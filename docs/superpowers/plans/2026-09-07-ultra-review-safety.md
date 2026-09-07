# Ultra-Review Safety Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every 2026-09-06 ultra-review finding (H1–H10 and MEDIUM) so analyze/list/preview never delete artifacts, plans cannot apply past current policy, restore metadata cannot silently vanish, and dev-sync cannot destroy tracked or live files.

**Architecture:** Keep analyze → plan → apply. Fail closed before the first mutation. Native commands get a real target, current policy, and `rollback=false`. Quarantine writes intent then data then durable manifest, or rolls back. Dev-sync copies to a temp path, then atomically replaces, using one approved-file list for every transport. Reports and `--json` read the same plan counters the planner just wrote.

**Tech Stack:** Bash 3.2, Python 3, unittest, ShellCheck, GitHub Actions (do not broaden macOS triggers).

**Spec:** User-supplied 2026-09-06 ultra-review at commit `ca7705340a048e06c777767adfce48f44caa2f7c` plus this plan.

## Global Constraints

- Bash 3.2 only: no `declare -A`, `mapfile`/`readarray`, `local -n`, `${var,,}`, `${var^^}`.
- `set -euo pipefail`: every `"${array[@]}"` expansion needs its own `(( ${#ARR[@]} > 0 ))` guard.
- Never treat a vendor command's post-run directory size as space freed; measure the same path before and after.
- `safe_remove()` remains the only generic removal. Native tools and quarantine purge stay the documented exceptions and must record `rollback=false`.
- `--exclude` appends to `NEVER_TOUCH_PATHS`; apply must re-check `is_protected_path` for native targets too.
- Tests must not touch the user's real Home, CloudStorage, or live package-manager caches. Use `mktemp` sandboxes and PATH stubs.
- Do not add, enable, or broaden GitHub Actions schedules or macOS-on-push jobs.
- TDD: write the failing test, run it, then write the minimum production code.
- Do not store secrets. Do not write Agentic OS vault paths into this repo.
- Indentation: 4 spaces. Quote all expansions. `print_warn` must also append to `WARNINGS_LIST` after Task 6.
- Existing tests that encoded the old (unsafe) behavior must be updated in the same task that changes the behavior. Name those tests in the commit body.
- Do not bump `SCRIPT_VERSION` or regenerate `SHA256SUMS` until Task 8.
- Commit after each task on branch `fix/ultra-review-safety-h1-h10`. Do not push.

---

### Task 1: H1 — Read-only modes must not prune artifacts

**Files:**
- Create: `tests/test_readonly_artifact_retention.sh`
- Modify: `cleanup_all.sh` (`preflight_checks` ~464, `parse_args`, `main`)
- Modify: `lib/common.sh` (`rotate_old_artifacts` ~147–173)
- Modify: `tests/test_security_privacy.sh` (the "wired into the run" assertion)
- Modify: `i18n/en.sh` and `i18n/pl.sh` (help strings for `--prune-artifacts`)

**Interfaces:**
- Consumes: `LOGS_DIR`, `REPORTS_DIR`, `ARTIFACT_RETENTION_DAYS`
- Produces: `rotate_old_artifacts` remains the only deleter of run artifacts; `preflight_checks` never calls it; `--prune-artifacts` is the only CLI entry that does.

- [ ] **Step 1: Write the failing CLI test**

Create `tests/test_readonly_artifact_retention.sh`:

