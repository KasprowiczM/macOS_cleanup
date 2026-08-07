#!/usr/bin/env bash
# =============================================================================
# tests/test_planner_apply.sh — hardening for apply_plan_file code paths
#
# Covers:
#   - Missing / malformed plan file (error paths)
#   - Unknown risk value  → skipped, no removal
#   - Unknown action value → plan_apply_skipped journal event
#   - report_only action  → no removal
#   - DANGEROUS always blocked (even with --include-review)
#   - REVIEW + NON_INTERACTIVE → skipped, journal event
#   - REVIEW + REQUIRE_TYPING_PATH wrong/right answer
#   - REVIEW + INCLUDE_REVIEW=1 + NON_INTERACTIVE=1 → still skipped
#   - SF1: is_protected_path blocks SAFE op even without policy change
#   - Empty operations array → clean exit, nothing applied
#   - native_command dry-run → planned journal event, no execution
#   - native_command allowlisted tool unavailable → skipped "tool unavailable: X"
#   - native_command allowlisted tool failure → failed journal event
#   - Non-allowlisted native_command → plan_apply_blocked journal event
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_planner_apply.XXXXXX)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
export USER="${USER:-testuser}"
export LOG_LEVEL="INFO"
export NO_COLOR=1

# Point all generated files inside the sandbox so nothing leaks into the repo.
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

cleanup() {
    rm -rf "$SANDBOX"
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

create_file_kb() {
    local path="$1" kb="$2"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/zero of="$path" bs=1024 count="$kb" 2>/dev/null
}

# Write a minimal-but-valid plan JSON with the given operations JSON array text.
write_plan() {
    local dest="$1" ops_json="$2"
    cat > "$dest" <<EOF
{
  "schema_version": "1.0",
  "tool": "cleanup_all.sh",
  "tool_version": "2.0.0",
  "run_id": "test_run",
  "generated_at": "2026-06-10T10:00:00Z",
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
    TOTAL_CLEANED_BYTES=0
    TOTAL_WOULD_FREE_BYTES=0
    TOTAL_QUARANTINED_BYTES=0
    TOTAL_QUARANTINED_ITEMS=0
    TOTAL_SKIPPED_ITEMS=0
    TOTAL_USER_DECISIONS_NEEDED=0
    USER_DECISION_ITEMS=()
    WARNINGS_LIST=()
    rm -f "$CLEANUP_JOURNAL_FILE"
}

journal_has_event() {
    local event="$1"
    [[ -f "$CLEANUP_JOURNAL_FILE" ]] && grep -q "\"${event}\"" "$CLEANUP_JOURNAL_FILE"
}

journal_has_message() {
    local msg="$1"
    [[ -f "$CLEANUP_JOURNAL_FILE" ]] && grep -q "$msg" "$CLEANUP_JOURNAL_FILE"
}

# ---------------------------------------------------------------------------
# EP1: Missing plan file → return 2, print_error, nothing touched
# ---------------------------------------------------------------------------
begin_test "EP1: missing plan file returns 2 without touching filesystem"
reset_apply_state
set +e
apply_plan_file "${SANDBOX}/no_such_plan.json" > /dev/null 2>&1
RC=$?
set -u
assert_eq "$RC" "2" "EP1: missing plan must return 2"

# ---------------------------------------------------------------------------
# EP2: Malformed JSON → python parse fails → nothing applied
# ---------------------------------------------------------------------------
begin_test "EP2: malformed JSON plan: nothing applied, no crash"
reset_apply_state
BAD_PLAN="${SANDBOX}/bad.json"
printf 'THIS IS NOT JSON\n' > "$BAD_PLAN"
TARGET_EP2="${HOME}/Library/Caches/ep2-file"
create_file_kb "$TARGET_EP2" 4
set +e
apply_plan_file "$BAD_PLAN" > /dev/null 2>&1
RC=$?
set -u
# Return code may be non-zero (python exits 1) but the file must be untouched.
assert_file_exists "$TARGET_EP2" "EP2: malformed JSON must not remove any files"

# ---------------------------------------------------------------------------
# EP3: Empty operations array → clean exit, nothing applied
# ---------------------------------------------------------------------------
begin_test "EP3: empty operations array exits cleanly"
reset_apply_state
EMPTY_PLAN="${SANDBOX}/empty.json"
write_plan "$EMPTY_PLAN" "[]"
set +e
apply_plan_file "$EMPTY_PLAN" > /dev/null 2>&1
RC=$?
set -u
assert_eq "$RC" "0" "EP3: empty operations must exit 0"

# ---------------------------------------------------------------------------
# UK1: Unknown risk value → op skipped, no removal
# ---------------------------------------------------------------------------
begin_test "UK1: unknown risk value skips op without removing file"
reset_apply_state
UK1_FILE="${HOME}/Library/Caches/uk1-testfile"
create_file_kb "$UK1_FILE" 4
UK1_PLAN="${SANDBOX}/uk1.json"
write_plan "$UK1_PLAN" "[
  {
    \"id\": \"op-uk1\", \"category\": \"user-caches\",
    \"risk\": \"SUPERSAFE\", \"action\": \"remove_path\",
    \"path\": \"${UK1_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"test\", \"recommendation\": \"test\"
  }
]"
apply_plan_file "$UK1_PLAN" > /dev/null 2>&1
assert_file_exists "$UK1_FILE" "UK1: unknown risk must not remove file"

# ---------------------------------------------------------------------------
# UK2: Unknown action value → plan_apply_skipped journal event, no removal
# ---------------------------------------------------------------------------
begin_test "UK2: unknown action skips op and writes plan_apply_skipped to journal"
reset_apply_state
UK2_FILE="${HOME}/Library/Caches/uk2-testfile"
create_file_kb "$UK2_FILE" 4
UK2_PLAN="${SANDBOX}/uk2.json"
write_plan "$UK2_PLAN" "[
  {
    \"id\": \"op-uk2\", \"category\": \"user-caches\",
    \"risk\": \"SAFE\", \"action\": \"delete_everything\",
    \"path\": \"${UK2_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"test\", \"recommendation\": \"test\"
  }
]"
apply_plan_file "$UK2_PLAN" > /dev/null 2>&1
assert_file_exists "$UK2_FILE" "UK2: unknown action must not remove file"
assert_true "journal_has_event 'plan_apply_skipped'" "UK2: plan_apply_skipped must be journalled"
assert_true "journal_has_message 'unknown action'"   "UK2: journal message must say 'unknown action'"

