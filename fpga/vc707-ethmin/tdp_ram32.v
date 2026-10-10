// tdp_ram32: a 2**AW-word x 32 RAM, two ports on one clock (AW 15..17).  Used for the program code RAM and the staging RAM.
//   a: a read port (registered output, always enabled): the fetch unit, or the sequencer
//   b: reads and byte writes (read-first, registered output, held while b_en is low)
//
// Explicit RAMB36E1, one per bit per 32K of depth (x1), NOT inferred: yosys builds a 128K x 1 slice as two cascaded pairs, and
// nextpnr cannot route CASCADEOUT -> CASCADEIN ("Failed to route arc ... CASCADEOUTA to CASCADEINA").  Here the depth blocks
// stand alone and the depth mux is in fabric, after the registered outputs, selected by the top two address bits a cycle later.
// The behavioural array is for the simulators, which do not define SYNTHESIS.
`default_nettype none
module tdp_ram32 #(parameter integer AW = 17) (
	input  wire        clk,
	input  wire [AW-1:0] a_addr,
	output wire [31:0] a_q,
	input  wire        b_en,
	input  wire [AW-1:0] b_addr,
	input  wire [3:0]  b_be,
	input  wire [31:0] b_data,
	output wire [31:0] b_q
);
`ifdef SYNTHESIS
	localparam integer DEPTHS = 1 << (AW - 15);
	localparam integer SW = AW > 15 ? AW - 15 : 1;
	wire [SW-1:0] a_hi = a_addr >> 15, b_hi = b_addr >> 15;
	reg [SW-1:0] a_sel, b_sel;
	always @(posedge clk) begin a_sel <= a_hi; if (b_en) b_sel <= b_hi; end
	wire [31:0] a_blk [0:DEPTHS-1];
	wire [31:0] b_blk [0:DEPTHS-1];
	genvar d, i;
	generate for (d = 0; d < DEPTHS; d = d + 1) begin : depth
		wire [31:0] qa, qb;
		for (i = 0; i < 32; i = i + 1) begin : bit_
			wire we = b_be[i/8] && b_hi == d;
			RAMB36E1 #(
				.RAM_MODE("TDP"),
				.READ_WIDTH_A(1), .READ_WIDTH_B(1), .WRITE_WIDTH_A(1), .WRITE_WIDTH_B(1),
				.WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
				.DOA_REG(0), .DOB_REG(0),
				.SIM_DEVICE("7SERIES")
			) ram (
				.CLKARDCLK(clk), .CLKBWRCLK(clk),
				.ENARDEN(1'b1), .ENBWREN(b_en),
				.REGCEAREGCE(1'b0), .REGCEB(1'b0),
				.RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0), .RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
				.ADDRARDADDR({1'b0, a_addr[14:0]}), .ADDRBWRADDR({1'b0, b_addr[14:0]}),
				.DIADI(32'b0), .DIPADIP(4'b0), .DIBDI({31'b0, b_data[i]}), .DIPBDIP(4'b0),
				.WEA(4'b0), .WEBWE({8{we}}),
				.DOADO(qa[i]), .DOPADOP(), .DOBDO(qb[i]), .DOPBDOP(),
				.CASCADEINA(1'b0), .CASCADEINB(1'b0), .CASCADEOUTA(), .CASCADEOUTB(),
				.INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
				.DBITERR(), .SBITERR(), .ECCPARITY(), .RDADDRECC());
		end
		assign a_blk[d] = qa;
		assign b_blk[d] = qb;
	end endgenerate
	assign a_q = a_blk[a_sel];
	assign b_q = b_blk[b_sel];
`else
	reg [31:0] mem [0:(1<<AW)-1];
	reg [31:0] a_r, b_r;
	integer lane;
	always @(posedge clk) begin
		a_r <= mem[a_addr];
		for (lane = 0; lane < 4; lane = lane + 1)
			if (b_en && b_be[lane]) mem[b_addr][8*lane +: 8] <= b_data[8*lane +: 8];
		if (b_en) b_r <= mem[b_addr];
	end
	assign a_q = a_r;
	assign b_q = b_r;
`endif
endmodule
`default_nettype wire
