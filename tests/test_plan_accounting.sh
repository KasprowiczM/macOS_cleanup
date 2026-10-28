#!/usr/bin/env bash
# =============================================================================
# tests/test_plan_accounting.sh — P1-1: the headline total is the plan's sum
#
# The 2026-10-27 review measured would_free_bytes != the plan's operations:
# report-only items (never executed) were summed into the review/dangerous
# buckets, Homebrew was counted twice (cache + brew-stale), and
# informational_bytes was always 0. These tests pin the honest split:
#   executable_bytes   remove_path/native_command that this mode would run
#   report_only_bytes  sized and shown, never executed (informational)
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_plan_accounting.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
export USER="${USER:-testuser}"
export LOG_LEVEL="INFO"
export NO_COLOR=1
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$HOME" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

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
source "${PROJ_DIR}/lib/json_summary.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

PLAN_OUT="${SANDBOX}/reports/plan.json"

# json_get <python-expr over d> — prints the value from PLAN_OUT.
json_get() {
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$PLAN_OUT" 2>/dev/null
}

reset_all() {
    plan_reset
    TOTAL_WOULD_FREE_BYTES=0
    TOTAL_INFORMATIONAL_BYTES=0
    TOTAL_USER_DECISIONS_NEEDED=0
    USER_DECISION_ITEMS=()
    REMOVE_MODE="quarantine"
}

# ---------------------------------------------------------------------------
begin_test "report-only bytes stay out of the executable risk buckets"
reset_all
plan_add_operation "op-0001" "user-caches" "REVIEW" "remove_path" "$HOME/Library/Caches/a" "" 1000 "d" "r"
plan_add_operation "op-0002" "app-leftovers" "REVIEW" "report_only" "$HOME/Library/Application Support/x" "" 7000 "d" "r"
plan_add_operation "op-0003" "mail" "DANGEROUS" "report_only" "$HOME/Library/Mail" "" 90000 "d" "r"
generate_plan_json "$PLAN_OUT" >/dev/null 2>&1
assert_eq "$(json_get "d['summary']['review_bytes']")" "1000" "review_bytes excludes report-only"
assert_eq "$(json_get "d['summary']['review_operations']")" "1" "review_operations excludes report-only"
assert_eq "$(json_get "d['summary']['dangerous_bytes']")" "0" "dangerous_bytes excludes report-only"
assert_eq "$(json_get "d['summary']['report_only_operations']")" "2" "report_only_operations counted"
assert_eq "$(json_get "d['summary']['report_only_bytes']")" "97000" "report_only_bytes summed"
assert_eq "$(json_get "d['summary']['executable_bytes']")" "1000" "executable_bytes = runnable ops"

# ---------------------------------------------------------------------------
begin_test "headline would_free = executable plan bytes; informational = report-only"
reset_all
plan_add_operation "op-0001" "trash" "REVIEW" "remove_path" "$HOME/.Trash/f" "" 4000 "d" "r"
plan_add_operation "op-0002" "dev" "SAFE" "native_command" "$HOME/.npm/_cacache" "npm cache clean --force" 2500 "d" "r" "false" "npm"
plan_add_operation "op-0003" "system" "REVIEW" "report_only" "/Library/Caches/x" "" 13000 "d" "r"
plan_add_operation "op-0004" "dev" "DANGEROUS" "remove_path" "$HOME/dangerous" "" 800 "d" "r"
TOTAL_WOULD_FREE_BYTES=999999
plan_record_headline_totals
assert_eq "$TOTAL_WOULD_FREE_BYTES" "6500" "would_free = SAFE+REVIEW runnable ops only"
assert_eq "$TOTAL_INFORMATIONAL_BYTES" "13000" "informational = report-only bytes"

