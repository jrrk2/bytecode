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
	parameter [23:0] FS_AT = 24'hE00000,    // the read-only file system (intcode_fs.py): 4 MiB into slot 2 of the Sonata, after the program (a 24-bit READ reaches 16 MiB)
	parameter FS_WRITE = 1,                 // findoutput creates files in the flash file system (append-only); 0: the console between STX and ETX, as before
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
	localparam B_R1 = 0, B_G1 = 1, B_R2 = 2, B_G2 = 3, B_CMD = 4, B_WORD = 5, B_SKIP = 6, B_DONE = 7, B_F = 8;
	reg [3:0]  bst = B_R1;
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
	reg        w_open = 1'b0;                      // a file is open for writing in the flash file system
	// micro-operations for the file system, asked for by the I/O state machine below with a toggle (f_req_t != f_ack_t) once the boot copy is done:
	// 0 start a READ (0x03) at f_addr, 1 read a 32-bit word into f_data (little-endian), 2 read a byte, 3 end (chip select high),
	// 4 start the command f_cmd with the address f_addr (page program, sector erase), 5 send the byte f_tx, 6 start the command f_cmd alone (write enable, read status).
	reg        f_req_t = 1'b0, f_ack_t = 1'b0, fbusy = 1'b0;
	reg [2:0]  f_op = 3'd0;
	reg [23:0] f_addr = 24'd0;
	reg [7:0]  f_cmd = 8'd0, f_tx = 8'd0;
	reg [31:0] f_data = 32'd0;
	wire [31:0] flash_word = {rxsh[7:0], rxsh[15:8], rxsh[23:16], rxsh[31:24]};
	assign spi_cs_n = cs_q; assign spi_clk = sck_q; assign spi_mosi = mosi_q; assign spi_wp_n = 1'b1; assign spi_hold_n = 1'b1;
	// A program loaded from the flash that halts is started afresh from the flash after about 120 ms (at 25 MHz; the UART has finished sending by then): the board
	// behaves like a command-line tool, run again for each job.  The receive FIFO keeps what the host has already sent.
	reg [22:0] hcnt = 23'd0;
	wire warm = have && halted && (hcnt == 23'd3000000) && !w_open;
	always @(posedge clk) begin
		if (!halted) hcnt <= 23'd0; else if (hcnt != 23'h7FFFFF) hcnt <= hcnt + 23'd1;
	end
	always @(posedge clk) begin
		ld_we <= 1'b0; xdone <= 1'b0;
		if (sys_rst || warm) begin
			bst <= B_R1; boot_run <= 1'b1; cs_q <= 1'b1; sck_q <= 1'b0; xfer <= 1'b0; gap <= 16'd0; have <= 1'b0; widx <= 4'd0; f_ack_t <= 1'b0; fbusy <= 1'b0;
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
				B_DONE: begin
					boot_run <= 1'b0;
					if (!boot_run && f_req_t != f_ack_t) bst <= B_F; else if (boot_run) cs_q <= 1'b1;
				end
				B_F: begin
					if (!fbusy) begin
						fbusy <= 1'b1;
						case (f_op)
							3'd0: begin cs_q <= 1'b0; txsh <= {8'h03, f_addr}; nbits <= 6'd32; xfer <= 1'b1; ph <= 4'd0; end
							3'd1: begin txsh <= 32'd0; nbits <= 6'd32; xfer <= 1'b1; ph <= 4'd0; end
							3'd2: begin txsh <= 32'd0; nbits <= 6'd8; xfer <= 1'b1; ph <= 4'd0; end
							3'd4: begin cs_q <= 1'b0; txsh <= {f_cmd, f_addr}; nbits <= 6'd32; xfer <= 1'b1; ph <= 4'd0; end
							3'd5: begin txsh <= {f_tx, 24'd0}; nbits <= 6'd8; xfer <= 1'b1; ph <= 4'd0; end
							3'd6: begin cs_q <= 1'b0; txsh <= {f_cmd, 24'd0}; nbits <= 6'd8; xfer <= 1'b1; ph <= 4'd0; end
							default: begin cs_q <= 1'b1; f_ack_t <= f_req_t; fbusy <= 1'b0; bst <= B_DONE; end
						endcase
					end else if (xdone) begin
						f_data <= (f_op == 3'd2) ? {24'd0, rxsh[7:0]} : flash_word;
						f_ack_t <= f_req_t; fbusy <= 1'b0; bst <= B_DONE;
					end
				end
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

	localparam IDLE = 0, GOT = 1, RD = 2, WR = 3, FIN = 4, NM0 = 5, NM1 = 6, NM2 = 7, ENQ = 8, FW = 9, FE_W = 10, FE_N0 = 11, FE_N1 = 12, FE_R = 13,
	           FE_C = 14, FE_O1 = 15, FE_O2 = 16, FE_L = 17, FE_OPEN = 18, FE_NF = 19, FR0 = 20, FR1 = 21, FR2 = 22, FE_NX = 23,
	           WO0 = 24, WO2 = 25, WO3 = 26, WO4 = 27, WO5 = 28, WO6 = 29, WO7 = 30,
	           PB0 = 31, PB1 = 32, PB2 = 33, SW0 = 34, SW1 = 35, SP0 = 36, SP1 = 37, SP2 = 38, SP3 = 39, SE0 = 40, SE1 = 41, SE2 = 42, SE3 = 43,
	           SG0 = 44, SG1 = 45, SG2 = 46, SG3 = 47, SG4 = 48, SL0 = 49, SL1 = 50, SL2 = 51, SL3 = 52, SL4 = 53, CL0 = 54, CL1 = 55, CL2 = 56, CL3 = 57;
	reg [5:0] st = IDLE;
	// ---- the flash file system (intcode_fs.py).  From FS_AT on, the flash holds a chain of records: a header of 32 bytes (the name as BCPL packs a string, six
	// words; the length of the data; a word kept for flags) and the data, padded to 4 bytes; the next record follows.  A blank header (all ones) ends the chain, and so
	// does a record whose length is still all ones (not yet closed).  A later record hides an earlier one of the same name.  Files are read three at a time (GET
	// nests), as streams 5, 6 and 7.  Flash can be programmed without erasing as long as bits only go from 1 to 0, so a file is appended page by page, and a sector is
	// erased only when the chain first reaches it; the length is written last, when the file is closed (endwrite, or the program halting).  One file is written at a time, as stream 8.
	reg [23:0] fl_base [0:2];
	reg [23:0] fl_pos  [0:2];
	reg [23:0] fl_len  [0:2];
	reg [2:0]  fl_open = 3'd0;
	reg [1:0]  fsel = 2'd0;                       // the selected input stream: 0 the console, else 1 + the file slot
	reg [1:0]  stdin_fs = 2'd0;                   // the file STDIN, if there is one, is the program's standard input: 1 + its slot
	reg        stdin_chk = 1'b0, stdin_scan = 1'b0, kname = 1'b0, isw = 1'b0, found = 1'b0, wsel = 1'b0;
	reg [5:0]  fret = 6'd0, rs0 = 6'd0, rs1 = 6'd0, pr = 6'd0, cl_ret = 6'd0;
	reg [2:0]  ei = 3'd0;                         // the name word being compared
	reg [11:0] ecount = 12'd0;                    // records seen
	reg [2:0]  nmw = 3'd0;                        // words in the name being looked up
	reg [7:0]  nlen = 8'd0;
	reg        match = 1'b0;
	reg [WIDTH-1:0] nm_cur = {WIDTH{1'b0}};
	reg [23:0] cur = 24'd0, fs_end = 24'd0, f_dat = 24'd0, f_ln = 24'd0, e_len = 24'd0;
	reg        e_open = 1'b0, inhdr = 1'b0;
	// writing
	reg [7:0]  pbuf [0:255];
	reg [23:0] wp = 24'd0, hdr = 24'd0, ea = 24'd0, pa = 24'd0;
	reg [7:0]  pstart = 8'd0, ps = 8'd0, pe = 8'd0, pi = 8'd0, pbyte = 8'd0;
	reg [1:0]  bc = 2'd0;
	reg [3:0]  fc = 4'd0;
	reg [31:0] wword = 32'd0;
	wire [1:0] fslot = !fl_open[0] ? 2'd0 : !fl_open[1] ? 2'd1 : 2'd2;
	wire       fany  = !(&fl_open);
	wire [2:0] sidx  = io_a[2:0] - 3'd5;
	wire [1:0] fcur  = fsel - 2'd1;
	// bytes of the name word that count: the length byte and characters, 4 a word
	wire [31:0] nm0_32 = nm_w0, nmcur32 = nm_cur;
	wire [8:0]  nbytes = {1'b0, nlen} + 9'd1 - {4'd0, ei, 2'b00};
	wire [31:0] nmask  = (nbytes >= 9'd4) ? 32'hffffffff : (nbytes == 9'd3) ? 32'hffffff00 : (nbytes == 9'd2) ? 32'hffff0000 : 32'hff000000;
	wire [23:0] next_rec = cur + 24'd32 + {e_len[23:2], 2'b00} + {22'd0, (|e_len[1:0]), 1'b0} + {22'd0, (|e_len[1:0]), 1'b0};
	reg [15:0] maddr = 16'd0;
	reg [WIDTH-1:0] nm_w0 = {WIDTH{1'b0}}, nm_w1 = {WIDTH{1'b0}};
	wire [15:0] maddr_o = (st == NM1) ? maddr + 16'd1 : maddr;
	wire        mre_o = (st == NM0) || (st == NM1) || (st == FE_N0);
	wire        wopen_ok = (fs_end < 24'hFFE000);
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
	// one micro-operation for the SPI engine, then wait in FW until it has been done, and go on to the state `nx`
	`define FOP(OP, NX) begin f_op <= OP; f_req_t <= ~f_req_t; fret <= NX; st <= FW; end
	wire [7:0] wlbyte = (bc == 2'd0) ? wword[7:0] : (bc == 2'd1) ? wword[15:8] : (bc == 2'd2) ? wword[23:16] : wword[31:24];
	wire [7:0] lenbyte = (bc == 2'd0) ? f_ln[7:0] : (bc == 2'd1) ? f_ln[15:8] : (bc == 2'd2) ? f_ln[23:16] : 8'd0;
	always @(posedge clk) begin
		io_ack <= 1'b0;
		if (rst) begin st <= IDLE; out_file <= 1'b0; wmark <= 1'b0; f_req_t <= 1'b0; fl_open <= 3'd0; fsel <= 2'd0; stdin_fs <= 2'd0; stdin_chk <= 1'b0; stdin_scan <= 1'b0;
			kname <= 1'b0; isw <= 1'b0; wsel <= 1'b0; w_open <= 1'b0; inhdr <= 1'b0; end
		else case (st)
			IDLE: if (io_req) begin
					op <= io_op;
					if (FS_WRITE != 0 && WIDTH == 32 && !stdin_chk) begin                // first request: is there a file STDIN?
						stdin_scan <= 1'b1; kname <= 1'b1; isw <= 1'b0; nlen <= 8'd5; nmw <= 3'd2; ei <= 3'd0; ecount <= 12'd0; match <= 1'b1; found <= 1'b0;
						cur <= FS_AT; f_op <= 3'd0; f_addr <= FS_AT; f_req_t <= ~f_req_t; fret <= FE_W; st <= FW;
					end else st <= GOT;
				end
				else if (enq_n != 4'd0) st <= ENQ;
				else if (halted && w_open) begin cl_ret <= IDLE; st <= CL0; end                // a program that halts with a file open closes it
			GOT: case (op)
				26: st <= (fsel != 2'd0) ? FR0 : RD;                     // rdch: from a file in the flash, or the console
				27: if (wsel) begin pbyte <= io_a[7:0]; pr <= FIN; st <= PB0; end
				    else begin wmark <= 1'b0; st <= WR; end                // wrch
				28: begin maddr <= io_a[15:0]; isw <= 1'b0; kname <= 1'b0; st <= NM0; end   // findinput: look the name up; if it is not a file, the console serves it (the host sends it), except OPTIONS
				29: if (FS_WRITE != 0 && WIDTH == 32) begin maddr <= io_a[15:0]; isw <= 1'b1; kname <= 1'b0; st <= NM0; end   // findoutput: a new file at the end of the chain
				    else begin io_res <= 4; st <= FIN; end                // or stream 4, the console between STX and ETX
				25: if (FS_WRITE != 0 && WIDTH == 32) begin wsel <= (io_a == 8) && w_open; st <= FIN; end                  // selectoutput
				    else if (io_a == 4 && !out_file) begin wmark <= 1'b1; wbyte <= 8'h02; out_file <= 1'b1; st <= WR; end
				    else if (io_a != 4 && out_file) begin wmark <= 1'b1; wbyte <= 8'h03; out_file <= 1'b0; st <= WR; end
				    else st <= FIN;
				34: if (wsel) begin cl_ret <= FIN; st <= CL0; end                                                      // endwrite
				    else if (out_file) begin wmark <= 1'b1; wbyte <= 8'h03; out_file <= 1'b0; st <= WR; end else st <= FIN;
				24: begin                                                // selectinput: a file's stream, the standard input, or the console
					if (io_a == 1 && stdin_fs != 2'd0) fsel <= stdin_fs;
					else fsel <= (io_a >= 5 && io_a <= 7 && fl_open[sidx]) ? sidx[1:0] + 2'd1 : 2'd0;
					st <= FIN;
				end
				33: begin                                                // endread: close the selected file
					if (fsel != 2'd0) begin fl_open[fcur] <= 1'b0; if (fsel == stdin_fs) stdin_fs <= 2'd0; fsel <= 2'd0; end
					st <= FIN;
				end
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
				nm_w1 <= m_rdata_w; nlen <= nm0_32[31:24]; nmw <= nm0_32[31:26] + 3'd1; ei <= 3'd0; ecount <= 12'd0; match <= 1'b1; found <= 1'b0; cur <= FS_AT;
				if (WIDTH == 32 && (isw ? 1'b1 : fany) && nm0_32[31:24] <= 8'd23) begin f_op <= 3'd0; f_addr <= FS_AT; f_req_t <= ~f_req_t; fret <= FE_W; st <= FW; end
				else st <= FE_NF;
			end
			FW: if (f_req_t == f_ack_t) st <= fret;
			// ---- the scan of the chain: the record at `cur`, its six name words compared with the name wanted, then its length and flags
			FE_W: begin
				if ({1'b0, ei} < {1'b0, nmw}) begin maddr <= io_a[15:0] + {13'd0, ei}; st <= FE_N0; end
				else begin nm_cur <= {WIDTH{1'b0}}; st <= FE_R; end
			end
			FE_N0: st <= FE_N1;
			FE_N1: begin nm_cur <= kname ? (ei == 3'd0 ? 32'h05535444 : ei == 3'd1 ? 32'h494E0000 : 32'd0) : m_rdata_w; st <= inhdr ? WO2 : FE_R; end      // STDIN, or the name from the store
			FE_R: `FOP(3'd1, FE_C)
			FE_C: begin
				if (ei == 3'd0 && (f_data == 32'd0 || f_data == 32'hffffffff)) begin          // a blank header: the end of the chain
					fs_end <= cur; e_open <= 1'b0; `FOP(3'd3, FE_OPEN)
				end else begin
					if ({1'b0, ei} < {1'b0, nmw} && ((nmcur32 & nmask) != (f_data & nmask))) match <= 1'b0;
					else if ({1'b0, ei} >= {1'b0, nmw} && (f_data & 32'hffffffff) != 32'd0 && 1'b0) match <= 1'b0;
					if (ei == 3'd5) st <= FE_O1; else begin ei <= ei + 3'd1; st <= FE_W; end
				end
			end
			FE_O1: `FOP(3'd1, FE_O2)
			FE_O2: begin e_len <= f_data[23:0]; e_open <= (f_data == 32'hffffffff); st <= FE_L; f_op <= 3'd1; f_req_t <= ~f_req_t; fret <= FE_L; st <= FW; end
			FE_L: begin                                              // the flags word has been read: the record is complete
				ecount <= ecount + 12'd1;
				if (e_open) begin fs_end <= cur; `FOP(3'd3, FE_OPEN) end                  // not closed: the chain ends here
				else begin
					if (match) begin found <= 1'b1; f_dat <= cur + 24'd32; f_ln <= e_len; end
					f_op <= 3'd3; f_req_t <= ~f_req_t; fret <= FE_NX; st <= FW;
				end
			end
			FE_NX: begin                                             // on to the next record
				cur <= next_rec; ei <= 3'd0; match <= 1'b1;
				if (ecount == 12'd4000) st <= FE_OPEN;
				else begin f_op <= 3'd0; f_addr <= next_rec; f_req_t <= ~f_req_t; fret <= FE_W; st <= FW; end
			end
			FE_OPEN: begin                                           // the end of the chain has been reached
				if (isw) begin
					if (wopen_ok && !w_open) begin wp <= fs_end; hdr <= fs_end; pstart <= fs_end[7:0]; ei <= 3'd0; inhdr <= 1'b1; st <= WO0; end
					else begin io_res <= {WIDTH{1'b0}}; st <= FIN; end
				end else if (found && fany) begin
					fl_base[fslot] <= f_dat; fl_pos[fslot] <= 24'd0; fl_len[fslot] <= f_ln; fl_open[fslot] <= 1'b1;
					if (stdin_scan) begin stdin_fs <= {1'b0, 1'b1} + fslot; fsel <= {1'b0, 1'b1} + fslot; stdin_chk <= 1'b1; stdin_scan <= 1'b0; kname <= 1'b0; st <= GOT; end
					else begin io_res <= {{(WIDTH-3){1'b0}}, 3'd5 + {1'b0, fslot}}; st <= FIN; end
				end else if (stdin_scan) begin stdin_chk <= 1'b1; stdin_scan <= 1'b0; kname <= 1'b0; st <= GOT; end
				else st <= FE_NF;
			end
			FE_NF: begin
				io_res <= (isw) ? {WIDTH{1'b0}} : (WIDTH == 32 && nm_w0 == 32'h074F5054 && nm_w1 == 32'h494F4E53) ? {WIDTH{1'b0}} : 3;
				st <= FIN;
			end
			FR0: begin                                               // rdch from a file: a READ at its position
				if (fl_pos[fcur] >= fl_len[fcur]) begin io_res <= {WIDTH{1'b1}}; st <= FIN; end
				else begin f_op <= 3'd0; f_addr <= fl_base[fcur] + fl_pos[fcur]; f_req_t <= ~f_req_t; fret <= FR1; st <= FW; end
			end
			FR1: `FOP(3'd2, FR2)
			FR2: begin io_res <= {{(WIDTH-8){1'b0}}, f_data[7:0]}; fl_pos[fcur] <= fl_pos[fcur] + 24'd1; f_op <= 3'd3; f_req_t <= ~f_req_t; fret <= FIN; st <= FW; end
			// ---- a new file: its header (name, then the length and flags left blank) goes into the page buffer
			WO0: begin
				if (ei < 3'd6) begin
					if ({1'b0, ei} < {1'b0, nmw}) begin maddr <= io_a[15:0] + {13'd0, ei}; st <= FE_N0; end
					else begin nm_cur <= {WIDTH{1'b0}}; st <= WO2; end
				end else begin bc <= 2'd0; fc <= 4'd0; st <= WO5; end
			end
			WO2: begin wword <= (({1'b0, ei} < {1'b0, nmw}) ? (nmcur32 & nmask) : 32'd0); bc <= 2'd0; st <= WO3; end
			WO3: begin pbyte <= wlbyte; pr <= WO4; st <= PB0; end
			WO4: if (bc == 2'd3) begin ei <= ei + 3'd1; st <= WO0; end else begin bc <= bc + 2'd1; st <= WO3; end
			WO5: begin pbyte <= 8'hff; pr <= WO6; st <= PB0; end                       // eight bytes of ones: the length and the flags
			WO6: if (fc == 4'd7) begin inhdr <= 1'b0; w_open <= 1'b1; wsel <= 1'b0; io_res <= 8; st <= FIN; end else begin fc <= fc + 4'd1; st <= WO5; end
			// ---- appending a byte: a new sector is erased when the chain first reaches it; a full page is programmed
			PB0: if (wp[11:0] == 12'd0) begin ea <= wp; rs0 <= PB1; st <= SE0; end else st <= PB1;
			PB1: begin
				pbuf[wp[7:0]] <= pbyte; wp <= wp + 24'd1;
				if (wp[7:0] == 8'hff) begin pa <= {wp[23:8], 8'h00}; ps <= pstart; pe <= 8'hff; rs0 <= PB2; st <= SG0; end
				else st <= pr;
			end
			PB2: begin pstart <= 8'd0; st <= pr; end
			// ---- the flash's own commands: write enable, wait for the busy bit, erase a sector, program a page's bytes, program the length word
			SW0: begin f_cmd <= 8'h06; `FOP(3'd6, SW1) end
			SW1: `FOP(3'd3, rs1)
			SP0: begin f_cmd <= 8'h05; `FOP(3'd6, SP1) end
			SP1: `FOP(3'd2, SP2)
			SP2: `FOP(3'd3, SP3)
			SP3: if (f_data[0]) st <= SP0; else st <= rs1;
			SE0: begin rs1 <= SE1; st <= SW0; end
			SE1: begin f_cmd <= 8'h20; f_addr <= ea; `FOP(3'd4, SE2) end
			SE2: `FOP(3'd3, SE3)
			SE3: begin rs1 <= rs0; st <= SP0; end
			SG0: begin rs1 <= SG1; st <= SW0; end
			SG1: begin f_cmd <= 8'h02; f_addr <= pa + {16'd0, ps}; pi <= ps; `FOP(3'd4, SG2) end
			SG2: begin f_tx <= pbuf[pi]; `FOP(3'd5, SG3) end
			SG3: if (pi == pe) `FOP(3'd3, SG4) else begin pi <= pi + 8'd1; st <= SG2; end
			SG4: begin rs1 <= rs0; st <= SP0; end
			SL0: begin rs1 <= SL1; st <= SW0; end
			SL1: begin f_cmd <= 8'h02; f_addr <= hdr + 24'd24; bc <= 2'd0; `FOP(3'd4, SL2) end
			SL2: begin f_tx <= (bc == 2'd3) ? 8'h00 : lenbyte; `FOP(3'd5, SL3) end
			SL3: if (bc == 2'd3) `FOP(3'd3, SL4) else begin bc <= bc + 2'd1; st <= SL2; end
			SL4: begin rs1 <= rs0; st <= SP0; end
			// ---- closing the file: program what is left of the last page, then the length
			CL0: if (wp[7:0] != 8'd0 && wp[7:0] != pstart) begin pa <= {wp[23:8], 8'h00}; ps <= pstart; pe <= wp[7:0] - 8'd1; rs0 <= CL1; st <= SG0; end
			     else st <= CL1;
			CL1: begin f_ln <= wp - (hdr + 24'd32); rs0 <= CL2; st <= SL0; end
			CL2: begin wp <= wp + 24'd3; st <= CL3; end
			CL3: begin fs_end <= {wp[23:2], 2'b00}; w_open <= 1'b0; wsel <= 1'b0; st <= cl_ret; end
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
