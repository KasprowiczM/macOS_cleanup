[🇺🇸 EN](README.md) | [🇵🇱 PL](README.pl.md) | [🇪🇸 ES](README.es.md) | [🇫🇷 FR](README.fr.md) | [🇩🇪 DE](README.de.md) | [🇮🇹 IT](README.it.md) | [🇵🇹 PT](README.pt.md)

---

<p align="center">
  <img src="assets/macos-cleanup-logo.png" alt="macOS Cleanup Logo" width="350" />
</p>

# macOS Cleanup — Professional System Cleaner

> **Profesjonalne narzędzie czyszczące macOS** — bezpieczniejsze niż komercyjne aplikacje, w pełni transparentne, z pełną kontrolą użytkownika nad tym, co jest usuwane.

<p align="center">
  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</p>

## Czym jest ten projekt?

`cleanup_all.sh` to skrypt bash zaprojektowany dla zaawansowanych użytkowników macOS, który:

- **Analizuje** system i identyfikuje co można bezpiecznie usunąć
- **Informuje** o konsekwencjach każdej operacji przed jej wykonaniem
- **Czeka na Twoją zgodę** — domyślna odpowiedź to zawsze NIE
- **Przenosi dane użytkownika do kwarantanny** w trybach czyszczenia, żeby możliwy był rollback
- **Nigdy nie dotyka** danych poczty, haseł, cookies, profili przeglądarek, dokumentów

## Wymagania

- macOS 10.15 Catalina lub nowszy (w tym Sonoma, Sequoia, macOS 26.x)
- bash 3.2+ (preinstalowany na macOS)
- Python 3.10+ dla pomocniczych narzędzi `dev-sync/` oraz bezpiecznego parsowania `plan.json` w `apply --from-plan`
- Opcjonalnie: `bc` (dla obliczeń rozmiarów), `mdfind` (Spotlight, preinstalowany)

## Instalacja

### Szybki test — instalator jedną linijką

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

Instalator **tylko klonuje repo i drukuje kolejne kroki** — niczego nie usuwa i
nie uruchamia czyszczenia. Domyślnie instaluje do `~/Dev_Env/macOS_cleanup`
(zmień przez `MACOS_CLEANUP_DIR=...`). Wolisz najpierw przejrzeć kod? Pobierz i
obejrzyj [`install.sh`](install.sh) przed uruchomieniem.

### Ręczna instalacja

```bash
git clone https://github.com/KasprowiczM/macOS_cleanup.git ~/Dev_Env/macOS_cleanup
cd ~/Dev_Env/macOS_cleanup
chmod +x cleanup_all.sh
```

## Sposób uruchomienia

### 1. Zalecane pierwsze uruchomienie — analiza (dry-run)

```bash
bash cleanup_all.sh
```

Skrypt przeanalizuje system, pokaże co można wyczyścić i zapyta czy chcesz przejść do czyszczenia. **Nic nie zostanie usunięte bez Twojej zgody.**

### 2. Pełne interaktywne czyszczenie

```bash
bash cleanup_all.sh --interactive
```

Przechodzi przez każdą kategorię z wyjaśnieniem co to jest, jakie są konsekwencje usunięcia i pyta o zgodę. Domyślne realne czyszczenie działa w trybie `--quarantine`: ścieżki użytkownika są przenoszone do `~/Library/Application Support/macOS_cleanup/quarantine`, a nie kasowane natychmiast.

Jeżeli po dry-run chcesz od razu trwale odzyskać miejsce, uruchom tryb permanentny:

```bash
bash cleanup_all.sh --interactive --permanent
```

### 3. Automatyczne czyszczenie tylko bezpiecznych elementów

```bash
bash cleanup_all.sh --auto-safe
```

Domyślnie przenosi do kwarantanny tylko jawnie znane cache aplikacji oznaczone jako niskiego ryzyka. Ogólne top-level elementy `~/Library/Caches` są raportowane do decyzji użytkownika, bo mogą oznaczać duże cache offline, które aplikacja musiałaby później pobrać ponownie. Pliki tymczasowe i ścieżki spoza `$HOME` wymagają trybu `--permanent`, ponieważ nie mają sensownego rollbacku:

```bash
bash cleanup_all.sh --auto-safe --permanent
```

Resztę raportuje do Twojej decyzji.

### 4. Konkretna kategoria

```bash
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --dry-run --category user-caches
bash cleanup_all.sh --interactive --category time-machine
```

### 5. Analyze / plan / apply

