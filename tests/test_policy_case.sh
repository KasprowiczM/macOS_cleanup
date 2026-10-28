#!/usr/bin/env bash
# =============================================================================
# tests/test_policy_case.sh — P0-2 remainder: case-insensitive policy lookup
#
# macOS APFS is case-insensitive, so "$HOME/.NPM" is the same object as
# "$HOME/.npm". Policy rule lookup must therefore see a case variant, but
# asymmetrically:
#   - a case-insensitive match may only RAISE risk (apply escalation);
#   - a SAFE rule may lower a REVIEW default only on an exact-case match.
#
# Run directly under stock bash too:  /bin/bash tests/test_policy_case.sh
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_policy_case.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
export USER="${USER:-testuser}"
export LOG_LEVEL="INFO"
export NO_COLOR=1
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
export QUARANTINE_RUN_DIR="${SANDBOX}/quarantine/test_run"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT" "$QUARANTINE_RUN_DIR"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

normalize_never_touch_paths

cleanup() {
    rm -rf "$SANDBOX"
    rm -f "${LOG_FILE:-}"
}
trap cleanup EXIT

# Synthetic policy: an `ask` cache root, an `ask` package cache, and a SAFE
# app cache below the REVIEW root.
policy_reset_rules
policy_add_rule "$HOME/Library/Caches" "ask" "cache" ""
policy_add_rule "$HOME/Library/Caches/com.example.app" "safe" "cache" ""
policy_add_rule "$HOME/.npm" "ask" "cache" ""

write_plan() {
    local dest="$1" ops_json="$2"
    local checksum
    checksum="$(python3 -c 'import hashlib, json, sys
ops = json.loads(sys.argv[1])
print(hashlib.sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()).hexdigest())' "$ops_json")"
    cat > "$dest" <<EOF
{
  "schema_version": "1.0",
  "tool": "cleanup_all.sh",
  "tool_version": "3.0.6",
  "run_id": "test_run",
  "generated_at": "2026-10-28T10:00:00Z",
  "checksum": "${checksum}",
  "summary": {"operations": 0, "safe_operations": 0,
               "review_operations": 0, "dangerous_operations": 0,
               "safe_bytes": 0, "review_bytes": 0, "dangerous_bytes": 0},
  "operations": ${ops_json}
}
EOF
}

reset_apply_state() {
    DRY_RUN=0
    REMOVE_MODE=quarantine
    NON_INTERACTIVE=1
    AUTO_YES=0
    INCLUDE_REVIEW=0
    REQUIRE_TYPING_PATH=0
    rm -f "$CLEANUP_JOURNAL_FILE"
}

safe_op() {
    local id="$1" path="$2"
    printf '[{"id": "%s", "category": "dev", "risk": "SAFE", "action": "remove_path", "path": "%s", "command": "", "estimated_bytes": 4096, "size": 4096, "description": "t", "recommendation": "t"}]' "$id" "$path"
}

# ---------------------------------------------------------------------------
begin_test "policy lookup: case variant of an ask rule is seen as REVIEW"
assert_eq "$(policy_explicit_risk_for_path "$HOME/.NPM")" "REVIEW" ".NPM explicit risk"
assert_eq "$(policy_explicit_risk_for_path "$HOME/.Npm/_cacache")" "REVIEW" ".Npm child explicit risk"
assert_eq "$(policy_adjust_risk_for_path "$HOME/.NPM" "SAFE")" "REVIEW" ".NPM SAFE default is raised"

begin_test "policy lookup: escalation check flags a case-variant SAFE plan op"
assert_true '_plan_path_blocked_or_escalated "$HOME/.NPM" "SAFE"' ".NPM SAFE op escalated"
assert_true '_plan_path_blocked_or_escalated "$HOME/LIBRARY/caches/foo" "SAFE"' "Caches variant SAFE op escalated"
assert_false '_plan_path_blocked_or_escalated "$HOME/.NPM" "REVIEW"' ".NPM REVIEW op is not escalated"

begin_test "policy lookup: case variant is never lowered to SAFE"
assert_eq "$(policy_adjust_risk_for_path "$HOME/Library/Caches/com.example.app" "REVIEW")" "SAFE" \
    "exact-case SAFE rule still lowers REVIEW"
assert_eq "$(policy_adjust_risk_for_path "$HOME/Library/Caches/COM.EXAMPLE.APP" "REVIEW")" "REVIEW" \
    "leaf case variant is not lowered"
assert_eq "$(policy_adjust_risk_for_path "$HOME/library/caches/com.example.app" "REVIEW")" "REVIEW" \
    "parent case variant is not lowered"

begin_test "apply: case-variant SAFE plan op on an ask path is not executed"
reset_apply_state
mkdir -p "$HOME/.npm/_cacache"
dd if=/dev/zero of="$HOME/.npm/_cacache/blob" bs=1024 count=4 2>/dev/null
PLAN1="${SANDBOX}/plan_npm_variant.json"
write_plan "$PLAN1" "$(safe_op op-npm "$HOME/.NPM")"
apply_plan_file "$PLAN1" >/dev/null 2>&1
assert_file_exists "$HOME/.npm/_cacache/blob" "case-variant .NPM must not be removed"
assert_true "grep -q 'plan_apply_blocked' '$CLEANUP_JOURNAL_FILE'" "blocked event journalled"

begin_test "apply: exact-case SAFE plan op on a SAFE rule still runs"
reset_apply_state
mkdir -p "$HOME/Library/Caches/com.example.app"
dd if=/dev/zero of="$HOME/Library/Caches/com.example.app/blob" bs=1024 count=4 2>/dev/null
PLAN2="${SANDBOX}/plan_safe_exact.json"
write_plan "$PLAN2" "$(safe_op op-safe "$HOME/Library/Caches/com.example.app")"
apply_plan_file "$PLAN2" >/dev/null 2>&1
assert_false "test -e '$HOME/Library/Caches/com.example.app/blob'" "exact SAFE op moved to quarantine"

print_test_summary
