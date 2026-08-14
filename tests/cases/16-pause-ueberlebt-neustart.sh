# Die Pause liegt als Flagdatei unter /var/lib und ueberlebt einen Neustart
# des Daemons.
run_cli pause
assert_true test -e "$SB/state/paused" "Die Pause-Flagdatei muss angelegt werden"
run_daemon 2
assert_state "PAUSIERT"
assert_no_bring_up
run_cli resume
assert_true test ! -e "$SB/state/paused" "resume muss die Flagdatei entfernen"
run_daemon 2
assert_state "GESUND"