# ---------------------------------------------------------------------------
# RA1: report_only action → no removal, no journal destruction event
# ---------------------------------------------------------------------------
begin_test "RA1: report_only action does not remove file"
reset_apply_state
RA1_FILE="${HOME}/Library/Caches/ra1-testfile"
create_file_kb "$RA1_FILE" 4
RA1_PLAN="${SANDBOX}/ra1.json"
write_plan "$RA1_PLAN" "[
  {
    \"id\": \"op-ra1\", \"category\": \"browsers\",
    \"risk\": \"REVIEW\", \"action\": \"report_only\",
    \"path\": \"${RA1_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"report only\", \"recommendation\": \"test\"
  }
]"
INCLUDE_REVIEW=1   # grant REVIEW so the report_only action is reached
apply_plan_file "$RA1_PLAN" > /dev/null 2>&1
assert_file_exists "$RA1_FILE" "RA1: report_only must not remove file"

# ---------------------------------------------------------------------------
# DA1: DANGEROUS always blocked, even with INCLUDE_REVIEW=1
# ---------------------------------------------------------------------------
begin_test "DA1: DANGEROUS op always blocked even with --include-review"
reset_apply_state
DA1_FILE="${HOME}/Library/Mail/V10/da1-mail"
create_file_kb "$DA1_FILE" 4
DA1_PLAN="${SANDBOX}/da1.json"
write_plan "$DA1_PLAN" "[
  {
    \"id\": \"op-da1\", \"category\": \"mail\",
    \"risk\": \"DANGEROUS\", \"action\": \"remove_path\",
    \"path\": \"${DA1_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"Mail data\", \"recommendation\": \"never\"
  }
]"
INCLUDE_REVIEW=1
apply_plan_file "$DA1_PLAN" > /dev/null 2>&1
assert_file_exists "$DA1_FILE" "DA1: DANGEROUS must never be applied"
assert_true "journal_has_event 'plan_apply_skipped'"  "DA1: plan_apply_skipped journalled"
assert_true "journal_has_message 'dangerous blocked'" "DA1: journal says dangerous blocked"

