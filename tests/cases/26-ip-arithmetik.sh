# Die Ueberlappungspruefung entscheidet, ob ein Tunnel das lokale Netz
# blackholen wuerde - sie muss stimmen.
load_libs

overlaps() { prefixes_overlap "$1" "$2" && printf 'ja' || printf 'nein'; }

assert_eq "$(overlaps 10.0.0.0/16 10.0.5.20/16)" "ja"   "Gleiches /16 ueberlappt"
assert_eq "$(overlaps 10.0.0.0/16 10.1.0.5/24)"  "nein" "Anderes /16 ueberlappt nicht"
assert_eq "$(overlaps 10.0.0.0/16 192.168.1.5/24)" "nein" "Privates LAN ohne Konflikt"
assert_eq "$(overlaps 10.0.0.0/8  10.99.3.4/24)" "ja"   "Enthaltenes Netz ueberlappt"
assert_eq "$(overlaps 10.0.0.0/16 fd00::1/64)"   "nein" "Verschiedene Adressfamilien nie"
assert_eq "$(overlaps fd00:1234::/48 fd00:1234:0:ab::7/64)" "ja"   "Adresse im ULA-Praefix"
assert_eq "$(overlaps fd00:1234::/32 fd00:1234:5::7/64)"    "ja"   "Kuerzeres Praefix umfasst mehr"
assert_eq "$(overlaps fd00:1234::/48 fd00:1234:5::7/64)"    "nein" "Dritte Gruppe liegt ausserhalb des /48"
assert_eq "$(overlaps fd00:1234::/48 fd00:9999::1/64)"      "nein" "Anderes ULA-Praefix"
# Praefixlaenge, die nicht auf einer Nibble-Grenze liegt.
assert_eq "$(overlaps fd00:1234::/47 fd00:1234:1::5/64)"    "ja"   "/47 umfasst auch das benachbarte /48"
assert_eq "$(overlaps fd00:1234::/47 fd00:1234:2::5/64)"    "nein" "/47 reicht nicht bis zum uebernaechsten /48"

# Der Vorschlag fuer den Ping-Host wird aus den AllowedIPs abgeleitet.
assert_eq "$(first_host_in_prefix 10.0.0.0/16)" "10.0.0.1" "Erste Adresse im Praefix"
assert_eq "$(first_host_in_prefix 192.168.178.0/24)" "192.168.178.1" "Erste Adresse im /24"
