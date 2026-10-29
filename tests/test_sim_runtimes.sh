#!/usr/bin/env bash
# =============================================================================
# tests/test_sim_runtimes.sh — Phase 3 (13): unusable simulator runtimes.
#
# Simulator runtimes live in a system-managed store and must be removed with
# `xcrun simctl runtime delete`, never with rm. Only the runtimes simctl itself
# marks unusable are offered, as REVIEW, in --interactive only, and never while
# Xcode, Simulator or xcodebuild runs. xcrun and pgrep are recording stubs.
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_simrt.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
export USER="${USER:-testuser}"
export LOG_LEVEL="ERROR"
export NO_COLOR=1
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$HOME" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/planner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

STUB_BIN="${SANDBOX}/bin"; CALLS="${SANDBOX}/calls.log"
DRY_OUT="${SANDBOX}/dry.out"; LIST_JSON="${SANDBOX}/list.json"; BUSY="${SANDBOX}/busy"
DRY_RC="${SANDBOX}/dry.rc"; DRY_STDOUT="${SANDBOX}/dry.stdout"; NODEV="${SANDBOX}/nodev"
mkdir -p "$STUB_BIN"
cat > "${STUB_BIN}/xcrun" <<STUB
#!/bin/sh
echo "xcrun \$*" >> "${CALLS}"
case "\$*" in
    "simctl runtime delete --unusable --dry-run")
        # The real simctl prints this report on stderr, and exits 2 when
        # nothing matches.
        if [ -f "${DRY_STDOUT}" ]; then cat "${DRY_OUT}"; else cat "${DRY_OUT}" >&2; fi
        exit "\$(cat "${DRY_RC}")" ;;
    "simctl runtime list -j") cat "${LIST_JSON}" ;;
    "simctl runtime delete --unusable") exit 0 ;;
esac
exit 0
STUB
cat > "${STUB_BIN}/pgrep" <<STUB
#!/bin/sh
[ -f "${BUSY}" ] || exit 1
for a in "\$@"; do [ "\$a" = "\$(cat "${BUSY}")" ] && exit 0; done
exit 1
STUB
cat > "${STUB_BIN}/xcode-select" <<STUB
#!/bin/sh
[ -f "${NODEV}" ] && exit 2
echo /Applications/Xcode.app/Contents/Developer
STUB
chmod +x "${STUB_BIN}/xcrun" "${STUB_BIN}/pgrep" "${STUB_BIN}/xcode-select"
export PATH="${STUB_BIN}:${PATH}"

U1="AAAAAAAA-1111-2222-3333-444444444444"
U2="BBBBBBBB-1111-2222-3333-444444444444"
USED="CCCCCCCC-1111-2222-3333-444444444444"

# shellcheck disable=SC2034  # globals read by the sourced lib functions
reset_state() {
    : > "$CALLS"; rm -f "$BUSY" "$DRY_STDOUT" "$NODEV"; echo 0 > "$DRY_RC"
    CLEANUP_CATEGORY_OUTCOMES=""
    FOUND_DEV_ITEMS=()
    catbytes_set "sim-runtimes" 0
    MODE="interactive"; DRY_RUN=0; EXPLICIT_DRY_RUN=0
    printf 'Would delete: %s (iOS 16.4)\nWould delete: %s (watchOS 9.4)\n' "$U1" "$U2" > "$DRY_OUT"
    cat > "$LIST_JSON" <<JSON
{
  "${U1}" : { "identifier" : "${U1}", "sizeBytes" : 1000, "state" : "Unusable" },
  "${U2}" : { "identifier" : "${U2}", "sizeBytes" : 2000, "state" : "Unusable" },
  "${USED}" : { "identifier" : "${USED}", "sizeBytes" : 9000, "state" : "Ready" }
}
JSON
}
deleted() { grep -c '^xcrun simctl runtime delete --unusable$' "$CALLS"; }
confirm_category() { return 0; }

# ---------------------------------------------------------------------------
begin_test "unusable runtimes are found and sized from simctl's own selection"
reset_state
analyze_sim_runtimes >/dev/null 2>&1
# The ${arr[@]+...} form: an empty array under set -u aborts the pipeline
# subshell in bash 3.2, which then runs the EXIT trap and removes $SANDBOX.
assert_true "printf '%s\n' \${FOUND_DEV_ITEMS[@]+\"\${FOUND_DEV_ITEMS[@]}\"} | grep -qx 'sim_runtimes_unusable:__simctl_runtime__'" "found"
assert_eq "$(catbytes_get sim-runtimes)" "3000" "only the two unusable runtimes are counted"

begin_test "a report on stdout is read as well"
reset_state
touch "$DRY_STDOUT"
analyze_sim_runtimes >/dev/null 2>&1
assert_eq "${#FOUND_DEV_ITEMS[@]}" "1" "found"
assert_eq "$(catbytes_get sim-runtimes)" "3000" "sized"

