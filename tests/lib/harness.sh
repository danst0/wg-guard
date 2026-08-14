# shellcheck shell=bash
# Testharness fuer wg-guard.
#
# Jeder Testfall bekommt eine eigene Sandbox: eigenes Zustands-, Lauf- und
# Konfigurationsverzeichnis, PATH-injizierte Mocks und eine gefaelschte Uhr.
# Dadurch laeuft die gesamte Zustandsmaschine ohne echten Tunnel, ohne Netz und
# ohne root – und Backoff sowie Hysterese sind deterministisch pruefbar.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOCK_BIN="$REPO_ROOT/tests/mocks"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_CASE=""

# ------------------------------------------------------------- Sandbox ------

sandbox_new() {
	SB="$(mktemp -d)"
	SCEN="$SB/scen"
	MOCK_LOG="$SB/calls.log"
	FAKE_TIME_FILE="$SB/time"
	export SB SCEN MOCK_LOG FAKE_TIME_FILE

	mkdir -p "$SCEN" "$SB/state" "$SB/run" "$SB/keyfiles" "$SB/etc"
	: >"$MOCK_LOG"
	printf '1700000000\n' >"$FAKE_TIME_FILE"

	# Vorgabe: alles gesund.
	scen conn_name "wgtest"
	scen iface "wgtest0"
	scen nm_state "connected"
	scen nm_conn "full"
	scen nm_active "0"
	scen link_exists "0"
	scen route_default_dev "eth0"
	scen route_10.0.0.1 "wgtest0"
	scen endpoint_ip "198.51.100.7"
	scen handshake_ts "-30"
	scen ping_rc "0"
	scen tcp_rc "0"
	scen dns_rc "0"
	scen up_rc "0"
	scen down_rc "0"
	scen nm_version "1.46.0"

	cat >"$SCEN/nm_props" <<-'EOF'
		connection.uuid=uuid-1234
		connection.type=wireguard
		connection.interface-name=wgtest0
		ipv4.never-default=yes
		ipv6.never-default=yes
		connection.autoconnect=no
		ipv4.dns=
		ipv6.dns=
		ipv4.dns-search=
		ipv6.dns-search=
		ipv4.dns-priority=0
		ipv6.dns-priority=0
		wireguard.ip4-auto-default-route=default
		wireguard.ip6-auto-default-route=default
	EOF

	cat >"$SB/keyfiles/irgendein-name.nmconnection" <<-'EOF'
		[connection]
		id=wgtest
		uuid=uuid-1234
		type=wireguard
		interface-name=wgtest0

		[wireguard]
		private-key=AAAA

		[wireguard-peer.PEERKEY123=]
		endpoint=vpn.example.org:51820
		allowed-ips=10.0.0.0/16;fd00:1234::/48;
		persistent-keepalive=25

		[ipv4]
		method=manual
	EOF

	cat >"$SB/config.conf" <<-'EOF'
		NM_CONNECTION="wgtest"
		WG_INTERFACE="wgtest0"
		PING_HOST="10.0.0.1"
		TCP_HEALTH="10.0.0.1:443"
		TCP_METHOD="nc"
		PING_TIMEOUT_FLAG="-W"
		PING_BIND_FLAG="-I"
		LOG_LEVEL="debug"
		CHECK_INTERVAL_HEALTHY=60
		CHECK_INTERVAL_IDLE=15
		CHECK_INTERVAL_DEGRADED=5
		BACKOFF_INITIAL=10
		BACKOFF_MAX=600
		BACKOFF_JITTER_PCT=0
		HYSTERESIS_FAILURES=4
		HYSTERESIS_WINDOW=1800
		HYSTERESIS_COOLDOWN=3600
		HANDSHAKE_GRACE=6
		HEALTH_FAILURES_BEFORE_DOWN=2
	EOF
}

sandbox_clean() {
	[ -n "${SB:-}" ] && [ -d "$SB" ] && rm -rf "$SB"
	SB=""
}

# scen <schluessel> <wert> – steuert das Verhalten der Mocks.
scen() { printf '%s' "$2" >"$SCEN/$1"; }
scen_get() { cat "$SCEN/$1" 2>/dev/null; }

# cfg <schluessel> <wert> – setzt einen Konfigurationswert.
cfg() {
	local key="$1" value="$2"
	grep -vE "^$key=" "$SB/config.conf" >"$SB/config.tmp" 2>/dev/null || true
	printf '%s="%s"\n' "$key" "$value" >>"$SB/config.tmp"
	mv "$SB/config.tmp" "$SB/config.conf"
}

