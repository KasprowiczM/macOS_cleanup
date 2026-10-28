#!/usr/bin/env bash
# =============================================================================
# lib/interactive.sh — User confirmation & informed-consent prompts
#
# Design principle: every destructive action requires the user to see:
#   1. What will be deleted (list of paths + sizes)
#   2. What consequences to expect (e.g. "apps will re-create this on launch")
#   3. Whether there's a safety net (Time Machine, external backup, etc.)
#   4. An explicit confirmation prompt — no defaults that destroy data
#
# Bash 3.2 compatible — NEVER use ${var,,} or ${var^^}
# =============================================================================

# ---------------------------------------------------------------------------
# Prints detailed explanation of all cleanup categories (--explain)
# ---------------------------------------------------------------------------
explain_categories() {
    print_header "$(t "explain_title")"

    cat << EOF
▶ User Caches (user-caches)
  • $(t "user_caches_desc")
  • Risk: LOW
  • Quarantine: Full restore support via --restore.

▶ Developer Caches (dev)
  • $(t "dev_caches_desc")
  • Risk: LOW / MEDIUM
  • Quarantine: Quarantine moves assets for recovery.

▶ Xcode Device Support (dev / xcode)
  • $(t "xcode_support_desc")
  • Risk: HIGH
  • Quarantine: Manual verification recommended.

▶ Logs (user-logs / system-logs)
  • $(t "logs_desc")
  • Risk: LOW

▶ System Caches (system-caches)
  • $(t "system_caches_desc")
  • Risk: REPORT ONLY

▶ Docker (docker)
  • $(t "docker_desc")
  • Risk: HIGH
EOF
}

# ---------------------------------------------------------------------------
# Low-level yes/no prompt
# Returns 0 for yes, 1 for no.
# ---------------------------------------------------------------------------
ask_yes_no() {
    local question="$1"
    local default="${2:-no}"   # safe default is always "no"
    local prompt

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        if [[ "${AUTO_YES:-0}" == "1" ]]; then
            log_info "Non-interactive mode: AUTO_YES=1, auto-confirming prompt: ${question}"
            return 0
        fi
        log_info "Non-interactive mode: using default response '${default}' for: ${question}"
        [[ "$default" == "yes" ]] && return 0 || return 1
    fi

    if [[ "$default" == "yes" ]]; then
        prompt="${C_BOLD}[Y/n]${C_RESET}"
    else
        prompt="${C_BOLD}[y/N]${C_RESET}"
    fi

    while true; do
        echo -ne "  ${C_CYAN}?${C_RESET}  ${question} ${prompt} "
        read -r answer
        answer="${answer:-$default}"
        # bash 3.2 compatible lowercase: use tr instead of ${answer,,}
        local answer_lower
        answer_lower="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        case "$answer_lower" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)
                echo -e "  ${C_RED}✖${C_RESET}  $(t "prompt_yes_no_err")"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Returns human-readable consequence string based on risk level and mode.
# ---------------------------------------------------------------------------
consequence_for_mode() {
    local risk="${1:-REVIEW}"
    local mode="${2:-${REMOVE_MODE:-quarantine}}"

    if [[ "$mode" == "native" ]]; then
        t "consequence_native_irreversible"
        return
    fi

    # Normalize legacy risk strings
    case "$risk" in
        LOW)  risk="SAFE" ;;
        MEDIUM) risk="REVIEW" ;;
        HIGH) risk="DANGEROUS" ;;
    esac

    case "$risk" in
        SAFE)
            if [[ "$mode" == "quarantine" ]]; then
                t "consequence_safe_quarantine"
            else
                t "consequence_safe_permanent"
            fi
            ;;
        REVIEW)
            if [[ "$mode" == "quarantine" ]]; then
                t "consequence_review_quarantine"
            else
                t "consequence_review_permanent"
            fi
            ;;
        DANGEROUS|*)
            if [[ "$mode" == "quarantine" ]]; then
                t "consequence_dangerous_quarantine"
            else
                t "consequence_dangerous_permanent"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Full informed-consent confirmation for a cleanup category.
