# wg-guard

Ein Watchdog für eine bestehende WireGuard-Verbindung unter NetworkManager.

wg-guard richtet **keinen** Tunnel ein. Es überwacht einen vorhandenen
Split-Tunnel und sorgt dafür, dass er nur dann oben ist, wenn kaskadiert
nachgewiesen ist, dass er funktioniert. In jedem anderen Fall fährt es ihn
herunter.

Bedient wird das Ganze über einen einzigen Eintrag im Anwendungsmenü –
„VPN pausieren / aktivieren". Ein Terminal ist im Alltag nicht nötig.

## Warum fail-safe-**down**?

Die meisten VPN-Werkzeuge sind fail-safe-**up** gebaut: Sie nehmen an, dass der
Tunnel das Wichtigste ist, und schneiden im Zweifel den Verkehr ab (Kill-Switch),
damit nichts am Tunnel vorbeiläuft.

Hier ist es genau umgekehrt, und das ist Absicht:

> Der Rechner darf unter keinen Umständen seine normale Internetverbindung
> verlieren, weil der Tunnel Probleme hat.

Der Tunnel erschließt nur interne Adressbereiche. Fällt er aus, ist das
unangenehm – aber wenn dabei das Internet mit ausfällt, steht jemand ohne
Arbeitsgerät und ohne Möglichkeit da, das selbst zu reparieren. Deshalb gilt
durchgehend: **jeder unerwartete Zustand, jeder Fehler, jedes nicht
interpretierbare Kommandoergebnis führt zum Herunterfahren des Tunnels.**
Es gibt bewusst **keinen Kill-Switch**.

Konkret heißt das:

- wg-guard fasst ausschließlich die eine konfigurierte NM-Verbindung an.
  Niemals andere Verbindungen, niemals `/etc/resolv.conf`, niemals globale
  Routen, niemals iptables oder nftables.
- Vor jedem Hochfahren läuft ein Preflight. Ist auch nur eine Invariante
  verletzt, wird nicht hochgefahren – und der Grund landet im Log.
- Nach jedem Hochfahren und in jedem gesunden Zyklus wird geprüft, ob der
  Tunnel die Default-Route an sich gezogen hat. Wenn ja: sofort herunter.
- Ein unerwarteter Fehler im Programm selbst fährt den Tunnel herunter und
  beendet den Dienst. systemd startet ihn neu, und die Kaskade beginnt von vorn.

## Installation

```
curl -fsSL https://raw.githubusercontent.com/danst0/wg-guard/main/install.sh | sudo bash
```

Der Installer ist idempotent, respektiert eine vorhandene Konfiguration und
startet beim ersten Lauf die interaktive Einrichtung.

Weil dieses Skript als root läuft, hier der geprüfte Weg – er tut dasselbe,
lässt aber vorher einen Blick hineinwerfen:

```
curl -fsSL -O https://raw.githubusercontent.com/danst0/wg-guard/main/install.sh
less install.sh
sudo bash install.sh
```

Eine bestimmte Version festnageln: `WG_GUARD_REF=v0.1.0` vor den Aufruf setzen.
Anderes Installationsziel: `--prefix /opt/wg-guard`.

**Voraussetzung:** Die WireGuard-Verbindung muss bereits als
NetworkManager-Verbindung existieren. Die Einrichtung listet alle gefundenen
WireGuard-Verbindungen auf und leitet Interface und Endpunkt selbst ab.

### Was die Einrichtung fragt

1. Welche WireGuard-Verbindung überwacht werden soll (Auswahl aus einer Liste).
2. Welcher interne Host per Ping erreichbar sein muss – mit einem Vorschlag aus
   den AllowedIPs.
3. Welcher interne TCP-Dienst erreichbar sein muss (Host:Port, optional).
4. Ob die gefundenen Preflight-Abweichungen behoben werden sollen – einzeln, mit
   Anzeige des genauen Kommandos. Es wird **nichts** stillschweigend geändert.
