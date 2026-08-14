# shellcheck shell=bash
# wg-guard – gemeinsame Grundfunktionen.
#
# Enthaelt Logging, Zeit- und Warteprimitive, das Ausfuehren externer Kommandos
# mit Timeout sowie die Zustandsdatei. Wird von Daemon, CLI und Updater geladen.
#
# Wichtig fuer alle Aufrufer: Zeit und Warten laufen ausschliesslich ueber now()
# und wait_interval(), damit der Testharness sie ersetzen kann.

# ---------------------------------------------------------------- Pfade -----

: "${SYSCONFDIR:=/etc}"
: "${STATEDIR:=/var/lib/wg-guard}"
: "${RUNDIR:=/run/wg-guard}"

CONFIG_FILE="${WG_GUARD_CONFIG:-$SYSCONFDIR/wg-guard/config.conf}"
STATE_FILE="$STATEDIR/state"
PAUSE_FILE="$STATEDIR/paused"
FINGERPRINT_FILE="$STATEDIR/net-fingerprint"
PID_FILE="$RUNDIR/daemon.pid"
LOCK_FILE="$RUNDIR/daemon.lock"

# --------------------------------------------------------------- Logging ----

# Numerische Rangfolge der Loglevel, damit LOG_LEVEL filtern kann.
log_level_rank() {
	case "$1" in
	debug) printf '10' ;;
	info) printf '20' ;;
	warn) printf '30' ;;
	error) printf '40' ;;
	*) printf '20' ;;
	esac
}

# journald liest die sd-daemon-Praefixe von stdout und setzt PRIORITY danach.
log_prefix() {
	case "$1" in
	debug) printf '<7>' ;;
	info) printf '<6>' ;;
	warn) printf '<4>' ;;
	error) printf '<3>' ;;
	*) printf '<6>' ;;
	esac
}

# log <level> <text...>
log() {
	local level="$1"
	shift
	local want configured
	want="$(log_level_rank "$level")"
	configured="$(log_level_rank "${LOG_LEVEL:-info}")"
	[ "$want" -ge "$configured" ] || return 0

	if [ "${WG_GUARD_LOG_PLAIN:-0}" = "1" ]; then
		printf '%s %s\n' "$(printf '%-5s' "$level")" "$*" >&2
	else
		printf '%s%s\n' "$(log_prefix "$level")" "$*"
	fi
}

log_debug() { log debug "$@"; }
log_info() { log info "$@"; }
log_warn() { log warn "$@"; }
log_error() { log error "$@"; }

# ------------------------------------------------------------------ Zeit ----

# Sekunden seit Epoche. Im Test ueber WG_GUARD_FAKE_TIME_FILE ersetzbar, damit
# Backoff und Hysterese deterministisch pruefbar sind.
now() {
	if [ -n "${WG_GUARD_FAKE_TIME_FILE:-}" ] && [ -r "$WG_GUARD_FAKE_TIME_FILE" ]; then
		cat "$WG_GUARD_FAKE_TIME_FILE"
		return 0
	fi
	date +%s
}

# Menschenlesbare Dauer, z. B. "2 Min. 5 Sek.".
human_duration() {
	local s="${1:-0}"
	# Bewusst als if statt "[ ... ] && ...": unter set -e wuerde eine falsche
	# Bedingung als fehlgeschlagenes Kommando gelten und den Aufrufer abbrechen.
	if [ "$s" -lt 0 ]; then s=0; fi
	if [ "$s" -lt 60 ]; then
		printf '%d Sek.' "$s"
	elif [ "$s" -lt 3600 ]; then
		printf '%d Min. %d Sek.' "$((s / 60))" "$((s % 60))"
	elif [ "$s" -lt 86400 ]; then
		printf '%d Std. %d Min.' "$((s / 3600))" "$(((s % 3600) / 60))"
	else
		printf '%d Tage %d Std.' "$((s / 86400))" "$(((s % 86400) / 3600))"
	fi
}

