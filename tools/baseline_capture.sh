#!/usr/bin/env bash
# =============================================================================
# tools/baseline_capture.sh <outdir>
#
# Builds a fixture home, runs cleanup_all.sh in various modes with redirected
# artifacts into <outdir>, capturing outputs for diffing.
# Bash 3.2 compatible.
# =============================================================================

set -eu

OUTDIR="${1:-}"
if [[ -z "$OUTDIR" ]]; then
    echo "Usage: $0 <outdir>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$OUTDIR"

# Create fixture home in a temporary directory
TMP_HOME="$(mktemp -d -t macos_cleanup_baseline_home.XXXXXX)"
trap 'chmod -R 700 "$TMP_HOME" 2>/dev/null || true; rm -rf "$TMP_HOME"' EXIT

bash "${PROJ_DIR}/tests/fixtures/make_fake_home.sh" "$TMP_HOME" >/dev/null

export HOME="$TMP_HOME"
export LOGS_DIR="${OUTDIR}/logs"
export REPORTS_DIR="${OUTDIR}/reports"
export CLEANUP_JOURNAL_FILE="${OUTDIR}/journal.jsonl"
export CLEANUP_RESTORE_MANIFEST="${OUTDIR}/restore.tsv"
export QUARANTINE_ROOT="${OUTDIR}/quarantine"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# Run targets and capture stdout/stderr
/bin/bash "${PROJ_DIR}/cleanup_all.sh" --version > "${OUTDIR}/version.txt" 2>&1 || true
/bin/bash "${PROJ_DIR}/cleanup_all.sh" --help > "${OUTDIR}/help.txt" 2>&1 || true
/bin/bash "${PROJ_DIR}/cleanup_all.sh" --dry-run --non-interactive --no-color > "${OUTDIR}/dryrun_all.txt" 2>&1 || true
/bin/bash "${PROJ_DIR}/cleanup_all.sh" plan --non-interactive --no-color > "${OUTDIR}/plan_all.txt" 2>&1 || true
/bin/bash "${PROJ_DIR}/cleanup_all.sh" --dry-run --non-interactive --no-color --json > "${OUTDIR}/json_all.txt" 2>&1 || true

for cat in user-caches system-caches app-caches logs downloads dev device-support trash; do
    /bin/bash "${PROJ_DIR}/cleanup_all.sh" --dry-run --non-interactive --no-color --category "$cat" > "${OUTDIR}/dryrun_${cat}.txt" 2>&1 || true
done

echo "Captured baseline outputs into: ${OUTDIR}"
