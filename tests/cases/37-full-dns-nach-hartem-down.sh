# Nach "ip link delete" weiss NetworkManager nichts vom Verschwinden und
# koennte die DNS-Einstellungen des Tunnels stehen lassen. Im Full-Modus zeigt
# die Namensaufloesung dann auf einen Server hinter dem toten Tunnel.
sandbox_full_tunnel
scen route_default_dev_after_up "eth0"   # loest ein Herunterfahren aus
scen down_rc "1"
scen dev_disconnect_rc "1"
run_daemon 1
assert_log_contains 'ip link delete' "Die Eskalation muss greifen"
assert_log_contains 'nmcli general reload dns-full' "Die DNS-Konfiguration muss aufgefrischt werden"
assert_output_contains "$(daemon_output)" "keine Reste des Tunnels" "Der Schritt muss protokolliert sein"
