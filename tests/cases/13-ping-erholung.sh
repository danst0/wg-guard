# Erholt sich der Ping nach einem Fehlschlag, bleibt der Tunnel oben.
printf '0 1 0 0\n' > "$SCEN/ping_rc_sequence"
run_daemon 4
assert_state "GESUND"
assert_log_missing 'nmcli connection down' "Ein einzelner Ausfall darf nicht zum Herunterfahren fuehren"
