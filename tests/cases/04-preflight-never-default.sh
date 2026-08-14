# ipv4.never-default=no verhindert das Hochfahren.
prop ipv4.never-default "no"
run_daemon 1
assert_no_bring_up
assert_state "PREFLIGHT_FEHLER"
