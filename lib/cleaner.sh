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
            --title      "Kosz (~/.Trash)" \
            --size       "$total_h" \
            --what       "Pliki w Koszu systemu macOS. To są rzeczy, które wcześniej usunąłeś, ale nie opróżniłeś Kosza." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Bezpieczne jeśli celowo usunąłeś te pliki i nie potrzebujesz ich odtwarzać." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: Kosz"
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
            --title      "Cache użytkownika (~/Library/Caches)" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "Pliki cache tworzone przez aplikacje w ~/Library/Caches. Służą do przyspieszenia działania programów." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Większość cache jest odtwarzalna po podaniu akceptacji w trybie kwarantanny." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: cache użytkownika"
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
                --title      "Cache aplikacji allowlisted (SAFE)" \
                --size       "$safe_h" \
                --paths      "$paths_str" \
                --what       "Pamięć podręczna znanych aplikacji z listy auto-safe (Slack, VS Code, Discord, Zoom, Spotify...)." \
                --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
                --safe-if    "Aplikacje odtworzą te pliki automatycznie po ponownym uruchomieniu." \
                --risk       "$cat_risk" && {
                print_section "Czyszczenie: cache aplikacji (SAFE)"
                for entry in "${safe_entries[@]}"; do
                    safe_remove "${entry#*:}"
                done
            }
        else
            print_section "Czyszczenie: cache aplikacji (SAFE)"
            for entry in "${safe_entries[@]}"; do
                safe_remove "${entry#*:}"
            done
        fi
    fi

    # 2. Process REVIEW (non-allowlisted) app cache items
    if [[ ${#review_entries[@]} -gt 0 ]]; then
        local review_bytes=0 review_h paths_str cat_risk
        local -a review_paths=()
        for entry in "${review_entries[@]}"; do
            path="${entry#*:}"
            review_paths+=("$path")
            review_bytes=$(( review_bytes + $(path_size_bytes "$path") ))
        done
        review_h=$(bytes_to_human "$review_bytes")
        paths_str=$(printf '%s|' "${review_paths[@]}")
        cat_risk="$(category_max_risk "${review_paths[@]}")"

        if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
            echo -e "  ${C_BOLD}Cache aplikacji wymagające przeglądu (${#review_entries[@]}):${C_RESET}"
            for entry in "${review_entries[@]}"; do
                label="${entry%%:*}"
                path="${entry#*:}"
                printf "    %8s  %s\n" "$(path_size_human "$path")" "$label"
                echo -e "              ${C_DIM}Opis: $(app_cache_description "$label")${C_RESET}"
                echo -e "              ${C_YELLOW}Rekomendacja: $(app_cache_recommendation "$label")${C_RESET}"
            done
            echo

            confirm_category \
                --title      "Cache aplikacji wymagające przeglądu (REVIEW)" \
                --size       "$review_h" \
                --paths      "$paths_str" \
                --what       "Zasoby cache aplikacji wymagające świadomej zgody (np. Adobe Media Cache, JetBrains, Figma)." \
                --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
                --safe-if    "Przejrzyj rekomendacje dla poszczególnych aplikacji powyżej." \
                --risk       "$cat_risk" && {
                print_section "Czyszczenie: cache aplikacji (REVIEW)"
                for entry in "${review_entries[@]}"; do
                    safe_remove "${entry#*:}"
                done
            }
        else
            print_section "Czyszczenie: cache aplikacji (REVIEW)"
            for entry in "${review_entries[@]}"; do
                safe_remove "${entry#*:}"
            done
        fi
    fi
}

# ---------------------------------------------------------------------------
# clean_system_caches — report-only (P0-1: privileged deletion removed)
#
# System caches under /Library/Caches are now report-only. The planner
# already treats them as report_only; this aligns the interactive path.
# Users who need to clean these should use Disk Utility or manual sudo
# outside this tool.
# ---------------------------------------------------------------------------
clean_system_caches() {
    [[ ${#FOUND_SYSTEM_CACHES[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "system-caches")
    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    print_section "Cache systemowe (/Library/Caches) — tylko raport"
    print_info "Rozmiar: ${total_h}"
    print_info "Cache systemowe są raportowane, ale nie usuwane przez ten skrypt."
    print_info "macOS zarządza tymi plikami automatycznie."

    for path in "${FOUND_SYSTEM_CACHES[@]}"; do
        record_skipped_item "System cache (report-only): ${path}"
        cleanup_journal_event "report_only" "$path" "" "$(path_size_bytes "$path")" "skipped" "system cache report-only (P0-1)"
    done
}
# clean_logs
# ---------------------------------------------------------------------------
clean_logs() {
    local total_user
    total_user=$(catbytes_get "user-logs")
    local total_sys
    total_sys=$(catbytes_get "system-logs")
    local total_all=$(( total_user + total_sys ))
    [[ $total_all -eq 0 ]] && return

    local total_h
    total_h=$(bytes_to_human "$total_all")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "${FOUND_APP_LOGS[@]}" "${FOUND_SYSTEM_LOGS[@]}")"
        confirm_category \
            --title      "Stare logi aplikacji (>$LOG_MAX_AGE_DAYS dni)" \
            --size       "$total_h" \
            --what       "Pliki dziennika systemowego i aplikacji starsze niż $LOG_MAX_AGE_DAYS dni." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Bezpieczne jeśli nie diagnozujesz aktywnie starszych problemów systemowych." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: stare logi"
    if (( ${#FOUND_APP_LOGS[@]} > 0 ));    then for f in "${FOUND_APP_LOGS[@]}";    do safe_remove "$f"; done; fi
    if (( ${#FOUND_SYSTEM_LOGS[@]} > 0 )); then for f in "${FOUND_SYSTEM_LOGS[@]}"; do safe_remove "$f"; done; fi
}

# ---------------------------------------------------------------------------
# clean_diagnostic_reports
# ---------------------------------------------------------------------------
clean_diagnostic_reports() {
    [[ ${#FOUND_DIAGNOSTIC_REPORTS[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "diagnostic-reports")
    [[ "$total_bytes" -eq 0 ]] && return

    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "${FOUND_DIAGNOSTIC_REPORTS[@]}")"
        confirm_category \
            --title      "Raporty diagnostyczne (crash logs, spin dumps)" \
            --size       "$total_h" \
            --what       "Pliki .crash, .spin, .hang generowane gdy aplikacje się zawieszają lub crashują." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Bezpieczne jeśli nie jesteś w trakcie diagnozowania problemów z aplikacjami." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: raporty diagnostyczne"
    for f in "${FOUND_DIAGNOSTIC_REPORTS[@]}"; do
        safe_remove "$f"
    done
}

# ---------------------------------------------------------------------------
# clean_tmp
# ---------------------------------------------------------------------------
clean_tmp() {
    [[ ${#FOUND_TMP_FILES[@]} -eq 0 ]] && return

    local total_h
    total_h=$(bytes_to_human "$(catbytes_get "tmp")")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "${FOUND_TMP_FILES[@]}")"
        confirm_category \
            --title      "Pliki tymczasowe (/tmp)" \
            --size       "$total_h" \
            --what       "Pliki tymczasowe starsze niż $TMP_MAX_AGE_HOURS h w /tmp i /private/tmp." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "macOS czyści /tmp przy każdym restarcie." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: pliki tymczasowe"
    for f in "${FOUND_TMP_FILES[@]}"; do safe_remove "$f"; done
}

# ---------------------------------------------------------------------------
# clean_app_leftovers
# ---------------------------------------------------------------------------
clean_app_leftovers() {
    [[ ${#FOUND_APP_LEFTOVERS[@]} -eq 0 ]] && return

    local total_h
    total_h=$(bytes_to_human "$(catbytes_get "app-leftovers")")

    print_warning_box "Pozostałości po aplikacjach" \
        "Poniższe elementy wyglądają jak dane po ODINSTALOWANYCH" \
        "aplikacjach, ale weryfikacja jest heurystyczna." \
        "" \
        "ZAWSZE sprawdź ręcznie listę przed potwierdzeniem!" \
        "Fałszywy alarm może usunąć dane działającej aplikacji."

    echo -e "  ${C_BOLD}Kandydaci (${#FOUND_APP_LEFTOVERS[@]}):${C_RESET}"
    for p in "${FOUND_APP_LEFTOVERS[@]}"; do
        printf "    %8s  %s\n" "$(path_size_human "$p")" "$p"
    done
    echo

    record_user_decision "Pozostałości po aplikacjach: ${total_h} — report-only; usuń ręcznie po weryfikacji"
    print_skip "App leftovers są teraz tylko raportowane. Brak automatycznego usuwania."
    return 0
}

# ---------------------------------------------------------------------------
# clean_xcode_derived_data
# ---------------------------------------------------------------------------
clean_xcode_derived_data() {
    local dd_entry=""
    for item in "${FOUND_DEV_ITEMS[@]}"; do
        [[ "$item" == "xcode_derived_data:"* ]] && dd_entry="${item#xcode_derived_data:}" && break
    done
    [[ -z "$dd_entry" ]] && return

    local size_h
    size_h=$(bytes_to_human "$(catbytes_get "xcode-derived")")

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "$dd_entry")"
        confirm_category \
            --title      "Xcode DerivedData" \
            --size       "$size_h" \
            --paths      "$dd_entry" \
            --what       "Skompilowane artefakty buildów Xcode. Tworzone automatycznie przy każdym buildzie." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Xcode odtworzy te dane przy kolejnym buildzie." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: Xcode DerivedData"
    safe_remove "$dd_entry"
}

# ---------------------------------------------------------------------------
# clean_ios_device_support — Xcode device symbol files
# These can be 2-5 GB per iOS version
# ---------------------------------------------------------------------------
clean_ios_device_support() {
    [[ ${#FOUND_DEVICE_SUPPORT_ITEMS[@]} -eq 0 ]] && return

    local total_bytes
    total_bytes=$(catbytes_get "device-support")
    [[ "$total_bytes" -eq 0 ]] && return

    local total_h
    total_h=$(bytes_to_human "$total_bytes")

    print_warning_box "Xcode Device Support (symbole debugowania)" \
        "Te pliki zawierają symbole debugowania dla podłączonych" \
        "urządzeń iOS/watchOS. Xcode pobierze je ponownie gdy" \
        "podłączysz urządzenie z tą wersją systemu." \
        "" \
        "Rozmiar: ${total_h}" \
        "" \
        "Bezpieczne do usunięcia jeśli: nie debugujesz urządzeń" \
        "z tymi wersjami iOS/watchOS, lub masz dostęp do internetu."

    echo -e "  ${C_BOLD}Znalezione wersje:${C_RESET}"
    for entry in "${FOUND_DEVICE_SUPPORT_ITEMS[@]}"; do
        local ds_type="${entry%%:*}"
        local path="${entry#*:}"
        local ver_name
        ver_name=$(basename "$path")
        printf "    %8s  %s / %s\n" "$(path_size_human "$path")" "$ds_type" "$ver_name"
    done
    echo

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local -a ds_paths=()
        for entry in "${FOUND_DEVICE_SUPPORT_ITEMS[@]}"; do
            ds_paths+=("${entry#*:}")
        done
        local cat_risk
        cat_risk="$(category_max_risk "${ds_paths[@]}")"
        confirm_category \
            --title      "Xcode Device Support (symbole debugowania)" \
            --size       "$total_h" \
            --what       "Symbole debugowania dla iOS/watchOS/tvOS. Pobierane gdy podłączysz urządzenie." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Bezpieczne jeśli masz internet i nie musisz natychmiast debugować na starym urządzeniu." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: Xcode Device Support"
    for entry in "${FOUND_DEVICE_SUPPORT_ITEMS[@]}"; do
        local path="${entry#*:}"
        safe_remove "$path"
    done
}

# ---------------------------------------------------------------------------
# clean_xcode_simulators — only OLD/unused runtimes
# ---------------------------------------------------------------------------
clean_xcode_simulators() {
    local sim_entry=""
    for item in "${FOUND_DEV_ITEMS[@]}"; do
        [[ "$item" == "ios_simulators:"* ]] && sim_entry="${item#ios_simulators:}" && break
    done
    [[ -z "$sim_entry" ]] && return

    local size_h
    size_h=$(bytes_to_human "$(catbytes_get "simulators")")

    print_warning_box "Symulatory iOS/watchOS/tvOS" \
        "Xcode przechowuje wiele wersji symulatorów." \
        "Bezpieczniejsza opcja: xcrun simctl delete unavailable" \
        "(usuwa tylko niedostępne symulatory, nie wszystkie)." \
        "" \
        "Zalecane: Xcode → Window → Devices and Simulators"

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local cat_risk
        cat_risk="$(category_max_risk "$sim_entry")"
        confirm_category \
            --title      "Stare symulatory iOS (xcrun simctl delete unavailable)" \
            --size       "$size_h" \
            --what       "Niedostępne urządzenia symulatorów iOS, watchOS, tvOS." \
            --consequence "$(consequence_for_mode "$cat_risk" "native")" \
            --safe-if    "Bezpieczne jeśli: masz dostęp do internetu i możesz czekać na pobieranie." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: stare symulatory (xcrun simctl delete unavailable)"
    if [[ "$DRY_RUN" == "1" ]]; then
        print_dry "Would run: xcrun simctl delete unavailable"
        record_native_command_event "xcrun simctl delete unavailable" "planned" "$(catbytes_get "simulators")" "dry-run"
    else
        if command -v xcrun &>/dev/null; then
            if xcrun simctl delete unavailable 2>/dev/null; then
                print_cleaned "Usunięto niedostępne symulatory."
                record_native_command_event "xcrun simctl delete unavailable" "ok" "$(catbytes_get "simulators")" ""
            else
                record_native_command_event "xcrun simctl delete unavailable" "failed" "$(catbytes_get "simulators")" "xcrun failed"
                print_warn "Nie udało się uruchomić xcrun simctl."
            fi
        else
            record_native_command_event "xcrun simctl delete unavailable" "skipped" "$(catbytes_get "simulators")" "xcrun unavailable"
            print_warn "xcrun niedostępne — Xcode nie jest zainstalowany?"
        fi
    fi
}

clean_dev_review_only_items() {
    local item key path total_h

    for item in "${FOUND_DEV_ITEMS[@]}"; do
        key="${item%%:*}"
        path="${item#*:}"
        case "$key" in
            xcode_archives)
                total_h=$(bytes_to_human "$(catbytes_get "xcode-archives")")
                record_user_decision "Xcode Archives: ${total_h} — review-only; usuń ręcznie tylko jeśli nie potrzebujesz archiwów dystrybucyjnych"
                ;;
            maven_cache)
                total_h=$(bytes_to_human "$(catbytes_get "maven")")
                record_user_decision "Maven ~/.m2/repository: ${total_h} — review-only; może zawierać lokalnie zbudowane artefakty niedostępne z internetu"
                ;;
            android_avd)
                total_h=$(bytes_to_human "$(catbytes_get "android-avd")")
                record_user_decision "Android AVD: ${total_h} — review-only; usuń z Android Studio Device Manager po sprawdzeniu stanu emulatorów"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# _clean_dev_native_or_fallback — shared helper for the 4 structurally-identical
# "try native tool, fallback to safe_remove" blocks in clean_dev_caches.
#
# Usage:
#   _clean_dev_native_or_fallback cmd tool catkey label ok_msg path
#
# Arguments:
#   cmd    — full native command string (e.g. "npm cache clean --force")
#   tool   — binary name for availability check (e.g. "npm")
#   catkey — catbytes key (e.g. "npm")
#   label  — Polish label used in print_cleaned/print_dry (e.g. "npm cache")
#   ok_msg — Polish success message printed after native command succeeds
#   path   — fallback path for safe_remove when tool is missing or fails
#
# Journal messages are verbatim to preserve them as a public API:
#   planned  : "dry-run"
#   ok       : "" (empty)
#   failed   : "$tool failed; fallback safe_remove"
#   skipped  : "$tool unavailable; fallback safe_remove"
# ---------------------------------------------------------------------------
_clean_dev_native_or_fallback() {
    local cmd="$1" tool="$2" catkey="$3" label="$4" ok_msg="$5" path="$6"

    if [[ "$DRY_RUN" == "1" ]]; then
        print_dry "Would run: ${cmd}  ($(path_size_human "$path"))"
        record_native_command_event "$cmd" "planned" "$(catbytes_get "$catkey")" "dry-run"
        return 0
    fi

    print_cleaned "Czyszczę: ${label} (${cmd})"
    if command -v "$tool" &>/dev/null; then
        if $cmd 2>/dev/null; then
            print_ok "${ok_msg}"
            record_native_command_event "$cmd" "ok" "$(catbytes_get "$catkey")" ""
        else
            record_native_command_event "$cmd" "failed" "$(catbytes_get "$catkey")" "${tool} failed; fallback safe_remove"
            safe_remove "$path"
        fi
    else
        record_native_command_event "$cmd" "skipped" "$(catbytes_get "$catkey")" "${tool} unavailable; fallback safe_remove"
        safe_remove "$path"
    fi
}

# ---------------------------------------------------------------------------
# clean_dev_caches — npm, yarn, pnpm, pip, brew, gradle, maven, cocoapods,
#                    swift-pm, gem, bundler, composer, cargo
# Uses native tool commands where available (safer than rm -rf)
# ---------------------------------------------------------------------------
clean_dev_caches() {
    # Helper: label for a cache key
    _dev_label() {
        case "$1" in
            npm_cache)       echo "npm cache" ;;
            yarn_cache)      echo "yarn cache" ;;
            pnpm_cache)      echo "pnpm store" ;;
            pip_cache)       echo "pip cache" ;;
            brew_cache)      echo "Homebrew cache" ;;
            brew_cleanup)     echo "Homebrew stale versions" ;;
            gradle_cache)    echo "Gradle cache" ;;
            maven_cache)     echo "" ;;
            cocoapods_cache) echo "CocoaPods cache" ;;
            cargo_cache)     echo "Cargo registry cache" ;;
            swift_pm_cache)  echo "Swift Package Manager cache" ;;
            gem_cache)       echo "Ruby gems cache" ;;
            bundler_cache)   echo "Bundler cache" ;;
            composer_cache)  echo "Composer cache (PHP)" ;;
            android_avd)     echo "" ;;
            *)               echo "" ;;
        esac
    }

    local dev_cache_items=()
    for item in "${FOUND_DEV_ITEMS[@]}"; do
        local key="${item%%:*}"
        [[ -n "$(_dev_label "$key")" ]] && dev_cache_items+=("$item")
    done

    [[ ${#dev_cache_items[@]} -eq 0 ]] && return

    # Calculate total
    local total=0
    for item in "${dev_cache_items[@]}"; do
        local key="${item%%:*}"
        local mapped_key=""
        case "$key" in
            npm_cache)       mapped_key="npm" ;;
            yarn_cache)      mapped_key="yarn" ;;
            pnpm_cache)      mapped_key="pnpm" ;;
            pip_cache)       mapped_key="pip" ;;
            brew_cache)      mapped_key="brew" ;;
            brew_cleanup)     mapped_key="brew-stale" ;;
            gradle_cache)    mapped_key="gradle" ;;
            maven_cache)     mapped_key="maven" ;;
            cocoapods_cache) mapped_key="cocoapods" ;;
            cargo_cache)     mapped_key="cargo" ;;
            swift_pm_cache)  mapped_key="swift-pm" ;;
            gem_cache)       mapped_key="gem" ;;
            bundler_cache)   mapped_key="bundler" ;;
            composer_cache)  mapped_key="composer" ;;
            android_avd)     mapped_key="android-avd" ;;
        esac
        [[ -n "$mapped_key" ]] && total=$(( total + $(catbytes_get "$mapped_key") ))
    done

    local total_h
    total_h=$(bytes_to_human "$total")

    # Show breakdown
    echo -e "  ${C_BOLD}Cache menedżerów pakietów:${C_RESET}"
    for item in "${dev_cache_items[@]}"; do
        local key="${item%%:*}"
        local path="${item#*:}"
        local label
        label=$(_dev_label "$key")
        [[ -z "$label" ]] && continue
        [[ "$path" == "__docker__" ]] && continue
        [[ "$path" == "__brew__" ]] && { printf "    %8s  %s\n" "$(bytes_to_human "$(catbytes_get "brew-stale")")" "$label"; continue; }
        [[ -d "$path" ]] && printf "    %8s  %s\n" "$(path_size_human "$path")" "$label"
    done
    echo

    if [[ "${MODE}" == "interactive" || "${MODE}" == "dry-run-then-interactive" ]]; then
        local -a dev_paths=()
        for item in "${dev_cache_items[@]}"; do
            local p="${item#*:}"
            [[ "$p" != "__brew__" && "$p" != "__docker__" ]] && dev_paths+=("$p")
        done
        local cat_risk
        cat_risk="$(category_max_risk "${dev_paths[@]}")"
        confirm_category \
            --title      "Cache menedżerów pakietów (npm, brew, pip, etc.)" \
            --size       "$total_h" \
            --what       "Lokalne cache: npm, yarn, pnpm, pip, Homebrew, Gradle, CocoaPods, Cargo, Swift PM..." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Bezpieczne jeśli masz dostęp do internetu. Pakiety zostaną pobrane ponownie gdy potrzeba." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: cache menedżerów pakietów"

    for item in "${dev_cache_items[@]}"; do
        local key="${item%%:*}"
        local path="${item#*:}"
        [[ "$path" == "__docker__" ]] && continue

        case "$key" in
            # ----------------------------------------------------------------
            # npm — use native command for safety (npm cache clean --force)
            # ----------------------------------------------------------------
            npm_cache)
                _clean_dev_native_or_fallback \
                    "npm cache clean --force" "npm" "npm" \
                    "npm cache" "npm cache wyczyszczony." "$path"
                ;;
            # ----------------------------------------------------------------
            # yarn — use yarn cache clean
            # ----------------------------------------------------------------
            yarn_cache)
                _clean_dev_native_or_fallback \
                    "yarn cache clean" "yarn" "yarn" \
                    "yarn cache" "yarn cache wyczyszczony." "$path"
                ;;
            # ----------------------------------------------------------------
            # pnpm — use pnpm store prune
            # ----------------------------------------------------------------
            pnpm_cache)
                _clean_dev_native_or_fallback \
                    "pnpm store prune" "pnpm" "pnpm" \
                    "pnpm store" "pnpm store przycięty." "$path"
                ;;
            # ----------------------------------------------------------------
            # brew — use brew cleanup --prune=all
            # __brew__ sentinel: catbytes-only entry, no path fallback
            # ----------------------------------------------------------------
            brew_cache|brew_cleanup)
                if [[ "$DRY_RUN" == "1" ]]; then
                    if [[ "$path" == "__brew__" ]]; then
                        print_dry "Would run: brew cleanup --prune=all  ($(bytes_to_human "$(catbytes_get "brew-stale")"))"
                    else
                        print_dry "Would run: brew cleanup --prune=all  ($(path_size_human "$path"))"
                    fi
                    record_native_command_event "brew cleanup --prune=all" "planned" "$(catbytes_get "brew-stale")" "dry-run"
                else
                    print_cleaned "Czyszczę: Homebrew (brew cleanup --prune=all)"
                    if command -v brew &>/dev/null; then
                        if brew cleanup --prune=all 2>/dev/null; then
                            print_ok "Homebrew wyczyszczony."
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
            # ----------------------------------------------------------------
            # pip — use pip cache purge
            # pip3 is tried first, then pip; actual binary name is journalled
            # ----------------------------------------------------------------
            pip_cache)
                if [[ "$DRY_RUN" == "1" ]]; then
                    print_dry "Would run: pip cache purge  ($(path_size_human "$path"))"
                    record_native_command_event "pip cache purge" "planned" "$(catbytes_get "pip")" "dry-run"
                else
                    print_cleaned "Czyszczę: pip cache (pip cache purge)"
                    local pip_cmd=""
                    command -v pip3 &>/dev/null && pip_cmd="pip3"
                    command -v pip  &>/dev/null && pip_cmd="pip"
                    if [[ -n "$pip_cmd" ]]; then
                        if $pip_cmd cache purge 2>/dev/null; then
                            print_ok "pip cache wyczyszczony."
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
            # ----------------------------------------------------------------
            # gem — use gem cleanup
            # ----------------------------------------------------------------
            gem_cache)
                _clean_dev_native_or_fallback \
                    "gem cleanup" "gem" "gem" \
                    "Ruby gems" "Ruby gems wyczyszczone." "$path"
                ;;
            # ----------------------------------------------------------------
            # All others: safe_remove directly
            # ----------------------------------------------------------------
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
            --what       "Nieużywane obrazy, zatrzymane kontenery, sieci i build cache usuwane przez docker system prune." \
            --consequence "$(consequence_for_mode "$cat_risk" "native")" \
            --safe-if    "Bezpieczne jeśli nie masz ważnych danych w zatrzymanych kontenerach." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: Docker (system prune)"
    if [[ "$DRY_RUN" == "1" ]]; then
        print_dry "Would run: docker system prune -f"
        record_native_command_event "docker system prune -f" "planned" "$(catbytes_get "docker")" "dry-run"
    else
        if command -v docker &>/dev/null; then
            if docker system prune -f 2>/dev/null; then
                print_cleaned "Docker system prune wykonany."
                record_native_command_event "docker system prune -f" "ok" "$(catbytes_get "docker")" ""
            else
                record_native_command_event "docker system prune -f" "failed" "$(catbytes_get "docker")" "docker prune failed"
                print_warn "docker system prune nie powiódł się lub Docker nie jest uruchomiony."
            fi
        else
            record_native_command_event "docker system prune -f" "skipped" "$(catbytes_get "docker")" "docker unavailable"
            print_warn "docker nie jest dostępny."
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

    if ! confirm_time_machine_snapshots "$snapshots_str" "${count} snapshotów"; then
        print_skip "Pominięto: lokalne snapshoty Time Machine"
        record_skipped_item "Lokalne snapshoty Time Machine"
        return
    fi

    print_section "Czyszczenie: lokalne snapshoty Time Machine"

    for snap in "${FOUND_TM_SNAPSHOTS[@]}"; do
        [[ -z "$snap" ]] && continue
        # Extract full datetime from snapshot name: com.apple.TimeMachine.2026-04-17-131903.local
        local snap_date=""
        snap_date=$(echo "$snap" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1) || snap_date=""

        if [[ -z "$snap_date" ]]; then
            print_warn "Nie można sparsować daty ze snapshotu: $snap"
            continue
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            print_dry "Would run: tmutil deletelocalsnapshots $snap_date"
            record_native_command_event "tmutil deletelocalsnapshots ${snap_date}" "planned" 0 "dry-run"
        else
            print_info "Usuwam snapshot: $snap_date"
            local tm_out
            if tm_out=$(tmutil deletelocalsnapshots "$snap_date" 2>&1); then
                print_cleaned "Usunięto snapshot: $snap_date"
                record_native_command_event "tmutil deletelocalsnapshots ${snap_date}" "ok" 0 ""
            else
                record_native_command_event "tmutil deletelocalsnapshots ${snap_date}" "failed" 0 "tmutil failed"
                print_warn "Nie udało się usunąć: $snap_date"
                print_warn "  Powód: $tm_out"
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
        print_skip "Pominięto: backupy iOS"
        record_skipped_item "Lokalne backupy iOS (kategoria anulowana przez użytkownika)"
        return
    fi

    print_section "Czyszczenie: backupy iOS (po jednym)"
    for backup_dir in "${FOUND_IOS_BACKUPS[@]}"; do
        [[ -d "$backup_dir" ]] || continue
        local device_name="Nieznane urządzenie"
        local info_plist="${backup_dir}/Info.plist"
        [[ -f "$info_plist" ]] && \
            device_name=$(defaults read "$info_plist" "Device Name" 2>/dev/null || echo "Nieznane")

        local bk_size
        bk_size=$(path_size_human "$backup_dir")
        echo
        if ask_yes_no "Usunąć backup: '${device_name}' (${bk_size})?" "no"; then
            safe_remove "$backup_dir"
        else
            print_skip "Zachowano backup: $device_name"
            record_skipped_item "Backup iOS zachowany: ${device_name}"
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
            --title      "Stare instalatory (DMG/PKG/ISO)" \
            --size       "$total_h" \
            --paths      "$paths_str" \
            --what       "Pliki instalatorów starsze niż $DMG_MAX_AGE_DAYS dni w ~/Downloads (>10 MB)." \
            --consequence "$(consequence_for_mode "$cat_risk" "${REMOVE_MODE:-quarantine}")" \
            --safe-if    "Bezpieczne jeśli masz dostęp do internetu lub nie potrzebujesz starych wersji." \
            --risk       "$cat_risk" || return 0
    fi

    print_section "Czyszczenie: stare instalatory"
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
        print_warn "Czyszczenie '${fn}' zakończyło się błędem (pomijam, kontynuuję)."
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
            *)             print_warn "Nieznana kategoria: $cat" ;;
        esac
    done
}
