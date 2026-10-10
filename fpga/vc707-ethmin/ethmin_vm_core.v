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
//   0x10000..0x4FFFF  the staging RAM, a byte per address (256 KiB)
//   0x1010..0x1015  w  the staged image: code, heap and globals lengths in
//              words, then where each starts in the staging RAM, in words
//              (the loader writes these, then BOOT; an OCVM image or a raw
//              bytecode executable stripped where it lies)
//   0x1016  w  the program's code is already in the code RAM (the loader wrote it there through
//              0x200000..): the value is its length in words; the code length in 0x1010 is then 0
//              and BOOT copies only the heap and globals.  Cleared by the boot.
//   0x100d  r  the RAM disk's size in bytes: 0, this build has none
//   0x100f  w  the program is finished: once its output has left, restart the resident program (the
//              loader); the RAM disk is kept
//   0x100e  w  boot an image from the RAM disk: the description in 0x1010..0x1015 (word indices from
//              the start of the disk) says where its sections are
//   0x100000..0x17FFFF  the RAM disk, a byte per address.  Block RAM, so
//              it is lost at power off, but the sequencer never touches it
//              and the VM's reset does not reach it: it outlives a chain
//              load, which is what makes it worth having a filesystem on.
//   0x200000..0x27FFFF  the program's code (128K words), a byte per address, readable and
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
	parameter integer BAUD = 115_200,
	parameter integer TRACE_LOG2 = 12      // the trace ring buffer holds 2^TRACE_LOG2 records
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
	output wire        gc_beat,       // the VM's collector: toggles at the end of each collection
	output wire        gc_err,        // ...and goes high, until reset, when a self-check fails or the VM meets a stack, memory or heap event
	input  wire        UART_RX,
	output wire        UART_TX,
	// the SD card slot (sd_wrap.v)
	output wire        sd_sclk,
	inout  wire        sd_cmd,
	inout  wire [3:0]  sd_dat,
	input  wire        sd_detect
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
	// 64K words.  It was 32768, which was a constant and not a limit: the
	// part has 853 RAMB36 spare of 1030, and PCW is 24 bits, so nothing
	// but that number stood in the way.  Doubling it costs about 33 tiles
	// and turns 3941 free words into some 37000.
	localparam integer DISK_WORDS  = 0;       // the RAM disk: none (it was 131072 words, 512 KiB); 0x100d reads 0 and the software copes
	localparam integer DISK_ALLOC  = DISK_WORDS > 0 ? DISK_WORDS : 1;
	localparam integer PROG_WORDS  = 131072;  // the program code RAM: 512 KiB (it was 65536 words)
	localparam integer STAGE_WORDS = 65536;   // staging RAM: 256 KiB, 0x10000..0x4FFFF
	// 64K words, two 32K semi-spaces (it was 32K words: a compiler's phrases
	// outgrew 16K).  It was briefly four times the 32K, to
	// give a tree-walking interpreter room for the frames it holds live,
	// and that cost 0.7 ns and with it 100 MHz.  Compiled code keeps its
	// frames on the VM's stack instead, so the room is better bought by
	// compiling than by block RAM.
	// 256K words, two 128K semi-spaces: a self-compile of io/comp.ml keeps about 100K words live at its peak
	localparam integer HEAP_AW     = 18;
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
	// The resident program's heap and globals images are one ROM, the heap words and then the
	// globals, explicit block RAMs like the code (tools/gen_rom_bram.py): placed where the
	// bitstream's contents can be replaced without a rebuild.
	wire [31:0] rom_q;
	reg [31:0] disk_ram  [0:DISK_ALLOC-1];

	wire [23:0] pc /*verilator public_flat_rd*/;
	reg         code_bank /*verilator public_flat_rd*/;  // 0: the resident program, 1: the loaded one
	reg  [17:0] prog_words /*verilator public_flat_rd*/;   // 18 bits: 131072 does not fit in 17

	// The staged image is described by the loader, not by a header the sequencer
	// reads: 0x1010..0x1015 take the lengths and the staging word index of the code,
	// heap and globals.  A raw bytecode executable is read where it lies.
	// The sequencer: after reset it loads the resident program's heap and
	// globals into the VM; on BOOT the staged image's code, heap and globals.
	// The VM is held in reset throughout, writing through its load port.
	localparam [2:0] SEQ_RESIDENT = 3'd0, SEQ_RHDR = 3'd1, SEQ_CODE = 3'd2,
	                 SEQ_HEAP = 3'd3, SEQ_GLOBALS = 3'd4, SEQ_START = 3'd5, SEQ_RUN = 3'd6;
	reg [2:0]  seq_state /*verilator public_flat_rd*/;
	reg        seq_from_stage;         // copying the staged image (else the resident one)
	reg        seq_data_ready;         // the word read last cycle is in seq_q
	reg [16:0] seq_i, seq_n;           // word index within the current section, its length
	reg [16:0] stage_code, stage_heap, stage_globals;   // section lengths in words, set by the loader
	reg        code_inplace;           // the loader wrote the code into the code RAM itself: nothing to copy, prog_words from inplace_words
	reg [17:0] inplace_words;
	reg [16:0] base_code, base_heap, base_globals;      // where each starts in the staging RAM or the RAM disk, in words
	reg [2:0]  rh_i;                                        // reading the ROM's description
	reg [15:0] res_heap, res_glob, res_prog;                // the resident program's sizes, from the ROM
	reg        seq_from_disk;                           // the image is in the RAM disk (BOOT by 0x100e), not the staging RAM
	reg [15:0] glob_count;             // globals from the image; the rest become Val_int(0)
	reg        vm_hold;
	reg        load_we, load_globals;
	reg [HEAP_AW-1:0] load_addr, image_words;
	// 36 bits, to match the VM's word: the value is in [31:0] and the bits
	// above it are the collector's.  The image supplies zeros there, which
	// is what an object that has never been collected should have.
	reg [35:0] load_data;
	reg        boot_req;
	reg        resident_req;      // 0x100f: go back to the resident program (the loader), keeping the RAM disk
	reg        resident_pending;   // ...once what the program printed has left by the UART
	wire       uart_idle;
	reg        boot_disk_req;     // 0x100e: boot the image the description points at in the RAM disk
	reg        set_pw;            // 0x100c: raise prog_words
	reg        desc_we;           // 0x1010..0x1015: one field of the staged image's description
	reg [2:0]  desc_sel;
	reg [17:0] desc_val;
	reg [17:0] set_pw_val;

	// The word read this cycle, available next cycle in rom_q (the resident
	// images) or seq_q (the staged one): header words 2-4, then each section.
	data_rom_bram data_rom_i (
		.clk(clk_sys), .en(1'b1),
		.addr((seq_state == SEQ_RHDR) ? {12'd0, rh_i[2:0]}
		      : (seq_state == SEQ_GLOBALS) ? seq_i[14:0] + 15'd3 + res_heap[14:0] : seq_i[14:0] + 15'd3), .dout(rom_q));
	reg  [31:0] disk_q;
	wire seq_disk_rd = seq_from_disk && (seq_state == SEQ_CODE || seq_state == SEQ_HEAP || seq_state == SEQ_GLOBALS);
	wire [31:0] seq_word = seq_from_disk ? disk_q : seq_q;
	wire [16:0] seq_addr = seq_i + ((seq_state == SEQ_CODE) ? base_code
	                              : (seq_state == SEQ_HEAP) ? base_heap : base_globals);
	always @(posedge clk_sys) begin
		load_we <= 1'b0;
		if (set_pw) prog_words <= set_pw_val;
		if (desc_we) case (desc_sel)
			3'd0: stage_code    <= desc_val[16:0];
			3'd1: stage_heap    <= desc_val[16:0];
			3'd2: stage_globals <= desc_val[16:0];
			3'd3: base_code     <= desc_val[16:0];
			3'd4: base_heap     <= desc_val[16:0];
			3'd5: base_globals  <= desc_val[16:0];
			3'd6: begin inplace_words <= desc_val; code_inplace <= 1'b1; end   // 0x1016: the code is already in the code RAM
			default: ;
		endcase
		if (!resetn) begin
			seq_state <= SEQ_RESIDENT;
			seq_from_stage <= 1'b0;
			seq_i <= 17'd0;
			seq_data_ready <= 1'b0;
			vm_hold <= 1'b1;
			code_bank <= 1'b0;
			seq_from_disk <= 1'b0;
			resident_pending <= 1'b0;
			code_inplace <= 1'b0;
		end else case (seq_state)
			SEQ_RESIDENT: begin             // the ROM's three-word description, then the heap copy
				rh_i <= 3'd0;
				seq_i <= 17'd0;
				seq_data_ready <= 1'b0;
				seq_state <= SEQ_RHDR;
			end
			SEQ_RHDR: begin                 // word k is in rom_q the cycle after its address
				rh_i <= rh_i + 3'd1;
				case (rh_i)
					3'd1: res_heap <= rom_q[15:0];
					3'd2: res_glob <= rom_q[15:0];
					3'd3: begin
						res_prog <= rom_q[15:0];
						seq_n    <= res_heap;
						seq_i    <= 17'd0;
						seq_data_ready <= 1'b0;
						seq_state <= SEQ_HEAP;
					end
					default: ;
				endcase
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
						           : seq_from_stage ? {4'd0, seq_word} : {4'd0, rom_q};
					end
				end
				if (seq_i < seq_n) begin              // seq_addr reads word seq_i this cycle
					seq_i <= seq_i + 17'd1;
					seq_data_ready <= 1'b1;
				end else begin                  // section done: the next
					seq_i <= 17'd0;
					seq_data_ready <= 1'b0;
					case (seq_state)
						SEQ_CODE: begin seq_n <= stage_heap; seq_state <= SEQ_HEAP; end
						SEQ_HEAP: begin   // every global slot: no stale pointers for the GC
							seq_n <= 17'd1 << GLOBALS_AW;   // every slot, so the GC never scans garbage
							glob_count <= seq_from_stage ? stage_globals : res_glob;
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
				image_words <= seq_from_stage ? stage_heap : res_heap;
				code_bank   <= seq_from_stage;
				prog_words  <= code_inplace ? inplace_words : {1'b0, stage_code};
				code_inplace <= 1'b0;
				seq_state   <= SEQ_RUN;         // the VM leaves reset next cycle
			end
			SEQ_RUN: begin
				vm_hold <= 1'b0;
				if (resident_req) resident_pending <= 1'b1;
				if (resident_pending && uart_idle) begin   // back to what a reset brings, with the disk as it is
					resident_pending <= 1'b0;
					vm_hold <= 1'b1;
					seq_from_stage <= 1'b0;
					seq_from_disk <= 1'b0;
					code_bank <= 1'b0;
					seq_i <= 17'd0;
					seq_data_ready <= 1'b0;
					seq_state <= SEQ_RESIDENT;
				end else if (boot_req || boot_disk_req) begin
					vm_hold <= 1'b1;
					seq_from_stage <= 1'b1;
					seq_from_disk <= boot_disk_req;
					seq_n <= stage_code;
					seq_i <= 17'd0;
					seq_data_ready <= 1'b0;
					seq_state <= SEQ_CODE;
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
	wire [31:0] code_prog_q;   // one registered output each: the block RAM's
	reg  [23:0] code_q_pc;
	reg         code_q_valid, fetch_in_range;
	wire        code_valid = code_q_valid && code_q_pc == pc;
	wire [23:0] fetch_pc = code_valid ? pc + 24'd1 : pc;   // prefetch past a hit
	wire [31:0] code_rdata = !fetch_in_range ? 32'hDEADBEEF : code_bank ? code_prog_q : code_rom_q_w;

	code_rom_bram code_rom_i (
		.clk(clk_sys), .en(1'b1), .addr(fetch_pc[14:0]), .dout(code_rom_q_w));

	always @(posedge clk_sys) begin
		fetch_in_range <= code_bank ? (fetch_pc < {6'd0, prog_words})
		                            : (fetch_pc < {8'd0, res_prog});
		code_q_pc <= fetch_pc;
		// a new program invalidates what was fetched, and so does writing
		// over the word that was prefetched
		code_q_valid <= !vm_reset && !code_wr;
	end


	// ─── the VM ──────────────────────────────────────────────────────────
	wire [35:0] vm_accu;
	wire [14:0] vm_sp;
	wire [6:0]  vm_state;
	wire [7:0]  vm_opcode;
	wire        vm_halted;
	wire        vm_oob_hit;
	wire [35:0] vm_env;
	wire [23:0] vm_dpc;
	wire        vm_gc_start;
	wire [19:0] vm_hp;
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
		.pc(pc), .code_rdata(code_rdata), .code_valid(code_valid), .code_oob(!fetch_in_range),
		.trap_valid(trap_valid), .trap_prim(trap_prim),
		.trap_arg0(trap_arg0), .trap_arg1(trap_arg1),
		.trap_ready(trap_ready), .trap_result(trap_result),
		.accu(), .sp(vm_sp), .state_out(vm_state), .imm(), .nvars(), .offset(),
		.alloc_wosize(), .alloc_base(), .alloc_tag(), .closure_codeptr(),
		.closure_nvars(), .closure_i(), .opcode_out(vm_opcode), .tos(), .halted(vm_halted), .oob_hit(vm_oob_hit), .dbg_accu(vm_accu), .dbg_env(vm_env), .dbg_hp(vm_hp), .dbg_pc(vm_dpc), .gc_start(vm_gc_start),
		.putc_valid(putc_valid), .putc_char(putc_char),
		.dbg_gc_active(), .dbg_gc_beat(gc_beat), .dbg_err(gc_err),
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
	assign     uart_idle = uf_empty && !uart_we;
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
			if (uart_rx_take && uart_rx_do[7:0] != 8'h14) begin     // Ctrl-T is the trace dump's, not the program's
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
	localparam [3:0] IO_IDLE = 4'd0, IO_PKT_READ = 4'd1, IO_UART = 4'd2, IO_DONE = 4'd3,
	                 IO_STAGE_READ = 4'd4, IO_FP_WAIT = 4'd5, IO_CODE_READ = 4'd6,
	                 IO_DISK_READ = 4'd7, IO_SDB_READ = 4'd8;
	reg [3:0] io_state;

	// The machine's recent history, kept in hardware and printed on a Ctrl-T from the console (vm_trace.v),
	// so a machine that has stopped answering can still say where it was.  The VM's own UART output wins a
	// cycle both want.
	wire       tr_dump = uart_rx_take && uart_rx_do[7:0] == 8'h14;
	wire       tr_valid, tr_valid_raw;
	wire [7:0] tr_byte;
	wire       tr_ready = !uf_full && !putc_valid && io_state != IO_UART;
	vm_trace #(.DEPTH_LOG2(TRACE_LOG2)) trace (
		.clk(clk_sys), .resetn(resetn), .state(vm_state), .pc(vm_dpc), .sp(vm_sp), .accu(vm_accu),
		.opcode(vm_opcode), .halted(vm_halted), .freeze(vm_oob_hit), .arm(vm_gc_start && code_bank), .dump_req(tr_dump), .env(vm_env), .hp(vm_hp),
		.out_byte(tr_byte), .out_valid(tr_valid_raw), .out_ready(tr_ready));
	assign tr_valid = tr_valid_raw && tr_ready;
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
	// 256 KiB, which is what STAGE_WORDS holds: below the code window at 0x60000.
	wire io_is_stage  = io_addr >= 32'h10000 && io_addr < 32'h50000;

	// Base-relative: the boot sequencer reads the image from word 0.  The old
	// [15:2] did that by accident, dropping bit 16 of a window that was one
	// bit wide; over 128 KiB the offset has to be taken properly.
	wire [15:0] stage_idx = (io_addr - 32'h10000) >> 2;      // the staging RAM: 256 KiB at 0x10000

	// Code memory while the VM runs.  The sequencer's write port is idle
	// then, so the two share it; they cannot collide, because the VM is
	// held in reset for the whole of a load and io_new needs !vm_reset.
	wire io_is_code = io_addr >= 32'h200000 && io_addr < 32'h280000;      // 512 KiB, a byte per address
	wire [16:0] code_idx = (io_addr - 32'h200000) >> 2;
	wire code_wr = io_new && io_is_code && io_write;

	// The RAM disk, written and read a byte at a time as the staging RAM is.
	wire io_is_disk = io_addr >= 32'h100000 && io_addr < 32'h180000;

	// The SD host (sd_wrap.v, the lowRISC controller): 0x1100.. its registers, two 16-bit halves each; 0x2000.. its 4 KB block buffer
	wire io_is_sdreg = io_addr >= 32'h1100 && io_addr < 32'h1180;
	wire io_is_sdbuf = io_addr >= 32'h2000 && io_addr < 32'h3000;
	wire [15:0] sd_rdata;
	wire [7:0]  sd_buf_rdata;
	sd_wrap sd (
		.clk(clk_sys), .resetn(resetn),
		.reg_write(io_new && io_is_sdreg && io_write), .reg_addr(io_addr[6:0]), .reg_wdata(trap_arg1[15:0]), .reg_rdata(sd_rdata),
		.buf_en(io_new && io_is_sdbuf), .buf_write(io_write), .buf_addr(io_addr[11:0]), .buf_wdata(trap_arg1[7:0]),
		.buf_rdata(sd_buf_rdata),
		.sd_sclk(sd_sclk), .sd_cmd(sd_cmd), .sd_dat(sd_dat), .sd_detect(sd_detect));
	wire [16:0] disk_idx = (io_addr - 32'h100000) >> 2;

	always @(*) begin
		pa_en    = io_new && io_is_packet;
		pa_we    = (io_new && io_is_packet && io_write) ? (4'b0001 << io_addr[1:0]) : 4'b0000;
		pa_addr  = io_addr[11:2];
		pa_wdata = {4{trap_arg1[7:0]}};
		// caml_ml_output_char, or a UART write the I/O space accepts
		uf_push  = putc_valid || (io_state == IO_UART && !uf_full) || tr_valid;
		uf_din   = putc_valid ? putc_char : (io_state == IO_UART) ? trap_arg1[7:0] : tr_byte;
	end

	wire [31:0] io_read_word = (io_state == IO_PKT_READ) ? pa_rdata
	                         : (io_state == IO_CODE_READ) ? code_q
	                         : (io_state == IO_DISK_READ) ? disk_q : stage_q;

	// prog_code's second port.  The sequencer loads a program through it and
	// a running program writes and reads its own code through it; the fetch
	// unit has the other.  One block, one address, byte enables -- which is
	// the pattern block RAM is inferred from, and mixing a whole-word write
	// with byte writes over two blocks is not.
	wire        pc_load  = (seq_state == SEQ_CODE) && seq_data_ready;
	// all 16 bits of seq_i: a program longer than 32K words wrapped onto its own start
	wire [16:0] pc_paddr = pc_load ? (seq_i - 17'd1) : code_idx;
	wire [31:0] pc_pdata = pc_load ? seq_word : {4{trap_arg1[7:0]}};
	wire [ 3:0] pc_pbe   = pc_load ? 4'b1111
	                     : (code_wr ? (4'b0001 << io_addr[1:0]) : 4'b0000);
	wire [31:0] code_q;
	tdp_ram32 #(.AW(17)) prog_code (.clk(clk_sys), .a_addr(fetch_pc[16:0]), .a_q(code_prog_q),
		.b_en(1'b1), .b_addr(pc_paddr), .b_be(pc_pbe), .b_data(pc_pdata), .b_q(code_q));

	// The sequencer reads an image out of the disk through the same read port, which is idle while
	// the VM is held in reset, as the code RAM's second port is shared with it.
	integer disk_lane;
	wire [16:0] disk_ra = seq_disk_rd ? seq_addr : disk_idx;
	generate if (DISK_WORDS > 0) begin : g_disk
		always @(posedge clk_sys) begin
			if (io_new && io_is_disk && io_write)
				for (disk_lane = 0; disk_lane < 4; disk_lane = disk_lane + 1)
					if (io_addr[1:0] == disk_lane)
						disk_ram[disk_idx][8*disk_lane +: 8] <= trap_arg1[7:0];
			if ((io_new && io_is_disk) || seq_disk_rd) disk_q <= disk_ram[disk_ra];
		end
	end else begin : g_nodisk
		always @(posedge clk_sys) disk_q <= 32'd0;       // no RAM disk: reads give 0, writes go nowhere
	end endgenerate

	// The staging RAM's program side: a byte per address, as the packet RAM.
	wire [31:0] stage_q;
	wire [31:0] seq_q;
	tdp_ram32 #(.AW(16)) stage_ram (.clk(clk_sys), .a_addr(seq_addr[15:0]), .a_q(seq_q),
		.b_en(io_new && io_is_stage), .b_addr(stage_idx[15:0]),
		.b_be(io_write ? (4'b0001 << io_addr[1:0]) : 4'b0000), .b_data({4{trap_arg1[7:0]}}), .b_q(stage_q));

	always @(posedge clk_sys) begin
		trap_ready <= 1'b0;
		fp_start   <= 1'b0;
		rx_ack     <= 1'b0;
		tx_start   <= 1'b0;
		boot_req   <= 1'b0;
		boot_disk_req <= 1'b0;
		resident_req  <= 1'b0;
		set_pw     <= 1'b0;
		desc_we    <= 1'b0;
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
				if (io_is_disk) begin
					if (io_read) io_state <= IO_DISK_READ;
					else begin trap_ready <= 1'b1; io_state <= IO_DONE; end
				end else if (io_is_sdbuf) begin
					if (io_read) io_state <= IO_SDB_READ;           // block RAM data next cycle
					else begin trap_ready <= 1'b1; io_state <= IO_DONE; end
				end else if (io_is_sdreg) begin
					trap_result <= {16'd0, sd_rdata};
					trap_ready  <= 1'b1;
					io_state    <= IO_DONE;
				end else if (io_is_code) begin
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
						32'h100c: trap_result <= {14'd0, prog_words};
						// the disk's size, so nothing has to assume it
						32'h100d: trap_result <= DISK_WORDS * 4;
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
						32'h100e: boot_disk_req <= 1'b1;              // boot the image in the RAM disk
						32'h100f: resident_req <= 1'b1;               // back to the loader (the program is finished)
						32'h100c: begin set_pw <= 1'b1; set_pw_val <= trap_arg1[17:0]; end
						32'h1010, 32'h1011, 32'h1012, 32'h1013, 32'h1014, 32'h1015, 32'h1016: begin
							desc_we <= 1'b1; desc_sel <= io_addr[2:0]; desc_val <= trap_arg1[17:0];
						end
						default: ;
					endcase
					trap_ready <= 1'b1;
					io_state   <= IO_DONE;
				end
			end
			IO_SDB_READ: begin
				trap_result <= {24'd0, sd_buf_rdata};
				trap_ready  <= 1'b1;
				io_state    <= IO_DONE;
			end
			IO_PKT_READ, IO_STAGE_READ, IO_CODE_READ, IO_DISK_READ: begin
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
