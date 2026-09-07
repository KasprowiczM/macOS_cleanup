#!/usr/bin/env bash
# =============================================================================
# lib/planner.sh — JSON plan generator & executor
#
# Bash 3.2 compatible.
# =============================================================================

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
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "xcrun simctl delete unavailable" "$(catbytes_get "simulators")" \
                        "Deletes only unavailable simulators." \
                        "Execute after review; runtimes can be re-downloaded." "$path" "xcrun"
                    ;;
                npx_cache|pnpm_stale_store)
                    plan_add_path "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                        "Recreateable package manager cache." \
                        "The tool will re-download packages as needed."
                    ;;
                npm_cache)
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "npm cache clean --force" "$(catbytes_get "npm")" \
                        "npm cache." "Packages will be re-downloaded if needed." "$path" "npm" ;;
                yarn_cache)
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "yarn cache clean" "$(catbytes_get "yarn")" \
                        "Yarn cache." "Packages will be re-downloaded if needed." "$path" "yarn" ;;
                pnpm_cache)
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "pnpm store prune" "$(catbytes_get "pnpm")" \
                        "pnpm store." "pnpm prunes unused store items." "$path" "pnpm" ;;
                pip_cache)
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "pip cache purge" "$(catbytes_get "pip")" \
                        "pip cache." "Packages will be re-downloaded if needed." "$path" "pip" ;;
                brew_cache|brew_cleanup)
                    brew_b="$(catbytes_get "brew")"
                    if [[ "$brew_b" == "0" || -z "$brew_b" ]]; then
                        brew_b="$(catbytes_get "brew-stale")"
                    fi
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "brew cleanup --prune=all" "$brew_b" \
                        "Homebrew cache & old formulae versions." "Homebrew rebuilds cache on demand." "$path" "brew" ;;
                gem_cache)
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "SAFE")" "gem cleanup" "$(catbytes_get "gem")" \
                        "Ruby gems cache / old versions." "Gems can be reinstalled." "$path" "gem" ;;
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
                    plan_add_native "dev" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "docker system prune -f" "$(catbytes_get "docker")" \
                        "Docker: images, stopped containers, networks, and build cache." \
                        "Execute only if stopped container data is no longer required." "$path" "docker"
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
    count=${#PLAN_OP_IDS[@]}
    safe_count=0; review_count=0; dangerous_count=0
    safe_bytes=0; review_bytes=0; dangerous_bytes=0

    for (( i=0; i<count; i++ )); do
        local r="${PLAN_OP_RISKS[$i]}"
        local b="${PLAN_OP_BYTES[$i]:-0}"
        case "$r" in
            SAFE)      safe_count=$(( safe_count + 1 ));           safe_bytes=$(( safe_bytes + b )) ;;
            REVIEW)    review_count=$(( review_count + 1 ));       review_bytes=$(( review_bytes + b )) ;;
            DANGEROUS) dangerous_count=$(( dangerous_count + 1 )); dangerous_bytes=$(( dangerous_bytes + b )) ;;
        esac
    done

    local checksum_val
    checksum_val="pending"

    local dir
    dir="$(dirname "$output")"
    mkdir -p "$dir" 2>/dev/null || true

    {
        printf '{\n'
        printf '  "schema_version": "1.0",\n'
        printf '  "version": "1.0",\n'
        printf '  "tool": "%s",\n' "$(json_escape "${SCRIPT_NAME:-cleanup_all.sh}")"
        printf '  "tool_version": "%s",\n' "$(json_escape "${SCRIPT_VERSION:-3.0.0}")"
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
        printf '    "dangerous_bytes": %s\n' "$dangerous_bytes"
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
    } > "$output"

    if ! python3 - "$output" <<'PLANCKSUM'
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
        print_error "Failed to stamp plan checksum: ${output}"
        return 1
    fi

    cleanup_journal_event "plan_generated" "$output" "" 0 "ok" "operations=${count}" "plan"
    TOTAL_USER_DECISIONS_NEEDED=$(( TOTAL_USER_DECISIONS_NEEDED + review_count + dangerous_count ))
    if (( review_count > 0 )); then
        USER_DECISION_ITEMS+=("Plan JSON: ${review_count} REVIEW operations require conscious decision")
    fi
    if (( dangerous_count > 0 )); then
        USER_DECISION_ITEMS+=("Plan JSON: ${dangerous_count} DANGEROUS operations will never execute automatically")
    fi
    if type json_summary_record_plan >/dev/null 2>&1; then
        json_summary_record_plan "$count" "$safe_count" "$review_count" "$dangerous_count" "$safe_bytes" "$review_bytes" "$dangerous_bytes"
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

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        print_dry "Would run: ${command}"
        record_native_command_event "$command" "planned" "$bytes" "plan dry-run"
        return 0
    fi

    local _cmd_rc=0
    case "$command" in
        "npm cache clean --force")
            if ! command -v npm >/dev/null 2>&1; then
                record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: npm"
                print_skip "npm unavailable — skipping: ${command}"
                return 0
            fi
            npm cache clean --force || _cmd_rc=$?
            ;;
        "yarn cache clean")
            if ! command -v yarn >/dev/null 2>&1; then
                record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: yarn"
                print_skip "yarn unavailable — skipping: ${command}"
                return 0
            fi
            yarn cache clean || _cmd_rc=$?
            ;;
        "pnpm store prune")
            if ! command -v pnpm >/dev/null 2>&1; then
                record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: pnpm"
                print_skip "pnpm unavailable — skipping: ${command}"
                return 0
            fi
            pnpm store prune || _cmd_rc=$?
            ;;
        "pip cache purge")
            local _pip_cmd=""
            command -v pip3 >/dev/null 2>&1 && _pip_cmd="pip3"
            [[ -z "$_pip_cmd" ]] && command -v pip >/dev/null 2>&1 && _pip_cmd="pip"
            if [[ -z "$_pip_cmd" ]]; then
                record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: pip/pip3"
                print_skip "pip/pip3 unavailable — skipping: ${command}"
                return 0
            fi
            $_pip_cmd cache purge || _cmd_rc=$?
            ;;
        "brew cleanup --prune=all")
            if ! command -v brew >/dev/null 2>&1; then
                record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: brew"
                print_skip "brew unavailable — skipping: ${command}"
                return 0
            fi
            brew cleanup --prune=all || _cmd_rc=$?
            ;;
        "gem cleanup")
            if ! command -v gem >/dev/null 2>&1; then
                record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: gem"
                print_skip "gem unavailable — skipping: ${command}"
                return 0
            fi
            gem cleanup || _cmd_rc=$?
            ;;
        *)
            print_warn "Plan native command not in allowlist: ${command}"
            cleanup_journal_event "plan_apply_blocked" "$command" "" "$bytes" "blocked" "native command not allowlisted" "plan"
            return 1 ;;
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

    if ! verify_plan_file_checksum "$plan_file"; then
        print_error "Plan checksum verification failed: ${plan_file}"
        cleanup_journal_event "plan_apply_blocked" "$plan_file" "" 0 "blocked" "checksum mismatch" "plan"
        return 2
    fi

    local parsed_ops apply_failed
    parsed_ops="$(mktemp -t macos_cleanup_plan_parsed.XXXXXX)"
    apply_failed=0
    if ! python3 - "$plan_file" > "$parsed_ops" <<'PLANPARSE'
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
    local explicit_risk

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
