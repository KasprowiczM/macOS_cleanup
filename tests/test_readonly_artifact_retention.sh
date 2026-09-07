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
