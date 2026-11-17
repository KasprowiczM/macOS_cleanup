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
    redact_into "$plain"
    plain="$REDACTED_TEXT"
    # The log directory is created by the run's startup (prepare_run_artifacts);
    # --help, --version and usage errors must not create any file.
    [[ -d "${LOG_FILE%/*}" ]] || return 0
    echo "[${ts}] [${level}] ${plain}" >> "${LOG_FILE}" 2>/dev/null || true
}

log_debug() { [[ "${LOG_LEVEL}" == "DEBUG" ]] && _log "DEBUG" "$@" || true; }
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }

# Signal, error and exit handlers live in cleanup_all.sh (_on_exit, _on_error,
# _on_interrupt): they need the run state it owns.

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
    local lang="${LANG_CODE:-en}"
    local fn="i18n_get_${lang}"
    local val=""
    if declare -f "$fn" >/dev/null 2>&1; then
        val="$("$fn" "$@" 2>/dev/null)"
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi
    # English is the fallback for a key the selected language lacks.
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

# Phase 2: per-path size memo. Analyzers measure every candidate with du, and
# the planner and the prompts used to measure the same paths again. When
# SIZE_MEMO_FILE is set (cleanup_all.sh sets it per run), path_size_bytes
# appends each successful measurement as "<bytes>\t<path>". It is a file, not
# a variable, because most measurements run inside $(...) subshells.
# Only plan estimates and prompt sizes read it (path_size_bytes_memo);
# safe_remove and native-command before/after accounting measure live.
# Never inherited: the exit handler removes this file.
SIZE_MEMO_FILE=""

size_memo_record() {
    local path="$1" bytes="$2"
    [[ -n "$SIZE_MEMO_FILE" ]] || return 0
    case "$path" in
        ''|*$'\n'*) return 0 ;;
    esac
    { printf '%s\t%s\n' "$bytes" "$path" >> "$SIZE_MEMO_FILE"; } 2>/dev/null || true
}

# path_size_bytes_memo <path> — the last recorded size of <path> this run, else
# a live measurement. A path that no longer exists is 0.
path_size_bytes_memo() {
    local path="$1" hit=""
    if [[ ! -e "$path" ]]; then
        echo 0
        return 0
    fi
    case "$path" in
        *$'\n'*) ;;
        *)
            if [[ -n "$SIZE_MEMO_FILE" && -f "$SIZE_MEMO_FILE" ]]; then
                hit="$(P="$path" awk -F'\t' 'substr($0, index($0, "\t") + 1) == ENVIRON["P"] { b = $1 } END { if (b != "") print b }' "$SIZE_MEMO_FILE" 2>/dev/null)" || hit=""
            fi
            ;;
    esac
    case "$hit" in
        ''|*[!0-9]*) path_size_bytes "$path"; return $? ;;
    esac
    echo "$hit"
}

path_size_human_memo() {
    local bytes
    bytes=$(path_size_bytes_memo "$1")
    bytes_to_human "$bytes"
}

# ---------------------------------------------------------------------------
# Privacy & Security Helpers
# ---------------------------------------------------------------------------

# F11: --redact (REDACT_PATHS=1) keeps the user name, the home path and the
# host name out of what the run writes for sharing: the report, the --json
# summary, the log and the journal. The plan file and the restore manifest keep
# real paths on purpose: applying a plan and restoring quarantine need them.
_redact_init() {
    [[ -n "${_REDACT_READY:-}" ]] && return 0
    _REDACT_USER="$(id -un 2>/dev/null || whoami 2>/dev/null || true)"
    _REDACT_HOST_FULL="$(hostname 2>/dev/null || true)"
    _REDACT_HOST_SHORT="$(hostname -s 2>/dev/null || true)"
    _REDACT_READY=1
}

