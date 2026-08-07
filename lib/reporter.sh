#!/usr/bin/env bash
# =============================================================================
# lib/reporter.sh — Markdown execution & summary report generator
#
# Generates a clear Markdown report at the end of every run.
#
# Bash 3.2 compatible.
# =============================================================================

generate_report() {
    local mode="${1:-${MODE}}"
    local report_dir
    report_dir="$(dirname "$REPORT_FILE")"
    mkdir -p "$report_dir" 2>/dev/null || true

    cat << EOF > "$REPORT_FILE"
# macOS Cleanup — Session Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S')  
**Mode:** \`${mode}\`  
**Deletion Strategy:** \`${REMOVE_MODE:-quarantine}\`  
**User:** $(whoami)  
**Host:** $(hostname)  
**OS Version:** $(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || echo "")  

---

## Session Summary

| Metric | Value |
|:-------|:------|
| Potentially freeable space | **$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")** |
EOF

    case "$mode" in
        apply-plan)
            echo "| Source plan | \`${PLAN_FROM_FILE:-}\` |" >> "$REPORT_FILE"
            echo "| Freed space | **$(bytes_to_human "$TOTAL_CLEANED_BYTES")** |" >> "$REPORT_FILE"
            ;;
        purge-quarantine)
            echo "| Quarantined purged | **$(bytes_to_human "$TOTAL_CLEANED_BYTES")** |" >> "$REPORT_FILE"
            ;;
        *)
            echo "| Freed space | **$(bytes_to_human "$TOTAL_CLEANED_BYTES")** |" >> "$REPORT_FILE"
            ;;
    esac

    cat << EOF >> "$REPORT_FILE"
| Items quarantined | ${TOTAL_QUARANTINED_ITEMS} ($(bytes_to_human "$TOTAL_QUARANTINED_BYTES")) |
| Decisions needed | ${TOTAL_USER_DECISIONS_NEEDED} |
| Skipped items | ${TOTAL_SKIPPED_ITEMS} |

---

## Results by Category

| Category | Size | Status | Recommended Action |
|:---------|:-----|:-------|:-------------------|
EOF

    local -a category_labels=(
        "user-caches:User Caches (~/Library/Caches)"
        "system-caches:System Caches (/Library/Caches)"
        "logs:System & App Logs"
        "diagnostic-reports:Diagnostic Reports"
        "app-leftovers:App Leftovers"
        "dev:Developer Caches & Artifacts"
        "derived-data:Xcode DerivedData"
        "xcode-archives:Xcode Archives"
        "xcode-device-support:Xcode Device Support"
        "simulators:iOS Simulators"
        "android-avd:Android AVD Emulators"
        "time-machine:Local TM Snapshots"
        "ios-backups:iOS Backups"
        "trash:Trash (~/.Trash)"
        "tmp:Temporary Files (/tmp)"
        "installers:Old Installers (~/Downloads)"
        "browser-caches:Browser Caches (review)"
        "browser-data:Browser Profiles (DANGEROUS)"
        "mail-total:Apple Mail (DANGEROUS)"
    )

    for entry in "${category_labels[@]}"; do
        local key="${entry%%:*}"
        local label="${entry#*:}"
        local bytes
        bytes=$(catbytes_get "$key")
        (( bytes == 0 )) && continue

        local status_str="Reported"
        local action_str="Review in interactive mode"

        case "$key" in
            user-caches|trash|tmp)
                if [[ "$mode" == "auto-safe" || "$mode" == "interactive" || "$mode" == "apply-plan" ]]; then
                    status_str="Cleaned/Quarantined"
                    action_str="Done"
                else
                    status_str="Found"
                    action_str="Safe to clean"
                fi
                ;;
            system-caches|mail-total|browser-data)
                status_str="Protected / Report-only"
                action_str="Do not delete with rm"
                ;;
            app-leftovers|xcode-archives|android-avd)
                status_str="Needs Decision"
                action_str="Manual verification required"
                ;;
            *)
                status_str="Found"
                action_str="Run --interactive to process"
                ;;
        esac

        echo "| ${label} | **$(bytes_to_human "$bytes")** | ${status_str} | ${action_str} |" >> "$REPORT_FILE"
    done

    cat << EOF >> "$REPORT_FILE"

---

**Total potentially freeable: $(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")**

---

## Items Requiring Your Decision

The following items were **not automatically deleted** and require manual review:

EOF

    if (( ${#USER_DECISION_ITEMS[@]} == 0 )); then
        echo "_No items require manual decision._" >> "$REPORT_FILE"
    else
        for item in "${USER_DECISION_ITEMS[@]}"; do
            echo "- ⚠️  ${item}" >> "$REPORT_FILE"
        done
    fi

    cat << EOF >> "$REPORT_FILE"

---

## Warnings & Notes

EOF

    if (( ${#WARNINGS_LIST[@]} == 0 )); then
        echo "_No warnings recorded for this session._" >> "$REPORT_FILE"
    else
        for warn in "${WARNINGS_LIST[@]}"; do
            echo "- ⚠️  ${warn}" >> "$REPORT_FILE"
        done
    fi

    if [[ "$REMOVE_MODE" == "quarantine" && "$TOTAL_QUARANTINED_ITEMS" -gt 0 ]]; then
        cat << EOF >> "$REPORT_FILE"

---

## Quarantine Information

Items were moved to quarantine instead of permanent deletion:

- **Quarantine Directory:** \`${QUARANTINE_RUN_DIR}\`
- **Restore Manifest:** \`${CLEANUP_RESTORE_MANIFEST}\`
- **Restoration Command:** \`bash cleanup_all.sh --restore ${QUARANTINE_RUN_ID:-latest}\`

EOF
    fi

    cat << EOF >> "$REPORT_FILE"

---

## Protected Paths & Exclusions

The script **never touches** the following locations:

- \`~/Library/Keychains\` — Keychains & passwords
- Browser profiles & credentials (cookies, logins, stored history)
- Password managers: 1Password, Bitwarden, LastPass, Dashlane, etc.
- Primary user documents: Documents, Desktop, Pictures, Movies, Music
- iOS backups — only with explicit warnings & confirmations

---

## How to Re-Run Cleanup

\`\`\`bash
# Interactive mode (step-by-step confirmation for each category)
bash cleanup_all.sh --interactive

# Apply plan mode
bash cleanup_all.sh --from-plan build/plan.json

# Auto-safe mode (clean only allowlisted caches)
bash cleanup_all.sh --auto-safe

# Restore quarantined files
bash cleanup_all.sh --restore ${QUARANTINE_RUN_ID:-latest}

# Purge quarantine
bash cleanup_all.sh --purge-quarantine latest
\`\`\`

EOF

    log_info "Session report written to: ${REPORT_FILE}"
}

print_summary_report() {
    echo
    echo -e "${C_BOLD}${C_GREEN}  FINAL SESSION SUMMARY${C_RESET}"
    echo -e "${C_DIM}  ────────────────────────────────────────────────${C_RESET}"

    case "$MODE" in
        dry-run)
            echo -e "  ${C_BOLD}Mode:${C_RESET}                       Analysis (dry-run) — nothing deleted"
            ;;
        plan)
            echo -e "  ${C_BOLD}Mode:${C_RESET}                       Plan — plan file generated"
            ;;
        *)
            if [[ "$REMOVE_MODE" == "quarantine" ]]; then
                echo -e "  ${C_BOLD}Freed directly:${C_RESET}      ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
                echo -e "  ${C_BOLD}Quarantined:${C_RESET}             ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_QUARANTINED_BYTES")${C_RESET} (${TOTAL_QUARANTINED_ITEMS} items)"
            elif [[ "$MODE" == "restore" ]]; then
                echo -e "  ${C_BOLD}Restored:${C_RESET}                 ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_RESTORED_BYTES")${C_RESET} (${TOTAL_RESTORED_ITEMS} items)"
            elif [[ "$MODE" == "purge" ]]; then
                echo -e "  ${C_BOLD}Purged:${C_RESET}                   ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
            else
                echo -e "  ${C_BOLD}Freed directly:${C_RESET}      ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
                echo -e "  ${C_BOLD}Quarantined:${C_RESET}             ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_QUARANTINED_BYTES")${C_RESET} (${TOTAL_QUARANTINED_ITEMS} items)"
            fi
            ;;
    esac

    echo -e "  ${C_BOLD}Potentially freeable:${C_RESET}   ${C_CYAN}$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")${C_RESET}"
    echo -e "  ${C_BOLD}Report File:${C_RESET}            ${C_DIM}${REPORT_FILE}${C_RESET}"
    echo -e "  ${C_BOLD}Journal File:${C_RESET}           ${C_DIM}${CLEANUP_JOURNAL_FILE}${C_RESET}"
    echo -e "${C_DIM}  ────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_DIM}  To open report: open \"${REPORT_FILE}\"${C_RESET}"
    echo
}
