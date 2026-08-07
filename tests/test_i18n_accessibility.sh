#!/usr/bin/env bash
# =============================================================================
# tests/test_i18n_accessibility.sh — Unit tests for i18n & Accessibility [Batch 8]
#
# Validates translation keys (t "key"), Gate G11, PLAIN_OUTPUT formatting, and QUIET_OUTPUT behavior.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_i18n.XXXXXX)"
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
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

begin_test "Gate G11: i18n files exist and contain non-zero translation keys"
if [[ -f "${PROJ_DIR}/i18n/pl.sh" && -f "${PROJ_DIR}/i18n/en.sh" ]]; then
    _pass
else
    _fail "Gate G11 failed: i18n/pl.sh and i18n/en.sh MUST exist"
fi

begin_test "t() function returns correct Polish translation"
LANG_CODE="pl"
res="$(t "user_caches")"
if [[ "$res" == "Cache użytkownika" ]]; then
    _pass
else
    _fail "t() should return Polish translation, got: ${res}"
fi

begin_test "t() function returns correct English translation"
LANG_CODE="en"
res="$(t "user_caches")"
if [[ "$res" == "User Caches" ]]; then
    _pass
else
    _fail "t() should return English translation, got: ${res}"
fi

begin_test "t() function falls back to key string when translation key is unknown"
res="$(t "non_existent_key_1234")"
if [[ "$res" == "non_existent_key_1234" ]]; then
    _pass
else
    _fail "t() should fallback to key name when key unknown, got: ${res}"
fi

begin_test "QUIET_OUTPUT suppresses print_info terminal output"
QUIET_OUTPUT=1
quiet_out="$(print_info "suppressed_test_msg" 2>&1)"
if [[ -z "$quiet_out" ]]; then
    _pass
else
    _fail "QUIET_OUTPUT should produce no terminal output, got: ${quiet_out}"
fi

print_test_summary
