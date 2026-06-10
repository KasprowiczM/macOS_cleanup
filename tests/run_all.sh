#!/usr/bin/env bash
# =============================================================================
# tests/run_all.sh — entry point for all tests.
# Returns non-zero if any test fails.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL_COUNT=0

echo "==========================================================="
echo " macOS_cleanup test suite"
echo "==========================================================="

for test_file in "${TEST_DIR}"/test_*.sh; do
    [[ -f "$test_file" ]] || continue
    echo
    echo ">>> $(basename "$test_file")"
    if bash "$test_file"; then
        :
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
done

echo
if (( FAIL_COUNT == 0 )); then
    echo "ALL TEST FILES PASSED"
    exit 0
else
    echo "FAILURES IN ${FAIL_COUNT} TEST FILE(S)"
    exit 1
fi
