module roundtrip (input wire [63:0] in, output wire [63:0] out, output wire [64:0] rec);
	recode64 r (.in(in), .out(rec));
	derecode64 d (.in(rec), .out(out));
endmodule