```bash
#!/usr/bin/env bash
set -u
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/helpers.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_readonly_artifacts.XXXXXX)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR"
OLD_LOG="${LOGS_DIR}/cleanup_2020-01-01_000000_1.log"
OLD_JOURNAL="${REPORTS_DIR}/journal_2020-01-01_000000_1.jsonl"
echo "KEEP-LOG" > "$OLD_LOG"
echo "KEEP-JOURNAL" > "$OLD_JOURNAL"
touch -t 202001010000 "$OLD_LOG" "$OLD_JOURNAL"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

run_mode() {
    env ARTIFACT_RETENTION_DAYS=1 \
        LOGS_DIR="$LOGS_DIR" REPORTS_DIR="$REPORTS_DIR" HOME="$HOME" \
        /bin/bash "${PROJ_DIR}/cleanup_all.sh" "$@" >/dev/null 2>&1 || true
}

begin_test "--list-quarantine does not delete old logs or journals"
run_mode --list-quarantine --non-interactive --no-color
assert_eq "$(cat "$OLD_LOG")" "KEEP-LOG" "list-quarantine must not prune logs"
assert_eq "$(cat "$OLD_JOURNAL")" "KEEP-JOURNAL" "list-quarantine must not prune journals"

begin_test "--dry-run does not delete old artifacts"
run_mode --dry-run --non-interactive --no-color --category trash
assert_eq "$(cat "$OLD_LOG")" "KEEP-LOG" "dry-run must not prune logs"

begin_test "plan mode does not delete old artifacts"
run_mode plan --non-interactive --no-color --category trash
assert_eq "$(cat "$OLD_JOURNAL")" "KEEP-JOURNAL" "plan must not prune journals"

begin_test "--prune-artifacts is the explicit retention operation"
run_mode --prune-artifacts --non-interactive --no-color
assert_file_absent "$OLD_LOG" "explicit prune may delete aged logs"

print_test_summary
```

Also change `tests/test_security_privacy.sh` "wired into the run" to require `--prune-artifacts` in `cleanup_all.sh` and to forbid `rotate_old_artifacts` inside `preflight_checks`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `/bin/bash tests/test_readonly_artifact_retention.sh`
Expected: FAIL because `--list-quarantine` currently calls `preflight_checks` → `rotate_old_artifacts`.

- [ ] **Step 3: Write minimal implementation**

1. `rotate_old_artifacts`:
   - Return 0 if `max_days` is 0/non-numeric.
   - Require `logs_dir`/`reports_dir` to be existing directories (`[[ -d ]]`), not files.
   - Delete only regular files whose names match `cleanup_*.log`, `report_*.md`, `plan_*.json`, `journal_*.jsonl`.
   - Skip symlinks. Require `path_is_within` the configured dir.
   - Do not use `find -exec rm`. Loop, validate, then `rm -f` on the validated path.
2. Remove the `rotate_old_artifacts` call from `preflight_checks`.
3. Add `--prune-artifacts` in `parse_args` setting `MODE="prune-artifacts"`.
4. In `main`, after preflight, if MODE is `prune-artifacts`, call `rotate_old_artifacts`, print the count, skip analysis, exit 0.
5. Help text in i18n.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/bin/bash tests/test_readonly_artifact_retention.sh && /bin/bash tests/test_security_privacy.sh`

- [ ] **Step 5: Commit**

```bash
git add tests/test_readonly_artifact_retention.sh tests/test_security_privacy.sh cleanup_all.sh lib/common.sh i18n/en.sh i18n/pl.sh
git commit -m "$(cat <<'EOF'
fix: stop pruning run artifacts from analyze and list modes

Retention is now an explicit --prune-artifacts operation so dry-run,
plan, and --list-quarantine cannot delete old logs or journals.
EOF
)"
```

---

### Task 2: H3 — Quarantine metadata is durable or the move rolls back

**Files:**
- Create: `tests/test_restore_metadata_failure.sh`
- Modify: `lib/common.sh` (`cleanup_journal_event` ~941–969, `cleanup_restore_record` ~1057–1071, `quarantine_remove` ~1158–1191)
- Modify: existing `tests/test_quarantine_restore.sh` only if an assertion encoded silent journal failure as success.

**Interfaces:**
- Consumes: `CLEANUP_JOURNAL_FILE`, `CLEANUP_RESTORE_MANIFEST`, `QUARANTINE_RUN_DIR`
- Produces: `quarantine_remove` returns non-zero and does not increment `TOTAL_QUARANTINED_*` unless both the item and its restore row exist. Journal/manifest write failures are no longer `|| true` for quarantine events.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bash
# tests/test_restore_metadata_failure.sh
set -u
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SANDBOX="$(mktemp -d -t macos_cleanup_meta_fail.XXXXXX)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME/Library/Caches/victim"
echo payload > "$HOME/Library/Caches/victim/data.bin"
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
export QUARANTINE_RUN_DIR="${QUARANTINE_ROOT}/run1"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal.jsonl"
mkdir -p "${SANDBOX}/reports"
echo notadir > "${SANDBOX}/reports/restore_run.tsv"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_run.tsv/nested.tsv"
source "${PROJ_DIR}/config/defaults.sh"
source "${PROJ_DIR}/lib/common.sh"
source "${TEST_DIR}/helpers.sh"
mkdir -p "$QUARANTINE_RUN_DIR/items"
DRY_RUN=0
REMOVE_MODE=quarantine
TOTAL_QUARANTINED_ITEMS=0
TOTAL_QUARANTINED_BYTES=0

begin_test "ENOTDIR on restore manifest does not report quarantine success"
set +e
quarantine_remove "$HOME/Library/Caches/victim" 100
rc=$?
set -e
assert_neq "$rc" "0" "quarantine_remove must fail when metadata cannot be written"
assert_eq "$TOTAL_QUARANTINED_ITEMS" "0" "must not count a restore-less move as success"
assert_file_exists "$HOME/Library/Caches/victim/data.bin" "source must be restored or never moved"

print_test_summary
```

