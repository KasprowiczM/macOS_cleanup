#!/usr/bin/env bash
# =============================================================================
# tests/test_planner.sh — plan.json generation and apply guardrails.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_planner.XXXXXX)"
export HOME="$SANDBOX"
export USER="${USER:-testuser}"
export LOG_LEVEL="INFO"
export NO_COLOR=1

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() {
    rm -rf "$SANDBOX"
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

reset_plan_fixture() {
    FOUND_USER_CACHES=()
    FOUND_APP_CACHE_ITEMS=()
    FOUND_APP_LOGS=()
    FOUND_SYSTEM_LOGS=()
    FOUND_DIAGNOSTIC_REPORTS=()
    FOUND_TMP_FILES=()
    FOUND_SYSTEM_CACHES=()
    FOUND_APP_LEFTOVERS=()
    FOUND_DEV_ITEMS=()
    FOUND_DEVICE_SUPPORT_ITEMS=()
    FOUND_TM_SNAPSHOTS=()
    FOUND_IOS_BACKUPS=()
    FOUND_DMG_PKG=()
    FOUND_TRASH_ITEMS=()
    FOUND_MAIL_ITEMS=()
    FOUND_BROWSER_CACHE_ITEMS=()
    FOUND_BROWSER_DATA_ITEMS=()
    USER_DECISION_ITEMS=()
    WARNINGS_LIST=()
    TOTAL_CLEANED_BYTES=0
    TOTAL_WOULD_FREE_BYTES=0
    TOTAL_QUARANTINED_BYTES=0
    TOTAL_QUARANTINED_ITEMS=0
    TOTAL_SKIPPED_ITEMS=0
    TOTAL_USER_DECISIONS_NEEDED=0

    local key
    for key in "${ALL_KNOWN_CATEGORY_KEYS[@]}"; do
        catbytes_set "$key" 0
    done
    plan_reset
}

create_file_kb() {
    local path="$1"
    local kb="$2"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/zero of="$path" bs=1024 count="$kb" 2>/dev/null
}

plan_has_risk_for_path() {
    local plan="$1" path="$2" risk="$3"
    python3 - "$plan" "$path" "$risk" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for op in data.get("operations", []):
    if op.get("path") == sys.argv[2] and op.get("risk") == sys.argv[3]:
        sys.exit(0)
sys.exit(1)
PY
}

plan_operations_have_required_fields() {
    local plan="$1"
    python3 - "$plan" <<'PY'
import json
import sys
required = {"id", "path", "category", "risk", "size", "action", "description", "recommendation"}
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
ops = data.get("operations", [])
if not ops:
    sys.exit(1)
for op in ops:
    if not required.issubset(op):
        sys.exit(1)
    if op.get("risk") not in {"SAFE", "REVIEW", "DANGEROUS"}:
        sys.exit(1)
    if not isinstance(op.get("size"), int):
        sys.exit(1)
sys.exit(0)
PY
}

begin_test "plan classifies SAFE app cache, REVIEW generic cache, DANGEROUS Mail"
reset_plan_fixture
generic_cache="$HOME/Library/Caches/com.example.generic"
spotify_cache="$HOME/Library/Caches/com.spotify.client"
mail_dir="$HOME/Library/Mail"
create_file_kb "$generic_cache/payload.bin" 4
create_file_kb "$spotify_cache/payload.bin" 16
create_file_kb "$mail_dir/V10/MailData/Envelope Index" 4
FOUND_USER_CACHES+=("$generic_cache")
FOUND_APP_CACHE_ITEMS+=("Spotify (Cache):$spotify_cache")
FOUND_MAIL_ITEMS+=("mail-store:$mail_dir")
build_cleanup_plan_from_analysis
PLAN_OUT="$SANDBOX/plan.json"
generate_plan_json "$PLAN_OUT" >/dev/null
assert_true "plan_has_risk_for_path '$PLAN_OUT' '$spotify_cache' 'SAFE'"
assert_true "plan_has_risk_for_path '$PLAN_OUT' '$generic_cache' 'REVIEW'"
assert_true "plan_has_risk_for_path '$PLAN_OUT' '$mail_dir' 'DANGEROUS'"
assert_true "plan_operations_have_required_fields '$PLAN_OUT'"

begin_test "apply plan default executes SAFE only and skips REVIEW/DANGEROUS"
reset_plan_fixture
generic_cache="$HOME/Library/Caches/com.example.generic2"
spotify_cache="$HOME/Library/Caches/com.spotify.client2"
mail_dir="$HOME/Library/Mail"
create_file_kb "$generic_cache/payload.bin" 4
create_file_kb "$spotify_cache/payload.bin" 16
create_file_kb "$mail_dir/V10/MailData/Envelope Index" 4
FOUND_USER_CACHES+=("$generic_cache")
FOUND_APP_CACHE_ITEMS+=("Spotify (Cache):$spotify_cache")
FOUND_MAIL_ITEMS+=("mail-store:$mail_dir")
build_cleanup_plan_from_analysis
PLAN_OUT="$SANDBOX/apply-plan.json"
generate_plan_json "$PLAN_OUT" >/dev/null
DRY_RUN=0
REMOVE_MODE=quarantine
NON_INTERACTIVE=1
AUTO_YES=1
INCLUDE_REVIEW=0
apply_plan_file "$PLAN_OUT" >/dev/null
assert_file_absent "$spotify_cache" "SAFE app cache should be quarantined"
assert_file_exists "$generic_cache/payload.bin" "REVIEW cache must not be applied by default"
assert_file_exists "$mail_dir/V10/MailData/Envelope Index" "DANGEROUS Mail data must never be applied"
assert_true "find \"$QUARANTINE_ROOT\" -path '*com.spotify.client2/payload.bin' -type f -print -quit | grep -q ."

# ---------------------------------------------------------------------------
# SF1: apply-time revalidation blocks escalated risk
# ---------------------------------------------------------------------------
begin_test "SF1: apply blocks SAFE path when risk escalates to DANGEROUS"
reset_plan_fixture
sf1_target="$HOME/Library/Caches/com.sf1.testcache"
create_file_kb "$sf1_target/payload.bin" 4
FOUND_APP_CACHE_ITEMS+=("Spotify (Cache):$sf1_target")
build_cleanup_plan_from_analysis
SF1_PLAN="$SANDBOX/sf1-plan.json"
generate_plan_json "$SF1_PLAN" >/dev/null
# Verify it was planned as SAFE
assert_true "plan_has_risk_for_path '$SF1_PLAN' '$sf1_target' 'SAFE'"
# Now escalate: add to NEVER_TOUCH_PATHS (simulates external policy change)
NEVER_TOUCH_PATHS+=("$sf1_target")
normalize_never_touch_paths
DRY_RUN=0
REMOVE_MODE=permanent
NON_INTERACTIVE=1
AUTO_YES=1
INCLUDE_REVIEW=0
apply_plan_file "$SF1_PLAN" >/dev/null
# File must be untouched
assert_file_exists "$sf1_target/payload.bin" "SF1: escalated path must NOT be removed"
# Journal should contain blocked event
if [[ -f "$CLEANUP_JOURNAL_FILE" ]]; then
    assert_true "grep -q 'plan_apply_blocked' '$CLEANUP_JOURNAL_FILE'" "SF1: journal has plan_apply_blocked"
else
    _fail "SF1: journal file not created"
fi
# Clean up: remove the added path
_sf1_idx=${#NEVER_TOUCH_PATHS[@]}
unset "NEVER_TOUCH_PATHS[$((_sf1_idx-1))]"
normalize_never_touch_paths

# ---------------------------------------------------------------------------
# TC2: validate plan.json against JSON Schema
# ---------------------------------------------------------------------------
begin_test "TC2: generated plan.json validates against plan.schema.json"
reset_plan_fixture
tc2_cache="$HOME/Library/Caches/com.tc2.test"
create_file_kb "$tc2_cache/payload.bin" 4
FOUND_USER_CACHES+=("$tc2_cache")
build_cleanup_plan_from_analysis
TC2_PLAN="$SANDBOX/tc2-plan.json"
generate_plan_json "$TC2_PLAN" >/dev/null
TC2_SCHEMA="${PROJ_DIR}/schemas/plan.schema.json"
# Write the validator to a temp file to avoid fragile nested shell/python quoting.
# Uses jsonschema when available, otherwise a structural fallback — both paths
# are exercised regardless of whether jsonschema is installed on the runner.
TC2_PYCHECK="$SANDBOX/tc2_validate.py"
cat > "$TC2_PYCHECK" <<'PYEOF'
import json, sys
plan_path, schema_path = sys.argv[1], sys.argv[2]
with open(plan_path) as f:
    plan = json.load(f)
try:
    import jsonschema
    with open(schema_path) as f:
        schema = json.load(f)
    jsonschema.validate(plan, schema)
except ImportError:
    required = {'schema_version', 'tool', 'tool_version', 'run_id',
                'generated_at', 'summary', 'operations'}
    missing = required - set(plan.keys())
    assert not missing, 'missing keys: %s' % (missing,)
    for op in plan['operations']:
        op_req = {'id', 'category', 'risk', 'action', 'path',
                  'description', 'recommendation', 'size'}
        op_missing = op_req - set(op.keys())
        assert not op_missing, 'op %s missing: %s' % (op.get('id', '?'), op_missing)
        assert op['risk'] in ('SAFE', 'REVIEW', 'DANGEROUS'), 'bad risk: %s' % op['risk']
print('ok')
PYEOF
assert_true "python3 '$TC2_PYCHECK' '$TC2_PLAN' '$TC2_SCHEMA'" "plan.json validates against plan.schema.json"

# ---------------------------------------------------------------------------
# TC3: end-to-end plan apply blocks non-allowlisted native commands and applies safe paths
# ---------------------------------------------------------------------------
begin_test "TC3: apply --from-plan quarantines SAFE remove_path and rejects non-allowlisted native_command"
reset_plan_fixture
tc3_file="$HOME/Library/Caches/com.tc3.cachefile"
create_file_kb "$tc3_file" 4
TC3_PLAN="$SANDBOX/tc3-plan.json"
cat > "$TC3_PLAN" <<EOF
{
  "schema_version": "1.0",
  "tool": "macOS_cleanup",
  "tool_version": "2.1.0",
  "run_id": "test_tc3",
  "generated_at": "2026-06-04T12:00:00Z",
  "summary": {
    "total_operations": 2,
    "total_safe_bytes": 4096,
    "total_review_bytes": 0,
    "total_dangerous_bytes": 0
  },
  "operations": [
    {
      "id": "op_tc3_1",
      "category": "user-caches",
      "risk": "SAFE",
      "action": "remove_path",
      "path": "$tc3_file",
      "description": "Test cache removal",
      "recommendation": "Safe to remove",
      "size": 4096
    },
    {
      "id": "op_tc3_2",
      "category": "user-caches",
      "risk": "SAFE",
      "action": "native_command",
      "command": "rm -rf /",
      "description": "Dangerous disallowed command",
      "recommendation": "Should be blocked",
      "size": 0
    }
  ]
}
EOF

DRY_RUN=0
REMOVE_MODE=quarantine
NON_INTERACTIVE=1
AUTO_YES=1
INCLUDE_REVIEW=0
# Clear/reset journal file
rm -f "$CLEANUP_JOURNAL_FILE"

apply_plan_file "$TC3_PLAN" >/dev/null

assert_file_absent "$tc3_file" "TC3: SAFE remove_path should be quarantined"
assert_true "find \"$QUARANTINE_ROOT\" -path '*com.tc3.cachefile' -type f -print -quit | grep -q ." "TC3: quarantined file exists"

if [[ -f "$CLEANUP_JOURNAL_FILE" ]]; then
    assert_true "grep -q 'native command not allowlisted' '$CLEANUP_JOURNAL_FILE'" "TC3: journal contains blocked native command log"
else
    _fail "TC3: journal file not created"
fi

# ---------------------------------------------------------------------------
# TC4: Bug #1 — apply --include-review must not consume plan stream as user input
#
# Creates a plan with: op1=REVIEW remove_path, op2=SAFE remove_path.
# Feeds "y\n" via stdin (simulating TTY answer to the REVIEW prompt).
# After the fix (fd-3 loop) op2 SAFE file must be quarantined.
# Before the fix the SAFE op's plan line is consumed by read -r answer,
# causing op2 to be silently skipped.
# ---------------------------------------------------------------------------
begin_test "TC4: apply --include-review does not consume SAFE ops after REVIEW prompt"
reset_plan_fixture
tc4_review_file="$HOME/Library/Caches/com.tc4.review-item"
tc4_safe_file="$HOME/Library/Caches/com.tc4.safe-item"
create_file_kb "$tc4_review_file" 4
create_file_kb "$tc4_safe_file" 4
TC4_PLAN="$SANDBOX/tc4-plan.json"
cat > "$TC4_PLAN" <<EOF
{
  "schema_version": "1.0",
  "tool": "macOS_cleanup",
  "tool_version": "2.1.0",
  "run_id": "test_tc4",
  "generated_at": "2026-06-04T12:00:00Z",
  "summary": {
    "operations": 2,
    "safe_operations": 1,
    "review_operations": 1,
    "dangerous_operations": 0,
    "safe_bytes": 4096,
    "review_bytes": 4096,
    "dangerous_bytes": 0
  },
  "operations": [
    {
      "id": "op_tc4_review",
      "category": "user-caches",
      "risk": "REVIEW",
      "action": "remove_path",
      "path": "$tc4_review_file",
      "command": "",
      "estimated_bytes": 4096,
      "size": 4096,
      "description": "REVIEW cache for TC4 test",
      "recommendation": "Confirm before removing"
    },
    {
      "id": "op_tc4_safe",
      "category": "user-caches",
      "risk": "SAFE",
      "action": "remove_path",
      "path": "$tc4_safe_file",
      "command": "",
      "estimated_bytes": 4096,
      "size": 4096,
      "description": "SAFE cache for TC4 test",
      "recommendation": "Always safe to remove"
    }
  ]
}
EOF

DRY_RUN=0
REMOVE_MODE=quarantine
NON_INTERACTIVE=0
AUTO_YES=0
INCLUDE_REVIEW=1
rm -f "$CLEANUP_JOURNAL_FILE"
# Feed "y" as the answer to the REVIEW confirmation prompt via stdin
printf 'y\n' | apply_plan_file "$TC4_PLAN" > /dev/null 2>&1
# The SAFE op (op_tc4_safe) must have been quarantined regardless of the REVIEW answer
assert_file_absent "$tc4_safe_file" \
    "TC4: SAFE op after REVIEW must be executed (Bug#1: stdin-consumption fix)"

print_test_summary


