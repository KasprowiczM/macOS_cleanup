#!/usr/bin/env bash
# =============================================================================
# lib/planner.sh — JSON plan generator & executor
#
# Bash 3.2 compatible.
# =============================================================================

# P1-4: native targets are checked with validate_cache_path.
if ! command -v validate_cache_path >/dev/null 2>&1; then
    _PLANNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    if [[ -f "${_PLANNER_LIB_DIR}/pathguard.sh" ]]; then
        # shellcheck disable=SC1091
        source "${_PLANNER_LIB_DIR}/pathguard.sh"
    fi
fi

# P1-7: temp files removed by remove_plan_temp_files when a run aborts.
PLAN_TMP_OUTPUT=""
APPLY_PLAN_SNAPSHOT=""

# remove_plan_temp_files — called from the EXIT handler.
remove_plan_temp_files() {
    [[ -n "${PLAN_TMP_OUTPUT:-}" ]] && rm -f "$PLAN_TMP_OUTPUT" 2>/dev/null
    [[ -n "${APPLY_PLAN_SNAPSHOT:-}" ]] && rm -f "$APPLY_PLAN_SNAPSHOT" 2>/dev/null
    return 0
}

declare -a PLAN_OP_IDS=()
declare -a PLAN_OP_CATEGORIES=()
declare -a PLAN_OP_RISKS=()
declare -a PLAN_OP_ACTIONS=()
declare -a PLAN_OP_PATHS=()
declare -a PLAN_OP_COMMANDS=()
declare -a PLAN_OP_BYTES=()
declare -a PLAN_OP_DESCS=()
declare -a PLAN_OP_RECS=()
declare -a PLAN_OP_ROLLBACK=()
declare -a PLAN_OP_TOOLS=()

plan_reset() {
    PLAN_OP_IDS=()
    PLAN_OP_CATEGORIES=()
    PLAN_OP_RISKS=()
    PLAN_OP_ACTIONS=()
    PLAN_OP_PATHS=()
    PLAN_OP_COMMANDS=()
    PLAN_OP_BYTES=()
    PLAN_OP_DESCS=()
    PLAN_OP_RECS=()
    PLAN_OP_ROLLBACK=()
    PLAN_OP_TOOLS=()
}

plan_next_id() {
    printf "op-%04d" "$(( ${#PLAN_OP_IDS[@]} + 1 ))"
}

plan_add_operation() {
    local id="$1" category="$2" risk="$3" action="$4" path="$5" command="$6" bytes="$7" description="$8" recommendation="$9"
    local rollback="${10:-}"
    local tool="${11:-}"
    if [[ -z "$rollback" ]]; then
        if [[ "$action" == "remove_path" ]]; then
            rollback="true"
        else
            rollback="false"
        fi
    fi
    PLAN_OP_IDS+=("$id")
    PLAN_OP_CATEGORIES+=("$category")
    PLAN_OP_RISKS+=("$risk")
    PLAN_OP_ACTIONS+=("$action")
    PLAN_OP_PATHS+=("$path")
    PLAN_OP_COMMANDS+=("$command")
    PLAN_OP_BYTES+=("${bytes:-0}")
    PLAN_OP_DESCS+=("$description")
    PLAN_OP_RECS+=("$recommendation")
    PLAN_OP_ROLLBACK+=("$rollback")
    PLAN_OP_TOOLS+=("$tool")
}

plan_add_path() {
    local category="$1" risk="$2" path="$3" description="$4" recommendation="$5"
    local bytes
    bytes="$(path_size_bytes "$path")"
    plan_add_operation "$(plan_next_id)" "$category" "$risk" "remove_path" "$path" "" "$bytes" "$description" "$recommendation" "true" ""
}

plan_add_report_only() {
    local category="$1" risk="$2" path="$3" bytes="$4" description="$5" recommendation="$6"
    plan_add_operation "$(plan_next_id)" "$category" "$risk" "report_only" "$path" "" "$bytes" "$description" "$recommendation" "false" ""
}

plan_add_native() {
    local category="$1" risk="$2" command="$3" bytes="$4" description="$5" recommendation="$6"
    local path="${7:-}"
    local tool="${8:-}"
    plan_add_operation "$(plan_next_id)" "$category" "$risk" "native_command" "$path" "$command" "$bytes" "$description" "$recommendation" "false" "$tool"
}

