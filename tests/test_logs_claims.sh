#!/usr/bin/env bash
# =============================================================================
# tests/test_logs_claims.sh — P2: a log already claimed by another category is
# not planned twice.
#
# analyze_app_specific_caches claims ~/Library/Logs/JetBrains as an app cache,
# and analyze_logs then listed the same files again: the plan counted them
# twice and apply tried to remove them twice. Files under DiagnosticReports
# belong to analyze_diagnostic_reports. Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_logs_claims.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
export USER="${USER:-testuser}"
export LOG_LEVEL="ERROR"
export NO_COLOR=1
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$HOME" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/analyzer.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

old_log() { mkdir -p "$(dirname "$1")"; printf 'log\n' > "$1"; touch -t 200001010000 "$1"; }

JB="$HOME/Library/Logs/JetBrains/idea.log"
DIAG="$HOME/Library/Logs/DiagnosticReports/app.log"
PLAIN="$HOME/Library/Logs/SomeApp/some.log"
old_log "$JB"; old_log "$DIAG"; old_log "$PLAIN"

begin_test "analyze_logs skips files claimed by another category"
reset_claimed_paths
claim_path "$HOME/Library/Logs/JetBrains" 4096
FOUND_APP_LOGS=(); FOUND_SYSTEM_LOGS=()
analyze_logs >/dev/null 2>&1
assert_array_var_not_contains_fragment "FOUND_APP_LOGS" "JetBrains" "claimed JetBrains logs are not listed again"
assert_array_var_not_contains_fragment "FOUND_APP_LOGS" "DiagnosticReports" "diagnostic reports belong to their own analyzer"
assert_array_var_contains_exact "FOUND_APP_LOGS" "$PLAIN" "an unclaimed old log is still found"

print_test_summary