# prop <schluessel> <wert> – setzt eine NM-Eigenschaft fuer den Preflight.
prop() {
	local key="$1" value="$2"
	grep -vE "^$key=" "$SCEN/nm_props" >"$SCEN/nm_props.tmp" 2>/dev/null || true
	printf '%s=%s\n' "$key" "$value" >>"$SCEN/nm_props.tmp"
	mv "$SCEN/nm_props.tmp" "$SCEN/nm_props"
}

keyfile_set_allowed_ips() {
	sed -i "s|^allowed-ips=.*|allowed-ips=$1|" "$SB/keyfiles/irgendein-name.nmconnection"
}

# ----------------------------------------------------------- Ausfuehrung ----

daemon_env() {
	printf '%s\n' \
		"PATH=$MOCK_BIN:$PATH" \
		"WG_GUARD_LIBDIR=$REPO_ROOT/src" \
		"WG_GUARD_CONFIG=$SB/config.conf" \
		"WG_GUARD_KEYFILE_DIR=$SB/keyfiles" \
		"STATEDIR=$SB/state" \
		"RUNDIR=$SB/run" \
		"SCEN=$SCEN" \
		"MOCK_LOG=$MOCK_LOG" \
		"FAKE_TIME_FILE=$FAKE_TIME_FILE" \
		"WG_GUARD_FAKE_TIME_FILE=$FAKE_TIME_FILE" \
		"WG_GUARD_LOG_PLAIN=1"
}

# run_daemon [zyklen] – laesst den Daemon eine begrenzte Zahl Schleifen laufen.
run_daemon() {
	local cycles="${1:-1}"
	# shellcheck disable=SC2046
	env $(daemon_env | tr '\n' ' ') "WG_GUARD_MAX_CYCLES=$cycles" \
		bash "$REPO_ROOT/src/wg-guard-daemon" >>"$SB/daemon.out" 2>&1
	return $?
}

# run_cli <argumente...> – ruft die CLI in der Sandbox auf.
run_cli() {
	# shellcheck disable=SC2046
	env $(daemon_env | tr '\n' ' ') \
		bash "$REPO_ROOT/src/wg-guard" "$@" >"$SB/cli.out" 2>&1
	return $?
}

cli_output() { cat "$SB/cli.out" 2>/dev/null; }
daemon_output() { cat "$SB/daemon.out" 2>/dev/null; }

state_of() {
	grep -E "^$1=" "$SB/state/state" 2>/dev/null | head -n1 | cut -d= -f2-
}

# --------------------------------------------------------------- Asserts ----

_fail() {
	printf '    FEHLGESCHLAGEN: %s\n' "$*" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	CASE_FAILED=1
}

assert_eq() { # assert_eq <ist> <soll> <beschreibung>
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$1" != "$2" ]; then
		_fail "$3 (erwartet: \"$2\", war: \"$1\")"
		return 1
	fi
	return 0
}

assert_state() { # assert_state <soll> [beschreibung]
	assert_eq "$(state_of STATE)" "$1" "${2:-Zustand}"
}

assert_log_contains() { # assert_log_contains <muster> <beschreibung>
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! grep -qE "$1" "$MOCK_LOG"; then
		_fail "${2:-Aufruf fehlt}: /$1/ steht nicht im Aufrufprotokoll"
		return 1
	fi
	return 0
}

assert_log_missing() { # assert_log_missing <muster> <beschreibung>
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$1" "$MOCK_LOG"; then
		_fail "${2:-Aufruf haette nicht stattfinden duerfen}: /$1/ steht im Aufrufprotokoll"
		return 1
	fi
	return 0
}

assert_output_contains() { # assert_output_contains <datei-inhalt> <muster> <beschreibung>
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! printf '%s' "$1" | grep -qE "$2"; then
		_fail "${3:-Ausgabe}: /$2/ fehlt"
		return 1
	fi
	return 0
}