human_timestamp() {
	local ts="${1:-}"
	[ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null || {
		printf 'unbekannt'
		return 0
	}
	date -d "@$ts" '+%d.%m.%Y %H:%M:%S' 2>/dev/null || printf '%s' "$ts"
}

# --------------------------------------------------------------- Warten -----

# Wird vom Signalhandler gesetzt, damit die Schleife den Grund des Aufwachens kennt.
WOKEN=0
SLEEP_PID=""

# wait_interval <sekunden>
# Schlaeft unterbrechbar. Ein SIGUSR1 (Wake) beendet das Warten sofort.
wait_interval() {
	local secs="${1:-1}"
	if [ "$secs" -lt 1 ]; then secs=1; fi

	if [ -n "${WG_GUARD_FAKE_TIME_FILE:-}" ] && [ -r "$WG_GUARD_FAKE_TIME_FILE" ]; then
		# Zeitraffer im Test: Uhr weiterstellen statt real zu warten.
		local t
		t="$(cat "$WG_GUARD_FAKE_TIME_FILE")"
		printf '%s\n' "$((t + secs))" >"$WG_GUARD_FAKE_TIME_FILE"
		return 0
	fi

	sleep "$secs" &
	SLEEP_PID=$!
	wait "$SLEEP_PID" 2>/dev/null || true
	SLEEP_PID=""
}

# Bricht ein laufendes wait_interval ab.
interrupt_sleep() {
	[ -n "$SLEEP_PID" ] || return 0
	kill "$SLEEP_PID" 2>/dev/null || true
}

# ---------------------------------------------- Externe Kommandos + Timeout --

# run_timeout <sekunden> <kommando...>
# Fuehrt ein Kommando mit harter Zeitgrenze aus. stdout wird durchgereicht,
# stderr nach debug umgeleitet. Rueckgabe 124 bedeutet Zeitueberschreitung.
# Kein externes Kommando im Projekt laeuft ohne diese Huelle.
run_timeout() {
	local secs="$1"
	shift
	local rc=0
	timeout --foreground -k 2 "$secs" "$@" 2>/dev/null || rc=$?
	return "$rc"
}

# Wie run_timeout, aber stderr wird mitgenommen (fuer Diagnoseausgaben).
run_timeout_v() {
	local secs="$1"
	shift
	local rc=0
	timeout --foreground -k 2 "$secs" "$@" 2>&1 || rc=$?
	return "$rc"
}

# ------------------------------------------------------------ Konfiguration --

# Defaults. Die Konfigurationsdatei enthaelt nur Abweichungen davon.
load_defaults() {
	# Pflichtangaben – ohne sie laeuft der Daemon nicht an.
	: "${NM_CONNECTION:=}"
	: "${WG_INTERFACE:=}"
	: "${PING_HOST:=}"
	: "${TCP_HEALTH:=}"
	: "${ENDPOINT_HOST:=}" # leer = aus der Peer-Konfiguration lesen

	# Betriebsart. Beim Split-Tunnel erschliesst der Tunnel nur interne Netze,
	# beim Full-Tunnel laeuft der gesamte Verkehr hindurch. Praktisch alle
	# Sicherheitsinvarianten kehren sich zwischen beiden um.
	: "${TUNNEL_MODE:=split}" # split | full

	# Nur im Full-Modus: ohne ein externes Ziel wuerde ein Tunnel als gesund
	# gelten, der zwar steht, hinter dem aber kein Internet mehr ist.
	: "${EXTERNAL_CHECK_HOST:=1.1.1.1}"
	: "${EXTERNAL_CHECK_TCP:=1.1.1.1:443}"
	# Nach einem harten Herunterfahren die DNS-Konfiguration auffrischen.
	: "${RESTORE_DNS_AFTER_HARD_DOWN:=yes}"

	# Intervalle
	: "${CHECK_INTERVAL_HEALTHY:=60}"
	: "${CHECK_INTERVAL_IDLE:=15}"
	: "${CHECK_INTERVAL_DEGRADED:=5}"

	# Backoff und Hysterese
	: "${BACKOFF_INITIAL:=15}"
	: "${BACKOFF_MAX:=600}"
	: "${BACKOFF_FACTOR:=2}"
	: "${BACKOFF_JITTER_PCT:=20}"
	: "${HYSTERESIS_FAILURES:=6}"
	: "${HYSTERESIS_WINDOW:=1800}"
	: "${HYSTERESIS_COOLDOWN:=3600}"

	# Timeouts
	: "${CMD_TIMEOUT:=10}"
	: "${NMCLI_UP_TIMEOUT:=30}"
	: "${NMCLI_DOWN_TIMEOUT:=20}"
	: "${DNS_TIMEOUT:=5}"
	: "${PING_TIMEOUT:=3}"
	: "${TCP_TIMEOUT:=4}"

	# Gesundheitspruefung
	: "${HANDSHAKE_MAX_AGE:=240}"
	: "${HANDSHAKE_GRACE:=25}"
	: "${HEALTH_FAILURES_BEFORE_DOWN:=2}"
	: "${REQUIRE_PERSISTENT_KEEPALIVE:=warn}" # warn | enforce
	: "${ALLOW_LAN_OVERLAP:=no}"

	# Beim Setup ermittelte Faehigkeiten
	: "${PING_COUNT:=1}"
	: "${PING_TIMEOUT_FLAG:=-W}" # -W (iputils), -w (inetutils) oder leer
	: "${PING_BIND_FLAG:=-I}"    # -I oder leer, wenn Bindung nicht moeglich
	: "${TCP_METHOD:=devtcp}"    # devtcp | nc
	: "${STAGE4_ENABLED:=yes}"

	# Betrieb
	: "${LOG_LEVEL:=info}"
	: "${WAKE_DEBOUNCE:=3}"

	# Autoupdate
	: "${AUTO_UPDATE:=yes}"
	: "${UPDATE_REPO:=danst0/wg-guard}"
	: "${UPDATE_CHANNEL:=release}"
	: "${UPDATE_TIMEOUT:=60}"
	: "${UPDATE_HEALTH_WAIT:=30}"
}

load_config() {
	if [ -r "$CONFIG_FILE" ]; then
		# shellcheck source=/dev/null
		. "$CONFIG_FILE"
	fi
	load_defaults
}

# Prueft die Pflichtangaben. Rueckgabe 1 mit Klartextmeldung, wenn etwas fehlt.
config_is_complete() {
	local missing=()
	[ -n "$NM_CONNECTION" ] || missing+=("NM_CONNECTION")
	[ -n "$WG_INTERFACE" ] || missing+=("WG_INTERFACE")

	case "$TUNNEL_MODE" in
	split)
		# Ohne internes Ziel liesse sich der Tunnel nicht pruefen.
		[ -n "$PING_HOST" ] || missing+=("PING_HOST")
		;;
	full)
		# Hier traegt das externe Ziel die Pruefung; interne sind optional.
		if [ -z "$EXTERNAL_CHECK_HOST" ] && [ -z "$EXTERNAL_CHECK_TCP" ]; then
			missing+=("EXTERNAL_CHECK_HOST oder EXTERNAL_CHECK_TCP")
		fi
		;;
	*)
		CONFIG_ERROR="TUNNEL_MODE ist \"$TUNNEL_MODE\", erlaubt sind split und full."
		return 1
		;;
	esac

	if [ "${#missing[@]}" -gt 0 ]; then
		CONFIG_ERROR="Pflichtangaben fehlen in $CONFIG_FILE: ${missing[*]}"
		return 1
	fi
	config_validate || return 1
	return 0
}

