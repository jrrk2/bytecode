// INTCODE machine (M. Richards, "INTCODE - An Interpretive Machine Code for BCPL"), after bcplkit's icint.c.
//
// Registers A B C D P G and the instruction word W.  An instruction word is F(3) I P G D(1) address(9): function in bits 15:13,
// the I, P, G and D flags in bits 12:9, a 9-bit address in 8:0; if D is set the effective address is the next word.  The effective
// address is address (+P)(+G), then indirect through the store if I.  Eight functions: L S A J T F K X; X runs one of the operate
// codes 1..39 (arithmetic, logic, compares, switch, call/return, the stream operations, getbyte/putbyte).
//
// The store is outside: a synchronous RAM, read data the cycle after m_re.  Stream operations (X24..29, 33, 34, 38, 39) are requests
// on the io port, answered by io_ack with io_res (a UART, a disc, or the host in simulation).  WIDTH is the word size: 32 matches the
// kit's INTCODE programs as shipped (four characters to a word); 16 is the small machine, for which the compiler is rebuilt.
// An instruction takes 4 to 6 clocks (more for the multi-word operate codes).  Multiply and divide are single-cycle here, and would be
// iterative on a small device.
`default_nettype none
module intcode_core #(
	parameter WIDTH = 32,
	parameter AW    = 16
) (
	input  wire             clk,
	input  wire             rst,
	input  wire [WIDTH-1:0] init_c, init_p, init_g,      // the registers as the loader leaves them
	output reg  [AW-1:0]    m_addr,
	output reg  [WIDTH-1:0] m_wdata,
	output reg              m_we,
	output reg              m_re,
	input  wire [WIDTH-1:0] m_rdata,
	output reg              io_req,
	output reg  [5:0]       io_op,
	output reg  [WIDTH-1:0] io_a,
	input  wire             io_ack,
	input  wire [WIDTH-1:0] io_res,
	output reg              instr_done,                   // one pulse per instruction executed
	output reg              halted,
	output reg  [WIDTH-1:0] result
);
	localparam BPW = WIDTH / 8;                           // characters to a word

	localparam [5:0]
		S_F0 = 0, S_F1 = 1, S_F2 = 2, S_F3 = 3, S_AD = 4, S_IND = 5, S_IND2 = 6, S_EX = 7,
		S_K1 = 8, S_K2 = 9,
		S_X1 = 10, S_X4A = 11, S_X4B = 12, S_X31 = 13,
		S_SW0 = 14, S_SW1 = 15, S_SWL = 16, S_SWC = 17, S_SWD = 18,
		S_C0 = 19, S_C1 = 20, S_C2 = 21, S_C3 = 22, S_C4 = 23, S_C5 = 24,      // X35: call with a new frame
		S_GB0 = 25,                                                           // getbyte
		S_PB0 = 26, S_PB1 = 27, S_PB2 = 28,                                    // putbyte
		S_IO = 29, S_IOW = 30, S_HALT = 31;

	reg [5:0]       st;
	reg [WIDTH-1:0] A, B, C, D, P, G, W;
	reg [WIDTH-1:0] T0, T1;                               // scratch for the multi-word operate codes

	wire [2:0] F = W[15:13];
	wire       pbit = W[11], gbit = W[10], ibit = W[12];
	wire signed [WIDTH-1:0] sA = A, sB = B;
	wire [WIDTH-1:0] TRUE_ = {WIDTH{1'b1}};               // ~0

	// the operate codes that compute from A and B alone
	reg [WIDTH-1:0] xres;
	reg             xvalid;
	always @(*) begin
		xvalid = 1'b1; xres = A;
		case (D[5:0])
			2:  xres = -A;
			3:  xres = ~A;
			5:  xres = B * A;
			6:  xres = (A == 0) ? {WIDTH{1'b0}} : $signed(sB / sA);
			7:  xres = (A == 0) ? {WIDTH{1'b0}} : $signed(sB % sA);
			8:  xres = B + A;
			9:  xres = B - A;
			10: xres = (B == A)    ? TRUE_ : 0;
			11: xres = (B != A)    ? TRUE_ : 0;
			12: xres = (sB <  sA)  ? TRUE_ : 0;
			13: xres = (sB >= sA)  ? TRUE_ : 0;
			14: xres = (sB >  sA)  ? TRUE_ : 0;
			15: xres = (sB <= sA)  ? TRUE_ : 0;
			16: xres = (A >= WIDTH) ? {WIDTH{1'b0}} : (B << A[5:0]);
			17: xres = (A >= WIDTH) ? (sB < 0 ? TRUE_ : {WIDTH{1'b0}}) : (sB >>> A[5:0]);
			18: xres = B & A;
			19: xres = B | A;
			20: xres = B ^ A;
			21: xres = B ^ ~A;
			default: xvalid = 1'b0;
		endcase
	end

	// getbyte / putbyte: character i of the string at word s is in word s + i/BPW, first character in the high byte
	wire [WIDTH-1:0] bw = B / BPW;
	wire [3:0]       bm = (B % BPW) ^ (BPW - 1);
	reg  [WIDTH-1:0] tword;
	wire [WIDTH-1:0] bmask = {{(WIDTH-8){1'b0}}, 8'hff} << (8 * bm);

	always @(*) begin
		m_addr = C[AW-1:0]; m_wdata = A; m_we = 1'b0; m_re = 1'b0;
		io_req = 1'b0; io_op = D[5:0]; io_a = A;
		case (st)
			S_F0:  begin m_addr = C[AW-1:0]; m_re = 1'b1; end
			S_F2:  begin m_addr = C[AW-1:0]; m_re = 1'b1; end
			S_IND: begin m_addr = D[AW-1:0]; m_re = 1'b1; end
			S_EX: case (F)
				3'd1: begin m_addr = D[AW-1:0]; m_wdata = A; m_we = 1'b1; end
				3'd7: case (D[5:0])
					1:  begin m_addr = A[AW-1:0]; m_re = 1'b1; end
					4:  begin m_addr = P[AW-1:0] + 1'b1; m_re = 1'b1; end
					23: begin m_addr = C[AW-1:0]; m_re = 1'b1; end
					31: begin m_addr = P[AW-1:0]; m_re = 1'b1; end
					35: begin m_addr = P[AW-1:0]; m_re = 1'b1; end
					36: begin m_addr = A[AW-1:0] + bw[AW-1:0]; m_re = 1'b1; end
					37: begin m_addr = P[AW-1:0] + 4; m_re = 1'b1; end
					default: ;
				endcase
				default: ;
			endcase
			S_K1:  begin m_addr = D[AW-1:0]; m_wdata = P; m_we = 1'b1; end
			S_K2:  begin m_addr = D[AW-1:0] + 1'b1; m_wdata = C; m_we = 1'b1; end
			S_X4A: begin m_addr = P[AW-1:0]; m_re = 1'b1; end
			S_SW0: begin m_addr = C[AW-1:0] + 1'b1; m_re = 1'b1; end
			S_SWL: begin m_addr = C[AW-1:0] + 2; m_re = 1'b1; end
			S_SWC: begin m_addr = C[AW-1:0] + 1'b1; m_re = 1'b1; end
			S_C0:  begin m_addr = P[AW-1:0] + 1'b1; m_re = 1'b1; end
			S_C1:  begin m_addr = D[AW-1:0]; m_wdata = T0; m_we = 1'b1; end
			S_C2:  begin m_addr = D[AW-1:0] + 1'b1; m_wdata = T1; m_we = 1'b1; end
			S_C3:  begin m_addr = D[AW-1:0] + 2; m_wdata = P; m_we = 1'b1; end
			S_C4:  begin m_addr = D[AW-1:0] + 3; m_wdata = B; m_we = 1'b1; end
			S_PB0: begin m_addr = A[AW-1:0] + bw[AW-1:0]; m_re = 1'b1; end
			S_PB2: begin m_addr = A[AW-1:0] + bw[AW-1:0]; m_wdata = tword; m_we = 1'b1; end
			S_IO:  io_req = 1'b1;
			default: ;
		endcase
	end

	always @(posedge clk) begin
		instr_done <= 1'b0;
		if (rst) begin
			st <= S_F0; halted <= 1'b0; result <= 0;
			A <= 0; B <= 0; D <= 0; W <= 0; T0 <= 0; T1 <= 0; tword <= 0;
			C <= init_c; P <= init_p; G <= init_g;
		end else case (st)
			// ---- fetch: W = M[C++]; D = the address field, or the next word if the D flag is set ----
			S_F0: st <= S_F1;
			S_F1: begin
				W <= m_rdata; C <= C + 1;
				if (m_rdata[9]) st <= S_F2;
				else begin D <= {{(WIDTH-9){1'b0}}, m_rdata[8:0]}; st <= S_AD; end
			end
			S_F2: st <= S_F3;
			S_F3: begin D <= m_rdata; C <= C + 1; st <= S_AD; end
			// ---- the effective address: + P, + G, then through the store if I ----
			S_AD: begin
				D <= D + (pbit ? P : {WIDTH{1'b0}}) + (gbit ? G : {WIDTH{1'b0}});
				st <= ibit ? S_IND : S_EX;
			end
			S_IND:  st <= S_IND2;
			S_IND2: begin D <= m_rdata; st <= S_EX; end
			// ---- execute ----
			S_EX: begin
				st <= S_F0;
				instr_done <= 1'b1;
				case (F)
					3'd0: begin B <= A; A <= D; end
					3'd1: ;                                              // the store is on the bus
					3'd2: A <= A + D;
					3'd3: C <= D;
					3'd4: begin if (A != 0) C <= D; A <= (A == 0) ? 1 : 0; end   // A = !A, then jump if that is zero
					3'd5: if (A == 0) C <= D;
					3'd6: begin D <= D + P; st <= S_K1; instr_done <= 1'b0; end
					3'd7: begin
						if (xvalid) A <= xres;
						else case (D[5:0])
							1:  begin st <= S_X1;  instr_done <= 1'b0; end
							4:  begin st <= S_X4A; instr_done <= 1'b0; end
							22: begin halted <= 1'b1; result <= 0; st <= S_HALT; end
							23: begin st <= S_SW0; instr_done <= 1'b0; end
							24, 25, 26, 27, 28, 29, 33, 34, 38, 39: begin st <= S_IO; instr_done <= 1'b0; end
							30: begin halted <= 1'b1; result <= A; st <= S_HALT; end
							31: begin st <= S_X31; instr_done <= 1'b0; end
							32: begin P <= A; C <= B; end
							35: begin st <= S_C0; instr_done <= 1'b0; D <= P + B + 1; end
							36: begin st <= S_GB0; instr_done <= 1'b0; end
							37: begin st <= S_PB0; instr_done <= 1'b0; end
							default: begin halted <= 1'b1; result <= -1; st <= S_HALT; end   // INTCODE ERROR
						endcase
					end
				endcase
			end
			// ---- K: D += P; M[D] = P; M[D+1] = C; P = D; C = A ----
			S_K1: st <= S_K2;
			S_K2: begin P <= D; C <= A; instr_done <= 1'b1; st <= S_F0; end
			// ---- X1: A = M[A];  X31: A = M[P] ----
			S_X1:  begin A <= m_rdata; instr_done <= 1'b1; st <= S_F0; end
			S_X31: begin A <= m_rdata; instr_done <= 1'b1; st <= S_F0; end
			// ---- X4 (return): C = M[P+1]; P = M[P] ----
			S_X4A: begin C <= m_rdata; st <= S_X4B; end
			S_X4B: begin P <= m_rdata; instr_done <= 1'b1; st <= S_F0; end
			// ---- X23 (switch): B = M[C]; D = M[C+1]; scan the B pairs after them for A; C = the matching target or the default ----
			S_SW0: begin B <= m_rdata; st <= S_SW1; end
			S_SW1: begin D <= m_rdata; st <= S_SWL; end
			S_SWL: begin
				if (B == 0) begin C <= D; instr_done <= 1'b1; st <= S_F0; end
				else begin B <= B - 1; C <= C + 2; st <= S_SWC; end
			end
			S_SWC: st <= (A == m_rdata) ? S_SWD : S_SWL;
			S_SWD: begin C <= m_rdata; instr_done <= 1'b1; st <= S_F0; end
			// ---- X35: D = P + B + 1; M[D] = M[P]; M[D+1] = M[P+1]; M[D+2] = P; M[D+3] = B; P = D; C = A ----
			S_C0: begin T0 <= m_rdata; st <= S_C1; end
			S_C1: begin T1 <= m_rdata; st <= S_C2; end
			S_C2: st <= S_C3;
			S_C3: st <= S_C4;
			S_C4: st <= S_C5;
			S_C5: begin P <= D; C <= A; instr_done <= 1'b1; st <= S_F0; end
			// ---- X36: A = getbyte(A, B) ----
			S_GB0: begin A <= (m_rdata >> (8 * bm)) & {{(WIDTH-8){1'b0}}, 8'hff}; instr_done <= 1'b1; st <= S_F0; end
			// ---- X37: putbyte(A, B, M[P+4]) ----
			S_PB0: begin T0 <= m_rdata; st <= S_PB1; end
			S_PB1: begin tword <= (m_rdata & ~bmask) | (({{(WIDTH-8){1'b0}}, T0[7:0]}) << (8 * bm)); st <= S_PB2; end
			S_PB2: begin instr_done <= 1'b1; st <= S_F0; end
			// ---- stream operations: one request, one answer ----
			S_IO:  st <= S_IOW;
			S_IOW: if (io_ack) begin
				if (D[5:0] == 26 || D[5:0] == 28 || D[5:0] == 29 || D[5:0] == 38 || D[5:0] == 39) A <= io_res;
				instr_done <= 1'b1; st <= S_F0;
			end
			default: ;                                                       // S_HALT
		endcase
	end
endmodule
`default_nettype wire
