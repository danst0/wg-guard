# status und check muessen ohne Vorwissen verstaendlich sein - und check darf
# den Tunnel unter keinen Umstaenden anfassen.
run_daemon 2
run_cli status
assert_output_contains "$(cli_output)" "GESUND" "Der Zustand muss erscheinen"
assert_output_contains "$(cli_output)" "Tunnel ist oben und geprueft" "Mit Erklaerung im Klartext"

# Nach einem Fehlschlag muss status die gescheiterte Stufe und den Grund nennen.
scen nm_active "0"
scen link_exists "0"
scen dns_rc "2"
run_daemon 1
run_cli status
assert_output_contains "$(cli_output)" "Letzter Fehlschlag: Stufe 1" "Die Stufe muss benannt werden"
assert_output_contains "$(cli_output)" "nicht aufloesen" "Der Grund muss benannt werden"

# check ist rein lesend.
scen dns_rc "0"
: > "$MOCK_LOG"
run_cli check
assert_no_bring_up "check darf niemals hochfahren"
assert_log_missing 'nmcli connection down' "check darf niemals herunterfahren"
assert_output_contains "$(cli_output)" "Umgebung" "check zeigt die Umgebung"
assert_output_contains "$(cli_output)" "Preflight" "check zeigt den Preflight"
