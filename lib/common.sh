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
        val="$("$fn" "$@" 2>/dev/null)"
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi
    if val="$(i18n_get_pl "$@" 2>/dev/null)" && [[ -n "$val" ]]; then
        echo "$val"
        return 0
    fi
    if val="$(i18n_get_en "$@" 2>/dev/null)" && [[ -n "$val" ]]; then
        echo "$val"
        return 0
    fi
    log_warn "Missing i18n key: ${key}"
    local humanized
    humanized="$(echo "$key" | sed -E 's/^(cli_|mode_|_)?//g' | tr '_' ' ')"
    echo "$humanized"
}

# P1-2: headline_total_label [permanent-key] — quarantined files free nothing
# until --purge-quarantine, so the quarantine-mode total must not be called
# "freeable" (it also covers native commands, which free space at once).
# The permanent mode keeps its own wording (default cli_total_freeable).
headline_total_label() {
    if [[ "${REMOVE_MODE:-quarantine}" == "permanent" ]]; then
        t "${1:-cli_total_freeable}"
    else
        t "total_quarantine_label"
    fi
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

# Delete one validated run artifact. Returns 0 only if the file was removed.
# Skip symlinks, non-regular files, names outside the artifact patterns, and
# paths that escape the configured logs/reports directory.
_rotate_artifact_file() {
    local candidate="$1"
    local root="$2"
    local base

    [[ -n "$candidate" ]] || return 1
    [[ -L "$candidate" ]] && return 1
    [[ -f "$candidate" ]] || return 1
    path_is_within "$candidate" "$root" || return 1
    base="${candidate##*/}"
    case "$base" in
        cleanup_*.log|unreadable_*.txt|report_*.md|plan_*.json|journal_*.jsonl) ;;
        *) return 1 ;;
    esac
    rm -f "$candidate"
    [[ ! -e "$candidate" ]]
}

# P0-1: true when this run must not mutate anything. An explicit --dry-run
# (EXPLICIT_DRY_RUN=1) wins even if a later code path reset DRY_RUN=0.
is_dry_run() {
    [[ "${DRY_RUN:-0}" == "1" || "${EXPLICIT_DRY_RUN:-0}" == "1" ]]
}

# P0-3: REMOVE_MODE must be exactly quarantine|permanent. A typo must never
# fall through to permanent deletion.
validate_remove_mode() {
    case "${REMOVE_MODE:-}" in
        quarantine|permanent) return 0 ;;
    esac
    print_error "Invalid REMOVE_MODE '${REMOVE_MODE:-}': expected quarantine or permanent."
    return 1
}

# P0-3: QUARANTINE_ROOT must be an absolute ".../quarantine" path without . or
# .. segments. Purge removes the root's immediate children, so a root such as
# $HOME would turn a purge into rm -rf of every home directory.
validate_quarantine_root() {
    local root="${QUARANTINE_ROOT:-}"

    case "$root" in
        /*) ;;
        *)
            print_error "Invalid QUARANTINE_ROOT '${root}': must be an absolute path."
            return 1
            ;;
    esac
    case "${root}/" in
        */./*|*/../*)
            print_error "Invalid QUARANTINE_ROOT '${root}': must not contain . or .. segments."
            return 1
            ;;
    esac
    root="${root%/}"
    if [[ "${root##*/}" != "quarantine" ]]; then
        print_error "Invalid QUARANTINE_ROOT '${QUARANTINE_ROOT}': last component must be 'quarantine'."
        return 1
    fi
    return 0
}

# Prune run artifacts older than $1 days (default 30).
#
# Call only from the explicit --prune-artifacts CLI path. Read-only modes
# (dry-run, plan, --list-quarantine) must not delete aged logs or journals.
# ARTIFACT_RETENTION_DAYS=0 disables pruning entirely.
#
# Echoes the number of files removed so the caller can report it.
rotate_old_artifacts() {
    local max_days="${1:-30}"
    local logs_dir="${LOGS_DIR:-}"
    local reports_dir="${REPORTS_DIR:-}"
    local removed=0
    local candidate

    # P0-1: never prune during a dry run.
    if is_dry_run; then
        echo 0
        return 0
    fi

    case "$max_days" in
        ''|*[!0-9]*) return 0 ;;
    esac
    (( max_days == 0 )) && return 0

    if [[ -n "$logs_dir" && -d "$logs_dir" ]]; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if _rotate_artifact_file "$candidate" "$logs_dir"; then
                removed=$((removed + 1))
            fi
        done < <(find "$logs_dir" -type f \( -name "cleanup_*.log" -o -name "unreadable_*.txt" \) -mtime +"$max_days" 2>/dev/null)
    fi

    if [[ -n "$reports_dir" && -d "$reports_dir" ]]; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if _rotate_artifact_file "$candidate" "$reports_dir"; then
                removed=$((removed + 1))
            fi
        done < <(find "$reports_dir" -type f \( -name "report_*.md" -o -name "plan_*.json" -o -name "journal_*.jsonl" \) -mtime +"$max_days" 2>/dev/null)
    fi

    echo "$removed"
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
print_warn()    { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; log_warn "$*"; WARNINGS_LIST+=("$*"); }
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

# Phase 3: unreadable is not empty. macOS can deny access to other apps'
# folders silently; du then exits non-zero and used to make this function
# report 0 bytes. Every location that could not be fully read is recorded in
# a run-scoped file (written from command substitutions too), and the
# summaries report the analysis as partial.
analysis_unreadable_file() {
    printf '%s/unreadable_%s.txt' "${LOGS_DIR:-${TMPDIR:-/tmp}}" "${RUN_TIMESTAMP:-run}"
}

