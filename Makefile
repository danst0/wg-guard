# wg-guard – Entwicklungsziele.
#
#   make syntax   bash -n ueber alle Skripte
#   make lint     shellcheck
#   make test     Testsuite mit Mocks (braucht kein Netz, keinen Tunnel)
#   make check    alles drei
#   make install  lokal installieren (PREFIX=... moeglich)
#   make release VERSION=x.y.z   Tag, Push und GitHub-Release mit SHA256SUMS

SHELL := /bin/bash
PREFIX ?= /usr/local
REPO   ?= danst0/wg-guard

SCRIPTS := src/wg-guard src/wg-guard-ctl src/wg-guard-toggle \
           src/wg-guard-daemon src/wg-guard-update \
           install.sh uninstall.sh
LIBS    := $(wildcard src/lib/*.sh)
TESTS   := tests/run.sh $(wildcard tests/cases/*.sh) $(wildcard tests/mocks/*)

.PHONY: all check syntax lint test verify-dist install uninstall release dist clean

all: check

check: syntax lint test verify-dist

syntax:
	@for f in $(SCRIPTS) $(LIBS) tests/run.sh; do \
		bash -n "$$f" || exit 1; \
	done
	@echo "Syntax in Ordnung."

lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "shellcheck ist nicht installiert - uebersprungen."; exit 0; }
	shellcheck -x -S style $(SCRIPTS) $(LIBS)
	shellcheck -x -S style -s bash tests/run.sh $(wildcard tests/cases/*.sh) \
	    tests/lib/harness.sh $(wildcard tests/mocks/*)
	shellcheck -S style -s sh dist/50-wg-guard.in
	@echo "shellcheck sauber."

# Prueft die erzeugten Systemdateien mit den Werkzeugen der jeweiligen Formate.
verify-dist:
	@tmp=$$(mktemp -d); \
	mkdir -p "$$tmp/root/lib/wg-guard" "$$tmp/root/bin"; \
	for b in wg-guard-daemon wg-guard-update; do \
	  printf '#!/bin/sh\n' > "$$tmp/root/lib/wg-guard/$$b"; \
	  chmod +x "$$tmp/root/lib/wg-guard/$$b"; \
	done; \
	printf '#!/bin/sh\n' > "$$tmp/root/bin/wg-guard-toggle"; \
	chmod +x "$$tmp/root/bin/wg-guard-toggle"; \
	for f in dist/*.in; do \
	  out="$$tmp/$$(basename "$$f" .in)"; \
	  sed -e "s|@PREFIX@|$$tmp/root|g" -e "s|@LIBDIR@|$$tmp/root/lib|g" \
	      -e 's|@SYSCONFDIR@|/etc|g' -e 's|@STATEDIR@|/var/lib/wg-guard|g' \
	      "$$f" > "$$out"; \
	done; \
	if command -v systemd-analyze >/dev/null 2>&1; then \
	  systemd-analyze verify "$$tmp"/wg-guard.service "$$tmp"/wg-guard-update.service \
	      "$$tmp"/wg-guard-update.timer || exit 1; \
	  echo "systemd-Units in Ordnung."; \
	fi; \
	if command -v visudo >/dev/null 2>&1; then \
	  visudo -cf "$$tmp"/wg-guard.sudoers >/dev/null || exit 1; \
	  echo "sudoers-Datei in Ordnung."; \
	fi; \
	if command -v desktop-file-validate >/dev/null 2>&1; then \
	  desktop-file-validate "$$tmp"/wg-guard-toggle.desktop || exit 1; \
	  echo "Desktop-Eintrag in Ordnung."; \
	fi; \
	rm -rf "$$tmp"

test:
	@bash tests/run.sh

install:
	@sudo PREFIX=$(PREFIX) bash install.sh --prefix $(PREFIX)

uninstall:
	@sudo bash uninstall.sh

# Erzeugt das Release-Archiv samt Pruefsumme – genau das, was der Updater laedt.
dist:
	@test -n "$(VERSION)" || { echo "VERSION=x.y.z angeben"; exit 1; }
	@rm -rf build && mkdir -p build/wg-guard-$(VERSION)
	@cp -a src dist install.sh uninstall.sh README.md LICENSE VERSION Makefile \
	      build/wg-guard-$(VERSION)/
	@cd build && tar -czf wg-guard-$(VERSION).tar.gz wg-guard-$(VERSION)
	@cd build && sha256sum wg-guard-$(VERSION).tar.gz > SHA256SUMS
	@echo "build/wg-guard-$(VERSION).tar.gz und build/SHA256SUMS erzeugt."

release:
	@test -n "$(VERSION)" || { echo "VERSION=x.y.z angeben"; exit 1; }
	@git diff --quiet || { echo "Arbeitsverzeichnis ist nicht sauber."; exit 1; }
	@echo "$(VERSION)" > VERSION
	@$(MAKE) check
	@$(MAKE) dist VERSION=$(VERSION)
	@git add VERSION && git commit -m "Release v$(VERSION)" || true
	@git tag -a "v$(VERSION)" -m "wg-guard v$(VERSION)"
	@git push origin main --tags
	@gh release create "v$(VERSION)" \
	    build/wg-guard-$(VERSION).tar.gz build/SHA256SUMS \
	    --repo $(REPO) --title "wg-guard v$(VERSION)" \
	    --notes "Siehe README fuer Installation und Konfiguration."
	@echo "Release v$(VERSION) veroeffentlicht."

clean:
	@rm -rf build