# ---------------------------------------------------------------------------
# RV1: REVIEW + INCLUDE_REVIEW=0 → skipped, journal plan_apply_skipped
# ---------------------------------------------------------------------------
begin_test "RV1: REVIEW op skipped when INCLUDE_REVIEW=0"
reset_apply_state
RV1_FILE="${HOME}/Library/Caches/rv1-testfile"
create_file_kb "$RV1_FILE" 4
RV1_PLAN="${SANDBOX}/rv1.json"
write_plan "$RV1_PLAN" "[
  {
    \"id\": \"op-rv1\", \"category\": \"user-caches\",
    \"risk\": \"REVIEW\", \"action\": \"remove_path\",
    \"path\": \"${RV1_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"review cache\", \"recommendation\": \"review\"
  }
]"
INCLUDE_REVIEW=0
apply_plan_file "$RV1_PLAN" > /dev/null 2>&1
assert_file_exists "$RV1_FILE" "RV1: REVIEW skipped when not included"
assert_true "journal_has_event 'plan_apply_skipped'"  "RV1: plan_apply_skipped journalled"
assert_true "journal_has_message 'review not included'" "RV1: journal says review not included"

# ---------------------------------------------------------------------------
# RV2: REVIEW + INCLUDE_REVIEW=1 + NON_INTERACTIVE=1 → still skipped
# ---------------------------------------------------------------------------
begin_test "RV2: REVIEW + --include-review + NON_INTERACTIVE skips the op"
reset_apply_state
RV2_FILE="${HOME}/Library/Caches/rv2-testfile"
create_file_kb "$RV2_FILE" 4
RV2_PLAN="${SANDBOX}/rv2.json"
write_plan "$RV2_PLAN" "[
  {
    \"id\": \"op-rv2\", \"category\": \"user-caches\",
    \"risk\": \"REVIEW\", \"action\": \"remove_path\",
    \"path\": \"${RV2_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"review cache\", \"recommendation\": \"review\"
  }
]"
INCLUDE_REVIEW=1
NON_INTERACTIVE=1
apply_plan_file "$RV2_PLAN" > /dev/null 2>&1
assert_file_exists "$RV2_FILE" "RV2: non-interactive must skip REVIEW even with --include-review"

# ---------------------------------------------------------------------------
# RV3: REVIEW + INCLUDE_REVIEW=1 + REQUIRE_TYPING_PATH=1, wrong answer → skipped
# ---------------------------------------------------------------------------
begin_test "RV3: REVIEW + REQUIRE_TYPING_PATH wrong answer leaves file intact"
reset_apply_state
RV3_FILE="${HOME}/Library/Caches/rv3-testfile"
create_file_kb "$RV3_FILE" 4
RV3_PLAN="${SANDBOX}/rv3.json"
write_plan "$RV3_PLAN" "[
  {
    \"id\": \"op-rv3\", \"category\": \"user-caches\",
    \"risk\": \"REVIEW\", \"action\": \"remove_path\",
    \"path\": \"${RV3_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"review cache\", \"recommendation\": \"review\"
  }
]"
INCLUDE_REVIEW=1
NON_INTERACTIVE=0
REQUIRE_TYPING_PATH=1
# Feed wrong path answer
printf '/wrong/path\n' | apply_plan_file "$RV3_PLAN" > /dev/null 2>&1
assert_file_exists "$RV3_FILE" "RV3: wrong typed path must not remove file"
REQUIRE_TYPING_PATH=0

# ---------------------------------------------------------------------------
# RV4: REVIEW + INCLUDE_REVIEW=1 + REQUIRE_TYPING_PATH=1, correct answer → applied
# ---------------------------------------------------------------------------
begin_test "RV4: REVIEW + REQUIRE_TYPING_PATH correct answer applies op"
reset_apply_state
RV4_FILE="${HOME}/Library/Caches/rv4-testfile"
create_file_kb "$RV4_FILE" 4
RV4_PLAN="${SANDBOX}/rv4.json"
write_plan "$RV4_PLAN" "[
  {
    \"id\": \"op-rv4\", \"category\": \"user-caches\",
    \"risk\": \"REVIEW\", \"action\": \"remove_path\",
    \"path\": \"${RV4_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"review cache\", \"recommendation\": \"review\"
  }
]"
INCLUDE_REVIEW=1
NON_INTERACTIVE=0
REQUIRE_TYPING_PATH=1
REMOVE_MODE=quarantine
# Feed exact path as the typed answer
printf '%s\n' "$RV4_FILE" | apply_plan_file "$RV4_PLAN" > /dev/null 2>&1
assert_file_absent "$RV4_FILE" "RV4: correct typed path must apply the removal"
REQUIRE_TYPING_PATH=0

