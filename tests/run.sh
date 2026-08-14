#!/usr/bin/env bash
#
# wg-guard – Testsuite.
#
# Laeuft vollstaendig ohne echten Tunnel, ohne Netz und ohne root: alle externen
# Kommandos sind Mocks, die jeden Aufruf protokollieren. Dadurch lassen sich
# auch die wichtigen Negativfaelle pruefen – etwa dass bei verletztem Preflight
# nachweislich *kein* "nmcli connection up" stattfindet.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
. "$HERE/lib/harness.sh"

FILTER="${1:-}"
TOTAL_CASES=0
FAILED_CASES=0

for case_file in "$HERE"/cases/*.sh; do
	[ -f "$case_file" ] || continue
	name="$(basename "$case_file" .sh)"
	if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
		continue
	fi

	TOTAL_CASES=$((TOTAL_CASES + 1))
	CURRENT_CASE="$name"
	CASE_FAILED=0
	printf '  %-46s' "$name"

	sandbox_new
	# shellcheck source=/dev/null
	# Ein Rueckgabewert != 0 kann schlicht von der letzten Zusicherung stammen;
	# nur wenn keine Zusicherung fehlschlug, ist der Fall selbst abgebrochen.
	if ! . "$case_file"; then
		if [ "$CASE_FAILED" -eq 0 ]; then
			_fail "Der Testfall selbst ist mit einem Fehler abgebrochen."
		fi
	fi

	if [ "$CASE_FAILED" -eq 0 ]; then
		printf 'ok\n'
	else
		printf 'FEHLGESCHLAGEN\n'
		FAILED_CASES=$((FAILED_CASES + 1))
		if [ -n "${WG_GUARD_TEST_VERBOSE:-}" ]; then
			printf '    --- Daemon-Ausgabe ---\n'
			sed 's/^/    /' "$SB/daemon.out" 2>/dev/null | tail -30
			printf '    --- Aufrufe ---\n'
			sed 's/^/    /' "$MOCK_LOG" 2>/dev/null | tail -30
		fi
	fi
	sandbox_clean
done

printf '\n%d Testfaelle, %d Zusicherungen, %d Fehler\n' \
	"$TOTAL_CASES" "$TESTS_RUN" "$TESTS_FAILED"

if [ "$FAILED_CASES" -gt 0 ]; then
	printf 'FEHLGESCHLAGEN: %d von %d Testfaellen.\n' "$FAILED_CASES" "$TOTAL_CASES"
	printf 'Fuer Details: WG_GUARD_TEST_VERBOSE=1 bash tests/run.sh\n'
	exit 1
fi
printf 'Alle Tests bestanden.\n'
exit 0
