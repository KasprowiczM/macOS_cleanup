[🇺🇸 EN](README.md) | [🇵🇱 PL](README.pl.md) | [🇪🇸 ES](README.es.md) | [🇫🇷 FR](README.fr.md) | [🇩🇪 DE](README.de.md) | [🇮🇹 IT](README.it.md) | [🇵🇹 PT](README.pt.md)

---

<p align="center">
  <img src="assets/macos-cleanup-logo.png" alt="macOS Cleanup Logo" width="350" />
</p>

# macOS Cleanup — Professioneller System Cleaner

> **Professionelles macOS-Bereinigungstool** — sicherer als kommerzielle Apps, völlig transparent, mit voller Benutzerkontrolle darüber, was gelöscht wird.

<p align="center">
  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</p>

## Was ist dieses Projekt?

`cleanup_all.sh` ist ein Bash-Skript für fortgeschrittene macOS-Benutzer, das:

- Das System **analysiert** und erkennt, was sicher gelöscht werden kann
- Sie über die Konsequenzen jeder Operation **informiert**, bevor diese ausgeführt wird
- **Auf Ihre Zustimmung wartet** — die Standardantwort ist immer NEIN
- **Benutzerdaten in Quarantäne verschiebt** in Bereinigungsmodi, sodass ein Rollback möglich ist
- **Niemals Mail-Daten, Passwörter, Cookies, Browserprofile oder Dokumente berührt**

## Anforderungen

- macOS 10.15 Catalina oder neuer (einschließlich Sonoma, Sequoia, macOS 26.x)
- bash 3.2+ (vorinstalliert auf macOS)
- Python 3.10+ für Hilfstools in `dev-sync/` und das sichere Parsen von `plan.json` in `apply --from-plan`
- Optional: `bc` (für Größenberechnungen), `mdfind` (Spotlight, vorinstalliert)

## Installation

### Schnelltest — Einzeiler-Installer

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

Der Installer **klont nur das Repo und druckt die nächsten Schritte** — er löscht nichts und startet die Bereinigung nicht. Er installiert standardmäßig nach `~/Dev_Env/macOS_cleanup` (änderbar über `MACOS_CLEANUP_DIR=...`). Möchten Sie zuerst den Code überprüfen? Laden Sie [`install.sh`](install.sh) herunter und inspizieren Sie es vor der Ausführung. Nach dem Klonen prüft er jedes Laufzeitskript, jede Regeldatei und jedes Schema gegen `SHA256SUMS` und bricht bei einer Abweichung oder fehlender Datei ab. Das erkennt einen beschädigten oder unvollständigen Download; es ist keine Signatur.

### Manuelle Installation

```bash
git clone https://github.com/KasprowiczM/macOS_cleanup.git ~/Dev_Env/macOS_cleanup
cd ~/Dev_Env/macOS_cleanup
chmod +x cleanup_all.sh
```

## Verwendung

### 1. Empfohlener erster Lauf — Analyse (dry-run)

```bash
bash cleanup_all.sh
```

Das Skript analysiert Ihr System, zeigt Ihnen, was bereinigt werden kann, und fragt, ob Sie fortfahren möchten. **Nichts wird ohne Ihre Zustimmung gelöscht.**

### 2. Vollständige Interaktive Bereinigung

```bash
bash cleanup_all.sh --interactive
```

Geht jede Kategorie durch, erklärt was es ist, die Konsequenzen der Löschung und bittet um Erlaubnis. Die standardmäßige tatsächliche Bereinigung arbeitet im `--quarantine` Modus: Benutzerpfade werden nach `~/Library/Application Support/macOS_cleanup/quarantine` verschoben anstatt sofort gelöscht zu werden.

Wenn Sie direkt nach der Analyse dauerhaft Speicherplatz freigeben möchten, führen Sie den permanenten Modus aus:

```bash
bash cleanup_all.sh --interactive --permanent
```

### 3. Automatische Bereinigung Nur Sicherer Elemente

```bash
bash cleanup_all.sh --auto-safe
```

