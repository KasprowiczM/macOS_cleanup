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
# shellcheck disable=SC2034
declare -a FOUND_LARGE_FILES=()
# shellcheck disable=SC2034
FOUND_DERIVED_DATA=""
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

optional_command_with_timeout() {
    local seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$seconds" "$@"
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$seconds" "$@" <<'PY'
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
    xcrun simctl list devices unavailable 2>/dev/null | grep -Eo '[0-9A-Fa-f-]{36}' | sort -u
}

# analyze_sim_runtimes — simulator runtimes that simctl itself marks unusable.
# They live in a system-managed store, so only `xcrun simctl runtime delete
# --unusable` may remove them. Its dry-run names the runtimes it would delete
# on stderr (and exits 2 with "No matching images found to delete" when there
# are none), so both streams are read and the exit status is not trusted;
# only runtime UUIDs in the report count. The size is the sum of `sizeBytes`
# for exactly those runtimes; when it cannot be read (or is 0) the runtimes
# are still offered, as size unknown. Without developer tools xcrun is not
# run: its shim can open the install-tools dialog during a read-only scan.
analyze_sim_runtimes() {
    command -v xcrun >/dev/null 2>&1 || return 0
    xcode-select -p >/dev/null 2>&1 || return 0
    local dry="" uuids="" bytes=""
    dry="$(xcrun simctl runtime delete --unusable --dry-run 2>&1)" || true
    case "$dry" in *"No matching images found to delete"*) return 0 ;; esac
    uuids="$(printf '%s\n' "$dry" \
        | grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | sort -u)" || uuids=""
    [[ -n "$uuids" ]] || return 0
    bytes="$(xcrun simctl runtime list -j 2>/dev/null | python3 -I -c '
import json, sys
want = {u.upper() for u in sys.argv[1].split()}
total = 0
for key, rt in json.load(sys.stdin).items():
    if not isinstance(rt, dict):
        continue
    if str(rt.get("identifier") or key).upper() in want:
        total += int(rt.get("sizeBytes") or 0)
