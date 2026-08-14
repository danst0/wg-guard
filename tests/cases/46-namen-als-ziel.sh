# Ein Hostname als Prueffziel muss funktionieren. Frueher hat "ip route get"
# selbst aufgeloest - schlug das fehl, kam die Meldung "keine Route", obwohl
# der Name das Problem war (oder eben auch nicht).
sandbox_full_tunnel
cfg TCP_HEALTH "https://m.example.org"
scen dns_m.example.org "203.0.113.9"
scen route_203.0.113.9 "wgtest0"

run_daemon 2
assert_state "GESUND" "Ein Name als Ziel muss funktionieren"
assert_log_contains 'getent ahosts m.example.org' "Der Name muss selbst aufgeloest werden"
assert_log_contains 'ip route get 203.0.113.9' "Die Route wird fuer die Adresse geprueft"
assert_log_missing 'ip route get m.example.org' "iproute2 darf nicht selbst aufloesen muessen"

# Nicht aufloesbar: die Meldung muss die Ursache benennen.
scen dns_rc "2"
scen nm_active "0"; scen link_exists "0"; scen route_default_dev "eth0"
: > "$MOCK_LOG"
run_daemon 1
assert_output_contains "$(daemon_output)" "laesst sich nicht aufloesen" "Die Ursache muss benannt werden"
