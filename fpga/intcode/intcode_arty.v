// A minimal INTCODE system for the Digilent Arty A7-35T, to take the core through the open flow (yosys, nextpnr, prjxray): the core, a 32K-word
// store in block RAM that starts holding an assembled program (image.hex, image.vh from tb_intcode with INTCODE_DUMP), and a console on the UART.
// The stream operations are a console only: rdch reads the UART, wrch writes it, input() and output() are streams 1 and 2, findinput and findoutput
// fail and succeed with the console.  LEDs: 0 running, 1 halted, 2 the result was not zero, 3 a character was received.
`default_nettype none
module intcode_arty #(
	parameter WIDTH = 32,
	parameter DIV   = 868                  // 100 MHz / 115200
) (
	input  wire       clk,
	input  wire       uart_rx_in,
	output wire       uart_tx_out,
	output wire [3:0] led
);
`include "image.vh"
	reg [3:0] rcnt = 4'd0;
	wire rst = ~&rcnt;
	always @(posedge clk) if (!&rcnt) rcnt <= rcnt + 4'd1;

	wire [15:0]      m_addr;
	wire [WIDTH-1:0] m_wdata, m_rdata_w;
	wire             m_we, m_re;
	wire             io_req, instr_done, halted;
	wire [5:0]       io_op;
	wire [WIDTH-1:0] io_a, result;
	reg              io_ack;
	reg  [WIDTH-1:0] io_res;

	intcode_core #(.WIDTH(WIDTH), .AW(16)) core (
		.clk(clk), .rst(rst), .init_c(`INIT_C), .init_p(`INIT_P), .init_g(`INIT_G),
		.m_addr(m_addr), .m_wdata(m_wdata), .m_we(m_we), .m_re(m_re), .m_rdata(m_rdata_w),
		.io_req(io_req), .io_op(io_op), .io_a(io_a), .io_ack(io_ack), .io_res(io_res),
		.instr_done(instr_done), .halted(halted), .result(result));

	// the store: 32K words deep, which the flow builds from RAMB36s a bit wide
	reg [WIDTH-1:0] mem [0:32767];
	initial $readmemh("image.hex", mem);
	reg [WIDTH-1:0] rdata;
	always @(posedge clk) begin
		if (m_we) mem[m_addr[14:0]] <= m_wdata;
		rdata <= mem[m_addr[14:0]];
	end
	assign m_rdata_w = rdata;

	// the console
	wire [31:0] u_do;
	reg         u_we = 1'b0, u_re = 1'b0;
	reg  [31:0] u_di = 32'd0;
	wire        u_wait;
	simpleuart #(.DEFAULT_DIV(DIV)) uart (
		.clk(clk), .resetn(~rst), .ser_tx(uart_tx_out), .ser_rx(uart_rx_in),
		.reg_div_we(4'b0), .reg_div_di(32'd0), .reg_div_do(),
		.reg_dat_we(u_we), .reg_dat_re(u_re), .reg_dat_di(u_di), .reg_dat_do(u_do), .reg_dat_wait(u_wait));

	localparam IDLE = 0, GOT = 1, RD = 2, WR = 3, FIN = 4;
	reg [2:0] st = IDLE;
	reg [5:0] op;
	reg       got_char = 1'b0;
	always @(posedge clk) begin
		io_ack <= 1'b0; u_we <= 1'b0; u_re <= 1'b0;
		if (rst) st <= IDLE;
		else case (st)
			IDLE: if (io_req) begin op <= io_op; st <= GOT; end
			GOT: case (op)
				26: st <= RD;                                            // rdch
				27: begin st <= WR; end                                  // wrch
				28: begin io_res <= 1; st <= FIN; end                    // findinput: the console
				29: begin io_res <= 2; st <= FIN; end                    // findoutput: the console
				38: begin io_res <= 1; st <= FIN; end                    // input()
				39: begin io_res <= 2; st <= FIN; end                    // output()
				default: st <= FIN;                                      // selectinput etc.: nothing to do
			endcase
			RD: begin
				u_re <= 1'b1;
				if (u_do != 32'hffffffff && u_re) begin io_res <= {{(WIDTH-8){1'b0}}, u_do[7:0]}; got_char <= 1'b1; u_re <= 1'b0; st <= FIN; end
			end
			WR: if (!u_wait) begin u_we <= 1'b1; u_di <= {24'd0, io_a[7:0]}; st <= FIN; end
			FIN: begin io_ack <= 1'b1; st <= IDLE; end
			default: st <= IDLE;
		endcase
	end

	assign led = {got_char, result != 0, halted, ~halted & ~rst};
endmodule
`default_nettype wire
