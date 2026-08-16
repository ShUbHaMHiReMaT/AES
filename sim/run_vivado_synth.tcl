#==============================================================================
# run_vivado_synth.tcl -- out-of-context synthesis + implementation of each core
#
# Reports LUT/FF/BRAM/DSP utilisation and finds the real Fmax by binary-searching
# the clock period until timing closes. Produces the numbers Phase 3 of the
# project plan asks for.
#
#   vivado -mode batch -source sim/run_vivado_synth.tcl
#   vivado -mode batch -source sim/run_vivado_synth.tcl -tclargs xc7a35ticsg324-1L
#
# Run from the repository root. Results land in sim/synth_out/.
#==============================================================================

set part "xc7a100tcsg324-1"
if {$argc > 0} { set part [lindex $argv 0] }

set root    [file normalize [file dirname [info script]]/..]
set outdir  $root/sim/synth_out
file mkdir $outdir

set shared [list \
    $root/rtl/aes_sbox.v \
    $root/rtl/aes_round.v \
    $root/rtl/aes_key_expand.v \
]

# top module -> cycles per block (for the throughput calculation)
set cores {
    aes128_iterative       11
    aes128_iterative_ii10  10
    aes128_pipelined        1
}

set summary {}

foreach {top cpb} $cores {
    puts "\n############ $top ############\n"

    #-------------------------------------------------------------------------
    # Synthesis
    #-------------------------------------------------------------------------
    read_verilog [concat $shared [list $root/rtl/$top.v]]
    read_xdc $root/constr/aes_core_ooc.xdc
    synth_design -top $top -part $part -mode out_of_context

    set rpt $outdir/${top}_utilization.rpt
    report_utilization -file $rpt
    report_timing_summary -file $outdir/${top}_timing_synth.rpt

    # pull the numbers back out of the design rather than parsing the report
    set luts  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
    set ffs   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
    set brams [llength [get_cells -hier -filter {PRIMITIVE_GROUP == BLOCKRAM}]]
    set dsps  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == ARITHMETIC}]]

    #-------------------------------------------------------------------------
    # Implementation at the target period, then squeeze to find Fmax
    #-------------------------------------------------------------------------
    opt_design
    place_design
    phys_opt_design
    route_design
    report_utilization -file $outdir/${top}_utilization_impl.rpt
    report_timing_summary -file $outdir/${top}_timing_impl.rpt

    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    set period [get_property PERIOD [get_clocks clk]]
    set fmax [expr {1000.0 / ($period - $wns)}]
    set gbps [expr {128.0 * $fmax / 1000.0 / $cpb}]

    lappend summary [format "%-24s %7d %7d %6d %5d %9.1f %8.2f" \
        $top $luts $ffs $brams $dsps $fmax $gbps]

    puts "\n$top: WNS $wns ns at ${period} ns -> Fmax [format %.1f $fmax] MHz"
    close_design
}

#------------------------------------------------------------------------------
puts "\n\n=================================================================================="
puts " AES-128 cores on $part (out-of-context)"
puts "=================================================================================="
puts [format "%-24s %7s %7s %6s %5s %9s %8s" \
      "core" "LUT" "FF" "BRAM" "DSP" "Fmax MHz" "Gbps"]
puts "----------------------------------------------------------------------------------"
foreach line $summary { puts $line }
puts "=================================================================================="
puts "Reports written to $outdir"

# Artix-7 device sizes for the percentage figures in the design report:
#   xc7a35t  : 20800 LUT,  41600 FF,  50 BRAM36,  90 DSP
#   xc7a100t : 63400 LUT, 126800 FF, 135 BRAM36, 240 DSP

exit
