#!/usr/bin/env bash
# =============================================================================
# tests/test_plan_policy_parity.sh — Plan vs Policy Risk Parity Tests [G17]
#
# Verifies that every path-based operation generated in a plan matches the
# risk level returned by policy_adjust_risk_for_path(path), preventing apply-time
# risk escalation blocks.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_plan_policy_parity.XXXXXX)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
export LOG_LEVEL="INFO"
export NO_COLOR=1

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
RULES_FILE="${PROJ_DIR}/cleanup_rules.yaml"
load_policy_rules_from_yaml
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/pathguard.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/json_summary.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# 1. Populate fixture items across categories
FOUND_APP_LOGS+=("$HOME/Library/Logs/TestApp/test.log")
FOUND_APP_CACHE_ITEMS+=("Spotify (Cache):$HOME/Library/Caches/com.spotify.client")
FOUND_DEV_ITEMS+=("cargo_cache:$HOME/.cargo/registry/cache")
FOUND_DMG_PKG+=("$HOME/Downloads/installer.dmg")

# 2. Run plan generation
build_cleanup_plan_from_analysis

PLAN_FILE="${REPORTS_DIR}/plan_test.json"
generate_plan_json "$PLAN_FILE" >/dev/null 2>&1

begin_test "G17: Every plan path risk matches policy_adjust_risk_for_path"
_py_script='
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for op in data.get("operations", []):
    path = op.get("path", "")
    risk = op.get("risk", "")
    action = op.get("action", "")
    op_id = op.get("id", "")
    if path and action in ("remove_path", "report_only"):
        print(op_id + "\t" + risk + "\t" + path)
'
while IFS=$'\t' read -r op_id plan_risk path; do
    expected_risk="$(policy_adjust_risk_for_path "$path" "$plan_risk")"
    if [[ "$plan_risk" == "$expected_risk" ]]; then
        _pass
    else
        _fail "Plan ${op_id} risk mismatch for ${path}: plan=${plan_risk}, expected=${expected_risk}"
    fi
done < <(python3 -c "$_py_script" "$PLAN_FILE")

begin_test "G17: Apply plan and assert zero risk escalated warnings"
APPLY_OUT="$(INCLUDE_REVIEW=1 NON_INTERACTIVE=1 apply_plan_file "$PLAN_FILE" 2>&1 || true)"
if echo "$APPLY_OUT" | grep -q "risk escalated"; then
    _fail "apply_plan_file contained 'risk escalated' warnings: ${APPLY_OUT}"
else
    _pass
fi

echo "-----------------------------------------------------------"
echo "Pass: ${TESTS_PASS}   Fail: ${TESTS_FAIL}"
echo "-----------------------------------------------------------"
(( TESTS_FAIL == 0 ))
