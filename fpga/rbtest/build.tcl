# Vivado build of vc707_rbtest, the readback oracle: which bits move when
# the flip-flops do, and where the CFG_CENTER_MID frames are.
#   cd <work>; vivado -mode batch -source <repo>/fpga/rbtest/build.tcl
set part xc7vx485tffg1761-2
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
set eth $repo/fpga/eth-rtl
file mkdir out
read_verilog [list $here/vc707_rbtest.v]
read_verilog -sv [list $eth/clkgen_vc707.sv]
read_xdc $here/vc707_rbtest.xdc
synth_design -top vc707_rbtest -part $part -verilog_define SYNTHESIS
opt_design
place_design
route_design
report_timing_summary -file out/timing.rpt
write_bitstream -force -logic_location_file out/vc707_rbtest.bit
write_checkpoint -force out/routed.dcp
puts "RBTEST_BUILD_DONE"
