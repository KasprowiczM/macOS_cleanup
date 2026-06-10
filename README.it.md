[🇺🇸 EN](README.md) | [🇵🇱 PL](README.pl.md) | [🇪🇸 ES](README.es.md) | [🇫🇷 FR](README.fr.md) | [🇩🇪 DE](README.de.md) | [🇮🇹 IT](README.it.md) | [🇵🇹 PT](README.pt.md)

---

# macOS Cleanup — Pulizia del Sistema Professionale

> **Strumento di pulizia professionale per macOS** — più sicuro delle app commerciali, completamente trasparente, con controllo totale dell'utente su cosa viene eliminato.

## Che cos'è questo progetto?

`cleanup_all.sh` è uno script bash progettato per utenti avanzati di macOS che:

- **Analizza** il sistema e identifica ciò che può essere rimosso in sicurezza
- **Ti informa** sulle conseguenze di ogni operazione prima di eseguirla
- **Attende il tuo consenso** — la risposta predefinita è sempre NO
- **Sposta i dati dell'utente in quarantena** nelle modalità di pulizia, in modo da poter annullare le modifiche
- **Non tocca mai** i dati di posta, le password, i cookie, i profili del browser o i documenti

## Requisiti

- macOS 10.15 Catalina o successivi (inclusi Sonoma, Sequoia, macOS 26.x)
- bash 3.2+ (preinstallato su macOS)
- Python 3.10+ per gli strumenti ausiliari `dev-sync/` e per l'analisi sicura di `plan.json` in `apply --from-plan`
- Opzionale: `bc` (per il calcolo delle dimensioni), `mdfind` (Spotlight, preinstallato)

## Installazione

### Test Rapido — Programma di installazione con una sola riga

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

L'installer **clona solo la repository e stampa i passaggi successivi** — non elimina nulla né avvia la pulizia. Si installa in `~/Dev_Env/macOS_cleanup` per impostazione predefinita (modificabile tramite `MACOS_CLEANUP_DIR=...`). Preferisci prima esaminare il codice? Scarica e ispeziona [`install.sh`](install.sh) prima dell'esecuzione.

### Installazione Manuale

```bash
git clone https://github.com/KasprowiczM/macOS_cleanup.git ~/Dev_Env/macOS_cleanup
cd ~/Dev_Env/macOS_cleanup
chmod +x cleanup_all.sh
```

## Utilizzo

### 1. Prima Esecuzione Raccomandata — Analisi (dry-run)

```bash
bash cleanup_all.sh
```

Lo script analizzerà il tuo sistema, ti mostrerà cosa può essere pulito e ti chiederà se desideri procedere. **Nulla viene eliminato senza il tuo consenso.**

### 2. Pulizia Interattiva Completa

```bash
bash cleanup_all.sh --interactive
```

Esamina ogni categoria, spiegando cosa sia, le conseguenze dell'eliminazione e chiede il tuo permesso. La pulizia effettiva predefinita funziona in modalità `--quarantine`: i percorsi dell'utente vengono spostati in `~/Library/Application Support/macOS_cleanup/quarantine` invece di essere eliminati immediatamente.

Se desideri liberare spazio permanentemente e immediatamente dopo l'analisi, esegui la modalità permanente:

```bash
bash cleanup_all.sh --interactive --permanent
```

### 3. Pulizia Automatica di Solo Elementi Sicuri

```bash
bash cleanup_all.sh --auto-safe
```

Per impostazione predefinita, questo mette in quarantena solo le cache di applicazioni esplicitamente conosciute e a basso rischio. Gli elementi generali di livello superiore in `~/Library/Caches` vengono segnalati per decisione dell'utente, in quanto potrebbero includere cache offline di grandi dimensioni che le app dovrebbero scaricare di nuovo. I file temporanei e i percorsi al di fuori di `$HOME` richiedono la modalità `--permanent` in quanto non esiste un sensato rollback tramite quarantena per essi:

```bash
bash cleanup_all.sh --auto-safe --permanent
```

