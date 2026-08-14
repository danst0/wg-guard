# Ueberlappen die AllowedIPs mit dem lokalen Netz, wuerde das Hochfahren
# das LAN blackholen.
printf '2: eth0    inet 10.0.5.20/16 brd 10.0.255.255 scope global eth0\n' > "$SCEN/local_addrs4"
run_daemon 1
assert_no_bring_up
assert_state "PREFLIGHT_FEHLER"
