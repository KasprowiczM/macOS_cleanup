#!/usr/bin/env bash
# =============================================================================
# tests/test_json_summary.sh — unit + integration tests for --json flag
# =============================================================================
# Tests:
#   1. emit_json_summary produces valid JSON (python3 -m json.tool round-trip)
#   2. Required top-level keys are present
#   3. dry_run field reflects DRY_RUN variable
#   4. plan counters flow from generate_plan_json → emit_json_summary
#   5. Human-readable output is suppressed on stdout; JSON goes to stdout
#   6. Edge: --json with empty category list still produces valid JSON
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_test_json.XXXXXX)"
export HOME="$SANDBOX"
export LOG_LEVEL="INFO"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/json_summary.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"


cleanup() {
    rm -rf "$SANDBOX"
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

reset_summary_state() {
    TOTAL_WOULD_FREE_BYTES=0
    TOTAL_CLEANED_BYTES=0
    TOTAL_QUARANTINED_BYTES=0
    TOTAL_QUARANTINED_ITEMS=0
    TOTAL_RESTORED_BYTES=0
    TOTAL_RESTORED_ITEMS=0
    TOTAL_SKIPPED_ITEMS=0
    TOTAL_USER_DECISIONS_NEEDED=0
    USER_DECISION_ITEMS=()
    WARNINGS_LIST=()
    MODE="dry-run"
    DRY_RUN=1
    REMOVE_MODE="quarantine"
    ACTIVE_CATEGORIES=("trash")
    json_summary_record_plan 0 0 0 0 0 0 0
}

json_valid() {
    python3 -c "import sys, json; json.load(sys.stdin)" < "$1"
}

run_cmd_capture() {
    local out_file="$1"; shift
    set +e
    "$@" > "$out_file" 2>&1
    local rc=$?
    set -u
    echo "$rc"
}

# ---------------------------------------------------------------------------
# TC1: emit_json_summary produces valid JSON
# ---------------------------------------------------------------------------
begin_test "emit_json_summary produces valid JSON"
reset_summary_state
TOTAL_WOULD_FREE_BYTES=102400
catbytes_set "trash" "102400"
JSON_OUT="$(mktemp -t json_summary_tc1.XXXXXX)"
emit_json_summary "dry-run" > "$JSON_OUT"
assert_true "json_valid \"$JSON_OUT\"" "JSON output must be valid JSON"
rm -f "$JSON_OUT"

# ---------------------------------------------------------------------------
# TC2: Required top-level keys are present
# ---------------------------------------------------------------------------
begin_test "JSON summary contains required top-level keys"
reset_summary_state
JSON_OUT="$(mktemp -t json_summary_tc2.XXXXXX)"
emit_json_summary "dry-run" > "$JSON_OUT"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert 'schema_version' in d\" 2>/dev/null" "schema_version present"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert 'tool' in d\" 2>/dev/null" "tool present"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert 'run_id' in d\" 2>/dev/null" "run_id present"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert 'mode' in d\" 2>/dev/null" "mode present"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert 'counters' in d\" 2>/dev/null" "counters present"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert 'plan' in d\" 2>/dev/null" "plan present"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert 'artifacts' in d\" 2>/dev/null" "artifacts present"
rm -f "$JSON_OUT"

# ---------------------------------------------------------------------------
# TC3: dry_run field reflects DRY_RUN variable
# ---------------------------------------------------------------------------
begin_test "JSON dry_run=true when DRY_RUN=1"
reset_summary_state
DRY_RUN=1
JSON_OUT="$(mktemp -t json_summary_tc3a.XXXXXX)"
emit_json_summary "dry-run" > "$JSON_OUT"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['dry_run'] is True\" 2>/dev/null" "dry_run should be true"
rm -f "$JSON_OUT"

begin_test "JSON dry_run=false when DRY_RUN=0"
reset_summary_state
DRY_RUN=0
JSON_OUT="$(mktemp -t json_summary_tc3b.XXXXXX)"
emit_json_summary "apply-plan" > "$JSON_OUT"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['dry_run'] is False\" 2>/dev/null" "dry_run should be false"
rm -f "$JSON_OUT"

# ---------------------------------------------------------------------------
# TC4: plan counters flow from json_summary_record_plan → emit_json_summary
# ---------------------------------------------------------------------------
begin_test "plan counters present in JSON when json_summary_record_plan is called"
reset_summary_state
json_summary_record_plan 10 7 2 1 512000 204800 102400
JSON_OUT="$(mktemp -t json_summary_tc4.XXXXXX)"
emit_json_summary "plan" > "$JSON_OUT"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['plan']['operations']==10\" 2>/dev/null" "plan.operations=10"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['plan']['safe_operations']==7\" 2>/dev/null" "plan.safe_operations=7"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['plan']['review_operations']==2\" 2>/dev/null" "plan.review_operations=2"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['plan']['dangerous_operations']==1\" 2>/dev/null" "plan.dangerous_operations=1"
rm -f "$JSON_OUT"

# ---------------------------------------------------------------------------
# TC5: counters reflected accurately
# ---------------------------------------------------------------------------
begin_test "counters accurately reflect global state"
reset_summary_state
TOTAL_WOULD_FREE_BYTES=999888
TOTAL_SKIPPED_ITEMS=3
TOTAL_USER_DECISIONS_NEEDED=2
JSON_OUT="$(mktemp -t json_summary_tc5.XXXXXX)"
emit_json_summary "dry-run" > "$JSON_OUT"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['counters']['would_free_bytes']==999888\" 2>/dev/null" "would_free_bytes=999888"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['counters']['skipped_items']==3\" 2>/dev/null" "skipped_items=3"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_OUT}')); assert d['counters']['user_decisions_needed']==2\" 2>/dev/null" "user_decisions_needed=2"
rm -f "$JSON_OUT"

