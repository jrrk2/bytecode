# Vivado build of vc707_ethmin_vm: the OCaml VM running io/ethmin.ml with
# ethmin's SGMII Ethernet.  The MAC, PCS/PMA, DMA and clocking come from
# xc7-bitstream-tools (examples/vc707-ethmin/rtl, $XC7BT, default
# ~/xc7-bitstream-tools).  First make the program images:
#   tools/progimage.sh io/ethmin.ml fpga/vc707-ethmin
# then, from a work directory:
#   vivado -mode batch -source <repo>/fpga/vc707-ethmin/build.tcl
# Reports and vc707_ethmin_vm.bit go to ./out.
set part xc7vx485tffg1761-2
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
if {[info exists ::env(XC7BT)]} { set xc7bt $::env(XC7BT) } else { set xc7bt $::env(HOME)/xc7-bitstream-tools }
set eth $xc7bt/examples/vc707-ethmin/rtl
file mkdir out
# $readmemh resolves against the working directory
foreach f {program.hex heap.hex globals.hex} { file copy -force $here/$f . }

read_verilog -sv $repo/ocaml4142_vm_rtl.sv
read_verilog [list $here/ethmin_vm_core.v $here/vc707_ethmin_vm.v $eth/simpleuart.v $eth/liteeth_sgmii_phy.v]
read_verilog -sv [list $eth/eth_mac_1g.sv $eth/axis_gmii_rx.sv $eth/axis_gmii_tx.sv $eth/rgmii_lfsr.sv \
    $eth/eth_lutram_fifo.sv $eth/eth_stream_dma.sv $eth/eth_gmii_retime256.sv $eth/eth_pkt_buf256.sv \
    $eth/sgmii_soc_liteeth.sv $eth/clkgen_vc707.sv]
read_xdc $here/vc707_ethmin_vm.xdc
synth_design -top vc707_ethmin_vm -part $part -include_dirs [list $repo $here] -verilog_define SYNTHESIS
report_utilization -file out/util_synth.rpt
opt_design
place_design
route_design
report_timing_summary -max_paths 10 -file out/timing.rpt
report_utilization -file out/util.rpt
report_methodology -file out/methodology.rpt
report_drc -file out/drc.rpt
report_cdc -file out/cdc.rpt
write_bitstream -force out/vc707_ethmin_vm.bit
puts "ETHMIN_VM_BUILD_DONE"
