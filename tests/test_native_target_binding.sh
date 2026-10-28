#!/usr/bin/env bash
# =============================================================================
# tests/test_native_target_binding.sh — P1-4/P1-5: native commands are bound
# to the directory they act on, resolved the same way at plan and apply time.
#
# The 2026-10-27 review accepted `npm cache clean --force` with
# ~/Library/Messages as its "path", resolved __brew__/__docker__ against the
# cwd, rejected a whole plan for one simctl/docker op, never re-resolved a
# target whose config changed after planning, and read Docker's SIZE column
# instead of RECLAIMABLE for the two-word "Build Cache" row.
# Bash 3.2 compatible. Every tool is a PATH stub; nothing real runs.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_native_binding.XXXXXX)"
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
export QUARANTINE_RUN_DIR="${SANDBOX}/quarantine/test_run"
mkdir -p "$HOME/Library/Messages" "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT" "$QUARANTINE_RUN_DIR"

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
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

STUB_BIN="${SANDBOX}/bin"
RECORDER="${SANDBOX}/calls.log"
mkdir -p "$STUB_BIN"
export PATH="${STUB_BIN}:${PATH}"

NPM_CACHE="$HOME/.npm"
BREW_CACHE="$HOME/Library/Caches/Homebrew"
mkdir -p "$NPM_CACHE/_cacache" "$BREW_CACHE"
printf 'x' > "$NPM_CACHE/_cacache/blob"

# stub_tool <name> <answer-to-resolver-query>: records every call; prints the
# resolver answer for the target query, succeeds for anything else.
stub_tool() {
    local name="$1" answer="$2"
    cat > "${STUB_BIN}/${name}" <<STUB
#!/bin/sh
echo "${name} \$*" >> "${RECORDER}"
case "\$*" in
    "config get cache"|"cache dir"|"store path"|"--cache"|"env gemdir") printf '%s\n' "${answer}" ;;
esac
exit 0
STUB
    chmod +x "${STUB_BIN}/${name}"
}

write_plan() {
    local dest="$1" ops_json="$2" checksum
    checksum="$(python3 -c 'import hashlib, json, sys
ops = json.loads(sys.argv[1])
print(hashlib.sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()).hexdigest())' "$ops_json")"
    printf '{"schema_version":"1.0","tool":"cleanup_all.sh","run_id":"t","checksum":"%s","summary":{},"operations":%s}\n' \
        "$checksum" "$ops_json" > "$dest"
}

native_op() {  # native_op <id> <risk> <command> <path>
    printf '{"id":"%s","category":"dev","risk":"%s","action":"native_command","path":"%s","command":"%s","estimated_bytes":1,"size":1,"description":"d","recommendation":"r","rollback":false}' \
        "$1" "$2" "$4" "$3"
}

reset_apply() {
    DRY_RUN=0; REMOVE_MODE=quarantine; NON_INTERACTIVE=1; AUTO_YES=0
    INCLUDE_REVIEW=0; REQUIRE_TYPING_PATH=0
    rm -f "$RECORDER" "$CLEANUP_JOURNAL_FILE"
}

PLAN="${SANDBOX}/plan.json"

# ---------------------------------------------------------------------------
begin_test "native_tool_target resolves each tool's own target"
stub_tool npm "$NPM_CACHE"
stub_tool brew "$BREW_CACHE"
assert_eq "$(native_tool_target npm)" "$(normalize_path "$NPM_CACHE")" "npm → npm config get cache"
assert_eq "$(native_tool_target brew)" "$(normalize_path "$BREW_CACHE")" "brew → brew --cache"
assert_eq "$(native_tool_target xcrun)" "$(normalize_path "$HOME/Library/Developer/CoreSimulator/Devices")" "simctl → CoreSimulator/Devices"
assert_eq "$(native_tool_for_command "npm cache clean --force")" "npm" "command → tool"
assert_false "native_tool_for_command 'rm -rf /'" "unknown command has no tool"

