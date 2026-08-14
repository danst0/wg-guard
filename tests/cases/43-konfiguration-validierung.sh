# Eine URL statt Host:Port fuehrte frueher zu voellig irrefuehrenden Meldungen
# ueber nicht ermittelbare Routen. Solche Werte muessen frueh und im Klartext
# auffallen - und der Tunnel bleibt derweil unten.
cfg TCP_HEALTH "https://intern.example.org"
run_daemon 1 || true
assert_no_bring_up "Bei fehlerhafter Konfiguration wird nicht hochgefahren"
assert_state "KONFIG_FEHLER"
run_cli status
assert_output_contains "$(cli_output)" "sieht aus wie eine URL" "Der Grund muss im Klartext stehen"
assert_output_contains "$(cli_output)" "10.0.41.1:443" "Ein Beispiel hilft beim Korrigieren"

# Ein Pfadanteil ist ebenso ungueltig.
cfg TCP_HEALTH "intern.example.org:443/status"
run_daemon 1 || true
assert_state "KONFIG_FEHLER"

# Portnummern ausserhalb des gueltigen Bereichs.
cfg TCP_HEALTH "10.0.0.1:99999"
run_daemon 1 || true
assert_state "KONFIG_FEHLER"

# Gueltige Angaben laufen durch, auch IPv6 in Klammern.
cfg TCP_HEALTH "[fd00::1]:443"
scen route_fd00::1 "wgtest0"
run_daemon 1 || true
assert_true test "$(state_of STATE)" != "KONFIG_FEHLER" "Gueltiges IPv6-Ziel muss akzeptiert werden"
