# Changelog

All notable changes to `macOS_cleanup` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
