#!/usr/bin/env bash
# =============================================================================
# tests/test_pathguard_anchor.sh — the cache-root allowlist has no environment
# escape hatch and no unanchored prefix.
#
# _is_within_allowed_cache_root accepted any path under "$SANDBOX" (an
# environment variable production code should not trust: SANDBOX=/ made every
# path an allowed cache root) and any path that merely started with the
# QUARANTINE_ROOT string (".../quarantine-evil" passed). Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

WORK="$(mktemp -d -t macos_cleanup_test_pathguard_anchor.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
export HOME="${WORK}/home"
export USER="${USER:-testuser}"
export LOG_LEVEL="ERROR"
export LOGS_DIR="${WORK}/logs"
export REPORTS_DIR="${WORK}/reports"
# Outside /var/folders (an allowed temp root) so only the rule under test can
# admit paths beneath it; QUARANTINE_ROOT is readonly once defaults load.
export QUARANTINE_ROOT="/Users/nobody-macos-cleanup-test/q/quarantine"
mkdir -p "$HOME" "$LOGS_DIR" "$REPORTS_DIR"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/pathguard.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# The allowlist check is lexical. Use a HOME outside /var/folders (itself an
# allowed temp root, where mktemp sandboxes live) so only the rules under test
# can admit these paths; nothing is created there.
FAKE_HOME="/Users/nobody-macos-cleanup-test"

begin_test "SANDBOX in the environment does not widen the cache roots"
HOME="$FAKE_HOME" SANDBOX="/" _is_within_allowed_cache_root "$FAKE_HOME/Documents/project"; rc=$?
assert_eq "$rc" "1" "SANDBOX=/ does not make ~/Documents a cache root"
HOME="$FAKE_HOME" SANDBOX="$FAKE_HOME" _is_within_allowed_cache_root "$FAKE_HOME/Documents/project"; rc=$?
assert_eq "$rc" "1" "SANDBOX=\$HOME does not either"

begin_test "the quarantine root is matched as a directory, not a string prefix"
HOME="$FAKE_HOME" _is_within_allowed_cache_root "$FAKE_HOME/q/quarantine/run/items/x"; rc=$?
assert_eq "$rc" "0" "inside the quarantine root"
HOME="$FAKE_HOME" _is_within_allowed_cache_root "$FAKE_HOME/q/quarantine-evil/x"; rc=$?
assert_eq "$rc" "1" "a sibling sharing the name prefix is not"

print_test_summary
