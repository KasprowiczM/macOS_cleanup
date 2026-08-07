#!/usr/bin/env bash
# =============================================================================
# tests/test_pathguard.sh — Unit tests for Path Provenance Engine [P0-2]
#
# Validates validate_cache_path() behavior against symlink traversal,
# out-of-bounds paths, protected system/user targets, hostile project overrides (.npmrc),
# and valid cache roots.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_pathguard.XXXXXX)"
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
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/pathguard.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers for pathguard assertions
# ---------------------------------------------------------------------------
assert_path_valid() {
    local target="$1" label="${2:-$1}"
    if validate_cache_path "$target"; then
        _pass
    else
        _fail "pathguard SHOULD accept valid cache path: ${label} (${target})"
    fi
}

assert_path_invalid() {
    local target="$1" label="${2:-$1}"
    if validate_cache_path "$target"; then
        _fail "pathguard SHOULD REJECT dangerous/out-of-bounds path: ${label} (${target})"
    else
        _pass
    fi
}

# Setup test directory structure in sandbox
mkdir -p "$HOME/Documents" "$HOME/Desktop" "$HOME/.ssh"
mkdir -p "$HOME/Library/Caches/com.example.goodapp"
mkdir -p "$HOME/Library/Caches/real_target_dir"
mkdir -p "$HOME/.cache/npm"

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

begin_test "Valid cache and disposable paths"
assert_path_valid "$HOME/Library/Caches/com.example.goodapp" "User app cache"
assert_path_valid "$HOME/Library/Caches/non_existent_cache_item" "Non-existent item in cache root"
assert_path_valid "$HOME/.cache/npm" "Dot-cache npm directory"
assert_path_valid "$HOME/Library/Logs/test_app.log" "User log path"

begin_test "Protected user and system roots must be rejected"
assert_path_invalid "$HOME/Documents" "Documents root"
assert_path_invalid "$HOME/Desktop" "Desktop root"
assert_path_invalid "$HOME/.ssh" "SSH directory"
assert_path_invalid "/etc" "System /etc"
assert_path_invalid "/System" "System root"
assert_path_invalid "/Library/Keychains" "System Keychains"

begin_test "Symlink traversal to /etc must be rejected"
ln -s "/etc" "$HOME/Library/Caches/symlink_to_etc"
assert_path_invalid "$HOME/Library/Caches/symlink_to_etc" "Symlink inside cache pointing to /etc"

begin_test "Symlink traversal to Documents must be rejected"
ln -s "$HOME/Documents" "$HOME/Library/Caches/symlink_to_docs"
assert_path_invalid "$HOME/Library/Caches/symlink_to_docs" "Symlink inside cache pointing to Documents"

begin_test "Valid symlink pointing inside allowed cache root"
ln -s "$HOME/Library/Caches/real_target_dir" "$HOME/Library/Caches/symlink_valid_cache"
assert_path_valid "$HOME/Library/Caches/symlink_valid_cache" "Symlink pointing within same cache root"

begin_test "Empty or invalid input arguments"
assert_path_invalid "" "Empty string candidate"
assert_path_invalid "relative/path/cache" "Relative path"

begin_test "Hostile .npmrc / project directory override rejected"
HOSTILE_PROJECT="$HOME/Projects/untrusted_app"
mkdir -p "$HOSTILE_PROJECT/.git"
touch "$HOSTILE_PROJECT/package.json"

assert_path_invalid "$HOSTILE_PROJECT" "Hostile project directory configured as npm cache"

# Test direct analyzer behavior with hostile path
FOUND_DEV_ITEMS=()
npm_cache_dir="$HOSTILE_PROJECT"
if validate_cache_path "$npm_cache_dir"; then
    FOUND_DEV_ITEMS+=("npm_cache:$npm_cache_dir")
else
    cleanup_journal_event "path_provenance_rejected" "$npm_cache_dir" "" "0" "blocked" "pathguard provenance validation failed"
fi

if [[ ${#FOUND_DEV_ITEMS[@]} -eq 0 ]]; then
    _pass
else
    _fail "Hostile project path MUST NOT be added to FOUND_DEV_ITEMS"
fi

if [[ -f "$CLEANUP_JOURNAL_FILE" ]] && grep -q "path_provenance_rejected" "$CLEANUP_JOURNAL_FILE"; then
    _pass
else
    _fail "path_provenance_rejected event MUST be recorded in journal"
fi

if [[ -d "$HOSTILE_PROJECT" && -f "$HOSTILE_PROJECT/package.json" ]]; then
    _pass
else
    _fail "Hostile project directory MUST survive on disk intact"
fi

print_test_summary
