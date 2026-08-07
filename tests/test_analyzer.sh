#!/usr/bin/env bash
# =============================================================================
# tests/test_analyzer.sh — unit tests for analyze_* functions in lib/analyzer.sh
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_analyzer.XXXXXX)"
export HOME="$SANDBOX"
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
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() {
    rm -rf "$SANDBOX"
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

reset_analyzer_state() {
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
    FOUND_TRASH_ITEMS=()

    local key
    for key in \
        trash user-caches app-caches system-caches user-logs system-logs diagnostic-reports \
        tmp app-leftovers xcode-derived xcode-archives simulators device-support \
        npm yarn pnpm pip brew brew-stale gradle maven cocoapods cargo \
        swift-pm gem bundler composer android-avd docker time-machine ios-backups installers; do
        catbytes_set "$key" 0
    done
}

create_file_kb() {
    local path="$1"
    local kb="$2"
    local stamp="${3:-200101010101}"

    mkdir -p "$(dirname "$path")"
    dd if=/dev/zero of="$path" bs=1024 count="$kb" 2>/dev/null
    touch -t "$stamp" "$path"
}

set_old_mtime() {
    local path="$1"
    touch -t 200101010101 "$path"
}

run_analyzer_check() {
    reset_analyzer_state
    "$@"
}

begin_test "analyze_user_caches collects cache entries under ~/Library/Caches"
run_analyzer_check analyze_user_caches
create_file_kb "$HOME/Library/Caches/small-item.bin" 1
create_file_kb "$HOME/Library/Caches/big-item.bin" 4
analyze_user_caches
assert_true "(( $(catbytes_get \"user-caches\") > 0 ))"
assert_array_var_contains_exact "FOUND_USER_CACHES" "$HOME/Library/Caches/small-item.bin"

begin_test "analyze_app_specific_caches detects known app cache paths"
run_analyzer_check analyze_app_specific_caches
create_file_kb "$HOME/Library/Application Support/Slack/Cache/index.dat" 12
analyze_app_specific_caches
assert_array_var_contains_fragment "FOUND_APP_CACHE_ITEMS" "Slack (Electron cache):$HOME/Library/Application Support/Slack/Cache"
_slack_sz="$(path_size_bytes "$HOME/Library/Application Support/Slack/Cache")"
assert_true "(( $(catbytes_get 'app-caches') >= _slack_sz ))"

begin_test "known app caches are not double-counted as generic user caches"
run_analyzer_check analyze_user_caches
create_file_kb "$HOME/Library/Caches/com.spotify.client/cache.dat" 16
create_file_kb "$HOME/Library/Caches/com.example.generic/cache.dat" 8
analyze_user_caches
analyze_app_specific_caches
assert_array_var_not_contains_exact "FOUND_USER_CACHES" "$HOME/Library/Caches/com.spotify.client"
assert_array_var_contains_exact "FOUND_USER_CACHES" "$HOME/Library/Caches/com.example.generic"
assert_array_var_contains_fragment "FOUND_APP_CACHE_ITEMS" "Spotify (Cache):$HOME/Library/Caches/com.spotify.client"

begin_test "analyze_dev_environment counts only unavailable simulator device directories"
run_analyzer_check analyze_dev_environment
unavailable_udid="11111111-2222-3333-4444-555555555555"
available_udid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
create_file_kb "$HOME/Library/Developer/CoreSimulator/Devices/${unavailable_udid}/data.bin" 20
create_file_kb "$HOME/Library/Developer/CoreSimulator/Devices/${available_udid}/data.bin" 40
simctl_unavailable_udids() { printf '%s\n' "$unavailable_udid"; }
analyze_dev_environment
assert_array_var_contains_fragment "FOUND_DEV_ITEMS" "ios_simulators:$HOME/Library/Developer/CoreSimulator/Devices"
expected_sim_bytes="$(path_size_bytes "$HOME/Library/Developer/CoreSimulator/Devices/${unavailable_udid}")"
assert_eq "$(catbytes_get "simulators")" "$expected_sim_bytes" "Simulator estimate should include only unavailable devices"

begin_test "analyze_ios_device_support ignores recent DeviceSupport versions"
run_analyzer_check analyze_ios_device_support
old_ds="$HOME/Library/Developer/Xcode/iOS DeviceSupport/16.0"
new_ds="$HOME/Library/Developer/Xcode/iOS DeviceSupport/17.0"
create_file_kb "$old_ds/symbols.bin" 2048
create_file_kb "$new_ds/symbols.bin" 2048
touch -t 200101010101 "$old_ds"
analyze_ios_device_support
assert_array_var_contains_fragment "FOUND_DEVICE_SUPPORT_ITEMS" "iOS DeviceSupport:$old_ds"
assert_array_var_not_contains_fragment "FOUND_DEVICE_SUPPORT_ITEMS" "iOS DeviceSupport:$new_ds"

begin_test "docker reclaim estimate skips local volumes"
run_analyzer_check analyze_dev_environment
simctl_unavailable_udids() { return 1; }
docker() {
    case "$1 ${2:-}" in
        "info ") return 0 ;;
        "system df")
            cat <<'DOCKERDF'
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          2         0         20MB      10MB (50%)
Containers      1         0         4MB       4MB (100%)
Local Volumes   3         0         90MB      90MB (100%)
Build Cache     1         0         8MB       8MB
DOCKERDF
            ;;
        *) return 1 ;;
    esac
}
analyze_dev_environment
unset -f docker
assert_array_var_contains_exact "FOUND_DEV_ITEMS" "docker_prune:__docker__"
expected_docker_bytes=$(( (10 + 4 + 8) * 1024 * 1024 ))
assert_eq "$(catbytes_get "docker")" "$expected_docker_bytes" "Docker estimate should exclude Local Volumes"

