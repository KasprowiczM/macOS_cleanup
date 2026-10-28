#!/usr/bin/env bash
# =============================================================================
# tests/test_dryrun_authoritative.sh — P0-1 regression lock
#
# An explicit --dry-run is a hard no-delete request. It MUST win over every
# mutating mode regardless of flag order: before the fix, mutating flags parsed
# after --dry-run reset DRY_RUN=0 (`--dry-run --purge-quarantine all --apply`
# permanently deleted; `--dry-run apply --from-plan` reported dry_run:false).
#
# For each mutating mode (apply / interactive / auto-safe / restore /
# prune-artifacts / purge --apply) and BOTH flag orders, the sandbox fixture
# must stay byte-identical. The low-level mutators must also refuse to act while
# DRY_RUN=1 (defense in depth).
#
# Run directly under stock bash too:  /bin/bash tests/test_dryrun_authoritative.sh
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_PATH="${PROJ_DIR}/cleanup_all.sh"

# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

SANDBOX="$(mktemp -d -t macos_cleanup_test_dryrun_auth.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

CASE_N=0
CASE=""

# Fresh, fully isolated tree per case so one variant cannot mask another.
new_case() {
    CASE_N=$(( CASE_N + 1 ))
    CASE="${SANDBOX}/case${CASE_N}"
    mkdir -p "${CASE}/home/Library/Caches" "${CASE}/logs" "${CASE}/reports" "${CASE}/quarantine"
}

# Run the CLI fully sandboxed under the interpreter running this test.
# Usage: run_cli <stdout_file> <args...>; echoes the exit code.
# PYTHONDONTWRITEBYTECODE: Apple's /usr/bin/python3 otherwise caches .pyc files
# under $HOME/Library/Caches/com.apple.python, which would change the fixture.
run_cli() {
    local out="$1"; shift
    local rc=0
    env HOME="${CASE}/home" USER="${USER:-tester}" LOG_LEVEL="INFO" NO_COLOR=1 \
        LOGS_DIR="${CASE}/logs" REPORTS_DIR="${CASE}/reports" \
        CLEANUP_JOURNAL_FILE="${CASE}/reports/journal_test.jsonl" \
        CLEANUP_RESTORE_MANIFEST="${CASE}/reports/restore_test.tsv" \
        QUARANTINE_ROOT="${CASE}/quarantine" \
        QUARANTINE_RUN_DIR="${CASE}/quarantine/current_run" \
        ARTIFACT_RETENTION_DAYS=1 PYTHONDONTWRITEBYTECODE=1 \
        "$BASH" "$SCRIPT_PATH" "$@" >"$out" 2>"${out}.err" </dev/null || rc=$?
    echo "$rc"
}

# Structure + content hash of the given paths (missing paths hash as absent).
fingerprint() {
    local p
    for p in "$@"; do
        if [[ -e "$p" ]]; then
            ( cd "$p" 2>/dev/null && { find . -print | LC_ALL=C sort; find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort; } ) \
                || shasum -a 256 "$p"
        else
            echo "ABSENT ${p}"
        fi
    done | shasum -a 256 | cut -d' ' -f1
}

make_blob() {
    mkdir -p "$(dirname "$1")"
    printf 'payload-%s\n' "$1" > "$1"
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

write_safe_plan() {
    local dest="$1" target="$2" ops checksum
    ops="[{\"id\": \"op-p01\", \"category\": \"app-caches\", \"risk\": \"SAFE\", \"action\": \"remove_path\", \"path\": \"${target}\", \"command\": \"\", \"estimated_bytes\": 0, \"size\": 0, \"description\": \"p01 fixture\", \"recommendation\": \"remove\"}]"
    checksum="$(python3 -c 'import hashlib, json, sys
ops = json.loads(sys.argv[1])
print(hashlib.sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()).hexdigest())' "$ops")"
    cat > "$dest" <<EOF
{
  "schema_version": "1.0",
  "tool": "cleanup_all.sh",
  "tool_version": "2.0.0",
  "run_id": "p01_run",
  "generated_at": "2026-06-10T10:00:00Z",
  "checksum": "${checksum}",
  "summary": {"operations": 1, "safe_operations": 1,
               "review_operations": 0, "dangerous_operations": 0,
               "safe_bytes": 0, "review_bytes": 0, "dangerous_bytes": 0},
  "operations": ${ops}
}
EOF
}