Add a second test that uses a directory as `CLEANUP_JOURNAL_FILE` (so append gets EISDIR/ENOTDIR) with the same expectations.

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash tests/test_restore_metadata_failure.sh`
Expected: FAIL — current code `mv`s then `cleanup_restore_record ... || true` and returns 0.

- [ ] **Step 3: Write minimal implementation**

In `quarantine_remove`:
1. Resolve `dest`, create `dirname "$dest"` as a real directory.
2. Probe metadata durability BEFORE `mv`:
   - `dirname` of `CLEANUP_RESTORE_MANIFEST` must be a writable directory.
   - `dirname` of `CLEANUP_JOURNAL_FILE` must be a writable directory.
   - If either path exists and is not a writable regular file (or missing file in a writable dir), fail without moving.
3. Append an `intent` journal event (`action=quarantine_intent`, `status=pending`). If that write fails, abort.
4. `mv` source → dest.
5. Write the restore TSV row. Check the write: `printf ... >> manifest` must succeed AND the new row must be readable.
6. Write `quarantined` journal event. Must succeed.
7. Only then increment `TOTAL_QUARANTINED_ITEMS/BYTES` and return 0.
8. On any metadata failure after `mv`: `mv` dest back to source. If rollback fails, print a recovery error (`status=recovery_needed`), do not increment success counters, return 1.
9. Remove `|| true` from `cleanup_restore_record` and from `cleanup_journal_event` when the caller needs the status — make those functions return 1 on write failure. Keep a silent no-op only when the journal file is unset.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/bin/bash tests/test_restore_metadata_failure.sh && /bin/bash tests/test_quarantine_restore.sh`

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
fix: fail quarantine when restore metadata cannot be written

