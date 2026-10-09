#==============================================================================
# create_project.tcl -- build the Vivado project for the Nexys A7-100T
#
#   vivado -mode batch -source fpga/scripts/create_project.tcl
#
# Creates fpga/vivado/aes_nexys_a7.xpr from the sources in the repository.
# The project is generated, not hand-edited: every file is referenced in
# place (nothing is copied into the project), so editing rtl/ or fpga/rtl/
# changes what the project builds, and the project directory can be deleted
# and recreated at any time.
#
# Afterwards, open fpga/vivado/aes_nexys_a7.xpr in the Vivado GUI as usual, or
# run fpga/scripts/build.tcl to produce the bitstream in batch.
#==============================================================================

set root     [file normalize [file dirname [info script]]/../..]
set proj_dir $root/fpga/vivado
set part     xc7a100tcsg324-1

create_project aes_nexys_a7 $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]

# Board awareness is nice to have in the GUI but not needed for the build:
# only set it if Digilent's board files are installed.
set bp [lindex [get_board_parts -quiet -latest_file_version {*nexys-a7-100t*}] 0]
if {$bp ne ""} {
    set_property board_part $bp [current_project]
    puts "Board part: $bp"
} else {
    puts "Digilent board files not installed -- using part $part only (fine)"
}

#------------------------------------------------------------------------------
# Design sources: the shared AES cores plus the board wrapper
#------------------------------------------------------------------------------
add_files -norecurse -fileset sources_1 [list \
    $root/rtl/aes_sbox.v \
    $root/rtl/aes_round.v \
    $root/rtl/aes_key_expand.v \
    $root/rtl/aes128_iterative.v \
    $root/rtl/aes128_iterative_ii10.v \
    $root/rtl/aes128_pipelined.v \
    $root/fpga/rtl/uart_rx.v \
    $root/fpga/rtl/uart_tx.v \
    $root/fpga/rtl/byte_fifo.v \
    $root/fpga/rtl/aes_engine.v \
    $root/fpga/rtl/aes_uart_bridge.v \
    $root/fpga/rtl/seg7_ctrl.v \
    $root/fpga/rtl/xadc_mon.v \
    $root/fpga/rtl/nexys_a7_top.v \
]
set_property top nexys_a7_top [get_filesets sources_1]

#------------------------------------------------------------------------------
# Constraints
#------------------------------------------------------------------------------
add_files -norecurse -fileset constrs_1 $root/fpga/constr/nexys_a7_100t.xdc
set_property target_constrs_file $root/fpga/constr/nexys_a7_100t.xdc \
    [current_fileset -constrset]

#------------------------------------------------------------------------------
# Simulation: board-level testbench (Flow > Run Simulation in the GUI)
#------------------------------------------------------------------------------
add_files -norecurse -fileset sim_1 $root/fpga/tb/tb_nexys_a7_top.v
set_property top tb_nexys_a7_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} \
    -value "-testplusarg vectors=$root/tb/vectors/aes128_vectors.txt" \
    -objects [get_filesets sim_1]

#------------------------------------------------------------------------------
# Runs: default strategies, timing-driven implementation
#------------------------------------------------------------------------------
set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]

puts "\nProject created: $proj_dir/aes_nexys_a7.xpr"
close_project
