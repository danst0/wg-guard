# Ohne nutzbares Netz bleibt der Tunnel unten - das ist ein Ruhezustand
# und darf den Backoff-Zaehler nicht erhoehen.
scen nm_conn "limited"
run_daemon 3
assert_state "RUHE"
assert_no_bring_up
assert_eq "$(state_of CONSEC_FAILS)" "0" "Ruhezustand erhoeht keinen Fehlerzaehler"
assert_eq "$(state_of BACKOFF)" "0" "Ruhezustand erzeugt keinen Backoff"
