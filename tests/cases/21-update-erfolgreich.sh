# Der gute Fall: Pruefsumme stimmt, Syntax ist sauber, der Dienst kommt hoch.
cfg UPDATE_HEALTH_WAIT 2
sandbox_install
make_fake_release "9.9.9"
run_update
assert_eq "$(installed_version)" "9.9.9" "Die neue Version muss installiert sein"
assert_log_contains 'systemctl restart' "Der Dienst muss neu gestartet werden"
assert_true test -d "$SB/state/backup/$(repo_version)" "Es muss eine Sicherung angelegt worden sein"
