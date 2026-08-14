# Bei abweichendem PREFIX muessen Unit, sudoers und Desktop-Eintrag
# uebereinstimmend dorthin zeigen - sonst laufen sie ins Leere.
sandbox_install

assert_true grep -q "ExecStart=$SB/opt/lib/wg-guard/wg-guard-daemon" "$SB/units/wg-guard.service" \
	"Die Unit muss auf den tatsaechlichen Pfad zeigen"
assert_true grep -q "$SB/opt/bin/wg-guard-ctl pause" "$SB/sudoers/wg-guard" \
	"Die sudoers-Zeile muss auf den tatsaechlichen Pfad zeigen"
assert_true grep -q "Exec=$SB/opt/bin/wg-guard-toggle" "$SB/apps/wg-guard-toggle.desktop" \
	"Der Desktop-Eintrag muss auf den tatsaechlichen Pfad zeigen"
assert_true grep -q "$SB/opt/lib/wg-guard" "$SB/opt/bin/wg-guard" \
	"Die CLI muss ihre Bibliotheken finden"

# Kein unersetzter Platzhalter darf uebrig bleiben.
LEFTOVER="$(grep -rl '@PREFIX@\|@LIBDIR@\|@SYSCONFDIR@\|@STATEDIR@' \
	"$SB/opt" "$SB/units" "$SB/sudoers" "$SB/apps" "$SB/dispatcher" 2>/dev/null || true)"
assert_eq "$LEFTOVER" "" "Es darf kein unersetzter Platzhalter zurueckbleiben"
