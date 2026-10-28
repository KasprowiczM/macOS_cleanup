#!/usr/bin/env bash
# =============================================================================
# tests/test_user_unset.sh — P1-6: path expansion must not fail open when
# USER is unset (launchd, cron, `env -i`).
#
# Under `set -u` an unset USER made _path_expand_home_and_vars die, so
# normalize_path failed and callers using `normalize_path … || echo raw` fell
# back to the raw, unnormalized path (for example a "~/.npm" policy rule that
# then never matched).
#
# Run directly under stock bash too:  /bin/bash tests/test_user_unset.sh
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_test_user_unset.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
SB_HOME="${SANDBOX}/home"
mkdir -p "$SB_HOME" "${SANDBOX}/logs" "${SANDBOX}/reports" "${SANDBOX}/quarantine"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

EXPECTED_USER="$(id -un)"

# Probe script: runs with USER unset under `set -u`, prints key=value lines.
PROBE="${SANDBOX}/probe.sh"
cat > "$PROBE" <<'EOF'
set -u
source "$PROJ_DIR/config/defaults.sh"
source "$PROJ_DIR/lib/common.sh"
source "$PROJ_DIR/lib/policy.sh"
normalize_never_touch_paths
probe_norm() {
    local out
    out="$(normalize_path "$2" 2>/dev/null)"
    echo "$1=${out}|rc$?"
}
probe_norm home_norm "$HOME/Library/Caches/x"
probe_norm tilde_norm "~/.npm"
probe_norm user_norm '/Users/$USER/Library/Mail'
probe_norm user_brace_norm '/Users/${USER}/x'
policy_reset_rules
policy_add_rule "~/.npm" "ask" "cache" "" 2>/dev/null
echo "rule_path=${POLICY_RULE_PATHS[0]}"
echo "rule_risk=$(policy_explicit_risk_for_path "$HOME/.npm/_cacache" 2>/dev/null)"
if is_protected_path "$HOME/Library/Mail" 2>/dev/null; then echo "mail=protected"; else echo "mail=allowed"; fi
EOF

OUT="$(env -i HOME="$SB_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" \
    PYTHONDONTWRITEBYTECODE=1 PROJ_DIR="$PROJ_DIR" \
    LOGS_DIR="${SANDBOX}/logs" REPORTS_DIR="${SANDBOX}/reports" \
    QUARANTINE_ROOT="${SANDBOX}/quarantine" \
    /bin/bash "$PROBE" 2>"${SANDBOX}/probe.err")"

probe_val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

begin_test "P1-6: normalize_path works with USER unset"
assert_eq "$(probe_val home_norm)" "${SB_HOME}/Library/Caches/x|rc0" "\$HOME path normalizes"
assert_eq "$(probe_val tilde_norm)" "${SB_HOME}/.npm|rc0" "~ path normalizes"

begin_test "P1-6: \$USER tokens fall back to id -un"
assert_eq "$(probe_val user_norm)" "/Users/${EXPECTED_USER}/Library/Mail|rc0" "\$USER expands via id -un"
assert_eq "$(probe_val user_brace_norm)" "/Users/${EXPECTED_USER}/x|rc0" "\${USER} expands via id -un"

begin_test "P1-6: policy rules normalize with USER unset"
assert_eq "$(probe_val rule_path)" "${SB_HOME}/.npm" "~ rule is stored normalized"
assert_eq "$(probe_val rule_risk)" "REVIEW" "~ rule matches its children"

begin_test "P1-6: protection still holds with USER unset"
assert_eq "$(probe_val mail)" "protected" "Mail stays protected"

if [[ "$TESTS_FAIL" -gt 0 ]]; then
    echo "  probe stdout:" >&2; printf '%s\n' "$OUT" | sed 's/^/    /' >&2
    echo "  probe stderr (head):" >&2; head -5 "${SANDBOX}/probe.err" | sed 's/^/    /' >&2
fi

print_test_summary
