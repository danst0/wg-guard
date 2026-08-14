# Uebernimmt der Tunnel nach dem Hochfahren die Default-Route, geht er sofort
# wieder herunter - ohne Toleranz und ohne die weiteren Stufen zu versuchen.
scen hijack_on_up "1"
run_daemon 1
assert_log_contains 'nmcli .*connection up' "Es wurde hochgefahren"
assert_log_contains 'nmcli connection down' "Es muss sofort heruntergefahren werden"
assert_log_missing '^nc ' "Stufe 5 darf nach einer Sicherheitsverletzung nicht laufen"
assert_output_contains "$(daemon_output)" "Sicherheitsverletzung" "Der Grund muss im Log stehen"
