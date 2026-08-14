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

# Die Firewall-Markierung, mit der WireGuard seine eigenen Pakete kennzeichnet.
# NetworkManager vergibt sie bei einem Peer mit Default-Route automatisch und
# haelt die Tunnelpakete damit ueber Policy-Routing aus dem Tunnel heraus.
wg_fwmark() {
	local out
	out="$(run_timeout "$CMD_TIMEOUT" wg show "$WG_INTERFACE" fwmark 2>/dev/null)" || return 1
	case "$out" in
	off | "" | 0 | 0x0) return 1 ;;
	esac
	printf '%s' "$out"
}

# Ueber welches Geraet erreicht der Tunnel selbst seinen Endpunkt?
#
# Ohne die Markierung ist die Frage nicht sinnvoll zu beantworten: bei einem
# Full-Tunnel zeigt "ip route get" fuer jede Adresse auf den Tunnel, auch fuer
# den Endpunkt. Die echten WireGuard-Pakete tragen aber die fwmark und werden
# an der Tunneltabelle vorbeigeleitet. Wer das ignoriert, haelt einen voellig
# gesunden Full-Tunnel faelschlich fuer eine Routenschleife.
endpoint_route_dev() {
	local target="$1" mark out
	if mark="$(wg_fwmark)"; then
		out="$(run_timeout "$CMD_TIMEOUT" ip route get "$target" mark "$mark" 2>/dev/null)" || out=""
		if [ -n "$out" ]; then
			printf '%s' "$out" | sed -n 's/.*[[:space:]]dev[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | head -n1
			return 0
		fi
	fi
	route_dev_for "$target"
}

# Q1f/Q5 – die Spiegelung fuer den Full-Tunnel.
#
# Hier ist die Default-Route am Tunnel der Normalzustand; ihr Fehlen waere der
# Fehler. Zusaetzlich darf die Route zum VPN-Endpunkt selbst niemals durch den
# Tunnel laufen, sonst versucht er sich selbst zu tunneln.
check_full_tunnel_routing() {
	SAFETY_REASON=""
	local dev

	# Q1f – der Verkehr muss tatsaechlich im Tunnel landen.
	dev="$(route_dev_for 1.1.1.1 2>/dev/null)" || dev=""
	if [ -z "$dev" ]; then
		SAFETY_REASON="Es laesst sich keine Default-Route ermitteln."
		return 1
	fi
	if [ "$dev" != "$WG_INTERFACE" ]; then
		SAFETY_REASON="Die Default-Route laeuft ueber $dev statt ueber $WG_INTERFACE – der Verkehr geht am Tunnel vorbei."
		return 1
	fi

	# Q5 – Routenschleife zum Endpunkt ausschliessen.
	local endpoint
	endpoint="${RESOLVED_ENDPOINT_IP:-}"
	if [ -n "$endpoint" ]; then
		dev="$(endpoint_route_dev "$endpoint")" || dev=""
		if [ -n "$dev" ] && [ "$dev" = "$WG_INTERFACE" ]; then
			SAFETY_REASON="Die Route zum VPN-Endpunkt $endpoint laeuft durch den Tunnel selbst – das kann nicht funktionieren."
			return 1
		fi
	fi

	return 0
}

# Einstiegspunkt fuer beide Betriebsarten.
check_routing_safe() {
	if is_full_tunnel; then
		check_full_tunnel_routing
		return $?
	fi
	check_default_route_safe
	return $?
}

# Gibt es einen nutzbaren Uplink unterhalb des Tunnels?
#
# Im Full-Modus taugt die Default-Route dafuer nicht als Kriterium – die gehoert
# im Betrieb dem Tunnel. Gesucht ist ein Weg nach draussen an ihm vorbei:
# entweder eine Default-Route ueber ein anderes Geraet oder eine Route zum
# VPN-Endpunkt, die nicht durch den Tunnel laeuft.
uplink_available() {
	SAFETY_REASON=""
	local out dev

	# Verlaesslichstes Kriterium, weil unabhaengig von der Routenlage und auch
	# direkt nach einem Neustart des Daemons gueltig.
	if nm_uplink_connected; then
		return 0
	fi

	out="$(run_timeout "$CMD_TIMEOUT" ip route show default 2>/dev/null || true)"
	if printf '%s' "$out" | grep -q 'default' &&
		printf '%s' "$out" | grep -qv "dev $WG_INTERFACE"; then
		return 0
	fi

	if [ -n "${RESOLVED_ENDPOINT_IP:-}" ]; then
		dev="$(route_dev_for "$RESOLVED_ENDPOINT_IP" 2>/dev/null)" || dev=""
		if [ -n "$dev" ] && [ "$dev" != "$WG_INTERFACE" ]; then
			return 0
		fi
	fi

	SAFETY_REASON="Es ist kein Uplink erkennbar, der nicht durch den Tunnel laeuft."
	return 1
}

