#!/usr/bin/env bash
# =============================================================================
# tests/test_native_cleaner_outcomes.sh — Docker and unavailable-simulator
# cleanup run their native command only in the interactive modes, and the
# report says "cleaned" only after the command succeeded.
#
# clean_docker and clean_xcode_simulators recorded "cleaned" right after
# consent, before the command ran, so a failed prune was reported as done.
# Neither checked the mode itself: only the call site kept them out of
# --auto-safe. docker and xcrun are recording stubs. Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_native_outcomes.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="$SANDBOX"
export LOG_LEVEL="ERROR"
export NO_COLOR=1
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"
setup_artifact_isolation "$SANDBOX"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/pathguard.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/policy.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/interactive.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/cleaner.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/reporter.sh"

trap 'rm -rf "$SANDBOX"' EXIT

STUB_BIN="${SANDBOX}/bin"; CALLS="${SANDBOX}/calls.log"; FAIL_FLAG="${SANDBOX}/fail"
mkdir -p "$STUB_BIN"
for tool in docker xcrun; do
    cat > "${STUB_BIN}/${tool}" <<STUB
#!/bin/sh
echo "${tool} \$*" >> "${CALLS}"
[ -f "${FAIL_FLAG}" ] && exit 1
exit 0
STUB
    chmod +x "${STUB_BIN}/${tool}"
done
export PATH="${STUB_BIN}:${PATH}"
# The real docker and xcrun must never run from this test.
for tool in docker xcrun; do
    [[ "$(command -v "$tool")" == "${STUB_BIN}/${tool}" ]] || { echo "stub for ${tool} is not first on PATH" >&2; exit 1; }
done

# shellcheck disable=SC2034  # globals read by the sourced lib functions
reset_state() {
    : > "$CALLS"; rm -f "$FAIL_FLAG"
    CLEANUP_CATEGORY_OUTCOMES=""
    MODE="interactive"; DRY_RUN=0; EXPLICIT_DRY_RUN=0
    FOUND_DEV_ITEMS=("docker_prune:__docker__" "ios_simulators:${SANDBOX}/Devices")
    catbytes_set "docker" 4096
    catbytes_set "simulators" 4096
}
ran() { grep -c "^$1\$" "$CALLS"; }
confirm_category() { return 0; }

DOCKER_CMD="docker system prune -f"
SIMS_CMD="xcrun simctl delete unavailable"

# ---------------------------------------------------------------------------
for c in "clean_docker|docker|${DOCKER_CMD}" "clean_xcode_simulators|simulators|${SIMS_CMD}"; do
    fn="${c%%|*}"; rest="${c#*|}"; key="${rest%%|*}"; cmd="${rest#*|}"

    begin_test "${fn}: consent and success: cleaned"
    reset_state
    "$fn" >/dev/null 2>&1
    assert_eq "$(ran "$cmd")" "1" "ran once"
    assert_eq "$(category_outcome "$key")" "cleaned" "outcome"

    begin_test "${fn}: the command fails: failed, not cleaned"
    reset_state; touch "$FAIL_FLAG"
    "$fn" >/dev/null 2>&1
    assert_eq "$(ran "$cmd")" "1" "ran once"
    assert_eq "$(category_outcome "$key")" "failed" "outcome"

    begin_test "${fn}: consent but the tool is not installed: unavailable"
    reset_state
    # Never hide a stub by editing PATH: the real tool in /usr/bin would run.
    # shellcheck disable=SC2329  # called by the cleaner under test
    native_tool_available() { return 1; }
    "$fn" >/dev/null 2>&1
    unset -f native_tool_available
    # shellcheck disable=SC1091
    source "${PROJ_DIR}/lib/cleaner.sh"
    assert_eq "$(ran "$cmd")" "0" "nothing run"
    assert_eq "$(category_outcome "$key")" "unavailable" "outcome"

    begin_test "${fn}: declined: skipped, nothing run"
    reset_state
    # shellcheck disable=SC2329  # called by the cleaner under test
    confirm_category() { return 1; }
    "$fn" >/dev/null 2>&1
    confirm_category() { return 0; }
    assert_eq "$(ran "$cmd")" "0" "not run"
    assert_eq "$(category_outcome "$key")" "skipped" "outcome"

    begin_test "${fn}: outside the interactive modes the command never runs"
    for m in auto-safe dry-run plan apply-plan; do
        reset_state; MODE="$m"
        "$fn" >/dev/null 2>&1
        assert_eq "$(ran "$cmd")" "0" "MODE=$m"
        assert_false "[[ \"\$(category_outcome $key)\" == cleaned ]]" "MODE=$m: not reported cleaned"
    done

    begin_test "${fn}: dry-run previews in any mode and claims nothing"
    for m in interactive auto-safe; do
        reset_state; MODE="$m"; DRY_RUN=1
        rm -f "$CLEANUP_JOURNAL_FILE"
        "$fn" >/dev/null 2>&1
        assert_eq "$(ran "$cmd")" "0" "MODE=$m dry-run runs nothing"
        assert_true "grep -q '${cmd}' \"\$CLEANUP_JOURNAL_FILE\"" "MODE=$m: the planned command is journaled"
        assert_eq "$(category_outcome "$key")" "" "MODE=$m: no outcome in a dry-run"
    done
done

# ---------------------------------------------------------------------------
begin_test "the report shows a failed native command as Failed"
reset_state
MODE="interactive"; REMOVE_MODE="quarantine"
# shellcheck disable=SC2034  # read by generate_report
TOTAL_CLEANED_BYTES=0; TOTAL_WOULD_FREE_BYTES=0; TOTAL_QUARANTINED_BYTES=0
# shellcheck disable=SC2034
TOTAL_QUARANTINED_ITEMS=0; TOTAL_SKIPPED_ITEMS=0; TOTAL_USER_DECISIONS_NEEDED=0
# shellcheck disable=SC2034
USER_DECISION_ITEMS=(); WARNINGS_LIST=()
mark_category_outcome "docker" failed
generate_report "interactive" >/dev/null 2>&1
assert_true "grep -F '| $(category_label docker) |' \"\$REPORT_FILE\" | grep -q 'Failed'" "Docker row says Failed"

begin_test "the report shows a missing tool as not processed"
reset_state
mark_category_outcome "docker" unavailable
generate_report "interactive" >/dev/null 2>&1
assert_true "grep -F '| $(category_label docker) |' \"\$REPORT_FILE\" | grep -q 'not installed'" "Docker row names the missing tool"

print_test_summary
