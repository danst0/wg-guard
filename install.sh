#!/usr/bin/env bash
#
# wg-guard – Installer.
#
# Einzeiler:
#   curl -fsSL https://raw.githubusercontent.com/danst0/wg-guard/main/install.sh | sudo bash
#
# Der gesamte Rumpf steht in geschweiften Klammern und endet mit main "$@".
# Dadurch fuehrt ein abgebrochener Download nichts halb aus – bash startet erst,
# wenn der Block vollstaendig gelesen ist.
#
# Interaktive Rueckfragen lesen von /dev/tty, weil stdin bei "curl | bash" die
# Pipe ist. Ohne Terminal werden nur Dateien installiert und der Dienst NICHT
# aktiviert; die Einrichtung erfolgt dann spaeter mit "sudo wg-guard setup".

set -euo pipefail

{
	PREFIX="${PREFIX:-/usr/local}"
	SYSCONFDIR="${SYSCONFDIR:-/etc}"
	STATEDIR="${STATEDIR:-/var/lib/wg-guard}"
	UNITDIR="${UNITDIR:-/etc/systemd/system}"
	DISPATCHDIR="${DISPATCHDIR:-/etc/NetworkManager/dispatcher.d}"
	SUDOERSDIR="${SUDOERSDIR:-/etc/sudoers.d}"
	REPO="${WG_GUARD_REPO:-danst0/wg-guard}"
	REF="${WG_GUARD_REF:-main}"

	FILES_ONLY=0
	RUN_SETUP=1
	SRCDIR=""
	TMPDIR_INSTALL=""
	INSTALLED=()

	say() { printf '%s\n' "$*"; }
	err() { printf 'FEHLER: %s\n' "$*" >&2; }

	cleanup() {
		if [ -n "$TMPDIR_INSTALL" ] && [ -d "$TMPDIR_INSTALL" ]; then
			rm -rf "$TMPDIR_INSTALL"
		fi
	}
	trap cleanup EXIT

	ask_tty() { # ask_tty <frage> <vorgabe>
		local prompt="$1" default="${2:-}" answer=""
		if [ ! -r /dev/tty ]; then
			printf '%s' "$default"
			return 0
		fi
		printf '%s [%s]: ' "$prompt" "$default" >&2
		IFS= read -r answer </dev/tty || true
		[ -n "$answer" ] || answer="$default"
		printf '%s' "$answer"
	}

	ask_yes_no_tty() {
		local answer
		answer="$(ask_tty "$1 (j/n)" "${2:-n}")"
		case "$answer" in
		j | J | ja | Ja | y | Y | yes) return 0 ;;
		*) return 1 ;;
		esac
	}

	usage() {
		cat <<'EOF'
wg-guard-Installer

  --prefix <pfad>       Installationspraefix (Vorgabe: /usr/local)
  --sysconfdir <pfad>   Konfigurationsverzeichnis (Vorgabe: /etc)
  --files-only          nur Dateien installieren, keine Einrichtung
                        (wird vom Autoupdate benutzt)
  --no-setup            installieren, aber die Einrichtung nicht starten
  --help                diese Hilfe

Umgebungsvariablen: WG_GUARD_REF pinnt den Git-Stand, WG_GUARD_REPO das Repo.
EOF
	}

	parse_args() {
		while [ "$#" -gt 0 ]; do
			case "$1" in
			--prefix)
				PREFIX="$2"
				shift 2
				;;
			--sysconfdir)
				SYSCONFDIR="$2"
				shift 2
				;;
			--files-only)
				FILES_ONLY=1
				RUN_SETUP=0
				shift
				;;
			--no-setup)
				RUN_SETUP=0
				shift
				;;
			--help | -h)
				usage
				exit 0
				;;
			*)
				err "Unbekannte Option: $1"
				usage
				exit 2
				;;
			esac
		done
		LIBDIR="${LIBDIR:-$PREFIX/lib}"
		APPDIR="${APPDIR:-$PREFIX/share/applications}"
	}

	# ------------------------------------------------------------- Quelle ----

	# Entweder lokales Checkout oder Release-/Branch-Archiv von GitHub.
	resolve_source() {
		local self="${BASH_SOURCE[0]:-}" self_dir=""
		# Bei "curl | bash" gibt es keine Skriptdatei – dann wird geladen.
		if [ -n "$self" ] && [ -f "$self" ]; then
			self_dir="$(cd "$(dirname "$(readlink -f "$self")")" 2>/dev/null && pwd)" || self_dir=""
		fi
		if [ -n "$self_dir" ] && [ -d "$self_dir/src" ] && [ -d "$self_dir/dist" ]; then
			SRCDIR="$self_dir"
			say "Quelle: lokales Verzeichnis $SRCDIR"
			return 0
		fi

		command -v curl >/dev/null 2>&1 || {
			err "curl wird zum Herunterladen benoetigt."
			return 1
		}
		command -v tar >/dev/null 2>&1 || {
			err "tar wird zum Entpacken benoetigt."
			return 1
		}

		TMPDIR_INSTALL="$(mktemp -d)"
		say "Lade wg-guard ($REF) von github.com/$REPO ..."
		if ! curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" -o "$TMPDIR_INSTALL/src.tar.gz"; then
			err "Der Download ist fehlgeschlagen."
			return 1
		fi
		mkdir -p "$TMPDIR_INSTALL/unpack"
		tar -xzf "$TMPDIR_INSTALL/src.tar.gz" -C "$TMPDIR_INSTALL/unpack"
		SRCDIR="$(find "$TMPDIR_INSTALL/unpack" -maxdepth 2 -name install.sh -printf '%h\n' | head -n1)"
		if [ -z "$SRCDIR" ] || [ ! -d "$SRCDIR/src" ]; then
			err "Das heruntergeladene Archiv hat nicht die erwartete Struktur."
			return 1
		fi
		return 0
	}

	# ---------------------------------------------------- Voraussetzungen ----

	check_prerequisites() {
		if [ "$(id -u)" -ne 0 ]; then
			err "Der Installer muss als root laufen (sudo)."
			return 1
		fi
		if [ ! -d /run/systemd/system ]; then
			err "Dieses System nutzt kein systemd."
			say "wg-guard braucht systemd fuer Dienst, Timer und Logging."
			say "Es wird nichts installiert, statt halb zu funktionieren."
			return 1
		fi
		if ! command -v nmcli >/dev/null 2>&1; then
			err "nmcli wurde nicht gefunden – wg-guard setzt NetworkManager voraus."
			return 1
		fi
		return 0
	}

	# ------------------------------------------------------------ Dateien ----

	render() { # render <vorlage> <ziel>
		sed -e "s|@PREFIX@|$PREFIX|g" \
			-e "s|@LIBDIR@|$LIBDIR|g" \
			-e "s|@SYSCONFDIR@|$SYSCONFDIR|g" \
			-e "s|@STATEDIR@|$STATEDIR|g" \
			"$1" >"$2"
	}

	install_rendered() { # install_rendered <quelle> <ziel> <modus>
		local src="$1" dest="$2" mode="$3"
		mkdir -p "$(dirname "$dest")"
		render "$src" "$dest.wgnew"
		chmod "$mode" "$dest.wgnew"
		mv -f "$dest.wgnew" "$dest"
		INSTALLED+=("$dest")
	}

	install_files() {
		say "Installiere nach $PREFIX ..."

		mkdir -p "$PREFIX/bin" "$LIBDIR/wg-guard/lib" "$STATEDIR" "$SYSCONFDIR/wg-guard" "$APPDIR"
		chmod 0755 "$STATEDIR"

		install_rendered "$SRCDIR/src/wg-guard" "$PREFIX/bin/wg-guard" 0755
		install_rendered "$SRCDIR/src/wg-guard-ctl" "$PREFIX/bin/wg-guard-ctl" 0755
		install_rendered "$SRCDIR/src/wg-guard-toggle" "$PREFIX/bin/wg-guard-toggle" 0755
		install_rendered "$SRCDIR/src/wg-guard-daemon" "$LIBDIR/wg-guard/wg-guard-daemon" 0755
		install_rendered "$SRCDIR/src/wg-guard-update" "$LIBDIR/wg-guard/wg-guard-update" 0755

		local lib
		for lib in "$SRCDIR"/src/lib/*.sh; do
			install_rendered "$lib" "$LIBDIR/wg-guard/lib/$(basename "$lib")" 0644
		done

		cp -f "$SRCDIR/VERSION" "$LIBDIR/wg-guard/VERSION"
		chmod 0644 "$LIBDIR/wg-guard/VERSION"
		INSTALLED+=("$LIBDIR/wg-guard/VERSION")

		# Die Vorlage wird immer aktualisiert, die aktive Konfiguration nie.
		cp -f "$SRCDIR/dist/config.conf.example" "$SYSCONFDIR/wg-guard/config.conf.example"
		chmod 0644 "$SYSCONFDIR/wg-guard/config.conf.example"
		INSTALLED+=("$SYSCONFDIR/wg-guard/config.conf.example")

		if [ ! -e "$SYSCONFDIR/wg-guard/config.conf" ]; then
			cp -f "$SRCDIR/dist/config.conf.example" "$SYSCONFDIR/wg-guard/config.conf"
			chmod 0644 "$SYSCONFDIR/wg-guard/config.conf"
			say "  Konfiguration angelegt: $SYSCONFDIR/wg-guard/config.conf"
		else
			say "  Bestehende Konfiguration bleibt unveraendert."
			report_new_keys
		fi

		install_rendered "$SRCDIR/dist/wg-guard.service.in" "$UNITDIR/wg-guard.service" 0644
		install_rendered "$SRCDIR/dist/wg-guard-update.service.in" "$UNITDIR/wg-guard-update.service" 0644
		install_rendered "$SRCDIR/dist/wg-guard-update.timer.in" "$UNITDIR/wg-guard-update.timer" 0644

		if [ -d "$(dirname "$DISPATCHDIR")" ]; then
			mkdir -p "$DISPATCHDIR"
			install_rendered "$SRCDIR/dist/50-wg-guard.in" "$DISPATCHDIR/50-wg-guard" 0755
		else
			say "  Hinweis: $DISPATCHDIR existiert nicht – der Aufweck-Hook wird ausgelassen."
			say "  wg-guard prueft dann im festen Intervall."
		fi

		install_rendered "$SRCDIR/dist/wg-guard-toggle.desktop.in" "$APPDIR/wg-guard-toggle.desktop" 0644

		install_sudoers
		write_manifest
		fix_selinux
	}

	# Meldet Konfigurationsschluessel, die in der Vorlage neu sind.
	report_new_keys() {
		local key new=()
		while IFS= read -r key; do
			grep -qE "^[[:space:]]*#?$key=" "$SYSCONFDIR/wg-guard/config.conf" || new+=("$key")
		done < <(grep -oE '^#?[A-Z_]+=' "$SRCDIR/dist/config.conf.example" | tr -d '#=' | sort -u)
		if [ "${#new[@]}" -gt 0 ]; then
			say "  Neue Konfigurationsschluessel in dieser Version: ${new[*]}"
			say "  (Vorgaben greifen automatisch, eine Aenderung ist nicht noetig.)"
		fi
	}

	install_sudoers() {
		local target="$SUDOERSDIR/wg-guard" tmp
		if [ ! -d "$SUDOERSDIR" ]; then
			say "  Hinweis: $SUDOERSDIR existiert nicht – der Desktop-Schalter braucht sonst ein Passwort."
			return 0
		fi
		if ! grep -qE '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null; then
			say "  Hinweis: /etc/sudoers bindet /etc/sudoers.d nicht ein."
			say "  Der Desktop-Schalter wuerde nach einem Passwort fragen. Bitte die Zeile"
			say "  '@includedir /etc/sudoers.d' in /etc/sudoers ergaenzen (mit visudo)."
		fi

		tmp="$(mktemp)"
		render "$SRCDIR/dist/wg-guard.sudoers.in" "$tmp"
		if command -v visudo >/dev/null 2>&1; then
			if ! visudo -cf "$tmp" >/dev/null 2>&1; then
				err "Die erzeugte sudoers-Datei ist ungueltig und wird nicht installiert."
				rm -f "$tmp"
				return 0
			fi
		fi
		install -m 0440 -o root -g root "$tmp" "$target"
		rm -f "$tmp"
		INSTALLED+=("$target")

		# Ohne /usr/local/bin im secure_path greift die Regel ins Leere.
		local secure
		secure="$(grep -E '^[[:space:]]*Defaults[[:space:]]+secure_path' /etc/sudoers 2>/dev/null | head -n1)" || true
		if [ -n "$secure" ]; then
			case ":${secure#*=}:" in
			*":$PREFIX/bin:"*) ;;
			*)
				say "  Hinweis: $PREFIX/bin steht nicht im secure_path von sudo."
				say "  Der Desktop-Schalter findet wg-guard-ctl dann eventuell nicht."
				;;
			esac
		fi
	}

	write_manifest() {
		local path
		mkdir -p "$STATEDIR"
		: >"$STATEDIR/manifest"
		for path in "${INSTALLED[@]}"; do
			printf '%s\n' "$path" >>"$STATEDIR/manifest"
		done
		chmod 0644 "$STATEDIR/manifest"

		# Die verwendeten Pfade festhalten, damit Update und Deinstallation
		# auch bei abweichendem PREFIX das Richtige tun.
		cat >"$STATEDIR/install.env" <<EOF
PREFIX="$PREFIX"
LIBDIR="$LIBDIR"
SYSCONFDIR="$SYSCONFDIR"
STATEDIR="$STATEDIR"
UNITDIR="$UNITDIR"
DISPATCHDIR="$DISPATCHDIR"
SUDOERSDIR="$SUDOERSDIR"
APPDIR="$APPDIR"
EOF
		chmod 0644 "$STATEDIR/install.env"
	}

	# Ohne passende Kontexte kann systemd die Skripte auf SELinux-Systemen
	# unter Umstaenden nicht ausfuehren.
	fix_selinux() {
		command -v restorecon >/dev/null 2>&1 || return 0
		local path
		for path in "${INSTALLED[@]}"; do
			[ -e "$path" ] || continue
			restorecon -F "$path" >/dev/null 2>&1 || true
		done
		restorecon -RF "$LIBDIR/wg-guard" >/dev/null 2>&1 || true
	}

	# --------------------------------------------------------------- Ende ----

	finish() {
		systemctl daemon-reload || true

		if [ "$FILES_ONLY" -eq 1 ]; then
			return 0
		fi

		say ""
		say "Dateien installiert."

		if [ ! -r /dev/tty ]; then
			say ""
			say "Kein Terminal verfuegbar – die Einrichtung wurde nicht gestartet"
			say "und der Dienst nicht aktiviert."
			say ""
			say "Naechster Schritt:  sudo wg-guard setup"
			return 0
		fi

		if [ "$RUN_SETUP" -eq 0 ]; then
			say "Naechster Schritt:  sudo wg-guard setup"
			return 0
		fi

		# Bereits eingerichtet? Dann nicht ungefragt durch das Setup laufen.
		if grep -qE '^[[:space:]]*NM_CONNECTION="[^"]+"' "$SYSCONFDIR/wg-guard/config.conf" 2>/dev/null; then
			say "Die Konfiguration ist bereits ausgefuellt – das Setup wird uebersprungen."
			systemctl restart wg-guard.service 2>/dev/null || true
			say ""
			"$PREFIX/bin/wg-guard" status || true
			return 0
		fi

		say ""
		if ask_yes_no_tty "Soll die Einrichtung jetzt starten?" "j"; then
			"$PREFIX/bin/wg-guard" setup || true
		else
			say "Spaeter mit 'sudo wg-guard setup' fortfahren."
		fi
	}

	main() {
		parse_args "$@"
		check_prerequisites || exit 1
		resolve_source || exit 1
		install_files
		finish
	}

	main "$@"
}
