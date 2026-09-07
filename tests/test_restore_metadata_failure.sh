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
export NO_COLOR=1
source "${PROJ_DIR}/config/defaults.sh"
source "${PROJ_DIR}/lib/common.sh"
source "${TEST_DIR}/helpers.sh"
mkdir -p "$QUARANTINE_RUN_DIR/items"
DRY_RUN=0
REMOVE_MODE=quarantine
TOTAL_QUARANTINED_ITEMS=0
TOTAL_QUARANTINED_BYTES=0

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

begin_test "ENOTDIR on restore manifest does not report quarantine success"
set +e
quarantine_remove "$HOME/Library/Caches/victim" 100
rc=$?
set -e
assert_neq "$rc" "0" "quarantine_remove must fail when metadata cannot be written"
assert_eq "$TOTAL_QUARANTINED_ITEMS" "0" "must not count a restore-less move as success"
assert_file_exists "$HOME/Library/Caches/victim/data.bin" "source must be restored or never moved"

begin_test "EISDIR on journal file does not report quarantine success"
# Same env vars (defaults.sh marks them readonly). Reconfigure the filesystem
# so the restore parent is a real directory and the journal path is a directory.
mkdir -p "$HOME/Library/Caches/victim"
echo payload > "$HOME/Library/Caches/victim/data.bin"
if [[ -e "$CLEANUP_JOURNAL_FILE" && ! -d "$CLEANUP_JOURNAL_FILE" ]]; then
    rm -f "$CLEANUP_JOURNAL_FILE"
fi
mkdir -p "$CLEANUP_JOURNAL_FILE"
if [[ -f "${SANDBOX}/reports/restore_run.tsv" ]]; then
    rm -f "${SANDBOX}/reports/restore_run.tsv"
fi
mkdir -p "${SANDBOX}/reports/restore_run.tsv"
TOTAL_QUARANTINED_ITEMS=0
TOTAL_QUARANTINED_BYTES=0
set +e
quarantine_remove "$HOME/Library/Caches/victim" 100
rc=$?
set -e
assert_neq "$rc" "0" "quarantine_remove must fail when journal cannot be written"
assert_eq "$TOTAL_QUARANTINED_ITEMS" "0" "must not count a journal-less move as success"
assert_file_exists "$HOME/Library/Caches/victim/data.bin" "source must be restored or never moved"

print_test_summary
