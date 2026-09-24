`timescale 1ns/1ps
// eth_gmii_retime256 -- GMII in, GMII out, different clocks on each side.
//
// Drops between the PCS/PMA and an UNMODIFIED eth_mac_1g so the MAC no longer
// has to run at the PCS's 125 MHz.  One eth_pkt_buf256 per direction does the
// decoupling; the MAC sees an ordinary GMII interface on mac_clk and does not
// know anything has changed.
//
// THIS IS THE DECOUPLING MECHANISM, not a wart.  Each buffer is a true
// dual-port BRAM whose two ports exist ONLY to give each side its own clock:
// RX is written on the PCS clock and read on mac_clk, TX the other way round.
// So MAC speed is independent of the PCS, which is what the MAC_DIV build knob
// in vc707_ethmin.v spends -- and what let the open flow close timing when its
// placer reached ~104 MHz on the MAC domain against the PCS's fixed 125.
//
// The price is STORE AND FORWARD in both directions, i.e. latency, not size:
//   RX  the whole frame is captured at the PCS clock, then replayed into
//       axis_gmii_rx at mac_clk.
//   TX  axis_gmii_tx fills the buffer at mac_clk, then it is burst out at the
//       PCS clock.  GMII has no mid-frame flow control, so TX had to be store
//       and forward regardless of the memory used.
// eth_stream_dma holds one frame at a time anyway, so that costs this design
// nothing.
//
// FRAMES ARE FULL SIZE.  The buffer is a 2048 x 9 RAMB18E1 (see
// eth_pkt_buf256), so a full 1518-byte Ethernet frame fits.  The old 256-byte
// bring-up limit, and the 8 x RAM256X1S per buffer behind it, are GONE -- this
// header described them long after they had been replaced, which is how the
// limit came to be quoted as current.  HW-verified 2026-08-19 on the fully
// open flow: ping 0% loss at -s 1472, i.e. a full-MTU frame.
`default_nettype none
module eth_gmii_retime256 (
	// ---- PCS side, 125 MHz, fixed by GMII ------------------------------
	// RX and TX take SEPARATE clocks.  The Xilinx PCS/PMA hands out one
	// userclk2 for both directions (it rate-adapts RX into the TX domain
	// internally), so for that PCS both ports are tied to the same wire and
	// nothing changes.  LiteEth's PCS does not: eth_tx comes from an MMCM off
	// TXOUTCLK and eth_rx from an MMCM off the RECOVERED RXOUTCLK -- same
	// nominal 125 MHz, different clocks, forever.
	//
	// The split costs nothing because the two halves below never shared
	// anything but the wire: RX capture uses pcs_clk only to receive, TX burst
	// uses it only to transmit, and they exchange no signals.  Each half
	// already crosses to mac_clk through its own toggle handshake.
	input  wire       pcs_rx_clk,
	input  wire       pcs_rx_rst,
	input  wire [7:0] pcs_rxd,
	input  wire       pcs_rx_dv,
	input  wire       pcs_rx_er,
	input  wire       pcs_tx_clk,
	input  wire       pcs_tx_rst,
	output reg  [7:0] pcs_txd,
	output reg        pcs_tx_en,

	// ---- MAC side, any frequency that closes ---------------------------
	input  wire       mac_clk,
	input  wire       mac_rst,
	// to the MAC's GMII RX
	output wire [7:0] mac_rxd,
	output wire       mac_rx_dv,
	output wire       mac_rx_er,
	// from the MAC's GMII TX
	input  wire [7:0] mac_txd,
	input  wire       mac_tx_en,
	output wire [7:0] frame_count
);

	// ═══ RX capture: 125 MHz -> 256-byte buffer ══════════════════════════
	wire       rxb_room;
	localparam integer AW = 11;   // matches eth_pkt_buf256's 2K x 9 block RAM
	wire [AW-1:0] rxb_count;
	wire [7:0] rxb_rdata;
	reg  [AW-1:0] rxb_raddr;
	reg        rx_in_frame;
	reg        rx_tog;
	reg  [AW-1:0] rx_len;

	// rewind on the first cycle of a frame we are going to accept
	wire rx_start = rx_in_frame_next && !rx_in_frame;

	eth_pkt_buf256 i_rxbuf (
		.clk(pcs_rx_clk), .rst(pcs_rx_rst), .rd_clk(mac_clk),
		.wr_start(rx_start),
		.wr_en(pcs_rx_dv && rx_in_frame_next), .wr_data(pcs_rxd),
		.wr_count(rxb_count), .wr_room(rxb_room),
		.rd_addr(rxb_raddr), .rd_data(rxb_rdata));

	// Capture only while the CPU side is not still replaying the last frame.
	wire rx_busy;                        // set below, crossed from mac_clk
	wire rx_in_frame_next = pcs_rx_dv && !rx_busy;

	always @(posedge pcs_rx_clk) begin
		if (pcs_rx_rst) begin
			rx_in_frame <= 1'b0; rx_tog <= 1'b0; rx_len <= {AW{1'b0}};
		end else begin
			rx_in_frame <= rx_in_frame_next;
			// frame ends when dv drops; publish the length and hand it over
			if (rx_in_frame && !pcs_rx_dv) begin
				rx_len <= rxb_count;
				rx_tog <= ~rx_tog;
			end
		end
	end

	// ═══ RX replay: buffer -> axis_gmii_rx at mac_clk ════════════════════
	reg  rx_tog_s1, rx_tog_s2, rx_ack_tog;
	reg  replaying;
	reg  [AW-1:0] replay_n;
	wire [AW-1:0] rx_len_s = rx_len;        // stable once rx_tog flips
	reg        replaying_d;              // dv, delayed to match the BRAM read

	always @(posedge mac_clk) begin
		if (mac_rst) begin
			rx_tog_s1 <= 1'b0; rx_tog_s2 <= 1'b0; rx_ack_tog <= 1'b0;
			replaying <= 1'b0; rxb_raddr <= {AW{1'b0}}; replay_n <= {AW{1'b0}};
			replaying_d <= 1'b0;
		end else begin
			rx_tog_s1 <= rx_tog;
			rx_tog_s2 <= rx_tog_s1;
			// The BRAM arm has a TAIL cycle: replaying is already low while the
			// last byte is still being emitted and rx_ack_tog has not been
			// updated yet.  Testing !replaying alone re-fires the start
			// condition in that cycle and the whole frame is replayed twice
			// (measured: 414 AXI beats for 207 bytes).
			if (!replaying && !replaying_d) begin
				if (rx_tog_s2 != rx_ack_tog) begin
					replaying <= 1'b1;
					rxb_raddr <= {AW{1'b0}};
					replay_n  <= rx_len_s;
				end
			end else begin
				rxb_raddr <= rxb_raddr + 1'b1;
				if (rxb_raddr + 1'b1 >= replay_n) begin
					replaying  <= 1'b0;
				end
			end
			// A REGISTERED read means the last byte is still in flight when
			// replaying drops -- releasing the buffer on that edge lets the PCS
			// side start refilling under the byte we have not emitted yet.
			// Measured before this: frames truncated, 81 of 192 bytes out.
			// So track the emitted cycle and release one later, when dv falls.
			replaying_d <= replaying;
			if (replaying_d && !replaying)
				rx_ack_tog <= rx_tog_s2;
		end
	end

	// tell the PCS side the buffer is still in use
	reg busy_s1, busy_s2;
	always @(posedge pcs_rx_clk) begin
		busy_s1 <= (rx_tog_s2 != rx_ack_tog) | replaying;
		busy_s2 <= busy_s1;
	end
	assign rx_busy = busy_s2;

	// The MAC lives OUTSIDE this module and is completely unmodified: it sees a
	// normal GMII stream, just one clocked at mac_clk.  replaying is the dv --
	// the buffer is replayed as a contiguous frame, which is what GMII means.
	assign mac_rxd   = rxb_rdata;
	// The block-RAM buffer REGISTERS its read: the byte for the address held
	// during cycle t appears at t+1, so dv follows the address by one cycle.
	// replaying is high for replay_n cycles (addresses 0..n-1), so its
	// registered copy is high for replay_n cycles too, one later -- covering
	// the final byte, which arrives the cycle after replaying drops.
	// replaying_d is driven by the FSM above, which also uses it to hold the
	// buffer until that last byte is out.
	assign mac_rx_dv = replaying_d;
	assign mac_rx_er = 1'b0;

	// ═══ TX capture: mac_clk -> 256-byte buffer ══════════════════════════
	wire [AW-1:0] txb_count;
	wire [7:0] txb_rdata;
	wire       txb_room;
	reg  [AW-1:0] txb_raddr;
	reg        tx_tog, tx_en_q;
	reg  [AW-1:0] tx_len;

	wire tx_start = mac_tx_en && !tx_en_q;

	eth_pkt_buf256 i_txbuf (
		.clk(mac_clk), .rst(mac_rst), .rd_clk(pcs_tx_clk),
		.wr_start(tx_start),
		.wr_en(mac_tx_en), .wr_data(mac_txd),
		.wr_count(txb_count), .wr_room(txb_room),
		.rd_addr(txb_raddr), .rd_data(txb_rdata));

	always @(posedge mac_clk) begin
		if (mac_rst) begin
			tx_tog <= 1'b0; tx_en_q <= 1'b0; tx_len <= {AW{1'b0}};
		end else begin
			tx_en_q <= mac_tx_en;
			if (tx_en_q && !mac_tx_en) begin      // frame complete
				tx_len <= txb_count;
				tx_tog <= ~tx_tog;
			end
		end
	end

	// ═══ TX burst: buffer -> GMII at 125 MHz ═════════════════════════════
	// Only starts once the WHOLE frame is buffered: GMII cannot be stalled
	// mid-frame, so a gap is a corrupt frame, not a pause.
	reg tx_tog_s1, tx_tog_s2, tx_done_tog;
	reg sending;
	reg sending_d;                       // tx_en, delayed to match the BRAM read
	reg [AW-1:0] send_n;
	reg [7:0] fcount;
	assign frame_count = fcount;

	always @(posedge pcs_tx_clk) begin
		if (pcs_tx_rst) begin
			tx_tog_s1 <= 1'b0; tx_tog_s2 <= 1'b0; tx_done_tog <= 1'b0;
			sending <= 1'b0; pcs_tx_en <= 1'b0; txb_raddr <= {AW{1'b0}};
			sending_d <= 1'b0;
			fcount <= 8'd0;
		end else begin
			tx_tog_s1 <= tx_tog;
			tx_tog_s2 <= tx_tog_s1;
			pcs_tx_en <= 1'b0;
			// TX is a cycle WORSE than RX: pcs_txd is itself registered from
			// txb_rdata, so with a registered read the byte for address k
			// reaches the pin two cycles after k is presented.  Capture while
			// sending OR one cycle past it (to catch the last byte), and let
			// tx_en trail by one more -- pcs_tx_en <= sending_d puts it exactly
			// on the n cycles that carry data.  GMII cannot be stalled
			// mid-frame, so an off-by-one here is a corrupt frame, not a
			// hiccup.
			sending_d <= sending;
			if (sending || sending_d)
				pcs_txd <= txb_rdata;
			pcs_tx_en <= sending_d;
			if (!sending && !sending_d) begin
				if (tx_tog_s2 != tx_done_tog) begin
					sending   <= 1'b1;
					txb_raddr <= {AW{1'b0}};
					send_n    <= tx_len;
				end
			end else if (sending) begin
				txb_raddr <= txb_raddr + 1'b1;
				if (txb_raddr + 1'b1 >= send_n)
					sending <= 1'b0;
			end
			// release only once the last byte has actually gone out
			if (sending_d && !sending) begin
				tx_done_tog <= tx_tog_s2;
				fcount      <= fcount + 8'd1;
			end
		end
	end
endmodule
`default_nettype wire