```bash
# Alias czytelny dla workflow agentów/operatorów
bash cleanup_all.sh analyze

# Analiza + strukturalny plan JSON
bash cleanup_all.sh plan

# Wykonanie planu: domyślnie wyłącznie SAFE
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Symulacja wykonania planu
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run
```

`plan.json` zawiera operacje z `id`, ścieżką albo komendą, kategorią, klasą `SAFE`/`REVIEW`/`DANGEROUS`, szacowanym rozmiarem, opisem skutków i rekomendacją. `apply --from-plan` nigdy nie wykonuje `DANGEROUS`; `REVIEW` jest pomijane, chyba że dodasz `--include-review` i przejdziesz interaktywne potwierdzenie.

### 6. Tryb bez interakcji (CI/automatyzacja)

```bash
# Analiza bez pytań
bash cleanup_all.sh --dry-run --non-interactive

# Auto-safe bez ręcznego potwierdzenia (tylko jawnie bezpieczne elementy)
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Realny odzysk miejsca w automatyzacji: tylko po świadomym --permanent
bash cleanup_all.sh --auto-safe --permanent --non-interactive --yes

# Uruchomienie konkretnej kategorii bez promptów
bash cleanup_all.sh --dry-run --non-interactive --category app-leftovers
```

`--non-interactive` uruchamia skrypt bez czytania inputu z TTY.
Dla bezpieczeństwa każde pytanie jest domyślnie traktowane jako `nie`.
`--yes` potwierdza tylko operacje niskiego ryzyka; kategorie medium/high wymagają trybu interaktywnego.

### 7. Z wykluczeniem ścieżki

```bash
bash cleanup_all.sh --interactive --exclude "$HOME/Library/Caches/myapp"
```

### 8. Kwarantanna, restore i purge

```bash
# Lista zapisanych runów kwarantanny
bash cleanup_all.sh --list-quarantine

# Odtworzenie ostatniego runu albo konkretnego manifestu
bash cleanup_all.sh --restore latest
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Podgląd trwałego usunięcia kwarantanny
bash cleanup_all.sh --purge-quarantine latest

# Faktyczne zwolnienie miejsca zajętego przez kwarantannę
bash cleanup_all.sh --purge-quarantine latest --apply

# Purge runów starszych niż okres retencji
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
```

Kwarantanna daje rollback, ale sama nie zwalnia miejsca na dysku. Miejsce odzyskujesz dopiero po `--permanent` albo po późniejszym `--purge-quarantine ... --apply`.

### 9. Wyjście JSON — maszynowy odczyt wyników (`--json`)

```bash
# Wynik analityczny (dry-run) w formacie JSON na stdout
bash cleanup_all.sh --dry-run --non-interactive --json --category dev

# Połącz z potokiem (human output trafia na stderr)
bash cleanup_all.sh plan --json --non-interactive 2>/dev/null | jq .counters

# Zapisz JSON do pliku, a raport Markdown pomiń
bash cleanup_all.sh --dry-run --non-interactive --json --category trash 2>/dev/null > summary.json
```

Flaga `--json` przekierowuje cały czytelny output (banery, sekcje, podsumowanie) na **stderr** i emituje jeden obiekt JSON na **stdout** na końcu runu. Obiekt zawiera:

| Pole | Opis |
|------|------|
| `mode` | Tryb wykonania (`dry-run`, `plan`, `apply-plan`, itp.) |
| `dry_run` | `true` / `false` |
| `categories` | Tablica aktywnych kategorii |
| `counters` | `would_free_bytes`, `cleaned_bytes`, `quarantined_bytes`, `skipped_items`, `user_decisions_needed` |
| `plan` | Liczniki operacji `SAFE`/`REVIEW`/`DANGEROUS` i bajty |
| `artifacts` | Ścieżki do `report`, `plan`, `journal`, `restore_manifest` |
| `warnings` | Liczba pominięć |
| `user_decisions` | Lista opisów elementów wymagających decyzji |

Flaga działa z każdym trybem (`dry-run`, `plan`, `apply`, `--auto-safe`, itp.) i jest bezpieczna dla `--non-interactive` oraz CI. Nie zmienia żadnego zachowania jeśli nie jest podana.

## Dostępne kategorie

