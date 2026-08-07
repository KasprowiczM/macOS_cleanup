#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared utilities: logging, output, formatting, safety checks
# Bash 3.2 compatible — no declare -A, no ${var,,}
# =============================================================================

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # Strip any ANSI escape sequences so log files stay plain-text.
    # Handles both real ESC bytes and literal "\033" / "\e" sequences
    # that may appear when colour variables are interpolated into log strings.
    local plain
    plain=$(printf '%s' "$msg" | sed -E \
        -e 's/\x1B\[[0-9;]*[A-Za-z]//g' \
        -e 's/\\033\[[0-9;]*[A-Za-z]//g' \
        -e 's/\\e\[[0-9;]*[A-Za-z]//g')
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    echo "[${ts}] [${level}] ${plain}" >> "${LOG_FILE}" 2>/dev/null || true
}

log_debug() { [[ "${LOG_LEVEL}" == "DEBUG" ]] && _log "DEBUG" "$@" || true; }
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Signal & Trap Handlers
# ---------------------------------------------------------------------------

_on_exit() {
    local rc=$?
    log_debug "Exit handler called with status ${rc}"
    return $rc
}

_on_error() {
    local line="${1:-0}"
    log_error "Unhandled error occurred on line ${line}"
}

_on_interrupt() {
    echo
    print_warn "Script interrupted (signal INT/TERM)."
    exit 130
}

# Sourcing i18n dictionaries
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_PROJ_ROOT="$(cd "${_COMMON_DIR}/.." && pwd -P)"
if [[ -d "${_PROJ_ROOT}/i18n" ]]; then
    for _lang_file in "${_PROJ_ROOT}/i18n/"*.sh; do
        if [[ -f "$_lang_file" ]]; then
            # shellcheck disable=SC1090
            source "$_lang_file"
        fi
    done
fi

t() {
    local key="${1:-}"
    local lang="${LANG_CODE:-pl}"
    local fn="i18n_get_${lang}"
    local val=""
    if declare -f "$fn" >/dev/null 2>&1; then
        val="$("$fn" "$key" 2>/dev/null)"
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi
    if val="$(i18n_get_pl "$key" 2>/dev/null)" && [[ -n "$val" ]]; then
        echo "$val"
        return 0
    fi
    if val="$(i18n_get_en "$key" 2>/dev/null)" && [[ -n "$val" ]]; then
        echo "$val"
        return 0
    fi
    log_warn "Missing i18n key: ${key}"
    local humanized
    humanized="$(echo "$key" | sed -E 's/^(cli_|mode_|_)?//g' | tr '_' ' ')"
    echo "$humanized"
}

# Cached path size calculation to optimize filesystem du traversal
SIZE_CACHE_KEYS=()
SIZE_CACHE_VALS=()

