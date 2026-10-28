#!/usr/bin/env bash
# =============================================================================
# tests/test_scan_performance.sh — Phase 2: the slow parts of a full scan are
# bounded or skipped.
#
# 2026-10-27 measurement (~322 s full scan): `du -sh ~/*/` alone took ~102 s,
# and analyze_app_leftovers ran a `defaults read` per installed app for every
# orphan candidate (~60 s) while also walking ~/Library/Containers, which on
# macOS 14+ can raise "access data from other apps" privacy prompts.
# Bash 3.2 compatible. Tools are PATH stubs that record their calls.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_scan_perf.XXXXXX)"
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
mkdir -p "$HOME/Documents" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

STUB_BIN="${SANDBOX}/bin"
CALLS="${SANDBOX}/calls.log"
mkdir -p "$STUB_BIN"
: > "$CALLS"

make_kb() { mkdir -p "$(dirname "$1")"; dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null; }

# ---------------------------------------------------------------------------
begin_test "the home top-10 walk is bounded by a timeout"
cat > "${STUB_BIN}/du" <<'STUB'
#!/bin/sh
sleep 8
exec /usr/bin/du "$@"
STUB
chmod +x "${STUB_BIN}/du"
unset ACTIVE_CATEGORIES 2>/dev/null || true
HOME_TOP_DIRS_TIMEOUT=1
_old_path="$PATH"; PATH="${STUB_BIN}:${PATH}"
start=$(date +%s)
# shellcheck disable=SC2034  # read inside the assert_true eval string
overview_out="$(analyze_disk_overview 2>&1)"
elapsed=$(( $(date +%s) - start ))
PATH="$_old_path"
rm -f "${STUB_BIN}/du"
assert_true "(( $elapsed < 6 ))" "full-scan overview returns within the bound (took ${elapsed}s)"
assert_true "printf '%s' \"\$overview_out\" | grep -q 'HOME_TOP_DIRS_TIMEOUT'" "the output says the list was cut short"

# ---------------------------------------------------------------------------
begin_test "app-leftover scan skips Containers and Group Containers"
make_kb "$HOME/Library/Containers/com.gone.sandboxed/Data/blob" 40
make_kb "$HOME/Library/Group Containers/group.com.gone.shared/blob" 40
make_kb "$HOME/Library/Application Support/com.gone.classic/blob" 40
FOUND_APP_LEFTOVERS=()
APP_BUNDLE_ID_CACHE_LOADED=1; APP_BUNDLE_ID_CACHE="com.installed.app"
mdfind() { return 1; }
analyze_app_leftovers >/dev/null 2>&1
unset -f mdfind
assert_array_var_contains_exact "FOUND_APP_LEFTOVERS" "$HOME/Library/Application Support/com.gone.classic"
assert_array_var_not_contains_fragment "FOUND_APP_LEFTOVERS" "Containers"

# ---------------------------------------------------------------------------
begin_test "app_bundle_exists answers from the bundle-id cache, no per-app plist reads"
cat > "${STUB_BIN}/defaults" <<STUB
#!/bin/sh
echo "defaults \$*" >> "${CALLS}"
exit 1
STUB
cat > "${STUB_BIN}/mdfind" <<STUB
#!/bin/sh
echo "mdfind \$*" >> "${CALLS}"
exit 0
STUB
chmod +x "${STUB_BIN}/defaults" "${STUB_BIN}/mdfind"
FOUND_INSTALLED_APPS=()
for i in 1 2 3 4 5; do
    mkdir -p "${SANDBOX}/Apps/A${i}.app/Contents"
    printf '<plist/>' > "${SANDBOX}/Apps/A${i}.app/Contents/Info.plist"
    FOUND_INSTALLED_APPS+=("${SANDBOX}/Apps/A${i}.app")
done
APP_BUNDLE_ID_CACHE_LOADED=1; APP_BUNDLE_ID_CACHE=$'com.installed.app\ncom.other.app'
_old_path="$PATH"; PATH="${STUB_BIN}:${PATH}"
: > "$CALLS"
app_bundle_exists "com.installed.app"; rc=$?
assert_eq "$rc" "0" "cached bundle id is installed"
assert_eq "$(wc -l < "$CALLS" | tr -d ' ')" "0" "a cache hit runs no external command"
: > "$CALLS"
app_bundle_exists "com.orphan.app" >/dev/null 2>&1
assert_false "grep -q '^defaults' '$CALLS'" "no per-installed-app defaults read for a cache miss"
assert_eq "$(grep -c '^mdfind' "$CALLS" | tr -d ' ')" "1" "a cache miss asks Spotlight once"
PATH="$_old_path"

print_test_summary