Tutto il resto viene segnalato per la tua decisione.

### 4. Categoria Specifica

```bash
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --dry-run --category user-caches
bash cleanup_all.sh --interactive --category time-machine
```

### 5. Analizza / Pianifica / Applica

```bash
# Alias leggibile per i flussi di lavoro degli agenti/operatori
bash cleanup_all.sh analyze

# Analisi + piano JSON strutturale
bash cleanup_all.sh plan

# Esegui piano: per impostazione predefinita solo SAFE
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Simula l'esecuzione del piano
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run
```

`plan.json` contiene operazioni con `id`, percorso o comando, categoria, classe `SAFE`/`REVIEW`/`DANGEROUS`, dimensioni stimate, descrizione delle conseguenze e raccomandazione. `apply --from-plan` non esegue mai `DANGEROUS`; `REVIEW` viene saltato a meno che non si aggiunga `--include-review` e si proceda alla conferma interattiva.

### 6. Modalità Non Interattiva (CI/Automazione)

```bash
# Analisi senza prompt
bash cleanup_all.sh --dry-run --non-interactive

# Pulizia sicura automatica senza conferma manuale (solo elementi esplicitamente sicuri)
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Reale recupero di spazio nell'automazione: solo dopo un consapevole --permanent
bash cleanup_all.sh --auto-safe --permanent --non-interactive --yes

# Esegui una categoria specifica senza prompt
bash cleanup_all.sh --dry-run --non-interactive --category app-leftovers
```

`--non-interactive` esegue lo script senza leggere l'input dal TTY.
Per sicurezza, ogni domanda viene considerata `no` di default.
`--yes` conferma solo le operazioni a basso rischio; le categorie medie/alte richiedono la modalità interattiva.

### 7. Con Esclusione di Percorso

```bash
bash cleanup_all.sh --interactive --exclude "$HOME/Library/Caches/myapp"
```

### 8. Quarantena, Ripristino ed Eliminazione Definitiva

```bash
# Elenca le esecuzioni in quarantena salvate
bash cleanup_all.sh --list-quarantine

# Ripristina l'ultima esecuzione o un manifesto specifico
bash cleanup_all.sh --restore latest
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Anteprima dell'eliminazione permanente della quarantena
bash cleanup_all.sh --purge-quarantine latest

# Libera effettivamente lo spazio occupato dalla quarantena
bash cleanup_all.sh --purge-quarantine latest --apply

# Elimina definitivamente le esecuzioni precedenti al periodo di conservazione
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
```

La quarantena offre un rollback, ma di per sé non libera spazio su disco. Recuperi spazio solo dopo `--permanent` o un successivo `--purge-quarantine ... --apply`.

### 9. Output JSON — Risultati Leggibili dalla Macchina (`--json`)

```bash
# Output analitico (dry-run) in formato JSON su stdout
bash cleanup_all.sh --dry-run --non-interactive --json --category dev

# Combina con un pipe (l'output umano va su stderr)
bash cleanup_all.sh plan --json --non-interactive 2>/dev/null | jq .counters

# Salva JSON in un file e salta il report in Markdown
bash cleanup_all.sh --dry-run --non-interactive --json --category trash 2>/dev/null > summary.json
```

Il flag `--json` reindirizza tutto l'output leggibile (banner, sezioni, riepiloghi) verso **stderr** ed emette un singolo oggetto JSON verso **stdout** al termine dell'esecuzione. L'oggetto contiene:

| Campo | Descrizione |
|-------|-------------|
| `mode` | Modalità di esecuzione (`dry-run`, `plan`, `apply-plan`, ecc.) |
| `dry_run` | `true` / `false` |
| `categories` | Array delle categorie attive |
| `counters` | `would_free_bytes`, `cleaned_bytes`, `quarantined_bytes`, `skipped_items`, `user_decisions_needed` |
| `plan` | Contatori per operazioni `SAFE`/`REVIEW`/`DANGEROUS` e byte |
| `artifacts` | Percorsi verso `report`, `plan`, `journal`, `restore_manifest` |
| `warnings` | Numero di elementi saltati |
| `user_decisions` | Elenco delle descrizioni di elementi che richiedono una decisione |