Standardmäßig verschiebt dies nur explizit bekannte, risikoarme App-Caches in Quarantäne. Allgemeine Top-Level-Elemente in `~/Library/Caches` werden zur Entscheidung des Benutzers gemeldet, da sie große Offline-Caches enthalten könnten, die Apps andernfalls erneut herunterladen müssten. Temporäre Dateien und Pfade außerhalb von `$HOME` erfordern den `--permanent` Modus, da es für sie kein sinnvolles Quarantäne-Rollback gibt:

```bash
bash cleanup_all.sh --auto-safe --permanent
```

Alles andere wird für Ihre Entscheidung gemeldet.

### 4. Spezifische Kategorie

```bash
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --dry-run --category user-caches
bash cleanup_all.sh --interactive --category time-machine
```

### 5. Analysieren / Planen / Anwenden

```bash
# Lesbarer Alias für Agenten/Operator-Workflows
bash cleanup_all.sh analyze

# Analyse + struktureller JSON Plan
bash cleanup_all.sh plan

# Plan ausführen: standardmäßig nur SAFE
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Planausführung simulieren
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run
```

`plan.json` enthält Operationen mit `id`, Pfad oder Befehl, Kategorie, Klasse `SAFE`/`REVIEW`/`DANGEROUS`, geschätzte Größe, Beschreibungen der Konsequenzen und Empfehlung. `apply --from-plan` führt niemals `DANGEROUS` aus; `REVIEW` wird übersprungen, es sei denn, Sie fügen `--include-review` hinzu und gehen durch die interaktive Bestätigung.

### 6. Nicht-interaktiver Modus (CI/Automatisierung)

```bash
# Analyse ohne Prompts
bash cleanup_all.sh --dry-run --non-interactive

# Auto-safe ohne manuelle Bestätigung (nur explizit sichere Elemente)
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Echte Speicherplatzrückgewinnung in der Automatisierung: nur nach bewusstem --permanent
bash cleanup_all.sh --auto-safe --permanent --non-interactive --yes

# Eine bestimmte Kategorie ohne Prompts ausführen
bash cleanup_all.sh --dry-run --non-interactive --category app-leftovers
```

`--non-interactive` führt das Skript aus, ohne Eingaben vom TTY zu lesen.
Aus Sicherheitsgründen wird jede Frage standardmäßig mit `nein` behandelt.
`--yes` bestätigt nur risikoarme Operationen; mittlere/hohe Kategorien erfordern den interaktiven Modus.

### 7. Mit Pfadausschluss

```bash
bash cleanup_all.sh --interactive --exclude "$HOME/Library/Caches/myapp"
```

### 8. Quarantäne, Wiederherstellung und Löschung

```bash
# Gespeicherte Quarantäne-Läufe auflisten
bash cleanup_all.sh --list-quarantine

# Den neuesten Lauf oder ein bestimmtes Manifest wiederherstellen
bash cleanup_all.sh --restore latest
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Vorschau auf permanente Quarantänelöschung
bash cleanup_all.sh --purge-quarantine latest

# Den durch die Quarantäne belegten Speicherplatz tatsächlich freigeben
bash cleanup_all.sh --purge-quarantine latest --apply

# Läufe löschen, die älter sind als der Aufbewahrungszeitraum
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
```

Quarantäne bietet ein Rollback, gibt aber selbst keinen Speicherplatz frei. Sie erhalten nur Platz zurück nach `--permanent` oder einem nachfolgenden `--purge-quarantine ... --apply`.

### 9. Alte Lauf-Logs und Berichte löschen (`--prune-artifacts`)

```bash
bash cleanup_all.sh --prune-artifacts
```

Analyze, list, plan und dry-run löschen niemals Logs oder Journale. Die Artefakt-Aufbewahrung ist ausschließlich dieser explizite Befehl. Das Alter steuert `ARTIFACT_RETENTION_DAYS` (0 deaktiviert).

### 10. JSON Ausgabe — Maschinenlesbare Ergebnisse (`--json`)

