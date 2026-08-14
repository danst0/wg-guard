# shellcheck shell=bash
# wg-guard – die Kaskade.
#
# Jede Stufe muss bestehen, bevor die naechste versucht wird. Der Tunnel gilt
# erst nach Stufe 5 als gesund. Jede Stufe setzt STAGE_REASON, damit `status`
# und das Log erklaeren koennen, woran es lag.

STAGE_REASON=""

# ------------------------------------------- Stufe 0 – ist ueberhaupt Netz? --
#
# Ruhezustand, kein Fehler: erhoeht keinen Backoff-Zaehler. Ein Captive Portal
# zaehlt bewusst dazu – dort wuerde jeder Verbindungsversuch nur scheitern und
# die Hysterese hochtreiben.
stage0_network_ready() {
	STAGE_REASON=""
	local general state conn dev

	general="$(nm_general_state)" || {
		STAGE_REASON="NetworkManager antwortet nicht."
		return 1
	}
	state="${general%% *}"
	conn="${general##* }"

	case "$state" in
	connected*) ;;
	*)
		STAGE_REASON="NetworkManager meldet Zustand \"$state\"."
		return 1
		;;
	esac

	# Die Konnektivitaetsmeldung taugt nur als Ruhegrund, solange der Tunnel
	# unten ist. Im Full-Modus mit laufendem Tunnel ist ein "limited" das
	# Symptom eines toten Tunnels und gehoert in die Gesundheitspruefung –
	# dort fuehrt es zum Herunterfahren statt zum Abwarten.
	if ! is_full_tunnel || tunnel_is_down; then
		case "$conn" in
		full) ;;
		portal)
			STAGE_REASON="Das Netz haengt hinter einer Anmeldeseite (Captive Portal)."
			return 1
			;;
		limited | none | unknown | "")
			STAGE_REASON="Netzverbindung eingeschraenkt (\"${conn:-unbekannt}\")."
			return 1
			;;
		*)
			STAGE_REASON="Unerwarteter Verbindungszustand \"$conn\"."
			return 1
			;;
		esac
	fi

	if is_full_tunnel; then
		# Gesucht ist der Uplink darunter, nicht die Default-Route: die gehoert
		# hier im Betrieb dem Tunnel.
		if uplink_available; then
			return 0
		fi
		STAGE_REASON="$SAFETY_REASON"
		return 1
	fi

	dev="$(route_dev_for 1.1.1.1 2>/dev/null)" || dev=""
	if [ -z "$dev" ]; then
		STAGE_REASON="Es existiert keine Default-Route."
		return 1
	fi
	if [ "$dev" = "$WG_INTERFACE" ]; then
		STAGE_REASON="Die Default-Route laeuft bereits ueber $WG_INTERFACE."
		return 1
	fi

	return 0
}

# ------------------------------------- Stufe 1 – loest der Endpunkt auf? -----
stage1_resolve_endpoint() {
	STAGE_REASON=""
	local host="$ENDPOINT_HOST"

	if [ -z "$host" ]; then
		host="$(nm_endpoint_host 2>/dev/null)" || host=""
	fi
	if [ -z "$host" ]; then
		STAGE_REASON="Der Endpunkt der Verbindung laesst sich nicht ermitteln."
		return 1
	fi

	RESOLVED_ENDPOINT_HOST="$host"

	if is_ip_literal "$host"; then
		RESOLVED_ENDPOINT_IP="$host"
		log_debug "Stufe 1 uebersprungen, Endpunkt ist eine IP-Adresse ($host)."
		return 0
	fi

	local resolved
	if resolved="$(run_timeout "$DNS_TIMEOUT" getent ahosts "$host" 2>/dev/null)"; then
		# Erste Adresse merken: im Full-Modus wird damit geprueft, dass die
		# Route zum Endpunkt nicht durch den Tunnel selbst laeuft.
		RESOLVED_ENDPOINT_IP="$(printf '%s' "$resolved" | awk 'NF{print $1; exit}')"
		return 0
	fi

	STAGE_REASON="Der Endpunkt-Hostname \"$host\" laesst sich nicht aufloesen."
	return 1
}

