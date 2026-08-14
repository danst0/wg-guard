# shellcheck shell=bash
# wg-guard – NetworkManager-Kapselung und Preflight.
#
# Alle nmcli-Aufrufe laufen ueber run_timeout. Nichts hier fasst eine andere
# Verbindung an als die konfigurierte.

# WG_GUARD_KEYFILE_DIR erlaubt es, ein zusaetzliches Verzeichnis voranzustellen
# (wird von der Testsuite genutzt).
NM_KEYFILE_DIRS=(
	${WG_GUARD_KEYFILE_DIR:+"$WG_GUARD_KEYFILE_DIR"}
	/etc/NetworkManager/system-connections
	/run/NetworkManager/system-connections
	/usr/lib/NetworkManager/system-connections
	/usr/local/lib/NetworkManager/system-connections
)

# ------------------------------------------------------------ Grundlagen ----

# nm_get <property> – einzelne Eigenschaft der konfigurierten Verbindung.
nm_get() {
	run_timeout "$CMD_TIMEOUT" nmcli -t -g "$1" connection show "$NM_CONNECTION" 2>/dev/null
}

nm_connection_exists() {
	run_timeout "$CMD_TIMEOUT" nmcli -t -f NAME connection show 2>/dev/null |
		grep -Fxq "$NM_CONNECTION"
}

nm_connection_uuid() { nm_get connection.uuid; }
nm_connection_type() { nm_get connection.type; }
nm_interface_name() { nm_get connection.interface-name; }

# Ist die Verbindung aktiv?
nm_is_active() {
	run_timeout "$CMD_TIMEOUT" nmcli -t -f NAME connection show --active 2>/dev/null |
		grep -Fxq "$NM_CONNECTION"
}

# Alle WireGuard-Verbindungen, eine pro Zeile (fuer das Setup-Menue).
nm_list_wireguard_connections() {
	run_timeout "$CMD_TIMEOUT" nmcli -t -f NAME,TYPE connection show 2>/dev/null |
		while IFS=: read -r name type; do
			if [ "$type" = "wireguard" ]; then printf '%s\n' "$name"; fi
		done
}

# NM-Gesamtzustand: gibt "STATE CONNECTIVITY" aus.
nm_general_state() {
	local out
	out="$(run_timeout "$CMD_TIMEOUT" nmcli -t -f STATE,CONNECTIVITY general 2>/dev/null)" || return 1
	printf '%s' "${out//:/ }"
}

# ------------------------------------------------------------- Keyfile ------

