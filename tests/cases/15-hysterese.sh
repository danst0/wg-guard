# Nach mehreren Fehlschlaegen im Fenster folgt eine lange Ruhephase, damit
# nicht endlos gegen eine tote Gegenstelle gelaufen wird.
cfg BACKOFF_MAX 10
scen dns_rc "2"
run_daemon 10
assert_state "COOLDOWN"
assert_no_bring_up
assert_true test "$(state_of BACKOFF)" -ge 3600 "Die Ruhephase muss deutlich laenger sein"
