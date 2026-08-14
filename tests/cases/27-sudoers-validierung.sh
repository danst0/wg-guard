# Eine ungueltige sudoers-Datei darf niemals installiert werden - ein Fehler
# dort kann sudo systemweit unbrauchbar machen.
scen visudo_rc "1"
sandbox_install
assert_true test ! -e "$SB/sudoers/wg-guard" "Bei ungueltiger Datei darf nichts liegen bleiben"
assert_output_contains "$(cat "$SB/install.out")" "ungueltig" "Der Grund muss genannt werden"

# Mit gueltiger Datei wird sie installiert - mit exakten Argumenten, ohne Wildcard.
scen visudo_rc "0"
sandbox_install
assert_true test -e "$SB/sudoers/wg-guard" "Gueltige Datei wird installiert"
assert_output_contains "$(cat "$SB/sudoers/wg-guard")" "wg-guard-ctl pause" "pause muss erlaubt sein"
assert_output_contains "$(cat "$SB/sudoers/wg-guard")" "wg-guard-ctl resume" "resume muss erlaubt sein"
assert_true grep -qv 'ALL$' "$SB/sudoers/wg-guard" "Kein NOPASSWD auf alles"