5. Für welche Benutzerin der VPN-Schalter freigeschaltet wird.

Alles andere ermittelt die Einrichtung selbst: Interface-Name, Endpunkt,
ping-Flags, TCP-Methode, SELinux-Kontexte, sudo-Konfiguration.

## Bedienung

### Für die Nutzerin

Ein Eintrag im Anwendungsmenü: **„VPN pausieren / aktivieren"**. Ein Klick
schaltet um, eine Benachrichtigung meldet den neuen Zustand – beim Aktivieren
erst dann, wenn feststeht, ob es geklappt hat, und andernfalls mit einem Satz,
der ohne Vorwissen verständlich ist („Die Gegenstelle antwortet nicht. Es wird
automatisch weiter versucht."). Die Pause überlebt einen Neustart.

### Auf der Kommandozeile

| Befehl | Wirkung |
|---|---|
| `wg-guard status` | Zustand im Klartext: welche Stufe zuletzt scheiterte, seit wann, wann der nächste Versuch läuft |
| `wg-guard check` | Vollständige Diagnose, **rein lesend** – fährt nie etwas hoch oder herunter |
| `wg-guard pause` / `resume` | VPN pausieren bzw. wieder freigeben |
| `wg-guard logs [-f]` | Protokoll aus journald |
| `wg-guard preflight [--fix]` | Sicherheitsprüfung der NM-Verbindung, optional mit Rückfrage reparieren |
| `wg-guard setup` | Einrichtung erneut durchlaufen |
| `wg-guard update [--check]` | Auf eine neue Version prüfen und aktualisieren |

`status` und `check` funktionieren ohne root; `check` ist ohne root nur
eingeschränkt aussagekräftig, weil AllowedIPs und Handshake dann nicht lesbar
sind.

## Wie die Prüfung abläuft

Jede Stufe muss bestehen, bevor die nächste versucht wird:

| Stufe | Prüfung | Bei Fehlschlag |
|---|---|---|
| 0 | Ist überhaupt Netz da? NM meldet `connected` und `full`, es existiert eine Default-Route, und sie führt nicht durch den Tunnel | **Ruhezustand**, kein Fehler: Tunnel bleibt unten, kein Backoff |
| 1 | Löst der Endpunkt-Hostname auf? | kein Verbindungsversuch, Backoff |
| 2 | Preflight, dann `nmcli connection up`, dann sofort Routenprüfung | herunterfahren, Backoff |
| 3 | Frischer WireGuard-Handshake | herunterfahren, Backoff |
| 4 | Ping auf den internen Host, gebunden an das Tunnel-Interface | Toleranz, dann herunterfahren |
| 5 | TCP-Verbindung zum internen Dienst | Toleranz, dann herunterfahren |

Erst nach Stufe 5 gilt der Tunnel als gesund. Im gesunden Zustand wird seltener
geprüft (Vorgabe: alle 60 s), im Fehlerzustand häufiger.

Zwei Details, die in der Praxis den Unterschied machen:

- **Stufe 3 wartet nicht passiv.** Ein WireGuard-Handshake erneuert sich nur bei
  Verkehr. wg-guard erzeugt deshalb im Sekundentakt selbst welchen, während es
  auf den Handshake wartet – sonst würde ein gesunder, aber ungenutzter Tunnel
  als tot gelten. `PersistentKeepalive` sollte trotzdem gesetzt sein; der
  Preflight warnt, wenn es fehlt.
- **Ein einzelner verlorener Ping reißt nichts ab.** Erst zwei aufeinander­
  folgende Fehlschläge auf Stufe 4 oder 5 führen zum Herunterfahren
  (`HEALTH_FAILURES_BEFORE_DOWN`). Sicherheitsverletzungen dagegen wirken immer
  sofort, ohne jede Toleranz.

### Flapping-Schutz

Exponentieller Backoff mit Jitter und Obergrenze. Zusätzlich eine Hysterese:
nach mehreren erfolglosen Zyklen innerhalb eines Zeitfensters folgt eine
deutlich längere Ruhephase, damit nicht endlos gegen eine tote Gegenstelle
gelaufen wird. Ein erfolgreicher Zyklus setzt alle Zähler zurück.

Ein NetworkManager-Dispatcher-Hook weckt den Daemon bei Netzereignissen, statt
ihn nur pollen zu lassen. Damit ein Ereignissturm die Hysterese nicht aushebelt,
kürzt ein Aufwecken die Wartezeit nur dann ab, wenn sich die **Netzidentität**
tatsächlich geändert hat (Default-Gateway, Gerät, aktive Verbindung).

## Die Sicherheits-Invarianten im Einzelnen

Der Preflight läuft vor **jedem** Hochfahren, nicht nur bei der Einrichtung.

| Code | Prüfung | Warum |
|---|---|---|
| P1 | Die Verbindung existiert und ist vom Typ `wireguard` | – |
| P2 | `ipv4.never-default` und `ipv6.never-default` sind gesetzt | sonst übernimmt der Tunnel die Default-Route |
| P3 | `connection.autoconnect` ist `no` | sonst fährt NetworkManager den Tunnel eigenmächtig und ungeprüft hoch |
| P4 | AllowedIPs enthalten weder `0.0.0.0/0` noch `::/0` | sonst ist es kein Split-Tunnel |
| P5 | `ipv4/ipv6.dns` und `dns-search` sind leer, `dns-priority` ist nicht negativ | eine negative Priorität kapert die systemweite Namensauflösung |
| P6 | `PersistentKeepalive` ist gesetzt | ohne Verkehr veraltet der Handshake |
| P7 | `wireguard.ip4/ip6-auto-default-route` ist nicht erzwungen | umginge `never-default` über Policy-Routing |
| P8 | AllowedIPs überlappen nicht mit dem lokalen Netz | `10.0.0.0/16` im Hotel-WLAN würde das lokale Netz blackholen |

P4 wird primär aus der NM-Keyfile gelesen (Zuordnung über die UUID, nicht über
den Dateinamen) und nur ersatzweise über `nmcli` – ältere NetworkManager-
Versionen geben Peers gar nicht aus. **Sind die AllowedIPs nicht ermittelbar,
zählt das als Fehlschlag**, nicht als „vermutlich in Ordnung".

Nach dem Hochfahren und in jedem gesunden Zyklus:

- Q1/Q2: `ip route get` für IPv4 und IPv6 – das Gerät darf nicht der Tunnel sein.
- Q3: In keiner Routentabelle darf eine Default-Route über den Tunnel stehen.
- Q4: Der Pfad zum Prüfziel muss durch den Tunnel führen – sonst würde ein
  LAN-Pfad geprüft und ein toter Tunnel für gesund gehalten.

### Garantiertes Herunterfahren

`nmcli connection down` kann scheitern oder hängen. Deshalb eskaliert wg-guard,
jeder Schritt mit Zeitgrenze, und **verifiziert das Ergebnis**:

1. `nmcli connection down`
2. `nmcli device disconnect <interface>`
3. `ip link set <interface> down` und `ip link delete <interface>`

Danach muss das Interface weg sein und es darf keine Route mehr darüber geben.
Alle Schritte betreffen ausschließlich dieses eine Interface.

## Konfiguration

`/etc/wg-guard/config.conf`, Shell-Syntax. Alle Werte haben Vorgaben im
Programm; die Datei enthält nur Abweichungen. Eine vollständig kommentierte
Vorlage liegt daneben als `config.conf.example`.

Die wichtigsten Stellschrauben:

| Schlüssel | Vorgabe | Bedeutung |
|---|---|---|
| `CHECK_INTERVAL_HEALTHY` | 60 | Prüfabstand, solange alles läuft |
| `CHECK_INTERVAL_IDLE` | 15 | Prüfabstand im Ruhezustand |
| `HEALTH_FAILURES_BEFORE_DOWN` | 2 | Toleranz für verlorene Pakete auf Stufe 4/5 |
| `HANDSHAKE_MAX_AGE` | 240 | Höchstalter des letzten Handshakes |
| `BACKOFF_INITIAL` / `BACKOFF_MAX` | 15 / 600 | Wartezeit zwischen Versuchen |
| `HYSTERESIS_FAILURES` / `_COOLDOWN` | 6 / 3600 | ab wann eine lange Ruhephase folgt |
| `LOG_LEVEL` | info | `debug` für die Fehlersuche |
| `AUTO_UPDATE` | yes | Autoupdate abschalten mit `no` |

Nach Änderungen: `sudo systemctl restart wg-guard`.

## Autoupdate

Ein systemd-Timer prüft täglich (nachts, mit Streuung, verpasste Läufe werden
nachgeholt), ob es ein neueres **getaggtes Release** gibt. Der Ablauf ist
absichtlich misstrauisch:

1. Release-Archiv und `SHA256SUMS` laden, Prüfsumme verifizieren – Abweichung
   bricht laut ab.
2. Entpacken, Struktur prüfen, **Syntax aller Skripte prüfen**. Ein fehlerhaftes
   Release darf den laufenden Watchdog nie ersetzen.
3. Die aktuelle Installation sichern.
4. Installieren, Dienst neu starten.
5. Läuft der Dienst danach nicht sauber, wird **automatisch zurückgerollt**.

Der kurze Neustart trennt den Tunnel; er wird anschließend über die volle
Kaskade neu aufgebaut. Eine aktive Pause überlebt das Update.

Abschalten: `AUTO_UPDATE=no` in der Konfiguration, oder
`sudo systemctl disable --now wg-guard-update.timer`.

## Rechte für den Desktop-Schalter

Der Schalter läuft als Benutzerin und ruft über `sudo` einen winzigen Wrapper
auf, der ausschließlich die Verben `pause` und `resume` akzeptiert. Die
sudoers-Regel nennt genau diese beiden Kommandozeilen – keine Wildcards, kein
`NOPASSWD` auf beliebige Programme:

```
%wgguard ALL=(root) NOPASSWD: /usr/local/bin/wg-guard-ctl pause
%wgguard ALL=(root) NOPASSWD: /usr/local/bin/wg-guard-ctl resume
```

Die Datei wird vor der Installation mit `visudo -cf` geprüft und bei einem
Fehler nicht installiert. Die Gruppenmitgliedschaft wirkt erst nach einer
Neuanmeldung – der Schalter sagt das auch, wenn ihm die Berechtigung fehlt.

## Unterstützte Systeme

Voraussetzung sind **systemd** und **NetworkManager ab 1.16** (davor kennt
NetworkManager kein WireGuard). Geprüft werden Fähigkeiten, nicht
Distributionen; die Distributionserkennung dient nur dem Nachinstallieren
fehlender Pakete.

| Familie | Paketmanager | Status |
|---|---|---|
| Debian, Ubuntu, Linux Mint | `apt-get` | Paketnamen hinterlegt |
| Fedora, RHEL, Rocky, Alma | `dnf` | Paketnamen hinterlegt |
| Arch, Manjaro | `pacman` | Paketnamen hinterlegt |
| openSUSE, SLES | `zypper` | Paketnamen hinterlegt |
| alle anderen | – | funktioniert; fehlende **Programme** werden benannt, aber nicht automatisch installiert |

Systeme ohne systemd werden bewusst nicht unterstützt – der Installer bricht
dort mit Begründung ab, statt halb zu installieren.

Was zur Laufzeit gemessen statt geraten wird: die ping-Flags (`-W` bei iputils,
`-w` bei inetutils), ob ping ans Interface gebunden werden kann, ob bash
`/dev/tcp` beherrscht oder `nc` einspringen muss, ob `/etc/sudoers.d` überhaupt
eingebunden ist, wo NetworkManager seine Keyfiles ablegt, und ob SELinux-
Kontexte gesetzt werden müssen.

Der Aufweck-Hook ist ausdrücklich **best effort**: Unter SELinux darf ein
Dispatcher-Skript nicht zwingend `systemctl` aufrufen, deshalb signalisiert er
direkt über die PID-Datei. Kommt das Signal nicht an, prüft wg-guard einfach im
konfigurierten Intervall weiter. `wg-guard check` zeigt im Abschnitt *Umgebung*,
was auf diesem System erkannt wurde.

## Fehlersuche

Erste Anlaufstelle:

```
wg-guard status      # Was ist gerade los?
sudo wg-guard check  # Vollständige Diagnose, ändert nichts
wg-guard logs -f     # Mitlesen
```

| Symptom | Ursache und Abhilfe |
|---|---|
| „Zustand: PREFLIGHT_FEHLER" | Die NM-Verbindung verletzt eine Invariante. `sudo wg-guard preflight --fix` zeigt jeden Punkt einzeln und fragt nach. |
| Der Tunnel geht ständig auf und zu | `wg-guard logs` zeigt die scheiternde Stufe. Bei Stufe 4/5 hilft oft ein höheres `HEALTH_FAILURES_BEFORE_DOWN`. |
| „Zustand: RUHE", obwohl Netz da ist | NetworkManager meldet `limited` oder `portal` – meist ein WLAN-Anmeldefenster. Das ist Absicht: hinter einer Anmeldeseite hätte ein Verbindungsversuch keine Aussicht. |
| Stufe 3 scheitert dauerhaft | Die Gegenstelle antwortet nicht. Prüfen, ob der dynamische Hostname auf die richtige Adresse zeigt: `getent ahosts <hostname>`. |
| Der Desktop-Schalter fragt nach einem Passwort | Die Gruppenmitgliedschaft ist noch nicht aktiv – einmal ab- und wieder anmelden. Sonst prüfen, ob `/etc/sudoers` die Zeile `@includedir /etc/sudoers.d` enthält. |
| Der Schalter meldet „Berechtigung fehlt" | Dasselbe; zusätzlich prüfen, ob `/usr/local/bin` im `secure_path` von sudo steht. |
| Nach einem Update ist alles wie vorher | Der Dienst kam nicht sauber hoch und es wurde automatisch zurückgerollt. `journalctl -u wg-guard-update` zeigt den Grund. |

Das Protokoll geht nach journald und ist im Normalbetrieb still. Für mehr
Details `LOG_LEVEL=debug` setzen und den Dienst neu starten.

## Deinstallation

```
sudo ./uninstall.sh            # Programm entfernen, Konfiguration behalten
sudo ./uninstall.sh --purge    # zusätzlich Konfiguration, Zustand und Gruppe
```

Die Deinstallation stoppt Dienst und Timer und fährt den Tunnel definiert
herunter – danach passt niemand mehr darauf auf. Die NetworkManager-Verbindung
selbst bleibt unangetastet.

## Entwicklung

```
make check   # Syntax, shellcheck, Testsuite, Prüfung der erzeugten Systemdateien
make test    # nur die Testsuite
```

Die Testsuite läuft vollständig ohne echten Tunnel, ohne Netz und ohne root:
alle externen Kommandos sind Mocks, die jeden Aufruf protokollieren. Dadurch
lassen sich gerade die Negativfälle prüfen – etwa dass bei verletztem Preflight
nachweislich **kein** `nmcli connection up` stattfindet, dass eine gekaperte
Default-Route sofort zum Herunterfahren führt, dass die Eskalation bis
`ip link delete` greift, wenn nmcli versagt, und dass ein Update mit falscher
Prüfsumme nichts anfasst.

Eine neue Version veröffentlichen:

```
make release VERSION=0.2.0
```

Das schreibt `VERSION`, lässt `make check` laufen, taggt, pusht und legt ein
GitHub-Release mit Archiv und `SHA256SUMS` an – genau das, was der Updater
erwartet.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
