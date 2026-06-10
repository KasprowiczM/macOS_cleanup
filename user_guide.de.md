[🇺🇸 EN](user_guide.md) | [🇵🇱 PL](user_guide.pl.md) | [🇪🇸 ES](user_guide.es.md) | [🇫🇷 FR](user_guide.fr.md) | [🇩🇪 DE](user_guide.de.md) | [🇮🇹 IT](user_guide.it.md) | [🇵🇹 PT](user_guide.pt.md)

---

# macOS Cleanup — Benutzerhandbuch

Dieses Dokument geht davon aus, dass Sie die `~/Library`-Struktur oder die Funktionsweise von Caches nicht kennen müssen. Das Ziel ist es, sicher Speicherplatz zurückzugewinnen, ohne E-Mails, Passwörter, Dokumente, Browserprofile, Projekte und Anwendungseinstellungen zu löschen.

## Die goldene Regel

Führen Sie die Bereinigung nicht „blind“ durch. Führen Sie immer zuerst eine Analyse durch:

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Dadurch wird nichts gelöscht. Das Skript zeigt:

- wie viel Speicherplatz potenziell zurückgewonnen werden kann,
- welche Elemente `SAFE` (sicher) sind,
- welche Elemente ein `REVIEW` (Überprüfung) erfordern,
- welche Elemente `DANGEROUS` (gefährlich) sind und nicht automatisch gelöscht werden.

## Risikoklassen

| Klasse | Bedeutung | Was das Skript tut |
|-------|------------|----------------|
| `SAFE` | Wiederherstellbare Daten: App-Caches, Build-Caches, alte Logs, tmp. | Kann mit `auto-safe` gelöscht oder aus einem Plan ausgeführt werden. Verschiebt Benutzerdateien standardmäßig in die Quarantäne. |
| `REVIEW` | Speicherplatz kann zurückgewonnen werden, jedoch möglicherweise mit Nachteilen: erneutes Herunterladen, langsamerer Start, Verlust von Diagnose-Logs, Emulator-Zustand. | Wird im Plan angezeigt. Wird nicht automatisch ohne bewusste Entscheidung gelöscht. |
| `DANGEROUS` | E-Mails, Browserprofile, Passwörter, Dokumente, Einstellungen, aktive Anwendungsdaten. | Nur Bericht oder Blockierung. Wird niemals automatisch gelöscht. |

Wenn Sie ein Element im Bericht nicht verstehen, behandeln Sie es als `REVIEW` oder `DANGEROUS`.

## Backup und Quarantäne

Für die eigentliche Bereinigung ist ein aktuelles Time Machine-Backup erforderlich. Wenn das Skript dieses nicht verifizieren kann, wird die Bereinigung blockiert. Sie können die Ausführung erzwingen durch:

```bash
bash cleanup_all.sh --auto-safe --allow-no-backup
```

Verwenden Sie dies nur, wenn Sie das Risiko bewusst akzeptieren.

Die Quarantäne gibt den Speicherplatz nicht sofort frei. Standardmäßig landen Benutzerdateien in:

```text
~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/
```

Sie gewinnen den Speicherplatz erst durch `--permanent` oder eine spätere Bereinigung zurück:

```bash
bash cleanup_all.sh --purge-quarantine latest --apply
```

Wiederherstellen:

```bash
bash cleanup_all.sh --restore latest
```

## Sicherster Workflow

### 1. Analyse

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Lesen Sie den Bericht unter `reports/report_*.md`.

### 2. JSON-Plan

```bash
bash cleanup_all.sh plan --non-interactive --no-color
```

Der Plan wird unter `reports/plan_*.json` gespeichert. Jede Operation hat eine `id`, `risk`, `path`, `description` und `recommendation`.

### 3. Sicherste Bereinigung

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes
```

Dies bereinigt nur explizit bekannte `SAFE` App-Caches. Wenn kein verifiziertes Backup vorhanden ist:

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes --allow-no-backup
```

### 4. Interaktive Überprüfung für größere Elemente

```bash
bash cleanup_all.sh --interactive
```

Das Skript zeigt die Kategorie, die Größe, die Konsequenzen an und stellt Fragen. Die Standardantwort ist immer `no`.

## Was ohne größere Konsequenzen gelöscht werden kann

Folgende Elemente sind in der Regel `SAFE`, können aber dennoch zu einem langsameren ersten App-Start führen:

