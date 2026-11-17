#!/usr/bin/env bash
# =============================================================================
# lib/executor.sh — the single executor (R07; findings F05, F06, F07, F15)
#
# Every mutating mode runs the SAME list of operations, the plan built by
# build_cleanup_plan_from_analysis (or loaded by apply --from-plan), through
# ONE loop, execute_ops. Modes differ only in the consent provider that marks
# which operations may run:
#
#   consent_interactive   --interactive: v3 prompt granularity (one prompt per
#                         v3 cleaner group, V4 §10.1), registry order; docker,
#                         simulator runtimes, local snapshots and iOS backups
#                         keep their extra confirmations
#   consent_auto          --auto-safe: an op runs only when its category's
#                         effective mode is auto AND the registry row is
#                         regenerable + quarantine + unattended=yes AND the op
#                         is a remove that is not DANGEROUS (V4 §13)
#   consent_plan_file     apply --from-plan: SAFE; REVIEW with --include-review
#                         and its confirmation; DANGEROUS never; from_file=no
#                         categories are plan_rejected
#   consent_unattended    --unattended: like auto, never a native command,
#                         quarantine only (V4 §10.2)
#
# Every approved op is re-checked at the sink (identity, category roots,
# protection and policy escalation, owner process, recent_days) before
# safe_remove or execute_plan_native_command runs. Category outcomes are
# computed from the per-item results, in every mode (F05).
#
# Bash 3.2: no associative arrays; per-op and per-category state lives in
# eval-named scalars (_EXA_<i>, _EXC_<id>_<field>), every array expansion
# that can be empty is guarded.
# =============================================================================

_EXECUTOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if ! type reg_load >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${_EXECUTOR_LIB_DIR}/registry.sh"
fi
if ! type mc_item_end >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${_EXECUTOR_LIB_DIR}/events.sh"
fi

# Category modes (V4 §1.3 category-modes.tsv, §13.1 defaults): the one
# definition is mc_category_mode in lib/paths.sh (config/defaults.sh loads it).
if ! type mc_category_mode >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${_EXECUTOR_LIB_DIR}/paths.sh"
fi

# _exc_mode <id> — REPLY = auto | review | skip (skip for an unknown id).
_exc_mode() {
    mc_category_mode "${1:-}" >/dev/null 2>&1 || REPLY="skip"
    case "$REPLY" in auto|review|skip) ;; *) REPLY="skip" ;; esac
}

# ---------------------------------------------------------------------------
# Helpers moved from the old cleaners (lib/cleaner.sh)
# ---------------------------------------------------------------------------

# native_tool_available <tool> — the one check that a native tool is
# installed, so a test can say "not installed" without hiding /usr/bin.
native_tool_available() {
    command -v "${1:-}" >/dev/null 2>&1
}

# category_max_risk <path> [<path>...] → SAFE | REVIEW | DANGEROUS — the risk
# a consent prompt shows: the highest policy risk of the paths with REVIEW as
# the default (v3 prompt semantics; per-op risks stay in the plan).
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

# Phase 3: tm_snapshot_date <name> — YYYY-MM-DD-HHMMSS from a snapshot name.
tm_snapshot_date() {
    printf '%s\n' "${1:-}" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | head -1
}

# Phase 3: tm_backup_running — true unless `tmutil status` positively reports
# `Running = 0;`. An unreadable status counts as running: snapshots are never
# deleted under a backup in progress.
tm_backup_running() {
    local status
    status="$(tmutil status 2>/dev/null)" || return 0
    if printf '%s\n' "$status" | grep -Eq '^[[:space:]]*Running = 0;'; then
        return 1
    fi
    return 0
}

