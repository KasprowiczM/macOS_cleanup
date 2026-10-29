#!/usr/bin/env bash
# =============================================================================
# tests/test_tm_snapshots.sh — Phase 3: local Time Machine snapshot deletion
# keeps the newest snapshot and never runs during a backup.
#
# clean_time_machine_snapshots deleted every com.apple.TimeMachine.* snapshot,
# the newest included (the rollback point before an update), and did not ask
# `tmutil status` whether a backup was running. tmutil is a recording stub.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_tm.XXXXXX)"
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
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

STUB_BIN="${SANDBOX}/bin"; CALLS="${SANDBOX}/calls.log"; STATUS_FILE="${SANDBOX}/status"
SNAP_DIR="${SANDBOX}/snaps"; MOUNT_OUT="${SANDBOX}/mount.out"
mkdir -p "$STUB_BIN" "$SNAP_DIR"
# listlocalsnapshots <mp> prints ${SNAP_DIR}/<mp with / and space as _>,
# or fails when a .fail file exists for it.
cat > "${STUB_BIN}/tmutil" <<STUB
#!/bin/sh
echo "tmutil \$*" >> "${CALLS}"
case "\$1" in
    status) [ -f "${STATUS_FILE}" ] || exit 1; cat "${STATUS_FILE}" ;;
    listlocalsnapshots)
        f="${SNAP_DIR}/\$(printf '%s' "\$2" | tr '/ ' '__')"
        [ -f "\$f.fail" ] && exit 1
        echo "Snapshots for disk \$2:"
        [ -f "\$f" ] && cat "\$f" ;;
esac
exit 0
STUB
cat > "${STUB_BIN}/mount" <<STUB
#!/bin/sh
[ -f "${MOUNT_OUT}.fail" ] && exit 1
echo "/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)"
echo "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect, root data)"
[ -f "${MOUNT_OUT}" ] && cat "${MOUNT_OUT}"
exit 0
STUB
chmod +x "${STUB_BIN}/tmutil" "${STUB_BIN}/mount"
export PATH="${STUB_BIN}:${PATH}"

confirm_time_machine_snapshots() { return 0; }
set_status() { printf 'Backup session status:\n{\n    ClientID = "com.apple.backupd";\n    Running = %s;\n}\n' "$1" > "$STATUS_FILE"; }

OLD1="com.apple.TimeMachine.2026-10-26-101500.local"
OLD2="com.apple.TimeMachine.2026-10-27-221500.local"
NEWEST="com.apple.TimeMachine.2026-10-28-091500.local"

