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
    -group [get_clocks -include_generated_clocks sgmii_refclk]


# NOTE: the GT-derived clock constraint and set_clock_groups from
# vc707_ethmin.xdc are deliberately ABSENT here -- nextpnr's XDC reader accepts
# pin constraints and create_clock on PORTS only, and chokes on
# `get_pins -hierarchical -filter {...}` ("failed to parse target").  nextpnr
# takes its target from --freq instead; the Vivado build keeps the full file.

# Hard-block placement, extracted from an IMPLEMENTED Vivado checkpoint by
# ethmin/export_hardblock_locs.tcl in vc707-openflow-demos.
#
# These are not a tuning preference.  Which CMT column an MMCM sits in decides
# whether a transceiver's clocks can reach it, and left to itself the placer
# put both PHY MMCMs and all six PHY clock buffers somewhere else -- the design
# configured, the CPU ran, and the Ethernet never came up because the MMCMs
# never locked.  The transceiver and the system MMCM it already agreed on.
set_property LOC BUFGCTRL_X0Y18 [get_cells clkgen.clk_mac_bufg]
set_property LOC BUFGCTRL_X0Y16 [get_cells clkgen.clk_sys_bufg]
set_property LOC MMCME2_ADV_X1Y5 [get_cells clkgen.mmcm]
set_property LOC GTXE2_CHANNEL_X1Y1 [get_cells eth.i_phy.GTXE2_CHANNEL]
set_property LOC MMCME2_ADV_X0Y6 [get_cells eth.i_phy.MMCME2_ADV]
set_property LOC MMCME2_ADV_X0Y3 [get_cells eth.i_phy.MMCME2_ADV_1]
set_property LOC BUFGCTRL_X0Y1 [get_cells eth.i_phy.bufg_ethrx125]
set_property LOC BUFGCTRL_X0Y0 [get_cells eth.i_phy.bufg_ethrx62]
set_property LOC BUFGCTRL_X0Y19 [get_cells eth.i_phy.bufg_ethtx125]
set_property LOC BUFGCTRL_X0Y17 [get_cells eth.i_phy.bufg_ethtx62]
set_property LOC BUFGCTRL_X0Y2 [get_cells eth.i_phy.bufg_rxoutrebuf]
set_property LOC BUFGCTRL_X0Y3 [get_cells eth.i_phy.bufg_txoutrebuf]
