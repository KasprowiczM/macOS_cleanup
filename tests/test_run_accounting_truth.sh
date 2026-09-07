#!/usr/bin/env bash
# =============================================================================
# tests/test_run_accounting_truth.sh
#
# Everything here comes from one real run: 2026-08-19 20:15, the first live
# `--interactive` session after the v3.0.3 empty-array fix. It completed (exit
# 0) — and then reported three different, mutually inconsistent numbers for
# what it had done:
#
#   log      "FOUND: npm cache: 6.03 GB  <- 6.03 GB do zwolnienia!"
#   journal  native_command npm cache clean --force  bytes=5707751424
#   report   "Freed space | 0 B"
#   truth    ~322 MB   (~/.npm/_cacache; the other 5.3 GB is _npx,
#                       which `npm cache clean --force` never touches)
#
# And the report claimed "User Caches | Cleaned/Quarantined | Done" for a
# category the same log recorded as "User skipped cleanup".
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_truth.XXXXXX)"
export HOME="$SANDBOX"
export LOG_LEVEL="ERROR"
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
export QUARANTINE_RUN_DIR="${SANDBOX}/quarantine/test_run"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT" "$QUARANTINE_RUN_DIR"

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

trap 'rm -rf "$SANDBOX"' EXIT

# ---------------------------------------------------------------------------
begin_test "Native cleanup reports what it FREED, not what it left behind"

# Mimic ~/.npm: a small cache the command clears, next to a large sibling it
# does not. This is the exact shape that produced the 5.7 GB fiction.
FAKE_NPM="${SANDBOX}/.npm"
mkdir -p "${FAKE_NPM}/_cacache" "${FAKE_NPM}/_npx"
dd if=/dev/zero of="${FAKE_NPM}/_cacache/blob.bin" bs=1024 count=200 2>/dev/null
dd if=/dev/zero of="${FAKE_NPM}/_npx/big.bin"     bs=1024 count=2000 2>/dev/null

before_bytes="$(path_size_bytes "$FAKE_NPM")"
rm -rf "${FAKE_NPM}/_cacache"          # stand-in for `npm cache clean --force`
after_bytes="$(path_size_bytes "$FAKE_NPM")"

TOTAL_CLEANED_BYTES=0
record_native_command_freed "npm cache clean --force" "$before_bytes" "$after_bytes" ""

expected_freed=$(( before_bytes - after_bytes ))
assert_eq "$TOTAL_CLEANED_BYTES" "$expected_freed" \
    "TOTAL_CLEANED_BYTES must be credited with the delta a native command freed"

if (( TOTAL_CLEANED_BYTES > 0 )); then
    _pass
else
    _fail "a native cleanup that removed data must not report 0 B freed"
fi

if (( TOTAL_CLEANED_BYTES < after_bytes )); then
    _pass
else
    _fail "freed bytes ($TOTAL_CLEANED_BYTES) must not exceed what remains ($after_bytes) — that is the leftover-as-freed inversion"
fi

journal_bytes="$(grep -o '"bytes":[0-9]*' "$CLEANUP_JOURNAL_FILE" | tail -1 | cut -d: -f2)"
assert_eq "$journal_bytes" "$expected_freed" \
    "the journal's bytes field must hold the freed delta"

# ---------------------------------------------------------------------------
begin_test "npm cache is sized by what 'npm cache clean --force' actually clears"

analyzer_text="$(cat "${PROJ_DIR}/lib/analyzer.sh")"
if [[ "$analyzer_text" == *'_cacache'* ]]; then
    _pass
else
    _fail "analyzer must size \${npm_cache_dir}/_cacache, not the whole ~/.npm tree"
fi
if [[ "$analyzer_text" == *'_npx'* ]]; then
    _pass
else
    _fail "the npx cache must be surfaced separately — it is the part npm cache clean cannot reclaim"
fi

# ---------------------------------------------------------------------------
begin_test "Report status reflects the recorded outcome, not the run mode"

CLEANUP_CATEGORY_OUTCOMES=""
mark_category_outcome "user-caches" skipped
mark_category_outcome "trash" cleaned

assert_eq "$(category_outcome "user-caches")" "skipped" "a declined category must record 'skipped'"
assert_eq "$(category_outcome "trash")"       "cleaned" "an approved category must record 'cleaned'"
assert_eq "$(category_outcome "tmp")"         ""        "an untouched category must record nothing"

# The regression itself: interactive mode alone must not imply "Cleaned".
reporter_text="$(cat "${PROJ_DIR}/lib/reporter.sh")"
if [[ "$reporter_text" == *'category_outcome'* ]]; then
    _pass
else
    _fail "reporter must consult category_outcome before printing a status"
fi

block="$(sed -n '/user-caches|trash|tmp)/,/;;/p' "${PROJ_DIR}/lib/reporter.sh")"
if [[ "$block" == *'Cleaned/Quarantined'* ]]; then
    _fail "reporter still derives 'Cleaned/Quarantined' from the run mode"
else
    _pass
fi

# ---------------------------------------------------------------------------
begin_test "Every cleaner that prompts also records its outcome"

prompts="$(awk '/confirm_category/ { n++ } END { print n+0 }' "${PROJ_DIR}/lib/cleaner.sh")"
skipped_marks="$(grep -c 'mark_category_outcome "[a-z-]*" skipped' "${PROJ_DIR}/lib/cleaner.sh")"

if (( skipped_marks >= prompts )); then
    _pass
else
    _fail "found ${prompts} confirm_category prompts but only ${skipped_marks} skipped-outcome markers — a declined category would still be reported as cleaned"
fi

print_test_summary