```bash
# Analytische Ausgabe (dry-run) im JSON Format auf stdout
bash cleanup_all.sh --dry-run --non-interactive --json --category dev

# Mit einer Pipe kombinieren (menschliche Ausgabe geht an stderr)
bash cleanup_all.sh plan --json --non-interactive 2>/dev/null | jq .counters

# JSON in eine Datei speichern und den Markdown-Bericht überspringen
bash cleanup_all.sh --dry-run --non-interactive --json --category trash 2>/dev/null > summary.json
```

Das `--json` Flag leitet alle lesbaren Ausgaben (Banner, Abschnitte, Zusammenfassungen) an **stderr** um und emittiert am Ende des Laufs ein einzelnes JSON Objekt auf **stdout**. Das Objekt enthält:

| Feld | Beschreibung |
|-------|-------------|
| `mode` | Ausführungsmodus (`dry-run`, `plan`, `apply-plan`, etc.) |
| `dry_run` | `true` / `false` |
| `analysis_status` | `complete` / `partial` |
| `categories` | Array der aktiven Kategorien |
| `counters` | `would_free_bytes`, `cleaned_bytes`, `informational_bytes`, `quarantined_bytes`, `skipped_items`, `unreadable_paths`, `user_decisions_needed` |
| `plan` | Zähler für `SAFE`/`REVIEW`/`DANGEROUS` Operationen und Bytes; `report_only_operations`, `report_only_bytes`, `executable_bytes` |
| `artifacts` | Pfade zu `report`, `plan`, `journal`, `restore_manifest` |
| `warnings` | Anzahl übersprungener Elemente |
| `user_decisions` | Liste von Elementbeschreibungen, die eine Entscheidung erfordern |

Das Flag funktioniert mit jedem Modus (`dry-run`, `plan`, `apply`, `--auto-safe`, etc.) und ist sicher für `--non-interactive` und CI. Es ändert kein Verhalten, wenn es nicht angegeben wird.

## Verfügbare Kategorien

| Kategorie | Inhalt |
|----------|----------|
| `trash` | Inhalt von ~/.Trash |
| `system` | Systemcaches, alte /tmp und /private/tmp Dateien |
| `user-caches` | ~/Library/Caches (Benutzer App Caches) |
| `logs` | Alte Anwendungs- und Systemprotokolle |
| `app-leftovers` | Heuristischer Restbericht; standardmäßig keine automatische Löschung |
| `dev` | Xcode DerivedData, Simulatoren, npm/pip/brew/docker Caches |
| `time-machine` | Lokale TM Snapshots + iOS Backups |
| `large-files` | Alte DMG/PKG/ISO Dateien in ~/Downloads |

## Sicherheitsmodell

### Philosophie: Informierte Zustimmung

Das Skript arbeitet nach dem Modell der **informierten Zustimmung**:

```
Analysieren → Ergebnisse zeigen → Konsequenzen erklären → Warnungen → Auf Zustimmung warten → Handeln
```

Die UX/DX Zielsprache beschreibt diesen Ablauf als **Analysieren → Planen → Anwenden**:

- `analyze` — dry-run ohne Mutation, z.B., `bash cleanup_all.sh --dry-run`
- `plan` — Markdown Bericht, JSONL Journal und eine Liste von Elementen, die eine Entscheidung erfordern
- `apply` — echte Aktion nach Zustimmung: `apply --from-plan`, `--interactive`, `--auto-safe`, oder `--purge-quarantine ... --apply`

Detailliertes Modell für Operatoren und Agenten: `docs/ux_dx_safety_model.md`.

### Was NIEMALS berührt wird