begin_test "nothing to delete (simctl exits 2): nothing found"
reset_state
echo "No matching images found to delete" > "$DRY_OUT"; echo 2 > "$DRY_RC"
analyze_sim_runtimes >/dev/null 2>&1
assert_eq "${#FOUND_DEV_ITEMS[@]}" "0" "no item"

begin_test "no developer tools: simctl is not asked"
reset_state
touch "$NODEV"
analyze_sim_runtimes >/dev/null 2>&1
assert_eq "${#FOUND_DEV_ITEMS[@]}" "0" "no item"
assert_false "grep -q simctl \"\$CALLS\"" "xcrun was not run (it can open the install-tools dialog)"

begin_test "a size that cannot be read still offers the runtimes"
reset_state
echo "not json" > "$LIST_JSON"
analyze_sim_runtimes >/dev/null 2>&1
assert_eq "${#FOUND_DEV_ITEMS[@]}" "1" "found"
assert_eq "$(catbytes_get sim-runtimes)" "0" "size unknown"

begin_test "an odd list entry does not hide the other sizes"
reset_state
printf '{ "x" : "str", "%s" : { "identifier" : "%s", "sizeBytes" : 1000 } }\n' "$U1" "$U1" > "$LIST_JSON"
analyze_sim_runtimes >/dev/null 2>&1
assert_eq "$(catbytes_get sim-runtimes)" "1000" "sized from the valid entry"

begin_test "interactive: deleted with simctl after consent, never with rm"
reset_state; analyze_sim_runtimes >/dev/null 2>&1
clean_sim_runtimes >/dev/null 2>&1
assert_eq "$(deleted)" "1" "simctl runtime delete --unusable ran once"
assert_eq "$(category_outcome sim-runtimes)" "cleaned" "outcome"
assert_false "declare -f clean_sim_runtimes | grep -Eq '(^|[^_])(rm|safe_remove) '" "no rm / safe_remove"

begin_test "declined: nothing deleted"
reset_state; analyze_sim_runtimes >/dev/null 2>&1
confirm_category() { return 1; }
clean_sim_runtimes >/dev/null 2>&1
confirm_category() { return 0; }
assert_eq "$(deleted)" "0" "declined"
assert_eq "$(category_outcome sim-runtimes)" "skipped" "outcome"

begin_test "Xcode, Simulator or xcodebuild running: nothing deleted"
for proc in Xcode Simulator xcodebuild; do
    reset_state; analyze_sim_runtimes >/dev/null 2>&1
    echo "$proc" > "$BUSY"
    clean_sim_runtimes >/dev/null 2>&1
    assert_eq "$(deleted)" "0" "$proc running"
    assert_eq "$(category_outcome sim-runtimes)" "in-use" "$proc: outcome in-use"
done

begin_test "Xcode started while the prompt was open: nothing deleted"
reset_state; analyze_sim_runtimes >/dev/null 2>&1
confirm_category() { echo Xcode > "$BUSY"; return 0; }
clean_sim_runtimes >/dev/null 2>&1
confirm_category() { return 0; }
assert_eq "$(deleted)" "0" "busy after consent"
assert_eq "$(category_outcome sim-runtimes)" "in-use" "outcome in-use"

begin_test "non-interactive modes never delete runtimes"
for m in auto-safe dry-run apply; do
    reset_state; analyze_sim_runtimes >/dev/null 2>&1
    MODE="$m"
    clean_sim_runtimes >/dev/null 2>&1
    assert_eq "$(deleted)" "0" "MODE=$m"
done

begin_test "dry-run previews only"
reset_state; analyze_sim_runtimes >/dev/null 2>&1
# shellcheck disable=SC2034  # DRY_RUN is read by is_dry_run; preview inside the assert_* eval strings
DRY_RUN=1
# shellcheck disable=SC2034
preview="$(clean_sim_runtimes 2>&1)"
assert_eq "$(deleted)" "0" "dry-run deletes nothing"
assert_true "printf '%s' \"\$preview\" | grep -q 'simctl runtime delete --unusable'" "dry-run names the command"

begin_test "the plan reports it, apply never runs it"
reset_state; analyze_sim_runtimes >/dev/null 2>&1
plan_reset
build_cleanup_plan_from_analysis >/dev/null 2>&1
found_action=""
for i in "${!PLAN_OP_COMMANDS[@]}"; do
    case "${PLAN_OP_PATHS[$i]}" in *simctl*runtime*) found_action="${PLAN_OP_ACTIONS[$i]}/${PLAN_OP_RISKS[$i]}" ;; esac
done
assert_eq "$found_action" "report_only/REVIEW" "report-only REVIEW op"
assert_false "native_tool_for_command 'xcrun simctl runtime delete --unusable' >/dev/null" "not in the apply allowlist"

print_test_summary
