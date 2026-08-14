# Nach einem Neustart darf status nicht minutenlang den Stand des vorherigen
# Laufs zeigen - der Daemon schreibt seinen Zustand sofort.
run_daemon 2
assert_state "GESUND"

# Einen beendeten Lauf simulieren, wie ihn SIGTERM hinterlaesst.
sed -i 's/^STATE=.*/STATE=BEENDET/' "$SB/state/state"
run_cli status
assert_output_contains "$(cli_output)" "startet gerade neu" "Der Widerspruch muss erklaert werden"

# Ein neuer Lauf ueberschreibt den Stand sofort.
scen nm_active "0"
scen link_exists "0"
scen nm_conn "limited"      # bleibt in Stufe 0 stehen, schreibt aber sofort
run_daemon 1
assert_true test "$(state_of STATE)" != "BEENDET" "Der alte Stand muss ersetzt sein"
