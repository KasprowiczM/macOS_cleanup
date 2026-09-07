#!/usr/bin/env bash
# tests/test_installer_preserves_changes.sh — installer must not destroy local edits
set -u
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_installer.XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

OFFICIAL_HTTPS="https://github.com/KasprowiczM/macOS_cleanup.git"

# Make origin look official while fetches stay on a local path (no network).
point_origin_at_local() {
    local dest="$1"
    local upstream="$2"
    git -C "$dest" remote set-url origin "$OFFICIAL_HTTPS"
    git -C "$dest" config --local "url.${upstream}.insteadOf" "$OFFICIAL_HTTPS"
}

clone_dest() {
    local dest="$1"
    git clone --local --no-hardlinks "$PROJ_DIR" "$dest" >/dev/null 2>&1
}

# --- Dirty checkout: refuse and keep local bytes --------------------------------
DEST="${SANDBOX}/macOS_cleanup"
clone_dest "$DEST"
point_origin_at_local "$DEST" "$PROJ_DIR"
echo "LOCAL-CHANGE" >> "$DEST/cleanup_all.sh"
BEFORE="$(cksum "$DEST/cleanup_all.sh")"
export MACOS_CLEANUP_DIR="$DEST"
DIRTY_OUT="${SANDBOX}/dirty.out"
set +e
/bin/bash "${PROJ_DIR}/install.sh" --edge >"$DIRTY_OUT" 2>&1
rc=$?
set -u
AFTER="$(cksum "$DEST/cleanup_all.sh")"

begin_test "installer refuses dirty checkout and keeps local bytes"
assert_neq "$rc" "0" "dirty update must fail"
assert_eq "$BEFORE" "$AFTER" "installer must not reset --hard over local edits"
assert_true "grep -q 'LOCAL-CHANGE' \"$DEST/cleanup_all.sh\"" "local edit must remain"
assert_false "grep -q 'Installed to:' \"$DIRTY_OUT\"" "dirty refuse must not print success banner"

begin_test "install.sh never uses git reset --hard"
assert_false "grep -q 'reset --hard' \"${PROJ_DIR}/install.sh\"" "install.sh must not contain reset --hard"

begin_test "install.sh keeps honest did-not-run-cleanup messaging"
assert_true "grep -q 'did NOT run any cleanup' \"${PROJ_DIR}/install.sh\"" "installer must still say it did not run cleanup"

# --- SHA256SUMS mismatch on a clean DEST: abort, not a warning -------------------
SUMS_DEST="${SANDBOX}/macOS_cleanup_sums"
clone_dest "$SUMS_DEST"
git -C "$SUMS_DEST" checkout -B main >/dev/null 2>&1
{
    echo "0000000000000000000000000000000000000000000000000000000000000000  cleanup_all.sh"
    tail -n +2 "$SUMS_DEST/SHA256SUMS"
} > "${SUMS_DEST}/SHA256SUMS.tmp"
mv "${SUMS_DEST}/SHA256SUMS.tmp" "$SUMS_DEST/SHA256SUMS"
git -C "$SUMS_DEST" add SHA256SUMS
git -C "$SUMS_DEST" -c user.name=installer-test -c user.email=installer-test@example.com \
    commit -m "junk SHA256SUMS for installer test" >/dev/null 2>&1
BARE="${SANDBOX}/origin.git"
git clone --bare "$SUMS_DEST" "$BARE" >/dev/null 2>&1
point_origin_at_local "$SUMS_DEST" "$BARE"
SUMS_BEFORE="$(cksum "$SUMS_DEST/SHA256SUMS")"
export MACOS_CLEANUP_DIR="$SUMS_DEST"
SUMS_OUT="${SANDBOX}/sums.out"
set +e
/bin/bash "${PROJ_DIR}/install.sh" --edge >"$SUMS_OUT" 2>&1
sums_rc=$?
set -u
SUMS_AFTER="$(cksum "$SUMS_DEST/SHA256SUMS")"

begin_test "SHA256SUMS mismatch aborts install"
assert_neq "$sums_rc" "0" "checksum mismatch must abort"
assert_eq "$SUMS_BEFORE" "$SUMS_AFTER" "checksum abort must not rewrite SHA256SUMS"
assert_false "grep -q 'Installed to:' \"$SUMS_OUT\"" "checksum abort must not print success banner"
assert_false "grep -q 'Checksum verification warning' \"$SUMS_OUT\"" "mismatch must not be a warning"

print_test_summary
