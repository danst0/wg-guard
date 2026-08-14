# Eine negative dns-priority kapert die systemweite Namensaufloesung.
prop ipv4.dns-priority "-42"
run_daemon 1
assert_no_bring_up
assert_state "PREFLIGHT_FEHLER"
