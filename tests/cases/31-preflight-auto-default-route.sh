# NetworkManager gibt ip4-auto-default-route numerisch aus (-1/0/1). Ein
# erzwungenes 1 umgeht never-default ueber Policy-Routing und muss erkannt
# werden - ein nicht interpretierbarer Wert ebenso.
prop wireguard.ip4-auto-default-route "1"
run_daemon 1
assert_no_bring_up
assert_state "PREFLIGHT_FEHLER"

# -1 ist der Normalfall und ohne /0-Peer wirkungslos.
prop wireguard.ip4-auto-default-route "-1"
: > "$MOCK_LOG"
run_daemon 2
assert_state "GESUND"

# Unbekannter Wert: im Zweifel nicht hochfahren.
prop wireguard.ip4-auto-default-route "vielleicht"
scen nm_active "0"
scen link_exists "0"
: > "$MOCK_LOG"
run_daemon 1
assert_no_bring_up "Ein nicht interpretierbarer Wert darf nicht durchgewinkt werden"
