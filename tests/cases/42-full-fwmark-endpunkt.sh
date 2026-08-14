# NetworkManager haelt die Tunnelpakete bei einem Full-Tunnel per
# Firewall-Markierung aus dem Tunnel heraus, statt eine Host-Route zum Endpunkt
# anzulegen. Ohne Beruecksichtigung der Markierung sieht jeder gesunde
# NM-Full-Tunnel wie eine Routenschleife aus.
sandbox_full_tunnel
scen fwmark "0xca6c"
# Ohne Markierung zeigt jede Route auf den Tunnel - so ist es beim Full-Tunnel.
scen route_198.51.100.7 "wgtest0"
# Mit Markierung gehen die Pakete am Tunnel vorbei.
scen route_marked "eth0"

run_daemon 2
assert_state "GESUND" "Die Markierung muss den Endpunktpfad korrekt aufloesen"
assert_log_contains 'wg show .* fwmark' "Die Markierung muss abgefragt werden"
assert_log_contains 'ip route get .* mark' "Die Route muss mit Markierung geprueft werden"

# Echte Schleife: auch mit Markierung landet der Endpunkt im Tunnel.
scen route_marked "wgtest0"
scen nm_active "0"; scen link_exists "0"; scen route_default_dev "eth0"
: > "$MOCK_LOG"
run_daemon 1
assert_log_contains 'nmcli connection down' "Eine echte Schleife muss weiterhin erkannt werden"
assert_output_contains "$(daemon_output)" "durch den Tunnel selbst" "Der Grund muss benannt werden"
