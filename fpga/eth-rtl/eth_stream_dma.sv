`timescale 1ns/1ps
// eth_stream_dma -- stream Ethernet frames DIRECTLY into and out of the SoC's
// main dual-port memory.  No packet FIFO, no async FIFO, no elastic buffer.
//
// The RX byte stream is packed into 32-bit words and written to BRAM port B at
// RX_WORD_BASE; the TX side reads words from TX_WORD_BASE and unpacks them to
// bytes.  Port B is clocked by eth_clk, so the DATA path never crosses a clock
// boundary -- only the small ownership handshake does, via toggle + 2-flop
// synchronisers.
//
// OWNERSHIP PROTOCOL (what makes the unarbitrated dual port safe):
//   RX  the eth side owns the RX window while receiving.  On a good
//       end-of-frame it latches the byte count and flips rx_tog.  The CPU sees
//       rx_valid, reads the frame, then writes the ack register, flipping
//       rx_ack_tog; the eth side resumes writing only after observing it.  So
//       exactly one side ever writes the window.
//   TX  the CPU owns the TX window while filling it.  Writing tx_len flips
//       tx_tog; the eth side then owns the window until the frame is sent, when
//       it flips tx_done_tog.  tx_busy tells the CPU to keep off.
//
// A frame longer than the window is TRUNCATED and flagged (rx_trunc), never
// wrapped -- wrapping would corrupt whatever follows it in memory, which here
// is the CPU's own code.
//
// The two directions drive the single BRAM port through an explicit mux rather
// than from two always blocks; TX only reads while tx_run, and the CPU cannot
// have handed over the TX window while it is also draining an RX frame.
`default_nettype none
module eth_stream_dma #(
	parameter [13:0] RX_WORD_BASE = 14'h0C00,  // word address of the RX window
	parameter [13:0] TX_WORD_BASE = 14'h0E00,  // word address of the TX window
	parameter integer WINDOW_WORDS = 512       // 2 KiB each
) (
	// ---- eth_clk domain -------------------------------------------------
	input  wire        eth_clk,
	input  wire        eth_rst,

	input  wire [7:0]  rx_axis_tdata,
	input  wire        rx_axis_tvalid,
	input  wire        rx_axis_tlast,
	input  wire        rx_axis_tuser,   // 1 = bad frame (FCS/length error)

	output reg  [7:0]  tx_axis_tdata,
	output reg         tx_axis_tvalid,
	output reg         tx_axis_tlast,
	input  wire        tx_axis_tready,
	output wire        tx_axis_tuser,

	// BRAM port B (eth_clk)
	output wire        mem_en,
	output wire        mem_we,
	output wire [13:0] mem_addr,
	output wire [31:0] mem_wdata,
	input  wire [31:0] mem_rdata,

	// ---- CPU domain -----------------------------------------------------
	input  wire        cpu_clk,
	input  wire        cpu_rst,
	output wire        rx_valid,
	output wire [10:0] rx_len,
	output wire        rx_trunc,
	input  wire        rx_ack,          // 1-cycle pulse
	input  wire [10:0] tx_len,
	input  wire        tx_start,        // 1-cycle pulse
	output wire        tx_busy
);
	// ─── declarations ────────────────────────────────────────────────────
	reg [1:0]  rx_byte;
	reg [9:0]  rx_word;   // 10 bits: WINDOW_WORDS may be 512, which does NOT fit in 9
	reg [10:0] rx_count;
	reg [23:0] rx_hold;
	reg        rx_tog, rx_trunc_q, rx_poison;
	reg [10:0] rx_len_q;
	reg        rx_ack_s1, rx_ack_s2;
	reg        rx_men, rx_mwe;
	reg [13:0] rx_maddr;
	reg [31:0] rx_mdata;

	reg        tx_run;
	reg [10:0] tx_idx;          // byte index whose READ is being issued
	reg [1:0]  sel1, sel2;      // byte-select, delayed to match BRAM latency
	reg        v1, v2, l1, l2;  // valid / last, delayed likewise
	reg [10:0] tx_nbyte;
	reg        tx_go_s1, tx_go_s2, tx_done_tog;
	reg        tx_men;
	reg [13:0] tx_maddr;

	reg        rx_tog_s1, rx_tog_s2, rx_ack_tog_q;
	reg        tx_tog, tx_done_s1, tx_done_s2;
	reg [10:0] tx_len_q;

	assign tx_axis_tuser = 1'b0;        // never signal an underrun abort

	// One BRAM port, two users.  TX only reads while it owns the window.
	assign mem_en    = tx_run ? tx_men  : rx_men;
	assign mem_we    = tx_run ? 1'b0    : rx_mwe;
	assign mem_addr  = tx_run ? tx_maddr : rx_maddr;
	assign mem_wdata = rx_mdata;

	wire rx_window_free = (rx_tog == rx_ack_s2);
	// Compare at FULL width.  This was `WINDOW_WORDS[8:0]`, and 512 truncated to
	// 9 bits is 0, so rx_room was permanently false and not a single frame byte
	// was ever written to the window -- the CPU got a frame-ready flag over empty
	// memory.  Found in xsim: mem_we pulsed once, rx_room final 0.
	wire rx_room        = ({5'd0, rx_word} < WINDOW_WORDS[14:0]);
	wire [31:0] rx_full = {rx_axis_tdata, rx_hold};
	// advance the TX pipeline whenever the output side can take a byte
	wire tx_adv = !tx_axis_tvalid || tx_axis_tready;

	// ─── RX: byte stream -> 32-bit words -> BRAM ─────────────────────────
	always @(posedge eth_clk) begin
		rx_men <= 1'b0;
		rx_mwe <= 1'b0;
		rx_ack_s1 <= rx_ack_tog_q;
		rx_ack_s2 <= rx_ack_s1;
		if (eth_rst) begin
			rx_byte <= 2'd0; rx_word <= 10'd0; rx_count <= 11'd0;
			rx_tog <= 1'b0; rx_trunc_q <= 1'b0; rx_len_q <= 11'd0;
			rx_poison <= 1'b0;
		end else if (rx_axis_tvalid) begin
			// A frame that cannot be stored in full is DISCARDED WHOLE.  The
			// gate used to sit on this `else if`, so when tx_run rose (or the
			// CPU still owned the window) mid-frame the bytes were silently
			// skipped, tlast was never processed, and rx_word/rx_byte stayed
			// mid-frame -- corrupting the NEXT frame too.  Poison the frame
			// instead and drop it at tlast: a lost packet is a retransmit, a
			// corrupt one is a bug.
			if (!rx_window_free || tx_run) rx_poison <= 1'b1;
			if (rx_window_free && !tx_run) begin
			rx_count <= rx_count + 11'd1;
			rx_hold  <= {rx_axis_tdata, rx_hold[23:8]};
			rx_byte  <= rx_byte + 2'd1;
			// Commit on every 4th byte, and again on tlast to flush the partial
			// tail (zero-padded; the length register is authoritative).
			if (rx_byte == 2'd3 || rx_axis_tlast) begin
				if (rx_room) begin
					rx_men   <= 1'b1;
					rx_mwe   <= 1'b1;
					rx_maddr <= RX_WORD_BASE + {4'd0, rx_word};
					rx_mdata <= (rx_byte == 2'd3) ? rx_full
					                              : (rx_full >> (8*(2'd3 - rx_byte)));
					rx_word  <= rx_word + 10'd1;
				end else
					rx_trunc_q <= 1'b1;
				rx_byte <= 2'd0;
			end
			end
			if (rx_axis_tlast) begin
				rx_word <= 10'd0; rx_count <= 11'd0; rx_byte <= 2'd0;
				rx_poison <= 1'b0;
				if (rx_axis_tuser || rx_poison || !rx_window_free || tx_run) begin
					// bad FCS, or we could not store every byte -- discard
					rx_trunc_q <= 1'b0;
				end else begin
					rx_len_q <= rx_count + 11'd1;
					rx_tog   <= ~rx_tog;      // hand ownership to the CPU
				end
			end
		end
	end

	// ─── TX: ONE BYTE PER CYCLE, straight out of the BRAM ────────────────
	// Port B serves a read every cycle, so no prefetch buffer and no word shift
	// register are needed: just issue a read for the word holding byte i and
	// select the byte.  The same word is simply read four times over (the
	// address only changes every 4th byte), which costs nothing on a port that
	// is otherwise idle during TX.
	//
	// This replaced a word-at-a-time FSM that produced BOTH of the bugs xsim
	// found: it branched to the next-word fetch AT byte 3 instead of after it,
	// dropping every fourth byte of the frame, and its first word was captured
	// before the BRAM read had landed, corrupting the destination MAC.  The
	// pipeline here has one shape and one latency, so neither can recur.
	//
	// mem_en/mem_addr are REGISTERED, so the BRAM sees them the next cycle and
	// mem_rdata is valid the cycle after that: the byte-select must therefore be
	// delayed by two stages to line up with the data.
	always @(posedge eth_clk) begin
		tx_go_s1 <= tx_tog;
		tx_go_s2 <= tx_go_s1;
		if (eth_rst) begin
			tx_axis_tvalid <= 1'b0; tx_axis_tlast <= 1'b0;
			tx_run <= 1'b0; tx_idx <= 11'd0; tx_done_tog <= 1'b0;
			tx_men <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; l1 <= 1'b0; l2 <= 1'b0;
		end else if (!tx_run) begin
			tx_men <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; l1 <= 1'b0; l2 <= 1'b0;
			tx_axis_tvalid <= 1'b0; tx_axis_tlast <= 1'b0;
			if (tx_go_s2 != tx_done_tog) begin
				tx_run   <= 1'b1;
				tx_idx   <= 11'd0;
				tx_nbyte <= tx_len_q;
			end
		end else if (tx_adv) begin
			// stage 0: issue the read for byte tx_idx
			tx_men   <= (tx_idx < tx_nbyte);
			tx_maddr <= TX_WORD_BASE + {3'd0, tx_idx[10:2]};
			sel1 <= tx_idx[1:0];
			v1   <= (tx_idx < tx_nbyte);
			l1   <= (tx_idx + 11'd1 == tx_nbyte);
			if (tx_idx < tx_nbyte) tx_idx <= tx_idx + 11'd1;
			// stage 1
			sel2 <= sel1; v2 <= v1; l2 <= l1;
			// stage 2: data for the read issued two cycles ago is on mem_rdata
			tx_axis_tdata  <= mem_rdata[8*sel2 +: 8];
			tx_axis_tvalid <= v2;
			tx_axis_tlast  <= l2;
			if (v2 && l2) begin
				tx_run      <= 1'b0;
				tx_done_tog <= tx_go_s2;   // give the window back
			end
		end
	end

	// ─── CDC: toggles only ───────────────────────────────────────────────
	// The payload registers (rx_len_q, tx_len_q) are stable for many cycles
	// either side of their toggle, so a 2-flop synchroniser on the toggle is
	// sufficient and no gray coding is needed.
	always @(posedge cpu_clk) begin
		if (cpu_rst) begin
			rx_tog_s1 <= 1'b0; rx_tog_s2 <= 1'b0; rx_ack_tog_q <= 1'b0;
			tx_tog <= 1'b0; tx_done_s1 <= 1'b0; tx_done_s2 <= 1'b0;
			tx_len_q <= 11'd0;
		end else begin
			rx_tog_s1  <= rx_tog;
			rx_tog_s2  <= rx_tog_s1;
			tx_done_s1 <= tx_done_tog;
			tx_done_s2 <= tx_done_s1;
			if (rx_ack && rx_valid) rx_ack_tog_q <= ~rx_ack_tog_q;
			if (tx_start && !tx_busy) begin
				tx_tog   <= ~tx_tog;
				tx_len_q <= tx_len;
			end
		end
	end

	assign rx_valid = (rx_tog_s2 != rx_ack_tog_q);
	assign rx_len   = rx_len_q;
	assign rx_trunc = rx_trunc_q;
	assign tx_busy  = (tx_tog != tx_done_s2);
endmodule
`default_nettype wire
