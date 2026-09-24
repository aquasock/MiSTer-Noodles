# Run in a compiled project directory:
# quartus_sta -t tools/report_timing.tcl
project_open Noodles -revision Noodles
create_timing_netlist
read_sdc
update_timing_netlist

report_clocks -file output_files/Noodles.clocks.rpt
set core_clocks [get_clocks {emu|pll|*PLL_OUTPUT_COUNTER*|divclk}]
if {[get_collection_size $core_clocks] != 1} {
    error "Expected exactly one core PLL clock"
}
foreach_in_collection clock $core_clocks {
    if {abs([get_clock_info -period $clock] - 10.0) > 0.001} {
        error "Core clock is not 100MHz"
    }
}

report_timing -setup -npaths 20 -detail full_path \
    -file output_files/Noodles.paths.setup.rpt
report_timing -hold -npaths 20 -detail full_path \
    -file output_files/Noodles.paths.hold.rpt

set ingress [get_registers {*|ddram_adapter:ddram_adapter|wr_ingress*}]
set slots [get_registers {*|ddram_adapter:ddram_adapter|wr_slot_en*}]
set writeq [get_registers {*|ddram_adapter:ddram_adapter|wr_*_q*}]
if {[get_collection_size $ingress] == 0 || [get_collection_size $slots] == 0 ||
    [get_collection_size $writeq] == 0} {
    error "Write ingress or registered queue-slot enables are missing"
}
report_timing -setup -npaths 10 -detail full_path -to $ingress \
    -file output_files/Noodles.paths.ingress.rpt
report_timing -setup -npaths 10 -detail full_path -from $ingress -to $writeq \
    -file output_files/Noodles.paths.ingress_to_queue.rpt
report_timing -setup -npaths 10 -detail full_path -from $slots -to $writeq \
    -file output_files/Noodles.paths.slots_to_queue.rpt

# Include the live DDR3 bridge paths even when they are not the worst overall.
report_timing -setup -npaths 10 -detail full_path \
    -from [get_registers {*f2sdram*}] -to [get_registers {*f2sdram*}] \
    -file output_files/Noodles.paths.ddr3.rpt
delete_timing_netlist
project_close
