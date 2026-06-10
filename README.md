[🇺🇸 EN](README.md) | [🇵🇱 PL](README.pl.md) | [🇪🇸 ES](README.es.md) | [🇫🇷 FR](README.fr.md) | [🇩🇪 DE](README.de.md) | [🇮🇹 IT](README.it.md) | [🇵🇹 PT](README.pt.md)

---

# macOS Cleanup — Professional System Cleaner

> **Professional macOS cleaning tool** — safer than commercial apps, fully transparent, with total user control over what gets deleted.

## What is this project?

`cleanup_all.sh` is a bash script designed for advanced macOS users that:

- **Analyzes** the system and identifies what can be safely removed
- **Informs** you about the consequences of each operation before executing it
- **Waits for your consent** — the default answer is always NO
- **Moves user data to quarantine** in cleaning modes, so a rollback is possible
- **Never touches** mail data, passwords, cookies, browser profiles, or documents

## Requirements

- macOS 10.15 Catalina or newer (including Sonoma, Sequoia, macOS 26.x)
- bash 3.2+ (preinstalled on macOS)
- Python 3.10+ for auxiliary `dev-sync/` tools and safe `plan.json` parsing in `apply --from-plan`
- Optional: `bc` (for size calculations), `mdfind` (Spotlight, preinstalled)

## Installation

### Quick Test — One-liner installer

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

The installer **only clones the repo and prints the next steps** — it does not delete anything or start the cleanup. It installs to `~/Dev_Env/macOS_cleanup` by default (change it via `MACOS_CLEANUP_DIR=...`). Prefer to review the code first? Download and inspect [`install.sh`](install.sh) before running.

### Manual Installation

```bash
git clone https://github.com/KasprowiczM/macOS_cleanup.git ~/Dev_Env/macOS_cleanup
cd ~/Dev_Env/macOS_cleanup
chmod +x cleanup_all.sh
```

## Usage

### 1. Recommended First Run — Analysis (dry-run)

```bash
bash cleanup_all.sh
```

The script will analyze your system, show you what can be cleaned, and ask if you want to proceed. **Nothing is deleted without your consent.**

### 2. Full Interactive Cleanup

```bash
bash cleanup_all.sh --interactive
```

Goes through each category, explaining what it is, the consequences of deletion, and asks for your permission. The default actual cleanup works in `--quarantine` mode: user paths are moved to `~/Library/Application Support/macOS_cleanup/quarantine` instead of being immediately deleted.

If you want to permanently free up space immediately after the dry-run, run the permanent mode:

```bash
bash cleanup_all.sh --interactive --permanent
```

### 3. Automatic Cleanup of Only Safe Items

```bash
bash cleanup_all.sh --auto-safe
```

By default, this only quarantines explicitly known low-risk application caches. General top-level items in `~/Library/Caches` are reported for the user's decision because they might include large offline caches that apps would have to redownload. Temporary files and paths outside `$HOME` require `--permanent` mode because there is no sensible quarantine rollback for them:

```bash
bash cleanup_all.sh --auto-safe --permanent
```

Everything else is reported for your decision.

### 4. Specific Category

```bash
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --dry-run --category user-caches
bash cleanup_all.sh --interactive --category time-machine
```

### 5. Analyze / plan / apply

```bash
# Readable alias for agent/operator workflows
bash cleanup_all.sh analyze

# Analysis + structural JSON plan
bash cleanup_all.sh plan

# Execute plan: only SAFE by default
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Simulate plan execution
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run
```

`plan.json` contains operations with `id`, path or command, category, class `SAFE`/`REVIEW`/`DANGEROUS`, estimated size, consequences description, and recommendation. `apply --from-plan` never executes `DANGEROUS`; `REVIEW` is skipped unless you add `--include-review` and go through the interactive confirmation.

### 6. Non-interactive Mode (CI/Automation)

```bash
# Analysis without prompts
bash cleanup_all.sh --dry-run --non-interactive

# Auto-safe without manual confirmation (only explicitly safe items)
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Real space recovery in automation: only after conscious --permanent
bash cleanup_all.sh --auto-safe --permanent --non-interactive --yes

# Run a specific category without prompts
bash cleanup_all.sh --dry-run --non-interactive --category app-leftovers
```

