#!/usr/bin/env bash
# =============================================================================
# tools/baseline_diff.sh <dir_a> <dir_b>
#
# Normalizes away run_id, timestamps, absolute sandbox paths, and PIDs,
# then diffs two capture directories. Exit 0 on equivalence.
# Bash 3.2 compatible.
# =============================================================================

set -eu

DIR_A="${1:-}"
DIR_B="${2:-}"

if [[ -z "$DIR_A" || -z "$DIR_B" ]]; then
    echo "Usage: $0 <dir_a> <dir_b>" >&2
    exit 1
fi

NORM_A="$(mktemp -d -t macos_cleanup_norm_a.XXXXXX)"
NORM_B="$(mktemp -d -t macos_cleanup_norm_b.XXXXXX)"
trap 'rm -rf "$NORM_A" "$NORM_B"' EXIT

normalize_file() {
    local src="$1" dest="$2"
    sed -E \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}/<TIMESTAMP>/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}/<ISO_TIMESTAMP>/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?/<ISO_TIMESTAMP>/g' \
        -e 's/_pid[0-9]+/_pid<PID>/g' \
        -e 's/_[0-9]{4,6}\.(log|md|json|jsonl)/_<PID>.\1/g' \
        -e 's/_[0-9]{4,6}"/_<PID>"/' \
        -e 's/_[0-9]{4,6}$/_<PID>/' \
        -e 's/"run_id": "<TIMESTAMP>_[0-9]+"/"run_id": "<TIMESTAMP>_<PID>"/g' \
        -e 's/quarantine\/<TIMESTAMP>_[0-9]+/quarantine\/<TIMESTAMP>_<PID>/g' \
        -e 's/\/private\/var\/folders\/[^\/]+\/[^\/]+\/T\/[^\/]+/<TMP_PATH>/g' \
        -e 's/\/var\/folders\/[^\/]+\/[^\/]+\/T\/[^\/]+/<TMP_PATH>/g' \
        -e 's/\/tmp\/[^\/]+/<TMP_PATH>/g' \
        -e 's/baseline\/[^\/]+\/(logs|reports|quarantine)/<OUTPUT_DIR>\/\1/g' \
        -e 's/<TMP_PATH>\/(logs|reports|quarantine)/<OUTPUT_DIR>\/\1/g' \
        -e 's/baseline\/(pre|post)/baseline\/<DIR>/g' \
        -e 's/version [0-9]+\.[0-9]+\.[0-9]+/version <VERSION>/g' \
        -e 's/"tool_version": "[0-9]+\.[0-9]+\.[0-9]+"/"tool_version": "<VERSION>"/g' \
        -e 's/Wersja:[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+/Wersja:   <VERSION>/g' \
        -e 's/Wolne:[[:space:]]+[0-9.]+[[:space:]]+[KMGT]?B/Wolne:     <FREE_SPACE>/g' \
        -e 's/Użyte:[[:space:]]+[0-9]+Gi[[:space:]]+\|[[:space:]]+Wolne:[[:space:]]+[0-9]+Gi[[:space:]]+\([0-9]+%\)/Użyte: <USED> | Wolne: <FREE>/g' \
        -e 's/.*com\.apple\.TimeMachine.*/    • com.apple.TimeMachine.<SNAPSHOT>.local/g' \
        -e '/"informational_bytes": 0,/d' \
        "$src" > "$dest"
}

for f in "$DIR_A"/*.txt; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    normalize_file "$f" "${NORM_A}/${base}"
    if [[ -f "${DIR_B}/${base}" ]]; then
        normalize_file "${DIR_B}/${base}" "${NORM_B}/${base}"
    else
        echo "Missing in ${DIR_B}: ${base}" >&2
    fi
done

diff -u -r "$NORM_A" "$NORM_B"
echo "Baseline diff check: EQUIVALENT"
