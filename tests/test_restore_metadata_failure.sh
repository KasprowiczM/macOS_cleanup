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

begin_test "post-mv journal failure rolls back and drops restore row"
# Restore writable journal/manifest after the EISDIR case.
if [[ -d "$CLEANUP_JOURNAL_FILE" ]]; then
    rm -rf "$CLEANUP_JOURNAL_FILE"
fi
if [[ -d "${SANDBOX}/reports/restore_run.tsv" ]]; then
    rm -rf "${SANDBOX}/reports/restore_run.tsv"
fi
mkdir -p "${SANDBOX}/reports"
: > "$CLEANUP_JOURNAL_FILE"
: > "${SANDBOX}/reports/restore.tsv"
# CLEANUP_RESTORE_MANIFEST is readonly from defaults; if it still points at nested.tsv, use that parent.
manifest_parent="$(dirname "$CLEANUP_RESTORE_MANIFEST")"
if [[ -f "${SANDBOX}/reports/restore_run.tsv" ]]; then
    :
elif [[ -d "$manifest_parent" ]]; then
    : > "$CLEANUP_RESTORE_MANIFEST"
else
    mkdir -p "$manifest_parent"
    : > "$CLEANUP_RESTORE_MANIFEST"
fi
mkdir -p "$HOME/Library/Caches/victim"
echo payload > "$HOME/Library/Caches/victim/data.bin"
TOTAL_QUARANTINED_ITEMS=0
TOTAL_QUARANTINED_BYTES=0
CLEANUP_TEST_FAIL_JOURNAL_ACTION=quarantined
set +e
quarantine_remove "$HOME/Library/Caches/victim" 100
rc=$?
set -e
unset CLEANUP_TEST_FAIL_JOURNAL_ACTION
assert_neq "$rc" "0" "post-mv journal failure must fail closed"
assert_eq "$TOTAL_QUARANTINED_ITEMS" "0" "rollback must not increment quarantine count"
assert_file_exists "$HOME/Library/Caches/victim/data.bin" "payload must be rolled back to source"
assert_eq "$(cat "$HOME/Library/Caches/victim/data.bin")" "payload" "source bytes must be identical after rollback"
if [[ -f "$CLEANUP_RESTORE_MANIFEST" ]]; then
    leftover=0
    if [[ -s "$CLEANUP_RESTORE_MANIFEST" ]]; then
        leftover="$(wc -l < "$CLEANUP_RESTORE_MANIFEST" | tr -d ' ')"
    fi
    assert_eq "$leftover" "0" "restore TSV must not keep a row for a rolled-back item"
fi

begin_test "safe_remove does not abort the shell on quarantine metadata failure"
mkdir -p "$HOME/Library/Caches/keep_me"
echo keep > "$HOME/Library/Caches/keep_me/x"
mkdir -p "$HOME/Library/Caches/victim"
echo payload > "$HOME/Library/Caches/victim/data.bin"
TOTAL_QUARANTINED_ITEMS=0
DRY_RUN=0
REMOVE_MODE=quarantine
CLEANUP_TEST_FAIL_JOURNAL_ACTION=quarantined
set +e
safe_remove "$HOME/Library/Caches/victim"
rc1=$?
safe_remove "$HOME/Library/Caches/keep_me"
rc2=$?
set -e
unset CLEANUP_TEST_FAIL_JOURNAL_ACTION
assert_neq "$rc1" "0" "first safe_remove should fail closed"
assert_file_exists "$HOME/Library/Caches/keep_me/x" "second item must still be reachable after first failure"

print_test_summary
