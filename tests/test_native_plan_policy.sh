#!/usr/bin/env bash
# tests/test_native_plan_policy.sh — H2: native plan ops obey policy
# Bash 3.2 compatible.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_native_plan_policy.XXXXXX)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
export USER="${USER:-testuser}"
export LOG_LEVEL="INFO"
export NO_COLOR=1
export LANG_CODE="en"
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
source "${PROJ_DIR}/lib/planner.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

reset_plan_fixture() {
    FOUND_USER_CACHES=()
    FOUND_APP_CACHE_ITEMS=()
    FOUND_APP_LOGS=()
    FOUND_SYSTEM_LOGS=()
    FOUND_DIAGNOSTIC_REPORTS=()
    FOUND_TMP_FILES=()
    FOUND_SYSTEM_CACHES=()
    FOUND_APP_LEFTOVERS=()
    FOUND_DEV_ITEMS=()
    FOUND_DEVICE_SUPPORT_ITEMS=()
    FOUND_TM_SNAPSHOTS=()
    FOUND_IOS_BACKUPS=()
    FOUND_DMG_PKG=()
    FOUND_TRASH_ITEMS=()
    FOUND_MAIL_ITEMS=()
    FOUND_BROWSER_CACHE_ITEMS=()
    FOUND_BROWSER_DATA_ITEMS=()
    USER_DECISION_ITEMS=()
    WARNINGS_LIST=()
    TOTAL_CLEANED_BYTES=0
    TOTAL_WOULD_FREE_BYTES=0
    TOTAL_QUARANTINED_BYTES=0
    TOTAL_QUARANTINED_ITEMS=0
    TOTAL_SKIPPED_ITEMS=0
    TOTAL_USER_DECISIONS_NEEDED=0
    DRY_RUN=0
    REMOVE_MODE=quarantine
    NON_INTERACTIVE=1
    AUTO_YES=0
    INCLUDE_REVIEW=0
    plan_reset
}

plan_action_for_path() {
    local plan="$1" path="$2"
    python3 - "$plan" "$path" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for op in data.get("operations", []):
    if op.get("path") == sys.argv[2]:
        print(op.get("action", ""))
        sys.exit(0)
sys.exit(1)
PY
}

plan_bytes_for_path() {
    local plan="$1" path="$2"
    python3 - "$plan" "$path" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for op in data.get("operations", []):
    if op.get("path") == sys.argv[2]:
        print(op.get("estimated_bytes", ""))
        sys.exit(0)
sys.exit(1)
PY
}

begin_test "npx_cache is planned as remove_path on the discovered path"
reset_plan_fixture
npx_path="${HOME}/.npm/_npx"
mkdir -p "$npx_path"
FOUND_DEV_ITEMS=("npx_cache:${npx_path}")
build_cleanup_plan_from_analysis
NPX_PLAN="${SANDBOX}/npx-plan.json"
generate_plan_json "$NPX_PLAN" >/dev/null 2>&1
npx_action="$(plan_action_for_path "$NPX_PLAN" "$npx_path")"
assert_eq "$npx_action" "remove_path" "npx_cache must be remove_path, not native_command"
assert_false "python3 -c \"import json,sys; d=json.load(open('${NPX_PLAN}')); sys.exit(0 if any(o.get('action')=='native_command' and o.get('path')=='${npx_path}' for o in d.get('operations',[])) else 1)\"" \
    "npx_cache path must not be a native_command op"

begin_test "pnpm_stale_store is planned as remove_path on the discovered path"
reset_plan_fixture
pnpm_path="${HOME}/.local/share/pnpm/store/v3"
mkdir -p "$pnpm_path"
FOUND_DEV_ITEMS=("pnpm_stale_store:${pnpm_path}")
build_cleanup_plan_from_analysis
PNPM_PLAN="${SANDBOX}/pnpm-plan.json"
generate_plan_json "$PNPM_PLAN" >/dev/null 2>&1
pnpm_action="$(plan_action_for_path "$PNPM_PLAN" "$pnpm_path")"
assert_eq "$pnpm_action" "remove_path" "pnpm_stale_store must be remove_path, not native_command"