# redact_into <text> — sets REDACTED_TEXT (no subshell, so it is cheap per log
# line). Identity unless REDACT_PATHS=1.
redact_into() {
    REDACTED_TEXT="$1"
    [[ "${REDACT_PATHS:-0}" == "1" ]] || return 0
    _redact_init
    local tilde='~' hostmark='<host>'
    if [[ -n "${HOME:-}" && "$HOME" != "/" ]]; then
        REDACTED_TEXT="${REDACTED_TEXT//"$HOME"/$tilde}"
    fi
    if [[ -n "$_REDACT_USER" ]]; then
        # The pattern goes through a variable: bash 3.2 keeps literal quotes
        # when a quoted pattern with a slash sits inside "${var//pat/rep}".
        local userhome="/Users/${_REDACT_USER}"
        REDACTED_TEXT="${REDACTED_TEXT//"$userhome"/$tilde}"
    fi
    # A short host name would match ordinary words; only hide real-looking ones.
    if [[ ${#_REDACT_HOST_FULL} -ge 4 ]]; then
        REDACTED_TEXT="${REDACTED_TEXT//"$_REDACT_HOST_FULL"/$hostmark}"
    fi
    if [[ ${#_REDACT_HOST_SHORT} -ge 4 ]]; then
        REDACTED_TEXT="${REDACTED_TEXT//"$_REDACT_HOST_SHORT"/$hostmark}"
    fi
    return 0
}

redact_path() {
    redact_into "$1"
    printf '%s\n' "$REDACTED_TEXT"
}

# redact_file <file> — rewrite a finished text artifact in place.
redact_file() {
    local file="$1" tmp line
    [[ "${REDACT_PATHS:-0}" == "1" && -f "$file" ]] || return 0
    tmp="${file}.redact.$$"
    : > "$tmp" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        redact_into "$line"
        printf '%s\n' "$REDACTED_TEXT" >> "$tmp"
    done < "$file"
    mv -f "$tmp" "$file"
}

# redact_stream — stdin to stdout, redacted when REDACT_PATHS=1.
redact_stream() {
    local line
    if [[ "${REDACT_PATHS:-0}" != "1" ]]; then
        cat
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        redact_into "$line"
        printf '%s\n' "$REDACTED_TEXT"
    done
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
        cleanup_*.log|unreadable_*.txt|size_memo_*.tsv|report_*.md|plan_*.json|journal_*.jsonl) ;;
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

# F14: QUARANTINE_RUN_DIR must be exactly one level below QUARANTINE_ROOT (the
# layout purge and restore enumerate). A stray value used to quarantine files
# into a directory that restore later refuses and purge never sees.
validate_quarantine_run_dir() {
    local root="${QUARANTINE_ROOT:-}" run="${QUARANTINE_RUN_DIR:-}" name

    root="${root%/}"
    case "$run" in
        /*) ;;
        *)
            print_error "Invalid QUARANTINE_RUN_DIR '${run}': must be an absolute path."
            return 1
            ;;
    esac
    case "${run}/" in
        */./*|*/../*)
            print_error "Invalid QUARANTINE_RUN_DIR '${run}': must not contain . or .. segments."
            return 1
            ;;
    esac
    run="${run%/}"
    name="${run#"${root}"/}"
    if [[ -z "$root" || "$run" != "${root}/${name}" || -z "$name" || "$name" == */* ]]; then
        print_error "Invalid QUARANTINE_RUN_DIR '${QUARANTINE_RUN_DIR}': must be a direct child of QUARANTINE_ROOT '${QUARANTINE_ROOT}'."
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
# Two places hold run artifacts:
#   <state>/runs/<run_id>/   a run directory goes when every file in it is
#                            older than the retention, the name is a strict run
#                            id, it is not a link, it is not the current run and
#                            holds nothing but the files the engine writes.
#                            Quarantine run directories are never touched.
#   legacy locations         the LOGS_DIR / REPORTS_DIR overrides and, in a dev
#                            checkout, <program>/logs and <program>/reports
#                            (cleanup_*.log, report_*.md, plan_*.json, ... only).
# Removal is per validated file (no recursive rm).
#
# Echoes the number of run directories and legacy files removed.
rotate_old_artifacts() {
    local max_days="${1:-30}"
    local removed=0
    local candidate dir

    # P0-1: never prune during a dry run.
    if is_dry_run; then
        echo 0
        return 0
    fi

    case "$max_days" in
        ''|*[!0-9]*) return 0 ;;
    esac
    (( max_days == 0 )) && return 0

    removed=$(( removed + $(_rotate_run_dirs "$max_days") ))

    while IFS= read -r dir; do
        [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || continue
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if _rotate_artifact_file "$candidate" "$dir"; then
                removed=$((removed + 1))
            fi
        done < <(find "$dir" -type f \( -name "cleanup_*.log" -o -name "unreadable_*.txt" -o -name "size_memo_*.tsv" \
                    -o -name "report_*.md" -o -name "plan_*.json" -o -name "journal_*.jsonl" \) -mtime +"$max_days" 2>/dev/null)
    done < <(_legacy_artifact_dirs)

    echo "$removed"
}

# The legacy folders that may still hold v3 run artifacts, one per line.
_legacy_artifact_dirs() {
    local d
    d="${MC_LEGACY_LOGS_DIR:-${LOGS_DIR:-}}"
    [[ -z "$d" ]] || printf '%s\n' "$d"
    d="${MC_LEGACY_REPORTS_DIR:-${REPORTS_DIR:-}}"
    [[ -z "$d" ]] || printf '%s\n' "$d"
    if [[ "${MC_PATHS_MODE:-}" == "checkout" && -n "${MC_PROGRAM_DIR:-}" ]]; then
        printf '%s/logs\n%s/reports\n' "${MC_PROGRAM_DIR%/}" "${MC_PROGRAM_DIR%/}"
    fi
    return 0
}

# Files a run directory may hold (see the runtime file table, V4 section 1.3).
_run_dir_file_known() {
    case "$1" in
        engine.log|unreadable.tsv|size_memo.tsv|report.md|plan.json|journal.jsonl|run.json|events.jsonl) return 0 ;;
        *.tmp.*) return 0 ;;
    esac
    return 1
}

# _rotate_run_dirs <days> — prune <state>/runs/<run_id>/; echoes how many run
# directories were removed.
_rotate_run_dirs() {
    local max_days="$1" runs d name entry removed=0 ok
    runs="${MC_STATE_DIR:-}/runs"
    if [[ -z "${MC_STATE_DIR:-}" || ! -d "$runs" || -L "$runs" ]]; then
        echo 0
        return 0
    fi
    # never inside the quarantine
    if [[ -n "${QUARANTINE_ROOT:-}" ]] && path_is_within "$runs" "$QUARANTINE_ROOT"; then
        echo 0
        return 0
    fi
    while IFS= read -r d; do
        [[ -n "$d" && -d "$d" && ! -L "$d" ]] || continue
        name="${d##*/}"
        mc_run_id_valid "$name" || continue
        [[ "$name" != "${RUN_TIMESTAMP:-}" ]] || continue
        [[ "${d%/*}" == "$runs" ]] || continue
        # every file old enough, the directory itself too
        [[ -z "$(find "$d" -type f -mtime -"$max_days" 2>/dev/null | head -n 1)" ]] || continue
        [[ -n "$(find "$d" -maxdepth 0 -mtime +"$max_days" 2>/dev/null)" ]] || continue
        # only known regular files, no links, no sub-directories
        ok=1
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            if [[ -L "$entry" || ! -f "$entry" ]] || ! _run_dir_file_known "${entry##*/}"; then
                ok=0
                break
            fi
        done < <(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null)
        (( ok == 1 )) || continue
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && rm -f "$entry"
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
        if rmdir "$d" 2>/dev/null; then
            removed=$(( removed + 1 ))
        fi
    done < <(find "$runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
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
# A standing advisory (e.g. "do not delete mail via rm"): shown and reported like a
# warning, but it says nothing about how this run went, so it never changes the result.
print_note()    { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; log_info "NOTE: $*"; NOTES_LIST+=("$*"); }
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

# Binary units with binary labels (1 GiB = 1024^3 bytes): the same convention as
# df, the doctor and the terminal interface, so one number never has two names.
bytes_to_human() {
    local bytes="${1:-0}"
    # Guard against non-numeric
    case "$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    if   (( bytes < 1024 )); then
        echo "${bytes} B"
    elif (( bytes < 1048576 )); then
        printf "%.1f KiB" "$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b / 1024}')"
    elif (( bytes < 1073741824 )); then
        printf "%.1f MiB" "$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b / 1048576}')"
    else
        printf "%.2f GiB" "$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b / 1073741824}')"
    fi
}

# Phase 3: unreadable is not empty. macOS can deny access to other apps'
# folders silently; du then exits non-zero and used to make this function
# report 0 bytes. Every location that could not be fully read is recorded in
# a run-scoped file (written from command substitutions too), and the
# summaries report the analysis as partial.
analysis_unreadable_file() {
    # <state>/runs/<run>/unreadable.tsv (legacy LOGS_DIR: unreadable_<run>.txt)
    printf '%s' "${MC_UNREADABLE_FILE:-${TMPDIR:-/tmp}/unreadable_${RUN_TIMESTAMP:-run}.txt}"
}

analysis_record_unreadable() {
    local kind="$1" path="$2" file dir
    file="$(analysis_unreadable_file)"
    dir="${file%/*}"
    [[ -d "$dir" ]] || ( umask 077; mkdir -p "$dir" ) 2>/dev/null || true
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
    # awk reads the whole file: no early-exit pipe that pipefail could turn
    # into a false "not partial".
    P="$1" awk -F'\t' 'substr($0, index($0, "\t") + 1) == ENVIRON["P"] { f = 1 } END { exit !f }' "$file"
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
    if type optional_command_with_timeout >/dev/null 2>&1; then
        # A tree that cannot be measured in time (a hung volume) is "not measured", never 0 bytes.
        du_out=$(optional_command_with_timeout "${SCAN_SIZE_TIMEOUT:-120}" du -sk "$path" 2>/dev/null) || du_rc=$?
    else
        du_out=$(du -sk "$path" 2>/dev/null) || du_rc=$?
    fi
    kb=$(printf '%s\n' "$du_out" | awk 'NR==1{print $1}')
    case "$kb" in
        ''|*[!0-9]*) kb="" ;;
    esac
    if (( du_rc != 0 )); then
        if [[ -n "$kb" ]]; then
            # Partly readable: keep what du could count; it is a lower bound.
            analysis_record_unreadable "partial" "$path"
            size_memo_record "$path" "$(( kb * 1024 ))"
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
    size_memo_record "$path" "$(( kb * 1024 ))"
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

# F13: case-insensitive like is_protected_path (APFS folds case), so an exclude
# typed as ~/.trash/dir/keep still protects ~/.Trash/dir. nocasematch is scoped
# to a subshell.
path_contains_protected_descendant() {
    local candidate="$1"
    local normalized_candidate

    normalized_candidate="$(normalize_path "$candidate" || echo "$candidate")"
    [[ -z "$normalized_candidate" ]] && return 1

    (
        shopt -s nocasematch
        # PF3: use pre-normalized array when available; fallback to per-call.
        if (( ${#_NEVER_TOUCH_NORMALIZED[@]} > 0 )); then
            local normalized_protected
            for normalized_protected in "${_NEVER_TOUCH_NORMALIZED[@]}"; do
                if [[ "$normalized_protected" == "$normalized_candidate/"* ]]; then
                    exit 0
                fi
            done
        elif (( ${#NEVER_TOUCH_PATHS[@]} > 0 )); then
            local protected normalized_protected
            for protected in "${NEVER_TOUCH_PATHS[@]}"; do
                normalized_protected="$(normalize_path "$protected" || echo "$protected")"
                if [[ "$normalized_protected" == "$normalized_candidate/"* ]]; then
                    exit 0
                fi
            done
        fi
        exit 1
    )
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
            mtime=$(python3 -I -c 'import os, sys; print(int(os.path.getmtime(sys.argv[1])))' "$target" 2>/dev/null || echo "0")
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
        APP_BUNDLE_ID_CACHE="$(python3 -I -c "$py_code" "${dirs[@]}" 2>/dev/null)"
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
        pbid="$(python3 -I -c '
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
        local found=""
        if type optional_command_with_timeout >/dev/null 2>&1; then
            found="$(optional_command_with_timeout "${SCAN_TOOL_TIMEOUT:-20}" mdfind "kMDItemCFBundleIdentifier == \"$bundle_id\"" 2>/dev/null)" || found=""
        else
            found="$(mdfind "kMDItemCFBundleIdentifier == \"$bundle_id\"" 2>/dev/null)" || found=""
        fi
        if [[ -n "$found" ]]; then
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
# Sudo: privileged deletion was removed (P0-1b). Nothing here can request it;
# paths that would need it are journalled as *_blocked and reported only.
# ---------------------------------------------------------------------------

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

# json_escape <text> — a JSON string body. Quote, backslash, \n \r \t as usual;
# every other control byte (0x01-0x1f) and DEL become \u00XX (F11), so an odd
# file name cannot make a plan or journal line invalid JSON. Pure Bash 3.2.
json_escape() {
    local s="${1:-}" n oct byte esc
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    case "$s" in
        *[[:cntrl:]]*)
            for n in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 127; do
                printf -v oct '%03o' "$n"
                # shellcheck disable=SC2059  # the format string is the octal escape itself
                printf -v byte "\\${oct}"
                printf -v esc '\\u%04x' "$n"
                s="${s//"$byte"/$esc}"
            done
            ;;
    esac
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
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    # F11: the journal is a shareable artifact; the restore manifest (not the
    # journal) is what restore reads, so the paths here may be redacted.
    redact_into "$path";            path="$REDACTED_TEXT"
    redact_into "$quarantine_path"; quarantine_path="$REDACTED_TEXT"
    redact_into "$message";         message="$REDACTED_TEXT"

    mkdir -p "$(dirname "$journal_file")" 2>/dev/null || return 1
    local line
    line="$(printf '{"ts":"%s","run_id":"%s","action":"%s","category":"%s","path":"%s","quarantine_path":"%s","bytes":%s,"status":"%s","message":"%s"}' \
        "$(json_escape "$ts")" \
        "$(json_escape "$run_id")" \
        "$(json_escape "$action")" \
        "$(json_escape "$category")" \
        "$(json_escape "$path")" \
        "$(json_escape "$quarantine_path")" \
        "$bytes" \
        "$(json_escape "$status")" \
        "$(json_escape "$message")")"
    printf '%s\n' "$line" >> "$journal_file" 2>/dev/null || return 1

    # The quarantine events of this run are kept with the payload they describe
    # (<quarantine>/<run>/journal.jsonl), so a run's history survives the state
    # dir. A failed quarantine intent or "quarantined" row is a metadata
    # failure: the caller rolls the move back.
    case "$action" in
        quarantine_intent|quarantined|quarantine_failed)
            local qjournal
            qjournal="$(quarantine_journal_file)"
            if [[ -n "$qjournal" && -d "${qjournal%/*}" ]]; then
                if ! printf '%s\n' "$line" >> "$qjournal" 2>/dev/null; then
                    [[ "$action" == "quarantine_failed" ]] || return 1
                fi
            fi
            ;;
    esac
    return 0
}

# <quarantine>/<run>/journal.jsonl of this run ("" when there is no run dir).
quarantine_journal_file() {
    if [[ -n "${CLEANUP_QUARANTINE_JOURNAL:-}" ]]; then
        printf '%s' "$CLEANUP_QUARANTINE_JOURNAL"
    elif [[ -n "${QUARANTINE_RUN_DIR:-}" ]]; then
        printf '%s/journal.jsonl' "$QUARANTINE_RUN_DIR"
    fi
}

# quarantine_run_info_ensure — <quarantine>/<run>/run-info.json, written once,
# atomically (temp file + rename): {run_id, created_at, tool_version,
# remove_mode, home}. Returns 1 when it cannot be made durable.
quarantine_run_info_ensure() {
    local file="${CLEANUP_QUARANTINE_RUN_INFO:-${QUARANTINE_RUN_DIR:-}/run-info.json}" tmp ts
    [[ -n "${QUARANTINE_RUN_DIR:-}" ]] || return 1
    if [[ -f "$file" && ! -L "$file" ]]; then
        return 0
    fi
    [[ ! -e "$file" && ! -L "$file" ]] || return 1
    mkdir -p "${file%/*}" 2>/dev/null || return 1
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    tmp="${file}.tmp.$$"
    if printf '{"run_id": "%s", "created_at": "%s", "tool_version": "%s", "remove_mode": "%s", "home": "%s"}\n' \
            "$(json_escape "${QUARANTINE_RUN_DIR##*/}")" "$(json_escape "$ts")" \
            "$(json_escape "${SCRIPT_VERSION:-unknown}")" "$(json_escape "${REMOVE_MODE:-quarantine}")" \
            "$(json_escape "${HOME:-}")" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$file" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# P1-4: one tool→target table for native cleanup commands. The analyzer, the
# planner and plan apply all resolve a command's target here, so a plan op is
# bound to the directory its tool actually cleans. Before, apply accepted
# `npm cache clean --force` with ~/Library/Messages as its path, resolved the
# __brew__ sentinel against the cwd, and never noticed an npmrc/pnpm/pip
# config that moved the cache after the plan was written.
# ---------------------------------------------------------------------------

# Phase 3: _proc_running <pgrep-args...> — true when a matching process runs,
# or when pgrep cannot tell (rc >= 2): unknown counts as running.
_proc_running() {
    local rc=0
    pgrep "$@" >/dev/null 2>&1 || rc=$?
    (( rc != 1 ))
}

# cache_owner_running <dev-item-key> — true while a tool that writes this
# cache is running. Removing a cache under a live build breaks that build.
# Patterns follow what macOS actually shows: npm renames itself "npm exec …",
# so live npx users are found by their ~/.npm/_npx/ command line; pnpm and
# composer usually run as node/php scripts.
cache_owner_running() {
    case "${1:-}" in
        cargo_cache)      _proc_running -x cargo || _proc_running -x rustc ;;
        gradle_cache)     _proc_running -f org.gradle ;;
        cocoapods_cache)  _proc_running -f bin/pod ;;
        swift_pm_cache)   _proc_running -x swift-build || _proc_running -x swift-package \
                              || _proc_running -x xcodebuild || _proc_running -x Xcode ;;
        bundler_cache)    _proc_running -f bin/bundle ;;
        composer_cache)   _proc_running -x composer || _proc_running -f bin/composer || _proc_running -f composer.phar ;;
        npx_cache)        _proc_running -f '\.npm/_npx/' || _proc_running -f 'npm exec' || _proc_running -x npx ;;
        pnpm_stale_store) _proc_running -x pnpm || _proc_running -f '(^|/)pnpm(\.c?js)?( |$)' ;;
        xcode_derived)    _proc_running -x Xcode || _proc_running -x xcodebuild ;;
        sim_runtimes)     _proc_running -x Xcode || _proc_running -x Simulator || _proc_running -x xcodebuild ;;
        *) return 1 ;;
    esac
}