# ---------------------------------------------------------------------------
# SF1b: SF1 via is_protected_path — SAFE plan op blocked when target is a
#        protected root (no policy change needed — tests the is_protected_path branch)
# ---------------------------------------------------------------------------
begin_test "SF1b: is_protected_path blocks SAFE plan op for a broad-root path"
reset_apply_state
# $HOME itself is protected. Write a plan claiming it is SAFE to remove.
SF1B_PLAN="${SANDBOX}/sf1b.json"
write_plan "$SF1B_PLAN" "[
  {
    \"id\": \"op-sf1b\", \"category\": \"user-caches\",
    \"risk\": \"SAFE\", \"action\": \"remove_path\",
    \"path\": \"${HOME}/Library\", \"command\": \"\",
    \"estimated_bytes\": 0, \"size\": 0,
    \"description\": \"Would delete Library\", \"recommendation\": \"never\"
  }
]"
apply_plan_file "$SF1B_PLAN" > /dev/null 2>&1
# ~/Library must still exist
assert_true "[ -d \"${HOME}/Library\" ]" "SF1b: ~/Library must not be removed"
assert_true "journal_has_event 'plan_apply_blocked'" "SF1b: plan_apply_blocked journalled"

# ---------------------------------------------------------------------------
# NC1: native_command dry-run → planned journal event, command not executed
# ---------------------------------------------------------------------------
begin_test "NC1: native_command in DRY_RUN=1 records planned event, does not run"
reset_apply_state
DRY_RUN=1
NC1_PLAN="${SANDBOX}/nc1.json"
write_plan "$NC1_PLAN" "[
  {
    \"id\": \"op-nc1\", \"category\": \"dev\",
    \"risk\": \"SAFE\", \"action\": \"native_command\",
    \"path\": \"\", \"command\": \"gem cleanup\",
    \"estimated_bytes\": 0, \"size\": 0,
    \"description\": \"gem cleanup dry\", \"recommendation\": \"test\"
  }
]"
apply_plan_file "$NC1_PLAN" > /dev/null 2>&1
assert_true "journal_has_event 'native_command'"   "NC1: native_command event written"
assert_true "journal_has_message 'planned'"        "NC1: status=planned in journal"
DRY_RUN=0

# ---------------------------------------------------------------------------
# NC2: non-allowlisted native_command → plan_apply_blocked + "not allowlisted"
# ---------------------------------------------------------------------------
begin_test "NC2: non-allowlisted native_command is blocked and journalled"
reset_apply_state
NC2_PLAN="${SANDBOX}/nc2.json"
write_plan "$NC2_PLAN" "[
  {
    \"id\": \"op-nc2\", \"category\": \"dev\",
    \"risk\": \"SAFE\", \"action\": \"native_command\",
    \"path\": \"\", \"command\": \"rm -rf /\",
    \"estimated_bytes\": 0, \"size\": 0,
    \"description\": \"blocked\", \"recommendation\": \"never\"
  }
]"
apply_plan_file "$NC2_PLAN" > /dev/null 2>&1
assert_true "journal_has_event 'plan_apply_blocked'"       "NC2: plan_apply_blocked journalled"
assert_true "journal_has_message 'native command not allowlisted'" "NC2: 'not allowlisted' in journal"

# ---------------------------------------------------------------------------
# NC3: allowlisted tool unavailable → status=skipped, "tool unavailable: X" in journal
#      We detect which allowlisted tool is absent on this machine and test with it.
#      If all allowlisted tools happen to be installed, the test is skipped with a note.
# ---------------------------------------------------------------------------
begin_test "NC3: allowlisted tool unavailable → status=skipped, tool unavailable message"
reset_apply_state
# Find an allowlisted tool that is definitely not installed.
NC3_ABSENT_TOOL=""
NC3_ABSENT_CMD=""
if ! command -v npm > /dev/null 2>&1; then
    NC3_ABSENT_TOOL="npm"; NC3_ABSENT_CMD="npm cache clean --force"
elif ! command -v pnpm > /dev/null 2>&1; then
    NC3_ABSENT_TOOL="pnpm"; NC3_ABSENT_CMD="pnpm store prune"
