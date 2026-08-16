#==============================================================================
# aes_core_ooc.xdc -- out-of-context constraints for the AES-128 cores
#
# Used for synthesis/implementation of a core on its own, which is how you get
# a meaningful Fmax number for the datapath without a board wrapper diluting it.
#
#   synth_design -mode out_of_context -top aes128_iterative_ii10 ...
#
# The 2.600 ns period is the project target (384.6 MHz). Tighten it until
# setup fails to find the real Fmax of a given core -- see
# sim/run_vivado_synth.tcl, which sweeps this automatically.
#==============================================================================

create_clock -period 2.600 -name clk [get_ports clk]

# I/O budget: assume the surrounding logic gives us half a clock either side.
# Adjust to match the real wrapper; these only affect the I/O paths, not the
# internal round-to-round timing that determines Fmax.
set_input_delay  -clock clk 1.300 \
    [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -clock clk 1.300 [all_outputs]

# Note: rst_n is deliberately left as a timed synchronous input. The cores use
# a synchronous reset, so declaring a false path on it would hide a real
# recovery/removal problem rather than fix one.
