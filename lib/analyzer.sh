#!/usr/bin/env bash
# =============================================================================
# lib/analyzer.sh — System inventory & size analysis
#
# Each analyze_* function:
#   • Scans its target area
#   • Accumulates sizes into global arrays via catbytes_set
#   • Prints a formatted summary
#   • Does NOT delete anything
#
# Bash 3.2 compatible — no ${var,,}, no declare -A, no mapfile
# =============================================================================

if ! command -v validate_cache_path >/dev/null 2>&1; then
    _ANALYZER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    if [[ -f "${_ANALYZER_LIB_DIR}/pathguard.sh" ]]; then
        # shellcheck disable=SC1091
        source "${_ANALYZER_LIB_DIR}/pathguard.sh"
    fi
fi

# Global arrays populated by analyzers; used by cleaner and reporter
declare -a FOUND_USER_CACHES=()
declare -a FOUND_SYSTEM_CACHES=()
declare -a FOUND_APP_LOGS=()
declare -a FOUND_SYSTEM_LOGS=()
declare -a FOUND_TMP_FILES=()
declare -a FOUND_APP_LEFTOVERS=()
declare -a FOUND_DEV_ITEMS=()
declare -a FOUND_TM_SNAPSHOTS=()
declare -a FOUND_IOS_BACKUPS=()
declare -a FOUND_DMG_PKG=()
declare -a FOUND_TRASH_ITEMS=()
declare -a FOUND_APP_CACHE_ITEMS=()
declare -a FOUND_DEVICE_SUPPORT_ITEMS=()
declare -a FOUND_DIAGNOSTIC_REPORTS=()
declare -a FOUND_INSTALLED_APPS=()
declare -a FOUND_BREW_PACKAGES=()
declare -a FOUND_MAS_APPS=()
declare -a FOUND_MAIL_ITEMS=()
declare -a FOUND_BROWSER_CACHE_ITEMS=()
declare -a FOUND_BROWSER_DATA_ITEMS=()
# Used by tests and JSON/report consumers after source.
# shellcheck disable=SC2034
ANALYSIS_PARTIAL=0

# optional_command_with_timeout <seconds> <cmd> [args...]
# Runs an external command with a deadline; exit 124 means it timed out.
# Stock macOS has no GNU `timeout`, but it always ships perl, so that is the
# portable implementation: the command runs in its own process group and, past
# the deadline, the whole group is killed (a wrapper script's children must not
# keep the caller's pipe open). GNU timeout/gtimeout and python3 are only
# fallbacks. With none of them the command is NOT run (124): an unbounded
# native query is worse than none.
optional_command_with_timeout() {
    local seconds="$1" rc=0
    shift

    if command -v perl >/dev/null 2>&1; then
        # The group's 2>/dev/null also hides the shell's "Killed" job message.
        { perl -e '
            my $t = shift @ARGV;
            my $pid = fork();
            exit 127 unless defined $pid;
            if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127; }
            setpgrp($pid, $pid);
            $SIG{ALRM} = sub {
                kill "TERM", -$pid; select(undef, undef, undef, 0.3);
                kill "KILL", -$pid; waitpid($pid, 0); exit 124;
            };
            alarm $t;
            waitpid($pid, 0);
            my $st = $?;
            exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
        ' "$seconds" "$@"; } 2>/dev/null || rc=$?
        return "$rc"
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$seconds" "$@"
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - "$seconds" "$@" <<'PY'
import subprocess
import sys

seconds = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=seconds,
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
except OSError:
    sys.exit(127)

sys.stdout.buffer.write(result.stdout)
sys.exit(result.returncode)
PY
        return $?
    fi

    return 124
}

# native_query_with_timeout <seconds> <label> <cmd> [args...]
# A read-only query of a native tool (xcrun, brew, docker, tmutil) under a
# deadline. A timeout is recorded for the run (so the summaries say "partial",
# also when called from a command substitution) and returned as 124: callers
# must treat that as "unknown", never as "0 bytes". stdout is the tool's.
native_query_with_timeout() {
    local seconds="$1" label="$2" rc=0
    shift 2
    _native_in_home optional_command_with_timeout "$seconds" "$@" || rc=$?
    if (( rc == 124 )); then
        analysis_record_unreadable "native_query_timeout" "native query timed out after ${seconds}s: ${label}"
        log_warn "Native query timed out after ${seconds}s: ${label}"
    fi
    return "$rc"
}

# Deadline for one native query; tests lower it.
NATIVE_QUERY_TIMEOUT="${NATIVE_QUERY_TIMEOUT:-20}"

# Every other external program a scan runs is bounded too, so that one hanging tool (a stuck
# network volume under find or du, an unresponsive diskutil or Spotlight) cannot stall the scan:
#   SCAN_TOOL_TIMEOUT  df, diskutil, defaults, mdfind (quick lookups)
#   SCAN_FIND_TIMEOUT  one find walk
#   SCAN_SIZE_TIMEOUT  one du measurement (common.sh path_size_bytes)
# A timeout counts as "not measured", never as 0 bytes. Tests lower them.
SCAN_TOOL_TIMEOUT="${SCAN_TOOL_TIMEOUT:-20}"
SCAN_FIND_TIMEOUT="${SCAN_FIND_TIMEOUT:-120}"
SCAN_SIZE_TIMEOUT="${SCAN_SIZE_TIMEOUT:-120}"

# scan_mark <id>... — per-category scan time inside an analyzer that measures several categories
# (analyze_dev_environment sizes 21 in one go). A mark closes the previous one: the seconds since
# it are recorded for the ids it named. _run_analyzer_scan_events turns them into the seconds of
# each category's group_end and an engine-log line; a category without a mark gets the whole
# analyzer's time.
_SCAN_MARK_IDS=""
_SCAN_MARK_AT=0
scan_mark() {
    local now=$SECONDS id
    if [[ -n "$_SCAN_MARK_IDS" ]]; then
        for id in $_SCAN_MARK_IDS; do eval "_SCANSECS_${id//-/_}=$(( now - _SCAN_MARK_AT ))"; done
    fi
    _SCAN_MARK_IDS="$*"
    _SCAN_MARK_AT=$now
}

# scan_secs_get <id> — REPLY = the seconds scan_mark recorded for the category; 1 when none.
scan_secs_get() {
    local v
    eval "v=\"\${_SCANSECS_${1//-/_}:-}\""
    [[ -n "$v" ]] || return 1
    REPLY="$v"
}

_claim_known_specific_caches() {
    local path
    for path in \
        "$HOME/Library/Caches/Homebrew" \
        "$HOME/Library/Caches/pip" \
        "$HOME/Library/Caches/CocoaPods" \
        "$HOME/Library/Caches/org.swift.swiftpm" \
        "$HOME/Library/Caches/composer" \
        "$HOME/Library/Caches/com.figma.Desktop" \
        "$HOME/Library/Caches/JetBrains" \
        "$HOME/Library/Caches/Adobe" \
        "$HOME/Library/Caches/com.spotify.client" \
        "$HOME/Library/Caches/us.zoom.xos" \
        "$HOME/Library/Caches/com.apple.dt.Xcode" \
        "$HOME/Library/Caches/com.macpaw.CleanMyMac4" \
        "$HOME/Library/Caches/com.apple.Safari" \
        "$HOME/Library/Caches/Google/Chrome" \
        "$HOME/Library/Caches/Firefox" \
        "$HOME/Library/Caches/Microsoft Edge" \
        "$HOME/Library/Caches/BraveSoftware/Brave-Browser"; do
        [[ -d "$path" ]] && claim_path "$path" 0
    done
}

is_known_app_specific_cache_path() {
    local path="$1"
    is_path_claimed "$path"
}

simctl_unavailable_udids() {
    command -v xcrun >/dev/null 2>&1 || return 1
    local out
    out="$(native_query_with_timeout "$NATIVE_QUERY_TIMEOUT" "xcrun simctl list devices unavailable" \
        xcrun simctl list devices unavailable 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -Eo '[0-9A-Fa-f-]{36}' | sort -u
}

# analyze_sim_runtimes — simulator runtimes that simctl itself marks unusable.
# They live in a system-managed store, so only `xcrun simctl runtime delete
# --unusable` may remove them. The scan is read-only: it asks
# `xcrun simctl runtime list -j` (under a deadline) and counts the entries whose
# state is Unusable, summing their `sizeBytes`; it never runs a delete command,
# not even with --dry-run. When the list cannot be read (timeout, bad JSON) the
# category is unknown and the run is marked partial, never "0 bytes". A size of
# 0 for runtimes that exist is still offered, as size unknown. Without
# developer tools xcrun is not run: its shim can open the install-tools dialog
# during a read-only scan.
analyze_sim_runtimes() {
    command -v xcrun >/dev/null 2>&1 || return 0
    xcode-select -p >/dev/null 2>&1 || return 0
    local list="" parsed="" count="" bytes=""
    list="$(native_query_with_timeout "$NATIVE_QUERY_TIMEOUT" "xcrun simctl runtime list -j" \
        xcrun simctl runtime list -j 2>/dev/null)" || return 0
    parsed="$(printf '%s\n' "$list" | python3 -I -c '
import json, sys
data = json.load(sys.stdin)
count = 0
total = 0
for key, rt in data.items():
    if not isinstance(rt, dict):
        continue
    if str(rt.get("state") or "").strip().lower() != "unusable":
        continue
    count += 1
    try:
        total += int(rt.get("sizeBytes") or 0)
    except (TypeError, ValueError):
        pass
print(count, total)
' 2>/dev/null)" || parsed=""
    case "$parsed" in
        [0-9]*" "[0-9]*) ;;
        *)
            analysis_record_unreadable "native_query_unreadable" "native query output not understood: xcrun simctl runtime list -j"
            return 0 ;;
    esac
    count="${parsed%% *}"
    bytes="${parsed##* }"
    (( count > 0 )) || return 0
    case "$bytes" in ''|0|*[!0-9]*) bytes="" ;; esac

    FOUND_DEV_ITEMS+=("sim_runtimes_unusable:__simctl_runtime__")
    catbytes_set "sim-runtimes" "${bytes:-0}"
    if [[ -n "$bytes" ]]; then
        print_found "Simulator runtimes (unusable): $(bytes_to_human "$bytes")"
    else
        print_found "Simulator runtimes (unusable): size unknown"
    fi
}

