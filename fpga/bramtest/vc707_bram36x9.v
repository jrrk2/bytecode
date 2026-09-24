// Minimal carrier for the hand-instantiated RAMB36E1 x9 case: enough design
// to build in both flows and compare, with the result on the LEDs.
`default_nettype none
`ifndef SYS_DIV
`define SYS_DIV 20.000
`endif
module vc707_bram36x9 (
	input  wire IO_CLK_P, input wire IO_CLK_N, input wire IO_RST,
	output wire UART_TX, input wire UART_RX,
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

	wire done, ok;
	wire [8:0] badbits;
	bram36x9 dut (.clk(clk), .rst(rst), .done(done), .ok(ok), .badbits(badbits));

	// LED7 done, LED6 ok, LED5..0 the low bad bits; bit 8 is LED4.
	assign LED = {done, ok, 1'b0, badbits[8], badbits[3:0]};
	assign UART_TX = 1'b1;
endmodule
`default_nettype wire
