#!/usr/bin/env bash
# =============================================================================
# tests/test_recovery.sh — Unit tests for Recovery Semantics & Plan Checksum [Batch 5]
#
# Validates quarantine restore stat conflict protection, plan file checksum verification,
# and signal interrupt traps.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_recovery.XXXXXX)"
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
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

begin_test "Plan file checksum verification succeeds on valid plan"
plan_file="${SANDBOX}/valid_plan.json"
empty_ops_chk="$(python3 -c 'import hashlib, json; print(hashlib.sha256(json.dumps([], sort_keys=True, separators=(",", ":")).encode()).hexdigest())')"
cat > "$plan_file" <<EOF
{
  "schema_version": "1.0",
  "tool": "cleanup_all.sh",
  "checksum": "${empty_ops_chk}",
  "summary": {
    "operations": 1,
    "safe_operations": 1,
    "review_operations": 0,
    "dangerous_operations": 0
  },
  "operations": []
}
EOF

if verify_plan_file_checksum "$plan_file"; then
    _pass
else
    _fail "Valid plan checksum should be accepted"
fi

begin_test "Plan file checksum verification fails on tampered plan"
tampered_plan="${SANDBOX}/tampered_plan.json"
cat <<'EOF' > "$tampered_plan"
{
  "schema_version": "1.0",
  "tool": "cleanup_all.sh",
  "checksum": "99-99-0-0",
  "summary": {
    "operations": 1,
    "safe_operations": 1,
    "review_operations": 0,
    "dangerous_operations": 0
  },
  "operations": []
}
EOF

if verify_plan_file_checksum "$tampered_plan"; then
    _fail "Tampered plan checksum MUST be rejected"
else
    _pass
fi

begin_test "Quarantine restore protects existing target files from overwrite"
mkdir -p "$HOME/Library/Caches/app"
source_file="${SANDBOX}/quarantine/item.cache"
target_file="$HOME/Library/Caches/app/existing.cache"

mkdir -p "$(dirname "$source_file")"
echo "quarantined_content" > "$source_file"
echo "important_original_content" > "$target_file"

manifest="${SANDBOX}/manifest.tsv"
q_b64="$(printf '%s' "$source_file" | base64_encode_string)"
p_b64="$(printf '%s' "$target_file" | base64_encode_string)"
printf '%s\t%s\t%s\n' "$q_b64" "$p_b64" "100" > "$manifest"

restore_quarantine_manifest "$manifest"

# Target file MUST still contain original content
if [[ "$(cat "$target_file")" == "important_original_content" ]]; then
    _pass
else
    _fail "Restore MUST NOT overwrite existing target file"
fi

begin_test "Signal trap handler _on_interrupt exits with code 130"
( _on_interrupt >/dev/null 2>&1 )
rc=$?
if (( rc == 130 )); then
    _pass
else
    _fail "_on_interrupt should exit with code 130, got ${rc}"
fi

print_test_summary