<!-- BEGIN NEVER_TOUCH_PATHS -->
- `~/Library/Mail`
- `~/Library/Containers/com.apple.mail`
- `~/Library/Keychains`
- `/Library/Keychains`
- `/System/Library/Keychains`
- `~/Library/Application Support/1Password`
- `~/Library/Application Support/1Password 7`
- `~/Library/Application Support/com.agilebits`
- `~/Library/Application Support/Bitwarden`
- `~/Library/Application Support/LastPass`
- `~/Library/Application Support/Dashlane`
- `~/Library/Application Support/Enpass`
- `~/Library/Application Support/Keybase`
- `~/Library/Application Support/macOS_cleanup`
- `~/Library/Caches/com.1password.1password`
- `~/Library/Caches/com.agilebits.onepassword7`
- `~/Library/Caches/com.bitwarden.desktop`
- `~/Library/Caches/com.lastpass.LastPass`
- `~/Library/Caches/com.dashlane.Dashlane`
- `~/Library/Caches/in.sinew.Enpass-Desktop`
- `~/Documents`
- `~/Desktop`
- `~/Pictures/Photos Library.photoslibrary`
- `~/Pictures/Photos Library`
- `~/Music/Music/Music Library.musiclibrary`
- `~/Music/Music Library.musiclibrary`
- `~/Movies`
- `~/Library/Messages`
- `~/Library/Calendars`
- `~/Library/Application Support/AddressBook`
- `~/Library/Mobile Documents`
- `~/Library/CloudStorage`
- `~/Dropbox`
- `~/OneDrive`
- `~/Google Drive`
- `~/Library/Application Support/Google/DriveFS`
- `~/Library/Application Support/Google/Chrome`
- `~/Library/Application Support/Firefox`
- `~/Library/Application Support/Microsoft Edge`
- `~/Library/Application Support/BraveSoftware`
- `~/Library/Application Support/Opera`
- `~/Library/Application Support/Vivaldi`
- `~/Library/Safari`
- `~/Library/MobileDevice/Provisioning Profiles`
- `~/Library/Keychains`
- `~/Developer`
- `~/Projects`
- `~/src`
- `~/code`
- `~/repos`
- `~/.ssh`
- `~/.gnupg`
- `~/.aws/credentials`
- `~/.aws/config`
- `~/.aws/sso`
- `~/.gitconfig`
- `~/.git-credentials`
- `~/.config`
- `~/.kube`
- `~/.docker`
- `~/.netrc`
- `~/.zshrc`
- `~/.zprofile`
- `~/.zsh_history`
- `~/.bash_profile`
- `~/.bashrc`
- `~/.bash_history`
- `~/.profile`
- `~/.npmrc`
- `~/.config/gh`
<!-- END NEVER_TOUCH_PATHS -->

### Regel-Sicherheitsstufen

- `SAFE` — reproduzierbare Artefakte, z.B. exakt bekannte App Caches; kann in `--auto-safe` aufgenommen werden, geht aber immer noch durch Guardrails
- `REVIEW` — erfordert einen Plan und eine Benutzerentscheidung, z.B. allgemeine Caches, Protokolle, Build-Artefakte, iOS Backups
- `DANGEROUS` — Benutzerdaten, Identität, Profile, Mail, Passwörter; nicht automatisch gelöscht

Das aktuelle `cleanup_rules.yaml` behält die technischen Werte `safe`, `ask`, `never`. Die UX/DX Zuordnung entspricht `SAFE`, `REVIEW`, `DANGEROUS`.

### Journal und Rollback

Jeder Bericht speichert eine maschinelle Zusammenfassung des Plans in `reports/journal_*.jsonl` (`report_generated`, `category_total`). Echte `safe_remove()` Operationen hängen Ausführungsereignisse an, z.B. `quarantined`, `deleted`, `skipped_non_user_scope`. Kontrollierte native Befehle, wie `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable`, und `tmutil deletelocalsnapshots`, fügen `native_command` Ereignisse hinzu, da sie kein Quarantäne-Rollback haben. Die Quarantäne generiert auch `reports/restore_*.tsv`, was von `--restore` verwendet wird. Der Wiederherstellungsprozess verweigert die Wiederherstellung außerhalb des Benutzerverzeichnisses, auf geschützte Pfade, durch symbolisch verknüpfte übergeordnete Verzeichnisse oder von Dateien außerhalb des Quarantäneverzeichnisses.

Quarantäne ist ein Rollback, kein Backup. Vor der ersten echten Bereinigung sollte der Benutzer immer noch über ein aktuelles System-Backup verfügen. Mail und Browserprofile werden nur als Richtlinien behandelt: Caches könnten gemeldet werden, aber Kontodaten, Sitzungen, Cookies, Lesezeichen und lokale Nachrichtenspeicher bleiben von der automatischen Bereinigung ausgeschlossen.

