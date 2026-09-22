# From vc707-openflow-demos ethmin/vc707_ethmin_liteeth.xdc, unchanged: the
# Vivado constraints for the ethmin top, whose ports vc707_ethmin_vm keeps.

# Pin constraints for vc707_ethmin -- exactly the ports this top has.
# Fabric/UART/LED set from ibexsoc/data/pins_vc707.xdc (proven ethsoc pin set),
# SGMII GT + PHY reset from ibexsoc/data/eth_vc707.xdc.  No MDIO: this SoC
# does not manage the PHY (the link comes up on autoneg without it).
# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

## VC707 (xc7vx485tffg1761-2) pins for the Ibex Demo System.
## Pin set proven on this board in the v7-johnson-demo campaign.

## 200 MHz LVDS system clock (bank 38, 1.8V)
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVDS} [get_ports IO_CLK_P]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVDS} [get_ports IO_CLK_N]
create_clock -period 5.000 -name sysclk [get_ports IO_CLK_P]

## CPU_RESET push button (active high)
set_property -dict {PACKAGE_PIN AV40 IOSTANDARD LVCMOS18} [get_ports IO_RST]



## User LEDs LD0-7
set_property -dict {PACKAGE_PIN AM39 IOSTANDARD LVCMOS18} [get_ports {LED[0]}]
set_property -dict {PACKAGE_PIN AN39 IOSTANDARD LVCMOS18} [get_ports {LED[1]}]
set_property -dict {PACKAGE_PIN AR37 IOSTANDARD LVCMOS18} [get_ports {LED[2]}]
set_property -dict {PACKAGE_PIN AT37 IOSTANDARD LVCMOS18} [get_ports {LED[3]}]
set_property -dict {PACKAGE_PIN AR35 IOSTANDARD LVCMOS18} [get_ports {LED[4]}]
set_property -dict {PACKAGE_PIN AP41 IOSTANDARD LVCMOS18} [get_ports {LED[5]}]
set_property -dict {PACKAGE_PIN AP42 IOSTANDARD LVCMOS18} [get_ports {LED[6]}]
set_property -dict {PACKAGE_PIN AU39 IOSTANDARD LVCMOS18} [get_ports {LED[7]}]

## USB-UART (shared with the system console)
set_property -dict {PACKAGE_PIN AU36 IOSTANDARD LVCMOS18} [get_ports UART_TX]
set_property -dict {PACKAGE_PIN AU33 IOSTANDARD LVCMOS18} [get_ports UART_RX]

set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]

# --- SGMII (GT bank 117); the GT diff pins take no IOSTANDARD ---
set_property PACKAGE_PIN AH8 [get_ports sgmii_refclk_p]
set_property PACKAGE_PIN AH7 [get_ports sgmii_refclk_n]
create_clock -period 8.000 -name sgmii_refclk [get_ports sgmii_refclk_p]
set_property PACKAGE_PIN AN2 [get_ports sgmii_txp]
set_property PACKAGE_PIN AN1 [get_ports sgmii_txn]
set_property PACKAGE_PIN AM8 [get_ports sgmii_rxp]
set_property PACKAGE_PIN AM7 [get_ports sgmii_rxn]
set_property PACKAGE_PIN AJ33 [get_ports eth_rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports eth_rst_n]
set_false_path -to [get_ports eth_rst_n]

# --- Ethernet clock domains (LiteEth PCS) ----------------------------------
# TWO GT user clocks here, where the Xilinx PCS/PMA had one.  That core
# rate-adapted RX into its own TX domain internally and handed the MAC a single
# userclk2; LiteEth does not, so the RECOVERED RX clock is a real, separately
# constrained clock in this design.
#
# Both are the LINE RATE OVER 20 = 62.5 MHz (16 ns), NOT 125.  Constraining
# them at 8 ns is the recorded trap: the MMCM multiplier then resolves against
# the wrong base and Vivado rejects the design with
#   [DRC PDRC-34] computed VCO 2250.000 MHz outside 600-1440 MHz
# The 125 MHz eth_tx/eth_rx are GENERATED clocks off these two and are derived
# automatically -- do not create_clock them by hand.
create_clock -period 16.000 -name gt_txoutclk \
    [get_pins -hierarchical -filter {NAME =~ *GTXE2_CHANNEL*TXOUTCLK}]
create_clock -period 16.000 -name gt_rxoutclk \
    [get_pins -hierarchical -filter {NAME =~ *GTXE2_CHANNEL*RXOUTCLK}]

# TX, RX and the fabric are mutually asynchronous.  eth_gmii_retime256 is the
# CDC between all three: each direction crosses to mac_clk through its own
# toggle handshake, which is exactly why the retimer is mandatory here.
# clk_sys and clk_mac come from one MMCM, so they are related clocks and were
# analysed against each other.  At 50 and 125 MHz that left 3.975 ns and passed
# unnoticed; at 100 and 125 the closest edges are 2 ns apart and 163 paths
# fail.  They cross through the same toggle handshakes as everything else here
# -- the DMA's, and the packet RAM's two independent clocks -- so the honest
# statement is that they are asynchronous too.
set_clock_groups -asynchronous \
    -group [get_clocks clk_sys_unbuf] \
    -group [get_clocks clk_mac_unbuf] \
    -group [get_clocks -include_generated_clocks gt_txoutclk] \
    -group [get_clocks -include_generated_clocks gt_rxoutclk] \
    -group [get_clocks -include_generated_clocks sgmii_refclk]

# SW11, the user DIP switch: switches 0-6 are the image server's host
# number on this board's network, switch 7 turns the receive log on (pins
# from Vivado's vc707 board file).  A switch that is off drives nothing, so
# the input needs a pull-down or it floats -- and floating reads as on.
set_property -dict {PACKAGE_PIN AV30 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[0]}]
set_property -dict {PACKAGE_PIN AY33 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[1]}]
set_property -dict {PACKAGE_PIN BA31 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[2]}]
set_property -dict {PACKAGE_PIN BA32 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[3]}]
set_property -dict {PACKAGE_PIN AW30 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[4]}]
set_property -dict {PACKAGE_PIN AY30 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[5]}]
set_property -dict {PACKAGE_PIN BA30 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[6]}]
set_property -dict {PACKAGE_PIN BB31 IOSTANDARD LVCMOS18 PULLDOWN TRUE} [get_ports {GPIO_DIP_SW[7]}]
