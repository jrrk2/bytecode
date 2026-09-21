# Place and route yosys's own netlist in Vivado, to split the open flow in two.
#
# The open flow's bitstream misbehaves on the board while every check upstream
# passes: LVS proves 15668 cells equivalent, the memory contents in the
# bitstream match synthesis row for row, and the width markers now match
# Vivado's.  Either yosys is emitting a netlist that does not mean what the
# RTL says, or nextpnr/prjxray are implementing that netlist wrongly.
#
# This reads the SAME netlist yosys handed to nextpnr -- as EDIF, so Vivado
# links the cells rather than re-elaborating them -- and lets Vivado place,
# route and assemble it.  The resulting bitstream answers the question:
#
#   it works    -> yosys's netlist is right; the fault is downstream of it
#   it fails    -> the netlist is wrong, and synthesis is where to look
#
#   yosys -p 'read_json design.json; delete t:$print; delete t:$scopeinfo; \
#             write_edif -pvector bra design.edif'
#   vivado -mode batch -source fpga/vc707-ethmin/vivado_pnr_edif.tcl \
#          -tclargs <design.edif> <constraints.xdc> <outdir> <top> [part]
set netlist [lindex $argv 0]
set xdc     [lindex $argv 1]
set outdir  [lindex $argv 2]
set top     [lindex $argv 3]
set part    [expr {[llength $argv] > 4 ? [lindex $argv 4] : "xc7vx485tffg1761-2"}]

file mkdir $outdir
create_project -force -in_memory -part $part
read_edif $netlist
read_xdc $xdc
# link_design, not synth_design: re-synthesising would change the cells and
# the experiment would no longer hold synthesis fixed.
link_design -top $top -part $part
puts "=== cells after link: [llength [get_cells -hier]]"

opt_design
place_design
route_design
report_timing_summary -max_paths 10 -file $outdir/timing.rpt
report_utilization                  -file $outdir/utilization.rpt
report_route_status                 -file $outdir/route_status.rpt
write_bitstream -force $outdir/design.bit
write_checkpoint -force $outdir/routed.dcp

# Every net's routed delay, driver pin -> each load pin, as the oracle for
# the extractor's own delay model (fasm2netlist's STA sums the database's
# per-pip delays along the route it recovers from the bitstream; these are
# what those sums should come to).  Net names are yosys's, the same names
# the extraction carries, so the two line up without a map.
set fh [open $outdir/net_delays.csv w]
puts $fh "net,from,to,fast_min,fast_max,slow_min,slow_max"
foreach n [get_nets -hierarchical -filter {TYPE != POWER && TYPE != GROUND}] {
    foreach d [get_net_delays -of_objects $n -quiet] {
        set f [get_pins -of_objects $d -filter {DIRECTION == OUT} -quiet]
        set t [get_pins -of_objects $d -filter {DIRECTION == IN} -quiet]
        puts $fh "[get_property NAME $n],[get_property NAME $f],[get_property NAME $t],[get_property FAST_MIN $d],[get_property FAST_MAX $d],[get_property SLOW_MIN $d],[get_property SLOW_MAX $d]"
    }
}
close $fh
puts "NETLIST_PNR_DONE"
