// Simulation stand-ins: the MMCM passes its input clock straight through.
module IBUFDS (input I, input IB, output O); assign O = I; endmodule
module BUFG (input I, output O); assign O = I; endmodule
module MMCME2_ADV #(parameter BANDWIDTH = "", parameter real CLKFBOUT_MULT_F = 1,
    parameter real CLKIN1_PERIOD = 1, parameter real CLKOUT0_DIVIDE_F = 1,
    parameter real CLKOUT0_PHASE = 0, parameter DIVCLK_DIVIDE = 1, parameter real REF_JITTER1 = 0)
  (input CLKFBIN, input CLKIN1, input PWRDWN, input RST,
   output CLKFBOUT, output CLKOUT0, output reg LOCKED = 1'b0);
  assign CLKOUT0 = CLKIN1;
  assign CLKFBOUT = CLKIN1;
  reg [3:0] n = 0;
  always @(posedge CLKIN1) if (RST) begin n <= 0; LOCKED <= 0; end
                           else if (n != 15) n <= n + 1; else LOCKED <= 1;
endmodule
