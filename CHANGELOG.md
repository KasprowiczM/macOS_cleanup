# Changelog

All notable changes to `macOS_cleanup` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.3] — 2026-08-19

Post-migration review release. The test suite was already reporting three
failures at HEAD; nobody had run it. All three were the same bug class, and the
one it produced was severe: **interactive cleanup silently stopped doing
anything after the second category.**

### Fixed

- **P0 — interactive/auto-safe cleanup aborted mid-run.** `cleanup_all.sh` runs
  with `set -euo pipefail`, and bash 3.2 treats `"${empty_array[@]}"` as an
  *unbound variable error*, not as an empty expansion. `clean_logs()` guarded
  only the **sum** of `FOUND_APP_LOGS` and `FOUND_SYSTEM_LOGS`, then expanded
  both. On any machine with user logs but no old system logs — the common case —
  the run died at `lib/cleaner.sh:239` with
  `FOUND_SYSTEM_LOGS[@]: unbound variable` *after* Trash and user caches had
  already been quarantined, and every later category (dev artifacts, app
  leftovers, Time Machine, large files) was silently never offered. The user
  answered "yes" and nothing happened, with no error surfaced in the report.
  `clean_xcode_simulators()` and `clean_docker()` had the identical defect on
  `FOUND_DEV_ITEMS` and aborted even with *every* array empty.
- **`rotate_old_artifacts()` was dead code.** The function existed and had a
  passing unit test, but no production caller. `logs/` had grown to 1183 files
  and `reports/` to 1574, accumulating since March — a disk-cleanup tool
  leaking 13 MB of its own artifacts. Now wired into `cli_init()`; the first
  run pruned 2312 stale files.
- **Time Machine snapshot count rendered as a byte size.** The `time-machine`
  ledger entry holds a snapshot *count* (an APFS local snapshot has no
  attributable size). `cleanup_all.sh` already special-cased this in the
  terminal summary; `lib/reporter.sh` did not, so the markdown report printed
  12 local snapshots as **"12 B"**.
- **`analyze_application_inventory()`** expanded `FOUND_INSTALLED_APPS` behind a
  `count > 0` guard that only implied non-emptiness. Made explicit.

### Added

- **`tests/test_empty_array_guards.sh`** — behavioural sweep that calls every
  `clean_*` entry point with all `FOUND_*` arrays empty, then again with each
  array holding exactly one element, and fails on any unbound-variable abort.
  Deliberately behavioural rather than a grep: the guard idiom varies across
  the file and a static scan cannot tell an effective guard from a decorative
  one. Verified against a negative control — reverting `lib/cleaner.sh` to HEAD
  makes it fail on all three sites.
- **`ARTIFACT_RETENTION_DAYS`** (default 30, `0` disables) and two tests
  asserting rotation is both wired up and disableable.

### Verified

- `tests/run_all.sh` — 462 assertions, 0 failures (was 459 with 3 failures)
- `python3 -m unittest tests/test_dev_sync_safety.py` — 8 tests, OK
- `shellcheck -S error` across `lib/`, `cleanup_all.sh`, `config/`, `tests/` — clean
- `bash cleanup_all.sh --dry-run` — exit 0


## [3.0.2] — 2026-08-07