A moved item without a manifest is not a successful quarantine.
Probe the journal and restore files first, then roll the move back
if the durable record cannot be stored.
EOF
)"
```

---

### Task 3: H2 + H9 — Native plan ops obey policy; apply fails closed

**Files:**
- Create: `tests/test_native_plan_policy.sh`
- Create: `tests/test_plan_fail_closed.sh`
- Modify: `lib/planner.sh` (`plan_add_native`, `build_cleanup_plan_from_analysis`, `generate_plan_json`, `execute_plan_native_command`, `verify_plan_file_checksum`, `apply_plan_file`)
- Modify: `schemas/plan.schema.json` (add `rollback`, `tool`; keep required fields compatible)
- Modify: `lib/cleaner.sh` (package-manager `--consequence` must not claim quarantine rollback for native commands)
- Modify: `tests/test_planner_apply.sh` (native ops need a target path; failed native must fail apply)
- Modify: `tools/verify_release.sh` G18 plan JSON must include a sandbox target path
- Calling `json_summary_record_plan` from `generate_plan_json` IS this task.

**Interfaces:**
- Consumes: `FOUND_DEV_ITEMS` keys including `npx_cache` and `pnpm_stale_store`; `policy_adjust_risk_for_path`; `is_protected_path`; `catbytes_get`
- Produces: every `native_command` operation has non-empty `path`, `rollback: false`, `tool`, current `risk` from policy. `apply_plan_file` validates the whole document before the first mutation and returns non-zero if the parser or any executed op fails.

- [ ] **Step 1: Write failing tests**

`tests/test_native_plan_policy.sh` must cover:
1. `FOUND_DEV_ITEMS=("npx_cache:$HOME/.npm/_npx")` → generated plan contains that path as `remove_path`. **Ruling:** `npx_cache` and `pnpm_stale_store` become `remove_path` ops on the discovered path, not native npm/pnpm commands, because those native commands never touch them.
2. `brew_cache:$HOME/Library/Caches/Homebrew` uses `catbytes_get "brew"` (the cache size), not only `brew-stale`.
3. Native npm: create a cache dir, add it to `NEVER_TOUCH_PATHS`, generate plan, apply with PATH stub for `npm`. The stub must not run.
4. Consequence copy for package managers in `lib/cleaner.sh` around `confirm_category` must say native commands are irreversible / not quarantined.

`tests/test_plan_fail_closed.sh` must cover:
1. Two-op plan: first `remove_path` of a sandbox file, second `estimated_bytes` is `NOT_A_NUMBER`. Apply must return non-zero AND the first file must still exist.
2. One-op native npm with PATH stub that exits 42. Apply must return non-zero.
3. Missing checksum is rejected. Update `write_plan` in `test_planner_apply.sh` in this task.

Implement validation in Python inside `apply_plan_file`:
- `json.load` must succeed.
- Every operation: `action` in `remove_path|native_command|report_only`; `risk` in `SAFE|REVIEW|DANGEROUS`; `estimated_bytes` integer >= 0; `id` string.
- `native_command`: `command` in the allowlist AND `path` non-empty. Re-resolve `path` with `normalize_path`. If `is_protected_path` or current policy rank > plan rank, skip and journal `blocked` (do not run the tool).
- Parser: write python output to a temp file; check python exit code before the loop.
- After validation, execute. Aggregate failures. Return 1 if any executed op failed; 0 if all executed ops succeeded (skips do not count as failure).

Checksum: SHA256 of `json.dumps(ops, sort_keys=True, separators=(',', ':'))`. Empty checksum → reject.

- [ ] **Step 2: Run tests to verify they fail**

Run: `/bin/bash tests/test_native_plan_policy.sh; /bin/bash tests/test_plan_fail_closed.sh`

- [ ] **Step 3: Write minimal implementation**

`plan_add_native category risk command bytes description recommendation path tool`:
- Extra indexed arrays `PLAN_OP_ROLLBACK` and `PLAN_OP_TOOLS`.
- JSON emission includes `"rollback": false` and `"tool": "npm"` etc.

`build_cleanup_plan_from_analysis` case additions for `npx_cache` and `pnpm_stale_store` as `plan_add_path`. For npm/yarn/pnpm/pip/brew/gem native: pass `"$path"` into `plan_add_native` and `policy_adjust_risk_for_path "$path"`. Homebrew bytes: `catbytes_get "brew"` if non-zero else `catbytes_get "brew-stale"`.

`execute_plan_native_command` takes `path`. Measure `path_size_bytes` before/after when path exists. Record delta via `record_native_command_freed`. Return the real command rc. Unavailable tool returns 0 with status skipped. Failed command returns that rc.

`apply_plan_file`: drop `|| true` on native execution.

At end of `generate_plan_json`:
```
if type json_summary_record_plan >/dev/null 2>&1; then
    json_summary_record_plan "$count" "$safe_count" "$review_count" "$dangerous_count" "$safe_bytes" "$review_bytes" "$dangerous_bytes"
fi
```

Update G18 in `tools/verify_release.sh` so the sample plan has a sandbox `path` and a valid checksum.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/bin/bash tests/test_native_plan_policy.sh && /bin/bash tests/test_plan_fail_closed.sh && /bin/bash tests/test_planner_apply.sh && /bin/bash tests/test_planner.sh`

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
fix: bind native plan commands to targets and fail closed on apply