- Slack/Teams/Discord-Cache: Die App erstellt Web-Assets und Miniaturansichten neu.
- VS Code/Cursor `Cache` und `Code Cache`: Der Editor baut den Cache neu auf; Projekte und Einstellungen bleiben erhalten.
- Standard Spotify `Cache`: Musik/Podcasts werden erneut heruntergeladen.
- Zoom-Cache: Löscht keine Aufnahmen aus `Documents/Zoom`.
- Xcode DerivedData: Xcode baut Projekte von Grund auf neu.
- npm/pnpm/yarn/pip/Homebrew-Cache: Abhängigkeiten werden erneut heruntergeladen.
- alte Logs: Sie verlieren den Diagnoseverlauf, aber keine App-Daten.
- alte `/tmp`-Dateien: Temporär, macOS bereinigt diese normalerweise selbst.

## Was eine Analyse erfordert

### Allgemeines `~/Library/Caches`

Das Skript zeigt Top-Level-Elemente in `~/Library/Caches` als `REVIEW` an, da nicht alle Caches günstig neu erstellt werden können. Einige Apps speichern dort große Offline-Daten, Karten, Medien, KI-Modelle oder Arbeits-Caches.

Was zu prüfen ist:

- Erkennen Sie die App am Ordnernamen?
- Hat die App Offline-Daten?
- Akzeptieren Sie das erneute Herunterladen von Gigabytes an Daten?
- Arbeiten Sie derzeit nicht offline?

### JetBrains

Der JetBrains-Cache kann groß sein. Das Löschen löscht keine Projekte, aber die IDE baut ihre Indizes neu auf. Dies kann lange dauern und die CPU belasten. Nur löschen, wenn Sie Zeit für die Neuindizierung haben.

### Adobe Media Cache

Löscht keine Quellprojekte oder Medien, aber Premiere/After Effects müssen möglicherweise Vorschauen, Audio/Video-Angleichungen und Caches neu generieren. Nur löschen, wenn Sie die Originalmedien haben und ein langsameres erstes Öffnen des Projekts akzeptieren.

### Figma

Der Cache ist normalerweise wiederherstellbar, kann sich aber auf das erneute Öffnen großer Dateien und die Offline-Arbeit auswirken. Bevorzugen Sie eine Überprüfung (Review).

### Spotify PersistentCache

Kann größere Streaming-/Offline-Daten bedeuten. Das Löschen kann erneute Downloads erzwingen. Der normale `Spotify Cache` ist sicherer als der `PersistentCache`.

### Xcode Device Support

Dies sind Debugging-Symbole für iOS/watchOS/tvOS-Geräte. Xcode lädt sie erneut herunter, wenn Sie ein Gerät mit einer bestimmten OS-Version anschließen. Nur löschen, wenn Sie keine alten Geräte debuggen oder Zeit und Internet haben.

### Xcode Archives

`.xcarchive`-Archive werden möglicherweise für den App Store, die Symbolisierung von Abstürzen und die Neuerstellung von Builds benötigt. Das Skript meldet sie nur. Nach Überprüfung manuell über den Xcode Organizer löschen.

### Docker

`docker system prune -f` löscht Images, gestoppte Container, Netzwerke und Build-Caches. Volumes werden nicht gelöscht, aber gestoppte Container können Zustände enthalten, die Sie noch nicht in ein Volume verschoben haben. Prüfen Sie:

```bash
docker ps -a
docker system df
```

### Android AVD

Android-Emulatoren können lokale Test-App-Zustände enthalten. Wenn Sie sich nicht sicher sind, löschen Sie sie über den Android Studio Device Manager, nicht über manuelles `rm`.

### Maven `~/.m2/repository`

Kann lokal erstellte Artefakte enthalten, die nicht im Internet verfügbar sind. Das Skript behandelt dies als "Nur Überprüfung".

### iOS Backups

Dies sind iPhone/iPad-Kopien. Nur löschen, wenn Sie ein aktuelles iCloud-Backup oder ein neues Finder-Backup haben.

### Time Machine Local Snapshots

macOS löscht diese automatisch, wenn Speicherplatz benötigt wird. Manuelles Bereinigen ist nur sinnvoll, wenn Sie verstehen, dass Sie lokale Wiederherstellungspunkte verlieren.

## Was das Skript NICHT automatisch löscht

### Apple Mail