### Added
- **[R-1 / BUG-1 / Gate G18] Unit Separator (0x1F) TSV Delimiter & Plan Round-Trip Preservation.** Resolved field shift corruption in `apply --from-plan` for `native_command` operations (e.g. `npm cache clean --force`). Added Gate G18 verifying end-to-end plan execution and round-trip preservation.
- **[R-2 / BUG-6 / Gate G13] Pre-Pass App Cache Claiming & Accounting Deduplication.** Implemented `_claim_known_specific_caches()` to claim specific application caches (Homebrew, pip, CocoaPods, SwiftPM, composer, Figma, JetBrains, Adobe, Spotify, Zoom, Xcode, Safari, Chrome, etc.) before `analyze_user_caches()` runs, eliminating double-counting.
- **[R-3 / BUG-9] Portable `app_bundle_exists` Helper.** Added `get_plist_bundle_id()` supporting `defaults read` on macOS with Python 3 `plistlib` / XML `grep` fallback.
- **[C-1] Verification Suite Performance Options & Gate G19.** Optimized `verify_release.sh` with `--quick` (~10s), `--summary` (1 suite run with quiet stdout), and `--full` (all 19 gates including G12 determinism). Added Gate G19 for protected path docs sync.
- **[C-2] APFS Purgeable Space Reporting.** Updated `diskutil info` query to target `/System/Volumes/Data` volume on modern macOS. Added `Purgeable (APFS)` and `Free now` to final summary output with explanation of Time Machine snapshot expiration.
- **[C-3] i18n Dictionary Auditing.** Added localized `in_items`, `items_count`, and `tm_snapshots_count` keys across all 7 language dictionaries (`en`, `pl`, `de`, `es`, `fr`, `it`, `pt`). Re-verified zero schema diffs or missing keys.
- **[C-4] Linux `stat` Portability.** Added `file_mtime_seconds()` helper supporting BSD `stat -f %m` and GNU `stat -c %Y` with Python 3 fallback, eliminating test failures on Linux.
- **[C-5] Restore Run ID Disambiguation.** Added run ID logging and hint listing remaining quarantine runs when using `--restore latest`.
- **[C-6] Installer Tag Pinning & Checksum Check.** Pinned `install.sh` default target to `v3.0.2` release tag with `SHA256SUMS` verification and `--edge` flag for tracking `main`. `tools/gen_protected_docs.sh` now auto-injects `NEVER_TOUCH_PATHS` into all 7 READMEs.
- **[C-7] Comprehensive User Guide.** Created `docs/USER_GUIDE.md` for Mac owners covering prerequisites, 4 core commands with example outputs, risk levels, APFS purgeable space, restore instructions, category details, automation, and troubleshooting.

### Fixed
- Fixed plan field shift corrupting binary parameters during TSV deserialization.
- Fixed double-counting accounting bug between app-specific caches and user disposable roots.
- Fixed untranslated English fragments (`in`, `items`, `count`) in non-English summary outputs.

## [3.0.0] — 2026-08-07

### Changed
- **[P0-1a] BREAKING: System cache cleanup is now report-only.** The interactive path
  no longer executes `sudo rm -rf` on `/Library/Caches` children. System caches are
  reported with sizes but never deleted. Users who need this should use Disk Utility
  or manual `sudo` outside this tool.
- **[P0-1b] BREAKING: All privileged (`sudo`) operations removed.** `request_sudo`,
  `_start_sudo_keepalive`, and the `sudo` branch in `direct_remove` are replaced
  with stubs that unconditionally refuse. No code path in the tool can escalate to
  root privileges.
- **[P0-3] Extended protected-path denylist.** Added ~30 new paths including iCloud
  Drive, `~/Library/CloudStorage`, `~/Dropbox`, `~/OneDrive`, `~/Google Drive`,
  developer source trees (`~/Developer`, `~/Projects`, `~/src`, `~/code`, `~/repos`),
  and credential dotfiles (`~/.config`, `~/.kube`, `~/.docker`, `~/.netrc`,
  `~/.zshrc`, `~/.bashrc`, `~/.npmrc`, etc.).
- **[P1-5] Consent copy accuracy.** Risk labels now match the policy engine (REVIEW
  for caches, not LOW). Consequence text varies by REMOVE_MODE (quarantine vs
  permanent). The false claim "Zawsze bezpieczne" for `~/Library/Caches` is removed.
- **[P1-11] Fail-closed path normalization.** If `normalize_path` returns empty,
  `safe_remove` blocks the operation and journals a `normalization_failed` event.
  Test artifact isolation: `LOGS_DIR` and `REPORTS_DIR` are now env-overridable.
- **[P1-12] Safety violations skip, not abort.** `assert_safe_path` returns 1 (skip)
  instead of `exit 99` (abort). A single rogue path no longer crashes the entire run.
  Violations are journalled with `safety_violation` event type.

### Added
- `tests/test_path_protection.sh`: Table-driven test covering 80+ protected/unprotected
  path assertions including all P0-3 additions, broad roots, system paths, edge cases.
- `tests/fixtures/make_fake_home.sh`: Deterministic fixture home generator for testing.
- `tests/helpers.sh`: `setup_artifact_isolation()` helper function.
- Signal handling: `INT`/`TERM` traps for clean Ctrl-C handling with proper exit 130.

### Fixed
- `--json`: removed a dead per-category byte block in `lib/json_summary.sh` that
  was assembled into `cat_fragment` but never emitted — and would have produced
  invalid JSON (unquoted keys) if it ever had been wired in.
- Test hermeticity: `tests/test_planner.sh` now sources `lib/json_summary.sh`
  the same way `cleanup_all.sh` does, so the suite no longer prints
  `json_summary_record_plan: command not found` to stderr while still passing.
- `tests/test_cli.sh`: quarantine path assertion now uses `$QUARANTINE_ROOT`
  instead of hardcoded default path.

