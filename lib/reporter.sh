#!/usr/bin/env bash
# =============================================================================
# lib/reporter.sh — Markdown execution & summary report generator
#
# Generates a clear Markdown report at the end of every run.
#
# Bash 3.2 compatible.
# =============================================================================

# P1-2: the quarantine mode frees nothing until --purge-quarantine, so its
# headline must not be called "freeable".
_report_total_label() {
    if [[ "${REMOVE_MODE:-quarantine}" == "permanent" ]]; then
        printf '%s' "Potentially freeable space"
    else
        printf '%s' "To process (quarantined files free space only after --purge-quarantine)"
    fi
}

# F11: the report is written by one long function; redact the finished file.
generate_report() {
    local _rc=0
    _generate_report_raw "$@" || _rc=$?
    redact_file "$REPORT_FILE"
    return "$_rc"
}

_generate_report_raw() {
    local mode="${1:-${MODE}}"
    local _report_user _report_host _report_redaction=""
    if [[ "${REDACT_PATHS:-0}" == "1" ]]; then
        _report_user="(redacted)"; _report_host="(redacted)"
        _report_redaction="**Redaction:** user name, home path and host name hidden (--redact)  "
    else
        _report_user="$(whoami)"; _report_host="$(hostname)"
    fi
    local report_dir
    report_dir="$(dirname "$REPORT_FILE")"
    mkdir -p "$report_dir" 2>/dev/null || true

    cat << EOF > "$REPORT_FILE"
# macOS Cleanup — Session Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S')  
**Mode:** \`${mode}\`  
**Deletion Strategy:** \`${REMOVE_MODE:-quarantine}\`  
**User:** ${_report_user}  
**Host:** ${_report_host}  
${_report_redaction}
**OS Version:** $(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || echo "")  

---

## Session Summary

| Metric | Value |
|:-------|:------|
| $(_report_total_label) | **$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")** |
EOF
    # Phase 3: locations macOS did not let us read fully are not "0 B".
    local _unreadable
    _unreadable="$(analysis_unreadable_count 2>/dev/null)" || _unreadable=0
    if (( ${_unreadable:-0} > 0 )); then
        echo "| Not fully readable (macOS privacy or permissions) | ${_unreadable} locations — sizes there are lower bounds; see $(analysis_unreadable_file) |" >> "$REPORT_FILE"
    fi
    # P1-1: report-only bytes are sized but never removed; show them apart.
    if (( ${TOTAL_INFORMATIONAL_BYTES:-0} > 0 )); then
        echo "| Report-only (never freed by this tool) | $(bytes_to_human "$TOTAL_INFORMATIONAL_BYTES") |" >> "$REPORT_FILE"
    fi

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

    # One pass over the registry, split into counted and report-only categories
    # so no sized category is silently omitted. The rows show what was found
    # per category; the total below is the plan's executable sum (P1-1), so it
    # leaves out work this mode will not do (Homebrew counted once, /tmp in
    # quarantine mode, Docker) and the rows need not add up to it.
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
            needs-permanent) status_str="Not processed";  action_str="Outside HOME: quarantine mode skips it — needs --permanent" ;;
            backup-running) status_str="Not processed"; action_str="Time Machine was backing up — re-run later" ;;
            in-use)  status_str="Not processed";  action_str="In use by a running tool — close it and re-run" ;;
            failed)  status_str="Failed";         action_str="The cleanup command failed — see the log and re-run" ;;
            unavailable) status_str="Not processed"; action_str="The cleanup tool is not installed" ;;
            kept-newest) status_str="Kept";           action_str="Only each disk's newest local snapshot exists; it is kept" ;;
            volumes-unknown) status_str="Not processed"; action_str="Another mounted disk's snapshots could not be listed — eject it and re-run" ;;
            partial) status_str="Partly processed"; action_str="Items under HOME done; the rest is outside HOME — needs --permanent" ;;
            partially-cleaned) status_str="Partly processed"; action_str="Some items were removed; others failed or were skipped — see the log" ;;
            nothing-removed) status_str="Nothing removed"; action_str="Every item was skipped or already gone — see the log" ;;
        esac

        if [[ -z "$recorded_outcome" ]]; then
            case "$key" in
                tmp|system-logs)
                    # P1-2: outside HOME — only --permanent can process these.
                    status_str="Found"
                    if [[ "${REMOVE_MODE:-quarantine}" == "permanent" ]]; then
                        action_str="Run --interactive to process"
                        [[ "$key" == "tmp" ]] && action_str="Safe to clean"
                    else
                        action_str="Outside HOME: quarantine mode skips it — needs --permanent"
                    fi ;;
                user-caches|trash)
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

**Total — $(_report_total_label): $(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")**
$( (( ${TOTAL_INFORMATIONAL_BYTES:-0} > 0 )) && printf '\nReport-only, never freed by this tool: %s\n' "$(bytes_to_human "$TOTAL_INFORMATIONAL_BYTES")" )

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

    local _n_notes=0
    if [ "${NOTES_LIST+set}" = "set" ]; then _n_notes=${#NOTES_LIST[@]}; fi
    if (( ${#WARNINGS_LIST[@]} == 0 )); then
        echo "_No warnings recorded for this session._" >> "$REPORT_FILE"
    else
        for warn in "${WARNINGS_LIST[@]}"; do
            echo "- ⚠️  ${warn}" >> "$REPORT_FILE"
        done
    fi
    # Standing advisories: listed for the reader, never counted as warnings.
    if (( _n_notes > 0 )); then
        echo "" >> "$REPORT_FILE"
        for warn in "${NOTES_LIST[@]}"; do
            echo "- ℹ️  ${warn}" >> "$REPORT_FILE"
        done
    fi

    if [[ "$REMOVE_MODE" == "quarantine" && "$TOTAL_QUARANTINED_ITEMS" -gt 0 ]]; then
        cat << EOF >> "$REPORT_FILE"

---

## Quarantine Information

Items were moved to quarantine instead of permanent deletion:

- **Quarantine Directory:** \`${QUARANTINE_RUN_DIR}\`
- **Restore Manifest:** \`${CLEANUP_RESTORE_MANIFEST}\`
- **Restoration Command:** \`macos-cleanup --restore ${QUARANTINE_RUN_DIR##*/}\`

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

EOF

    # Only commands that exist in this version and make sense for this run.
    local _rr_run="${QUARANTINE_RUN_DIR:-}"
    _rr_run="${_rr_run%/}"; _rr_run="${_rr_run##*/}"
    {
        echo "---"
        echo
        echo "## How to Re-Run Cleanup"
        echo
        echo '```bash'
        echo "# Terminal interface: scan, preview, choose what to clean"
        echo "macos-cleanup"
        echo
        echo "# Plain terminal, one question per category"
        echo "macos-cleanup --cli --interactive"
        if [[ -n "${PLAN_FILE:-}" && -f "${PLAN_FILE:-}" ]]; then
            echo
            echo "# Apply this run's plan (SAFE operations; add --include-review for REVIEW)"
            echo "macos-cleanup apply --from-plan \"${PLAN_FILE}\""
        fi
        if [[ "${REMOVE_MODE:-}" == "quarantine" && "${TOTAL_QUARANTINED_ITEMS:-0}" -gt 0 && -n "$_rr_run" ]]; then
            echo
            echo "# Put back what this run moved to quarantine"
            echo "macos-cleanup --restore ${_rr_run}"
            echo
            echo "# Free that space for good (cannot be undone)"
            echo "macos-cleanup --purge-quarantine ${_rr_run}"
        fi
        echo '```'
        echo
    } >> "$REPORT_FILE"

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
        echo -e "  ${C_BOLD}$(_report_total_label):${C_RESET}   ${C_CYAN}$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")${C_RESET}"
        local _unreadable_n
        _unreadable_n="$(analysis_unreadable_count 2>/dev/null)" || _unreadable_n=0
        if (( ${_unreadable_n:-0} > 0 )); then
            echo -e "  ${C_YELLOW}Not fully readable:${C_RESET}     ${_unreadable_n} locations (macOS privacy or permissions); their sizes are lower bounds"
        fi
    fi

    if command -v diskutil &>/dev/null; then
        local target_vol="/"
        [[ -d "/System/Volumes/Data" ]] && target_vol="/System/Volumes/Data"
        local diskinfo=""
        if type optional_command_with_timeout >/dev/null 2>&1; then
            diskinfo=$(optional_command_with_timeout "${SCAN_TOOL_TIMEOUT:-20}" diskutil info "$target_vol" 2>/dev/null) || diskinfo=""
        else
            diskinfo=$(diskutil info "$target_vol" 2>/dev/null) || diskinfo=""
        fi
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

    echo -e "  ${C_BOLD}Report File:${C_RESET}            ${C_DIM}$(redact_path "$REPORT_FILE")${C_RESET}"
    echo -e "  ${C_BOLD}Journal File:${C_RESET}           ${C_DIM}$(redact_path "$CLEANUP_JOURNAL_FILE")${C_RESET}"
    echo -e "${C_DIM}  ────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_DIM}  Space held by Time Machine local snapshots is reclaimed automatically as snapshots expire, usually within 24 hours, or immediately under disk pressure.${C_RESET}"
    echo -e "${C_DIM}  To open report: open \"$(redact_path "$REPORT_FILE")\"${C_RESET}"
    echo
}
