#!/usr/bin/env bash
# =============================================================================
# tests/test_apply_lock.sh — exclusive mkdir lock for apply/restore/purge
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

LOG_LEVEL="INFO"
LOG_FILE="$(mktemp -t macos_cleanup_test_apply_lock.XXXXXX)"
SANDBOX="$(mktemp -d -t macos_cleanup_test_apply_lock.XXXXXX)"
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

cleanup() {
    release_cleanup_lock 2>/dev/null || true
    rm -f "$LOG_FILE"
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

begin_test "acquire_cleanup_lock succeeds on an empty quarantine root"
acquire_cleanup_lock
assert_eq "$?" "0" "first acquire returns 0"
assert_file_exists "${QUARANTINE_ROOT}/.apply.lock" "lock dir exists after acquire"

begin_test "second acquire_cleanup_lock fails while lock is held"
acquire_cleanup_lock
assert_eq "$?" "1" "second acquire returns 1"

begin_test "release_cleanup_lock then acquire succeeds again"
release_cleanup_lock
assert_file_absent "${QUARANTINE_ROOT}/.apply.lock" "lock dir removed after release"
acquire_cleanup_lock
assert_eq "$?" "0" "acquire after release returns 0"
release_cleanup_lock

begin_test "release does not remove a lock this process did not create"
mkdir "${QUARANTINE_ROOT}/.apply.lock"
CLEANUP_LOCK_HELD=0
release_cleanup_lock
assert_file_exists "${QUARANTINE_ROOT}/.apply.lock" "foreign lock dir left in place"
acquire_cleanup_lock
assert_eq "$?" "1" "foreign lock still blocks acquire"
rmdir "${QUARANTINE_ROOT}/.apply.lock"

begin_test "apply/restore/purge phases take the lock"
python3 - "$PROJ_DIR/cleanup_all.sh" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
names = ("run_restore_phase", "run_purge_quarantine_phase", "run_apply_plan_phase")
missing = []
for name in names:
    start = text.find("%s() {" % name)
    if start < 0:
        missing.append(name + ":missing")
        continue
    rest = text[start:]
    m = re.search(r"\n(?=[a-zA-Z_]+\(\) \{|# ----)", rest)
    body = rest[: m.start()] if m else rest
    if "acquire_cleanup_lock" not in body:
        missing.append(name + ":no-lock")
if missing:
    sys.stderr.write("lock wiring: %s\n" % ", ".join(missing))
    sys.exit(1)
PY
assert_eq "$?" "0" "restore/apply/purge call acquire_cleanup_lock"

print_test_summary
