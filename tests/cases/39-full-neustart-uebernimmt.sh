# Ein Neustart des Daemons - etwa nach einem Update - darf einen laufenden,
# gesunden Full-Tunnel nicht abschiessen. Die Uplink-Erkennung darf sich dabei
# nicht auf die Default-Route stuetzen: die gehoert im Full-Modus dem Tunnel.
sandbox_full_tunnel
run_daemon 2
assert_state "GESUND"
assert_eq "$(scen_get nm_active)" "1" "Der Tunnel muss oben sein"

# Zweiter Lauf mit bereits laufendem Tunnel und Default-Route am Tunnel.
: > "$MOCK_LOG"
run_daemon 2
assert_state "GESUND" "Der laufende Tunnel muss uebernommen werden"
assert_log_missing 'nmcli connection down' "Ein gesunder Tunnel darf nicht abgeschossen werden"
assert_eq "$(scen_get nm_active)" "1" "Der Tunnel bleibt oben"

# Faellt der Uplink darunter weg, ist das Ruhezustand.
scen uplink_state "unavailable"
scen route_default_dev ""
: > "$MOCK_LOG"
run_daemon 2
assert_state "RUHE"
