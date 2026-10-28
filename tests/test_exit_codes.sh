#!/usr/bin/env bash
# =============================================================================
# tests/test_exit_codes.sh — P2: failures are not reported as success, and a
# failure count is not returned as an exit code.
#
# restore ended with exit 0 even when no row could be restored, and
# purge_quarantine returned its failure count, so two failed runs looked like
# exit 2 ("bad argument"). Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_exit_codes.XXXXXX)"
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
export QUARANTINE_RUN_DIR="${SANDBOX}/quarantine/test_run"
mkdir -p "$HOME/Library/Caches/com.example.app" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

begin_test "a restore that could not restore everything is flagged incomplete"
TARGET="$HOME/Library/Caches/com.example.app/data.bin"
printf 'payload' > "$TARGET"
DRY_RUN=0; EXPLICIT_DRY_RUN=0; REMOVE_MODE=quarantine
safe_remove "$TARGET" >/dev/null 2>&1
assert_false "[ -e '$TARGET' ]" "fixture: file moved to quarantine"
printf 'new' > "$TARGET"                     # conflict: the target exists again
RESTORE_INCOMPLETE=0
restore_quarantine_manifest "$CLEANUP_RESTORE_MANIFEST" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "the function itself still returns 0 (errexit stays active inside)"
assert_eq "$RESTORE_INCOMPLETE" "1" "the conflict marks the restore incomplete"

begin_test "the restore phase exits non-zero when the restore was incomplete"
assert_true "sed -n '/^run_restore_phase() {/,/^}/p' '$PROJ_DIR/cleanup_all.sh' | grep -q 'RESTORE_INCOMPLETE'" "run_restore_phase checks RESTORE_INCOMPLETE"

begin_test "re-running a completed restore is not reported as incomplete"
rm -f "$TARGET"                               # resolve the conflict
RESTORE_INCOMPLETE=0
restore_quarantine_manifest "$CLEANUP_RESTORE_MANIFEST" >/dev/null 2>&1
assert_true "[ -f '$TARGET' ]" "fixture: the file is restored"
RESTORE_INCOMPLETE=0
restore_quarantine_manifest "$CLEANUP_RESTORE_MANIFEST" >/dev/null 2>&1
assert_eq "$RESTORE_INCOMPLETE" "0" "already-restored rows do not make a re-run incomplete"

begin_test "a failed apply still writes its report and its --json summary"
E2E_HOME="${SANDBOX}/e2e_home"; mkdir -p "$E2E_HOME"
BAD_PLAN="${SANDBOX}/bad_plan.json"
printf '{"schema_version":"1.0","checksum":"0000","summary":{},"operations":[]}\n' > "$BAD_PLAN"
# shellcheck disable=SC2034  # read inside the assert_true eval string
E2E_OUT="$(env -i HOME="$E2E_HOME" USER="$USER" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
    LOGS_DIR="${SANDBOX}/e2e_logs" REPORTS_DIR="${SANDBOX}/e2e_reports" \
    QUARANTINE_ROOT="${E2E_HOME}/q/quarantine" PYTHONDONTWRITEBYTECODE=1 \
    /bin/bash "${PROJ_DIR}/cleanup_all.sh" apply --from-plan "$BAD_PLAN" --non-interactive --json </dev/null 2>/dev/null)"; e2e_rc=$?
assert_neq "$e2e_rc" "0" "the failed apply exits non-zero"
assert_true "ls '${SANDBOX}/e2e_reports'/report_*.md >/dev/null 2>&1" "a report was written"
assert_true "printf '%s' \"\$E2E_OUT\" | python3 -c 'import json,sys; json.load(sys.stdin)'" "a JSON summary was emitted"

begin_test "purge returns 1 for any number of failures, never the count"
mkdir -p "$QUARANTINE_ROOT/2026-01-01_000000_1/items" "$QUARANTINE_ROOT/2026-01-02_000000_2/items"
purge_one_quarantine_run() { return 1; }
purge_quarantine "all" 1 30 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "two failed runs return 1, not 2"

print_test_summary
