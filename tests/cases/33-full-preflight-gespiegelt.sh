# Im Full-Modus kehren sich die Erwartungen um: eine Default-Route in den
# AllowedIPs ist gewollt, DNS im Profil ebenfalls.
sandbox_full_tunnel
run_daemon 2
assert_state "GESUND"
assert_output_contains "$(daemon_output)" "" "Preflight darf nicht blockieren"

# never-default=yes wuerde den Full-Tunnel funktionslos machen: NetworkManager
# legt die Peer-Route fuer 0.0.0.0/0 dann gar nicht erst an.
prop ipv4.never-default "yes"
scen nm_active "0"; scen link_exists "0"; scen route_default_dev "eth0"
: > "$MOCK_LOG"
run_daemon 1
assert_no_bring_up "Mit never-default=yes darf im Full-Modus nicht hochgefahren werden"
assert_state "PREFLIGHT_FEHLER"

# Umgekehrt: fehlt die Default-Route in den AllowedIPs, passen Modus und
# Verbindung nicht zusammen.
prop ipv4.never-default "no"
keyfile_set_allowed_ips "10.0.0.0/16;"
: > "$MOCK_LOG"
run_daemon 1
assert_no_bring_up "Ohne Default-Route in den AllowedIPs ist es kein Full-Tunnel"
assert_state "PREFLIGHT_FEHLER"