# tm_other_volume_newest_dates — the newest local Time Machine snapshot date
# of every other writable APFS volume, one per line.
# `tmutil deletelocalsnapshots <date>` deletes that date on all mounted disks,
# so such a date must be kept. The startup disk (/ and /System/Volumes/*) is
# handled by the caller; read-only mounts (simulator runtimes, disk images)
# cannot lose snapshots. Fails when the mount table cannot be read or parsed,
# or a volume's snapshot list cannot be read.
tm_other_volume_newest_dates() {
    local mounts mline rest mp opts listing line d newest
    mounts="$(mount 2>/dev/null)" || return 1
    while IFS= read -r mline; do
        case "$mline" in *" (apfs, "*) ;; *) continue ;; esac
        rest="${mline#* on }"
        mp="${rest% (apfs, *}"
        opts="${rest##* (apfs, }"
        [[ "$rest" != "$mline" && "$mp" != "$rest" && "$mp" == /* ]] || return 1
        case "$mp" in /|/System/Volumes/*) continue ;; esac
        case ", ${opts%)}," in *", read-only,"*) continue ;; esac
        listing="$(tmutil listlocalsnapshots "$mp" 2>/dev/null)" || return 1
        newest=""
        while IFS= read -r line; do
            case "$line" in com.apple.TimeMachine.*) ;; *) continue ;; esac
            d="$(tm_snapshot_date "$line")" || d=""
            [[ -n "$d" && "$d" > "$newest" ]] && newest="$d"
        done <<< "$listing"
        [[ -z "$newest" ]] || echo "$newest"
    done <<< "$mounts"
    return 0
}

# ---------------------------------------------------------------------------
# Consent state
#   _EXA_<i>=1        op i approved (also listed in MC_APPROVED, newline-delimited
#                     op ids, V4 §6.2)
#   _EXD_<i>=reason   op i not run, with this reason
#   _EXW_<i>=1        op i withdrawn: not an item of this run at all (the kept
#                     newest local snapshot)
# An op that is neither approved nor denied is not part of the clean phase.
# ---------------------------------------------------------------------------
MC_APPROVED=""
EXEC_PROVIDER=""
EXEC_ANY_FAILED=0
EXEC_CATEGORIES_RUN=""

_exc_reset() {
    local i count
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        unset "_EXA_${i}" "_EXD_${i}" "_EXW_${i}"
    done
    MC_APPROVED=""
    EXEC_ANY_FAILED=0
    EXEC_CATEGORIES_RUN=""
}

_exc_approve() {
    eval "_EXA_${1}=1"
    unset "_EXD_${1}"
    MC_APPROVED="${MC_APPROVED}${PLAN_OP_IDS[$1]}"$'\n'
}

_exc_deny() {
    eval "_EXD_${1}=\"\$2\""
}

_exc_withdraw() {
    eval "_EXW_${1}=1"
}

_exc_is_approved() {
    local v
    eval "v=\"\${_EXA_${1}:-}\""
    [[ "$v" == "1" ]]
}

# _exc_state <i> — REPLY = approved | denied | withdrawn | none
_exc_state() {
    local v
    eval "v=\"\${_EXW_${1}:-}\""
    if [[ "$v" == "1" ]]; then REPLY=withdrawn; return 0; fi
    eval "v=\"\${_EXA_${1}:-}\""
    if [[ "$v" == "1" ]]; then REPLY=approved; return 0; fi
    eval "v=\"\${_EXD_${1}:-}\""
    if [[ -n "$v" ]]; then REPLY=denied; return 0; fi
    REPLY=none
}

_exc_deny_reason() {
    eval "REPLY=\"\${_EXD_${1}:-user_declined}\""
}

# _exc_executable <i> — a remove or native op (interactive-only natives too).
_exc_executable() {
    case "${PLAN_OP_ACTIONS[$1]}" in
        remove_path|native_command) return 0 ;;
    esac
    return 1
}

# _exc_ops_of <category> — REPLY = space-separated indices of its executable
# ops, in plan order.
_exc_ops_of() {
    local want="$1" i count out=""
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        [[ "${PLAN_OP_CATEGORIES[$i]}" == "$want" ]] || continue
        _exc_executable "$i" || continue
        out="${out} ${i}"
    done
    REPLY="$out"
}

# _exc_has_ops_of <category> [any] — has executable (or, with 'any', any) ops.
_exc_has_ops_of() {
    local want="$1" any="${2:-}" i count
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        [[ "${PLAN_OP_CATEGORIES[$i]}" == "$want" ]] || continue
        if [[ -n "$any" ]] || _exc_executable "$i"; then
            return 0
        fi
    done
    return 1
}

# _exc_bytes_of <indices...> — REPLY = sum of the ops' estimated bytes.
_exc_bytes_of() {
    local i sum=0 b
    for i in "$@"; do
        b="${PLAN_OP_BYTES[$i]:-0}"
        case "$b" in ''|*[!0-9]*) b=0 ;; esac
        sum=$(( sum + b ))
    done
    REPLY="$sum"
}

# _exc_reg <id> <column> — REPLY = registry field ("" when unknown).
_exc_reg() {
    reg_get "$1" "$2" 2>/dev/null || REPLY=""
}

# ---------------------------------------------------------------------------
# Interactive consent groups — the v3 prompt granularity (V4 §10.1). One
# prompt per v3 cleaner: the log prompt covers user and system logs, the
# package-manager prompt covers every developer cache.
# ---------------------------------------------------------------------------
_EXC_DEVCACHE_IDS="npm npx yarn pnpm pnpm-stale pip brew gradle cocoapods cargo swift-pm gem bundler composer"

_exc_group_of() {
    case "$1" in
        user-logs|system-logs) REPLY="logs" ;;
        npm|npx|yarn|pnpm|pnpm-stale|pip|brew|gradle|cocoapods|cargo|swift-pm|gem|bundler|composer) REPLY="devcaches" ;;
        *) REPLY="$1" ;;
    esac
}

_exc_group_ids() {
    case "$1" in
        logs) REPLY="user-logs system-logs" ;;
        devcaches) REPLY="$_EXC_DEVCACHE_IDS" ;;
        *) REPLY="$1" ;;
    esac
}

# _exc_offer <group> — sets EXC_OFFERED (indices the prompt covers) and
# EXC_NEEDS_PERM (count left out because quarantine cannot move them);
# denies ops of categories in mode skip and ops outside HOME in quarantine.
_exc_offer() {
    local ids i mode cat ops
    EXC_OFFERED=""
    EXC_NEEDS_PERM=0
    EXC_GROUP_TOTAL=0
    _exc_group_ids "$1"; ids="$REPLY"
    for cat in $ids; do
        _exc_ops_of "$cat"; ops="$REPLY"
        [[ -n "$ops" ]] || continue
        _exc_mode "$cat"; mode="$REPLY"
        for i in $ops; do
            EXC_GROUP_TOTAL=$(( EXC_GROUP_TOTAL + 1 ))
            if [[ "$mode" == "skip" ]]; then
                _exc_deny "$i" user_declined
                continue
            fi
            # A path that is already gone is offered: the sink reports not_found.
            if [[ "${PLAN_OP_ACTIONS[$i]}" == "remove_path" && "${REMOVE_MODE:-quarantine}" != "permanent" ]] \
                && [[ -e "${PLAN_OP_PATHS[$i]}" || -L "${PLAN_OP_PATHS[$i]}" ]] \
                && ! is_user_space_path "${PLAN_OP_PATHS[$i]}"; then
                _exc_deny "$i" needs_permanent
                EXC_NEEDS_PERM=$(( EXC_NEEDS_PERM + 1 ))
                continue
            fi
            EXC_OFFERED="${EXC_OFFERED} ${i}"
        done
    done
}

# _exc_paths_str <indices...> — REPLY = "p1|p2|" of remove/native paths.
_exc_paths_str() {
    local i out=""
    for i in "$@"; do
        [[ "${PLAN_OP_SCOPE[$i]:-}" == "interactive" ]] && continue
        [[ -n "${PLAN_OP_PATHS[$i]}" ]] || continue
        out="${out}${PLAN_OP_PATHS[$i]}|"
    done
    REPLY="$out"
}

# _exc_group_risk <group> <indices...> — the prompt risk (v3 semantics).
_exc_group_risk() {
    local group="$1" i
    shift
    local -a paths=()
    # Natives without a host path are REVIEW, as the plan rates them (v3 rated
    # the words "simulators"/"docker" as paths, relative to the cwd).
    case "$group" in
        simulators|docker|sim-runtimes) echo "REVIEW"; return 0 ;;
    esac
    for i in "$@"; do
        [[ "${PLAN_OP_SCOPE[$i]:-}" == "interactive" ]] && continue
        [[ -n "${PLAN_OP_PATHS[$i]}" ]] && paths+=("${PLAN_OP_PATHS[$i]}")
    done
    if (( ${#paths[@]} > 0 )); then
        category_max_risk "${paths[@]}"
    else
        echo "REVIEW"
    fi
}

# _exc_decide <rc> <risk> <indices...> — record the answer of confirm_category.
_exc_decide() {
    local rc="$1" risk="$2" i reason="user_declined"
    shift 2
    if (( rc == 0 )); then
        # A DANGEROUS op never runs, whatever the answer.
        for i in "$@"; do
            if [[ "${PLAN_OP_RISKS[$i]}" == "DANGEROUS" ]]; then
                _exc_deny "$i" dangerous_blocked
            else
                _exc_approve "$i"
            fi
        done
        return 0
    fi
    if [[ "$risk" == "DANGEROUS" ]]; then
        reason="dangerous_blocked"
    elif [[ "${NON_INTERACTIVE:-0}" == "1" && "${AUTO_YES:-0}" == "1" && "$risk" != "SAFE" ]]; then
        reason="review_not_included"
    fi
    for i in "$@"; do _exc_deny "$i" "$reason"; done
}

# _exc_report_note <id> — the v3 interactive notes for report-only categories.
_exc_report_note() {
    local id="$1" i count total=0 b total_h
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        [[ "${PLAN_OP_CATEGORIES[$i]}" == "$id" ]] || continue
        b="${PLAN_OP_BYTES[$i]:-0}"; case "$b" in ''|*[!0-9]*) b=0 ;; esac
        total=$(( total + b ))
    done
    total_h="$(bytes_to_human "$total")"
    case "$id" in
        system-caches)
            print_section "Report: $(t "system_caches")"
            print_info "Size: ${total_h}"
            print_info "$(t "system_cache_notice_1")"
            print_info "$(t "system_cache_notice_2")"
            record_user_decision "System Caches: ${total_h} — report-only; SIP/system managed"
            print_skip "System Caches (/Library/Caches) report-only."
            ;;
        app-leftovers)
            print_warning_box "$(t "app_leftovers_box_title")" \
                "$(t "app_leftovers_box_1")" \
                "applications. Verify before deletion!" \
                "$(t "app_leftovers_box_2")" \
                "$(t "app_leftovers_box_3")"
            print_section "Report: App leftovers (${total_h})"
            for (( i=0; i<count; i++ )); do
                [[ "${PLAN_OP_CATEGORIES[$i]}" == "$id" ]] && echo "  - ${PLAN_OP_PATHS[$i]}"
            done
            record_user_decision "App leftovers: ${total_h} — $(t "app_leftovers_rec")"
            print_skip "$(t "app_leftovers_skip")"
            ;;
        xcode-archives) record_user_decision "Xcode Archives: ${total_h} — $(t "archives_rec")" ;;
        maven)          record_user_decision "Maven ~/.m2/repository: ${total_h} — $(t "maven_rec")" ;;
        android-avd)    record_user_decision "Android AVD: ${total_h} — $(t "android_avd_rec")" ;;
    esac
}

# _exc_consent_tm — local snapshots: the newest of every disk is kept, nothing
# is deleted while a backup runs, then confirm_time_machine_snapshots.
_exc_consent_tm() {
    local i d newest="" keep_dates="" seen=" " names="" n=0
    local -a deletable=()
    for i in $EXC_OFFERED; do
        d="$(tm_snapshot_date "${PLAN_OP_PATHS[$i]}")" || d=""
        [[ -n "$d" && "$d" > "$newest" ]] && newest="$d"
    done
    if (( EXC_GROUP_TOTAL > 1 )); then
        if ! keep_dates="$(tm_other_volume_newest_dates)"; then
            print_warn "Could not list the local snapshots of every mounted disk. Deleting by date affects all disks, so local snapshots are left alone."
            record_skipped_item "Local Time Machine snapshots: another mounted disk could not be checked"
            for i in $EXC_OFFERED; do _exc_deny "$i" unknown; done
            # shellcheck disable=SC2034  # read via eval in _exc_mark_outcome
            EXC_OUTCOME_OVERRIDE_tm_snapshots="volumes-unknown"
            return 0
        fi
    fi
    for i in $EXC_OFFERED; do
        d="$(tm_snapshot_date "${PLAN_OP_PATHS[$i]}")" || d=""
        # One op per date: deletelocalsnapshots works by date, on every
        # mounted disk, so another APFS volume's newest date is kept too.
        if [[ -z "$d" || "$d" == "$newest" ]]; then _exc_withdraw "$i"; continue; fi
        case $'\n'"${keep_dates}"$'\n' in *$'\n'"${d}"$'\n'*) _exc_withdraw "$i"; continue ;; esac
        case "$seen" in *" ${d} "*) _exc_withdraw "$i"; continue ;; esac
        seen="${seen}${d} "
        deletable+=("$i")
        names="${names}${PLAN_OP_PATHS[$i]}"$'\n'
        n=$(( n + 1 ))
    done
    if (( n == 0 )); then
        print_info "Local Time Machine snapshots: only the newest of each disk exists; it is kept."
        # shellcheck disable=SC2034  # read via eval in _exc_mark_outcome
        EXC_OUTCOME_OVERRIDE_tm_snapshots="kept-newest"
        return 0
    fi
    if tm_backup_running; then
        print_warn "Time Machine is backing up (or its status is unknown); local snapshots are left alone."
        record_skipped_item "Local Time Machine snapshots: backup in progress or status unknown"
        for i in "${deletable[@]}"; do _exc_deny "$i" backup_running; done
        return 0
    fi
    if ! confirm_time_machine_snapshots "$names" "${n} snapshots"; then
        print_skip "$(t "skipped_category"): local Time Machine snapshots"
        record_skipped_item "Local Time Machine snapshots"
        for i in "${deletable[@]}"; do _exc_deny "$i" user_declined; done
        return 0
    fi
    for i in "${deletable[@]}"; do _exc_approve "$i"; done
    print_section "Cleaning: local Time Machine snapshots (newest kept: ${newest})"
    print_info "Each date is deleted on every mounted disk; each disk's newest snapshot is kept."
}

# _exc_consent_ios — confirm_ios_backups for the category, then one prompt per
# backup.
_exc_consent_ios() {
    local i list="" total=0 b device_name info_plist bk_size
    for i in $EXC_OFFERED; do
        list="${list}${PLAN_OP_PATHS[$i]}"$'\n'
        b="${PLAN_OP_BYTES[$i]:-0}"; case "$b" in ''|*[!0-9]*) b=0 ;; esac
        total=$(( total + b ))
    done
    if ! confirm_ios_backups "$list" "$(bytes_to_human "$total")"; then
        print_skip "$(t "skipped_category"): iOS backups"
        record_skipped_item "Local iOS backups (category cancelled by user)"
        for i in $EXC_OFFERED; do _exc_deny "$i" user_declined; done
        return 0
    fi
    print_section "Cleaning: iOS backups (one by one)"
    for i in $EXC_OFFERED; do
        device_name="$(t "unknown_device")"
        info_plist="${PLAN_OP_PATHS[$i]}/Info.plist"
        [[ -f "$info_plist" ]] && \
            device_name=$(defaults read "$info_plist" "Device Name" 2>/dev/null || t "unknown_device")
        bk_size=$(path_size_human_memo "${PLAN_OP_PATHS[$i]}")
        PLAN_OP_LABELS[$i]="$device_name"
        echo
        if ask_yes_no "Remove backup: '${device_name}' (${bk_size})?" "no" "ios-backups"; then
            _exc_approve "$i"
        else
            print_skip "Kept backup: $device_name"
            record_skipped_item "iOS backup retained: ${device_name}"
            _exc_deny "$i" user_declined
        fi
    done
}

# _exc_consent_group <group> — one v3 prompt.
_exc_consent_group() {
    local group="$1" risk size_h title="" what="" safe_if="" consequence_mode i label
    local -a offered=()
    _exc_offer "$group"
    if (( EXC_NEEDS_PERM > 0 )); then
        case "$group" in
            logs)  print_skip "Log files outside HOME: $(t "clean_needs_permanent")" ;;
            diagnostic-reports) print_skip "Diagnostic reports outside HOME: $(t "clean_needs_permanent")" ;;
            tmp)   if [[ -z "$EXC_OFFERED" ]]; then
                       print_skip "Temporary files (/tmp): $(t "clean_needs_permanent")"
                   else
                       print_skip "Temporary files outside HOME: $(t "clean_needs_permanent")"
                   fi ;;
            *)     print_skip "${group}: $(t "clean_needs_permanent")" ;;
        esac
    fi
    [[ -n "$EXC_OFFERED" ]] || return 0
    for i in $EXC_OFFERED; do offered+=("$i"); done

    case "$group" in
        tm-snapshots) _exc_consent_tm; return 0 ;;
        ios-backups)  _exc_consent_ios; return 0 ;;
        xcode-derived)
            # Phase 3: removing DerivedData under a running build breaks it.
            if cache_owner_running xcode_derived; then
                print_skip "Xcode is running; DerivedData is left alone: ${PLAN_OP_PATHS[${offered[0]}]}"
                record_skipped_item "Xcode DerivedData in use (Xcode or xcodebuild running)"
                for i in "${offered[@]}"; do _exc_deny "$i" in_use; done
                return 0
            fi ;;
        sim-runtimes)
            print_section "Cleaning: unusable simulator runtimes"
            if cache_owner_running sim_runtimes; then
                print_skip "Xcode, Simulator or xcodebuild is running; simulator runtimes are left alone."
                record_skipped_item "Simulator runtimes in use (Xcode, Simulator or xcodebuild running)"
                for i in "${offered[@]}"; do _exc_deny "$i" in_use; done
                return 0
            fi ;;
    esac

    _exc_bytes_of "${offered[@]}"
    size_h="$(bytes_to_human "$REPLY")"
    _exc_paths_str "${offered[@]}"
    local paths_str="$REPLY"
    risk="$(_exc_group_risk "$group" "${offered[@]}")"
    consequence_mode="${REMOVE_MODE:-quarantine}"

    case "$group" in
        trash)
            title="$(t "trash") (~/.Trash)"; paths_str=""
            what="$(t "clean_trash_what")"; safe_if="$(t "clean_trash_safe_if")" ;;
        user-caches)
            title="$(t "user_caches") (~/Library/Caches)"
            what="$(t "clean_user_cache_what")"; safe_if="$(t "clean_user_cache_safe_if")" ;;
        app-caches)
            title="$(t "app_caches") allowlisted (SAFE)"
            what="$(t "clean_auto_safe_what")"; safe_if="$(t "clean_auto_safe_safe_if")" ;;
        app-caches-review)
            echo
            echo -e "  ${C_BOLD}$(t "category_review_title") (${#offered[@]}):${C_RESET}"
            for i in "${offered[@]}"; do
                label="${PLAN_OP_LABELS[$i]:-${PLAN_OP_PATHS[$i]##*/}}"
                echo -e "    ${C_YELLOW}• ${label}${C_RESET} ($(path_size_human_memo "${PLAN_OP_PATHS[$i]}"))"
                echo -e "      ${C_DIM}Path: ${PLAN_OP_PATHS[$i]}${C_RESET}"
                echo -e "      ${C_DIM}$(app_cache_description "$label")${C_RESET}"
                echo -e "      ${C_CYAN}$(app_cache_recommendation "$label")${C_RESET}"
            done
            title="$(t "category_review_title")"
            what="$(t "category_review_what")"; safe_if="$(t "category_review_safe_if")" ;;
        logs)
            title="Log files (> $LOG_MAX_AGE_DAYS days)"
            what="$(t "clean_logs_what")"; safe_if="$(t "clean_logs_safe_if")" ;;
        diagnostic-reports)
            title="Diagnostic Reports / Crash Logs"
            what="$(t "clean_crash_logs_what")"; safe_if="$(t "clean_crash_logs_safe_if")" ;;
        tmp)
            title="Temporary files (/tmp)"
            what="$(t "clean_tmp_what")"; safe_if="$(t "clean_tmp_safe_if")" ;;
        xcode-derived)
            title="Xcode DerivedData"
            what="$(t "xcode_derived_what")"; safe_if="Safe if you accept longer build time for the next build." ;;
        device-support)
            print_warning_box "$(t "xcode_support_box_title")" \
                "$(t "xcode_support_box_1")" \
                "$(t "xcode_support_box_2")" \
                "$(t "xcode_support_box_3")" \
                "" \
                "$(t "xcode_support_box_4")" \
                "$(t "xcode_support_box_5")"
            title="$(t "xcode_support_box_title")"
            what="$(t "xcode_support_what")"; safe_if="$(t "xcode_support_safe_if")" ;;
        simulators)
            print_warning_box "iOS Simulators" \
                "$(t "simulators_box_1")" \
                "$(t "simulators_box_2")"
            title="Unavailable iOS Simulators"; paths_str=""; consequence_mode="native"
            what="$(t "simulators_what")"; safe_if="$(t "simulators_safe_if")" ;;
        sim-runtimes)
            title="Unusable simulator runtimes"; paths_str=""; consequence_mode="native"
            _exc_bytes_of "${offered[@]}"; (( REPLY > 0 )) || size_h="size unknown"
            what="Simulator runtimes that simctl marks unusable, deleted by: xcrun simctl runtime delete --unusable"
            safe_if="Safe if you do not need these runtimes; Xcode can download runtimes again." ;;
        devcaches)
            echo
            echo -e "  ${C_BOLD}$(t "package_managers_title"):${C_RESET}"
            for i in "${offered[@]}"; do
                echo -e "    ${C_DIM}• ${PLAN_OP_CATEGORIES[$i]}: ${PLAN_OP_PATHS[$i]}${C_RESET}"
            done
            title="$(t "package_managers_title")"; consequence_mode="native"
            what="Package manager caches for development tools."; safe_if="$(t "package_managers_safe_if")" ;;
        docker)
            title="Docker: dangling images / stopped containers"; paths_str=""; consequence_mode="native"
            what="Unused images, stopped containers, networks, and build cache removed by docker system prune."
            safe_if="Safe if you do not have important data in stopped containers." ;;
        installers)
            title="Old installers (DMG/PKG/ISO)"
            what="$(t "downloads_ok")"; safe_if="Safe if you have internet access or do not need old versions." ;;
        *)
            label="$(category_label "$group")"
            title="$label"; what="$label" ;;
    esac

    local rc=0
    confirm_category \
        --title       "$title" \
        --size        "$size_h" \
        --paths       "$paths_str" \
        --what        "$what" \
        --consequence "$(consequence_for_mode "$risk" "$consequence_mode")" \
        --safe-if     "$safe_if" \
        --risk        "$risk" \
        --group       "${PLAN_OP_CATEGORIES[${offered[0]}]}" || rc=$?
    _exc_decide "$rc" "$risk" "${offered[@]}"
}

