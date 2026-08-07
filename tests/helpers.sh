#!/usr/bin/env bash
# =============================================================================
# tests/helpers.sh — minimal bash 3.2 assertion helpers
# Sourced by individual test files.
# =============================================================================

TESTS_PASS=0
TESTS_FAIL=0
CURRENT_TEST=""

_fail() {
    local msg="$1"
    TESTS_FAIL=$(( TESTS_FAIL + 1 ))
    echo "  FAIL: ${CURRENT_TEST}: ${msg}" >&2
}

_pass() {
    TESTS_PASS=$(( TESTS_PASS + 1 ))
}

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [[ "$actual" == "$expected" ]]; then
        _pass
    else
        _fail "${msg:-assert_eq} — expected '${expected}', got '${actual}'"
    fi
}

assert_neq() {
    local actual="$1" unexpected="$2" msg="${3:-}"
    if [[ "$actual" != "$unexpected" ]]; then
        _pass
    else
        _fail "${msg:-assert_neq} — value equals forbidden '${unexpected}'"
    fi
}

assert_true() {
    # Usage: assert_true "cmd to run" "message"
    local cmd="$1" msg="${2:-}"
    if eval "$cmd" >/dev/null 2>&1; then
        _pass
    else
        _fail "${msg:-assert_true} — command failed: ${cmd}"
    fi
}

assert_false() {
    local cmd="$1" msg="${2:-}"
    if ! eval "$cmd" >/dev/null 2>&1; then
        _pass
    else
        _fail "${msg:-assert_false} — command unexpectedly succeeded: ${cmd}"
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [[ -e "$path" ]]; then
        _pass
    else
        _fail "${msg:-assert_file_exists} — missing: ${path}"
    fi
}

assert_file_absent() {
    local path="$1" msg="${2:-}"
    if [[ ! -e "$path" ]]; then
        _pass
    else
        _fail "${msg:-assert_file_absent} — unexpectedly present: ${path}"
    fi
}

_array_var_contains() {
    local array_name="$1"
    local needle="$2"
    local mode="${3:-exact}"
    local count idx item

    eval "count=\${#${array_name}[@]}"
    idx=0
    while [[ "$idx" -lt "$count" ]]; do
        eval "item=\${${array_name}[$idx]}"
        case "$mode" in
            exact)
                [[ "$item" == "$needle" ]] && return 0
                ;;
            fragment)
                [[ "$item" == *"$needle"* ]] && return 0
                ;;
        esac
        idx=$(( idx + 1 ))
    done
    return 1
}

assert_array_var_contains_exact() {
    local array_name="$1" needle="$2" msg="${3:-}"
    if _array_var_contains "$array_name" "$needle" exact; then
        _pass
    else
        _fail "${msg:-assert_array_var_contains_exact} — ${array_name} does not contain '${needle}'"
    fi
}

assert_array_var_not_contains_exact() {
    local array_name="$1" needle="$2" msg="${3:-}"
    if _array_var_contains "$array_name" "$needle" exact; then
        _fail "${msg:-assert_array_var_not_contains_exact} — ${array_name} unexpectedly contains '${needle}'"
    else
        _pass
    fi
}

assert_array_var_contains_fragment() {
    local array_name="$1" needle="$2" msg="${3:-}"
    if _array_var_contains "$array_name" "$needle" fragment; then
        _pass
    else
        _fail "${msg:-assert_array_var_contains_fragment} — ${array_name} does not contain fragment '${needle}'"
    fi
}

assert_array_var_not_contains_fragment() {
    local array_name="$1" needle="$2" msg="${3:-}"
    if _array_var_contains "$array_name" "$needle" fragment; then
        _fail "${msg:-assert_array_var_not_contains_fragment} — ${array_name} unexpectedly contains fragment '${needle}'"
    else
        _pass
    fi
}

begin_test() { CURRENT_TEST="$1"; }

print_test_summary() {
    echo
    echo "-----------------------------------------------------------"
    echo "Pass: ${TESTS_PASS}   Fail: ${TESTS_FAIL}"
    echo "-----------------------------------------------------------"
    (( TESTS_FAIL == 0 ))
}

# Create a temp sandbox root the tests can safely write into.
make_sandbox() {
    local dir
    dir=$(mktemp -d -t macos_cleanup_test.XXXXXX)
    echo "$dir"
}

# Redirect all artifact output directories into the given sandbox.
# Call this BEFORE sourcing config/defaults.sh so the readonly vars
# pick up the exported values.
setup_artifact_isolation() {
    local sandbox="$1"
    export LOGS_DIR="${sandbox}/logs"
    export REPORTS_DIR="${sandbox}/reports"
    export CLEANUP_JOURNAL_FILE="${sandbox}/reports/journal_test.jsonl"
    export CLEANUP_RESTORE_MANIFEST="${sandbox}/reports/restore_test.tsv"
    export QUARANTINE_ROOT="${sandbox}/quarantine"
    export QUARANTINE_RUN_DIR="${sandbox}/quarantine/test_run"
    mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT" "$QUARANTINE_RUN_DIR"
}

