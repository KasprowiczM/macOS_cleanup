#!/usr/bin/env bash
# =============================================================================
# tests/test_common.sh — unit tests for lib/common.sh pure helpers.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# Minimal env expected by lib/common.sh sourcing.
LOG_LEVEL="INFO"
LOG_FILE="$(mktemp -t macos_cleanup_testlog.XXXXXX)"
_COMMON_TEST_TMPDIR="$(mktemp -d -t macos_cleanup_test_common.XXXXXX)"
export LOGS_DIR="${_COMMON_TEST_TMPDIR}/logs"
export REPORTS_DIR="${_COMMON_TEST_TMPDIR}/reports"
export CLEANUP_JOURNAL_FILE="${_COMMON_TEST_TMPDIR}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${_COMMON_TEST_TMPDIR}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${_COMMON_TEST_TMPDIR}/quarantine"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"
# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() {
    rm -f "$LOG_FILE"
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    [[ -n "${_COMMON_TEST_TMPDIR:-}" && -d "$_COMMON_TEST_TMPDIR" ]] && rm -rf "$_COMMON_TEST_TMPDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
begin_test "bytes_to_human small bytes"
assert_eq "$(bytes_to_human 0)"     "0 B"
assert_eq "$(bytes_to_human 1023)"  "1023 B"

begin_test "bytes_to_human KB/MB/GB"
assert_eq "$(bytes_to_human 1024)"        "1.0 KB"
assert_eq "$(bytes_to_human 1048576)"     "1.0 MB"
assert_eq "$(bytes_to_human 1073741824)"  "1.00 GB"

begin_test "bytes_to_human non-numeric input"
assert_eq "$(bytes_to_human "")"    "0 B"
assert_eq "$(bytes_to_human "abc")" "0 B"

# ---------------------------------------------------------------------------
begin_test "catbytes set/get/add round-trip"
catbytes_set "trash" 5000
assert_eq "$(catbytes_get "trash")" "5000"
catbytes_add "trash" 2500
assert_eq "$(catbytes_get "trash")" "7500"

begin_test "catbytes default is zero for unknown key"
assert_eq "$(catbytes_get "never-set")" "0"

begin_test "catbytes hyphenated keys"
catbytes_set "xcode-derived" 42
assert_eq "$(catbytes_get "xcode-derived")" "42"

# ---------------------------------------------------------------------------
begin_test "is_protected_path: exact match"
assert_true  "is_protected_path '$HOME/.ssh'"          "\$HOME/.ssh should be protected"
assert_true  "is_protected_path '$HOME/Documents'"     "Documents should be protected"
assert_true  "is_protected_path '$HOME/.Trash'"        "Trash root should be protected"

begin_test "is_protected_path: subpath match"
assert_true  "is_protected_path '$HOME/.ssh/id_ed25519'" "subpath of \$HOME/.ssh protected"
assert_true  "is_protected_path '$HOME/Documents/tax/2024.pdf'" "subpath of Documents protected"

begin_test "is_protected_path: unrelated path is NOT protected"
assert_false "is_protected_path '/tmp/xyz'"             "/tmp/xyz should not be protected"
assert_false "is_protected_path '$HOME/.Trash/item.txt'" "Trash contents should remain cleanable"

begin_test "is_protected_path: near-miss prefix not matched"
# '$HOME/.sshfoo' must NOT match '$HOME/.ssh'.
assert_false "is_protected_path '$HOME/.sshfoo'"        "near-miss prefix not protected"

begin_test "is_protected_path: protected system/user roots"
assert_true  "is_protected_path '/System/Library'"                   "/System path should be protected"
assert_true  "is_protected_path '/Users'"                            "/Users root should be protected"
assert_true  "is_protected_path '/Users/anotheruser/Library/Documents'" "other user paths should be protected"
assert_true  "is_protected_path '/Library/Caches'"                   "Library cache root should be protected"
assert_false "is_protected_path '/Library/Caches/com.example.app'"    "Library cache children may be cleanable in dedicated flow"
assert_true  "is_protected_path '/Library/Logs'"                     "Library logs root should be protected"
assert_false "is_protected_path '/Library/Logs/example.log'"          "Library log files may be cleanable in dedicated flow"
assert_true  "is_protected_path '/Library/PrivateFrameworks'"        "/Library private framework path should be protected"

