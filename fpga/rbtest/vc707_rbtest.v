// Readback test: is the bitstream a scan chain?
//
// Every flip-flop's initial value is an INIT bit in the bitstream, and
// readback with capture (GCAPTURE) puts the live values back into the same
// frames.  If that works, a test vector is a bitstream and a response is a
// readback -- no scan cells, and the placement under test is untouched.
// This design is what the claim is checked on: one of each register type
// with non-zero INITs, a carry-chain counter, a distributed RAM and a block
// RAM, all clocked from a gate that JTAG controls, so the state is held at
// its INIT until told to advance, and advances by exactly as many cycles as
// it is told.
//
// Control: BSCANE2 USER1, a 32-bit register shifted LSB first.
//   [23:0]  N       pulses to release on the next UPDATE (0 = none)
//   [31]    free    run freely while set
// CAPTURE loads the register with {cnt, lfsr, ac, ss} so the DUT's state can
// be read over JTAG as well, independently of readback.
`default_nettype none
`ifndef SYS_DIV
`define SYS_DIV 16.000
`endif

module vc707_rbtest (
	input  wire IO_CLK_P,
	input  wire IO_CLK_N,
	input  wire IO_RST,
	output wire [7:0] LED
);
	wire clk_free, clk_mac_unused, rst_sys_n, locked;
	clkgen_vc707 #(.SYS_DIV(`SYS_DIV)) clkgen (
		.IO_CLK_P(IO_CLK_P), .IO_CLK_N(IO_CLK_N), .IO_RST_N(1'b1),
		.clk_sys(clk_free), .clk_mac(clk_mac_unused), .rst_sys_n(rst_sys_n), .locked(locked));

	// ─── JTAG: USER1 ────────────────────────────────────────────────────
	wire cap, drck, sel, shift, tdi, update;
	wire tdo;
	BSCANE2 #(.JTAG_CHAIN(1)) bscan (
		.CAPTURE(cap), .DRCK(drck), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift),
		.TCK(), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo));

	reg  [31:0] sr = 32'd0;
	wire [31:0] status;
	always @(posedge drck)
		if (sel) begin
			if (cap)        sr <= status;
			else if (shift) sr <= {tdi, sr[31:1]};
		end
	assign tdo = sr[0];

	// UPDATE is a TCK-derived pulse: the new control word and a request
	// toggle, both then crossed into the free-running clock.
	reg [31:0] ctrl  = 32'd0;
	reg        req_t = 1'b0;
	always @(posedge update)
		if (sel) begin
			ctrl  <= sr;
			req_t <= ~req_t;
		end

	reg [2:0]  req_s = 3'b000;
	reg [23:0] left  = 24'd0;
	reg        ce    = 1'b0;
	always @(posedge clk_free) begin
		req_s <= {req_s[1:0], req_t};
		if (req_s[2] != req_s[1])
			left <= ctrl[23:0];
		else if (left != 0 && ce)
			left <= left - 24'd1;
		// registered, so the gate's enable is glitch-free: a cycle with ce
		// high is a cycle the DUT sees, and left counts exactly those
		ce <= ctrl[31] || (req_s[2] != req_s[1] ? (ctrl[23:0] != 0) : (left > (ce ? 24'd1 : 24'd0)));
	end

	wire clk;
	BUFGCE gate (.I(clk_free), .CE(ce), .O(clk));

	// ─── the DUT: one of everything readback should see ─────────────────
	reg [7:0]  cnt  = 8'h05;                 // FDRE + CARRY4
	reg [15:0] lfsr = 16'hACE1;              // FDRE with mixed INIT
	reg [3:0]  ac   = 4'b1010;               // FDCE/FDPE: async clear on the button
	reg [3:0]  ss   = 4'b0101;               // FDSE: sync set
	always @(posedge clk) cnt <= cnt + 8'd1;
	always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
	always @(posedge clk or posedge IO_RST)
		if (IO_RST) ac <= 4'b0000; else ac <= {ac[2:0], cnt[0]};
	always @(posedge clk)
		if (cnt[7]) ss <= 4'hF; else ss <= ss ^ {3'b000, lfsr[0]};

	// distributed RAM: written from the counter, read at the LFSR's address
	reg [3:0] dram [0:63];
	integer i;
	initial for (i = 0; i < 64; i = i + 1) dram[i] = i[3:0] ^ 4'h3;
	reg [3:0] dq = 4'h0;
	always @(posedge clk) begin
		dram[cnt[5:0]] <= cnt[3:0];
		dq <= dram[lfsr[5:0]];
	end

	// block RAM, 1024 x 18, with initial contents
	reg [17:0] bram [0:1023];
	initial for (i = 0; i < 1024; i = i + 1) bram[i] = {i[9:0], 8'hA5} ^ 18'h15555;
	reg [17:0] bq = 18'h0;
	always @(posedge clk) begin
		if (cnt[6]) bram[{cnt[1:0], lfsr[7:0]}] <= {lfsr, 2'b11};
		bq <= bram[lfsr[9:0]];
	end

	assign status = {cnt, lfsr, ac, ss};
	assign LED = {cnt[3:0], dq[1:0], bq[1:0]};
endmodule

`default_nettype wire
