#!/usr/bin/env bash
# =============================================================================
# tests/test_quarantine_honesty.sh — P1-2: say what the quarantine mode does
#
# Quarantine mode only moves paths under HOME; safe_remove skips /tmp,
# /Library/Logs and /Library/Logs/DiagnosticReports. clean_tmp and clean_logs
# still asked for consent and recorded "cleaned" for those categories, and the
# headline called quarantined bytes "freeable" although nothing is freed until
# --purge-quarantine. Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_quarantine_honesty.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
export USER="${USER:-testuser}"
export LOG_LEVEL="ERROR"
export NO_COLOR=1
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$HOME/Library/Logs" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT" "${SANDBOX}/sys"

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
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/reporter.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# Nothing in this file may touch a real path: record instead of removing.
REMOVED=""
safe_remove() { REMOVED="${REMOVED}${1}"$'\n'; return 0; }
CONFIRM_CALLS=0
CONFIRM_RC=0
confirm_category() { CONFIRM_CALLS=$(( CONFIRM_CALLS + 1 )); return "$CONFIRM_RC"; }

USER_LOG="$HOME/Library/Logs/app.log"
SYS_LOG="${SANDBOX}/sys/system.log"      # outside HOME, like /Library/Logs
SYS_TMP="${SANDBOX}/sys/old.tmp"         # outside HOME, like /private/tmp
printf 'x' > "$USER_LOG"; printf 'y' > "$SYS_LOG"; printf 'z' > "$SYS_TMP"

reset_state() {
    FOUND_TMP_FILES=(); FOUND_APP_LOGS=(); FOUND_SYSTEM_LOGS=(); FOUND_DIAGNOSTIC_REPORTS=()
    CLEANUP_CATEGORY_OUTCOMES=""
    REMOVED=""; CONFIRM_CALLS=0; CONFIRM_RC=0
    MODE="interactive"; REMOVE_MODE="quarantine"; DRY_RUN=0
}

# ---------------------------------------------------------------------------
begin_test "clean_tmp in quarantine mode: no consent prompt, no false 'cleaned'"
reset_state
FOUND_TMP_FILES=("$SYS_TMP")
clean_tmp >/dev/null 2>&1
assert_eq "$CONFIRM_CALLS" "0" "no prompt for work the mode will not do"
assert_eq "$REMOVED" "" "nothing handed to safe_remove"
assert_eq "$(category_outcome tmp)" "needs-permanent" "outcome says it needs --permanent"

begin_test "clean_tmp in permanent mode still processes /tmp"
reset_state
REMOVE_MODE="permanent"
FOUND_TMP_FILES=("$SYS_TMP")
clean_tmp >/dev/null 2>&1
assert_eq "$CONFIRM_CALLS" "1" "permanent: prompt shown"
assert_eq "$REMOVED" "${SYS_TMP}"$'\n' "permanent: tmp handed to safe_remove"
assert_eq "$(category_outcome tmp)" "cleaned" "permanent: cleaned after consent"

# ---------------------------------------------------------------------------
begin_test "clean_logs in quarantine mode: user logs processed, system logs deferred"
reset_state
FOUND_APP_LOGS=("$USER_LOG")
FOUND_SYSTEM_LOGS=("$SYS_LOG")
clean_logs >/dev/null 2>&1
assert_eq "$CONFIRM_CALLS" "1" "one prompt for the user logs"
assert_eq "$REMOVED" "${USER_LOG}"$'\n' "only the user log reaches safe_remove"
assert_eq "$(category_outcome user-logs)" "cleaned" "user-logs cleaned"
assert_eq "$(category_outcome system-logs)" "needs-permanent" "system-logs not claimed as cleaned"

begin_test "clean_logs declined: user logs skipped, system logs still deferred"
reset_state
CONFIRM_RC=1
FOUND_APP_LOGS=("$USER_LOG")
FOUND_SYSTEM_LOGS=("$SYS_LOG")
clean_logs >/dev/null 2>&1
assert_eq "$REMOVED" "" "declined: nothing removed"
assert_eq "$(category_outcome user-logs)" "skipped" "declined: user-logs skipped"
assert_eq "$(category_outcome system-logs)" "needs-permanent" "declined: system-logs deferred"

begin_test "clean_logs with only system logs in quarantine mode: no prompt"
reset_state
FOUND_SYSTEM_LOGS=("$SYS_LOG")
clean_logs >/dev/null 2>&1
assert_eq "$CONFIRM_CALLS" "0" "no prompt"
assert_eq "$(category_outcome system-logs)" "needs-permanent" "system-logs deferred"

begin_test "clean_diagnostic_reports in quarantine mode skips non-user reports"
reset_state
FOUND_DIAGNOSTIC_REPORTS=("$SYS_LOG")
clean_diagnostic_reports >/dev/null 2>&1
assert_eq "$CONFIRM_CALLS" "0" "no prompt"
assert_eq "$(category_outcome diagnostic-reports)" "needs-permanent" "diagnostic-reports deferred"