analyze_application_inventory() {
    print_section "$(t "app_inventory_title")"

    local app_dirs=("/Applications" "$HOME/Applications" "/System/Applications")
    local dir app count=0
    FOUND_INSTALLED_APPS=()

    for dir in "${app_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' app; do
            FOUND_INSTALLED_APPS+=("$app")
            count=$(( count + 1 ))
        done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$dir" -maxdepth 2 -name "*.app" -print0 2>/dev/null)
    done

    if (( count > 0 )) && (( ${#FOUND_INSTALLED_APPS[@]} > 0 )); then
        print_found "$(t "app_inventory_found" "$count")"
        printf '%s\n' "${FOUND_INSTALLED_APPS[@]}" | sort | head -10 | while IFS= read -r app; do
            echo "    $(basename "$app" .app)"
        done
    else
        print_skip "$(t "app_inventory_none")"
    fi

    FOUND_BREW_PACKAGES=()
    if command -v brew >/dev/null 2>&1; then
        local brew_count=0 brew_output=""
        brew_output="$(_native_in_home optional_command_with_timeout 15 brew list --formula 2>/dev/null || true)"
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            FOUND_BREW_PACKAGES+=("$pkg")
            brew_count=$(( brew_count + 1 ))
        done <<< "$brew_output"
        brew_output="$(_native_in_home optional_command_with_timeout 15 brew list --cask 2>/dev/null || true)"
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            FOUND_BREW_PACKAGES+=("cask:${pkg}")
            brew_count=$(( brew_count + 1 ))
        done <<< "$brew_output"
        print_info "Homebrew formulae/casks: ${brew_count}"
    fi

    FOUND_MAS_APPS=()
    if command -v mas >/dev/null 2>&1; then
        local mas_count=0 mas_output=""
        if ! mas_output="$(_native_in_home optional_command_with_timeout 8 mas list 2>/dev/null)"; then
            print_warn "$(t "mas_warn")"
            return
        fi
        while IFS= read -r mas_line; do
            [[ -z "$mas_line" ]] && continue
            FOUND_MAS_APPS+=("$mas_line")
            mas_count=$(( mas_count + 1 ))
        done <<< "$mas_output"
        print_info "Mac App Store apps: ${mas_count}"
    fi
}

# _overview_scan_events <start|end> <t0> <id>... — the scan-phase events of the report-only overview
# categories (V4 section 3). analyze_mail_storage and analyze_browser_storage are run directly by the
# full scan, not through _run_analyzer_scan_events, so without this the result views never hear of
# browser-caches, browser-data, mail-data and mail-downloads. No-ops without the event channel.
_overview_scan_events() {
    local what="$1" t0="${2:-0}" id unit bytes
    shift 2
    for id in "$@"; do
        if [[ "$what" == "start" ]]; then
            mc_group_start "$id" scan
        else
            reg_get "$id" unit 2>/dev/null || REPLY=bytes
            unit="${REPLY:-bytes}"
            bytes="$(catbytes_get "$id")"
            mc_group_sized "$id" "${bytes:-0}" 0 0 "$unit"
            mc_group_end "$id" scan $(( SECONDS - t0 ))
        fi
    done
    return 0
}

analyze_mail_storage() {
    print_section "$(t "mail_analysis_title")"
    local _ov_t0=$SECONDS
    _overview_scan_events start "$_ov_t0" mail-data mail-downloads

    local mail_dir="$HOME/Library/Mail"
    local mail_container="$HOME/Library/Containers/com.apple.mail"
    local mail_downloads="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    local total=0
    FOUND_MAIL_ITEMS=()

    if [[ -d "$mail_dir" ]]; then
        local bytes
        bytes="$(path_size_bytes "$mail_dir")"
        FOUND_MAIL_ITEMS+=("mail-store:$mail_dir")
        catbytes_set "mail-data" "$bytes"
        total=$(( total + bytes ))
        print_found "Mail store: $(bytes_to_human "$bytes")"
        print_note "  $(t "mail_warn_1")"
    fi

    if [[ -d "$mail_container" ]]; then
        local bytes
        bytes="$(path_size_bytes "$mail_container")"
        FOUND_MAIL_ITEMS+=("mail-container:$mail_container")
        total=$(( total + bytes ))
        print_found "Mail container: $(bytes_to_human "$bytes")"
    fi

    if [[ -d "$mail_downloads" ]]; then
        local bytes
        bytes="$(path_size_bytes "$mail_downloads")"
        FOUND_MAIL_ITEMS+=("mail-downloads:$mail_downloads")
        catbytes_set "mail-downloads" "$bytes"
        print_found "Mail Downloads: $(bytes_to_human "$bytes")"
        print_info "  $(t "mail_warn_2")"
    fi

    # The v3 mail-total ledger (store + container) is gone: the registry keeps
    # mail-data and mail-downloads; the container stays in the plan as a
    # mail-data report-only item.
    if (( ${#FOUND_MAIL_ITEMS[@]} == 0 )); then
        print_ok "$(t "mail_ok")"
    else
        print_info "$(t "mail_danger")"
    fi
    _overview_scan_events end "$_ov_t0" mail-data mail-downloads
}

analyze_browser_storage() {
    print_section "$(t "browsers_section")"
    local _ov_t0=$SECONDS
    _overview_scan_events start "$_ov_t0" browser-caches browser-data

    FOUND_BROWSER_CACHE_ITEMS=()
    FOUND_BROWSER_DATA_ITEMS=()

    local labels=(
        "Safari cache" "Chrome cache" "Firefox cache" "Edge cache" "Brave cache"
    )
    local paths=(
        "$HOME/Library/Caches/com.apple.Safari"
        "$HOME/Library/Caches/Google/Chrome"
        "$HOME/Library/Caches/Firefox"
        "$HOME/Library/Caches/Microsoft Edge"
        "$HOME/Library/Caches/BraveSoftware/Brave-Browser"
    )
    local data_labels=(
        "Safari profile" "Chrome profile" "Firefox profile" "Edge profile" "Brave profile"
    )
    local data_paths=(
        "$HOME/Library/Safari"
        "$HOME/Library/Application Support/Google/Chrome"
        "$HOME/Library/Application Support/Firefox"
        "$HOME/Library/Application Support/Microsoft Edge"
        "$HOME/Library/Application Support/BraveSoftware"
    )

    local total_cache=0 total_data=0 i path bytes
    for (( i = 0; i < ${#labels[@]}; i++ )); do
        path="${paths[$i]}"
        [[ -d "$path" ]] || continue
        bytes="$(path_size_bytes "$path")"
        FOUND_BROWSER_CACHE_ITEMS+=("${labels[$i]}:$path")
        total_cache=$(( total_cache + bytes ))
        print_found "${labels[$i]}: $(bytes_to_human "$bytes")"
    done

    for (( i = 0; i < ${#data_labels[@]}; i++ )); do
        path="${data_paths[$i]}"
        [[ -d "$path" ]] || continue
        bytes="$(path_size_bytes "$path")"
        FOUND_BROWSER_DATA_ITEMS+=("${data_labels[$i]}:$path")
        total_data=$(( total_data + bytes ))
    done

    catbytes_set "browser-caches" "$total_cache"
    catbytes_set "browser-data"   "$total_data"

    if (( total_cache > 0 )); then
        print_found "Browser Caches: $(bytes_to_human "$total_cache")"
    fi
    if (( total_data > 0 )); then
        print_note "$(t "browsers_data_warn") ($(bytes_to_human "$total_data"))"
        print_info "  $(t "browsers_data_rec")"
    fi
    if (( total_cache == 0 && total_data == 0 )); then
        print_ok "$(t "browsers_ok")"
    fi
    _overview_scan_events end "$_ov_t0" browser-caches browser-data
}

# PF2: skip expensive home-dir enumeration for single-category runs.
_is_full_scan() {
    # True when no category filter was set OR all categories are active.
    if [[ -z "${ACTIVE_CATEGORIES+x}" ]] || (( ${#ACTIVE_CATEGORIES[@]} == 0 )); then
        return 0
    fi
    (( ${#ACTIVE_CATEGORIES[@]} >= ${#ALL_CATEGORIES[@]} ))
}

# ---------------------------------------------------------------------------
# analyze_disk_overview — df summary, APFS free/purgeable, largest top-level dirs
# ---------------------------------------------------------------------------
analyze_disk_overview() {
    print_section "$(t "disk_overview")"

    local target_vol="/"
    [[ -d "/System/Volumes/Data" ]] && target_vol="/System/Volumes/Data"

    # --- Basic disk usage ---
    echo -e "  ${C_BOLD}$(t "disk_volumes_header")${C_RESET}"
    local df_size="" df_used="" df_free="" df_pct=""
    # df -k, so the sizes go through bytes_to_human like every other size here.
    # The last df column is Capacity: the USED share, not the free one.
    read -r df_size df_used df_free df_pct < <(optional_command_with_timeout "$SCAN_TOOL_TIMEOUT" df -k "$target_vol" 2>/dev/null | \
        awk 'NR==2{printf "%.0f %.0f %.0f %s\n", $2*1024, $3*1024, $4*1024, $5}') || true
    if [[ -n "$df_size" && -n "$df_pct" ]]; then
        printf '    Size: %s  |  Used: %s (%s)  |  Free: %s\n' \
            "$(bytes_to_human "$df_size")" "$(bytes_to_human "$df_used")" "$df_pct" "$(bytes_to_human "$df_free")"
    fi
    echo

    # --- APFS Free & Purgeable space ---
    if command -v diskutil &>/dev/null; then
        local diskinfo=""
        diskinfo=$(optional_command_with_timeout "$SCAN_TOOL_TIMEOUT" diskutil info "$target_vol" 2>/dev/null) || diskinfo=""

        local free_space=""
        free_space=$(printf '%s\n' "$diskinfo" | \
            grep -iE "(Container Free Space|Volume Free Space|Free Space)" | \
            head -1 | sed 's/.*:[[:space:]]*//' | sed 's/ (.*//' | sed 's/[[:space:]]*$//') \
            || free_space=""

        # Purgeable: macOS <= 12 exposes a "Purgeable" field in `diskutil info`.
        # macOS 13+ (verified absent on 26.6.1) removed it, so fall back to
        # deriving it: APFS container free space counts snapshot-retained
        # bytes, df's available figure does not. The difference is what macOS
        # can reclaim on demand.
        local purgeable_space=""
        purgeable_space=$(printf '%s\n' "$diskinfo" | \
            grep -i "Purgeable" | \
            head -1 | sed 's/.*:[[:space:]]*//' | sed 's/ (.*//' | sed 's/[[:space:]]*$//') \
            || purgeable_space=""

        if [[ -z "$purgeable_space" ]]; then
            local container_bytes="" avail_bytes="" delta=0
            # diskutil prints byte counts with thousands separators, e.g.
            # "(53,500,000,000 Bytes)" — strip them before extracting.
            container_bytes=$(printf '%s\n' "$diskinfo" | \
                grep -i "Container Free Space" | head -1 | tr -d ',' | \
                sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p') || container_bytes=""
            avail_bytes=$(optional_command_with_timeout "$SCAN_TOOL_TIMEOUT" df -k "$target_vol" 2>/dev/null | awk 'NR==2{print $4*1024}') || avail_bytes=""
            case "${container_bytes:-}" in ''|*[!0-9]*) container_bytes="" ;; esac
            case "${avail_bytes:-}" in ''|*[!0-9]*) avail_bytes="" ;; esac
            if [[ -n "$container_bytes" && -n "$avail_bytes" ]] && (( container_bytes > avail_bytes )); then
                delta=$(( container_bytes - avail_bytes ))
                # Only report a meaningful delta; small differences are noise.
                (( delta > 1073741824 )) && purgeable_space="$(bytes_to_human "$delta")"
            fi
        fi

        echo -e "  ${C_BOLD}APFS Space:${C_RESET}"
        if [[ -n "$free_space" ]]; then
            echo -e "    ${C_GREEN}Free:      ${free_space}${C_RESET}"
        else
            echo -e "    ${C_DIM}$(t "disk_util_err")${C_RESET}"
        fi
        if [[ -n "$purgeable_space" ]]; then
            echo -e "    ${C_YELLOW}Purgeable: ${purgeable_space}${C_RESET}"
            echo -e "    ${C_DIM}^ APFS will reclaim automatically: TM local snapshots, iCloud files${C_RESET}"
        fi

        # Snapshot-retention notice. This is the single most common source of
        # "I cleaned and df did not change", so surface it whenever local
        # snapshots exist — independently of whether a purgeable figure was
        # obtainable on this macOS version.
        if command -v tmutil >/dev/null 2>&1; then
            local snap_count=0
            snap_count=$(native_query_with_timeout "$NATIVE_QUERY_TIMEOUT" "tmutil listlocalsnapshots /" \
                tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine") || snap_count=0
            case "${snap_count:-}" in ''|*[!0-9]*) snap_count=0 ;; esac
            if (( snap_count > 0 )); then
                echo -e "    ${C_DIM}${snap_count} local Time Machine snapshot(s) present.${C_RESET}"
                echo -e "    ${C_DIM}Deleted files retained by a snapshot stay on disk until it${C_RESET}"
                echo -e "    ${C_DIM}expires (usually within 24h, or sooner under disk pressure),${C_RESET}"
                echo -e "    ${C_DIM}so free space may not change immediately after a cleanup.${C_RESET}"
            fi
        fi
        echo
    fi

    # --- Largest directories in home (PF2: skip for --category X) ---
    # Phase 2: this walk alone took ~102 s of a ~322 s full scan. It is
    # informational only, so it is bounded (setting home_top_timeout, default
    # 20 s), stays on the home volume (-x) and skips iCloud Drive and
    # CloudStorage, whose dataless files must not be enumerated or fetched.
    if _is_full_scan; then
        print_info "$(t "disk_home_top10")"
        local home_top="" home_line home_dir home_rc home_slow="" home_tmp="" home_n=0 home_i home_pids=""
        local home_limit="${HOME_TOP_DIRS_TIMEOUT:-20}"
        case "$home_limit" in ''|*[!0-9]*) home_limit=20 ;; esac
        (( home_limit >= 1 )) || home_limit=20
        # Every top-level directory is measured at the same time, each under
        # the whole budget. Measured one after another with a share of the
        # budget each, the few really large trees all timed out and the list
        # showed only the small ones. du block-buffers, so one du per directory.
        home_tmp="$(mktemp -d "${TMPDIR:-/tmp}/mc_home_top.XXXXXX" 2>/dev/null)" || home_tmp=""
        if [[ -n "$home_tmp" && -d "$home_tmp" ]]; then
            for home_dir in "$HOME"/*/; do
                [[ -d "$home_dir" ]] || continue
                home_n=$(( home_n + 1 ))
                (
                    home_rc=0
                    optional_command_with_timeout "$home_limit" \
                        du -x -sk -I 'Mobile Documents' -I CloudStorage "$home_dir" \
                        > "$home_tmp/$home_n.out" 2>/dev/null || home_rc=$?
                    printf '%s\n' "$home_rc" > "$home_tmp/$home_n.rc"
                ) &
                home_pids+=" $!"
                printf '%s\n' "$home_dir" > "$home_tmp/$home_n.dir"
            done
            for home_i in $home_pids; do wait "$home_i" 2>/dev/null || true; done
            home_i=0
            while (( home_i < home_n )); do
                home_i=$(( home_i + 1 ))
                home_rc=""; home_line=""; home_dir=""
                [[ -f "$home_tmp/$home_i.rc" ]] && IFS= read -r home_rc < "$home_tmp/$home_i.rc"
                [[ -f "$home_tmp/$home_i.out" ]] && IFS= read -r home_line < "$home_tmp/$home_i.out"
                [[ -f "$home_tmp/$home_i.dir" ]] && IFS= read -r home_dir < "$home_tmp/$home_i.dir"
                if [[ "$home_rc" == "124" || -z "$home_rc" ]]; then
                    home_dir="${home_dir%/}"
                    home_slow+="${home_slow:+, }${home_dir##*/}"
                elif [[ -n "$home_line" ]]; then
                    home_top+="${home_line}"$'\n'
                fi
                # Our own scratch files, created above; not user data.
                rm -f "$home_tmp/$home_i.rc" "$home_tmp/$home_i.out" "$home_tmp/$home_i.dir" 2>/dev/null || true
            done
            rmdir "$home_tmp" 2>/dev/null || true
        fi
        if [[ -n "$home_top" ]]; then
            # du -sk prints "<KiB><tab><path>"; sizes are shown through bytes_to_human.
            printf '%s' "$home_top" | sort -rn 2>/dev/null | head -10 | \
                while IFS=$'\t' read -r home_kb home_path; do
                    case "$home_kb" in ''|*[!0-9]*) continue ;; esac
                    echo "    $(bytes_to_human $(( home_kb * 1024 )))  ${home_path}"
                done || true
        fi
        if [[ -n "$home_slow" ]]; then
            print_info "    $(t "disk_home_top10_partial" "$home_limit" "$home_slow")"
        fi
        echo
    fi
}

# ---------------------------------------------------------------------------
# analyze_trash — ~/.Trash
# Always safe; often overlooked source of GBs.
# ---------------------------------------------------------------------------
analyze_trash() {
    print_section "$(t "trash_section")"

    local trash_dir="$HOME/.Trash"
    if [[ ! -d "$trash_dir" ]]; then
        print_ok "$(t "trash_empty_or_missing")"
        catbytes_set "trash" 0
        return
    fi

    local total=0
    local count=0
    local size_list=""   # PF1: accumulate sizes to avoid double-du

    # Count items and total size
    while IFS= read -r -d '' item; do
        local bytes
        bytes=$(path_size_bytes "$item")
        total=$(( total + bytes ))
        count=$(( count + 1 ))
        FOUND_TRASH_ITEMS+=("$item")
        size_list+="${bytes} ${item}"$'\n'
    done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$trash_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    catbytes_set "trash" "$total"

    if (( count == 0 )); then
        print_ok "$(t "trash_empty")"
        return
    fi

    print_found "$(t "trash"): $(t "in_items" "$(bytes_to_human "$total")" "$count")"

    # Show top 5 largest items in trash
    if (( ${#FOUND_TRASH_ITEMS[@]} > 0 )); then
        echo -e "  ${C_DIM}$(t "trash_top_items"):${C_RESET}"
        local top5=""
        top5=$(printf '%s' "$size_list" | sort -rn | head -5) || true
        while IFS=' ' read -r bytes path; do
            [[ -z "$bytes" ]] && continue
            printf "    %8s  %s\n" "$(bytes_to_human "$bytes")" "$(basename "$path")"
        done <<< "$top5"
    fi
}

# ---------------------------------------------------------------------------
# analyze_user_caches — ~/Library/Caches (per-app breakdown)
# ---------------------------------------------------------------------------
analyze_user_caches() {
    print_section "$(t "user_caches_section")"

    local cache_base="$HOME/Library/Caches"
    [[ -d "$cache_base" ]] || { print_skip "Directory does not exist: $cache_base"; return; }

    _claim_known_specific_caches

    local total=0
    local size_list=""   # PF1: accumulate sizes to avoid double-du
    while IFS= read -r -d '' item; do
        is_protected_path "$item" && continue
        is_known_app_specific_cache_path "$item" && continue
        case "${item##*/}" in
            Google|BraveSoftware) continue ;;
        esac
        local bytes
        bytes=$(path_size_bytes "$item")
        local b="${bytes:-0}"
        [[ "$b" -lt 1024 ]] 2>/dev/null && continue  # ignore < 1 KB
        FOUND_USER_CACHES+=("$item")
        claim_path "$item" "$b"
        total=$(( total + b ))
        size_list+="${b} ${item}"$'\n'
    done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$cache_base" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    catbytes_set "user-caches" "$total"

    if (( ${#FOUND_USER_CACHES[@]} == 0 )); then
        print_ok "$(t "user_caches_ok")"
        return
    fi

    print_found "$(t "user_caches_found"): $(t "in_items" "$(bytes_to_human "$total")" "${#FOUND_USER_CACHES[@]}")"

    echo -e "  ${C_DIM}$(t "user_caches_top10"):${C_RESET}"
    local top10=""
    top10=$(printf '%s' "$size_list" | sort -rn | head -10) || true
    while IFS=' ' read -r bytes path; do
        [[ -z "$bytes" ]] && continue
        printf "    %8s  %s\n" "$(bytes_to_human "$bytes")" "$path"
    done <<< "$top10"
}

# ---------------------------------------------------------------------------
# analyze_app_specific_caches — well-known app caches not in generic ~/Library/Caches
# Slack, VS Code, JetBrains, Spotify, Adobe, Figma, Microsoft Teams, etc.
# ---------------------------------------------------------------------------
analyze_app_specific_caches() {
    print_section "$(t "app_specific_caches_title")"

    # The application list is share/app_caches.tsv (label, path, category),
    # loaded with the registry (R06); category app-caches is the allowlisted
    # half, app-caches-review the rest.
    local app_labels=()
    local app_paths=()
    local app_cats=()
    local _ai=0
    registry_require
    while [[ $_ai -lt $REG_APPC_COUNT ]]; do
        app_labels+=("${REG_APPC_LABEL[$_ai]}")
        reg_expand_path "${REG_APPC_PATH[$_ai]}" || true
        app_paths+=("$REPLY")
        app_cats+=("${REG_APPC_CATEGORY[$_ai]}")
        _ai=$(( _ai + 1 ))
    done

    local total=0
    local total_safe=0
    local total_review=0
    local found_count=0
    local i=0

    while [[ $i -lt ${#app_labels[@]} ]]; do
        local label="${app_labels[$i]}"
        local path="${app_paths[$i]}"
        local app_cat="${app_cats[$i]}"
        i=$(( i + 1 ))

        [[ -d "$path" ]] || continue
        is_protected_path "$path" && continue

        local bytes
        bytes=$(path_size_bytes "$path")
        local b="${bytes:-0}"
        [[ "$b" -lt 10240 ]] 2>/dev/null && continue  # ignore < 10 KB

        FOUND_APP_CACHE_ITEMS+=("${label}:${path}")
        claim_path "$path" "$b"
        total=$(( total + b ))
        if [[ "$app_cat" == "app-caches" ]]; then
            total_safe=$(( total_safe + b ))
        else
            total_review=$(( total_review + b ))
        fi
        found_count=$(( found_count + 1 ))
        printf "  ${C_YELLOW}→${C_RESET}  %-40s  %s\n" "$label" "$(bytes_to_human "$b")"
    done

    catbytes_set "app-caches" "$total_safe"
    catbytes_set "app-caches-review" "$total_review"

    if (( found_count == 0 )); then
        print_ok "$(t "app_specific_caches_none")"
    else
        print_found "$(t "app_specific_caches_found" "$(bytes_to_human "$total")" "$found_count")"
    fi
}

# ---------------------------------------------------------------------------
# analyze_system_caches — /Library/Caches (SIP-protected; report size only)
# ---------------------------------------------------------------------------
analyze_system_caches() {
    print_section "Cache systemowe (/Library/Caches)"

    local dirs=(
        "/Library/Caches"
    )

    local total=0
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        local bytes
        bytes=$(path_size_bytes "$dir")
        local b="${bytes:-0}"
        if (( b > 0 )); then
            FOUND_SYSTEM_CACHES+=("$dir")
            total=$(( total + b ))
            printf "  %8s  %s\n" "$(bytes_to_human "$b")" "$dir"
        fi
    done

    catbytes_set "system-caches" "$total"
    if (( total > 0 )); then
        print_found "System Caches: $(bytes_to_human "$total")"
        print_info  "  $(t "system_caches_sip_warn")"
        print_info  "  Cleanup: sudo periodic daily  or  sudo purge"
    else
        print_ok "$(t "system_caches_ok")"
    fi
}

# ---------------------------------------------------------------------------
# analyze_logs — ~/Library/Logs, /var/log, /Library/Logs
# ---------------------------------------------------------------------------
analyze_logs() {
    print_section "$(t "logs_section_title" "$LOG_MAX_AGE_DAYS")"

    local raw_log_dirs=(
        "$HOME/Library/Logs"
        "/Library/Logs"
        "/var/log"
        "/private/var/log"
    )
    local log_dirs=()
    local raw_dir norm_dir seen_dir existing_dir
    for raw_dir in "${raw_log_dirs[@]}"; do
        [[ -d "$raw_dir" ]] || continue
        norm_dir="$(normalize_path "$raw_dir" || echo "$raw_dir")"
        seen_dir=0
        if (( ${#log_dirs[@]} > 0 )); then
            for existing_dir in "${log_dirs[@]}"; do
                [[ "$existing_dir" == "$norm_dir" ]] && { seen_dir=1; break; }
            done
        fi
        (( seen_dir == 0 )) && log_dirs+=("$norm_dir")
    done

    local total_user=0
    local total_system=0
    local normalized_home
    normalized_home="$(normalize_path "$HOME" || echo "$HOME")"

    for dir in "${log_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        local target_is_user_log=0
        [[ "$dir" == "$normalized_home"* ]] && target_is_user_log=1

        if [[ "$dir" == "$normalized_home"* || "$dir" == /Library* ]]; then
            while IFS= read -r -d '' f; do
                is_protected_path "$f" && continue
                # P2: a file another category already owns is not listed twice
                # (app caches claim ~/Library/Logs/JetBrains; DiagnosticReports
                # has its own analyzer).
                case "$f" in */DiagnosticReports/*) continue ;; esac
                is_path_claimed "$f" && continue
                local bytes
                bytes=$(path_size_bytes "$f")
                if (( target_is_user_log == 1 )); then
                    FOUND_APP_LOGS+=("$f")
                    total_user=$(( total_user + bytes ))
                else
                    FOUND_SYSTEM_LOGS+=("$f")
                    total_system=$(( total_system + bytes ))
                fi
            done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$dir" -maxdepth 4 -type f \( -name "*.log" -o -name "*.log.gz" -o -name "*.log.[0-9]*" \) \
                -mtime "+${LOG_MAX_AGE_DAYS}" -print0 2>/dev/null)
        else
            while IFS= read -r -d '' f; do
                is_protected_path "$f" && continue
                local bytes
                bytes=$(path_size_bytes "$f")
                FOUND_SYSTEM_LOGS+=("$f")
                total_system=$(( total_system + bytes ))
            done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$dir" -maxdepth 4 -type f \( -name "*.log" -o -name "*.log.gz" -o -name "*.log.[0-9]*" \) \
                -mtime "+${LOG_MAX_AGE_DAYS}" -print0 2>/dev/null)
        fi
    done

    catbytes_set "user-logs" "$total_user"
    catbytes_set "system-logs" "$total_system"

    local total_all=$(( total_user + total_system ))
    local total_count=$(( ${#FOUND_APP_LOGS[@]} + ${#FOUND_SYSTEM_LOGS[@]} ))

    if (( total_count == 0 )); then
        print_ok "$(t "logs_ok") (criterion: > ${LOG_MAX_AGE_DAYS} days)."
    else
        print_found "$(t "logs_found"): $(bytes_to_human "$total_all") (${total_count} files)"
        print_info  "  $(t "logs_user"): $(bytes_to_human "$total_user") (${#FOUND_APP_LOGS[@]} files)"
        print_info  "  $(t "logs_system"): $(bytes_to_human "$total_system") (${#FOUND_SYSTEM_LOGS[@]} files)"
    fi
}

# ---------------------------------------------------------------------------
# analyze_diagnostic_reports — ~/Library/Logs/DiagnosticReports + /Library/Logs/DiagnosticReports
# Crash logs, spin dumps, hang reports — often accumulate unnoticed
# ---------------------------------------------------------------------------
analyze_diagnostic_reports() {
    print_section "Diagnostic Reports (crash logs, hang reports)"

    local diag_dirs=(
        "$HOME/Library/Logs/DiagnosticReports"
        "/Library/Logs/DiagnosticReports"
    )

    local total=0
    local count=0

    for dir in "${diag_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            local bytes
            bytes=$(path_size_bytes "$f")
            local b="${bytes:-0}"
            [[ "$b" -lt 1 ]] && continue
            FOUND_DIAGNOSTIC_REPORTS+=("$f")
            total=$(( total + b ))
            count=$(( count + 1 ))
        done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$dir" -maxdepth 2 -type f \
            \( -name "*.crash" -o -name "*.spin" -o -name "*.hang" -o -name "*.ips" -o -name "*.diag" \) \
            -mtime "+${LOG_MAX_AGE_DAYS}" -print0 2>/dev/null)
    done

    catbytes_set "diagnostic-reports" "$total"

    if (( count == 0 )); then
        print_ok "$(t "crash_reports_ok")"
    else
        print_found "$(t "crash_reports_found"): $(bytes_to_human "$total") (${count} files)"
        print_info  "  $(t "crash_reports_info")"
    fi
}

# ---------------------------------------------------------------------------
# analyze_tmp — /tmp and /private/tmp (macOS temp space)
# ---------------------------------------------------------------------------
analyze_tmp() {
    print_section "$(t "tmp_section_title")"

    local raw_tmp_dirs=(
        "/private/tmp"
        "/tmp"
    )
    local tmp_dirs=()
    local raw_dir norm_dir seen_dir existing_dir
    for raw_dir in "${raw_tmp_dirs[@]}"; do
        [[ -d "$raw_dir" ]] || continue
        norm_dir="$(normalize_path "$raw_dir" || echo "$raw_dir")"
        seen_dir=0
        if (( ${#tmp_dirs[@]} > 0 )); then
            for existing_dir in "${tmp_dirs[@]}"; do
                [[ "$existing_dir" == "$norm_dir" ]] && { seen_dir=1; break; }
            done
        fi
        (( seen_dir == 0 )) && tmp_dirs+=("$norm_dir")
    done

    local total=0
    for dir in "${tmp_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            is_protected_path "$f" && continue
            local bytes
            bytes=$(path_size_bytes "$f")
            FOUND_TMP_FILES+=("$f")
            total=$(( total + bytes ))
        done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$dir" -maxdepth 2 -type f \
            -not -name ".DS_Store" \
            -mmin "+$(( TMP_MAX_AGE_HOURS * 60 ))" \
            -print0 2>/dev/null)
    done

    catbytes_set "tmp" "$total"

    if (( ${#FOUND_TMP_FILES[@]} == 0 )); then
        print_ok "$(t "tmp_ok")"
    else
        print_found "$(t "tmp_found"): $(bytes_to_human "$total") (${#FOUND_TMP_FILES[@]} files)"
    fi
}

# ---------------------------------------------------------------------------
# analyze_app_leftovers — orphaned app support/prefs/containers
# ---------------------------------------------------------------------------
analyze_app_leftovers() {
    print_section "$(t "leftovers_section")"

    # Phase 2: Containers and Group Containers are protected (is_protected_path
    # skips every child) and walking them can raise macOS "access data from
    # other apps" prompts, so they are not scanned at all.
    local search_dirs=(
        "$HOME/Library/Application Support"
    )

    local total=0
    local count=0
    local size_list=""   # PF1: accumulate sizes to avoid double-du

    for search_dir in "${search_dirs[@]}"; do
        [[ -d "$search_dir" ]] || continue

        while IFS= read -r -d '' item; do
            local basename
            basename=$(basename "$item")

            # Skip known-safe system and company prefixes
            local should_skip=0
            case "$basename" in
                com.apple.*|Apple|Microsoft|Adobe|Google|JetBrains|Mozilla)
                    should_skip=1 ;;
                UBF8T346G9.Office|group.com.apple.*|group.com.microsoft.*)
                    should_skip=1 ;;
            esac
            (( should_skip )) && continue

            # Check reverse-DNS bundle ID pattern
            if [[ "$basename" =~ ^[a-zA-Z]{2,}\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+ ]]; then
                # Phase 2: the cheap protection check before the bundle lookup.
                is_protected_path "$item" && continue
                if ! app_bundle_exists "$basename" 2>/dev/null; then
                    local bytes
                    bytes=$(path_size_bytes "$item")
                    local b="${bytes:-0}"
                    [[ "$b" -lt 10240 ]] 2>/dev/null && continue  # ignore < 10 KB
                    FOUND_APP_LEFTOVERS+=("$item")
                    total=$(( total + b ))
                    count=$(( count + 1 ))
                    size_list+="${b} ${item}"$'\n'
                fi
            fi
        done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$search_dir" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
    done

    catbytes_set "app-leftovers" "$total"

    if (( count == 0 )); then
        print_ok "$(t "leftovers_ok")"
        print_info "  $(t "leftovers_heuristic_note")"
    else
        print_found "$(t "leftovers_found"): $(t "in_items" "$(bytes_to_human "$total")" "$count")"
        print_note  "  $(t "leftovers_warn")"
        # Show top 5
        echo -e "  ${C_DIM}Top 5:${C_RESET}"
        local top5=""
        top5=$(printf '%s' "$size_list" | sort -rn | head -5) || true
        while IFS=' ' read -r bytes path; do
            [[ -z "$bytes" ]] && continue
            printf "    %8s  %s\n" "$(bytes_to_human "$bytes")" "$path"
        done <<< "$top5"
    fi
}

# ---------------------------------------------------------------------------
# analyze_dev_environment — Xcode, iOS Device Support, npm, brew, pip, etc.
# ---------------------------------------------------------------------------
analyze_dev_environment() {
    print_section "$(t "dev_section")"

    scan_mark xcode-derived
    # --- Xcode DerivedData ---
    local dd="$HOME/Library/Developer/Xcode/DerivedData"
    if [[ -d "$dd" ]] && ! is_protected_path "$dd"; then
        local dd_size
        dd_size=$(path_size_bytes "$dd")
        if (( dd_size > 0 )); then
            FOUND_DEV_ITEMS+=("xcode_derived_data:$dd")
            catbytes_set "xcode-derived" "$dd_size"
            print_found "Xcode DerivedData: $(bytes_to_human "$dd_size")"
        fi
    fi

    scan_mark xcode-archives
    # --- Xcode Archives ---
    local archives="$HOME/Library/Developer/Xcode/Archives"
    if [[ -d "$archives" ]] && ! is_protected_path "$archives"; then
        local ar_size
        ar_size=$(path_size_bytes "$archives")
        if (( ar_size > 0 )); then
            FOUND_DEV_ITEMS+=("xcode_archives:$archives")
            catbytes_set "xcode-archives" "$ar_size"
            print_found "Xcode Archives (.xcarchive): $(bytes_to_human "$ar_size")"
            print_info  "  ^ $(t "archives_check_needed")"
        fi
    fi

    scan_mark simulators
    # --- iOS Simulators unavailable to current Xcode ---
    local sims="$HOME/Library/Developer/CoreSimulator/Devices"
    if [[ -d "$sims" ]] && ! is_protected_path "$sims"; then
        local sim_size=0
        local sim_count=0
        local sim_udid sim_dir sim_bytes
        while IFS= read -r sim_udid; do
            [[ -z "$sim_udid" ]] && continue
            sim_dir="${sims}/${sim_udid}"
            [[ -d "$sim_dir" ]] || continue
            is_protected_path "$sim_dir" && continue
            sim_bytes=$(path_size_bytes "$sim_dir")
            sim_size=$(( sim_size + sim_bytes ))
            sim_count=$(( sim_count + 1 ))
        done < <(simctl_unavailable_udids || true)

        if (( sim_size > 0 )); then
            FOUND_DEV_ITEMS+=("ios_simulators:$sims")
            catbytes_set "simulators" "$sim_size"
            print_found "$(t "simulators_found"): $(bytes_to_human "$sim_size") (${sim_count})"
        fi
    fi

    scan_mark sim-runtimes
    # --- Simulator runtimes simctl marks unusable ---
    analyze_sim_runtimes

    scan_mark npm npx
    # --- npm cache ---
    #
    # `npm config get cache` returns ~/.npm, but `npm cache clean --force` only
    # empties ~/.npm/_cacache. Sizing the whole directory made the tool promise
    # space it cannot reclaim: on 2026-08-19 it advertised "npm cache: 6.03 GB
    # ← 6.03 GB to free!" when _cacache held ~322 MB and the other 5.3 GB was
    # _npx, which that command never touches. Size what the command actually
    # clears, and surface _npx as its own reviewable item so the space is still
    # reachable — just honestly labelled.
    if command -v npm &>/dev/null; then
        local npm_cache_dir npm_cacache npm_npx
        npm_cache_dir=$(native_tool_target npm) || npm_cache_dir="$HOME/.npm"
        if [[ -d "$npm_cache_dir" ]]; then
            if validate_cache_path "$npm_cache_dir"; then
                npm_cacache="${npm_cache_dir}/_cacache"
                [[ -d "$npm_cacache" ]] || npm_cacache="$npm_cache_dir"
                local npm_size
                npm_size=$(path_size_bytes "$npm_cacache")
                if (( npm_size > 0 )); then
                    FOUND_DEV_ITEMS+=("npm_cache:$npm_cache_dir")
                    catbytes_set "npm" "$npm_size"
                    print_found "npm cache: $(bytes_to_human "$npm_size")  ${C_DIM}(npm cache clean --force)${C_RESET}"
                fi

                npm_npx="${npm_cache_dir}/_npx"
                if [[ -d "$npm_npx" ]]; then
                    local npx_size
                    npx_size=$(path_size_bytes "$npm_npx")
                    if (( npx_size > 0 )); then
                        FOUND_DEV_ITEMS+=("npx_cache:$npm_npx")
                        catbytes_set "npx" "$npx_size"
                        print_found "npx cache: $(bytes_to_human "$npx_size")  ${C_DIM}(${npm_npx} — not touched by npm cache clean)${C_RESET}"
                    fi
                fi
            else
                log_warn "Pathguard rejected candidate npm cache path provenance: $npm_cache_dir"
                cleanup_journal_event "path_provenance_rejected" "$npm_cache_dir" "" "0" "blocked" "pathguard provenance validation failed"
            fi
        fi
    fi

    scan_mark yarn
    # --- yarn cache ---
    if command -v yarn &>/dev/null; then
        local yarn_cache
        yarn_cache=$(native_tool_target yarn) || yarn_cache=""
        if [[ -n "$yarn_cache" && -d "$yarn_cache" ]]; then
            if validate_cache_path "$yarn_cache"; then
                local yarn_size
                yarn_size=$(path_size_bytes "$yarn_cache")
                if (( yarn_size > 0 )); then
                    FOUND_DEV_ITEMS+=("yarn_cache:$yarn_cache")
                    catbytes_set "yarn" "$yarn_size"
                    print_found "yarn cache: $(bytes_to_human "$yarn_size")"
                fi
            else
                log_warn "Pathguard rejected candidate yarn cache path provenance: $yarn_cache"
                cleanup_journal_event "path_provenance_rejected" "$yarn_cache" "" "0" "blocked" "pathguard provenance validation failed"
            fi
        fi
    fi

    scan_mark pnpm pnpm-stale
    # --- pnpm cache ---
    if command -v pnpm &>/dev/null; then
        local pnpm_cache
        pnpm_cache=$(native_tool_target pnpm) || pnpm_cache=""
        if [[ -n "$pnpm_cache" && -d "$pnpm_cache" ]]; then
            if validate_cache_path "$pnpm_cache"; then
                local pnpm_size
                pnpm_size=$(path_size_bytes "$pnpm_cache")
                if (( pnpm_size > 0 )); then
                    FOUND_DEV_ITEMS+=("pnpm_cache:$pnpm_cache")
                    catbytes_set "pnpm" "$pnpm_size"
                    print_found "pnpm store: $(bytes_to_human "$pnpm_size")"
                fi

                # `pnpm store prune` only ever touches the CURRENT store version
                # directory. Every major pnpm upgrade leaves the previous one
                # behind for good: on 2026-09-01 this machine held v3 (436 MB)
                # and v10 (3.6 GB) beside a 41 MB v11 — 4.0 GB no vendor command
                # will ever reclaim. Identical shape to ~/.npm/_npx in 3.0.4:
                # surface it as its own category and route it through
                # safe_remove (quarantine) instead of a command that cannot see it.
                local pnpm_store_root pnpm_stale_total=0 pnpm_stale_dir pnpm_stale_size
                pnpm_store_root="$(dirname "$pnpm_cache")"
                if [[ "$(basename "$pnpm_store_root")" == "store" ]]; then
                    while IFS= read -r pnpm_stale_dir; do
                        [[ -z "$pnpm_stale_dir" ]] && continue
                        [[ "$pnpm_stale_dir" == "$pnpm_cache" ]] && continue
                        is_protected_path "$pnpm_stale_dir" && continue
                        validate_cache_path "$pnpm_stale_dir" || continue
                        pnpm_stale_size=$(path_size_bytes "$pnpm_stale_dir")
                        (( pnpm_stale_size > 0 )) || continue
                        FOUND_DEV_ITEMS+=("pnpm_stale_store:$pnpm_stale_dir")
                        pnpm_stale_total=$(( pnpm_stale_total + pnpm_stale_size ))
                    done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$pnpm_store_root" -mindepth 1 -maxdepth 1 -type d -name 'v*' 2>/dev/null)
                    if (( pnpm_stale_total > 0 )); then
                        catbytes_set "pnpm-stale" "$pnpm_stale_total"
                        print_found "pnpm stale store versions: $(bytes_to_human "$pnpm_stale_total")  ${C_DIM}(pnpm store prune never touches these)${C_RESET}"
                        print_info  "  ^ files still hard-linked from a live node_modules keep their disk blocks until that project is removed too"
                    fi
                fi
            else
                log_warn "Pathguard rejected candidate pnpm cache path provenance: $pnpm_cache"
                cleanup_journal_event "path_provenance_rejected" "$pnpm_cache" "" "0" "blocked" "pathguard provenance validation failed"
            fi
        fi
    fi

    scan_mark pip
    # --- pip cache ---
    if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
        # P1-4: ask pip (PIP_CACHE_DIR / pip.conf), as plan apply does.
        local pip_cache
        pip_cache=$(native_tool_target pip) || pip_cache="$HOME/Library/Caches/pip"
        if [[ -d "$pip_cache" ]]; then
            if validate_cache_path "$pip_cache"; then
                local pip_size
                pip_size=$(path_size_bytes "$pip_cache")
                if (( pip_size > 0 )); then
                    FOUND_DEV_ITEMS+=("pip_cache:$pip_cache")
                    catbytes_set "pip" "$pip_size"
                    print_found "pip cache: $(bytes_to_human "$pip_size")"
                fi
            else
                log_warn "Pathguard rejected candidate pip cache path provenance: $pip_cache"
                cleanup_journal_event "path_provenance_rejected" "$pip_cache" "" "0" "blocked" "pathguard provenance validation failed"
            fi
        fi
    fi

    scan_mark brew
    # --- Homebrew cache ---
    if command -v brew &>/dev/null; then
        local brew_cache
        local brew_cache_found=0
        brew_cache=$(native_tool_target brew) || brew_cache="$HOME/Library/Caches/Homebrew"
        if [[ -d "$brew_cache" ]]; then
            if validate_cache_path "$brew_cache"; then
                local brew_size
                brew_size=$(path_size_bytes "$brew_cache")
                if (( brew_size > 0 )); then
                    FOUND_DEV_ITEMS+=("brew_cache:$brew_cache")
                    brew_cache_found=1
                    catbytes_set "brew" "$brew_size"
                    print_found "Homebrew cache: $(bytes_to_human "$brew_size")"
                fi
            else
                log_warn "Pathguard rejected candidate brew cache path provenance: $brew_cache"
                cleanup_journal_event "path_provenance_rejected" "$brew_cache" "" "0" "blocked" "pathguard provenance validation failed"
            fi
        fi
        # Also check for outdated formula installations
        local brew_old_size
        # CN1: parse human-readable sizes from 'Would remove: ... (N files, X.XMB)'
        local brew_dry="" _brew_rc=0
        brew_dry="$(native_query_with_timeout "$NATIVE_QUERY_TIMEOUT" "brew cleanup --dry-run" \
            brew cleanup --dry-run 2>/dev/null)" || _brew_rc=$?
        brew_old_size=0
        if (( _brew_rc == 0 )); then
            brew_old_size=$(printf '%s\n' "$brew_dry" | \
                grep "Would remove" | \
                sed 's/.*(\([^)]*\)).*/\1/' | \
                awk -F', ' '{print $NF}' | \
                awk '
                    /GB$/ { sub(/GB$/,""); total += $1 * 1073741824; next }
                    /MB$/ { sub(/MB$/,""); total += $1 * 1048576; next }
                    /[kK]B$/ { sub(/[kK]B$/,""); total += $1 * 1024; next }
                    /B$/  { sub(/B$/,"");  total += $1; next }
                    END { printf "%d", total }
                ') || brew_old_size=0
        fi
        if [[ -n "$brew_old_size" ]] && (( brew_old_size > 0 )); then
            (( brew_cache_found == 0 )) && FOUND_DEV_ITEMS+=("brew_cleanup:__brew__")
            # One brew cleanup removes the cache and the stale versions, which
            # overlap: the merged brew category is the larger estimate (R06).
            if (( brew_old_size > $(catbytes_get "brew") )); then
                catbytes_set "brew" "$brew_old_size"
            fi
            print_found "$(t "brew_stale_found" "$(bytes_to_human "$brew_old_size")")"
        fi
    fi

    scan_mark swift-pm
    # --- Swift Package Manager cache ---
    local swift_pm_cache="$HOME/Library/Caches/org.swift.swiftpm"
    local swift_pm_dir="$HOME/.swiftpm"
    local swift_total=0
    local swift_pm_dir_cache="$swift_pm_dir/cache"
    if [[ -d "$swift_pm_cache" ]]; then
        if ! is_protected_path "$swift_pm_cache"; then
            local s
            s=$(path_size_bytes "$swift_pm_cache")
            swift_total=$(( swift_total + s ))
            FOUND_DEV_ITEMS+=("swift_pm_cache:$swift_pm_cache")
        fi
    fi
    if [[ -d "$swift_pm_dir_cache" ]]; then
        if ! is_protected_path "$swift_pm_dir_cache"; then
            local s
            s=$(path_size_bytes "$swift_pm_dir_cache")
            swift_total=$(( swift_total + s ))
            FOUND_DEV_ITEMS+=("swift_pm_cache:$swift_pm_dir_cache")
        fi
    fi
    if (( swift_total > 0 )); then
        catbytes_set "swift-pm" "$swift_total"
        print_found "Swift Package Manager cache: $(bytes_to_human "$swift_total")"
    fi

    scan_mark gem
    # --- Ruby gems cache (~/.gem/cache) ---
    local gem_cache="$HOME/.gem/cache"
    if [[ -d "$gem_cache" ]] && ! is_protected_path "$gem_cache"; then
        local gem_size
        gem_size=$(path_size_bytes "$gem_cache")
        if (( gem_size > 0 )); then
            FOUND_DEV_ITEMS+=("gem_cache:$gem_cache")
            catbytes_set "gem" "$gem_size"
            print_found "Ruby gems cache (~/.gem/cache): $(bytes_to_human "$gem_size")"
        fi
    fi

    scan_mark bundler
    # --- Bundler cache (~/.bundle/cache) ---
    local bundler_cache="$HOME/.bundle/cache"
    if [[ -d "$bundler_cache" ]] && ! is_protected_path "$bundler_cache"; then
        local bundler_size
        bundler_size=$(path_size_bytes "$bundler_cache")
        if (( bundler_size > 0 )); then
            FOUND_DEV_ITEMS+=("bundler_cache:$bundler_cache")
            catbytes_set "bundler" "$bundler_size"
            print_found "Bundler cache (~/.bundle/cache): $(bytes_to_human "$bundler_size")"
        fi
    fi

    scan_mark composer
    # --- Composer cache (PHP) ---
    local composer_cache="$HOME/.composer/cache"
    local composer_cache2="$HOME/Library/Caches/composer"
    local composer_total=0
    local composer_path=""
    if [[ -d "$composer_cache" ]]; then
        if ! is_protected_path "$composer_cache"; then
            composer_total=$(path_size_bytes "$composer_cache")
            composer_path="$composer_cache"
        fi
    elif [[ -d "$composer_cache2" ]]; then
        if ! is_protected_path "$composer_cache2"; then
            composer_total=$(path_size_bytes "$composer_cache2")
            composer_path="$composer_cache2"
        fi
    fi
    if (( composer_total > 0 )); then
        FOUND_DEV_ITEMS+=("composer_cache:$composer_path")
        catbytes_set "composer" "$composer_total"
        print_found "Composer cache (PHP): $(bytes_to_human "$composer_total")"
    fi

    scan_mark gradle
    # --- Gradle cache ---
    local gradle_cache="$HOME/.gradle/caches"
    if [[ -d "$gradle_cache" ]] && ! is_protected_path "$gradle_cache"; then
        local gradle_size
        gradle_size=$(path_size_bytes "$gradle_cache")
        if (( gradle_size > 0 )); then
            FOUND_DEV_ITEMS+=("gradle_cache:$gradle_cache")
            catbytes_set "gradle" "$gradle_size"
            print_found "Gradle cache: $(bytes_to_human "$gradle_size")"
        fi
    fi

    scan_mark maven
    # --- Maven cache ---
    local maven_cache="$HOME/.m2/repository"
    if [[ -d "$maven_cache" ]] && ! is_protected_path "$maven_cache"; then
        local maven_size
        maven_size=$(path_size_bytes "$maven_cache")
        if (( maven_size > 0 )); then
            FOUND_DEV_ITEMS+=("maven_cache:$maven_cache")
            catbytes_set "maven" "$maven_size"
            print_found "Maven cache: $(bytes_to_human "$maven_size")"
        fi
    fi

    scan_mark cocoapods
    # --- CocoaPods cache ---
    local cocoa_cache="$HOME/Library/Caches/CocoaPods"
    if [[ -d "$cocoa_cache" ]] && ! is_protected_path "$cocoa_cache"; then
        local cocoa_size
        cocoa_size=$(path_size_bytes "$cocoa_cache")
        if (( cocoa_size > 0 )); then
            FOUND_DEV_ITEMS+=("cocoapods_cache:$cocoa_cache")
            catbytes_set "cocoapods" "$cocoa_size"
            print_found "CocoaPods cache: $(bytes_to_human "$cocoa_size")"
        fi
    fi

    scan_mark docker
    # --- Docker ---
    if command -v docker &>/dev/null \
        && native_query_with_timeout "$NATIVE_QUERY_TIMEOUT" "docker info" docker info &>/dev/null; then
        local docker_output=""
        # CN2 (P1-5): ask for TYPE|RECLAIMABLE directly. Splitting the table on
        # whitespace shifted the two-word "Build Cache" row one column, so its
        # SIZE was read as RECLAIMABLE. Docker prints decimal SI units.
        docker_output=$(native_query_with_timeout "$NATIVE_QUERY_TIMEOUT" "docker system df" \
            docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null) || docker_output=""
        if [[ -n "$docker_output" ]]; then
            local docker_reclaim=0
            local rb
            rb=$(printf '%s\n' "$docker_output" | awk -F'|' '
                $1 == "Local Volumes" || $1 == "Volumes" { next }
                {
                    val=$2
                    sub(/[[:space:]]*\(.*$/, "", val)   # strip " (XX%)"
                    gsub(/[[:space:]]/, "", val)
                    if (val ~ /^[0-9.]+TB$/)      { sub(/TB$/,"",val); total += val * 1000000000000 }
                    else if (val ~ /^[0-9.]+GB$/) { sub(/GB$/,"",val); total += val * 1000000000 }
                    else if (val ~ /^[0-9.]+MB$/) { sub(/MB$/,"",val); total += val * 1000000 }
                    else if (val ~ /^[0-9.]+[kK]B$/) { sub(/[kK]B$/,"",val); total += val * 1000 }
                    else if (val ~ /^[0-9.]+B$/)  { sub(/B$/,"",val);  total += val }
                }
                END { printf "%d", total }
            ') || rb=0
            docker_reclaim="${rb:-0}"
            if (( docker_reclaim > 0 )); then
                FOUND_DEV_ITEMS+=("docker_prune:__docker__")
                catbytes_set "docker" "$docker_reclaim"
                print_found "Docker (reclaimable): $(bytes_to_human "$docker_reclaim")"
            fi
        fi
    fi

    scan_mark cargo
    # --- Rust / Cargo ---
    local cargo_cache="$HOME/.cargo/registry"
    if [[ -d "$cargo_cache" ]] && ! is_protected_path "$cargo_cache"; then
        local cargo_size
        cargo_size=$(path_size_bytes "$cargo_cache")
        if (( cargo_size > 0 )); then
            FOUND_DEV_ITEMS+=("cargo_cache:$cargo_cache")
            catbytes_set "cargo" "$cargo_size"
            print_found "Cargo registry cache: $(bytes_to_human "$cargo_size")"
        fi
    fi

    scan_mark android-avd
    # --- Android AVD ---
    local avd_dir="$HOME/.android/avd"
    if [[ -d "$avd_dir" ]] && ! is_protected_path "$avd_dir"; then
        local avd_size
        avd_size=$(path_size_bytes "$avd_dir")
        if (( avd_size > 0 )); then
            FOUND_DEV_ITEMS+=("android_avd:$avd_dir")
            catbytes_set "android-avd" "$avd_size"
            print_found "Android AVD emulators: $(bytes_to_human "$avd_size")"
            print_info  "  ^ $(t "avd_review_note")"
        fi
    fi

    if (( ${#FOUND_DEV_ITEMS[@]} == 0 )); then
        print_ok "No significant dev data to clean."
    fi
}

# ---------------------------------------------------------------------------
# device_support_newest_version <platform-dir> — prints the version directory
# with the highest version number ("17.4 (21E213)" > "17.0.1 (21A340)"); equal
# or unparseable versions are decided by modification time. Fails when the
# platform has no version directory.
# ---------------------------------------------------------------------------
_ds_version_cmp() {  # _ds_version_cmp <a> <b> -> 0 when a > b
    local a="$1" b="$2" x y
    while [[ -n "$a" || -n "$b" ]]; do
        x="${a%%.*}"; y="${b%%.*}"
        case "$x" in ''|*[!0-9]*) x=0 ;; esac
        case "$y" in ''|*[!0-9]*) y=0 ;; esac
        if (( 10#$x > 10#$y )); then return 0; fi
        if (( 10#$x < 10#$y )); then return 1; fi
        if [[ "$a" == *.* ]]; then a="${a#*.}"; else a=""; fi
        if [[ "$b" == *.* ]]; then b="${b#*.}"; else b=""; fi
    done
    return 2
}

device_support_newest_version() {
    local base="$1" dir name ver best="" best_ver="" best_m=0 m rc
    while IFS= read -r -d '' dir; do
        name="${dir##*/}"
        ver="${name%% *}"
        case "$ver" in [0-9]*) ;; *) ver="" ;; esac
        m="$(file_mtime_seconds "$dir" 2>/dev/null)" || m=0
        case "$m" in ''|*[!0-9]*) m=0 ;; esac
        if [[ -z "$best" ]]; then
            best="$dir"; best_ver="$ver"; best_m="$m"
            continue
        fi
        rc=0
        _ds_version_cmp "${ver:-0}" "${best_ver:-0}" || rc=$?
        if (( rc == 0 )) || { (( rc == 2 )) && (( m > best_m )); }; then
            best="$dir"; best_ver="$ver"; best_m="$m"
        fi
    done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    [[ -n "$best" ]] || return 1
    printf '%s\n' "$best"
}

# ---------------------------------------------------------------------------
# analyze_ios_device_support — ~/Library/Developer/Xcode/*DeviceSupport
# These symbol files for old iOS versions can take up 10-50+ GB
# ---------------------------------------------------------------------------
analyze_ios_device_support() {
    print_section "Device Support (Xcode debug symbols)"

    local dev_base="$HOME/Library/Developer/Xcode"
    local total=0
    local count=0

    # Scan all *DeviceSupport directories
    local ds_types=("iOS DeviceSupport" "watchOS DeviceSupport" "tvOS DeviceSupport" "macOS DeviceSupport")
    for ds_type in "${ds_types[@]}"; do
        local ds_base="${dev_base}/${ds_type}"
        [[ -d "$ds_base" ]] || continue

        # Each subdirectory is a different OS version. V4 §13.3: the newest
        # version of each platform is never a candidate, whatever its age.
        local ds_newest=""
        ds_newest="$(device_support_newest_version "$ds_base")" || ds_newest=""
        while IFS= read -r -d '' version_dir; do
            is_protected_path "$version_dir" && continue
            [[ -n "$ds_newest" && "$version_dir" == "$ds_newest" ]] && continue
            if ! file_older_than_days "$version_dir" "$DEVICE_SUPPORT_MIN_AGE_DAYS"; then
                continue
            fi

            local bytes
            bytes=$(path_size_bytes "$version_dir")
            local b="${bytes:-0}"
            [[ "$b" -lt 1048576 ]] && continue  # ignore < 1 MB

            FOUND_DEVICE_SUPPORT_ITEMS+=("${ds_type}:${version_dir}")
            total=$(( total + b ))
            count=$(( count + 1 ))
            local ver_name
            ver_name=$(basename "$version_dir")
            printf "  ${C_YELLOW}->${C_RESET}  %-45s  %s\n" "${ds_type} / ${ver_name}" "$(bytes_to_human "$b")"
        done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$ds_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    done

    catbytes_set "device-support" "$total"

    if (( count == 0 )); then
        print_ok "$(t "device_support_ok")"
    else
        print_found "Xcode Device Support: $(bytes_to_human "$total") in ${count} OS versions"
        print_info  "  ^ $(t "device_support_info_1")"
        print_info  "  $(t "device_support_info_2")"
    fi
}

# ---------------------------------------------------------------------------
# analyze_time_machine — local snapshots
# ---------------------------------------------------------------------------
analyze_time_machine() {
    print_section "Time Machine — local snapshots"

    if ! command -v tmutil &>/dev/null; then
        print_skip "$(t "tmutil_missing")"
        return
    fi

    local snapshots="" _tm_rc=0
    snapshots=$(native_query_with_timeout "$NATIVE_QUERY_TIMEOUT" "tmutil listlocalsnapshots /" \
        tmutil listlocalsnapshots / 2>/dev/null) || _tm_rc=$?
    if (( _tm_rc == 124 )); then
        # Unknown, not "no snapshots": do not report 0 bytes.
        print_warn "Time Machine snapshot query timed out; local snapshots not measured."
        return 0
    fi
    (( _tm_rc == 0 )) || snapshots=""

    if [[ -z "$snapshots" ]]; then
        print_ok "$(t "tmutil_ok")"
        catbytes_set "tm-snapshots" 0
        return
    fi

    local count=0
    count=$(echo "$snapshots" | grep -c "com.apple.TimeMachine" 2>/dev/null) || count=0

    print_info "$(t "tm_snapshots_count" "$count")"

    while IFS= read -r snap; do
        [[ -z "$snap" ]] && continue
        # Skip the header line "Snapshots for disk /:"
        [[ "$snap" != com.apple.TimeMachine.* ]] && continue
        echo -e "    ${C_DIM}• ${snap}${C_RESET}"
        FOUND_TM_SNAPSHOTS+=("$snap")
    done <<< "$snapshots"

    # Show purgeable space
    if command -v diskutil &>/dev/null; then
        local target_vol="/"
        [[ -d "/System/Volumes/Data" ]] && target_vol="/System/Volumes/Data"
        local purgeable=""
        purgeable=$(optional_command_with_timeout "$SCAN_TOOL_TIMEOUT" diskutil info "$target_vol" 2>/dev/null | grep -i "Purgeable" | \
            head -1 | sed 's/.*:[[:space:]]*//' | sed 's/ (.*//' | sed 's/[[:space:]]*$//') \
            || purgeable=""
        if [[ -n "$purgeable" ]]; then
            print_info "Purgeable (APFS): ${purgeable}  <- macOS will reclaim automatically"
        fi
    fi

    catbytes_set "tm-snapshots" "$count"
}

# ---------------------------------------------------------------------------
# analyze_ios_backups — ~/Library/Application Support/MobileSync/Backup
# ---------------------------------------------------------------------------
analyze_ios_backups() {
    print_section "iOS/iPadOS Backups"

    local backup_base="$HOME/Library/Application Support/MobileSync/Backup"

    if [[ ! -d "$backup_base" ]]; then
        print_ok "$(t "ios_backups_ok")"
        catbytes_set "ios-backups" 0
        return
    fi

    local total=0
    local count=0

    while IFS= read -r -d '' backup_dir; do
        is_protected_path "$backup_dir" && continue
        local bytes
        bytes=$(path_size_bytes "$backup_dir")
        FOUND_IOS_BACKUPS+=("$backup_dir")
        total=$(( total + bytes ))
        count=$(( count + 1 ))

        local info_plist="${backup_dir}/Info.plist"
        local device_name
        device_name="$(t "unknown_device")"
        local last_backup="Unknown date"
        if [[ -f "$info_plist" ]]; then
            device_name=$(optional_command_with_timeout "$SCAN_TOOL_TIMEOUT" defaults read "$info_plist" "Device Name" 2>/dev/null || echo "$(t "unknown_device")")
            last_backup=$(optional_command_with_timeout "$SCAN_TOOL_TIMEOUT" defaults read "$info_plist" "Last Backup Date" 2>/dev/null || echo "Unknown date")
        fi

        print_found "  ${device_name}  $(bytes_to_human "$bytes")  (last: ${last_backup})"
    done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$backup_base" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

    catbytes_set "ios-backups" "$total"

    if (( count == 0 )); then
        print_ok "$(t "ios_backups_ok")"
    else
        print_found "$(t "ios_backups_found_total"): $(bytes_to_human "$total") in ${count} backups"
        print_warn  "$(t "ios_backups_warn")"
    fi
}

# ---------------------------------------------------------------------------
# analyze_large_dmg_pkg — old installers in ~/Downloads
# ---------------------------------------------------------------------------
analyze_large_dmg_pkg() {
    print_section "Old installers (DMG, PKG) in ~/Downloads"

    [[ -d "$HOME/Downloads" ]] || return

    local total=0
    local count=0
    local size_list=""   # PF1: accumulate sizes to avoid double-du

    while IFS= read -r -d '' f; do
        is_protected_path "$f" && continue
        local bytes
        bytes=$(path_size_bytes "$f")
        local b="${bytes:-0}"
        [[ "$b" -lt 10485760 ]] 2>/dev/null && continue  # ignore < 10 MB
        FOUND_DMG_PKG+=("$f")
        total=$(( total + b ))
        count=$(( count + 1 ))
        size_list+="${b} ${f}"$'\n'
    done < <(optional_command_with_timeout "$SCAN_FIND_TIMEOUT" find "$HOME/Downloads" -maxdepth 2 -type f \
        \( -iname "*.dmg" -o -iname "*.pkg" -o -iname "*.iso" -o -iname "*.mpkg" \) \
        -mtime "+${DMG_MAX_AGE_DAYS}" \
        -print0 2>/dev/null)

    catbytes_set "installers" "$total"

    if (( count == 0 )); then
        print_ok "$(t "downloads_ok")"
    else
        print_found "Old installers: $(bytes_to_human "$total") (${count} files)"
        local top5=""
        top5=$(printf '%s' "$size_list" | sort -rn | head -5) || true
        while IFS=' ' read -r bytes path; do
            [[ -z "$bytes" ]] && continue
            printf "    %8s  %s\n" "$(bytes_to_human "$bytes")" "$path"
        done <<< "$top5"
    fi
}

# ---------------------------------------------------------------------------
# _run_analyzer — wrapper that isolates errors from set -euo pipefail
# ---------------------------------------------------------------------------
_run_analyzer() {
    local fn="$1"
    "$fn" || {
        # shellcheck disable=SC2034
        ANALYSIS_PARTIAL=1
        print_warn "Analysis '${fn}' failed (skipping, continuing)."
        log_warn "Analyzer function '${fn}' failed — continuing."
    }
}

# ---------------------------------------------------------------------------
# run_full_analysis — orchestrate all analyzers
# ---------------------------------------------------------------------------
run_full_analysis() {
    local categories=("$@")
    local cat fn seen id i
    local -a fns=()
    if (( ${#categories[@]} == 0 )); then
        categories=("${ALL_CATEGORIES[@]}")
    fi
    registry_require

    for cat in "${categories[@]}"; do
        if ! reg_is_section "$cat" || [[ "$cat" == "overview" ]]; then
            print_warn "$(t "unknown_category" "$cat")"
            continue
        fi
        # The section's analyzers, in registry order, each once (R06). One
        # rule the registry cannot express: the app-specific caches are
        # measured (and claimed) before the generic ~/Library/Caches scan.
        fns=()
        seen=" "
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            reg_get "$id" analyzer || continue
            fn="$REPLY"
            case "$seen" in *" ${fn} "*) continue ;; esac
            seen="${seen}${fn} "
            fns+=("$fn")
        done < <(reg_ids "$cat")
        if [[ "$seen" == *" analyze_app_specific_caches "* && "$seen" == *" analyze_user_caches "* ]]; then
            fns=("analyze_app_specific_caches" "analyze_user_caches")
        fi
        (( ${#fns[@]} > 0 )) || continue
        for (( i=0; i<${#fns[@]}; i++ )); do
            _run_analyzer_scan_events "${fns[$i]}" "$cat"
        done
    done
}

# _run_analyzer_scan_events <fn> <section> — one analyzer wrapped in the
# scan-phase events of every registry id it measures (V4 §3: group_start,
# group_sized, group_end, phase scan). No-ops without the event channel.
_run_analyzer_scan_events() {
    local fn="$1" sec="$2" id ids="" t0 partial=0 unit bytes
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        reg_get "$id" section || continue
        [[ "$REPLY" == "$sec" ]] || continue
        ids="${ids} ${id}"
    done < <(reg_ids_for_analyzer "$fn")
    t0=$SECONDS
    for id in $ids; do mc_group_start "$id" scan; unset "_SCANSECS_${id//-/_}"; done
    _SCAN_MARK_IDS=""
    ANALYSIS_PARTIAL="${ANALYSIS_PARTIAL:-0}"
    local before_partial="$ANALYSIS_PARTIAL"
    _run_analyzer "$fn"
    scan_mark ""
    [[ "$ANALYSIS_PARTIAL" != "$before_partial" ]] && partial=1
    local secs
    for id in $ids; do
        reg_get "$id" unit; unit="$REPLY"
        bytes="$(catbytes_get "$id")"
        mc_group_sized "$id" "$bytes" 0 "$partial" "$unit"
        # The category's own time when the analyzer marked it, else the whole analyzer's.
        if scan_secs_get "$id"; then secs="$REPLY"; else secs=$(( SECONDS - t0 )); fi
        log_info "scan time: ${id} ${secs}s"
        mc_group_end "$id" scan "$secs"
    done
    return 0
}