# ---------------------------------------------------------------------------
# apply --from-plan
# ---------------------------------------------------------------------------
apply_case() {
    local order="$1" target plan before rc
    new_case
    target="${CASE}/home/Library/Caches/com.spotify.client"
    make_blob "${target}/blob.bin"
    plan="${CASE}/plan.json"
    write_safe_plan "$plan" "$target"
    before="$(fingerprint "${CASE}/home")"
    if [[ "$order" == "first" ]]; then
        rc="$(run_cli "${CASE}/out" --dry-run apply --from-plan "$plan" --non-interactive --yes --permanent --json)"
    else
        rc="$(run_cli "${CASE}/out" apply --from-plan "$plan" --non-interactive --yes --permanent --json --dry-run)"
    fi
    assert_eq "$(fingerprint "${CASE}/home")" "$before" "apply (--dry-run ${order}) must leave fixture byte-identical"
    assert_true "grep -q '\"dry_run\": true' '${CASE}/out'" "apply (--dry-run ${order}) must report dry_run:true"
    assert_neq "$rc" "99" "apply (--dry-run ${order}) must not hit the exit-99 safety abort"
}

begin_test "P0-1: positive control — apply without --dry-run removes the plan target"
new_case
CTRL_TARGET="${CASE}/home/Library/Caches/com.spotify.client"
make_blob "${CTRL_TARGET}/blob.bin"
write_safe_plan "${CASE}/plan.json" "$CTRL_TARGET"
run_cli "${CASE}/out" apply --from-plan "${CASE}/plan.json" --non-interactive --yes --permanent >/dev/null
assert_file_absent "$CTRL_TARGET" "control: the fixture plan must be applicable (else the dry-run cases prove nothing)"

begin_test "P0-1: --dry-run before apply is authoritative"
apply_case first
begin_test "P0-1: --dry-run after apply is authoritative"
apply_case last

# ---------------------------------------------------------------------------
# --interactive / --auto-safe
# ---------------------------------------------------------------------------
cleaning_mode_case() {
    local mode="$1" order="$2" before rc
    new_case
    make_blob "${CASE}/home/Library/Caches/com.example.p01/blob.bin"
    before="$(fingerprint "${CASE}/home")"
    if [[ "$order" == "first" ]]; then
        rc="$(run_cli "${CASE}/out" --dry-run "$mode" --category user-caches --non-interactive --yes --quarantine --json)"
    else
        rc="$(run_cli "${CASE}/out" "$mode" --category user-caches --non-interactive --yes --quarantine --json --dry-run)"
    fi
    assert_eq "$(fingerprint "${CASE}/home")" "$before" "${mode} (--dry-run ${order}) must leave fixture byte-identical"
    assert_true "grep -q '\"dry_run\": true' '${CASE}/out'" "${mode} (--dry-run ${order}) must report dry_run:true"
    assert_neq "$rc" "99" "${mode} (--dry-run ${order}) must not hit the exit-99 safety abort"
}

begin_test "P0-1: --dry-run wins over --interactive (both orders)"
cleaning_mode_case --interactive first
cleaning_mode_case --interactive last

begin_test "P0-1: --dry-run wins over --auto-safe (both orders)"
cleaning_mode_case --auto-safe first
cleaning_mode_case --auto-safe last

# ---------------------------------------------------------------------------
# --restore (no preview form exists → refused with exit 2)
# ---------------------------------------------------------------------------
restore_case() {
    local order="$1" payload target manifest before rc
    new_case
    payload="${CASE}/quarantine/oldrun/items/restore.payload"
    target="${CASE}/home/Library/Caches/com.example.p01/restored.txt"
    make_blob "$payload"
    manifest="${CASE}/reports/restore_oldrun.tsv"
    printf '%s\t%s\t%s\n' "$(b64 "$payload")" "$(b64 "$target")" "20" > "$manifest"
    before="$(fingerprint "${CASE}/home" "${CASE}/quarantine/oldrun")"
    if [[ "$order" == "first" ]]; then
        rc="$(run_cli "${CASE}/out" --dry-run --restore "$manifest" --category trash --non-interactive)"
    else
        rc="$(run_cli "${CASE}/out" --restore "$manifest" --category trash --non-interactive --dry-run)"
    fi
    assert_eq "$(fingerprint "${CASE}/home" "${CASE}/quarantine/oldrun")" "$before" "restore (--dry-run ${order}) must leave fixture byte-identical"
    assert_eq "$rc" "2" "restore (--dry-run ${order}) must be refused with exit 2"
}

begin_test "P0-1: --dry-run refuses --restore (both orders)"
restore_case first
restore_case last

# ---------------------------------------------------------------------------
# --prune-artifacts (no preview form exists → refused with exit 2)
# ---------------------------------------------------------------------------
prune_case() {
    local order="$1" old_log rc
    new_case
    old_log="${CASE}/logs/cleanup_2020-01-01_000000_1.log"
    echo "KEEP-LOG" > "$old_log"
    touch -t 202001010000 "$old_log"
    if [[ "$order" == "first" ]]; then
        rc="$(run_cli "${CASE}/out" --dry-run --prune-artifacts --category trash --non-interactive)"
    else
        rc="$(run_cli "${CASE}/out" --prune-artifacts --category trash --non-interactive --dry-run)"
    fi
    assert_file_exists "$old_log" "prune-artifacts (--dry-run ${order}) must not delete aged logs"
    assert_eq "$rc" "2" "prune-artifacts (--dry-run ${order}) must be refused with exit 2"
}

