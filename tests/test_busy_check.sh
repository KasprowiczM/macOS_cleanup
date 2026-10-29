#!/usr/bin/env bash
# =============================================================================
# tests/test_busy_check.sh — Phase 3: a cache is not removed while the tool
# that writes it is running.
#
# Gradle, Cargo, CocoaPods, SwiftPM, Bundler and Composer caches, the npx
# cache, the pnpm stale store and Xcode DerivedData were removed even while a
# build was using them, which breaks that build mid-way. pgrep is a stub.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_busy.XXXXXX)"
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
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"
stub_native_tools "${SANDBOX}/native_bin"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
begin_test "real pgrep: the npx and Gradle patterns match live command lines"
# A sleeping perl whose argv looks like a live npx user / Gradle daemon.
perl -e 'sleep 20' "${SANDBOX}/.npm/_npx/abc/node_modules/.bin/server" &
NPX_MARK=$!
perl -e 'sleep 20' org.gradle.launcher.daemon.bootstrap.GradleDaemon &
GRADLE_MARK=$!
sleep 1
assert_true "cache_owner_running npx_cache" "an ~/.npm/_npx/ command line is seen as an npx user"
assert_true "cache_owner_running gradle_cache" "a Gradle daemon command line is seen"
kill "$NPX_MARK" "$GRADLE_MARK" 2>/dev/null; wait "$NPX_MARK" "$GRADLE_MARK" 2>/dev/null

STUB_BIN="${SANDBOX}/bin"; BUSY="${SANDBOX}/busy"
mkdir -p "$STUB_BIN"
# pgrep stub: exit 0 when any argument matches a line of $BUSY, 1 otherwise;
# exit 3 when $BUSY contains "BROKEN".
cat > "${STUB_BIN}/pgrep" <<STUB
#!/bin/sh
grep -qx BROKEN "${BUSY}" 2>/dev/null && exit 3
for a in "\$@"; do
    grep -qxF -- "\$a" "${BUSY}" 2>/dev/null && exit 0
done
exit 1
STUB
chmod +x "${STUB_BIN}/pgrep"
export PATH="${STUB_BIN}:${PATH}"

REMOVED=""
safe_remove() { REMOVED="${REMOVED}${1}"$'\n'; return 0; }
confirm_category() { return 0; }

CARGO="$HOME/.cargo/registry"; GRADLE="$HOME/.gradle/caches"; DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$CARGO" "$GRADLE" "$DERIVED"

reset_state() {
    : > "$BUSY"; REMOVED=""; CLEANUP_CATEGORY_OUTCOMES=""
    MODE="interactive"; DRY_RUN=0; REMOVE_MODE="quarantine"
}

# ---------------------------------------------------------------------------
begin_test "a running cargo keeps the Cargo cache; Gradle's is still cleaned"
reset_state
echo cargo > "$BUSY"
FOUND_DEV_ITEMS=("cargo_cache:$CARGO" "gradle_cache:$GRADLE")
clean_dev_caches >/dev/null 2>&1
assert_eq "$REMOVED" "${GRADLE}"$'\n' "only the idle tool's cache is removed"

begin_test "a running Gradle daemon keeps the Gradle cache"
reset_state
echo 'org.gradle' > "$BUSY"
FOUND_DEV_ITEMS=("gradle_cache:$GRADLE")
clean_dev_caches >/dev/null 2>&1
assert_eq "$REMOVED" "" "Gradle cache kept while its daemon runs"

begin_test "a broken pgrep counts as busy"
reset_state
echo BROKEN > "$BUSY"
FOUND_DEV_ITEMS=("cargo_cache:$CARGO")
clean_dev_caches >/dev/null 2>&1
assert_eq "$REMOVED" "" "unknown process state: nothing removed"

begin_test "a running npx keeps the npx cache"
reset_state
printf '%s\n' '\.npm/_npx/' > "$BUSY"
NPX="$HOME/.npm/_npx"; mkdir -p "$NPX"
FOUND_DEV_ITEMS=("npx_cache:$NPX")
clean_dev_caches >/dev/null 2>&1
assert_eq "$REMOVED" "" "npx cache kept while npx runs"

begin_test "plan apply runs the same in-use check"
reset_state
printf '%s\n' '\.npm/_npx/' > "$BUSY"
NPXP="$HOME/.npm/_npx/feedbeef"; mkdir -p "$NPXP"; printf 'x' > "$NPXP/f"
PLAN="${SANDBOX}/plan.json"
python3 - "$PLAN" "$NPXP" <<'PY'
import hashlib, json, sys
ops=[{"id":"op-1","category":"dev","risk":"SAFE","action":"remove_path","path":sys.argv[2],"command":"",
      "estimated_bytes":1,"size":1,"description":"d","recommendation":"r","rollback":True}]
chk=hashlib.sha256(json.dumps(ops,sort_keys=True,separators=(",",":")).encode()).hexdigest()
json.dump({"schema_version":"1.0","checksum":chk,"summary":{},"operations":ops},open(sys.argv[1],"w"))
PY
NON_INTERACTIVE=1
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_eq "$REMOVED" "" "plan apply leaves an in-use npx cache alone"
assert_true "grep -q 'in use: npx_cache' '$CLEANUP_JOURNAL_FILE'" "journal records why"

begin_test "a skipped npx cache is reported as in use, not cleaned"
reset_state
printf '%s\n' '\.npm/_npx/' > "$BUSY"
FOUND_DEV_ITEMS=("npx_cache:$NPX")
clean_dev_caches >/dev/null 2>&1
assert_eq "$(category_outcome npx)" "in-use" "npx outcome is in-use"

begin_test "Xcode DerivedData is not removed while Xcode builds"
reset_state
echo Xcode > "$BUSY"
FOUND_DERIVED_DATA="$DERIVED"
clean_xcode_derived_data >/dev/null 2>&1
assert_eq "$REMOVED" "" "DerivedData kept while Xcode runs"
assert_eq "$(category_outcome xcode-derived)" "in-use" "outcome says it was in use"

reset_state
FOUND_DERIVED_DATA="$DERIVED"
clean_xcode_derived_data >/dev/null 2>&1
assert_eq "$REMOVED" "${DERIVED}"$'\n' "idle Xcode: DerivedData removed"

print_test_summary
