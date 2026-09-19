// vc707_ethmin_vm -- xc7-bitstream-tools' examples/vc707-ethmin top
// (vc707_ethmin.v) with the OCaml bytecode VM in place of picosoc: the
// clocking, SGMII PCS/PMA and MAC are unchanged, and ethmin_vm_core replaces
// ethmin_core.  The VM runs io/ethmin.ml; its packet RAM holds only the two
// windows (RX words 0..511, TX words 512..1023).
`default_nettype none
module vc707_ethmin_vm (
	input  wire       IO_CLK_P,        // 200 MHz LVDS system clock
	input  wire       IO_CLK_N,
	input  wire       IO_RST,          // CPU_RESET, active high
	output wire [7:0] LED,
	input  wire       UART_RX,
	output wire       UART_TX,

	input  wire       sgmii_rxp,
	input  wire       sgmii_rxn,
	output wire       sgmii_txp,
	output wire       sgmii_txn,
	input  wire       sgmii_refclk_p,
	input  wire       sgmii_refclk_n,
	output wire       eth_rst_n
);
	localparam [13:0] RX_WORD_BASE = 14'd0;     // VM I/O 0x0000
	localparam [13:0] TX_WORD_BASE = 14'd512;   // VM I/O 0x0800
	localparam integer WINDOW_WORDS = 512;

	// ─── clocking ────────────────────────────────────────────────────────
	// MAC_DIV picks the MAC's clock: VCO 1000 MHz / MAC_DIV.  8 -> 125 MHz.
	// The MAC no longer has to match the PCS, so this is a build knob -- lower
	// it if timing does not close, at the cost of sustained throughput (which
	// this design does not use: it holds one frame at a time).
	// Overridable so the open flow can lower it WITHOUT a second copy of this
	// file: the open placer reaches ~98 MHz on the MAC domain where Vivado
	// reaches 125+, and that gap is placement quality, not the design.
	// Default 8 keeps every existing flow byte-identical.
`ifndef MAC_DIV
`define MAC_DIV 8
`endif
	localparam integer MAC_DIV = `MAC_DIV;

	wire clk_sys, clk_mac, rst_sys_n, locked;
	clkgen_vc707 #(.MAC_DIV(MAC_DIV)) clkgen (
		.IO_CLK_P(IO_CLK_P), .IO_CLK_N(IO_CLK_N), .IO_RST_N(~IO_RST),
		.clk_sys(clk_sys), .clk_mac(clk_mac),
		.rst_sys_n(rst_sys_n), .locked(locked));
	wire resetn = rst_sys_n;

	wire eth_clk, rx_clk;
	wire eth_rst = ~rst_sys_n;

	// ─── SGMII PCS/PMA + MAC ─────────────────────────────────────────────
	wire [7:0] rx_tdata, tx_tdata;
	wire       rx_tvalid, rx_tlast, rx_tuser;
	wire       tx_tvalid, tx_tlast, tx_tready, tx_tuser;
	wire [15:0] pcspma_status;

	// RETIME_MAC=1: the MAC runs on clk_mac, decoupled from the PCS's 125 MHz
	// by 256-byte RAM256X1S packet buffers.  Frames over 256 bytes are dropped.
	sgmii_soc #(.RETIME_MAC(1)) eth (
		.clk_int(clk_sys), .rst_int(~rst_sys_n),
		.mac_clk_in(clk_mac),
		.eth_clk(eth_clk),
		.sgmii_rxp(sgmii_rxp), .sgmii_rxn(sgmii_rxn),
		.sgmii_txp(sgmii_txp), .sgmii_txn(sgmii_txn),
		.sgmii_refclk_p(sgmii_refclk_p), .sgmii_refclk_n(sgmii_refclk_n),
		.phy_reset_n(eth_rst_n),
		.mac_gmii_tx_en(),
		.tx_axis_tvalid(tx_tvalid), .tx_axis_tlast(tx_tlast),
		.tx_axis_tdata(tx_tdata),   .tx_axis_tready(tx_tready),
		.tx_axis_tuser(tx_tuser),
		.rx_clk(rx_clk),
		.rx_axis_tdata(rx_tdata),   .rx_axis_tvalid(rx_tvalid),
		.rx_axis_tlast(rx_tlast),   .rx_axis_tuser(rx_tuser),
		.rx_fcs_reg(), .tx_fcs_reg(),
		.pcspma_status(pcspma_status));

	// ─── VM + DMA + registers (ethmin_vm_core.v) ─────────────────────────
	ethmin_vm_core #(
		.RX_WORD_BASE(RX_WORD_BASE), .TX_WORD_BASE(TX_WORD_BASE),
		.WINDOW_WORDS(WINDOW_WORDS)
	) core (
		.clk_sys(clk_sys), .resetn(resetn),
		// clk_mac DIRECTLY, not the eth_clk that comes back out of sgmii_soc.
		//
		// With RETIME_MAC=1 -- which this top hardcodes, and which the LiteEth
		// PCS requires -- sgmii_soc's eth_clk IS mac_clk_in, i.e. clk_mac
		// routed out of one module and back into another.  yosys's clkbufmap
		// cannot know that net is already buffered by clkgen.clk_mac_bufg, so
		// it inserted a SECOND global buffer in series: a BUFG->BUFG cascade,
		// which Vivado's DRC flags (PLCK-1) and which costs two insertion
		// delays instead of one.  That delay lands as skew against eth_tx and
		// eth_rx, the two domains already tightest at 125 MHz.
		//
		// eth_clk stays connected below purely as an observable; with no loads
		// no buffer is inferred for it.
		.eth_clk(clk_mac), .eth_rst(eth_rst),
		.rx_axis_tdata(rx_tdata), .rx_axis_tvalid(rx_tvalid),
		.rx_axis_tlast(rx_tlast), .rx_axis_tuser(rx_tuser),
		.tx_axis_tdata(tx_tdata), .tx_axis_tvalid(tx_tvalid),
		.tx_axis_tlast(tx_tlast), .tx_axis_tready(tx_tready),
		.tx_axis_tuser(tx_tuser),
		.pcspma_status(pcspma_status),
		.LED(LED), .UART_RX(UART_RX), .UART_TX(UART_TX));
endmodule
`default_nettype wire
