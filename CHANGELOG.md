# Changelog

All notable changes to `macOS_cleanup` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Safety fixes for the confirmed data-loss findings of the 2026-10-27 ultra-review (P0-1, P0-2, P0-3), plus P1-1 to P1-7.

### Fixed

- **P0-1: an explicit `--dry-run` is authoritative.** Flag order no longer matters. `--dry-run` combined with `--interactive` or `--auto-safe` runs analysis only. With `apply --from-plan` it previews. With `--purge-quarantine … --apply` it previews the purge. With `--restore` or `--prune-artifacts` it is refused with exit 2, since those modes have no preview. Before this fix, `--dry-run --purge-quarantine all --apply` deleted permanently. A new `is_dry_run` check also stops `safe_remove`, `direct_remove`, artifact pruning, restore, purge, and cleaner/planner native commands.
- **P0-2: the protected-path guard is case-insensitive.** On case-insensitive APFS, `~/Library/mail`, `~/documents`, or `~/.SSH` no longer pass as unprotected. Repeated slashes collapse correctly on bash 3.2. A path that cannot be normalized (`/`, `//`, `/.`) counts as protected. `normalize_path` no longer returns success with an empty path.
- **P0-3: runtime config fails closed.** `REMOVE_MODE` must be exactly `quarantine` or `permanent`; before, a typo meant permanent deletion. `QUARANTINE_ROOT` must be an absolute `…/quarantine` path with no `.` or `..` segments; before, `QUARANTINE_ROOT=$HOME` plus a purge removed every directory under HOME. Both values are checked at startup (exit 2), and again inside `safe_remove` and `purge_quarantine`.
- **P0-2 (remainder): policy rule lookup sees case variants.** A hand-edited plan with `$HOME/.NPM` no longer skips the REVIEW escalation for the `~/.npm` `ask` rule. Matching is asymmetric: a case-insensitive match can only raise risk, and a SAFE rule lowers a REVIEW default only on an exact-case match.
- **P1-6: unset `USER` no longer fails open.** Under launchd, cron or `env -i`, `set -u` made path expansion abort, and callers fell back to raw paths (a `~/.npm` policy rule was stored unexpanded and never matched). `$USER` tokens now fall back to `id -un`, and expansion fails when neither source resolves.
- **P1-1: the headline total is the plan's executable sum.** `would_free_bytes` used to add up the category ledgers. That counted Homebrew twice (cache plus `brew-stale`, which one `brew cleanup --prune=all` removes together). It also counted `/tmp` and `/Library/Logs` work that the default quarantine mode always skips. Now the dry-run total sums only `remove_path` and `native_command` operations with SAFE or REVIEW risk that the current mode will run. In quarantine mode that means user-space paths only. Report-only items stay out of the plan's `safe`/`review`/`dangerous` buckets: they get their own `report_only_operations` and `report_only_bytes`, and they feed `informational_bytes`, which was always 0 before. The plan and the `--json` summary gain `executable_bytes`: SAFE and REVIEW work this mode can run, where REVIEW still needs confirmation at apply. An invalid `REMOVE_MODE` counts nothing, matching `safe_remove`. The Homebrew operation uses the larger of the two estimates, never the sum. The terminal summary and the Markdown report show the report-only total on its own line. Report-only DANGEROUS items (Mail, browser data) are now listed under report-only in the decision list, not under DANGEROUS operations.
- **P1-2: the quarantine mode says what it does.** It moves files and frees nothing until `--purge-quarantine`, but the totals called that space "freeable". In quarantine mode the terminal total, the interactive prompts and the Markdown report now say "to process (quarantined files free space only after --purge-quarantine)"; the total also covers native commands, which are never quarantined. The SAFE, REVIEW and DANGEROUS consent texts mention purge in all 7 languages. The quarantine mode only moves paths under HOME, yet `clean_tmp`, `clean_logs` and `clean_diagnostic_reports` asked for consent for `/tmp`, `/Library/Logs` and system DiagnosticReports, and then recorded the category as cleaned while every item was skipped. These paths no longer reach the prompt or `safe_remove` in quarantine mode, the category is recorded as `needs-permanent` (or `partial` when only its items under HOME were processed), and the report says so. `--permanent` is unchanged.
- **P1-4: native commands are bound to their target.** One tool→target table (`native_tool_target`: `npm config get cache`, `yarn cache dir`, `pnpm store path`, `pip cache dir`, `brew --cache`, `gem env gemdir`, CoreSimulator/Devices) now serves the analyzer, the planner and plan apply. Plans carry the resolved absolute target instead of the `__brew__` sentinel, which apply used to resolve against the current directory. Apply re-resolves the target and refuses the op when the plan names another directory. Before, `npm cache clean --force` was accepted with `~/Library/Messages` as its path. It is also refused when a config change moved the cache after planning. The target of a cache-emptying tool (npm, yarn, pnpm, pip, brew) must also be that tool's own folder under HOME (`~/.npm`, `~/.yarn`, the pnpm store, a child of `~/Library/Caches` or `~/.cache`) and pass `validate_cache_path`. A redirect such as `NPM_CONFIG_CACHE=~/Dev_Env/project` is reported, never cleaned. A plan dry-run now previews only ops that a real apply would run. `xcrun simctl delete unavailable` is allowlisted for apply, so one simulator op no longer rejects the whole plan. Docker has no host target, so a plan reports it and `--interactive` runs it. `gem cleanup` and `brew cleanup --prune=all` remove old installed versions and are now REVIEW. pip's cache is asked from pip (`PIP_CACHE_DIR`, pip.conf) instead of being assumed.
- **P1-5 (CN2): Docker reclaimable size reads the right column.** `docker system df` is parsed via `--format '{{.Type}}|{{.Reclaimable}}'`. The whitespace split shifted the two-word "Build Cache" row and read its SIZE as RECLAIMABLE. Docker's decimal units are no longer converted with 1024.
- **P1-7: one lock for every mutating mode; atomic plan files.** The apply lock covered only apply, restore and purge, so an interactive or auto-safe run could fill a quarantine run while `--purge-quarantine latest` deleted it. Interactive and auto-safe now take the same lock. A lock left by a crashed run blocked every later apply forever. A lock is now recovered when its recorded holder is no longer running (`ps -p`, which also sees other users' processes; without a working `ps` every holder is presumed alive), or when it has no pid and is older than 10 minutes. Recovery runs under its own mkdir mutex, so two recoverers cannot remove a freshly re-taken lock. `acquire` fails if it cannot record its pid, and `release` removes the lock only while it still records this process. `generate_plan_json` writes and stamps a temp file and renames it into place, so a failed stamp keeps the previous plan; a directory given as the plan file is refused, and an aborted write's temp file is removed on exit. `apply --from-plan` verifies and parses one private snapshot instead of reading the file twice.
- **Phase 3: local Time Machine snapshots keep the newest and wait for backups.** `clean_time_machine_snapshots` deleted every `com.apple.TimeMachine.*` snapshot, including the newest. The newest is the rollback point, for example before an update. It also never asked whether a backup was running. The newest snapshot is now always kept, and the prompt and the dry-run list only the older ones. Nothing is deleted unless `tmutil status` positively reports `Running = 0`; an unreadable status counts as running. The status is checked again after the confirmation prompt. A repeated date is deleted once. The report says "Time Machine was backing up" or "only the newest exists; kept" instead of "Skipped by you".
- **Phase 3: unreadable is not empty.** macOS can silently deny access to other apps' folders. `path_size_bytes` used to discard du's partial result and report 0 bytes for any location it could not read completely. It now keeps the readable part as a lower bound and records the location in a run-scoped file (`logs/unreadable_<run>.txt`). `--json` gains `analysis_status` (`complete`/`partial`) and `counters.unreadable_paths`. The terminal summary and the Markdown report say how many locations were not fully readable. Such a location is never deleted in `--permanent` mode, because `rm -rf` would remove the readable part and stop at the rest. Quarantine (a same-volume rename) still moves it. The lists are rotated with the logs. `~/.aws/sso` (SSO token cache) is now NEVER_TOUCH.
- **Phase 3: caches in use are not removed.** Several file-based caches were removed even while a build was using them: Gradle, Cargo, CocoaPods, SwiftPM, Bundler and Composer, the npx cache, the pnpm stale store and Xcode DerivedData. Removing a cache mid-build breaks that build. `cache_owner_running` now checks with `pgrep`, using command lines as macOS shows them. npm renames itself "npm exec …", so live npx users (such as MCP servers) are found by their `~/.npm/_npx/` path. Other checks cover the Gradle daemon, `cargo`/`rustc`, Xcode/`xcodebuild`, and pnpm and composer running as scripts. A matching cache is skipped and reported as "in use". `apply --from-plan` runs the same check through a shared path→owner map. When `pgrep` cannot tell, the cache counts as in use.
- **P2: no environment escape hatch in the cache-root allowlist.** `_is_within_allowed_cache_root` used to accept any path under `$SANDBOX`, an environment variable production code should not trust: `SANDBOX=/` made every path an allowed cache root. It also accepted any path whose name merely started with the quarantine root (`…/quarantine-evil`). The `$SANDBOX` hatch is gone, and the quarantine root is matched as a directory.
- **P2: one version everywhere.** The README footers said 2.1.0 and the `cleanup_all.sh` header said 3.0.0, while `SCRIPT_VERSION` is 3.0.6. The planner's fallback is now `unknown` instead of a stale number. `tests/test_release_consistency.sh` checks that every footer and the header carry `SCRIPT_VERSION`.
- **Phase 3: deleting a snapshot date keeps every disk's newest snapshot.** `tmutil deletelocalsnapshots <date>` deletes that date on every mounted disk, not only on the startup disk. An external APFS disk whose newest local snapshot had the same date as an older startup-disk snapshot lost it. Before deleting, the cleaner now lists the local snapshots of every other writable APFS volume, wherever it is mounted, and keeps any date that is a volume's newest. Read-only mounts such as simulator runtimes and disk images are skipped, since `tmutil` cannot delete their snapshots. If the mount table cannot be read or parsed, or a volume's list cannot be read, nothing is deleted and the report says "Another mounted disk's snapshots could not be listed". Non-APFS volumes are not asked.
- **P2: logs are not planned twice.** `analyze_logs` listed files that the app-cache analyzer had already claimed, such as `~/Library/Logs/JetBrains`. It also listed `DiagnosticReports` files, which have their own analyzer. The plan counted them twice, and apply tried to remove them twice.

### Performance

- **Bounded home-folder walk.** The informational `du -sh ~/*/` list took ~102 s of a ~322 s full scan. It now measures one directory at a time under a shared deadline (`HOME_TOP_DIRS_TIMEOUT`, default 20 s). Each directory gets at most a quarter of that budget, and a directory that runs over is listed as not measured. It stays on the home volume (`-x`). It skips iCloud Drive (`Mobile Documents`) and `CloudStorage`, whose dataless files must not be enumerated. When the list is cut short, the scan says so.
- **Faster app-leftover scan.** `app_bundle_exists` answers from the one-time bundle-id index first and asks Spotlight only on a miss. It no longer runs a `defaults read` per installed app for every orphan candidate. The protected-path check now runs before the bundle lookup. `~/Library/Containers` and `~/Library/Group Containers` are no longer walked: every child was already protected, and walking them can raise macOS "access data from other apps" prompts.

- **Sizes are measured once per run.** The analyzers measured each candidate with `du`, then the planner, the report-only list and the interactive prompts measured the same paths again. Each measurement is now recorded in a run-scoped file (`logs/size_memo_<run>.tsv`, removed when the run exits), and plan estimates and prompt sizes reuse it. `safe_remove`, the journal and the native-command before/after accounting still measure live. A full dry-run on the reference Mac dropped from 165 s to 121 s with the same 332 plan operations. The unused in-memory `get_path_size_cached` is gone: its cache never survived the `$(...)` subshells it was called from.

### Security

- **P1-3: dev-sync rclone import applies the hard-exclude list.** The remote listing is untrusted. A forged remote could previously deliver `.git/hooks/*` (code execution on the next Git command), `.git/config`, `.ssh/`, `secrets/`, `*.pem` and dependency folders. The listing now passes through the same candidate filter as the local provider. Hard excludes and the tracked-file guard ignore case, so `.GIT/hooks` and `readme.MD` (which overwrote `README.md` on APFS) are rejected. The tracked-file guard also ignores Unicode normalization: an NFD `Café.txt` no longer overwrites a tracked NFC `Café.txt`. A bare `.git` gitfile is hard-excluded. The rclone import refuses to write through a symlinked destination ancestor, matching the local provider. It passes names with `--files-from-raw` and rejects names with leading or trailing whitespace or control characters; `--files-from` stripped whitespace, so an approved " README.md" copied over the tracked `README.md`. Export and prune use the same deny list, so case variants such as `id.PEM` are no longer exported and are pruned from the provider mirror.

- **P3-4: the installer verifies every runtime script, rule file and schema, and a missing SHA256SUMS aborts.** SHA256SUMS listed only `cleanup_all.sh`, `lib/`, `config/`, `tools/` and `i18n/`. `install.sh`, `cleanup_rules.yaml`, the `dev-sync-*.sh` wrappers, the `dev-sync/` scripts and Python modules, and `schemas/plan.schema.json` were installed unchecked. They are now listed, and `tests/test_release_consistency.sh` fails when a shipped file is missing from the list. A checkout without SHA256SUMS used to install silently; it now aborts. On a mismatch the installer names each failing file, and `--strict` rejects malformed lines. Tests, docs and CI files are not listed. The checksums are checked inside the checkout, so they catch a damaged or partial download, not a forged repository.

### Changed

- **P2: exit codes no longer hide failures.** `--restore` exited 0 even when no row could be restored. It now writes its report and exits 1 if any entry was blocked, conflicted or failed. `--purge-quarantine` returned its failure count, so two failed runs looked like exit 2 ("bad argument"); it now returns 1 for any failure. A failing apply, restore or purge still writes its report, the terminal summary and the `--json` object before it exits. Re-running an already completed restore no longer counts as incomplete.
- **Apply enforces REVIEW for `brew cleanup --prune=all`, `gem cleanup` and `xcrun simctl delete unavailable`,** even when a hand-edited plan labels them SAFE. In `--permanent` mode, `safe_remove` checks directly whether a tree is fully readable, so the skip no longer depends on the unreadable list having been written. An unmeasurable size no longer aborts a run under errexit. Plans written before these changes carry `__brew__` or `_cacache` paths: apply refuses those native ops (target mismatch), so regenerate old plans. Refused native ops count as apply failures; refused or in-use `remove_path` ops are skipped.
- **P2: the exit-code table matches the code.** `docs/agents/security.md` listed a security-violation exit 99 that is never emitted, and it omitted 3 (unsupported macOS) and 130 (interrupted).
- **P3-4a: the installer tests reach the checks they claim to test.** `install.sh` reads origin with `git remote get-url`, which applies `insteadOf` rewrites. The tests used an `insteadOf` redirect to fetch locally, so origin looked unofficial and every case was refused at the origin check: the dirty-tree and checksum-mismatch tests passed without reaching their checks. A test-only git shim now redirects the fetch, each refusal asserts its own reason, and a verified clean checkout must install.
- **P3: the keep-alive test checks the property, not bash's job notices.** Its control case killed a raw background job and expected bash to print "Terminated". Whether bash prints that depends on the environment, so the suite failed on some hosts. Since P0-1b `_start_sudo_keepalive` starts nothing; the test now asserts that it leaves no child process, tracked or disowned. Against the old disowned keep-alive loop it fails.
- **P2: historical prompts and reviews moved to `docs/history/`.** 22 dated prompts, reviews, release notes and progress logs left the repository root. `docs/history/README.md` says they are kept for reference only.

### Added

- **Phase 3: unusable simulator runtimes are found and can be removed safely.** Runtimes live in a system-managed store, so only `xcrun simctl runtime delete --unusable` may remove them; the cleaner never uses `rm`. The analyzer asks simctl's own dry-run which runtimes it would delete and sizes exactly those from `xcrun simctl runtime list -j`. simctl prints that report on stderr and exits 2 when nothing matches, so both streams are read and only runtime UUIDs count. If the size cannot be read, the runtimes are still listed, as size unknown. Without developer tools (`xcode-select -p` fails) xcrun is not run, because its shim can open the install-tools dialog during a read-only scan. A plan reports them as REVIEW, report-only, and apply never runs the command. Only `--interactive` deletes them, after consent, and never while Xcode, Simulator or xcodebuild runs (outcome "in-use"); the check is repeated after the prompt. The reference Mac has no runtimes, so this was verified with stubbed `xcrun` and `pgrep` (`tests/test_sim_runtimes.sh`) and against the real `xcrun`, which reports none. dSYM export was considered and dropped: Xcode Archives are report-only, so their dSYMs are never removed. Docker prune was rechecked: it runs only from the interactive phase, after consent; `--auto-safe` and plan apply never reach it.
- NEVER_TOUCH now covers `~/Library/Messages`, `~/Library/Calendars`, and `~/Library/Application Support/AddressBook`.
- Regression tests: `tests/test_path_protection_case.sh`, `tests/test_dryrun_authoritative.sh`, `tests/test_runtime_config_validation.sh`, `tests/test_policy_case.sh`, `tests/test_user_unset.sh`, `tests/test_plan_accounting.sh`, `tests/test_quarantine_honesty.sh`, `tests/test_native_target_binding.sh`, `tests/test_lock_atomic.sh`, `tests/test_scan_performance.sh`, `tests/test_tm_snapshots.sh`, `tests/test_privacy_status.sh`, `tests/test_busy_check.sh`, `tests/test_pathguard_anchor.sh`, `tests/test_logs_claims.sh`, `tests/test_exit_codes.sh`, and `DevSyncRcloneImportFilterTests` in `tests/test_dev_sync_safety.py`.

## [3.0.6] — 2026-09-07

Safety release for the 2026-09-06 ultra-review (H1–H10 and MEDIUM). Analyze, list, plan, and dry-run stay non-destructive; apply and restore fail closed; installer and protected-path docs match the tree.

### Added

- **`--prune-artifacts`.** The only operator path that deletes aged run logs and journals. Analyze, list, plan, and dry-run no longer prune those artifacts.
- Plan schema coverage (`tests/test_plan_schema.sh`) and an apply/restore/purge `mkdir` lock (`tests/test_apply_lock.sh`).
- Release consistency checks: `SCRIPT_VERSION` vs installer `RELEASE_TAG`, `shasum -a 256 -c SHA256SUMS`, and protected-path docs under an isolated `HOME`.

### Changed

- `SCRIPT_VERSION` is `3.0.6`; `install.sh` `RELEASE_TAG` is `v3.0.6`.
- Generated NEVER_TOUCH docs rewrite an expanded `$HOME` prefix to `~` so `--check` does not depend on the builder home. Absolute `/Library` and `/System` paths stay as-is.
- Package-manager confirm copy states that native commands are irreversible and not quarantined.
- `npx_cache` and `pnpm_stale_store` are `remove_path` (quarantineable), not native commands.
- Brew reclaimable bytes prefer `catbytes brew`, then `brew-stale`.
- `system-caches`, `app-leftovers`, `maven`, `android-avd`, and `xcode-archives` are report-only.
- CI and G01 run `bash -n` per file. `tests/run_all.sh` keeps the Python unittest exit status.

### Fixed

- `--json` `plan.operations` matches the written plan file.
- `print_warn` appends to `WARNINGS_LIST`.
- Chrome and Brave cache roots are not listed in `FOUND_USER_CACHES`.
- Analyzer failure sets `ANALYSIS_PARTIAL`. `du` failure warns and returns 1.

### Security

- **H2/H9:** Native plan operations carry a real path, `rollback:false`, and tool. Apply validates the whole JSON first, checks SHA256 of the canonical operations (empty checksum rejected), and returns non-zero on native failure. NEVER_TOUCH and `--exclude` are re-checked on apply for native targets.
- **H3:** Quarantine probes metadata durability before `mv`. Post-move journal or restore TSV failure rolls back the move and drops the restore TSV row. Counters increment only after durable metadata. `safe_remove` does not abort the shell on that failure.
- **H4–H7:** Dev-sync copies via temp + `os.replace`. Overlay directories that contain tracked files are rejected. rclone uses `--files-from`. `verify-full` fails on missing local or provider files. Prune moves the symlink leaf, not the target. `write_json` refuses a symlink destination.
- **H8:** The installer refuses a dirty checkout and a SHA256 mismatch (exit 1). It never runs `git reset --hard`.
- **H10:** `SCRIPT_VERSION`, `RELEASE_TAG`, `SHA256SUMS`, and portable `~` protected-path docs stay in lockstep.

## [3.0.5] — 2026-09-01

Full review on macOS 26.6.2 (Tahoe, Apple Silicon), triggered by the last run
log `reports/report_2026-08-19_203444_73749.md`. The whole 474-assertion suite
was green and every one of the defects below was live, because every existing
test called functions directly and never compared what the analyzer *writes*
against what the reporter and cleaners *read*.

Measured on this machine before the fix: the terminal summary listed **13.05 GB
across 12 categories** and the markdown report itemised **6 of them**.

### Fixed

- **The markdown report silently omitted most categories.** `lib/reporter.sh`
  kept its own hand-maintained label list — 21 entries against 37 live ledger
  keys — so `app-caches` (1.04 GB on this machine), `cargo` (183 MB), `brew`
  (41 MB), `pip`, `swift-pm`, `xcode-derived`, every log category and every
  remaining package-manager cache were sized, added to the headline total, and
  then printed nowhere. Four of the labels it *did* carry (`logs`, `dev`,
  `derived-data`, `xcode-device-support`) named keys nothing ever sets, so they
  could never render at all. Replaced with `CATEGORY_REGISTRY` in
  `lib/common.sh`: one `key|label|class` table that the terminal summary, the
  grand total and the markdown report all read from. Report-only categories
  (browser profiles, Apple Mail) now sit in their own table, explicitly marked as
  excluded from the total, so the rows reconcile with the figure under them.
- **`clean_ios_device_support` deleted nothing.** `analyze_ios_device_support`
  records `"${ds_type}:${version_dir}"`, and the cleaner passed that whole string
  to `safe_remove`. The path never existed, `safe_remove` returned 0, and the
  category was still marked cleaned — so a user could confirm removing tens of
  GB of Xcode debug symbols, see a success line, and lose nothing but the
  illusion. The cleaner now resolves the path out of the entry.
- **`clean_xcode_simulators` was unreachable.** Its guard matched the literal
  `simulators:__unavailable__`; the analyzer emits `ios_simulators:<path>`.
  Unavailable simulators were sized, totalled and reported, and never once
  offered for deletion. Both spellings are now accepted.
- **pnpm's store was rejected on every single run.** `_is_within_allowed_cache_root`
  knew only the legacy `~/.pnpm-store`, while pnpm >= 8 on macOS stores under
  `~/Library/pnpm/store`. Every run logged `path_provenance_rejected` and 4.1 GB
  stayed permanently unreachable. Added `~/Library/pnpm` and the XDG
  `~/.local/share/pnpm` roots.
- **Two cleaners read ledger keys nothing sets.** `clean_logs` read `"logs"`
  (the analyzer writes `user-logs` and `system-logs`) and
  `clean_ios_device_support` read `"xcode-device-support"` (the analyzer writes
  `device-support`). `catbytes_get` returns 0 for an unknown key, so both
  prompts advertised **0 B** regardless of how much was queued.
- **Three caches were measured but had no way to be cleaned.** `swift_pm_cache`,
  `bundler_cache` and `composer_cache` were sized by the analyzer and counted in
  the freeable total, but were absent from the cleanable set in
  `clean_dev_caches` — they could only ever be advertised.
- **Declining the SAFE app-cache group cancelled the REVIEW group.** A `no` to a
  handful of allowlisted caches did `return 0` out of the whole function, so the
  larger, more interesting half of `~/Library/Caches` was never offered.
- **The first recorded outcome won, not the last.** `category_outcome` returned
  the first match while `mark_category_outcome` appends, so a category recorded
  twice in one run (app caches ask twice) reported the earlier answer. Last write
  wins now.

### Added

- **`pnpm-stale` category.** `pnpm store prune` only ever touches the *current*
  store version directory, so every major pnpm upgrade orphans the previous one
  for good. This machine held `v3` (436 MB) and `v10` (3.6 GB) beside a 41 MB
  `v11` — 4.0 GB no vendor command will ever reclaim. Same shape as `~/.npm/_npx`
  in 3.0.4, and handled the same way: surfaced as its own category and routed
  through `safe_remove` (quarantine, reversible) rather than a command that
  cannot see it. Files still hard-linked from a live `node_modules` keep their
  blocks until that project goes too — the analyzer says so.
- **`tests/test_report_parity.sh`** (226 assertions) — structural, not
  behavioural-by-proxy: it scans every `catbytes_set` / `catbytes_get` literal in
  `lib/` and asserts each has a registry row, populates every registered category
  and asserts `generate_report` prints a row for each, extracts every
  `FOUND_DEV_ITEMS` prefix the analyzer emits and asserts a cleaner matches it,
  and drives `clean_ios_device_support` end to end against a real sandbox path.
  Negative control: reverting `lib/reporter.sh`, `lib/cleaner.sh` and
  `lib/pathguard.sh` to HEAD produces 30 failures, one per defect above.
- **`tests/test_dev_sync_safety.py` is wired into `tests/run_all.sh`.** It is in
  `AGENTS.md`'s minimum workflow but the runner globs `test_*.sh` only, so it ran
  only when someone remembered to type it.

## [3.0.4] — 2026-08-19

Findings from the **first live `--interactive` run** after 3.0.3
(`logs/cleanup_2026-08-19_201549_98843.log`). The run completed — exit 0, all
categories offered, npm and Homebrew caches actually cleaned — which is what
3.0.3 was for. But it then reported three different, mutually inconsistent
numbers for what it had just done:

| source | figure |
|---|---|
| analyzer | `npm cache: 6.03 GB ← 6.03 GB do zwolnienia!` |
| journal | `native_command npm cache clean --force` · `bytes: 5707751424` |
| report | `Freed space: 0 B` |
| **reality** | **~322 MB** |

### Fixed

- **The journal recorded what was LEFT as if it were what was freed.**
  `_clean_dev_native_or_fallback` measured `path_size_bytes "$path"` *after* the
  command ran and logged it in the `bytes` field. For `npm cache clean --force`
  on `~/.npm` that is 5.3 GB of `_npx` — the part the command never touches.
  Native cleanups now measure before **and** after and record the delta.
- **`Freed space` ignored native commands entirely.** `TOTAL_CLEANED_BYTES` was
  only ever incremented inside `safe_remove()`, so a session whose only action
  was `npm cache clean` + `brew cleanup` reported `0 B` freed. The new
  `record_native_command_freed()` credits the measured delta. Applied to the
  npm/yarn/pnpm helper and to the inline `brew` and `pip` branches.
- **The npm cache was sized by the wrong directory.** `npm config get cache`
  returns `~/.npm`, but `npm cache clean --force` only empties `~/.npm/_cacache`.
  Sizing the whole tree made the tool advertise 6.03 GB of reclaimable space
  where 360 KB was reclaimable. The npm entry is now sized by `_cacache`, and
  `~/.npm/_npx` is surfaced as its own category — so the 5.31 GB is still
  reachable, just honestly labelled and routed through quarantine rather than a
  vendor command that cannot touch it. New `npx` category key, i18n label in all
  7 languages.
- **The report claimed categories were cleaned when the user had declined them.**
  `lib/reporter.sh` derived status from the *run mode*: in interactive mode
  `user-caches` was always printed as `Cleaned/Quarantined | Done`. In the 20:15
  run the user answered no and the log recorded `User skipped cleanup:
  Cache użytkownika` — the report still said Done. Status now comes from a
  recorded per-category outcome (`cleaned` / `skipped`), rendered as
  `Skipped by you | Still on disk — re-run to process` when declined.
- **`test_i18n_accessibility.sh` Gate G11 had a false-positive scanner.** Its
  regex `t\s+["']key["']` matched the trailing `t` of any identifier, so
  `catbytes_set "npx"` was read as a translation key. It only ever passed
  because every previously-scanned key happened to exist. Tightened with a
  non-word-character lookbehind.

### Added

- **`tests/test_run_accounting_truth.sh`** — asserts a native cleanup reports
  the delta it freed (never the leftover, never zero), that the npm entry is
  sized by `_cacache` with `_npx` surfaced separately, that report status comes
  from the recorded outcome rather than the mode, and that every
  `confirm_category` prompt has a matching skipped-outcome marker. Verified
  against a negative control: reverting `lib/` to 3.0.3 fails 10 of its 12
  assertions.

### Verified

- `tests/run_all.sh` — 474 assertions, 0 failures (was 462)
- `shellcheck -S error` across `lib/`, `cleanup_all.sh`, `config/`, `tests/` — clean
- Live `--dry-run`: `npm cache: 360.0 KB` / `npx cache: 5.31 GB` (was a single
  `6.03 GB` line)
- Live sandboxed `--interactive`: approving Trash and declining user caches now
  reports `Cleaned/Quarantined | Done` and `Skipped by you` respectively


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
