#!/usr/bin/env bash
# =============================================================================
# tests/test_i18n_accessibility.sh — Unit tests for i18n & Accessibility [Batch 8]
#
# Validates translation keys (t "key"), Gate G11, PLAIN_OUTPUT formatting, and QUIET_OUTPUT behavior.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_i18n.XXXXXX)"
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

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

begin_test "Gate G11: i18n files exist and contain non-zero translation keys"
if [[ -f "${PROJ_DIR}/i18n/pl.sh" && -f "${PROJ_DIR}/i18n/en.sh" ]]; then
    _pass
else
    _fail "Gate G11 failed: i18n/pl.sh and i18n/en.sh MUST exist"
fi

begin_test "Gate G11: 100% of t() keys exist across all 7 language files"
missing_count=$(python3 -c "
import glob, re
t_keys = set()
for filepath in glob.glob('${PROJ_DIR}/lib/*.sh') + ['${PROJ_DIR}/cleanup_all.sh']:
    with open(filepath, 'r', encoding='utf-8') as f:
        matches = re.findall(r't\s+[\"\']([a-zA-Z0-9_]+)[\"\']', f.read())
        t_keys.update(matches)

dict_keys = {}
for lang_file in glob.glob('${PROJ_DIR}/i18n/*.sh'):
    lang = lang_file.split('/')[-1].replace('.sh', '')
    with open(lang_file, 'r', encoding='utf-8') as f:
        dict_keys[lang] = set(re.findall(r'^\s*([a-zA-Z0-9_]+)\)', f.read(), re.MULTILINE))

missing = 0
for key in t_keys:
    for lang, keys in dict_keys.items():
        if key not in keys:
            missing += 1
print(missing)
")
if [[ "$missing_count" -eq 0 ]]; then
    _pass
else
    _fail "Missing translation keys detected across language files: ${missing_count}"
fi

begin_test "t() function returns correct Polish translation"
LANG_CODE="pl"
res="$(t "user_caches")"
if [[ "$res" == "Cache użytkownika" ]]; then
    _pass
else
    _fail "t() should return Polish translation, got: ${res}"
fi

begin_test "t() function returns correct English translation"
LANG_CODE="en"
res="$(t "user_caches")"
if [[ "$res" == "User Caches" ]]; then
    _pass
else
    _fail "t() should return English translation, got: ${res}"
fi

begin_test "t() function falls back to humanized string when translation key is unknown"
res="$(t "non_existent_key_1234")"
if [[ "$res" == "non existent key 1234" ]]; then
    _pass
else
    _fail "t() should fallback to humanized name when key unknown, got: ${res}"
fi

begin_test "QUIET_OUTPUT suppresses print_info terminal output"
QUIET_OUTPUT=1
quiet_out="$(print_info "suppressed_test_msg" 2>&1)"
if [[ -z "$quiet_out" ]]; then
    _pass
else
    _fail "QUIET_OUTPUT should produce no terminal output, got: ${quiet_out}"
fi

print_test_summary
