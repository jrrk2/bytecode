// sgmii_soc_liteeth.sv -- sgmii_soc built on LiteEth's OPEN PCS.
//
// Same module name and same port list as ethsoc/sgmii_soc.sv, so
// ethmin/vc707_ethmin.v is unchanged and the SOURCE LIST decides which PCS the
// design gets:
//
//   ethmin/ethmin_sources.f          ethsoc/sgmii_soc.sv + 23 Xilinx IP files
//   ethmin/ethmin_sources_liteeth.f  this file + ethmin/liteeth_phy/*.v
//
// WHY: the Xilinx gig_ethernet_pcs_pma sources are Licensed Materials under the
// AMD Core License Agreement, whose 3.2 permits redistribution "solely in
// Bitstream form".  A design built on them can be run but never published as
// source.  LiteEth's PCS is BSD-2-Clause.  The MAC above (Forencich
// eth_mac_1g) was already MIT, and the firmware is ours, so replacing the PCS
// makes the whole SoC publishable.
//
// TWO CLOCKS WHERE THERE WAS ONE
// ------------------------------
// The Xilinx core exports a single userclk2 and rate-adapts RX into it.
// LiteEth exports eth_tx (MMCM off TXOUTCLK) and eth_rx (MMCM off the
// RECOVERED RXOUTCLK).  They are both 125 MHz and they are not the same clock.
//
// RETIME_MAC=1 is required here GIVEN THE PRESENT DMA, not intrinsically.
// eth_mac_1g does have separate rx_clk and tx_clk, so the MAC itself could sit
// directly on eth_rx/eth_tx; what cannot, today, is what follows it --
// eth_stream_dma has a single eth_clk and port B of picosoc_mem_dp has a
// single clk_b, and two PCS clocks cannot share one port.  Removing the
// retimer therefore means splitting the RX and TX windows into separate
// buffers, and it would also give up the MAC_DIV knob that the open flow
// currently needs.  See the header of ethmin/eth_gmii_retime256.sv.