Plans now carry the real cache path, current policy, and no-rollback
flag. Apply validates the whole document before the first change and
returns non-zero when the parser or a native command fails.
EOF
)"
```

---

### Task 4: H4–H7 — Dev-sync copy, git protection, verify-full, symlink leaves

**Files:**
- Modify: `tests/test_dev_sync_safety.py` (extend; do not replace existing tests)
- Modify: `dev-sync/dev_sync_core.py` (`copy_relpaths`, `remove_path` usage, `import_overlay`, `RCloneProvider.sync_from`, `compare_overlay_content`, `verify_full_state`, `write_json`, `resolve_under`)
- Modify: `dev-sync/dev_sync_prune_excluded.py` (`quarantine_from_plan`)

**Interfaces:**
- Consumes: `tracked_files()`, `lexists()`, `safe_relpath()`, `scan_overlay_files()`
- Produces:
  - `copy_relpaths` never deletes dest before a successful verified copy.
  - `approved_overlay_relpaths(provider_files, tracked)` returns only files/leaf paths that are not tracked and not ancestors of tracked files.
  - Every transport (python copy, rsync, rclone) receives that closed list.
  - `verify_full_state` FAILs when an expected overlay file is missing on provider or local.
  - `resolve_under_leaf` does not follow the leaf symlink; prune moves the link, not the target.
  - `write_json` refuses a symlink destination and writes atomically.

- [ ] **Step 1: Write failing tests in `tests/test_dev_sync_safety.py`**

Add tests (real temp dirs, no mocks of `copy_relpaths` internals except rclone argv capture):

1. `test_copy_relpaths_missing_source_leaves_destination_bytes_identical`
2. `test_copy_relpaths_read_error_leaves_destination` (chmod 000; skip if ineffective)
3. `test_import_rejects_directory_that_contains_tracked_file`
4. `test_rclone_sync_from_uses_files_from_not_whole_repo`
5. `test_verify_full_fails_when_provider_file_missing`
6. `test_verify_full_fails_when_local_file_missing`
7. `test_prune_moves_symlink_leaf_not_target`
8. `test_write_json_refuses_symlink_manifest`

Helper: tiny git repo with `git init`/`git add`/`commit`. Set `GIT_AUTHOR_*` env.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m unittest tests.test_dev_sync_safety -v`

- [ ] **Step 3: Write minimal implementation**

`copy_relpaths`: source must lexist first; copy to `dest.name + ".importing-" + pid`; verify; `os.replace`; never `remove_path(dest)` first. Directories: copytree to importing dir, rename dest to `.replaced-...`, rename importing to dest, rmtree replaced; on failure rename replaced back.

`approved_overlay_relpaths(files, tracked)`: drop tracked names and any rel that is a prefix of a tracked path.

`import_overlay` local: use approved list. rclone `sync_from`: take approved list; empty list → no-op; otherwise `rclone copy --files-from`.

`compare_overlay_content`: missing local or missing provider → mismatch (do not `continue`).

`verify_full_state`: `provider_snapshot` = actual scan, not manifest-as-presence. Manifest is the expected set. `passed` requires missing lists empty.

`resolve_under_leaf(base, relpath)`: walk parts; ancestor symlink → error; do not `.resolve()` the leaf.

`quarantine_from_plan` uses `resolve_under_leaf`.

`write_json`: refuse symlink path; write temp then `os.replace`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m unittest tests.test_dev_sync_safety -v`

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
fix: make dev-sync import, verify, and prune fail closed

Copy via a verified temp file, reject overlay directories that contain
tracked Git files, require real copies in verify-full, and operate on
symlink leaves instead of their targets.
EOF
)"
```

---

### Task 5: H8 — Installer must not destroy local changes

**Files:**
- Create: `tests/test_installer_preserves_changes.sh`
- Modify: `install.sh`

