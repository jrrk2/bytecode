// A double-precision floating-point unit for the OCaml bytecode processor,
// built from Berkeley HardFloat's cores (hardfloat.v) with the IEEE boundary
// in recode64.v.
//
// The processor reaches it through the trap port, so the interface is a
// request and a result and nothing else: raise `start` with an operation and
// two doubles, wait for `done`, take `result`.  Latency does not matter here
// -- the processor runs about a million bytecode instructions a second, so
// even the sequential divider's tens of cycles are lost in the noise -- and
// nothing is pipelined for that reason.
//
// Add and subtract come from the fused multiply-add as a*1 (+/-) c, which is
// exact.  Multiply is a*b + zero, and the zero carries the product's sign:
// (-1)*0 + (+0) would be +0 under round-to-nearest, where the product alone
// is -0.
`default_nettype none

module fpu_hardfloat (
	input  wire        clk,
	input  wire        resetn,

	input  wire        start,
	input  wire [3:0]  op,
	input  wire [63:0] a,
	input  wire [63:0] b,
	output reg         done,
	output reg  [63:0] result,
	output reg         flag           // comparisons answer here
);
	localparam [3:0] OP_ADD  = 4'd0, OP_SUB  = 4'd1, OP_MUL = 4'd2, OP_DIV = 4'd3,
	                 OP_SQRT = 4'd4, OP_LT   = 4'd5, OP_LE  = 4'd6, OP_EQ  = 4'd7,
	                 OP_NEG  = 4'd8, OP_ABS  = 4'd9,
	                 OP_OF_INT = 4'd10, OP_TO_INT = 4'd11;

	localparam [2:0] RNE = 3'b000;              // round to nearest, ties to even
	// 1.0 recoded: IEEE's 1023 plus the format's own 1025, no fraction
	localparam [64:0] REC_ONE = {1'b0, 12'd2048, 52'd0};

	// Everything below works from registered copies.  Latency does not
	// matter here and long combinational chains do: recoding, the cores and
	// the way back are each given their own cycle, which is what keeps the
	// processor's own clock out of this datapath's shadow.
	reg  [63:0] a_r, b_r;
	reg  [3:0]  op_r;
	wire [64:0] a_rec_c, b_rec_c;
	recode64 rec_a (.in(a_r), .out(a_rec_c));
	recode64 rec_b (.in(b_r), .out(b_rec_c));
	reg  [64:0] a_rec, b_rec;


	// ---- integer conversions ----
	//
	// OCaml's ints are 31 bits here, so every one of them is a double
	// exactly and int_of_float only has to truncate toward zero, which is
	// what OCaml's own cast does.  Neither needs a core.
	wire signed [31:0] int_in = a_r[31:0];
	wire [31:0] mag = int_in[31] ? (~int_in + 32'd1) : int_in;

	reg [4:0] msb;                        // the position of the top set bit
	integer k;
	always @* begin
		msb = 5'd0;
		for (k = 0; k < 32; k = k + 1)
			if (mag[k]) msb = k[4:0];
	end

	wire [52:0] mant_shifted = {21'd0, mag} << (6'd52 - {1'b0, msb});
	wire [63:0] of_int = (mag == 32'd0) ? 64'd0
	                   : {int_in[31], 11'd1023 + {6'd0, msb}, mant_shifted[51:0]};

	// Truncation toward zero: the significand, shifted down by however far
	// the exponent falls short of 52.  Out of range answers zero, which is
	// where OCaml's own undefined behaviour lands on this target.
	wire [10:0] exp_a = a_r[62:52];
	wire signed [11:0] e_unbiased = $signed({1'b0, exp_a}) - 12'sd1023;
	wire [52:0] sig_a = {1'b1, a_r[51:0]};
	wire [5:0]  rshift = (e_unbiased > 12'sd52) ? 6'd0 : 6'd52 - e_unbiased[5:0];
	wire [52:0] truncated = sig_a >> rshift;
	wire in_range = (e_unbiased >= 12'sd0) && (e_unbiased < 12'sd31);
	wire [31:0] to_int_mag = in_range ? truncated[31:0] : 32'd0;
	wire [31:0] to_int = a_r[63] ? (~to_int_mag + 32'd1) : to_int_mag;

	// ---- fused multiply-add: add, subtract and multiply ----
	wire product_sign = a_r[63] ^ b_r[63];
	reg  [1:0]  fma_op;
	reg  [64:0] fma_a, fma_b, fma_c;
	always @* begin
		case (op_r)
			OP_MUL:  begin fma_a = a_rec;   fma_b = b_rec;   fma_c = {product_sign, 64'd0}; fma_op = 2'b00; end
			OP_SUB:  begin fma_a = a_rec;   fma_b = REC_ONE; fma_c = b_rec;                 fma_op = 2'b01; end
			default: begin fma_a = a_rec;   fma_b = REC_ONE; fma_c = b_rec;                 fma_op = 2'b00; end
		endcase
	end

	reg fma_valid;
	wire [64:0] fma_out;
	wire        fma_validout;
	MulAddRecFNPipe_1 fma (
		.clock(clk), .reset(!resetn),
		.io_validin(fma_valid), .io_op(fma_op),
		.io_a(fma_a), .io_b(fma_b), .io_c(fma_c),
		.io_roundingMode(RNE),
		.io_out(fma_out), .io_exceptionFlags(), .io_validout(fma_validout));

	// ---- divide and square root, sequential ----
	reg  div_valid, div_sqrt;
	wire div_ready, div_out_div, div_out_sqrt;
	wire [64:0] div_out;
	DivSqrtRecFN_small_1 divsqrt (
		.clock(clk), .reset(!resetn),
		.io_inReady(div_ready), .io_inValid(div_valid), .io_sqrtOp(div_sqrt),
		.io_a(a_rec), .io_b(b_rec), .io_roundingMode(RNE),
		.io_outValid_div(div_out_div), .io_outValid_sqrt(div_out_sqrt),
		.io_out(div_out), .io_exceptionFlags());

	// ---- comparison ----
	wire cmp_lt, cmp_eq;
	CompareRecFN cmp (.io_a(a_rec), .io_b(b_rec), .io_signaling(1'b0),
	                  .io_lt(cmp_lt), .io_eq(cmp_eq));

	reg  [64:0] res_rec;
	wire [63:0] res_ieee;
	derecode64 back (.in(res_rec), .out(res_ieee));

	localparam [2:0] IDLE = 3'd0, RECODE = 3'd1, ISSUE = 3'd2, WAIT = 3'd3, BACK = 3'd4;
	reg [2:0] state;

	always @(posedge clk) begin
		if (!resetn) begin
			state <= IDLE; done <= 1'b0; result <= 64'd0; flag <= 1'b0;
			fma_valid <= 1'b0; div_valid <= 1'b0; div_sqrt <= 1'b0;
			a_r <= 64'd0; b_r <= 64'd0; op_r <= 4'd0;
			a_rec <= 65'd0; b_rec <= 65'd0; res_rec <= 65'd0;
		end else begin
			done      <= 1'b0;
			fma_valid <= 1'b0;
			case (state)
				IDLE: if (start) begin
					a_r <= a; b_r <= b; op_r <= op;
					state <= RECODE;
				end
				RECODE: begin
					a_rec <= a_rec_c;
					b_rec <= b_rec_c;
					state <= ISSUE;
				end
				ISSUE: case (op_r)
					// These never reach a core: the sign bit, a comparison,
					// or a conversion, each already a registered cycle away
					// from the operands.
					OP_NEG:    begin result <= {~a_r[63], a_r[62:0]}; done <= 1'b1; state <= IDLE; end
					OP_ABS:    begin result <= {1'b0,     a_r[62:0]}; done <= 1'b1; state <= IDLE; end
					OP_OF_INT: begin result <= of_int;                done <= 1'b1; state <= IDLE; end
					OP_TO_INT: begin result <= {32'd0, to_int};       done <= 1'b1; state <= IDLE; end
					OP_LT:     begin flag <= cmp_lt;                  done <= 1'b1; state <= IDLE; end
					OP_LE:     begin flag <= cmp_lt || cmp_eq;        done <= 1'b1; state <= IDLE; end
					OP_EQ:     begin flag <= cmp_eq;                  done <= 1'b1; state <= IDLE; end
					OP_DIV, OP_SQRT: begin
						div_valid <= 1'b1;
						div_sqrt  <= (op_r == OP_SQRT);
						state     <= WAIT;
					end
					default: begin fma_valid <= 1'b1; state <= WAIT; end
				endcase
				WAIT: begin
					if (div_valid && div_ready) div_valid <= 1'b0;
					if (fma_validout || div_out_div || div_out_sqrt) begin
						res_rec <= (op_r == OP_DIV || op_r == OP_SQRT) ? div_out : fma_out;
						state   <= BACK;
					end
				end
				BACK: begin
					result <= res_ieee;
					done   <= 1'b1;
					state  <= IDLE;
				end
				default: state <= IDLE;
			endcase
		end
	end
endmodule
`default_nettype wire