consent_interactive() {
    local i id group done_groups=" "
    for (( i=0; i<REG_COUNT; i++ )); do
        id="${REG_ID[$i]}"
        if ! _exc_has_ops_of "$id"; then
            if [[ "${REG_TIER[$i]}" == "report" ]] && _exc_has_ops_of "$id" any; then
                _exc_report_note "$id"
            fi
            continue
        fi
        _exc_group_of "$id"; group="$REPLY"
        case "$done_groups" in *" ${group} "*) continue ;; esac
        done_groups="${done_groups}${group} "
        _exc_consent_group "$group"
    done
}

# _exc_auto_eligible <i> — V4 §13.1: effective mode auto AND a regenerable,
# quarantine, unattended=yes row AND a remove op that is not DANGEROUS.
# REPLY = deny reason.
_exc_auto_eligible() {
    local i="$1" cat="${PLAN_OP_CATEGORIES[$1]}"
    REPLY="review_not_included"
    [[ "${PLAN_OP_ACTIONS[$i]}" == "remove_path" && -z "${PLAN_OP_SCOPE[$i]:-}" ]] || return 1
    if [[ "${PLAN_OP_RISKS[$i]}" == "DANGEROUS" ]]; then REPLY="dangerous_blocked"; return 1; fi
    _exc_mode "$cat"; [[ "$REPLY" == "auto" ]] || return 1
    _exc_reg "$cat" tier;       [[ "$REPLY" == "regenerable" ]] || { REPLY="review_not_included"; return 1; }
    _exc_reg "$cat" undo;       [[ "$REPLY" == "quarantine" ]] || { REPLY="review_not_included"; return 1; }
    _exc_reg "$cat" unattended; [[ "$REPLY" == "yes" ]] || { REPLY="review_not_included"; return 1; }
    # V4 §13.1: never from the risk class alone — cleanup_rules.yaml keeps
    # "ask" (REVIEW) for these roots; the user's auto mode is the decision.
    # DANGEROUS is excluded above.
    if [[ "${REMOVE_MODE:-quarantine}" != "permanent" ]] \
        && [[ -e "${PLAN_OP_PATHS[$i]}" || -L "${PLAN_OP_PATHS[$i]}" ]] \
        && ! is_user_space_path "${PLAN_OP_PATHS[$i]}"; then
        REPLY="needs_permanent"
        return 1
    fi
    return 0
}

