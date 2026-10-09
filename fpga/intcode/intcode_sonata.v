// The lowRISC Sonata ONE (Artix-7 xc7a50tcsg324-1) top for intcode_sys: the 25 MHz oscillator, the UART header, the eight user LEDs.
// 25 MHz / 5.6 clocks an instruction is about 4.5 MIPS.
`default_nettype none
module intcode_sonata #(parameter WIDTH = 32) (
	input  wire       mainClk,
	input  wire       uart_rx,
	output wire       uart_tx,
	output wire [7:0] usrLed
);
	intcode_sys #(.WIDTH(WIDTH), .DIV(217)) sys (.clk(mainClk), .uart_rx_in(uart_rx), .uart_tx_out(uart_tx), .led(usrLed));
endmodule
`default_nettype wire