Il flag funziona con ogni modalità (`dry-run`, `plan`, `apply`, `--auto-safe`, ecc.) ed è sicuro per `--non-interactive` e CI. Non modifica alcun comportamento se non specificato.

## Categorie Disponibili

| Categoria | Contenuto |
|-----------|-----------|
| `trash` | Contenuto di ~/.Trash |
| `system` | Cache di sistema, file obsoleti /tmp e /private/tmp |
| `user-caches` | ~/Library/Caches (cache app dell'utente) |
| `logs` | Registri vecchi di sistema e delle applicazioni |
| `app-leftovers` | Report euristico dei rimasugli; nessuna eliminazione automatica di default |
| `dev` | Xcode DerivedData, simulatori, cache npm/pip/brew/docker |
| `time-machine` | Snapshot locali di TM + backup di iOS |
| `large-files` | Vecchi file DMG/PKG/ISO in ~/Downloads |

## Modello di Sicurezza

### Filosofia: Consenso Informato

Lo script funziona in base a un modello di **consenso informato**:

```
Analizza → Mostra risultati → Spiega conseguenze → Avvertenze → Attendi il consenso → Agisci
```

Il linguaggio di destinazione UX/DX descrive questo flusso come **analizza → pianifica → applica**:

- `analyze` — dry-run senza mutazione, es. `bash cleanup_all.sh --dry-run`
- `plan` — report in Markdown, journal in JSONL, e una lista degli elementi che richiedono una decisione
- `apply` — azione reale in seguito a consenso: `apply --from-plan`, `--interactive`, `--auto-safe`, o `--purge-quarantine ... --apply`

Modello dettagliato per operatori e agenti: `docs/ux_dx_safety_model.md`.

### Cosa non viene MAI Toccato

- `~/Library/Mail` — Dati di Apple Mail e tutti i client e-mail
- `~/Library/Containers/com.apple.mail` e repository locali di Outlook/Spark/Thunderbird
- `~/Library/Keychains` — Portachiavi macOS
- Profili dei browser (Chrome, Firefox, Edge, Safari) — cookie, password, preferiti
- Gestori di password (1Password, Bitwarden, LastPass)
- `~/Documents`, `~/Desktop`
- Libreria Foto, Libreria Musica
- Profili di provisioning e certificati di sviluppatori
- Dati di container sandbox di applicazioni di sistema
- Chiavi SSH/GPG e archivi di credenziali

### Livelli di Sicurezza delle Regole

- `SAFE` — artefatti riproducibili, ad es. cache di app esattamente note; può rientrare in `--auto-safe`, passa sempre i filtri di sicurezza
- `REVIEW` — richiede un piano e una decisione dell'utente, ad es. cache generiche, log, artefatti di build, backup iOS
- `DANGEROUS` — dati utente, identità, profili, mail, password; non viene eliminato automaticamente

L'attuale `cleanup_rules.yaml` mantiene i valori tecnici `safe`, `ask`, `never`. La mappatura UX/DX corrisponde a `SAFE`, `REVIEW`, `DANGEROUS`.

### Journal e Rollback

Ogni report salva un riepilogo leggibile dalla macchina del piano su `reports/journal_*.jsonl` (`report_generated`, `category_total`). Reali operazioni di `safe_remove()` aggiungono eventi di esecuzione, es. `quarantined`, `deleted`, `skipped_non_user_scope`. Comandi nativi controllati, come `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable` e `tmutil deletelocalsnapshots` aggiungono eventi `native_command` dato che non hanno opzioni di ripristino dalla quarantena. La quarantena genera anche `reports/restore_*.tsv`, il quale è impiegato da `--restore`. Il processo di ripristino si rifiuta di recuperare dati all'infuori della directory utente, su percorsi protetti, attraverso cartelle padri con link simbolici, o file estranei alla directory di quarantena.

La quarantena è un ripristino, non un backup. Prima della prima vera pulizia, l'utente dovrebbe comunque disporre di un recente backup di sistema. Mail e i profili browser sono considerati solamente a titolo orientativo: le cache potrebbero essere riportate, ma i dati dell'account, le sessioni, i cookie, i segnalibri, e l'archivio messaggi in locale non sono parte del processo di pulizia automatica.

## Struttura del Progetto

```
macOS_cleanup/
├── cleanup_all.sh          # Script principale — punto di ingresso
├── cleanup_rules.yaml      # Base di conoscenza: regole di pulizia per ogni app
├── config/
│   └── defaults.sh         # Configurazione predefinita, soglie di anzianità, percorsi protetti
├── lib/
│   ├── common.sh           # Logging, formattazione, safe_remove(), protezione dei percorsi
│   ├── policy.sh           # Parser delle policy YAML e mappatura SAFE/REVIEW/DANGEROUS
│   ├── analyzer.sh         # Analisi del sistema (tutte le funzioni analyze_*)
│   ├── cleaner.sh          # Motore di pulizia (tutte le funzioni clean_*)
│   ├── planner.sh          # plan.json e apply --from-plan
│   ├── interactive.sh      # Avvisi e conferme dell'utente
│   └── reporter.sh         # Generatore di report Markdown
├── docs/
│   ├── rules_design.md     # Documentazione della struttura delle regole
│   └── ux_dx_safety_model.md # Modello SAFE/REVIEW/DANGEROUS e analyze/plan/apply
├── tests/                  # Scenari di test
└── AGENTS.md               # Il ruolo degli agenti IA nel progetto
```

## Report e Registri

Dopo ogni esecuzione, lo script genera:

- **Registro**: `logs/cleanup_YYYY-MM-DD_HHMMSS_PID.log` — diario operativo completo
- **Report**: `reports/report_YYYY-MM-DD_HHMMSS_PID.md` — Riepilogo Markdown
- **Piano**: `reports/plan_YYYY-MM-DD_HHMMSS_PID.json` — piano strutturale `SAFE`/`REVIEW`/`DANGEROUS`
- **Journal**: `reports/journal_YYYY-MM-DD_HHMMSS_PID.jsonl` — piano della macchina e log di audit
- **Manifesto di ripristino**: `reports/restore_YYYY-MM-DD_HHMMSS_PID.tsv` — percorsi necessari per il rollback di quarantena

```bash
# Apri l'ultimo report
open reports/$(ls -t reports/ | head -1)
```

## Espansione e Configurazione

### Aggiunta di una Nuova Applicazione alla Base delle Regole

Modifica `cleanup_rules.yaml` e aggiungi una voce seguendo questo schema:

```yaml
- name: "Nome App"
  bundle_ids:
    - "com.vendor.appname"
  type: dev-tool   # browser|mail|dev-tool|media-editor|system|...
  paths:
    - path: "~/Library/Caches/com.vendor.appname"
      type: cache
      safety: ask   # safe | ask | never
      notes: "Descrizione di cosa sia e se è sicuro"
```

### Modifica delle Soglie d'Età

Modifica `config/defaults.sh`:

```bash
LOG_MAX_AGE_DAYS=30       # Log più vecchi di N giorni
TMP_MAX_AGE_HOURS=24      # File Tmp più vecchi di N ore
DMG_MAX_AGE_DAYS=30       # DMG/PKG in ~/Downloads
```

## Dichiarazione di Limitazione di Responsabilità

> **Utilizza questo script a tuo rischio e pericolo.** Lo script è stato progettato con l'attenzione rivolta alla sicurezza e richiede sempre un consenso esplicito prima di eliminare dati, tuttavia nessun software è esente da difetti. Assicurati di disporre di un recente backup prima dell'esecuzione iniziale, tramite una modalità diversa da un test virtuale (dry-run).

---

Progetto: `macOS_cleanup` | Versione: 2.1.0 | Licenza: MIT
