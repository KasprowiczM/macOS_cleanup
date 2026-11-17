#!/usr/bin/env bash
# =============================================================================
# lib/planner.sh — the plan: one list of operations for every mode
#
# build_cleanup_plan_from_analysis turns the analyzers' FOUND_* findings into
# operations. Every operation carries a registry category id (share/categories
# .tsv), its risk, its action, the dev:inode identity of its path and, for a
# native command, the target its tool resolves. Interactive, auto-safe,
# unattended and plan apply all execute this same list through execute_ops
# (lib/executor.sh); only the consent provider differs (R07, F06).
#
# Plans written to disk carry provenance (R08, F08): host, HOME, creation time
# and an HMAC made with a private local key; apply refuses anything else.
# Dependency: python3 (JSON parsing, checksum and HMAC; hashlib/hmac only).
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

# The analyzer owns the FOUND_* findings; a caller that builds a plan without
# it (tests, apply) still gets empty arrays, never an unbound-variable abort.
for _plan_found in FOUND_TRASH_ITEMS FOUND_USER_CACHES FOUND_APP_CACHE_ITEMS FOUND_APP_LOGS \
    FOUND_SYSTEM_LOGS FOUND_DIAGNOSTIC_REPORTS FOUND_TMP_FILES FOUND_SYSTEM_CACHES \
    FOUND_APP_LEFTOVERS FOUND_DEV_ITEMS FOUND_DEVICE_SUPPORT_ITEMS FOUND_TM_SNAPSHOTS \
    FOUND_IOS_BACKUPS FOUND_DMG_PKG FOUND_MAIL_ITEMS FOUND_BROWSER_CACHE_ITEMS FOUND_BROWSER_DATA_ITEMS; do
    if ! declare -p "$_plan_found" >/dev/null 2>&1; then
        eval "${_plan_found}=()"
    fi
done
unset _plan_found

# P1-7: temp files removed by remove_plan_temp_files when a run aborts.
PLAN_TMP_OUTPUT=""
APPLY_PLAN_SNAPSHOT=""

# remove_plan_temp_files — called from the EXIT handler.
remove_plan_temp_files() {
    [[ -n "${PLAN_TMP_OUTPUT:-}" ]] && rm -f "$PLAN_TMP_OUTPUT" 2>/dev/null
    [[ -n "${APPLY_PLAN_SNAPSHOT:-}" ]] && rm -f "$APPLY_PLAN_SNAPSHOT" 2>/dev/null
    [[ -n "${SIZE_MEMO_FILE:-}" ]] && rm -f "$SIZE_MEMO_FILE" 2>/dev/null
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
# dev:inode of the path at plan time ("" for native and report ops)
declare -a PLAN_OP_IDENTITY=()
# "" or "interactive": a native op only the interactive consent may run
# (docker, simulator runtimes, local snapshots); a plan file shows it as
# report_only, so apply --from-plan can never execute it.
declare -a PLAN_OP_SCOPE=()
# display name for events and prompts ("" = derived from the path)
declare -a PLAN_OP_LABELS=()
# "no" when an interactive native op must not fall back to safe_remove of its
# target (v3: brew with only stale versions found had no cache path to remove)
declare -a PLAN_OP_FALLBACK=()

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
    PLAN_OP_IDENTITY=()
    PLAN_OP_SCOPE=()
    PLAN_OP_LABELS=()
    PLAN_OP_FALLBACK=()
}

plan_next_id() {
    printf "op-%04d" "$(( ${#PLAN_OP_IDS[@]} + 1 ))"
}

# EXEC_ONLY_IDS — newline-delimited category ids from --only / --category <id>;
# empty means every category of the active sections (set by cleanup_all.sh).
EXEC_ONLY_IDS="${EXEC_ONLY_IDS:-}"

plan_category_allowed() {
    [[ -n "${EXEC_ONLY_IDS:-}" ]] || return 0
    case $'\n'"${EXEC_ONLY_IDS}"$'\n' in
        *$'\n'"${1:-}"$'\n'*) return 0 ;;
    esac
    return 1
}

plan_add_operation() {
    local id="$1" category="$2" risk="$3" action="$4" path="$5" command="$6" bytes="$7" description="$8" recommendation="$9"
    local rollback="${10:-}"
    local tool="${11:-}"
    local identity="${12:-}" scope="${13:-}" label="${14:-}" fallback="${15:-yes}"
    plan_category_allowed "$category" || return 0
    # V4 §4.4: a category whose mode is skip is reported, never offered.
    if [[ "$action" == "remove_path" || "$action" == "native_command" ]] && type mc_category_mode >/dev/null 2>&1; then
        mc_category_mode "$category" >/dev/null 2>&1 || REPLY=""
        if [[ "$REPLY" == "skip" ]]; then
            action="report_only"; command=""; tool=""; scope=""; rollback="false"
            recommendation="Category mode is skip (category-modes.tsv); not offered."
        fi
    fi
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
    PLAN_OP_IDENTITY+=("$identity")
    PLAN_OP_SCOPE+=("$scope")
    PLAN_OP_LABELS+=("$label")
    PLAN_OP_FALLBACK+=("$fallback")
}

# plan_root_allows <category> <path> — the path, normalized, lies under one of
# the category's registry roots. HOME is tried as given and resolved, so a
# HOME behind a symlink (/var -> /private/var) still matches.
plan_root_allows() {
    local cat="$1" path="$2" norm home_norm
    norm="$(normalize_path "$path" 2>/dev/null)" || return 1
    [[ -n "$norm" ]] || return 1
    home_norm="$(normalize_path "$HOME" 2>/dev/null)" || home_norm="$HOME"
    REG_HOME="$home_norm" reg_root_allows "$cat" "$norm" && return 0
    REG_HOME="$HOME" reg_root_allows "$cat" "$norm"
}