# cache_owner_key_for_path <normalized-path> — the dev-item key of a cache
# path, so plan apply can run the same in-use check as the cleaners.
cache_owner_key_for_path() {
    case "${1:-}" in
        */.npm/_npx|*/.npm/_npx/*)                                  echo npx_cache ;;
        */Library/Developer/Xcode/DerivedData|*/Library/Developer/Xcode/DerivedData/*) echo xcode_derived ;;
        */.gradle|*/.gradle/*)                                      echo gradle_cache ;;
        */.cargo|*/.cargo/*)                                        echo cargo_cache ;;
        */Library/Caches/CocoaPods|*/Library/Caches/CocoaPods/*)    echo cocoapods_cache ;;
        */org.swift.swiftpm|*/org.swift.swiftpm/*)                  echo swift_pm_cache ;;
        */.bundle|*/.bundle/*)                                      echo bundler_cache ;;
        */Library/Caches/composer|*/Library/Caches/composer/*|*/.composer|*/.composer/*) echo composer_cache ;;
        */pnpm/store|*/pnpm/store/*|*/.pnpm-store|*/.pnpm-store/*)  echo pnpm_stale_store ;;
        *) return 1 ;;
    esac
}

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

# _native_in_home <command> [args...] — F5: run a native query or cleanup from
# $HOME, never from the caller's working directory (a project's .npmrc,
# .yarnrc.yml yarnPath or package.json packageManager would steer the tool),
# with corepack's network access and download prompt off. Fails closed (126)
# when HOME cannot be entered. A function name works as the command.
_native_in_home() {
    (
        cd "${HOME:-/nonexistent}" 2>/dev/null || exit 126
        export COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0
        "$@"
    )
}

# native_tool_target <tool> — normalized absolute directory the tool's cleanup
# acts on; fails (no output) when the tool cannot tell.
# _native_target_query <cmd> [args...] — a read-only target query, under the
# native-query deadline when the analyzer's helper is loaded (E-C: these
# queries used to run unbounded at plan, apply and clean time).
_native_target_query() {
    if type native_query_with_timeout >/dev/null 2>&1; then
        _native_in_home native_query_with_timeout "${NATIVE_QUERY_TIMEOUT:-20}" "$*" "$@" </dev/null 2>/dev/null
    else
        _native_in_home "$@" </dev/null 2>/dev/null
    fi
}

native_tool_target() {
    local tool="${1:-}" target_dir="" pip_bin
    case "$tool" in
        npm)   target_dir="$(_native_target_query npm config get cache)" ;;
        yarn)  target_dir="$(_native_target_query yarn cache dir)" ;;
        pnpm)  target_dir="$(_native_target_query pnpm store path)" ;;
        pip)   pip_bin="$(native_pip_bin)" || return 1
               target_dir="$(_native_target_query "$pip_bin" cache dir)" ;;
        brew)  target_dir="$(_native_target_query brew --cache)" ;;
        gem)   target_dir="$(_native_target_query gem env gemdir)" ;;
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
#   kept-newest:     only each disk's newest local snapshot exists; it is kept
#   volumes-unknown: another mounted APFS disk's snapshots could not be listed
#   in-use:          the tool that writes this cache was running
#   failed:          the native cleanup command ran and failed
#   unavailable:     the native cleanup tool is not installed
#   partially-cleaned / nothing-removed: derived by the executor from the
#                    per-item results (F05: consent is not a result)
mark_category_outcome() {
    local key="${1:-}" outcome="${2:-}"
    [[ -n "$key" && -n "$outcome" ]] || return 0
    CLEANUP_CATEGORY_OUTCOMES="${CLEANUP_CATEGORY_OUTCOMES}${key}=${outcome}"$'\n'
}

# _category_outcome_raw <category-key> — the last recorded outcome, unresolved.
_category_outcome_raw() {
    local key="${1:-}" line found=""
    [[ -n "$key" ]] || return 0
    # LAST write wins: mark_category_outcome appends, and a test or a second
    # executor pass in one process may record a category again.
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

# category_outcome <category-key> — echoes the recorded outcome, or nothing.
# E-C: the executor records it from the per-item results (_exc_mark_outcome).
category_outcome() {
    _category_outcome_raw "${1:-}"
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

# F6: the identity, ownership, key-mode and account-home checks use these tools
# by absolute path. With GNU coreutils first on PATH `stat -f` means "filesystem
# status" (the identity check turned vacuous), and a PATH stub of dscl or id
# could name another account. The names are the fallback on a system without
# the macOS locations; there is no override: a test that wants other answers
# changes HOME or the files, not the tools.
_MC_STAT="/usr/bin/stat";         [[ -x "$_MC_STAT" ]] || _MC_STAT="stat"
_MC_ID="/usr/bin/id";             [[ -x "$_MC_ID" ]] || _MC_ID="id"
_MC_DSCL="/usr/bin/dscl";         [[ -x "$_MC_DSCL" ]] || _MC_DSCL=""
_MC_HOSTNAME="/bin/hostname";     [[ -x "$_MC_HOSTNAME" ]] || _MC_HOSTNAME="hostname"
_MC_SHASUM="/usr/bin/shasum";     [[ -x "$_MC_SHASUM" ]] || _MC_SHASUM="shasum"

# plan_path_identity <path> — "dev:inode" of an existing path, else "". Lives
# here (not in the planner) because the restore also compares identities.
plan_path_identity() {
    local id=""
    if [[ -e "${1:-}" || -L "${1:-}" ]]; then
        id="$("$_MC_STAT" -f '%d:%i' "$1" 2>/dev/null)" || id=""
        case "$id" in [0-9]*:[0-9]*) ;; *) id="" ;; esac
    fi
    printf '%s' "$id"
}

# base64_decode_exact <b64> — REPLY = the decoded bytes with trailing newlines
# kept; a $(...) would strip them and name another path (F12).
base64_decode_exact() {
    local out
    out="$(base64_decode_string "${1:-}" || true; printf x)"
    REPLY="${out%x}"
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
RESTORE_INCOMPLETE=0
RESTORE_HARD_FAIL=0

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

# ---------------------------------------------------------------------------
# Real-home consent guard (2026-11-16 incident): a consent answer is never
# read from a pipe against the account's real home folder.
#
# mc_account_home — physical home of the effective user from the account
# database (dscl on macOS, else ~user), independent of $HOME. Fails when it
# cannot be determined.
# ---------------------------------------------------------------------------
MC_EXIT_CONSENT_REFUSED=5

mc_account_home() {
    local user dir=""
    user="$("$_MC_ID" -un 2>/dev/null)" || user=""
    case "$user" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    if [[ -n "$_MC_DSCL" ]]; then
        dir="$("$_MC_DSCL" . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null \
            | awk '/^NFSHomeDirectory:/ { sub(/^NFSHomeDirectory:[ \t]*/, ""); print; exit }')"
    fi
    if [[ -z "$dir" ]]; then
        # ~user expansion reads the passwd database; the name is validated above.
        dir="$(eval "printf '%s' ~${user}")"
    fi
    [[ "$dir" == /* && -d "$dir" ]] || return 1
    (cd -P "$dir" 2>/dev/null && pwd -P)
}

# mc_home_is_throwaway — F7: 0 only when HOME is POSITIVELY a throwaway: its
# physical path lies under /private/var/folders/ or /private/tmp/ (where mktemp
# and the test harness put sandboxes) AND it is not the account's own home, read
# with the absolute-path tools of mc_account_home. Everything else, including an
# account home that cannot be determined, is not a throwaway. A PATH stub of
# dscl or id cannot turn a real home into a throwaway, because the question is
# no longer "is this the real home" but "is this positively a sandbox".
mc_home_is_throwaway() {
    local home_phys acct
    home_phys="$(cd -P "${HOME:-/}" 2>/dev/null && pwd -P)" || return 1
    case "$home_phys" in
        /private/var/folders/?*|/private/tmp/?*) ;;
        *) return 1 ;;
    esac
    acct="$(mc_account_home)" || return 1
    [[ "$home_phys" != "$acct" ]]
}

# mc_consent_guard <context> — call immediately before reading a consent
# answer (and at the start of a restore, an apply or an applied purge). Returns
# 0 when stdin is a terminal or HOME is positively a throwaway (a test sandbox,
# where answers are piped); otherwise the run stops here, before any removal,
# with exit MC_EXIT_CONSENT_REFUSED. Residual risk: a pseudo-terminal wrapper
# (script, expect) makes stdin a terminal and cannot be told from a person.
mc_consent_guard() {
    local context="${1:-prompt}" i cat seen=" "
    [[ -t 0 ]] && return 0
    mc_home_is_throwaway && return 0
    print_error "$(t "consent_no_terminal")"
    log_error "Consent refused (${context}): stdin is not a terminal and HOME is not a throwaway sandbox."
    if type mc_warning >/dev/null 2>&1; then
        mc_warning consent_no_terminal "$(t "consent_no_terminal")"
    fi
    cleanup_journal_event "consent_refused" "" "" 0 "blocked" "${context}: stdin is not a terminal" 2>/dev/null || true
    # Nothing ran: every category that had work is recorded as not done.
    if declare -p PLAN_OP_CATEGORIES >/dev/null 2>&1 && (( ${#PLAN_OP_CATEGORIES[@]} > 0 )); then
        for (( i=0; i<${#PLAN_OP_CATEGORIES[@]}; i++ )); do
            case "${PLAN_OP_ACTIONS[$i]:-}" in remove_path|native_command) ;; *) continue ;; esac
            cat="${PLAN_OP_CATEGORIES[$i]}"
            case "$seen" in *" ${cat} "*) continue ;; esac
            seen="${seen}${cat} "
            mark_category_outcome "$cat" skipped
        done
    fi
    exit "$MC_EXIT_CONSENT_REFUSED"
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

# F14: INT/TERM held back around the quarantine move and the metadata writes
# that make it recoverable, so an item is never left moved with only an intent
# row. The signal is re-raised afterwards and the caller's own handler runs.
_MC_SIG_SAVED_INT=""
_MC_SIG_SAVED_TERM=""
_MC_SIG_PENDING=""
_mc_signals_defer() {
    _MC_SIG_SAVED_INT="$(trap -p INT)"
    _MC_SIG_SAVED_TERM="$(trap -p TERM)"
    _MC_SIG_PENDING=""
    trap '_MC_SIG_PENDING="${_MC_SIG_PENDING} INT"' INT
    trap '_MC_SIG_PENDING="${_MC_SIG_PENDING} TERM"' TERM
}
_mc_signals_release() {
    local sig pending="$_MC_SIG_PENDING"
    _MC_SIG_PENDING=""
    trap - INT TERM
    [[ -z "$_MC_SIG_SAVED_INT" ]] || eval "$_MC_SIG_SAVED_INT"
    [[ -z "$_MC_SIG_SAVED_TERM" ]] || eval "$_MC_SIG_SAVED_TERM"
    for sig in $pending; do
        kill -s "$sig" $$
    done
    return 0
}

quarantine_remove() {
    local target="$1"
    local size="${2:-0}"
    local dest dest_dir
    local journal_file="${CLEANUP_JOURNAL_FILE:-}"
    local manifest="${CLEANUP_RESTORE_MANIFEST:-}"

    # F14: fail closed on a run dir that is not a child of the quarantine root.
    if ! validate_quarantine_run_dir 2>/dev/null; then
        print_warn "Quarantine run directory is invalid; skipping: ${target}"
        record_skipped_item "Quarantine run directory is invalid (fail-closed): ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "" "$size" "failed" "invalid QUARANTINE_RUN_DIR (fail-closed)" || true
        return 1
    fi

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

    if ! metadata_path_is_durable "$manifest" || ! metadata_path_is_durable "$journal_file" \
        || ! metadata_path_is_durable "$(quarantine_journal_file)" || ! quarantine_run_info_ensure; then
        print_warn "Cannot persist quarantine metadata for: ${target}"
        record_skipped_item "Cannot persist quarantine metadata for ${target}"
        if metadata_path_is_durable "$journal_file"; then
            cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "metadata not durable" || true
        fi
        return 1
    fi

    _mc_signals_defer
    if ! cleanup_journal_event "quarantine_intent" "$target" "$dest" "$size" "pending" ""; then
        _mc_signals_release
        print_warn "Could not record quarantine intent for: ${target}"
        record_skipped_item "Cannot record quarantine intent for ${target}"
        return 1
    fi

    if ! mv "$target" "$dest" 2>/dev/null; then
        _mc_signals_release
        print_warn "Could not quarantine: ${target}"
        log_warn "mv to quarantine failed for: ${target}"
        record_skipped_item "Failed to move to quarantine: ${target}"
        cleanup_journal_event "quarantine_failed" "$target" "$dest" "$size" "failed" "mv failed" || true
        return 1
    fi

    if ! cleanup_restore_record "$dest" "$target" "$size"; then
        _quarantine_rollback_move "$dest" "$target" "$size" || true
        _mc_signals_release
        return 1
    fi

    if ! cleanup_journal_event "quarantined" "$target" "$dest" "$size" "ok" ""; then
        _quarantine_rollback_move "$dest" "$target" "$size" 1 || true
        _mc_signals_release
        return 1
    fi

    TOTAL_QUARANTINED_BYTES=$(( TOTAL_QUARANTINED_BYTES + size ))
    TOTAL_QUARANTINED_ITEMS=$(( TOTAL_QUARANTINED_ITEMS + 1 ))
    print_cleaned "Quarantining: ${target} -> ${dest}  ($(bytes_to_human "$size"))"
    _mc_signals_release
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

# ---------------------------------------------------------------------------
# Restore (V4 sections 1.5 and 12.1)
#
# Restore metadata lives in the quarantine run: <quarantine>/<run>/manifest.tsv
# (authoritative, base64 rows "quarantine_path<TAB>original_path<TAB>bytes"),
# journal.jsonl and run-info.json. The manifest is never rewritten: a restored
# row is recorded as {"op":"restore","path":...,"ts":...,"result":...} in the
# run's own journal.jsonl.
# ---------------------------------------------------------------------------

# Candidate folders that may still hold a v3 reports/restore_<run>.tsv, one per
# line: the legacy REPORTS_DIR override, <state>/legacy/reports (where
# layout_migrate.py copies orphans) and, in a dev checkout, <program>/reports.
_restore_legacy_dirs() {
    local d="${MC_LEGACY_REPORTS_DIR:-${REPORTS_DIR:-}}"
    [[ -z "$d" ]] || printf '%s\n' "$d"
    [[ -z "${MC_STATE_DIR:-}" ]] || printf '%s/legacy/reports\n' "${MC_STATE_DIR%/}"
    if [[ "${MC_PATHS_MODE:-}" == "checkout" && -n "${MC_PROGRAM_DIR:-}" ]]; then
        printf '%s/reports\n' "${MC_PROGRAM_DIR%/}"
    fi
    return 0
}

# A run id (or file name) that cannot leave the quarantine root.
_restore_name_safe() {
    case "${1:-}" in
        ''|.|..|.*|*/*|*[[:cntrl:]]*) return 1 ;;
    esac
    return 0
}

