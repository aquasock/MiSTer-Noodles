# Run against a completed fit, without rebuilding or changing project settings:
# quartus_sta -t tools/report_multicorner.tcl
proc check_report {summary corner check result} {
    if {[llength $result] != 2} {
        error "Unexpected $check result at $corner: $result"
    }
    lassign $result count slack
    if {![string is integer -strict $count] || $count < 1 ||
        ![string is double -strict $slack]} {
        error "Missing or invalid $check timing evidence at $corner: $result"
    }
    set passed [expr {$slack >= 0.0}]
    puts $summary "$corner\t$check\t$count\t$slack\t[expr {$passed ? {PASS} : {FAIL}}]"
    flush $summary
    return $passed
}

project_open Noodles -revision Noodles
create_timing_netlist
read_sdc

set out output_files/multicorner
file mkdir $out
set summary [open [file join $out summary.tsv] w]
puts $summary "corner\tcheck\treported_paths\tworst_slack_ns\tstatus"
set corners [get_available_operating_conditions]
set total [get_collection_size $corners]
if {$total == 0} {
    error "No operating conditions available for the fitted device"
}
set index 0
set failures 0
foreach_in_collection corner $corners {
    incr index
    puts "Timing corner $index/$total: $corner"
    set_operating_conditions $corner
    update_timing_netlist
    set core [get_clocks {emu|pll|*PLL_OUTPUT_COUNTER*|divclk}]
    if {[get_collection_size $core] != 1} {
        error "Expected exactly one core PLL clock at $corner"
    }
    foreach_in_collection clock $core {
        if {abs([get_clock_info -period $clock] - 10.0) > 0.001} {
            error "Core clock is not 100MHz at $corner"
        }
    }
    foreach check {setup hold recovery removal} {
        set result [report_timing -$check -npaths 20 -detail full_path \
            -file [file join $out $corner.$check.rpt]]
        if {![check_report $summary $corner $check $result]} { incr failures }
    }
    foreach check {setup hold} {
        set result [report_timing -$check -to_clock $core -npaths 10 \
            -detail full_path -file [file join $out $corner.core_$check.rpt]]
        if {![check_report $summary $corner core_$check $result]} { incr failures }
    }
    set result [report_min_pulse_width -nworst 20 \
        -file [file join $out $corner.pulse_width.rpt]]
    if {![check_report $summary $corner pulse_width $result]} { incr failures }
}
close $summary
delete_timing_netlist
project_close
if {$failures != 0} {
    error "Multi-corner timing FAILED: $failures checks have negative slack; see $out"
}
puts "Multi-corner timing PASS: all $total corners; see $out/summary.tsv"
