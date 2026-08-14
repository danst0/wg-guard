# shellcheck shell=bash
# wg-guard – Plattform- und Faehigkeitserkennung.
#
# Leitprinzip: Faehigkeiten pruefen, nicht Distributionen erkennen. Die
# Distributionserkennung dient ausschliesslich dem Komfort beim Nachinstallieren
# von Paketen. Fehlt eine Faehigkeit, wird immer das *Binary* benannt – das
# versteht man auf jeder Distribution.

: "${OS_RELEASE_FILE:=/etc/os-release}"

# Benoetigte Binaries. Ohne diese laeuft wg-guard nicht.
REQUIRED_BINARIES=(nmcli wg ip ping timeout flock getent curl)
# Nur fuer die Rueckmeldung an die Nutzerin noetig.
OPTIONAL_BINARIES=(notify-send)

# ------------------------------------------------------- Distributionen -----

# Setzt DISTRO_ID, DISTRO_LIKE, DISTRO_NAME, PKG_MANAGER, PKG_INSTALL_CMD.
detect_distro() {
	DISTRO_ID="unknown"
	DISTRO_LIKE=""
	DISTRO_NAME="unbekannte Distribution"

	if [ -r "$OS_RELEASE_FILE" ]; then
		local line key value
		while IFS= read -r line; do
			case "$line" in
			\#* | "") continue ;;
			esac
			key="${line%%=*}"
			value="${line#*=}"
			value="${value%\"}"
			value="${value#\"}"
			case "$key" in
			ID) DISTRO_ID="$value" ;;
			ID_LIKE) DISTRO_LIKE="$value" ;;
			PRETTY_NAME) DISTRO_NAME="$value" ;;
			esac
		done <"$OS_RELEASE_FILE"
	fi

	DISTRO_FAMILY="$(distro_family "$DISTRO_ID" "$DISTRO_LIKE")"
	case "$DISTRO_FAMILY" in
	debian)
		PKG_MANAGER="apt-get"
		PKG_INSTALL_CMD="apt-get install -y"
		;;
	fedora)
		if command -v dnf >/dev/null 2>&1; then
			PKG_MANAGER="dnf"
			PKG_INSTALL_CMD="dnf install -y"
		else
			PKG_MANAGER="yum"
			PKG_INSTALL_CMD="yum install -y"
		fi
		;;
	arch)
		PKG_MANAGER="pacman"
		PKG_INSTALL_CMD="pacman -S --needed --noconfirm"
		;;
	suse)
		PKG_MANAGER="zypper"
		PKG_INSTALL_CMD="zypper --non-interactive install"
		;;
	*)
		PKG_MANAGER=""
		PKG_INSTALL_CMD=""
		;;
	esac
}

# distro_family <id> <id_like> – bildet ID/ID_LIKE auf eine Familie ab.
distro_family() {
	local id="$1" like="$2" token
	for token in "$id" $like; do
		case "$token" in
		debian | ubuntu | linuxmint | pop | elementary | raspbian | devuan)
			printf 'debian'
			return 0
			;;
		fedora | rhel | centos | rocky | almalinux | ol)
			printf 'fedora'
			return 0
			;;
		arch | archlinux | manjaro | endeavouros)
			printf 'arch'
			return 0
			;;
		opensuse | opensuse-leap | opensuse-tumbleweed | sles | suse)
			printf 'suse'
			return 0
			;;
		esac
	done
	printf 'unknown'
}

# package_for <binary> – Paketname fuer die erkannte Familie.
# Leere Ausgabe bedeutet: kein Vorschlag moeglich.
package_for() {
	local bin="$1"
	case "$bin" in
	wg)
		printf 'wireguard-tools'
		return 0
		;;
	esac

	case "$DISTRO_FAMILY:$bin" in
	debian:nmcli) printf 'network-manager' ;;
	debian:ping) printf 'iputils-ping' ;;
	debian:notify-send) printf 'libnotify-bin' ;;
	debian:ip) printf 'iproute2' ;;
	debian:timeout | debian:flock | debian:getent) printf 'coreutils' ;;
	debian:curl) printf 'curl' ;;

	fedora:nmcli) printf 'NetworkManager' ;;
	fedora:ping) printf 'iputils' ;;
	fedora:notify-send) printf 'libnotify' ;;
	fedora:ip) printf 'iproute' ;;
	fedora:timeout | fedora:flock | fedora:getent) printf 'coreutils' ;;
	fedora:curl) printf 'curl' ;;

	arch:nmcli) printf 'networkmanager' ;;
	arch:ping) printf 'iputils' ;;
	arch:notify-send) printf 'libnotify' ;;
	arch:ip) printf 'iproute2' ;;
	arch:timeout | arch:flock | arch:getent) printf 'coreutils' ;;
	arch:curl) printf 'curl' ;;

	suse:nmcli) printf 'NetworkManager' ;;
	suse:ping) printf 'iputils' ;;
	suse:notify-send) printf 'libnotify-tools' ;;
	suse:ip) printf 'iproute2' ;;
	suse:timeout | suse:flock | suse:getent) printf 'coreutils' ;;
	suse:curl) printf 'curl' ;;

	*) printf '' ;;
	esac
}

