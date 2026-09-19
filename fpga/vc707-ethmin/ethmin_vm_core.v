// ethmin_vm_core -- xc7-bitstream-tools' ethmin_core with the OCaml bytecode
// VM in place of picosoc.  Same ports, same Ethernet DMA (eth_stream_dma) and
// register semantics; the program (io/ethmin.ml) reaches them through the
// VM's trap port as one I/O space (vm_io_read / vm_io_write), exactly as
// ethmodel.c simulates it:
//
//   0x0000..0x07FF  RX window, a byte per address   packet RAM words 0..511
//   0x0800..0x0FFF  TX window                       packet RAM words 512..1023
//   0x1000  r  {rx_trunc, tx_busy, rx_valid}
//   0x1001  r  pcspma_status
//   0x1002  r  received length       w  release the RX window
//   0x1003  w  length: send the TX window
//   0x1004  rw LEDs
//   0x1005  w  UART byte (simpleuart, 115200 8N1)
//
// The packet RAM is a true dual-port BRAM: port B belongs to the DMA on
// eth_clk, port A to the VM on clk_sys; eth_stream_dma's ownership handshake
// keeps the two off the same window, as it did for picosoc.
`default_nettype none
module ethmin_vm_core #(
	parameter [13:0] RX_WORD_BASE = 14'd0,
	parameter [13:0] TX_WORD_BASE = 14'd512,
	parameter integer WINDOW_WORDS = 512,
	parameter integer CLK_HZ = 25_000_000,
	parameter integer BAUD = 115_200
) (
	input  wire        clk_sys,
	input  wire        resetn,
	input  wire        eth_clk,
	input  wire        eth_rst,

	input  wire [7:0]  rx_axis_tdata,
	input  wire        rx_axis_tvalid,
	input  wire        rx_axis_tlast,
	input  wire        rx_axis_tuser,
	output wire [7:0]  tx_axis_tdata,
	output wire        tx_axis_tvalid,
	output wire        tx_axis_tlast,
	input  wire        tx_axis_tready,
	output wire        tx_axis_tuser,

	input  wire [15:0] pcspma_status,
	output wire [7:0]  LED,
	input  wire        UART_RX,
	output wire        UART_TX
);
`include "program.vh"  // PROGRAM_HEX, PROGRAM_WORDS, HEAP_WORDS (tools/progimage.sh)

	// ─── the DMA: MAC stream <-> packet RAM port B ───────────────────────
	wire        mem_b_en, mem_b_we;
	wire [13:0] mem_b_addr;
	wire [31:0] mem_b_wdata;
	reg  [31:0] mem_b_rdata;
	wire        rx_valid, rx_trunc, tx_busy;
	wire [10:0] rx_len;
	reg  [10:0] tx_len;
	reg         tx_start, rx_ack;

	eth_stream_dma #(
		.RX_WORD_BASE(RX_WORD_BASE), .TX_WORD_BASE(TX_WORD_BASE),
		.WINDOW_WORDS(WINDOW_WORDS)
	) dma (
		.eth_clk(eth_clk), .eth_rst(eth_rst),
		.rx_axis_tdata(rx_axis_tdata), .rx_axis_tvalid(rx_axis_tvalid),
		.rx_axis_tlast(rx_axis_tlast), .rx_axis_tuser(rx_axis_tuser),
		.tx_axis_tdata(tx_axis_tdata), .tx_axis_tvalid(tx_axis_tvalid),
		.tx_axis_tlast(tx_axis_tlast), .tx_axis_tready(tx_axis_tready),
		.tx_axis_tuser(tx_axis_tuser),
		.mem_en(mem_b_en), .mem_we(mem_b_we), .mem_addr(mem_b_addr),
		.mem_wdata(mem_b_wdata), .mem_rdata(mem_b_rdata),
		.cpu_clk(clk_sys), .cpu_rst(~resetn),
		.rx_valid(rx_valid), .rx_len(rx_len), .rx_trunc(rx_trunc),
		.rx_ack(rx_ack), .tx_len(tx_len), .tx_start(tx_start),
		.tx_busy(tx_busy));

	// ─── packet RAM: 2 KiB RX + 2 KiB TX, little-endian bytes ───────────
	reg  [31:0] pkt [0:1023];
	reg         pa_en;
	reg  [3:0]  pa_we;
	reg  [9:0]  pa_addr;
	reg  [31:0] pa_wdata;
	reg  [31:0] pa_rdata;
	integer lane;

	// Both ports are written per byte lane (port B always all four) so the
	// synthesiser sees one byte-write template and infers a single BRAM.
	integer lane_b;
	always @(posedge eth_clk)
		if (mem_b_en) begin
			for (lane_b = 0; lane_b < 4; lane_b = lane_b + 1)
				if (mem_b_we) pkt[mem_b_addr[9:0]][8*lane_b +: 8] <= mem_b_wdata[8*lane_b +: 8];
			mem_b_rdata <= pkt[mem_b_addr[9:0]];
		end

	always @(posedge clk_sys)
		if (pa_en) begin
			for (lane = 0; lane < 4; lane = lane + 1)
				if (pa_we[lane]) pkt[pa_addr][8*lane +: 8] <= pa_wdata[8*lane +: 8];
			pa_rdata <= pkt[pa_addr];
		end

	// ─── the VM ──────────────────────────────────────────────────────────
	wire [23:0] pc;
	wire        trap_valid;
	wire [7:0]  trap_prim;
	wire [31:0] trap_arg0, trap_arg1;
	reg         trap_ready;
	reg  [31:0] trap_result;

	// Code ROM: asynchronous, as the VM samples code_rdata in the cycle it
	// presents pc.
	reg  [31:0] code_rom [0:`PROGRAM_WORDS-1];
	initial $readmemh(`PROGRAM_HEX, code_rom);
	wire [31:0] code_rdata = (pc < `PROGRAM_WORDS) ? code_rom[pc] : 32'hDEADBEEF;

	ocaml4142_vm_rtl #(
		.STACK_AW       (13),
		.HEAP_AW        (13),
		.HEAP_INIT      ("heap.hex"),
		.GLOBALS_INIT   ("globals.hex"),
		.HEAP_INIT_WORDS(`HEAP_WORDS)
	) vm (
		.clk(clk_sys), .reset(~resetn),
		.pc(pc), .code_rdata(code_rdata),
		.trap_valid(trap_valid), .trap_prim(trap_prim),
		.trap_arg0(trap_arg0), .trap_arg1(trap_arg1),
		.trap_ready(trap_ready), .trap_result(trap_result),
		.accu(), .sp(), .state_out(), .imm(), .nvars(), .offset(),
		.alloc_wosize(), .alloc_base(), .alloc_tag(), .closure_codeptr(),
		.closure_nvars(), .closure_i(), .opcode_out(), .tos(), .halted(),
		.putc_valid(), .putc_char());

	// ─── UART ────────────────────────────────────────────────────────────
	reg        uart_we;
	reg  [7:0] uart_byte;
	wire       uart_wait;
	simpleuart #(.DEFAULT_DIV(CLK_HZ / BAUD)) uart (
		.clk(clk_sys), .resetn(resetn),
		.ser_tx(UART_TX), .ser_rx(UART_RX),
		.reg_div_we(4'b0000), .reg_div_di(32'd0), .reg_div_do(),
		.reg_dat_we(uart_we), .reg_dat_re(1'b0),
		.reg_dat_di({24'd0, uart_byte}), .reg_dat_do(),
		.reg_dat_wait(uart_wait));

	// ─── the I/O space, answering the VM's trap port ─────────────────────
	// One trap_ready per request; a request is not acted on again until
	// trap_valid has dropped (the VM drops it on seeing trap_ready).
	localparam [7:0] TRAP_IO_READ = 8'h01, TRAP_IO_WRITE = 8'h02;
	localparam [1:0] IO_IDLE = 2'd0, IO_PKT_READ = 2'd1, IO_UART = 2'd2, IO_DONE = 2'd3;
	reg [1:0] io_state;
	reg [1:0] io_lane;
	reg [7:0] leds;
	assign LED = leds;

	wire io_read  = trap_prim == TRAP_IO_READ;
	wire io_write = trap_prim == TRAP_IO_WRITE;
	wire io_new   = trap_valid && (io_read || io_write) && io_state == IO_IDLE;
	wire [31:0] io_addr = trap_arg0;
	wire io_is_packet = io_addr < 32'h1000;

	always @(*) begin
		pa_en    = io_new && io_is_packet;
		pa_we    = (io_new && io_is_packet && io_write) ? (4'b0001 << io_addr[1:0]) : 4'b0000;
		pa_addr  = io_addr[11:2];
		pa_wdata = {4{trap_arg1[7:0]}};
	end

	always @(posedge clk_sys) begin
		trap_ready <= 1'b0;
		rx_ack     <= 1'b0;
		tx_start   <= 1'b0;
		if (!resetn) begin
			io_state <= IO_IDLE;
			leds     <= 8'd0;
			tx_len   <= 11'd0;
			uart_we  <= 1'b0;
		end else case (io_state)
			IO_IDLE: if (io_new) begin
				io_lane <= io_addr[1:0];
				if (io_is_packet) begin
					if (io_read) io_state <= IO_PKT_READ;      // BRAM data next cycle
					else begin trap_ready <= 1'b1; io_state <= IO_DONE; end
				end else if (io_write && io_addr == 32'h1005) begin
					uart_byte <= trap_arg1[7:0];
					uart_we   <= 1'b1;
					io_state  <= IO_UART;
				end else begin
					case (io_addr)
						32'h1000: trap_result <= {29'd0, rx_trunc, tx_busy, rx_valid};
						32'h1001: trap_result <= {16'd0, pcspma_status};
						32'h1002: trap_result <= {21'd0, rx_len};
						32'h1004: trap_result <= {24'd0, leds};
						default:  trap_result <= 32'd0;
					endcase
					if (io_write) case (io_addr)
						32'h1002: rx_ack <= 1'b1;                     // release the RX window
						32'h1003: begin tx_len <= trap_arg1[10:0]; tx_start <= 1'b1; end
						32'h1004: leds <= trap_arg1[7:0];
						default: ;
					endcase
					trap_ready <= 1'b1;
					io_state   <= IO_DONE;
				end
			end
			IO_PKT_READ: begin
				trap_result <= {24'd0, pa_rdata[8*io_lane +: 8]};
				trap_ready  <= 1'b1;
				io_state    <= IO_DONE;
			end
			IO_UART: if (!uart_wait) begin                     // simpleuart took the byte
				uart_we    <= 1'b0;
				trap_ready <= 1'b1;
				io_state   <= IO_DONE;
			end
			IO_DONE: if (!trap_valid) io_state <= IO_IDLE;
		endcase
	end
endmodule
`default_nettype wire
