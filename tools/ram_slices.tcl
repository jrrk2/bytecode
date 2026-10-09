# vivado -mode batch -source tools/ram_slices.tcl -tclargs out/routed.dcp out/ram_slices.txt
# The table build.tcl now writes itself, for a build made before it did.
open_checkpoint [lindex $argv 0]
set fp [open [lindex $argv 1] w]
foreach c [get_cells -hier -filter {REF_NAME =~ RAMB*}] {
    puts $fp "[get_property NAME $c] [get_property LOC $c] [get_property REF_NAME $c] [get_property RAM_SLICE_BEGIN $c] [get_property RAM_SLICE_END $c] [get_property RAM_ADDR_BEGIN $c] [get_property RAM_ADDR_END $c]"
}
close $fp
