# Der Desktop-Umschalter ist die einzige Bedienung, die die Nutzerin sieht.
# Er muss zuverlaessig umschalten und verstaendlich zurueckmelden.
run_toggle() {
	env PATH="$MOCK_BIN:$PATH" \
		STATEDIR="$SB/state" \
		WG_GUARD_CTL="$REPO_ROOT/src/wg-guard-ctl" \
		WG_GUARD_BIN="$REPO_ROOT/src/wg-guard" \
		WG_GUARD_LIBDIR="$REPO_ROOT/src" \
		WG_GUARD_CONFIG="$SB/config.conf" \
		WG_GUARD_KEYFILE_DIR="$SB/keyfiles" \
		RUNDIR="$SB/run" SCEN="$SCEN" MOCK_LOG="$MOCK_LOG" \
		RESUME_WAIT=2 \
		bash "$REPO_ROOT/src/wg-guard-toggle" >"$SB/toggle.out" 2>&1
}

# Erster Klick: pausieren.
run_daemon 2
run_toggle
assert_true test -e "$SB/state/paused" "Der erste Klick muss pausieren"
assert_log_contains 'notify-send .*pausiert' "Die Rueckmeldung muss den Zustand nennen"
assert_log_contains 'Internetverbindung ist davon nicht betroffen' "Die Nutzerin muss das einordnen koennen"

# Zweiter Klick: wieder aktivieren.
run_toggle
assert_true test ! -e "$SB/state/paused" "Der zweite Klick muss wieder aktivieren"
assert_log_contains 'notify-send .*aktiviert' "Die Rueckmeldung muss den Zustand nennen"

# Fehlende Berechtigung wird verstaendlich gemeldet, nicht als sudo-Fehler.
scen sudo_rc "1"
run_toggle
assert_log_contains 'ab- und wieder anmelden' "Fehlende Rechte muessen erklaert werden"

# wg-guard-ctl akzeptiert ausser pause und resume nichts.
env PATH="$MOCK_BIN:$PATH" WG_GUARD_BIN="$REPO_ROOT/src/wg-guard" \
	bash "$REPO_ROOT/src/wg-guard-ctl" status >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "2" "Andere Verben muessen abgewiesen werden"
env PATH="$MOCK_BIN:$PATH" WG_GUARD_BIN="$REPO_ROOT/src/wg-guard" \
	bash "$REPO_ROOT/src/wg-guard-ctl" pause --extra >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "$rc" "2" "Zusaetzliche Argumente muessen abgewiesen werden"
