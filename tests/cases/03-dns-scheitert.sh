# Loest der Endpunkt nicht auf, wird gar nicht erst hochgefahren.
scen dns_rc "2"
run_daemon 1
assert_no_bring_up
assert_state "BACKOFF"
assert_eq "$(state_of LAST_FAIL_STAGE)" "1" "Stufe 1 muss als Fehlerquelle vermerkt sein"