is_full_tunnel() { [ "$TUNNEL_MODE" = "full" ]; }

# Zerlegt eine Zieladresse in "host port".
#
# Versteht neben "Host:Port" und "[IPv6]:Port" auch URLs: aus
# "https://m.dumke.me" wird "m.dumke.me 443". Ein Pfadanteil wird verworfen –
# geprueft wird eine TCP-Verbindung, kein HTTP-Abruf.
tcp_split_host() {
	local spec="$1" host port="" scheme=""

	case "$spec" in
	*://*)
		scheme="${spec%%://*}"
		spec="${spec#*://}"
		;;
	esac
	# Zugangsdaten, Pfad, Query und Fragment abschneiden.
	spec="${spec##*@}"
	spec="${spec%%/*}"
	spec="${spec%%\?*}"
	spec="${spec%%#*}"

	case "$spec" in
	\[*\]:*)
		host="${spec%%]*}"
		host="${host#[}"
		port="${spec##*:}"
		;;
	\[*\])
		host="${spec#[}"
		host="${host%]}"
		;;
	*:*:*)
		# Nacktes IPv6 ohne Klammern hat keinen Port.
		host="$spec"
		;;
	*:*)
		host="${spec%:*}"
		port="${spec##*:}"
		;;
	*)
		host="$spec"
		;;
	esac

	if [ -z "$port" ]; then
		case "$scheme" in
		https | wss) port=443 ;;
		http | ws) port=80 ;;
		ssh) port=22 ;;
		imaps) port=993 ;;
		smtps) port=465 ;;
		esac
	fi

	printf '%s %s' "$host" "$port"
}

# Prueft eine "Host:Port"-Angabe. Bei Fehlern steht der Grund in SPEC_ERROR.
#
# Der haeufigste Fehler ist eine URL: "https://host" zerlegt sich naiv in den
# Host "https" und den Port "//host", was zu voellig irrefuehrenden Meldungen
# ueber nicht ermittelbare Routen fuehrt.
validate_host_port() {
	local spec="$1" name="$2" host port
	SPEC_ERROR=""
	[ -n "$spec" ] || return 0 # leer heisst deaktiviert

	read -r host port <<<"$(tcp_split_host "$spec")"
	if [ -z "$host" ]; then
		SPEC_ERROR="$name=\"$spec\" enthaelt keinen Host."
		return 1
	fi
	if [ -z "$port" ]; then
		SPEC_ERROR="$name=\"$spec\" nennt keinen Port. Erwartet wird Host:Port (10.0.41.1:443) oder eine URL mit bekanntem Schema (https://host)."
		return 1
	fi
	case "$port" in
	*[!0-9]*)
		SPEC_ERROR="$name=\"$spec\": \"$port\" ist keine Portnummer."
		return 1
		;;
	esac
	if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
		SPEC_ERROR="$name=\"$spec\": Port $port liegt ausserhalb von 1-65535."
		return 1
	fi
	return 0
}

