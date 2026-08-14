# Scheitert die neue Version an der Konfiguration statt am Code, waere ein
# Rollback verkehrt: die alte Version hat denselben Fehler, meldet ihn nur
# spaeter und unverstaendlicher. Genau das ist beim ersten Feldeinsatz passiert.
cfg UPDATE_HEALTH_WAIT 2
sandbox_install
make_fake_release "9.9.9"
scen service_active_rc "1"
scen restart_updates_state "0"
scen exec_main_status "78"
printf 'STATE=KONFIG_FEHLER\nLAST_FAIL_REASON=TCP_HEALTH="https://x" sieht aus wie eine URL.\n' \
	> "$SB/state/state"

run_update || true
assert_eq "$(installed_version)" "9.9.9" "Die neue Version muss installiert bleiben"
assert_output_contains "$(update_output)" "Konfiguration fehlerhaft" "Die Ursache muss benannt werden"
assert_output_contains "$(update_output)" "sieht aus wie eine URL" "Der konkrete Grund muss durchgereicht werden"
assert_output_contains "$(update_output)" "Rollback wuerde nichts loesen" "Die Entscheidung muss begruendet sein"

# Kaputter Code fuehrt weiterhin zum Rollback.
scen exec_main_status "1"
printf 'STATE=FEHLER\n' > "$SB/state/state"
sandbox_install
run_update || true
assert_eq "$(installed_version)" "$(repo_version)" "Bei kaputtem Code wird zurueckgerollt"