begin_test "normalize_path handles tilde and relative segments"
# shellcheck disable=SC2088
assert_eq "$(normalize_path '~/.ssh')" "$HOME/.ssh"
assert_eq "$(normalize_path '$HOME/.ssh')" "$HOME/.ssh"
EXPECTED_TMP="/tmp"
if command -v realpath >/dev/null 2>&1; then
    EXPECTED_TMP="$(realpath -m /tmp 2>/dev/null || echo /tmp)"
fi
if [[ "$EXPECTED_TMP" == "/tmp" ]]; then
    EXPECTED_TMP="$(cd -P /tmp 2>/dev/null && pwd -P || echo /tmp)"
fi
assert_eq "$(normalize_path '/tmp/../tmp')" "$EXPECTED_TMP"

tmp_abs="$(mktemp -d -t macos_cleanup_norm.XXXXXX)"
mkdir -p "${tmp_abs}/deep/path"
EXPECTED_DEEP="${tmp_abs}/deep/path"
if command -v realpath >/dev/null 2>&1; then
    EXPECTED_DEEP="$(realpath -m "${tmp_abs}/deep/path" 2>/dev/null || echo "${tmp_abs}/deep/path")"
fi
if [[ "$EXPECTED_DEEP" == "${tmp_abs}/deep/path" ]]; then
    EXPECTED_DEEP="$(cd -P "${tmp_abs}/deep/path" 2>/dev/null && pwd -P || echo "${tmp_abs}/deep/path")"
fi
assert_eq "$(cd "$tmp_abs" && normalize_path 'deep/../deep/path')" "$EXPECTED_DEEP"
rm -rf "$tmp_abs"

begin_test "load_never_paths_from_rules supports mixed YAML path entries"
RULES_FILE_TMP="$(mktemp -t cleanup_rules_test.XXXXXX)"
cat > "$RULES_FILE_TMP" <<'EOF'
- path: "$HOME/Library/RuleOne"
  safety: never

- path: "~/Library/RuleTwo"
  safety: never

# safety should not be added for this one
- path: "$HOME/Library/RuleSkip"
  safety: ask

path: "/tmp/RuleThree"
safety: never

path: "/tmp/RuleFour"
safety: safe
EOF
NEVER_TOUCH_PATHS=()
RULES_FILE="$RULES_FILE_TMP"
load_never_paths_from_rules
assert_array_var_contains_exact "NEVER_TOUCH_PATHS" "${HOME}/Library/RuleOne"
assert_array_var_contains_exact "NEVER_TOUCH_PATHS" "${HOME}/Library/RuleTwo"
EXPECTED_RULE_THREE="$(normalize_path "/tmp/RuleThree")"
assert_array_var_contains_exact "NEVER_TOUCH_PATHS" "$EXPECTED_RULE_THREE"
assert_array_var_not_contains_exact "NEVER_TOUCH_PATHS" "${HOME}/Library/RuleSkip"
rm -f "$RULES_FILE_TMP"

begin_test "record_user_decision tracks required decisions"
TOTAL_USER_DECISIONS_NEEDED=0
USER_DECISION_ITEMS=()
record_user_decision "Decyzja testowa"
assert_eq "$TOTAL_USER_DECISIONS_NEEDED" "1"
assert_eq "${USER_DECISION_ITEMS[0]}" "Decyzja testowa"

begin_test "record_skipped_item tracks skips and warnings"
TOTAL_SKIPPED_ITEMS=0
WARNINGS_LIST=()
record_skipped_item "Pominięto test"
assert_eq "$TOTAL_SKIPPED_ITEMS" "1"
assert_array_var_contains_exact "WARNINGS_LIST" "Skipped: Pominięto test"

# ---------------------------------------------------------------------------
begin_test "safe_remove in dry-run does not delete"
SANDBOX="$(make_sandbox)"
target="${SANDBOX}/victim.txt"
echo "hello" > "$target"
DRY_RUN=1
TOTAL_WOULD_FREE_BYTES=0
TOTAL_CLEANED_BYTES=0
safe_remove "$target" >/dev/null
assert_file_exists "$target"                         "dry-run must NOT remove file"
assert_true "(( TOTAL_WOULD_FREE_BYTES > 0 ))"       "would-free counter incremented"
assert_eq   "${TOTAL_CLEANED_BYTES}" "0"             "cleaned counter must stay 0 in dry-run"

