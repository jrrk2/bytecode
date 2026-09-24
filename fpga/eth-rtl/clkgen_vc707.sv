// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// VC707: 200 MHz LVDS system clock -> 50 MHz system clock.
// MMCM topology (ZHOLD, direct feedback loop) proven on this board in
// both the Vivado and the open nextpnr flow (v7-johnson-demo ethsoc).
module clkgen_vc707 #(
    // clk_mac = VCO / MAC_DIV.  The VCO here is 1000 MHz, so 8 -> 125 MHz,
    // 10 -> 100 MHz, 16 -> 62.5 MHz.
    parameter integer MAC_DIV = 8,
    // clk_sys = VCO / SYS_DIV: 40 -> 25 MHz (the default, unchanged),
    // 20 -> 50 MHz, 10 -> 100 MHz.
    parameter real SYS_DIV = 40.000
) (
    input  IO_CLK_P,
    input  IO_CLK_N,
    input  IO_RST_N,
    output clk_sys,
    // Second output for the Ethernet MAC when it is retimed off the PCS clock.
    // Existing users can leave it unconnected: it costs one CLKOUT and a BUFG
    // that synthesis removes if nothing drives a load.
    output clk_mac,
    output rst_sys_n,
    output locked          // MMCM LOCKED, exposed for the open-flow USER1 probe
);
  logic locked_mmcm;
  logic io_clk_buf;
  logic clk_sys_unbuf, clk_mac_unbuf;
  logic clk_fb;

  IBUFDS io_clk_ibufds (
    .I (IO_CLK_P),
    .IB(IO_CLK_N),
    .O (io_clk_buf)
  );

  // 200 MHz x5 = 1 GHz VCO; /SYS_DIV.  The open flow (nextpnr, no proper
  // hold STA) does not reliably close 50 MHz for the debug-module CDC, so the
  // core clock defaults to 25 MHz here at the source -- no post-route fasm
  // patch.  A design without that CDC can ask for more with SYS_DIV.
  MMCME2_ADV #(
    .BANDWIDTH          ("OPTIMIZED"),
    .COMPENSATION       ("ZHOLD"),
    .STARTUP_WAIT       ("FALSE"),
    .DIVCLK_DIVIDE      (1),
    .CLKFBOUT_MULT_F    (5.000),
    .CLKFBOUT_PHASE     (0.000),
    .CLKOUT1_DIVIDE     (MAC_DIV),
    .CLKOUT1_PHASE      (0.000),
    .CLKOUT1_DUTY_CYCLE (0.500),
    .CLKOUT0_DIVIDE_F   (SYS_DIV),
    .CLKOUT0_PHASE      (0.000),
    .CLKOUT0_DUTY_CYCLE (0.500),
    .CLKIN1_PERIOD      (5.000)
  ) mmcm (
    .CLKFBOUT (clk_fb),
    .CLKFBOUTB(),
    .CLKOUT0  (clk_sys_unbuf),
    .CLKOUT0B (), .CLKOUT1(clk_mac_unbuf), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
    .CLKOUT3  (), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .CLKFBIN  (clk_fb),
    .CLKIN1   (io_clk_buf),
    .CLKIN2   (1'b0),
    .CLKINSEL (1'b1),
    .DADDR    (7'h0), .DCLK(1'b0), .DEN(1'b0), .DI(16'h0),
    .DO       (), .DRDY(), .DWE(1'b0),
    .PSCLK    (1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
    .CLKINSTOPPED(), .CLKFBSTOPPED(),
    .LOCKED   (locked_mmcm),
    .PWRDWN   (1'b0),
    .RST      (1'b0)
  );

  BUFG clk_sys_bufg (
    .I(clk_sys_unbuf),
    .O(clk_sys)
  );

  BUFG clk_mac_bufg (
    .I(clk_mac_unbuf),
    .O(clk_mac)
  );

  // POR from MMCM lock ONLY: the VC707 CPU_RESET input (AV40) single-ended
  // LVCMOS18 IOB is marginal/build-dependent on the open flow (its ILOGIC
  // ZINV_D is a prjxray segbit gap), so gating reset on it spuriously holds
  // the core in reset.  Self-boot from BRAM needs no button; release on lock.
  assign rst_sys_n = locked_mmcm;
  assign locked    = locked_mmcm;
endmodule
