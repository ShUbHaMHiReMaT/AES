#==============================================================================
# build_seg7.tcl -- bitstream for the web-page-to-7-segment demo (~2 minutes)
#
#   vivado -mode batch -source fpga/demo7seg/build_seg7.tcl
#
# Same pins as the smoke test, so it reuses fpga/smoke/smoke.xdc.
#==============================================================================

set root   [file normalize [file dirname [info script]]/../..]
set outdir $root/fpga/build
file mkdir $outdir

read_verilog [list \
    $root/fpga/rtl/uart_rx.v \
    $root/fpga/rtl/uart_tx.v \
    $root/fpga/demo7seg/seg7_text_top.v \
]
read_xdc $root/fpga/smoke/smoke.xdc

synth_design -top seg7_text_top -part xc7a100tcsg324-1
opt_design
place_design
route_design

report_utilization    -file $outdir/seg7_utilization.rpt
report_timing_summary -file $outdir/seg7_timing.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts [format "\nSEG7: %d LUT, %d FF, WNS %.3f ns, WHS %.3f ns" \
    [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] \
    [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]] \
    $wns $whs]
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met"
    exit 1
}

write_bitstream -force $outdir/seg7_text.bit
puts "Bitstream: $outdir/seg7_text.bit"