# ---------------------------------------------------------------------------
begin_test "mixed lists: only user paths are processed and the outcome says partial"
reset_state
USER_TMP="$HOME/tmp_user.tmp"; printf 'abcd' > "$USER_TMP"
FOUND_TMP_FILES=("$USER_TMP" "$SYS_TMP")
catbytes_set "tmp" 999999
clean_tmp >/dev/null 2>&1
assert_eq "$REMOVED" "${USER_TMP}"$'\n' "mixed tmp: only the user path reaches safe_remove"
assert_eq "$(category_outcome tmp)" "partial" "mixed tmp: outcome partial, not cleaned"
assert_eq "$(processable_total_bytes 2 999999)" "$(path_size_bytes "$USER_TMP")" "mixed: prompt size is the processable size"

reset_state
USER_DIAG="$HOME/Library/Logs/user.crash"; printf 'c' > "$USER_DIAG"
FOUND_DIAGNOSTIC_REPORTS=("$USER_DIAG" "$SYS_LOG")
clean_diagnostic_reports >/dev/null 2>&1
assert_eq "$REMOVED" "${USER_DIAG}"$'\n' "mixed diagnostics: only the user report is processed"
assert_eq "$(category_outcome diagnostic-reports)" "partial" "mixed diagnostics: outcome partial"

begin_test "permanent mode processes system logs; non-interactive mode never prompts"
reset_state
REMOVE_MODE="permanent"
FOUND_APP_LOGS=("$USER_LOG"); FOUND_SYSTEM_LOGS=("$SYS_LOG")
clean_logs >/dev/null 2>&1
assert_eq "$REMOVED" "${USER_LOG}"$'\n'"${SYS_LOG}"$'\n' "permanent: both logs processed"
assert_eq "$(category_outcome system-logs)" "cleaned" "permanent: system-logs cleaned"

reset_state
MODE="auto-safe"
FOUND_TMP_FILES=("$SYS_TMP"); FOUND_APP_LOGS=("$USER_LOG"); FOUND_SYSTEM_LOGS=("$SYS_LOG")
clean_tmp >/dev/null 2>&1
clean_logs >/dev/null 2>&1
assert_eq "$CONFIRM_CALLS" "0" "non-interactive: no prompt"
assert_eq "$REMOVED" "${USER_LOG}"$'\n' "non-interactive quarantine: only the user log is processed"

# ---------------------------------------------------------------------------
begin_test "report: needs-permanent is not 'Cleaned'; the quarantine total says when space is freed"
reset_state
TOTAL_WOULD_FREE_BYTES=8192; TOTAL_INFORMATIONAL_BYTES=0; TOTAL_CLEANED_BYTES=0
TOTAL_QUARANTINED_BYTES=0; TOTAL_QUARANTINED_ITEMS=0; TOTAL_SKIPPED_ITEMS=0
TOTAL_USER_DECISIONS_NEEDED=0; USER_DECISION_ITEMS=(); WARNINGS_LIST=()
catbytes_set "tmp" 4096
mark_category_outcome "tmp" needs-permanent
generate_report "interactive" >/dev/null 2>&1
# shellcheck disable=SC2034  # read inside the assert_* eval strings
tmp_row="$(grep '^| Temporary Files (/tmp) |' "$REPORT_FILE" 2>/dev/null)"
assert_true "printf '%s' \"\$tmp_row\" | grep -q -- '--permanent'" "tmp row says it needs --permanent"
assert_false "printf '%s' \"\$tmp_row\" | grep -q 'Cleaned'" "tmp row does not claim Cleaned"
assert_true "grep -q 'quarantine.*--purge-quarantine' \"\$REPORT_FILE\"" "report total explains purge"
assert_true "grep -q 'To process' \"\$REPORT_FILE\"" "report total covers native commands too (not only quarantine)"
assert_false "grep -q 'Potentially freeable' \"\$REPORT_FILE\"" "quarantine report does not say freeable"

# ---------------------------------------------------------------------------
begin_test "quarantine labels say space is freed only after purge (all 7 languages)"
for lang in en pl de fr es it pt; do
    LANG_CODE="$lang"
    REMOVE_MODE="quarantine"
    assert_true "headline_total_label | grep -q -- '--purge-quarantine'" "${lang}: quarantine headline mentions --purge-quarantine"
    for k in consequence_safe_quarantine consequence_review_quarantine consequence_dangerous_quarantine; do
        assert_true "\"i18n_get_${lang}\" $k | grep -q -- '--purge-quarantine'" "${lang}: $k mentions --purge-quarantine"
    done
    assert_true "[ \"\$(\"i18n_get_${lang}\" clean_needs_permanent)\" != '' ]" "${lang}: clean_needs_permanent translated"
    REMOVE_MODE="permanent"
    assert_eq "$(headline_total_label)" "$(t cli_total_freeable)" "${lang}: permanent headline unchanged"
done
LANG_CODE="en"

print_test_summary
