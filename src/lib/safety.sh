# shellcheck shell=bash
# wg-guard – Sicherheitspruefungen und garantiertes Herunterfahren.
#
# Dieses Modul haelt die Invarianten, die ueber allem stehen: der Rechner darf
# seine normale Internetverbindung nicht verlieren, weil der Tunnel Probleme
# hat. Jede Verletzung fuehrt sofort zum Herunterfahren – ohne Toleranzzaehler.
#
# Alle Eingriffe betreffen ausschliesslich das konfigurierte Interface. Es wird
# niemals an globalen Routen, an /etc/resolv.conf, an iptables/nftables oder an
# anderen NM-Verbindungen gedreht.

# ------------------------------------------------------- IP-Arithmetik ------

# IPv4 in eine 32-Bit-Zahl. Fuehrende Nullen werden dezimal gelesen.
ipv4_to_int() {
	local a b c d
	IFS=. read -r a b c d <<<"$1"
	printf '%s' "$(((10#${a:-0} << 24) | (10#${b:-0} << 16) | (10#${c:-0} << 8) | 10#${d:-0}))"
}

ipv4_mask() {
	local p="$1"
	if [ "$p" -le 0 ]; then
		printf '0'
		return 0
	fi
	if [ "$p" -ge 32 ]; then
		printf '4294967295'
		return 0
	fi
	printf '%s' "$((0xFFFFFFFF & (0xFFFFFFFF << (32 - p))))"
}

# 32-Bit-Zahl zurueck in Punktnotation.
int_to_ipv4() {
	local i="$1"
	printf '%d.%d.%d.%d' "$(((i >> 24) & 255))" "$(((i >> 16) & 255))" "$(((i >> 8) & 255))" "$((i & 255))"
}

# Erste nutzbare Adresse eines IPv4-Praefixes – als Vorschlag fuer PING_HOST.
first_host_in_prefix() {
	local cidr="$1" addr len net
	addr="${cidr%%/*}"
	len="${cidr##*/}"
	case "$addr" in *:*) return 1 ;; esac
	if [ "$addr" = "$len" ]; then len=32; fi
	net=$(($(ipv4_to_int "$addr") & $(ipv4_mask "$len")))
	int_to_ipv4 "$((net + 1))"
}

