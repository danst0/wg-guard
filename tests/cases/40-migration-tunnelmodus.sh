# Ein Update darf einen Bestandsnutzer nicht in den falschen Modus laufen
# lassen: fehlt TUNNEL_MODE in einer alten Konfiguration, muss die Betriebsart
# erkannt und nachgetragen werden.
sandbox_full_tunnel
sed -i '/^TUNNEL_MODE=/d' "$SB/config.conf"
assert_true test ! -s /dev/null "Vorbereitung"

# Ohne Terminal wird nichts stillschweigend gesetzt, aber laut hingewiesen.
run_cli migrate || true
assert_output_contains "$(cli_output)" "Full-Tunnel" "Der erkannte Typ muss benannt werden"
assert_output_contains "$(cli_output)" "wg-guard migrate" "Der Weg muss genannt werden"
assert_true grep -qv '^TUNNEL_MODE=' "$SB/config.conf" "Ohne Rueckfrage wird nichts gesetzt"

# Bei einem Split-Tunnel wird die Vorgabe einfach festgeschrieben.
keyfile_set_allowed_ips "10.0.0.0/16;"
run_cli migrate
assert_true grep -q '^TUNNEL_MODE="split"' "$SB/config.conf" "Split wird eingetragen"

# Ist die Angabe vorhanden, passiert nichts mehr.
run_cli migrate
assert_output_contains "$(cli_output)" "auf dem Stand dieser Version" "Zweiter Lauf ist folgenlos"