# Findet die Keyfile der Verbindung ueber die UUID – nicht ueber den Dateinamen,
# denn der muss dem Verbindungsnamen nicht entsprechen.
nm_keyfile_path() {
	local uuid dir file
	uuid="$(nm_connection_uuid)" || return 1
	[ -n "$uuid" ] || return 1
	for dir in "${NM_KEYFILE_DIRS[@]}"; do
		[ -d "$dir" ] || continue
		for file in "$dir"/*; do
			[ -f "$file" ] || continue
			[ -r "$file" ] || continue
			if grep -qxF "uuid=$uuid" "$file" 2>/dev/null; then
				printf '%s' "$file"
				return 0
			fi
		done
	done
	return 1
}

# Liest ein Peer-Attribut aus der Keyfile, ueber alle Peers hinweg, eine Zeile
# pro Fundstelle. Ohne lesbare Keyfile Rueckgabe 1.
nm_keyfile_peer_attr() {
	local attr="$1" file line in_peer=0 found=0
	file="$(nm_keyfile_path)" || return 1
	while IFS= read -r line; do
		case "$line" in
		"[wireguard-peer."*)
			in_peer=1
			continue
			;;
		"["*)
			in_peer=0
			continue
			;;
		esac
		[ "$in_peer" -eq 1 ] || continue
		case "$line" in
		"$attr="*)
			printf '%s\n' "${line#*=}"
			found=1
			;;
		esac
	done <"$file"
	[ "$found" -eq 1 ]
}

# Fallback ueber nmcli, falls die Keyfile nicht lesbar ist. Aeltere NM-Versionen
# geben Peers gar nicht aus – dann bleibt die Ausgabe leer und der Aufrufer
# behandelt das als "nicht ermittelbar".
nm_cli_peer_attr() {
	local attr="$1" out
	out="$(run_timeout "$CMD_TIMEOUT" nmcli --show-secrets -t connection show "$NM_CONNECTION" 2>/dev/null |
		grep -oE "$attr = [^,]*" | sed "s/^$attr = //")" || true
	[ -n "$out" ] || return 1
	printf '%s\n' "$out"
}

# AllowedIPs aller Peers, ein Praefix pro Zeile.
# Rueckgabe 1 bedeutet ausdruecklich "nicht ermittelbar" – das ist ein Fehler,
# kein leeres Ergebnis.
nm_allowed_ips() {
	local raw
	raw="$(nm_keyfile_peer_attr allowed-ips)" || raw="$(nm_cli_peer_attr allowed-ips)" || return 1
	[ -n "$raw" ] || return 1
	# Trennzeichen sind je nach Quelle Semikolon, Komma oder Leerzeichen.
	printf '%s' "$raw" | tr ';, ' '\n' | sed '/^$/d'
}

# Endpunkt-Hostname des ersten Peers (ohne Port).
nm_endpoint_host() {
	local raw host
	raw="$(nm_keyfile_peer_attr endpoint 2>/dev/null | head -n1)" ||
		raw="$(nm_cli_peer_attr endpoint 2>/dev/null | head -n1)" || return 1
	[ -n "$raw" ] || return 1
	case "$raw" in
	\[*\]:*) host="${raw%%]*}" && host="${host#[}" ;; # [IPv6]:port
	*:*:*) host="$raw" ;;                             # nacktes IPv6 ohne Port
	*:*) host="${raw%:*}" ;;
	*) host="$raw" ;;
	esac
	printf '%s' "$host"
}

# Kleinster PersistentKeepalive-Wert ueber alle Peers; leer, wenn keiner gesetzt.
nm_persistent_keepalive() {
	local raw min="" v
	raw="$(nm_keyfile_peer_attr persistent-keepalive 2>/dev/null)" ||
		raw="$(nm_cli_peer_attr persistent-keepalive 2>/dev/null)" || return 1
	while IFS= read -r v; do
		[ -n "$v" ] || continue
		case "$v" in *[!0-9]*) continue ;; esac
		if [ "$v" -eq 0 ]; then continue; fi
		if [ -z "$min" ] || [ "$v" -lt "$min" ]; then min="$v"; fi
	done <<<"$raw"
	[ -n "$min" ] || return 1
	printf '%s' "$min"
}

# ------------------------------------------------------------ Preflight -----

# Ergebnisse als "CODE|STATUS|Beschreibung|Reparaturkommando".
# STATUS ist ok, warn oder fail. Nur fail verhindert das Hochfahren.
PREFLIGHT_RESULTS=()
PREFLIGHT_FAILED=0
PREFLIGHT_WARNED=0

preflight_add() {
	PREFLIGHT_RESULTS+=("$1|$2|$3|${4:-}")
	case "$2" in
	fail) PREFLIGHT_FAILED=$((PREFLIGHT_FAILED + 1)) ;;
	warn) PREFLIGHT_WARNED=$((PREFLIGHT_WARNED + 1)) ;;
	esac
}

# preflight_run – prueft alle Invarianten vor dem Hochfahren.
# Rueckgabe 0, wenn kein fail aufgetreten ist.
preflight_run() {
	PREFLIGHT_RESULTS=()
	PREFLIGHT_FAILED=0
	PREFLIGHT_WARNED=0

	local nmcli_mod="nmcli connection modify \"$NM_CONNECTION\""

	# P1 – Verbindung existiert und ist vom Typ wireguard.
	if ! nm_connection_exists; then
		preflight_add P1 fail "Die NM-Verbindung \"$NM_CONNECTION\" existiert nicht."
		return 1 # alles Weitere waere sinnlos
	fi
	local ctype
	ctype="$(nm_connection_type)" || ctype=""
	if [ "$ctype" = "wireguard" ]; then
		preflight_add P1 ok "Verbindung \"$NM_CONNECTION\" existiert und ist vom Typ wireguard."
	else
		preflight_add P1 fail "Verbindung \"$NM_CONNECTION\" ist vom Typ \"${ctype:-unbekannt}\", erwartet wird wireguard."
	fi

	# P2 – keine Default-Route aus dem Profil.
	local v4nd v6nd
	v4nd="$(nm_get ipv4.never-default)" || v4nd=""
	v6nd="$(nm_get ipv6.never-default)" || v6nd=""
	if [ "$v4nd" = "yes" ]; then
		preflight_add P2 ok "ipv4.never-default ist gesetzt."
	else
		preflight_add P2 fail "ipv4.never-default ist \"${v4nd:-unbekannt}\", erwartet wird yes." \
			"$nmcli_mod ipv4.never-default yes"
	fi
	if [ "$v6nd" = "yes" ]; then
		preflight_add P2 ok "ipv6.never-default ist gesetzt."
	else
		preflight_add P2 fail "ipv6.never-default ist \"${v6nd:-unbekannt}\", erwartet wird yes." \
			"$nmcli_mod ipv6.never-default yes"
	fi

	# P3 – der Guard besitzt den Lebenszyklus allein.
	local autoconn
	autoconn="$(nm_get connection.autoconnect)" || autoconn=""
	if [ "$autoconn" = "no" ]; then
		preflight_add P3 ok "connection.autoconnect ist deaktiviert."
	else
		preflight_add P3 fail "connection.autoconnect ist \"${autoconn:-unbekannt}\". NetworkManager wuerde den Tunnel ungeprueft hochfahren." \
			"$nmcli_mod connection.autoconnect no"
	fi

	# P4 – AllowedIPs ohne Default-Route. Nicht ermittelbar zaehlt als Fehler.
	local ips ip has_default=0
	if ips="$(nm_allowed_ips)"; then
		while IFS= read -r ip; do
			[ -n "$ip" ] || continue
			case "$ip" in
			0.0.0.0/0 | ::/0) has_default=1 ;;
			esac
		done <<<"$ips"
		if [ "$has_default" -eq 1 ]; then
			preflight_add P4 fail "AllowedIPs enthaelt eine Default-Route (0.0.0.0/0 oder ::/0). Das ist kein Split-Tunnel."
		else
			preflight_add P4 ok "AllowedIPs enthaelt keine Default-Route ($(printf '%s' "$ips" | tr '\n' ' '))."
		fi
	else
		preflight_add P4 fail "AllowedIPs konnten weder aus der Keyfile noch ueber nmcli ermittelt werden. Im Zweifel wird nicht hochgefahren."
	fi

	# P5 – kein DNS-Hijack. Eine negative dns-priority zieht die systemweite
	#      Aufloesung an sich, auch ohne Default-Route.
	local key val prio
	for key in ipv4.dns ipv6.dns ipv4.dns-search ipv6.dns-search; do
		val="$(nm_get "$key")" || val=""
		if [ -z "$val" ]; then
			preflight_add P5 ok "$key ist leer."
		else
			preflight_add P5 fail "$key ist gesetzt (\"$val\"). Der Tunnel darf die Namensaufloesung nicht anfassen." \
				"$nmcli_mod $key \"\""
		fi
	done
	for key in ipv4.dns-priority ipv6.dns-priority; do
		prio="$(nm_get "$key")" || prio=""
		[ -n "$prio" ] || prio=0
		if [ "$prio" -ge 0 ] 2>/dev/null; then
			preflight_add P5 ok "$key ist $prio (nicht negativ)."
		else
			preflight_add P5 fail "$key ist $prio. Negative Werte kapern die systemweite Namensaufloesung." \
				"$nmcli_mod $key 0"
		fi
	done

	# P6 – ohne PersistentKeepalive erneuert sich der Handshake nicht von selbst.
	local ka
	if ka="$(nm_persistent_keepalive)"; then
		if [ "$ka" -le $((HANDSHAKE_MAX_AGE / 2)) ]; then
			preflight_add P6 ok "PersistentKeepalive ist ${ka}s."
		else
			preflight_add P6 warn "PersistentKeepalive ist ${ka}s und damit hoch fuer HANDSHAKE_MAX_AGE=${HANDSHAKE_MAX_AGE}s."
		fi
	else
		local st="warn"
		if [ "$REQUIRE_PERSISTENT_KEEPALIVE" = "enforce" ]; then st="fail"; fi
		preflight_add P6 "$st" "PersistentKeepalive ist nicht gesetzt. Ohne Traffic veraltet der Handshake und ein funktionierender Tunnel gilt als tot."
	fi

	# P7 – Policy-Routing darf never-default nicht aushebeln.
	for key in wireguard.ip4-auto-default-route wireguard.ip6-auto-default-route; do
		val="$(nm_get "$key")" || val=""
		case "$val" in
		"true" | "yes")
			preflight_add P7 fail "$key ist erzwungen aktiviert und umgeht never-default." \
				"$nmcli_mod $key default"
			;;
		*)
			preflight_add P7 ok "$key ist \"${val:-default}\"."
			;;
		esac
	done

	# P8 – Ueberlappung mit dem lokalen Netz wuerde das LAN blackholen.
	if [ "$ALLOW_LAN_OVERLAP" = "yes" ]; then
		preflight_add P8 warn "Ueberlappungspruefung ist per ALLOW_LAN_OVERLAP deaktiviert."
	elif ips="$(nm_allowed_ips)"; then
		local conflict
		if conflict="$(find_lan_overlap "$ips")"; then
			preflight_add P8 fail "AllowedIPs ueberlappen mit dem lokalen Netz: $conflict. Das Hochfahren wuerde die lokale Verbindung stoeren."
		else
			preflight_add P8 ok "Keine Ueberlappung zwischen AllowedIPs und dem lokalen Netz."
		fi
	fi

	[ "$PREFLIGHT_FAILED" -eq 0 ]
}

# Gibt die Preflight-Ergebnisse menschenlesbar aus.
preflight_print() {
	local entry code status text fix
	for entry in "${PREFLIGHT_RESULTS[@]}"; do
		IFS='|' read -r code status text fix <<<"$entry"
		case "$status" in
		ok) printf '  [ok]   %-3s %s\n' "$code" "$text" ;;
		warn) printf '  [WARN] %-3s %s\n' "$code" "$text" ;;
		fail) printf '  [FEHL] %-3s %s\n' "$code" "$text" ;;
		esac
		if [ -n "$fix" ]; then printf '         %-3s Reparatur: %s\n' "" "$fix"; fi
	done
	return 0
}

# Schreibt die Preflight-Fehler ins Log.
preflight_log() {
	local entry code status text fix
	for entry in "${PREFLIGHT_RESULTS[@]}"; do
		IFS='|' read -r code status text fix <<<"$entry"
		case "$status" in
		fail) log_error "Preflight $code: $text" ;;
		warn) log_warn "Preflight $code: $text" ;;
		*) log_debug "Preflight $code: $text" ;;
		esac
	done
}