# Expandiert eine IPv6-Adresse zu 32 Hex-Nibbles ohne Doppelpunkte.
ipv6_expand() {
	local addr="$1" left right group out=""
	local -a lg=() rg=()

	case "$addr" in
	*::*)
		left="${addr%%::*}"
		right="${addr#*::}"
		;;
	*)
		left="$addr"
		right=""
		;;
	esac

	if [ -n "$left" ]; then IFS=: read -ra lg <<<"$left"; fi
	if [ -n "$right" ]; then IFS=: read -ra rg <<<"$right"; fi

	local missing=$((8 - ${#lg[@]} - ${#rg[@]}))
	if [ "$missing" -lt 0 ]; then return 1; fi

	for group in "${lg[@]}"; do out+="$(printf '%04x' "0x${group:-0}")"; done
	local i
	for ((i = 0; i < missing; i++)); do out+="0000"; done
	for group in "${rg[@]}"; do out+="$(printf '%04x' "0x${group:-0}")"; done

	[ "${#out}" -eq 32 ] || return 1
	printf '%s' "$out"
}

# Ueberlappen zwei Praefixe? Gibt 0 bei Ueberlappung zurueck.
# Unterschiedliche Adressfamilien ueberlappen nie.
prefixes_overlap() {
	local a="$1" b="$2"
	local a_addr="${a%%/*}" a_len="${a##*/}"
	local b_addr="${b%%/*}" b_len="${b##*/}"
	if [ "$a_addr" = "$a_len" ]; then a_len=""; fi
	if [ "$b_addr" = "$b_len" ]; then b_len=""; fi

	local a_is6=0 b_is6=0
	case "$a_addr" in *:*) a_is6=1 ;; esac
	case "$b_addr" in *:*) b_is6=1 ;; esac
	[ "$a_is6" = "$b_is6" ] || return 1

	if [ "$a_is6" -eq 0 ]; then
		[ -n "$a_len" ] || a_len=32
		[ -n "$b_len" ] || b_len=32
		local min=$a_len
		if [ "$b_len" -lt "$min" ]; then min="$b_len"; fi
		local m ai bi
		m="$(ipv4_mask "$min")"
		ai="$(ipv4_to_int "$a_addr")"
		bi="$(ipv4_to_int "$b_addr")"
		[ "$((ai & m))" -eq "$((bi & m))" ]
		return $?
	fi

	[ -n "$a_len" ] || a_len=128
	[ -n "$b_len" ] || b_len=128
	local min6=$a_len
	if [ "$b_len" -lt "$min6" ]; then min6="$b_len"; fi

	local ax bx
	ax="$(ipv6_expand "$a_addr")" || return 1
	bx="$(ipv6_expand "$b_addr")" || return 1

	local full=$((min6 / 4)) rest=$((min6 % 4))
	if [ "$full" -gt 0 ]; then
		[ "${ax:0:$full}" = "${bx:0:$full}" ] || return 1
	fi
	if [ "$rest" -gt 0 ]; then
		local an bn mask
		an=$((16#${ax:$full:1}))
		bn=$((16#${bx:$full:1}))
		mask=$((0xF & (0xF << (4 - rest))))
		[ "$((an & mask))" -eq "$((bn & mask))" ] || return 1
	fi
	return 0
}

# ------------------------------------------------- Lokale Netzumgebung ------

# Alle On-Link-Praefixe ausser denen des Tunnelinterfaces und der Loopback.
local_prefixes() {
	local line dev cidr
	{
		run_timeout "$CMD_TIMEOUT" ip -o -4 addr show 2>/dev/null || true
		run_timeout "$CMD_TIMEOUT" ip -o -6 addr show 2>/dev/null || true
	} | while read -r _ dev _ cidr _; do
		[ -n "$dev" ] || continue
		if [ "$dev" = "lo" ]; then continue; fi
		if [ "$dev" = "$WG_INTERFACE" ]; then continue; fi
		case "$cidr" in
		fe80:*) continue ;; # Link-Local ist kein Konflikt
		*/*) printf '%s %s\n' "$dev" "$cidr" ;;
		esac
	done
}

# find_lan_overlap <allowed-ips-liste>
# Gibt bei Ueberlappung eine Beschreibung aus und liefert 0 zurueck.
find_lan_overlap() {
	local allowed="$1" ip line dev cidr net
	local locals
	locals="$(local_prefixes)" || return 1
	[ -n "$locals" ] || return 1

	while IFS= read -r ip; do
		[ -n "$ip" ] || continue
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			dev="${line%% *}"
			cidr="${line#* }"
			# Adresse des Interfaces auf ihr Netz reduzieren.
			net="$cidr"
			if prefixes_overlap "$ip" "$net"; then
				printf '%s ueberschneidet sich mit %s auf %s' "$ip" "$net" "$dev"
				return 0
			fi
		done <<<"$locals"
	done <<<"$allowed"
	return 1
}

# ---------------------------------------------- Routen- und Pfadpruefung ----

# Interface, ueber das eine Zieladresse geroutet wird. Leer, wenn unbekannt.
route_dev_for() {
	local target="$1" out
	out="$(run_timeout "$CMD_TIMEOUT" ip route get "$target" 2>/dev/null)" || return 1
	printf '%s' "$out" | sed -n 's/.*[[:space:]]dev[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | head -n1
}

route6_dev_for() {
	local target="$1" out
	out="$(run_timeout "$CMD_TIMEOUT" ip -6 route get "$target" 2>/dev/null)" || return 1
	printf '%s' "$out" | sed -n 's/.*[[:space:]]dev[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | head -n1
}

# Q1–Q3: Hat der Tunnel die Default-Route uebernommen?
# Rueckgabe 0 = alles in Ordnung. Bei 1 steht der Grund in SAFETY_REASON.
check_default_route_safe() {
	SAFETY_REASON=""
	local dev

	# Q1 – IPv4-Default.
	dev="$(route_dev_for 1.1.1.1 2>/dev/null)" || dev=""
	if [ -n "$dev" ] && [ "$dev" = "$WG_INTERFACE" ]; then
		SAFETY_REASON="Die IPv4-Default-Route laeuft ueber $WG_INTERFACE."
		return 1
	fi

	# Q2 – IPv6-Default. Kein Ergebnis ist in Ordnung (kein IPv6 vorhanden).
	dev="$(route6_dev_for 2606:4700:4700::1111 2>/dev/null)" || dev=""
	if [ -n "$dev" ] && [ "$dev" = "$WG_INTERFACE" ]; then
		SAFETY_REASON="Die IPv6-Default-Route laeuft ueber $WG_INTERFACE."
		return 1
	fi

	# Q3 – Default-Route in irgendeiner Routentabelle ueber den Tunnel.
	local out
	out="$({
		run_timeout "$CMD_TIMEOUT" ip route show table all default 2>/dev/null || true
		run_timeout "$CMD_TIMEOUT" ip -6 route show table all default 2>/dev/null || true
	})"
	if printf '%s' "$out" | grep -qE "dev[[:space:]]+$WG_INTERFACE([[:space:]]|$)"; then
		SAFETY_REASON="In einer Routentabelle existiert eine Default-Route ueber $WG_INTERFACE."
		return 1
	fi

	return 0
}

# Q4 – Laeuft der Pfad zum Prueffziel wirklich durch den Tunnel?
check_probe_path() {
	local target="$1" dev
	SAFETY_REASON=""
	case "$target" in
	*:*) dev="$(route6_dev_for "$target" 2>/dev/null)" || dev="" ;;
	*) dev="$(route_dev_for "$target" 2>/dev/null)" || dev="" ;;
	esac
	if [ -z "$dev" ]; then
		SAFETY_REASON="Fuer $target laesst sich keine Route ermitteln."
		return 1
	fi
	if [ "$dev" != "$WG_INTERFACE" ]; then
		SAFETY_REASON="$target wird ueber $dev geroutet, nicht ueber $WG_INTERFACE."
		return 1
	fi
	return 0
}

# ------------------------------------------------------ Herunterfahren ------

tunnel_link_exists() {
	run_timeout "$CMD_TIMEOUT" ip link show "$WG_INTERFACE" >/dev/null 2>&1
}

# Existiert noch irgendeine Route ueber das Tunnelinterface?
tunnel_routes_exist() {
	local out
	out="$({
		run_timeout "$CMD_TIMEOUT" ip route show table all dev "$WG_INTERFACE" 2>/dev/null || true
		run_timeout "$CMD_TIMEOUT" ip -6 route show table all dev "$WG_INTERFACE" 2>/dev/null || true
	})"
	[ -n "$out" ]
}

# Ist der Tunnel nachweislich unten?
tunnel_is_down() {
	if nm_is_active; then return 1; fi
	if tunnel_link_exists; then return 1; fi
	return 0
}

# ensure_down – faehrt den Tunnel definiert herunter und verifiziert das.
#
# Eskalation, weil ein fehlgeschlagenes nmcli sonst eine blosse Absichts-
# erklaerung waere. Jeder Schritt fasst ausschliesslich das konfigurierte
# Interface an. Rueckgabe 0, wenn das Herunterfahren verifiziert ist.
ensure_down() {
	local reason="${1:-}"
	if [ -n "$reason" ]; then log_info "Fahre Tunnel herunter: $reason"; fi

	if tunnel_is_down; then
		ST_TUNNEL="down"
		return 0
	fi

	# Stufe 1 – der regulaere Weg.
	if nm_is_active; then
		if run_timeout "$NMCLI_DOWN_TIMEOUT" nmcli connection down "$NM_CONNECTION" >/dev/null 2>&1; then
			log_debug "nmcli connection down war erfolgreich."
		else
			log_warn "nmcli connection down ist fehlgeschlagen, eskaliere."
		fi
	fi
	if tunnel_is_down; then
		ST_TUNNEL="down"
		return 0
	fi

	# Stufe 2 – Geraet trennen.
	log_warn "Tunnel ist noch oben, trenne das Geraet $WG_INTERFACE."
	run_timeout "$NMCLI_DOWN_TIMEOUT" nmcli device disconnect "$WG_INTERFACE" >/dev/null 2>&1 || true
	if tunnel_is_down; then
		ST_TUNNEL="down"
		return 0
	fi

	# Stufe 3 – das Interface selbst entfernen. Es gehoert ausschliesslich zu
	# dieser Verbindung, deshalb ist das hier zulaessig.
	log_warn "Entferne das Interface $WG_INTERFACE direkt."
	run_timeout "$CMD_TIMEOUT" ip link set "$WG_INTERFACE" down >/dev/null 2>&1 || true
	run_timeout "$CMD_TIMEOUT" ip link delete "$WG_INTERFACE" >/dev/null 2>&1 || true

	if tunnel_is_down && ! tunnel_routes_exist; then
		ST_TUNNEL="down"
		return 0
	fi

	ST_TUNNEL="unbekannt"
	log_error "Der Tunnel liess sich nicht nachweislich herunterfahren. Interface: $(tunnel_link_exists && printf 'vorhanden' || printf 'weg'), Routen: $(tunnel_routes_exist && printf 'vorhanden' || printf 'weg')."
	return 1
}