# consent_auto_confirm — the one auto-safe question (default no).
consent_auto_confirm() {
    ask_yes_no "$(t "cli_auto_safe_prompt")" "no"
}

# _exc_consent_selective — auto and unattended: approve eligible ops; an op
# of a category that has an approved op but is not eligible itself is
# skipped with its reason; every other category becomes a decision.
_exc_consent_selective() {
    local i count cat reason id k bytes
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        _exc_executable "$i" || continue
        if _exc_auto_eligible "$i"; then
            _exc_approve "$i"
        fi
    done
    for (( i=0; i<count; i++ )); do
        _exc_executable "$i" || continue
        _exc_is_approved "$i" && continue
        cat="${PLAN_OP_CATEGORIES[$i]}"
        if _exc_category_has_approved "$cat"; then
            _exc_auto_eligible "$i" || true
            reason="$REPLY"
            _exc_deny "$i" "$reason"
        fi
    done
    # Everything not cleaned here is a decision for the user.
    for (( k=0; k<REG_COUNT; k++ )); do
        id="${REG_ID[$k]}"
        _exc_has_ops_of "$id" any || continue
        _exc_category_has_approved "$id" && continue
        _exc_category_total "$id"; bytes="$REPLY"
        if [[ "${REG_UNIT[$k]}" == "count" ]]; then
            record_user_decision "$(category_label "$id"): ${bytes} $(t "cli_units_pcs") — $(t "cli_run_interactive_to_clean")"
        else
            record_user_decision "$(category_label "$id"): $(bytes_to_human "$bytes") — $(t "cli_run_interactive_to_clean")"
        fi
    done
}

