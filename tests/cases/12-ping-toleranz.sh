# Ein einzelner verlorener Ping reisst den gesunden Tunnel nicht ab,
# zwei aufeinanderfolgende schon (HEALTH_FAILURES_BEFORE_DOWN=2).
printf '0 1 1\n' > "$SCEN/ping_rc_sequence"
run_daemon 3
assert_state "BACKOFF"
assert_log_contains 'nmcli connection down' "Nach zwei Fehlschlaegen muss heruntergefahren werden"
assert_eq "$(state_of LAST_FAIL_STAGE)" "4" "Stufe 4 als Fehlerquelle"
