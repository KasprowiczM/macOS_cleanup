#!/usr/bin/env bash
# =============================================================================
# tests/test_ux_performance.sh — Unit tests for Performance & UX Engine [Batch 9]
#
# Validates the per-run size memo (path_size_bytes_memo) and --explain category documentation.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_ux_perf.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
export LOG_LEVEL="INFO"
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

begin_test "path_size_bytes_memo reuses a measurement made in a subshell"
test_dir="${SANDBOX}/cache_test_dir"
mkdir -p "$test_dir"
echo "test_payload_data" > "${test_dir}/file1.bin"
SIZE_MEMO_FILE="${LOGS_DIR}/size_memo_ux.tsv"

size1="$(path_size_bytes "$test_dir")"
dd if=/dev/zero of="${test_dir}/file2.bin" bs=1024 count=64 2>/dev/null
size2="$(path_size_bytes_memo "$test_dir")"

if (( size1 > 0 )) && [[ "$size1" == "$size2" ]]; then
    _pass
else
    _fail "path_size_bytes_memo failed size1=${size1}, size2=${size2}"
fi
SIZE_MEMO_FILE=""

begin_test "--explain flag outputs category explanations"
explain_out="$(explain_categories 2>&1)"

if [[ "$explain_out" == *"User Caches"* && "$explain_out" == *"Developer Caches"* && "$explain_out" == *"Xcode Device Support"* ]]; then
    _pass
else
    _fail "--explain output missing key category descriptions: ${explain_out}"
fi

print_test_summary
