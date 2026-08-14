# Eine Default-Route in den AllowedIPs ist kein Split-Tunnel mehr.
keyfile_set_allowed_ips "0.0.0.0/0;10.0.0.0/16;"
run_daemon 1
assert_no_bring_up
assert_state "PREFLIGHT_FEHLER"
