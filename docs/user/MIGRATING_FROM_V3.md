# Migrating from 3.x

**macOS Cleanup 4.0.5.** This page lists what changed since 3.0.7 and how to bring your old runs along. Nothing here deletes your old files.

## The short version

1. Install 4.0.5 (see [INSTALL.md](INSTALL.md)). It leaves your old 3.x folder alone.
2. Run `macos-cleanup migrate --preview` to see what would be copied.
3. Run `macos-cleanup migrate --apply` to copy it.
4. Quarantine runs you made with 3.x stay restorable with `macos-cleanup restore`.

## What changed

| Topic | 3.x | 4.x |
|-------|-----|-------|
| Command | `bash cleanup_all.sh` in a git folder | `macos-cleanup` (the engine, `cleanup_all.sh`, still exists) |
| Running with no arguments | Dry run, then an offer to clean | Opens the terminal interface on a terminal. The old flow lives under `--cli` |
| Where the program lives | Wherever you cloned it | `~/.local/share/macos-cleanup` |
| Where logs and reports go | `logs/` and `reports/` inside the program folder | `~/.local/state/macos-cleanup/runs/<run id>/` |
| Settings | Environment variables | `~/.config/macos-cleanup/settings.conf` and the interface |
| Install | `git clone`, checksums checked after cloning | A release package, checksum checked before unpacking |
| Automatic runs | None | Opt-in LaunchAgent, off by default |
| Plans | Any plan file | Only plans this tool wrote, on this Mac, for this user, under 24 hours old |
| Categories | Section names | Section names and 39 category ids, plus `--only <ids>` |

Sections such as `dev` still work with `--category`. Category ids such as `npm` work with `--only` and `--category`.

## Paths

| What | 3.x | 4.x |
|------|-----|-------|
| Engine log | `logs/cleanup_<run>.log` | `~/.local/state/macos-cleanup/runs/<run>/engine.log` |
| Markdown report | `reports/report_<run>.md` | `.../runs/<run>/report.md` |
| Plan | `reports/plan_<run>.json` | `.../runs/<run>/plan.json` |
| Run journal | `reports/journal_<run>.jsonl` | `.../runs/<run>/journal.jsonl` |
| Run summary | printed with `--json` only | `.../runs/<run>/run.json`, always written |
| Restore manifest | `reports/restore_<run>.tsv` | `~/Library/Application Support/macOS_cleanup/quarantine/<run>/manifest.tsv` |
| Quarantine items | `~/Library/Application Support/macOS_cleanup/quarantine/<run>/items/` | unchanged |

The quarantine folder did not move. That is deliberate: moving it would copy every quarantined item and temporarily double the space it uses. The run id format is unchanged.

`LOGS_DIR` and `REPORTS_DIR` still work in 4.x and are logged as deprecated. When set, they replace the run folder for the log, or for the report, plan and journal. Restore information always stays with the quarantine run.

## The `migrate` command

`migrate` only copies. It never deletes anything from your old folder.

```bash
macos-cleanup migrate --preview
macos-cleanup migrate --apply
macos-cleanup migrate --undo MANIFEST
```

- `--preview` lists what would be copied and changes nothing.
- `--apply` copies, records a SHA-256 for each file, and writes a manifest under `~/.local/state/macos-cleanup/backups/layout-<timestamp>/`.
- `--undo MANIFEST` removes only files that `--apply` created and that still match their recorded checksum, and puts back anything it overwrote.

It looks for your old folder in `MACOS_CLEANUP_LEGACY_DIR` if you set it, then in the folder the 3.x installer used by default, then in the current folder if that is a 3.x checkout.

| From your old folder | To |
|----------------------|----|
| `logs/cleanup_<run>.log` | `runs/<run>/engine.log` |
| `reports/report_<run>.md`, `plan_<run>.json`, `journal_<run>.jsonl` | `runs/<run>/report.md`, `plan.json`, `journal.jsonl` |
| `reports/restore_<run>.tsv`, when that quarantine run still exists | `<quarantine>/<run>/manifest.tsv` |
| `reports/restore_<run>.tsv`, when the run no longer exists | `legacy/reports/restore_<run>.tsv` in the state folder (reported as an orphan, never deleted) |
| `cleanup_rules.yaml`, if you edited it | `~/.config/macos-cleanup/rules.local.yaml.from-v3` (not active; review it) |

