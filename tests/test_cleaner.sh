#!/usr/bin/env bash
# =============================================================================
# tests/test_cleaner.sh — unit tests for cleaner_* functions in lib/cleaner.sh
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_cleaner.XXXXXX)"
export HOME="$SANDBOX"
export LOG_LEVEL="INFO"
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
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() {
    rm -rf "$SANDBOX"
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

REQUEST_SUDO_RESULT=0
request_sudo() {
    return "$REQUEST_SUDO_RESULT"
}

reset_cleaner_state() {
    FOUND_TRASH_ITEMS=()
    FOUND_USER_CACHES=()
    FOUND_APP_CACHE_ITEMS=()
    FOUND_SYSTEM_CACHES=()
    FOUND_APP_LOGS=()
    FOUND_SYSTEM_LOGS=()
    FOUND_DIAGNOSTIC_REPORTS=()
    FOUND_TMP_FILES=()
    FOUND_APP_LEFTOVERS=()
    FOUND_DEV_ITEMS=()
    FOUND_TM_SNAPSHOTS=()
    FOUND_IOS_BACKUPS=()
    FOUND_DMG_PKG=()

    local key
    for key in \
        trash user-caches app-caches system-caches user-logs system-logs diagnostic-reports \
        tmp app-leftovers xcode-derived xcode-archives simulators device-support \
        npm yarn pnpm pip brew brew-stale gradle maven cocoapods cargo \
        swift-pm gem bundler composer android-avd docker time-machine ios-backups installers; do
        catbytes_set "$key" 0
    done

    TOTAL_CLEANED_BYTES=0
    TOTAL_WOULD_FREE_BYTES=0
    TOTAL_USER_DECISIONS_NEEDED=0
    USER_DECISION_ITEMS=()
    MODE="dry-run"
    REMOVE_MODE="permanent"
    DRY_RUN=1
}

create_file_kb() {
    local path="$1"
    local kb="$2"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/zero of="$path" bs=1024 count="$kb" 2>/dev/null
}

begin_test "clean_user_caches removes discovered cache dirs in non-dry-run mode"
reset_cleaner_state
MODE="auto-safe"
DRY_RUN=0
USER_CACHE_DIR="$HOME/Library/Caches/test-app"
mkdir -p "$USER_CACHE_DIR"
create_file_kb "$USER_CACHE_DIR/file.bin" 4
FOUND_USER_CACHES=("$USER_CACHE_DIR")
catbytes_set "user-caches" "$(path_size_bytes "$USER_CACHE_DIR")"

clean_user_caches
assert_file_absent "$USER_CACHE_DIR"
assert_true "(( TOTAL_CLEANED_BYTES > 0 ))"

begin_test "clean_user_caches honours DRY_RUN and keeps data"
reset_cleaner_state
MODE="auto-safe"
DRY_RUN=1
USER_CACHE_DIR2="$HOME/Library/Caches/test-app-dry"
mkdir -p "$USER_CACHE_DIR2"
create_file_kb "$USER_CACHE_DIR2/file.bin" 4
FOUND_USER_CACHES=("$USER_CACHE_DIR2")
catbytes_set "user-caches" "$(path_size_bytes "$USER_CACHE_DIR2")"
prev_cleaned="$TOTAL_CLEANED_BYTES"

clean_user_caches
assert_file_exists "$USER_CACHE_DIR2/file.bin"
assert_eq "${TOTAL_CLEANED_BYTES}" "${prev_cleaned}"

begin_test "clean_system_caches is report-only (P0-1a)"
reset_cleaner_state
MODE="auto-safe"
DRY_RUN=0
SYSTEM_CACHE_DIR="$HOME/system-cache"
mkdir -p "$SYSTEM_CACHE_DIR"
create_file_kb "$SYSTEM_CACHE_DIR/file.bin" 4
FOUND_SYSTEM_CACHES=("$SYSTEM_CACHE_DIR")
catbytes_set "system-caches" "$(path_size_bytes "$SYSTEM_CACHE_DIR")"

clean_system_caches
# P0-1a: system caches must NOT be deleted — report-only
assert_file_exists "$SYSTEM_CACHE_DIR/file.bin" "system cache must survive (report-only)"

begin_test "clean_app_specific_caches removes entries prepared in FOUND_APP_CACHE_ITEMS"
reset_cleaner_state
MODE="auto-safe"
DRY_RUN=0
APP_CACHE_DIR="$HOME/Library/Caches/TestApp/Cache"
mkdir -p "$APP_CACHE_DIR"
create_file_kb "$APP_CACHE_DIR/file.bin" 4
FOUND_APP_CACHE_ITEMS=("TestApp cache:$APP_CACHE_DIR")
catbytes_set "app-caches" "$(path_size_bytes "$APP_CACHE_DIR")"

clean_app_specific_caches
assert_file_absent "$APP_CACHE_DIR/file.bin"

begin_test "clean_dev_review_only_items records risky dev folders without deleting"
reset_cleaner_state
MODE="auto-safe"
DRY_RUN=0
MAVEN_DIR="$HOME/.m2/repository"
AVD_DIR="$HOME/.android/avd"
ARCHIVES_DIR="$HOME/Library/Developer/Xcode/Archives"
create_file_kb "$MAVEN_DIR/local-artifact.bin" 4
create_file_kb "$AVD_DIR/state.bin" 4
create_file_kb "$ARCHIVES_DIR/app.xcarchive/payload.bin" 4
FOUND_DEV_ITEMS=("maven_cache:$MAVEN_DIR" "android_avd:$AVD_DIR" "xcode_archives:$ARCHIVES_DIR")
catbytes_set "maven" "$(path_size_bytes "$MAVEN_DIR")"
catbytes_set "android-avd" "$(path_size_bytes "$AVD_DIR")"
catbytes_set "xcode-archives" "$(path_size_bytes "$ARCHIVES_DIR")"

clean_dev_review_only_items
assert_file_exists "$MAVEN_DIR/local-artifact.bin"
assert_file_exists "$AVD_DIR/state.bin"
assert_file_exists "$ARCHIVES_DIR/app.xcarchive/payload.bin"
assert_eq "$TOTAL_USER_DECISIONS_NEEDED" "3"

begin_test "clean_docker dry-run journals native command plan"
reset_cleaner_state
MODE="auto-safe"
DRY_RUN=1
FOUND_DEV_ITEMS=("docker_prune:__docker__")
catbytes_set "docker" "4096"
rm -f "$CLEANUP_JOURNAL_FILE"
clean_docker
assert_file_exists "$CLEANUP_JOURNAL_FILE"
assert_true "grep -q '\"action\":\"native_command\"' \"$CLEANUP_JOURNAL_FILE\""
assert_true "grep -q 'docker system prune -f' \"$CLEANUP_JOURNAL_FILE\""

# ---------------------------------------------------------------------------
# SF2: verify _run_cleaner isolates failures
# ---------------------------------------------------------------------------
begin_test "SF2: _run_cleaner continues after a cleaner failure"
reset_cleaner_state
MODE="auto-safe"
DRY_RUN=0
_SF2_SECOND_RAN=0
_sf2_failing_cleaner() { return 1; }
_sf2_succeeding_cleaner() { _SF2_SECOND_RAN=1; }
_run_cleaner _sf2_failing_cleaner
_run_cleaner _sf2_succeeding_cleaner
assert_eq "$_SF2_SECOND_RAN" "1" "second cleaner ran despite first failure"

print_test_summary
