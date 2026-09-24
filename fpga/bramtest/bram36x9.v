// One RAMB36E1 in x9 mode, instantiated by hand.
//
// The inferred x9 case (bramtest.v) fails in the open flow and passes in
// Vivado, but the two flows do not build it the same way: yosys picks one
// RAMB36 at x9, Vivado picks two RAMB18s.  So the comparison does not isolate
// anything -- it could be the mode, or it could be the choice of primitive.
//
// Instantiating the primitive removes that variable.  Both flows then place
// the same cell in the same mode, and the FASM difference between them is
// about x9 and nothing else.  Only bit 8 came back wrong on the board, and
// bit 8 is the one that lives in the parity memory (DIP/DOP), so that is
// what this is built to catch.
//
// Written through port A, read through port B, which is how the VM uses its
// memories and how the failing case reads.
`default_nettype none

module bram36x9 (
	input  wire clk,
	input  wire rst,
	output reg  done,
	output reg  ok,
	output reg [8:0] badbits
);
	// x9 on a RAMB36 is 4096 words: address bits [14:3], data DI[7:0] plus
	// the parity bit DIP[0].
	localparam integer DEPTH = 4096;

	function [8:0] pattern(input [11:0] a);
		pattern = {~a[2:0], a[5:0] ^ 6'b101010};
	endfunction

	reg [11:0]  idx;
	reg [11:0]  a_addr, b_addr;
	reg         a_we;
	reg [8:0]   a_data;
	reg [11:0]  addr_d1;
	reg         presenting, valid_d1;
	reg [1:0]   state;
	localparam [1:0] S_FILL = 2'd0, S_READ = 2'd1, S_DONE = 2'd2;

	wire [31:0] dob;
	wire [3:0]  dopb;
	wire [8:0]  b_q = {dopb[0], dob[7:0]};

	RAMB36E1 #(
		.RAM_MODE("TDP"),
		.READ_WIDTH_A(9), .READ_WIDTH_B(9),
		.WRITE_WIDTH_A(9), .WRITE_WIDTH_B(9),
		.WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
		.DOA_REG(0), .DOB_REG(0),
		.SIM_DEVICE("7SERIES")
	) ram (
		.CLKARDCLK(clk), .CLKBWRCLK(clk),
		.ENARDEN(1'b1), .ENBWREN(1'b1),
		.REGCEAREGCE(1'b0), .REGCEB(1'b0),
		.RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0),
		.RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
		// port A writes: the address sits at [14:3] for x9
		.ADDRARDADDR({1'b0, a_addr, 3'b000}),
		.DIADI({24'b0, a_data[7:0]}), .DIPADIP({3'b0, a_data[8]}),
		.WEA({4{a_we}}), .WEBWE(8'b0),
		// port B reads
		.ADDRBWRADDR({1'b0, b_addr, 3'b000}),
		.DIBDI(32'b0), .DIPBDIP(4'b0),
		.DOADO(), .DOPADOP(), .DOBDO(dob), .DOPBDOP(dopb),
		.CASCADEINA(1'b0), .CASCADEINB(1'b0),
		.CASCADEOUTA(), .CASCADEOUTB(),
		.INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
		.DBITERR(), .SBITERR(), .ECCPARITY(), .RDADDRECC()
	);

	always @(posedge clk) begin
		if (rst) begin
			state      <= S_FILL;
			idx        <= 0;
			a_we       <= 1'b0;
			presenting <= 1'b0;
			valid_d1   <= 1'b0;
			done       <= 1'b0;
			ok         <= 1'b1;
			badbits    <= 9'b0;
		end else begin
			a_we       <= 1'b0;
			presenting <= 1'b0;
			addr_d1    <= b_addr;
			valid_d1   <= presenting;
			case (state)
				S_FILL: begin
					a_addr <= idx;
					a_data <= pattern(idx);
					a_we   <= 1'b1;
					if (idx == DEPTH - 1) begin
						idx   <= 0;
						state <= S_READ;
					end else idx <= idx + 1'b1;
				end
				S_READ: begin
					b_addr     <= idx;
					presenting <= 1'b1;
					if (idx == DEPTH - 1) state <= S_DONE;
					else idx <= idx + 1'b1;
				end
				default:
					if (!valid_d1 && !presenting) done <= 1'b1;
			endcase
			if (valid_d1 && b_q !== pattern(addr_d1)) begin
				ok      <= 1'b0;
				badbits <= badbits | (b_q ^ pattern(addr_d1));
			end
		end
	end
endmodule

`default_nettype wire
