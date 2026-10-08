// behavioural stand-ins for the Xilinx primitives the SD host uses, for the Verilator core simulations
module BUFG (input wire I, output wire O); assign O = I; endmodule
module IOBUF #(parameter IOSTANDARD = "", parameter SLEW = "") (inout wire IO, input wire I, output wire O, input wire T);
	assign IO = T ? 1'bz : I;
	assign O = IO;
endmodule
module OBUFT #(parameter IOSTANDARD = "", parameter SLEW = "") (output wire O, input wire I, input wire T);
	assign O = T ? 1'bz : I;
endmodule
