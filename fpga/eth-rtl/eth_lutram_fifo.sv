`timescale 1ns/1ps
// eth_lutram_fifo -- 2 KiB asynchronous FIFO built from CLB distributed RAM.
//
// WHY THIS EXISTS -- it is a PLACEMENT fix, not a throughput one.
//
// eth_stream_dma writes the RX stream straight into the SoC's main dual-port
// memory with port B clocked by eth_clk.  That is elegant (the data path never
// crosses a clock boundary) and it is the reason the 125 MHz domain cannot
// close timing: the domain is TETHERED TO A BRAM COLUMN.  BRAM lives in a few
// fixed columns, so eth_clk logic is pulled across the die to reach it --
// measured, axis_gmii_tx's 327 cells spread over X 1..50, and the critical path
// was 14.5 ns of ROUTING against 1.6 ns of logic.  The logic is fast enough for
// 625 MHz; it is the distance that fails.
//
// Distributed RAM lives in SLICEM, and SLICEM columns are interleaved
// throughout the fabric rather than gathered into a handful of columns.  So a
// LUTRAM FIFO can sit wherever the rest of the 125 MHz island sits -- next to
// the PCS/GT -- and the island becomes compact and self-contained.
//
// The secondary win is the larger one: with its storage local, the whole
// 125 MHz island (MAC + FIFO) becomes freezable as ONE hard macro.  Today's
// frozen macro closes at 264 MHz and is irrelevant to the failure, because the
// logic that actually fails (eth.i_mac) sits OUTSIDE it.
//
// 512 x 32 = 2 KiB = one maximum Ethernet frame (1518 B), so store-and-forward
// holds a whole frame locally and the drain side never has to keep up with line
// rate inside a frame -- only between frames.
//
// NO OCCUPANCY OUTPUT, deliberately.  The obvious interface would report a
// level so the RX side could ask "is there room for a worst-case frame?" before
// committing to one.  It does not need to: the caller runs ONE FRAME
// OUTSTANDING -- the eth side will not start another frame until the CPU has
// acked, and the ack cannot happen until the drain engine has emptied the FIFO.
// So an accepted frame always meets an empty FIFO.  Reporting a level would mean
// converting a gray pointer back to binary, which is the one construct here that
// would need a loop, so the protocol invariant buys real simplicity.
//
// ram_style IS LOAD-BEARING.  Without it yosys infers BRAM for a RAM this size
// and the tether is silently back -- the build still works, still routes, and
// still misses timing for the original reason with no sign of why.  Check the
// synthesis log for RAM64X1D/RAM32M, not RAMB18/RAMB36.
`default_nettype none
module eth_lutram_fifo #(
	parameter integer WIDTH = 32,
	parameter integer DEPTH = 512,          // 512 x 32 = 2 KiB = one max frame
	parameter integer AW    = 9             // clog2(DEPTH)
) (
	// ---- write side (eth_clk, 125 MHz) ---------------------------------
	input  wire              wclk,
	input  wire              wrst,
	input  wire              wr_en,
	input  wire [WIDTH-1:0]  wr_data,
	output wire              wr_full,

	// ---- read side (cpu_clk) -------------------------------------------
	input  wire              rclk,
	input  wire              rrst,
	input  wire              rd_en,
	output wire [WIDTH-1:0]  rd_data,
	output wire              rd_empty
);

	// Distributed RAM: written synchronously on wclk, read ASYNCHRONOUSLY.
	// The asynchronous read is what makes this a LUTRAM inference rather than a
	// block RAM one, and it also removes the read-latency bubble a BRAM FIFO
	// needs at the empty boundary.
	(* ram_style = "distributed" *)
	reg [WIDTH-1:0] mem [0:DEPTH-1];

	// Binary counters for arithmetic, gray for crossing.  Both carry ONE EXTRA
	// BIT so full and empty are distinguishable: with AW bits alone, wptr==rptr
	// means both, and the FIFO silently reports empty when it has wrapped.
	reg [AW:0] wbin, wgray, rbin, rgray;
	// Full/empty are REGISTERED, not combinational.  Computing them as a
	// comparison of the live pointers puts the comparator AND the pointer
	// adder in series in one period, via the consumer: measured on the
	// standalone MAC island that was the critical path --
	//   wr_full -> (consumer) wr_en -> wbin_nxt CARRY4 chain -> wgray
	// at 8.9 ns, capping a 358-cell design on an EMPTY die at 112 MHz.  The
	// flag is derived from the NEXT pointer value, so registering it costs no
	// correctness: it still asserts the cycle the FIFO becomes full, never a
	// cycle late.  (Cummings, "Simulation and Synthesis Techniques for
	// Asynchronous FIFO Design".)
	reg        wfull_q, rempty_q;
	reg [AW:0] wq1_rgray, wq2_rgray;        // read ptr, seen from the write side
	reg [AW:0] rq1_wgray, rq2_wgray;        // write ptr, seen from the read side

	// Gray conversion is written as a plain EXPRESSION, not a function with a
	// loop.  Only the binary->gray direction is needed, and it is one XOR; the
	// gray->binary direction would need a suffix-XOR loop and exists only to
	// compute occupancy, which this FIFO deliberately does not report (see the
	// note on levels above).  Loop-bearing functions are also the shape that has
	// silently mis-emitted through the SVS front end before, so avoiding one
	// here costs nothing and removes a whole class of risk.

	wire [AW:0] wbin_nxt  = wbin + {{AW{1'b0}}, (wr_en && !wfull_q)};
	wire [AW:0] rbin_nxt  = rbin + {{AW{1'b0}}, (rd_en && !rempty_q)};
	wire [AW:0] wgray_nxt = wbin_nxt ^ (wbin_nxt >> 1);
	wire [AW:0] rgray_nxt = rbin_nxt ^ (rbin_nxt >> 1);
	// full when the next write pointer would meet the read pointer with the
	// wrap bit inverted; empty when the next read pointer catches the write one
	wire wfull_nxt  = (wgray_nxt == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});
	wire rempty_nxt = (rgray_nxt == rq2_wgray);

	// ---- write side ----------------------------------------------------
	always @(posedge wclk) begin
		if (wrst) begin
			wbin <= {(AW+1){1'b0}};
			wgray <= {(AW+1){1'b0}};
			wfull_q <= 1'b0;
			wq1_rgray <= {(AW+1){1'b0}};
			wq2_rgray <= {(AW+1){1'b0}};
		end else begin
			if (wr_en && !wfull_q) mem[wbin[AW-1:0]] <= wr_data;
			wbin  <= wbin_nxt;
			wgray <= wgray_nxt;
			wfull_q <= wfull_nxt;
			// two-flop synchroniser: gray code guarantees at most one bit
			// changes, so a sample taken mid-transition is either the old or the
			// new value, never a third one that was never a real pointer.
			wq1_rgray <= rgray;
			wq2_rgray <= wq1_rgray;
		end
	end

	assign wr_full = wfull_q;

	// ---- read side -----------------------------------------------------
	always @(posedge rclk) begin
		if (rrst) begin
			rbin <= {(AW+1){1'b0}};
			rgray <= {(AW+1){1'b0}};
			rempty_q <= 1'b1;
			rq1_wgray <= {(AW+1){1'b0}};
			rq2_wgray <= {(AW+1){1'b0}};
		end else begin
			rbin  <= rbin_nxt;
			rgray <= rgray_nxt;
			rempty_q <= rempty_nxt;
			rq1_wgray <= wgray;
			rq2_wgray <= rq1_wgray;
		end
	end

	assign rd_empty = rempty_q;
	// Asynchronous read -- the LUTRAM output is combinational, so rd_data is the
	// head of the queue in the same cycle rd_empty is valid.
	assign rd_data  = mem[rbin[AW-1:0]];

endmodule
`default_nettype wire