begin_test "brew_cache estimated_bytes uses catbytes brew when non-zero"
reset_plan_fixture
brew_path="${HOME}/Library/Caches/Homebrew"
mkdir -p "$brew_path"
catbytes_set "brew" 123
catbytes_set "brew-stale" 9
FOUND_DEV_ITEMS=("brew_cache:${brew_path}")
# P1-4: the plan binds brew to `brew --cache`; stub it to the fixture path.
BREW_STUB_BIN="${SANDBOX}/stub_bin_brew"
mkdir -p "$BREW_STUB_BIN"
printf '#!/bin/sh\n[ "$1" = "--cache" ] && echo "%s"\nexit 0\n' "$brew_path" > "${BREW_STUB_BIN}/brew"
chmod +x "${BREW_STUB_BIN}/brew"
_old_path="$PATH"
export PATH="${BREW_STUB_BIN}:${PATH}"
build_cleanup_plan_from_analysis
export PATH="$_old_path"
BREW_PLAN="${SANDBOX}/brew-plan.json"
generate_plan_json "$BREW_PLAN" >/dev/null 2>&1
brew_bytes="$(plan_bytes_for_path "$BREW_PLAN" "$(normalize_path "$brew_path")")"
assert_eq "$brew_bytes" "123" "brew_cache must use catbytes brew=123, not brew-stale=9"

begin_test "native npm on NEVER_TOUCH_PATHS does not run the npm stub"
reset_plan_fixture
npm_cache="${SANDBOX}/npm-protected-cache"
mkdir -p "$npm_cache"
echo cache > "${npm_cache}/index-v5"
NEVER_TOUCH_PATHS+=("$npm_cache")
normalize_never_touch_paths
FOUND_DEV_ITEMS=("npm_cache:${npm_cache}")
RECORDER_LOG="${SANDBOX}/npm_protected_recorder.log"
STUB_BIN="${SANDBOX}/stub_bin_protected"
mkdir -p "$STUB_BIN"
# P1-4: plan and apply resolve the target via `npm config get cache`; only
# the cleanup command itself is recorded.
cat > "${STUB_BIN}/npm" << STUB
#!/usr/bin/env bash
[ "\$*" = "config get cache" ] && { echo "${npm_cache}"; exit 0; }
echo "NPM_CALLED: \$*" >> "${RECORDER_LOG}"
exit 0
STUB
chmod +x "${STUB_BIN}/npm"
_old_path="$PATH"
export PATH="${STUB_BIN}:${PATH}"
build_cleanup_plan_from_analysis
NPM_PLAN="${SANDBOX}/npm-protected-plan.json"
generate_plan_json "$NPM_PLAN" >/dev/null 2>&1
DRY_RUN=0
NON_INTERACTIVE=1
set +e
apply_plan_file "$NPM_PLAN" >/dev/null 2>&1
set -u
export PATH="$_old_path"
assert_false "[[ -f \"${RECORDER_LOG}\" ]]" "protected npm cache must not invoke the npm stub"

begin_test "package-manager confirm_category uses native consequence, not quarantine"
pm_block="$(awk '/t \"package_managers_title\"/,/--risk/' "${PROJ_DIR}/lib/cleaner.sh")"
if printf '%s\n' "$pm_block" | grep -q 'consequence_for_mode'; then
    _pass
else
    _fail "package manager confirm must call consequence_for_mode"
fi
if printf '%s\n' "$pm_block" | grep 'consequence_for_mode' | grep -q '"native"'; then
    _pass
else
    _fail "package manager consequence_for_mode must use native"
fi
if printf '%s\n' "$pm_block" | grep 'consequence_for_mode' | grep -q 'REMOVE_MODE'; then
    _fail "package manager consequence must not use REMOVE_MODE"
else
    _pass
fi
if printf '%s\n' "$pm_block" | grep 'consequence_for_mode' | grep -q 'quarantine'; then
    _fail "package manager consequence must not claim quarantine"
else
    _pass
fi

native_txt="$(consequence_for_mode "SAFE" "native")"
if printf '%s\n' "$native_txt" | grep -qi 'irreversible'; then
    _pass
else
    _fail "native consequence must mention irreversible"
fi
if printf '%s\n' "$native_txt" | grep -qi 'not quarantined'; then
    _pass
else
    _fail "native consequence must mention not quarantined"
fi

print_test_summary
