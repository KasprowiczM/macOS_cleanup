#!/usr/bin/env bash
# =============================================================================
# lib/cleaner.sh — Cleanup execution engine
#
# Every clean_* function:
#   1. Checks if there's anything to clean
#   2. Shows what it's about to do with full consequences
#   3. Asks for confirmation (in interactive mode)
#   4. Only then calls safe_remove() or native tool commands
#
# DRY_RUN=1 means: analyse, report, but don't touch anything.
# Bash 3.2 compatible.
# =============================================================================

# Ensure policy functions are available for risk calculations
if ! command -v policy_adjust_risk_for_path >/dev/null 2>&1; then
    _CLEANER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    if [[ -f "${_CLEANER_LIB_DIR}/policy.sh" ]]; then
        # shellcheck disable=SC1091
        source "${_CLEANER_LIB_DIR}/policy.sh"
    fi
fi

# ---------------------------------------------------------------------------
# category_max_risk <path> [<path>...] → SAFE | REVIEW | DANGEROUS
# Returns the highest policy risk across all passed target paths.
# ---------------------------------------------------------------------------
category_max_risk() {
    local max_risk="SAFE"
    local max_rank=1
    local p risk rank

    for p in "$@"; do
        [[ -z "$p" ]] && continue
        risk="$(policy_adjust_risk_for_path "$p" "REVIEW")"
        rank="$(policy_risk_rank "$risk")"
        if (( rank > max_rank )); then
            max_rank="$rank"
            max_risk="$risk"
        fi
    done

    echo "$max_risk"
}

