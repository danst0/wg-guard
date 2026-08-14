# Stimmt die Pruefsumme nicht, wird nichts installiert - die alte Version
# bleibt unangetastet.
sandbox_install
make_fake_release "9.9.9" badsum
run_update
assert_eq "$(installed_version)" "$(repo_version)" "Die installierte Version darf sich nicht aendern"
assert_output_contains "$(update_output)" "Pruefsumme" "Der Grund muss im Log stehen"
assert_log_missing 'systemctl restart' "Ohne gueltiges Archiv darf kein Neustart erfolgen"