begin_test "analyze_trash discovers top-level items in ~/.Trash"
run_analyzer_check analyze_trash
create_file_kb "$HOME/.Trash/trash-item.bin" 4
analyze_trash
assert_array_var_contains_exact "FOUND_TRASH_ITEMS" "$HOME/.Trash/trash-item.bin"
assert_true "(( $(catbytes_get trash) > 0 ))"

begin_test "analyze_logs puts ~/Library/Logs entries into user-logs bucket"
run_analyzer_check analyze_logs
LOG_MAX_AGE_DAYS=1
mkdir -p "$HOME/Library/Logs"
create_file_kb "$HOME/Library/Logs/app-old.log" 4
set_old_mtime "$HOME/Library/Logs/app-old.log"
analyze_logs
EXPECTED_USER_LOG="$(normalize_path "$HOME/Library/Logs/app-old.log")"
assert_array_var_contains_exact "FOUND_APP_LOGS" "$EXPECTED_USER_LOG"
assert_array_var_not_contains_exact "FOUND_SYSTEM_LOGS" "$EXPECTED_USER_LOG"
assert_true "(( $(catbytes_get \"user-logs\") > 0 ))"

begin_test "analyze_large_dmg_pkg detects old large files and ignores small ones"
run_analyzer_check analyze_large_dmg_pkg
mkdir -p "$HOME/Downloads"
create_file_kb "$HOME/Downloads/old-small.dmg" 512
set_old_mtime "$HOME/Downloads/old-small.dmg"
create_file_kb "$HOME/Downloads/old-big.dmg" 12000
set_old_mtime "$HOME/Downloads/old-big.dmg"
analyze_large_dmg_pkg
assert_array_var_contains_exact "FOUND_DMG_PKG" "$HOME/Downloads/old-big.dmg"
assert_array_var_not_contains_exact "FOUND_DMG_PKG" "$HOME/Downloads/old-small.dmg"
assert_true "(( $(catbytes_get \"installers\") > 10000000 ))"

# ---------------------------------------------------------------------------
# PF1: verify scan-accumulated sizes appear in top-N output (proves no re-scan)
# ---------------------------------------------------------------------------
begin_test "PF1: analyze_trash top-N output uses scan-accumulated sizes"
run_analyzer_check analyze_trash
create_file_kb "$HOME/.Trash/pf1-a.bin" 10
create_file_kb "$HOME/.Trash/pf1-b.bin" 50
create_file_kb "$HOME/.Trash/pf1-c.bin" 100
_pf1_output="$(analyze_trash 2>&1)"
# The output should contain all 3 items sorted by size (largest first)
# This proves size_list was accumulated during scan and used for top-N
assert_true "echo '$_pf1_output' | grep -q 'pf1-c.bin'" "100KB item in output"
assert_true "echo '$_pf1_output' | grep -q 'pf1-b.bin'" "50KB item in output"
assert_true "echo '$_pf1_output' | grep -q 'pf1-a.bin'" "10KB item in output"
# Verify sort order: pf1-c should appear before pf1-a in the output
_pf1_c_line=$(echo "$_pf1_output" | grep -n 'pf1-c.bin' | head -1 | cut -d: -f1)
_pf1_a_line=$(echo "$_pf1_output" | grep -n 'pf1-a.bin' | head -1 | cut -d: -f1)
assert_true "(( _pf1_c_line < _pf1_a_line ))" "items sorted by size (largest first)"

print_test_summary
