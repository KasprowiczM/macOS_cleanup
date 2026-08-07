#!/usr/bin/env bash
# =============================================================================
# tools/mutate_check.sh <source_file> <sed_expr> <test_file>
#
# Applies a temporary mutation to source_file, runs test_file, restores
# source_file, and reports whether the test caught the mutation (i.e. failed).
# Bash 3.2 compatible.
# =============================================================================

set -eu

SRC="${1:-}"
EXPR="${2:-}"
TEST="${3:-}"

if [[ -z "$SRC" || -z "$EXPR" || -z "$TEST" ]]; then
    echo "Usage: $0 <source_file> <sed_expr> <test_file>" >&2
    exit 1
fi

BAK="${SRC}.mutate_bak_$$"
cp "$SRC" "$BAK"
trap 'mv -f "$BAK" "$SRC" 2>/dev/null || true' EXIT INT TERM

echo "Applying mutation to ${SRC}: ${EXPR}"
sed -E -i '' "$EXPR" "$SRC" 2>/dev/null || sed -E -i "$EXPR" "$SRC"

echo "Running test: ${TEST}"
set +e
/bin/bash "$TEST" > /tmp/mutate_test.log 2>&1
TEST_RC=$?
set -e

# Restore original
mv -f "$BAK" "$SRC"
trap - EXIT INT TERM

if (( TEST_RC != 0 )); then
    echo "✅ MUTATION CAUGHT: Test failed as expected (exit code ${TEST_RC})"
    exit 0
else
    echo "❌ MUTATION ESCAPED: Test passed despite mutation!"
    exit 1
fi