# ---------------------------------------------------------------------------
# clean_trash — ~/.Trash
# Simplest and safest cleanup — always offer first
# ---------------------------------------------------------------------------
clean_trash() {
    local trash_bytes
    trash_bytes=$(catbytes_get "trash")
    [[ "$trash_bytes" -eq 0 ]] && return
    [[ ${#FOUND_TRASH_ITEMS[@]} -eq 0 ]] && return

    local total_h
    total_h=$(bytes_to_human "$trash_bytes")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "${FOUND_TRASH_ITEMS[@]}")"
        confirm_category \
            --title      "$(t "trash") (~/.Trash)" \
            --size       "$total_h" \
            --what       "$(t "clean_trash_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "$(t "clean_trash_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: $(t "trash")"
    # Remove contents, not the .Trash directory itself
    for item in "${FOUND_TRASH_ITEMS[@]}"; do
        safe_remove "$item"
    done
}

# ---------------------------------------------------------------------------
# clean_user_caches
# ---------------------------------------------------------------------------
clean_user_caches() {
    [[ ${#FOUND_USER_CACHES[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "user-caches")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local paths_str cat_risk
        paths_str=$(printf '%s|' "${FOUND_USER_CACHES[@]}")
        cat_risk="$(category_max_risk "${FOUND_USER_CACHES[@]}")"

        confirm_category \
            --title      "$(t "user_caches") (~/Library/Caches)" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "$(t "clean_user_cache_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "$(t "clean_user_cache_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: $(t "user_caches")"
    for path in "${FOUND_USER_CACHES[@]}"; do
        safe_remove "$path"
    done
}

# ---------------------------------------------------------------------------
# clean_app_specific_caches — Electron, JetBrains, Adobe, etc. (Split SAFE / REVIEW)
# ---------------------------------------------------------------------------
clean_app_specific_caches() {
    [[ ${#FOUND_APP_CACHE_ITEMS[@]} -eq 0 ]] && return

    local -a safe_entries=()
    local -a review_entries=()
    local entry label path

    for entry in "${FOUND_APP_CACHE_ITEMS[@]}"; do
        label="${entry%%:*}"
        path="${entry#*:}"
        [[ -d "$path" ]] || continue
        if app_cache_auto_safe "$label"; then
            safe_entries+=("$entry")
        else
            review_entries+=("$entry")
        fi
    done

    # 1. Process SAFE (allowlisted) app cache items
    if [[ ${#safe_entries[@]} -gt 0 ]]; then
        local safe_bytes=0 safe_h paths_str cat_risk
        local -a safe_paths=()
        for entry in "${safe_entries[@]}"; do
            path="${entry#*:}"
            safe_paths+=("$path")
            safe_bytes=$(( safe_bytes + $(path_size_bytes "$path") ))
        done
        safe_h=$(bytes_to_human "$safe_bytes")
        paths_str=$(printf '%s|' "${safe_paths[@]}")
        cat_risk="$(category_max_risk "${safe_paths[@]}")"

        if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
            confirm_category \
                --title      "$(t "app_caches") allowlisted (SAFE)" \
                --size       "$safe_h" \
                --paths      "$paths_str" \
                --what       "$(t "clean_auto_safe_what")" \
                --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
                --safe-if    "$(t "clean_auto_safe_safe_if")" \
                --risk       "$cat_risk" || return 0
        fi

        for path in "${safe_paths[@]}"; do
            safe_remove "$path"
        done
    fi

    # 2. Process REVIEW (non-allowlisted) app cache items itemized with policy recommendations
    if [[ ${#review_entries[@]} -gt 0 ]]; then
        local review_bytes=0 review_h paths_str cat_risk
        local -a review_paths=()
        for entry in "${review_entries[@]}"; do
            label="${entry%%:*}"
            path="${entry#*:}"
            review_paths+=("$path")
            review_bytes=$(( review_bytes + $(path_size_bytes "$path") ))
        done
        review_h=$(bytes_to_human "$review_bytes")
        paths_str=$(printf '%s|' "${review_paths[@]}")
        cat_risk="$(category_max_risk "${review_paths[@]}")"

        if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
            echo
            echo -e "  ${C_BOLD}$(t "category_review_title") (${#review_entries[@]}):${C_RESET}"
            for entry in "${review_entries[@]}"; do
                label="${entry%%:*}"
                path="${entry#*:}"
                local desc rec item_sz
                desc="$(app_cache_description "$label")"
                rec="$(app_cache_recommendation "$label")"
                item_sz="$(path_size_human "$path")"
                echo -e "    ${C_YELLOW}• ${label}${C_RESET} (${item_sz})"
                echo -e "      ${C_DIM}Path: ${path}${C_RESET}"
                echo -e "      ${C_DIM}${desc}${C_RESET}"
                echo -e "      ${C_CYAN}${rec}${C_RESET}"
            done

            confirm_category \
                --title      "$(t "category_review_title")" \
                --size       "$review_h" \
                --paths      "$paths_str" \
                --what       "$(t "category_review_what")" \
                --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
                --safe-if    "$(t "category_review_safe_if")" \
                --risk       "$cat_risk" || return 0
        fi

        for path in "${review_paths[@]}"; do
            safe_remove "$path"
        done
    fi
}

# ---------------------------------------------------------------------------
# clean_system_caches — REPORT ONLY
# P0-1 fix: /Library/Caches children are NEVER deleted automatically.
# ---------------------------------------------------------------------------
clean_system_caches() {
    [[ ${#FOUND_SYSTEM_CACHES[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "system-caches")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    print_section "Report: $(t "system_caches")"
    print_info "Size: ${total_h}"
    print_info "$(t "system_cache_notice_1")"
    print_info "$(t "system_cache_notice_2")"

    record_user_decision "System Caches: ${total_h} — report-only; SIP/system managed"
    print_skip "System Caches (/Library/Caches) report-only."
}

# ---------------------------------------------------------------------------
# clean_logs
# ---------------------------------------------------------------------------
clean_logs() {
    local total_count=$(( ${#FOUND_USER_LOGS[@]} + ${#FOUND_SYSTEM_LOGS[@]} ))
    [[ $total_count -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "logs")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    local -a all_logs=("${FOUND_USER_LOGS[@]}" "${FOUND_SYSTEM_LOGS[@]}")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local paths_str cat_risk
        paths_str=$(printf '%s|' "${all_logs[@]}")
        cat_risk="$(category_max_risk "${all_logs[@]}")"

        confirm_category \
            --title      "Log files (> $LOG_MAX_AGE_DAYS days)" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "$(t "clean_logs_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "$(t "clean_logs_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: logs"
    for log_file in "${all_logs[@]}"; do
        safe_remove "$log_file"
    done
}

# ---------------------------------------------------------------------------
# clean_diagnostic_reports
# ---------------------------------------------------------------------------
clean_diagnostic_reports() {
    [[ ${#FOUND_CRASH_REPORTS[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "diagnostic-reports")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local paths_str cat_risk
        paths_str=$(printf '%s|' "${FOUND_CRASH_REPORTS[@]}")
        cat_risk="$(category_max_risk "${FOUND_CRASH_REPORTS[@]}")"

        confirm_category \
            --title      "Diagnostic Reports / Crash Logs" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "$(t "clean_crash_logs_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "$(t "clean_crash_logs_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: diagnostic reports"
    for f in "${FOUND_CRASH_REPORTS[@]}"; do
        safe_remove "$f"
    done
}

# ---------------------------------------------------------------------------
# clean_tmp — /tmp and /private/tmp files (> TMP_MAX_AGE_HOURS h)
# ---------------------------------------------------------------------------
clean_tmp() {
    [[ ${#FOUND_TMP_FILES[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "tmp")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local paths_str cat_risk
        paths_str=$(printf '%s|' "${FOUND_TMP_FILES[@]}")
        cat_risk="$(category_max_risk "${FOUND_TMP_FILES[@]}")"

        confirm_category \
            --title      "Temporary files (/tmp)" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "$(t "clean_tmp_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "$(t "clean_tmp_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: temporary files (/tmp)"
    for f in "${FOUND_TMP_FILES[@]}"; do
        safe_remove "$f"
    done
}

# ---------------------------------------------------------------------------
# clean_app_leftovers — REPORT ONLY
# ---------------------------------------------------------------------------
clean_app_leftovers() {
    [[ ${#FOUND_APP_LEFTOVERS[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "app-leftovers")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    print_warning_box "$(t "app_leftovers_box_title")" \
        "$(t "app_leftovers_box_1")" \
        "applications. Verify before deletion!" \
        "$(t "app_leftovers_box_2")" \
        "$(t "app_leftovers_box_3")"

    print_section "Report: App leftovers (${total_h})"
    for item in "${FOUND_APP_LEFTOVERS[@]}"; do
        echo "  - $item"
    done

    record_user_decision "App leftovers: ${total_h} — $(t "app_leftovers_rec")"
    print_skip "$(t "app_leftovers_skip")"
}

# ---------------------------------------------------------------------------
# Developer tools cleaners
# ---------------------------------------------------------------------------

clean_xcode_derived_data() {
    [[ -z "${FOUND_DERIVED_DATA:-}" ]] && return

    local size_h
    size_h=$(path_size_human "$FOUND_DERIVED_DATA")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "$FOUND_DERIVED_DATA")"
        confirm_category \
            --title      "Xcode DerivedData" \
            --size       "$size_h" \
            --paths      "$FOUND_DERIVED_DATA" \
            --what       "$(t "xcode_derived_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Safe if you accept longer build time for the next build." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: Xcode DerivedData"
    safe_remove "$FOUND_DERIVED_DATA"
}

clean_ios_device_support() {
    [[ ${#FOUND_DEVICE_SUPPORT[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "xcode-device-support")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")
    local paths_str
    paths_str=$(printf '%s|' "${FOUND_DEVICE_SUPPORT[@]}")

    print_warning_box "$(t "xcode_support_box_title")" \
        "$(t "xcode_support_box_1")" \
        "$(t "xcode_support_box_2")" \
        "$(t "xcode_support_box_3")" \
        "" \
        "$(t "xcode_support_box_4")" \
        "$(t "xcode_support_box_5")"

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "${FOUND_DEVICE_SUPPORT[@]}")"
        confirm_category \
            --title      "$(t "xcode_support_box_title")" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "$(t "xcode_support_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "$(t "xcode_support_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: iOS DeviceSupport"
    for item in "${FOUND_DEVICE_SUPPORT[@]}"; do
        safe_remove "$item"
    done
}

clean_xcode_simulators() {
    local has_sims=0
    for item in "${FOUND_DEV_ITEMS[@]}"; do
        [[ "$item" == "simulators:__unavailable__" ]] && has_sims=1 && break
    done
    [[ $has_sims -eq 0 ]] && return

    local size_h
    size_h=$(bytes_to_human "$(catbytes_get "simulators")")

    print_warning_box "iOS Simulators" \
        "$(t "simulators_box_1")" \
        "$(t "simulators_box_2")"

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "simulators")"
        confirm_category \
            --title      "Unavailable iOS Simulators" \
            --size       "$size_h" \
            --what       "$(t "simulators_what")" \
            --consequence "$(consequence_for_mode "$cat_risk" "native")" \
            --safe-if    "$(t "simulators_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: iOS Simulators"
    if [[ "$DRY_RUN" == "1" ]]; then
        print_dry "Would run: xcrun simctl delete unavailable"
        record_native_command_event "xcrun simctl delete unavailable" "planned" "$(catbytes_get "simulators")" "dry-run"
    else
        if command -v xcrun &>/dev/null; then
            if xcrun simctl delete unavailable 2>/dev/null; then
                print_cleaned "$(t "simulators_success")"
                record_native_command_event "xcrun simctl delete unavailable" "ok" "$(catbytes_get "simulators")" ""
            else
                record_native_command_event "xcrun simctl delete unavailable" "failed" "$(catbytes_get "simulators")" "xcrun failed"
                print_warn "$(t "simulators_simctl_err")"
            fi
        else
            record_native_command_event "xcrun simctl delete unavailable" "skipped" "$(catbytes_get "simulators")" "xcrun unavailable"
            print_warn "$(t "simulators_xcrun_err")"
        fi
    fi
}

clean_dev_review_only_items() {
    [[ ${#FOUND_DEV_ITEMS[@]} -eq 0 ]] && return

    local item key path total_h
    for item in "${FOUND_DEV_ITEMS[@]}"; do
        key="${item%%:*}"
        path="${item#*:}"
        total_h=$(path_size_human "$path")

        case "$key" in
            xcode_archives)
                record_user_decision "Xcode Archives: ${total_h} — $(t "archives_rec")"
                ;;
            maven_cache)
                record_user_decision "Maven ~/.m2/repository: ${total_h} — $(t "maven_rec")"
                ;;
            android_avd)
                record_user_decision "Android AVD: ${total_h} — $(t "android_avd_rec")"
                ;;
        esac
    done
}

# Helper for dev native commands with fallback to safe_remove
_clean_dev_native_or_fallback() {
    local cmd="$1" check_cmd="$2" tool_label="$3" _item_label="$4" ok_msg="$5" path="$6"
    local size_h
    size_h=$(path_size_human "$path")

    if [[ "$DRY_RUN" == "1" ]]; then
        print_dry "Would run: ${cmd}  (${size_h})"
        record_native_command_event "$cmd" "planned" "$(path_size_bytes "$path")" "dry-run"
    else
        if command -v "$check_cmd" &>/dev/null; then
            print_cleaned "$(t "cleaning_cmd"): ${tool_label} (${cmd})"
            if $cmd 2>/dev/null; then
                print_ok "$ok_msg"
                record_native_command_event "$cmd" "ok" "$(path_size_bytes "$path")" ""
            else
                record_native_command_event "$cmd" "failed" "$(path_size_bytes "$path")" "${tool_label} failed; fallback safe_remove"
                safe_remove "$path"
            fi
        else
            record_native_command_event "$cmd" "skipped" "$(path_size_bytes "$path")" "${tool_label} unavailable; fallback safe_remove"
            safe_remove "$path"
        fi
    fi
}

clean_dev_caches() {
    [[ ${#FOUND_DEV_ITEMS[@]} -eq 0 ]] && return

    local -a cleanable_items=()
    local item key path
    for item in "${FOUND_DEV_ITEMS[@]}"; do
        key="${item%%:*}"
        path="${item#*:}"

        case "$key" in
            npm_cache|yarn_cache|pnpm_cache|pip_cache|brew_cache|brew_cleanup|gradle_cache|cargo_cache|cocoapods_cache|gem_cache)
                cleanable_items+=("$item")
                ;;
        esac
    done

    [[ ${#cleanable_items[@]} -eq 0 ]] && return

    local total_bytes=0 total_h paths_str cat_risk
    local -a item_paths=()
    for item in "${cleanable_items[@]}"; do
        path="${item#*:}"
        [[ "$path" != "__brew__" ]] && item_paths+=("$path")
        total_bytes=$(( total_bytes + $(path_size_bytes "$path") ))
    done
    total_h=$(bytes_to_human "$total_bytes")
    paths_str=$(printf '%s|' "${item_paths[@]}")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        echo
        echo -e "  ${C_BOLD}$(t "package_managers_title"):${C_RESET}"
        for item in "${cleanable_items[@]}"; do
            key="${item%%:*}"
            path="${item#*:}"
            [[ "$path" != "__brew__" ]] && echo -e "    ${C_DIM}• ${key}: ${path}${C_RESET}"
        done

        cat_risk="$(category_max_risk "${item_paths[@]}")"
        confirm_category \
            --title      "$(t "package_managers_title")" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "Package manager caches for development tools." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "$(t "package_managers_safe_if")" \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: $(t "package_managers_title")"

    for item in "${cleanable_items[@]}"; do
        key="${item%%:*}"
        path="${item#*:}"

        case "$key" in
            npm_cache)
                _clean_dev_native_or_fallback \
                    "npm cache clean --force" "npm" "npm" \
                    "npm cache" "npm cache clean complete." "$path"
                ;;
            yarn_cache)
                _clean_dev_native_or_fallback \
                    "yarn cache clean" "yarn" "yarn" \
                    "yarn cache" "yarn cache clean complete." "$path"
                ;;
            pnpm_cache)
                _clean_dev_native_or_fallback \
                    "pnpm store prune" "pnpm" "pnpm" \
                    "pnpm store" "$(t "pnpm_store_trimmed")" "$path"
                ;;
            brew_cache|brew_cleanup)
                if [[ "$DRY_RUN" == "1" ]]; then
                    if [[ "$path" == "__brew__" ]]; then
                        print_dry "Would run: brew cleanup --prune=all  ($(bytes_to_human "$(catbytes_get "brew-stale")"))"
                    else
                        print_dry "Would run: brew cleanup --prune=all  ($(path_size_human "$path"))"
                    fi
                    record_native_command_event "brew cleanup --prune=all" "planned" "$(catbytes_get "brew-stale")" "dry-run"
                else
                    print_cleaned "$(t "cleaning_cmd"): Homebrew (brew cleanup --prune=all)"
                    if command -v brew &>/dev/null; then
                        if brew cleanup --prune=all 2>/dev/null; then
                            print_ok "Homebrew cleanup complete."
                            record_native_command_event "brew cleanup --prune=all" "ok" "$(catbytes_get "brew-stale")" ""
                        else
                            record_native_command_event "brew cleanup --prune=all" "failed" "$(catbytes_get "brew-stale")" "brew cleanup failed"
                            [[ "$path" != "__brew__" ]] && safe_remove "$path"
                        fi
                    else
                        record_native_command_event "brew cleanup --prune=all" "skipped" "$(catbytes_get "brew-stale")" "brew unavailable"
                        [[ "$path" != "__brew__" ]] && safe_remove "$path"
                    fi
                fi
                ;;
            pip_cache)
                if [[ "$DRY_RUN" == "1" ]]; then
                    print_dry "Would run: pip cache purge  ($(path_size_human "$path"))"
                    record_native_command_event "pip cache purge" "planned" "$(catbytes_get "pip")" "dry-run"
                else
                    print_cleaned "$(t "cleaning_cmd"): pip cache (pip cache purge)"
                    local pip_cmd=""
                    command -v pip3 &>/dev/null && pip_cmd="pip3"
                    command -v pip  &>/dev/null && pip_cmd="pip"
                    if [[ -n "$pip_cmd" ]]; then
                        if $pip_cmd cache purge 2>/dev/null; then
                            print_ok "pip cache purge complete."
                            record_native_command_event "${pip_cmd} cache purge" "ok" "$(catbytes_get "pip")" ""
                        else
                            record_native_command_event "${pip_cmd} cache purge" "failed" "$(catbytes_get "pip")" "pip failed; fallback safe_remove"
                            safe_remove "$path"
                        fi
                    else
                        record_native_command_event "pip cache purge" "skipped" "$(catbytes_get "pip")" "pip unavailable; fallback safe_remove"
                        safe_remove "$path"
                    fi
                fi
                ;;
            gem_cache)
                _clean_dev_native_or_fallback \
                    "gem cleanup" "gem" "gem" \
                    "Ruby gems" "Ruby gems cleanup complete." "$path"
                ;;
            *)
                [[ -d "$path" || -f "$path" ]] && safe_remove "$path"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# clean_docker
# ---------------------------------------------------------------------------
clean_docker() {
    local has_docker=0
    for item in "${FOUND_DEV_ITEMS[@]}"; do
        [[ "$item" == "docker_prune:__docker__" ]] && has_docker=1 && break
    done
    [[ $has_docker -eq 0 ]] && return

    local size_h
    size_h=$(bytes_to_human "$(catbytes_get "docker")")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "docker")"
        confirm_category \
            --title      "Docker: dangling images / stopped containers" \
            --size       "$size_h" \
            --what       "Unused images, stopped containers, networks, and build cache removed by docker system prune." \
            --consequence "$(consequence_for_mode "$cat_risk" "native")" \
            --safe-if    "Safe if you do not have important data in stopped containers." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: Docker (system prune)"
    if [[ "$DRY_RUN" == "1" ]]; then
        print_dry "Would run: docker system prune -f"
        record_native_command_event "docker system prune -f" "planned" "$(catbytes_get "docker")" "dry-run"
    else
        if command -v docker &>/dev/null; then
            if docker system prune -f 2>/dev/null; then
                print_cleaned "Docker system prune complete."
                record_native_command_event "docker system prune -f" "ok" "$(catbytes_get "docker")" ""
            else
                record_native_command_event "docker system prune -f" "failed" "$(catbytes_get "docker")" "docker prune failed"
                print_warn "docker system prune failed or Docker is not running."
            fi
        else
            record_native_command_event "docker system prune -f" "skipped" "$(catbytes_get "docker")" "docker unavailable"
            print_warn "docker is not available."
        fi
    fi
}

# ---------------------------------------------------------------------------
# clean_time_machine_snapshots
# ---------------------------------------------------------------------------
clean_time_machine_snapshots() {
    [[ ${#FOUND_TM_SNAPSHOTS[@]} -eq 0 ]] && return

    local count=${#FOUND_TM_SNAPSHOTS[@]}
    local snapshots_str
    snapshots_str=$(printf '%s\n' "${FOUND_TM_SNAPSHOTS[@]}")

    if ! confirm_time_machine_snapshots "$snapshots_str" "${count} snapshots"; then
        print_skip "$(t "skipped_category"): local Time Machine snapshots"
        record_skipped_item "Local Time Machine snapshots"
        return
    fi

    print_section "Cleaning: local Time Machine snapshots"

    for snap in "${FOUND_TM_SNAPSHOTS[@]}"; do
        [[ -z "$snap" ]] && continue
        # Extract full datetime from snapshot name: com.apple.TimeMachine.2026-04-17-131903.local
        local snap_date=""
        snap_date=$(echo "$snap" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1) || snap_date=""

        if [[ -z "$snap_date" ]]; then
            print_warn "Could not parse date from snapshot: $snap"
            continue
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            print_dry "Would run: tmutil deletelocalsnapshots $snap_date"
            record_native_command_event "tmutil deletelocalsnapshots ${snap_date}" "planned" 0 "dry-run"
        else
            print_info "Removing snapshot: $snap_date"
            local tm_out
            if tm_out=$(tmutil deletelocalsnapshots "$snap_date" 2>&1); then
                print_cleaned "Removed snapshot: $snap_date"
                record_native_command_event "tmutil deletelocalsnapshots ${snap_date}" "ok" 0 ""
            else
                record_native_command_event "tmutil deletelocalsnapshots ${snap_date}" "failed" 0 "tmutil failed"
                print_warn "Failed to remove: $snap_date"
                print_warn "  Reason: $tm_out"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# clean_ios_backups
# ---------------------------------------------------------------------------
clean_ios_backups() {
    [[ ${#FOUND_IOS_BACKUPS[@]} -eq 0 ]] && return

    local backups_str
    backups_str=$(printf '%s\n' "${FOUND_IOS_BACKUPS[@]}")
    local total_h
    total_h=$(bytes_to_human "$(catbytes_get "ios-backups")")

    if ! confirm_ios_backups "$backups_str" "$total_h"; then
        print_skip "$(t "skipped_category"): iOS backups"
        record_skipped_item "Local iOS backups (category cancelled by user)"
        return
    fi

    print_section "Cleaning: iOS backups (one by one)"
    for backup_dir in "${FOUND_IOS_BACKUPS[@]}"; do
        [[ -d "$backup_dir" ]] || continue
        local device_name
        device_name="$(t "unknown_device")"
        local info_plist="${backup_dir}/Info.plist"
        [[ -f "$info_plist" ]] && \
            device_name=$(defaults read "$info_plist" "Device Name" 2>/dev/null || echo "$(t "unknown_device")")

        local bk_size
        bk_size=$(path_size_human "$backup_dir")
        echo
        if ask_yes_no "Remove backup: '${device_name}' (${bk_size})?" "no"; then
            safe_remove "$backup_dir"
        else
            print_skip "Kept backup: $device_name"
            record_skipped_item "iOS backup retained: ${device_name}"
        fi
    done
}

# ---------------------------------------------------------------------------
# clean_dmg_pkg — old installers
# ---------------------------------------------------------------------------
clean_dmg_pkg() {
    [[ ${#FOUND_DMG_PKG[@]} -eq 0 ]] && return

    local total_h
    total_h=$(bytes_to_human "$(catbytes_get "installers")")
    local paths_str
    paths_str=$(printf '%s|' "${FOUND_DMG_PKG[@]}")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "${FOUND_DMG_PKG[@]}")"
        confirm_category \
            --title      "Old installers (DMG/PKG/ISO)" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "$(t "downloads_ok")" \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Safe if you have internet access or do not need old versions." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Cleaning: old installers"
    for f in "${FOUND_DMG_PKG[@]}"; do
        safe_remove "$f"
    done
}

# ---------------------------------------------------------------------------
# SF2: _run_cleaner — isolate cleaner failures (mirrors _run_analyzer)
# ---------------------------------------------------------------------------
_run_cleaner() {
    local fn="$1"
    "$fn" || {
        print_warn "Cleaner '${fn}' failed (skipping, continuing)."
        log_warn "Cleaner function '${fn}' failed — continuing."
    }
}

# ---------------------------------------------------------------------------
# run_cleanup — orchestrate all cleaners
# ---------------------------------------------------------------------------
run_cleanup() {
    local categories=("$@")
    if (( ${#categories[@]} == 0 )); then
        categories=("${ALL_CATEGORIES[@]}")
    fi

    for cat in "${categories[@]}"; do
        case "$cat" in
            trash)         _run_cleaner clean_trash ;;
            system)        _run_cleaner clean_system_caches ; _run_cleaner clean_tmp ;;
            user-caches)   _run_cleaner clean_user_caches ; _run_cleaner clean_app_specific_caches ;;
            logs)          _run_cleaner clean_logs ; _run_cleaner clean_diagnostic_reports ;;
            app-leftovers) _run_cleaner clean_app_leftovers ;;
            dev)           _run_cleaner clean_xcode_derived_data
                           _run_cleaner clean_ios_device_support
                           _run_cleaner clean_xcode_simulators
                           _run_cleaner clean_dev_review_only_items
                           _run_cleaner clean_dev_caches
                           _run_cleaner clean_docker ;;
            time-machine)  _run_cleaner clean_time_machine_snapshots ; _run_cleaner clean_ios_backups ;;
            large-files)   _run_cleaner clean_dmg_pkg ;;
            *)             print_warn "Unknown category: $cat" ;;
        esac
    done
}