# ---------------------------------------------------------------------------
# TC6: --json integration — stdout is valid JSON; return code is 0
# ---------------------------------------------------------------------------
begin_test "--json dry-run integration: stdout is valid JSON"
JSON_CAPTURE="$(mktemp -t json_summary_tc6.XXXXXX)"
# Capture only stdout (the JSON); stderr gets the human output
RC=$(set +e; env HOME="$SANDBOX" bash "$SCRIPT_PATH" --dry-run --non-interactive --json --category trash --no-color > "$JSON_CAPTURE" 2>/dev/null; echo $?)
assert_eq "$RC" "0" "--json exits 0"
assert_true "json_valid \"$JSON_CAPTURE\"" "--json stdout is valid JSON"
assert_true "python3 -c \"import json; d=json.load(open('${JSON_CAPTURE}')); assert d['mode']=='dry-run'\" 2>/dev/null" "mode=dry-run in JSON"
rm -f "$JSON_CAPTURE"

# ---------------------------------------------------------------------------
# TC7: --json suppresses human output from stdout (only JSON on stdout)
# ---------------------------------------------------------------------------
begin_test "--json suppresses human-readable output from stdout"
JSON_CAPTURE="$(mktemp -t json_summary_tc7.XXXXXX)"
env HOME="$SANDBOX" bash "$SCRIPT_PATH" --dry-run --non-interactive --json --category trash --no-color > "$JSON_CAPTURE" 2>/dev/null
# stdout must be valid JSON — specifically, it must start with "{"
FIRST_CHAR="$(head -c1 "$JSON_CAPTURE")"
assert_eq "$FIRST_CHAR" "{" "stdout must start with '{' not human text"
# confirm no ANSI banner in stdout
assert_false "grep -q 'FAZA' \"$JSON_CAPTURE\"" "human text (FAZA) must not appear in stdout"
rm -f "$JSON_CAPTURE"

# ---------------------------------------------------------------------------
# TC8: Edge — valid JSON with empty active categories
# ---------------------------------------------------------------------------
begin_test "emit_json_summary is valid JSON with empty ACTIVE_CATEGORIES"
reset_summary_state
ACTIVE_CATEGORIES=()
JSON_OUT="$(mktemp -t json_summary_tc8.XXXXXX)"
emit_json_summary "dry-run" > "$JSON_OUT"
assert_true "json_valid \"$JSON_OUT\"" "empty categories still produces valid JSON"
rm -f "$JSON_OUT"

print_test_summary
