# Der wichtigste Fall im Full-Modus: der Tunnel steht, aber dahinter ist kein
# Internet. Ohne Stufe 6 gaelte er als gesund und der Rechner waere offline,
# ohne dass es jemand merkt.
sandbox_full_tunnel
printf '0 1 1\n' > "$SCEN/ping_rc_sequence"
run_daemon 3
assert_state "BACKOFF"
assert_eq "$(state_of LAST_FAIL_STAGE)" "6" "Stufe 6 muss den Fehler melden"
assert_log_contains 'nmcli connection down' "Der tote Tunnel muss herunter, damit der Rechner online kommt"
assert_output_contains "$(daemon_output)" "dahinter ist kein Internet" "Der Grund muss verstaendlich sein"