`default_nettype none

module sgmii_soc #(
    // Present only for interface compatibility with the Xilinx-PCS variant.
    // RETIME_MAC=0 has no meaning here (see above) and is IGNORED, not
    // rejected -- see the note at the top of the module body for why.
    parameter integer RETIME_MAC = 1
) (
    input wire          clk_int,
    input wire          rst_int,
    input wire          mac_clk_in,
    output wire         eth_clk,

    input wire          sgmii_rxp,
    input wire          sgmii_rxn,
    output wire         sgmii_txp,
    output wire         sgmii_txn,
    input wire          sgmii_refclk_p,
    input wire          sgmii_refclk_n,

    output wire         phy_reset_n,
    output wire         mac_gmii_tx_en,

    input wire          tx_axis_tvalid,
    input wire          tx_axis_tlast,
    input wire [7:0]    tx_axis_tdata,
    output wire         tx_axis_tready,
    input wire          tx_axis_tuser,

    output wire         rx_clk,
    output wire [7:0]   rx_axis_tdata,
    output wire         rx_axis_tvalid,
    output wire         rx_axis_tlast,
    output wire         rx_axis_tuser,

    output wire [31:0]  rx_fcs_reg,
    output wire [31:0]  tx_fcs_reg,

    output wire [15:0]  pcspma_status,
    output wire         dbg_enablealign,
    output wire         gtrefclk_bufg_out
);

    // RETIME_MAC is accepted for interface compatibility and then IGNORED:
    // this variant always retimes, because with separate eth_tx/eth_rx clocks
    // there is no single clock a directly-attached MAC could run on.  An
    // elaboration-time $error would say so more loudly, but it is not
    // reliably supported through sv2v/yosys, and the benign failure mode
    // (parameter has no effect) is preferable to an unsynthesisable design.

    // ================================================================
    //  LiteEth PCS + GTXE2, GMII out
    // ================================================================
    wire        eth_tx_clk, eth_rx_clk;
    wire [7:0]  gmii_rxd,  gmii_txd;
    wire        gmii_rx_dv, gmii_rx_er, gmii_tx_en;
    wire        link_up, phy_ready;

    liteeth_sgmii_phy i_phy (
        .clk_int        (clk_int),
        .rst_int        (rst_int),
        .sgmii_refclk_p (sgmii_refclk_p),
        .sgmii_refclk_n (sgmii_refclk_n),
        .sgmii_txp      (sgmii_txp),
        .sgmii_txn      (sgmii_txn),
        .sgmii_rxp      (sgmii_rxp),
        .sgmii_rxn      (sgmii_rxn),
        .gmii_tx_clk    (eth_tx_clk),
        .gmii_txd       (gmii_txd),
        .gmii_tx_en     (gmii_tx_en),
        .gmii_rx_clk    (eth_rx_clk),
        .gmii_rxd       (gmii_rxd),
        .gmii_rx_dv     (gmii_rx_dv),
        .gmii_rx_er     (gmii_rx_er),
        .link_up        (link_up),
        .phy_ready      (phy_ready)
    );

    // ================================================================
    //  Reset synchronisers -- one per PCS clock domain
    // ================================================================
    // phy_ready (both user-clock MMCMs locked) is the async release; each
    // domain then shifts a zero in, so nothing downstream sees a reset edge
    // that did not come from its own clock.
    logic [3:0] txrst_sync, rxrst_sync, macrst_sync;

    always_ff @(posedge eth_tx_clk or negedge phy_ready)
        if (!phy_ready) txrst_sync <= 4'hF;
        else            txrst_sync <= {txrst_sync[2:0], 1'b0};

    always_ff @(posedge eth_rx_clk or negedge phy_ready)
        if (!phy_ready) rxrst_sync <= 4'hF;
        else            rxrst_sync <= {rxrst_sync[2:0], 1'b0};

    always_ff @(posedge mac_clk_in or negedge phy_ready)
        if (!phy_ready) macrst_sync <= 4'hF;
        else            macrst_sync <= {macrst_sync[2:0], 1'b0};

    wire pcs_tx_rst = txrst_sync[3];
    wire pcs_rx_rst = rxrst_sync[3];
    wire mac_rst    = macrst_sync[3];

    // ================================================================
    //  Retimer: two PCS clocks in, one MAC clock out
    // ================================================================
    wire [7:0]  mac_gmii_rxd_i, mac_gmii_txd_i;
    wire        mac_gmii_rx_dv_i, mac_gmii_rx_er_i, mac_gmii_tx_en_i;

    eth_gmii_retime256 i_retime (
        .pcs_rx_clk (eth_rx_clk),
        .pcs_rx_rst (pcs_rx_rst),
        .pcs_rxd    (gmii_rxd),
        .pcs_rx_dv  (gmii_rx_dv),
        .pcs_rx_er  (gmii_rx_er),
        .pcs_tx_clk (eth_tx_clk),
        .pcs_tx_rst (pcs_tx_rst),
        .pcs_txd    (gmii_txd),
        .pcs_tx_en  (gmii_tx_en),
        .mac_clk    (mac_clk_in),
        .mac_rst    (mac_rst),
        .mac_rxd    (mac_gmii_rxd_i),
        .mac_rx_dv  (mac_gmii_rx_dv_i),
        .mac_rx_er  (mac_gmii_rx_er_i),
        .mac_txd    (mac_gmii_txd_i),
        .mac_tx_en  (mac_gmii_tx_en_i),
        .frame_count());

    // ================================================================
    //  Forencich eth_mac_1g -- unmodified, exactly as the Xilinx variant
    // ================================================================
    eth_mac_1g #(
        .ENABLE_PADDING     (1),
        .MIN_FRAME_LENGTH   (64)
    ) i_mac (
        .rx_clk             (mac_clk_in),
        .rx_rst             (mac_rst),
        .tx_clk             (mac_clk_in),
        .tx_rst             (mac_rst),
        .tx_axis_tdata      (tx_axis_tdata),
        .tx_axis_tvalid     (tx_axis_tvalid),
        .tx_axis_tready     (tx_axis_tready),
        .tx_axis_tlast      (tx_axis_tlast),
        .tx_axis_tuser      (tx_axis_tuser),
        .rx_axis_tdata      (rx_axis_tdata),
        .rx_axis_tvalid     (rx_axis_tvalid),
        .rx_axis_tlast      (rx_axis_tlast),
        .rx_axis_tuser      (rx_axis_tuser),
        .gmii_rxd           (mac_gmii_rxd_i),
        .gmii_rx_dv         (mac_gmii_rx_dv_i),
        .gmii_rx_er         (mac_gmii_rx_er_i),
        .gmii_txd           (mac_gmii_txd_i),
        .gmii_tx_en         (mac_gmii_tx_en_i),
        .gmii_tx_er         (),
        // The frame is replayed from the buffer as a contiguous stream, so the
        // PCS's rate enable does not apply on the MAC side.
        .rx_clk_enable      (1'b1),
        .tx_clk_enable      (1'b1),
        .rx_mii_select      (1'b0),
        .tx_mii_select      (1'b0),
        .rx_error_bad_frame (),
        .rx_error_bad_fcs   (),
        .rx_fcs_reg         (rx_fcs_reg),
        .tx_fcs_reg         (tx_fcs_reg),
        .ifg_delay          (8'd12)
    );

    // ================================================================
    //  Outputs
    // ================================================================
    assign phy_reset_n    = ~rst_int;
    assign mac_gmii_tx_en = gmii_tx_en;
    assign rx_clk         = mac_clk_in;
    assign eth_clk        = mac_clk_in;

    // Shaped like the Xilinx status_vector where ethmin actually reads it:
    // bit 0 link status, bits [11:10] speed (2'b10 = 1000 Mbps).  The rest of
    // the Xilinx vector has no counterpart here and reads as zero.
    // ================================================================
    //  Liveness instrument (diagnostic, sampled asynchronously)
    // ================================================================
    // Reported through the SPARE bits of pcspma_status, so no port changes
    // and both the CPU (0x04000000 bits [31:16]) and any LED mux can see it.
    //
    // These exist because when this design went dark on the open flow there
    // was NO observable at all: the UART divider made the firmware's prints
    // unreadable, and the LEDs are CPU GPIO.  The three questions that could
    // not be answered were "are both PHY clocks running", "did the link come
    // up", and "did the MAC ever hand a frame to the PCS" -- one bit each.
    //
    // Each counter lives in its own domain and is read from another without a
    // synchroniser.  That is deliberate and safe HERE: every bit is either a
    // slow heartbeat or a sticky flag, so a metastable sample costs at worst
    // one wrong reading of a bit that is about to settle anyway.  Do not copy
    // this pattern onto anything the design depends on.
    reg [25:0] hb_tx = 0;   always_ff @(posedge eth_tx_clk) hb_tx <= hb_tx + 1'b1;
    reg [25:0] hb_rx = 0;   always_ff @(posedge eth_rx_clk) hb_rx <= hb_rx + 1'b1;

    // Sticky: did the PCS ever see tx_en / rx_dv assert?  Sticky rather than
    // live because a frame is ~1 us and nothing could catch it otherwise.
    reg txen_seen = 0;      always_ff @(posedge eth_tx_clk) if (gmii_tx_en) txen_seen <= 1'b1;
    reg rxdv_seen = 0;      always_ff @(posedge eth_rx_clk) if (gmii_rx_dv) rxdv_seen <= 1'b1;

    // Frame counter on the PCS TX handoff: increments on each tx_en rising
    // edge, so a stuck-at-one tx_en cannot masquerade as traffic.
    reg        txen_q = 0;
    reg [3:0]  tx_frames = 0;
    always_ff @(posedge eth_tx_clk) begin
        txen_q <= gmii_tx_en;
        if (gmii_tx_en && !txen_q) tx_frames <= tx_frames + 1'b1;
    end

    assign pcspma_status  = {tx_frames,   // [15:12] frames handed to the PCS
                             2'b10,       // [11:10] speed = 1000 Mbps
                             hb_tx[25],   // [9]     eth_tx clock alive
                             hb_rx[25],   // [8]     eth_rx clock alive
                             txen_seen,   // [7]     MAC ever drove tx_en
                             rxdv_seen,   // [6]     PCS ever drove rx_dv
                             4'b0,        // [5:2]   spare
                             phy_ready,   // [1]     both user MMCMs locked
                             link_up};    // [0]     link status

    // The Xilinx core brought the 125 MHz refclk out through its own BUFG for
    // the CLK125 mode.  ethmin leaves that port unconnected, and LiteEth keeps
    // its refclk inside the GT, so there is nothing to export.
    assign gtrefclk_bufg_out = 1'b0;
    assign dbg_enablealign   = 1'b0;

endmodule

`default_nettype wire
