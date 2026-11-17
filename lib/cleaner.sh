#!/usr/bin/env bash
# =============================================================================
# lib/cleaner.sh — entry point kept for the engine's source list
#
# 4.0 (R07, F06): the per-category clean_* functions, run_cleanup and the
# auto-safe phase are gone. Every mutating mode builds the plan
# (lib/planner.sh) and runs it through the single executor (lib/executor.sh),
# which also holds the helpers the cleaners used to own (native_tool_available,
# tm_*, the docker/simctl/tmutil command wrappers, category_max_risk).
#
# Bash 3.2 compatible.
# =============================================================================

# Policy functions rate the paths a consent prompt shows.
if ! command -v policy_adjust_risk_for_path >/dev/null 2>&1; then
    _CLEANER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    if [[ -f "${_CLEANER_LIB_DIR}/policy.sh" ]]; then
        # shellcheck disable=SC1091
        source "${_CLEANER_LIB_DIR}/policy.sh"
    fi
fi

if ! type execute_ops >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/executor.sh"
fi
