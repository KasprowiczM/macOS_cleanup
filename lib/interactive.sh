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
                echo -e "  ${C_RED}✖${C_RESET}  Wpisz 'y' (tak) lub 'n' (nie)."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Full informed-consent confirmation for a cleanup category.
#
# Usage:
#   confirm_category \
#       --title      "Xcode DerivedData" \
#       --size       "4.2 GB" \
#       --paths      "/Users/you/Library/Developer/Xcode/DerivedData" \
#       --what       "Compiled build artefacts created by Xcode." \
#       --consequence "Xcode will recompile your projects from scratch. First build after cleaning will take longer." \
#       --safe-if    "You can rebuild at any time; no source code is deleted." \
#       --risk       "LOW"
#
# Returns 0 if user approves, 1 if skipped.
# ---------------------------------------------------------------------------
confirm_category() {
    local title="" size="" paths_str="" what="" consequence="" safe_if="" risk="LOW"
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

    local -a paths=()
    local _oldIFS="${IFS}"
    IFS='|'
    for p in $paths_str; do
        paths[${#paths[@]}]="$p"
    done
    IFS="${_oldIFS}"

    # Risk colour
    local risk_color="$C_GREEN"
    [[ "$risk" == "MEDIUM" ]] && risk_color="$C_YELLOW"
    [[ "$risk" == "HIGH" ]]   && risk_color="$C_RED"

    echo
    echo -e "${C_BOLD}${C_BLUE}┌─ ${title} ──────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Rozmiar:${C_RESET}       ${C_YELLOW}${size}${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Ryzyko:${C_RESET}        ${risk_color}${risk}${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"

    if [[ -n "$what" ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Co to jest?${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${what}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    if [[ -n "$consequence" ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Skutki usunięcia:${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${C_YELLOW}${consequence}${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    if [[ -n "$safe_if" ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Bezpieczne jeśli:${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${C_GREEN}${safe_if}${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    if [[ ${#paths[@]} -gt 0 ]]; then
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}  ${C_BOLD}Ścieżki do usunięcia:${C_RESET}"
        for p in "${paths[@]}"; do
            [[ -z "$p" ]] && continue
            if [[ -e "$p" ]]; then
                local sz
                sz=$(path_size_human "$p")
                echo -e "${C_BOLD}${C_BLUE}│${C_RESET}    ${C_DIM}${p}${C_RESET}  ${C_YELLOW}(${sz})${C_RESET}"
            fi
        done
        echo -e "${C_BOLD}${C_BLUE}│${C_RESET}"
    fi

    echo -e "${C_BOLD}${C_BLUE}└──────────────────────────────────────────────────────────────${C_RESET}"

    if [[ "${NON_INTERACTIVE:-0}" == "1" && "${AUTO_YES:-0}" == "1" && "$risk" != "LOW" ]]; then
        print_skip "Automatyczne --yes nie zatwierdza ryzyka ${risk}: ${title}"
        record_skipped_item "${title} (wymaga interaktywnego potwierdzenia)"
        log_info "Non-interactive AUTO_YES blocked for ${risk} cleanup: ${title}"
        return 1
    fi

    if ask_yes_no "Czy chcesz wyczyścić tę kategorię? (${title})" "no"; then
        log_info "User approved cleanup: ${title}"
        return 0
    else
        print_skip "Pominięto: ${title}"
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
    print_warning_box "Lokalne snapshoty Time Machine" \
        "Te dane to lokalne kopie bezpieczeństwa Twojego systemu." \
        "Mogą być potrzebne do odtworzenia plików, które usunąłeś" \
        "lub zmieniłeś PRZED ostatnim backupem na dysk zewnętrzny." \
        "" \
        "UWAGA: Snapshoty są trwale usuwane (nie podlegają kwarantannie)." \
        "" \
        "Rozmiar: ${total_size}" \
        "" \
        "WAŻNE: macOS usuwa snapshoty automatycznie, gdy" \
        "brakuje miejsca na dysku (mechanizm APFS purge)."

    echo -e "  ${C_BOLD}Znalezione snapshoty:${C_RESET}"
    while IFS= read -r snap; do
        [[ -z "$snap" ]] && continue
        echo -e "    ${C_DIM}• ${snap}${C_RESET}"
    done <<< "$snapshots_list"
    echo

    if [[ "${NON_INTERACTIVE:-0}" == "1" && "${AUTO_YES:-0}" == "1" ]]; then
        print_skip "Snapshoty Time Machine wymagają interaktywnego potwierdzenia."
        record_skipped_item "Lokalne snapshoty Time Machine (wymagają interaktywnego potwierdzenia)"
        return 1
    fi

    ask_yes_no "Czy potwierdzasz, że masz aktualny backup na dysku zewnętrznym i chcesz usunąć lokalne snapshoty?" "no"
}

# ---------------------------------------------------------------------------
# iOS backup confirmation
# ---------------------------------------------------------------------------
confirm_ios_backups() {
    local backups_list="$1"
    local total_size="$2"

    print_warning_box "Lokalne backupy iOS/iPadOS/watchOS" \
        "To są kopie Twoich iPhone / iPad / Apple Watch." \
        "Po usunięciu nie odtworzysz zawartości urządzenia" \
        "bez nowego backupu (iTunes/Finder lub iCloud)." \
        "" \
        "Rozmiar: ${total_size}" \
        "" \
        "Bezpieczne TYLKO jeśli masz backup w iCloud LUB" \
        "właśnie zrobiłeś backup w Finderze i nie potrzebujesz" \
        "odtwarzać urządzeń z tego komputera."

    echo -e "  ${C_BOLD}Znalezione backupy:${C_RESET}"
    while IFS= read -r bk; do
        [[ -z "$bk" ]] && continue
        local bk_size
        bk_size=$(path_size_human "$bk")
        echo -e "    ${C_DIM}• $(basename "$bk")${C_RESET}  ${C_YELLOW}(${bk_size})${C_RESET}"
    done <<< "$backups_list"
    echo

    if [[ "${NON_INTERACTIVE:-0}" == "1" && "${AUTO_YES:-0}" == "1" ]]; then
        print_skip "Backupy iOS wymagają interaktywnego potwierdzenia."
        record_skipped_item "Backupy iOS (wymagają interaktywnego potwierdzenia)"
        return 1
    fi

    ask_yes_no "Rozumiem ryzyko i chcę usunąć wybrane backupy iOS?" "no"
}

# ---------------------------------------------------------------------------
# Summary pause — show the user what would happen before committing
# ---------------------------------------------------------------------------
show_dry_run_summary() {
    local category="$1"
    local items_str="$2"   # pipe-separated "path|size" pairs
    local total_size="$3"

    echo
    echo -e "${C_BOLD}  Analiza – ${category}${C_RESET}"
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
    echo -e "  ${C_BOLD}Łącznie do zwolnienia: ${C_YELLOW}${total_size}${C_RESET}"
    echo
}

# ---------------------------------------------------------------------------
# Prompt to enter interactive mode after dry-run completes
# ---------------------------------------------------------------------------
ask_proceed_to_interactive() {
    echo
    echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}  Analiza zakończona. Czas na czyszczenie?${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
    echo
    echo -e "  Skrypt znalazł do zwolnienia: ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")${C_RESET}"
    echo
    echo -e "  ${C_DIM}Jeśli odpowiesz 'tak', przejdziemy przez każdą kategorię${C_RESET}"
    echo -e "  ${C_DIM}osobno — zobaczysz ostrzeżenia i będziesz mógł decydować.${C_RESET}"
    echo -e "  ${C_DIM}Domyślna odpowiedź to zawsze NIE — bezpiecznie naciśnij Enter.${C_RESET}"
    echo

    ask_yes_no "Chcesz teraz przejść do interaktywnego czyszczenia?" "no"
}