| Kategoria | Co zawiera |
|-----------|-----------|
| `trash` | Zawartość ~/.Trash |
| `system` | Cache systemowe, stare pliki /tmp i /private/tmp |
| `user-caches` | ~/Library/Caches (cache aplikacji użytkownika) |
| `logs` | Stare logi aplikacji i systemu |
| `app-leftovers` | Heurystyczny raport pozostałości; domyślnie bez automatycznego usuwania |
| `dev` | Xcode DerivedData, symulatory, npm/pip/brew/docker cache |
| `time-machine` | Lokalne snapshoty TM + backupy iOS |
| `large-files` | Stare DMG/PKG/ISO w ~/Downloads |

## Model bezpieczeństwa

### Filozofia: Informed Consent

Skrypt działa w modelu **świadomej zgody**:

```
Analiza → Pokaż wyniki → Wyjaśnij konsekwencje → Ostrzeżenia → Poczekaj na zgodę → Działaj
```

Docelowy język UX/DX opisuje ten przepływ jako **analyze → plan → apply**:

- `analyze` — dry-run bez mutacji, np. `bash cleanup_all.sh --dry-run`
- `plan` — raport Markdown, journal JSONL i lista elementów wymagających decyzji
- `apply` — realne działanie po zgodzie: `apply --from-plan`, `--interactive`, `--auto-safe` albo `--purge-quarantine ... --apply`

Szczegółowy model dla operatorów i agentów: `docs/ux_dx_safety_model.md`.

### Co NIGDY nie jest dotykane

- `~/Library/Mail` — dane Apple Mail i wszystkich klientów poczty
- `~/Library/Containers/com.apple.mail` i lokalne magazyny Outlook/Spark/Thunderbird
- `~/Library/Keychains` — pęk kluczy macOS
- Profile przeglądarek (Chrome, Firefox, Edge, Safari) — cookies, hasła, zakładki
- Menedżery haseł (1Password, Bitwarden, LastPass)
- `~/Documents`, `~/Desktop`
- Photos Library, Music Library
- Provisioning Profiles i certyfikaty deweloperskie
- Dane kontenerów sandboxowych aplikacji systemowych
- Klucze SSH/GPG i credential stores

### Poziomy bezpieczeństwa reguł

- `SAFE` — odtwarzalne artefakty, np. precyzyjnie znane cache aplikacji; mogą wejść do `--auto-safe`, nadal przez guardraile
- `REVIEW` — wymaga planu i decyzji użytkownika, np. ogólne cache, logi, build artefacts, backupy iOS
- `DANGEROUS` — dane użytkownika, tożsamość, profile, poczta, hasła; nie usuwać automatycznie

Obecny `cleanup_rules.yaml` zachowuje wartości techniczne `safe`, `ask`, `never`. Mapowanie UX/DX to odpowiednio `SAFE`, `REVIEW`, `DANGEROUS`.

### Journal i rollback

Każdy raport zapisuje maszynowe podsumowanie planu do `reports/journal_*.jsonl` (`report_generated`, `category_total`). Realne operacje `safe_remove()` dopisują zdarzenia wykonawcze, np. `quarantined`, `deleted`, `skipped_non_user_scope`. Kontrolowane komendy natywne, takie jak `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable` i `tmutil deletelocalsnapshots`, dopisują zdarzenia `native_command`, bo nie mają rollbacku kwarantanny. Dla kwarantanny powstaje też `reports/restore_*.tsv`, którego używa `--restore`. Restore odmawia odtwarzania poza katalog użytkownika, do chronionych ścieżek, przez symlinkowane katalogi nadrzędne i z plików spoza katalogu kwarantanny.

Kwarantanna jest rollbackiem, nie backupem. Przed pierwszym realnym czyszczeniem użytkownik nadal powinien mieć aktualny backup systemowy. Poczta i profile przeglądarek są obsługiwane wyłącznie jako wskazówki: cache może być raportowane, ale dane kont, sesje, cookies, zakładki i lokalne magazyny wiadomości pozostają poza automatycznym czyszczeniem.

## Struktura projektu

