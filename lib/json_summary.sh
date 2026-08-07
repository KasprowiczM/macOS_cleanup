#!/usr/bin/env bash
# =============================================================================
# lib/json_summary.sh — Machine-readable run summary for --json flag
# Bash 3.2 compatible.
#
# Writes a single JSON object to stdout (fd 1) describing the completed run.
# When --json is active, cleanup_all.sh redirects human-readable output to
# stderr (fd 2) early via "exec 3>&1 1>&2", so that only JSON reaches fd 1.
# =============================================================================

# Emit the full run summary as JSON to fd 1 (which, when --json is set,
# has been remapped by cleanup_all.sh to the original stdout/pipe).
emit_json_summary() {
    local mode="${1:-unknown}"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    # Plan summary counters (set by generate_plan_json if plan was built).
    local plan_ops="${_JSON_PLAN_OPERATIONS:-0}"
    local plan_safe="${_JSON_PLAN_SAFE:-0}"
    local plan_review="${_JSON_PLAN_REVIEW:-0}"
    local plan_dangerous="${_JSON_PLAN_DANGEROUS:-0}"
    local plan_safe_bytes="${_JSON_PLAN_SAFE_BYTES:-0}"
    local plan_review_bytes="${_JSON_PLAN_REVIEW_BYTES:-0}"
    local plan_dangerous_bytes="${_JSON_PLAN_DANGEROUS_BYTES:-0}"

    # Build the JSON with printf to avoid subshell quoting issues.
    {
        printf '{\n'
        printf '  "schema_version": "1.0",\n'
        printf '  "tool": "%s",\n'         "$(json_escape "$SCRIPT_NAME")"
        printf '  "tool_version": "%s",\n' "$(json_escape "$SCRIPT_VERSION")"
        printf '  "run_id": "%s",\n'       "$(json_escape "$RUN_TIMESTAMP")"
        printf '  "generated_at": "%s",\n' "$(json_escape "$ts")"
        printf '  "mode": "%s",\n'         "$(json_escape "$mode")"
        printf '  "remove_mode": "%s",\n'  "$(json_escape "${REMOVE_MODE:-quarantine}")"
        printf '  "dry_run": %s,\n'        "$([ "${DRY_RUN:-1}" = "1" ] && echo true || echo false)"
        # Build a proper JSON array of quoted category strings.
        local _cats_json=""
        local _first_cat=1
        if [ "${ACTIVE_CATEGORIES+set}" = "set" ]; then
            for _cat in "${ACTIVE_CATEGORIES[@]}"; do
                if (( _first_cat )); then
                    _cats_json="\"$(json_escape "$_cat")\""
                    _first_cat=0
                else
                    _cats_json="${_cats_json}, \"$(json_escape "$_cat")\""
                fi
            done
        fi
        printf '  "categories": [%s],\n' "$_cats_json"
        printf '  "counters": {\n'
        printf '    "would_free_bytes": %s,\n'      "${TOTAL_WOULD_FREE_BYTES:-0}"
        printf '    "cleaned_bytes": %s,\n'         "${TOTAL_CLEANED_BYTES:-0}"
        printf '    "quarantined_bytes": %s,\n'     "${TOTAL_QUARANTINED_BYTES:-0}"
        printf '    "quarantined_items": %s,\n'     "${TOTAL_QUARANTINED_ITEMS:-0}"
        printf '    "restored_bytes": %s,\n'        "${TOTAL_RESTORED_BYTES:-0}"
        printf '    "restored_items": %s,\n'        "${TOTAL_RESTORED_ITEMS:-0}"
        printf '    "skipped_items": %s,\n'         "${TOTAL_SKIPPED_ITEMS:-0}"
        printf '    "user_decisions_needed": %s\n'  "${TOTAL_USER_DECISIONS_NEEDED:-0}"
        printf '  },\n'
        printf '  "plan": {\n'
        printf '    "operations": %s,\n'       "$plan_ops"
        printf '    "safe_operations": %s,\n'  "$plan_safe"
        printf '    "review_operations": %s,\n' "$plan_review"
        printf '    "dangerous_operations": %s,\n' "$plan_dangerous"
        printf '    "safe_bytes": %s,\n'       "$plan_safe_bytes"
        printf '    "review_bytes": %s,\n'     "$plan_review_bytes"
        printf '    "dangerous_bytes": %s\n'   "$plan_dangerous_bytes"
        printf '  },\n'
        printf '  "artifacts": {\n'
        printf '    "report": "%s",\n'   "$(json_escape "${REPORT_FILE:-}")"
        printf '    "plan": "%s",\n'     "$(json_escape "${PLAN_FILE:-}")"
        printf '    "journal": "%s",\n'  "$(json_escape "${CLEANUP_JOURNAL_FILE:-}")"
        printf '    "restore_manifest": "%s"\n' "$(json_escape "${CLEANUP_RESTORE_MANIFEST:-}")"
        printf '  },\n'
        # Count warnings and decisions — guard against unset arrays (bash 3.2 set -u safe).
        local _warn_count=0
        if [ "${WARNINGS_LIST+set}" = "set" ]; then
            _warn_count=${#WARNINGS_LIST[@]}
        fi
        printf '  "warnings": %s,\n' "$_warn_count"
        printf '  "user_decisions": ['
        local _dec_count=0
        if [ "${USER_DECISION_ITEMS+set}" = "set" ]; then
            _dec_count=${#USER_DECISION_ITEMS[@]}
        fi
        local i=0
        if (( _dec_count > 0 )); then
            for item in "${USER_DECISION_ITEMS[@]}"; do
                i=$(( i + 1 ))
                if (( i < _dec_count )); then
                    printf '"%s", ' "$(json_escape "$item")"
                else
                    printf '"%s"' "$(json_escape "$item")"
                fi
            done
        fi
        printf ']\n'
        printf '}\n'
    }
}

# Called by generate_plan_json to cache plan summary counters for JSON output.
# This avoids re-parsing the plan file at emit time.
json_summary_record_plan() {
    _JSON_PLAN_OPERATIONS="${1:-0}"
    _JSON_PLAN_SAFE="${2:-0}"
    _JSON_PLAN_REVIEW="${3:-0}"
    _JSON_PLAN_DANGEROUS="${4:-0}"
    _JSON_PLAN_SAFE_BYTES="${5:-0}"
    _JSON_PLAN_REVIEW_BYTES="${6:-0}"
    _JSON_PLAN_DANGEROUS_BYTES="${7:-0}"
}

# Initialize plan counters to zero (called at source time).
_JSON_PLAN_OPERATIONS=0
_JSON_PLAN_SAFE=0
_JSON_PLAN_REVIEW=0
_JSON_PLAN_DANGEROUS=0
_JSON_PLAN_SAFE_BYTES=0
_JSON_PLAN_REVIEW_BYTES=0
_JSON_PLAN_DANGEROUS_BYTES=0