Copied 3.x runs show up in History marked as legacy. Plans from 3.x are copied for reference only: see below.

If you edited the shipped `cleanup_rules.yaml`, 4.x does not apply your edits automatically. Move the entries you still want into `rules.local.yaml`. That overlay can only make rules stricter, so an edit that marked something `safe` will not carry over.

## Old quarantine runs stay restorable

`macos-cleanup restore <x>` looks for the restore list in this order:

1. `<quarantine>/<x>/manifest.tsv`.
2. If `<x>` is `latest`, the newest run that has a manifest with at least one source still present.
3. `<x>` as a file path.
4. An old-style `restore_<x>.tsv` in your old `reports/` folder (when you run from that checkout), in `REPORTS_DIR` if set, and in the state folder's `legacy/reports/`.

`macos-cleanup quarantine list` shows a manifest state for each run: `ok`, `legacy` (copied from 3.x) or `missing`. Purging a run removes its manifest too.

## Category keys in `--json` output

Some category keys changed. If a script reads the `categories` array of `--json` output, update it.

| 3.x key | 4.x id | Note |
|---------|----------|------|
| `time-machine` | `tm-snapshots` | Renamed. The section `time-machine` still exists for `--category` |
| `app-caches` | `app-caches` and `app-caches-review` | Split: the allowlisted half keeps `app-caches` (regenerable), the other half is the new `app-caches-review` (review) |
| `brew` and `brew-stale` | `brew` | Merged. One `brew cleanup --prune=all` removes both, so the estimate is the larger of the two, not the sum |
| `mail-total` | (none) | Dropped. `mail-data` and `mail-downloads` remain |
| everything else | same id | |

The summary also has `schema_version` `2.0`. The 3.x keys `counters.*` and `user_decisions[]` are still present in 4.x for scripts.

## Environment variables

| Variable | 4.x behaviour |
|----------|-----------------|
| `AUTO_YES` | Ignored, with one warning naming the flag to use (`--yes`) |
| `REMOVE_MODE` | Ignored, with one warning. Use `--quarantine` or `--permanent`, or `MACOS_CLEANUP_REMOVE_MODE` in `settings.conf` |
| `NON_INTERACTIVE` | Still honoured, with a deprecation note. It can only make a run less interactive |
| `LANG_CODE`, `QUARANTINE_ROOT`, `ARTIFACT_RETENTION_DAYS`, `HOME_TOP_DIRS_TIMEOUT`, `RULES_FILE` | Still read in 4.x. Prefer the `MACOS_CLEANUP_` names |
| `LOGS_DIR`, `REPORTS_DIR` | Still read in 4.x, deprecated, logged when used |

Consent now comes only from flags and `settings.conf`, never from a stray environment variable. If a script of yours relied on `AUTO_YES=1`, pass `--yes` with `--non-interactive`. Precedence is: flag, `MACOS_CLEANUP_*` variable, old-style variable, `settings.conf`, default.

A `MACOS_CLEANUP_*` path variable that is not absolute is an error (exit 2). `QUARANTINE_RUN_DIR`, if you set it, must be an immediate child of the quarantine folder.

## Plans from 3.x are refused

4.x signs the plans it writes and checks the signature, the Mac, the user and the age before `apply --from-plan` does anything. A plan written by 3.x has no signature and is refused with a one-line explanation (exit 2). Write a new one:

```bash
macos-cleanup plan
```

## Other behaviour you may notice

- `--include` is an alias of `--category`. The 3.x help text described it differently and was wrong.
- The report's "re-run" hints now show commands that work (`apply --from-plan FILE`).
- `--redact` now applies to the report, summary, journal and log, and leaves out your user and host name.
- A 3.x run and a 4.x run exclude each other while either is changing files.
- Category outcomes are computed from what happened to each item. A category where every move failed is reported as failed, not cleaned.
- `--restore` accepts a run id, `latest` or a file. You no longer need to be in the program folder.
