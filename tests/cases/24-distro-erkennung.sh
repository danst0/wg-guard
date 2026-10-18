# Die Paketnamen-Tabelle muss fuer alle hinterlegten Familien stimmen - und
# eine unbekannte Distribution darf nicht in einen Fehler laufen, sondern
# einfach kein Installationsangebot machen.
load_libs

check_distro() { # <fixture> <familie> <manager> <nmcli-paket> [PATH fuer die Erkennung]
	OS_RELEASE_FILE="$REPO_ROOT/tests/fixtures/os-release/$1"
	if [ -n "${5:-}" ]; then
		PATH="$5" detect_distro
	else
		detect_distro
	fi
	assert_eq "$DISTRO_FAMILY" "$2" "Familie fuer $1"
	assert_eq "$PKG_MANAGER" "$3" "Paketmanager fuer $1"
	assert_eq "$(package_for nmcli)" "$4" "nmcli-Paket fuer $1"
}

check_distro mint     debian "apt-get" "network-manager"
check_distro ubuntu   debian "apt-get" "network-manager"
check_distro debian   debian "apt-get" "network-manager"
# Fedora: dnf, wenn es installiert ist, sonst yum. Beides unabhaengig vom
# Rechner, auf dem der Test laeuft - der GitHub-Runner ist Ubuntu ohne dnf,
# dort scheiterte der Test, solange er das echte PATH nahm.
nur_dnf="$(mktemp -d)"
printf '#!/bin/sh\n' >"$nur_dnf/dnf"
chmod +x "$nur_dnf/dnf"
ohne_dnf="$(mktemp -d)"
check_distro fedora   fedora "dnf"     "NetworkManager" "$nur_dnf"
check_distro fedora   fedora "yum"     "NetworkManager" "$ohne_dnf"
rm -rf "$nur_dnf" "$ohne_dnf"
check_distro arch     arch   "pacman"  "networkmanager"
check_distro opensuse suse   "zypper"  "NetworkManager"

# Unbekannt: kein Manager, kein Paketvorschlag, aber ein sauberer Durchlauf.
OS_RELEASE_FILE="$REPO_ROOT/tests/fixtures/os-release/unknown"
detect_distro
assert_eq "$DISTRO_FAMILY" "unknown" "Unbekannte Distribution"
assert_eq "$PKG_MANAGER" "" "Kein Paketmanager fuer Unbekanntes"
assert_eq "$(package_for nmcli)" "" "Kein Paketvorschlag fuer Unbekanntes"
# wireguard-tools heisst ueberall gleich und wird trotzdem benannt.
assert_eq "$(package_for wg)" "wireguard-tools" "wg-Paket ist distributionsunabhaengig"