```
macOS_cleanup/
├── cleanup_all.sh          # Główny skrypt — punkt wejścia
├── cleanup_rules.yaml      # Baza wiedzy: reguły czyszczenia per-aplikacja
├── config/
│   └── defaults.sh         # Domyślna konfiguracja, progi wiekowe, ścieżki chronione
├── lib/
│   ├── common.sh           # Logging, formatowanie, safe_remove(), ochrona ścieżek
│   ├── policy.sh           # Parser polityk YAML i mapowanie SAFE/REVIEW/DANGEROUS
│   ├── analyzer.sh         # Analiza systemu (wszystkie analyze_* funkcje)
│   ├── cleaner.sh          # Silnik czyszczenia (wszystkie clean_* funkcje)
│   ├── planner.sh          # plan.json i apply --from-plan
│   ├── interactive.sh      # Prompty i potwierdzenia użytkownika
│   └── reporter.sh         # Generator raportów Markdown
├── docs/
│   ├── rules_design.md     # Dokumentacja struktury reguł
│   └── ux_dx_safety_model.md # Model SAFE/REVIEW/DANGEROUS i analyze/plan/apply
├── dev-sync/               # Pomocniczy sync prywatnego overlayu lokalnego
├── DEV_SCRIPTS_README.md   # Operator guide dla dev-sync
├── DESIGN.md               # System projektowy UX/UI dla raportów i prototypów
├── graphify-out/           # Mapa projektu dla agentów (generowana)
├── logs/                   # Logi wykonań (auto-generowane)
├── reports/                # Raporty Markdown, journal JSONL i manifesty restore
├── tests/                  # Scenariusze testowe
├── AGENTS.md               # Rola agentów AI w projekcie
├── CLAUDE.md               # Instrukcje dla Claude / Cowork
├── CODEX.md                # Instrukcje dla asystentów code-focused
└── GEMINI.md               # Instrukcje dla modeli Gemini
```

## Raporty i logi

Po każdym uruchomieniu skrypt generuje:

- **Log**: `logs/cleanup_YYYY-MM-DD_HHMMSS_PID.log` — pełny dziennik operacji
- **Raport**: `reports/report_YYYY-MM-DD_HHMMSS_PID.md` — Markdown z podsumowaniem
- **Plan**: `reports/plan_YYYY-MM-DD_HHMMSS_PID.json` — strukturalny plan `SAFE`/`REVIEW`/`DANGEROUS`
- **Journal**: `reports/journal_YYYY-MM-DD_HHMMSS_PID.jsonl` — maszynowy plan i audit operacji
- **Manifest restore**: `reports/restore_YYYY-MM-DD_HHMMSS_PID.tsv` — ścieżki potrzebne do rollbacku kwarantanny

```bash
# Otwórz ostatni raport
open reports/$(ls -t reports/ | head -1)
```

## Dev-sync i mapa agentów

`dev-sync/` to pomocniczy system odtwarzania prywatnych plików lokalnych po klonie na nowej maszynie. Git pozostaje źródłem prawdy dla tracked source; provider przechowuje tylko manifest-backed overlay. Start:

```bash
bash dev-sync/provider_setup.sh
bash dev-sync/dev-sync-export.sh --dry-run --verbose
```

Szczegóły: `DEV_SCRIPTS_README.md`.

Mapa projektu dla agentów jest generowana przez graphify w `graphify-out/`. Plik `graphify-out/AGENT_PROJECT_MAP.md` zawiera skrót architektury i ścieżkę walidacji dla kolejnych sesji.

## Rozszerzanie i konfiguracja

### Dodanie nowej aplikacji do bazy reguł

Edytuj `cleanup_rules.yaml` i dodaj wpis według schematu:

```yaml
- name: "Nazwa Aplikacji"
  bundle_ids:
    - "com.vendor.appname"
  type: dev-tool   # browser|mail|dev-tool|media-editor|system|...
  paths:
    - path: "~/Library/Caches/com.vendor.appname"
      type: cache
      safety: ask   # safe | ask | never
      notes: "Opis co to jest i czy bezpieczne"
```

### Zmiana progów wiekowych

Edytuj `config/defaults.sh`:

```bash
LOG_MAX_AGE_DAYS=30       # Logi starsze niż N dni
TMP_MAX_AGE_HOURS=24      # Tmp pliki starsze niż N godzin
DMG_MAX_AGE_DAYS=30       # DMG/PKG w ~/Downloads
```

## Disclaimer

> **Używasz tego skryptu na własną odpowiedzialność.** Skrypt jest zaprojektowany z myślą o bezpieczeństwie i zawsze pyta przed usunięciem, ale żadne oprogramowanie nie jest wolne od błędów. Przed pierwszym uruchomieniem w trybie innym niż dry-run upewnij się, że masz aktualną kopię zapasową.


---

## 🌍 Landing Page & UI Preview

<p align="center">
  <a href="https://macos-cleanup.64bit.site">
    <br/>
    <strong>Visit Official Website for full details and documentation</strong>
  </a>
</p>

---

Projekt: `macOS_cleanup` | Wersja: 2.1.0 | Licencja: MIT