_exc_category_has_approved() {
    local i count
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        [[ "${PLAN_OP_CATEGORIES[$i]}" == "$1" ]] || continue
        _exc_is_approved "$i" && return 0
    done
    return 1
}

# _exc_category_total <id> — REPLY = bytes (count for unit=count) of all its ops.
_exc_category_total() {
    local i count sum=0 b n=0
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        [[ "${PLAN_OP_CATEGORIES[$i]}" == "$1" ]] || continue
        n=$(( n + 1 ))
        b="${PLAN_OP_BYTES[$i]:-0}"; case "$b" in ''|*[!0-9]*) b=0 ;; esac
        sum=$(( sum + b ))
    done
    reg_get "$1" unit 2>/dev/null || REPLY=""
    if [[ "$REPLY" == "count" ]]; then REPLY="$n"; else REPLY="$sum"; fi
}

consent_auto() {
    _exc_consent_selective
}

# consent_unattended — like auto; no native command can be eligible (a native
# row is never undo=quarantine), the dispatcher forces quarantine mode.
consent_unattended() {
    if [[ "${REMOVE_MODE:-}" != "quarantine" ]]; then
        print_error "$(t exec_unattended_quarantine_only)"
        return 1
    fi
    _exc_consent_selective
}

consent_plan_file() {
    local i count id risk cat path bytes _exc_mode_now
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        id="${PLAN_OP_IDS[$i]}"; risk="${PLAN_OP_RISKS[$i]}"; cat="${PLAN_OP_CATEGORIES[$i]}"
        path="${PLAN_OP_PATHS[$i]}"; bytes="${PLAN_OP_BYTES[$i]:-0}"
        if ! _exc_executable "$i"; then
            print_skip "Plan ${id}: report_only does not apply changes."
            continue
        fi
        # F3: the category's CURRENT mode counts, not the one at plan time: a
        # category now set to skip, or in the report tier, is never executed.
        _exc_mode "$cat"
        _exc_mode_now="$REPLY"
        _exc_reg "$cat" tier
        if [[ "$_exc_mode_now" == "skip" || "$REPLY" == "report" ]]; then
            print_skip "Plan ${id}: category ${cat} is set to skip (or is report-only) now; not executed."
            cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "plan_rejected: category ${cat} mode is skip" "$cat"
            _exc_deny "$i" plan_rejected
            continue
        fi
        _exc_reg "$cat" from_file
        if [[ "$REPLY" != "yes" ]]; then
            print_skip "$(t exec_plan_not_from_file "$id" "$cat")"
            cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "plan_rejected: ${cat} is not executable from a plan" "$cat"
            _exc_deny "$i" plan_rejected
            continue
        fi
        case "$risk" in
            DANGEROUS)
                print_skip "Plan ${id}: DANGEROUS operations are never executed."
                cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "dangerous blocked" "$cat"
                _exc_deny "$i" dangerous_blocked
                ;;
            REVIEW)
                if [[ "${INCLUDE_REVIEW:-0}" != "1" ]]; then
                    print_skip "Plan ${id}: REVIEW skipped (add --include-review after conscious review)."
                    cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "review not included" "$cat"
                    _exc_deny "$i" review_not_included
                elif plan_require_review_confirmation "$path" "$id" "$cat"; then
                    _exc_approve "$i"
                else
                    cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "review confirmation failed" "$cat"
                    _exc_deny "$i" user_declined
                fi
                ;;
            SAFE)
                _exc_approve "$i"
                ;;
            *)
                print_skip "Plan ${id}: unknown risk '${risk}', skipping."
                _exc_deny "$i" unknown
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Sink re-checks and dispatch
# ---------------------------------------------------------------------------

# _exc_in_use_key <i> — REPLY = the owner key to check for this op, or "".
_exc_in_use_key() {
    local cat="${PLAN_OP_CATEGORIES[$1]}"
    _exc_reg "$cat" in_use
    if [[ -z "$REPLY" ]]; then
        REPLY="$(cache_owner_key_for_path "${PLAN_OP_PATHS[$1]}" 2>/dev/null)" || REPLY=""
    fi
}

# _exc_recent_days — the recent_days setting (0 = off).
_exc_recent_days() {
    # RECENT_DAYS: settings.conf / MACOS_CLEANUP_RECENT_DAYS, validated by
    # mc_load_settings (lib/paths.sh).
    local d="${RECENT_DAYS:-0}"
    case "$d" in ''|*[!0-9]*) d=0 ;; esac
    REPLY="$d"
}

# _exc_find_recent <path> <days> — 0: something under the path (two levels)
# changed within <days> days; 1: nothing did; 2: the check itself failed (an
# unreadable subfolder, find missing). `-print -quit` stops at the first hit,
# so there is no pipe whose SIGPIPE could swallow the answer (F1).
_exc_find_recent() {
    local path="$1" days="$2" hit="" rc=0 finder="/usr/bin/find"
    [[ -x "$finder" ]] || finder="find"
    hit="$("$finder" "$path" -maxdepth 2 -mtime "-${days}" -print -quit 2>/dev/null)" || rc=$?
    [[ -n "$hit" ]] && return 0
    (( rc == 0 )) && return 1
    return 2
}