assert_true() { # assert_true <kommando...> – letzter Parameter ist die Beschreibung
	local desc="${!#}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! "${@:1:$#-1}"; then
		_fail "$desc"
		return 1
	fi
	return 0
}

# Der Tunnel darf nicht hochgefahren worden sein.
assert_no_bring_up() {
	assert_log_missing 'nmcli .*connection up' "${1:-Es haette nicht hochgefahren werden duerfen}"
}

# ------------------------------------------------- Installation und Update --

# Installiert das Repository in die Sandbox (wie ein echter Erstinstall,
# nur mit umgebogenen Pfaden). Setzt SB_PREFIX und SB_LIBDIR.
sandbox_install() {
	SB_PREFIX="$SB/opt"
	SB_LIBDIR="$SB_PREFIX/lib"
	export SB_PREFIX SB_LIBDIR
	mkdir -p "$SB/units" "$SB/dispatcher" "$SB/sudoers" "$SB/apps"
	env PATH="$MOCK_BIN:$PATH" \
		SCEN="$SCEN" MOCK_LOG="$MOCK_LOG" \
		PREFIX="$SB_PREFIX" LIBDIR="$SB_LIBDIR" \
		SYSCONFDIR="$SB/etc" STATEDIR="$SB/state" \
		UNITDIR="$SB/units" DISPATCHDIR="$SB/dispatcher" \
		SUDOERSDIR="$SB/sudoers" APPDIR="$SB/apps" \
		bash "$REPO_ROOT/install.sh" --files-only \
		>"$SB/install.out" 2>&1
	return $?
}

# Baut ein Release-Archiv samt Pruefsumme, wie es der Updater erwartet.
# make_fake_release <version> [broken|badsum]
make_fake_release() {
	local version="$1" variant="${2:-}"
	local dir="$SCEN/release" work="$SB/relwork/wg-guard-$version"
	mkdir -p "$dir" "$work"
	cp -a "$REPO_ROOT/src" "$REPO_ROOT/dist" "$REPO_ROOT/install.sh" \
		"$REPO_ROOT/uninstall.sh" "$REPO_ROOT/VERSION" "$work/"
	printf '%s\n' "$version" >"$work/VERSION"

	if [ "$variant" = "broken" ]; then
		printf 'if then fi(( unvollstaendig\n' >>"$work/src/wg-guard-daemon"
	fi

	(cd "$SB/relwork" && tar -czf "$dir/wg-guard-$version.tar.gz" "wg-guard-$version")

	if [ "$variant" = "badsum" ]; then
		printf '%s  wg-guard-%s.tar.gz\n' \
			"0000000000000000000000000000000000000000000000000000000000000000" "$version" \
			>"$dir/SHA256SUMS"
	else
		(cd "$dir" && sha256sum "wg-guard-$version.tar.gz" >SHA256SUMS)
	fi
	scen release_version "$version"
}

# Fuehrt den Updater gegen die Sandbox-Installation aus.
run_update() {
	env PATH="$MOCK_BIN:$PATH" \
		WG_GUARD_LIBDIR="$SB_LIBDIR/wg-guard" \
		WG_GUARD_CONFIG="$SB/config.conf" \
		STATEDIR="$SB/state" RUNDIR="$SB/run" \
		SCEN="$SCEN" MOCK_LOG="$MOCK_LOG" \
		WG_GUARD_LOG_PLAIN=1 \
		bash "$SB_LIBDIR/wg-guard/wg-guard-update" "$@" \
		>"$SB/update.out" 2>&1
	return $?
}

update_output() { cat "$SB/update.out" 2>/dev/null; }
installed_version() { cat "$SB_LIBDIR/wg-guard/VERSION" 2>/dev/null; }
# Die Version des Arbeitsstands - Tests duerfen sie nicht hartkodieren.
repo_version() { cat "$REPO_ROOT/VERSION"; }

# ------------------------------------------------------- Bibliothekstests ---

# Laedt die Bibliotheken in die aktuelle Shell, um einzelne Funktionen direkt
# zu pruefen (Plattformerkennung, IP-Arithmetik).
load_libs() {
	CMD_TIMEOUT=5
	LOG_LEVEL=error
	WG_INTERFACE="wgtest0"
	# shellcheck source=../../src/lib/common.sh
	. "$REPO_ROOT/src/lib/common.sh"
	# shellcheck source=../../src/lib/platform.sh
	. "$REPO_ROOT/src/lib/platform.sh"
	# shellcheck source=../../src/lib/safety.sh
	. "$REPO_ROOT/src/lib/safety.sh"
	load_defaults
}

# Stellt die Sandbox auf einen Full-Tunnel um: AllowedIPs mit Default-Route,
# DNS im Profil, never-default aus - so wie eine echte Full-Tunnel-Verbindung.
sandbox_full_tunnel() {
	cfg TUNNEL_MODE "full"
	cfg EXTERNAL_CHECK_HOST "1.1.1.1"
	cfg EXTERNAL_CHECK_TCP ""
	cfg PING_HOST ""
	cfg TCP_HEALTH ""
	keyfile_set_allowed_ips "0.0.0.0/0;::/0;"
	prop ipv4.never-default "no"
	prop ipv6.never-default "no"
	prop ipv4.dns "10.0.41.1"
	prop ipv6.dns "fd5a:8c37:5ae1:36f::1"
	# Im Betrieb gehoert die Default-Route dem Tunnel, der Endpunkt liegt
	# daran vorbei.
	scen route_default_dev_after_up "wgtest0"
	scen route_198.51.100.7 "eth0"
}
