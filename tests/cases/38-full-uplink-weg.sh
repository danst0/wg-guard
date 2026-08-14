# Ohne Uplink darunter bleibt der Tunnel unten - das ist Ruhezustand,
# kein Fehler, und darf den Backoff nicht hochtreiben.
sandbox_full_tunnel
scen uplink_state "unavailable"
scen route_default_dev ""
scen route_198.51.100.7 ""
run_daemon 3
assert_state "RUHE"
assert_no_bring_up
assert_eq "$(state_of CONSEC_FAILS)" "0" "Fehlender Uplink erhoeht keinen Fehlerzaehler"
