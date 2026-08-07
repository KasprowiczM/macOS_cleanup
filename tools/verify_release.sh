#!/usr/bin/env bash
# =============================================================================
# tools/verify_release.sh — Release verification gates (G01–G15)
#
# Runs all verification gates for the 3.0.0 release. Each gate prints
# PASS or FAIL with an explanation. Exit 0 only if all gates pass.
# Bash 3.2 compatible.
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

gate() {
    local id="$1" desc="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then
        echo "  ✅  ${id}: ${desc}"
        PASS=$(( PASS + 1 ))
    else
        echo "  ❌  ${id}: ${desc}"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "═══════════════════════════════════════════════════"
echo "  macOS_cleanup v3.0.0 — Release Verification"
echo "═══════════════════════════════════════════════════"
echo

# G01: Syntax check
gate "G01" "bash -n on all .sh files" \
    /bin/bash -c '/bin/bash -n '"${PROJ_DIR}"'/cleanup_all.sh '"${PROJ_DIR}"'/lib/*.sh '"${PROJ_DIR}"'/config/*.sh '"${PROJ_DIR}"'/tests/*.sh'

# G02: Test suite passes
gate "G02" "All test files pass" \
    /bin/bash "${PROJ_DIR}/tests/run_all.sh"

# G03: No sudo in execution paths
gate "G03" "No executable sudo calls in lib/" \
    /bin/bash -c '! grep -rn "sudo " '"${PROJ_DIR}"'/lib/*.sh | grep -v "^.*:#" | grep -v "cleanup_sudo_keepalive" | grep -v "request_sudo.*return 1" | grep -v "print_\|log_\|echo\|record_" | grep -qv "^$"'

# G04: Version is 3.0.0
gate "G04" "Version string is 3.0.0" \
    /bin/bash -c 'grep -q "SCRIPT_VERSION=\"3.0.0\"" '"${PROJ_DIR}"'/config/defaults.sh'

# G05: CHANGELOG has 3.0.0 entry
gate "G05" "CHANGELOG contains [3.0.0] entry" \
    /bin/bash -c 'grep -q "\[3.0.0\]" '"${PROJ_DIR}"'/CHANGELOG.md'

# G06: No read -ra in common.sh (bash 3.2 compat)
gate "G06" "No read -ra in common.sh (bash 3.2)" \
    /bin/bash -c '! grep -q "read -ra\|read -a" '"${PROJ_DIR}"'/lib/common.sh'

# G07: No _REALPATH_HAS_M in common.sh
gate "G07" "No realpath -m probe in common.sh" \
    /bin/bash -c '! grep -q "_REALPATH_HAS_M\|_REALPATH_CMD" '"${PROJ_DIR}"'/lib/common.sh'

# G08: Protected path test exists and passes
gate "G08" "test_path_protection.sh exists and passes" \
    /bin/bash "${PROJ_DIR}/tests/test_path_protection.sh"

# G09: NEVER_TOUCH has cloud storage paths
gate "G09" "NEVER_TOUCH includes cloud storage" \
    /bin/bash -c 'grep -q "CloudStorage\|Dropbox\|OneDrive" '"${PROJ_DIR}"'/config/defaults.sh'

# G10: assert_safe_path returns 1, not exit 99
gate "G10" "assert_safe_path uses return, not exit 99" \
    /bin/bash -c '! grep -q "exit 99" '"${PROJ_DIR}"'/lib/common.sh'

# G11: System caches report-only
gate "G11" "clean_system_caches is report-only" \
    /bin/bash -c 'grep -q "report.only\|report_only\|tylko raport" '"${PROJ_DIR}"'/lib/cleaner.sh'

# G12: Dry-run runs without error
gate "G12" "cleanup_all.sh --dry-run exits 0" \
    /bin/bash "${PROJ_DIR}/cleanup_all.sh" --dry-run

# G13: INT/TERM trap exists
gate "G13" "INT/TERM signal trap registered" \
    /bin/bash -c 'grep -q "trap.*INT.*TERM\|trap.*_on_interrupt.*INT" '"${PROJ_DIR}"'/cleanup_all.sh'

# G14: Fail-closed normalization in safe_remove
gate "G14" "safe_remove has fail-closed normalization check" \
    /bin/bash -c 'grep -q "normalization.failed\|normalization_failed" '"${PROJ_DIR}"'/lib/common.sh'

# G15: LOGS_DIR/REPORTS_DIR env-overridable
gate "G15" "LOGS_DIR uses env override pattern" \
    /bin/bash -c 'grep -q "LOGS_DIR:-\|LOGS_DIR=.*{LOGS_DIR" '"${PROJ_DIR}"'/config/defaults.sh'

echo
echo "═══════════════════════════════════════════════════"
echo "  Results: ${PASS} pass, ${FAIL} fail"
echo "═══════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
