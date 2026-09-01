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
    if [[ "${QUIET:-0}" -eq 1 ]]; then
        tlog="$(mktemp)"
        if bash "$test_file" > "$tlog" 2>&1; then
            grep -E '^(Pass:|Fail:)' "$tlog" || echo "Pass: OK"
            rm -f "$tlog"
        else
            cat "$tlog"
            rm -f "$tlog"
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        fi
    else
        if bash "$test_file"; then
            :
        else
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        fi
    fi
done

# tests/test_dev_sync_safety.py is listed in AGENTS.md's minimum workflow but the
# glob above only matches test_*.sh, so for months it ran only when someone
# remembered to type it. Wire it in.
if [[ -f "${TEST_DIR}/test_dev_sync_safety.py" ]]; then
    echo
    echo ">>> test_dev_sync_safety.py"
    if ( cd "${TEST_DIR}/.." && python3 -m unittest tests/test_dev_sync_safety.py ) 2>&1 | tail -3; then
        :
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
fi

echo
if (( FAIL_COUNT == 0 )); then
    echo "ALL TEST FILES PASSED"
    exit 0
else
    echo "FAILURES IN ${FAIL_COUNT} TEST FILE(S)"
    exit 1
fi