analysis_record_unreadable() {
    local kind="$1" path="$2" file
    file="$(analysis_unreadable_file)"
    { printf '%s\t%s\n' "$kind" "$path" >> "$file"; } 2>/dev/null || true
}

# analysis_unreadable_count — distinct locations recorded this run.
analysis_unreadable_count() {
    local file
    file="$(analysis_unreadable_file)"
    if [[ -f "$file" ]]; then
        cut -f2- "$file" 2>/dev/null | sort -u | grep -c . 2>/dev/null || true
    else
        echo 0
    fi
}

# analysis_path_partial <path> — true when this run recorded <path> as only
# partly (or not) readable.
analysis_path_partial() {
    local file
    file="$(analysis_unreadable_file)"
    [[ -f "$file" ]] || return 1
    cut -f2- "$file" 2>/dev/null | grep -qFx -- "$1"
}

# Return the disk usage of a path in bytes.
# Missing path: echo 0, return 0.
# du succeeds with a numeric KB: echo kb*1024, return 0.
# du fails but reports a numeric KB (partly unreadable): record, echo the
# readable lower bound, return 0.
# du fails with no numeric KB: record, warn, echo 0, return 1.
path_size_bytes() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        echo 0
        return 0
    fi
    local du_out kb
    local du_rc=0
    du_out=$(du -sk "$path" 2>/dev/null) || du_rc=$?
    kb=$(printf '%s\n' "$du_out" | awk 'NR==1{print $1}')
    case "$kb" in
        ''|*[!0-9]*) kb="" ;;
    esac
    if (( du_rc != 0 )); then
        if [[ -n "$kb" ]]; then
            # Partly readable: keep what du could count; it is a lower bound.
            analysis_record_unreadable "partial" "$path"
            echo $(( kb * 1024 ))
            return 0
        fi
        analysis_record_unreadable "unreadable" "$path"
        print_warn "Could not measure size of: $path" >&2
        echo 0
        return 1
    fi
    if [[ -z "$kb" ]]; then
        analysis_record_unreadable "unreadable" "$path"
        print_warn "Could not measure size of: $path" >&2
        echo 0
        return 1
    fi
    echo $(( kb * 1024 ))
    return 0
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
    local user

    p="${p/#\~/$HOME}"
    p="${p//\$HOME/$HOME}"
    p="${p//\$\{HOME\}/$HOME}"
    # P1-6: USER is unset under launchd/cron/`env -i`; under `set -u` a bare
    # $USER aborted expansion and callers fell back to raw paths. Resolve it
    # only when the path needs it, and fail when it cannot be resolved.
    case "$p" in
        *'$USER'*|*'${USER}'*)
            user="${USER:-}"
            [[ -n "$user" ]] || user="$(id -un 2>/dev/null || true)"
            [[ -n "$user" ]] || return 1
            p="${p//\$USER/$user}"
            p="${p//\$\{USER\}/$user}"
            ;;
    esac

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

    path="$(_path_expand_home_and_vars "$input")" || return 1

    # P0-2: collapse consecutive slashes with tr. The global parameter-
    # expansion form ${path//\/\//\/} mis-handles on bash 3.2 (it can leave a
    # literal backslash), which let "//"-separated protected paths bypass the
    # guard. tr -s is deterministic across bash 3.2 and 5.
    path="$(printf '%s' "$path" | tr -s '/')"
    # Root ("/", "//") strips to empty and fails; callers fall back to the raw
    # path, which the broad-root guards then protect.
    path="${path%/}"
    [[ -z "$path" ]] && return 1



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
        if [[ "$base" == ".." ]]; then
            # A trailing ".." is never a symlink leaf; resolve it so
            # "~/Library/Caches/.." matches as ~/Library.
            norm="$(cd -P "$path" 2>/dev/null && pwd -P)"
        elif [[ -n "$base" && "$base" != "." && "$base" != "/" ]]; then
            if [[ "$dir" == "/" ]]; then
                norm="/$base"
            else
                norm="$dir/$base"
            fi
        else
            norm="$dir"
        fi
        # Fail closed: "/." resolves to an empty dir; never report success
        # with an empty path.
        [[ -z "$norm" ]] && return 1
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
#
# P0-2: all pattern matching runs under `shopt -s nocasematch` inside a
# subshell so the guard is case-insensitive. macOS APFS is case-insensitive by
# default, so "$HOME/Library/mail" is the same object as "$HOME/Library/Mail";
# a case-sensitive compare let a case variant bypass the guard. Scoping
# nocasematch to a subshell keeps it out of the rest of the script and adds no
# per-entry forks (preserving the PF3 pre-normalized array). Case folding can
# only ever protect MORE paths, never fewer — over-protection is the safe
# direction for a deletion guard.
is_protected_path() {
    local candidate="$1"
    local normalized_candidate

    # Fail closed: a path that cannot be normalized ("", "/", "//", "/.") is
    # treated as protected.
    normalized_candidate="$(normalize_path "$candidate")" || return 0
    [[ -n "$normalized_candidate" ]] || return 0

    (
        shopt -s nocasematch

        # Fail closed for broad roots. Cleaners should pass leaf candidates,
        # never whole user/system roots.
        case "$normalized_candidate" in
            /|/bin|/bin/*|/sbin|/sbin/*|/usr|/usr/*|/etc|/etc/*|/private/etc|/private/etc/*|/Applications|/Applications/*|/opt|/opt/*)
                exit 0 ;;
            /tmp|/private/tmp|/private|/private/var|/private/var/folders|/var|/var/folders)
                exit 0 ;;
            "$HOME"|"$HOME/Library"|"$HOME/Library/Caches"|"$HOME/.Trash"|"$HOME/Library/Application Support")
                exit 0 ;;
            "$HOME/Library/Preferences"|"$HOME/Library/Preferences/"*)
                exit 0 ;;
            "$HOME/Library/Containers"|"$HOME/Library/Containers/"*)
                exit 0 ;;
            "$HOME/Library/Group Containers"|"$HOME/Library/Group Containers/"*)
                exit 0 ;;
            "$HOME/Library/Saved Application State"|"$HOME/Library/Saved Application State/"*)
                exit 0 ;;
        esac

        # /System/* and other users are never touched.
        # /Library is protected by default, with targeted cache/log leaf cleanup.
        if [[ "$normalized_candidate" == "/System" || "$normalized_candidate" == "/System/"* || \
              "$normalized_candidate" == "/private/var/System"* || "$normalized_candidate" == "/var/System"* ]]; then
            exit 0
        fi
        if [[ "$normalized_candidate" == "/Users" || "$normalized_candidate" == "/Users/"* ]]; then
            if [[ "$normalized_candidate" != "$HOME/"* ]]; then
                exit 0
            fi
        fi
        if [[ "$normalized_candidate" == "/Library" || "$normalized_candidate" == "/Library/"* ]]; then
            case "$normalized_candidate" in
                /Library/Caches/*|/Library/Logs/*)
                    :
                    ;;
                *)
                    exit 0
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
                    exit 0  # protected
                fi
            done
        elif (( ${#NEVER_TOUCH_PATHS[@]} > 0 )); then
            local protected normalized_protected
            for protected in "${NEVER_TOUCH_PATHS[@]}"; do
                normalized_protected="$(normalize_path "$protected" || echo "$protected")"
                if [[ "$normalized_candidate" == "$normalized_protected" || \
                      "$normalized_candidate" == "$normalized_protected"/* || \
                      "$normalized_protected" == "$normalized_candidate"/* ]]; then
                    exit 0  # protected
                fi
            done
        fi
        exit 1  # not protected
    )
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

file_mtime_seconds() {
    local target="$1"
    [[ -e "$target" ]] || return 1
    local mtime=""
    mtime=$(stat -f "%m" "$target" 2>/dev/null) || mtime=""
    if [[ -z "$mtime" || "$mtime" == *[!0-9]* ]]; then
        mtime=$(stat -c "%Y" "$target" 2>/dev/null) || mtime=""
    fi
    if [[ -z "$mtime" || "$mtime" == *[!0-9]* ]]; then
        if command -v python3 >/dev/null 2>&1; then
            mtime=$(python3 -c 'import os, sys; print(int(os.path.getmtime(sys.argv[1])))' "$target" 2>/dev/null || echo "0")
        fi
    fi
    echo "${mtime:-0}"
}

file_older_than_days() {
    local file="$1"
    local days="$2"
    if [[ ! -e "$file" ]]; then return 1; fi
    local mtime now diff_days
    mtime="$(file_mtime_seconds "$file")"
    [[ -z "$mtime" || "$mtime" -eq 0 ]] && return 1
    now=$(date +%s)
    diff_days=$(( (now - mtime) / 86400 ))
    (( diff_days > days ))
}

file_older_than_hours() {
    local file="$1"
    local hours="$2"
    if [[ ! -e "$file" ]]; then return 1; fi
    local mtime now diff_hours
    mtime="$(file_mtime_seconds "$file")"
    [[ -z "$mtime" || "$mtime" -eq 0 ]] && return 1
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

get_plist_bundle_id() {
    local plist="$1"
    [[ -f "$plist" ]] || return 1
    if command -v defaults >/dev/null 2>&1; then
        local bid
        bid="$(defaults read "$plist" CFBundleIdentifier 2>/dev/null || true)"
        if [[ -n "$bid" ]]; then
            echo "$bid"
            return 0
        fi
    fi
    if command -v python3 >/dev/null 2>&1; then
        local pbid
        pbid="$(python3 -c '
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        p = plistlib.load(f)
        print(p.get("CFBundleIdentifier", ""))
except Exception:
    pass' "$plist" 2>/dev/null || true)"
        if [[ -n "$pbid" ]]; then
            echo "$pbid"
            return 0
        fi
    fi
    grep -A1 "<key>CFBundleIdentifier</key>" "$plist" 2>/dev/null | grep "<string>" | sed 's/.*<string>\(.*\)<\/string>.*/\1/'
}

app_bundle_exists() {
    local bundle_id="$1"
    [[ -n "$bundle_id" ]] || return 1

    # Phase 2: the one-time bundle-id index of /Applications, ~/Applications
    # and /System/Applications answers most lookups without a fork. It covers
    # the same apps as FOUND_INSTALLED_APPS, whose per-app `defaults read`
    # loop used to run for every orphan candidate (~60 s per full scan).
    if (( APP_BUNDLE_ID_CACHE_LOADED == 0 )); then
        _load_app_bundle_id_cache
    fi
    case $'\n'"${APP_BUNDLE_ID_CACHE}"$'\n' in
        *$'\n'"${bundle_id}"$'\n'*) return 0 ;;
    esac

    # Apps outside those folders (other volumes, Setapp, ...): ask Spotlight.
    if command -v mdfind >/dev/null 2>&1; then
        local found
        if found="$(mdfind "kMDItemCFBundleIdentifier == \"$bundle_id\"" 2>/dev/null)" && [[ -n "$found" ]]; then
            return 0
        fi
    fi
    return 1
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

    local local_snaps=0
    if command -v tmutil >/dev/null 2>&1; then
        local_snaps="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine" 2>/dev/null || echo 0)"
    fi
    local_snaps="$(echo "$local_snaps" | tr -d '[:space:]')"
    [[ -z "$local_snaps" ]] && local_snaps=0

    if (( local_snaps > 0 )); then
        print_warning_box "No destination backup (local snapshots found)" \
            "No destination Time Machine backup in last ${BACKUP_MAX_AGE_DAYS} days." \
            "Found ${local_snaps} local APFS snapshot(s) on disk." \
            "" \
            "Local snapshots reside on local disk, NOT an off-device backup." \
            "Context: ${context}" \
            "" \
            "Proceeding under guardrails; REVIEW/DANGEROUS" \
            "are not executed automatically."
        WARNINGS_LIST+=("No destination Time Machine backup (found ${local_snaps} local APFS snapshots) before: ${context}")
        cleanup_journal_event "backup_check" "" "" 0 "warning" "destination backup missing (${local_snaps} local APFS snapshots found) for ${context}" "safety"
    else
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
    fi
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