# P1-4: plan_add_bound_native <category> <default-risk> <command> <bytes> <desc> <rec>
# The op's path is the target its tool resolves now (native_tool_target), the
# same value apply re-resolves and must match. A tool that cannot name its
# target is reported instead of planned.
plan_add_bound_native() {
    local category="$1" default_risk="$2" command="$3" bytes="$4" description="$5" recommendation="$6"
    local tool target
    tool="$(native_tool_for_command "$command")" || return 1
    if ! target="$(native_tool_target "$tool")" || [[ -z "$target" ]]; then
        plan_add_report_only "$category" "REVIEW" "${tool}: target unresolved" "$bytes" "$description" \
            "${tool} did not report the directory it cleans; run it by hand after review."
        return 0
    fi
    if ! native_target_allowed "$tool" "$target"; then
        plan_add_report_only "$category" "REVIEW" "$target" "$bytes" "$description" \
            "${tool} cleans ${target}, which is outside the known cache roots; review it by hand."
        return 0
    fi
    plan_add_native "$category" "$(policy_adjust_risk_for_path "$target" "$default_risk")" "$command" "$bytes" \
        "$description" "$recommendation" "$target" "$tool"
}

# P1-1: plan_op_is_executable <index> — true when this run's mode would act on
# the operation. report_only never runs, DANGEROUS is never applied, and the
# quarantine mode skips non-user remove_path targets (/tmp, /Library/Logs), so
# none of them can free anything.
plan_op_is_executable() {
    local i="$1"
    case "${PLAN_OP_ACTIONS[$i]}" in
        remove_path|native_command) ;;
        *) return 1 ;;
    esac
    [[ "${PLAN_OP_RISKS[$i]}" == "SAFE" || "${PLAN_OP_RISKS[$i]}" == "REVIEW" ]] || return 1
    [[ "${PLAN_OP_ACTIONS[$i]}" == "remove_path" ]] || return 0
    # Mirror safe_remove: an invalid REMOVE_MODE removes nothing (P0-3).
    case "${REMOVE_MODE:-}" in
        permanent)  return 0 ;;
        quarantine) is_user_space_path "${PLAN_OP_PATHS[$i]}" ;;
        *)          return 1 ;;
    esac
}

# P1-1: plan_compute_totals — sets PLAN_SUM_* from the current operations.
# The risk buckets hold remove_path/native_command only; report_only items are
# counted apart, because summing never-executed bytes into review/dangerous
# inflated the plan by 22% (13.24 GB) on the 2026-10-27 measurement.
plan_compute_totals() {
    local i r b count
    count=${#PLAN_OP_IDS[@]}
    PLAN_SUM_SAFE_OPS=0; PLAN_SUM_REVIEW_OPS=0; PLAN_SUM_DANGEROUS_OPS=0
    PLAN_SUM_SAFE_BYTES=0; PLAN_SUM_REVIEW_BYTES=0; PLAN_SUM_DANGEROUS_BYTES=0
    PLAN_SUM_REPORT_ONLY_OPS=0; PLAN_SUM_REPORT_ONLY_BYTES=0
    PLAN_SUM_EXECUTABLE_BYTES=0
    for (( i=0; i<count; i++ )); do
        r="${PLAN_OP_RISKS[$i]}"
        b="${PLAN_OP_BYTES[$i]:-0}"
        case "$b" in ''|*[!0-9]*) b=0 ;; esac
        if [[ "${PLAN_OP_ACTIONS[$i]}" == "report_only" ]]; then
            PLAN_SUM_REPORT_ONLY_OPS=$(( PLAN_SUM_REPORT_ONLY_OPS + 1 ))
            PLAN_SUM_REPORT_ONLY_BYTES=$(( PLAN_SUM_REPORT_ONLY_BYTES + b ))
            continue
        fi
        case "$r" in
            SAFE)      PLAN_SUM_SAFE_OPS=$(( PLAN_SUM_SAFE_OPS + 1 ));           PLAN_SUM_SAFE_BYTES=$(( PLAN_SUM_SAFE_BYTES + b )) ;;
            REVIEW)    PLAN_SUM_REVIEW_OPS=$(( PLAN_SUM_REVIEW_OPS + 1 ));       PLAN_SUM_REVIEW_BYTES=$(( PLAN_SUM_REVIEW_BYTES + b )) ;;
            DANGEROUS) PLAN_SUM_DANGEROUS_OPS=$(( PLAN_SUM_DANGEROUS_OPS + 1 )); PLAN_SUM_DANGEROUS_BYTES=$(( PLAN_SUM_DANGEROUS_BYTES + b )) ;;
        esac
        if plan_op_is_executable "$i"; then
            PLAN_SUM_EXECUTABLE_BYTES=$(( PLAN_SUM_EXECUTABLE_BYTES + b ))
        fi
    done
}

# P1-1: plan_record_headline_totals — the headline figure is the plan's
# executable sum, and report-only bytes are informational. The old headline
# summed category ledgers, which counted Homebrew twice and included work the
# current mode never performs.
plan_record_headline_totals() {
    plan_compute_totals
    # shellcheck disable=SC2034  # read by reporter.sh and json_summary.sh
    TOTAL_WOULD_FREE_BYTES=$PLAN_SUM_EXECUTABLE_BYTES
    # shellcheck disable=SC2034
    TOTAL_INFORMATIONAL_BYTES=0
    add_informational_bytes "$PLAN_SUM_REPORT_ONLY_BYTES"
}

