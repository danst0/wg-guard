# Scheitern nmcli connection down und device disconnect, wird das Interface
# direkt entfernt - sonst waere "fail-safe down" nur eine Absichtserklaerung.
scen handshake_ts "-99999"
scen down_rc "1"
scen dev_disconnect_rc "1"
run_daemon 1
assert_log_contains 'nmcli connection down' "Der regulaere Weg wird zuerst versucht"
assert_log_contains 'nmcli device disconnect' "Danach das Geraet trennen"
assert_log_contains 'ip link delete' "Zuletzt das Interface entfernen"
assert_eq "$(scen_get link_exists)" "0" "Das Interface muss nachweislich weg sein"
