# Steht der Tunnel, laeuft der Verkehr aber daran vorbei, ist der Zweck
# verfehlt - im Split-Modus waere genau das der Normalzustand.
sandbox_full_tunnel
scen route_default_dev_after_up "eth0"
run_daemon 1
assert_log_contains 'nmcli connection down' "Der Tunnel muss herunter"
assert_output_contains "$(daemon_output)" "am Tunnel vorbei" "Der Grund muss benannt werden"
