# Vivado build of vc707_ethmin_vm: the OCaml VM running io/ethmin.ml with
# ethmin's SGMII Ethernet.  The MAC, PCS/PMA, DMA and clocking are in
# fpga/eth-rtl (see its README for where each file came from).  First make
# the program images:
#   tools/progimage.sh io/ethmin.ml fpga/vc707-ethmin
# then, from a work directory:
#   vivado -mode batch -source <repo>/fpga/vc707-ethmin/build.tcl
# Reports and vc707_ethmin_vm.bit go to ./out.
set part xc7vx485tffg1761-2
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
set eth $repo/fpga/eth-rtl
file mkdir out
# $readmemh resolves against the working directory
foreach f {program.hex heap.hex globals.hex} { file copy -force $here/$f . }

read_verilog -sv $repo/ocaml4142_vm_rtl.sv
read_verilog [list $here/program_bram.v $here/ethmin_vm_core.v $here/vc707_ethmin_vm.v $eth/simpleuart.v $eth/liteeth_sgmii_phy.v]
read_verilog -sv [list $eth/eth_mac_1g.sv $eth/axis_gmii_rx.sv $eth/axis_gmii_tx.sv $eth/rgmii_lfsr.sv \
    $eth/eth_lutram_fifo.sv $eth/eth_stream_dma.sv $eth/eth_gmii_retime256.sv $eth/eth_pkt_buf256.sv \
    $eth/sgmii_soc_liteeth.sv $eth/clkgen_vc707.sv]
read_xdc $here/vc707_ethmin_vm.xdc
# $VM_DEFS adds Verilog defines, for a build that differs only by a macro:
#   VM_DEFS="SYS_DIV=16.000 CLK_HZ=62500000" vivado -mode batch -source build.tcl
# builds the 62.5 MHz variant the open flow runs at, which is how to tell a
# fault of the frequency from a fault of the flow.
set defs [list SYNTHESIS]
if {[info exists env(VM_DEFS)]} { lappend defs {*}$env(VM_DEFS) }
# Who built this bitstream, for the banner: the commit, a dirty bit, and the
# flow (2 = Vivado).  0x100a reads it back.
set commit [string trim [exec git -C $repo rev-parse --short=7 HEAD]]
set dirty 0
if {[catch {exec git -C $repo diff --quiet HEAD --}]} { set dirty 1 }
# The flow bits put the value past 2^31, which this Tcl's format will not
# take, so the word is spelled out: one nibble for flow 2 and the dirty
# bit, then the seven digits of the commit -- eight digits in all, or the
# top bits fall off the 32-bit constant and the flow reads as unsaid.
set build_id [format "32'h%x%s" [expr {8 + $dirty}] $commit]
lappend defs "BUILD_ID=$build_id"
puts "build id $build_id (commit $commit, dirty $dirty, Vivado)"
synth_design -top vc707_ethmin_vm -part $part -include_dirs [list $repo $here] -verilog_define $defs
report_utilization -file out/util_synth.rpt
opt_design
place_design
# Physical optimisation, which this flow used to skip entirely: retiming moves
# registers across logic now that placement knows the real delays, and the
# post-route pass fixes what is left.  Worth about a nanosecond at 100 MHz,
# where the design has little to spare.
phys_opt_design -directive AggressiveExplore
route_design
phys_opt_design -directive AggressiveExplore
report_timing_summary -max_paths 10 -file out/timing.rpt
report_utilization -file out/util.rpt
report_methodology -file out/methodology.rpt
report_drc -file out/drc.rpt
report_cdc -file out/cdc.rpt
write_bitstream -force out/vc707_ethmin_vm.bit
puts "ETHMIN_VM_BUILD_DONE"
