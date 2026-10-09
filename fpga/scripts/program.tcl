#==============================================================================
# program.tcl -- load the bitstream into the Nexys A7 over USB-JTAG
#
#   vivado -mode batch -source fpga/scripts/program.tcl
#   vivado -mode batch -source fpga/scripts/program.tcl -tclargs path/to.bit
#
# Volatile: the FPGA forgets the design at power-off. The board's power switch
# must be ON and the USB cable in the PROG/UART port (J6).
#==============================================================================

set root [file normalize [file dirname [info script]]/../..]
set bit  $root/fpga/build/aes_nexys_a7.bit
if {$argc > 0} { set bit [file normalize [lindex $argv 0]] }

if {![file exists $bit]} {
    puts "ERROR: $bit not found -- run fpga/scripts/build.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag

set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts "ERROR: no JTAG cable found. Check: USB in the PROG/UART port,"
    puts "       power switch ON, and the Digilent cable driver installed."
    exit 1
}
current_hw_target [lindex $targets 0]
open_hw_target

set dev [lindex [get_hw_devices -quiet xc7a100t*] 0]
if {$dev eq ""} {
    puts "ERROR: no xc7a100t on the JTAG chain; found: [get_hw_devices]"
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev

if {[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev] == 1} {
    puts "\nPROGRAMMED: $bit -> $dev (DONE pin high)"
} else {
    puts "\nERROR: DONE pin did not go high"
    exit 1
}

close_hw_target
disconnect_hw_server
close_hw_manager
