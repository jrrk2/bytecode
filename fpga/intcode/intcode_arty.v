// The Digilent Arty A7-35T top for intcode_sys: 100 MHz clock, the USB UART, four LEDs.
`default_nettype none
module intcode_arty #(parameter WIDTH = 32) (
	input  wire       clk,
	input  wire       uart_rx_in,
	output wire       uart_tx_out,
	output wire [3:0] led
);
	wire [7:0] l;
	intcode_sys #(.WIDTH(WIDTH), .DIV(868)) sys (.clk(clk), .uart_rx_in(uart_rx_in), .uart_tx_out(uart_tx_out), .led(l));
	assign led = l[3:0];
endmodule
`default_nettype wire