# The manifest of quarantine run <id>: the run's own manifest.tsv, else a v3
# restore_<id>.tsv in a legacy folder. Prints the path.
_restore_manifest_for_run() {
    local id="$1" m dir
    m="${QUARANTINE_ROOT}/${id}/manifest.tsv"
    if [[ -f "$m" && ! -L "$m" ]]; then
        printf '%s\n' "$m"
        return 0
    fi
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if [[ -f "${dir}/restore_${id}.tsv" && ! -L "${dir}/restore_${id}.tsv" ]]; then
            printf '%s\n' "${dir}/restore_${id}.tsv"
            return 0
        fi
    done < <(_restore_legacy_dirs)
    return 1
}

# restore_journal_has <quarantine-run-dir> <original-path> — the run's journal
# records that path as restored.
restore_journal_has() {
    local journal="${1}/journal.jsonl" esc
    [[ -f "$journal" ]] || return 1
    esc="$(json_escape "$2")"
    grep -F -e "\"op\":\"restore\",\"path\":\"${esc}\"," "$journal" 2>/dev/null \
        | grep -q '"result":"restored"'
}

# restore_journal_record <quarantine-run-dir> <original-path> <result> [reason]
# Appends one {"op":"restore",...} line to that run's journal.jsonl. The paths
# are real (not redacted): they are what later restores match against.
restore_journal_record() {
    local qrun="$1" path="$2" result="$3" reason="${4:-}" ts line
    [[ -d "$qrun" ]] || return 1
    ts="$(date +%s 2>/dev/null)" || ts=0
    line="$(printf '{"op":"restore","path":"%s","ts":%s,"result":"%s"' "$(json_escape "$path")" "$ts" "$(json_escape "$result")")"
    [[ -z "$reason" ]] || line="${line},\"reason\":\"$(json_escape "$reason")\""
    printf '%s}\n' "$line" >> "${qrun}/journal.jsonl" 2>/dev/null
}

# The quarantine run directory a payload path belongs to.
_restore_run_of_source() {
    local src="$1" root rest
    root="$(normalize_path "$QUARANTINE_ROOT" || echo "$QUARANTINE_ROOT")"
    rest="${src#"${root}"/}"
    [[ "$rest" != "$src" ]] || return 1
    printf '%s/%s\n' "$root" "${rest%%/*}"
}

# True when <manifest> has at least one row whose payload is still in the
# quarantine and is not recorded as restored.
_restore_manifest_restorable() {
    local manifest="$1" q_b64 p_b64 bytes src orig qrun
    while IFS=$'\t' read -r q_b64 p_b64 bytes || [[ -n "${q_b64:-}${p_b64:-}" ]]; do
        [[ -n "${q_b64:-}" && -n "${p_b64:-}" ]] || continue
        src="$(base64_decode_string "$q_b64" || true)"
        orig="$(base64_decode_string "$p_b64" || true)"
        [[ -n "$src" && -n "$orig" ]] || continue
        [[ -e "$src" || -L "$src" ]] || continue
        qrun="$(_restore_run_of_source "$src" 2>/dev/null)" || qrun=""
        if [[ -n "$qrun" ]] && restore_journal_has "$qrun" "$orig"; then
            continue
        fi
        return 0
    done < "$manifest"
    return 1
}

