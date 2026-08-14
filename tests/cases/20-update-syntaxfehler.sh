# Ein Release mit Syntaxfehler darf den laufenden Watchdog nie ersetzen.
sandbox_install
make_fake_release "9.9.9" broken
run_update
assert_eq "$(installed_version)" "$(repo_version)" "Die installierte Version darf sich nicht aendern"
assert_output_contains "$(update_output)" "Syntaxfehler" "Der Grund muss im Log stehen"
assert_log_missing 'systemctl restart' "Ohne gueltiges Release darf kein Neustart erfolgen"
