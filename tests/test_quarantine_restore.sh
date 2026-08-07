#!/usr/bin/env bash
# =============================================================================
# tests/test_quarantine_restore.sh - intended quarantine/restore behavior.
#
# These tests pin the wave 2 contract: user-space safe_remove() quarantines
# real removals, dry-run does not quarantine, and restore works through both the
# library function and CLI.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_test_quarantine.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"

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

LOG_FILE="${SANDBOX}/initial.log"
C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM=''
NEVER_TOUCH_PATHS=()
RULES_FILE="${PROJ_DIR}/cleanup_rules.yaml"

# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

CASE_NUM=0

cleanup() {
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

start_case() {
    CASE_NUM=$(( CASE_NUM + 1 ))
    CASE_DIR="${SANDBOX}/case_${CASE_NUM}"
    TEST_HOME="${CASE_DIR}/home"
    mkdir -p "$TEST_HOME"

    export HOME="$TEST_HOME"
    LOG_FILE="${CASE_DIR}/test.log"

    RUN_TIMESTAMP="test_run_${CASE_NUM}"
    REPORTS_DIR="${CASE_DIR}/reports"
    CLEANUP_JOURNAL_FILE="${REPORTS_DIR}/journal_${RUN_TIMESTAMP}.jsonl"
    CLEANUP_RESTORE_MANIFEST="${REPORTS_DIR}/restore_${RUN_TIMESTAMP}.tsv"
    QUARANTINE_ROOT="${CASE_DIR}/quarantine"
    QUARANTINE_RUN_DIR="${QUARANTINE_ROOT}/${RUN_TIMESTAMP}"
    QUARANTINE_JOURNAL="$CLEANUP_JOURNAL_FILE"
    QUARANTINE_DIR="$QUARANTINE_ROOT"
    export RUN_TIMESTAMP REPORTS_DIR
    export CLEANUP_JOURNAL_FILE CLEANUP_RESTORE_MANIFEST
    export QUARANTINE_ROOT QUARANTINE_RUN_DIR

    NEVER_TOUCH_PATHS=()
    DRY_RUN=0
    MODE="auto-safe"; : "$MODE"
    REMOVE_MODE="quarantine"
    TOTAL_CLEANED_BYTES=0
    TOTAL_WOULD_FREE_BYTES=0
    TOTAL_QUARANTINED_BYTES=0
    TOTAL_QUARANTINED_ITEMS=0
    TOTAL_RESTORED_BYTES=0
    TOTAL_RESTORED_ITEMS=0
    TOTAL_SKIPPED_ITEMS=0
    TOTAL_USER_DECISIONS_NEEDED=0
    USER_DECISION_ITEMS=()
    WARNINGS_LIST=()
}

make_file() {
    local path="$1"
    local content="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
}

assert_file_content_eq() {
    local path="$1"
    local expected="$2"
    local msg="${3:-file content should match}"
    local actual

    if [[ ! -f "$path" ]]; then
        _fail "${msg} - missing file: ${path}"
        return
    fi

    actual="$(cat "$path")"
    assert_eq "$actual" "$expected" "$msg"
}

assert_quarantine_empty() {
    local msg="${1:-quarantine should be empty}"

    if [[ -d "$QUARANTINE_DIR" ]] && find "$QUARANTINE_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        _fail "$msg"
    else
        _pass
    fi
}

run_safe_remove_capture_rc() {
    local target="$1"
    local out_file="$2"
    local rc

    set +e
    ( safe_remove "$target" ) >"$out_file" 2>&1
    rc=$?
    set -u
    echo "$rc"
}

run_restore_manifest_capture_rc() {
    local manifest="$1"
    local out_file="$2"
    local rc

    if ! declare -F restore_quarantine_manifest >/dev/null 2>&1; then
        _fail "restore_quarantine_manifest function must exist"
        echo 127
        return
    fi

    set +e
    ( restore_quarantine_manifest "$manifest" ) >"$out_file" 2>&1
    rc=$?
    set -u
    echo "$rc"
}

run_cmd_capture() {
    local out_file="$1"; shift
    local rc

    set +e
    "$@" >"$out_file" 2>&1
    rc=$?
    set -u
    echo "$rc"
}

assert_jsonl_valid() {
    local path="$1"
    local msg="${2:-journal should be valid non-empty JSONL}"

    if python3 - "$path" <<'PY' >/dev/null 2>&1
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    lines = [line for line in fh if line.strip()]
if not lines:
    raise SystemExit(1)
for line in lines:
    json.loads(line)
PY
    then
        _pass
    else
        _fail "$msg"
    fi
}

jsonl_last_field() {
    local path="$1"
    local field="$2"

    python3 - "$path" "$field" <<'PY' 2>/dev/null
import json
import sys

path = sys.argv[1]
field = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as fh:
        lines = [line for line in fh if line.strip()]
    entry = json.loads(lines[-1])
    value = entry
    for part in field.split("."):
        value = value[part]
except Exception:
    raise SystemExit(0)

if isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
else:
    print(str(value))
PY
}

assert_last_journal_field_eq() {
    local field="$1"
    local expected="$2"
    local msg="${3:-journal field should match}"
    local actual

    actual="$(jsonl_last_field "$QUARANTINE_JOURNAL" "$field")"
    assert_eq "$actual" "$expected" "$msg"
}

write_quarantine_fixture() {
    local original="$1"
    local quarantine_path="$2"
    local content="$3"
    local bytes

    make_file "$quarantine_path" "$content"
    bytes="$(path_size_bytes "$quarantine_path")"
    cleanup_restore_record "$quarantine_path" "$original" "$bytes"
}

# ---------------------------------------------------------------------------
begin_test "safe_remove real mode quarantines file and writes JSONL journal"
start_case
file_target="${HOME}/Library/Caches/com.example.app/payload file.txt"
make_file "$file_target" "file-payload"
SAFE_REMOVE_OUTPUT="${CASE_DIR}/safe_remove_file.out"

RC="$(run_safe_remove_capture_rc "$file_target" "$SAFE_REMOVE_OUTPUT")"
assert_eq "$RC" "0" "safe_remove should exit 0 for a user cache file"
assert_file_absent "$file_target" "real mode should move original file away"
assert_file_exists "$QUARANTINE_JOURNAL" "real mode should write a quarantine journal"
assert_file_exists "$CLEANUP_RESTORE_MANIFEST" "real mode should write a restore manifest"
assert_jsonl_valid "$QUARANTINE_JOURNAL"
assert_last_journal_field_eq "action" "quarantined" "journal action should be quarantined"
assert_last_journal_field_eq "path" "$file_target" "journal should record original path"
assert_last_journal_field_eq "status" "ok" "journal should record successful quarantine"
file_quarantine_path="$(jsonl_last_field "$QUARANTINE_JOURNAL" "quarantine_path")"
assert_neq "$file_quarantine_path" "" "journal should record quarantine_path"
if [[ -n "$file_quarantine_path" ]]; then
    assert_file_exists "$file_quarantine_path" "quarantined file should exist"
    assert_file_content_eq "$file_quarantine_path" "file-payload" "quarantined file should preserve content"
fi

# ---------------------------------------------------------------------------
begin_test "safe_remove real mode quarantines directory and writes JSONL journal"
start_case
dir_target="${HOME}/Library/Caches/com.example.dir"
make_file "${dir_target}/nested/data.txt" "dir-payload"
SAFE_REMOVE_OUTPUT="${CASE_DIR}/safe_remove_dir.out"

RC="$(run_safe_remove_capture_rc "$dir_target" "$SAFE_REMOVE_OUTPUT")"
assert_eq "$RC" "0" "safe_remove should exit 0 for a user cache directory"
assert_file_absent "$dir_target" "real mode should move original directory away"
assert_file_exists "$QUARANTINE_JOURNAL" "directory quarantine should write a journal"
assert_file_exists "$CLEANUP_RESTORE_MANIFEST" "directory quarantine should write a restore manifest"
assert_jsonl_valid "$QUARANTINE_JOURNAL"
assert_last_journal_field_eq "action" "quarantined" "journal action should be quarantined"
assert_last_journal_field_eq "path" "$dir_target" "journal should record directory original path"
assert_last_journal_field_eq "status" "ok" "journal should record successful directory quarantine"
dir_quarantine_path="$(jsonl_last_field "$QUARANTINE_JOURNAL" "quarantine_path")"
assert_neq "$dir_quarantine_path" "" "journal should record directory quarantine_path"
if [[ -n "$dir_quarantine_path" ]]; then
    assert_file_exists "${dir_quarantine_path}/nested/data.txt" "quarantined directory should preserve tree"
    assert_file_content_eq "${dir_quarantine_path}/nested/data.txt" "dir-payload" "quarantined directory should preserve file content"
fi

# ---------------------------------------------------------------------------
begin_test "safe_remove dry-run does not quarantine"
start_case
dry_target="${HOME}/Library/Caches/com.example.dry/payload.txt"
make_file "$dry_target" "dry-payload"
DRY_RUN=1
SAFE_REMOVE_OUTPUT="${CASE_DIR}/safe_remove_dry.out"

RC="$(run_safe_remove_capture_rc "$dry_target" "$SAFE_REMOVE_OUTPUT")"
assert_eq "$RC" "0" "dry-run safe_remove should exit 0"
assert_file_exists "$dry_target" "dry-run should leave original file in place"
assert_file_absent "$CLEANUP_RESTORE_MANIFEST" "dry-run should not write restore manifest"
assert_quarantine_empty "dry-run should not create quarantined payloads"

# ---------------------------------------------------------------------------
begin_test "restore_quarantine_manifest restores a journaled file"
start_case
restore_target="${HOME}/Library/Caches/com.example.restore/restore me.txt"
restore_quarantine_path="${QUARANTINE_RUN_DIR}/items/restore-function.payload"
write_quarantine_fixture "$restore_target" "$restore_quarantine_path" "restore-function-payload"
RESTORE_OUTPUT="${CASE_DIR}/restore_function.out"

RC="$(run_restore_manifest_capture_rc "$CLEANUP_RESTORE_MANIFEST" "$RESTORE_OUTPUT")"
assert_eq "$RC" "0" "restore_quarantine_manifest should exit 0"
if [[ "$RC" == "0" ]]; then
    assert_file_exists "$restore_target" "restore function should recreate original file"
    assert_file_absent "$restore_quarantine_path" "restore function should move item out of quarantine"
    assert_file_content_eq "$restore_target" "restore-function-payload" "restore function should preserve file content"
fi

# ---------------------------------------------------------------------------
begin_test "restore blocks target paths with symlinked ancestors"
start_case
outside_dir="${CASE_DIR}/outside"
mkdir -p "$HOME/Library/Caches" "$outside_dir"
ln -s "$outside_dir" "$HOME/Library/Caches/link-to-outside"
symlink_restore_target="${HOME}/Library/Caches/link-to-outside/restored.txt"
symlink_quarantine_path="${QUARANTINE_RUN_DIR}/items/restore-symlink.payload"
write_quarantine_fixture "$symlink_restore_target" "$symlink_quarantine_path" "blocked-payload"
RESTORE_SYMLINK_OUTPUT="${CASE_DIR}/restore_symlink.out"

RC="$(run_restore_manifest_capture_rc "$CLEANUP_RESTORE_MANIFEST" "$RESTORE_SYMLINK_OUTPUT")"
assert_eq "$RC" "0" "restore should skip symlink-ancestor targets without crashing"
assert_file_exists "$symlink_quarantine_path" "blocked restore should leave payload in quarantine"
assert_file_absent "${outside_dir}/restored.txt" "restore must not write through symlinked parent"
assert_last_journal_field_eq "action" "restore_blocked" "journal action should record blocked restore"
assert_last_journal_field_eq "status" "blocked" "journal should record the restore as blocked (resolved path outside HOME)"

# ---------------------------------------------------------------------------
begin_test "cleanup_all --restore restores a journaled file"
start_case
cli_restore_target="${HOME}/Library/Caches/com.example.restore.cli/restore via cli.txt"
cli_quarantine_path="${QUARANTINE_RUN_DIR}/items/restore-cli.payload"
write_quarantine_fixture "$cli_restore_target" "$cli_quarantine_path" "restore-cli-payload"
CLI_RESTORE_OUTPUT="${CASE_DIR}/restore_cli.out"

RC="$(run_cmd_capture "$CLI_RESTORE_OUTPUT" env \
    HOME="$HOME" USER="$USER" LOG_LEVEL="INFO" NO_COLOR=1 \
    CLEANUP_JOURNAL_FILE="$CLEANUP_JOURNAL_FILE" \
    CLEANUP_RESTORE_MANIFEST="$CLEANUP_RESTORE_MANIFEST" \
    QUARANTINE_ROOT="$QUARANTINE_ROOT" \
    QUARANTINE_RUN_DIR="$QUARANTINE_RUN_DIR" \
    bash "$SCRIPT_PATH" --restore "$CLEANUP_RESTORE_MANIFEST" --non-interactive --no-color)"
assert_eq "$RC" "0" "cleanup_all --restore should exit 0"
if [[ "$RC" == "0" ]]; then
    assert_file_exists "$cli_restore_target" "restore CLI should recreate original file"
    assert_file_absent "$cli_quarantine_path" "restore CLI should move item out of quarantine"
    assert_file_content_eq "$cli_restore_target" "restore-cli-payload" "restore CLI should preserve file content"
fi

# ---------------------------------------------------------------------------
begin_test "cleanup_all --list-quarantine lists existing run"
start_case
list_payload="${QUARANTINE_RUN_DIR}/items/list.payload"
make_file "$list_payload" "list-payload"
LIST_OUTPUT="${CASE_DIR}/list_quarantine.out"

RC="$(run_cmd_capture "$LIST_OUTPUT" env \
    HOME="$HOME" USER="$USER" LOG_LEVEL="INFO" NO_COLOR=1 \
    QUARANTINE_ROOT="$QUARANTINE_ROOT" \
    bash "$SCRIPT_PATH" --list-quarantine --non-interactive --no-color)"
assert_eq "$RC" "0" "cleanup_all --list-quarantine should exit 0"
assert_true "grep -q \"$RUN_TIMESTAMP\" \"$LIST_OUTPUT\"" "list output should include run id"
assert_true "grep -q \"Quarantine List — listing entries\" \"$LIST_OUTPUT\"" "list output should show Quarantine List mode in summary"
assert_false "grep -q \"Freed directly\" \"$LIST_OUTPUT\"" "list output should not claim Freed directly in summary"
assert_file_exists "$list_payload" "list should not mutate quarantine"

# ---------------------------------------------------------------------------
begin_test "cleanup_all --purge-quarantine requires --apply"
start_case
purge_payload="${QUARANTINE_RUN_DIR}/items/purge.payload"
make_file "$purge_payload" "purge-payload"
PURGE_PREVIEW_OUTPUT="${CASE_DIR}/purge_preview.out"

RC="$(run_cmd_capture "$PURGE_PREVIEW_OUTPUT" env \
    HOME="$HOME" USER="$USER" LOG_LEVEL="INFO" NO_COLOR=1 \
    CLEANUP_JOURNAL_FILE="$CLEANUP_JOURNAL_FILE" \
    QUARANTINE_ROOT="$QUARANTINE_ROOT" \
    bash "$SCRIPT_PATH" --purge-quarantine "$RUN_TIMESTAMP" --non-interactive --no-color)"
assert_eq "$RC" "0" "purge preview should exit 0"
assert_file_exists "$purge_payload" "purge preview should not delete quarantine"

PURGE_APPLY_OUTPUT="${CASE_DIR}/purge_apply.out"
RC="$(run_cmd_capture "$PURGE_APPLY_OUTPUT" env \
    HOME="$HOME" USER="$USER" LOG_LEVEL="INFO" NO_COLOR=1 \
    CLEANUP_JOURNAL_FILE="$CLEANUP_JOURNAL_FILE" \
    CLEANUP_RESTORE_MANIFEST="$CLEANUP_RESTORE_MANIFEST" \
    QUARANTINE_ROOT="$QUARANTINE_ROOT" \
    bash "$SCRIPT_PATH" --purge-quarantine "$RUN_TIMESTAMP" --apply --non-interactive --no-color)"
assert_eq "$RC" "0" "purge with --apply should exit 0"
assert_file_absent "$QUARANTINE_RUN_DIR" "purge with --apply should remove quarantine run"

# ---------------------------------------------------------------------------
begin_test "protected user roots still abort before quarantine"
start_case
mkdir -p "$HOME/Library/Caches/allowed-child"

for protected_root in "$HOME" "$HOME/Library" "$HOME/Library/Caches"; do
    PROTECTED_OUTPUT="${CASE_DIR}/protected_${protected_root##*/}.out"
    RC="$(run_safe_remove_capture_rc "$protected_root" "$PROTECTED_OUTPUT")"
    assert_eq "$RC" "1" "safe_remove should block protected root (P1-12): ${protected_root}"
    assert_file_exists "$protected_root" "protected root should remain present: ${protected_root}"
done

# ---------------------------------------------------------------------------
begin_test "system roots are only classified protected, not removed with sudo"
start_case
assert_true "is_protected_path '/'" "root should be protected"
assert_true "is_protected_path '/System'" "/System should be protected"
assert_true "is_protected_path '/Library'" "/Library should be protected"

print_test_summary