reset_state() {
    : > "$CALLS"; rm -f "$STATUS_FILE" "$MOUNT_OUT" "${MOUNT_OUT}.fail"
    rm -f "${SNAP_DIR}"/*
    CLEANUP_CATEGORY_OUTCOMES=""
    MODE="interactive"; DRY_RUN=0; REMOVE_MODE="quarantine"
    FOUND_TM_SNAPSHOTS=("$OLD2" "$NEWEST" "$OLD1")   # listing order is not date order
}
deleted() { grep '^tmutil deletelocalsnapshots' "$CALLS" | awk '{print $3}' | sort | tr '\n' ' '; }

# ---------------------------------------------------------------------------
begin_test "older snapshots are deleted, the newest is kept"
reset_state; set_status 0
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "2026-10-26-101500 2026-10-27-221500 " "only the two older dates are deleted"
assert_false "grep -q '2026-10-28-091500' '$CALLS'" "the newest snapshot is never deleted"

begin_test "nothing is deleted while a backup is running"
reset_state; set_status 1
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "" "Running = 1: no deletion"
assert_eq "$(category_outcome time-machine)" "backup-running" "outcome records why nothing was deleted"

begin_test "an unreadable backup status counts as running"
reset_state                                   # no status file: tmutil status fails
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "" "unknown status: no deletion"

begin_test "a single snapshot is the newest and is kept"
reset_state; set_status 0
FOUND_TM_SNAPSHOTS=("$NEWEST")
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "" "the only snapshot is kept"

begin_test "a backup that starts during the prompt stops the deletion"
reset_state; set_status 0
confirm_time_machine_snapshots() { set_status 1; return 0; }
clean_time_machine_snapshots >/dev/null 2>&1
confirm_time_machine_snapshots() { return 0; }
assert_eq "$(deleted)" "" "re-checked after confirmation: no deletion"
assert_eq "$(category_outcome time-machine)" "backup-running" "outcome says a backup was running"

begin_test "duplicate older dates are deleted once; only-newest records kept"
reset_state; set_status 0
FOUND_TM_SNAPSHOTS=("$OLD1" "$OLD1" "$NEWEST")
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "2026-10-26-101500 " "a repeated date is deleted once"
reset_state; set_status 0
FOUND_TM_SNAPSHOTS=("$NEWEST")
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(category_outcome time-machine)" "kept-newest" "only-newest is recorded as kept"

begin_test "dry-run previews only what a real run would delete"
reset_state; set_status 0; DRY_RUN=1
# shellcheck disable=SC2034  # read inside the assert_* eval strings
preview="$(clean_time_machine_snapshots 2>&1)"
assert_eq "$(deleted)" "" "dry-run deletes nothing"
assert_false "printf '%s' \"\$preview\" | grep -q 'deletelocalsnapshots 2026-10-28-091500'" "dry-run does not offer the newest"
assert_true "printf '%s' \"\$preview\" | grep -q 'deletelocalsnapshots 2026-10-26-101500'" "dry-run lists an older one"

# ---------------------------------------------------------------------------
# deletelocalsnapshots <date> deletes that date on every mounted disk. A date
# that is another APFS volume's newest snapshot must survive.
add_volume() {   # add_volume <mount point> <snapshot>...
    local mp="$1"; shift
    echo "/dev/disk9s1 on ${mp} (apfs, local, nodev, nosuid, journaled, noowners)" >> "$MOUNT_OUT"
    printf '%s\n' "$@" > "${SNAP_DIR}/$(printf '%s' "$mp" | tr '/ ' '__')"
}
add_ro_volume() {   # read-only: deletelocalsnapshots cannot touch it
    local mp="$1"; shift
    echo "/dev/disk9s2 on ${mp} (apfs, local, nodev, nosuid, read-only, journaled, noowners)" >> "$MOUNT_OUT"
    printf '%s\n' "$@" > "${SNAP_DIR}/$(printf '%s' "$mp" | tr '/ ' '__')"
}

begin_test "a date that is another volume's newest snapshot is kept"
reset_state; set_status 0
add_volume "/Volumes/Ext" "$OLD1"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "2026-10-27-221500 " "only the date that is no volume's newest is deleted"

begin_test "another volume's older snapshots do not block a date"
reset_state; set_status 0
add_volume "/Volumes/My Disk" "$OLD1" "com.apple.TimeMachine.2026-10-28-120000.local"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "2026-10-26-101500 2026-10-27-221500 " "a volume name with a space is listed too"

begin_test "a volume whose snapshots cannot be listed stops the deletion"
reset_state; set_status 0
add_volume "/Volumes/Ext" "$OLD1"
: > "${SNAP_DIR}/_Volumes_Ext.fail"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "" "unknown volume: no deletion"
assert_eq "$(category_outcome time-machine)" "volumes-unknown" "outcome says why"

begin_test "an unreadable mount table stops the deletion"
reset_state; set_status 0
: > "${MOUNT_OUT}.fail"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "" "mount failed: no deletion"

begin_test "non-APFS volumes are not asked"
reset_state; set_status 0
echo "/dev/disk8s1 on /Volumes/USB (msdos, local, nodev, nosuid, noowners)" >> "$MOUNT_OUT"
: > "${SNAP_DIR}/_Volumes_USB.fail"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "2026-10-26-101500 2026-10-27-221500 " "an msdos stick does not block deletion"

begin_test "an APFS volume mounted outside /Volumes is asked too"
reset_state; set_status 0
add_volume "/Users/nobody/mnt/ext" "$OLD1"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "2026-10-27-221500 " "a custom mount point's newest is kept"

begin_test "read-only APFS mounts (simulator runtimes, images) are not asked"
reset_state; set_status 0
add_ro_volume "/Library/Developer/CoreSimulator/Volumes/iOS_21A328" "$OLD1"
: > "${SNAP_DIR}/_Library_Developer_CoreSimulator_Volumes_iOS_21A328.fail"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "2026-10-26-101500 2026-10-27-221500 " "a read-only image neither blocks nor protects"

begin_test "an APFS mount line that cannot be parsed stops the deletion"
reset_state; set_status 0
echo "garbled-line (apfs, local, journaled)" >> "$MOUNT_OUT"
clean_time_machine_snapshots >/dev/null 2>&1
assert_eq "$(deleted)" "" "unparseable mount table: no deletion"
assert_eq "$(category_outcome time-machine)" "volumes-unknown" "outcome says why"

begin_test "dry-run keeps another volume's newest too"
reset_state; set_status 0; DRY_RUN=1
add_volume "/Volumes/Ext" "$OLD2"
# shellcheck disable=SC2034  # read inside the assert_* eval strings
preview="$(clean_time_machine_snapshots 2>&1)"
assert_false "printf '%s' \"\$preview\" | grep -q 'deletelocalsnapshots 2026-10-27-221500'" "dry-run does not offer another volume's newest"
assert_true "printf '%s' \"\$preview\" | grep -q 'deletelocalsnapshots 2026-10-26-101500'" "dry-run lists the rest"

print_test_summary