# _exc_sink_check_remove <i> [no_identity] — 0 when the remove may run; else
# sets MC_LAST_*. no_identity is for a native op's fallback, which has no
# plan-time identity of its target.
_exc_sink_check_remove() {
    local i="$1" no_identity="${2:-}" path cat id risk ident cur explicit key days hit bytes
    path="${PLAN_OP_PATHS[$i]}"; cat="${PLAN_OP_CATEGORIES[$i]}"; id="${PLAN_OP_IDS[$i]}"
    risk="${PLAN_OP_RISKS[$i]}"; bytes="${PLAN_OP_BYTES[$i]:-0}"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        _mc_last skipped not_found 0
        return 1
    fi
    ident="${PLAN_OP_IDENTITY[$i]:-}"
    # F12: the path arrives with its exact bytes. normalize_path (a $(...)) drops
    # a trailing newline, so safe_remove would act on the stripped twin of a name
    # whose identity was just verified: such a path is not executed at all.
    case "$path" in
        *$'\n')
            print_skip "Plan ${id}: the path ends in a newline and cannot be handled safely; skipped."
            cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "path ends in a newline" "$cat"
            _mc_last skipped protected_path 0
            return 1 ;;
    esac
    # F12: an op without an identity (the path did not exist when the plan was
    # made, or a hand-edited plan) is a mismatch, never a free pass.
    cur="$(plan_path_identity "$path")"
    if [[ -z "$no_identity" ]] && [[ -z "$ident" || "$cur" != "$ident" ]]; then
        print_skip "$(t exec_identity_changed "$path")"
        cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "identity changed: ${ident:-none} -> ${cur:-none}" "$cat"
        _mc_last skipped identity_changed 0
        return 1
    fi
    if ! plan_root_allows "$cat" "$path"; then
        print_warn "$(t exec_outside_roots "$cat" "$path")"
        cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "outside category roots: ${cat}" "$cat"
        _mc_last skipped outside_category_root 0
        return 1
    fi
    if _plan_path_blocked_or_escalated "$path" "$risk"; then
        explicit="$(policy_explicit_risk_for_path "$path" 2>/dev/null || true)"
        print_warn "Plan ${id}: risk escalated (${risk}->${explicit:-protected}) or path protected — skipping."
        cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "risk escalated since plan: ${risk}->${explicit:-protected}" "$cat"
        if is_protected_path "$path"; then
            _mc_last skipped protected_path 0
        else
            _mc_last skipped risk_escalated 0
        fi
        return 1
    fi
    _exc_in_use_key "$i"; key="$REPLY"
    if [[ -n "$key" ]] && cache_owner_running "$key"; then
        print_skip "In use, not removed (${key}): ${path}"
        record_skipped_item "Cache in use by a running tool (${key}): ${path}"
        cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "in use: ${key}" "$cat"
        _mc_last skipped in_use 0
        return 1
    fi
    _exc_recent_days; days="$REPLY"
    if (( days > 0 )); then
        # F1: no pipe (find killed by SIGPIPE lost the hit under pipefail) and
        # an error in the check counts as "too recent": it fails closed.
        hit=0
        _exc_find_recent "$path" "$days" || hit=$?
        if (( hit != 1 )); then
            print_skip "$(t exec_too_recent "$days" "$path")"
            cleanup_journal_event "plan_apply_skipped" "$path" "" "$bytes" "skipped" "too recent (${days} days)" "$cat"
            _mc_last skipped too_recent 0
            return 1
        fi
    fi
    return 0
}

# _exc_fallback_allowed <tool> — the native tools whose cache v3 removed with
# safe_remove when the tool failed or was missing.
_exc_fallback_allowed() {
    case "${1:-}" in npm|yarn|pnpm|pip|brew|gem) return 0 ;; esac
    return 1
}

# _exc_run_bound_native <i> — an allowlisted command bound to its target.
_exc_run_bound_native() {
    local i="$1" path cmd cat id risk tool bytes explicit
    path="${PLAN_OP_PATHS[$i]}"; cmd="${PLAN_OP_COMMANDS[$i]}"; cat="${PLAN_OP_CATEGORIES[$i]}"
    id="${PLAN_OP_IDS[$i]}"; risk="${PLAN_OP_RISKS[$i]}"; bytes="${PLAN_OP_BYTES[$i]:-0}"
    if _plan_path_blocked_or_escalated "$path" "$risk"; then
        explicit="$(policy_explicit_risk_for_path "$path" 2>/dev/null || true)"
        print_warn "Plan ${id}: native target blocked (${risk}->${explicit:-protected}) or path protected — skipping."
        cleanup_journal_event "plan_apply_blocked" "$path" "" "$bytes" "blocked" "native target protected or risk escalated: ${risk}->${explicit:-protected}" "$cat"
        if is_protected_path "$path"; then _mc_last skipped protected_path 0; else _mc_last skipped risk_escalated 0; fi
        return 0
    fi
    print_cleaned "$(t "cleaning_cmd"): ${cat} (${cmd})"
    execute_plan_native_command "$cmd" "$bytes" "$path" "$cat" "$id" || true
    # v3 interactive fallback: a failed or missing npm/yarn/pnpm/pip/brew/gem
    # leaves its cache to safe_remove (quarantine by default). Never after a
    # refusal (target moved or outside the cache roots).
    tool="$(native_tool_for_command "$cmd" 2>/dev/null)" || tool=""
    if [[ "$EXEC_PROVIDER" == "interactive" ]] && _exc_fallback_allowed "$tool" \
        && [[ "${PLAN_OP_FALLBACK[$i]:-yes}" != "no" ]] \
        && { [[ "$MC_LAST_RESULT" == "unavailable" ]] || [[ "$MC_LAST_RESULT/$MC_LAST_REASON" == "failed/native_failed" ]]; }; then
        if [[ -e "$path" ]] && native_target_allowed "$tool" "$path"; then
            # F10: the fallback removes a whole directory, so it passes the same
            # sink checks as any other removal (category roots, protection,
            # in-use owner, recent_days). A refusal leaves the native result.
            local _fb_res="$MC_LAST_RESULT" _fb_rsn="$MC_LAST_REASON" _fb_freed="${MC_LAST_FREED:-0}"
            if _exc_sink_check_remove "$i" no_identity; then
                print_info "$(t exec_native_fallback "$tool" "$path")"
                safe_remove "$path" || true
            else
                _mc_last "$_fb_res" "$_fb_rsn" "$_fb_freed"
            fi
        fi
    fi
    return 0
}

# _exc_run_interactive_native <i> — docker, simctl runtimes, tmutil (no host
# target; only the interactive consent approves these).
_exc_run_interactive_native() {
    local i="$1" cmd cat bytes snap_date tm_out
    cmd="${PLAN_OP_COMMANDS[$i]}"; cat="${PLAN_OP_CATEGORIES[$i]}"; bytes="${PLAN_OP_BYTES[$i]:-0}"
    if [[ "$EXEC_PROVIDER" != "interactive" ]]; then
        _mc_last skipped plan_rejected 0
        return 0
    fi
    # P0-1: no native command while any dry-run is in effect.
    if is_dry_run; then
        print_dry "Would run: ${cmd}"
        record_native_command_event "$cmd" "planned" "$bytes" "dry-run"
        _mc_last dry_run "" 0
        return 0
    fi
    mc_item_progress "$cat" "${PLAN_OP_IDS[$i]}" running
    case "$cmd" in
        "docker system prune -f")
            print_section "Cleaning: Docker (system prune)"
            if ! native_tool_available docker; then
                record_native_command_event "$cmd" "skipped" "$bytes" "docker unavailable"
                print_warn "docker is not available."
                _mc_last unavailable "" 0
            elif docker system prune -f 2>/dev/null; then
                print_cleaned "Docker system prune complete."
                record_native_command_event "$cmd" "ok" "$bytes" ""
                _mc_last cleaned "" 0
            else
                record_native_command_event "$cmd" "failed" "$bytes" "docker prune failed"
                print_warn "docker system prune failed or Docker is not running."
                _mc_last failed native_failed 0
            fi
            ;;
        "xcrun simctl runtime delete --unusable")
            # Xcode may have been started while the prompt was open.
            if cache_owner_running sim_runtimes; then
                print_skip "Xcode, Simulator or xcodebuild started; simulator runtimes are left alone."
                record_skipped_item "Simulator runtimes in use (Xcode, Simulator or xcodebuild running)"
                _mc_last skipped in_use 0
            elif ! native_tool_available xcrun; then
                record_native_command_event "$cmd" "skipped" "$bytes" "xcrun unavailable"
                print_warn "xcrun is not available."
                _mc_last unavailable "" 0
            elif xcrun simctl runtime delete --unusable 2>/dev/null; then
                print_cleaned "Unusable simulator runtimes deleted."
                record_native_command_event "$cmd" "ok" "$bytes" ""
                _mc_last cleaned "" 0
            else
                record_native_command_event "$cmd" "failed" "$bytes" "xcrun failed"
                print_warn "xcrun simctl runtime delete --unusable failed."
                _mc_last failed native_failed 0
            fi
            ;;
        "tmutil deletelocalsnapshots "*)
            snap_date="${cmd#tmutil deletelocalsnapshots }"
            # The prompt can wait for minutes; a backup may have started.
            if tm_backup_running; then
                print_warn "Time Machine started backing up; local snapshots are left alone."
                record_skipped_item "Local Time Machine snapshots: backup started during confirmation"
                _mc_last skipped backup_running 0
            elif ! native_tool_available tmutil; then
                record_native_command_event "$cmd" "skipped" 0 "tmutil unavailable"
                _mc_last unavailable "" 0
            else
                print_info "Removing snapshot: $snap_date"
                if tm_out=$(tmutil deletelocalsnapshots "$snap_date" 2>&1); then
                    print_cleaned "Removed snapshot: $snap_date"
                    record_native_command_event "$cmd" "ok" 0 ""
                    _mc_last cleaned "" 0
                else
                    record_native_command_event "$cmd" "failed" 0 "tmutil failed"
                    print_warn "Failed to remove: $snap_date"
                    print_warn "  Reason: $tm_out"
                    _mc_last failed native_failed 0
                fi
            fi
            ;;
        *)
            _mc_last skipped plan_rejected 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Outcomes from per-item results (F05)