build_cleanup_plan_from_analysis() {
    local item path label key brew_b
    plan_reset

    if (( ${#FOUND_TRASH_ITEMS[@]} > 0 )); then
        for path in "${FOUND_TRASH_ITEMS[@]}"; do
            plan_add_path "trash" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Item in macOS Trash." \
                "Remove only if deliberately deleted and rollback is not needed."
        done
    fi

    if (( ${#FOUND_USER_CACHES[@]} > 0 )); then
        for path in "${FOUND_USER_CACHES[@]}"; do
            plan_add_path "user-caches" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Top-level cache in ~/Library/Caches; mixed risk category." \
                "Review app name before removing."
        done
    fi

    if (( ${#FOUND_APP_CACHE_ITEMS[@]} > 0 )); then
        for item in "${FOUND_APP_CACHE_ITEMS[@]}"; do
            label="${item%%:*}"
            path="${item#*:}"
            if app_cache_auto_safe "$label"; then
                plan_add_path "app-caches" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                    "${label}: recreateable app cache." \
                    "App will recreate cache on launch."
            else
                plan_add_path "app-caches" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                    "${label}: app cache outside auto-safe allowlist." \
                    "Review manually before removal."
            fi
        done
    fi

    if (( ${#FOUND_APP_LOGS[@]} > 0 )); then
        for path in "${FOUND_APP_LOGS[@]}"; do
            plan_add_path "logs" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old log file or diagnostic report." \
                "Safe unless actively troubleshooting."
        done
    fi
    if (( ${#FOUND_SYSTEM_LOGS[@]} > 0 )); then
        for path in "${FOUND_SYSTEM_LOGS[@]}"; do
            plan_add_path "logs" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old log file or diagnostic report." \
                "Safe unless actively troubleshooting."
        done
    fi
    if (( ${#FOUND_DIAGNOSTIC_REPORTS[@]} > 0 )); then
        for path in "${FOUND_DIAGNOSTIC_REPORTS[@]}"; do
            plan_add_path "logs" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old log file or diagnostic report." \
                "Safe unless actively troubleshooting."
        done
    fi

    if (( ${#FOUND_TMP_FILES[@]} > 0 )); then
        for path in "${FOUND_TMP_FILES[@]}"; do
            plan_add_path "system" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old temporary file." \
                "Safe to remove; macOS and apps treat /tmp as transient."
        done
    fi

    if (( ${#FOUND_SYSTEM_CACHES[@]} > 0 )); then
        for path in "${FOUND_SYSTEM_CACHES[@]}"; do
            plan_add_report_only "system" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes "$path")" \
                "System cache /Library/Caches." \
                "Not executed from plan; use interactive mode after review."
        done
    fi

    if (( ${#FOUND_APP_LEFTOVERS[@]} > 0 )); then
        for path in "${FOUND_APP_LEFTOVERS[@]}"; do
            plan_add_report_only "app-leftovers" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes "$path")" \
                "Heuristic app leftover." \
                "Remove manually after confirming app is uninstalled."
        done
    fi

    if (( ${#FOUND_DEV_ITEMS[@]} > 0 )); then
        for item in "${FOUND_DEV_ITEMS[@]}"; do
            key="${item%%:*}"
            path="${item#*:}"
            case "$key" in
                xcode_derived_data)
                    plan_add_path "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                        "Xcode DerivedData: recreateable build artifacts." \
                        "Xcode will rebuild projects on next compilation."
                    ;;
                xcode_archives)
                    plan_add_report_only "dev" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes "$path")" \
                        "Xcode Archives may be required for app distribution or symbolication." \
                        "Review in Xcode Organizer before deletion."
                    ;;
                ios_simulators)
                    plan_add_bound_native "dev" "REVIEW" "xcrun simctl delete unavailable" "$(catbytes_get "simulators")" \
                        "Deletes only unavailable simulators." \
                        "Execute after review; runtimes can be re-downloaded."
                    ;;
                npx_cache|pnpm_stale_store)
                    plan_add_path "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                        "Recreateable package manager cache." \
                        "The tool will re-download packages as needed."
                    ;;
                npm_cache)
                    plan_add_bound_native "dev" "SAFE" "npm cache clean --force" "$(catbytes_get "npm")" \
                        "npm cache." "Packages will be re-downloaded if needed." ;;
                yarn_cache)
                    plan_add_bound_native "dev" "SAFE" "yarn cache clean" "$(catbytes_get "yarn")" \
                        "Yarn cache." "Packages will be re-downloaded if needed." ;;
                pnpm_cache)
                    plan_add_bound_native "dev" "SAFE" "pnpm store prune" "$(catbytes_get "pnpm")" \
                        "pnpm store." "pnpm prunes unused store items." ;;
                pip_cache)
                    plan_add_bound_native "dev" "SAFE" "pip cache purge" "$(catbytes_get "pip")" \
                        "pip cache." "Packages will be re-downloaded if needed." ;;
                brew_cache|brew_cleanup)
                    # P1-1: one brew cleanup covers the cache and the stale
                    # versions, which overlap; count the larger estimate once.
                    brew_b="$(catbytes_get "brew")"
                    if (( $(catbytes_get "brew-stale") > brew_b )); then
                        brew_b="$(catbytes_get "brew-stale")"
                    fi
                    # P1-4: --prune=all also removes old formula versions (REVIEW).
                    plan_add_bound_native "dev" "REVIEW" "brew cleanup --prune=all" "$brew_b" \
                        "Homebrew cache & old formulae versions." "Homebrew rebuilds cache on demand." ;;
                gem_cache)
                    # P1-4: gem cleanup uninstalls old gem versions (REVIEW).
                    plan_add_bound_native "dev" "REVIEW" "gem cleanup" "$(catbytes_get "gem")" \
                        "Ruby gems cache / old versions." "Gems can be reinstalled." ;;
                gradle_cache|cocoapods_cache|cargo_cache|swift_pm_cache|bundler_cache|composer_cache)
                    plan_add_path "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                        "Recreateable dev tool cache." \
                        "Builds will re-download dependencies."
                    ;;
                maven_cache)
                    plan_add_report_only "dev" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes "$path")" \
                        "Maven repository may contain locally built artifacts." \
                        "Do not delete automatically; review manually."
                    ;;
                android_avd)
                    plan_add_report_only "dev" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes "$path")" \
                        "Android AVD may contain emulator local state." \
                        "Remove via Android Studio Device Manager after review."
                    ;;
                docker_prune)
                    # P1-4: Docker storage lives in its VM, so there is no host
                    # target to bind; a plan reports it and the interactive
                    # mode runs it with its own confirmation.
                    plan_add_report_only "dev" "REVIEW" "docker: reclaimable (docker system df)" "$(catbytes_get "docker")" \
                        "Docker: images, stopped containers, networks, and build cache." \
                        "Run 'docker system prune' yourself, or use --interactive, if stopped container data is no longer required."
                    ;;
            esac
        done
    fi

    if (( ${#FOUND_DEVICE_SUPPORT_ITEMS[@]} > 0 )); then
        for item in "${FOUND_DEVICE_SUPPORT_ITEMS[@]}"; do
            path="${item#*:}"
            plan_add_path "dev" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Xcode Device Support older than ${DEVICE_SUPPORT_MIN_AGE_DAYS} days." \
                "Xcode re-downloads debug symbols upon connecting matching devices."
        done
    fi

    if (( ${#FOUND_TM_SNAPSHOTS[@]} > 0 )); then
        for item in "${FOUND_TM_SNAPSHOTS[@]}"; do
            plan_add_report_only "time-machine" "REVIEW" "$item" 0 \
                "Local Time Machine snapshot." \
                "macOS reclaims snapshots automatically; manual deletion requires fresh backup."
        done
    fi

    if (( ${#FOUND_IOS_BACKUPS[@]} > 0 )); then
        for path in "${FOUND_IOS_BACKUPS[@]}"; do
            plan_add_path "time-machine" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Local iOS/iPadOS backup." \
                "Remove only after confirming external or iCloud backup."
        done
    fi

    if (( ${#FOUND_DMG_PKG[@]} > 0 )); then
        for path in "${FOUND_DMG_PKG[@]}"; do
            plan_add_path "large-files" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Old DMG/PKG/ISO installer in Downloads." \
                "Remove only if re-downloadable or no longer needed."
        done
    fi

    if (( ${#FOUND_MAIL_ITEMS[@]} > 0 )); then
        for item in "${FOUND_MAIL_ITEMS[@]}"; do
            key="${item%%:*}"
            path="${item#*:}"
            plan_add_report_only "mail" "DANGEROUS" "$path" "$(path_size_bytes "$path")" \
                "Apple Mail: ${key}. Mail data is critical user content." \
                "Manage attachments via Mail.app or Finder."
        done
    fi

    if (( ${#FOUND_BROWSER_CACHE_ITEMS[@]} > 0 )); then
        for item in "${FOUND_BROWSER_CACHE_ITEMS[@]}"; do
            label="${item%%:*}"
            path="${item#*:}"
            plan_add_report_only "browsers" "REVIEW" "$path" "$(path_size_bytes "$path")" \
                "${label}: browser cache." \
                "Prefer clearing cache via browser UI."
        done
    fi

    if (( ${#FOUND_BROWSER_DATA_ITEMS[@]} > 0 )); then
        for item in "${FOUND_BROWSER_DATA_ITEMS[@]}"; do
            label="${item%%:*}"
            path="${item#*:}"
            plan_add_report_only "browsers" "DANGEROUS" "$path" "$(path_size_bytes "$path")" \
                "${label}: profile, cookies, passwords, history, or sessions." \
                "Never delete automatically; use browser privacy settings."
        done
    fi
}

generate_plan_json() {
    local output="${1:-$PLAN_FILE_DEFAULT}"
    local i count safe_count review_count dangerous_count safe_bytes review_bytes dangerous_bytes
    local report_only_count report_only_bytes executable_bytes
    count=${#PLAN_OP_IDS[@]}
    plan_compute_totals
    safe_count=$PLAN_SUM_SAFE_OPS; review_count=$PLAN_SUM_REVIEW_OPS; dangerous_count=$PLAN_SUM_DANGEROUS_OPS
    safe_bytes=$PLAN_SUM_SAFE_BYTES; review_bytes=$PLAN_SUM_REVIEW_BYTES; dangerous_bytes=$PLAN_SUM_DANGEROUS_BYTES
    report_only_count=$PLAN_SUM_REPORT_ONLY_OPS; report_only_bytes=$PLAN_SUM_REPORT_ONLY_BYTES
    executable_bytes=$PLAN_SUM_EXECUTABLE_BYTES

    local checksum_val
    checksum_val="pending"

    local dir tmp_output
    dir="$(dirname "$output")"
    mkdir -p "$dir" 2>/dev/null || true
    # P1-7: write and stamp a temp file next to the destination, then rename it
    # into place, so a failed stamp or an interrupted run never leaves a
    # half-written plan where apply --from-plan will read it.
    tmp_output="${output}.tmp.$$"
    if [[ -d "$output" ]]; then
        print_error "Plan file is a directory: ${output}"
        return 1
    fi
    # Bare (no `|| handler`) so set -e still aborts on a failed write; the
    # EXIT handler removes the temp file in that case.
    PLAN_TMP_OUTPUT="$tmp_output"

    {
        printf '{\n'
        printf '  "schema_version": "1.0",\n'
        printf '  "version": "1.0",\n'
        printf '  "tool": "%s",\n' "$(json_escape "${SCRIPT_NAME:-cleanup_all.sh}")"
        printf '  "tool_version": "%s",\n' "$(json_escape "${SCRIPT_VERSION:-unknown}")"
        printf '  "run_id": "%s",\n' "$(json_escape "${RUN_TIMESTAMP:-test_run}")"
        printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "checksum": "%s",\n' "$checksum_val"
        printf '  "summary": {\n'
        printf '    "operations": %d,\n' "$count"
        printf '    "total_operations": %d,\n' "$count"
        printf '    "safe_operations": %d,\n' "$safe_count"
        printf '    "review_operations": %d,\n' "$review_count"
        printf '    "dangerous_operations": %d,\n' "$dangerous_count"
        printf '    "safe_bytes": %s,\n' "$safe_bytes"
        printf '    "review_bytes": %s,\n' "$review_bytes"
        printf '    "dangerous_bytes": %s,\n' "$dangerous_bytes"
        printf '    "report_only_operations": %d,\n' "$report_only_count"
        printf '    "report_only_bytes": %s,\n' "$report_only_bytes"
        printf '    "executable_bytes": %s\n' "$executable_bytes"
        printf '  },\n'
        printf '  "operations": [\n'

        for (( i=0; i<count; i++ )); do
            local sep=","
            (( i == count - 1 )) && sep=""

            local json_path json_cmd json_desc json_rec json_tool json_rollback
            json_path="$(json_escape "${PLAN_OP_PATHS[$i]}")"
            json_cmd="$(json_escape "${PLAN_OP_COMMANDS[$i]}")"
            json_desc="$(json_escape "${PLAN_OP_DESCS[$i]}")"
            json_rec="$(json_escape "${PLAN_OP_RECS[$i]}")"
            json_tool="$(json_escape "${PLAN_OP_TOOLS[$i]:-}")"
            json_rollback="${PLAN_OP_ROLLBACK[$i]:-false}"
            case "$json_rollback" in
                true|false) ;;
                *) json_rollback="false" ;;
            esac

            printf '    {\n'
            printf '      "id": "%s",\n' "${PLAN_OP_IDS[$i]}"
            printf '      "category": "%s",\n' "${PLAN_OP_CATEGORIES[$i]}"
            printf '      "risk": "%s",\n' "${PLAN_OP_RISKS[$i]}"
            printf '      "action": "%s",\n' "${PLAN_OP_ACTIONS[$i]}"
            printf '      "path": "%s",\n' "$json_path"
            printf '      "command": "%s",\n' "$json_cmd"
            printf '      "estimated_bytes": %s,\n' "${PLAN_OP_BYTES[$i]:-0}"
            printf '      "size": %s,\n' "${PLAN_OP_BYTES[$i]:-0}"
            printf '      "description": "%s",\n' "$json_desc"
            printf '      "recommendation": "%s",\n' "$json_rec"
            printf '      "rollback": %s,\n' "$json_rollback"
            printf '      "tool": "%s"\n' "$json_tool"
            printf '    }%s\n' "$sep"
        done
        printf '  ]\n'
        printf '}\n'
    } > "$tmp_output"

    if ! python3 - "$tmp_output" <<'PLANCKSUM'
import hashlib
import json
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    raw = f.read()
data = json.loads(raw)
ops = data.get("operations", [])
chk = hashlib.sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
new, n = re.subn(r'"checksum":\s*"[^"]*"', '"checksum": "%s"' % chk, raw, count=1)
if n != 1:
    sys.exit(1)
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
PLANCKSUM
    then
        rm -f "$tmp_output"
        PLAN_TMP_OUTPUT=""
        print_error "Failed to stamp plan checksum: ${output}"
        return 1
    fi
    if ! mv -f "$tmp_output" "$output"; then
        rm -f "$tmp_output"
        print_error "Failed to write plan: ${output}"
        return 1
    fi
    PLAN_TMP_OUTPUT=""

    cleanup_journal_event "plan_generated" "$output" "" 0 "ok" "operations=${count}" "plan"
    TOTAL_USER_DECISIONS_NEEDED=$(( TOTAL_USER_DECISIONS_NEEDED + review_count + dangerous_count + report_only_count ))
    if (( review_count > 0 )); then
        USER_DECISION_ITEMS+=("Plan JSON: ${review_count} REVIEW operations require conscious decision")
    fi
    if (( dangerous_count > 0 )); then
        USER_DECISION_ITEMS+=("Plan JSON: ${dangerous_count} DANGEROUS operations will never execute automatically")
    fi
    if (( report_only_count > 0 )); then
        USER_DECISION_ITEMS+=("Plan JSON: ${report_only_count} report-only items are sized for manual review and never executed")
    fi
    if type json_summary_record_plan >/dev/null 2>&1; then
        json_summary_record_plan "$count" "$safe_count" "$review_count" "$dangerous_count" "$safe_bytes" "$review_bytes" "$dangerous_bytes" \
            "$report_only_count" "$report_only_bytes" "$executable_bytes"
    fi
    print_ok "Plan JSON saved: ${output}"
}

execute_plan_native_command() {
    local command="$1"
    local bytes="${2:-0}"
    local path="${3:-}"
    local before=0
    local after=0

    if [[ -n "$path" && -e "$path" ]]; then
        before="$(path_size_bytes "$path")"
    fi

    local _cmd_rc=0 tool bin target want
    if ! tool="$(native_tool_for_command "$command")"; then
        print_warn "Plan native command not in allowlist: ${command}"
        cleanup_journal_event "plan_apply_blocked" "$command" "" "$bytes" "blocked" "native command not allowlisted" "plan"
        return 1
    fi
    bin="$tool"
    if [[ "$tool" == "pip" ]]; then
        bin="$(native_pip_bin)" || bin=""
    fi
    if [[ -z "$bin" ]] || ! command -v "$bin" >/dev/null 2>&1; then
        [[ "$tool" == "pip" ]] && tool="pip/pip3"
        record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: ${tool}"
        print_skip "${tool} unavailable — skipping: ${command}"
        return 0
    fi

    # P1-4: the op is bound to its tool's target, re-resolved now. A plan that
    # names another directory, or a config that moved the cache since the
    # plan was written, is refused instead of cleaning something else.
    target="$(native_tool_target "$tool")" || target=""
    want="$(normalize_path "$path" 2>/dev/null)" || want=""
    if [[ -z "$target" || "$target" != "$want" ]]; then
        print_warn "Plan command target mismatch: ${command} (plan: ${path:-none}, ${tool}: ${target:-unresolved})"
        cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "native target mismatch: ${target:-unresolved}" "plan"
        return 1
    fi
    if ! native_target_allowed "$tool" "$target"; then
        print_warn "Plan command target outside the cache roots: ${command} (${target})"
        cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "native target outside cache roots" "plan"
        return 1
    fi

    # P1-4: a dry-run previews only what a real apply would run.
    if is_dry_run; then
        print_dry "Would run: ${command}"
        record_native_command_event "$command" "planned" "$bytes" "plan dry-run"
        return 0
    fi

    case "$command" in
        "npm cache clean --force")         npm cache clean --force || _cmd_rc=$? ;;
        "yarn cache clean")                yarn cache clean || _cmd_rc=$? ;;
        "pnpm store prune")                pnpm store prune || _cmd_rc=$? ;;
        "pip cache purge")                 "$bin" cache purge || _cmd_rc=$? ;;
        "brew cleanup --prune=all")        brew cleanup --prune=all || _cmd_rc=$? ;;
        "gem cleanup")                     gem cleanup || _cmd_rc=$? ;;
        "xcrun simctl delete unavailable") xcrun simctl delete unavailable || _cmd_rc=$? ;;
    esac

    if (( _cmd_rc == 0 )); then
        if [[ -n "$path" && -e "$path" ]]; then
            after="$(path_size_bytes "$path")"
        else
            after=0
        fi
        print_cleaned "Executed plan command: ${command}"
        record_native_command_freed "$command" "$before" "$after" "plan apply"
    else
        print_warn "Plan command failed: ${command}"
        record_native_command_event "$command" "failed" "$bytes" "plan apply failed"
    fi
    return "$_cmd_rc"
}

plan_require_review_confirmation() {
    local path="$1"
    local id="$2"

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        print_skip "Plan REVIEW requires interaction: ${id}"
        return 1
    fi

    if [[ "${REQUIRE_TYPING_PATH:-0}" == "1" && -n "$path" ]]; then
        local typed
        echo
        echo "  REVIEW: to execute ${id}, type exact path:"
        echo "  ${path}"
        echo -n "  > "
        read -r typed
        [[ "$typed" == "$path" ]] || return 1
        return 0
    fi

    ask_yes_no "Execute plan REVIEW operation: ${id}?" "no"
}

verify_plan_file_checksum() {
    local plan_file="$1"
    python3 -c '
import hashlib, json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
chk = data.get("checksum", "")
if not chk:
    sys.exit(1)
ops = data.get("operations", [])
expected = hashlib.sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
if chk != expected:
    sys.exit(1)
' "$plan_file" 2>/dev/null
}

_plan_path_blocked_or_escalated() {
    local path="$1"
    local risk="$2"
    local explicit_risk current_rank plan_rank
    explicit_risk="$(policy_explicit_risk_for_path "$path" 2>/dev/null || true)"
    if [[ -n "$explicit_risk" ]]; then
        current_rank="$(policy_risk_rank "$explicit_risk")"
        plan_rank="$(policy_risk_rank "$risk")"
    else
        current_rank=0
        plan_rank=0
    fi
    if (( current_rank > plan_rank )) || is_protected_path "$path"; then
        return 0
    fi
    return 1
}

apply_plan_file() {
    local plan_file="$1"
    [[ -f "$plan_file" ]] || { print_error "Plan file not found: ${plan_file}"; return 2; }
    command -v python3 >/dev/null 2>&1 || { print_error "apply --from-plan requires python3 for safe JSON parsing."; return 2; }

    # P1-7: verify and parse one private snapshot, so the plan cannot change
    # between the checksum check and the parse.
    local plan_snapshot
    plan_snapshot="$(mktemp -t macos_cleanup_plan_snapshot.XXXXXX)" || { print_error "Cannot snapshot plan: ${plan_file}"; return 2; }
    if ! cp "$plan_file" "$plan_snapshot" 2>/dev/null; then
        rm -f "$plan_snapshot"
        print_error "Cannot snapshot plan: ${plan_file}"
        return 2
    fi
    # Called bare so set -e keeps aborting inside the apply loop; on such an
    # abort the EXIT handler removes the snapshot.
    APPLY_PLAN_SNAPSHOT="$plan_snapshot"
    local _apply_rc=0
    _apply_plan_snapshot "$plan_file" "$plan_snapshot"
    _apply_rc=$?
    rm -f "$plan_snapshot"
    APPLY_PLAN_SNAPSHOT=""
    return "$_apply_rc"
}

# _apply_plan_snapshot <plan-file-for-messages> <snapshot> — body of apply_plan_file.
_apply_plan_snapshot() {
    local plan_file="$1" plan_snapshot="$2"

    if ! verify_plan_file_checksum "$plan_snapshot"; then
        print_error "Plan checksum verification failed: ${plan_file}"
        cleanup_journal_event "plan_apply_blocked" "$plan_file" "" 0 "blocked" "checksum mismatch" "plan"
        return 2
    fi

    local parsed_ops apply_failed
    parsed_ops="$(mktemp -t macos_cleanup_plan_parsed.XXXXXX)"
    apply_failed=0
    if ! python3 - "$plan_snapshot" > "$parsed_ops" <<'PLANPARSE'
import base64
import json
import sys

ALLOWLIST = {
    "npm cache clean --force",
    "yarn cache clean",
    "pnpm store prune",
    "pip cache purge",
    "brew cleanup --prune=all",
    "gem cleanup",
    "xcrun simctl delete unavailable",
}
ACTIONS = {"remove_path", "native_command", "report_only"}
RISKS = {"SAFE", "REVIEW", "DANGEROUS"}

def b64(value):
    if value is None:
        value = ""
    return base64.b64encode(str(value).encode("utf-8")).decode("ascii")

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

ops = data.get("operations")
if not isinstance(ops, list):
    sys.exit(1)

for op in ops:
    if not isinstance(op, dict):
        sys.exit(1)
    op_id = op.get("id")
    action = op.get("action")
    risk = op.get("risk")
    estimated = op.get("estimated_bytes")
    if not isinstance(op_id, str) or not op_id:
        sys.exit(1)
    if action not in ACTIONS:
        sys.exit(1)
    if risk not in RISKS:
        sys.exit(1)
    if isinstance(estimated, bool) or not isinstance(estimated, int) or estimated < 0:
        sys.exit(1)
    if action == "native_command":
        command = op.get("command")
        path = op.get("path")
        if not isinstance(command, str) or command not in ALLOWLIST:
            sys.exit(1)
        if not isinstance(path, str) or not path.strip():
            sys.exit(1)

for op in ops:
    print("\x1f".join([
        b64(op.get("id", "")),
        str(op.get("risk", "")),
        str(op.get("action", "")),
        b64(op.get("path", "")),
        b64(op.get("command", "")),
        str(op.get("estimated_bytes")),
        b64(op.get("category", "")),
    ]))
PLANPARSE
    then
        rm -f "$parsed_ops"
        print_error "Plan document validation failed: ${plan_file}"
        cleanup_journal_event "plan_apply_blocked" "$plan_file" "" 0 "blocked" "parser error" "plan"
        return 1
    fi

    local id_b64 risk action path_b64 command_b64 bytes category_b64
    local id path command category
    local explicit_risk owner_key

    while IFS=$'\x1f' read -u3 -r id_b64 risk action path_b64 command_b64 bytes category_b64; do
        id="$(base64_decode_string "$id_b64")"
        path="$(base64_decode_string "$path_b64")"
        command="$(base64_decode_string "$command_b64")"
        category="$(base64_decode_string "$category_b64")"
        case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac

        case "$risk" in
            DANGEROUS)
                print_skip "Plan ${id}: DANGEROUS operations are never executed."
                cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "dangerous blocked" "$category"
                continue
                ;;
            REVIEW)
                if [[ "${INCLUDE_REVIEW:-0}" != "1" ]]; then
                    print_skip "Plan ${id}: REVIEW skipped (add --include-review after conscious review)."
                    cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "review not included" "$category"
                    continue
                fi
                plan_require_review_confirmation "$path" "$id" || {
                    cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "review confirmation failed" "$category"
                    continue
                }
                ;;
            SAFE)
                :
                ;;
            *)
                print_skip "Plan ${id}: unknown risk '${risk}', skipping."
                continue
                ;;
        esac

        case "$action" in
            remove_path)
                if [[ -n "$path" ]]; then
                    path="$(normalize_path "$path" || echo "$path")"
                    explicit_risk="$(policy_explicit_risk_for_path "$path" 2>/dev/null || true)"
                    if _plan_path_blocked_or_escalated "$path" "$risk"; then
                        print_warn "Plan ${id}: risk escalated (${risk}->${explicit_risk:-protected}) or path protected — skipping."
                        cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "risk escalated since plan: ${risk}->${explicit_risk:-protected}" "$category"
                        continue
                    fi
                    # Phase 3: same in-use check as the interactive cleaners.
                    owner_key="$(cache_owner_key_for_path "$path")" || owner_key=""
                    if [[ -n "$owner_key" ]] && cache_owner_running "$owner_key"; then
                        print_skip "Plan ${id}: in use by a running tool (${owner_key}) — skipping."
                        cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "in use: ${owner_key}" "$category"
                        continue
                    fi
                    if ! safe_remove "$path"; then
                        apply_failed=1
                    fi
                fi
                ;;
            native_command)
                path="$(normalize_path "$path" || echo "$path")"
                explicit_risk="$(policy_explicit_risk_for_path "$path" 2>/dev/null || true)"
                if _plan_path_blocked_or_escalated "$path" "$risk"; then
                    print_warn "Plan ${id}: native target blocked (${risk}->${explicit_risk:-protected}) or path protected — skipping."
                    cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "native target protected or risk escalated: ${risk}->${explicit_risk:-protected}" "$category"
                    continue
                fi
                if ! execute_plan_native_command "$command" "$bytes" "$path"; then
                    apply_failed=1
                fi
                ;;
            report_only)
                print_skip "Plan ${id}: report_only does not apply changes."
                ;;
            *)
                print_skip "Plan ${id}: unknown action '${action}'."
                cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "unknown action" "$category"
                ;;
        esac
    done 3< "$parsed_ops"
    rm -f "$parsed_ops"

    if (( apply_failed != 0 )); then
        return 1
    fi
    return 0
}