get_path_size_cached() {
    local path="${1:-}"
    [[ -z "$path" || ! -e "$path" ]] && { echo "0"; return 0; }

    local norm
    norm="$(normalize_path "$path" || echo "$path")"

    local i
    for (( i=0; i<${#SIZE_CACHE_KEYS[@]}; i++ )); do
        if [[ "${SIZE_CACHE_KEYS[i]}" == "$norm" ]]; then
            echo "${SIZE_CACHE_VALS[i]}"
            return 0
        fi
    done

    local bytes
    bytes="$(du -sk "$norm" 2>/dev/null | awk '{print $1 * 1024}')"
    bytes="${bytes:-0}"

    SIZE_CACHE_KEYS+=("$norm")
    SIZE_CACHE_VALS+=("$bytes")

    echo "$bytes"
}

# ---------------------------------------------------------------------------
# Privacy & Security Helpers
# ---------------------------------------------------------------------------

redact_path() {
    local str="$1"
    if [[ "${REDACT_PATHS:-0}" == "1" ]]; then
        if [[ -n "${HOME:-}" ]]; then
            str="${str//$HOME/~}"
        fi
        local user
        user="$(whoami 2>/dev/null || echo "")"
        if [[ -n "$user" ]]; then
            str="${str//\/Users\/$user/~}"
        fi
    fi
    echo "$str"
}

rotate_old_artifacts() {
    local max_days="${1:-30}"
    local logs_dir="${LOGS_DIR:-}"
    local reports_dir="${REPORTS_DIR:-}"

    if [[ -n "$logs_dir" && -d "$logs_dir" ]]; then
        find "$logs_dir" -type f -name "cleanup_*.log" -mtime +"$max_days" -exec rm -f {} + 2>/dev/null || true
    fi

    if [[ -n "$reports_dir" && -d "$reports_dir" ]]; then
        find "$reports_dir" -type f \( -name "report_*.md" -o -name "plan_*.json" -o -name "journal_*.jsonl" \) -mtime +"$max_days" -exec rm -f {} + 2>/dev/null || true
    fi
}

print_header() {
    [[ "${QUIET_OUTPUT:-0}" == "1" ]] && return 0
    echo
    if [[ "${PLAIN_OUTPUT:-0}" == "1" ]]; then
        echo "=========================================================="
        echo "  $*"
        echo "=========================================================="
    else
        echo -e "${C_BOLD}${C_BLUE}══════════════════════════════════════════════════════════${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}  $*${C_RESET}"
        echo -e "${C_BOLD}${C_BLUE}══════════════════════════════════════════════════════════${C_RESET}"
    fi
    echo
}

print_section() {
    [[ "${QUIET_OUTPUT:-0}" == "1" ]] && return 0
    echo
    if [[ "${PLAIN_OUTPUT:-0}" == "1" ]]; then
        echo "-> $*"
        echo "----------------------------------------------------------"
    else
        echo -e "${C_BOLD}${C_CYAN}▶ $*${C_RESET}"
        echo -e "${C_DIM}──────────────────────────────────────────────────────────${C_RESET}"
    fi
}

print_info()    { [[ "${QUIET_OUTPUT:-0}" == "1" ]] || echo -e "  ${C_BLUE}ℹ${C_RESET}  $*"; log_info "$*"; }
print_ok()      { echo -e "  ${C_GREEN}✔${C_RESET}  $*"; log_info "OK: $*"; }
print_warn()    { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; log_warn "$*"; }
print_error()   { echo -e "  ${C_RED}✖${C_RESET}  $*" >&2; log_error "$*"; }
print_skip()    { [[ "${QUIET_OUTPUT:-0}" == "1" ]] || echo -e "  ${C_DIM}↷${C_RESET}  ${C_DIM}$*${C_RESET}"; log_info "SKIP: $*"; }
print_found()   { [[ "${QUIET_OUTPUT:-0}" == "1" ]] || echo -e "  ${C_YELLOW}→${C_RESET}  $*"; log_info "FOUND: $*"; }
print_cleaned() { echo -e "  ${C_GREEN}✓${C_RESET}  $*"; log_info "CLEANED: $*"; }
print_dry()     { [[ "${QUIET_OUTPUT:-0}" == "1" ]] || echo -e "  ${C_CYAN}[DRY]${C_RESET}  $*"; log_info "DRY-RUN: $*"; }

# A prominent warning box used before any destructive confirmation prompt.
print_warning_box() {
    local title="$1"; shift
    echo
    echo -e "${C_YELLOW}${C_BOLD}  ╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_YELLOW}${C_BOLD}  ║  ⚠  WARNING: ${title}${C_RESET}"
    echo -e "${C_YELLOW}${C_BOLD}  ╠══════════════════════════════════════════════════════╣${C_RESET}"
    for line in "$@"; do
        printf "${C_YELLOW}${C_BOLD}  ║  ${C_RESET}%-52s${C_YELLOW}${C_BOLD}  ║${C_RESET}\n" "$line"
    done
    echo -e "${C_YELLOW}${C_BOLD}  ╚══════════════════════════════════════════════════════╝${C_RESET}"
    echo
}

# ---------------------------------------------------------------------------
# Human-readable file sizes
# ---------------------------------------------------------------------------

bytes_to_human() {
    local bytes="${1:-0}"
    # Guard against non-numeric
    case "$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    if   (( bytes < 1024 )); then
        echo "${bytes} B"
    elif (( bytes < 1048576 )); then
        printf "%.1f KB" "$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b / 1024}')"
    elif (( bytes < 1073741824 )); then
        printf "%.1f MB" "$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b / 1048576}')"
    else
        printf "%.2f GB" "$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b / 1073741824}')"
    fi
}

# Return the disk usage of a path in bytes (0 if path doesn't exist).
path_size_bytes() {
    local path="$1"
    if [[ -e "$path" ]]; then
        local kb
        kb=$(du -sk "$path" 2>/dev/null | awk 'NR==1{print $1+0}')
        echo $(( ${kb:-0} * 1024 ))
    else
        echo 0
    fi
}

# Same, but formatted for humans.
path_size_human() {
    local bytes
    bytes=$(path_size_bytes "$1")
    bytes_to_human "$bytes"
}

# ---------------------------------------------------------------------------
# Path safety guard
# ---------------------------------------------------------------------------

# Task 1.7: realpath -m probe removed — use only in-tree normalizer for
# deterministic behavior across macOS bash 3.2 and homebrew bash 5.

# Pre-normalized copy of NEVER_TOUCH_PATHS; populated by
# normalize_never_touch_paths() during preflight_checks.
declare -a _NEVER_TOUCH_NORMALIZED=()

_path_expand_home_and_vars() {
    local p="$1"

    p="${p/#\~/$HOME}"
    p="${p//\$HOME/$HOME}"
    p="${p//\$\{HOME\}/$HOME}"
    p="${p//\$USER/$USER}"
    p="${p//\$\{USER\}/$USER}"

    # Trim quotes used in YAML-style values.
    case "$p" in
        \"*\"|\'*\') p="${p:1:${#p}-2}" ;;
    esac

    echo "$p"
}

# Return path with normalized separators and without symbolic surprises.
#  - expands ~ and $HOME-like vars
#  - converts to absolute path
#  - performs best-effort normalization for non-existent paths
normalize_path() {
    local input="$1"
    local path
    local norm=""
    local top=0 is_abs=0 i seg

    path="$(_path_expand_home_and_vars "$input")"
    path="${path%/}"
    [[ -z "$path" ]] && return 1

    # Collapse consecutive slashes
    while :; do
        local collapsed="${path//\/\//\/}"
        [[ "$collapsed" == "$path" ]] && break
        path="$collapsed"
    done



    # Convert relative input to absolute
    if [[ "$path" != /* ]]; then
        path="$(pwd -P)/$path"
    fi

    # For existing paths: resolve ancestors with cd -P, keep leaf unresolved
    if [[ -e "$path" || -L "$path" ]]; then
        local dir base
        if [[ "$path" == */* ]]; then
            dir="${path%/*}"
            base="${path##*/}"
        else
            dir="."
            base="$path"
        fi
        dir="$(cd -P "$dir" 2>/dev/null && pwd -P)"
        if [[ -n "$base" && "$base" != "." && "$base" != "/" ]]; then
            if [[ "$dir" == "/" ]]; then
                norm="/$base"
            else
                norm="$dir/$base"
            fi
        else
            norm="$dir"
        fi
        echo "$norm"
        return 0
    fi

    # For non-existent paths: segment-based normalization (bash 3.2 compatible)
    [[ "$path" == /* ]] && is_abs=1

    # Split path on '/' without read array construct (bash 3.2 compatible)
    local -a segs=()
    local _oldIFS="${IFS}"
    IFS='/'
    for seg in $path; do
        segs[${#segs[@]}]="$seg"
    done
    IFS="${_oldIFS}"

    local -a out=()
    for seg in "${segs[@]}"; do
        case "$seg" in
            ""|".")
                continue
                ;;
            "..")
                if (( top > 0 )); then
                    top=$(( top - 1 ))
                    unset "out[$top]"
                elif (( is_abs == 0 )); then
                    out[$top]="$seg"
                    top=$(( top + 1 ))
                fi
                ;;
            *)
                out[$top]="$seg"
                top=$(( top + 1 ))
                ;;
        esac
    done

    if (( is_abs == 1 )); then
        norm="/"
    else
        norm=""
    fi
    for (( i = 0; i < top; i++ )); do
        if [[ -z "$norm" || "$norm" == "/" ]]; then
            norm="${norm}${out[$i]}"
        else
            norm="${norm}/${out[$i]}"
        fi
    done

    [[ -z "$norm" ]] && norm="."
    echo "$norm"
}

# Returns 0 (true) if the given path matches any entry in NEVER_TOUCH_PATHS.
is_protected_path() {
    local candidate="$1"
    local normalized_candidate

    normalized_candidate="$(normalize_path "$candidate" || echo "$candidate")"

    # Fail closed for broad roots. Cleaners should pass leaf candidates, never
    # whole user/system roots.
    case "$normalized_candidate" in
        /|/bin|/bin/*|/sbin|/sbin/*|/usr|/usr/*|/etc|/etc/*|/private/etc|/private/etc/*|/Applications|/Applications/*|/opt|/opt/*)
            return 0 ;;
        /tmp|/private/tmp|/private|/private/var|/private/var/folders|/var|/var/folders)
            return 0 ;;
        "$HOME"|"$HOME/Library"|"$HOME/Library/Caches"|"$HOME/.Trash"|"$HOME/Library/Application Support")
            return 0 ;;
        "$HOME/Library/Preferences"|"$HOME/Library/Preferences/"*)
            return 0 ;;
        "$HOME/Library/Containers"|"$HOME/Library/Containers/"*)
            return 0 ;;
        "$HOME/Library/Group Containers"|"$HOME/Library/Group Containers/"*)
            return 0 ;;
        "$HOME/Library/Saved Application State"|"$HOME/Library/Saved Application State/"*)
            return 0 ;;
    esac

    # /System/* and other users are never touched.
    # /Library is protected by default, with targeted cache/log leaf cleanup.
    if [[ "$normalized_candidate" == "/System" || "$normalized_candidate" == "/System/"* || \
          "$normalized_candidate" == "/private/var/System"* || "$normalized_candidate" == "/var/System"* ]]; then
        return 0
    fi
    if [[ "$normalized_candidate" == "/Users" || "$normalized_candidate" == "/Users/"* ]]; then
        if [[ "$normalized_candidate" != "$HOME/"* ]]; then
            return 0
        fi
    fi
    if [[ "$normalized_candidate" == "/Library" || "$normalized_candidate" == "/Library/"* ]]; then
        case "$normalized_candidate" in
            /Library/Caches/*|/Library/Logs/*)
                :
                ;;
            *)
                return 0
                ;;
        esac
    fi

    # PF3: use pre-normalized array when available (after preflight);
    # fall back to per-call normalization for callers that skip preflight.
    if (( ${#_NEVER_TOUCH_NORMALIZED[@]} > 0 )); then
        local normalized_protected
        for normalized_protected in "${_NEVER_TOUCH_NORMALIZED[@]}"; do
            if [[ "$normalized_candidate" == "$normalized_protected" || \
                  "$normalized_candidate" == "$normalized_protected"/* || \
                  "$normalized_protected" == "$normalized_candidate"/* ]]; then
                return 0  # protected
            fi
        done
    elif (( ${#NEVER_TOUCH_PATHS[@]} > 0 )); then
        for protected in "${NEVER_TOUCH_PATHS[@]}"; do
            local normalized_protected
            normalized_protected="$(normalize_path "$protected" || echo "$protected")"
            if [[ "$normalized_candidate" == "$normalized_protected" || \
                  "$normalized_candidate" == "$normalized_protected"/* || \
                  "$normalized_protected" == "$normalized_candidate"/* ]]; then
                return 0  # protected
            fi
        done
    fi
    return 1  # not protected
}

path_contains_protected_descendant() {
    local candidate="$1"
    local normalized_candidate

    normalized_candidate="$(normalize_path "$candidate" || echo "$candidate")"
    [[ -z "$normalized_candidate" ]] && return 1

    # PF3: use pre-normalized array when available; fallback to per-call.
    if (( ${#_NEVER_TOUCH_NORMALIZED[@]} > 0 )); then
        local normalized_protected
        for normalized_protected in "${_NEVER_TOUCH_NORMALIZED[@]}"; do
            if [[ "$normalized_protected" == "$normalized_candidate/"* ]]; then
                return 0
            fi
        done
    elif (( ${#NEVER_TOUCH_PATHS[@]} > 0 )); then
        local protected normalized_protected
        for protected in "${NEVER_TOUCH_PATHS[@]}"; do
            normalized_protected="$(normalize_path "$protected" || echo "$protected")"
            if [[ "$normalized_protected" == "$normalized_candidate/"* ]]; then
                return 0
            fi
        done
    fi

    return 1
}

add_never_touch_path() {
    local path="$1"
    local normalized
    normalized="$(normalize_path "$path" || echo "$path")"
    [[ -z "$normalized" ]] && return 0

    local existing
    if (( ${#NEVER_TOUCH_PATHS[@]} > 0 )); then
        for existing in "${NEVER_TOUCH_PATHS[@]}"; do
            [[ "$existing" == "$normalized" ]] && return 0
        done
    fi

    NEVER_TOUCH_PATHS+=("$normalized")
}

# ---------------------------------------------------------------------------
# Claimed path registry — prevents double-counting across categories
# ---------------------------------------------------------------------------
_CLAIMED_PATHS=()
_CLAIMED_BYTES=()

claim_path() {
    local target="$1"
    local bytes="${2:-0}"
    local norm
    norm="$(normalize_path "$target" 2>/dev/null || echo "$target")"
    [[ -z "$norm" ]] && return 1

    if is_path_claimed "$norm"; then
        return 1
    fi

    _CLAIMED_PATHS+=("$norm")
    _CLAIMED_BYTES+=("$bytes")
    return 0
}

is_path_claimed() {
    local target="$1"
    local norm
    norm="$(normalize_path "$target" 2>/dev/null || echo "$target")"
    [[ -z "$norm" ]] && return 1

    if (( ${#_CLAIMED_PATHS[@]} == 0 )); then
        return 1
    fi

    local p
    for p in "${_CLAIMED_PATHS[@]}"; do
        if [[ "$p" == "$norm" || "$norm" == "$p"/* ]]; then
            return 0
        fi
    done
    return 1
}

reset_claimed_paths() {
    _CLAIMED_PATHS=()
    _CLAIMED_BYTES=()
}

add_informational_bytes() {
    local bytes="${1:-0}"
    case "$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    TOTAL_INFORMATIONAL_BYTES=$(( TOTAL_INFORMATIONAL_BYTES + bytes ))
}

# Parse cleanup_rules.yaml and append all paths with safety: never.
load_never_paths_from_rules() {
    local rules_file="${RULES_FILE:-}"
    [[ -z "$rules_file" ]] && return 0
    [[ -f "$rules_file" ]] || { log_warn "Rules file not found: ${rules_file}"; return 0; }

    local line
    local candidate_path=""
    local value
    local safety

    while IFS= read -r line; do
        # Strip inline comments for simple parser.
        line="${line%%#*}"
        # Trim spaces.
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        if [[ "$line" == "- path:"* ]]; then
            value="${line#- path:}"
            value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            if [[ "${value:0:1}" == "\"" || "${value:0:1}" == "'" ]]; then
                value="${value:1}"
                value="${value%\"}"
                value="${value%\'}"
            fi
            candidate_path="$value"
            continue
        fi

        if [[ "$line" == "path:"* ]]; then
            value="${line#path:}"
            value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            if [[ "${value:0:1}" == "\"" || "${value:0:1}" == "'" ]]; then
                value="${value:1}"
                value="${value%\"}"
                value="${value%\'}"
            fi
            candidate_path="$value"
            continue
        fi

        if [[ "$line" == "safety:"* ]] && [[ -n "$candidate_path" ]]; then
            safety="${line#safety:}"
            safety="$(printf '%s' "$safety" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            safety="${safety%\"}"
            safety="${safety#\"}"
            safety="${safety%\'}"
            safety="${safety#\'}"
            safety="$(printf '%s' "$safety" | tr '[:upper:]' '[:lower:]')"
            if [[ "$safety" == "never" ]]; then
                add_never_touch_path "$candidate_path"
            fi
            candidate_path=""
            continue
        fi

        if [[ "$line" == "-"* ]]; then
            candidate_path=""
            continue
        fi
    done < "$rules_file"
}

dedupe_never_touch_paths() {
    local -a dedup=()
    local p i
    (( ${#NEVER_TOUCH_PATHS[@]} == 0 )) && return 0
    for p in "${NEVER_TOUCH_PATHS[@]}"; do
        local normalized
        normalized="$(normalize_path "$p" || echo "$p")"
        local found=0
        if (( ${#dedup[@]} > 0 )); then
            for i in "${dedup[@]}"; do
                [[ "$i" == "$normalized" ]] && { found=1; break; }
            done
        fi
        (( found == 0 )) && dedup+=("$normalized")
    done
    NEVER_TOUCH_PATHS=("${dedup[@]}")
}

normalize_never_touch_paths() {
    dedupe_never_touch_paths
    # PF3: build pre-normalized copy for is_protected_path hot path
    _NEVER_TOUCH_NORMALIZED=()
    local p norm
    for p in "${NEVER_TOUCH_PATHS[@]}"; do
        norm="$(normalize_path "$p" || echo "$p")"
        _NEVER_TOUCH_NORMALIZED+=("$norm")
    done
}

# Block and journal (but do NOT abort) if a protected path is about to be touched.
# Returns 0 if path is safe to proceed, 1 if blocked.
assert_safe_path() {
    local path="$1"
    if is_protected_path "$path"; then
        print_error "SAFETY VIOLATION: attempted to touch protected path: ${path}"
        log_error "SAFETY VIOLATION: protected path blocked: ${path}"
        record_skipped_item "SAFETY VIOLATION (protected): ${path}"
        cleanup_journal_event "safety_violation" "$path" "" "0" "blocked" "protected path"
        return 1
    fi
    if path_contains_protected_descendant "$path"; then
        print_error "SAFETY VIOLATION: attempted to remove parent of protected path: ${path}"
        log_error "SAFETY VIOLATION: parent of protected path blocked: ${path}"
        record_skipped_item "SAFETY VIOLATION (parent of protected): ${path}"
        cleanup_journal_event "safety_violation" "$path" "" "0" "blocked" "parent of protected path"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# File age helpers
# ---------------------------------------------------------------------------

file_older_than_days() {
    local file="$1"
    local days="$2"
    if [[ ! -e "$file" ]]; then return 1; fi
    local mtime now diff_days
    mtime=$(stat -f "%m" "$file" 2>/dev/null) || return 1
    now=$(date +%s)
    diff_days=$(( (now - mtime) / 86400 ))
    (( diff_days > days ))
}

file_older_than_hours() {
    local file="$1"
    local hours="$2"
    if [[ ! -e "$file" ]]; then return 1; fi
    local mtime now diff_hours
    mtime=$(stat -f "%m" "$file" 2>/dev/null) || return 1
    now=$(date +%s)
    diff_hours=$(( (now - mtime) / 3600 ))
    (( diff_hours > hours ))
}

# ---------------------------------------------------------------------------
# Application presence helpers
# ---------------------------------------------------------------------------

APP_BUNDLE_ID_CACHE_LOADED=0
APP_BUNDLE_ID_CACHE=""
APP_BUNDLE_SEARCH_DIRS=("/Applications" "$HOME/Applications" "/System/Applications")

_load_app_bundle_id_cache() {
    APP_BUNDLE_ID_CACHE_LOADED=1
    APP_BUNDLE_ID_CACHE=""

    local dirs=("${APP_BUNDLE_SEARCH_DIRS[@]}")

    # PF4: Use fast Python-based plist parser if python3 is available
    if command -v python3 >/dev/null 2>&1; then
        local py_code
        py_code=$(cat <<'EOF'
import os, plistlib, sys
dirs = sys.argv[1:]
for d in dirs:
    if not os.path.isdir(d):
        continue
    for root, subdirs, files in os.walk(d, followlinks=True):
        depth = root.count(os.sep) - d.count(os.sep)
        if "Info.plist" in files:
            plist_path = os.path.join(root, "Info.plist")
            try:
                with open(plist_path, "rb") as f:
                    plist = plistlib.load(f)
                    bid = plist.get("CFBundleIdentifier")
                    if bid:
                        sys.stdout.write(bid + "\n")
            except Exception:
                pass
            del subdirs[:]
        elif depth >= 3:
            del subdirs[:]
EOF
        )
        APP_BUNDLE_ID_CACHE="$(python3 -c "$py_code" "${dirs[@]}" 2>/dev/null)"
        return
    fi

    # Fallback to defaults read loop if python3 is not available
    local dir
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' plist; do
            local bundle_id
            bundle_id="$(defaults read "$plist" CFBundleIdentifier 2>/dev/null || true)"
            [[ -n "$bundle_id" ]] && APP_BUNDLE_ID_CACHE="${APP_BUNDLE_ID_CACHE}${bundle_id}"$'\n'
        done < <(find -L "$dir" -maxdepth 3 -name "Info.plist" -print0 2>/dev/null)
    done
}

app_bundle_exists() {
    local bundle_id="$1"

    # Attempt to use mdfind first
    if command -v mdfind >/dev/null 2>&1; then
        local found
        if found="$(mdfind "kMDItemCFBundleIdentifier == \"$bundle_id\"" 2>/dev/null)" && [[ -n "$found" ]]; then
            return 0
        fi
    fi

    if (( APP_BUNDLE_ID_CACHE_LOADED == 0 )); then
        _load_app_bundle_id_cache
    fi
    printf '%s' "$APP_BUNDLE_ID_CACHE" | grep -Fxq "$bundle_id"
}

app_name_exists() {
    local name="$1"
    [[ -d "/Applications/${name}.app" ]] || \
    [[ -d "$HOME/Applications/${name}.app" ]] || \
    find /Applications "$HOME/Applications" -maxdepth 1 -iname "*${name}*" -name "*.app" \
        2>/dev/null | grep -q .
}

# ---------------------------------------------------------------------------
# Sudo helpers — DISABLED (P0-1b: privileged deletion removed)
#
# These stubs exist so that callers don't need code changes, but they
# unconditionally refuse sudo. Any code path that depended on sudo
# should now use report_only instead.
# ---------------------------------------------------------------------------

request_sudo() {
    log_info "request_sudo called but privileged operations are disabled (P0-1b)."
    return 1
}

_start_sudo_keepalive() { :; }

cleanup_sudo_keepalive() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

fresh_time_machine_backup_available() {
    local max_age_days="${1:-$BACKUP_MAX_AGE_DAYS}"
    command -v tmutil >/dev/null 2>&1 || return 1

    local latest=""
    latest="$(tmutil latestbackup 2>/dev/null || true)"
    [[ -n "$latest" && -e "$latest" ]] || return 1

    local mtime now max_age_seconds
    mtime="$(stat -f "%m" "$latest" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    max_age_seconds=$(( max_age_days * 86400 ))
    (( mtime > 0 && now - mtime <= max_age_seconds ))
}

warn_if_no_fresh_backup() {
    local context="${1:-cleanup}"

    if fresh_time_machine_backup_available "$BACKUP_MAX_AGE_DAYS"; then
        cleanup_journal_event "backup_check" "" "" 0 "ok" "fresh Time Machine backup available for ${context}" "safety"
        return 0
    fi

    print_warning_box "No confirmed fresh backup" \
        "Could not verify Time Machine backup" \
        "from the last ${BACKUP_MAX_AGE_DAYS} days." \
        "" \
        "Context: ${context}" \
        "" \
        "Proceeding only under guardrails; REVIEW/DANGEROUS" \
        "are not executed automatically."
    WARNINGS_LIST+=("No fresh Time Machine backup confirmed before: ${context}")
    cleanup_journal_event "backup_check" "" "" 0 "warning" "fresh Time Machine backup missing for ${context}" "safety"
    return 1
}

# ---------------------------------------------------------------------------
# Journal, quarantine, and restore helpers
# ---------------------------------------------------------------------------

json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

cleanup_journal_event() {
    local action="${1:-unknown}"
    local path="${2:-}"
    local quarantine_path="${3:-}"
    local bytes="${4:-0}"
    local status="${5:-ok}"
    local message="${6:-}"
    local category="${7:-}"
    local journal_file="${CLEANUP_JOURNAL_FILE:-}"
    local run_id="${RUN_TIMESTAMP:-unknown}"
    local ts

    [[ -n "$journal_file" ]] || return 0
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    mkdir -p "$(dirname "$journal_file")" 2>/dev/null || true
    printf '{"ts":"%s","run_id":"%s","action":"%s","category":"%s","path":"%s","quarantine_path":"%s","bytes":%s,"status":"%s","message":"%s"}\n' \
        "$(json_escape "$ts")" \
        "$(json_escape "$run_id")" \
        "$(json_escape "$action")" \
        "$(json_escape "$category")" \
        "$(json_escape "$path")" \
        "$(json_escape "$quarantine_path")" \
        "$bytes" \
        "$(json_escape "$status")" \
        "$(json_escape "$message")" \
	        >> "$journal_file" 2>/dev/null || true
}

record_native_command_event() {
    local command="$1"
    local status="${2:-ok}"
    local bytes="${3:-0}"
    local message="${4:-}"

    cleanup_journal_event "native_command" "$command" "" "$bytes" "$status" "$message"
}

base64_encode_string() {
    printf '%s' "${1:-}" | base64 | tr -d '\n'
}

base64_decode_string() {
    local encoded="${1:-}"
    if printf '%s' "$encoded" | base64 -D 2>/dev/null; then
        return 0
    fi
    printf '%s' "$encoded" | base64 -d 2>/dev/null
}

cleanup_restore_record() {
    local quarantine_path="$1"
    local original_path="$2"
    local bytes="${3:-0}"
    local manifest="${CLEANUP_RESTORE_MANIFEST:-}"

    [[ -n "$manifest" ]] || return 0
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac

    mkdir -p "$(dirname "$manifest")" 2>/dev/null || true
    printf '%s\t%s\t%s\n' \
        "$(base64_encode_string "$quarantine_path")" \
        "$(base64_encode_string "$original_path")" \
        "$bytes" >> "$manifest" 2>/dev/null || true
}

path_is_within() {
    local candidate="$1"
    local root="$2"
    local normalized_candidate normalized_root

    normalized_candidate="$(normalize_path "$candidate" || echo "$candidate")"
    normalized_root="$(normalize_path "$root" || echo "$root")"
    [[ -z "$normalized_candidate" || -z "$normalized_root" ]] && return 1

    [[ "$normalized_candidate" == "$normalized_root" || "$normalized_candidate" == "$normalized_root/"* ]]
}

is_quarantine_path() {
    [[ -n "${QUARANTINE_ROOT:-}" ]] || return 1
    path_is_within "$1" "$QUARANTINE_ROOT"
}

is_trash_child_path() {
    local normalized home_norm
    normalized="$(normalize_path "$1" || echo "$1")"
    home_norm="$(normalize_path "$HOME" || echo "$HOME")"
    [[ "$normalized" == "$home_norm/.Trash/"* ]]
}

is_user_space_path() {
    local normalized home_norm
    normalized="$(normalize_path "$1" || echo "$1")"
    home_norm="$(normalize_path "$HOME" || echo "$HOME")"
    [[ "$normalized" == "$home_norm/"* ]]
}

path_has_symlink_ancestor_under_home() {
    local target="$1"
    local normalized parent home_norm rel current part
    local -a parts

    normalized="$(normalize_path "$target" || echo "$target")"
    home_norm="$(normalize_path "$HOME" || echo "$HOME")"

    [[ "$normalized" == "$home_norm/"* ]] || return 1

    parent="$(dirname "$normalized")"
    [[ "$parent" == "$home_norm" ]] && return 1

    rel="${parent#"$home_norm"/}"
    current="$home_norm"
    local -a parts=()
    local _oldIFS="${IFS}"
    IFS='/'
    for part in $rel; do
        parts[${#parts[@]}]="$part"
    done
    IFS="${_oldIFS}"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        current="${current}/${part}"
        if [[ -L "$current" ]]; then
            return 0
        fi
    done

    return 1
}

quarantine_destination_for() {
    local target="$1"
    local normalized rel dest base i

    [[ -n "${QUARANTINE_RUN_DIR:-}" ]] || return 1
    normalized="$(normalize_path "$target" || echo "$target")"
    rel="${normalized#/}"
    dest="${QUARANTINE_RUN_DIR}/items/${rel}"

    if [[ -e "$dest" || -L "$dest" ]]; then
        base="$dest"
        i=1
        while [[ -e "${base}.${i}" || -L "${base}.${i}" ]]; do
            i=$(( i + 1 ))
        done
        dest="${base}.${i}"
    fi

    echo "$dest"
}

quarantine_remove() {
    local target="$1"
    local size="${2:-0}"
    local dest

    dest="$(quarantine_destination_for "$target" 2>/dev/null || true)"
    if [[ -z "$dest" ]]; then
        print_warn "Quarantine is not configured; skipping: ${target}"
        record_skipped_item "Quarantine is not configured: ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "" "$size" "failed" "quarantine not configured"
        return 1
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || {
        print_warn "Could not create quarantine directory for: ${target}"
        record_skipped_item "Cannot create quarantine directory for ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "mkdir failed"
        return 1
    }

    print_cleaned "Quarantining: ${target} -> ${dest}  ($(bytes_to_human "$size"))"
    if mv "$target" "$dest" 2>/dev/null; then
        TOTAL_QUARANTINED_BYTES=$(( TOTAL_QUARANTINED_BYTES + size ))
        TOTAL_QUARANTINED_ITEMS=$(( TOTAL_QUARANTINED_ITEMS + 1 ))
        cleanup_restore_record "$dest" "$target" "$size"
        cleanup_journal_event "quarantined" "$target" "$dest" "$size" "ok" ""
        return 0
    fi

    print_warn "Could not quarantine: ${target}"
    log_warn "mv to quarantine failed for: ${target}"
    record_skipped_item "Failed to move to quarantine: ${target}"
    cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "mv failed"
    return 1
}

direct_remove() {
    local target="$1"
    local size="${2:-0}"
    local sudo_required="${3:-0}"
    local action="${4:-deleted}"

    # P0-1b: privileged deletion is disabled
    if [[ "$sudo_required" == "1" ]]; then
        print_warn "Privileged deletion disabled (P0-1b): ${target}"
        record_skipped_item "Privileged deletion refused: ${target}"
        cleanup_journal_event "${action}_blocked" "$target" "" "$size" "blocked" "sudo disabled (P0-1b)"
        return 1
    fi

    print_cleaned "Removing: ${target}  ($(bytes_to_human "$size"))"
    if rm -rf "$target" 2>/dev/null; then
        TOTAL_CLEANED_BYTES=$(( TOTAL_CLEANED_BYTES + size ))
        cleanup_journal_event "$action" "$target" "" "$size" "ok" ""
        return 0
    fi

    print_warn "Could not remove: ${target}"
    log_warn "rm failed for: ${target}"
    record_skipped_item "Failed to remove: ${target}"
    cleanup_journal_event "${action}_failed" "$target" "" "$size" "failed" "rm failed"
    return 1
}

resolve_restore_manifest() {
    local requested="${1:-}"
    local candidate

    [[ -z "$requested" ]] && return 1

    if [[ "$requested" == "latest" ]]; then
        # shellcheck disable=SC2012
        candidate="$(ls -t "${REPORTS_DIR}"/restore_*.tsv 2>/dev/null | head -1 || true)"
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            normalize_path "$candidate" || echo "$candidate"
            return 0
        fi
        return 1
    fi

    if [[ -f "$requested" ]]; then
        normalize_path "$requested" || echo "$requested"
        return 0
    fi

    candidate="${REPORTS_DIR}/restore_${requested}.tsv"
    if [[ -f "$candidate" ]]; then
        normalize_path "$candidate" || echo "$candidate"
        return 0
    fi

    candidate="${REPORTS_DIR}/${requested}"
    if [[ -f "$candidate" ]]; then
        normalize_path "$candidate" || echo "$candidate"
        return 0
    fi

    return 1
}

restore_quarantine_manifest() {
    local requested="$1"
    local manifest

    manifest="$(resolve_restore_manifest "$requested" 2>/dev/null || true)"
    if [[ -z "$manifest" ]]; then
        print_error "Restore manifest not found: ${requested}"
        return 2
    fi

    print_info "Restoring quarantine from manifest: ${manifest}"

    local q_b64 p_b64 bytes source_path target_path source_norm target_norm
    local quarantine_root_norm actual_size
    quarantine_root_norm="$(normalize_path "$QUARANTINE_ROOT" || echo "$QUARANTINE_ROOT")"

    while IFS=$'\t' read -r q_b64 p_b64 bytes || [[ -n "${q_b64:-}${p_b64:-}${bytes:-}" ]]; do
        [[ -z "${q_b64:-}" || -z "${p_b64:-}" ]] && continue

        source_path="$(base64_decode_string "$q_b64" || true)"
        target_path="$(base64_decode_string "$p_b64" || true)"
        [[ -z "$source_path" || -z "$target_path" ]] && {
            record_skipped_item "Invalid restore record in ${manifest}"
            continue
        }

        source_norm="$(normalize_path "$source_path" || echo "$source_path")"
        target_norm="$(normalize_path "$target_path" || echo "$target_path")"
        case "${bytes:-0}" in ''|*[!0-9]*) bytes=0 ;; esac

        case "$source_norm" in
            "$quarantine_root_norm"/*/items/*)
                :
                ;;
            *)
                print_warn "Skipping source outside quarantine items directory: ${source_norm}"
                record_skipped_item "Restore source outside quarantine items: ${source_norm}"
                cleanup_journal_event "restore_blocked" "$target_norm" "$source_norm" "$bytes" "blocked" "source outside quarantine items"
                continue
                ;;
        esac

        if [[ "$source_norm" == "$quarantine_root_norm" ]]; then
            print_warn "Skipping dangerous restore source: ${source_norm}"
            record_skipped_item "Dangerous restore source: ${source_norm}"
            cleanup_journal_event "restore_blocked" "$target_norm" "$source_norm" "$bytes" "blocked" "source is quarantine root"
            continue
        fi

        if ! path_is_within "$source_norm" "$QUARANTINE_ROOT"; then
            print_warn "Skipping source outside quarantine: ${source_norm}"
            record_skipped_item "Restore source outside quarantine: ${source_norm}"
            cleanup_journal_event "restore_blocked" "$target_norm" "$source_norm" "$bytes" "blocked" "source outside quarantine"
            continue
        fi

        if is_protected_path "$target_norm" || path_contains_protected_descendant "$target_norm"; then
            print_warn "Skipping restore to protected path: ${target_norm}"
            record_skipped_item "Restore to protected path: ${target_norm}"
            cleanup_journal_event "restore_blocked" "$target_norm" "$source_norm" "$bytes" "blocked" "target protected"
            continue
        fi

        if ! is_user_space_path "$target_norm"; then
            print_warn "Skipping restore outside user directory: ${target_norm}"
            record_skipped_item "Restore outside HOME: ${target_norm}"
            cleanup_journal_event "restore_blocked" "$target_norm" "$source_norm" "$bytes" "blocked" "target outside user scope"
            continue
        fi

        if [[ ! -e "$source_norm" && ! -L "$source_norm" ]]; then
            print_warn "Quarantine file does not exist: ${source_norm}"
            record_skipped_item "Quarantine file does not exist: ${source_norm}"
            cleanup_journal_event "restore_missing" "$target_norm" "$source_norm" "$bytes" "missing" "source missing"
            continue
        fi

        if [[ -e "$target_norm" || -L "$target_norm" ]]; then
            print_warn "Target path already exists, skipping: ${target_norm}"
            record_skipped_item "Restore conflict: ${target_norm}"
            cleanup_journal_event "restore_conflict" "$target_norm" "$source_norm" "$bytes" "conflict" "target exists"
            continue
        fi

        if path_has_symlink_ancestor_under_home "$target_norm"; then
            print_warn "Skipping restore through symlinked parent directory: ${target_norm}"
            record_skipped_item "Restore through symlinked parent directory: ${target_norm}"
            cleanup_journal_event "restore_blocked" "$target_norm" "$source_norm" "$bytes" "blocked" "target has symlink ancestor"
            continue
        fi

        if ! mkdir -p "$(dirname "$target_norm")" 2>/dev/null; then
            print_warn "Cannot create target directory: $(dirname "$target_norm")"
            record_skipped_item "Cannot create directory for restore: ${target_norm}"
            cleanup_journal_event "restore_failed" "$target_norm" "$source_norm" "$bytes" "failed" "mkdir failed"
            continue
        fi

        actual_size="$(path_size_bytes "$source_norm")"
        if mv "$source_norm" "$target_norm" 2>/dev/null; then
            TOTAL_RESTORED_BYTES=$(( TOTAL_RESTORED_BYTES + actual_size ))
            TOTAL_RESTORED_ITEMS=$(( TOTAL_RESTORED_ITEMS + 1 ))
            print_cleaned "Restored: ${target_norm}  ($(bytes_to_human "$actual_size"))"
            cleanup_journal_event "restored" "$target_norm" "$source_norm" "$actual_size" "ok" ""
        else
            print_warn "Failed to restore: ${target_norm}"
            record_skipped_item "Failed to restore: ${target_norm}"
            cleanup_journal_event "restore_failed" "$target_norm" "$source_norm" "$bytes" "failed" "mv failed"
        fi
    done < "$manifest"
}

latest_quarantine_run_dir() {
    local latest
    # shellcheck disable=SC2012
    latest="$(ls -td "${QUARANTINE_ROOT}"/* 2>/dev/null | head -1 || true)"
    [[ -n "$latest" && -d "$latest" ]] || return 1
    normalize_path "$latest" || echo "$latest"
}

is_quarantine_run_dir() {
    local candidate="$1"
    local normalized root_norm parent

    normalized="$(normalize_path "$candidate" || echo "$candidate")"
    root_norm="$(normalize_path "$QUARANTINE_ROOT" || echo "$QUARANTINE_ROOT")"
    parent="$(dirname "$normalized")"

    [[ -d "$normalized" && "$parent" == "$root_norm" && "$normalized" != "$root_norm" ]]
}

resolve_quarantine_run_dir() {
    local requested="${1:-}"
    local candidate

    [[ -z "$requested" ]] && return 1

    if [[ "$requested" == "latest" ]]; then
        latest_quarantine_run_dir
        return
    fi

    if [[ -d "$requested" ]]; then
        candidate="$(normalize_path "$requested" || echo "$requested")"
    else
        candidate="${QUARANTINE_ROOT}/${requested}"
        candidate="$(normalize_path "$candidate" || echo "$candidate")"
    fi

    if is_quarantine_run_dir "$candidate"; then
        echo "$candidate"
        return 0
    fi

    return 1
}

list_quarantine_runs() {
    local count=0
    local dir size

    print_info "Quarantine: ${QUARANTINE_ROOT}"

    if [[ ! -d "$QUARANTINE_ROOT" ]]; then
        print_skip "Quarantine directory does not exist."
        return 0
    fi

    for dir in "${QUARANTINE_ROOT}"/*; do
        [[ -d "$dir" ]] || continue
        count=$(( count + 1 ))
        size="$(path_size_bytes "$dir")"
        print_found "$(basename "$dir")  $(bytes_to_human "$size")  ${dir}"
    done

    if (( count == 0 )); then
        print_skip "No saved quarantine runs."
    fi
}

purge_one_quarantine_run() {
    local run_dir="$1"
    local apply="${2:-0}"
    local normalized size

    normalized="$(normalize_path "$run_dir" || echo "$run_dir")"
    if ! is_quarantine_run_dir "$normalized"; then
        print_warn "Skipping invalid quarantine directory: ${run_dir}"
        record_skipped_item "Invalid quarantine purge: ${run_dir}"
        cleanup_journal_event "purge_blocked" "$normalized" "" 0 "blocked" "not an immediate quarantine run directory"
        return 1
    fi

    size="$(path_size_bytes "$normalized")"
    if [[ "$apply" != "1" ]]; then
        print_dry "Would purge quarantine run: ${normalized}  ($(bytes_to_human "$size"))"
        TOTAL_WOULD_FREE_BYTES=$(( TOTAL_WOULD_FREE_BYTES + size ))
        cleanup_journal_event "purge_quarantine_planned" "$normalized" "" "$size" "planned" "requires --apply"
        return 0
    fi

    direct_remove "$normalized" "$size" 0 "purged_quarantine"
}

purge_quarantine() {
    local requested="${1:-}"
    local apply="${2:-0}"
    local retention_days="${3:-$QUARANTINE_RETENTION_DAYS}"
    local run_dir failures=0

    if [[ -z "$requested" ]]; then
        print_error "Missing quarantine purge selector."
        return 2
    fi

    if [[ "$requested" == "all" ]]; then
        if [[ ! -d "$QUARANTINE_ROOT" ]]; then
            print_skip "Quarantine directory does not exist."
            return 0
        fi
        for run_dir in "${QUARANTINE_ROOT}"/*; do
            [[ -d "$run_dir" ]] || continue
            purge_one_quarantine_run "$run_dir" "$apply" || failures=$(( failures + 1 ))
        done
        return "$failures"
    fi

    if [[ "$requested" == "expired" ]]; then
        if [[ ! -d "$QUARANTINE_ROOT" ]]; then
            print_skip "Quarantine directory does not exist."
            return 0
        fi
        for run_dir in "${QUARANTINE_ROOT}"/*; do
            [[ -d "$run_dir" ]] || continue
            if file_older_than_days "$run_dir" "$retention_days"; then
                purge_one_quarantine_run "$run_dir" "$apply" || failures=$(( failures + 1 ))
            fi
        done
        return "$failures"
    fi

    run_dir="$(resolve_quarantine_run_dir "$requested" 2>/dev/null || true)"
    if [[ -z "$run_dir" ]]; then
        print_error "Quarantine run not found: ${requested}"
        return 2
    fi

    purge_one_quarantine_run "$run_dir" "$apply"
}

# ---------------------------------------------------------------------------
# Safe removal helper — the only function that actually deletes files
# ---------------------------------------------------------------------------

safe_remove() {
    local target="$1"
    local dry="${DRY_RUN:-0}"
    local normalized_target

    normalized_target="$(normalize_path "$target")" || normalized_target=""
    if [[ -z "$normalized_target" ]]; then
        print_error "safe_remove: path normalization failed for: ${target}"
        log_error "safe_remove: normalize_path returned empty for: ${target}"
        record_skipped_item "Normalization failed (fail-closed): ${target}"
        cleanup_journal_event "normalization_failed" "$target" "" "0" "blocked" "fail-closed (P1-11)"
        return 1
    fi

    if is_quarantine_path "$normalized_target"; then
        print_skip "Skipping cleanup quarantine path: ${normalized_target}"
        record_skipped_item "Quarantine cleanup is protected from recursive cleaning: ${normalized_target}"
        cleanup_journal_event "skipped_quarantine" "$normalized_target" "" 0 "skipped" "target is cleanup quarantine"
        return 0
    fi

    assert_safe_path "$normalized_target" || return 1

    if [[ ! -e "$normalized_target" && ! -L "$normalized_target" ]]; then
        log_debug "safe_remove: path does not exist, skipping: ${normalized_target}"
        return 0
    fi

    local size
    size=$(path_size_bytes "$normalized_target")

    if [[ "$dry" == "1" ]]; then
        print_dry "Would remove: ${normalized_target}  ($(bytes_to_human "$size"))"
        TOTAL_WOULD_FREE_BYTES=$(( TOTAL_WOULD_FREE_BYTES + size ))
        cleanup_journal_event "would_remove" "$normalized_target" "" "$size" "planned" ""
    else
        if [[ "${REMOVE_MODE:-permanent}" == "quarantine" ]]; then
            if is_user_space_path "$normalized_target"; then
                quarantine_remove "$normalized_target" "$size"
                return
            fi

            print_skip "Skipping non-user path in quarantine mode: ${normalized_target}"
            record_skipped_item "Quarantine mode does not remove system/non-HOME paths: ${normalized_target}"
            cleanup_journal_event "skipped_non_user_scope" "$normalized_target" "" "$size" "skipped" "quarantine mode only supports user-scope paths"
            return
        fi

        if is_user_space_path "$normalized_target"; then
            direct_remove "$normalized_target" "$size" 0 "deleted"
            return
        fi

        if [[ "$normalized_target" == /private/tmp/* || "$normalized_target" == /private/var/folders/* ]]; then
            direct_remove "$normalized_target" "$size" 0 "deleted"
            return
        fi

        if [[ "$normalized_target" == /Library/* || "$normalized_target" == /System/* || "$normalized_target" == /private/* ]]; then
            direct_remove "$normalized_target" "$size" 1 "deleted"
            return
        fi

        direct_remove "$normalized_target" "$size" 0 "deleted"
    fi
}

# ---------------------------------------------------------------------------
# Bash 3.2-compatible category bytes storage
# macOS ships with bash 3.2; declare -A requires bash 4.0+.
# We use eval-based named variables: _CATBYTES_<key> (hyphens → underscores).
# ---------------------------------------------------------------------------

# catbytes_set "key" bytes_value
catbytes_set() {
    local raw_key="${1//\"/}"
    raw_key="${raw_key//\'/}"
    raw_key="${raw_key//-/_}"
    case "$raw_key" in ''|*[!A-Za-z0-9_]* ) return 1 ;; esac
    case "${2:-0}" in ''|*[!0-9]* ) return 1 ;; esac
    eval "_CATBYTES_${raw_key}=\$2"
}

# catbytes_get "key"  →  prints current value (0 if unset)
# Bash 3.2 compatible: uses eval instead of ${!varname:-0}
catbytes_get() {
    local raw_key="${1//\"/}"
    raw_key="${raw_key//\'/}"
    raw_key="${raw_key//-/_}"
    case "$raw_key" in ''|*[!A-Za-z0-9_]* ) echo 0; return 1 ;; esac
    local varname="_CATBYTES_${raw_key}"
    local val
    eval "val=\"\${${varname}:-0}\""
    echo "$val"
}

# catbytes_add "key" bytes_to_add
catbytes_add() {
    local raw_key="${1//\"/}"
    raw_key="${raw_key//\'/}"
    raw_key="${raw_key//-/_}"
    case "$raw_key" in ''|*[!A-Za-z0-9_]* ) return 1 ;; esac
    case "${2:-0}" in ''|*[!0-9]* ) return 1 ;; esac
    local varname="_CATBYTES_${raw_key}"
    local current
    eval "current=\"\${${varname}:-0}\""
    eval "_CATBYTES_${raw_key}=$(( current + $2 ))"
}

# All known category keys (used for iteration in reporter + dry-run summary).
# shellcheck disable=SC2034
ALL_KNOWN_CATEGORY_KEYS=(
    trash
    user-caches system-caches app-caches
    user-logs system-logs diagnostic-reports tmp
    app-leftovers
    xcode-derived xcode-archives simulators device-support
    npm yarn pnpm pip brew brew-stale gradle maven cocoapods cargo
    swift-pm gem bundler composer android-avd
    docker time-machine ios-backups installers
)

# ---------------------------------------------------------------------------
# Global counters (reset at script start)
# ---------------------------------------------------------------------------
TOTAL_CLEANED_BYTES=0
TOTAL_WOULD_FREE_BYTES=0
TOTAL_QUARANTINED_BYTES=0
TOTAL_QUARANTINED_ITEMS=0
TOTAL_RESTORED_BYTES=0
TOTAL_RESTORED_ITEMS=0
TOTAL_SKIPPED_ITEMS=0
TOTAL_USER_DECISIONS_NEEDED=0
declare -a USER_DECISION_ITEMS=()
declare -a WARNINGS_LIST=()

inc_skipped_items() {
    TOTAL_SKIPPED_ITEMS=$(( TOTAL_SKIPPED_ITEMS + 1 ))
}

inc_user_decisions_needed() {
    TOTAL_USER_DECISIONS_NEEDED=$(( TOTAL_USER_DECISIONS_NEEDED + 1 ))
}

record_user_decision() {
    local item="$1"
    USER_DECISION_ITEMS+=("$item")
    inc_user_decisions_needed
}

record_skipped_item() {
    local item="${1:-}"
    local msg
    msg="${item:-Unspecified item}"
    # keep a compact list in WARNINGS_LIST for auditability
    WARNINGS_LIST+=("Skipped: ${msg}")
    inc_skipped_items
}