**Interfaces:**
- Consumes: `git status --porcelain`, `git remote get-url origin`
- Produces: dirty tracked files unchanged; checksum mismatch aborts; no `git reset --hard`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -u
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/helpers.sh"
SANDBOX="$(mktemp -d -t macos_cleanup_installer.XXXXXX)"
DEST="${SANDBOX}/macOS_cleanup"
git clone --local --no-hardlinks "$PROJ_DIR" "$DEST" >/dev/null 2>&1
git -C "$DEST" remote get-url origin >/dev/null 2>&1 || git -C "$DEST" remote add origin "https://github.com/KasprowiczM/macOS_cleanup.git"
echo "LOCAL-CHANGE" >> "$DEST/cleanup_all.sh"
BEFORE="$(cksum "$DEST/cleanup_all.sh")"
export MACOS_CLEANUP_DIR="$DEST"
set +e
/bin/bash "${PROJ_DIR}/install.sh" --edge >/dev/null 2>&1
rc=$?
set -e
AFTER="$(cksum "$DEST/cleanup_all.sh")"
begin_test "installer refuses dirty checkout and keeps local bytes"
assert_neq "$rc" "0" "dirty update must fail"
assert_eq "$BEFORE" "$AFTER" "installer must not reset --hard over local edits"
print_test_summary
```

Also add a test: replace `SHA256SUMS` first line with junk in a clean DEST, run installer, expect non-zero abort.

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash tests/test_installer_preserves_changes.sh`

- [ ] **Step 3: Write minimal implementation**

If `DEST/.git` exists: verify origin matches `KasprowiczM/macOS_cleanup`; if `git status --porcelain` is non-empty, print refuse message and exit 1; fetch and checkout without `reset --hard`. If `SHA256SUMS` present, `shasum -a 256 -c` must succeed or exit 1. Do not retarget `RELEASE_TAG` in this task.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/bin/bash tests/test_installer_preserves_changes.sh`

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
fix: refuse installer updates on dirty checkouts and bad checksums

A failed checkout no longer falls back to git reset --hard, and a
SHA256SUMS mismatch aborts the install instead of printing a warning.
EOF
)"
```

---

### Task 6: MEDIUM — Plan/report/warning honesty

**Files:**
- Modify: `tests/test_json_summary.sh` — CLI test comparing stdout plan.operations to the written plan
- Modify: `lib/analyzer.sh` — skip Chrome/Brave top-level cache dirs in `FOUND_USER_CACHES`; `_run_analyzer` records partial failure
- Modify: `lib/common.sh` — `print_warn` appends to `WARNINGS_LIST`; `path_size_bytes` on du failure; CATEGORY_REGISTRY class for `system-caches`, `app-leftovers`, `maven`, `android-avd`, `xcode-archives` → `report-only`
- Modify: `lib/reporter.sh` if it assumes those keys are counted
- Modify: `tests/test_report_parity.sh`, `tests/test_common.sh`, `tests/test_analyzer.sh`, `tests/test_run_accounting_truth.sh` as needed

**Interfaces:**
- Produces: `--json` plan.operations equals the written plan; report-only categories are not summed into would-free; `print_warn` feeds the report warning list; analyzer failure sets `ANALYSIS_PARTIAL=1`.

- [ ] **Step 1: Write failing tests**

1. CLI `--json` plan.operations matches written plan file.
2. `category_class` for `system-caches`, `app-leftovers`, `maven`, `android-avd`, `xcode-archives` is `report-only`.
3. `print_warn` records `WARNINGS_LIST`.
4. Chrome cache dir must not appear in `FOUND_USER_CACHES` when sized as browser-caches.
5. `_run_analyzer` on a failing function sets `ANALYSIS_PARTIAL=1`. `path_size_bytes` on a permission-denied existing path must not look like a measured 0 B success: if `du` fails, return 1 and emit a warning; non-existent paths still echo 0 and return 0.

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Write minimal implementation**

- `print_warn() { WARNINGS_LIST+=("$*"); ... }`
- `_run_analyzer`: on failure set `ANALYSIS_PARTIAL=1`
- `analyze_user_caches`: skip known browser cache roots
- Registry class changes. Grand total already uses `category_class`.

- [ ] **Step 4: Run tests**

Run: `/bin/bash tests/test_json_summary.sh && /bin/bash tests/test_report_parity.sh && /bin/bash tests/test_common.sh && /bin/bash tests/test_analyzer.sh`

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
fix: align JSON plan counters, warnings, and report-only totals

