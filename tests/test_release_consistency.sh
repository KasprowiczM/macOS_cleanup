#!/usr/bin/env bash
# =============================================================================
# tests/test_release_consistency.sh — SCRIPT_VERSION, SHA256SUMS, portable docs
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

begin_test "SCRIPT_VERSION equals install.sh RELEASE_TAG without leading v"
script_version="$(sed -n 's/^readonly SCRIPT_VERSION="\([^"]*\)".*/\1/p' "${PROJ_DIR}/config/defaults.sh" | head -n 1)"
release_tag="$(sed -n 's/^RELEASE_TAG="\([^"]*\)".*/\1/p' "${PROJ_DIR}/install.sh" | head -n 1)"
assert_neq "$script_version" "" "SCRIPT_VERSION must be set"
assert_neq "$release_tag" "" "RELEASE_TAG must be set"
assert_eq "$script_version" "${release_tag#v}" \
    "SCRIPT_VERSION (${script_version}) must equal RELEASE_TAG without leading v (${release_tag})"

begin_test "P2: README footers and the cleanup_all.sh header carry SCRIPT_VERSION"
for readme in "${PROJ_DIR}"/README.md "${PROJ_DIR}"/README.*.md; do
    footer_version="$(grep -E '^[^|]*`macOS_cleanup` \|' "$readme" | sed -E 's/.*\| [^|]*: ?([0-9]+\.[0-9]+\.[0-9]+) \|.*/\1/' | head -n 1)"
    assert_eq "$footer_version" "$script_version" "$(basename "$readme") footer version"
done
header_version="$(sed -n 's/^# Version: \([0-9.]*\).*/\1/p' "${PROJ_DIR}/cleanup_all.sh" | head -n 1)"
assert_eq "$header_version" "$script_version" "cleanup_all.sh header version"
assert_false "grep -q 'SCRIPT_VERSION:-[0-9]' '${PROJ_DIR}/lib/planner.sh'" "no hard-coded version fallback in planner.sh"

begin_test "SHA256SUMS verifies from repo root"
sums_out="$(mktemp -t macos_cleanup_sha256sums.XXXXXX)"
set +e
( cd "$PROJ_DIR" && shasum -a 256 -c SHA256SUMS ) >"$sums_out" 2>&1
sums_rc=$?
set -u
if [[ "$sums_rc" -eq 0 ]]; then
    _pass
else
    _fail "shasum -a 256 -c SHA256SUMS failed (rc=${sums_rc}): $(tr '\n' ' ' < "$sums_out")"
fi
rm -f "$sums_out"

begin_test "Phase 4: SHA256SUMS covers every shipped script, rule file and schema"
listed="$(awk '{print $2}' "${PROJ_DIR}/SHA256SUMS")"
missing=""
shipped_count=0
while IFS= read -r shipped; do
    [[ -n "$shipped" ]] || continue
    shipped_count=$((shipped_count + 1))
    printf '%s\n' "$listed" | grep -qxF "$shipped" || missing="${missing} ${shipped}"
done < <(cd "$PROJ_DIR" && git ls-files -- cleanup_all.sh install.sh cleanup_rules.yaml \
    'config/*.sh' 'lib/*.sh' 'i18n/*.sh' 'tools/*.sh' 'dev-sync-*.sh' \
    'dev-sync/*.sh' 'dev-sync/*.py' 'schemas/*.json' 2>/dev/null)
assert_eq "${missing}" "" "shipped files missing from SHA256SUMS"
# An empty list (no git, or an exported tree) would pass without checking.
assert_true "(( shipped_count > 20 ))" "git ls-files listed the shipped files (got ${shipped_count})"

begin_test "protected-path docs check passes with isolated HOME"
iso_home="/tmp/macos_cleanup_isolated_home_$$"
check_out="$(mktemp -t macos_cleanup_protected_docs.XXXXXX)"
set +e
HOME="$iso_home" /bin/bash "${PROJ_DIR}/tools/gen_protected_docs.sh" --check >"$check_out" 2>&1
check_rc=$?
set -u
if [[ "$check_rc" -eq 0 ]]; then
    _pass
else
    _fail "HOME=${iso_home} tools/gen_protected_docs.sh --check failed (rc=${check_rc}): $(tr '\n' ' ' < "$check_out")"
fi
rm -f "$check_out"

print_test_summary
