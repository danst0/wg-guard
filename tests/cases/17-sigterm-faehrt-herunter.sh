# Bei SIGTERM wird der Tunnel definiert heruntergefahren, nicht einfach
# stehen gelassen. Laeuft bewusst in Echtzeit, ohne Zeitraffer.
# shellcheck disable=SC2046
env $(daemon_env | grep -v FAKE_TIME | tr '\n' ' ') \
	bash "$REPO_ROOT/src/wg-guard-daemon" >"$SB/daemon.out" 2>&1 &
DPID=$!
# Warten, bis der Tunnel wirklich oben ist.
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ "$(scen_get nm_active)" = "1" ] && break
	sleep 0.5
done
assert_eq "$(scen_get nm_active)" "1" "Der Tunnel muss zuerst hochgefahren sein"
kill -TERM "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
assert_log_contains 'nmcli connection down' "SIGTERM muss den Tunnel herunterfahren"
assert_eq "$(scen_get nm_active)" "0" "Der Tunnel muss danach unten sein"
