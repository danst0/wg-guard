# Laeuft die Route zum VPN-Endpunkt durch den Tunnel selbst, kann das nicht
# funktionieren - der Tunnel wuerde sich selbst tunneln.
sandbox_full_tunnel
scen route_198.51.100.7 "wgtest0"
run_daemon 1
assert_log_contains 'nmcli connection down' "Die Schleife muss zum Herunterfahren fuehren"
assert_output_contains "$(daemon_output)" "durch den Tunnel selbst" "Der Grund muss benannt werden"
