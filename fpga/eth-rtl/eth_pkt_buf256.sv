`timescale 1ns/1ps
// eth_pkt_buf256 -- a packet buffer, one 2K x 9 block RAM.
//
// 2048 x 9 is a RAMB18E1's own geometry, so one block holds the buffer with no
// width or depth stitching.  The ninth bit is spare -- a per-byte tag (end of
// frame, or the PCS's error flag) has an obvious future use; it is tied low
// here rather than left undriven.
//
// WAS 8 x RAM256X1S, ONE PER DATA BIT.  That is gone, and the reasons are worth
// keeping because every one of them was paid for:
//
//   * RAM256X1S is a MACRO, not a bel.  nextpnr's dist-RAM packer expands each
//     one into 4 address LUTs plus an F7/F7/F8 tree DURING PACKING -- after
//     place_lef has stamped the netlist -- so 119 cells arrived at the router
//     unplaced and whichever placer was running invented positions for them.
//   * Its wide write address needs WA7USED/WA8USED, and those arcs would not
//     route: 14 skips of the form D6LUT_O6 -> WA8USED_OUT.
//   * The read is ASYNCHRONOUS, and the buffer is read from the OTHER CLOCK
//     DOMAIN (rd_addr is driven on mac_clk for RX, pcs_clk for TX).  The async
//     read was doing the clock crossing implicitly, which is not a property to
//     rest a design on.
//   * Eight SLICEMs and sixteen MUXF7/F8 per buffer, and the replay read was a
//     combinational LUT-RAM plus three-level mux tree inside one 125 MHz cycle.
//
// A block RAM has none of those problems, and 2048 deep lifts the 256-byte
// bring-up limit: a full 1518-byte Ethernet frame now fits, where before
// anything longer was DROPPED WHOLE (see wr_room) rather than wrapped -- a
// wrapped frame looks like a valid short one and is far harder to diagnose.
//
// THE READ IS REGISTERED: the byte for the address held during cycle t appears
// at t+1.  That is this module's CONTRACT, not an implementation detail, and
// eth_gmii_retime256 delays its dv and its buffer-release handshake to match.
//
// PING-PONG, NOT FIFO.  Fill, then drain; the two phases never overlap.  That
// is what lets a single logical port serve both jobs, and it is unchanged --
// eth_stream_dma holds one frame at a time and TX is store-and-forward.  The
// two physical ports are used only to give each side its own CLOCK.
`default_nettype none
module eth_pkt_buf256 #(
	parameter integer ADDR_W = 11          // 2048 entries
) (
	// write side
	input  wire       clk,
	input  wire       rst,
	// READ CLOCK.  The read port is clocked from the READER's domain: the RX
	// buffer is written on pcs_clk and read on mac_clk, the TX buffer the other
	// way round.  Tie rd_clk to clk if both sides really are one domain.
	input  wire       rd_clk,

	// ---- fill ----------------------------------------------------------
	// wr_start REWINDS the write pointer.  Without it the buffer fills once and
	// never again: waddr and wr_count only cleared on rst, so the first frame
	// worked and every later one wrote past the end.  A single-frame testbench
	// passes happily; on a live network the background broadcast traffic fills
	// the buffer before the frame you care about arrives, and the design looks
	// dead from the very first packet.
	input  wire       wr_start,
	input  wire       wr_en,
	input  wire [7:0] wr_data,
	output reg  [ADDR_W-1:0] wr_count,   // bytes written so far
	output wire       wr_room,           // room for another byte

	// ---- drain ---------------------------------------------------------
	input  wire [ADDR_W-1:0] rd_addr,
	output wire [7:0] rd_data
);
	// A packet longer than the buffer is DROPPED, not wrapped.
	assign wr_room = wr_start || (wr_count != {ADDR_W{1'b1}});

	reg [ADDR_W-1:0] waddr;
	wire      do_wr = wr_en && wr_room;
	// The rewind must apply to THIS cycle's write, not the next one: wr_start
	// arrives WITH the frame's first byte, and a registered reset would not take
	// effect until the following edge, putting that byte at the previous frame's
	// address.  So the effective address is forced to 0 combinationally.
	wire [ADDR_W-1:0] waddr_eff = wr_start ? {ADDR_W{1'b0}} : waddr;

	always @(posedge clk) begin
		if (rst) begin
			waddr    <= {ADDR_W{1'b0}};
			wr_count <= {ADDR_W{1'b0}};
		end else if (wr_start) begin
			// a new frame: the first byte (if any) has just gone to address 0
			waddr    <= do_wr ? {{(ADDR_W-1){1'b0}}, 1'b1} : {ADDR_W{1'b0}};
			wr_count <= do_wr ? {{(ADDR_W-1){1'b0}}, 1'b1} : {ADDR_W{1'b0}};
		end else if (do_wr) begin
			waddr    <= waddr + 1'b1;
			wr_count <= wr_count + 1'b1;
		end
	end

	// SIMPLE DUAL PORT, one 9-bit array so it maps to a RAMB18E1 in its own
	// geometry rather than being stitched from narrower slices.  Inferred, not
	// instantiated: a sync-read single-port RAM is the one shape this toolchain
	// infers reliably (the explicit instantiation the LUT-RAM version needed was
	// because inference for a 256-deep ASYNC-read RAM is where it has gone wrong
	// before -- a 512x32 inferred FIFO came out as 16462 flip-flops).
	reg [8:0] mem [0:(1<<ADDR_W)-1];
	reg [8:0] rd_q;
	always @(posedge clk)
		if (do_wr) mem[waddr_eff] <= {1'b0, wr_data};
	always @(posedge rd_clk)
		rd_q <= mem[rd_addr];
	assign rd_data = rd_q[7:0];
endmodule
`default_nettype wire
