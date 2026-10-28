#!/usr/bin/env bash
# =============================================================================
# tests/test_path_protection_case.sh — P0-2 regression lock
#
# Protected-path matching MUST be case-insensitive (macOS APFS is case-
# insensitive by default, so `~/Library/mail` is the same object as
# `~/Library/Mail`) and robust to repeated slashes under bash 3.2.
# A case/`//` variant of a protected path that `is_protected_path` reports as
# "allowed" is a data-loss bypass (plan paths, --exclude, --restore).
#
# Run directly under stock bash too:  /bin/bash tests/test_path_protection_case.sh
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_pathcase.XXXXXX)"
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
source "${TEST_DIR}/helpers.sh"

# Mirror production preflight: populate the pre-normalized NEVER_TOUCH array.
normalize_never_touch_paths

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

assert_protected() {
    local path="$1" label="${2:-$1}"
    if is_protected_path "$path"; then _pass; else _fail "MUST be protected: ${label} (${path})"; fi
}
assert_unprotected() {
    local path="$1" label="${2:-$1}"
    if is_protected_path "$path"; then _fail "should NOT be protected: ${label} (${path})"; else _pass; fi
}

# ---------------------------------------------------------------------------
# Case variants of NEVER_TOUCH entries (lower / UPPER / Mixed)
# ---------------------------------------------------------------------------
begin_test "P0-2: case-variant Mail is protected"
assert_protected "$HOME/Library/mail"              "lowercase mail"
assert_protected "$HOME/library/Mail"              "lowercase library"
assert_protected "$HOME/LIBRARY/MAIL"              "uppercase"
assert_protected "$HOME/Library/mail/V10"          "case variant + child"

begin_test "P0-2: case-variant user data / credentials protected"
assert_protected "$HOME/documents"                 "lowercase documents"
assert_protected "$HOME/.SSH"                       "uppercase .ssh"
assert_protected "$HOME/Library/Application Support/1PASSWORD" "uppercase 1Password"

# ---------------------------------------------------------------------------
# Case variants of broad roots (in the is_protected_path case block)
# ---------------------------------------------------------------------------
begin_test "P0-2: case-variant broad roots protected"
assert_protected "$HOME/library"                   "lowercase ~/Library root"
assert_protected "$HOME/library/caches"            "lowercase ~/Library/Caches root"

# ---------------------------------------------------------------------------
# Repeated-slash robustness (bash 3.2 normalize bug)
# ---------------------------------------------------------------------------
begin_test "P0-2: root spellings stay protected (normalize must not return empty success)"
assert_protected "/"                               "root"
assert_protected "//"                              "double-slash root"

begin_test "P0-2: trailing . / .. on existing paths resolve before matching"
mkdir -p "$HOME/Library/Caches/com.foo"
assert_protected "$HOME/Library/Caches/.."         "Caches/.. is ~/Library"
assert_protected "$HOME/Library/Caches/com.foo/../.." "nested .. is ~/Library"
assert_protected "$HOME/.."                         "HOME/.. is the users root"
assert_protected "$HOME/Library/Caches/."          "Caches/. is the Caches root"

begin_test "P0-2: // separators do not bypass protection"
assert_protected "$HOME/Library//Mail"             "double slash"
assert_protected "$HOME/Documents//sub"            "double slash + child"
assert_protected "$HOME/Library//mail"             "double slash + case"

# ---------------------------------------------------------------------------
# NEVER_TOUCH completeness: Messages / Calendars / AddressBook (user data)
# ---------------------------------------------------------------------------
begin_test "P0-2: Messages / Calendars / Contacts protected"
assert_protected "$HOME/Library/Messages"          "Messages (iMessage chat.db)"
assert_protected "$HOME/library/messages"          "Messages case variant"
assert_protected "$HOME/Library/Calendars"         "Calendars"
assert_protected "$HOME/Library/Application Support/AddressBook" "Contacts"

# ---------------------------------------------------------------------------
# Quarantine self-protection must also ignore case (custom QUARANTINE_ROOT)
# ---------------------------------------------------------------------------
begin_test "P0-2: case-variant quarantine paths are recognised as quarantine"
_q_parent="${QUARANTINE_ROOT%/*}"
if is_quarantine_path "${_q_parent}/QUARANTINE/run1/items/f"; then _pass; else _fail "QUARANTINE variant must be quarantine"; fi
if is_quarantine_path "${_q_parent}/Quarantine"; then _pass; else _fail "Quarantine root variant must be quarantine"; fi
if is_quarantine_path "${_q_parent}/quarantine-other/x"; then _fail "sibling must not match"; else _pass; fi

# ---------------------------------------------------------------------------
# Must NOT over-protect: ordinary caches stay cleanable in any case
# ---------------------------------------------------------------------------
begin_test "P0-2: ordinary app caches remain unprotected (no over-blocking)"
assert_unprotected "$HOME/Library/Caches/com.foo"       "normal cache leaf"
assert_unprotected "$HOME/Library/Caches/Com.Foo"       "normal cache leaf (mixed case)"
assert_unprotected "$HOME/Library/Caches/com.spotify.client" "spotify cache"

print_test_summary
