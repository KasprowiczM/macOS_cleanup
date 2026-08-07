#!/usr/bin/env bash
# =============================================================================
# tests/test_safety_regressions.sh - focused coverage for safety hotfixes.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"

# We use a temp directory to simulate the filesystem.
SANDBOX="$(mktemp -d -t macos_cleanup_test_safety.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
TEST_HOME="${SANDBOX}/home"
mkdir -p "$TEST_HOME"

export HOME="$TEST_HOME"
export USER="${USER:-testuser}"
export LOG_LEVEL="INFO"
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

LOG_FILE="${SANDBOX}/test.log"
C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM=''
NEVER_TOUCH_PATHS=()
RULES_FILE="${PROJ_DIR}/cleanup_rules.yaml"

# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() {
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

run_cmd_capture() {
    local out_file="$1"; shift
    set +e
    "$@" >"$out_file" 2>&1
    local rc=$?
    set -u
    echo "$rc"
}

create_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    printf 'fixture\n' > "$path"
}

assert_path_protected() {
    local path="$1"
    local label="$2"

    if is_protected_path "$path"; then
        _pass
    else
        _fail "${label} should be protected by is_protected_path: ${path}"
    fi
}

assert_safe_remove_blocks() {
    local path="$1"
    local label="$2"
    local rc

    set +e
    (
        DRY_RUN=1
        TOTAL_WOULD_FREE_BYTES=0
        TOTAL_CLEANED_BYTES=0
        path_size_bytes() { echo 1; }
        safe_remove "$path" >/dev/null 2>&1
    )
    rc=$?
    set -u

    assert_eq "$rc" "1" "${label} should be rejected by safe_remove (P1-12)"
}

# ---------------------------------------------------------------------------
begin_test "explicit dry-run with --yes stays analysis-only"
DRY_HOME="$(mktemp -d "${SANDBOX}/dry_home.XXXXXX")"
DRY_TRASH_ITEM="${DRY_HOME}/.Trash/keep-me.txt"
DRY_OUTPUT="$(mktemp "${SANDBOX}/dry_output.XXXXXX")"
create_file "$DRY_TRASH_ITEM"

RC=$(run_cmd_capture "$DRY_OUTPUT" env HOME="$DRY_HOME" NO_COLOR=1 \
    bash "$SCRIPT_PATH" --dry-run --non-interactive --yes --category trash --no-color)

assert_eq "$RC" "0" "dry-run CLI should exit successfully"
assert_file_exists "$DRY_TRASH_ITEM" "explicit dry-run must not remove Trash contents"
if grep -q "FAZA 2" "$DRY_OUTPUT" || grep -q "Czyszczenie: Kosz" "$DRY_OUTPUT"; then
    _fail "dry-run --non-interactive --yes entered cleanup flow"
else
    _pass
fi

# ---------------------------------------------------------------------------
begin_test "broad roots are protected by is_protected_path"
mkdir -p \
    "$HOME/Library/Application Support" \
    "$HOME/Library/Preferences"

for protected_root in \
    "$HOME" \
    "$HOME/Library" \
    "$HOME/Library/Application Support" \
    "$HOME/Library/Preferences" \
    "/" \
    "/private" \
    "/var" \
    "/Applications"; do
    assert_path_protected "$protected_root" "broad root (${protected_root})"
done

begin_test "broad roots are rejected by safe_remove"
for protected_root in \
    "$HOME" \
    "$HOME/Library" \
    "$HOME/Library/Application Support" \
    "$HOME/Library/Preferences" \
    "/" \
    "/private" \
    "/var" \
    "/Applications"; do
    assert_safe_remove_blocks "$protected_root" "broad root (${protected_root})"
done

# ---------------------------------------------------------------------------
begin_test "cleanup_rules.yaml safety never paths load after type lines"
NEVER_TOUCH_PATHS=()
RULES_FILE="${PROJ_DIR}/cleanup_rules.yaml"
load_never_paths_from_rules

assert_array_var_contains_exact "NEVER_TOUCH_PATHS" \
    "${HOME}/Library/Application Support/Google/Chrome" \
    "Chrome profile from real rules should be loaded as never-touch"
assert_array_var_contains_exact "NEVER_TOUCH_PATHS" \
    "${HOME}/Library/Group Containers/UBF8T346G9.Office" \
    "Office group container from real rules should be loaded as never-touch"
assert_array_var_contains_exact "NEVER_TOUCH_PATHS" \
    "${HOME}/Library/Application Support/Adobe" \
    "Adobe data root from real rules should be loaded as never-touch"
assert_array_var_contains_exact "NEVER_TOUCH_PATHS" \
    "/Library/Keychains" \
    "System keychains from real rules should be loaded as never-touch"

# ---------------------------------------------------------------------------
begin_test "auto-safe does not delete Trash"
AUTO_HOME="$(mktemp -d "${SANDBOX}/auto_home.XXXXXX")"
AUTO_TRASH_ITEM="${AUTO_HOME}/.Trash/keep-me.txt"
AUTO_OUTPUT="$(mktemp "${SANDBOX}/auto_output.XXXXXX")"
create_file "$AUTO_TRASH_ITEM"

RC=$(run_cmd_capture "$AUTO_OUTPUT" env HOME="$AUTO_HOME" NO_COLOR=1 \
    bash "$SCRIPT_PATH" --auto-safe --non-interactive --yes --category trash --no-color)

assert_eq "$RC" "0" "auto-safe CLI should exit successfully"
assert_file_exists "$AUTO_TRASH_ITEM" "auto-safe must not remove Trash contents"
if grep -q "Czyszczenie: Kosz (auto-safe)" "$AUTO_OUTPUT"; then
    _fail "auto-safe entered Trash cleanup flow"
else
    _pass
fi

# ---------------------------------------------------------------------------
begin_test "non-interactive --yes does not approve medium risk prompts"
NON_INTERACTIVE=1
AUTO_YES=1
TOTAL_SKIPPED_ITEMS=0
WARNINGS_LIST=()
set +e
confirm_category \
    --title "Medium risk fixture" \
    --size "1 KB" \
    --what "fixture" \
    --consequence "fixture" \
    --safe-if "fixture" \
    --risk "MEDIUM" >/dev/null 2>&1
RC=$?
set -u
assert_eq "$RC" "1" "MEDIUM risk prompt should not auto-confirm"
assert_eq "$TOTAL_SKIPPED_ITEMS" "1" "blocked medium prompt should be recorded as skipped"
NON_INTERACTIVE=0
AUTO_YES=0

print_test_summary