# ------------------------------------------- Stufe 2 – Verbindung hoch -------
#
# Vor jedem Hochfahren laeuft der vollstaendige Preflight. Direkt danach wird
# geprueft, ob der Tunnel die Default-Route uebernommen hat.
stage2_bring_up() {
	STAGE_REASON=""

	if ! preflight_run; then
		preflight_log
		STAGE_REASON="Preflight fehlgeschlagen ($PREFLIGHT_FAILED Punkte). Es wird nicht hochgefahren."
		return 2 # 2 = Konfigurationsfehler, nicht bloss Netzproblem
	fi
	if [ "$PREFLIGHT_WARNED" -gt 0 ]; then preflight_log; fi

	if nm_is_active; then
		log_debug "Verbindung ist bereits aktiv, uebernehme sie."
	else
		log_info "Fahre Tunnel \"$NM_CONNECTION\" hoch."
		local rc=0
		run_timeout "$((NMCLI_UP_TIMEOUT + 5))" nmcli --wait "$NMCLI_UP_TIMEOUT" connection up "$NM_CONNECTION" >/dev/null 2>&1 || rc=$?
		if [ "$rc" -ne 0 ]; then
			STAGE_REASON="nmcli connection up ist fehlgeschlagen (Code $rc)."
			return 1
		fi
	fi

	if ! tunnel_link_exists; then
		STAGE_REASON="Das Interface $WG_INTERFACE existiert nach dem Hochfahren nicht."
		return 1
	fi

	# Routenpruefung sofort nach dem Hochfahren – im Full-Modus gespiegelt.
	if ! check_routing_safe; then
		STAGE_REASON="Sicherheitsverletzung nach dem Hochfahren: $SAFETY_REASON"
		return 3 # 3 = Sicherheitsverletzung, sofort down ohne Toleranz
	fi

	return 0
}

# --------------------------------------------- Stufe 3 – frischer Handshake --
#
# Der Handshake erneuert sich nur bei Traffic. Statt passiv zu warten, erzeugt
# diese Stufe selbst Traffic und pollt parallel – sonst wuerde ein gesunder,
# aber ungenutzter Tunnel als tot gelten.
wg_latest_handshake() {
	local out newest=0 ts
	out="$(run_timeout "$CMD_TIMEOUT" wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null)" || return 1
	[ -n "$out" ] || return 1
	while read -r _ ts; do
		[ -n "$ts" ] || continue
		case "$ts" in *[!0-9]*) continue ;; esac
		if [ "$ts" -gt "$newest" ]; then newest="$ts"; fi
	done <<<"$out"
	printf '%s' "$newest"
}

# Erzeugt einmal Traffic durch den Tunnel, damit ein Handshake ausgeloest wird.
# Das Ergebnis ist bewusst egal.
poke_tunnel() {
	[ -n "$PING_HOST" ] || return 0
	local args=(-n -q -c 1)
	if [ -n "$PING_TIMEOUT_FLAG" ]; then args+=("$PING_TIMEOUT_FLAG" 1); fi
	if [ -n "$PING_BIND_FLAG" ]; then args+=("$PING_BIND_FLAG" "$WG_INTERFACE"); fi
	run_timeout 3 ping "${args[@]}" "$PING_HOST" >/dev/null 2>&1 || true
}

stage3_handshake() {
	STAGE_REASON=""
	local deadline age ts start
	start="$(now)"
	deadline=$((start + HANDSHAKE_GRACE))

	while :; do
		ts="$(wg_latest_handshake)" || ts=""
		if [ -n "$ts" ] && [ "$ts" -gt 0 ]; then
			age=$(($(now) - ts))
			if [ "$age" -le "$HANDSHAKE_MAX_AGE" ]; then
				log_debug "Handshake ist ${age}s alt."
				return 0
			fi
		fi
		if [ "$(now)" -ge "$deadline" ]; then break; fi
		poke_tunnel
		wait_interval 2
	done

	if [ -z "$ts" ]; then
		STAGE_REASON="wg show liefert keinen Handshake fuer $WG_INTERFACE."
	elif [ "$ts" -eq 0 ]; then
		STAGE_REASON="Es hat noch nie ein Handshake stattgefunden (Gegenstelle antwortet nicht)."
	else
		STAGE_REASON="Der letzte Handshake ist $(($(now) - ts))s alt, erlaubt sind ${HANDSHAKE_MAX_AGE}s."
	fi
	return 1
}

# Schnelle Variante fuer den gesunden Zustand: nur pruefen, nicht warten.
stage3_handshake_quick() {
	STAGE_REASON=""
	local ts age
	ts="$(wg_latest_handshake)" || ts=""
	if [ -z "$ts" ] || [ "$ts" -eq 0 ]; then
		STAGE_REASON="Kein gueltiger Handshake auf $WG_INTERFACE."
		return 1
	fi
	age=$(($(now) - ts))
	if [ "$age" -gt "$HANDSHAKE_MAX_AGE" ]; then
		STAGE_REASON="Der letzte Handshake ist ${age}s alt, erlaubt sind ${HANDSHAKE_MAX_AGE}s."
		return 1
	fi
	return 0
}

