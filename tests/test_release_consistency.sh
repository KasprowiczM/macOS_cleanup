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
