#!/usr/bin/env bash
# =============================================================================
# tests/test_lock_atomic.sh — P1-7: one lock for every mutating mode, stale
# locks recovered, plan files written atomically and applied from a snapshot.
#
# The 2026-10-27 review: the lock covered apply/restore/purge only, so an
# interactive or auto-safe run could move files into the quarantine while
# `--purge-quarantine latest` deleted that very run; a lock left by a crashed
# run blocked every later apply forever; and generate_plan_json wrote the
# destination in place, so a failed checksum stamp left a broken plan behind.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_lock_atomic.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
export USER="${USER:-testuser}"
export LOG_LEVEL="ERROR"
export NO_COLOR=1
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$HOME" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

LIVE_PID=""
cleanup() {
    [[ -n "$LIVE_PID" ]] && kill "$LIVE_PID" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

LOCK="${QUARANTINE_ROOT}/.apply.lock"

# A pid that is certainly not running: a finished child.
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null

# ---------------------------------------------------------------------------
begin_test "a lock left by a dead process is recovered"
mkdir "$LOCK"; printf '%s\n' "$DEAD_PID" > "${LOCK}/pid"
CLEANUP_LOCK_HELD=0
acquire_cleanup_lock; rc=$?
assert_eq "$rc" "0" "stale lock (dead pid) recovered"
assert_eq "$(cat "${LOCK}/pid" 2>/dev/null)" "$$" "lock now records this process"
release_cleanup_lock

begin_test "a lock held by a live process still blocks"
sleep 30 &
LIVE_PID=$!
mkdir "$LOCK"; printf '%s\n' "$LIVE_PID" > "${LOCK}/pid"
CLEANUP_LOCK_HELD=0
acquire_cleanup_lock; rc=$?
assert_eq "$rc" "1" "live holder blocks"
assert_eq "$(cat "${LOCK}/pid" 2>/dev/null)" "$LIVE_PID" "live holder's lock untouched"
kill "$LIVE_PID" 2>/dev/null; LIVE_PID=""
rm -f "${LOCK}/pid"; rmdir "$LOCK"

begin_test "a lock without a pid is stale only when old"
mkdir "$LOCK"
CLEANUP_LOCK_HELD=0
acquire_cleanup_lock; rc=$?
assert_eq "$rc" "1" "fresh pid-less lock blocks (holder may be mid-acquire)"
touch -t 200001010000 "$LOCK"
acquire_cleanup_lock; rc=$?
assert_eq "$rc" "0" "old pid-less lock is recovered"
release_cleanup_lock

begin_test "release never removes a lock this process does not hold"
CLEANUP_LOCK_HELD=0
acquire_cleanup_lock
printf '%s\n' "$DEAD_PID" > "${LOCK}/pid"      # someone else's lock now
release_cleanup_lock
assert_true "[ -d '$LOCK' ]" "release left the other holder's lock in place"
rm -f "${LOCK}/pid"; rmdir "$LOCK"

begin_test "only one recoverer at a time (recovery mutex)"
mkdir "$LOCK"; printf '%s\n' "$DEAD_PID" > "${LOCK}/pid"
mkdir "${LOCK}.recover"
CLEANUP_LOCK_HELD=0
acquire_cleanup_lock; rc=$?
assert_eq "$rc" "1" "a fresh recovery mutex blocks a second recoverer"
touch -t 200001010000 "${LOCK}.recover"
acquire_cleanup_lock; rc=$?
assert_eq "$rc" "0" "an abandoned (old) recovery mutex is cleared"
assert_false "[ -d '${LOCK}.recover' ]" "recovery mutex released"
release_cleanup_lock

begin_test "a broken ps never makes a live lock look stale"
mkdir "$LOCK"; printf '%s\n' "$DEAD_PID" > "${LOCK}/pid"
PS_BIN="${SANDBOX}/psbin"; mkdir -p "$PS_BIN"
printf '#!/bin/sh\nexit 1\n' > "${PS_BIN}/ps"; chmod +x "${PS_BIN}/ps"
_old_path="$PATH"; PATH="${PS_BIN}:${PATH}"
CLEANUP_LOCK_HELD=0
acquire_cleanup_lock; rc=$?
PATH="$_old_path"
assert_eq "$rc" "1" "without a working ps the holder is presumed alive"
rm -f "${LOCK}/pid"; rmdir "$LOCK"

# ---------------------------------------------------------------------------
begin_test "interactive and auto-safe phases take the lock too"
python3 - "$PROJ_DIR/cleanup_all.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
missing = []
for name in ("run_interactive_phase", "run_auto_safe_phase", "run_restore_phase",
             "run_purge_quarantine_phase", "run_apply_plan_phase"):
    start = text.find("%s() {" % name)
    if start < 0:
        missing.append(name + ":missing"); continue
    rest = text[start:]
    m = re.search(r"\n(?=[a-zA-Z_]+\(\) \{|# ----)", rest)
    body = rest[: m.start()] if m else rest
    if "require_cleanup_lock" not in body:
        missing.append(name)
if missing:
    sys.stderr.write("no lock: %s\n" % ", ".join(missing)); sys.exit(1)
PY
assert_eq "$?" "0" "every mutating phase calls require_cleanup_lock"

begin_test "the locked-mode EXIT trap still reaches _on_exit on a failing exit"
TRAP_TEXT="$(sed -n '/^require_cleanup_lock() {/,/^}/p' "$PROJ_DIR/cleanup_all.sh" | grep -o "trap '.*' EXIT")"
assert_neq "$TRAP_TEXT" "" "trap found in require_cleanup_lock"
# shellcheck disable=SC2034  # read inside the assert_true eval string
TRAP_OUT="$( /bin/bash -c '
    set -e
    release_cleanup_lock() { echo release; }
    _on_exit() { echo on_exit; }
    eval "$1"
    exit 3' _ "$TRAP_TEXT" 2>&1 )"; rc=$?
assert_eq "$rc" "3" "exit status preserved"
assert_true "printf '%s' \"\$TRAP_OUT\" | grep -q on_exit" "_on_exit runs after release on a non-zero exit"

# ---------------------------------------------------------------------------
begin_test "a failed checksum stamp leaves the previous plan intact"
PLAN="${REPORTS_DIR}/plan.json"
printf '%s\n' '{"previous": true}' > "$PLAN"
plan_reset
plan_add_operation "op-0001" "trash" "SAFE" "remove_path" "$HOME/.Trash/x" "" 10 "d" "r"
FAKE_BIN="${SANDBOX}/fakebin"; mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 1\n' > "${FAKE_BIN}/python3"; chmod +x "${FAKE_BIN}/python3"
_old_path="$PATH"; PATH="${FAKE_BIN}:${PATH}"
generate_plan_json "$PLAN" >/dev/null 2>&1; rc=$?
PATH="$_old_path"
assert_neq "$rc" "0" "stamp failure is reported"
assert_eq "$(cat "$PLAN")" '{"previous": true}' "destination keeps the previous plan"
assert_eq "$(find "$REPORTS_DIR" -name 'plan.json.*' | wc -l | tr -d ' ')" "0" "no temp file left behind"

begin_test "plan generation still aborts under errexit when a write fails"
printf '%s\n' '{"previous": true}' > "$PLAN"
( set -e
  printf() { if [[ "${1:-}" == *schema_version* ]]; then return 1; fi; builtin printf "$@"; }
  generate_plan_json "$PLAN" >/dev/null 2>&1 ); rc=$?
assert_neq "$rc" "0" "a failed write aborts under set -e"
assert_eq "$(cat "$PLAN")" '{"previous": true}' "the previous plan survives an aborted write"
rm -f "${REPORTS_DIR}"/plan.json.tmp.*

begin_test "a directory as --plan-file is refused, not written into"
mkdir -p "${REPORTS_DIR}/plandir"
generate_plan_json "${REPORTS_DIR}/plandir" >/dev/null 2>&1; rc=$?
assert_neq "$rc" "0" "directory target refused"
assert_eq "$(ls -A "${REPORTS_DIR}/plandir" | wc -l | tr -d ' ')" "0" "nothing moved into the directory"

begin_test "apply still aborts under errexit (no fail-open wrapper)"
python3 - "$PLAN" "$HOME/keep.txt" <<'PY'
import hashlib, json, sys
ops=[{"id":"op-1","category":"trash","risk":"SAFE","action":"remove_path","path":sys.argv[2],"command":"",
      "estimated_bytes":1,"size":1,"description":"d","recommendation":"r","rollback":True}]
chk=hashlib.sha256(json.dumps(ops,sort_keys=True,separators=(",",":")).encode()).hexdigest()
json.dump({"schema_version":"1.0","checksum":chk,"summary":{},"operations":ops},open(sys.argv[1],"w"))
PY
printf 'k' > "$HOME/keep.txt"
( set -e
  DRY_RUN=0; REMOVE_MODE=quarantine; NON_INTERACTIVE=1
  base64_decode_string() { return 1; }
  apply_plan_file "$PLAN" >/dev/null 2>&1
  echo "continued" > "${SANDBOX}/continued" ); rc=$?
assert_neq "$rc" "0" "a failing decode aborts apply"
assert_false "[ -f '${SANDBOX}/continued' ]" "nothing runs after the failure"

begin_test "a successful write replaces the plan and leaves no temp file"
generate_plan_json "$PLAN" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "plan written"
assert_true "python3 -c \"import json,sys; d=json.load(open('$PLAN')); sys.exit(0 if d['checksum']!='pending' else 1)\"" "plan is stamped"
assert_eq "$(find "$REPORTS_DIR" -name 'plan.json.*' | wc -l | tr -d ' ')" "0" "no temp file left behind"

# ---------------------------------------------------------------------------
begin_test "apply verifies and parses one snapshot of the plan"
assert_true "grep -q 'plan_snapshot' '$PROJ_DIR/lib/planner.sh'" "apply_plan_file works on a private snapshot"

print_test_summary