# plan_add_path <category> <risk> <path> <description> <recommendation> [label]
# A path outside its category's registry roots is reported, never planned.
plan_add_path() {
    local category="$1" risk="$2" path="$3" description="$4" recommendation="$5" label="${6:-}"
    local bytes
    plan_category_allowed "$category" || return 0
    bytes="$(path_size_bytes_memo "$path")"
    if ! plan_root_allows "$category" "$path"; then
        plan_add_operation "$(plan_next_id)" "$category" "REVIEW" "report_only" "$path" "" "$bytes" "$description" \
            "Outside the ${category} category roots; not removed by this tool." "false" "" "" "" "$label"
        return 0
    fi
    plan_add_operation "$(plan_next_id)" "$category" "$risk" "remove_path" "$path" "" "$bytes" "$description" "$recommendation" \
        "true" "" "$(plan_path_identity "$path")" "" "$label"
}

plan_add_report_only() {
    local category="$1" risk="$2" path="$3" bytes="$4" description="$5" recommendation="$6"
    plan_add_operation "$(plan_next_id)" "$category" "$risk" "report_only" "$path" "" "$bytes" "$description" "$recommendation" "false" ""
}

plan_add_native() {
    local category="$1" risk="$2" command="$3" bytes="$4" description="$5" recommendation="$6"
    local path="${7:-}"
    local tool="${8:-}"
    local fallback="${9:-yes}"
    plan_add_operation "$(plan_next_id)" "$category" "$risk" "native_command" "$path" "$command" "$bytes" "$description" "$recommendation" "false" "$tool" \
        "" "" "" "$fallback"
}

# plan_add_interactive_native <category> <command> <path-text> <bytes> <desc> <rec>
# A native op without a host target (docker, simctl runtimes, tmutil): only
# the interactive consent runs it, after its own confirmation; written to a
# plan file as report_only.
plan_add_interactive_native() {
    local category="$1" command="$2" path="$3" bytes="$4" description="$5" recommendation="$6"
    local tool="${command%% *}"
    plan_add_operation "$(plan_next_id)" "$category" "REVIEW" "native_command" "$path" "$command" "$bytes" "$description" "$recommendation" \
        "false" "$tool" "" "interactive"
}

# P1-4: plan_add_bound_native <category> <default-risk> <command> <bytes> <desc> <rec> [fallback]
# The op's path is the target its tool resolves now (native_tool_target), the
# same value apply re-resolves and must match. A tool that cannot name its
# target is reported instead of planned.
plan_add_bound_native() {
    local category="$1" default_risk="$2" command="$3" bytes="$4" description="$5" recommendation="$6"
    local fallback="${7:-yes}"
    local tool target
    plan_category_allowed "$category" || return 0
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
        "$description" "$recommendation" "$target" "$tool" "$fallback"
}

# plan_file_action <index> — the action a plan file shows: interactive-only
# native ops are report_only there.
plan_file_action() {
    if [[ "${PLAN_OP_SCOPE[$1]:-}" == "interactive" ]]; then
        printf 'report_only'
    else
        printf '%s' "${PLAN_OP_ACTIONS[$1]}"
    fi
}

# P1-1: plan_op_is_executable <index> — true when this run's mode would act on
# the operation. report_only never runs, DANGEROUS is never applied, and the
# quarantine mode skips non-user remove_path targets (/tmp, /Library/Logs), so
# none of them can free anything. Interactive-only natives count as report-only
# (their size is informational, as in v3).
plan_op_is_executable() {
    local i="$1"
    [[ "${PLAN_OP_SCOPE[$i]:-}" != "interactive" ]] || return 1
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
        if [[ "$(plan_file_action "$i")" == "report_only" ]]; then
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

# dev_item_category <FOUND_DEV_ITEMS key> — the registry id of an analyzer
# dev item (the analyzer keeps its own item keys; this is the one mapping).
dev_item_category() {
    case "${1:-}" in
        xcode_derived_data) echo xcode-derived ;;
        xcode_archives)     echo xcode-archives ;;
        ios_simulators)     echo simulators ;;
        sim_runtimes_unusable) echo sim-runtimes ;;
        npm_cache)          echo npm ;;
        npx_cache)          echo npx ;;
        yarn_cache)         echo yarn ;;
        pnpm_cache)         echo pnpm ;;
        pnpm_stale_store)   echo pnpm-stale ;;
        pip_cache)          echo pip ;;
        brew_cache|brew_cleanup) echo brew ;;
        gradle_cache)       echo gradle ;;
        maven_cache)        echo maven ;;
        cocoapods_cache)    echo cocoapods ;;
        cargo_cache)        echo cargo ;;
        swift_pm_cache)     echo swift-pm ;;
        gem_cache)          echo gem ;;
        bundler_cache)      echo bundler ;;
        composer_cache)     echo composer ;;
        android_avd)        echo android-avd ;;
        docker_prune)       echo docker ;;
        *) return 1 ;;
    esac
}

# _plan_app_cache_category <label> — app-caches (allowlisted) or
# app-caches-review, from share/app_caches.tsv.
_plan_app_cache_category() {
    if reg_app_cache_category "${1:-}" 2>/dev/null && [[ -n "$REPLY" ]]; then
        printf '%s' "$REPLY"
    else
        printf 'app-caches-review'
    fi
}

