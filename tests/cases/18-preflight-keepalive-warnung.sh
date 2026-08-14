# Ohne PersistentKeepalive wird gewarnt, aber nicht blockiert - der Handshake
# wird dann durch die eigenen Sonden am Leben gehalten.
sed -i '/^persistent-keepalive=/d' "$SB/keyfiles/irgendein-name.nmconnection"
run_daemon 2
assert_state "GESUND"
assert_output_contains "$(daemon_output)" "PersistentKeepalive ist nicht gesetzt" "Es muss gewarnt werden"

# Mit enforce wird daraus ein Abbruchgrund.
cfg REQUIRE_PERSISTENT_KEEPALIVE "enforce"
: > "$MOCK_LOG"
scen nm_active "0"
scen link_exists "0"
run_daemon 1
assert_no_bring_up "Mit enforce darf nicht hochgefahren werden"
