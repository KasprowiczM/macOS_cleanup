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

    # One pass over the registry, split into what the headline total counts and
    # what it deliberately does not, so the itemised rows reconcile with the
    # "Total potentially freeable" line instead of silently omitting categories.
    local entry key label klass bytes size_cell status_str action_str recorded_outcome
    local -a report_only_rows=()

    for entry in "${CATEGORY_REGISTRY[@]}"; do
        key="${entry%%|*}"
        klass="${entry##*|}"
        label="$(category_label "$key")"
        bytes=$(catbytes_get "$key")
        (( bytes == 0 )) && continue

        # The "time-machine" ledger entry holds a SNAPSHOT COUNT, not a byte
        # size — an APFS local snapshot has no assignable size. Without this the
        # markdown report rendered 14 local snapshots as "14 B".
        if [[ "$klass" == "count" ]]; then
            size_cell="${bytes} $(t "cli_units_pcs")"
        else
            size_cell="$(bytes_to_human "$bytes")"
        fi

        status_str="Reported"
        action_str="Review in interactive mode"

        # What actually happened wins over what the mode implies. Before this,
        # `user-caches` was printed as "Cleaned/Quarantined | Done" in every
        # interactive run — including the 2026-08-19 20:15 run where the user
        # declined it and the log recorded "User skipped cleanup".
        recorded_outcome="$(category_outcome "$key")"
        case "$recorded_outcome" in
            cleaned) status_str="Cleaned/Quarantined"; action_str="Done" ;;
            skipped) status_str="Skipped by you";      action_str="Still on disk — re-run to process" ;;
        esac

        if [[ -z "$recorded_outcome" ]]; then
            case "$key" in
                user-caches|trash|tmp)
                    # No outcome was recorded for this category, so the run never
                    # reached it. Do not claim it was cleaned.
                    status_str="Found"; action_str="Safe to clean" ;;
                system-caches|mail-total|mail-data|mail-downloads|browser-data)
                    status_str="Protected / Report-only"; action_str="Do not delete with rm" ;;
                browser-caches)
                    # No cleaner touches browser caches — telling the reader to
                    # "run --interactive to process" promised an action that does
                    # not exist. Clearing them behind a running browser's back
                    # corrupts its cache index, so the browser's own control is
                    # the correct route.
                    status_str="Report-only"; action_str="Clear from the browser's privacy settings" ;;
                app-leftovers|xcode-archives|android-avd|maven)
                    status_str="Needs Decision"; action_str="Manual verification required" ;;
                *)
                    status_str="Found"; action_str="Run --interactive to process" ;;
            esac
        fi

        if [[ "$klass" == "report-only" ]]; then
            report_only_rows+=("| ${label} | **${size_cell}** | ${status_str} | ${action_str} |")
        else
            echo "| ${label} | **${size_cell}** | ${status_str} | ${action_str} |" >> "$REPORT_FILE"
        fi
    done

    if (( ${#report_only_rows[@]} > 0 )); then
        cat << EOF >> "$REPORT_FILE"

### Report-only — sized but NOT included in the total

These are never removed by this script, so their size is deliberately excluded
from the figure below.

| Category | Size | Status | Recommended Action |
|:---------|:-----|:-------|:-------------------|
EOF
        local row
        for row in "${report_only_rows[@]}"; do
            echo "$row" >> "$REPORT_FILE"
        done
    fi

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
        list-quarantine|list)
            echo -e "  ${C_BOLD}Mode:${C_RESET}                       Quarantine List — listing entries"
            ;;
        restore)
            echo -e "  ${C_BOLD}Restored:${C_RESET}                 ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_RESTORED_BYTES")${C_RESET} ($(t "items_count" "$TOTAL_RESTORED_ITEMS"))"
            ;;
        purge)
            echo -e "  ${C_BOLD}Purged:${C_RESET}                   ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
            ;;
        *)
            echo -e "  ${C_BOLD}Freed directly:${C_RESET}      ${C_GREEN}${C_BOLD}$(bytes_to_human "$TOTAL_CLEANED_BYTES")${C_RESET}"
            echo -e "  ${C_BOLD}Quarantined:${C_RESET}             ${C_YELLOW}${C_BOLD}$(bytes_to_human "$TOTAL_QUARANTINED_BYTES")${C_RESET} ($(t "items_count" "$TOTAL_QUARANTINED_ITEMS"))"
            ;;
    esac

    if [[ "$MODE" != "list-quarantine" && "$MODE" != "list" ]]; then
        echo -e "  ${C_BOLD}Potentially freeable:${C_RESET}   ${C_CYAN}$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")${C_RESET}"
    fi

    if command -v diskutil &>/dev/null; then
        local target_vol="/"
        [[ -d "/System/Volumes/Data" ]] && target_vol="/System/Volumes/Data"
        local diskinfo=""
        diskinfo=$(diskutil info "$target_vol" 2>/dev/null) || diskinfo=""
        local free_now="" purgeable_now=""
        free_now=$(printf '%s\n' "$diskinfo" | grep -iE "(Container Free Space|Volume Free Space|Free Space)" | head -1 | sed 's/.*:[[:space:]]*//' | sed 's/ (.*//' | sed 's/[[:space:]]*$//') || free_now=""
        purgeable_now=$(printf '%s\n' "$diskinfo" | grep -i "Purgeable" | head -1 | sed 's/.*:[[:space:]]*//' | sed 's/ (.*//' | sed 's/[[:space:]]*$//') || purgeable_now=""

        if [[ -n "$purgeable_now" ]]; then
            echo -e "  ${C_BOLD}Purgeable (APFS):${C_RESET}       ${C_YELLOW}${purgeable_now}${C_RESET}   ← snapshot-retained; returns automatically"
        fi
        if [[ -n "$free_now" ]]; then
            echo -e "  ${C_BOLD}Free now:${C_RESET}               ${C_GREEN}${free_now}${C_RESET}"
        fi
    fi

    echo -e "  ${C_BOLD}Report File:${C_RESET}            ${C_DIM}${REPORT_FILE}${C_RESET}"
    echo -e "  ${C_BOLD}Journal File:${C_RESET}           ${C_DIM}${CLEANUP_JOURNAL_FILE}${C_RESET}"
    echo -e "${C_DIM}  ────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_DIM}  Space held by Time Machine local snapshots is reclaimed automatically as snapshots expire, usually within 24 hours, or immediately under disk pressure.${C_RESET}"
    echo -e "${C_DIM}  To open report: open \"${REPORT_FILE}\"${C_RESET}"
    echo
}