# metadata_path_is_durable <path>
# Parent must be a writable directory. Path must be absent or a writable regular file.
metadata_path_is_durable() {
    local path="${1:-}"
    local parent

    [[ -n "$path" ]] || return 1
    parent="$(dirname "$path")"
    mkdir -p "$parent" 2>/dev/null || return 1
    [[ -d "$parent" && -w "$parent" ]] || return 1

    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && -w "$path" ]] || return 1
    fi
    return 0
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
    if [[ -n "${CLEANUP_TEST_FAIL_JOURNAL_ACTION:-}" && "$action" == "$CLEANUP_TEST_FAIL_JOURNAL_ACTION" ]]; then
        return 1
    fi
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    mkdir -p "$(dirname "$journal_file")" 2>/dev/null || return 1
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
        >> "$journal_file" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# P1-4: one tool→target table for native cleanup commands. The analyzer, the
# planner and plan apply all resolve a command's target here, so a plan op is
# bound to the directory its tool actually cleans. Before, apply accepted
# `npm cache clean --force` with ~/Library/Messages as its path, resolved the
# __brew__ sentinel against the cwd, and never noticed an npmrc/pnpm/pip
# config that moved the cache after the plan was written.
# ---------------------------------------------------------------------------

# native_tool_for_command <command> — the tool an allowlisted command uses.
native_tool_for_command() {
    case "${1:-}" in
        "npm cache clean --force")         echo npm ;;
        "yarn cache clean")                echo yarn ;;
        "pnpm store prune")                echo pnpm ;;
        "pip cache purge")                 echo pip ;;
        "brew cleanup --prune=all")        echo brew ;;
        "gem cleanup")                     echo gem ;;
        "xcrun simctl delete unavailable") echo xcrun ;;
        *) return 1 ;;
    esac
}

