# Eine gleiche oder aeltere Version loest kein Update aus.
sandbox_install
make_fake_release "0.0.1"
run_update
assert_eq "$(installed_version)" "$(repo_version)" "Kein Downgrade"
assert_log_missing 'systemctl restart' "Ohne neue Version kein Neustart"

# --check meldet den Stand, ohne etwas zu tun.
run_update --check
assert_output_contains "$(update_output)" "ist aktuell" "check muss den Stand melden"
