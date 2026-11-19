[EN](README.md) | [PL](README.pl.md) | [ES](README.es.md) | [FR](README.fr.md) | [DE](README.de.md) | [IT](README.it.md) | [PT](README.pt.md)

<p align="center">
  <a href="https://macos-cleanup.64bit.site/"><img src="assets/brand-banner.svg" alt="macOS Cleanup" width="640" /></a>
</p>

# macOS Cleanup

**Version 4.0.5** · Apple-Silicon-Mac · macOS 11 oder neuer · [Website](https://macos-cleanup.64bit.site/) · [Support](https://macos-cleanup.64bit.site/support) · [MIT-Lizenz](LICENSE) · [Änderungen](CHANGELOG.md)

Ein lokales Werkzeug für behutsames Aufräumen der Festplatte unter macOS. Es misst zuerst, zeigt Ihnen einen Plan und handelt nur dort, wo Sie zustimmen. Die meisten Entfernungen landen in einem Quarantäneordner, aus dem Sie sie wiederherstellen können. Es hat eine Terminaloberfläche und einen einfachen Kommandozeilenmodus und verwendet niemals `sudo`.

## Was es bereinigt

Jede Kategorie hat eine Stufe (Tier). Die Stufe bestimmt, wie das Werkzeug sie behandelt.

**Regenerierbar (regenerable).** Der Eigentümer der Daten baut sie selbst wieder auf. „Sicher bereinigen“ und ein automatischer Lauf berühren nur Kategorien, deren Modus `auto` ist. Ab Werk ist das nur `app-caches`; jede andere regenerierbare Kategorie beginnt im Modus `review`. Im Tab „Kategorien“ (`m`) können Sie eine regenerierbare Kategorie, die in die Quarantäne wandert, auf `auto` umschalten. `npm`, `yarn`, `pnpm` und `pip` führen ein natives Werkzeug aus und können nie `auto` sein.

| Kategorie | Was es ist | Rückgängig |
|-----------|-----------|------------|
| `app-caches` | Caches von Apps auf einer eingebauten Positivliste | wiederherstellbar |
| `xcode-derived` | Xcode DerivedData | wiederherstellbar |
| `npx`, `gradle`, `cocoapods`, `cargo`, `swift-pm`, `bundler`, `composer` | Build- und Paket-Caches, entfernt durch Verschieben in die Quarantäne | wiederherstellbar |
| `npm`, `yarn`, `pnpm`, `pip` | Caches von Paketmanagern, vom Werkzeug selbst bereinigt (`npm cache clean --force`, `yarn cache clean`, `pnpm store prune`, `pip cache purge`) | dauerhaft |

**Prüfen (review).** Aufwendig neu aufzubauen oder für Sie sichtbar. Jede dieser Kategorien braucht Ihre Zustimmung in der laufenden Sitzung. Sie sind nie Teil eines automatischen Laufs.

| Kategorie | Was es ist | Rückgängig |
|-----------|-----------|------------|
| `trash` | Der Inhalt des Papierkorbs | wiederherstellbar |
| `user-caches` | Weitere Unterordner von `~/Library/Caches` | wiederherstellbar |
| `app-caches-review` | Caches bekannter Apps, die Offline-Daten enthalten oder langsam neu aufzubauen sein können | wiederherstellbar |
| `user-logs`, `diagnostic-reports` | Alte Protokolle und Absturzberichte in Ihrem Home-Ordner | wiederherstellbar |
| `device-support` | Alte iOS-Device-Support-Ordner (der neueste pro Plattform bleibt erhalten) | wiederherstellbar |
| `pnpm-stale` | Veraltete Daten im pnpm-Store | wiederherstellbar |
| `ios-backups` | iOS-Geräte-Backups, einzeln bestätigt | wiederherstellbar |
| `installers` | Alte DMG-, PKG- und ISO-Dateien in Downloads | wiederherstellbar |
| `system-logs`, `tmp` | Systemprotokolle und temporäre Dateien außerhalb Ihres Home-Ordners | dauerhaft, und nur im dauerhaften Modus |
| `simulators`, `sim-runtimes` | Nicht verfügbare Simulatoren und unbrauchbare Simulator-Laufzeiten (`xcrun simctl`) | dauerhaft |
| `brew`, `gem` | `brew cleanup --prune=all` und `gem cleanup`, die alte installierte Versionen entfernen | dauerhaft |
| `docker` | `docker system prune -f` | dauerhaft |
| `tm-snapshots` | Lokale Time-Machine-Snapshots (`tmutil`); der neueste bleibt erhalten | dauerhaft |

`sim-runtimes`, `docker` und `tm-snapshots` laufen nur, wenn Sie sie in einem interaktiven Lauf auswählen, nie über „Sicher bereinigen“ oder einen automatischen Lauf.

**Nur Bericht (report only).** Gemessen und erklärt, von diesem Werkzeug nie entfernt: `system-caches`, `xcode-archives`, `maven`, `android-avd`, `app-leftovers`, `browser-caches`, `browser-data`, `mail-data` und `mail-downloads`.

## Wie es Sie schützt

- **Nichts ändert sich ohne Ihre Zustimmung.** Ein Scan oder eine Vorschau berührt Ihre Dateien nie. Die Standardantwort auf jede Frage ist Nein.
- **Quarantäne statt Löschen.** Wo das Werkzeug Dateien selbst verschiebt, legt es sie in einen Quarantäneordner auf demselben Datenträger und protokolliert, was es verschoben hat, sodass `restore` sie zurückbringen kann. Die Quarantäne gibt keinen Speicherplatz frei, bis Sie sie endgültig löschen.
- **Dauerhafte Schritte sind gekennzeichnet.** Bereinigungen mit nativen Werkzeugen (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`) lassen sich nicht rückgängig machen und daher auch nicht wiederherstellen. Der dauerhafte Modus löscht ebenfalls endgültig. Oberfläche und Rückfragen weisen jedes Mal darauf hin.
- **Eine Schutzliste, die geschützt bleibt.** Mail, Nachrichten, Kalender, Kontakte, Schlüsselbunde, Passwortmanager, Browserprofile, Dokumente, Schreibtisch, Fotos-, Musik- und Filmbibliotheken, iCloud und andere Cloud-Ordner, SSH- und GPG-Schlüssel, Zugangsdatendateien, `~/.config`, Quellcode-Ordner und Git-Arbeitsverzeichnisse werden nie angefasst. Ebenso wenig das eigene Programm, die Einstellungen, die Zustandsdaten und die Quarantäneordner dieses Werkzeugs.
- **Unmittelbar vor der Aktion erneut geprüft.** Kurz bevor es ein Element entfernt, prüft das Werkzeug, ob es noch existiert, ob es dasselbe Element ist, das geplant war, ob es in den erlaubten Ordnern seiner Kategorie liegt, ob es nicht in Gebrauch ist und, falls Sie ein Mindestalter festgelegt haben, nicht zu neu ist.
- **Automatische Läufe sind eng begrenzt.** Sie sind standardmäßig aus. Wenn Sie sie einschalten, berühren sie nur Kategorien, deren Modus `auto` ist (ab Werk nur `app-caches`), nur über die Quarantäne, und löschen danach Quarantäne-Läufe, deren Aufbewahrungsfrist abgelaufen ist, endgültig. Sie führen kein natives Werkzeug aus und verwenden nie den dauerhaften Modus.
- **Ehrliche Zahlen.** Ergebnisse zeigen eine Schätzung (die Summe der Größen dessen, worauf der Lauf gewirkt hat) und, wenn messbar, die tatsächliche Änderung des freien Speichers. Beide weichen oft voneinander ab, und die Oberfläche sagt, warum. Größen werden in Binäreinheiten angegeben: KiB, MiB, GiB.

Die Quarantäne ist ein Rückgängig-Mechanismus, kein Backup. Legen Sie vor der ersten echten Bereinigung ein aktuelles Backup an.

## Voraussetzungen

- Apple-Silicon-Mac mit macOS 11 Big Sur oder neuer. Intel-Macs werden vom Code nicht blockiert, liegen aber außerhalb des offiziellen Supports.
- `bash` 3.2 oder neuer, das macOS mitbringt.
- Python 3.9 oder neuer für die Terminaloberfläche, für Pläne (`plan` und `apply`) und für `migrate`. Fehlt es, führen Sie `xcode-select --install` aus. Ohne Python funktioniert der einfache Kommandozeilenmodus weiterhin für die übrigen Befehle.
- Ein Terminal mit mindestens 40 Spalten mal 12 Zeilen für die Oberfläche.
- Netzwerkzugriff nur für die Installation und für ein Update, das Sie selbst mit `macos-cleanup update-self` starten. Bereinigen, Scannen und Wiederherstellen berühren das Netzwerk nie.

## Installation

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

Das Installationsprogramm lädt das Release-Paket und seine Datei `SHA256SUMS` herunter, prüft die Prüfsumme, legt das Programm in `~/.local/share/macos-cleanup` ab und verlinkt `~/.local/bin/macos-cleanup`. Es braucht kein `git`, verwendet nie `sudo`, ändert nie Ihre Einstellungen, Ihre Zustandsdaten oder Ihre Quarantäne, installiert nie den automatischen Lauf und startet nie eine Bereinigung. So installieren Sie ein bestimmtes Release: `install.sh --version 4.0.5`.

So prüfen Sie den Download zuerst selbst:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/macos-cleanup-4.0.5.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Entpacken Sie das Paket nur, wenn die Prüfung `OK` ausgibt. Prüfsummen schützen vor einem beschädigten oder unvollständigen Download. Die Releases sind nicht kryptografisch signiert; eine Prüfsumme, die vom selben Ort wie das Paket stammt, beweist daher nicht, wer es veröffentlicht hat. Weitere Optionen und manuelle Schritte: [INSTALL.md](docs/user/INSTALL.md) (auf Englisch).

Wird `macos-cleanup` danach nicht gefunden, öffnen Sie ein neues Terminalfenster und prüfen Sie, ob `~/.local/bin` in Ihrem `PATH` liegt.

## Erster Lauf

```bash
macos-cleanup
```

In einem Terminal öffnet das die Oberfläche in der Übersicht. Ohne Terminal ist ein einfaches `macos-cleanup` ein reiner Lese-Scan. Drücken Sie `S`, um zu scannen. Ein Scan ändert nichts. Drücken Sie `P` für eine Vorschau dessen, was eine Bereinigung tun würde, danach `C`, um die sicheren Kategorien zu bereinigen, oder wählen Sie im Tab „Kategorien“ Kategorien aus und drücken Sie `X`.

`mac-cleanup` ist derselbe Befehl wie `macos-cleanup`, und beide funktionieren aus jedem Ordner. Ohne Argumente öffnet jeder die Oberfläche; `--cli` läuft im einfachen Terminalmodus. Das Installationsprogramm meldet es, wenn ein anderes Programm in Ihrem `PATH` auf einen der beiden Namen antwortet: Die Eingabe dieses Namens startet dann jenes Programm, nicht macOS Cleanup.

Stattdessen als einfacher Text:

```bash
macos-cleanup scan
```

Führen Sie vor jeder echten Aktion `macos-cleanup doctor` aus, um Ihre Pfade, den freien Speicher, den Status des Festplattenvollzugriffs und lokale Snapshots zu sehen.

## Die Terminaloberfläche

Sieben Tabs, erreichbar mit `1` bis `7`:

| # | Tab | Wofür er da ist |
|---|-----|-----------------|
| 1 | Übersicht | Scannen, Vorschau, Bereinigen. Live-Fortschritt pro Kategorie und das Ergebnis des letzten Laufs |
| 2 | Kategorien | Jede Kategorie mit Stufe, Modus und Größe. Hier wählen Sie aus, was bereinigt wird |
| 3 | Quarantäne | Einen Lauf wiederherstellen, einen Lauf endgültig löschen (Sie tippen den letzten Teil seiner ID), abgelaufene Läufe endgültig löschen |
| 4 | Verlauf | Frühere Läufe und ihre Berichte. Einen aktuellen Plan anwenden |
| 5 | Einstellungen | Sprache und Aussehen, Sicherheitsgrenzen, Regeln, Aufbewahrung, Zeitplan, Pfade, Export und Import |
| 6 | Diagnose | Gesundheitsprüfungen, Festplattenvollzugriff, Vorschau der Layout-Migration |
| 7 | Hilfe | Tasten, Stufen, Pfade, Version |

Haupttasten: Pfeile bewegen, `Enter` öffnet oder bestätigt, `Tab` wechselt das Fenster, `Esc` geht zurück (oder fragt, ob ein laufender Auftrag gestoppt werden soll), `1` bis `7` springen zu einem Tab, `?` öffnet die Hilfe, `L` zeigt das Protokoll, `q` beendet. `/` sucht und `s` sortiert in den Listen, die das anbieten. Die untere Zeile zeigt immer die Tasten, die gerade funktionieren. Alle Details: [USER_GUIDE.md](docs/user/USER_GUIDE.md) (auf Englisch).

## Einfache Kommandozeilennutzung

`macos-cleanup` mit einem Unterbefehl öffnet nie die Oberfläche. Das gilt auch für `--cli` und für jeden Lauf ohne Terminal. Ein einfaches `macos-cleanup` ohne Terminal ist ein reiner Lese-Scan.

```bash
macos-cleanup scan                        # messen, nichts ändern
macos-cleanup plan                        # messen und eine Plandatei schreiben
macos-cleanup clean --safe                # Kategorien im Modus auto, nach einer Frage
macos-cleanup clean --only trash,npm      # genau diese Kategorien, mit einer Frage pro Abschnitt
macos-cleanup quarantine list             # Wiederherstellungspunkte auflisten
macos-cleanup restore latest              # den letzten Lauf zurückbringen
macos-cleanup quarantine purge expired --apply   # abgelaufene Wiederherstellungspunkte endgültig löschen
macos-cleanup doctor                      # diesen Mac prüfen
macos-cleanup history                     # frühere Läufe auflisten
```

`scan`, `plan`, `quarantine list`, `history` und `doctor` lesen nur. `clean`, `apply`, `restore` und `quarantine purge ... --apply` ändern etwas. `quarantine purge` ohne `--apply` zeigt nur eine Vorschau. Eine Wiederherstellung überschreibt nie etwas: Ein Element, dessen ursprünglicher Platz belegt ist, wird übersprungen und bleibt in der Quarantäne, und die Wiederherstellung endet dann mit einer Warnung (Exit-Status 1), nicht mit einem Fehler. Die Tabelle aller Befehle und Optionen finden Sie im [Benutzerhandbuch](docs/user/USER_GUIDE.md) (auf Englisch).

## Wo die Dateien liegen

| Was | Wo | Überschreiben mit |
|-----|----|-------------------|
| Programm | `~/.local/share/macos-cleanup` | `MACOS_CLEANUP_HOME` |
| Einstellungen und Regeln | `~/.config/macos-cleanup` | `MACOS_CLEANUP_CONFIG_DIR` |
| Protokolle, Berichte, Pläne, Verlauf | `~/.local/state/macos-cleanup` | `MACOS_CLEANUP_STATE_DIR` |
| Quarantäne (Wiederherstellungspunkte) | `~/Library/Application Support/macOS_cleanup/quarantine` | `MACOS_CLEANUP_QUARANTINE_DIR` |

Überschreibungen müssen absolute Pfade sein. Die Quarantäne muss auf demselben Datenträger liegen wie Ihr Home-Ordner. Ein Upgrade ersetzt nur das Programm. Einstellungen, Zustandsdaten und Quarantäne bleiben erhalten.

## Automatische Läufe

Standardmäßig aus, und das Installationsprogramm schaltet sie nie ein. Sie aktivieren sie in den **Einstellungen** oder mit:

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

Das installiert einen macOS-LaunchAgent (`com.github.kasprowiczm.macos-cleanup`). Ein geplanter Lauf tut nur zwei Dinge: Er verschiebt Elemente von Kategorien im Modus `auto` (ab Werk nur `app-caches`) in die Quarantäne und löscht Quarantäne-Läufe, deren Aufbewahrungsfrist abgelaufen ist, endgültig. Er führt kein natives Werkzeug aus, nichts aus der Stufe „prüfen“ und nie den dauerhaften Modus. Er schreibt einen normalen Eintrag in den Verlauf.

## Aktualisieren und deinstallieren

Führen Sie das Installationsprogramm erneut aus oder `macos-cleanup update-self`, um zu aktualisieren. Die vorherige Version bleibt neben dem Programm als `.previous` erhalten. So entfernen Sie das Werkzeug:

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

Es fragt, ob Ihre Einstellungen und Ihr Laufverlauf behalten werden sollen, und löscht die Quarantäne nie, außer Sie übergeben `--purge-quarantine --yes`. Siehe [UNINSTALL.md](docs/user/UNINSTALL.md) (auf Englisch). Sie kommen von 3.x? Lesen Sie [MIGRATING_FROM_V3.md](docs/user/MIGRATING_FROM_V3.md) (auf Englisch).

## Datenschutz

Scannen, Bereinigen und Wiederherstellen funktionieren offline; das Netzwerk wird nur für die Installation und für `update-self` verwendet. Das Werkzeug sendet keine Pfade, Ergebnisse oder Nutzungsdaten irgendwohin und hat keine Telemetrie. Protokolle, Berichte und Pläne bleiben im Ordner für Zustandsdaten auf Ihrem Mac. Verwenden Sie `--redact`, um Ihren Home-Ordner durch `~` zu ersetzen und Ihren Benutzer- und Hostnamen wegzulassen, bevor Sie einen Bericht teilen.

## Grenzen und bekannte Lücken

- Die Quarantäne gibt keinen Speicherplatz frei, bis Sie sie endgültig löschen, und lokale Snapshots können gelöschte Blöcke danach noch festhalten. Der Platz kommt zurück, wenn macOS ihn freigibt.
- Größen sind Schätzungen nach oben. APFS-Klone und gemeinsam genutzte Blöcke werden nicht erkannt.
- Ohne Festplattenvollzugriff lassen sich einige Ordner nicht lesen. Der Scan wird dann als partiell markiert, und diese Größen sind Untergrenzen.
- Bereinigungen mit nativen Werkzeugen und der dauerhafte Modus lassen sich nicht rückgängig machen.
- Kategorien „nur Bericht“ werden nie entfernt. Bereinigen Sie sie mit ihren eigenen Werkzeugen.
- Releases werden per Prüfsumme verifiziert, nicht per kryptografischer Signatur.
- Apple Silicon mit macOS 11 oder neuer ist die unterstützte Konfiguration. Andere Konfigurationen sind ungetestet.

## Dokumentation

[Benutzerhandbuch](docs/user/USER_GUIDE.md) · [Installation](docs/user/INSTALL.md) · [Deinstallation](docs/user/UNINSTALL.md) · [Migration von 3.x](docs/user/MIGRATING_FROM_V3.md) · [Änderungen](CHANGELOG.md) (alle auf Englisch)

## Support

[macos-cleanup.64bit.site/support](https://macos-cleanup.64bit.site/support)

## Lizenz

[MIT](LICENSE)

> **Nutzung auf eigene Gefahr.** Das Werkzeug ist darauf ausgelegt, vor dem Handeln zu fragen und den Weg zurück offen zu halten, aber keine Software ist frei von Fehlern. Legen Sie zuerst ein Backup an.