# Prueft die Werte, die erst zur Laufzeit auffallen wuerden. Rueckgabe 1 mit
# Klartextbegruendung in CONFIG_ERROR.
config_validate() {
	if ! validate_host_port "$TCP_HEALTH" "TCP_HEALTH"; then
		CONFIG_ERROR="$SPEC_ERROR"
		return 1
	fi
	if ! validate_host_port "$EXTERNAL_CHECK_TCP" "EXTERNAL_CHECK_TCP"; then
		CONFIG_ERROR="$SPEC_ERROR"
		return 1
	fi
	return 0
}

# -------------------------------------------------------------- Zustand -----

# Der Zustand liegt als key=value-Datei, damit `status` ihn ohne root und ohne
# jq lesen kann. Geschrieben wird immer atomar (tmp + mv).
state_write() {
	local tmp
	mkdir -p "$STATEDIR" 2>/dev/null || true
	tmp="$(mktemp "$STATE_FILE.XXXXXX" 2>/dev/null)" || return 0
	{
		printf 'STATE=%s\n' "${ST_STATE:-UNBEKANNT}"
		printf 'SINCE=%s\n' "${ST_SINCE:-0}"
		printf 'UPDATED=%s\n' "$(now)"
		printf 'LAST_STAGE_OK=%s\n' "${ST_LAST_STAGE_OK:-}"
		printf 'LAST_FAIL_STAGE=%s\n' "${ST_LAST_FAIL_STAGE:-}"
		printf 'LAST_FAIL_REASON=%s\n' "${ST_LAST_FAIL_REASON:-}"
		printf 'LAST_FAIL_TS=%s\n' "${ST_LAST_FAIL_TS:-0}"
		printf 'LAST_HEALTHY_TS=%s\n' "${ST_LAST_HEALTHY_TS:-0}"
		printf 'NEXT_ATTEMPT=%s\n' "${ST_NEXT_ATTEMPT:-0}"
		printf 'CONSEC_FAILS=%s\n' "${ST_CONSEC_FAILS:-0}"
		printf 'HEALTH_FAILS=%s\n' "${ST_HEALTH_FAILS:-0}"
		printf 'BACKOFF=%s\n' "${ST_BACKOFF:-0}"
		printf 'PAUSED=%s\n' "$(is_paused && printf 'yes' || printf 'no')"
		printf 'TUNNEL=%s\n' "${ST_TUNNEL:-down}"
		printf 'VERSION=%s\n' "${WG_GUARD_VERSION:-unbekannt}"
	} >"$tmp"
	chmod 0644 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$STATE_FILE"
}

# state_read <schluessel> – liest einen Wert aus der Zustandsdatei.
state_read() {
	local key="$1" line
	[ -r "$STATE_FILE" ] || return 1
	while IFS= read -r line; do
		case "$line" in
		"$key="*)
			printf '%s' "${line#*=}"
			return 0
			;;
		esac
	done <"$STATE_FILE"
	return 1
}

# --------------------------------------------------------------- Pause ------

is_paused() { [ -e "$PAUSE_FILE" ]; }

set_paused() {
	mkdir -p "$STATEDIR"
	: >"$PAUSE_FILE"
	chmod 0644 "$PAUSE_FILE" 2>/dev/null || true
}

clear_paused() { rm -f "$PAUSE_FILE"; }

# ---------------------------------------------------------------- Hilfen ----

# Ist der uebergebene String eine IP-Adresse (v4 oder v6)?
# Bewusst grob: unterscheidet nur Literal von Hostname, validiert nicht.
is_ip_literal() {
	case "$1" in
	*:*) return 0 ;; # IPv6 enthaelt immer einen Doppelpunkt
	[0-9]*)
		case "$1" in
		*[!0-9.]*) return 1 ;; # Ziffern und Punkte -> IPv4
		*) return 0 ;;
		esac
		;;
	*) return 1 ;;
	esac
}

# Zufallszahl 0..n-1 ohne externes Kommando.
rand_below() {
	local n="${1:-1}"
	if [ "$n" -lt 1 ]; then n=1; fi
	printf '%s' "$((RANDOM % n))"
}

die() {
	log_error "$*"
	exit 1
}

# Ist der Aufrufer root?
is_root() { [ "$(id -u)" -eq 0 ]; }

require_root() {
	is_root || die "Dieser Befehl benoetigt root-Rechte. Bitte mit sudo aufrufen."
}