# The newest RESTORABLE run: run folders newest first (run ids sort by time),
# each with its manifest; then, as a last resort, legacy manifests newest first
# (their payload may sit in a run folder with another name).
_restore_latest_manifest() {
    local run id m dir
    if [[ -d "$QUARANTINE_ROOT" ]]; then
        while IFS= read -r run; do
            [[ -d "$run" && ! -L "$run" ]] || continue
            id="${run##*/}"
            m="$(_restore_manifest_for_run "$id")" || continue
            if _restore_manifest_restorable "$m"; then
                printf '%s\n' "$m"
                return 0
            fi
        done < <(find "$QUARANTINE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort -r)
    fi
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        # shellcheck disable=SC2012
        while IFS= read -r m; do
            [[ -n "$m" && -f "$m" ]] || continue
            if _restore_manifest_restorable "$m"; then
                printf '%s\n' "$m"
                return 0
            fi
        done < <(ls -t "${dir}"/restore_*.tsv 2>/dev/null || true)
    done < <(_restore_legacy_dirs)
    return 1
}

# resolve_restore_manifest <run_id|latest|file> — prints the manifest path.
# Order (V4 section 1.5): the run's own manifest.tsv; "latest" = the newest
# restorable run; a file path; legacy restore_<id>.tsv in the legacy folders.
resolve_restore_manifest() {
    local requested="${1:-}" candidate dir
    [[ -z "$requested" ]] && return 1

    if [[ "$requested" == "latest" ]]; then
        candidate="$(_restore_latest_manifest)" || return 1
        normalize_path "$candidate" || echo "$candidate"
        return 0
    fi

    if _restore_name_safe "$requested"; then
        candidate="${QUARANTINE_ROOT}/${requested}/manifest.tsv"
        if [[ -f "$candidate" && ! -L "$candidate" ]]; then
            normalize_path "$candidate" || echo "$candidate"
            return 0
        fi
    fi

    if [[ -f "$requested" ]]; then
        normalize_path "$requested" || echo "$requested"
        return 0
    fi

    if _restore_name_safe "$requested"; then
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            for candidate in "${dir}/restore_${requested}.tsv" "${dir}/${requested}"; do
                if [[ -f "$candidate" && ! -L "$candidate" ]]; then
                    normalize_path "$candidate" || echo "$candidate"
                    return 0
                fi
            done
        done < <(_restore_legacy_dirs)
    fi
    return 1
}

# Parsed manifest rows (decoded, normalized), index-aligned.
RESTORE_ROW_SRC=()
RESTORE_ROW_ORIG=()
RESTORE_ROW_BYTES=()
RESTORE_ROW_SEL=()
RESTORE_ROW_DONE=()
RESTORE_RUN_ID=""

_restore_load_rows() {
    local manifest="$1" q_b64 p_b64 bytes source_path target_path n=0
    RESTORE_ROW_SRC=(); RESTORE_ROW_ORIG=(); RESTORE_ROW_BYTES=(); RESTORE_ROW_SEL=(); RESTORE_ROW_DONE=()
    while IFS=$'\t' read -r q_b64 p_b64 bytes || [[ -n "${q_b64:-}${p_b64:-}${bytes:-}" ]]; do
        [[ -z "${q_b64:-}" || -z "${p_b64:-}" ]] && continue
        source_path="$(base64_decode_string "$q_b64" || true)"
        target_path="$(base64_decode_string "$p_b64" || true)"
        if [[ -z "$source_path" || -z "$target_path" ]]; then
            record_skipped_item "Invalid restore record in ${manifest}"
            continue
        fi
        case "${bytes:-0}" in ''|*[!0-9]*) bytes=0 ;; esac
        RESTORE_ROW_SRC[$n]="$(normalize_path "$source_path" || echo "$source_path")"
        RESTORE_ROW_ORIG[$n]="$(normalize_path "$target_path" || echo "$target_path")"
        RESTORE_ROW_BYTES[$n]="$bytes"
        RESTORE_ROW_SEL[$n]=1
        RESTORE_ROW_DONE[$n]=0
        n=$(( n + 1 ))
    done < "$manifest"
    RESTORE_ROW_COUNT="$n"
    RESTORE_RUN_ID=""
    if (( n > 0 )); then
        local qrun
        qrun="$(_restore_run_of_source "${RESTORE_ROW_SRC[0]}" 2>/dev/null)" || qrun=""
        [[ -z "$qrun" ]] || RESTORE_RUN_ID="${qrun##*/}"
    fi
    if [[ -z "$RESTORE_RUN_ID" ]]; then
        RESTORE_RUN_ID="${manifest##*/}"
        RESTORE_RUN_ID="${RESTORE_RUN_ID#restore_}"; RESTORE_RUN_ID="${RESTORE_RUN_ID%.tsv}"
    fi
    return 0
}
RESTORE_ROW_COUNT=0

# Mark rows that the run's journal records as restored (the manifest itself is
# never rewritten).
_restore_mark_done() {
    local i qrun
    i=0
    while (( i < RESTORE_ROW_COUNT )); do
        qrun="$(_restore_run_of_source "${RESTORE_ROW_SRC[$i]}" 2>/dev/null)" || qrun=""
        if [[ -n "$qrun" ]] && restore_journal_has "$qrun" "${RESTORE_ROW_ORIG[$i]}"; then
            RESTORE_ROW_DONE[$i]=1
        fi
        i=$(( i + 1 ))
    done
}

