// behavioural stand-ins for the Xilinx primitives the SD host uses, for the Verilator core simulations
module BUFG (input wire I, output wire O); assign O = I; endmodule
module IOBUF #(parameter IOSTANDARD = "", parameter SLEW = "") (inout wire IO, input wire I, output wire O, input wire T);
	assign IO = T ? 1'bz : I;
	assign O = IO;
endmodule
module OBUFT #(parameter IOSTANDARD = "", parameter SLEW = "") (output wire O, input wire I, input wire T);
	assign O = T ? 1'bz : I;
endmodule
// the one RAMB36E1 shape sd_wrap uses: true dual port, x36, byte write enables, READ_FIRST, unregistered output, port A's clock
// optionally inverted.  (Addresses are the primitive's: word address in [14:5].)
module RAMB36E1 #(parameter RAM_MODE = "TDP", parameter integer READ_WIDTH_A = 36, READ_WIDTH_B = 36, WRITE_WIDTH_A = 36, WRITE_WIDTH_B = 36,
                  parameter WRITE_MODE_A = "READ_FIRST", WRITE_MODE_B = "READ_FIRST", parameter integer DOA_REG = 0, DOB_REG = 0,
                  parameter [0:0] IS_CLKARDCLK_INVERTED = 1'b0, parameter SIM_DEVICE = "7SERIES") (
	input  wire CLKARDCLK, CLKBWRCLK, ENARDEN, ENBWREN, REGCEAREGCE, REGCEB, RSTRAMARSTRAM, RSTRAMB, RSTREGARSTREG, RSTREGB,
	input  wire [15:0] ADDRARDADDR, ADDRBWRADDR,
	input  wire [3:0] WEA, input wire [7:0] WEBWE,
	input  wire [31:0] DIADI, DIBDI, input wire [3:0] DIPADIP, DIPBDIP,
	output reg  [31:0] DOADO, DOBDO, output reg [3:0] DOPADOP, DOPBDOP,
	input  wire CASCADEINA, CASCADEINB, INJECTSBITERR, INJECTDBITERR,
	output wire CASCADEOUTA, CASCADEOUTB, DBITERR, SBITERR, output wire [7:0] ECCPARITY, output wire [8:0] RDADDRECC);
	reg [35:0] mem [0:1023];
	wire clka = CLKARDCLK ^ IS_CLKARDCLK_INVERTED;
	wire [9:0] aa = ADDRARDADDR[14:5], ab = ADDRBWRADDR[14:5];
	integer i;
	always @(posedge clka) if (ENARDEN) begin
		DOADO <= mem[aa][31:0];
		for (i = 0; i < 4; i = i + 1) if (WEA[i]) mem[aa][8*i +: 8] <= DIADI[8*i +: 8];
	end
	always @(posedge CLKBWRCLK) if (ENBWREN) begin
		DOBDO <= mem[ab][31:0];
		for (i = 0; i < 4; i = i + 1) if (WEBWE[i]) mem[ab][8*i +: 8] <= DIBDI[8*i +: 8];
	end
endmodule
