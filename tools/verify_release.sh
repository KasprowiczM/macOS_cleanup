#!/usr/bin/env bash
# =============================================================================
# tools/verify_release.sh — Release verification gates (G01–G15)
# Part 2 & Part 0.1 Contract Specification
# Exit 0 only if all gates pass.
# Bash 3.2 compatible.
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PROJ_DIR

QUICK_MODE=0
TARGET_GATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK_MODE=1
            shift
            ;;
        --gate)
            TARGET_GATE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

PASS=0
FAIL=0

run_gate() {
    local id="$1" desc="$2" cmd="$3"
    if [[ "$id" == "G14" && ( -z "${TARGET_GATE:-}" || "${TARGET_GATE:-}" == "G14" ) && ( ! -d "${PROJ_DIR}/baseline/pre" || ! -d "${PROJ_DIR}/baseline/post" ) ]]; then
        echo "Skipping G14: private machine baselines are not distributed; capture local baselines first."
        return 0
    fi
    
    if [[ -n "$TARGET_GATE" && "$TARGET_GATE" != "$id" ]]; then
        return 0
    fi
    if [[ "$QUICK_MODE" -eq 1 && ("$id" == "G04" || "$id" == "G06" || "$id" == "G12") ]]; then
        echo "-----------------------------------------------------------"
        echo "Skipping ${id} (--quick mode): ${desc}"
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

SUITE_RUN_NEEDED=0
if [[ "$QUICK_MODE" -eq 0 ]]; then
    if [[ -z "$TARGET_GATE" || "$TARGET_GATE" == "G04" || "$TARGET_GATE" == "G06" || "$TARGET_GATE" == "G08" || "$TARGET_GATE" == "G10" || "$TARGET_GATE" == "G13" ]]; then
        SUITE_RUN_NEEDED=1
    fi
fi

_SUITE_LOG=""
_SUITE_RC=0
_GIT_BEFORE=""
_GIT_AFTER=""

if [[ "$SUITE_RUN_NEEDED" -eq 1 ]]; then
    _SUITE_LOG="$(mktemp -t verify_suite.XXXXXX)"
    trap 'rm -f "$_SUITE_LOG"' EXIT
    _GIT_BEFORE="$(git status --porcelain)"
    /bin/bash "${PROJ_DIR}/tests/run_all.sh" > "$_SUITE_LOG" 2>&1
    _SUITE_RC=$?
    _GIT_AFTER="$(git status --porcelain)"
fi

# G01: Syntax check
run_gate "G01" "Syntax check (/bin/bash -n)" \
    '/bin/bash -n "${PROJ_DIR}/cleanup_all.sh" "${PROJ_DIR}"/lib/*.sh "${PROJ_DIR}"/config/*.sh "${PROJ_DIR}"/tests/*.sh "${PROJ_DIR}"/tools/*.sh $(ls "${PROJ_DIR}"/i18n/*.sh 2>/dev/null || true)'

# G02: Bash 3.2 compatibility
run_gate "G02" "Bash 3.2 compatibility (no bash 4 constructs)" \
    '! grep -rnE "declare -A|\$\{[a-zA-Z_]+,,\}|\$\{[a-zA-Z_]+\^\^\}|mapfile|readarray|local -n|read -ra" "${PROJ_DIR}/lib/" "${PROJ_DIR}/cleanup_all.sh" "${PROJ_DIR}/config/" "${PROJ_DIR}/tools/" | grep -v "verify_release.sh" | grep -v ":[[:space:]]*#" | grep -qv "^$"'

# G03: shellcheck -S info
run_gate "G03" "shellcheck -S info" \
    'command -v shellcheck >/dev/null 2>&1 && shellcheck -S info -e SC2016 "${PROJ_DIR}/cleanup_all.sh" "${PROJ_DIR}"/lib/*.sh "${PROJ_DIR}"/config/*.sh "${PROJ_DIR}"/tools/*.sh "${PROJ_DIR}"/tests/*.sh'

# G04: Full test suite passes
run_gate "G04" "Full test suite (tests/run_all.sh)" \
    '[[ "$_SUITE_RC" -eq 0 ]] && grep -q "ALL TEST FILES PASSED" "$_SUITE_LOG"'

# G05: Python dev sync safety
run_gate "G05" "Python dev sync safety tests" \
    'python3 -m unittest "${PROJ_DIR}/tests/test_dev_sync_safety.py"'

# G06: Artifact isolation
run_gate "G06" "Artifact isolation (git status --porcelain unchanged by suite)" \
    '[[ "$_GIT_BEFORE" == "$_GIT_AFTER" ]]'

# G07: No executable sudo
run_gate "G07" "No executable sudo in lib/ or cleanup_all.sh" \
    '! grep -rn "sudo " "${PROJ_DIR}/lib/" "${PROJ_DIR}/cleanup_all.sh" | grep -v "^[[:space:]]*#" | grep -v "request_sudo.*return 1" | grep -v "print_\|log_\|echo\|record_\|cleanup_journal_event\|użyj trybu\|sudo disabled" | grep -qv "^$"'

# G08: Protected path assertions >= 60
run_gate "G08" "Protected path assertions >= 60 (tests/test_path_protection.sh)" \
    'if [[ -n "$_SUITE_LOG" ]]; then [[ "$_SUITE_RC" -eq 0 ]]; else /bin/bash "${PROJ_DIR}/tests/test_path_protection.sh" >/dev/null 2>&1; fi && [[ $(grep -c "assert_protected\|assert_unprotected\|check_path" "${PROJ_DIR}/tests/test_path_protection.sh") -ge 60 ]]'

# G09: plan.json schema validation
run_gate "G09" "plan.json validates against schemas/plan.schema.json" \
    '_g09_tmp=$(mktemp -d) && HOME="$_g09_tmp" /bin/bash "${PROJ_DIR}/cleanup_all.sh" plan --non-interactive --no-color >/dev/null 2>&1 && _plan=$(ls -t "${PROJ_DIR}/reports/plan_"*.json 2>/dev/null | head -1) && [[ -n "$_plan" ]] && jsonschema -i "$_plan" "${PROJ_DIR}/schemas/plan.schema.json" && rm -rf "${_g09_tmp}"'

# G10: Risk parity (Must check category_max_risk wiring and parity assertions)
run_gate "G10" "Risk parity (tests/test_risk_parity.sh)" \
    '[[ $(grep -c "category_max_risk\|policy_adjust_risk_for_path" "${PROJ_DIR}/lib/cleaner.sh") -ge 12 ]] && ! grep -qE -e '\''--risk "(LOW|MEDIUM|HIGH)"'\'' "${PROJ_DIR}/lib/cleaner.sh" && [[ -f "${PROJ_DIR}/tests/test_risk_parity.sh" ]] && /bin/bash "${PROJ_DIR}/tests/test_risk_parity.sh"'

# G11: i18n string coverage (Must check 7 lang files, key equality, and 0 Polish literals)
run_gate "G11" "i18n string coverage (no literals outside i18n/)" \
    '[[ -d "${PROJ_DIR}/i18n" ]] && [[ -f "${PROJ_DIR}/i18n/en.sh" ]] && [[ -f "${PROJ_DIR}/i18n/pl.sh" ]] && [[ -f "${PROJ_DIR}/i18n/de.sh" ]] && [[ -f "${PROJ_DIR}/i18n/es.sh" ]] && [[ -f "${PROJ_DIR}/i18n/fr.sh" ]] && [[ -f "${PROJ_DIR}/i18n/it.sh" ]] && [[ -f "${PROJ_DIR}/i18n/pt.sh" ]] && [[ $(grep -rcE "[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]" "${PROJ_DIR}/lib/"*.sh "${PROJ_DIR}/cleanup_all.sh" | awk -F: "{s+=\$2} END{print s}") -eq 0 ]] && /bin/bash "${PROJ_DIR}/tests/test_i18n_accessibility.sh" >/dev/null 2>&1'

# G12: Suite passes with and without grealpath on PATH (Only gate allowed 2nd full suite run)
run_gate "G12" "Normalizer determinism (suite passes with and without grealpath)" \
    'PATH="$(echo "$PATH" | tr ":" "\n" | grep -v "coreutils" | tr "\n" ":")" /bin/bash "${PROJ_DIR}/tests/run_all.sh" >/dev/null 2>&1'

# G13: Accounting deduplication
run_gate "G13" "Accounting deduplication (tests/test_accounting.sh)" \
    'if [[ -n "$_SUITE_LOG" ]]; then [[ "$_SUITE_RC" -eq 0 ]]; else [[ -f "${PROJ_DIR}/tests/test_accounting.sh" ]] && /bin/bash "${PROJ_DIR}/tests/test_accounting.sh" >/dev/null 2>&1; fi'

# G14: Baseline diff
run_gate "G14" "Baseline diff (baseline/pre vs baseline/post)" \
    '[[ -d "${PROJ_DIR}/baseline/post" ]] && /bin/bash "${PROJ_DIR}/tools/baseline_diff.sh" "${PROJ_DIR}/baseline/pre" "${PROJ_DIR}/baseline/post"'

# G15: No runtime network usage
run_gate "G15" "No network calls in cleanup code" \
    '! grep -rnE "curl|wget|nc |/dev/tcp|ftp " "${PROJ_DIR}/lib/" "${PROJ_DIR}/cleanup_all.sh" | grep -v "^[[:space:]]*#" | grep -qv "^$"'

# G16: Functional smoke gate (assert tool actually cleans and quarantines removable cache)
run_gate "G16" "Functional deletion smoke gate (quarantine mode cleans candidate)" \
    '_g16_tmp=$(mktemp -d) && mkdir -p "${_g16_tmp}/home/Library/Caches/smoke_app" && echo "smoke" > "${_g16_tmp}/home/Library/Caches/smoke_app/data.bin" && _g16_out=$(env HOME="${_g16_tmp}/home" LOGS_DIR="${_g16_tmp}/logs" REPORTS_DIR="${_g16_tmp}/reports" CLEANUP_JOURNAL_FILE="${_g16_tmp}/reports/journal.jsonl" QUARANTINE_ROOT="${_g16_tmp}/quarantine" /bin/bash "${PROJ_DIR}/cleanup_all.sh" --category user-caches --interactive --no-color <<< "y" 2>&1) && [[ ! -d "${_g16_tmp}/home/Library/Caches/smoke_app" ]] && echo "$_g16_out" | grep -q "Quarantining" && rm -rf "${_g16_tmp}"'

# G17: Plan risk vs policy parity
run_gate "G17" "Plan risk vs policy parity (tests/test_plan_policy_parity.sh)" \
    '[[ -f "${PROJ_DIR}/tests/test_plan_policy_parity.sh" ]] && /bin/bash "${PROJ_DIR}/tests/test_plan_policy_parity.sh"'

echo
echo "═══════════════════════════════════════════════════"
echo "  Results: ${PASS} pass, ${FAIL} fail"
echo "═══════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