begin_test "safe_remove in real mode deletes"
real_target="${SANDBOX}/real.txt"
echo "goodbye" > "$real_target"
DRY_RUN=0
REMOVE_MODE=permanent
prev_cleaned="$TOTAL_CLEANED_BYTES"
safe_remove "$real_target" >/dev/null
assert_file_absent "$real_target"                    "real mode must remove file"
assert_true "(( TOTAL_CLEANED_BYTES > prev_cleaned ))" "cleaned counter incremented"

begin_test "safe_remove on missing path is a no-op"
DRY_RUN=0
REMOVE_MODE=permanent
prev_cleaned="$TOTAL_CLEANED_BYTES"
safe_remove "${SANDBOX}/does-not-exist" >/dev/null
assert_eq "$TOTAL_CLEANED_BYTES" "$prev_cleaned"     "missing path must not change counter"

# ---------------------------------------------------------------------------
# P1-12: protected-path violations now skip (return 1), not abort (exit 99).
begin_test "safe_remove skips on protected path (P1-12, return 1)"
DRY_RUN=0
REMOVE_MODE=quarantine
prev_cleaned="$TOTAL_CLEANED_BYTES"
# Use $HOME/Documents which is in NEVER_TOUCH_PATHS; ensure it exists
mkdir -p "$HOME/Documents"
_test_marker="${HOME}/Documents/_test_marker_safe_remove_$$"
echo "precious" > "$_test_marker"
set +e
(
    safe_remove "$HOME/Documents" >/dev/null 2>&1
)
rc=$?
set -u
assert_eq "$rc" "1" "safe_remove must return 1 on protected path"
assert_eq "$TOTAL_CLEANED_BYTES" "$prev_cleaned" "protected path must not change counter"
assert_file_exists "$_test_marker" "protected directory contents must NOT be deleted"
rm -f "$_test_marker"

# ---------------------------------------------------------------------------
begin_test "log file receives plain-text (no ANSI escapes)"
: > "$LOG_FILE"
print_found "colored $(printf '\033[2m')dim$(printf '\033[0m') text" >/dev/null
# If any raw ESC (0x1B) byte landed in the log, fail.
if grep -q $'\x1B' "$LOG_FILE"; then
    _fail "log file contains raw ESC byte"
else
    _pass
fi


# ---------------------------------------------------------------------------
# PF3: verify precomputed NEVER_TOUCH cache
# ---------------------------------------------------------------------------
begin_test "PF3: _NEVER_TOUCH_NORMALIZED populated by normalize_never_touch_paths"
NEVER_TOUCH_PATHS=("$HOME/.ssh" "$HOME/Documents" "$HOME/Library/Mail")
_NEVER_TOUCH_NORMALIZED=()
normalize_never_touch_paths
assert_true "(( ${#_NEVER_TOUCH_NORMALIZED[@]} == 3 ))" "_NEVER_TOUCH_NORMALIZED has 3 entries"

begin_test "PF3: is_protected_path unchanged after precompute"
NEVER_TOUCH_PATHS=("$HOME/.ssh" "$HOME/Documents" "$HOME/Library/Mail")
_NEVER_TOUCH_NORMALIZED=()
normalize_never_touch_paths
assert_true  "is_protected_path '$HOME/.ssh'"            "\$HOME/.ssh still protected after precompute"
assert_true  "is_protected_path '$HOME/Documents'"       "Documents still protected after precompute"
assert_true  "is_protected_path '$HOME/Library/Mail'"    "Mail still protected after precompute"
assert_true  "is_protected_path '$HOME/.ssh/id_ed25519'" "subpath still protected after precompute"
assert_true  "is_protected_path '$HOME/Library/Mail/V10/MailData'" "Mail subpath still protected"
assert_false "is_protected_path '$HOME/.sshfoo'"         "near-miss still not protected after precompute"
assert_false "is_protected_path '/tmp/xyz'"              "unrelated still not protected after precompute"

