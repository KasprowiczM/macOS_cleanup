#!/usr/bin/env bash
# =============================================================================
# tests/test_accounting.sh — Unit tests for Correctness & Accounting Engine [Batch 4]
#
# Validates path claiming deduplication (_CLAIMED_PATHS), sub-path matching,
# split headline accounting (TOTAL_INFORMATIONAL_BYTES), and JSON summary output.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_accounting.XXXXXX)"
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
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/pathguard.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/json_summary.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Setup test directories
mkdir -p "$HOME/Library/Caches/com.spotify.client"
mkdir -p "$HOME/Library/Caches/com.spotify.client/Data"

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

begin_test "Claiming paths prevents duplicate accounting"
reset_claimed_paths

# First claim must succeed
if claim_path "$HOME/Library/Caches/com.spotify.client" 1048576; then
    _pass
else
    _fail "First path claim should succeed"
fi

# Duplicate exact claim must be rejected
if claim_path "$HOME/Library/Caches/com.spotify.client" 1048576; then
    _fail "Duplicate exact claim MUST be rejected"
else
    _pass
fi

# Sub-path claim must be rejected
if claim_path "$HOME/Library/Caches/com.spotify.client/Data" 524288; then
    _fail "Sub-path of claimed parent MUST be rejected"
else
    _pass
fi

begin_test "is_path_claimed helper verification"
if is_path_claimed "$HOME/Library/Caches/com.spotify.client"; then
    _pass
else
    _fail "is_path_claimed should return 0 for claimed path"
fi

if is_path_claimed "$HOME/Library/Caches/com.spotify.client/Data/file.cache"; then
    _pass
else
    _fail "is_path_claimed should return 0 for sub-path of claimed parent"
fi

if is_path_claimed "$HOME/Library/Caches/unclaimed_app"; then
    _fail "is_path_claimed should return 1 for unclaimed path"
else
    _pass
fi

begin_test "reset_claimed_paths clears registry"
reset_claimed_paths
if is_path_claimed "$HOME/Library/Caches/com.spotify.client"; then
    _fail "reset_claimed_paths should clear claimed registry"
else
    _pass
fi

begin_test "Split headline accounting: TOTAL_INFORMATIONAL_BYTES"
TOTAL_INFORMATIONAL_BYTES=0
add_informational_bytes 4096
add_informational_bytes 8192

if (( TOTAL_INFORMATIONAL_BYTES == 12288 )); then
    _pass
else
    _fail "TOTAL_INFORMATIONAL_BYTES should equal 12288, got ${TOTAL_INFORMATIONAL_BYTES}"
fi

begin_test "JSON summary includes informational_bytes counter"
json_out="$(emit_json_summary "dry-run")"
if [[ "$json_out" == *"\"informational_bytes\":"* ]]; then
    _pass
else
    _fail "emit_json_summary JSON output MUST contain informational_bytes key"
fi

begin_test "Analyzer category order & claiming prevents app-cache double counting"
reset_claimed_paths
FOUND_USER_CACHES=()
FOUND_APP_CACHE_ITEMS=()

mkdir -p "$HOME/Library/Caches/com.spotify.client"
dd if=/dev/zero of="$HOME/Library/Caches/com.spotify.client/cache.dat" bs=1024 count=50 2>/dev/null

mkdir -p "$HOME/Library/Caches/com.generic.app"
dd if=/dev/zero of="$HOME/Library/Caches/com.generic.app/data.dat" bs=1024 count=20 2>/dev/null

run_full_analysis "user-caches" >/dev/null 2>&1

spotify_in_user=0
for item in "${FOUND_USER_CACHES[@]}"; do
    [[ "$item" == *"/com.spotify.client"* ]] && spotify_in_user=1
done

spotify_in_app=0
for item in "${FOUND_APP_CACHE_ITEMS[@]}"; do
    [[ "$item" == *"/com.spotify.client"* ]] && spotify_in_app=1
done

if [[ "$spotify_in_app" -eq 1 && "$spotify_in_user" -eq 0 ]]; then
    _pass
else
    _fail "com.spotify.client claimed twice or misplaced: in_app=${spotify_in_app}, in_user=${spotify_in_user}"
fi

print_test_summary