`~/Library/Mail` und `~/Library/Containers/com.apple.mail` können Nachrichten, Anhänge, POP-Konten, Indizes und lokale Archive enthalten. Das Skript zeigt nur die Größen und die größten Bereiche an.

Sichere Aktionen:

- Löschen Sie große Nachrichten in Mail.app.
- Leeren Sie Papierkorb und Spam in Mail.app.
- Prüfen Sie Anhänge.
- Exportieren Sie lokale Postfächer vor manuellen Eingriffen.

### Browser

Profile von Chrome/Firefox/Safari/Edge/Brave enthalten Cookies, Sitzungen, Passwörter, Verlauf, Lesezeichen und Erweiterungen. Das Skript löscht sie nicht.

Löschen Sie Website-Daten über die Benutzeroberfläche:

- Safari: Einstellungen -> Datenschutz -> Website-Daten verwalten.
- Chrome/Brave/Edge: `chrome://settings/clearBrowserData`.
- Firefox: Einstellungen -> Datenschutz & Sicherheit -> Cookies und Website-Daten.

Das Löschen von Cookies kann Sie von Websites abmelden.

### Application Support und Preferences

`~/Library/Application Support` und `~/Library/Preferences` enthalten oft Datenbanken, Einstellungen, Lizenzen, lokale Projekte und Konfigurationen. Das Skript löscht keine aktiven Anwendungsdaten. Überreste deinstallierter Apps werden nur gemeldet.

## Wie man `plan.json` liest

Beispiel:

```json
{
  "id": "op-0007",
  "category": "app-caches",
  "risk": "SAFE",
  "action": "remove_path",
  "path": "/Users/me/Library/Caches/com.spotify.client",
  "estimated_bytes": 532000000,
  "description": "Spotify cache: streaming cache muzyki/podcastów.",
  "recommendation": "SAFE: można usunąć przez auto-safe..."
}
```

Interpretation:

- `SAFE`: kann über `apply --from-plan` ausgeführt werden.
- `REVIEW`: erfordert eine manuelle Entscheidung.
- `DANGEROUS`: wird nicht ausgeführt.
- `native_command`: Das Skript führt ein Tool wie `brew cleanup` aus; normalerweise ohne Quarantäne-Rollback.
- `report_only`: Nur Information, keine Löschung.

## Beispielentscheidungen

| Situation | Entscheidung |
|----------|---------|
| Sie möchten schnell und ohne Risiko etwas Speicherplatz zurückgewinnen | `--auto-safe` |
| Sie haben viel npm/pnpm Cache und Internet | Bereinigen Sie die Kategorie `dev` nach Überprüfung |
| Sie haben ein großes Chrome/Firefox-Profil | Nicht manuell löschen, Browser-UI verwenden |
| Großes `~/Library/Mail` | Über Mail.app bereinigen, nicht über das Skript |
| Große `Xcode Archives` | Prüfen Sie den Xcode Organizer |
| Kein Time Machine Backup | Führen Sie kein echtes Apply durch, es sei denn, Sie verwenden bewusst `--allow-no-backup` |

## Nützliche Befehle

```bash
# Alles analysieren
bash cleanup_all.sh --dry-run --non-interactive --no-color

# JSON-Plan
bash cleanup_all.sh plan --non-interactive --no-color

# Nur Entwickler-Cache
bash cleanup_all.sh --dry-run --category dev --non-interactive --no-color

# Sicherste Bereinigung
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Interaktiv, mit vollständigen Fragen
bash cleanup_all.sh --interactive

# Planausführung simulieren
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run --non-interactive --no-color

# Aus Quarantäne wiederherstellen
bash cleanup_all.sh --restore latest

# Nach Überprüfung Speicherplatz aus Quarantäne freigeben
bash cleanup_all.sh --purge-quarantine latest --apply
```

## Wann man abbrechen sollte

Brechen Sie ab und bestätigen Sie die Bereinigung nicht, wenn:

- Sie kein Backup haben,
- Sie den Pfad nicht verstehen,
- es E-Mails, Browser, Passwörter, Dokumente oder Einstellungen betrifft,
- Sie gerade einen Absturz diagnostizieren und Logs benötigen,
- die App Offline-Daten hat, die Sie nicht erneut herunterladen möchten.

Sicheres Bereinigen bedeutet, Speicherplatz aus wiederherstellbaren Daten zurückzugewinnen, und nicht alles zu löschen, was groß ist.