Stdout --json now records the generated plan size, print_warn feeds
the report, and report-only categories no longer inflate counted bytes.
EOF
)"
```

---

### Task 7: MEDIUM — Test runner, bash -n loop, schema validation, apply lock

**Files:**
- Modify: `tests/run_all.sh` (Python pipeline status)
- Modify: `.github/workflows/ci.yml` (syntax check loop; do not add macOS-on-push)
- Modify: `tools/verify_release.sh` G01
- Create: `tests/test_plan_schema.sh`
- Modify: `lib/common.sh` — `acquire_cleanup_lock` / `release_cleanup_lock` using `mkdir` on `"${QUARANTINE_ROOT}/.apply.lock"`
- Modify: `cleanup_all.sh` apply/restore/purge to take the lock
- Create: `tests/test_apply_lock.sh`

**Interfaces:**
- Produces: `tests/run_all.sh` fails if Python unittest fails even when piped; CI `bash -n` checks every script; apply/restore/purge are mutually exclusive per quarantine root.

- [ ] **Step 1: Write failing tests**

Fix `run_all.sh` to not pipe unittest into `tail` (or use `set -o pipefail` and keep unittest rc). Prefer no pipe.

`tests/test_plan_schema.sh`: stdlib python checker matching `schemas/plan.schema.json`. Negative cases: bad action, missing id, non-integer bytes.

`tests/test_apply_lock.sh`: `acquire_cleanup_lock` twice — second returns 1.

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement**

CI / G01:
```
fail=0
for f in cleanup_all.sh lib/*.sh config/*.sh tests/*.sh tools/*.sh i18n/*.sh dev-sync/*.sh dev-sync-*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" || fail=1
done
exit $fail
```
Do not add macOS jobs or schedules.

Lock via exclusive `mkdir`. Trap release on EXIT in apply/restore/purge. Do not claim TOCTOU immunity.

- [ ] **Step 4: Run tests**

Run: `/bin/bash tests/run_all.sh` plus new tests.

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
fix: fail the suite on python errors and lock apply against itself

run_all.sh now keeps the unittest exit status, bash -n checks each
script, plans validate against the schema, and apply/restore/purge
take a per-quarantine directory lock.
EOF
)"
```

---

### Task 8: H10 — Consistent release artifacts and portable docs

**Files:**
- Modify: `config/defaults.sh` (`SCRIPT_VERSION` → `3.0.6`)
- Modify: `install.sh` (`RELEASE_TAG="v3.0.6"`)
- Modify: `CHANGELOG.md`
- Modify: `SHA256SUMS`
- Modify: `tools/gen_protected_docs.sh`
- Modify: `docs/PROTECTED_PATHS.md` and README NEVER_TOUCH blocks via the generator
- Modify: tests that fail shellcheck at info level (SC2088, SC1003)
- Create: `tests/test_release_consistency.sh`

**Interfaces:**
- Produces: installer tag matches `SCRIPT_VERSION`; `shasum -a 256 -c SHA256SUMS` passes; `HOME=/tmp/isolated gen_protected_docs.sh --check` passes; G03 passes.

- [ ] **Step 1: Write failing checks in `tests/test_release_consistency.sh`**

SCRIPT_VERSION vs install.sh RELEASE_TAG; SHA256SUMS check; `HOME=/tmp/macos_cleanup_isolated_home_$$ /bin/bash tools/gen_protected_docs.sh --check`.

- [ ] **Step 2: Run to verify fail**

- [ ] **Step 3: Implement**

Rewrite expanded `$HOME` to `~` in generated docs. Fix ShellCheck at info level; do not weaken G03 to warning. Do not enable extra CI macOS runs. Regenerate SHA256SUMS last.

- [ ] **Step 4: Run**

Run: `/bin/bash tests/test_release_consistency.sh` and `/bin/bash tests/run_all.sh` and shellcheck -S info if available.

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
chore: ship 3.0.6 checksums, installer tag, and portable path docs

Release metadata matches the safety fixes, checksum mismatches abort
install, and protected-path docs no longer depend on the builder HOME.
EOF
)"
```

---

## Self-review

1. Spec coverage: H1→T1, H2+H9+npx/pnpm/brew→T3, H3→T2, H4–H7→T4, H8→T5, H10→T8, MEDIUM json/report/warn/overlap→T6, MEDIUM run_all/bash-n/schema/lock→T7. LOW YAML-parser cleanup is out of scope.
2. Placeholder scan: none.
3. G18 and `write_plan` helpers must be updated in Task 3 when checksum/path become required.
4. `test_security_privacy.sh` wiring assertion is updated in Task 1; it previously required the unsafe preflight prune.
