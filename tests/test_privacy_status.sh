#!/usr/bin/env bash
# =============================================================================
# tests/test_privacy_status.sh — Phase 3: unreadable is not empty.
#
# macOS 27 can deny access to other apps' folders silently. path_size_bytes
# discarded du's partial size and returned 0 for any location it could not
# fully read, and ANALYSIS_PARTIAL was set but never reported, so a scan of a
# privacy-protected tree looked like "0 B, complete". ~/.aws/sso (SSO tokens)
# was not protected. Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_privacy.XXXXXX)"
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
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/json_summary.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/reporter.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
begin_test "a partly unreadable tree keeps its readable size and is recorded"
TREE="${HOME}/Library/Caches/com.example.partly"
mkdir -p "${TREE}/open" "${TREE}/locked"
dd if=/dev/zero of="${TREE}/open/blob" bs=1024 count=64 2>/dev/null
dd if=/dev/zero of="${TREE}/locked/blob" bs=1024 count=64 2>/dev/null
chmod 000 "${TREE}/locked"
bytes="$(path_size_bytes "$TREE" 2>/dev/null)"
chmod 755 "${TREE}/locked"
assert_true "(( ${bytes:-0} >= 65536 ))" "readable part is counted, not 0 (got ${bytes:-0})"
assert_eq "$(analysis_unreadable_count)" "1" "the location is recorded as not fully readable"

begin_test "the JSON summary and the terminal summary report a partial analysis"
JSON_OUT="${SANDBOX}/summary.json"
emit_json_summary "dry-run" > "$JSON_OUT" 2>/dev/null
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['analysis_status'])" "$JSON_OUT" 2>/dev/null)" "partial" "analysis_status is partial"
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['counters']['unreadable_paths'])" "$JSON_OUT" 2>/dev/null)" "1" "unreadable_paths counted"
MODE="dry-run"
# shellcheck disable=SC2034  # read inside the assert_true eval string
summary="$(print_summary_report 2>&1)"
assert_true "printf '%s' \"\$summary\" | grep -qi 'not fully readable'" "terminal summary says some locations were not fully readable"

begin_test "a clean run reports complete"
rm -f "$(analysis_unreadable_file)"
ANALYSIS_PARTIAL=0
emit_json_summary "dry-run" > "$JSON_OUT" 2>/dev/null
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['analysis_status'])" "$JSON_OUT" 2>/dev/null)" "complete" "analysis_status is complete"

begin_test "a fully unreadable directory is recorded once, however often it is measured"
rm -f "$(analysis_unreadable_file)"
SHUT="${HOME}/Library/Caches/com.example.shut"
mkdir -p "$SHUT"; printf 'x' > "${SHUT}/f"; chmod 000 "$SHUT"
path_size_bytes "$SHUT" >/dev/null 2>&1
path_size_bytes "$SHUT" >/dev/null 2>&1
chmod 755 "$SHUT"
assert_eq "$(analysis_unreadable_count)" "1" "measured twice, counted once"

begin_test "permanent mode never deletes a tree it could not fully read"
rm -f "$(analysis_unreadable_file)"
PART="${HOME}/Library/Caches/com.example.halfdelete"
mkdir -p "${PART}/open" "${PART}/locked"
printf 'o' > "${PART}/open/f"; printf 'l' > "${PART}/locked/f"
chmod 000 "${PART}/locked"
( REMOVE_MODE=permanent; DRY_RUN=0; safe_remove "$PART" >/dev/null 2>&1 )
chmod 755 "${PART}/locked"
assert_true "[ -f '${PART}/open/f' ]" "the readable part was not deleted"
assert_true "[ -f '${PART}/locked/f' ]" "the locked part is intact"

begin_test "unreadable_*.txt files are rotated with the logs"
OLD_UR="${LOGS_DIR}/unreadable_2000-01-01_000000_1.txt"
printf 'partial\t/x\n' > "$OLD_UR"; touch -t 200001010000 "$OLD_UR"
( DRY_RUN=0; EXPLICIT_DRY_RUN=0; rotate_old_artifacts 30 >/dev/null 2>&1 || true )
assert_false "[ -f '$OLD_UR' ]" "an old unreadable list is rotated"

# ---------------------------------------------------------------------------
begin_test "AWS SSO tokens are protected"
mkdir -p "$HOME/.aws/sso/cache"
normalize_never_touch_paths 2>/dev/null || true
assert_true "is_protected_path '$HOME/.aws/sso/cache/token.json'" "AWS SSO cache is NEVER_TOUCH"

print_test_summary