# --items-file validation (V4 section 12.1). Fails closed before anything is
# touched: every listed path must name exactly one not-yet-restored manifest
# row; an unknown, duplicate, relative, control-character or already-restored
# line refuses the whole restore (return 2, message names the line).
_restore_apply_items_file() {
    local file="$1" line n=0 i matches seen=$'\n' only_row
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        print_error "Items file not found or unreadable: ${file}"
        return 2
    fi
    i=0
    while (( i < RESTORE_ROW_COUNT )); do RESTORE_ROW_SEL[$i]=0; i=$(( i + 1 )); done
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$(( n + 1 ))
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue
        case "$line" in
            *[[:cntrl:]]*)
                print_error "Items file line ${n}: contains a control character."
                return 2 ;;
            /*) ;;
            *)
                print_error "Items file line ${n}: not an absolute path: ${line}"
                return 2 ;;
        esac
        case "$seen" in
            *$'\n'"$line"$'\n'*)
                print_error "Items file line ${n}: duplicate path: ${line}"
                return 2 ;;
        esac
        seen="${seen}${line}"$'\n'
        matches=0; only_row=-1
        i=0
        while (( i < RESTORE_ROW_COUNT )); do
            if [[ "${RESTORE_ROW_ORIG[$i]}" == "$line" ]]; then
                if (( RESTORE_ROW_DONE[i] == 1 )); then
                    print_error "Items file line ${n}: already restored: ${line}"
                    return 2
                fi
                matches=$(( matches + 1 )); only_row="$i"
            fi
            i=$(( i + 1 ))
        done
        if (( matches == 0 )); then
            print_error "Items file line ${n}: not in this run's manifest: ${line}"
            return 2
        fi
        if (( matches > 1 )); then
            print_error "Items file line ${n}: matches ${matches} manifest rows, refusing to guess: ${line}"
            return 2
        fi
        RESTORE_ROW_SEL[$only_row]=1
    done < "$file"
    # An items file with no paths at all restores nothing: that is a mistake.
    i=0; matches=0
    while (( i < RESTORE_ROW_COUNT )); do
        (( RESTORE_ROW_SEL[i] == 1 )) && matches=$(( matches + 1 ))
        i=$(( i + 1 ))
    done
    if (( matches == 0 )); then
        print_error "Items file lists no paths."
        return 2
    fi
    return 0
}

# Decide what restoring one row would do, without touching anything. Sets:
#   RESTORE_STATE   free | exists | parent_missing | blocked | done
#   RESTORE_REASON  "" | destination_exists | parent_missing | protected_path | not_found | unknown
#   RESTORE_EVENT / RESTORE_WHY / RESTORE_WARN / RESTORE_SKIPREC  (journal action,
#   journal message, console warning, skipped-item note for the executing path)
_restore_classify() {
    local source_norm="$1" target_norm="$2" quarantine_root_norm anc home_norm
    quarantine_root_norm="$(normalize_path "$QUARANTINE_ROOT" || echo "$QUARANTINE_ROOT")"
    RESTORE_STATE="free"; RESTORE_REASON=""; RESTORE_EVENT=""; RESTORE_WHY=""; RESTORE_WARN=""; RESTORE_SKIPREC=""

    case "$source_norm" in
        "$quarantine_root_norm"/*/items/*) ;;
        *)
            RESTORE_STATE="blocked"; RESTORE_REASON="unknown"; RESTORE_EVENT="restore_blocked"
            RESTORE_WHY="source outside quarantine items"
            RESTORE_WARN="Skipping source outside quarantine items directory: ${source_norm}"
            RESTORE_SKIPREC="Restore source outside quarantine items: ${source_norm}"
            return 0 ;;
    esac

    if [[ "$source_norm" == "$quarantine_root_norm" ]]; then
        RESTORE_STATE="blocked"; RESTORE_REASON="unknown"; RESTORE_EVENT="restore_blocked"
        RESTORE_WHY="source is quarantine root"
        RESTORE_WARN="Skipping dangerous restore source: ${source_norm}"
        RESTORE_SKIPREC="Dangerous restore source: ${source_norm}"
        return 0
    fi

    if ! path_is_within "$source_norm" "$QUARANTINE_ROOT"; then
        RESTORE_STATE="blocked"; RESTORE_REASON="unknown"; RESTORE_EVENT="restore_blocked"
        RESTORE_WHY="source outside quarantine"
        RESTORE_WARN="Skipping source outside quarantine: ${source_norm}"
        RESTORE_SKIPREC="Restore source outside quarantine: ${source_norm}"
        return 0
    fi

    if is_protected_path "$target_norm" || path_contains_protected_descendant "$target_norm"; then
        RESTORE_STATE="blocked"; RESTORE_REASON="protected_path"; RESTORE_EVENT="restore_blocked"
        RESTORE_WHY="target protected"
        RESTORE_WARN="Skipping restore to protected path: ${target_norm}"
        RESTORE_SKIPREC="Restore to protected path: ${target_norm}"
        return 0
    fi

    if ! is_user_space_path "$target_norm"; then
        RESTORE_STATE="blocked"; RESTORE_REASON="protected_path"; RESTORE_EVENT="restore_blocked"
        RESTORE_WHY="target outside user scope"
        RESTORE_WARN="Skipping restore outside user directory: ${target_norm}"
        RESTORE_SKIPREC="Restore outside HOME: ${target_norm}"
        return 0
    fi

    # Already restored by an earlier run: not a failure of this one.
    if [[ ! -e "$source_norm" && ! -L "$source_norm" ]] && [[ -e "$target_norm" || -L "$target_norm" ]]; then
        RESTORE_STATE="done"; RESTORE_REASON="destination_exists"
        return 0
    fi

    if [[ ! -e "$source_norm" && ! -L "$source_norm" ]]; then
        RESTORE_STATE="blocked"; RESTORE_REASON="not_found"; RESTORE_EVENT="restore_missing"
        RESTORE_WHY="source missing"
        RESTORE_WARN="Quarantine file does not exist: ${source_norm}"
        RESTORE_SKIPREC="Quarantine file does not exist: ${source_norm}"
        return 0
    fi

    # Never overwrite.
    if [[ -e "$target_norm" || -L "$target_norm" ]]; then
        RESTORE_STATE="exists"; RESTORE_REASON="destination_exists"; RESTORE_EVENT="restore_conflict"
        RESTORE_WHY="target exists"
        RESTORE_WARN="Target path already exists, skipping: ${target_norm}"
        RESTORE_SKIPREC="Restore conflict: ${target_norm}"
        return 0
    fi

    if path_has_symlink_ancestor_under_home "$target_norm"; then
        RESTORE_STATE="blocked"; RESTORE_REASON="protected_path"; RESTORE_EVENT="restore_blocked"
        RESTORE_WHY="target has symlink ancestor"
        RESTORE_WARN="Skipping restore through symlinked parent directory: ${target_norm}"
        RESTORE_SKIPREC="Restore through symlinked parent directory: ${target_norm}"
        return 0
    fi

    # Missing parents are created only inside the original path's existing
    # ancestors under HOME (a regular directory, no link).
    anc="$(dirname "$target_norm")"
    home_norm="$(normalize_path "$HOME" || echo "$HOME")"
    while [[ ! -e "$anc" && ! -L "$anc" && "$anc" != "/" && "$anc" != "$home_norm" ]]; do
        anc="$(dirname "$anc")"
    done
    if [[ ! -d "$anc" || -L "$anc" ]] || { [[ "$anc" != "$home_norm" ]] && ! is_user_space_path "$anc"; } || [[ ! -w "$anc" ]]; then
        RESTORE_STATE="parent_missing"; RESTORE_REASON="parent_missing"; RESTORE_EVENT="restore_failed"
        RESTORE_WHY="parent directory cannot be created"
        RESTORE_WARN="Cannot create target directory: $(dirname "$target_norm")"
        RESTORE_SKIPREC="Cannot create directory for restore: ${target_norm}"
        return 0
    fi
    return 0
}

# Refresh REPLY-style outputs for a run listing; used by --list-quarantine.
# restore_items_summary <manifest> sets RESTORE_SUM_TOTAL / _RESTORED / _BYTES_LEFT.
restore_items_summary() {
    local manifest="$1" q_b64 p_b64 bytes src orig qrun
    RESTORE_SUM_TOTAL=0; RESTORE_SUM_RESTORED=0; RESTORE_SUM_BYTES_LEFT=0
    [[ -f "$manifest" ]] || return 0
    while IFS=$'\t' read -r q_b64 p_b64 bytes || [[ -n "${q_b64:-}${p_b64:-}" ]]; do
        [[ -n "${q_b64:-}" && -n "${p_b64:-}" ]] || continue
        RESTORE_SUM_TOTAL=$(( RESTORE_SUM_TOTAL + 1 ))
        src="$(base64_decode_string "$q_b64" || true)"
        orig="$(base64_decode_string "$p_b64" || true)"
        qrun="$(_restore_run_of_source "$src" 2>/dev/null)" || qrun=""
        if [[ -n "$qrun" && -n "$orig" ]] && restore_journal_has "$qrun" "$orig"; then
            RESTORE_SUM_RESTORED=$(( RESTORE_SUM_RESTORED + 1 ))
        else
            case "${bytes:-0}" in ''|*[!0-9]*) bytes=0 ;; esac
            RESTORE_SUM_BYTES_LEFT=$(( RESTORE_SUM_BYTES_LEFT + bytes ))
        fi
    done < "$manifest"
}
RESTORE_SUM_TOTAL=0; RESTORE_SUM_RESTORED=0; RESTORE_SUM_BYTES_LEFT=0

# Common front half of restore and its preview: resolve, load, drop what is
# already restored, apply --items-file. Returns 2 (message printed) on failure.
_restore_prepare() {
    local requested="$1" manifest
    manifest="$(resolve_restore_manifest "$requested" 2>/dev/null || true)"
    if [[ -z "$manifest" ]]; then
        if [[ "$requested" == "latest" ]]; then
            print_error "No restorable quarantine run found."
        else
            print_error "Restore manifest not found: ${requested}"
        fi
        return 2
    fi
    RESTORE_MANIFEST_PATH="$manifest"
    _restore_load_rows "$manifest"
    _restore_mark_done
    if [[ -n "${RESTORE_ITEMS_FILE:-}" ]]; then
        _restore_apply_items_file "$RESTORE_ITEMS_FILE" || return 2
    fi
    return 0
}
RESTORE_MANIFEST_PATH=""
RESTORE_ITEMS_FILE=""

# restore_preview — what restoring would do. Never changes anything. Output:
# one line per item, or (as_json=1) the JSON object of section 12.1.
restore_preview() {
    local requested="$1" as_json="${2:-0}" i n_restore=0 n_skip=0 bytes_restore=0 first=1 action reason state
    _restore_prepare "$requested" || return 2
    if (( as_json )); then
        printf '{\n  "run_id": "%s",\n  "items": [' "$(json_escape "$RESTORE_RUN_ID")"
    else
        print_info "Restore preview for run ${RESTORE_RUN_ID} (nothing is changed)"
    fi
    i=0
    while (( i < RESTORE_ROW_COUNT )); do
        if (( RESTORE_ROW_SEL[i] == 1 && RESTORE_ROW_DONE[i] == 0 )); then
            _restore_classify "${RESTORE_ROW_SRC[$i]}" "${RESTORE_ROW_ORIG[$i]}"
            state="$RESTORE_STATE"; reason="$RESTORE_REASON"
            if [[ "$state" == "done" ]]; then state="exists"; fi
            if [[ "$state" == "free" ]]; then
                action="restore"; reason=""
                n_restore=$(( n_restore + 1 )); bytes_restore=$(( bytes_restore + RESTORE_ROW_BYTES[i] ))
            else
                action="skip"
                n_skip=$(( n_skip + 1 ))
            fi
            if (( as_json )); then
                (( first )) || printf ','
                first=0
                printf '\n    {"path": "%s", "bytes": %s, "category": null, "destination_state": "%s", "action": "%s"' \
                    "$(json_escape "${RESTORE_ROW_ORIG[$i]}")" "${RESTORE_ROW_BYTES[$i]}" "$state" "$action"
                [[ -z "$reason" ]] || printf ', "reason": "%s"' "$reason"
                printf '}'
            else
                printf '  %-8s %-14s %s%s\n' "$action" "$state" "${RESTORE_ROW_ORIG[$i]}" "${reason:+  ($reason)}"
            fi
        fi
        i=$(( i + 1 ))
    done
    if (( as_json )); then
        printf '\n  ],\n  "totals": {"items": %s, "restorable": %s, "skipped": %s, "restorable_bytes": %s}\n}\n' \
            "$(( n_restore + n_skip ))" "$n_restore" "$n_skip" "$bytes_restore"
    else
        print_info "${n_restore} item(s) would be restored, ${n_skip} skipped, $(bytes_to_human "$bytes_restore") to restore."
    fi
    return 0
}

restore_quarantine_manifest() {
    local requested="$1"

    # P0-1: restore moves files; its preview is restore_preview.
    if is_dry_run; then
        print_error "Restore refused: a dry run is in effect."
        return 2
    fi

    # P2: a row that is not restored (blocked, conflict, failure) marks the
    # restore incomplete; run_restore_phase reports it and exits 1.
    local _skipped_before="${TOTAL_SKIPPED_ITEMS:-0}"
    RESTORE_INCOMPLETE=0
    RESTORE_HARD_FAIL=0     # 1 when a row could not be restored for a reason other than a skip

    _restore_prepare "$requested" || return 2
    local manifest="$RESTORE_MANIFEST_PATH"

    if [[ "$requested" == "latest" ]]; then
        print_info "Restoring quarantine from latest restorable run (run ID: ${RESTORE_RUN_ID}): ${manifest}"
    else
        print_info "Restoring quarantine from manifest: ${manifest}"
    fi

    local i source_norm target_norm bytes actual_size qrun n_sel=0 t0=$SECONDS ev_id ev_res ev_rsn src_ident nested
    # Events (V4 §3): the restore pseudo-group, one item per selected row.
    for (( i=0; i<RESTORE_ROW_COUNT; i++ )); do
        (( RESTORE_ROW_SEL[i] == 1 )) && n_sel=$(( n_sel + 1 ))
    done
    mc_group_start restore clean
    mc_group_total restore "$n_sel"
    RESTORE_TOUCHED_RUNS=$'\n'
    i=0
    while (( i < RESTORE_ROW_COUNT )); do
        if (( RESTORE_ROW_SEL[i] != 1 )); then
            i=$(( i + 1 )); continue
        fi
        source_norm="${RESTORE_ROW_SRC[$i]}"
        target_norm="${RESTORE_ROW_ORIG[$i]}"
        bytes="${RESTORE_ROW_BYTES[$i]}"
        qrun="$(_restore_run_of_source "$source_norm" 2>/dev/null)" || qrun=""
        if [[ -n "$qrun" ]]; then
            case $'\n'"$RESTORE_TOUCHED_RUNS" in *$'\n'"$qrun"$'\n'*) ;; *) RESTORE_TOUCHED_RUNS="${RESTORE_TOUCHED_RUNS}${qrun}"$'\n' ;; esac
        fi
        ev_id="$(printf 'op-%04d' $(( i + 1 )))"
        redact_into "$target_norm"
        mc_item_start restore "$ev_id" "${target_norm##*/}" "$REDACTED_TEXT" "$bytes" remove quarantine
        mc_item_progress restore "$ev_id" moving
        ev_res="skipped"; ev_rsn="unknown"

        if (( RESTORE_ROW_DONE[i] == 1 )); then
            print_skip "Already restored: ${target_norm}"
            mc_item_end restore "$ev_id" skipped destination_exists "$bytes" 0 "" "${target_norm##*/}"
            i=$(( i + 1 )); continue
        fi

        _restore_classify "$source_norm" "$target_norm"
        case "$RESTORE_STATE" in
            done)
                print_skip "Already restored: ${target_norm}"
                ev_rsn="destination_exists"
                ;;
            blocked|exists|parent_missing)
                ev_rsn="${RESTORE_REASON:-unknown}"
                print_warn "$RESTORE_WARN"
                record_skipped_item "$RESTORE_SKIPREC"
                cleanup_journal_event "$RESTORE_EVENT" "$target_norm" "$source_norm" "$bytes" "${RESTORE_EVENT#restore_}" "$RESTORE_WHY"
                [[ -z "$qrun" ]] || restore_journal_record "$qrun" "$target_norm" "skipped" "$RESTORE_REASON" || true
                ;;
            *)
                if ! mkdir -p "$(dirname "$target_norm")" 2>/dev/null; then
                    print_warn "Cannot create target directory: $(dirname "$target_norm")"
                    record_skipped_item "Cannot create directory for restore: ${target_norm}"
                    RESTORE_HARD_FAIL=1
                    cleanup_journal_event "restore_failed" "$target_norm" "$source_norm" "$bytes" "failed" "mkdir failed"
                    mc_item_end restore "$ev_id" failed parent_missing "$bytes" 0 "" "${target_norm##*/}"
                    i=$(( i + 1 )); continue
                fi
                actual_size="$(path_size_bytes "$source_norm")"
                # F9: never overwrite. mv -n refuses an existing file; a
                # directory that appeared since the check would receive the
                # item instead, which the identity check below detects and
                # undoes. A restore is only reported when the target IS the
                # quarantined item.
                src_ident="$(plan_path_identity "$source_norm")"
                mv -n "$source_norm" "$target_norm" 2>/dev/null || true
                if [[ -n "$src_ident" && ! -e "$source_norm" && ! -L "$source_norm" \
                    && "$(plan_path_identity "$target_norm")" == "$src_ident" ]]; then
                    TOTAL_RESTORED_BYTES=$(( TOTAL_RESTORED_BYTES + actual_size ))
                    TOTAL_RESTORED_ITEMS=$(( TOTAL_RESTORED_ITEMS + 1 ))
                    print_cleaned "Restored: ${target_norm}  ($(bytes_to_human "$actual_size"))"
                    cleanup_journal_event "restored" "$target_norm" "$source_norm" "$actual_size" "ok" ""
                    ev_res="restored"; ev_rsn=""
                    if [[ -z "$qrun" ]] || ! restore_journal_record "$qrun" "$target_norm" "restored"; then
                        log_warn "Restore bookkeeping could not be written for: ${target_norm}"
                    fi
                elif [[ -e "$target_norm" || -L "$target_norm" ]]; then
                    nested="${target_norm}/${source_norm##*/}"
                    if [[ -n "$src_ident" && ! -e "$source_norm" && ! -L "$source_norm" \
                        && "$(plan_path_identity "$nested")" == "$src_ident" ]]; then
                        mv -n "$nested" "$source_norm" 2>/dev/null || true
                    fi
                    print_warn "Target path already exists, skipping: ${target_norm}"
                    record_skipped_item "Restore conflict: ${target_norm}"
                    cleanup_journal_event "restore_conflict" "$target_norm" "$source_norm" "$bytes" "conflict" "target appeared during restore"
                    [[ -z "$qrun" ]] || restore_journal_record "$qrun" "$target_norm" "skipped" "destination_exists" || true
                    ev_res="skipped"; ev_rsn="destination_exists"
                else
                    print_warn "Failed to restore: ${target_norm}"
                    record_skipped_item "Failed to restore: ${target_norm}"
                    # shellcheck disable=SC2034  # read by json_summary.sh and cleanup_all.sh (_mc_events_end)
                    RESTORE_HARD_FAIL=1
                    cleanup_journal_event "restore_failed" "$target_norm" "$source_norm" "$bytes" "failed" "mv failed"
                    ev_res="failed"; ev_rsn="unknown"
                fi
                ;;
        esac
        mc_item_end restore "$ev_id" "$ev_res" "$ev_rsn" "$bytes" 0 "" "${target_norm##*/}"
        i=$(( i + 1 ))
    done
    mc_group_end restore clean $(( SECONDS - t0 ))
    _restore_remove_emptied_runs
    if (( ${TOTAL_SKIPPED_ITEMS:-0} > _skipped_before )); then
        # shellcheck disable=SC2034  # read by run_restore_phase in cleanup_all.sh
        RESTORE_INCOMPLETE=1
    fi
    return 0
}

