# Ein veralteter Handshake bedeutet: die Gegenstelle antwortet nicht.
scen handshake_ts "-99999"
run_daemon 1
assert_log_contains 'nmcli .*connection up' "Es wurde hochgefahren"
assert_log_contains 'nmcli connection down' "Danach muss heruntergefahren werden"
assert_state "BACKOFF"
assert_eq "$(state_of LAST_FAIL_STAGE)" "3" "Stufe 3 als Fehlerquelle"