# ---------------------------------------------------------------------------
begin_test "apply refuses a native command whose path is not its target"
reset_apply
stub_tool npm "$NPM_CACHE"
write_plan "$PLAN" "[$(native_op op-1 SAFE "npm cache clean --force" "$HOME/Library/Messages")]"
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_false "grep -q 'npm cache clean' '$RECORDER'" "npm never runs against ~/Library/Messages"

reset_apply
OTHER="$HOME/Library/Caches/com.example.other"   # unprotected: only the binding can stop it
mkdir -p "$OTHER"
write_plan "$PLAN" "[$(native_op op-1 SAFE "npm cache clean --force" "$OTHER")]"
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_false "grep -q 'npm cache clean' '$RECORDER'" "npm never runs against an unrelated directory"
assert_true "grep -q 'native target mismatch' '$CLEANUP_JOURNAL_FILE'" "journal names the mismatch"

begin_test "apply refuses when the tool's target changed after the plan"
reset_apply
write_plan "$PLAN" "[$(native_op op-1 SAFE "npm cache clean --force" "$NPM_CACHE")]"
stub_tool npm "$HOME/elsewhere"
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_false "grep -q 'npm cache clean' '$RECORDER'" "npm does not run on a re-resolved mismatch"

begin_test "apply runs the command when the path is its target"
reset_apply
stub_tool npm "$NPM_CACHE"
write_plan "$PLAN" "[$(native_op op-1 SAFE "npm cache clean --force" "$NPM_CACHE")]"
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_true "grep -q 'npm cache clean --force' '$RECORDER'" "bound npm op runs"

# ---------------------------------------------------------------------------
begin_test "a redirected cache outside the known cache roots is never cleaned"
reset_apply
BROAD="$HOME/Dev_Env/project"          # unprotected, but not a cache root
mkdir -p "$BROAD"
stub_tool npm "$BROAD"                 # e.g. NPM_CONFIG_CACHE=~/Dev_Env/project
plan_reset
FOUND_DEV_ITEMS=("npm_cache:$BROAD")
build_cleanup_plan_from_analysis >/dev/null 2>&1
assert_eq "${PLAN_OP_ACTIONS[0]:-}" "report_only" "plan: redirected npm cache is report-only"
write_plan "$PLAN" "[$(native_op op-1 SAFE "npm cache clean --force" "$BROAD")]"
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_false "grep -q 'npm cache clean' '$RECORDER'" "apply: npm never cleans a non-cache directory"
FOUND_DEV_ITEMS=()

begin_test "resolver output that is relative or empty does not bind"
stub_tool npm "relative/cache"
assert_false "native_tool_target npm" "relative resolver output is rejected"
stub_tool npm ""
assert_false "native_tool_target npm" "empty resolver output is rejected"

begin_test "dry-run previews the refusal instead of 'Would run'"
reset_apply
DRY_RUN=1
stub_tool npm "$NPM_CACHE"
write_plan "$PLAN" "[$(native_op op-1 SAFE "npm cache clean --force" "$OTHER")]"
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_true "grep -q 'native target mismatch' '$CLEANUP_JOURNAL_FILE'" "dry-run journals the refusal"
assert_false "grep -q '\"planned\"' '$CLEANUP_JOURNAL_FILE'" "dry-run does not record it as planned"
DRY_RUN=0

# ---------------------------------------------------------------------------
begin_test "a simctl op no longer rejects the whole plan"
reset_apply
stub_tool npm "$NPM_CACHE"
SIMS="$HOME/Library/Developer/CoreSimulator/Devices"
write_plan "$PLAN" "[$(native_op op-1 REVIEW "xcrun simctl delete unavailable" "$SIMS"),$(native_op op-2 SAFE "npm cache clean --force" "$NPM_CACHE")]"
apply_plan_file "$PLAN" >/dev/null 2>&1
assert_true "grep -q 'npm cache clean --force' '$RECORDER'" "SAFE npm op still applied next to a simctl op"

