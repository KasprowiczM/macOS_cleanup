#!/usr/bin/env bash
# =============================================================================
# tests/test_size_memo.sh — Phase 2: sizes are measured once per run.
#
# The analyzers measured every candidate with du, then the planner and the
# interactive prompts measured the same paths again. path_size_bytes now
# records each measurement in a run-scoped memo; plan estimates and prompts
# read it. Before/after accounting and safe_remove still measure live.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_size_memo.XXXXXX)"
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
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

grow() { dd if=/dev/zero of="$1/blob_$2" bs=1024 count="$2" 2>/dev/null; }

CACHE="${HOME}/Library/Caches/com.example.memo"
mkdir -p "$CACHE"
grow "$CACHE" 64

# ---------------------------------------------------------------------------
begin_test "SIZE_MEMO_FILE is not taken from the environment"
# The exit handler removes the memo file, so an inherited value would let the
# environment name a file to delete.
VICTIM="${SANDBOX}/victim.txt"; echo keep > "$VICTIM"
inherited="$(SIZE_MEMO_FILE="$VICTIM" bash -c 'source "'"${PROJ_DIR}"'/config/defaults.sh"; source "'"${PROJ_DIR}"'/lib/common.sh"; printf "%s" "$SIZE_MEMO_FILE"' 2>/dev/null)"
assert_eq "$inherited" "" "an exported SIZE_MEMO_FILE is ignored"
assert_file_exists "$VICTIM" "the named file is untouched"

# ---------------------------------------------------------------------------
begin_test "without a memo file every size is measured live"
SIZE_MEMO_FILE=""
# shellcheck disable=SC2034  # read inside the assert_* eval strings
first="$(path_size_bytes "$CACHE")"
grow "$CACHE" 32
assert_true "(( $(path_size_bytes_memo "$CACHE") > first ))" "no memo: the estimate follows the disk"

# ---------------------------------------------------------------------------
begin_test "a measurement is recorded and later estimates reuse it"
SIZE_MEMO_FILE="${LOGS_DIR}/size_memo_test.tsv"
measured="$(path_size_bytes "$CACHE")"
grow "$CACHE" 128
assert_eq "$(path_size_bytes_memo "$CACHE")" "$measured" "the estimate comes from the memo, not a second du"
assert_true "(( $(path_size_bytes "$CACHE") > measured ))" "path_size_bytes itself always measures live"
assert_true "(( $(path_size_bytes_memo "$CACHE") > measured ))" "the newest measurement wins"

# ---------------------------------------------------------------------------
begin_test "a path that is gone is 0 even when it was measured"
GONE="${HOME}/Library/Caches/com.example.gone"
mkdir -p "$GONE"; grow "$GONE" 16
path_size_bytes "$GONE" >/dev/null
rm -rf "$GONE"
assert_eq "$(path_size_bytes_memo "$GONE")" "0" "missing path"

# ---------------------------------------------------------------------------
begin_test "a path with a newline is never memoized"
NL="${HOME}/Library/Caches/odd
name"
mkdir -p "$NL"; grow "$NL" 16
path_size_bytes "$NL" >/dev/null
assert_false "grep -q 'odd' '$SIZE_MEMO_FILE'" "newline path not written to the memo"
grow "$NL" 64
assert_true "(( $(path_size_bytes_memo "$NL") > 16384 ))" "newline path is measured live"

# ---------------------------------------------------------------------------
begin_test "a path that only prefixes another does not match"
PFX="${HOME}/Library/Caches/com.example"
mkdir -p "$PFX"
assert_true "(( $(path_size_bytes_memo "$PFX") != $(path_size_bytes_memo "$CACHE") ))" "exact key match"

# ---------------------------------------------------------------------------
begin_test "plan_add_path and the prompts read the memo"
PLAN_CACHE="${HOME}/Library/Caches/com.example.plan"
mkdir -p "$PLAN_CACHE"; grow "$PLAN_CACHE" 64
plan_measured="$(path_size_bytes "$PLAN_CACHE")"
grow "$PLAN_CACHE" 256
plan_reset
plan_add_path "app-caches" "SAFE" "$PLAN_CACHE" "desc" "rec"
assert_eq "${PLAN_OP_BYTES[0]}" "$plan_measured" "plan_add_path reuses the analyzer's size"
assert_eq "$(path_size_human_memo "$PLAN_CACHE")" "$(bytes_to_human "$plan_measured")" "prompt size reuses it"
for fn in confirm_category confirm_ios_backups processable_total_bytes; do
    assert_true "declare -f $fn | grep -q 'path_size_\(bytes\|human\)_memo'" "$fn reads the memo"
done

# ---------------------------------------------------------------------------
begin_test "deletion and before/after accounting never read the memo"
for fn in safe_remove direct_remove _clean_dev_native_or_fallback clean_dev_caches; do
    if declare -f "$fn" >/dev/null 2>&1; then
        # shellcheck disable=SC2034  # read inside the assert_* eval strings
        body="$(declare -f "$fn")"
        case "$fn" in
            safe_remove|direct_remove)
                assert_false "printf '%s' \"\$body\" | grep -q '_memo'" "$fn measures live" ;;
            *)
                # Native-command before/after pairs (_before/_after, _bb/_ba,
                # _pb/_pa) must stay live.
                assert_false "printf '%s' \"\$body\" | grep -Eq '_(before|after|bb|ba|pb|pa)=.*_memo'" "$fn before/after is live" ;;
        esac
    fi
done

# ---------------------------------------------------------------------------
begin_test "the memo file is removed when the run exits"
assert_file_exists "$SIZE_MEMO_FILE" "memo written during the run"
remove_plan_temp_files
assert_file_absent "$SIZE_MEMO_FILE" "memo removed by the exit handler"

print_test_summary
