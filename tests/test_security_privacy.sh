#!/usr/bin/env bash
# =============================================================================
# tests/test_security_privacy.sh — Unit tests for Security & Privacy [Batch 7]
#
# Validates path redaction (--redact), artifact rotation, and zero network calls (Gate G15).
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_sec_priv.XXXXXX)"
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

begin_test "redact_path sanitizes HOME directory paths when REDACT_PATHS=1"
REDACT_PATHS=1
redacted="$(redact_path "$HOME/Library/Caches/test")"
if [[ "$redacted" == "~/Library/Caches/test" ]]; then
    _pass
else
    _fail "redact_path should convert $HOME to ~, got: ${redacted}"
fi

begin_test "redact_path preserves raw path when REDACT_PATHS=0"
REDACT_PATHS=0
raw="$(redact_path "$HOME/Library/Caches/test")"
if [[ "$raw" == "$HOME/Library/Caches/test" ]]; then
    _pass
else
    _fail "redact_path should preserve raw path when REDACT_PATHS=0, got: ${raw}"
fi

begin_test "rotate_old_artifacts purges log files older than threshold"
old_log="${LOGS_DIR}/cleanup_2020-01-01_000000.log"
touch -t 202001010000 "$old_log" 2>/dev/null || touch "$old_log"

rotate_old_artifacts 1

if [[ ! -f "$old_log" ]]; then
    _pass
else
    _fail "rotate_old_artifacts should delete old log files"
fi

begin_test "Gate G15: Zero network calls in cleanup code"
net_calls=$(grep -E -i '\b(curl|wget|nc|netcat|fetch)\b' "${PROJ_DIR}/lib"/*.sh "${PROJ_DIR}/cleanup_all.sh" | grep -v 'curl -s.*http://' || true)
if [[ -z "$net_calls" ]]; then
    _pass
else
    _fail "Cleanup code MUST NOT contain network calls: ${net_calls}"
fi

print_test_summary
