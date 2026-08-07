#!/usr/bin/env bash
# =============================================================================
# tests/test_risk_parity.sh — Unit tests for Risk Parity & Informed Consent [P0-1c, P1-5, P1-6]
#
# Validates that DANGEROUS and REVIEW risk categories are NEVER auto-confirmed
# by --yes / AUTO_YES=1 in non-interactive mode, validates consequence warnings,
# category_max_risk calculation, and parity between planner policy and cleaner prompts.
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
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

begin_test "consequence_for_mode output format"
c_safe_q="$(consequence_for_mode "SAFE" "quarantine")"
c_safe_p="$(consequence_for_mode "SAFE" "permanent")"
c_rev_p="$(consequence_for_mode "REVIEW" "permanent")"
c_dang_p="$(consequence_for_mode "DANGEROUS" "permanent")"

if [[ "$c_safe_q" == *"kwarantanny"* ]] && [[ "$c_safe_p" == *"usunięte"* ]]; then
    _pass
else
    _fail "SAFE risk consequence strings invalid"
fi

if [[ "$c_rev_p" == *"RYZYKO REVIEW"* ]]; then
    _pass
else
    _fail "REVIEW risk consequence should mention RYZYKO REVIEW"
fi

if [[ "$c_dang_p" == *"RYZYKO DANGEROUS"* ]]; then
    _pass
else
    _fail "DANGEROUS risk consequence should mention RYZYKO DANGEROUS"
fi

begin_test "AUTO_YES=1 in non-interactive mode only auto-approves SAFE risk"
export NON_INTERACTIVE=1
export AUTO_YES=1

# SAFE risk should return 0 (approved)
if confirm_category --title "Safe User Cache" --size "10 MB" --risk "SAFE"; then
    _pass
else
    _fail "AUTO_YES=1 should approve SAFE risk category"
fi

# REVIEW risk should return 1 (blocked/skipped)
if confirm_category --title "Old Downloads" --size "500 MB" --risk "REVIEW"; then
    _fail "AUTO_YES=1 MUST NOT approve REVIEW risk category"
else
    _pass
fi

# DANGEROUS risk should return 1 (blocked/skipped)
if confirm_category --title "System Critical Path" --size "12 GB" --risk "DANGEROUS"; then
    _fail "AUTO_YES=1 MUST NOT approve DANGEROUS risk category"
else
    _pass
fi

begin_test "AUTO_YES=0 in non-interactive mode rejects ALL risk levels"
export NON_INTERACTIVE=1
export AUTO_YES=0

if confirm_category --title "Safe Cache" --size "10 MB" --risk "SAFE"; then
    _fail "AUTO_YES=0 should not approve SAFE risk category"
else
    _pass
fi

if confirm_category --title "Old Logs" --size "50 MB" --risk "REVIEW"; then
    _fail "AUTO_YES=0 should not approve REVIEW risk category"
else
    _pass
fi

if confirm_category --title "Docker System Prune" --size "5 GB" --risk "DANGEROUS"; then
    _fail "AUTO_YES=0 should not approve DANGEROUS risk category"
else
    _pass
fi

begin_test "category_max_risk returns highest risk across paths"
risk_single="$(category_max_risk "$HOME/Library/Caches/test.cache")"
risk_mixed="$(category_max_risk "$HOME/Library/Caches/test.cache" "/System/Library/CoreServices")"

if [[ "$risk_single" == "REVIEW" || "$risk_single" == "SAFE" ]]; then
    _pass
else
    _fail "Expected SAFE or REVIEW for user cache path, got $risk_single"
fi

if [[ "$risk_mixed" == "DANGEROUS" ]]; then
    _pass
else
    _fail "Expected DANGEROUS for path containing system protected directory, got $risk_mixed"
fi

begin_test "Cleaner category prompts match category_max_risk policy evaluation"
# Seed test items
FOUND_TRASH_ITEMS=("$HOME/.Trash/testfile")
mkdir -p "$HOME/.Trash"
touch "$HOME/.Trash/testfile"
catbytes_set "trash" 1024

# Setup mock confirm_category recorder
RECORDED_PROMPT_TITLES=()
RECORDED_PROMPT_RISKS=()

confirm_category() {
    local p_title="" p_risk="REVIEW"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title) p_title="$2"; shift 2 ;;
            --risk)  p_risk="$2";  shift 2 ;;
            *) shift ;;
        esac
    done
    RECORDED_PROMPT_TITLES+=("$p_title")
    RECORDED_PROMPT_RISKS+=("$p_risk")
    return 1 # skip cleanup execution in test
}

export MODE="interactive"
clean_trash

if [[ ${#RECORDED_PROMPT_RISKS[@]} -eq 1 ]]; then
    expected_risk="$(category_max_risk "${FOUND_TRASH_ITEMS[@]}")"
    actual_risk="${RECORDED_PROMPT_RISKS[0]}"
    if [[ "$actual_risk" == "$expected_risk" ]]; then
        _pass
    else
        _fail "Parity fail: expected cleaner prompt risk '$expected_risk', got '$actual_risk'"
    fi
else
    _fail "Cleaner failed to trigger confirm_category prompt"
fi

print_test_summary