print(total)
' "$uuids" 2>/dev/null)" || bytes=""
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
    print_section "Inwentarz aplikacji"

    local app_dirs=("/Applications" "$HOME/Applications" "/System/Applications")
    local dir app count=0
    FOUND_INSTALLED_APPS=()

    for dir in "${app_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' app; do
            FOUND_INSTALLED_APPS+=("$app")
            count=$(( count + 1 ))
        done < <(find "$dir" -maxdepth 2 -name "*.app" -print0 2>/dev/null)
    done

    if (( count > 0 )) && (( ${#FOUND_INSTALLED_APPS[@]} > 0 )); then
        print_found "Aplikacje .app: ${count}"
        printf '%s\n' "${FOUND_INSTALLED_APPS[@]}" | sort | head -10 | while IFS= read -r app; do
            echo "    $(basename "$app" .app)"
        done
    else
        print_skip "Nie znaleziono aplikacji .app w standardowych lokalizacjach."
    fi

    FOUND_BREW_PACKAGES=()
    if command -v brew >/dev/null 2>&1; then
        local brew_count=0 brew_output=""
        brew_output="$(optional_command_with_timeout 15 brew list --formula 2>/dev/null || true)"
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            FOUND_BREW_PACKAGES+=("$pkg")
            brew_count=$(( brew_count + 1 ))
        done <<< "$brew_output"
        brew_output="$(optional_command_with_timeout 15 brew list --cask 2>/dev/null || true)"
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
        if ! mas_output="$(optional_command_with_timeout 8 mas list 2>/dev/null)"; then
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

analyze_mail_storage() {
    print_section "Apple Mail — analiza bez czyszczenia"

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
        print_warn "  $(t "mail_warn_1")"
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

    if (( ${#FOUND_MAIL_ITEMS[@]} == 0 )); then
        print_ok "$(t "mail_ok")"
    else
        catbytes_set "mail-total" "$total"
        print_info "$(t "mail_danger")"
    fi
}

analyze_browser_storage() {
    print_section "$(t "browsers_section")"

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
        print_warn "$(t "browsers_data_warn") ($(bytes_to_human "$total_data"))"
        print_info "  $(t "browsers_data_rec")"
    fi
    if (( total_cache == 0 && total_data == 0 )); then
        print_ok "$(t "browsers_ok")"
    fi
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
    df -h "$target_vol" 2>/dev/null | awk 'NR==1{next} {
        printf "    Size: %s  |  Used: %s  |  Free: %s  (%s)\n", $2, $3, $4, $5
    }' || true
    echo

    # --- APFS Free & Purgeable space ---
    if command -v diskutil &>/dev/null; then
        local diskinfo=""
        diskinfo=$(diskutil info "$target_vol" 2>/dev/null) || diskinfo=""

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
            avail_bytes=$(df -k "$target_vol" 2>/dev/null | awk 'NR==2{print $4*1024}') || avail_bytes=""
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
            snap_count=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine") || snap_count=0
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
    # informational only, so it is bounded (HOME_TOP_DIRS_TIMEOUT, default
    # 20 s), stays on the home volume (-x) and skips iCloud Drive and
    # CloudStorage, whose dataless files must not be enumerated or fetched.
    if _is_full_scan; then
        print_info "$(t "disk_home_top10")"
        local home_top="" home_line home_dir home_left home_rc home_cut=0
        local home_limit="${HOME_TOP_DIRS_TIMEOUT:-20}"
        case "$home_limit" in ''|*[!0-9]*) home_limit=20 ;; esac
        (( home_limit >= 1 )) || home_limit=20
        # One du per directory under a shared deadline: du block-buffers its
        # output, so a single timed-out du over every directory printed nothing.
        # Each directory gets at most a quarter of the budget, so one huge
        # tree cannot starve the rest; it is listed as not measured instead.
        local home_deadline=$(( $(date +%s) + home_limit )) home_cap=$(( home_limit / 4 ))
        local home_slow=""
        (( home_cap >= 1 )) || home_cap=1
        for home_dir in "$HOME"/*/; do
            [[ -d "$home_dir" ]] || continue
            home_left=$(( home_deadline - $(date +%s) ))
            if (( home_left < 1 )); then home_cut=1; break; fi
            (( home_left > home_cap )) && home_left=$home_cap
            home_rc=0
            home_line="$(optional_command_with_timeout "$home_left" \
                du -x -sh -I 'Mobile Documents' -I CloudStorage "$home_dir" 2>/dev/null)" || home_rc=$?
            if (( home_rc == 124 )); then
                home_cut=1
                home_slow+="    >${home_left}s	${home_dir}"$'\n'
                continue
            fi
            [[ -n "$home_line" ]] && home_top+="${home_line}"$'\n'
        done
        if [[ -n "$home_top" ]]; then
            printf '%s' "$home_top" | sort -rh 2>/dev/null | head -10 | \
                while IFS= read -r line; do
                    echo "    $line"
                done || true
        fi
        [[ -n "$home_slow" ]] && printf '%s' "$home_slow"
        if (( home_cut == 1 )); then
            print_info "    $(t "disk_home_top10_partial" "$home_limit")"
        fi
        echo
    fi
}

# ---------------------------------------------------------------------------
# analyze_trash — ~/.Trash
# Always safe; often overlooked source of GBs.
# ---------------------------------------------------------------------------
analyze_trash() {
    print_section "Kosz (Trash)"

    local trash_dir="$HOME/.Trash"
    if [[ ! -d "$trash_dir" ]]; then
        print_ok "Kosz jest pusty lub nie istnieje."
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
    done < <(find "$trash_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    catbytes_set "trash" "$total"

    if (( count == 0 )); then
        print_ok "Kosz jest pusty."
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
    done < <(find "$cache_base" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

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
    print_section "Cache konkretnych aplikacji (Electron, Adobe, JetBrains...)"

    # Map: label → path (use parallel arrays since bash 3.2 has no assoc arrays)
    local app_labels=()
    local app_paths=()

    # Electron-based apps store cache in Application Support
    app_labels+=("Slack (Electron cache)")
    app_paths+=("$HOME/Library/Application Support/Slack/Cache")

    app_labels+=("Slack (Code Cache)")
    app_paths+=("$HOME/Library/Application Support/Slack/Code Cache")

    app_labels+=("Slack (GPU Cache)")
    app_paths+=("$HOME/Library/Application Support/Slack/GPUCache")

    app_labels+=("VS Code (Cache)")
    app_paths+=("$HOME/Library/Application Support/Code/Cache")

    app_labels+=("VS Code (Code Cache)")
    app_paths+=("$HOME/Library/Application Support/Code/Code Cache")

    app_labels+=("VS Code (CachedData)")
    app_paths+=("$HOME/Library/Application Support/Code/CachedData")

    app_labels+=("VS Code (CachedExtensionVSIXs)")
    app_paths+=("$HOME/Library/Application Support/Code/CachedExtensionVSIXs")

    app_labels+=("Cursor (Cache)")
    app_paths+=("$HOME/Library/Application Support/Cursor/Cache")

    app_labels+=("Cursor (Code Cache)")
    app_paths+=("$HOME/Library/Application Support/Cursor/Code Cache")

    app_labels+=("Figma (Cache)")
    app_paths+=("$HOME/Library/Caches/com.figma.Desktop")

    app_labels+=("JetBrains IDEs (Cache)")
    app_paths+=("$HOME/Library/Caches/JetBrains")

    app_labels+=("JetBrains IDEs (Logs)")
    app_paths+=("$HOME/Library/Logs/JetBrains")

    app_labels+=("Adobe (Cache)")
    app_paths+=("$HOME/Library/Caches/Adobe")

    app_labels+=("Adobe Media Cache Files")
    app_paths+=("$HOME/Library/Application Support/Adobe/Common/Media Cache Files")

    app_labels+=("Adobe Media Cache")
    app_paths+=("$HOME/Library/Application Support/Adobe/Common/Media Cache")

    app_labels+=("Microsoft Teams (Cache)")
    app_paths+=("$HOME/Library/Application Support/Microsoft/Teams/Cache")

    app_labels+=("Microsoft Teams (Code Cache)")
    app_paths+=("$HOME/Library/Application Support/Microsoft/Teams/Code Cache")

    app_labels+=("Spotify (Cache)")
    app_paths+=("$HOME/Library/Caches/com.spotify.client")

    app_labels+=("Spotify (PersistentCache)")
    app_paths+=("$HOME/Library/Application Support/Spotify/PersistentCache")

    app_labels+=("Discord (Cache)")
    app_paths+=("$HOME/Library/Application Support/discord/Cache")

    app_labels+=("Discord (Code Cache)")
    app_paths+=("$HOME/Library/Application Support/discord/Code Cache")

    app_labels+=("Zoom (Cache)")
    app_paths+=("$HOME/Library/Caches/us.zoom.xos")

    app_labels+=("Xcode (Cache)")
    app_paths+=("$HOME/Library/Caches/com.apple.dt.Xcode")

    app_labels+=("CleanMyMac (Cache)")
    app_paths+=("$HOME/Library/Caches/com.macpaw.CleanMyMac4")

    local total=0
    local found_count=0
    local i=0

    while [[ $i -lt ${#app_labels[@]} ]]; do
        local label="${app_labels[$i]}"
        local path="${app_paths[$i]}"
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
        found_count=$(( found_count + 1 ))
        printf "  ${C_YELLOW}→${C_RESET}  %-40s  %s\n" "$label" "$(bytes_to_human "$b")"
    done

    catbytes_set "app-caches" "$total"

    if (( found_count == 0 )); then
        print_ok "Brak znanych cache aplikacji (Slack, VS Code, JetBrains, Adobe...)."
    else
        print_found "Cache aplikacji: $(bytes_to_human "$total") w ${found_count} lokalizacjach"
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
    print_section "Logi aplikacji i systemu (>$LOG_MAX_AGE_DAYS dni)"

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
            done < <(find "$dir" -maxdepth 4 -type f \( -name "*.log" -o -name "*.log.gz" -o -name "*.log.[0-9]*" \) \
                -mtime "+${LOG_MAX_AGE_DAYS}" -print0 2>/dev/null)
        else
            while IFS= read -r -d '' f; do
                is_protected_path "$f" && continue
                local bytes
                bytes=$(path_size_bytes "$f")
                FOUND_SYSTEM_LOGS+=("$f")
                total_system=$(( total_system + bytes ))
            done < <(find "$dir" -maxdepth 4 -type f \( -name "*.log" -o -name "*.log.gz" -o -name "*.log.[0-9]*" \) \
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
        done < <(find "$dir" -maxdepth 2 -type f \
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
    print_section "Pliki tymczasowe (/tmp, /private/tmp)"

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
        done < <(find "$dir" -maxdepth 2 -type f \
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
        done < <(find "$search_dir" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
    done

    catbytes_set "app-leftovers" "$total"

    if (( count == 0 )); then
        print_ok "$(t "leftovers_ok")"
        print_info "  $(t "leftovers_heuristic_note")"
    else
        print_found "$(t "leftovers_found"): $(t "in_items" "$(bytes_to_human "$total")" "$count")"
        print_warn  "  $(t "leftovers_warn")"
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

    # --- Xcode DerivedData ---
    local dd="$HOME/Library/Developer/Xcode/DerivedData"
    if [[ -d "$dd" ]] && ! is_protected_path "$dd"; then
        local dd_size
        dd_size=$(path_size_bytes "$dd")
        if (( dd_size > 0 )); then
            # shellcheck disable=SC2034
            FOUND_DERIVED_DATA="$dd"
            FOUND_DEV_ITEMS+=("xcode_derived_data:$dd")
            catbytes_set "xcode-derived" "$dd_size"
            print_found "Xcode DerivedData: $(bytes_to_human "$dd_size")"
        fi
    fi

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

    # --- Simulator runtimes simctl marks unusable ---
    analyze_sim_runtimes

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
                    done < <(find "$pnpm_store_root" -mindepth 1 -maxdepth 1 -type d -name 'v*' 2>/dev/null)
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
        brew_old_size=$(brew cleanup --dry-run 2>/dev/null | \
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
        if [[ -n "$brew_old_size" ]] && (( brew_old_size > 0 )); then
            (( brew_cache_found == 0 )) && FOUND_DEV_ITEMS+=("brew_cleanup:__brew__")
            catbytes_set "brew-stale" "$brew_old_size"
            print_found "Homebrew stare wersje (brew cleanup): $(bytes_to_human "$brew_old_size")"
        fi
    fi

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

    # --- Docker ---
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        local docker_output=""
        # CN2 (P1-5): ask for TYPE|RECLAIMABLE directly. Splitting the table on
        # whitespace shifted the two-word "Build Cache" row one column, so its
        # SIZE was read as RECLAIMABLE. Docker prints decimal SI units.
        docker_output=$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null) || docker_output=""
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

        # Each subdirectory is a different OS version
        while IFS= read -r -d '' version_dir; do
            is_protected_path "$version_dir" && continue
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
        done < <(find "$ds_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
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

    local snapshots=""
    snapshots=$(tmutil listlocalsnapshots / 2>/dev/null) || snapshots=""

    if [[ -z "$snapshots" ]]; then
        print_ok "$(t "tmutil_ok")"
        catbytes_set "time-machine" 0
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
        purgeable=$(diskutil info "$target_vol" 2>/dev/null | grep -i "Purgeable" | \
            head -1 | sed 's/.*:[[:space:]]*//' | sed 's/ (.*//' | sed 's/[[:space:]]*$//') \
            || purgeable=""
        if [[ -n "$purgeable" ]]; then
            print_info "Purgeable (APFS): ${purgeable}  <- macOS will reclaim automatically"
        fi
    fi

    catbytes_set "time-machine" "$count"
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
            device_name=$(defaults read "$info_plist" "Device Name" 2>/dev/null || echo "$(t "unknown_device")")
            last_backup=$(defaults read "$info_plist" "Last Backup Date" 2>/dev/null || echo "Unknown date")
        fi

        print_found "  ${device_name}  $(bytes_to_human "$bytes")  (last: ${last_backup})"
    done < <(find "$backup_base" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

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
    done < <(find "$HOME/Downloads" -maxdepth 2 -type f \
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
    if (( ${#categories[@]} == 0 )); then
        categories=("${ALL_CATEGORIES[@]}")
    fi

    for cat in "${categories[@]}"; do
        case "$cat" in
            trash)         _run_analyzer analyze_trash ;;
            system)        _run_analyzer analyze_system_caches
                           _run_analyzer analyze_tmp ;;
            user-caches)   _run_analyzer analyze_app_specific_caches
                           _run_analyzer analyze_user_caches ;;
            logs)          _run_analyzer analyze_logs
                           _run_analyzer analyze_diagnostic_reports ;;
            app-leftovers) _run_analyzer analyze_app_leftovers ;;
            dev)           _run_analyzer analyze_dev_environment
                           _run_analyzer analyze_ios_device_support ;;
            time-machine)  _run_analyzer analyze_time_machine
                           _run_analyzer analyze_ios_backups ;;
            large-files)   _run_analyzer analyze_large_dmg_pkg ;;
            *)             print_warn "Nieznana kategoria: $cat" ;;
        esac
    done
}
