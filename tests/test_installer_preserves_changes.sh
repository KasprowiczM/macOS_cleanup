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

# install.sh checks origin with `git remote get-url`, which applies insteadOf
# rewrites, so a url.<local>.insteadOf redirect made origin look unofficial and
# every case was refused at the origin check. Origin keeps the official URL;
# a git shim on PATH turns `fetch origin`, and a fresh `clone` of the official
# URL, into a fetch or clone from the local upstream (no network).
SHIM_DIR="${SANDBOX}/shim"
mkdir -p "$SHIM_DIR"
cat > "${SHIM_DIR}/git" <<'EOF'
#!/bin/bash
args=("$@")
i=0
while (( i + 1 < ${#args[@]} )); do
    if [[ "${args[i]}" == fetch && "${args[i+1]}" == origin ]]; then
        args[i+1]="$INSTALLER_TEST_UPSTREAM"
        break
    fi
    i=$((i + 1))
done
i=0
while (( i < ${#args[@]} )); do
    [[ "${args[i]}" == "$INSTALLER_TEST_OFFICIAL" ]] && args[i]="file://$INSTALLER_TEST_UPSTREAM"
    i=$((i + 1))
done
exec "$INSTALLER_TEST_REAL_GIT" "${args[@]}"
EOF
chmod +x "${SHIM_DIR}/git"
INSTALLER_TEST_REAL_GIT="$(command -v git)"
export INSTALLER_TEST_REAL_GIT
export INSTALLER_TEST_OFFICIAL="$OFFICIAL_HTTPS"

point_origin_at_local() {
    local dest="$1"
    local upstream="$2"
    git -C "$dest" remote set-url origin "$OFFICIAL_HTTPS"
    export INSTALLER_TEST_UPSTREAM="$upstream"
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
PATH="${SHIM_DIR}:${PATH}" /bin/bash "${PROJ_DIR}/install.sh" --edge >"$DIRTY_OUT" 2>&1
rc=$?
set -u
AFTER="$(cksum "$DEST/cleanup_all.sh")"

begin_test "installer refuses dirty checkout and keeps local bytes"
assert_neq "$rc" "0" "dirty update must fail"
assert_eq "$BEFORE" "$AFTER" "installer must not reset --hard over local edits"
assert_true "grep -q 'LOCAL-CHANGE' \"$DEST/cleanup_all.sh\"" "local edit must remain"
assert_false "grep -q 'Installed to:' \"$DIRTY_OUT\"" "dirty refuse must not print success banner"
assert_true "grep -q 'working tree is not clean' \"$DIRTY_OUT\"" "refused for the dirty tree, not another reason"

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
git clone --bare --no-hardlinks "$SUMS_DEST" "$BARE" >/dev/null 2>&1
point_origin_at_local "$SUMS_DEST" "$BARE"
SUMS_BEFORE="$(cksum "$SUMS_DEST/SHA256SUMS")"
export MACOS_CLEANUP_DIR="$SUMS_DEST"
SUMS_OUT="${SANDBOX}/sums.out"
set +e
PATH="${SHIM_DIR}:${PATH}" /bin/bash "${PROJ_DIR}/install.sh" --edge >"$SUMS_OUT" 2>&1
sums_rc=$?
set -u
SUMS_AFTER="$(cksum "$SUMS_DEST/SHA256SUMS")"

begin_test "SHA256SUMS mismatch aborts install"
assert_neq "$sums_rc" "0" "checksum mismatch must abort"
assert_eq "$SUMS_BEFORE" "$SUMS_AFTER" "checksum abort must not rewrite SHA256SUMS"
assert_false "grep -q 'Installed to:' \"$SUMS_OUT\"" "checksum abort must not print success banner"
assert_false "grep -q 'Checksum verification warning' \"$SUMS_OUT\"" "mismatch must not be a warning"
assert_true "grep -q 'checksum mismatch' \"$SUMS_OUT\"" "aborted for the mismatch, not another reason"

# --- Verified clean DEST: installs (the checks above must not block every install)
OK_DEST="${SANDBOX}/macOS_cleanup_ok"
clone_dest "$OK_DEST"
git -C "$OK_DEST" checkout -B main >/dev/null 2>&1
OK_BARE="${SANDBOX}/origin_ok.git"
git clone --bare --no-hardlinks "$OK_DEST" "$OK_BARE" >/dev/null 2>&1
point_origin_at_local "$OK_DEST" "$OK_BARE"
export MACOS_CLEANUP_DIR="$OK_DEST"
OK_OUT="${SANDBOX}/ok.out"
set +e
PATH="${SHIM_DIR}:${PATH}" /bin/bash "${PROJ_DIR}/install.sh" --edge >"$OK_OUT" 2>&1
ok_rc=$?
set -u

begin_test "a verified clean checkout installs"
assert_eq "$ok_rc" "0" "verified install must succeed: $(tr '\n' ' ' < "$OK_OUT")"
assert_true "grep -q 'Installed to:' \"$OK_OUT\"" "verified install prints the success banner"

# --- SHA256SUMS missing on a clean DEST: abort, not a silent skip --------------
NOSUMS_DEST="${SANDBOX}/macOS_cleanup_nosums"
clone_dest "$NOSUMS_DEST"
git -C "$NOSUMS_DEST" checkout -B main >/dev/null 2>&1
git -C "$NOSUMS_DEST" rm -q SHA256SUMS >/dev/null 2>&1
git -C "$NOSUMS_DEST" -c user.name=installer-test -c user.email=installer-test@example.com \
    commit -m "drop SHA256SUMS for installer test" >/dev/null 2>&1
NOSUMS_BARE="${SANDBOX}/origin_nosums.git"
git clone --bare --no-hardlinks "$NOSUMS_DEST" "$NOSUMS_BARE" >/dev/null 2>&1
point_origin_at_local "$NOSUMS_DEST" "$NOSUMS_BARE"
export MACOS_CLEANUP_DIR="$NOSUMS_DEST"
NOSUMS_OUT="${SANDBOX}/nosums.out"
set +e
PATH="${SHIM_DIR}:${PATH}" /bin/bash "${PROJ_DIR}/install.sh" --edge >"$NOSUMS_OUT" 2>&1
nosums_rc=$?
set -u

begin_test "Phase 4: a checkout without SHA256SUMS aborts install"
assert_neq "$nosums_rc" "0" "missing SHA256SUMS must abort"
assert_false "grep -q 'Installed to:' \"$NOSUMS_OUT\"" "missing SHA256SUMS must not print success banner"
assert_true "grep -q 'SHA256SUMS is missing' \"$NOSUMS_OUT\"" "aborted for the missing file, not another reason"

begin_test "Phase 4: a checksum mismatch names the file"
assert_true "grep -q 'cleanup_all.sh: FAILED' \"$SUMS_OUT\"" "the failing file is shown"

# --- Fresh clone (no DEST yet): the same checks run after `git clone` --------
# Reuses the upstreams above: junk SHA256SUMS, no SHA256SUMS, and a good one.
fresh_install() {
    local upstream="$1" out="$2"
    export INSTALLER_TEST_UPSTREAM="$upstream"
    MACOS_CLEANUP_DIR="${SANDBOX}/fresh_$(basename "$out" .out)"
    export MACOS_CLEANUP_DIR
    set +e
    PATH="${SHIM_DIR}:${PATH}" /bin/bash "${PROJ_DIR}/install.sh" --edge >"$out" 2>&1
    fresh_rc=$?
    set -u
}

begin_test "fresh clone: a verified checkout installs"
fresh_install "$OK_BARE" "${SANDBOX}/fresh_ok.out"
assert_eq "$fresh_rc" "0" "fresh verified install must succeed: $(tr '\n' ' ' < "${SANDBOX}/fresh_ok.out")"
assert_true "grep -q 'Cloning macOS Cleanup' \"${SANDBOX}/fresh_ok.out\"" "the fresh-clone path ran"
assert_true "grep -q 'Installed to:' \"${SANDBOX}/fresh_ok.out\"" "success banner"

begin_test "fresh clone: a checksum mismatch aborts and names the file"
fresh_install "$BARE" "${SANDBOX}/fresh_sums.out"
assert_neq "$fresh_rc" "0" "fresh mismatch must abort"
assert_true "grep -q 'cleanup_all.sh: FAILED' \"${SANDBOX}/fresh_sums.out\"" "the failing file is shown"
assert_false "grep -q 'Installed to:' \"${SANDBOX}/fresh_sums.out\"" "no success banner"

begin_test "fresh clone: a missing SHA256SUMS aborts"
fresh_install "$NOSUMS_BARE" "${SANDBOX}/fresh_nosums.out"
assert_neq "$fresh_rc" "0" "fresh install without SHA256SUMS must abort"
assert_true "grep -q 'SHA256SUMS is missing' \"${SANDBOX}/fresh_nosums.out\"" "aborted for the missing file"

# --- A rewritten upstream tag must not silently select the stale local tag. ---
begin_test "rewritten release tag refuses update without rewriting local work"
MIGRATION_DEST="${SANDBOX}/before_history_migration"
clone_dest "$MIGRATION_DEST"
MIGRATION_BARE="${SANDBOX}/rewritten_upstream.git"
git clone --bare --no-hardlinks "$PROJ_DIR" "$MIGRATION_BARE" >/dev/null 2>&1
git --git-dir="$MIGRATION_BARE" tag -f v3.0.7 main >/dev/null 2>&1
point_origin_at_local "$MIGRATION_DEST" "$MIGRATION_BARE"
MIGRATION_HEAD="$(git -C "$MIGRATION_DEST" rev-parse HEAD)"
MIGRATION_TAG="$(git -C "$MIGRATION_DEST" rev-parse refs/tags/v3.0.7)"
export MACOS_CLEANUP_DIR="$MIGRATION_DEST"
MIGRATION_OUT="${SANDBOX}/migration.out"
set +e
PATH="${SHIM_DIR}:${PATH}" /bin/bash "${PROJ_DIR}/install.sh" >"$MIGRATION_OUT" 2>&1
migration_rc=$?
set -u
assert_neq "$migration_rc" "0" "a changed release tag must abort"
assert_eq "$(git -C "$MIGRATION_DEST" rev-parse HEAD)" "$MIGRATION_HEAD" "migration refusal must preserve HEAD"
assert_eq "$(git -C "$MIGRATION_DEST" rev-parse refs/tags/v3.0.7)" "$MIGRATION_TAG" "migration refusal must preserve local tag"
assert_true "grep -q 'release tag differs' \"$MIGRATION_OUT\"" "explain the release history mismatch"
assert_true "grep -q 'fresh directory' \"$MIGRATION_OUT\"" "offer a fresh installation without replacing local work"
assert_false "grep -q 'Installed to:' \"$MIGRATION_OUT\"" "refusal must not claim installation success"

print_test_summary
