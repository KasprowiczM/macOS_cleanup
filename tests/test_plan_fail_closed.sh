#!/usr/bin/env bash
# tests/test_plan_fail_closed.sh — H9: apply validates the whole document first
# Bash 3.2 compatible.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_plan_fail_closed.XXXXXX)"
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

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

write_plan_ops() {
    local dest="$1" ops_json="$2" include_checksum="${3:-1}"
    local checksum=""
    checksum="$(python3 -c 'import hashlib, json, sys
ops = json.loads(sys.argv[1])
print(hashlib.sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()).hexdigest())' "$ops_json")"
    if [[ "$include_checksum" == "1" ]]; then
        cat > "$dest" <<EOF
{
  "schema_version": "1.0",
  "tool": "cleanup_all.sh",
  "tool_version": "2.0.0",
  "run_id": "test_run",
  "generated_at": "2026-09-07T10:00:00Z",
  "checksum": "${checksum}",
  "summary": {"operations": 0, "safe_operations": 0,
               "review_operations": 0, "dangerous_operations": 0,
               "safe_bytes": 0, "review_bytes": 0, "dangerous_bytes": 0},
  "operations": ${ops_json}
}
EOF
    else
        cat > "$dest" <<EOF
{
  "schema_version": "1.0",
  "tool": "cleanup_all.sh",
  "tool_version": "2.0.0",
  "run_id": "test_run",
  "generated_at": "2026-09-07T10:00:00Z",
  "summary": {"operations": 0, "safe_operations": 0,
               "review_operations": 0, "dangerous_operations": 0,
               "safe_bytes": 0, "review_bytes": 0, "dangerous_bytes": 0},
  "operations": ${ops_json}
}
EOF
    fi
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

begin_test "invalid estimated_bytes rejects apply before first mutation"
reset_apply_state
FC1_FILE="${HOME}/Library/Caches/fc1-keep-me"
mkdir -p "$(dirname "$FC1_FILE")"
echo keep > "$FC1_FILE"
FC1_PLAN="${SANDBOX}/fc1.json"
write_plan_ops "$FC1_PLAN" "[
  {
    \"id\": \"op-fc1a\", \"category\": \"user-caches\",
    \"risk\": \"SAFE\", \"action\": \"remove_path\",
    \"path\": \"${FC1_FILE}\", \"command\": \"\",
    \"estimated_bytes\": 4, \"size\": 4,
    \"description\": \"first\", \"recommendation\": \"safe\"
  },
  {
    \"id\": \"op-fc1b\", \"category\": \"user-caches\",
    \"risk\": \"SAFE\", \"action\": \"remove_path\",
    \"path\": \"${HOME}/Library/Caches/fc1-other\", \"command\": \"\",
    \"estimated_bytes\": \"NOT_A_NUMBER\", \"size\": 0,
    \"description\": \"bad bytes\", \"recommendation\": \"safe\"
  }
]"
set +e
apply_plan_file "$FC1_PLAN" >/dev/null 2>&1
FC1_RC=$?
set -u
assert_neq "$FC1_RC" "0" "malformed estimated_bytes must fail apply"
assert_file_exists "$FC1_FILE" "parser failure must not execute op 1"

begin_test "native npm command exit 42 fails apply"
reset_apply_state
FC2_CACHE="${SANDBOX}/npm-cache-fc2"
mkdir -p "$FC2_CACHE"
FC2_PLAN="${SANDBOX}/fc2.json"
write_plan_ops "$FC2_PLAN" "[
  {
    \"id\": \"op-fc2\", \"category\": \"dev\",
    \"risk\": \"SAFE\", \"action\": \"native_command\",
    \"path\": \"${FC2_CACHE}\", \"command\": \"npm cache clean --force\",
    \"estimated_bytes\": 1024, \"size\": 1024,
    \"description\": \"npm\", \"recommendation\": \"safe\",
    \"rollback\": false, \"tool\": \"npm\"
  }
]"
FC2_BIN="${SANDBOX}/fc2_bin"
mkdir -p "$FC2_BIN"
cat > "${FC2_BIN}/npm" << 'STUB'
#!/bin/sh
exit 42
STUB
chmod +x "${FC2_BIN}/npm"
_old_path="$PATH"
export PATH="${FC2_BIN}:${PATH}"
set +e
apply_plan_file "$FC2_PLAN" >/dev/null 2>&1
FC2_RC=$?
set -u
export PATH="$_old_path"
assert_neq "$FC2_RC" "0" "native command failure must fail apply"

begin_test "missing checksum is rejected"
reset_apply_state
FC3_PLAN="${SANDBOX}/fc3.json"
write_plan_ops "$FC3_PLAN" "[
  {
    \"id\": \"op-fc3\", \"category\": \"dev\",
    \"risk\": \"SAFE\", \"action\": \"report_only\",
    \"path\": \"/tmp/unused\", \"command\": \"\",
    \"estimated_bytes\": 0, \"size\": 0,
    \"description\": \"no checksum\", \"recommendation\": \"safe\"
  }
]" "0"
set +e
apply_plan_file "$FC3_PLAN" >/dev/null 2>&1
FC3_RC=$?
set -u
assert_neq "$FC3_RC" "0" "missing checksum must reject apply"

print_test_summary