# Nach dem Herunterfahren im Full-Modus: es muss wieder eine Default-Route
# geben, die nicht am Tunnel haengt. Sonst waere der Rechner offline, und genau
# das soll dieses Werkzeug verhindern.
verify_uplink_restored() {
	SAFETY_REASON=""
	local out
	out="$(run_timeout "$CMD_TIMEOUT" ip route show default 2>/dev/null || true)"
	if [ -z "$out" ]; then
		SAFETY_REASON="Nach dem Herunterfahren existiert keine Default-Route mehr."
		return 1
	fi
	if ! printf '%s' "$out" | grep -qv "dev $WG_INTERFACE"; then
		SAFETY_REASON="Die einzige Default-Route zeigt weiterhin auf $WG_INTERFACE."
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

# Nach einem harten "ip link delete" weiss NetworkManager nichts vom
# Verschwinden des Interfaces und nimmt seine DNS-Einstellungen unter Umstaenden
# nicht zurueck. Beim Split-Tunnel ist das folgenlos; beim Full-Tunnel zeigt die
# Namensaufloesung danach auf einen Server hinter dem toten Tunnel – fuer die
# Nutzerin sieht das aus wie "Internet immer noch kaputt".
#
# Aufgefrischt wird ausschliesslich die DNS-Konfiguration, es wird keine fremde
# Verbindung angefasst.
restore_dns_after_hard_down() {
	is_full_tunnel || return 0
	[ "$RESTORE_DNS_AFTER_HARD_DOWN" = "yes" ] || return 0

	log_info "Frische die DNS-Konfiguration auf, damit keine Reste des Tunnels zurueckbleiben."
	if command -v resolvectl >/dev/null 2>&1; then
		run_timeout "$CMD_TIMEOUT" resolvectl revert "$WG_INTERFACE" >/dev/null 2>&1 || true
	fi
	run_timeout "$CMD_TIMEOUT" nmcli general reload dns-full >/dev/null 2>&1 || true
}

# Nach dem Herunterfahren im Full-Modus pruefen, ob der Rechner wieder online
# ist. Reparieren kann wg-guard das nicht, ohne fremde Verbindungen anzufassen –
# aber es muss laut sagen, wenn etwas nicht stimmt.
check_uplink_after_down() {
	is_full_tunnel || return 0
	if verify_uplink_restored; then
		log_debug "Uplink nach dem Herunterfahren wiederhergestellt."
		return 0
	fi
	log_error "Nach dem Herunterfahren ist der Rechner offline: $SAFETY_REASON"
	log_error "Bitte die normale Netzwerkverbindung pruefen – wg-guard fasst fremde Verbindungen bewusst nicht an."
	return 1
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
		check_uplink_after_down
		return 0
	fi

	# Stufe 2 – Geraet trennen.
	log_warn "Tunnel ist noch oben, trenne das Geraet $WG_INTERFACE."
	run_timeout "$NMCLI_DOWN_TIMEOUT" nmcli device disconnect "$WG_INTERFACE" >/dev/null 2>&1 || true
	if tunnel_is_down; then
		ST_TUNNEL="down"
		check_uplink_after_down
		return 0
	fi

	# Stufe 3 – das Interface selbst entfernen. Es gehoert ausschliesslich zu
	# dieser Verbindung, deshalb ist das hier zulaessig.
	log_warn "Entferne das Interface $WG_INTERFACE direkt."
	run_timeout "$CMD_TIMEOUT" ip link set "$WG_INTERFACE" down >/dev/null 2>&1 || true
	run_timeout "$CMD_TIMEOUT" ip link delete "$WG_INTERFACE" >/dev/null 2>&1 || true
	restore_dns_after_hard_down

	if tunnel_is_down && ! tunnel_routes_exist; then
		ST_TUNNEL="down"
		check_uplink_after_down
		return 0
	fi

	ST_TUNNEL="unbekannt"
	log_error "Der Tunnel liess sich nicht nachweislich herunterfahren. Interface: $(tunnel_link_exists && printf 'vorhanden' || printf 'weg'), Routen: $(tunnel_routes_exist && printf 'vorhanden' || printf 'weg')."
	return 1
}
