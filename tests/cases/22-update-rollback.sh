# Kommt der Dienst nach dem Update nicht hoch, wird automatisch
# zurueckgerollt - sonst staende die Nutzerin dauerhaft ohne VPN da.
cfg UPDATE_HEALTH_WAIT 2
sandbox_install
make_fake_release "9.9.9"
scen service_active_rc "1"
scen restart_updates_state "0"
run_update
assert_eq "$(installed_version)" "0.1.0" "Der Rollback muss die alte Version wiederherstellen"
assert_output_contains "$(update_output)" "Rollback" "Der Rollback muss protokolliert werden"