`--non-interactive` runs the script without reading input from TTY.
For safety, every question is treated as `no` by default.
`--yes` confirms only low-risk operations; medium/high categories require interactive mode.

### 7. With Path Exclusion

```bash
bash cleanup_all.sh --interactive --exclude "$HOME/Library/Caches/myapp"
```

### 8. Quarantine, Restore, and Purge

```bash
# List saved quarantine runs
bash cleanup_all.sh --list-quarantine

# Restore the latest run or a specific manifest
bash cleanup_all.sh --restore latest
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Preview permanent quarantine deletion
bash cleanup_all.sh --purge-quarantine latest

# Actually free up space taken by the quarantine
bash cleanup_all.sh --purge-quarantine latest --apply

# Purge runs older than the retention period
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
```

Quarantine provides a rollback but does not free up disk space itself. You only recover space after `--permanent` or a subsequent `--purge-quarantine ... --apply`.

### 9. JSON Output — Machine Readable Results (`--json`)

```bash
# Analytical output (dry-run) in JSON format on stdout
bash cleanup_all.sh --dry-run --non-interactive --json --category dev

# Combine with a pipe (human output goes to stderr)
bash cleanup_all.sh plan --json --non-interactive 2>/dev/null | jq .counters

# Save JSON to a file, and skip the Markdown report
bash cleanup_all.sh --dry-run --non-interactive --json --category trash 2>/dev/null > summary.json
```

The `--json` flag redirects all readable output (banners, sections, summaries) to **stderr** and emits a single JSON object to **stdout** at the end of the run. The object contains:

| Field | Description |
|-------|-------------|
| `mode` | Execution mode (`dry-run`, `plan`, `apply-plan`, etc.) |
| `dry_run` | `true` / `false` |
| `categories` | Array of active categories |
| `counters` | `would_free_bytes`, `cleaned_bytes`, `quarantined_bytes`, `skipped_items`, `user_decisions_needed` |
| `plan` | Counters for `SAFE`/`REVIEW`/`DANGEROUS` operations and bytes |
| `artifacts` | Paths to `report`, `plan`, `journal`, `restore_manifest` |
| `warnings` | Number of skipped items |
| `user_decisions` | List of item descriptions requiring a decision |

The flag works with every mode (`dry-run`, `plan`, `apply`, `--auto-safe`, etc.) and is safe for `--non-interactive` and CI. It doesn't change any behavior if not provided.

## Available Categories

| Category | Contents |
|----------|----------|
| `trash` | Contents of ~/.Trash |
| `system` | System caches, old /tmp and /private/tmp files |
| `user-caches` | ~/Library/Caches (user app caches) |
| `logs` | Old application and system logs |
| `app-leftovers` | Heuristic leftover report; no automatic deletion by default |
| `dev` | Xcode DerivedData, simulators, npm/pip/brew/docker caches |
| `time-machine` | Local TM snapshots + iOS backups |
| `large-files` | Old DMG/PKG/ISO files in ~/Downloads |

## Security Model

### Philosophy: Informed Consent

The script operates on an **informed consent** model:

```
Analyze → Show results → Explain consequences → Warnings → Wait for consent → Act
```

The target UX/DX language describes this flow as **analyze → plan → apply**:

- `analyze` — dry-run without mutation, e.g., `bash cleanup_all.sh --dry-run`
- `plan` — Markdown report, JSONL journal, and a list of items requiring a decision
- `apply` — real action after consent: `apply --from-plan`, `--interactive`, `--auto-safe`, or `--purge-quarantine ... --apply`

Detailed model for operators and agents: `docs/ux_dx_safety_model.md`.

### What is NEVER Touched

- `~/Library/Mail` — Apple Mail data and all email clients
- `~/Library/Containers/com.apple.mail` and local Outlook/Spark/Thunderbird stores
- `~/Library/Keychains` — macOS Keychain
- Browser profiles (Chrome, Firefox, Edge, Safari) — cookies, passwords, bookmarks
- Password managers (1Password, Bitwarden, LastPass)
- `~/Documents`, `~/Desktop`
- Photos Library, Music Library
- Provisioning Profiles and developer certificates
- Sandbox container data of system applications
- SSH/GPG keys and credential stores

### Rule Security Levels

