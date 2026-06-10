#!/usr/bin/env bash
# =============================================================================
# lib/reporter.sh — Markdown report generation
# Bash 3.2 compatible.
# =============================================================================

write_report_journal_summary() {
    local mode="$1"
    local key bytes

    cleanup_journal_event "report_generated" "$REPORT_FILE" "" 0 "ok" "mode=${mode}" ""

    for key in "${ALL_KNOWN_CATEGORY_KEYS[@]}"; do
        bytes=$(catbytes_get "$key")
        (( bytes == 0 )) && continue
        cleanup_journal_event "category_total" "$key" "" "$bytes" "found" "mode=${mode}" "$key"
    done
}

generate_report() {
    local mode="$1"
    # shellcheck disable=SC2034
    local categories_run=("${@:2}")

    mkdir -p "$(dirname "$REPORT_FILE")"
    write_report_journal_summary "$mode"

    cat > "$REPORT_FILE" << HEADER
# macOS Cleanup Report
**Skrypt:** \`${SCRIPT_NAME}\` v${SCRIPT_VERSION}
**Data:** $(date '+%Y-%m-%d %H:%M:%S')
**Tryb:** \`${mode}\`
**Użytkownik:** $(whoami)
**Host:** $(hostname)
**macOS:** $(sw_vers -productVersion 2>/dev/null || echo "nieznana")

---

## Podsumowanie

| Metryka | Wartość |
|---------|---------|
HEADER

    if [[ "$mode" == "dry-run" ]]; then
        echo "| Potencjalnie do zwolnienia | **$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")** |" >> "$REPORT_FILE"
    elif [[ "$mode" == "plan" ]]; then
        echo "| Plan JSON | \`${PLAN_FILE:-$PLAN_FILE_DEFAULT}\` |" >> "$REPORT_FILE"
    elif [[ "$mode" == "apply-plan" ]]; then
        echo "| Plan źródłowy | \`${PLAN_FROM_FILE:-}\` |" >> "$REPORT_FILE"
        echo "| Usunięte bezpośrednio      | **$(bytes_to_human "$TOTAL_CLEANED_BYTES")** |" >> "$REPORT_FILE"
        echo "| Przeniesione do kwarantanny | **$(bytes_to_human "$TOTAL_QUARANTINED_BYTES")** |" >> "$REPORT_FILE"
    elif [[ "$mode" == "restore" ]]; then
        echo "| Odtworzone z kwarantanny | **$(bytes_to_human "$TOTAL_RESTORED_BYTES")** |" >> "$REPORT_FILE"
        echo "| Odtworzone elementy | ${TOTAL_RESTORED_ITEMS} |" >> "$REPORT_FILE"
    elif [[ "$mode" == "list-quarantine" ]]; then
        echo "| Katalog kwarantanny | \`${QUARANTINE_ROOT}\` |" >> "$REPORT_FILE"
    elif [[ "$mode" == "purge-quarantine" ]]; then
        echo "| Trwale usunięte z kwarantanny | **$(bytes_to_human "$TOTAL_CLEANED_BYTES")** |" >> "$REPORT_FILE"
    else
        echo "| Usunięte bezpośrednio      | **$(bytes_to_human "$TOTAL_CLEANED_BYTES")** |" >> "$REPORT_FILE"
        echo "| Przeniesione do kwarantanny | **$(bytes_to_human "$TOTAL_QUARANTINED_BYTES")** |" >> "$REPORT_FILE"
        echo "| Elementy w kwarantannie    | ${TOTAL_QUARANTINED_ITEMS} |" >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" << SUMMARY
| Elementy wymagające decyzji | ${TOTAL_USER_DECISIONS_NEEDED} |
| Pominięte elementy         | ${TOTAL_SKIPPED_ITEMS} |
| Log pliku                  | \`${LOG_FILE}\` |
| Journal JSONL              | \`${CLEANUP_JOURNAL_FILE}\` |
| Manifest restore           | \`${CLEANUP_RESTORE_MANIFEST}\` |

---

## Wyniki według kategorii

SUMMARY

    # Category breakdown
    local all_cats=(
        "trash:Kosz (~/.Trash)"
        "user-caches:Cache użytkownika (~/Library/Caches)"
        "app-caches:Cache aplikacji (Slack, VSCode, JetBrains...)"
        "system-caches:Cache systemowe"
        "user-logs:Logi użytkownika"
        "system-logs:Logi systemowe"
        "diagnostic-reports:Raporty diagnostyczne (crash logs)"
        "tmp:Pliki tymczasowe"
        "app-leftovers:Pozostałości po aplikacjach"
        "xcode-derived:Xcode DerivedData"
        "xcode-archives:Xcode Archives"
        "simulators:iOS Symulatory"
        "device-support:Xcode Device Support (symbole)"
        "npm:npm cache"
        "yarn:yarn cache"
        "pnpm:pnpm store"
        "pip:pip cache"
        "brew:Homebrew cache"
        "brew-stale:Homebrew stare wersje"
        "gradle:Gradle cache"
        "maven:Maven cache"
        "cocoapods:CocoaPods cache"
        "cargo:Cargo cache (Rust)"
        "swift-pm:Swift Package Manager cache"
        "gem:Ruby gems cache"
        "bundler:Bundler cache"
        "composer:Composer cache (PHP)"
        "android-avd:Android AVD emulatory"
        "docker:Docker (reclaimable)"
        "time-machine:Time Machine snapshoty (szt.)"
        "ios-backups:Backupy iOS"
        "installers:Stare instalatory DMG/PKG"
        "mail-total:Apple Mail (report-only)"
        "mail-downloads:Mail Downloads (report-only)"
        "browser-caches:Cache przeglądarek (review)"
        "browser-data:Profile przeglądarek (DANGEROUS)"
    )

    echo "| Kategoria | Znaleziono | Status |" >> "$REPORT_FILE"
    echo "|-----------|-----------|--------|" >> "$REPORT_FILE"

    local grand_total=0
    for entry in "${all_cats[@]}"; do
        local key="${entry%%:*}"
        local label="${entry#*:}"
        local bytes; bytes=$(catbytes_get "$key")
        if (( bytes > 0 )); then
            local display
            # time-machine stores a snapshot count, not a byte size
            if [[ "$key" == "time-machine" ]]; then
                display="${bytes} szt."
            elif [[ "$key" == mail-* || "$key" == browser-* ]]; then
                display=$(bytes_to_human "$bytes")
            else
                display=$(bytes_to_human "$bytes")
                grand_total=$(( grand_total + bytes ))
            fi
            if [[ "$key" == mail-* || "$key" == browser-* ]]; then
                echo "| ${label} | ${display} | 🔒 Report-only |" >> "$REPORT_FILE"
            else
                echo "| ${label} | ${display} | 🔍 Znaleziono |" >> "$REPORT_FILE"
            fi
        fi
    done

    echo >> "$REPORT_FILE"
    echo "**Łącznie potencjalnie do zwolnienia: $(bytes_to_human "$grand_total")**" >> "$REPORT_FILE"
    echo >> "$REPORT_FILE"

    # User decision items
    if (( ${#USER_DECISION_ITEMS[@]} > 0 )); then
        cat >> "$REPORT_FILE" << DECISIONS
---

## ⚠️  Elementy wymagające Twojej decyzji

Poniższe elementy **nie zostały automatycznie usunięte** — wymagają ręcznej weryfikacji:

DECISIONS
        for item in "${USER_DECISION_ITEMS[@]}"; do
            echo "- ${item}" >> "$REPORT_FILE"
        done
        echo >> "$REPORT_FILE"
    fi

    # Warnings
    if (( ${#WARNINGS_LIST[@]} > 0 )); then
        cat >> "$REPORT_FILE" << WARNS
---

## ⚠️  Ostrzeżenia i uwagi

WARNS
        for w in "${WARNINGS_LIST[@]}"; do
            echo "- ${w}" >> "$REPORT_FILE"
        done
        echo >> "$REPORT_FILE"
    fi

    if (( TOTAL_QUARANTINED_ITEMS > 0 )); then
        cat >> "$REPORT_FILE" << QUARANTINE
---

## Kwarantanna i rollback

Elementy użytkownika nie zostały trwale skasowane. Zostały przeniesione do:

\`${QUARANTINE_RUN_DIR}\`

Manifest odtwarzania:

\`${CLEANUP_RESTORE_MANIFEST}\`

Odtwarzanie:

\`\`\`bash
bash cleanup_all.sh --restore "${CLEANUP_RESTORE_MANIFEST}"
\`\`\`

QUARANTINE
    fi

    # Safety section
    cat >> "$REPORT_FILE" << SAFETY
---

## 🔒 Nigdy nie dotknięte

Skrypt z założenia **nie czyści** następujących obszarów:

- \`~/Library/Mail\` — dane Apple Mail
- \`~/Library/Keychains\` — pęk kluczy
- Dane przeglądarek (Chrome, Firefox, Safari, Edge, Brave): cookies, hasła, profile
- \`~/Library/Application Support\` aktywnych aplikacji i \`~/Library/Preferences\`
- Menedżery haseł: 1Password, Bitwarden, LastPass, Dashlane, itp.
- \`~/Documents\`, \`~/Desktop\`
- Biblioteka Photos, Music, Movies
- Provisioning Profiles i certyfikaty deweloperskie
- Klucze SSH (\`~/.ssh\`), klucze GPG (\`~/.gnupg\`)
- Backupy iOS — tylko z dodatkowym ostrzeżeniem i potwierdzeniem

---

## Jak ponownie uruchomić czyszczenie

\`\`\`bash
# Tylko analiza (bezpieczna)
bash cleanup_all.sh --dry-run
bash cleanup_all.sh analyze

# Strukturalny plan do recenzji/agenta
bash cleanup_all.sh plan

# Wykonanie planu: domyślnie tylko SAFE
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Interaktywne czyszczenie (zalecane)
bash cleanup_all.sh --interactive

# Konkretna kategoria
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --interactive --category trash
bash cleanup_all.sh --interactive --category user-caches

# Automatyczne czyszczenie tylko bezpiecznych elementów
bash cleanup_all.sh --auto-safe

# Odtwarzanie elementów przeniesionych do kwarantanny
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Lista i trwały purge kwarantanny
bash cleanup_all.sh --list-quarantine
bash cleanup_all.sh --purge-quarantine latest --apply
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
\`\`\`

---
*Raport wygenerowany przez \`${SCRIPT_NAME}\` v${SCRIPT_VERSION}*
SAFETY

    print_ok "Raport zapisany: ${REPORT_FILE}"
    log_info "Report written: ${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# print_final_summary — terminal summary at script end
# ---------------------------------------------------------------------------
print_final_summary() {
    local mode="$1"

    echo
    echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}  PODSUMOWANIE KOŃCOWE${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
    echo

    if [[ "$mode" == "dry-run" ]]; then
        echo -e "  ${C_BOLD}Tryb:${C_RESET}                       Analiza (dry-run) — nic nie usunięto"
        echo -e "  ${C_BOLD}Potencjalnie do zwolnienia:${C_RESET} ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")${C_RESET}"
    elif [[ "$mode" == "plan" ]]; then
        echo -e "  ${C_BOLD}Tryb:${C_RESET}                       plan — nic nie usunięto"
        echo -e "  ${C_BOLD}Plan:${C_RESET}                       ${C_DIM}${PLAN_FILE:-$PLAN_FILE_DEFAULT}${C_RESET}"
    elif [[ "$mode" == "apply-plan" ]]; then
        echo -e "  ${C_BOLD}Tryb:${C_RESET}                       apply plan"
        echo -e "  ${C_BOLD}Usunięto bezpośrednio:${C_RESET}      ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
        echo -e "  ${C_BOLD}W kwarantannie:${C_RESET}             ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_QUARANTINED_BYTES")${C_RESET} (${TOTAL_QUARANTINED_ITEMS} elementów)"
    elif [[ "$mode" == "restore" ]]; then
        echo -e "  ${C_BOLD}Tryb:${C_RESET}                       restore"
        echo -e "  ${C_BOLD}Odtworzono:${C_RESET}                 ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_RESTORED_BYTES")${C_RESET} (${TOTAL_RESTORED_ITEMS} elementów)"
    elif [[ "$mode" == "list-quarantine" ]]; then
        echo -e "  ${C_BOLD}Tryb:${C_RESET}                       list-quarantine"
    elif [[ "$mode" == "purge-quarantine" ]]; then
        echo -e "  ${C_BOLD}Tryb:${C_RESET}                       purge-quarantine"
        echo -e "  ${C_BOLD}Trwale usunięto:${C_RESET}            ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
    else
        echo -e "  ${C_BOLD}Tryb:${C_RESET}                       ${mode}"
        echo -e "  ${C_BOLD}Usunięto bezpośrednio:${C_RESET}      ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
        echo -e "  ${C_BOLD}W kwarantannie:${C_RESET}             ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_QUARANTINED_BYTES")${C_RESET} (${TOTAL_QUARANTINED_ITEMS} elementów)"
    fi

    echo -e "  ${C_BOLD}Elementy do decyzji:${C_RESET}        ${TOTAL_USER_DECISIONS_NEEDED}"
    echo -e "  ${C_BOLD}Log:${C_RESET}                        ${C_DIM}${LOG_FILE}${C_RESET}"
    echo -e "  ${C_BOLD}Raport:${C_RESET}                     ${C_DIM}${REPORT_FILE}${C_RESET}"
    echo -e "  ${C_BOLD}Journal:${C_RESET}                    ${C_DIM}${CLEANUP_JOURNAL_FILE}${C_RESET}"
    if (( TOTAL_QUARANTINED_ITEMS > 0 )); then
        echo -e "  ${C_BOLD}Restore manifest:${C_RESET}           ${C_DIM}${CLEANUP_RESTORE_MANIFEST}${C_RESET}"
    fi
    echo
    echo -e "${C_DIM}  Aby otworzyć raport w przeglądarce: open \"${REPORT_FILE}\"${C_RESET}"
    echo
}