## Projektstruktur

```
macOS_cleanup/
├── cleanup_all.sh          # Hauptskript — Einstiegspunkt
├── cleanup_rules.yaml      # Wissensbasis: Bereinigungsregeln pro App
├── config/
│   └── defaults.sh         # Standardkonfiguration, Altersschwellenwerte, geschützte Pfade
├── lib/
│   ├── common.sh           # Logging, Formatierung, safe_remove(), Pfadschutz
│   ├── policy.sh           # YAML Policy Parser und SAFE/REVIEW/DANGEROUS Zuordnung
│   ├── analyzer.sh         # Systemanalyse (alle analyze_* Funktionen)
│   ├── cleaner.sh          # Bereinigungs-Engine (alle clean_* Funktionen)
│   ├── planner.sh          # plan.json und apply --from-plan
│   ├── interactive.sh      # Benutzer-Prompts und Bestätigungen
│   └── reporter.sh         # Markdown Berichtsgenerator
├── docs/
│   ├── rules_design.md     # Regelstruktur-Dokumentation
│   └── ux_dx_safety_model.md # SAFE/REVIEW/DANGEROUS Modell und analyze/plan/apply
├── tests/                  # Testszenarien
└── AGENTS.md               # Die Rolle von KI Agenten im Projekt
```

## Berichte und Logs

Nach jedem Durchlauf generiert das Skript:

- **Log**: `logs/cleanup_YYYY-MM-DD_HHMMSS_PID.log` — vollständiges Operationstagebuch
- **Bericht**: `reports/report_YYYY-MM-DD_HHMMSS_PID.md` — Markdown Zusammenfassung
- **Plan**: `reports/plan_YYYY-MM-DD_HHMMSS_PID.json` — struktureller `SAFE`/`REVIEW`/`DANGEROUS` Plan
- **Journal**: `reports/journal_YYYY-MM-DD_HHMMSS_PID.jsonl` — maschineller Plan und Audit-Log
- **Wiederherstellungsmanifest**: `reports/restore_YYYY-MM-DD_HHMMSS_PID.tsv` — Pfade, die für das Quarantäne-Rollback benötigt werden

```bash
# Öffnen des letzten Berichts
open reports/$(ls -t reports/ | head -1)
```

## Erweiterung und Konfiguration

### Hinzufügen einer Neuen Anwendung zur Regelbasis

Bearbeiten Sie `cleanup_rules.yaml` und fügen Sie einen Eintrag nach diesem Schema hinzu:

```yaml
- name: "App Name"
  bundle_ids:
    - "com.vendor.appname"
  type: dev-tool   # browser|mail|dev-tool|media-editor|system|...
  paths:
    - path: "~/Library/Caches/com.vendor.appname"
      type: cache
      safety: ask   # safe | ask | never
      notes: "Beschreibung was dies ist und ob es sicher ist"
```

### Ändern der Altersschwellenwerte

Bearbeiten Sie `config/defaults.sh`:

```bash
LOG_MAX_AGE_DAYS=30       # Logs älter als N Tage
TMP_MAX_AGE_HOURS=24      # Tmp Dateien älter als N Stunden
DMG_MAX_AGE_DAYS=30       # DMG/PKG in ~/Downloads
```

## Haftungsausschluss

> **Die Verwendung dieses Skripts erfolgt auf eigene Gefahr.** Das Skript wurde mit Blick auf Sicherheit entwickelt und fragt immer nach, bevor gelöscht wird, aber keine Software ist fehlerfrei. Stellen Sie sicher, dass Sie ein aktuelles Backup haben, bevor Sie es zum ersten Mal in einem anderen Modus als dem dry-run ausführen.


---

## 🌍 Landing Page & UI Preview

<p align="center">
  <a href="https://macos-cleanup.64bit.site">
    <br/>
    <strong>Visit Official Website for full details and documentation</strong>
  </a>
</p>

---

Projekt: `macOS_cleanup` | Version: 3.0.7 | Lizenz: MIT
