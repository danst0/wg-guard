# Die Paketnamen-Tabelle muss fuer alle hinterlegten Familien stimmen - und
# eine unbekannte Distribution darf nicht in einen Fehler laufen, sondern
# einfach kein Installationsangebot machen.
load_libs

check_distro() { # <fixture> <familie> <manager> <nmcli-paket>
	OS_RELEASE_FILE="$REPO_ROOT/tests/fixtures/os-release/$1"
	detect_distro
	assert_eq "$DISTRO_FAMILY" "$2" "Familie fuer $1"
	assert_eq "$PKG_MANAGER" "$3" "Paketmanager fuer $1"
	assert_eq "$(package_for nmcli)" "$4" "nmcli-Paket fuer $1"
}

check_distro mint     debian "apt-get" "network-manager"
check_distro ubuntu   debian "apt-get" "network-manager"
check_distro debian   debian "apt-get" "network-manager"
check_distro fedora   fedora "dnf"     "NetworkManager"
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