begin_test "PF3: is_protected_path falls back when _NEVER_TOUCH_NORMALIZED empty"
NEVER_TOUCH_PATHS=("$HOME/.ssh" "$HOME/Documents")
_NEVER_TOUCH_NORMALIZED=()
assert_true  "is_protected_path '$HOME/.ssh'"      "fallback: \$HOME/.ssh still protected"
assert_true  "is_protected_path '$HOME/Documents'"  "fallback: Documents still protected"

# ---------------------------------------------------------------------------
# PF4: verify app bundle ID caching and detection
# ---------------------------------------------------------------------------
begin_test "PF4: app_bundle_exists uses mdfind fast path"
APP_BUNDLE_SEARCH_DIRS=("${SANDBOX}/Applications")
APP_BUNDLE_ID_CACHE_LOADED=0
APP_BUNDLE_ID_CACHE=""
# shellcheck disable=SC2329
mdfind() {
    case "$*" in
        *com.example.fastpath*)
            printf '%s\n' "${SANDBOX}/Applications/FastPath.app"
            ;;
        *)
            return 0
            ;;
    esac
}
assert_true "app_bundle_exists 'com.example.fastpath'" "Bundle should be found via mdfind"
assert_eq "$APP_BUNDLE_ID_CACHE_LOADED" "0" "mdfind path should not load fallback cache"
unset -f mdfind

begin_test "PF4: app_bundle_exists works via sandboxed plist fallback"
APP_BUNDLE_SEARCH_DIRS=("${SANDBOX}/Applications")
APP_BUNDLE_ID_CACHE_LOADED=0
APP_BUNDLE_ID_CACHE=""
mkdir -p "${APP_BUNDLE_SEARCH_DIRS[0]}/Mock.app/Contents"
cat > "${APP_BUNDLE_SEARCH_DIRS[0]}/Mock.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.mockapp</string>
</dict>
</plist>
EOF
# shellcheck disable=SC2329
mdfind() {
    return 1
}
assert_true "app_bundle_exists 'com.example.mockapp'" "Sandbox app bundle should exist via directory fallback"
assert_false "app_bundle_exists 'com.example.missing'" "Missing sandbox bundle should not exist"
unset -f mdfind
APP_BUNDLE_SEARCH_DIRS=("/Applications" "$HOME/Applications" "/System/Applications")
normalize_never_touch_paths 2>/dev/null || true

# ---------------------------------------------------------------------------
# Regression: the sudo keep-alive background loop must be `disown`ed so that a
# signal-kill (e.g. interrupting the run) does NOT leak a job-control notice
# like "lib/common.sh: line N: <pid> Terminated: 15 ( while true; ... )".
# We run the scenario in a child bash and capture its combined output.
# ---------------------------------------------------------------------------
_run_keepalive_scenario() {
    # $1 = "raw" (pre-fix control) or "fixed" (real _start_sudo_keepalive)
    local mode="$1"
    MODE="$mode" bash -c '
        set -u
        SUDO_KEEPALIVE_PID=""
        source "'"${PROJ_DIR}"'/lib/common.sh"
        if [[ "$MODE" == "fixed" ]]; then
            _start_sudo_keepalive
        else
            # Raw pre-fix pattern: a tracked background job, no disown.
            (while true; do sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null) &
            SUDO_KEEPALIVE_PID=$!
        fi
        kill -TERM "$SUDO_KEEPALIVE_PID" 2>/dev/null
        # Parent keeps executing commands so a *tracked* dead job would be reported.
        sleep 0.2; :; sleep 0.2; :
    ' 2>&1
}

begin_test "keepalive control: raw pattern DOES leak a Terminated job notice"
_KP_RAW_OUT="$(_run_keepalive_scenario raw)"
if [[ "$(uname -s)" == "Darwin" ]]; then
    assert_true "printf '%s' \"\$_KP_RAW_OUT\" | grep -qi terminated" \
        "raw (no disown) keepalive should leak 'Terminated' — proves the test detects the bug"
fi

begin_test "keepalive fixed: _start_sudo_keepalive disowns; no Terminated notice leaks"
_KP_FIXED_OUT="$(_run_keepalive_scenario fixed)"
assert_false "printf '%s' \"\$_KP_FIXED_OUT\" | grep -qi terminated" \
    "disowned keepalive must NOT print a 'Terminated' job-control notice"

print_test_summary
