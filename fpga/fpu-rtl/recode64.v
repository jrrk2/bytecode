// IEEE-754 binary64 <-> Berkeley HardFloat's recoded format.
//
// HardFloat's cores speak a 65-bit number: sign, a 12-bit exponent, and 52
// significand bits with the leading one implied.  The exponent's top three
// bits classify: 000 is zero, 111 is infinity (significand zero) or NaN
// (significand non-zero), anything between is finite.  Subnormal inputs are
// normalised on the way in, which is why the exponent needs a bit more range
// than IEEE's, and it carries 1024 on top of IEEE's own bias:
//
//     finite normal      exp = E + 1025            E is IEEE's 1..2046
//     finite subnormal   exp = 1025 - normDist     normDist leading zeros
//     zero               exp = 000_xxxxxxxxx
//     infinity           exp = 110_xxxxxxxxx
//     NaN                exp = 111_xxxxxxxxx
//
// These two modules are the only part of this FPU that is not HardFloat's
// own, so the test bench proves them by round trip and then proves them in
// anger, against the host's doubles, through every operation.
`default_nettype none

module recode64 (
	input  wire [63:0] in,
	output wire [64:0] out
);
	wire        sign     = in[63];
	wire [10:0] exp_in   = in[62:52];
	wire [51:0] fract_in = in[51:0];

	wire is_zero_exp   = (exp_in == 11'd0);
	wire is_zero_fract = (fract_in == 52'd0);
	wire is_zero       = is_zero_exp && is_zero_fract;
	wire is_special    = (exp_in == 11'h7ff);
	wire is_subnormal  = is_zero_exp && !is_zero_fract;

	// Leading zeros of the fraction: how far a subnormal shifts left to put
	// its leading one where the implied one belongs.  The loop runs upward so
	// that the last assignment is the most significant bit that is set.
	reg [5:0] lz;
	integer i;
	always @* begin
		lz = 6'd52;
		for (i = 0; i < 52; i = i + 1)
			if (fract_in[i]) lz = 6'd51 - i[5:0];
	end

	// Shifting by lz+1 drops the leading one, which the format implies.
	wire [51:0] subnorm_fract = (fract_in << lz) << 1;

	wire [11:0] exp_normal    = {1'b0, exp_in} + 12'd1025;
	wire [11:0] exp_subnormal = 12'd1025 - {6'd0, lz};

	wire is_inf_in = is_special && is_zero_fract;
	wire [11:0] exp_out = is_zero       ? 12'd0
	                    : is_special    ? (is_inf_in ? {3'b110, 9'd0} : {3'b111, 9'd0})
	                    : is_subnormal  ? exp_subnormal
	                                    : exp_normal;

	wire [51:0] fract_out = is_zero      ? 52'd0
	                      : is_special   ? (is_zero_fract ? 52'd0 : {1'b1, fract_in[50:0]})
	                      : is_subnormal ? subnorm_fract
	                                     : fract_in;

	assign out = {sign, exp_out, fract_out};
endmodule

module derecode64 (
	input  wire [64:0] in,
	output wire [63:0] out
);
	wire        sign   = in[64];
	wire [11:0] exp_in = in[63:52];
	wire [51:0] fract  = in[51:0];

	// The top two bits say special; the third tells infinity from NaN.
	wire is_zero    = (exp_in[11:9] == 3'b000);
	wire is_special = (exp_in[11:10] == 2'b11);
	wire is_nan     = is_special && exp_in[9];
	wire is_inf     = is_special && !exp_in[9];

	// IEEE's own exponent field, which is what is left after the recoded
	// format's extra 1024.  At or below zero the number has no place as a
	// normal one, and comes back as a subnormal with its leading one shifted
	// into the fraction.
	wire signed [12:0] e_ieee = $signed({1'b0, exp_in}) - 13'sd1025;
	wire is_subnormal = !is_special && !is_zero && (e_ieee < 13'sd1);

	wire [6:0]  shift = 7'd1 - e_ieee[6:0];
	wire [52:0] with_implied = {1'b1, fract};
	wire [52:0] shifted = (shift >= 7'd53) ? 53'd0 : (with_implied >> shift[5:0]);

	wire [10:0] exp_out = (is_zero || is_subnormal) ? 11'd0
	                    : is_special                ? 11'h7ff
	                                                : e_ieee[10:0];

	wire [51:0] fract_out = is_zero      ? 52'd0
	                      : is_special   ? (is_nan ? {1'b1, fract[50:0]} : 52'd0)
	                      : is_subnormal ? shifted[51:0]
	                                     : fract;

	assign out = {sign, exp_out, fract_out};
endmodule
`default_nettype wire
