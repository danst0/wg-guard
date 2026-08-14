# Der gesunde Full-Tunnel: die Default-Route gehoert hier dem Tunnel, und
# genau das ist der Normalzustand - nicht der Fehler wie im Split-Modus.
sandbox_full_tunnel
run_daemon 2
assert_state "GESUND"
assert_log_contains 'nmcli .*connection up' "Der Tunnel muss hochgefahren werden"
assert_log_contains '^ping .*1\.1\.1\.1' "Stufe 6 muss das externe Ziel pruefen"
assert_eq "$(state_of LAST_STAGE_OK)" "6" "Bis Stufe 6 muss alles bestehen"