# ---------------------------------------------------------------------------
begin_test "planner: real targets, docker report-only, gem/brew REVIEW"
plan_reset
stub_tool brew "$BREW_CACHE"
stub_tool gem "$HOME/.gem/ruby"
mkdir -p "$HOME/.gem/ruby"
FOUND_USER_CACHES=(); FOUND_APP_CACHE_ITEMS=(); FOUND_APP_LOGS=(); FOUND_SYSTEM_LOGS=()
FOUND_DIAGNOSTIC_REPORTS=(); FOUND_TMP_FILES=(); FOUND_SYSTEM_CACHES=(); FOUND_APP_LEFTOVERS=()
FOUND_DEVICE_SUPPORT_ITEMS=(); FOUND_TM_SNAPSHOTS=(); FOUND_IOS_BACKUPS=(); FOUND_DMG_PKG=()
FOUND_TRASH_ITEMS=(); FOUND_MAIL_ITEMS=(); FOUND_BROWSER_CACHE_ITEMS=(); FOUND_BROWSER_DATA_ITEMS=()
FOUND_DEV_ITEMS=("brew_cleanup:__brew__" "docker_prune:__docker__" "gem_cache:$HOME/.gem/cache")
catbytes_set "brew-stale" 5000; catbytes_set "docker" 7000; catbytes_set "gem" 300
build_cleanup_plan_from_analysis >/dev/null 2>&1
generate_plan_json "$PLAN" >/dev/null 2>&1
py() { python3 -c "import json,sys; ops=json.load(open(sys.argv[1]))['operations']; $1" "$PLAN" 2>/dev/null; }
assert_eq "$(py "print([o['path'] for o in ops if o['command'].startswith('brew')][0])")" "$(normalize_path "$BREW_CACHE")" "brew sentinel resolved to brew --cache"
assert_eq "$(py "print([o['risk'] for o in ops if o['command'].startswith('brew')][0])")" "REVIEW" "brew --prune=all is REVIEW"
assert_eq "$(py "print([o['risk'] for o in ops if o['command'].startswith('gem')][0])")" "REVIEW" "gem cleanup is REVIEW"
assert_eq "$(py "print([o['path'] for o in ops if o['command'].startswith('gem')][0])")" "$(normalize_path "$HOME/.gem/ruby")" "gem op bound to gem env gemdir"
assert_eq "$(py "print([o['action'] for o in ops if o['category']=='dev' and 'docker' in (o['path']+o['command']+o['description']).lower()][0])")" "report_only" "docker prune is report-only in a plan"
assert_eq "$(py "print(sum(1 for o in ops if '__' in o['path']))")" "0" "no sentinel path reaches the plan"

# ---------------------------------------------------------------------------
begin_test "CN2: Docker reclaimable comes from --format, not the SIZE column"
simctl_unavailable_udids() { return 1; }
docker() {
    case "$*" in
        "info") return 0 ;;
        "system df --format {{.Type}}|{{.Reclaimable}}")
            printf '%s\n' 'Images|10MB (50%)' 'Containers|4MB (100%)' 'Local Volumes|90MB (100%)' 'Build Cache|8MB' ;;
        "system df")
            cat <<'DOCKERDF'
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          2         0         20MB      10MB (50%)
Containers      1         0         4MB       4MB (100%)
Local Volumes   3         0         90MB      90MB (100%)
Build Cache     1         0         20MB      8MB
DOCKERDF
            ;;
        *) return 1 ;;
    esac
}
FOUND_DEV_ITEMS=()
catbytes_set "docker" 0
analyze_dev_environment >/dev/null 2>&1
unset -f docker
assert_eq "$(catbytes_get docker)" "$(( (10 + 4 + 8) * 1000 * 1000 ))" "Build Cache uses RECLAIMABLE (8MB), decimal units, volumes excluded"

print_test_summary