# _plan_sort_by_registry — stable reorder of the operations into registry
# order (consent, execution and event groups follow it), then renumber ids.
_plan_sort_by_registry() {
    local count i idx key order
    count=${#PLAN_OP_IDS[@]}
    (( count > 0 )) || return 0
    local -a n_cat=() n_risk=() n_act=() n_path=() n_cmd=() n_bytes=() n_desc=() n_rec=() n_rb=() n_tool=() n_ident=() n_scope=() n_label=() n_fb=()
    order=""
    for (( i=0; i<count; i++ )); do
        idx="$REG_COUNT"
        if reg_index "${PLAN_OP_CATEGORIES[$i]}" 2>/dev/null; then idx="$REPLY"; fi
        eval "_PLB_${idx}=\"\${_PLB_${idx}:-} ${i}\""
    done
    for (( idx=0; idx<=REG_COUNT; idx++ )); do
        eval "key=\"\${_PLB_${idx}:-}\""
        unset "_PLB_${idx}"
        [[ -n "$key" ]] && order="${order}${key}"
    done
    for i in $order; do
        n_cat+=("${PLAN_OP_CATEGORIES[$i]}");  n_risk+=("${PLAN_OP_RISKS[$i]}")
        n_act+=("${PLAN_OP_ACTIONS[$i]}");     n_path+=("${PLAN_OP_PATHS[$i]}")
        n_cmd+=("${PLAN_OP_COMMANDS[$i]}");    n_bytes+=("${PLAN_OP_BYTES[$i]}")
        n_desc+=("${PLAN_OP_DESCS[$i]}");      n_rec+=("${PLAN_OP_RECS[$i]}")
        n_rb+=("${PLAN_OP_ROLLBACK[$i]}");     n_tool+=("${PLAN_OP_TOOLS[$i]}")
        n_ident+=("${PLAN_OP_IDENTITY[$i]}");  n_scope+=("${PLAN_OP_SCOPE[$i]}")
        n_label+=("${PLAN_OP_LABELS[$i]}");   n_fb+=("${PLAN_OP_FALLBACK[$i]:-yes}")
    done
    plan_reset
    for (( i=0; i<count; i++ )); do
        PLAN_OP_IDS+=("$(printf 'op-%04d' "$(( i + 1 ))")")
    done
    PLAN_OP_CATEGORIES=("${n_cat[@]}");  PLAN_OP_RISKS=("${n_risk[@]}")
    PLAN_OP_ACTIONS=("${n_act[@]}");     PLAN_OP_PATHS=("${n_path[@]}")
    PLAN_OP_COMMANDS=("${n_cmd[@]}");    PLAN_OP_BYTES=("${n_bytes[@]}")
    PLAN_OP_DESCS=("${n_desc[@]}");      PLAN_OP_RECS=("${n_rec[@]}")
    PLAN_OP_ROLLBACK=("${n_rb[@]}");     PLAN_OP_TOOLS=("${n_tool[@]}")
    PLAN_OP_IDENTITY=("${n_ident[@]}");  PLAN_OP_SCOPE=("${n_scope[@]}")
    PLAN_OP_LABELS=("${n_label[@]}");    PLAN_OP_FALLBACK=("${n_fb[@]}")
}

build_cleanup_plan_from_analysis() {
    local item path label key brew_b brew_fb cat snap_date
    plan_reset
    registry_require

    # E-B: mc_phase plan start / end are emitted by the callers around this
    # function and generate_plan_json (cleanup_all.sh run_dry_run_phase).

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
            cat="$(_plan_app_cache_category "$label")"
            if [[ "$cat" == "app-caches" ]]; then
                plan_add_path "app-caches" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                    "${label}: recreateable app cache." \
                    "App will recreate cache on launch." "$label"
            else
                plan_add_path "app-caches-review" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                    "${label}: app cache outside auto-safe allowlist." \
                    "Review manually before removal." "$label"
            fi
        done
    fi

    if (( ${#FOUND_APP_LOGS[@]} > 0 )); then
        for path in "${FOUND_APP_LOGS[@]}"; do
            plan_add_path "user-logs" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old log file or diagnostic report." \
                "Safe unless actively troubleshooting."
        done
    fi
    if (( ${#FOUND_SYSTEM_LOGS[@]} > 0 )); then
        for path in "${FOUND_SYSTEM_LOGS[@]}"; do
            plan_add_path "system-logs" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old log file or diagnostic report." \
                "Safe unless actively troubleshooting."
        done
    fi
    if (( ${#FOUND_DIAGNOSTIC_REPORTS[@]} > 0 )); then
        for path in "${FOUND_DIAGNOSTIC_REPORTS[@]}"; do
            plan_add_path "diagnostic-reports" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old log file or diagnostic report." \
                "Safe unless actively troubleshooting."
        done
    fi

    if (( ${#FOUND_TMP_FILES[@]} > 0 )); then
        for path in "${FOUND_TMP_FILES[@]}"; do
            plan_add_path "tmp" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                "Old temporary file." \
                "Safe to remove; macOS and apps treat /tmp as transient."
        done
    fi

    if (( ${#FOUND_SYSTEM_CACHES[@]} > 0 )); then
        for path in "${FOUND_SYSTEM_CACHES[@]}"; do
            plan_add_report_only "system-caches" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes_memo "$path")" \
                "System cache /Library/Caches." \
                "Not executed from plan; use interactive mode after review."
        done
    fi

    if (( ${#FOUND_APP_LEFTOVERS[@]} > 0 )); then
        for path in "${FOUND_APP_LEFTOVERS[@]}"; do
            plan_add_report_only "app-leftovers" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes_memo "$path")" \
                "Heuristic app leftover." \
                "Remove manually after confirming app is uninstalled."
        done
    fi

    if (( ${#FOUND_DEV_ITEMS[@]} > 0 )); then
        for item in "${FOUND_DEV_ITEMS[@]}"; do
            key="${item%%:*}"
            path="${item#*:}"
            cat="$(dev_item_category "$key")" || continue
            case "$key" in
                xcode_derived_data)
                    plan_add_path "$cat" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                        "Xcode DerivedData: recreateable build artifacts." \
                        "Xcode will rebuild projects on next compilation."
                    ;;
                xcode_archives)
                    plan_add_report_only "$cat" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes_memo "$path")" \
                        "Xcode Archives may be required for app distribution or symbolication." \
                        "Review in Xcode Organizer before deletion."
                    ;;
                ios_simulators)
                    plan_add_bound_native "$cat" "REVIEW" "xcrun simctl delete unavailable" "$(catbytes_get "simulators")" \
                        "Deletes only unavailable simulators." \
                        "Execute after review; runtimes can be re-downloaded."
                    ;;
                sim_runtimes_unusable)
                    # Runtimes live in a system-managed store that only simctl
                    # may change; a plan file reports them and the interactive
                    # mode runs simctl with its own confirmation.
                    plan_add_interactive_native "$cat" "xcrun simctl runtime delete --unusable" \
                        "simctl: unusable runtimes (xcrun simctl runtime delete --unusable)" \
                        "$(catbytes_get "sim-runtimes")" \
                        "Simulator runtimes that simctl marks unusable." \
                        "Run 'xcrun simctl runtime delete --unusable' yourself, or use --interactive."
                    ;;
                npx_cache|pnpm_stale_store)
                    plan_add_path "$cat" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                        "Recreateable package manager cache." \
                        "The tool will re-download packages as needed."
                    ;;
                npm_cache)
                    plan_add_bound_native "$cat" "SAFE" "npm cache clean --force" "$(catbytes_get "npm")" \
                        "npm cache." "Packages will be re-downloaded if needed." ;;
                yarn_cache)
                    plan_add_bound_native "$cat" "SAFE" "yarn cache clean" "$(catbytes_get "yarn")" \
                        "Yarn cache." "Packages will be re-downloaded if needed." ;;
                pnpm_cache)
                    plan_add_bound_native "$cat" "SAFE" "pnpm store prune" "$(catbytes_get "pnpm")" \
                        "pnpm store." "pnpm prunes unused store items." ;;
                pip_cache)
                    plan_add_bound_native "$cat" "SAFE" "pip cache purge" "$(catbytes_get "pip")" \
                        "pip cache." "Packages will be re-downloaded if needed." ;;
                brew_cache|brew_cleanup)
                    # P1-1: one brew cleanup covers the cache and the stale
                    # versions, which overlap; the analyzer records the
                    # larger estimate as the brew category (registry: merged).
                    brew_b="$(catbytes_get "brew")"
                    # v3: only a found cache dir was removed when brew failed.
                    brew_fb="yes"
                    [[ "$key" == "brew_cleanup" ]] && brew_fb="no"
                    # P1-4: --prune=all also removes old formula versions (REVIEW).
                    plan_add_bound_native "$cat" "REVIEW" "brew cleanup --prune=all" "$brew_b" \
                        "Homebrew cache & old formulae versions." "Homebrew rebuilds cache on demand." "$brew_fb" ;;
                gem_cache)
                    # P1-4: gem cleanup uninstalls old gem versions (REVIEW).
                    plan_add_bound_native "$cat" "REVIEW" "gem cleanup" "$(catbytes_get "gem")" \
                        "Ruby gems cache / old versions." "Gems can be reinstalled." ;;
                gradle_cache|cocoapods_cache|cargo_cache|swift_pm_cache|bundler_cache|composer_cache)
                    plan_add_path "$cat" "$(policy_adjust_risk_for_path "$path" "SAFE")" "$path" \
                        "Recreateable dev tool cache." \
                        "Builds will re-download dependencies."
                    ;;
                maven_cache)
                    plan_add_report_only "$cat" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes_memo "$path")" \
                        "Maven repository may contain locally built artifacts." \
                        "Do not delete automatically; review manually."
                    ;;
                android_avd)
                    plan_add_report_only "$cat" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" "$(path_size_bytes_memo "$path")" \
                        "Android AVD may contain emulator local state." \
                        "Remove via Android Studio Device Manager after review."
                    ;;
                docker_prune)
                    # P1-4: Docker storage lives in its VM, so there is no host
                    # target to bind; a plan file reports it and the interactive
                    # mode runs it with its own confirmation.
                    plan_add_interactive_native "$cat" "docker system prune -f" "docker: reclaimable (docker system df)" "$(catbytes_get "docker")" \
                        "Docker: images, stopped containers, networks, and build cache." \
                        "Run 'docker system prune' yourself, or use --interactive, if stopped container data is no longer required."
                    ;;
            esac
        done
    fi

    if (( ${#FOUND_DEVICE_SUPPORT_ITEMS[@]} > 0 )); then
        for item in "${FOUND_DEVICE_SUPPORT_ITEMS[@]}"; do
            path="${item#*:}"
            plan_add_path "device-support" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Xcode Device Support older than ${DEVICE_SUPPORT_MIN_AGE_DAYS} days." \
                "Xcode re-downloads debug symbols upon connecting matching devices."
        done
    fi

    if (( ${#FOUND_TM_SNAPSHOTS[@]} > 0 )); then
        for item in "${FOUND_TM_SNAPSHOTS[@]}"; do
            snap_date="$(tm_snapshot_date "$item")" || snap_date=""
            if [[ -n "$snap_date" ]]; then
                plan_add_interactive_native "tm-snapshots" "tmutil deletelocalsnapshots ${snap_date}" "$item" 0 \
                    "Local Time Machine snapshot." \
                    "macOS reclaims snapshots automatically; manual deletion requires fresh backup."
            else
                plan_add_report_only "tm-snapshots" "REVIEW" "$item" 0 \
                    "Local Time Machine snapshot." \
                    "macOS reclaims snapshots automatically; manual deletion requires fresh backup."
            fi
        done
    fi

    if (( ${#FOUND_IOS_BACKUPS[@]} > 0 )); then
        for path in "${FOUND_IOS_BACKUPS[@]}"; do
            plan_add_path "ios-backups" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Local iOS/iPadOS backup." \
                "Remove only after confirming external or iCloud backup."
        done
    fi

    if (( ${#FOUND_DMG_PKG[@]} > 0 )); then
        for path in "${FOUND_DMG_PKG[@]}"; do
            plan_add_path "installers" "$(policy_adjust_risk_for_path "$path" "REVIEW")" "$path" \
                "Old DMG/PKG/ISO installer in Downloads." \
                "Remove only if re-downloadable or no longer needed."
        done
    fi

    if (( ${#FOUND_MAIL_ITEMS[@]} > 0 )); then
        for item in "${FOUND_MAIL_ITEMS[@]}"; do
            key="${item%%:*}"
            path="${item#*:}"
            cat="mail-data"
            [[ "$key" == "mail-downloads" ]] && cat="mail-downloads"
            plan_add_report_only "$cat" "DANGEROUS" "$path" "$(path_size_bytes_memo "$path")" \
                "Apple Mail: ${key}. Mail data is critical user content." \
                "Manage attachments via Mail.app or Finder."
        done
    fi

    if (( ${#FOUND_BROWSER_CACHE_ITEMS[@]} > 0 )); then
        for item in "${FOUND_BROWSER_CACHE_ITEMS[@]}"; do
            label="${item%%:*}"
            path="${item#*:}"
            plan_add_report_only "browser-caches" "REVIEW" "$path" "$(path_size_bytes_memo "$path")" \
                "${label}: browser cache." \
                "Prefer clearing cache via browser UI."
        done
    fi

    if (( ${#FOUND_BROWSER_DATA_ITEMS[@]} > 0 )); then
        for item in "${FOUND_BROWSER_DATA_ITEMS[@]}"; do
            label="${item%%:*}"
            path="${item#*:}"
            plan_add_report_only "browser-data" "DANGEROUS" "$path" "$(path_size_bytes_memo "$path")" \
                "${label}: profile, cookies, passwords, history, or sessions." \
                "Never delete automatically; use browser privacy settings."
        done
    fi

    _plan_sort_by_registry
}

# ---------------------------------------------------------------------------
# R08: plan provenance — host, HOME, time and a keyed HMAC.
# ---------------------------------------------------------------------------
PLAN_MAX_AGE_SECONDS=86400

# plan_state_dir — the state directory (V4 §1.1 precedence).
plan_state_dir() {
    local d=""
    if [[ -n "${MC_STATE_DIR:-}" ]]; then
        d="$MC_STATE_DIR"
    elif [[ "${MACOS_CLEANUP_STATE_DIR:-}" == /* ]]; then
        d="$MACOS_CLEANUP_STATE_DIR"
    elif [[ "${XDG_STATE_HOME:-}" == /* ]]; then
        d="${XDG_STATE_HOME}/macos-cleanup"
    else
        d="${HOME}/.local/state/macos-cleanup"
    fi
    printf '%s' "${d%/}"
}

# plan_host_id — sha256 of "<hostname>:<uid>" (computed once per run).
PLAN_HOST_ID=""
plan_host_id() {
    if [[ -z "$PLAN_HOST_ID" ]]; then
        PLAN_HOST_ID="$(printf '%s:%s' "$("$_MC_HOSTNAME" 2>/dev/null)" "$("$_MC_ID" -u 2>/dev/null)" | "$_MC_SHASUM" -a 256 2>/dev/null | awk '{print $1}')" || PLAN_HOST_ID=""
    fi
    printf '%s' "$PLAN_HOST_ID"
}

# _plan_key_ok <file> — a regular, non-symlink, 32-byte, mode-0600 file of ours.
_plan_key_ok() {
    local f="$1"
    [[ -f "$f" && ! -L "$f" && -O "$f" ]] || return 1
    [[ "$("$_MC_STAT" -f '%Lp' "$f" 2>/dev/null)" == "600" ]] || return 1
    [[ "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" == "32" ]]
}

# _plan_key_dir_ok <dir> — a real directory (no link), owned by us, that neither
# the group nor others can write to.
_plan_key_dir_ok() {
    local d="$1" mode
    [[ -d "$d" && ! -L "$d" && -O "$d" ]] || return 1
    mode="$("$_MC_STAT" -f '%Lp' "$d" 2>/dev/null)" || return 1
    case "$mode" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;; *) return 1 ;; esac
    (( (8#$mode & 8#022) == 0 ))
}

# plan_key_file [--create] — prints the plan key path when the key is usable;
# --create makes it on first use (32 random bytes, 0600, in a 0700 dir).
plan_key_file() {
    local dir key tmp
    dir="$(plan_state_dir)/keys"
    key="${dir}/plan.key"
    if _plan_key_ok "$key"; then
        printf '%s' "$key"
        return 0
    fi
    [[ "${1:-}" == "--create" ]] || return 1
    [[ -e "$key" || -L "$key" ]] && return 1
    ( umask 077; mkdir -p "$dir" ) 2>/dev/null || return 1
    # F15: the directory is ours and nobody else can write to it; anything
    # else is refused (an older 0755 directory is fine and gets tightened).
    _plan_key_dir_ok "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    # The temporary file is created exclusively (mktemp: O_EXCL, 0600), so a
    # planted link cannot redirect the write, and moved into place without
    # replacing anything.
    tmp="$(mktemp "${dir}/plan.key.XXXXXXXX" 2>/dev/null)" || return 1
    ( umask 077; head -c 32 /dev/urandom > "$tmp" ) 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -n "$tmp" "$key" 2>/dev/null || { rm -f "$tmp"; return 1; }
    [[ ! -e "$tmp" ]] || { rm -f "$tmp"; return 1; }
    _plan_key_ok "$key" || return 1
    printf '%s' "$key"
}

# The one implementation of the stamp: header fields, checksum and HMAC.
# argv: file key_file host_id home created_epoch. An empty key leaves the
# HMAC empty (apply then refuses the plan).
# shellcheck disable=SC2016
_PLAN_STAMP_PY='
import hashlib, hmac, json, sys
path, key_file, host_id, home, epoch = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
ops = data.get("operations", [])
if not isinstance(ops, list):
    sys.exit(1)
data["schema_version"] = "2.0"
data["version"] = "2.0"
data["host_id"] = host_id
data["home"] = home
data["created_epoch"] = int(epoch)
data["checksum"] = hashlib.sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
mac = ""
if key_file:
    with open(key_file, "rb") as f:
        key = f.read()
    msg = json.dumps({"created_epoch": data["created_epoch"], "home": home, "host_id": host_id,
                      "run_id": data.get("run_id", ""), "operations": ops},
                     sort_keys=True, separators=(",", ":")).encode()
    mac = hmac.new(key, msg, hashlib.sha256).hexdigest()
data["hmac"] = mac
tmp = path + ".stamp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
import os
os.replace(tmp, path)
'

# plan_sign_file <plan> [created_epoch] [host_id] — (re)stamp a plan file with
# this host, this HOME, the given time (default now) and the local key. Used
# by generate_plan_json; tests use it to sign hand-written plans.
plan_sign_file() {
    local file="$1" epoch="${2:-}" host="${3:-}" key=""
    [[ -f "$file" ]] || return 1
    [[ -n "$epoch" ]] || epoch="$(date +%s)"
    [[ -n "$host" ]] || host="$(plan_host_id)"
    key="$(plan_key_file --create)" || key=""
    if [[ -z "$key" ]]; then
        print_warn "Plan key unavailable under $(plan_state_dir)/keys; the plan cannot be applied."
    fi
    python3 -I -c "$_PLAN_STAMP_PY" "$file" "$key" "$host" "$HOME" "$epoch"
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

    local dir tmp_output now_epoch
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
    now_epoch="$(date +%s)"

    {
        printf '{\n'
        printf '  "schema_version": "2.0",\n'
        printf '  "version": "2.0",\n'
        printf '  "tool": "%s",\n' "$(json_escape "${SCRIPT_NAME:-cleanup_all.sh}")"
        printf '  "tool_version": "%s",\n' "$(json_escape "${SCRIPT_VERSION:-unknown}")"
        printf '  "run_id": "%s",\n' "$(json_escape "${RUN_TIMESTAMP:-test_run}")"
        printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "created_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "created_epoch": %s,\n' "$now_epoch"
        printf '  "host_id": "",\n'
        printf '  "home": "",\n'
        printf '  "checksum": "pending",\n'
        printf '  "hmac": "",\n'
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

            local json_path json_cmd json_desc json_rec json_tool json_rollback json_ident
            json_path="$(json_escape "${PLAN_OP_PATHS[$i]}")"
            json_cmd="$(json_escape "${PLAN_OP_COMMANDS[$i]}")"
            json_desc="$(json_escape "${PLAN_OP_DESCS[$i]}")"
            json_rec="$(json_escape "${PLAN_OP_RECS[$i]}")"
            json_tool="$(json_escape "${PLAN_OP_TOOLS[$i]:-}")"
            json_ident="$(json_escape "${PLAN_OP_IDENTITY[$i]:-}")"
            json_rollback="${PLAN_OP_ROLLBACK[$i]:-false}"
            case "$json_rollback" in
                true|false) ;;
                *) json_rollback="false" ;;
            esac
            # An interactive-only native is never executable from a file.
            if [[ "${PLAN_OP_SCOPE[$i]:-}" == "interactive" ]]; then
                json_cmd=""
                json_tool=""
            fi

            printf '    {\n'
            printf '      "id": "%s",\n' "${PLAN_OP_IDS[$i]}"
            printf '      "category": "%s",\n' "${PLAN_OP_CATEGORIES[$i]}"
            printf '      "risk": "%s",\n' "${PLAN_OP_RISKS[$i]}"
            printf '      "action": "%s",\n' "$(plan_file_action "$i")"
            printf '      "path": "%s",\n' "$json_path"
            printf '      "command": "%s",\n' "$json_cmd"
            printf '      "estimated_bytes": %s,\n' "${PLAN_OP_BYTES[$i]:-0}"
            printf '      "size": %s,\n' "${PLAN_OP_BYTES[$i]:-0}"
            printf '      "description": "%s",\n' "$json_desc"
            printf '      "recommendation": "%s",\n' "$json_rec"
            printf '      "rollback": %s,\n' "$json_rollback"
            printf '      "identity": "%s",\n' "$json_ident"
            printf '      "tool": "%s"\n' "$json_tool"
            printf '    }%s\n' "$sep"
        done
        printf '  ]\n'
        printf '}\n'
    } > "$tmp_output"

    if ! plan_sign_file "$tmp_output" "$now_epoch"; then
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
    mc_plan_written "$output" "$count" "$executable_bytes" "$report_only_bytes"
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

# execute_plan_native_command <command> <bytes> <path> [group] [op-id]
# Runs one allowlisted native command bound to its tool's target (P1-4).
# Sets MC_LAST_RESULT / MC_LAST_REASON / MC_LAST_FREED (before/after on the
# bound path):
#   cleaned       the command succeeded
#   failed        the command failed (native_failed)
#   unavailable   the tool is not installed
#   skipped       refused: not allowlisted (plan_rejected), target moved
#                 (identity_changed) or outside the cache roots
#                 (outside_category_root)
#   dry_run       a dry-run preview
# Returns non-zero for a refusal or a failed command.
execute_plan_native_command() {
    local command="$1"
    local bytes="${2:-0}"
    local path="${3:-}"
    local group="${4:-}" op_id="${5:-}"
    local before=0
    local after=0

    _mc_last skipped unknown 0
    if [[ -n "$path" && -e "$path" ]]; then
        before="$(path_size_bytes "$path")" || before=0
    fi

    local _cmd_rc=0 tool bin target want
    if ! tool="$(native_tool_for_command "$command")"; then
        print_warn "Plan native command not in allowlist: ${command}"
        cleanup_journal_event "plan_apply_blocked" "$command" "" "$bytes" "blocked" "native command not allowlisted" "plan"
        _mc_last skipped plan_rejected 0
        return 1
    fi
    bin="$tool"
    if [[ "$tool" == "pip" ]]; then
        bin="$(native_pip_bin)" || bin=""
    fi
    if [[ -z "$bin" ]] || ! native_tool_available "$bin"; then
        [[ "$tool" == "pip" ]] && tool="pip/pip3"
        record_native_command_event "$command" "skipped" "$bytes" "tool unavailable: ${tool}"
        print_skip "${tool} unavailable — skipping: ${command}"
        _mc_last unavailable "" 0
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
        _mc_last skipped identity_changed 0
        return 1
    fi
    if ! native_target_allowed "$tool" "$target"; then
        print_warn "Plan command target outside the cache roots: ${command} (${target})"
        cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "native target outside cache roots" "plan"
        _mc_last skipped outside_category_root 0
        return 1
    fi

    # P1-4: a dry-run previews only what a real apply would run.
    if is_dry_run; then
        print_dry "Would run: ${command}"
        record_native_command_event "$command" "planned" "$bytes" "plan dry-run"
        _mc_last dry_run "" 0
        return 0
    fi

    [[ -n "$group" ]] && mc_item_progress "$group" "$op_id" running
    case "$command" in
        "npm cache clean --force")         _native_in_home npm cache clean --force || _cmd_rc=$? ;;
        "yarn cache clean")                _native_in_home yarn cache clean || _cmd_rc=$? ;;
        "pnpm store prune")                _native_in_home pnpm store prune || _cmd_rc=$? ;;
        "pip cache purge")                 _native_in_home "$bin" cache purge || _cmd_rc=$? ;;
        "brew cleanup --prune=all")        _native_in_home brew cleanup --prune=all || _cmd_rc=$? ;;
        "gem cleanup")                     _native_in_home gem cleanup || _cmd_rc=$? ;;
        "xcrun simctl delete unavailable") _native_in_home xcrun simctl delete unavailable || _cmd_rc=$? ;;
    esac

    if (( _cmd_rc == 0 )); then
        if [[ -n "$path" && -e "$path" ]]; then
            after="$(path_size_bytes "$path")" || after=0
        else
            after=0
        fi
        print_cleaned "Executed plan command: ${command}"
        record_native_command_freed "$command" "$before" "$after" "plan apply"
        case "$before" in ''|*[!0-9]*) before=0 ;; esac
        case "$after" in ''|*[!0-9]*) after=0 ;; esac
        if (( before > after )); then
            _mc_last cleaned "" $(( before - after ))
        else
            _mc_last cleaned "" 0
        fi
    else
        print_warn "Plan command failed: ${command}"
        record_native_command_event "$command" "failed" "$bytes" "plan apply failed"
        _mc_last failed native_failed 0
    fi
    return "$_cmd_rc"
}

plan_require_review_confirmation() {
    local path="$1"
    local id="$2"
    local group="${3:-}"

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
        mc_consent_guard "plan-review"
        mc_prompt "plan-review" text "REVIEW: to execute ${id}, type exact path: ${path}" "" "$group"
        read -r typed
        [[ "$typed" == "$path" ]] || return 1
        return 0
    fi

    ask_yes_no "Execute plan REVIEW operation: ${id}?" "no" "$group"
}

verify_plan_file_checksum() {
    local plan_file="$1"
    python3 -I -c '
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
    _apply_plan_snapshot "$plan_file" "$plan_snapshot" || _apply_rc=$?
    rm -f "$plan_snapshot"
    APPLY_PLAN_SNAPSHOT=""
    return "$_apply_rc"
}

# _plan_reject <plan-file> <reason> — R08: refuse the whole plan (exit code 2
# from apply), one sentence on stderr, one journal line.
_plan_reject() {
    print_error "$(t plan_rejected "$2" "$1")"
    cleanup_journal_event "plan_apply_blocked" "$1" "" 0 "blocked" "plan_rejected: ${2}" "plan"
    return 2
}

# Structure, provenance and HMAC check of a plan snapshot, then one record
# per operation. argv: snapshot key_file host_id home now max_age.
# Exit: 0 ok, 1 malformed, 3 a 3.x plan, 4 no key / bad HMAC, 5 other HOME,
# 6 other host, 7 too old (or from the future).
# shellcheck disable=SC2016
_PLAN_VERIFY_PY='
import base64, hashlib, hmac, json, sys

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

snap, key_file, host_id, home, now, max_age = sys.argv[1:7]
try:
    with open(snap, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
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
    if not isinstance(op.get("category", ""), str):
        sys.exit(1)
    if action == "native_command":
        command = op.get("command")
        path = op.get("path")
        if not isinstance(command, str) or command not in ALLOWLIST:
            sys.exit(1)
        if not isinstance(path, str) or not path.strip():
            sys.exit(1)

mac = data.get("hmac")
if str(data.get("schema_version", "")) != "2.0" or not isinstance(mac, str) or not mac:
    sys.exit(3)
if not key_file:
    sys.exit(4)
epoch = data.get("created_epoch")
if isinstance(epoch, bool) or not isinstance(epoch, int):
    sys.exit(4)
with open(key_file, "rb") as f:
    key = f.read()
msg = json.dumps({"created_epoch": epoch, "home": data.get("home", ""), "host_id": data.get("host_id", ""),
                  "run_id": data.get("run_id", ""), "operations": ops},
                 sort_keys=True, separators=(",", ":")).encode()
if not hmac.compare_digest(hmac.new(key, msg, hashlib.sha256).hexdigest(), mac):
    sys.exit(4)
if data.get("home") != home:
    sys.exit(5)
if data.get("host_id") != host_id:
    sys.exit(6)
age = int(now) - epoch
if age > int(max_age) or age < -300:
    sys.exit(7)

for op in ops:
    print("\x1f".join([
        b64(op.get("id", "")),
        str(op.get("risk", "")),
        str(op.get("action", "")),
        b64(op.get("path", "")),
        b64(op.get("command", "")),
        str(op.get("estimated_bytes")),
        b64(op.get("category", "")),
        b64(op.get("identity", "")),
    ]))
'

# _plan_section_selected <category-id> — 0 when no section selection narrows the
# run (--category <section>) or the category's section is among the selected
# ones. Other modes get this for free from the analysis, which only visits the
# selected sections; an apply loads a plan and needs the check itself.
_plan_section_selected() {
    local sec
    [[ -n "${ACTIVE_CATEGORIES+x}" && -n "${ALL_CATEGORIES+x}" ]] || return 0
    (( ${#ACTIVE_CATEGORIES[@]} > 0 && ${#ACTIVE_CATEGORIES[@]} < ${#ALL_CATEGORIES[@]} )) || return 0
    reg_get "${1:-}" section 2>/dev/null || return 0
    sec="$REPLY"
    case " ${ACTIVE_CATEGORIES[*]} " in *" ${sec} "*) return 0 ;; esac
    return 1
}

# _apply_plan_snapshot <plan-file-for-messages> <snapshot> — body of
# apply_plan_file: verify, load the operations into PLAN_OP_*, then the same
# executor as every other mode with the plan_file consent provider.
# shellcheck disable=SC2094  # the loop reads a parsed snapshot; the journal it writes is another file
_apply_plan_snapshot() {
    local plan_file="$1" plan_snapshot="$2"

    if ! verify_plan_file_checksum "$plan_snapshot"; then
        print_error "Plan checksum verification failed: ${plan_file}"
        cleanup_journal_event "plan_apply_blocked" "$plan_file" "" 0 "blocked" "checksum mismatch" "plan"
        return 2
    fi
    registry_require

    local parsed_ops key_file verify_rc=0
    key_file="$(plan_key_file)" || key_file=""
    parsed_ops="$(mktemp -t macos_cleanup_plan_parsed.XXXXXX)"
    python3 -I -c "$_PLAN_VERIFY_PY" "$plan_snapshot" "$key_file" "$(plan_host_id)" "$HOME" "$(date +%s)" \
        "$PLAN_MAX_AGE_SECONDS" > "$parsed_ops" 2>/dev/null || verify_rc=$?
    case "$verify_rc" in
        0) ;;
        1)
            rm -f "$parsed_ops"
            print_error "Plan document validation failed: ${plan_file}"
            cleanup_journal_event "plan_apply_blocked" "$plan_file" "" 0 "blocked" "parser error" "plan"
            return 1 ;;
        3) rm -f "$parsed_ops"
           _plan_reject "$plan_file" "written by macOS Cleanup 3.x or unsigned; plans are bound to a local key since 4.0 — run 'plan' again"
           return 2 ;;
        4) rm -f "$parsed_ops"; _plan_reject "$plan_file" "missing plan key or HMAC mismatch"; return 2 ;;
        5) rm -f "$parsed_ops"; _plan_reject "$plan_file" "made for another HOME"; return 2 ;;
        6) rm -f "$parsed_ops"; _plan_reject "$plan_file" "made on another host"; return 2 ;;
        7) rm -f "$parsed_ops"; _plan_reject "$plan_file" "older than 24 hours"; return 2 ;;
        *) rm -f "$parsed_ops"; _plan_reject "$plan_file" "verification failed"; return 2 ;;
    esac

    local id_b64 risk action path_b64 command_b64 bytes category_b64 ident_b64
    local id path command category identity reg_action reg_cmd norm
    plan_reset
    while IFS=$'\x1f' read -u3 -r id_b64 risk action path_b64 command_b64 bytes category_b64 ident_b64; do
        # Exact bytes: a path ending in a newline stays that path (F12).
        base64_decode_exact "$id_b64"; id="$REPLY"
        base64_decode_exact "$path_b64"; path="$REPLY"
        base64_decode_exact "$command_b64"; command="$REPLY"
        base64_decode_exact "$category_b64"; category="$REPLY"
        base64_decode_exact "$ident_b64"; identity="$REPLY"
        case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac

        # R08: an executable op whose category the registry does not know,
        # whose action the category does not take, whose native command is
        # not the category's own, or whose path lies outside the category
        # roots refuses the whole plan before anything runs. report_only rows
        # never execute and are not checked. The path is kept as written (the
        # typed-path confirmation compares it); every sink check normalizes.
        if [[ "$action" == "remove_path" || "$action" == "native_command" ]]; then
            if ! reg_is_id "$category"; then
                rm -f "$parsed_ops"
                _plan_reject "$plan_file" "unknown category '${category}' in ${id}"
                return 2
            fi
            reg_get "$category" action; reg_action="$REPLY"
            reg_get "$category" native_cmd; reg_cmd="$REPLY"
        fi
        case "$action" in
            remove_path)
                if [[ "$reg_action" != "remove" ]]; then
                    rm -f "$parsed_ops"; _plan_reject "$plan_file" "${id}: ${category} takes no remove_path"; return 2
                fi
                norm="$(normalize_path "$path" 2>/dev/null)" || norm=""
                if [[ -z "$norm" ]] || ! plan_root_allows "$category" "$norm"; then
                    rm -f "$parsed_ops"; _plan_reject "$plan_file" "${id}: path outside the ${category} roots"; return 2
                fi
                ;;
            native_command)
                if [[ "$reg_action" != "native" || "$command" != "$reg_cmd" ]]; then
                    rm -f "$parsed_ops"; _plan_reject "$plan_file" "${id}: '${command}' is not the ${category} command"; return 2
                fi
                ;;
        esac
        # Holistic review: these commands remove installed versions or devices,
        # so apply enforces REVIEW even when a hand-edited plan says SAFE.
        if [[ "$action" == "native_command" && "$risk" == "SAFE" ]]; then
            case "$command" in
                "brew cleanup --prune=all"|"gem cleanup"|"xcrun simctl delete unavailable") risk="REVIEW" ;;
            esac
        fi
        # F2: --only / --category narrow an apply like every other mode. An op
        # of a category outside the selection is not loaded; it is journaled.
        if ! plan_category_allowed "$category" || ! _plan_section_selected "$category"; then
            cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "outside the --only/--category scope: ${category}" "$category"
            continue
        fi
        PLAN_OP_IDS+=("$id")
        PLAN_OP_CATEGORIES+=("$category")
        PLAN_OP_RISKS+=("$risk")
        PLAN_OP_ACTIONS+=("$action")
        PLAN_OP_PATHS+=("$path")
        PLAN_OP_COMMANDS+=("$command")
        PLAN_OP_BYTES+=("$bytes")
        PLAN_OP_DESCS+=("")
        PLAN_OP_RECS+=("")
        PLAN_OP_ROLLBACK+=("false")
        PLAN_OP_TOOLS+=("")
        PLAN_OP_IDENTITY+=("$identity")
        PLAN_OP_SCOPE+=("")
        PLAN_OP_LABELS+=("")
        PLAN_OP_FALLBACK+=("no")
    done 3< "$parsed_ops"
    rm -f "$parsed_ops"

    executor_run plan_file
}

# The executor runs the plan; it is loaded with the planner so every caller
# of apply_plan_file has it.
if ! type execute_ops >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/executor.sh"
fi