## [2.1.0]

### Added
- [SF1] Apply-time defense-in-depth risk revalidation before deletion.
- [SF2] Cleaner execution is now isolated; one cleaner's failure doesn't halt the rest.
- [TC1] Shellcheck added to CI.
- [TC2] JSON Schema validation for `plan.json` added to CI.
- [TC3] End-to-end `apply --from-plan` test covers quarantining a SAFE path and
  blocking a non-allowlisted native command.
- [TC4] CI now runs shell tests under macOS system Bash 3.2 and adds a Linux job
  for OS-independent test coverage.
- One-line installer (`install.sh`) + README "quick test" section. The installer
  only clones/updates the repo and prints next steps — it never deletes anything
  and never runs a cleanup.
- `LICENSE` (MIT) matching the license already declared in `README.md`.
- `.editorconfig` for consistent formatting (bash 4-space, LF, final newline).
- This `CHANGELOG.md`.

### Changed
- [PF1] Replaced double-`du` loops in analyzer with single-pass accumulations.
- [PF2] Skipped home directory enumeration when running in single-category mode.
- [PF3] Precompute `NEVER_TOUCH` paths and probe `realpath -m` once at source-time to save subprocess overhead.
- [PF4] App bundle checks now prefer Spotlight lookup and use a cached Python
  plist scan fallback instead of repeated `defaults read` subprocesses.
- Single-category dry-runs skip heavyweight full-scan inventories while still
  running disk overview and the requested category.
- Optional Brew/Mac App Store inventory commands are bounded so a slow provider
  cannot stall a dry-run indefinitely.

### Fixed
- [CN1] Correctly extract Homebrew stale-size from `--dry-run` output.
- [CN2] Robust parsing of Docker `system df` output regardless of column order.
- [CN3] Distinguish "tool missing" from "command failed" for native tools.
- Replaced the placeholder bug-report URL (`github.com/your/repo`) printed on a
  safety violation in `cleanup_all.sh` and the clone URL in `README.md` with the
  real repository URL.
- Quoted the `unset "out[$top]"` array element in `lib/common.sh::normalize_path`
  (shellcheck SC2184) to avoid accidental glob expansion.
- Fixed Time Machine snapshot deletion silently failing by capturing and printing `tmutil deletelocalsnapshots` output, and clarified that TM snapshots are permanently deleted, not quarantined.
- Fixed automated test sandboxes (`.test_safety_regressions.*`, `.test_quarantine_restore.*`) being left in the project directory instead of `/tmp`.

## [2.0.0]

### Added
- Three-phase **analyze → plan → apply** workflow with a machine-readable
  `reports/plan_<run_id>.json` validated by `schemas/plan.schema.json`.
- `SAFE` / `REVIEW` / `DANGEROUS` risk model layered over the YAML
  `safe` / `ask` / `never` values.
- Quarantine-by-default (`REMOVE_MODE=quarantine`): user-scope deletions are
  moved to `~/Library/Application Support/macOS_cleanup/quarantine/<run_id>` with
  a `reports/restore_<run_id>.tsv` manifest and `--restore` / `--list-quarantine`
  / `--purge-quarantine` commands.
- JSONL audit journal (`reports/journal_<run_id>.jsonl`) recording planned and
  executed operations, including non-rollbackable `native_command` events.
- Time Machine freshness gate before any real apply (`--allow-no-backup` to
  override, recorded in the journal).
- 28-category analyzer (Trash, user/app/system caches, logs, diagnostic reports,
  tmp, app leftovers, Xcode DerivedData/Archives/DeviceSupport/simulators, npm,
  yarn, pnpm, pip, Homebrew, Gradle, Maven, CocoaPods, Cargo, Swift PM, gems,
  Bundler, Composer, Android AVD, Docker, Time Machine snapshots, iOS backups,
  old installers) plus report-only Mail and browser analysis.
- Bash test suite (`tests/run_all.sh`) and a Python dev-sync safety suite, gated
  by `.github/workflows/ci.yml` on `macos-latest`.

### Security
- `safe_remove()` is the only deletion path; it fails closed (exit 99) on
  protected paths and on parents of protected paths.
- Hard `NEVER_TOUCH` list covering Mail, Keychains, password managers, browser
  profiles, SSH/GPG keys, `~/Documents`, `~/Desktop`, and media libraries,
  merged with `never` paths from `cleanup_rules.yaml`.
- `--yes` in non-interactive mode never auto-approves MEDIUM/HIGH-risk,
  Time Machine, or iOS-backup prompts.
