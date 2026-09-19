# Vivado reference build of the VC707 VM harness, reading the VM's original
# SystemVerilog (not the sv2v copy apio synthesises).  Run ../vc707/gen.sh
# first, then from a work directory:
#   vivado -mode batch -source <repo>/fpga/vc707-vivado/build.tcl
# Reports and vc707_vm.bit go to ./out.
set part xc7vx485tffg1761-2
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
set proj $repo/fpga/vc707
file mkdir out
# $readmemh resolves against the working directory
foreach f {program.hex heap.hex globals.hex} { file copy -force $proj/$f . }
read_verilog -sv $repo/ocaml4142_vm_rtl.sv
read_verilog [list $proj/vc707_vm_top.v $proj/simpleuart.v]
read_xdc $proj/vc707.xdc
synth_design -top vc707_vm_top -part $part -include_dirs [list $repo $proj] -verilog_define SYNTHESIS
report_utilization -file out/util_synth.rpt
opt_design
place_design
route_design
report_timing_summary -max_paths 10 -file out/timing.rpt
report_utilization -file out/util.rpt
report_methodology -file out/methodology.rpt
report_drc -file out/drc.rpt
report_clock_utilization -file out/clocks.rpt
write_bitstream -force out/vc707_vm.bit
puts "VM_VIVADO_BUILD_DONE"
