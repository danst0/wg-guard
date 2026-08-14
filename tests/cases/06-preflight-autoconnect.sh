# Mit autoconnect=yes wuerde NetworkManager den Tunnel ungeprueft hochfahren.
prop connection.autoconnect "yes"
run_daemon 1
assert_no_bring_up
assert_state "PREFLIGHT_FEHLER"