# --------------------------------------------------- Harte Voraussetzungen --

have_systemd() { [ -d /run/systemd/system ]; }

# NetworkManager ab 1.16 kann WireGuard. Rueckgabe 1, wenn zu alt oder unbekannt.
nm_version_ok() {
	local ver major minor
	ver="$(run_timeout "${CMD_TIMEOUT:-10}" nmcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)" || true
	[ -n "$ver" ] || return 1
	NM_VERSION="$ver"
	major="${ver%%.*}"
	minor="${ver#*.}"
	minor="${minor%%.*}"
	if [ "$major" -gt 1 ]; then return 0; fi
	[ "$major" -eq 1 ] && [ "$minor" -ge 16 ]
}

bash_version_ok() {
	if [ "${BASH_VERSINFO[0]}" -gt 4 ]; then return 0; fi
	[ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]
}

# Fuellt MISSING_REQUIRED und MISSING_OPTIONAL.
check_binaries() {
	MISSING_REQUIRED=()
	MISSING_OPTIONAL=()
	local bin
	for bin in "${REQUIRED_BINARIES[@]}"; do
		command -v "$bin" >/dev/null 2>&1 || MISSING_REQUIRED+=("$bin")
	done
	for bin in "${OPTIONAL_BINARIES[@]}"; do
		command -v "$bin" >/dev/null 2>&1 || MISSING_OPTIONAL+=("$bin")
	done
	[ "${#MISSING_REQUIRED[@]}" -eq 0 ]
}

# ------------------------------------------------- Faehigkeitserkennung -----

# ping unterscheidet sich zwischen iputils und inetutils: das Flag fuer die
# Wartezeit heisst mal -W, mal -w, mal gar nicht. Statt die Variante zu raten,
# werden die Kandidaten einmal gegen die Loopback-Adresse getestet. Ergebnis
# landet als PING_TIMEOUT_FLAG in der Konfiguration ("" = kein Flag verfuegbar).
detect_ping_timeout_flag() {
	local flag
	for flag in -W -w; do
		if run_timeout 5 ping -n -q -c 1 "$flag" 1 127.0.0.1 >/dev/null 2>&1; then
			printf '%s' "$flag"
			return 0
		fi
	done
	# Ohne Zeitflag ist ping immer noch brauchbar, weil run_timeout ohnehin greift.
	if run_timeout 5 ping -n -q -c 1 127.0.0.1 >/dev/null 2>&1; then
		printf ''
		return 0
	fi
	return 1
}

# Kann ping an ein Interface gebunden werden? Ohne -I traegt die Routenpruefung
# (Q4) die Last, dass wirklich der Tunnel getestet wird.
detect_ping_bind_flag() {
	if run_timeout 5 ping -n -q -c 1 -I lo 127.0.0.1 >/dev/null 2>&1; then
		printf '%s' "-I"
		return 0
	fi
	printf ''
	return 0
}

# Kann diese bash /dev/tcp? Ein abgelehnter Verbindungsaufbau zaehlt als
# vorhanden – nur "not supported" bedeutet, dass die Funktion fehlt.
detect_tcp_method() {
	local out
	out="$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/1 && exec 3<&-' 2>&1 || true)"
	case "$out" in
	*"not supported"* | *"nicht unterst"*)
		if command -v nc >/dev/null 2>&1; then
			printf 'nc'
			return 0
		fi
		return 1
		;;
	*)
		printf 'devtcp'
		return 0
		;;
	esac
}

# Ist /etc/sudoers.d ueberhaupt eingebunden? Nicht ueberall selbstverstaendlich.
sudoers_d_active() {
	[ -r /etc/sudoers ] || return 1
	grep -qE '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers
}

# Liegt das Verzeichnis im secure_path von sudo? Sonst greift `sudo wg-guard-ctl`
# ins Leere, obwohl die sudoers-Zeile stimmt.
in_sudo_secure_path() {
	local dir="$1" line
	[ -r /etc/sudoers ] || return 0
	line="$(grep -E '^[[:space:]]*Defaults[[:space:]]+secure_path' /etc/sudoers 2>/dev/null | head -n1)" || true
	[ -n "$line" ] || return 0 # kein secure_path gesetzt -> keine Einschraenkung
	case ":${line#*=}:" in
	*":$dir:"*) return 0 ;;
	*) return 1 ;;
	esac
}

selinux_enabled() {
	command -v getenforce >/dev/null 2>&1 || return 1
	[ "$(getenforce 2>/dev/null)" != "Disabled" ]
}

# Setzt die SELinux-Kontexte neu, sofern das System welche kennt.
restore_selinux_context() {
	command -v restorecon >/dev/null 2>&1 || return 0
	local path
	for path in "$@"; do
		[ -e "$path" ] || continue
		restorecon -F "$path" >/dev/null 2>&1 || true
	done
}