# ---------------------------------------------------------------------------
begin_test "quarantine mode does not count non-user paths it will skip"
reset_all
plan_add_operation "op-0001" "system" "SAFE" "remove_path" "/private/tmp/old.tmp" "" 5500 "d" "r"
plan_add_operation "op-0002" "logs" "SAFE" "remove_path" "/Library/Logs/old.log" "" 300 "d" "r"
plan_add_operation "op-0003" "logs" "SAFE" "remove_path" "$HOME/Library/Logs/old.log" "" 200 "d" "r"
plan_record_headline_totals
assert_eq "$TOTAL_WOULD_FREE_BYTES" "200" "quarantine: only user-space remove_path counts"

reset_all
REMOVE_MODE="permanent"
plan_add_operation "op-0001" "system" "SAFE" "remove_path" "/private/tmp/old.tmp" "" 5500 "d" "r"
plan_add_operation "op-0003" "logs" "SAFE" "remove_path" "$HOME/Library/Logs/old.log" "" 200 "d" "r"
plan_record_headline_totals
assert_eq "$TOTAL_WOULD_FREE_BYTES" "5700" "permanent: non-user remove_path counts"

reset_all
REMOVE_MODE="permenant"
plan_add_operation "op-0001" "logs" "SAFE" "remove_path" "$HOME/Library/Logs/old.log" "" 200 "d" "r"
plan_record_headline_totals
assert_eq "$TOTAL_WOULD_FREE_BYTES" "0" "invalid REMOVE_MODE: safe_remove refuses, so nothing counts"

begin_test "an empty plan yields zero totals under set -u"
reset_all
plan_record_headline_totals
assert_eq "$TOTAL_WOULD_FREE_BYTES" "0" "empty plan: would_free 0"
assert_eq "$TOTAL_INFORMATIONAL_BYTES" "0" "empty plan: informational 0"
generate_plan_json "$PLAN_OUT" >/dev/null 2>&1
assert_eq "$(json_get "d['summary']['executable_bytes']")" "0" "empty plan JSON: executable_bytes 0"

# ---------------------------------------------------------------------------
begin_test "Homebrew is counted once: max(cache, brew-stale), never the sum"
reset_all
mkdir -p "$HOME/Library/Caches/Homebrew"
FOUND_DEV_ITEMS=("brew_cache:$HOME/Library/Caches/Homebrew")
catbytes_set "brew" 1000
catbytes_set "brew-stale" 3000
build_cleanup_plan_from_analysis >/dev/null 2>&1
plan_record_headline_totals
assert_eq "$TOTAL_WOULD_FREE_BYTES" "3000" "brew op uses the larger estimate (stale >= cache)"

reset_all
FOUND_DEV_ITEMS=("brew_cache:$HOME/Library/Caches/Homebrew")
catbytes_set "brew" 5000
catbytes_set "brew-stale" 3000
build_cleanup_plan_from_analysis >/dev/null 2>&1
plan_record_headline_totals
assert_eq "$TOTAL_WOULD_FREE_BYTES" "5000" "brew op uses the larger estimate (cache >= stale)"
FOUND_DEV_ITEMS=()

# ---------------------------------------------------------------------------
begin_test "plan counters reach the JSON summary"
reset_all
plan_add_operation "op-0001" "trash" "SAFE" "remove_path" "$HOME/.Trash/f" "" 4000 "d" "r"
plan_add_operation "op-0002" "system" "REVIEW" "report_only" "/Library/Caches/x" "" 13000 "d" "r"
generate_plan_json "$PLAN_OUT" >/dev/null 2>&1
plan_record_headline_totals
JSON_OUT="${SANDBOX}/summary.json"
emit_json_summary "plan" > "$JSON_OUT"
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['counters']['would_free_bytes'])" "$JSON_OUT" 2>/dev/null)" "4000" "summary would_free_bytes"
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['counters']['informational_bytes'])" "$JSON_OUT" 2>/dev/null)" "13000" "summary informational_bytes"
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['plan']['report_only_bytes'])" "$JSON_OUT" 2>/dev/null)" "13000" "summary plan.report_only_bytes"

print_test_summary