# native_pip_bin — pip3 when present, else pip (the same choice apply makes).
native_pip_bin() {
    if command -v pip3 >/dev/null 2>&1; then echo pip3
    elif command -v pip >/dev/null 2>&1; then echo pip
    else return 1
    fi
}

# native_tool_target <tool> — normalized absolute directory the tool's cleanup
# acts on; fails (no output) when the tool cannot tell.
native_tool_target() {
    local tool="${1:-}" target_dir="" pip_bin
    case "$tool" in
        npm)   target_dir="$(npm config get cache </dev/null 2>/dev/null)" ;;
        yarn)  target_dir="$(yarn cache dir </dev/null 2>/dev/null)" ;;
        pnpm)  target_dir="$(pnpm store path </dev/null 2>/dev/null)" ;;
        pip)   pip_bin="$(native_pip_bin)" || return 1
               target_dir="$("$pip_bin" cache dir </dev/null 2>/dev/null)" ;;
        brew)  target_dir="$(brew --cache </dev/null 2>/dev/null)" ;;
        gem)   target_dir="$(gem env gemdir </dev/null 2>/dev/null)" ;;
        xcrun) target_dir="${HOME}/Library/Developer/CoreSimulator/Devices" ;;
        *)     return 1 ;;
    esac
    target_dir="$(printf '%s\n' "$target_dir" | head -n 1)"
    [[ "$target_dir" == /* ]] || return 1
    normalize_path "$target_dir"
}

# native_target_allowed <tool> <target> — the cleanup of npm/yarn/pnpm/pip/brew
# empties the directory its tool names, and NPM_CONFIG_CACHE, PIP_CACHE_DIR, an
# .npmrc or a pnpm store-dir can name any directory. validate_cache_path alone
# is too broad here (it admits the whole brew prefix and /var/folders), so the
# target must also be the tool's own folder under HOME: its dot-directory, or a
# child (never the root) of ~/Library/Caches or ~/.cache.
# gem cleanup only uninstalls old versions; simctl's target is fixed.
native_target_allowed() {
    local tool="${1:-}" target="${2:-}" home
    case "$tool" in
        gem|xcrun) [[ -n "$target" ]]; return ;;
        npm|yarn|pnpm|pip|brew) ;;
        *) return 1 ;;
    esac
    home="$(normalize_path "$HOME" 2>/dev/null)" || return 1
    case "${tool}:${target}" in
        npm:"$home/.npm"|npm:"$home/.npm/"*) ;;
        yarn:"$home/.yarn"|yarn:"$home/.yarn/"*) ;;
        pnpm:"$home/.pnpm-store"|pnpm:"$home/.pnpm-store/"*) ;;
        pnpm:"$home/Library/pnpm/"?*|pnpm:"$home/.local/share/pnpm/"?*) ;;
        *:"$home/Library/Caches/"?*|*:"$home/.cache/"?*) ;;
        *) return 1 ;;
    esac
    command -v validate_cache_path >/dev/null 2>&1 || return 1
    validate_cache_path "$target"
}

record_native_command_event() {
    local command="$1"
    local status="${2:-ok}"
    local bytes="${3:-0}"
    local message="${4:-}"

    cleanup_journal_event "native_command" "$command" "" "$bytes" "$status" "$message"
}

# record_native_command_freed <command> <bytes_before> <bytes_after> [message]
#
# The journal used to record `path_size_bytes "$path"` measured AFTER the
# command ran — i.e. what was LEFT, logged in the "bytes" field as if it were
# what was freed. The 2026-08-19 20:15 run recorded 5,707,751,424 bytes against
# `npm cache clean --force`; that was ~/.npm/_npx, which the command never
# touches. The real reclaim was ~322 MB.
#
# Record the before/after delta instead, and credit it to TOTAL_CLEANED_BYTES —
# native commands previously contributed nothing, so a run whose only action was
# `npm cache clean` reported "Freed space: 0 B".
record_native_command_freed() {
    local command="$1"
    local before="${2:-0}"
    local after="${3:-0}"
    local message="${4:-}"
    local freed=0

    case "$before" in ''|*[!0-9]*) before=0 ;; esac
    case "$after"  in ''|*[!0-9]*) after=0  ;; esac
    (( before > after )) && freed=$(( before - after ))

    TOTAL_CLEANED_BYTES=$(( ${TOTAL_CLEANED_BYTES:-0} + freed ))
    cleanup_journal_event "native_command" "$command" "" "$freed" "ok" "$message"
}

# ---------------------------------------------------------------------------
# Category outcome ledger
#
# The report used to infer a category's status from the RUN MODE: in
# interactive mode `user-caches` was always printed as "Cleaned/Quarantined |
# Done". On 2026-08-19 the user declined that exact category and the report
# still claimed it had been cleaned. A cleanup report that misstates what it
# did is worse than no report. Record the real outcome instead.
# ---------------------------------------------------------------------------
CLEANUP_CATEGORY_OUTCOMES=""

# mark_category_outcome <category-key> <cleaned|skipped|report-only|needs-permanent|partial>
#   needs-permanent: quarantine mode cannot move these paths (outside HOME)
#   partial:         the paths under HOME were processed, the rest need --permanent
#   backup-running:  Time Machine was backing up, so no snapshot was deleted
#   kept-newest:     the only local snapshot is the newest one, which is kept
mark_category_outcome() {
    local key="${1:-}" outcome="${2:-}"
    [[ -n "$key" && -n "$outcome" ]] || return 0
    CLEANUP_CATEGORY_OUTCOMES="${CLEANUP_CATEGORY_OUTCOMES}${key}=${outcome}"$'\n'
}

# category_outcome <category-key> — echoes the recorded outcome, or nothing.
category_outcome() {
    local key="${1:-}" line found=""
    [[ -n "$key" ]] || return 0
    # LAST write wins. mark_category_outcome appends, and a category can be
    # recorded twice in one run — clean_app_specific_caches asks separately
    # about its allowlisted and its review half. Returning the first match
    # meant declining the small SAFE group printed the whole category as
    # "Skipped by you" even when the REVIEW half was cleaned.
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "${line%%=*}" == "$key" ]]; then
            found="${line#*=}"
        fi
    done <<EOF
${CLEANUP_CATEGORY_OUTCOMES}
EOF
    printf '%s' "$found"
    return 0
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
    local encoded_q encoded_o row last

    [[ -n "$manifest" ]] || return 0
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac

    mkdir -p "$(dirname "$manifest")" 2>/dev/null || return 1

    encoded_q="$(base64_encode_string "$quarantine_path")"
    encoded_o="$(base64_encode_string "$original_path")"
    row="$(printf '%s\t%s\t%s' "$encoded_q" "$encoded_o" "$bytes")"

    printf '%s\n' "$row" >> "$manifest" 2>/dev/null || return 1
    [[ -r "$manifest" ]] || return 1
    last="$(tail -n 1 "$manifest" 2>/dev/null || true)"
    [[ "$last" == "$row" ]] || return 1
    return 0
}

_quarantine_drop_last_restore_row() {
    local manifest="${CLEANUP_RESTORE_MANIFEST:-}"
    local tmp

    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    tmp="${manifest}.tmp.$$"
    if sed '$d' "$manifest" > "$tmp" 2>/dev/null && mv "$tmp" "$manifest"; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
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

# Deny-side check (safe_remove skips quarantine data), so it ignores case like
# is_protected_path. path_is_within stays case-sensitive: it is also an
# allowlist (artifact rotation, restore source).
is_quarantine_path() {
    [[ -n "${QUARANTINE_ROOT:-}" ]] || return 1
    local candidate root
    candidate="$(normalize_path "$1" || echo "$1")"
    root="$(normalize_path "$QUARANTINE_ROOT" || echo "$QUARANTINE_ROOT")"
    [[ -n "$candidate" && -n "$root" ]] || return 1
    (
        shopt -s nocasematch
        [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]
    )
}

# Exclusive lock for every mutating mode (apply, restore, purge, interactive,
# auto-safe) via mkdir(2). Not TOCTOU-proof.
CLEANUP_LOCK_HELD="${CLEANUP_LOCK_HELD:-0}"

# P1-7: _cleanup_lock_holder_gone <lock_dir> — true when the recorded holder is
# no longer running. `ps -p` sees other users' processes too (kill -0 fails
# with EPERM for a live root-owned run); when ps itself does not work, every
# holder is presumed alive. A lock without a pid may belong to a holder between
# mkdir and the pid write, so it counts as abandoned only after 10 minutes.
_cleanup_lock_holder_gone() {
    local lock_dir="$1" pid
    pid="$(head -n 1 "${lock_dir}/pid" 2>/dev/null)" || pid=""
    case "$pid" in
        ''|*[!0-9]*)
            [[ -n "$(find "$lock_dir" -maxdepth 0 -mmin +10 2>/dev/null)" ]] ;;
        *)
            ps -p "$$" >/dev/null 2>&1 || return 1
            [[ "$pid" != "$$" ]] && ! ps -p "$pid" >/dev/null 2>&1 ;;
    esac
}

# P1-7: _recover_stale_cleanup_lock <lock_dir> — remove a lock whose holder is
# gone. Only one process recovers at a time (mkdir of "<lock>.recover"), and
# only a recoverer ever removes another process's lock, so the lock re-checked
# under that mutex cannot be swapped for a live one before it is removed.
# A recovery mutex older than 10 minutes was abandoned by a crashed recoverer.
_recover_stale_cleanup_lock() {
    local lock_dir="$1" mutex="${1}.recover" rc=1
    if ! mkdir "$mutex" 2>/dev/null; then
        [[ -n "$(find "$mutex" -maxdepth 0 -mmin +10 2>/dev/null)" ]] || return 1
        rmdir "$mutex" 2>/dev/null || return 1
        mkdir "$mutex" 2>/dev/null || return 1
    fi
    if [[ -d "$lock_dir" ]] && _cleanup_lock_holder_gone "$lock_dir"; then
        rm -f "${lock_dir}/pid" 2>/dev/null || true
        if rmdir "$lock_dir" 2>/dev/null; then
            log_warn "Recovered a stale cleanup lock: ${lock_dir}"
            rc=0
        fi
    fi
    rmdir "$mutex" 2>/dev/null || true
    return "$rc"
}

acquire_cleanup_lock() {
    local lock_dir
    if [[ -z "${QUARANTINE_ROOT:-}" ]]; then
        return 1
    fi
    mkdir -p "$QUARANTINE_ROOT" 2>/dev/null || return 1
    lock_dir="${QUARANTINE_ROOT}/.apply.lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        _recover_stale_cleanup_lock "$lock_dir" || return 1
        mkdir "$lock_dir" 2>/dev/null || return 1
    fi
    # A lock without a pid would look abandoned to others after 10 minutes.
    if ! printf '%s\n' "$$" > "${lock_dir}/pid" 2>/dev/null; then
        rmdir "$lock_dir" 2>/dev/null || true
        return 1
    fi
    CLEANUP_LOCK_HELD=1
    return 0
}

# release_cleanup_lock — removes the lock only while it still records this
# process; a lock recovered and re-taken by another run is left alone.
release_cleanup_lock() {
    local lock_dir pid
    if [[ "${CLEANUP_LOCK_HELD:-0}" != "1" ]]; then
        return 0
    fi
    CLEANUP_LOCK_HELD=0
    lock_dir="${QUARANTINE_ROOT:-}/.apply.lock"
    [[ -d "$lock_dir" ]] || return 0
    pid="$(head -n 1 "${lock_dir}/pid" 2>/dev/null)" || pid=""
    if [[ "$pid" != "$$" ]]; then
        log_warn "Cleanup lock now belongs to ${pid:-nobody}; leaving it: ${lock_dir}"
        return 0
    fi
    rm -f "${lock_dir}/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
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

_quarantine_rollback_move() {
    local dest="$1"
    local target="$2"
    local size="${3:-0}"
    local drop_restore_row="${4:-0}"

    if [[ "$drop_restore_row" == "1" ]]; then
        _quarantine_drop_last_restore_row || true
    fi

    if mv "$dest" "$target" 2>/dev/null; then
        print_warn "Rolled back quarantine because metadata could not be written: ${target}"
        record_skipped_item "Quarantine metadata write failed; rolled back: ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "metadata write failed; rolled back" || true
        return 0
    fi

    print_error "Quarantine recovery needed: ${target} was moved to ${dest} but metadata could not be written and rollback failed"
    record_skipped_item "Quarantine recovery needed: ${target} -> ${dest}"
    cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "recovery_needed" "moved but metadata missing; rollback failed" || true
    return 1
}

quarantine_remove() {
    local target="$1"
    local size="${2:-0}"
    local dest dest_dir
    local journal_file="${CLEANUP_JOURNAL_FILE:-}"
    local manifest="${CLEANUP_RESTORE_MANIFEST:-}"

    dest="$(quarantine_destination_for "$target" 2>/dev/null || true)"
    if [[ -z "$dest" ]]; then
        print_warn "Quarantine is not configured; skipping: ${target}"
        record_skipped_item "Quarantine is not configured: ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "" "$size" "failed" "quarantine not configured" || true
        return 1
    fi
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir" 2>/dev/null || {
        print_warn "Could not create quarantine directory for: ${target}"
        record_skipped_item "Cannot create quarantine directory for ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "mkdir failed" || true
        return 1
    }
    if [[ ! -d "$dest_dir" || ! -w "$dest_dir" ]]; then
        print_warn "Could not create quarantine directory for: ${target}"
        record_skipped_item "Cannot create quarantine directory for ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "mkdir failed" || true
        return 1
    fi

    if ! metadata_path_is_durable "$manifest" || ! metadata_path_is_durable "$journal_file"; then
        print_warn "Cannot persist quarantine metadata for: ${target}"
        record_skipped_item "Cannot persist quarantine metadata for ${target}"
        if metadata_path_is_durable "$journal_file"; then
            cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "metadata not durable" || true
        fi
        return 1
    fi

    if ! cleanup_journal_event "quarantine_intent" "$target" "$dest" "$size" "pending" ""; then
        print_warn "Could not record quarantine intent for: ${target}"
        record_skipped_item "Cannot record quarantine intent for ${target}"
        return 1
    fi

    if ! mv "$target" "$dest" 2>/dev/null; then
        print_warn "Could not quarantine: ${target}"
        log_warn "mv to quarantine failed for: ${target}"
        record_skipped_item "Failed to move to quarantine: ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "mv failed" || true
        return 1
    fi

    if ! cleanup_restore_record "$dest" "$target" "$size"; then
        _quarantine_rollback_move "$dest" "$target" "$size" || true
        return 1
    fi

    if ! cleanup_journal_event "quarantined" "$target" "$dest" "$size" "ok" ""; then
        _quarantine_rollback_move "$dest" "$target" "$size" 1 || true
        return 1
    fi

    TOTAL_QUARANTINED_BYTES=$(( TOTAL_QUARANTINED_BYTES + size ))
    TOTAL_QUARANTINED_ITEMS=$(( TOTAL_QUARANTINED_ITEMS + 1 ))
    print_cleaned "Quarantining: ${target} -> ${dest}  ($(bytes_to_human "$size"))"
    return 0
}

direct_remove() {
    local target="$1"
    local size="${2:-0}"
    local sudo_required="${3:-0}"
    local action="${4:-deleted}"

    # P0-1: last line of defense — no removal while any dry-run is in effect.
    if is_dry_run; then
        print_warn "Dry run: refusing to remove ${target}"
        record_skipped_item "Dry-run removal refused: ${target}"
        cleanup_journal_event "${action}_blocked" "$target" "" "$size" "blocked" "dry-run (P0-1)"
        return 1
    fi

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

    # P0-1: restore moves files; it has no preview form.
    if is_dry_run; then
        print_error "Restore refused: a dry run is in effect."
        return 2
    fi

    manifest="$(resolve_restore_manifest "$requested" 2>/dev/null || true)"
    if [[ -z "$manifest" ]]; then
        print_error "Restore manifest not found: ${requested}"
        return 2
    fi

    if [[ "$requested" == "latest" ]]; then
        local run_id=""
        run_id="$(basename "$manifest" | sed 's/^restore_//;s/\.tsv$//')"
        print_info "Restoring quarantine from latest run (run ID: ${run_id}): ${manifest}"

        local -a other_manifests=()
        while IFS= read -r m; do
            [[ -n "$m" && "$m" != "$manifest" ]] && other_manifests+=("$m")
        done < <(ls -t "${REPORTS_DIR}"/restore_*.tsv 2>/dev/null || true)

        if (( ${#other_manifests[@]} > 0 )); then
            print_info "Other available quarantine runs:"
            for om in "${other_manifests[@]}"; do
                local om_id
                om_id="$(basename "$om" | sed 's/^restore_//;s/\.tsv$//')"
                echo "  • ${om_id}"
            done
            print_info "Hint: Target a specific run with: bash cleanup_all.sh --restore <run_id>"
        fi
    else
        print_info "Restoring quarantine from manifest: ${manifest}"
    fi

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
    # P0-1: a dry run downgrades --apply to a preview.
    is_dry_run && apply=0
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

    # P0-3: never purge children of a root that is not a quarantine directory.
    validate_quarantine_root || return 2

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
    local dry=0
    local normalized_target

    is_dry_run && dry=1

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

    # Phase 3: rm -rf on a tree with an unreadable part deletes what it can
    # and stops at the rest, leaving it half-deleted. Quarantine (a rename on
    # the same volume) is unaffected; permanent removal skips such a tree.
    if [[ "${REMOVE_MODE:-quarantine}" == "permanent" ]] && analysis_path_partial "$normalized_target"; then
        print_skip "Not fully readable, not deleted permanently: ${normalized_target}"
        record_skipped_item "Not fully readable (macOS privacy or permissions), skipped in permanent mode: ${normalized_target}"
        cleanup_journal_event "skipped_unreadable" "$normalized_target" "" "$size" "skipped" "partly unreadable; permanent removal would half-delete it"
        return 0
    fi

    if [[ "$dry" == "1" ]]; then
        print_dry "Would remove: ${normalized_target}  ($(bytes_to_human "$size"))"
        TOTAL_WOULD_FREE_BYTES=$(( TOTAL_WOULD_FREE_BYTES + size ))
        cleanup_journal_event "would_remove" "$normalized_target" "" "$size" "planned" ""
    else
        # P0-3: fail closed on an unknown/unset mode instead of deleting.
        if ! validate_remove_mode; then
            record_skipped_item "Invalid REMOVE_MODE (fail-closed): ${normalized_target}"
            cleanup_journal_event "remove_mode_invalid" "$normalized_target" "" "$size" "blocked" "fail-closed (P0-3)"
            return 1
        fi

        if [[ "$REMOVE_MODE" == "quarantine" ]]; then
            if is_user_space_path "$normalized_target"; then
                if quarantine_remove "$normalized_target" "$size"; then
                    return 0
                fi
                return 1
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

# ---------------------------------------------------------------------------
# CATEGORY_REGISTRY — the single source of truth for reportable categories.
#
# Row format:  key|label|class
#   counted     real byte size of work a cleaner can do; the headline
#               TOTAL_WOULD_FREE_BYTES is the plan's executable sum (P1-1)
#   count       ledger value is an ITEM COUNT, not bytes (APFS local snapshots);
#               listed, never summed
#   report-only sized and shown, never auto-removed, never summed
#
# Every `catbytes_set "<key>"` in lib/ must have a row here. lib/reporter.sh used
# to keep its own hand-written label list, and the two drifted: 21 labels against
# 37 live keys, four of them ("logs", "dev", "derived-data",
# "xcode-device-support") naming keys nothing ever sets, so they could never
# render at all. Measured on 2026-09-01: the terminal summary listed 13.05 GB
# across 12 categories while the markdown report itemised 6 of them — app-caches
# (1.04 GB), cargo, brew, pip, swift-pm and xcode-derived were sized, counted in
# the headline total, and then printed nowhere. tests/test_report_parity.sh keeps
# the two lists from separating again.
# ---------------------------------------------------------------------------
CATEGORY_REGISTRY=(
    "trash|Trash (~/.Trash)|counted"
    "user-caches|User Caches (~/Library/Caches)|counted"
    "system-caches|System Caches (/Library/Caches)|report-only"
    "app-caches|App-specific Caches (Electron/JetBrains/...)|counted"
    "user-logs|User Logs (~/Library/Logs)|counted"
    "system-logs|System Logs (/Library/Logs)|counted"
    "diagnostic-reports|Diagnostic Reports|counted"
    "tmp|Temporary Files (/tmp)|counted"
    "app-leftovers|App Leftovers|report-only"
    "xcode-derived|Xcode DerivedData|counted"
    "xcode-archives|Xcode Archives|report-only"
    "simulators|iOS Simulators (unavailable)|counted"
    "device-support|Xcode Device Support|counted"
    "npm|npm cache (~/.npm/_cacache)|counted"
    "npx|npx cache (~/.npm/_npx)|counted"
    "yarn|yarn cache|counted"
    "pnpm|pnpm store|counted"
    "pnpm-stale|pnpm stale store versions|counted"
    "pip|pip cache|counted"
    "brew|Homebrew cache|counted"
    "brew-stale|Homebrew stale versions (brew cleanup)|counted"
    "gradle|Gradle cache|counted"
    "maven|Maven repository (~/.m2)|report-only"
    "cocoapods|CocoaPods cache|counted"
    "cargo|Cargo registry cache|counted"
    "swift-pm|Swift Package Manager cache|counted"
    "gem|Ruby gems cache|counted"
    "bundler|Bundler cache|counted"
    "composer|Composer cache (PHP)|counted"
    "android-avd|Android AVD Emulators|report-only"
    "docker|Docker (reclaimable)|counted"
    "time-machine|Local TM Snapshots|count"
    "ios-backups|iOS Backups|counted"
    "installers|Old Installers (~/Downloads)|counted"
    "browser-caches|Browser Caches (review)|report-only"
    "browser-data|Browser Profiles (DANGEROUS)|report-only"
    "mail-total|Apple Mail (DANGEROUS)|report-only"
    "mail-data|Apple Mail - store|report-only"
    "mail-downloads|Apple Mail - downloads|report-only"
)

# category_label <key> - printable label, or the key itself when unregistered.
category_label() {
    local key="${1:-}" row
    for row in "${CATEGORY_REGISTRY[@]}"; do
        if [[ "${row%%|*}" == "$key" ]]; then
            local rest="${row#*|}"
            printf '%s' "${rest%%|*}"
            return 0
        fi
    done
    printf '%s' "$key"
}

# category_class <key> - counted | count | report-only ("" when unregistered).
category_class() {
    local key="${1:-}" row
    for row in "${CATEGORY_REGISTRY[@]}"; do
        if [[ "${row%%|*}" == "$key" ]]; then
            printf '%s' "${row##*|}"
            return 0
        fi
    done
    return 0
}

# All keys that participate in the grand total's iteration (counted + count).
# Derived from the registry so it cannot drift from the labels again.
# shellcheck disable=SC2034
ALL_KNOWN_CATEGORY_KEYS=()
_reg_row=""
for _reg_row in "${CATEGORY_REGISTRY[@]}"; do
    case "${_reg_row##*|}" in
        counted|count) ALL_KNOWN_CATEGORY_KEYS+=("${_reg_row%%|*}") ;;
    esac
done
unset _reg_row

# ---------------------------------------------------------------------------
# Global counters (reset at script start)
# ---------------------------------------------------------------------------
TOTAL_CLEANED_BYTES=0
TOTAL_WOULD_FREE_BYTES=0
TOTAL_INFORMATIONAL_BYTES=0
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