# ------------------------------------------------- Stufe 4 – interner Ping --
stage4_ping() {
	STAGE_REASON=""
	[ "$STAGE4_ENABLED" = "yes" ] || {
		log_debug "Stufe 4 ist deaktiviert."
		return 0
	}
	if [ -z "$PING_HOST" ]; then
		# Im Full-Modus traegt Stufe 6 die Pruefung; ein internes Ziel ist
		# dort optional.
		if is_full_tunnel; then
			log_debug "Stufe 4 uebersprungen, kein internes Ziel konfiguriert."
			return 0
		fi
		STAGE_REASON="PING_HOST ist nicht konfiguriert."
		return 1
	fi

	# Q4 – der Pfad muss durch den Tunnel laufen, sonst testen wir das LAN.
	if ! check_probe_path "$PING_HOST"; then
		STAGE_REASON="$SAFETY_REASON"
		return 3
	fi

	local args=(-n -q -c "$PING_COUNT")
	if [ -n "$PING_TIMEOUT_FLAG" ]; then args+=("$PING_TIMEOUT_FLAG" "$PING_TIMEOUT"); fi
	if [ -n "$PING_BIND_FLAG" ]; then args+=("$PING_BIND_FLAG" "$WG_INTERFACE"); fi

	if run_timeout "$((PING_TIMEOUT + 3))" ping "${args[@]}" "$PING_HOST" >/dev/null 2>&1; then
		return 0
	fi
	STAGE_REASON="Der interne Host $PING_HOST antwortet nicht auf Ping."
	return 1
}

# ------------------------------------------- Stufe 5 – interner TCP-Dienst --
stage5_tcp() {
	STAGE_REASON=""
	[ -n "$TCP_HEALTH" ] || {
		log_debug "Stufe 5 ist deaktiviert (kein TCP_HEALTH konfiguriert)."
		return 0
	}

	local host port
	read -r host port <<<"$(tcp_split_host "$TCP_HEALTH")"
	if [ -z "$host" ] || [ -z "$port" ]; then
		STAGE_REASON="TCP_HEALTH=\"$TCP_HEALTH\" ist kein gueltiges Host:Port."
		return 1
	fi

	if ! check_probe_path "$host"; then
		STAGE_REASON="$SAFETY_REASON"
		return 3
	fi

	if [ "$TCP_METHOD" = "nc" ]; then
		if run_timeout "$((TCP_TIMEOUT + 2))" nc -z -w "$TCP_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
			return 0
		fi
	else
		if run_timeout "$TCP_TIMEOUT" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1; then
			return 0
		fi
	fi

	STAGE_REASON="Der interne Dienst $host:$port nimmt keine TCP-Verbindung an."
	return 1
}

# ------------------------------ Stufe 6 – Internet durch den Tunnel ---------
#
# Nur im Full-Modus, und dort die wichtigste Stufe: ohne sie wuerde ein Tunnel
# als gesund gelten, der zwar steht, hinter dem aber kein Internet mehr ist –
# genau der Zustand, in dem die Nutzerin vor einem toten Rechner sitzt.
stage6_external() {
	STAGE_REASON=""
	is_full_tunnel || return 0

	local host port rc=0

	if [ -n "$EXTERNAL_CHECK_HOST" ]; then
		# Der Weg dorthin muss durch den Tunnel fuehren, sonst pruefen wir den
		# Uplink statt des Tunnels.
		if ! check_probe_path "$EXTERNAL_CHECK_HOST"; then
			STAGE_REASON="$SAFETY_REASON"
			return 3
		fi
		if [ "$STAGE4_ENABLED" = "yes" ]; then
			local args=(-n -q -c "$PING_COUNT")
			if [ -n "$PING_TIMEOUT_FLAG" ]; then args+=("$PING_TIMEOUT_FLAG" "$PING_TIMEOUT"); fi
			if [ -n "$PING_BIND_FLAG" ]; then args+=("$PING_BIND_FLAG" "$WG_INTERFACE"); fi
			if ! run_timeout "$((PING_TIMEOUT + 3))" ping "${args[@]}" "$EXTERNAL_CHECK_HOST" >/dev/null 2>&1; then
				STAGE_REASON="Durch den Tunnel ist $EXTERNAL_CHECK_HOST nicht erreichbar – der Tunnel steht, aber dahinter ist kein Internet."
				return 1
			fi
		fi
	fi

	if [ -n "$EXTERNAL_CHECK_TCP" ]; then
		read -r host port <<<"$(tcp_split_host "$EXTERNAL_CHECK_TCP")"
		if [ -z "$host" ] || [ -z "$port" ]; then
			STAGE_REASON="EXTERNAL_CHECK_TCP=\"$EXTERNAL_CHECK_TCP\" ist kein gueltiges Host:Port."
			return 1
		fi
		if ! check_probe_path "$host"; then
			STAGE_REASON="$SAFETY_REASON"
			return 3
		fi
		if [ "$TCP_METHOD" = "nc" ]; then
			run_timeout "$((TCP_TIMEOUT + 2))" nc -z -w "$TCP_TIMEOUT" "$host" "$port" >/dev/null 2>&1 || rc=$?
		else
			run_timeout "$TCP_TIMEOUT" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1 || rc=$?
		fi
		if [ "$rc" -ne 0 ]; then
			STAGE_REASON="Durch den Tunnel nimmt $host:$port keine Verbindung an – der Tunnel steht, aber dahinter ist kein Internet."
			return 1
		fi
	fi

	return 0
}
