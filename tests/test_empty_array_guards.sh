#!/usr/bin/env bash
# =============================================================================
# tests/test_empty_array_guards.sh
#
# bash 3.2 + `set -u` treats "${empty_array[@]}" as an UNBOUND VARIABLE error,
# not as an empty expansion. cleanup_all.sh runs with `set -euo pipefail`, so a
# single unguarded expansion does not degrade — it kills the run mid-cleanup.
#
# Observed 2026-08-19: clean_logs() guarded only the SUM of FOUND_APP_LOGS and
# FOUND_SYSTEM_LOGS, then expanded both. On a machine with user logs but no old
# system logs the interactive run quarantined Trash and user caches, then died
# with "FOUND_SYSTEM_LOGS[@]: unbound variable" — and every later category
# (dev, app-leftovers, time-machine, large-files) was silently never offered.
# The user answered "yes" and nothing happened.
#
# This test calls every clean_* entry point with EVERY FOUND_* array empty,
# then again with each array holding exactly one element, and fails on any
# unbound-variable abort. It is deliberately behavioural rather than a grep:
# the guard idiom varies across the file, and a static scan cannot tell an
# effective guard from a decorative one.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

FOUND_ARRAYS="FOUND_USER_CACHES FOUND_SYSTEM_CACHES FOUND_APP_LOGS FOUND_SYSTEM_LOGS \
FOUND_TMP_FILES FOUND_APP_LEFTOVERS FOUND_DEV_ITEMS FOUND_TM_SNAPSHOTS FOUND_IOS_BACKUPS \
FOUND_LARGE_FILES FOUND_DMG_PKG FOUND_TRASH_ITEMS FOUND_APP_CACHE_ITEMS \
FOUND_DEVICE_SUPPORT_ITEMS FOUND_DIAGNOSTIC_REPORTS FOUND_INSTALLED_APPS \
FOUND_MAIL_ITEMS FOUND_BROWSER_CACHE_ITEMS FOUND_BROWSER_DATA_ITEMS"

CLEAN_FUNCS="clean_trash clean_user_caches clean_app_specific_caches clean_system_caches \
clean_logs clean_diagnostic_reports clean_tmp clean_app_leftovers clean_xcode_derived_data \
clean_ios_device_support clean_xcode_simulators clean_dev_review_only_items clean_dev_caches \
clean_docker clean_time_machine_snapshots clean_ios_backups clean_dmg_pkg"

# Run one clean_* function in a fresh subshell process with a controlled array
# state. $1 = function name, $2 = name of the array to populate (or "" for none).
# Prints nothing on success; prints the abort message on failure.
run_isolated() {
    local func="$1" populate="${2:-}"
    local sandbox
    sandbox="$(mktemp -d -t macos_cleanup_guard.XXXXXX)"

    local script="${sandbox}/probe.sh"
    {
        printf '%s\n' 'set -euo pipefail'
        printf 'export HOME=%q\n' "$sandbox"
        printf 'export LOG_LEVEL=ERROR\n'
        printf 'export LOGS_DIR=%q\n' "${sandbox}/logs"
        printf 'export REPORTS_DIR=%q\n' "${sandbox}/reports"
        printf 'export CLEANUP_JOURNAL_FILE=%q\n' "${sandbox}/reports/journal.jsonl"
        printf 'export CLEANUP_RESTORE_MANIFEST=%q\n' "${sandbox}/reports/restore.tsv"
        printf 'export QUARANTINE_ROOT=%q\n' "${sandbox}/quarantine"
        printf 'export QUARANTINE_RUN_DIR=%q\n' "${sandbox}/quarantine/run"
        # shellcheck disable=SC2016  # deliberately emitted verbatim into the probe script
        printf 'mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT" "$QUARANTINE_RUN_DIR"\n'
        printf 'source %q\n' "${PROJ_DIR}/config/defaults.sh"
        printf 'source %q\n' "${PROJ_DIR}/lib/common.sh"
        printf 'source %q\n' "${PROJ_DIR}/lib/policy.sh"
        printf 'source %q\n' "${PROJ_DIR}/lib/interactive.sh"
        printf 'source %q\n' "${PROJ_DIR}/lib/analyzer.sh"
        printf 'source %q\n' "${PROJ_DIR}/lib/cleaner.sh"
        # Neutralise everything that would touch the real system or block on a tty.
        printf '%s\n' 'safe_remove() { :; }'
        printf '%s\n' 'confirm_category() { return 0; }'
        printf '%s\n' 'request_sudo() { return 1; }'
        printf '%s\n' 'MODE="interactive"; REMOVE_MODE="quarantine"; DRY_RUN=0'
        local arr
        for arr in $FOUND_ARRAYS; do
            printf '%s=()\n' "$arr"
        done
        if [[ -n "$populate" ]]; then
            printf '%s=(%q)\n' "$populate" "${sandbox}/probe_item"
            printf 'mkdir -p %q\n' "${sandbox}/probe_item"
        fi
        printf '%s\n' "$func"
    } > "$script"

    local out
    out="$(bash "$script" 2>&1)" || true
    rm -rf "$sandbox" 2>/dev/null || true

    # Only unbound-variable aborts are this test's business. A clean_* function
    # may legitimately fail for other reasons in a sandbox (missing tools, no
    # sudo); those are other tests' problem.
    if printf '%s' "$out" | grep -q "unbound variable"; then
        printf '%s' "$(printf '%s' "$out" | grep 'unbound variable' | head -1)"
        return 1
    fi
    return 0
}

begin_test "Empty-array guards — every clean_* survives an all-empty FOUND_* state"
for func in $CLEAN_FUNCS; do
    if err="$(run_isolated "$func" "")"; then
        _pass
    else
        _fail "${func} aborted with all arrays empty: ${err}"
    fi
done

begin_test "Empty-array guards — every clean_* survives a partially populated FOUND_* state"
# The 2026-08-19 bug needed exactly this shape: one array populated, its
# sibling empty. An all-empty sweep alone would have missed it, because the
# summed guard returned early when BOTH were empty.
for arr in $FOUND_ARRAYS; do
    for func in $CLEAN_FUNCS; do
        if err="$(run_isolated "$func" "$arr")"; then
            :
        else
            _fail "${func} aborted with only ${arr} populated: ${err}"
        fi
    done
done
_pass

print_test_summary