begin_test "P0-1: --dry-run refuses --prune-artifacts (both orders)"
prune_case first
prune_case last

# ---------------------------------------------------------------------------
# --purge-quarantine --apply (downgraded to the preview form)
# ---------------------------------------------------------------------------
purge_case() {
    local order="$1" before rc
    new_case
    make_blob "${CASE}/quarantine/oldrun/items/purge.payload"
    before="$(fingerprint "${CASE}/quarantine/oldrun")"
    case "$order" in
        first) rc="$(run_cli "${CASE}/out" --dry-run --purge-quarantine all --apply --category trash --non-interactive)" ;;
        middle) rc="$(run_cli "${CASE}/out" --purge-quarantine oldrun --dry-run --apply --category trash --non-interactive)" ;;
        last) rc="$(run_cli "${CASE}/out" --purge-quarantine oldrun --apply --category trash --non-interactive --dry-run)" ;;
    esac
    assert_eq "$(fingerprint "${CASE}/quarantine/oldrun")" "$before" "purge --apply (--dry-run ${order}) must leave quarantine byte-identical"
    assert_neq "$rc" "99" "purge (--dry-run ${order}) must not hit the exit-99 safety abort"
}

begin_test "P0-1: --dry-run downgrades --purge-quarantine --apply to a preview (all orders)"
purge_case first
purge_case middle
purge_case last

# ---------------------------------------------------------------------------
# Defense in depth: low-level mutators refuse while DRY_RUN=1
# ---------------------------------------------------------------------------
# Usage: run_lib <snippet> [args...]; sources the libs in a sandboxed child.
run_lib() {
    local snippet="$1"; shift
    env HOME="${CASE}/home" USER="${USER:-tester}" LOG_LEVEL="INFO" NO_COLOR=1 \
        LOGS_DIR="${CASE}/logs" REPORTS_DIR="${CASE}/reports" \
        CLEANUP_JOURNAL_FILE="${CASE}/reports/journal_test.jsonl" \
        CLEANUP_RESTORE_MANIFEST="${CASE}/reports/restore_test.tsv" \
        QUARANTINE_ROOT="${CASE}/quarantine" \
        QUARANTINE_RUN_DIR="${CASE}/quarantine/current_run" \
        PROJ_DIR="$PROJ_DIR" \
        "$BASH" -c 'set -u
source "${PROJ_DIR}/config/defaults.sh"
source "${PROJ_DIR}/lib/common.sh"
DRY_RUN=1
'"$snippet" _ "$@" >/dev/null 2>&1
}

begin_test "P0-1: direct_remove refuses while DRY_RUN=1"
new_case
make_blob "${CASE}/home/Library/Caches/com.example.p01/blob.bin"
run_lib 'direct_remove "$1" 10 0 deleted' "${CASE}/home/Library/Caches/com.spotify.client"
assert_file_exists "${CASE}/home/Library/Caches/com.example.p01/blob.bin" "direct_remove must not delete in dry-run"

begin_test "P0-1: rotate_old_artifacts refuses while DRY_RUN=1"
new_case
echo "KEEP-LOG" > "${CASE}/logs/cleanup_2020-01-01_000000_1.log"
touch -t 202001010000 "${CASE}/logs/cleanup_2020-01-01_000000_1.log"
run_lib 'rotate_old_artifacts 1'
assert_file_exists "${CASE}/logs/cleanup_2020-01-01_000000_1.log" "rotate_old_artifacts must not prune in dry-run"

begin_test "P0-1: restore_quarantine_manifest refuses while DRY_RUN=1"
new_case
make_blob "${CASE}/quarantine/oldrun/items/restore.payload"
printf '%s\t%s\t%s\n' "$(b64 "${CASE}/quarantine/oldrun/items/restore.payload")" \
    "$(b64 "${CASE}/home/Library/Caches/com.example.p01/restored.txt")" "20" > "${CASE}/reports/restore_oldrun.tsv"
run_lib 'restore_quarantine_manifest "$1"' "${CASE}/reports/restore_oldrun.tsv"
assert_file_exists "${CASE}/quarantine/oldrun/items/restore.payload" "restore must not move payload in dry-run"
assert_file_absent "${CASE}/home/Library/Caches/com.example.p01/restored.txt" "restore must not create target in dry-run"

begin_test "P0-1: purge_one_quarantine_run refuses apply while DRY_RUN=1"
new_case
make_blob "${CASE}/quarantine/oldrun/items/purge.payload"
run_lib 'purge_one_quarantine_run "$1" 1' "${CASE}/quarantine/oldrun"
assert_file_exists "${CASE}/quarantine/oldrun/items/purge.payload" "purge must not delete in dry-run"

print_test_summary
