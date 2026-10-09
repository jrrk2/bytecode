// A minimal INTCODE system: the core, a 32K-word store in block RAM that starts holding an assembled program (image.hex, image.vh from tb_intcode
// with INTCODE_DUMP), and a console on the UART.  intcode_arty.v and intcode_sonata.v are the board tops.
// The stream operations are a console only: rdch reads the UART, wrch writes it, input() and output() are streams 1 and 2.  A program that opens files
// (the BCPL compiler: GET "LIBHDR", and OCODE, INTCODE for output) is served through the console, in order: findinput gives stream 3 and findoutput stream
// 4, both still the UART; the host sends each input file's text where the program will read it, and the byte 0x04 (EOT) is read as end of stream (-1), after
// each such file and at the end of the main input; while stream 4 is selected for output everything written is bracketed by STX (0x02) and ETX (0x03), so the
// host can tell a file's text from the program's messages.  LEDs: 0 running, 1 halted, 2 the result was not zero, 3 a character was received, 4 heartbeat (about 1 Hz at
// 25 MHz), 5 toggles at each stream request, 6 toggles at each character received, 7 toggles at each character sent.
`default_nettype none
module intcode_sys #(
	parameter WIDTH = 32,
	parameter DIV   = 868,                 // clocks per UART bit: 100 MHz / 115200 (simpleuart takes the divider as bit period - 2)
	parameter [23:0] FLASH_AT = 24'hA00000, // where the program is in the software flash: slot 2 of the Sonata (10 MiB)
	parameter SPI_HALF = 2                  // clocks in half a period of the SPI clock
) (
	input  wire       clk,
	input  wire       uart_rx_in,
	output wire       uart_tx_out,
	output wire [7:0] led,
	// the software flash, SPI mode 0, single bit: at reset a program is copied from it into the store if it holds one (see the header below)
	output wire       spi_cs_n,
	output wire       spi_clk,
	output wire       spi_mosi,
	input  wire       spi_miso,
	output wire       spi_wp_n,
	output wire       spi_hold_n
);
	reg [3:0] rcnt = 4'd0;
	wire sys_rst = (rcnt != 4'hf);
	reg  boot_run = 1'b1;                          // the flash copy is under way: the core is held
	wire rst = sys_rst | boot_run;
	always @(posedge clk) if (rcnt != 4'hf) rcnt <= rcnt + 4'd1;

	wire [15:0]      m_addr;
	wire [WIDTH-1:0] m_wdata, m_rdata_w;
	wire             m_we, m_re;
	wire             io_req, instr_done, halted;
	wire [5:0]       io_op;
	wire [WIDTH-1:0] io_a, result;
	reg              io_ack;
	reg  [WIDTH-1:0] io_res;

	intcode_core #(.WIDTH(WIDTH), .AW(16)) core (
		.clk(clk), .rst(rst), .init_c(32'd0), .init_p(32'd0), .init_g(32'd0), .boot_store(1'b1),   // C, P and G come from the store (image.hex words 32765..32767)
		.m_addr(m_addr), .m_wdata(m_wdata), .m_we(m_we), .m_re(m_re), .m_rdata(m_rdata_w),
		.io_req(io_req), .io_op(io_op), .io_a(io_a), .io_ack(io_ack), .io_res(io_res), .io_maddr(maddr_o), .io_mre(mre_o),
		.instr_done(instr_done), .halted(halted), .result(result));

	// the store: 32K words deep, which the flow builds from RAMB36s a bit wide
	reg [WIDTH-1:0] mem [0:32767];
	initial $readmemh("image.hex", mem);
	reg [WIDTH-1:0] rdata;
	reg         ld_we = 1'b0;                      // the flash copier's write, while the core is held
	reg  [14:0] ld_addr = 15'd0;
	reg  [WIDTH-1:0] ld_data = {WIDTH{1'b0}};
	always @(posedge clk) begin
		if (ld_we) mem[ld_addr] <= ld_data;
		else if (m_we) mem[m_addr[14:0]] <= m_wdata;
		rdata <= mem[m_addr[14:0]];
	end
	assign m_rdata_w = rdata;

	// ---- reading a program from the software flash ----
	// At reset, with the core held, the flash is reset (0x66, 0x99), then read from FLASH_AT with READ (0x03): a header of five little-endian words -- the
	// magic 0x494E5443 ("INTC"), N, C, P, G -- and then N words, which become words 0..N-1 of the store; C, P and G go to words 32765..32767, where the core reads
	// them.  Without the magic (a blank flash reads 0xFFFFFFFF, an absent one 0) the store is left as the bitstream built it.
	localparam B_R1 = 0, B_G1 = 1, B_R2 = 2, B_G2 = 3, B_CMD = 4, B_WORD = 5, B_SKIP = 6, B_DONE = 7;
	reg [2:0]  bst = B_R1;
	reg [15:0] gap = 16'd0;
	reg        cs_q = 1'b1, sck_q = 1'b0, mosi_q = 1'b0;
	reg [31:0] txsh = 32'd0, rxsh = 32'd0;
	reg [5:0]  nbits = 6'd0;
	reg [3:0]  ph = 4'd0;
	reg        xfer = 1'b0, xdone = 1'b0;
	reg [3:0]  widx = 4'd0;                         // which header word, then 5 = body
	reg [15:0] nwords = 16'd0, wcnt = 16'd0;
	reg [31:0] hc = 32'd0, hp = 32'd0, hg = 32'd0;
	reg        have = 1'b0;
	wire [31:0] flash_word = {rxsh[7:0], rxsh[15:8], rxsh[23:16], rxsh[31:24]};
	assign spi_cs_n = cs_q; assign spi_clk = sck_q; assign spi_mosi = mosi_q; assign spi_wp_n = 1'b1; assign spi_hold_n = 1'b1;
	// A program loaded from the flash that halts is started afresh from the flash after about 120 ms (at 25 MHz; the UART has finished sending by then): the board
	// behaves like a command-line tool, run again for each job.  The receive FIFO keeps what the host has already sent.
	reg [22:0] hcnt = 23'd0;
	wire warm = have && halted && (hcnt == 23'd3000000);
	always @(posedge clk) begin
		if (!halted) hcnt <= 23'd0; else if (hcnt != 23'h7FFFFF) hcnt <= hcnt + 23'd1;
	end
	always @(posedge clk) begin
		ld_we <= 1'b0; xdone <= 1'b0;
		if (sys_rst || warm) begin
			bst <= B_R1; boot_run <= 1'b1; cs_q <= 1'b1; sck_q <= 1'b0; xfer <= 1'b0; gap <= 16'd0; have <= 1'b0; widx <= 4'd0;
		end else begin
			// the bit engine: nbits bits out of txsh (MSB first) and into rxsh, SPI mode 0
			if (xfer) begin
				ph <= ph + 4'd1;
				if (ph == 4'd0) mosi_q <= txsh[31];
				if (ph == SPI_HALF) begin sck_q <= 1'b1; rxsh <= {rxsh[30:0], spi_miso}; end
				if (ph == 2 * SPI_HALF - 1) begin
					sck_q <= 1'b0; txsh <= {txsh[30:0], 1'b0}; nbits <= nbits - 6'd1; ph <= 4'd0;
					if (nbits == 6'd1) begin xfer <= 1'b0; xdone <= 1'b1; end
				end
			end
			case (bst)
				B_R1: begin cs_q <= 1'b0; if (!xfer && !xdone) begin txsh <= {8'h66, 24'd0}; nbits <= 6'd8; xfer <= 1'b1; ph <= 4'd0; end else if (xdone) begin cs_q <= 1'b1; gap <= 16'd0; bst <= B_G1; end end
				B_G1: begin gap <= gap + 16'd1; if (gap == 16'd16) begin bst <= B_R2; end end
				B_R2: begin cs_q <= 1'b0; if (!xfer && !xdone) begin txsh <= {8'h99, 24'd0}; nbits <= 6'd8; xfer <= 1'b1; ph <= 4'd0; end else if (xdone) begin cs_q <= 1'b1; gap <= 16'd0; bst <= B_G2; end end
				B_G2: begin gap <= gap + 16'd1; if (gap == 16'd5000) bst <= B_CMD; end         // the flash needs about 30 us after a reset
				B_CMD: begin cs_q <= 1'b0;
					if (!xfer && !xdone) begin txsh <= {8'h03, FLASH_AT}; nbits <= 6'd32; xfer <= 1'b1; ph <= 4'd0; end
					else if (xdone) begin widx <= 4'd0; bst <= B_WORD; end
				end
				B_WORD: begin
					if (!xfer && !xdone) begin txsh <= 32'd0; nbits <= 6'd32; xfer <= 1'b1; ph <= 4'd0; end
					else if (xdone) begin
						case (widx)
							4'd0: if (flash_word != 32'h494E5443) bst <= B_DONE; else widx <= 4'd1;
							4'd1: begin nwords <= flash_word[15:0]; if (flash_word > 32'd32765) bst <= B_DONE; else widx <= 4'd2; end
							4'd2: begin hc <= flash_word; widx <= 4'd3; end
							4'd3: begin hp <= flash_word; widx <= 4'd4; end
							4'd4: begin hg <= flash_word; widx <= 4'd5; wcnt <= 16'd0; have <= 1'b1; if (nwords == 16'd0) bst <= B_SKIP; end
							default: begin
								ld_we <= 1'b1; ld_addr <= wcnt[14:0]; ld_data <= flash_word[WIDTH-1:0];
								wcnt <= wcnt + 16'd1;
								if (wcnt + 16'd1 == nwords) bst <= B_SKIP;
							end
						endcase
					end
				end
				B_SKIP: begin                                                                   // the start registers, into the top of the store
					cs_q <= 1'b1;
					gap <= gap + 16'd1;
					if (gap[1:0] == 2'd0) begin ld_we <= 1'b1; ld_addr <= 15'd32765; ld_data <= hc[WIDTH-1:0]; end
					if (gap[1:0] == 2'd1) begin ld_we <= 1'b1; ld_addr <= 15'd32766; ld_data <= hp[WIDTH-1:0]; end
					if (gap[1:0] == 2'd2) begin ld_we <= 1'b1; ld_addr <= 15'd32767; ld_data <= hg[WIDTH-1:0]; end
					if (gap[2:0] == 3'd4) bst <= B_DONE;
				end
				B_DONE: begin cs_q <= 1'b1; boot_run <= 1'b0; end
				default: bst <= B_R1;
			endcase
		end
	end

	// the console
	wire [31:0] u_do;
	wire        u_we, u_re;                    // u_we is held for as long as the state asks (simpleuart holds the bus, wait, while it is busy)
	// A receive FIFO between the UART and the program: simpleuart keeps one received byte, and a program that is busy for longer than a character takes
	// (the BCPL compiler, parsing) would lose characters.  Every byte is taken from the UART at once and the program reads them out of the FIFO.
	reg  [7:0]  rxf [0:127];
	reg  [6:0]  rxw = 7'd0, rxr = 7'd0;
	wire        rxf_empty = (rxw == rxr);
	wire        rxf_full  = (rxw + 7'd1 == rxr);
	wire        u_valid;
	wire [31:0] u_di = {24'd0, (st == ENQ) ? 8'h05 : wmark ? wbyte : io_a[7:0]};
	wire        u_wait;
	simpleuart #(.DEFAULT_DIV(DIV - 2)) uart (
		.clk(clk), .resetn(~sys_rst), .ser_tx(uart_tx_out), .ser_rx(uart_rx_in),
		.reg_div_we(4'b0), .reg_div_di(32'd0), .reg_div_do(),
		.reg_dat_we(u_we), .reg_dat_re(u_re), .reg_dat_di(u_di), .reg_dat_do(u_do), .reg_dat_wait(u_wait));

	localparam IDLE = 0, GOT = 1, RD = 2, WR = 3, FIN = 4, NM0 = 5, NM1 = 6, NM2 = 7, ENQ = 8;
	reg [3:0] st = IDLE;
	reg [15:0] maddr = 16'd0;
	reg [WIDTH-1:0] nm_w0 = {WIDTH{1'b0}};
	wire [15:0] maddr_o = (st == NM1) ? maddr + 16'd1 : maddr;
	wire        mre_o = (st == NM0) || (st == NM1);
	assign u_valid = (u_do != 32'hffffffff);
	assign u_we = (st == WR) || (st == ENQ);
	assign u_re = u_valid && !rxf_full;                                     // take a received byte whenever there is one and room for it
	always @(posedge clk) begin
		if (sys_rst) begin rxw <= 7'd0; rxr <= 7'd0; end
		else begin
			if (u_re) begin rxf[rxw] <= u_do[7:0]; rxw <= rxw + 7'd1; end
			if (st == RD && !rxf_empty) rxr <= rxr + 7'd1;
		end
	end
	// Flow control for the host: it starts with credit for 96 bytes and gets 32 more for each ENQ (0x05, which the host strips from the output wherever it comes)
	// the board sends after the program has taken 32 bytes out of the FIFO; so the host never sends more than the FIFO can hold.
	reg [4:0] pops = 5'd0;
	reg [3:0] enq_n = 4'd0;
	always @(posedge clk) begin
		if (sys_rst || rst) begin pops <= 5'd0; enq_n <= 4'd0; end
		else begin
			if (st == RD && !rxf_empty) pops <= pops + 5'd1;
			enq_n <= enq_n + ((st == RD && !rxf_empty && pops == 5'd31) ? 4'd1 : 4'd0) - ((st == ENQ && !u_wait) ? 4'd1 : 4'd0);
		end
	end
	reg [5:0] op;
	reg       got_char = 1'b0;
	reg       out_file = 1'b0, wmark = 1'b0;     // stream 4 is selected for output; the byte being written is a marker
	reg [7:0] wbyte = 8'd0;
	always @(posedge clk) begin
		io_ack <= 1'b0;
		if (rst) begin st <= IDLE; out_file <= 1'b0; wmark <= 1'b0; end
		else case (st)
			IDLE: if (io_req) begin op <= io_op; st <= GOT; end else if (enq_n != 4'd0) st <= ENQ;
			GOT: case (op)
				26: st <= RD;                                            // rdch
				27: begin wmark <= 1'b0; st <= WR; end                   // wrch
				28: begin maddr <= io_a[15:0]; st <= NM0; end            // findinput: look at the name; every file is stream 3, the console (the host sends it in turn), except OPTIONS
				29: begin io_res <= 4; st <= FIN; end                    // findoutput: stream 4, the console between STX and ETX
				25: if (io_a == 4 && !out_file) begin wmark <= 1'b1; wbyte <= 8'h02; out_file <= 1'b1; st <= WR; end        // selectoutput
				    else if (io_a != 4 && out_file) begin wmark <= 1'b1; wbyte <= 8'h03; out_file <= 1'b0; st <= WR; end
				    else st <= FIN;
				34: if (out_file) begin wmark <= 1'b1; wbyte <= 8'h03; out_file <= 1'b0; st <= WR; end else st <= FIN;     // endwrite
				38: begin io_res <= 1; st <= FIN; end                    // input()
				39: begin io_res <= 2; st <= FIN; end                    // output()
				default: st <= FIN;                                      // selectinput etc.: nothing to do
			endcase
			RD: if (!rxf_empty) begin io_res <= (rxf[rxr] == 8'h04) ? {WIDTH{1'b1}} : {{(WIDTH-8){1'b0}}, rxf[rxr]}; got_char <= 1'b1; st <= FIN; end   // the oldest byte
			ENQ: if (!u_wait) st <= IDLE;
			WR: if (!u_wait) st <= FIN;                                                                                    // this write was accepted
			NM0: st <= NM1;
			NM1: begin nm_w0 <= m_rdata_w; st <= NM2; end
			NM2: begin
				// the string "OPTIONS" as BCPL packs it: length 7 in the first byte, then the characters, four to a word, the first in the high byte.
				// The compiler asks for it first and reads an options line if it exists; here it does not, as under icint.
				io_res <= (WIDTH == 32 && nm_w0 == 32'h074F5054 && m_rdata_w == 32'h494F4E53) ? {WIDTH{1'b0}} : 3;
				st <= FIN;
			end
			FIN: begin io_ack <= 1'b1; st <= IDLE; end
			default: st <= IDLE;
		endcase
	end

`ifdef TRACE_RD
	always @(posedge clk) if (st == RD && !rxf_empty) $write("%c%c", 8'h01, rxf[rxr]);
`endif
	reg [24:0] hb = 25'd0;
	reg        t_io = 1'b0, t_rx = 1'b0, t_tx = 1'b0;
	always @(posedge clk) begin
		hb <= hb + 25'd1;
		if (io_req) t_io <= ~t_io;
		if (u_re) t_rx <= ~t_rx;
		if (st == WR && !u_wait) t_tx <= ~t_tx;
	end
	assign led = {t_tx, t_rx, t_io, hb[24], got_char, result != 0, halted, ~halted & ~rst};
endmodule
`default_nettype wire
