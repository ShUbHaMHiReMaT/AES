#==============================================================================
# build_smoke.tcl -- bitstream for the first-power-up check (about 2 minutes)
#
#   vivado -mode batch -source fpga/smoke/build_smoke.tcl
#   vivado -mode batch -source fpga/scripts/program.tcl -tclargs fpga/build/smoke.bit
#==============================================================================

set root   [file normalize [file dirname [info script]]/../..]
set outdir $root/fpga/build
file mkdir $outdir

read_verilog [list \
    $root/fpga/rtl/uart_rx.v \
    $root/fpga/rtl/uart_tx.v \
    $root/fpga/smoke/smoke_top.v \
]
read_xdc $root/fpga/smoke/smoke.xdc

synth_design -top smoke_top -part xc7a100tcsg324-1
opt_design
place_design
route_design

report_utilization    -file $outdir/smoke_utilization.rpt
report_timing_summary -file $outdir/smoke_timing.rpt
report_drc            -file $outdir/smoke_drc.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts [format "\nSMOKE: %d LUT, %d FF, WNS %.3f ns, WHS %.3f ns" \
    [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] \
    [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]] \
    $wns $whs]
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met"
    exit 1
}

write_bitstream -force $outdir/smoke.bit
puts "Bitstream: $outdir/smoke.bit"
