// ethmin_vm_core -- xc7-bitstream-tools' ethmin_core with the OCaml bytecode
// VM in place of picosoc.  Same ports, same Ethernet DMA (eth_stream_dma) and
// register semantics.  The resident program (io/ethmin.ml, io/dhcp.ml or the
// loader io/netboot.ml, built in by tools/progimage.sh) runs after every
// reset; the loader can stage another program's image and BOOT it (see the
// boot sequencer below).  Programs reach the hardware through the VM's trap
// port as one I/O space (vm_io_read / vm_io_write), exactly as ethmodel.c
// simulates it:
//
//   0x0000..0x07FF  RX window, a byte per address   packet RAM words 0..511
//   0x0800..0x0FFF  TX window                       packet RAM words 512..1023
//   0x1000  r  {rx_trunc, tx_busy, rx_valid}
//   0x1001  r  pcspma_status
//   0x1002  r  received length       w  release the RX window
//   0x1003  w  length: send the TX window
//   0x1004  rw LEDs
//   0x1005  w  UART byte (simpleuart, 115200 8N1)
//   0x1006  r  milliseconds since reset (30 bits, wraps after ~12 days)
//   0x1007  w  boot the image staged in the staging RAM
//   0x1008  r  the next byte received on the UART, or -1 (a 256-byte FIFO)
//   0x1009  r  the board's DIP switches (8 bits), synchronised
//   0x100b  r  the board's push buttons (5 bits), synchronised
//   0x100a  r  who built this bitstream: bits 27:0 the git commit (7 hex
//              digits), bit 28 set if the tree was dirty, bits 31:30 the
//              flow (1 = the open flow, 2 = Vivado, 0 = unsaid)
//   0x100c  rw the program's length in words: what the fetch unit will
//              reach.  Read, it says where the program's own code ends, so
//              a compiler can append without being told; written, it
//              admits what was appended.
//   0x10000..0x2FFFF  the staging RAM, a byte per address
//   0x60000..0x7FFFF  the program's code, a byte per address, readable and
//              writable while it runs: a compiler on this machine appends
//              closures to the program it is itself part of, and reads it
//              back to find the places it must patch
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
	parameter [31:0]  BUILD_ID = 32'd0,   // the commit, the dirty bit and the flow
	parameter integer BAUD = 115_200
) (
	input  wire        clk_sys,
	input  wire        resetn,
	input  wire [7:0]  DIP,           // the board's DIP switches (SW11)
	input  wire [4:0]  BTN,           // the board's push buttons
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
	wire [31:0] mem_b_rdata;
	wire        rx_valid /*verilator public_flat_rd*/;  // the testbench feeds frames when it is clear
	wire        rx_trunc, tx_busy;
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
	// One byte-wide memory per lane, each a plain two-port RAM with a whole-
	// word write enable.  As one 32-bit memory with byte enables it is what
	// Vivado infers from a byte-write template, but yosys consolidates the
	// two write ports and then finds no block RAM that fits, so the open
	// flow cannot map it (memory_libmap: "no valid mapping found").
	//
	// Each port also leaves its read register alone while it writes (the
	// block RAM's NO_CHANGE mode).  Reading the old word of the address
	// being written is READ_FIRST, which Vivado infers but yosys has no
	// block RAM rule for; neither side here reads while it writes.
	reg         pa_en;
	reg  [3:0]  pa_we;
	reg  [9:0]  pa_addr;
	reg  [31:0] pa_wdata;
	wire [31:0] pa_rdata;

	genvar lane;
	generate
		for (lane = 0; lane < 4; lane = lane + 1) begin : pkt_lane
			reg [7:0] mem [0:1023];
			reg [7:0] b_q, a_q;
			always @(posedge eth_clk)
				if (mem_b_en) begin
					if (mem_b_we) mem[mem_b_addr[9:0]] <= mem_b_wdata[8*lane +: 8];
					else b_q <= mem[mem_b_addr[9:0]];
				end
			always @(posedge clk_sys)
				if (pa_en) begin
					if (pa_we[lane]) mem[pa_addr] <= pa_wdata[8*lane +: 8];
					else a_q <= mem[pa_addr];
				end
			assign mem_b_rdata[8*lane +: 8] = b_q;
			assign pa_rdata[8*lane +: 8] = a_q;
		end
	endgenerate

	// ─── code, images and the boot sequencer ─────────────────────────────
	// The resident program (tools/progimage.sh: program.hex, heap.hex,
	// globals.hex) runs after every reset.  It may stage another program's
	// image (tools/mkvmimage.py) in the staging RAM and write BOOT: the
	// sequencer then loads that image into the program code RAM and the VM
	// and starts it, until the next reset brings the resident one back.
	// Every memory here is 32K words deep, which is what makes yosys build it
	// from RAMB36s in x1 mode -- one bit per block RAM, 32K deep, the mode the
	// open flow gets right.  At 16K deep it picks x2 and at 8K x4, and those
	// come out of nextpnr miscompiled: the board then runs the loader (whose
	// code is a x9 ROM) while its heap is corrupt, so the strings are intact
	// but every pointer into them is wrong.  Vivado is happy either way.
	// The staging RAM is fully addressed: 32K words (128 KiB).
	localparam integer PROG_WORDS  = 32768;   // program code RAM (block RAM)
	localparam integer STAGE_WORDS = 32768;   // staging RAM: 128 KiB
	// 32K words, two 16K semi-spaces.  It was briefly four times this, to
	// give a tree-walking interpreter room for the frames it holds live,
	// and that cost 0.7 ns and with it 100 MHz.  Compiled code keeps its
	// frames on the VM's stack instead, so the room is better bought by
	// compiling than by block RAM.
	localparam integer HEAP_AW     = 15;
	localparam integer GLOBALS_AW  = 13;      // see the VM instantiation

	// 36 bits, not 32: at 32 bits yosys slices these ROMs x9, and a RAMB36 in
	// x9 mode loses its ninth bit in the open flow -- the parity bit comes out
	// of the lower RAMB18's wire, which prjxray's site-pin mapping does not
	// model.  Every ninth bit of the program and its constants was wrong.
	// Four unused bits per word buys x18/x36 slicing instead, and block RAM is
	// what this design has spare.
	// code_rom is not inferred: tools/gen_rom_bram.py writes it out as one
	// RAMB36E1 per bit at x1 (program_bram.v), because inference picks x9 --
	// fewest block RAMs -- and a RAMB36 at x9 loses its ninth bit in the open
	// flow.  The others are small and do not land on x9.
	reg [35:0] heap_rom    [0:`HEAP_WORDS-1];
	reg [35:0] globals_rom [0:`GLOBALS_WORDS-1];
	initial begin
		$readmemh("heap.hex", heap_rom);
		$readmemh("globals.hex", globals_rom);
	end
	reg [31:0] prog_code [0:PROG_WORDS-1];
	reg [31:0] stage_ram [0:STAGE_WORDS-1];

	wire [23:0] pc /*verilator public_flat_rd*/;
	reg         code_bank /*verilator public_flat_rd*/;  // 0: the resident program, 1: the loaded one
	reg  [15:0] prog_words /*verilator public_flat_rd*/;

	// The sequencer: after reset it loads the resident program's heap and
	// globals into the VM; on BOOT the staged image's code, heap and globals.
	// The VM is held in reset throughout, writing through its load port.
	localparam [2:0] SEQ_RESIDENT = 3'd0, SEQ_HEADER = 3'd1, SEQ_CODE = 3'd2,
	                 SEQ_HEAP = 3'd3, SEQ_GLOBALS = 3'd4, SEQ_START = 3'd5, SEQ_RUN = 3'd6;
	reg [2:0]  seq_state /*verilator public_flat_rd*/;
	reg        seq_from_stage;         // copying the staged image (else the resident one)
	reg        seq_data_ready;         // the word read last cycle is in seq_q
	reg [15:0] seq_i, seq_n;           // word index within the current section, its length
	reg [15:0] stage_code, stage_heap, stage_globals;
	reg [15:0] glob_count;             // globals from the image; the rest become Val_int(0)
	reg [31:0] seq_q, rom_q;
	reg        vm_hold;
	reg        load_we, load_globals;
	reg [HEAP_AW-1:0] load_addr, image_words;
	// 36 bits, to match the VM's word: the value is in [31:0] and the bits
	// above it are the collector's.  The image supplies zeros there, which
	// is what an object that has never been collected should have.
	reg [35:0] load_data;
	reg        boot_req;
	reg        set_pw;            // 0x100c: raise prog_words
	reg [15:0] set_pw_val;
	integer    code_lane;
	reg [1:0]  hdr_i;

	// The word read this cycle, available next cycle in rom_q (the resident
	// images) or seq_q (the staged one): header words 2-4, then each section.
	wire [14:0] seq_addr = (seq_state == SEQ_HEADER) ? 15'd2 + hdr_i
	                     : 15'd8 + seq_i + ((seq_state != SEQ_CODE) ? stage_code : 16'd0)
	                                     + ((seq_state == SEQ_GLOBALS) ? stage_heap : 16'd0);
	always @(posedge clk_sys) begin
		rom_q <= (seq_state == SEQ_GLOBALS) ? globals_rom[seq_i][31:0] : heap_rom[seq_i][31:0];
		seq_q <= stage_ram[seq_addr];
	end

	always @(posedge clk_sys) begin
		load_we <= 1'b0;
		if (set_pw) prog_words <= set_pw_val;
		if (!resetn) begin
			seq_state <= SEQ_RESIDENT;
			seq_from_stage <= 1'b0;
			seq_i <= 16'd0;
			seq_data_ready <= 1'b0;
			vm_hold <= 1'b1;
			code_bank <= 1'b0;
		end else case (seq_state)
			SEQ_RESIDENT: begin             // straight to the heap copy
				seq_n <= `HEAP_WORDS;
				seq_i <= 16'd0;
				seq_data_ready <= 1'b0;
				seq_state <= SEQ_HEAP;
			end
			SEQ_HEADER: begin               // staged words 2, 3, 4: code, heap, globals
				seq_data_ready <= 1'b1;
				if (seq_data_ready) case (hdr_i)
					2'd1: stage_code <= seq_q[15:0];
					2'd2: stage_heap <= seq_q[15:0];
					2'd3: begin
						stage_globals <= seq_q[15:0];
						seq_n <= stage_code;
						seq_i <= 16'd0;
						seq_data_ready <= 1'b0;
						seq_state <= SEQ_CODE;
					end
					default: ;
				endcase
				hdr_i <= hdr_i + 2'd1;
			end
			// Each section: read word i, write it the cycle after.
			SEQ_CODE, SEQ_HEAP, SEQ_GLOBALS: begin
				if (seq_data_ready) begin
					if (seq_state == SEQ_CODE) ;   // written on the shared port
					else begin
						load_we <= 1'b1;
						load_globals <= seq_state == SEQ_GLOBALS;
						load_addr <= seq_i - 1;
						load_data <= (seq_state == SEQ_GLOBALS && seq_i - 1 >= glob_count) ? 36'h1
						           : seq_from_stage ? {4'd0, seq_q} : {4'd0, rom_q};
					end
				end
				if (seq_i < seq_n) begin              // seq_addr reads word seq_i this cycle
					seq_i <= seq_i + 16'd1;
					seq_data_ready <= 1'b1;
				end else begin                  // section done: the next
					seq_i <= 16'd0;
					seq_data_ready <= 1'b0;
					case (seq_state)
						SEQ_CODE: begin seq_n <= stage_heap; seq_state <= SEQ_HEAP; end
						SEQ_HEAP: begin   // every global slot: no stale pointers for the GC
							seq_n <= 16'd1 << GLOBALS_AW;   // every slot, so the GC never scans garbage
							glob_count <= seq_from_stage ? stage_globals : `GLOBALS_WORDS;
							seq_state <= SEQ_GLOBALS;
						end
						default: seq_state <= SEQ_START;
					endcase
				end
			end
			SEQ_START: begin
				// stage_heap is 16 bits and image_words is HEAP_AW: the
				// assignment pads or truncates as needed, where the slice
				// that used to be here reached past the end of a heap
				// wider than 16 bits
				image_words <= seq_from_stage ? stage_heap : `HEAP_WORDS;
				code_bank   <= seq_from_stage;
				prog_words  <= stage_code[15:0];
				seq_state   <= SEQ_RUN;         // the VM leaves reset next cycle
			end
			SEQ_RUN: begin
				vm_hold <= 1'b0;
				if (boot_req) begin
					vm_hold <= 1'b1;
					seq_from_stage <= 1'b1;
					hdr_i <= 2'd0;
					seq_data_ready <= 1'b0;
					seq_state <= SEQ_HEADER;
				end
			end
			default: seq_state <= SEQ_RUN;
		endcase
	end
	wire vm_reset = !resetn || vm_hold;

	// Instruction fetch.  Both code memories are read synchronously so they
	// infer block RAM (read asynchronously they cost ~14K LUTs of
	// distributed RAM).  The word read is kept with the pc it came from:
	// while it is the one the VM wants, code_valid is high and the next
	// word is prefetched, so running straight through costs no extra cycle
	// and only a jump pays one.
	wire [31:0] code_rom_q_w;
	reg  [31:0] code_prog_q;   // one registered output each: the block RAM's
	reg  [23:0] code_q_pc;
	reg         code_q_valid, fetch_in_range;
	wire        code_valid = code_q_valid && code_q_pc == pc;
	wire [23:0] fetch_pc = code_valid ? pc + 24'd1 : pc;   // prefetch past a hit
	wire [31:0] code_rdata = !fetch_in_range ? 32'hDEADBEEF : code_bank ? code_prog_q : code_rom_q_w;

	code_rom_bram code_rom_i (
		.clk(clk_sys), .en(1'b1), .addr(fetch_pc[14:0]), .dout(code_rom_q_w));

	always @(posedge clk_sys) begin
		code_prog_q <= prog_code[fetch_pc[14:0]];
		fetch_in_range <= code_bank ? (fetch_pc < {8'd0, prog_words})
		                            : (fetch_pc < `PROGRAM_WORDS);
		code_q_pc <= fetch_pc;
		// a new program invalidates what was fetched, and so does writing
		// over the word that was prefetched
		code_q_valid <= !vm_reset && !code_wr;
	end


	// ─── the VM ──────────────────────────────────────────────────────────
	wire        trap_valid;
	wire [7:0]  trap_prim;
	wire [31:0] trap_arg0, trap_arg1;
	reg         trap_ready;
	reg  [31:0] trap_result;
	wire        putc_valid;
	wire [7:0]  putc_char;

	ocaml4142_vm_rtl #(
		.STACK_AW      (15),
		.HEAP_AW       (HEAP_AW),
		// 8K globals, not 4K: 4096 x 32 packs into exactly four RAMB36s at x9,
		// and a RAMB36 at x9 loses its ninth bit in the open flow.  This is
		// the pointer table -- every string constant is reached through it --
		// which is how the board printed intact strings with wrong pointers
		// and a MAC of "ting i".  At 8K deep yosys packs it x4, which works.
		.GLOBALS_AW    (GLOBALS_AW),
		.EXTERNAL_IMAGE(1'b1)
	) vm (
		.clk(clk_sys), .reset(vm_reset),
		.pc(pc), .code_rdata(code_rdata), .code_valid(code_valid),
		.trap_valid(trap_valid), .trap_prim(trap_prim),
		.trap_arg0(trap_arg0), .trap_arg1(trap_arg1),
		.trap_ready(trap_ready), .trap_result(trap_result),
		.accu(), .sp(), .state_out(), .imm(), .nvars(), .offset(),
		.alloc_wosize(), .alloc_base(), .alloc_tag(), .closure_codeptr(),
		.closure_nvars(), .closure_i(), .opcode_out(), .tos(), .halted(),
		.putc_valid(putc_valid), .putc_char(putc_char),
		.load_we(load_we), .load_globals(load_globals), .load_addr(load_addr),
		.load_data(load_data), .image_heap_words(image_words));

	// ─── UART: a FIFO fed by I/O writes and caml_ml_output_char ─────────
	reg  [7:0] uart_fifo [0:255];
	reg  [8:0] uf_wp, uf_rp;             // one extra bit tells full from empty
	wire       uf_empty = uf_wp == uf_rp;
	wire       uf_full  = (uf_wp[7:0] == uf_rp[7:0]) && (uf_wp[8] != uf_rp[8]);
	reg        uf_push;
	reg  [7:0] uf_din;
	reg  [7:0] uart_byte;
	reg        uart_we;
	wire       uart_wait;
	wire       uart_rx_take;
	wire [31:0] uart_rx_do;
	simpleuart #(.DEFAULT_DIV(CLK_HZ / BAUD)) uart (
		.clk(clk_sys), .resetn(resetn),
		.ser_tx(UART_TX), .ser_rx(UART_RX),
		.reg_div_we(4'b0000), .reg_div_di(32'd0), .reg_div_do(),
		.reg_dat_we(uart_we), .reg_dat_re(uart_rx_take),
		.reg_dat_di({24'd0, uart_byte}), .reg_dat_do(uart_rx_do),
		.reg_dat_wait(uart_wait));

	// Received bytes: simpleuart holds one (reg_dat_do is ~0 without one);
	// take each into a FIFO at once, so a pasted line is not lost.
	reg  [7:0]  rx_fifo [0:255];
	reg  [8:0]  rxf_wp, rxf_rp;
	wire        rxf_empty = rxf_wp == rxf_rp;
	wire        rxf_full  = (rxf_wp[7:0] == rxf_rp[7:0]) && (rxf_wp[8] != rxf_rp[8]);
	assign uart_rx_take = (uart_rx_do != 32'hFFFFFFFF) && !rxf_full;
	reg         rxf_pop;
	always @(posedge clk_sys)
		if (!resetn) begin
			rxf_wp <= 9'd0;
			rxf_rp <= 9'd0;
		end else begin
			if (uart_rx_take) begin
				rx_fifo[rxf_wp[7:0]] <= uart_rx_do[7:0];
				rxf_wp <= rxf_wp + 9'd1;
			end
			if (rxf_pop) rxf_rp <= rxf_rp + 9'd1;
		end
	always @(posedge clk_sys)
		if (!resetn) begin
			uf_wp <= 9'd0; uf_rp <= 9'd0; uart_we <= 1'b0;
		end else begin
			if (uf_push && !uf_full) begin
				uart_fifo[uf_wp[7:0]] <= uf_din;
				uf_wp <= uf_wp + 9'd1;
			end
			if (uart_we) begin
				if (!uart_wait) uart_we <= 1'b0;   // simpleuart took it
			end else if (!uf_empty) begin
				uart_byte <= uart_fifo[uf_rp[7:0]];
				uart_we <= 1'b1;
				uf_rp <= uf_rp + 9'd1;
			end
		end

	// ─── millisecond timer ───────────────────────────────────────────────
	localparam integer MS_DIV = CLK_HZ / 1000;
	localparam integer MS_W   = $clog2(MS_DIV);   // 100 MHz needs 17 bits, not 16
	reg [MS_W-1:0] ms_prescale;
	reg [29:0] ms_count;
	always @(posedge clk_sys)
		if (!resetn) begin
			ms_prescale <= {MS_W{1'b0}};
			ms_count    <= 30'd0;
		end else if (ms_prescale == MS_DIV - 1) begin
			ms_prescale <= {MS_W{1'b0}};
			ms_count    <= ms_count + 30'd1;
		end else ms_prescale <= ms_prescale + 1'b1;

	// ─── the I/O space, answering the VM's trap port ─────────────────────
	// One trap_ready per request; a request is not acted on again until
	// trap_valid has dropped (the VM drops it on seeing trap_ready).
	localparam [7:0] TRAP_IO_READ = 8'h01, TRAP_IO_WRITE = 8'h02;
	// The floating-point peripheral: an operand at a time, then the
	// operation, then the upper half of the answer.
	localparam [7:0] TRAP_FP_A = 8'h10, TRAP_FP_B = 8'h11,
	                 TRAP_FP_EXEC = 8'h12, TRAP_FP_HI = 8'h13;
	localparam [2:0] IO_IDLE = 3'd0, IO_PKT_READ = 3'd1, IO_UART = 3'd2, IO_DONE = 3'd3,
	                 IO_STAGE_READ = 3'd4, IO_FP_WAIT = 3'd5, IO_CODE_READ = 3'd6;
	reg [2:0] io_state;
	reg [1:0] io_lane;
	reg [7:0] leds;
	assign LED = leds;

	// The DIP switches are asynchronous to everything: two flops before the
	// processor ever sees them.
	reg [7:0] dip_sync [0:1];
	reg [4:0] btn_sync [0:1];
	always @(posedge clk_sys) begin
		dip_sync[0] <= DIP;
		dip_sync[1] <= dip_sync[0];
		btn_sync[0] <= BTN;
		btn_sync[1] <= btn_sync[0];
	end

	// ─── the floating-point peripheral ───────────────────────────────────
	reg  [63:0] fp_a, fp_b, fp_res;
	reg         fp_start;
	reg  [3:0]  fp_op;
	wire        fp_done, fp_flag;
	wire [63:0] fp_result;
	fpu_hardfloat fpu (
		.clk(clk_sys), .resetn(resetn && !vm_reset),
		.start(fp_start), .op(fp_op), .a(fp_a), .b(fp_b),
		.done(fp_done), .result(fp_result), .flag(fp_flag));

	wire fp_is_cmp = (fp_op == 4'd5) || (fp_op == 4'd6) || (fp_op == 4'd7);
	wire fp_trap = (trap_prim == TRAP_FP_A) || (trap_prim == TRAP_FP_B) ||
	               (trap_prim == TRAP_FP_EXEC) || (trap_prim == TRAP_FP_HI);
	wire fp_new  = trap_valid && fp_trap && io_state == IO_IDLE && !vm_reset;

	wire io_read  = trap_prim == TRAP_IO_READ;
	wire io_write = trap_prim == TRAP_IO_WRITE;
	wire io_new   = trap_valid && (io_read || io_write) && io_state == IO_IDLE && !vm_reset;
	wire [31:0] io_addr = trap_arg0;
	wire io_is_packet = io_addr < 32'h1000;
	// 128 KiB, which is what STAGE_WORDS has always held: the decode used
	// to reach only half of it, and a netboot image that outgrew 64 KiB
	// stopped being acknowledged part way through the transfer.
	wire io_is_stage  = io_addr >= 32'h10000 && io_addr < 32'h30000;

	// Base-relative: the boot sequencer reads the image from word 0.  The old
	// [15:2] did that by accident, dropping bit 16 of a window that was one
	// bit wide; over 128 KiB the offset has to be taken properly.
	wire [14:0] stage_idx = (io_addr - 32'h10000) >> 2;

	// Code memory while the VM runs.  The sequencer's write port is idle
	// then, so the two share it; they cannot collide, because the VM is
	// held in reset for the whole of a load and io_new needs !vm_reset.
	wire io_is_code = io_addr >= 32'h60000 && io_addr < 32'h80000;
	wire [14:0] code_idx = (io_addr - 32'h60000) >> 2;
	wire code_wr = io_new && io_is_code && io_write;

	always @(*) begin
		pa_en    = io_new && io_is_packet;
		pa_we    = (io_new && io_is_packet && io_write) ? (4'b0001 << io_addr[1:0]) : 4'b0000;
		pa_addr  = io_addr[11:2];
		pa_wdata = {4{trap_arg1[7:0]}};
		// caml_ml_output_char, or a UART write the I/O space accepts
		uf_push  = putc_valid || (io_state == IO_UART && !uf_full);
		uf_din   = putc_valid ? putc_char : trap_arg1[7:0];
	end

	wire [31:0] io_read_word = (io_state == IO_PKT_READ) ? pa_rdata
	                         : (io_state == IO_CODE_READ) ? code_q : stage_q;

	// prog_code's second port.  The sequencer loads a program through it and
	// a running program writes and reads its own code through it; the fetch
	// unit has the other.  One block, one address, byte enables -- which is
	// the pattern block RAM is inferred from, and mixing a whole-word write
	// with byte writes over two blocks is not.
	wire        pc_load  = (seq_state == SEQ_CODE) && seq_data_ready;
	wire [14:0] pc_paddr = pc_load ? (seq_i[14:0] - 15'd1) : code_idx;
	wire [31:0] pc_pdata = pc_load ? seq_q : {4{trap_arg1[7:0]}};
	wire [ 3:0] pc_pbe   = pc_load ? 4'b1111
	                     : (code_wr ? (4'b0001 << io_addr[1:0]) : 4'b0000);
	reg [31:0] code_q;
	always @(posedge clk_sys) begin
		for (code_lane = 0; code_lane < 4; code_lane = code_lane + 1)
			if (pc_pbe[code_lane])
				prog_code[pc_paddr][8*code_lane +: 8] <= pc_pdata[8*code_lane +: 8];
		code_q <= prog_code[pc_paddr];
	end

	// The staging RAM's program side: a byte per address, as the packet RAM.
	reg [31:0] stage_q;
	integer stage_lane;
	always @(posedge clk_sys)
		if (io_new && io_is_stage) begin
			if (io_write)
				for (stage_lane = 0; stage_lane < 4; stage_lane = stage_lane + 1)
					if (io_addr[1:0] == stage_lane)
						stage_ram[stage_idx][8*stage_lane +: 8] <= trap_arg1[7:0];
			stage_q <= stage_ram[stage_idx];
		end

	always @(posedge clk_sys) begin
		trap_ready <= 1'b0;
		fp_start   <= 1'b0;
		rx_ack     <= 1'b0;
		tx_start   <= 1'b0;
		boot_req   <= 1'b0;
		set_pw     <= 1'b0;
		rxf_pop    <= 1'b0;
		if (!resetn || vm_reset) begin
			io_state <= IO_IDLE;
			if (!resetn) begin
				leds   <= 8'd0;
				tx_len <= 11'd0;
			end
		end else case (io_state)
			IO_IDLE: if (fp_new) begin
				case (trap_prim)
					TRAP_FP_A: begin fp_a <= {trap_arg1, trap_arg0}; trap_ready <= 1'b1; io_state <= IO_DONE; end
					TRAP_FP_B: begin fp_b <= {trap_arg1, trap_arg0}; trap_ready <= 1'b1; io_state <= IO_DONE; end
					TRAP_FP_HI: begin trap_result <= fp_res[63:32];  trap_ready <= 1'b1; io_state <= IO_DONE; end
					default: begin                 // TRAP_FP_EXEC
						fp_op    <= trap_arg0[3:0];
						fp_start <= 1'b1;
						io_state <= IO_FP_WAIT;
					end
				endcase
			end else if (io_new) begin
				io_lane <= io_addr[1:0];
				if (io_is_code) begin
					if (io_read) io_state <= IO_CODE_READ;   // block RAM data next cycle
					else begin trap_ready <= 1'b1; io_state <= IO_DONE; end
				end else if (io_is_packet || io_is_stage) begin
					if (io_read) io_state <= io_is_packet ? IO_PKT_READ : IO_STAGE_READ;  // BRAM data next cycle
					else begin trap_ready <= 1'b1; io_state <= IO_DONE; end
				end else if (io_write && io_addr == 32'h1005) begin
					io_state <= IO_UART;                                // into the FIFO when there is room
				end else begin
					case (io_addr)
						32'h1000: trap_result <= {29'd0, rx_trunc, tx_busy, rx_valid};
						32'h1001: trap_result <= {16'd0, pcspma_status};
						32'h1002: trap_result <= {21'd0, rx_len};
						32'h1004: trap_result <= {24'd0, leds};
						32'h1006: trap_result <= {2'b00, ms_count};
						32'h1009: trap_result <= {24'd0, dip_sync[1]};  // the DIP switches
						32'h100a: trap_result <= BUILD_ID;             // commit, dirty, flow
						32'h100b: trap_result <= {27'd0, btn_sync[1]}; // the push buttons
						// the program's length: read to find where its code
						// ends, written to admit what was appended
						32'h100c: trap_result <= {16'd0, prog_words};
						32'h1008: begin                               // a received byte, or -1
							trap_result <= rxf_empty ? 32'hFFFFFFFF : {24'd0, rx_fifo[rxf_rp[7:0]]};
							rxf_pop <= io_read && !rxf_empty;
						end
						default:  trap_result <= 32'd0;
					endcase
					if (io_write) case (io_addr)
						32'h1002: rx_ack <= 1'b1;                     // release the RX window
						32'h1003: begin tx_len <= trap_arg1[10:0]; tx_start <= 1'b1; end
						32'h1004: leds <= trap_arg1[7:0];
						32'h1007: boot_req <= 1'b1;                   // boot the staged image
						32'h100c: begin set_pw <= 1'b1; set_pw_val <= trap_arg1[15:0]; end
						default: ;
					endcase
					trap_ready <= 1'b1;
					io_state   <= IO_DONE;
				end
			end
			IO_PKT_READ, IO_STAGE_READ, IO_CODE_READ: begin
				trap_result <= {24'd0, io_read_word[8*io_lane +: 8]};
				trap_ready  <= 1'b1;
				io_state    <= IO_DONE;
			end
			IO_UART: if (!uf_full) begin                         // the FIFO took the byte
				trap_ready <= 1'b1;
				io_state   <= IO_DONE;
			end
			IO_FP_WAIT: if (fp_done) begin
				fp_res      <= fp_result;
				// a comparison answers with its bit; everything else with
				// the lower half, the upper half fetched after it
				trap_result <= fp_is_cmp ? {31'd0, fp_flag} : fp_result[31:0];
				trap_ready  <= 1'b1;
				io_state    <= IO_DONE;
			end
			IO_DONE: if (!trap_valid) io_state <= IO_IDLE;
			default: io_state <= IO_IDLE;
		endcase
	end
endmodule
`default_nettype wire