# ---------------------------------------------------------------------------
_exc_key() {
    REPLY="${1//-/_}"
}

_exc_tally_reset() {
    local k f
    _exc_key "$1"; k="$REPLY"
    for f in cleaned quarantined skipped failed unavailable dry_run freed est items declined; do
        eval "_EXC_${k}_${f}=0"
    done
    for f in in_use protected_path permission_denied fda_missing too_recent user_declined native_failed timeout \
             not_found needs_permanent identity_changed risk_escalated review_not_included dangerous_blocked \
             backup_running unreadable outside_category_root plan_rejected unknown; do
        eval "_EXC_${k}_R_${f}=0"
    done
}

_exc_tally() {
    local k res="$2" rsn="$3" freed="${4:-0}" est="${5:-0}"
    _exc_key "$1"; k="$REPLY"
    case "$res" in cleaned|quarantined|skipped|failed|unavailable|dry_run) ;; *) return 0 ;; esac
    case "$freed" in ''|*[!0-9]*) freed=0 ;; esac
    case "$est" in ''|*[!0-9]*) est=0 ;; esac
    eval "_EXC_${k}_${res}=\$(( \${_EXC_${k}_${res}:-0} + 1 ))"
    eval "_EXC_${k}_items=\$(( \${_EXC_${k}_items:-0} + 1 ))"
    eval "_EXC_${k}_freed=\$(( \${_EXC_${k}_freed:-0} + freed ))"
    eval "_EXC_${k}_est=\$(( \${_EXC_${k}_est:-0} + est ))"
    if [[ -n "$rsn" ]]; then
        case "$rsn" in *[!a-z_]*) rsn=unknown ;; esac
        eval "_EXC_${k}_R_${rsn}=\$(( \${_EXC_${k}_R_${rsn}:-0} + 1 ))"
    fi
}

# executor_category_counts <id> — REPLY = "cleaned quarantined skipped failed
# unavailable dry_run" for the last execute_ops.
executor_category_counts() {
    local k c q s f u d
    _exc_key "${1:-}"; k="$REPLY"
    eval "c=\${_EXC_${k}_cleaned:-0} q=\${_EXC_${k}_quarantined:-0} s=\${_EXC_${k}_skipped:-0}"
    eval "f=\${_EXC_${k}_failed:-0} u=\${_EXC_${k}_unavailable:-0} d=\${_EXC_${k}_dry_run:-0}"
    REPLY="$c $q $s $f $u $d"
}

# executor_category_freed <id> — REPLY = measured bytes of the removed items.
executor_category_freed() {
    local k
    _exc_key "${1:-}"; k="$REPLY"
    eval "REPLY=\${_EXC_${k}_freed:-0}"
}

# executor_category_reason <id> — REPLY = the dominant skip/fail reason.
executor_category_reason() {
    local k r best=0 cnt out=""
    _exc_key "${1:-}"; k="$REPLY"
    for r in user_declined needs_permanent in_use backup_running too_recent identity_changed \
             outside_category_root risk_escalated protected_path review_not_included dangerous_blocked \
             plan_rejected native_failed not_found permission_denied unreadable fda_missing timeout unknown; do
        eval "cnt=\${_EXC_${k}_R_${r}:-0}"
        if (( cnt > best )); then best=$cnt; out=$r; fi
    done
    REPLY="$out"
}

# executor_category_outcome <id> — REPLY = the contract outcome (V4 §3.2):
# cleaned | partial | failed | skipped | not_processed | dry_run | "" (not run).
executor_category_outcome() {
    local k c q s f u d acted declined
    _exc_key "${1:-}"; k="$REPLY"
    eval "c=\${_EXC_${k}_cleaned:-0} q=\${_EXC_${k}_quarantined:-0} s=\${_EXC_${k}_skipped:-0}"
    eval "f=\${_EXC_${k}_failed:-0} u=\${_EXC_${k}_unavailable:-0} d=\${_EXC_${k}_dry_run:-0}"
    eval "declined=\${_EXC_${k}_R_user_declined:-0}"
    acted=$(( c + q ))
    if (( acted > 0 )); then
        if (( s + f + u > 0 )); then REPLY="partial"; else REPLY="cleaned"; fi
    elif (( f > 0 )); then
        REPLY="failed"
    elif (( s > 0 && declined == s && u == 0 )); then
        REPLY="skipped"
    elif (( s + u > 0 )); then
        REPLY="not_processed"
    elif (( d > 0 )); then
        REPLY="dry_run"
    else
        REPLY=""
    fi
}

# _exc_mark_outcome <id> — the report's outcome (lib/reporter.sh vocabulary),
# computed from the same counts.
_exc_mark_outcome() {
    local id="$1" k c q s f u perm outcome="" override
    _exc_key "$id"; k="$REPLY"
    eval "override=\${EXC_OUTCOME_OVERRIDE_${k}:-}"
    if [[ -n "$override" ]]; then
        mark_category_outcome "$id" "$override"
        return 0
    fi
    eval "c=\${_EXC_${k}_cleaned:-0} q=\${_EXC_${k}_quarantined:-0} s=\${_EXC_${k}_skipped:-0}"
    eval "f=\${_EXC_${k}_failed:-0} u=\${_EXC_${k}_unavailable:-0} perm=\${_EXC_${k}_R_needs_permanent:-0}"
    executor_category_outcome "$id"
    case "$REPLY" in
        cleaned) outcome="cleaned" ;;
        partial)
            if (( f == 0 && u == 0 && s == perm )); then outcome="partial"; else outcome="partially-cleaned"; fi ;;
        failed) outcome="failed" ;;
        skipped) outcome="skipped" ;;
        not_processed)
            executor_category_reason "$id"
            case "$REPLY" in
                needs_permanent) outcome="needs-permanent" ;;
                in_use) outcome="in-use" ;;
                backup_running) outcome="backup-running" ;;
                *)
                    if (( u > 0 && s == 0 )); then outcome="unavailable"; else outcome="nothing-removed"; fi ;;
            esac ;;
        *) outcome="" ;;
    esac
    [[ -n "$outcome" ]] && mark_category_outcome "$id" "$outcome"
    return 0
}