# _restore_remove_emptied_runs — a quarantine run that a restore has emptied has
# nothing left to restore from: remove its folder (the run stays in History, which
# lives in the state folder). Only a real run folder whose items/ exists and holds
# no file, link or other non-directory entry is removed; one skipped item keeps
# its run. The removal is the purge path's own (direct_remove), never a quarantine move.
RESTORE_TOUCHED_RUNS=""
_restore_remove_emptied_runs() {
    local run size cleaned_before
    while IFS= read -r run; do
        [[ -n "$run" ]] || continue
        is_quarantine_run_dir "$run" || continue
        [[ -d "$run/items" && ! -L "$run/items" ]] || continue
        [[ -z "$(find "$run/items" ! -type d -print -quit 2>/dev/null)" ]] || continue
        size="$(path_size_bytes "$run")"
        cleaned_before="${TOTAL_CLEANED_BYTES:-0}"
        if direct_remove "$run" "$size" 0 "restore_emptied_run"; then
            print_info "Quarantine run ${run##*/} has nothing left to restore and was removed."
        fi
        TOTAL_CLEANED_BYTES="$cleaned_before"      # a restore frees nothing: its summary says so

    done <<EOF
${RESTORE_TOUCHED_RUNS}
EOF
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
    local dir size id state m ld

    print_info "Quarantine: ${QUARANTINE_ROOT}"

    if [[ ! -d "$QUARANTINE_ROOT" ]]; then
        print_skip "Quarantine directory does not exist."
        return 0
    fi

    for dir in "${QUARANTINE_ROOT}"/*; do
        [[ -d "$dir" ]] || continue
        count=$(( count + 1 ))
        id="${dir##*/}"
        size="$(path_size_bytes "$dir")"
        state="missing"; m=""
        if [[ -f "${dir}/manifest.tsv" && ! -L "${dir}/manifest.tsv" ]]; then
            state="ok"; m="${dir}/manifest.tsv"
        else
            while IFS= read -r ld; do
                [[ -n "$ld" ]] || continue
                if [[ -f "${ld}/restore_${id}.tsv" && ! -L "${ld}/restore_${id}.tsv" ]]; then
                    state="legacy"; m="${ld}/restore_${id}.tsv"
                    break
                fi
            done < <(_restore_legacy_dirs)
        fi
        if [[ -n "$m" ]]; then
            restore_items_summary "$m"
            if (( RESTORE_SUM_TOTAL > 0 && RESTORE_SUM_RESTORED >= RESTORE_SUM_TOTAL )); then
                print_found "${id}  $(bytes_to_human "$size")  manifest: ${state}  empty (all ${RESTORE_SUM_TOTAL} restored)  ${dir}"
            else
                print_found "${id}  $(bytes_to_human "$size")  manifest: ${state}  items: ${RESTORE_SUM_TOTAL}  restored: ${RESTORE_SUM_RESTORED}  remaining: $(bytes_to_human "$RESTORE_SUM_BYTES_LEFT")  ${dir}"
            fi
        else
            print_found "${id}  $(bytes_to_human "$size")  manifest: ${state}  ${dir}"
        fi
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

    # The run folder holds its own manifest, journal and run-info, so the
    # metadata goes with it: no orphans.
    local ev_id="${normalized##*/}"
    redact_into "$normalized"
    mc_item_start purge "$ev_id" "$ev_id" "$REDACTED_TEXT" "$size" remove none
    mc_item_progress purge "$ev_id" running
    if direct_remove "$normalized" "$size" 0 "purged_quarantine"; then
        cleanup_journal_event "purged" "$normalized" "" "$size" "ok" "run ${normalized##*/} removed with its restore metadata"
        mc_item_end purge "$ev_id" cleaned "" "$size" "$size" "" "$ev_id"
        return 0
    fi
    mc_item_end purge "$ev_id" failed unknown "$size" 0 "" "$ev_id"
    return 1
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
        (( failures == 0 )) || return 1
        return 0
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
        (( failures == 0 )) || return 1
        return 0
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
#
# Result contract (V4 §3.2, §6.2): before every return safe_remove sets
#   MC_LAST_RESULT  cleaned | quarantined | skipped | failed | dry_run
#   MC_LAST_REASON  "" when the item was removed, else a reason code
#                   (protected_path, not_found, needs_permanent, unreadable,
#                   permission_denied, unknown)
#   MC_LAST_FREED   bytes, measured on the same path before and after; 0
#                   unless something was removed
# The executor turns these into item_end events and category outcomes.
# execute_plan_native_command sets the same three (result unavailable when
# the tool is missing).
# ---------------------------------------------------------------------------
MC_LAST_RESULT=""
MC_LAST_REASON=""
MC_LAST_FREED=0

# _mc_last <result> <reason> [freed]
# shellcheck disable=SC2034  # MC_LAST_* are read by lib/executor.sh
_mc_last() {
    MC_LAST_RESULT="$1"
    MC_LAST_REASON="$2"
    MC_LAST_FREED="${3:-0}"
    case "$MC_LAST_FREED" in ''|*[!0-9]*) MC_LAST_FREED=0 ;; esac
}

# _mc_freed_after <path> <before> — MC_LAST_FREED-style delta: what is gone
# from <path>; a path that no longer exists left nothing behind.
_mc_freed_after() {
    local path="$1" before="${2:-0}" after=0
    case "$before" in ''|*[!0-9]*) before=0 ;; esac
    if [[ -e "$path" || -L "$path" ]]; then
        after="$(path_size_bytes "$path" 2>/dev/null)" || after=0
        case "$after" in ''|*[!0-9]*) after=0 ;; esac
    fi
    if (( before > after )); then
        REPLY=$(( before - after ))
    else
        REPLY=0
    fi
}

# _mc_fail_reason <path> — permission_denied when the item is still there and
# its parent is not writable, else unknown.
_mc_fail_reason() {
    local parent
    parent="$(dirname "$1" 2>/dev/null)" || parent=""
    if [[ -n "$parent" && -d "$parent" && ! -w "$parent" ]]; then
        REPLY="permission_denied"
    else
        REPLY="unknown"
    fi
}