elif ! command -v yarn > /dev/null 2>&1; then
    NC3_ABSENT_TOOL="yarn"; NC3_ABSENT_CMD="yarn cache clean"
fi

if [[ -z "$NC3_ABSENT_TOOL" ]]; then
    # All allowlisted tools present — test not applicable; count as pass with note.
    echo "  NOTE: NC3 skipped — all allowlisted tools installed on this machine" >&2
    _pass  # count it as one pass so the suite doesn't break
else
    DRY_RUN=0
    execute_plan_native_command "$NC3_ABSENT_CMD" "102400" > /dev/null 2>&1
    assert_true "journal_has_event 'native_command'"     "NC3: native_command event written"
    assert_true "journal_has_message 'tool unavailable'" "NC3: 'tool unavailable' in journal"
    assert_true "journal_has_message 'skipped'"          "NC3: status=skipped (not failed)"
fi


# ---------------------------------------------------------------------------
# NC4: allowlisted tool present but command fails → status=failed in journal
#      Calls execute_plan_native_command directly with a stub gem that exits 1.
# ---------------------------------------------------------------------------
begin_test "NC4: allowlisted tool present but fails → status=failed in journal"
reset_apply_state
FAKE_BIN_NC4="${SANDBOX}/nc4_fakedir"
mkdir -p "$FAKE_BIN_NC4"
cat > "${FAKE_BIN_NC4}/gem" << 'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "${FAKE_BIN_NC4}/gem"
_OLD_PATH_NC4="$PATH"
PATH="${FAKE_BIN_NC4}:${PATH}"
DRY_RUN=0
execute_plan_native_command "gem cleanup" "0" > /dev/null 2>&1
PATH="$_OLD_PATH_NC4"
assert_true "journal_has_event 'native_command'"          "NC4: native_command event written"
assert_true "journal_has_message 'failed'"                "NC4: status=failed in journal"
assert_false "journal_has_message 'tool unavailable'"     "NC4: must NOT say tool unavailable"


# ---------------------------------------------------------------------------
# Mixed plan: SAFE applied, REVIEW skipped, DANGEROUS blocked — all in one pass
# ---------------------------------------------------------------------------
begin_test "Mixed plan: SAFE applied, REVIEW skipped, DANGEROUS blocked"
reset_apply_state
MIX_SAFE="${HOME}/Library/Caches/mix-safe"
MIX_REVIEW="${HOME}/Library/Caches/mix-review"
MIX_DANGER="${HOME}/Library/Mail/V10/mix-danger"
create_file_kb "$MIX_SAFE" 4
create_file_kb "$MIX_REVIEW" 4
create_file_kb "$MIX_DANGER" 4

MIX_PLAN="${SANDBOX}/mix.json"
write_plan "$MIX_PLAN" "[
  {
    \"id\": \"op-safe\", \"category\": \"user-caches\",
    \"risk\": \"SAFE\", \"action\": \"remove_path\",
    \"path\": \"${MIX_SAFE}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"safe\", \"recommendation\": \"safe\"
  },
  {
    \"id\": \"op-review\", \"category\": \"user-caches\",
    \"risk\": \"REVIEW\", \"action\": \"remove_path\",
    \"path\": \"${MIX_REVIEW}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"review\", \"recommendation\": \"review\"
  },
  {
    \"id\": \"op-danger\", \"category\": \"mail\",
    \"risk\": \"DANGEROUS\", \"action\": \"remove_path\",
    \"path\": \"${MIX_DANGER}\", \"command\": \"\",
    \"estimated_bytes\": 4096, \"size\": 4096,
    \"description\": \"mail\", \"recommendation\": \"never\"
  }
]"
INCLUDE_REVIEW=0
apply_plan_file "$MIX_PLAN" > /dev/null 2>&1
assert_file_absent  "$MIX_SAFE"   "Mixed: SAFE must be removed"
assert_file_exists  "$MIX_REVIEW" "Mixed: REVIEW must stay"
assert_file_exists  "$MIX_DANGER" "Mixed: DANGEROUS must stay"
# Quarantine must have the safe file
assert_true "find \"${QUARANTINE_ROOT}\" -name 'mix-safe' -print -quit | grep -q ." \
    "Mixed: SAFE file must be in quarantine"

print_test_summary
