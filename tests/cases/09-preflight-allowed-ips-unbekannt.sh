# Sind die AllowedIPs nicht ermittelbar, wird im Zweifel nicht hochgefahren.
# Der Endpunkt wird explizit konfiguriert, damit der Test wirklich an P4 haengt
# und nicht schon an Stufe 1 scheitert.
cfg ENDPOINT_HOST "vpn.example.org"
rm -f "$SB/keyfiles/"*.nmconnection
: > "$SCEN/nm_peer_dump"
run_daemon 1
assert_no_bring_up
assert_state "PREFLIGHT_FEHLER"
assert_output_contains "$(daemon_output)" "AllowedIPs konnten weder" "Der Grund muss benannt werden"
