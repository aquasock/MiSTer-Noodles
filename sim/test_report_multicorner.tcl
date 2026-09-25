# Pure Tcl control-flow regression; actual timing still requires a fitted DB.
set script [file normalize [file join [file dirname [info script]] \
    .. tools report_multicorner.tcl]]
set work [file normalize [file join [file dirname [info script]] \
    .. build test-report-multicorner]]
file mkdir $work
cd $work

proc project_open {args} {}
proc project_close {} {}
proc create_timing_netlist {} {}
proc delete_timing_netlist {} {}
proc read_sdc {} {}
proc update_timing_netlist {} {}
proc get_available_operating_conditions {} {
    if {$::scenario eq "no-corners"} { return {} }
    return {slow_hot slow_cold fast_hot fast_cold}
}
proc get_collection_size {collection} { return [llength $collection] }
proc foreach_in_collection {var collection body} {
    uplevel 1 [list foreach $var $collection $body]
}
proc set_operating_conditions {corner} { lappend ::visited $corner }
proc get_clocks {args} {
    if {$::scenario eq "no-core"} { return {} }
    if {$::scenario eq "two-cores"} { return {core extra} }
    return core
}
proc get_clock_info {args} {
    if {$::scenario eq "wrong-frequency"} { return 10.0 }
    return [expr {1000.0 / 120.0}]
}
proc mock_report {check count} {
    if {$::scenario eq "negative-$check"} { return [list $count -0.001] }
    if {$::scenario eq "empty-report"} { return {0 0.0} }
    if {$::scenario eq "malformed-report"} { return {invalid} }
    return [list $count 0.081]
}
proc report_timing {args} {
    set check [string range [lindex $args 0] 1 end]
    if {[lsearch -exact $args -to_clock] >= 0} { set check core_$check }
    return [mock_report $check 20]
}
proc report_min_pulse_width {args} { return [mock_report pulse_width 20] }

foreach scenario {pass negative-setup negative-hold negative-recovery
    negative-removal negative-core_setup negative-core_hold
    negative-pulse_width empty-report malformed-report no-corners
    no-core two-cores wrong-frequency} {
    set visited {}
    set failed [catch {source $script} message]
    # A missing-evidence error can leave a partial summary open.
    if {[info exists summary] && [lsearch -exact [file channels] $summary] >= 0} {
        close $summary
    }
    if {$scenario eq "pass"} {
        if {$failed} { error "Valid reports rejected: $message" }
        set f [open output_files/multicorner/summary.tsv r]
        set rows [split [string trim [read $f]] \n]
        close $f
        if {[llength $rows] != 29} { error "Expected header and 28 timing rows" }
    } else {
        if {!$failed} { error "Invalid evidence accepted: $scenario" }
        if {[string match negative-* $scenario]} {
            if {![string match {*checks have negative slack*} $message]} {
                error "Unexpected failure for $scenario: $message"
            }
        } elseif {![string match {*timing evidence*} $message] &&
                  ![string match {*Unexpected*result*} $message] &&
                  ![string match {*operating conditions*} $message] &&
                  ![string match {*core PLL clock*} $message] &&
                  ![string match {*not 120MHz*} $message]} {
            error "Unexpected failure for $scenario: $message"
        }
    }
    if {$scenario eq "pass" || [string match negative-* $scenario]} {
        if {[llength $visited] != 4} { error "Did not analyze every corner" }
    }
}
puts "PASS: multi-corner reporting, negative slack, missing evidence and clock guards"
