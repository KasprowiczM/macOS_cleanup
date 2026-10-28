#!/usr/bin/env bash
# =============================================================================
# tests/test_runtime_config_validation.sh — P0-3 regression lock
#
# REMOVE_MODE must be exactly quarantine|permanent: a typo ("quarentine") used
# to fall through to permanent deletion. QUARANTINE_ROOT must be an absolute
# ".../quarantine" directory: with QUARANTINE_ROOT=$HOME, `--purge-quarantine
# all --apply` treated every directory directly under HOME as a run to rm -rf.
#
# Run directly under stock bash too:  /bin/bash tests/test_runtime_config_validation.sh
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"

# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_test_runtime_cfg.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

CASE_N=0
CASE=""

new_case() {
    CASE_N=$(( CASE_N + 1 ))
    CASE="${SANDBOX}/case${CASE_N}"
    mkdir -p "${CASE}/home/Library/Caches" "${CASE}/home/Documents" "${CASE}/logs" "${CASE}/reports" "${CASE}/quarantine"
    printf 'keep\n' > "${CASE}/home/Documents/precious.txt"
}

# Usage: run_cli <remove_mode> <quarantine_root> <args...>; echoes the exit code.
run_cli() {
    local remove_mode="$1" qroot="$2" rc=0
    shift 2
    env HOME="${CASE}/home" USER="${USER:-tester}" LOG_LEVEL="INFO" NO_COLOR=1 \
        LOGS_DIR="${CASE}/logs" REPORTS_DIR="${CASE}/reports" \
        CLEANUP_JOURNAL_FILE="${CASE}/reports/journal_test.jsonl" \
        CLEANUP_RESTORE_MANIFEST="${CASE}/reports/restore_test.tsv" \
        REMOVE_MODE="$remove_mode" QUARANTINE_ROOT="$qroot" \
        "$BASH" "$SCRIPT_PATH" "$@" >"${CASE}/out" 2>&1 </dev/null || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
begin_test "P0-3: unknown REMOVE_MODE is rejected at startup (exit 2)"
new_case
assert_eq "$(run_cli quarentine "${CASE}/quarantine" --list-quarantine --non-interactive)" "2" "typo REMOVE_MODE must exit 2"
assert_eq "$(run_cli Permanent "${CASE}/quarantine" --list-quarantine --non-interactive)" "2" "REMOVE_MODE is matched exactly"

begin_test "P0-3: valid REMOVE_MODE values are accepted"
new_case
assert_eq "$(run_cli quarantine "${CASE}/quarantine" --list-quarantine --non-interactive)" "0" "quarantine accepted"
assert_eq "$(run_cli permanent "${CASE}/quarantine" --list-quarantine --non-interactive)" "0" "permanent accepted"
# defaults.sh maps an empty value to the quarantine default (the safe direction).
assert_eq "$(run_cli "" "${CASE}/quarantine" --list-quarantine --non-interactive)" "0" "empty REMOVE_MODE falls back to quarantine"

# ---------------------------------------------------------------------------
begin_test "P0-3: QUARANTINE_ROOT=\$HOME cannot purge home directories"
new_case
RC="$(run_cli quarantine "${CASE}/home" --purge-quarantine all --apply --non-interactive)"
assert_eq "$RC" "2" "QUARANTINE_ROOT=HOME must be rejected with exit 2"
assert_file_exists "${CASE}/home/Documents/precious.txt" "HOME children must survive a misconfigured purge"
assert_true "[ -d '${CASE}/home/Library/Caches' ]" "HOME/Library must survive a misconfigured purge"

begin_test "P0-3: QUARANTINE_ROOT must be absolute and named quarantine"
new_case
assert_eq "$(run_cli quarantine "relative/quarantine" --list-quarantine --non-interactive)" "2" "relative root rejected"
assert_eq "$(run_cli quarantine "/" --list-quarantine --non-interactive)" "2" "root / rejected"
assert_eq "$(run_cli quarantine "${CASE}/quarantine/../home" --list-quarantine --non-interactive)" "2" "dot-dot escape rejected"

# ---------------------------------------------------------------------------
# Library-level fail-closed checks (callers that bypass cleanup_all.sh startup)
# ---------------------------------------------------------------------------
run_lib() {
    local remove_mode="$1" qroot="$2" snippet="$3"
    shift 3
    env HOME="${CASE}/home" USER="${USER:-tester}" LOG_LEVEL="INFO" NO_COLOR=1 \
        LOGS_DIR="${CASE}/logs" REPORTS_DIR="${CASE}/reports" \
        CLEANUP_JOURNAL_FILE="${CASE}/reports/journal_test.jsonl" \
        CLEANUP_RESTORE_MANIFEST="${CASE}/reports/restore_test.tsv" \
        QUARANTINE_ROOT="$qroot" PROJ_DIR="$PROJ_DIR" \
        "$BASH" -c 'set -u
source "${PROJ_DIR}/config/defaults.sh"
source "${PROJ_DIR}/lib/common.sh"
DRY_RUN=0
REMOVE_MODE="$1"; shift
'"$snippet" _ "$remove_mode" "$@" >/dev/null 2>&1
}

begin_test "P0-3: safe_remove fails closed on an unknown REMOVE_MODE"
new_case
mkdir -p "${CASE}/home/Library/Caches/com.example.p03"
printf 'x\n' > "${CASE}/home/Library/Caches/com.example.p03/blob.bin"
run_lib quarentine "${CASE}/quarantine" 'safe_remove "$1"' "${CASE}/home/Library/Caches/com.example.p03"
assert_file_exists "${CASE}/home/Library/Caches/com.example.p03/blob.bin" "typo REMOVE_MODE must not delete"

begin_test "P0-3: purge_quarantine refuses a non-quarantine root"
new_case
run_lib quarantine "${CASE}/home" 'purge_quarantine all 1'
assert_file_exists "${CASE}/home/Documents/precious.txt" "purge must refuse QUARANTINE_ROOT=HOME"

print_test_summary