- `SAFE` — reproducible artifacts, e.g., precisely known app caches; can enter `--auto-safe`, still passed through guardrails
- `REVIEW` — requires a plan and user decision, e.g., general caches, logs, build artifacts, iOS backups
- `DANGEROUS` — user data, identity, profiles, mail, passwords; not deleted automatically

The current `cleanup_rules.yaml` retains technical values `safe`, `ask`, `never`. The UX/DX mapping corresponds to `SAFE`, `REVIEW`, `DANGEROUS`.

### Journal and Rollback

Every report saves a machine summary of the plan to `reports/journal_*.jsonl` (`report_generated`, `category_total`). Real `safe_remove()` operations append execution events, e.g., `quarantined`, `deleted`, `skipped_non_user_scope`. Controlled native commands, such as `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable`, and `tmutil deletelocalsnapshots`, append `native_command` events since they have no quarantine rollback. The quarantine also generates `reports/restore_*.tsv`, which is used by `--restore`. The restore process refuses to recover outside the user directory, to protected paths, through symlinked parent directories, or from files outside the quarantine directory.

Quarantine is a rollback, not a backup. Before the first real cleanup, the user should still have a recent system backup. Mail and browser profiles are handled solely as guidelines: caches might be reported, but account data, sessions, cookies, bookmarks, and local message stores are kept out of automatic cleaning.

## Project Structure

```
macOS_cleanup/
├── cleanup_all.sh          # Main script — entry point
├── cleanup_rules.yaml      # Knowledge base: per-app cleaning rules
├── config/
│   └── defaults.sh         # Default configuration, age thresholds, protected paths
├── lib/
│   ├── common.sh           # Logging, formatting, safe_remove(), path protection
│   ├── policy.sh           # YAML policy parser and SAFE/REVIEW/DANGEROUS mapping
│   ├── analyzer.sh         # System analysis (all analyze_* functions)
│   ├── cleaner.sh          # Cleaning engine (all clean_* functions)
│   ├── planner.sh          # plan.json and apply --from-plan
│   ├── interactive.sh      # User prompts and confirmations
│   └── reporter.sh         # Markdown report generator
├── docs/
│   ├── rules_design.md     # Rule structure documentation
│   └── ux_dx_safety_model.md # SAFE/REVIEW/DANGEROUS model and analyze/plan/apply
├── tests/                  # Test scenarios
└── AGENTS.md               # The role of AI agents in the project
```

## Reports and Logs

After each run, the script generates:

- **Log**: `logs/cleanup_YYYY-MM-DD_HHMMSS_PID.log` — full operation diary
- **Report**: `reports/report_YYYY-MM-DD_HHMMSS_PID.md` — Markdown summary
- **Plan**: `reports/plan_YYYY-MM-DD_HHMMSS_PID.json` — structural `SAFE`/`REVIEW`/`DANGEROUS` plan
- **Journal**: `reports/journal_YYYY-MM-DD_HHMMSS_PID.jsonl` — machine plan and audit log
- **Restore Manifest**: `reports/restore_YYYY-MM-DD_HHMMSS_PID.tsv` — paths needed for quarantine rollback

```bash
# Open the last report
open reports/$(ls -t reports/ | head -1)
```

## Extending and Configuration

### Adding a New Application to the Rule Base

Edit `cleanup_rules.yaml` and add an entry following this schema:

```yaml
- name: "App Name"
  bundle_ids:
    - "com.vendor.appname"
  type: dev-tool   # browser|mail|dev-tool|media-editor|system|...
  paths:
    - path: "~/Library/Caches/com.vendor.appname"
      type: cache
      safety: ask   # safe | ask | never
      notes: "Description of what this is and if it's safe"
```

### Changing Age Thresholds

Edit `config/defaults.sh`:

```bash
LOG_MAX_AGE_DAYS=30       # Logs older than N days
TMP_MAX_AGE_HOURS=24      # Tmp files older than N hours
DMG_MAX_AGE_DAYS=30       # DMG/PKG in ~/Downloads
```

## Disclaimer

> **Use this script at your own risk.** The script is designed with safety in mind and always asks before deleting, but no software is bug-free. Ensure you have a recent backup before running in a mode other than dry-run for the first time.

---

Project: `macOS_cleanup` | Version: 2.1.0 | License: MIT