# ---------------------------------------------------------------------------
# execute_ops — THE loop. Categories in registry order; within a category the
# plan order. Approved ops run after the sink re-check; denied ops end as
# skipped with the provider's reason; withdrawn ops are not items.
# ---------------------------------------------------------------------------
_exc_run_one() {
    local i="$1" id cat action path est name undo evaction rc=0
    id="${PLAN_OP_IDS[$i]}"; cat="${PLAN_OP_CATEGORIES[$i]}"; action="${PLAN_OP_ACTIONS[$i]}"
    path="${PLAN_OP_PATHS[$i]}"; est="${PLAN_OP_BYTES[$i]:-0}"
    name="${PLAN_OP_LABELS[$i]:-}"
    if [[ -z "$name" ]]; then
        if [[ "$action" == "native_command" ]]; then name="${PLAN_OP_COMMANDS[$i]}"; else name="${path##*/}"; fi
    fi
    evaction="remove"; undo="none"
    if [[ "$action" == "native_command" ]]; then
        evaction="native"
    elif [[ "${REMOVE_MODE:-quarantine}" == "quarantine" ]] && is_user_space_path "$path"; then
        undo="quarantine"
    fi
    redact_into "$path"
    mc_item_start "$cat" "$id" "$name" "$REDACTED_TEXT" "$est" "$evaction" "$undo"
    _mc_last skipped unknown 0
    if _exc_is_approved "$i" && [[ "${PLAN_OP_RISKS[$i]}" == "DANGEROUS" ]]; then
        # F8: one veto at the sink for every provider and every consent path
        # (the iOS-backup and Time Machine consents approve their ops directly).
        print_skip "Plan ${id}: DANGEROUS operations are never executed."
        cleanup_journal_event "plan_apply_skipped" "$path" "" "$est" "skipped" "dangerous blocked" "$cat"
        _mc_last skipped dangerous_blocked 0
    elif _exc_is_approved "$i"; then
        if [[ "$action" == "remove_path" ]]; then
            mc_item_progress "$cat" "$id" checking
            if _exc_sink_check_remove "$i"; then
                if [[ "$undo" == "quarantine" ]]; then
                    mc_item_progress "$cat" "$id" moving
                else
                    mc_item_progress "$cat" "$id" deleting
                fi
                safe_remove "$path" || rc=$?
            fi
        elif [[ "${PLAN_OP_SCOPE[$i]:-}" == "interactive" ]]; then
            _exc_run_interactive_native "$i"
        else
            _exc_run_bound_native "$i"
        fi
    else
        _exc_deny_reason "$i"
        _mc_last skipped "$REPLY" 0
    fi
    [[ "$MC_LAST_RESULT" == "failed" ]] && EXEC_ANY_FAILED=1
    mc_item_end "$cat" "$id" "$MC_LAST_RESULT" "$MC_LAST_REASON" "$est" "$MC_LAST_FREED" "" "$name"
    _exc_tally "$cat" "$MC_LAST_RESULT" "$MC_LAST_REASON" "$MC_LAST_FREED" "$est"
    return 0
}

execute_ops() {
    local k id i count t0 n_ops any_warn=0 any_err=0 any_ok=0 res
    local -a ops=()
    count=${#PLAN_OP_IDS[@]}
    mc_phase clean start
    for (( k=0; k<REG_COUNT; k++ )); do
        id="${REG_ID[$k]}"
        ops=()
        for (( i=0; i<count; i++ )); do
            [[ "${PLAN_OP_CATEGORIES[$i]}" == "$id" ]] || continue
            _exc_executable "$i" || continue
            _exc_state "$i"
            case "$REPLY" in approved|denied) ops+=("$i") ;; esac
        done
        n_ops=${#ops[@]}
        _exc_key "$id"
        if (( n_ops == 0 )); then
            # A category whose every op was withdrawn still has its outcome.
            eval "res=\${EXC_OUTCOME_OVERRIDE_${REPLY}:-}"
            [[ -n "$res" ]] && mark_category_outcome "$id" "$res"
            continue
        fi
        _exc_tally_reset "$id"
        EXEC_CATEGORIES_RUN="${EXEC_CATEGORIES_RUN}${id}"$'\n'
        t0=$SECONDS
        mc_group_start "$id" clean
        mc_group_total "$id" "$n_ops"
        for i in "${ops[@]}"; do
            _exc_run_one "$i"
        done
        mc_group_end "$id" clean $(( SECONDS - t0 ))
        _exc_mark_outcome "$id"
        executor_category_outcome "$id"
        case "$REPLY" in
            cleaned|dry_run) any_ok=1 ;;
            failed) any_err=1 ;;
            partial|not_processed) any_warn=1 ;;
        esac
    done
    if (( any_err )); then
        res=error
        (( any_ok )) && res=warn
    elif (( any_warn )); then
        res=warn
    else
        res=ok
    fi
    mc_phase clean end "$res"
    return 0
}

# _exc_record_estimate — a cleaning run's estimate is the size of the operations
# it was going to act on (the approved ones), not the whole scan: the headline
# figure of the report, run.json totals.estimated_bytes and run_end all read
# TOTAL_WOULD_FREE_BYTES. An apply-from-plan run never scans, so this is its
# only source. A scan or preview never reaches the executor and keeps the total.
_exc_record_estimate() {
    local i count sum=0 b
    count=${#PLAN_OP_IDS[@]}
    for (( i=0; i<count; i++ )); do
        _exc_is_approved "$i" || continue
        b="${PLAN_OP_BYTES[$i]:-0}"; case "$b" in ''|*[!0-9]*) b=0 ;; esac
        sum=$(( sum + b ))
    done
    # shellcheck disable=SC2034  # read by reporter.sh, json_summary.sh and mc_run_end
    TOTAL_WOULD_FREE_BYTES=$sum
}

# executor_run <interactive|auto|plan_file|unattended> — consent, then
# execute_ops. Returns 1 when a plan-file op failed (apply exits 1, as v3).
executor_run() {
    local provider="${1:-}" k
    registry_require
    _exc_reset
    for (( k=0; k<REG_COUNT; k++ )); do
        _exc_key "${REG_ID[$k]}"
        unset "EXC_OUTCOME_OVERRIDE_${REPLY}"
    done
    EXEC_PROVIDER="$provider"
    case "$provider" in
        interactive) consent_interactive ;;
        auto)        consent_auto ;;
        plan_file)   consent_plan_file ;;
        unattended)  consent_unattended || return 1 ;;
        *)
            print_error "Unknown consent provider: ${provider}"
            return 2 ;;
    esac
    _exc_record_estimate
    if [[ "$provider" == "auto" || "$provider" == "unattended" ]]; then
        if [[ -z "$MC_APPROVED" ]]; then
            print_skip "$(t "cli_no_safe_caches")"
        else
            print_section "$(t "cli_cleaning_auto_safe")"
        fi
    fi
    execute_ops
    if [[ "$provider" == "plan_file" ]] && (( EXEC_ANY_FAILED != 0 )); then
        return 1
    fi
    return 0
}

# The executor runs the plan: the planner's helpers (plan_root_allows,
# plan_path_identity, execute_plan_native_command, ...) must be loaded too.
if ! type build_cleanup_plan_from_analysis >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${_EXECUTOR_LIB_DIR}/planner.sh"
fi