# ---------------------------------------------------------------------------
confirm_category() {
    local title="" size="" paths_str="" what="" consequence="" safe_if="" risk="REVIEW"
    local -a paths=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title)       title="$2";       shift 2 ;;
            --size)        size="$2";        shift 2 ;;
            --paths)       paths_str="$2";   shift 2 ;;
            --what)        what="$2";        shift 2 ;;
            --consequence) consequence="$2"; shift 2 ;;
            --safe-if)     safe_if="$2";     shift 2 ;;
            --risk)        risk="$2";        shift 2 ;;
            *)             shift ;;
        esac
    done

    # Normalize legacy risk labels
    case "$risk" in
        LOW)       risk="SAFE" ;;
        MEDIUM)    risk="REVIEW" ;;
        HIGH)      risk="DANGEROUS" ;;
        SAFE|REVIEW|DANGEROUS) ;;
        *)
            log_error "Unknown risk level '${risk}' for ${title} — failing closed as DANGEROUS"
            risk="DANGEROUS"
            ;;
    esac

    if [[ "$risk" == "DANGEROUS" ]]; then
        echo -e "${C_RED}✖  Category DANGEROUS (${title}): $(t "dangerous_blocked")${C_RESET}"
        record_user_decision "${title} (DANGEROUS - blocked)"
        log_info "DANGEROUS risk level blocked from interactive prompt: ${title}"
        return 1
    fi

    if [[ -z "$consequence" ]]; then
        consequence="$(consequence_for_mode "$risk" "${REMOVE_MODE:-quarantine}")"
    fi

    local -a paths=()
    local _oldIFS="${IFS}"
    IFS='|'
    for p in $paths_str; do
        paths[${#paths[@]}]="$p"
    done
    IFS="${_oldIFS}"

    # Risk colour and text
    local risk_color="$C_GREEN"
    [[ "$risk" == "REVIEW" ]] && risk_color="$C_YELLOW"
    [[ "$risk" == "DANGEROUS" ]] && risk_color="$C_RED"

    echo
    echo -e "${C_BOLD}${C_BLUE}┌─ ${title} ──────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Size:${C_RESET}       ${C_YELLOW}${size}${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Risk Level:${C_RESET} ${risk_color}${C_BOLD}${risk}${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"

    if [[ -n "$what" ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}What is this?${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${what}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    if [[ -n "$consequence" ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Consequences:${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${C_YELLOW}${consequence}${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    if [[ -n "$safe_if" ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Safe if:${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${C_GREEN}${safe_if}${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    if [[ ${#paths[@]} -gt 0 ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Paths to remove:${C_RESET}"
        for p in "${paths[@]}"; do
            [[ -z "$p" ]] && continue
            if [[ -e "$p" ]]; then
                local sz
                sz=$(path_size_human_memo "$p")
                echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${C_DIM}${p}${C_RESET}  ${C_YELLOW}(${sz})${C_RESET}"
            fi
        done
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    echo -e "${C_BOLD}${C_BLUE}└──────────────────────────────────────────────────────────────${C_RESET}"

    if [[ "${NON_INTERACTIVE:-0}" == "1" && "${AUTO_YES:-0}" == "1" && "$risk" != "SAFE" ]]; then
        print_skip "$(t "auto_yes_blocked") ${risk}: ${title}"
        record_skipped_item "${title} (requires interactive confirmation)"
        log_info "Non-interactive AUTO_YES blocked for ${risk} cleanup: ${title}"
        return 1
    fi

    if ask_yes_no "$(t "ask_clean_category") (${title})" "no"; then
        log_info "User approved cleanup: ${title}"
        return 0
    else
        print_skip "$(t "skipped_category"): ${title}"
        record_skipped_item "${title}"
        log_info "User skipped cleanup: ${title}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Time Machine specific confirmation — extra safety check
# ---------------------------------------------------------------------------
confirm_time_machine_snapshots() {
    local snapshots_list="$1"  # newline-separated list of snapshot names
    local total_size="$2"

    echo
    print_warning_box "$(t "time_machine_title")" \
        "$(t "time_machine_box_1")" \
        "$(t "time_machine_box_2")" \
        "$(t "time_machine_box_3")" \
        "" \
        "$(t "time_machine_box_4")" \
        "" \
        "$(t "time_machine_box_5"): ${total_size}" \
        "" \
        "$(t "time_machine_box_6")" \
        "$(t "time_machine_box_7")"

    echo -e "  ${C_BOLD}$(t "time_machine_found"):${C_RESET}"
    while IFS= read -r snap; do
        [[ -z "$snap" ]] && continue
        echo -e "    ${C_DIM}• ${snap}${C_RESET}"
    done <<< "$snapshots_list"
    echo

    if [[ "${NON_INTERACTIVE:-0}" == "1" && "${AUTO_YES:-0}" == "1" ]]; then
        print_skip "$(t "time_machine_interactive_req")"
        record_skipped_item "$(t "time_machine_title") ($(t "time_machine_interactive_req"))"
        return 1
    fi

    ask_yes_no "$(t "time_machine_prompt")" "no"
}

# ---------------------------------------------------------------------------
# iOS backup confirmation
# ---------------------------------------------------------------------------
confirm_ios_backups() {
    local backups_list="$1"
    local total_size="$2"

    print_warning_box "$(t "ios_backups_title")" \
        "$(t "ios_backups_box_1")" \
        "$(t "ios_backups_box_2")" \
        "$(t "ios_backups_box_3")" \
        "" \
        "Size: ${total_size}" \
        "" \
        "$(t "ios_backups_box_4")" \
        "$(t "ios_backups_box_5")"

    echo -e "  ${C_BOLD}$(t "ios_backups_found"):${C_RESET}"
    while IFS= read -r bk; do
        [[ -z "$bk" ]] && continue
        local bk_size
        bk_size=$(path_size_human_memo "$bk")
        echo -e "    ${C_DIM}• $(basename "$bk")${C_RESET}  ${C_YELLOW}(${bk_size})${C_RESET}"
    done <<< "$backups_list"
    echo

    if [[ "${NON_INTERACTIVE:-0}" == "1" && "${AUTO_YES:-0}" == "1" ]]; then
        print_skip "$(t "ios_backups_interactive_req")"
        record_skipped_item "$(t "ios_backups_title") ($(t "ios_backups_interactive_req"))"
        return 1
    fi

    ask_yes_no "$(t "ios_backups_prompt")" "no"
}

# ---------------------------------------------------------------------------
# Summary pause — show the user what would happen before committing
# ---------------------------------------------------------------------------
show_dry_run_summary() {
    local category="$1"
    local items_str="$2"   # pipe-separated "path|size" pairs
    local total_size="$3"

    echo
    echo -e "${C_BOLD}  $(t "dryrun_summary_title") – ${category}${C_RESET}"
    echo -e "${C_DIM}  ────────────────────────────────────────────────${C_RESET}"

    local -a items=()
    local _oldIFS="${IFS}"
    IFS='|'
    for it in $items_str; do
        items[${#items[@]}]="$it"
    done
    IFS="${_oldIFS}"
    for item in "${items[@]}"; do
        [[ -z "$item" ]] && continue
        echo -e "  ${C_DIM}→${C_RESET}  ${item}"
    done

    echo -e "${C_DIM}  ────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_BOLD}$(headline_total_label "dryrun_summary_total"): ${C_YELLOW}${total_size}${C_RESET}"
    echo
}

# ---------------------------------------------------------------------------
# Prompt to enter interactive mode after dry-run completes
# ---------------------------------------------------------------------------
ask_proceed_to_interactive() {
    echo
    echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}  $(t "proceed_interactive_title")${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
    echo
    echo -e "  $(headline_total_label "proceed_interactive_found"): ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")${C_RESET}"
    echo
    echo -e "  ${C_DIM}$(t "proceed_interactive_note_1")${C_RESET}"
    echo -e "  ${C_DIM}$(t "proceed_interactive_note_2")${C_RESET}"
    echo -e "  ${C_DIM}$(t "proceed_interactive_note_3")${C_RESET}"
    echo

    ask_yes_no "$(t "proceed_interactive_prompt")" "no"
}
