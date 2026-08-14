#!/usr/bin/env bash
#
# wg-guard – Deinstallation.
#
# Raeumt restlos auf: Dienst und Timer stoppen, den Tunnel definiert
# herunterfahren, alle installierten Dateien entfernen. Die
# NetworkManager-Verbindung selbst wird nicht angefasst – sie gehoert nicht uns.
#
#   sudo ./uninstall.sh            Programm entfernen, Konfiguration behalten
#   sudo ./uninstall.sh --purge    zusaetzlich Konfiguration, Zustand und Gruppe

set -euo pipefail

{
	PURGE=0
	STATEDIR="${STATEDIR:-/var/lib/wg-guard}"
	SYSCONFDIR="${SYSCONFDIR:-/etc}"
	PREFIX="${PREFIX:-/usr/local}"

	say() { printf '%s\n' "$*"; }

	usage() {
		cat <<'EOF'
wg-guard deinstallieren

  --purge   auch Konfiguration (/etc/wg-guard), Zustand (/var/lib/wg-guard)
            und die Gruppe wgguard entfernen
  --help    diese Hilfe
EOF
	}

	load_install_env() {
		# Die beim Installieren verwendeten Pfade, falls vorhanden.
		if [ -r "$STATEDIR/install.env" ]; then
			# shellcheck source=/dev/null
			. "$STATEDIR/install.env"
		fi
		LIBDIR="${LIBDIR:-$PREFIX/lib}"
		UNITDIR="${UNITDIR:-/etc/systemd/system}"
		DISPATCHDIR="${DISPATCHDIR:-/etc/NetworkManager/dispatcher.d}"
		SUDOERSDIR="${SUDOERSDIR:-/etc/sudoers.d}"
		APPDIR="${APPDIR:-$PREFIX/share/applications}"
	}

	stop_services() {
		say "Stoppe Dienst und Timer ..."
		systemctl disable --now wg-guard-update.timer >/dev/null 2>&1 || true
		systemctl disable --now wg-guard.service >/dev/null 2>&1 || true

		# Sicherstellen, dass der Tunnel wirklich unten ist – der Watchdog
		# passt ab jetzt nicht mehr darauf auf.
		if [ -x "$LIBDIR/wg-guard/wg-guard-daemon" ]; then
			"$LIBDIR/wg-guard/wg-guard-daemon" --down-only >/dev/null 2>&1 || true
		fi
	}

	remove_files() {
		local path removed=0
		if [ -r "$STATEDIR/manifest" ]; then
			while IFS= read -r path; do
				[ -n "$path" ] || continue
				if [ -e "$path" ]; then
					rm -f "$path"
					removed=$((removed + 1))
				fi
			done <"$STATEDIR/manifest"
			say "Entfernt: $removed Datei(en) laut Manifest."
		else
			say "Kein Manifest gefunden – entferne die bekannten Standardpfade."
			rm -f "$PREFIX/bin/wg-guard" "$PREFIX/bin/wg-guard-ctl" "$PREFIX/bin/wg-guard-toggle"
			rm -f "$UNITDIR/wg-guard.service" "$UNITDIR/wg-guard-update.service" "$UNITDIR/wg-guard-update.timer"
			rm -f "$DISPATCHDIR/50-wg-guard" "$SUDOERSDIR/wg-guard"
			rm -f "$APPDIR/wg-guard-toggle.desktop"
		fi
		rm -rf "$LIBDIR/wg-guard"
		systemctl daemon-reload || true
	}

	purge_rest() {
		say "Entferne Konfiguration und Zustand ..."
		rm -rf "$SYSCONFDIR/wg-guard"
		rm -rf "$STATEDIR"
		rm -rf /run/wg-guard
		if getent group wgguard >/dev/null 2>&1; then
			groupdel wgguard >/dev/null 2>&1 || say "Die Gruppe wgguard liess sich nicht entfernen (noch in Benutzung?)."
		fi
	}

	main() {
		while [ "$#" -gt 0 ]; do
			case "$1" in
			--purge)
				PURGE=1
				shift
				;;
			--help | -h)
				usage
				exit 0
				;;
			*)
				say "Unbekannte Option: $1"
				usage
				exit 2
				;;
			esac
		done

		if [ "$(id -u)" -ne 0 ]; then
			say "FEHLER: Bitte mit sudo ausfuehren."
			exit 1
		fi

		load_install_env
		stop_services
		remove_files

		if [ "$PURGE" -eq 1 ]; then
			purge_rest
		else
			say "Konfiguration unter $SYSCONFDIR/wg-guard bleibt erhalten (--purge entfernt sie)."
		fi

		say ""
		say "wg-guard ist entfernt. Die NetworkManager-Verbindung wurde nicht veraendert."
	}

	main "$@"
}
