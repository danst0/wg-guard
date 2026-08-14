# Der gesunde Fall: alle Stufen bestehen, der Tunnel bleibt oben.
run_daemon 2
assert_state "GESUND"
assert_log_contains 'nmcli .*connection up' "Der Tunnel muss hochgefahren werden"
assert_log_contains 'wg show' "Der Handshake muss geprueft werden"
assert_log_contains '^ping ' "Stufe 4 muss laufen"
assert_log_contains '^nc ' "Stufe 5 muss laufen"
assert_eq "$(state_of TUNNEL)" "up" "Tunnel laut Zustandsdatei oben"
assert_eq "$(state_of LAST_STAGE_OK)" "5" "Alle fuenf Stufen bestanden"
