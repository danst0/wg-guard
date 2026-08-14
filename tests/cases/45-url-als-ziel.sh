# Eine URL als Ziel ist eine naheliegende Eingabe und hat eine eindeutige
# Bedeutung - das Werkzeug versteht sie, statt sie abzulehnen.
load_libs

split() { read -r h p <<<"$(tcp_split_host "$1")"; printf '%s|%s' "$h" "$p"; }

assert_eq "$(split 'https://m.dumke.me')"        "m.dumke.me|443"    "https ohne Port"
assert_eq "$(split 'http://intern.example')"     "intern.example|80" "http ohne Port"
assert_eq "$(split 'https://host:8443')"         "host|8443"         "URL mit Port"
assert_eq "$(split 'https://host/status?x=1')"   "host|443"          "Pfad und Query werden verworfen"
assert_eq "$(split '10.0.41.1:443')"             "10.0.41.1|443"     "Klassisches Host:Port"
assert_eq "$(split '[fd00::1]:443')"             "fd00::1|443"       "IPv6 in Klammern"
assert_eq "$(split 'ssh://build.example')"       "build.example|22"  "Weiteres bekanntes Schema"

# Ohne ableitbaren Port bleibt es ein Fehler - aber mit brauchbarer Meldung.
validate_host_port "example.org" "TCP_HEALTH" && rc=0 || rc=1
assert_eq "$rc" "1" "Ohne Port ist die Angabe unvollstaendig"
assert_output_contains "$SPEC_ERROR" "nennt keinen Port" "Der Grund muss klar sein"
validate_host_port "https://m.dumke.me" "TCP_HEALTH" && rc=0 || rc=1
assert_eq "$rc" "0" "Eine URL mit bekanntem Schema ist gueltig"
