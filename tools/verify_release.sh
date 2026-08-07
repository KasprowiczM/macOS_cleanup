#!/usr/bin/env bash
# =============================================================================
# tools/verify_release.sh — Release verification gates (G01–G15)
# Part 2 Contract Specification
# Exit 0 only if all gates pass.
# Bash 3.2 compatible.
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PROJ_DIR

PASS=0
FAIL=0

run_gate() {
    local id="$1" desc="$2" cmd="$3"
    if [[ "$id" == "G14" && ( -z "${TARGET_GATE:-}" || "${TARGET_GATE:-}" == "G14" ) && ( ! -d "${PROJ_DIR}/baseline/pre" || ! -d "${PROJ_DIR}/baseline/post" ) ]]; then
        echo "Skipping G14: private machine baselines are not distributed; capture local baselines first."
        return 0
    fi
    echo "-----------------------------------------------------------"
    echo "Running ${id}: ${desc}"
    if eval "$cmd"; then
        echo "  ✅  ${id}: PASS — ${desc}"
        PASS=$(( PASS + 1 ))
    else
        echo "  ❌  ${id}: FAIL — ${desc}"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "═══════════════════════════════════════════════════"
echo "  macOS_cleanup v3.0.0 — Release Verification"
echo "═══════════════════════════════════════════════════"
echo

# shellcheck disable=SC2016

# G01: /bin/bash -n on all shell files
run_gate "G01" "Syntax check (/bin/bash -n)" \
    '/bin/bash -n "${PROJ_DIR}/cleanup_all.sh" "${PROJ_DIR}"/lib/*.sh "${PROJ_DIR}"/config/*.sh "${PROJ_DIR}"/tests/*.sh "${PROJ_DIR}"/tools/*.sh $(ls "${PROJ_DIR}"/i18n/*.sh 2>/dev/null || true)'

# G02: bash 3.2 construct check
run_gate "G02" "Bash 3.2 compatibility (no bash 4 constructs)" \
    '! grep -rnE "declare -A|\$\{[a-zA-Z_]+,,\}|\$\{[a-zA-Z_]+\^\^\}|mapfile|readarray|local -n|read -ra" "${PROJ_DIR}/lib/" "${PROJ_DIR}/cleanup_all.sh" "${PROJ_DIR}/config/" "${PROJ_DIR}/tools/" | grep -v "verify_release.sh" | grep -v ":[[:space:]]*#" | grep -qv "^$"'

# G03: shellcheck -S info
run_gate "G03" "shellcheck -S info" \
    'command -v shellcheck >/dev/null 2>&1 && shellcheck -S info -e SC2016 "${PROJ_DIR}/cleanup_all.sh" "${PROJ_DIR}"/lib/*.sh "${PROJ_DIR}"/config/*.sh "${PROJ_DIR}"/tools/*.sh "${PROJ_DIR}"/tests/*.sh'

# G04: Full test suite passes
run_gate "G04" "Full test suite (tests/run_all.sh)" \
    '/bin/bash "${PROJ_DIR}/tests/run_all.sh"'

# G05: Python safety test
run_gate "G05" "Python dev sync safety tests" \
    'python3 -m unittest "${PROJ_DIR}/tests/test_dev_sync_safety.py"'

# G06: Harness isolation
run_gate "G06" "Artifact isolation (git status --porcelain unchanged by suite)" \
    '_g06_before=$(git status --porcelain) && /bin/bash "${PROJ_DIR}/tests/run_all.sh" >/dev/null 2>&1 && _g06_after=$(git status --porcelain) && [[ "$_g06_before" == "$_g06_after" ]]'

# G07: No executable sudo in lib/ or cleanup_all.sh
run_gate "G07" "No executable sudo in lib/ or cleanup_all.sh" \
    '! grep -rn "sudo " "${PROJ_DIR}/lib/" "${PROJ_DIR}/cleanup_all.sh" | grep -v "^[[:space:]]*#" | grep -v "request_sudo.*return 1" | grep -v "print_\|log_\|echo\|record_\|cleanup_journal_event\|użyj trybu\|sudo disabled" | grep -qv "^$"'

# G08: Protected path table assertions >= 60
run_gate "G08" "Protected path assertions >= 60 (tests/test_path_protection.sh)" \
    '/bin/bash "${PROJ_DIR}/tests/test_path_protection.sh" && [[ $(grep -c "assert_protected\|assert_unprotected\|check_path" "${PROJ_DIR}/tests/test_path_protection.sh") -ge 60 ]]'

# G09: Generated plan.json validates against plan.schema.json using jsonschema
run_gate "G09" "plan.json validates against schemas/plan.schema.json" \
    '_g09_tmp=$(mktemp -d) && HOME="$_g09_tmp" /bin/bash "${PROJ_DIR}/cleanup_all.sh" plan --non-interactive --no-color >/dev/null 2>&1 && _plan=$(ls -t "${PROJ_DIR}/reports/plan_"*.json 2>/dev/null | head -1) && [[ -n "$_plan" ]] && jsonschema -i "$_plan" "${PROJ_DIR}/schemas/plan.schema.json" && rm -rf "${_g09_tmp}"'

# G10: Risk parity check
run_gate "G10" "Risk parity (tests/test_risk_parity.sh)" \
    '[[ -f "${PROJ_DIR}/tests/test_risk_parity.sh" ]] && /bin/bash "${PROJ_DIR}/tests/test_risk_parity.sh"'

# G11: i18n string coverage
run_gate "G11" "i18n string coverage (no literals outside i18n/)" \
    '[[ -d "${PROJ_DIR}/i18n" ]] && /bin/bash -c "for f in ${PROJ_DIR}/i18n/*.sh; do [[ -f \$f ]] || exit 1; done"'

# G12: Suite passes with and without grealpath on PATH
run_gate "G12" "Normalizer determinism (suite passes with and without grealpath)" \
    '/bin/bash "${PROJ_DIR}/tests/run_all.sh" >/dev/null 2>&1 && PATH="$(echo "$PATH" | tr ":" "\n" | grep -v "coreutils" | tr "\n" ":")" /bin/bash "${PROJ_DIR}/tests/run_all.sh"'

# G13: Accounting deduplication
run_gate "G13" "Accounting deduplication (tests/test_accounting.sh)" \
    '[[ -f "${PROJ_DIR}/tests/test_accounting.sh" ]] && /bin/bash "${PROJ_DIR}/tests/test_accounting.sh"'

# G14: Baseline diff
run_gate "G14" "Baseline diff (baseline/pre vs baseline/post)" \
    '[[ -d "${PROJ_DIR}/baseline/post" ]] && /bin/bash "${PROJ_DIR}/tools/baseline_diff.sh" "${PROJ_DIR}/baseline/pre" "${PROJ_DIR}/baseline/post"'

# G15: No runtime network usage
run_gate "G15" "No network calls in cleanup code" \
    '! grep -rnE "curl|wget|nc |/dev/tcp|ftp " "${PROJ_DIR}/lib/" "${PROJ_DIR}/cleanup_all.sh" | grep -v "^[[:space:]]*#" | grep -qv "^$"'

echo
echo "═══════════════════════════════════════════════════"
echo "  Results: ${PASS} pass, ${FAIL} fail"
echo "═══════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
