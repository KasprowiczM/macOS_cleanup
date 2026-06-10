#!/usr/bin/env bash
# =============================================================================
# tests/test_cli.sh — CLI argument handling and guardrail validation.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"
CLI_HOME="$(mktemp -d -t macos_cleanup_test_cli_home.XXXXXX)"
LOG_LEVEL="INFO"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() {
    rm -rf "$CLI_HOME"
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

begin_test "CLI --help prints usage and exits 0"
HELP_OUTPUT="$(mktemp -t macos_cleanup_cli_help.XXXXXX)"
RC=$(run_cmd_capture "$HELP_OUTPUT" bash "$SCRIPT_PATH" --help)
assert_eq "$RC" "0"
assert_true "grep -q \"Kategorie:\" \"$HELP_OUTPUT\""
rm -f "$HELP_OUTPUT"

begin_test "CLI --version prints script version"
VERSION_OUTPUT="$(bash "$SCRIPT_PATH" --version | tr -d '\r\n')"
assert_eq "$VERSION_OUTPUT" "cleanup_all.sh version ${SCRIPT_VERSION}"

begin_test "CLI rejects invalid --log-level"
LOG_LEVEL_OUTPUT="$(mktemp -t macos_cleanup_cli_loglevel.XXXXXX)"
RC=$(run_cmd_capture "$LOG_LEVEL_OUTPUT" bash "$SCRIPT_PATH" --log-level garbage --category logs --non-interactive)
assert_eq "$RC" "2"
assert_true "grep -q \"Nieznany poziom logów\" \"$LOG_LEVEL_OUTPUT\""
rm -f "$LOG_LEVEL_OUTPUT"

begin_test "CLI rejects unknown category"
CAT_OUTPUT="$(mktemp -t macos_cleanup_cli_category.XXXXXX)"
RC=$(run_cmd_capture "$CAT_OUTPUT" bash "$SCRIPT_PATH" --category does-not-exist --dry-run)
assert_eq "$RC" "2"
assert_true "grep -q \"Nieznana kategoria\" \"$CAT_OUTPUT\""
rm -f "$CAT_OUTPUT"

begin_test "CLI accepts include alias, --yes and lower-case log-level"
DRY_RUN_OUTPUT="$(mktemp -t macos_cleanup_cli_dryrun.XXXXXX)"
RC=$(run_cmd_capture "$DRY_RUN_OUTPUT" env HOME="$CLI_HOME" bash "$SCRIPT_PATH" --dry-run --non-interactive --yes --include trash --log-level debug)
assert_eq "$RC" "0"
assert_true "grep -q \"FAZA 1: Analiza systemu\" \"$DRY_RUN_OUTPUT\""
assert_false "grep -q \"Inwentarz aplikacji\" \"$DRY_RUN_OUTPUT\"" "category dry-run should skip heavyweight full-scan inventories"
rm -f "$DRY_RUN_OUTPUT"

begin_test "auto-safe keeps generic user cache but quarantines explicit safe app cache"
AUTO_SAFE_OUTPUT="$(mktemp -t macos_cleanup_cli_autosafe.XXXXXX)"
GENERIC_CACHE="$CLI_HOME/Library/Caches/com.example.generic"
SPOTIFY_CACHE="$CLI_HOME/Library/Caches/com.spotify.client"
mkdir -p "$GENERIC_CACHE" "$SPOTIFY_CACHE"
printf 'generic' > "$GENERIC_CACHE/payload.txt"
dd if=/dev/zero of="$SPOTIFY_CACHE/payload.txt" bs=1024 count=16 2>/dev/null
RC=$(run_cmd_capture "$AUTO_SAFE_OUTPUT" env HOME="$CLI_HOME" USER="${USER:-testuser}" bash "$SCRIPT_PATH" --auto-safe --non-interactive --yes --category user-caches --no-color)
assert_eq "$RC" "0"
assert_file_exists "$GENERIC_CACHE/payload.txt" "generic cache should remain for interactive review"
assert_file_absent "$SPOTIFY_CACHE" "explicit safe app cache should be moved to quarantine"
assert_true "find \"$CLI_HOME/Library/Application Support/macOS_cleanup/quarantine\" -path '*com.spotify.client/payload.txt' -type f -print -quit | grep -q ."
rm -f "$AUTO_SAFE_OUTPUT"

print_test_summary
