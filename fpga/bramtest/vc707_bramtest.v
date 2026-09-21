// Block RAM shapes on the VC707, each answering one question: does what comes
// out match what went in?  See bramtest.v for why this exists rather than
// another build of the VM.
//
// The UART (115200 8N1) prints one line per shape:
//
//     bram test: x1x32768 rw PASS
//     bram test: x2x16384 rw FAIL
//     ...
//     bram test: 7/8 passed
//
// LED[i] is shape i's result while it runs; LED7 is "all done".
`default_nettype none
`ifndef SYS_DIV
`define SYS_DIV 20.000
`endif
`ifndef CLK_HZ
`define CLK_HZ 50_000_000
`endif

module vc707_bramtest (
	input  wire IO_CLK_P,
	input  wire IO_CLK_N,
	input  wire IO_RST,
	output wire UART_TX,
	input  wire UART_RX,
	output wire [7:0] LED
);
	wire clk, clk_mac_unused, rst_sys_n, locked;
	clkgen_vc707 #(.SYS_DIV(`SYS_DIV)) clkgen (
		.IO_CLK_P(IO_CLK_P), .IO_CLK_N(IO_CLK_N), .IO_RST_N(~IO_RST),
		.clk_sys(clk), .clk_mac(clk_mac_unused), .rst_sys_n(rst_sys_n), .locked(locked));

	reg [15:0] rstcnt = 16'd0;
	wire rst = !rstcnt[15];
	always @(posedge clk)
		if (!rst_sys_n) rstcnt <= 16'd0;
		else if (!rstcnt[15]) rstcnt <= rstcnt + 1'b1;

	// The shapes.  Depth is chosen so each is one RAMB36's worth at that
	// width, which is what makes yosys pick the width mode under test.
	localparam integer N = 10;
	wire [N-1:0] done, ok;
	wire [8:0]   bad9;      // the x9 case's wrong bit positions
	wire [31:0]  bad32;

	bram_case #(.WIDTH(1),  .AW(15), .ROM(0)) c0 (.clk(clk), .rst(rst), .done(done[0]), .ok(ok[0]), .badbits());
	bram_case #(.WIDTH(2),  .AW(14), .ROM(0)) c1 (.clk(clk), .rst(rst), .done(done[1]), .ok(ok[1]), .badbits());
	bram_case #(.WIDTH(4),  .AW(13), .ROM(0)) c2 (.clk(clk), .rst(rst), .done(done[2]), .ok(ok[2]), .badbits());
	bram_case #(.WIDTH(9),  .AW(12), .ROM(0)) c3 (.clk(clk), .rst(rst), .done(done[3]), .ok(ok[3]), .badbits(bad9));
	bram_case #(.WIDTH(18), .AW(11), .ROM(0)) c4 (.clk(clk), .rst(rst), .done(done[4]), .ok(ok[4]), .badbits());
	bram_case #(.WIDTH(36), .AW(10), .ROM(0)) c5 (.clk(clk), .rst(rst), .done(done[5]), .ok(ok[5]), .badbits());
	// The two the VM's own memories are: a 32-bit RAM written through A and
	// read through B, and a 32-bit ROM never written at all.
	bram_case #(.WIDTH(32), .AW(14), .ROM(0)) c6 (.clk(clk), .rst(rst), .done(done[6]), .ok(ok[6]), .badbits(bad32));
	bram_case #(.WIDTH(32), .AW(13), .ROM(1)) c7 (.clk(clk), .rst(rst), .done(done[7]), .ok(ok[7]), .badbits());
	// The shapes the Ethernet path uses and the x9 case above does not
	// cover: 2048 deep, so one RAMB18 rather than a RAMB36 -- at x9, and at
	// x8 (eight data bits in the x9 mode, the ninth never used), which is
	// what the packet lanes and the GMII retimer buffers are.
	bram_case #(.WIDTH(9),  .AW(11), .ROM(0)) c8 (.clk(clk), .rst(rst), .done(done[8]), .ok(ok[8]), .badbits());
	bram_case #(.WIDTH(8),  .AW(11), .ROM(0)) c9 (.clk(clk), .rst(rst), .done(done[9]), .ok(ok[9]), .badbits());

	assign LED = {&done, ok[9:8], ok[4:0]};

	// ─── reporting ────────────────────────────────────────────────────────
	// A tiny ROM of the text, walked a character at a time once everything
	// has finished.  Each shape's name is fixed; only PASS/FAIL varies.
	reg [7:0] msg [0:255];
	integer i;
	initial for (i = 0; i < 256; i = i + 1) msg[i] = 8'h20;

	// the x9 line carries three extra characters of detail
	wire [5:0] linelen = (shape == 3) ? 6'd31 : 6'd26;
	// "bram test: xNNxNNNNN rw ????\r\n" is built from parts below instead of
	// a character ROM, to keep this readable.
	reg [7:0] name [0:N*10-1];
	initial begin
		// each name is 10 characters, padded
		{name[0],name[1],name[2],name[3],name[4],name[5],name[6],name[7],name[8],name[9]} =
			"x1 x32768 ";
		{name[10],name[11],name[12],name[13],name[14],name[15],name[16],name[17],name[18],name[19]} =
			"x2 x16384 ";
		{name[20],name[21],name[22],name[23],name[24],name[25],name[26],name[27],name[28],name[29]} =
			"x4 x8192  ";
		{name[30],name[31],name[32],name[33],name[34],name[35],name[36],name[37],name[38],name[39]} =
			"x9 x4096  ";
		{name[40],name[41],name[42],name[43],name[44],name[45],name[46],name[47],name[48],name[49]} =
			"x18x2048  ";
		{name[50],name[51],name[52],name[53],name[54],name[55],name[56],name[57],name[58],name[59]} =
			"x36x1024  ";
		{name[60],name[61],name[62],name[63],name[64],name[65],name[66],name[67],name[68],name[69]} =
			"x32x16384 ";
		{name[70],name[71],name[72],name[73],name[74],name[75],name[76],name[77],name[78],name[79]} =
			"x32rom8192";
		{name[80],name[81],name[82],name[83],name[84],name[85],name[86],name[87],name[88],name[89]} =
			"x9 x2048  ";
		{name[90],name[91],name[92],name[93],name[94],name[95],name[96],name[97],name[98],name[99]} =
			"x8 x2048  ";
	end

	// One character at a time.  simpleuart's wait line is "strobe AND busy",
	// so it only means anything while the strobe is held: a one-cycle pulse
	// is accepted when the UART is idle and silently dropped when it is not,
	// and waiting afterwards for a busy flag that never rises hangs after
	// the first character.  So the strobe is held until wait falls, which is
	// when the byte is taken.  The strobe is registered, so nothing feeds
	// back into it -- driving it from the wait line makes a combinatorial
	// loop that Vivado rejects at DRC.
	reg [3:0]  shape;      // which line is being printed
	reg [5:0]  col;        // which character of it
	reg        printing;
	reg [7:0]  ch;
	reg        we_q;
	reg        phase;      // 0: present the character, 1: hold until taken
	wire       uart_busy;

	function [7:0] hex(input [3:0] v);
		hex = (v < 10) ? ("0" + v) : ("a" + (v - 10));
	endfunction

	function [7:0] char_at(input [3:0] sh, input [5:0] c);
		case (c)
			0:  char_at = "b";  1:  char_at = "r";  2:  char_at = "a";
			3:  char_at = "m";  4:  char_at = " ";  5:  char_at = "t";
			6:  char_at = "e";  7:  char_at = "s";  8:  char_at = "t";
			9:  char_at = ":";  10: char_at = " ";
			11, 12, 13, 14, 15, 16, 17, 18, 19, 20:
				char_at = name[sh * 10 + (c - 11)];
			21: char_at = ok[sh] ? "P" : "F";
			22: char_at = "A";
			23: char_at = ok[sh] ? "S" : "I";
			24: char_at = ok[sh] ? "S" : "L";
			// the x9 case also says which bit positions were wrong: bit 8
			// lives in the parity memory, so "8 only" is a different fault
			// from "all of them"
			25: char_at = (sh == 3) ? " " : 8'h0d;
			26: char_at = (sh == 3) ? "b" : 8'h0a;
			27: char_at = hex({3'b0, bad9[8]});
			28: char_at = hex(bad9[7:4]);
			29: char_at = hex(bad9[3:0]);
			30: char_at = 8'h0d;
			default: char_at = 8'h0a;
		endcase
	endfunction

	always @(posedge clk) begin
		we_q <= 1'b0;
		if (rst) begin
			shape    <= 0;
			col      <= 0;
			printing <= 1'b0;
			phase    <= 1'b0;
		end else if (!printing) begin
			// Print the lot again whenever the shapes have all finished, so a
			// console attached late still sees the results.
			if (&done) begin
				printing <= 1'b1;
				shape    <= 0;
				col      <= 0;
				phase    <= 1'b0;
			end
		end else if (!phase) begin
			ch    <= char_at(shape, col);
			we_q  <= 1'b1;
			phase <= 1'b1;
		end else begin
			we_q <= 1'b1;               // held until the UART takes it
			if (!uart_busy) begin
				we_q  <= 1'b0;
				phase <= 1'b0;
				if (col == linelen) begin
					col <= 0;
					if (shape == N - 1) printing <= 1'b0;
					else shape <= shape + 1'b1;
				end else col <= col + 1'b1;
			end
		end
	end

	simpleuart #(.DEFAULT_DIV(`CLK_HZ / 115200)) uart (
		.clk(clk), .resetn(!rst),
		.ser_tx(UART_TX), .ser_rx(UART_RX),
		.reg_div_we(4'b0), .reg_div_di(32'b0), .reg_div_do(),
		.reg_dat_we(we_q), .reg_dat_re(1'b0), .reg_dat_di({24'b0, ch}),
		.reg_dat_do(), .reg_dat_wait(uart_busy));
endmodule

`default_nettype wire
