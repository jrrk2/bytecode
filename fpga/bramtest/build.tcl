# Vivado build of vc707_bramtest -- the reference.  Every shape must pass
# here; a shape that passes here and fails in the open flow names a toolchain
# bug, which is the whole point of this design.
#
#   cd <work dir>; vivado -mode batch -source <repo>/fpga/bramtest/build.tcl
set part xc7vx485tffg1761-2
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
file mkdir out

read_verilog [list $here/bramtest.v $here/vc707_bramtest.v \
    $repo/fpga/eth-rtl/simpleuart.v]
read_verilog -sv $repo/fpga/eth-rtl/clkgen_vc707.sv
read_xdc $here/vc707_bramtest.xdc
synth_design -top vc707_bramtest -part $part -include_dirs [list $here]
opt_design
place_design
route_design
report_timing_summary -max_paths 5 -file out/timing.rpt
report_utilization -file out/util.rpt
write_bitstream -force out/vc707_bramtest.bit
puts "BRAMTEST_BUILD_DONE"
