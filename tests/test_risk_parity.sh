#!/usr/bin/env bash
# =============================================================================
# tests/test_risk_parity.sh — Unit tests for Risk Parity & Informed Consent [P0-1c, P1-5, P1-6]
#
# Validates that HIGH and MEDIUM risk categories are NEVER auto-confirmed
# by --yes / AUTO_YES=1 in non-interactive mode, and validates consequence warnings.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_risk_parity.XXXXXX)"
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

begin_test "consequence_for_mode output format"
c_low_q="$(consequence_for_mode "LOW" "quarantine")"
c_low_p="$(consequence_for_mode "LOW" "permanent")"
c_med_p="$(consequence_for_mode "MEDIUM" "permanent")"
c_high_p="$(consequence_for_mode "HIGH" "permanent")"

if [[ "$c_low_q" == *"kwarantanny"* ]] && [[ "$c_low_p" == *"usunięte"* ]]; then
    _pass
else
    _fail "LOW risk consequence strings invalid"
fi

if [[ "$c_med_p" == *"ŚREDNIE RYZYKO"* ]]; then
    _pass
else
    _fail "MEDIUM risk consequence should mention ŚREDNIE RYZYKO"
fi

if [[ "$c_high_p" == *"WYSOKIE RYZYKO"* ]]; then
    _pass
else
    _fail "HIGH risk consequence should mention WYSOKIE RYZYKO"
fi

begin_test "AUTO_YES=1 in non-interactive mode only auto-approves LOW risk"
export NON_INTERACTIVE=1
export AUTO_YES=1

# LOW risk should return 0 (approved)
if confirm_category --title "Safe User Cache" --size "10 MB" --risk "LOW"; then
    _pass
else
    _fail "AUTO_YES=1 should approve LOW risk category"
fi

# MEDIUM risk should return 1 (blocked/skipped)
if confirm_category --title "Old Downloads" --size "500 MB" --risk "MEDIUM"; then
    _fail "AUTO_YES=1 MUST NOT approve MEDIUM risk category"
else
    _pass
fi

# HIGH risk should return 1 (blocked/skipped)
if confirm_category --title "Xcode DeviceSupport" --size "12 GB" --risk "HIGH"; then
    _fail "AUTO_YES=1 MUST NOT approve HIGH risk category"
else
    _pass
fi

begin_test "AUTO_YES=0 in non-interactive mode rejects ALL risk levels"
export NON_INTERACTIVE=1
export AUTO_YES=0

if confirm_category --title "Safe Cache" --size "10 MB" --risk "LOW"; then
    _fail "AUTO_YES=0 should not approve LOW risk category"
else
    _pass
fi

if confirm_category --title "Old Logs" --size "50 MB" --risk "MEDIUM"; then
    _fail "AUTO_YES=0 should not approve MEDIUM risk category"
else
    _pass
fi

if confirm_category --title "Docker System Prune" --size "5 GB" --risk "HIGH"; then
    _fail "AUTO_YES=0 should not approve HIGH risk category"
else
    _pass
fi

print_test_summary
