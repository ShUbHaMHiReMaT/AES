#==============================================================================
# build.tcl -- synthesise, implement and write the bitstream
#
#   vivado -mode batch -source fpga/scripts/build.tcl
#
# Runs synth_1 and impl_1 of fpga/vivado/aes_nexys_a7.xpr (creating the
# project first if it does not exist), then pulls the numbers worth keeping
# into fpga/build/: utilisation per core, timing summary, and the bitstream.
# Fails if timing is not met, so a bitstream that exists is one that closed.
#==============================================================================

set root   [file normalize [file dirname [info script]]/../..]
set xpr    $root/fpga/vivado/aes_nexys_a7.xpr
set outdir $root/fpga/build
set jobs   6

# always regenerate: the project is derived from the sources, so this picks
# up added or removed files and can never drift from the repository
source $root/fpga/scripts/create_project.tcl
open_project $xpr
file mkdir $outdir

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: synthesis failed -- see [get_property DIRECTORY [get_runs synth_1]]/runme.log"
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: implementation failed -- see [get_property DIRECTORY [get_runs impl_1]]/runme.log"
    exit 1
}

#------------------------------------------------------------------------------
# Reports from the routed design
#------------------------------------------------------------------------------
open_run impl_1
report_utilization                -file $outdir/utilization.rpt
report_utilization -hierarchical  -file $outdir/utilization_hier.rpt
report_timing_summary -max_paths 10 -file $outdir/timing_summary.rpt
report_power                      -file $outdir/power.rpt
report_drc                        -file $outdir/drc.rpt

set period 10.0
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
set fmax [expr {1000.0 / ($period - $wns)}]

# per-core figures, read from the routed design rather than estimated
proc cell_count {inst group} {
    llength [get_cells -hier -quiet -filter "NAME =~ $inst/* && PRIMITIVE_GROUP == $group"]
}
# worst setup slack of any path ending inside the core
proc core_slack {inst} {
    set ends [get_cells -hier -quiet -filter "NAME =~ $inst/* && IS_SEQUENTIAL"]
    if {[llength $ends] == 0} { return 0.0 }
    return [get_property SLACK [get_timing_paths -quiet -max_paths 1 -delay_type max -to $ends]]
}

set luts_total [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ffs_total  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set bram_total [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == BLOCKRAM}]]
set dsp_total  [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == ARITHMETIC}]]

# Vivado's power estimate for this placement (vectorless, default activity)
set pwr [report_power -return_string]
proc pwr_field {text label} {
    if {[regexp "$label\[^|\]*\\|\\s*(\[0-9.\]+)" $text -> v]} { return $v }
    return 0
}
set p_total   [pwr_field $pwr {Total On-Chip Power \(W\)}]
set p_dynamic [pwr_field $pwr {Dynamic \(W\)}]
set p_static  [pwr_field $pwr {Device Static \(W\)}]

puts "\n=========================================================================="
puts " Nexys A7-100T (xc7a100tcsg324-1) -- routed design"
puts "=========================================================================="
puts [format " %-26s %8s %8s %10s %10s" "block" "LUT" "FF" "slack ns" "Fmax MHz"]
puts " --------------------------------------------------------------------------"
set cores_json {}
foreach {key name inst} {
    iterative  "aes128_iterative"       u_engine/u_iter
    ii10       "aes128_iterative_ii10"  u_engine/u_ii10
    pipelined  "aes128_pipelined"       u_engine/u_pipe
    bridge     "UART bridge"            u_bridge
} {
    set l [cell_count $inst LUT]
    set f [cell_count $inst FLOP_LATCH]
    set s [core_slack $inst]
    set fm [expr {1000.0 / ($period - $s)}]
    puts [format " %-26s %8d %8d %10.3f %10.1f" $name $l $f $s $fm]
    lappend cores_json [format {"%s": {"name": "%s", "lut": %d, "ff": %d, "slack_ns": %.3f, "fmax_mhz": %.1f}} \
        $key $name $l $f $s $fm]
}
puts [format " %-26s %8d %8d" "whole design" $luts_total $ffs_total]
puts " --------------------------------------------------------------------------"
puts [format " WNS %.3f ns   WHS %.3f ns   at 100 MHz" $wns $whs]
puts [format " Fmax implied by worst path: %.1f MHz (this build's placement)" $fmax]
puts [format " Power estimate: %s W total (%s W dynamic, %s W static)" $p_total $p_dynamic $p_static]
puts "=========================================================================="

# numbers for the web page
set fh [open $root/fpga/web/build_info.json w]
puts $fh "{"
puts $fh "  \"part\": \"xc7a100tcsg324-1\","
puts $fh "  \"built\": \"[clock format [clock seconds] -format {%Y-%m-%d %H:%M}]\","
puts $fh "  \"clock_mhz\": 100,"
puts $fh "  \"device\": {\"lut\": 63400, \"ff\": 126800, \"bram\": 135, \"dsp\": 240},"
puts $fh "  \"total\": {\"lut\": $luts_total, \"ff\": $ffs_total, \"bram\": $bram_total, \"dsp\": $dsp_total},"
puts $fh [format "  \"timing\": {\"wns_ns\": %.3f, \"whs_ns\": %.3f, \"fmax_mhz\": %.1f}," $wns $whs $fmax]
puts $fh "  \"power_w\": {\"total\": $p_total, \"dynamic\": $p_dynamic, \"static\": $p_static},"
puts $fh "  \"cores\": {[join $cores_json {, }]}"
puts $fh "}"
close $fh
puts "Build info: $root/fpga/web/build_info.json"

set bit [glob -nocomplain [get_property DIRECTORY [get_runs impl_1]]/*.bit]
if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met -- not exporting a bitstream"
    exit 1
}
file copy -force $bit $outdir/aes_nexys_a7.bit
puts "Bitstream: $outdir/aes_nexys_a7.bit"
close_project
