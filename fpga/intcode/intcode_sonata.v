// The lowRISC Sonata ONE (Artix-7 xc7a50tcsg324-1) top for intcode_sys: the 25 MHz oscillator, the UART header, the eight user LEDs.
// 25 MHz / 5.6 clocks an instruction is about 4.5 MIPS.
`default_nettype none
module intcode_sonata #(parameter WIDTH = 32) (
	input  wire       mainClk,
	input  wire       uart_rx,
	output wire       uart_tx,
	output wire [7:0] usrLed,
	output wire       flash_cs_n,
	output wire       flash_clk,
	output wire       flash_d0,        // COPI / IO0
	input  wire       flash_d1,        // CIPO / IO1
	output wire       flash_d2,        // WP_N / IO2, held high for single-bit reads
	output wire       flash_d3         // HOLD_N / IO3, held high
);
	intcode_sys #(.WIDTH(WIDTH), .DIV(217)) sys (.clk(mainClk), .uart_rx_in(uart_rx), .uart_tx_out(uart_tx), .led(usrLed),
		.spi_cs_n(flash_cs_n), .spi_clk(flash_clk), .spi_mosi(flash_d0), .spi_miso(flash_d1), .spi_wp_n(flash_d2), .spi_hold_n(flash_d3));
endmodule
`default_nettype wire