safe_remove() {
    local target="$1"
    local dry=0
    local normalized_target

    _mc_last skipped unknown 0
    is_dry_run && dry=1

    normalized_target="$(normalize_path "$target")" || normalized_target=""
    if [[ -z "$normalized_target" ]]; then
        print_error "safe_remove: path normalization failed for: ${target}"
        log_error "safe_remove: normalize_path returned empty for: ${target}"
        record_skipped_item "Normalization failed (fail-closed): ${target}"
        cleanup_journal_event "normalization_failed" "$target" "" "0" "blocked" "fail-closed (P1-11)"
        _mc_last failed unknown 0
        return 1
    fi

    if is_quarantine_path "$normalized_target"; then
        print_skip "Skipping cleanup quarantine path: ${normalized_target}"
        record_skipped_item "Quarantine cleanup is protected from recursive cleaning: ${normalized_target}"
        cleanup_journal_event "skipped_quarantine" "$normalized_target" "" 0 "skipped" "target is cleanup quarantine"
        _mc_last skipped protected_path 0
        return 0
    fi

    if ! assert_safe_path "$normalized_target"; then
        _mc_last skipped protected_path 0
        return 1
    fi

    if [[ ! -e "$normalized_target" && ! -L "$normalized_target" ]]; then
        log_debug "safe_remove: path does not exist, skipping: ${normalized_target}"
        _mc_last skipped not_found 0
        return 0
    fi

    local size
    # An unmeasurable size must not abort the run under errexit.
    size=$(path_size_bytes "$normalized_target") || size=0

    # Phase 3: rm -rf on a tree with an unreadable part deletes what it can
    # and stops at the rest, leaving it half-deleted. Quarantine (a rename on
    # the same volume) is unaffected; permanent removal skips such a tree.
    # The readability is probed here directly (du exits non-zero), so the
    # skip does not depend on the unreadable list having been written.
    if [[ "${REMOVE_MODE:-quarantine}" == "permanent" && -d "$normalized_target" ]] \
        && ! du -sk "$normalized_target" >/dev/null 2>&1; then
        print_skip "Not fully readable, not deleted permanently: ${normalized_target}"
        record_skipped_item "Not fully readable (macOS privacy or permissions), skipped in permanent mode: ${normalized_target}"
        cleanup_journal_event "skipped_unreadable" "$normalized_target" "" "$size" "skipped" "partly unreadable; permanent removal would half-delete it"
        _mc_last skipped unreadable 0
        return 0
    fi

    if [[ "$dry" == "1" ]]; then
        print_dry "Would remove: ${normalized_target}  ($(bytes_to_human "$size"))"
        TOTAL_WOULD_FREE_BYTES=$(( TOTAL_WOULD_FREE_BYTES + size ))
        cleanup_journal_event "would_remove" "$normalized_target" "" "$size" "planned" ""
        _mc_last dry_run "" 0
        return 0
    fi

    # P0-3: fail closed on an unknown/unset mode instead of deleting.
    if ! validate_remove_mode; then
        record_skipped_item "Invalid REMOVE_MODE (fail-closed): ${normalized_target}"
        cleanup_journal_event "remove_mode_invalid" "$normalized_target" "" "$size" "blocked" "fail-closed (P0-3)"
        _mc_last failed unknown 0
        return 1
    fi

    if [[ "$REMOVE_MODE" == "quarantine" ]]; then
        if is_user_space_path "$normalized_target"; then
            if quarantine_remove "$normalized_target" "$size"; then
                _mc_freed_after "$normalized_target" "$size"
                _mc_last quarantined "" "$REPLY"
                return 0
            fi
            _mc_fail_reason "$normalized_target"
            _mc_last failed "$REPLY" 0
            return 1
        fi

        print_skip "Skipping non-user path in quarantine mode: ${normalized_target}"
        record_skipped_item "Quarantine mode does not remove system/non-HOME paths: ${normalized_target}"
        cleanup_journal_event "skipped_non_user_scope" "$normalized_target" "" "$size" "skipped" "quarantine mode only supports user-scope paths"
        _mc_last skipped needs_permanent 0
        return 0
    fi

    local _rc=0
    if is_user_space_path "$normalized_target" \
        || [[ "$normalized_target" == /private/tmp/* || "$normalized_target" == /private/var/folders/* ]]; then
        direct_remove "$normalized_target" "$size" 0 "deleted" || _rc=$?
        if (( _rc == 0 )); then
            _mc_freed_after "$normalized_target" "$size"
            _mc_last cleaned "" "$REPLY"
        else
            _mc_fail_reason "$normalized_target"
            _mc_last failed "$REPLY" 0
        fi
        return "$_rc"
    fi

    if [[ "$normalized_target" == /Library/* || "$normalized_target" == /System/* || "$normalized_target" == /private/* ]]; then
        # P0-1b: privileged deletion is disabled; direct_remove refuses it.
        direct_remove "$normalized_target" "$size" 1 "deleted" || _rc=$?
        _mc_last skipped permission_denied 0
        return "$_rc"
    fi

    # F16: any other root (/Volumes/*, /opt, ...) is unknown territory.
    # Permanent mode only deletes where it knows the rules; fail closed.
    print_skip "Not deleting under an unknown root: ${normalized_target}"
    record_skipped_item "Permanent mode does not delete under an unknown root: ${normalized_target}"
    cleanup_journal_event "skipped_unknown_root" "$normalized_target" "" "$size" "skipped" "unknown root; permanent removal only under HOME, /private/tmp, /private/var/folders, /Library, /private"
    _mc_last skipped protected_path 0
    return 0
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
# Category tables, derived from the registry (share/categories.tsv, R06/F17).
#
# CATEGORY_REGISTRY rows are "id|label|class", built once from lib/registry.sh:
#   counted     real byte size of work a cleaner can do; the headline
#               TOTAL_WOULD_FREE_BYTES is the plan's executable sum (P1-1)
#   count       ledger value is an ITEM COUNT (unit=count: APFS local snapshots);
#               listed, never summed
#   report-only tier=report: sized and shown, never auto-removed, never summed
# ALL_KNOWN_CATEGORY_KEYS (counted + count) and ALL_CATEGORIES (the --category
# sections) come from the same load. Every `catbytes_set "<id>"` must name a
# registry id (tests/test_report_parity.sh). A registry that does not load
# leaves the tables empty and sets REGISTRY_LOAD_ERROR; the engine then exits 2
# before any mode runs (registry_require).
# ---------------------------------------------------------------------------
if ! type reg_load >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${_COMMON_DIR}/registry.sh"
fi

REGISTRY_LOAD_ERROR=""
CATEGORY_REGISTRY=()
ALL_KNOWN_CATEGORY_KEYS=()
ALL_CATEGORIES=()

# _category_label_fallback <id> — REPLY = the English label shown until the
# i18n dictionaries carry cat_<id> (another work package appends those keys).
# Delete this table once every registry label key resolves in i18n/en.sh.
_category_label_fallback() {
    case "${1:-}" in
        trash) REPLY="Trash (~/.Trash)" ;;
        user-caches) REPLY="User Caches (~/Library/Caches)" ;;
        app-caches) REPLY="App-specific Caches (allowlisted)" ;;
        app-caches-review) REPLY="App-specific Caches (review)" ;;
        user-logs) REPLY="User Logs (~/Library/Logs)" ;;
        system-logs) REPLY="System Logs (/Library/Logs)" ;;
        diagnostic-reports) REPLY="Diagnostic Reports" ;;
        system-caches) REPLY="System Caches (/Library/Caches)" ;;
        tmp) REPLY="Temporary Files (/tmp)" ;;
        xcode-derived) REPLY="Xcode DerivedData" ;;
        xcode-archives) REPLY="Xcode Archives" ;;
        simulators) REPLY="iOS Simulators (unavailable)" ;;
        sim-runtimes) REPLY="Simulator runtimes (unusable)" ;;
        device-support) REPLY="Xcode Device Support" ;;
        npm) REPLY="npm cache (~/.npm/_cacache)" ;;
        npx) REPLY="npx cache (~/.npm/_npx)" ;;
        yarn) REPLY="yarn cache" ;;
        pnpm) REPLY="pnpm store" ;;
        pnpm-stale) REPLY="pnpm stale store versions" ;;
        pip) REPLY="pip cache" ;;
        brew) REPLY="Homebrew cache and old versions" ;;
        gradle) REPLY="Gradle cache" ;;
        maven) REPLY="Maven repository (~/.m2)" ;;
        cocoapods) REPLY="CocoaPods cache" ;;
        cargo) REPLY="Cargo registry cache" ;;
        swift-pm) REPLY="Swift Package Manager cache" ;;
        gem) REPLY="Ruby gems cache" ;;
        bundler) REPLY="Bundler cache" ;;
        composer) REPLY="Composer cache (PHP)" ;;
        android-avd) REPLY="Android AVD Emulators" ;;
        docker) REPLY="Docker (reclaimable)" ;;
        app-leftovers) REPLY="App Leftovers" ;;
        tm-snapshots) REPLY="Local TM Snapshots" ;;
        ios-backups) REPLY="iOS Backups" ;;
        installers) REPLY="Old Installers (~/Downloads)" ;;
        browser-caches) REPLY="Browser Caches (review)" ;;
        browser-data) REPLY="Browser Profiles (DANGEROUS)" ;;
        mail-data) REPLY="Apple Mail - store" ;;
        mail-downloads) REPLY="Apple Mail - downloads" ;;
        *) REPLY="${1:-}"; return 1 ;;
    esac
    return 0
}

# registry_tables_build — (re)load the registry and derive the tables above.
registry_tables_build() {
    local i id klass s
    CATEGORY_REGISTRY=()
    ALL_KNOWN_CATEGORY_KEYS=()
    ALL_CATEGORIES=()
    if ! reg_load 2>/dev/null; then
        REGISTRY_LOAD_ERROR="${REG_ERROR:-registry did not load}"
        return 2
    fi
    REGISTRY_LOAD_ERROR=""
    i=0
    while [ "$i" -lt "$REG_COUNT" ]; do
        id="${REG_ID[$i]}"
        if [[ "${REG_TIER[$i]}" == "report" ]]; then
            klass="report-only"
        elif [[ "${REG_UNIT[$i]}" == "count" ]]; then
            klass="count"
        else
            klass="counted"
        fi
        _category_label_fallback "$id" || true
        CATEGORY_REGISTRY+=("${id}|${REPLY}|${klass}")
        [[ "$klass" == "report-only" ]] || ALL_KNOWN_CATEGORY_KEYS+=("$id")
        i=$(( i + 1 ))
    done
    while IFS= read -r s; do
        [[ -n "$s" ]] && ALL_CATEGORIES+=("$s")
    done < <(reg_sections --cli)
    return 0
}

# registry_require — the engine's fail-closed gate: exit 2 when the registry
# did not load (or a later re-source reset it and it no longer loads).
registry_require() {
    if [[ "${REG_LOADED:-0}" != "1" ]] || (( ${#CATEGORY_REGISTRY[@]} == 0 )); then
        registry_tables_build || true
    fi
    if [[ -n "$REGISTRY_LOAD_ERROR" ]] || (( ${#CATEGORY_REGISTRY[@]} == 0 )); then
        echo "  ✖  $(t registry_invalid "${REGISTRY_LOAD_ERROR:-no categories}")" >&2
        log_error "Category registry is invalid: ${REGISTRY_LOAD_ERROR:-no categories}"
        exit 2
    fi
}

registry_tables_build || true

# category_label <id> - printable label: the i18n cat_<id> text when the
# dictionary has it, else the fallback label, else the id itself.
category_label() {
    local key="${1:-}" lkey="" fn val=""
    if reg_get "$key" label_key 2>/dev/null; then
        lkey="$REPLY"
    fi
    if [[ -n "$lkey" ]]; then
        fn="i18n_get_${LANG_CODE:-en}"
        if declare -f "$fn" >/dev/null 2>&1; then
            val="$("$fn" "$lkey" 2>/dev/null)" || val=""
        fi
        [[ -n "$val" ]] || val="$(i18n_get_en "$lkey" 2>/dev/null)" || val=""
        if [[ -n "$val" ]]; then
            printf '%s' "$val"
            return 0
        fi
    fi
    _category_label_fallback "$key" || true
    printf '%s' "$REPLY"
}

# category_class <id> - counted | count | report-only ("" when unregistered).
category_class() {
    local key="${1:-}" row
    (( ${#CATEGORY_REGISTRY[@]} > 0 )) || return 0
    for row in "${CATEGORY_REGISTRY[@]}"; do
        if [[ "${row%%|*}" == "$key" ]]; then
            printf '%s' "${row##*|}"
            return 0
        fi
    done
    return 0
}

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
declare -a NOTES_LIST=()

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
