#!/usr/bin/env bash
# lib/paths.sh - single source of truth for the toolkit directories (Bash 3.2+).
#
# Shell twin of lib/python/mc_paths.py: identical input gives identical output
# (seam test S4 compares them). Change both together. Contract: V4 architecture §1.
#
#   program     replaced wholesale by an upgrade; nothing writes inside it at runtime
#   config      user-owned settings, never touched by installers or upgrades
#   state       disposable: run dirs (logs, plans, reports, journals), caches, backups
#   quarantine  the user's restore point; stays on the HOME volume (rename(2))
#
# Resolution, first match wins:
#   program     $MACOS_CLEANUP_HOME
#               this toolkit's own physical root when it has .git (mode checkout)
#               or .install-info (mode installed)
#               ~/.local/share/macos-cleanup (mode default)
#   config      $MACOS_CLEANUP_CONFIG_DIR, $XDG_CONFIG_HOME/macos-cleanup, ~/.config/macos-cleanup
#   state       $MACOS_CLEANUP_STATE_DIR,  $XDG_STATE_HOME/macos-cleanup,  ~/.local/state/macos-cleanup
#   quarantine  $MACOS_CLEANUP_QUARANTINE_DIR, legacy $QUARANTINE_ROOT,
#               ~/Library/Application Support/macOS_cleanup/quarantine
#
# MACOS_CLEANUP_* overrides must be absolute (a relative one is an error); XDG_*
# values that are not absolute are ignored. Trailing slashes are dropped.
# Symlinks are not resolved, except for the program root, which is physical.
# Empty values count as unset.
#
# Library use (safe under set -euo pipefail; sourcing prints and does nothing):
#   . "$SCRIPT_DIR/lib/paths.sh"
#   mc_paths_init [ROOT] || { echo "$MC_PATHS_ERROR" >&2; exit 2; }
#     sets MC_PROGRAM_DIR MC_CONFIG_DIR MC_STATE_DIR MC_QUARANTINE_DIR MC_PATHS_MODE
#          MC_LEGACY_LOGS_DIR MC_LEGACY_REPORTS_DIR (legacy overrides, "" when unset)
#          MC_QUARANTINE_RUN_DIR_OVERRIDE ("" when unset)
#          MC_LEGACY_VARS_USED (space-separated names of legacy variables in effect)
#   mc_quarantine_check          # 0 when the quarantine dir is on the HOME device
#   mc_ensure_dir config|state|quarantine|run <run_id>   # 0700; prints the path
#   mc_run_dir <run_id>          # $MC_STATE_DIR/runs/<run_id>
#   mc_log_dir <run_id>          # legacy $LOGS_DIR when set, else the run dir
#   mc_report_dir <run_id>       # legacy $REPORTS_DIR when set, else the run dir
#   mc_quarantine_run_dir <run_id>   # override when set, else $MC_QUARANTINE_DIR/<run_id>
#   mc_run_id_valid <id>         # YYYY-MM-DD_HHMMSS_PID
# Command line:
#   bash lib/paths.sh [print|program|config|state|quarantine|mode|check-quarantine|
#                      ensure <kind> [run_id]|run-dir <id>] [--root DIR]

_MC_PATHS_NAME="macos-cleanup"
_MC_PATHS_FILE="${BASH_SOURCE[0]:-$0}"

_mc_pe() {
    MC_PATHS_ERROR="$1"
    return 2
}

# Drop trailing slashes ("/" stays "/").
_mc_clean() {
    local p="$1"
    while [ "${p%/}" != "$p" ] && [ -n "${p%/}" ]; do
        p="${p%/}"
    done
    [ -n "$p" ] || p="/"
    printf '%s' "$p"
}

# Physical directory of the toolkit this file belongs to.
mc_toolkit_root() {
    local dir="${_MC_PATHS_FILE%/*}"
    [ "$dir" != "$_MC_PATHS_FILE" ] || dir="."
    ( cd "$dir/.." 2>/dev/null && pwd -P )
}

# Resolve a path that may not exist yet: the deepest existing ancestor is made
# physical, the missing tail is appended unchanged.
_mc_physical() {
    local p="$1" tail="" base
    while [ ! -d "$p" ] && [ "$p" != "/" ] && [ -n "$p" ]; do
        base="${p##*/}"
        tail="/${base}${tail}"
        p="${p%/*}"
        [ -n "$p" ] || p="/"
    done
    p="$( cd "$p" 2>/dev/null && pwd -P )" || p="$1"
    [ "$p" = "/" ] && p=""
    printf '%s%s' "$p" "$tail"
}

_mc_inside() {
    local path="$1" parent="$2"
    parent="${parent%/}"
    case "$path" in
        "$parent"|"$parent"/*) return 0 ;;
    esac
    return 1
}

# Device number of a path that exists (symlinks followed); empty on failure.
_mc_dev() {
    local d
    d="$(stat -L -f %d "$1" 2>/dev/null)" || return 1
    case "$d" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$d"
}

# The quarantine dir as validate_quarantine_root checks it: absolute, no "."
# or ".." segments, last component "quarantine". $1 value, $2 variable name.
_mc_quarantine_format() {
    local value="$1" name="$2"
    case "$value" in
        /*) ;;
        *) _mc_pe "$name must be an absolute path."; return 2 ;;
    esac
    case "${value}/" in
        */./*|*/../*) _mc_pe "$name must not contain . or .. segments."; return 2 ;;
    esac
    value="$(_mc_clean "$value")"
    if [ "${value##*/}" != "quarantine" ]; then
        _mc_pe "$name must end in a folder named quarantine."
        return 2
    fi
    return 0
}

# $1 variable name, $2 value of the override. Sets REPLY (cleaned) or errors.
_mc_abs_override() {
    case "$2" in
        /*) ;;
        *) _mc_pe "$1 must be an absolute path."; return 2 ;;
    esac
    REPLY="$(_mc_clean "$2")"
    return 0
}

mc_run_id_valid() {
    local id="${1:-}" pid
    case "$id" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_[0-9]*) ;;
        *) return 1 ;;
    esac
    pid="${id##*_}"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# A run id usable as a single path component (the strict format is
# mc_run_id_valid; this only refuses anything that could escape runs/).
_mc_run_id_safe() {
    case "${1:-}" in
        ''|.|..|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

mc_paths_init() {
    local root="${1:-}" home value base
    MC_PROGRAM_DIR="" MC_CONFIG_DIR="" MC_STATE_DIR="" MC_QUARANTINE_DIR="" MC_PATHS_MODE=""
    MC_LEGACY_LOGS_DIR="" MC_LEGACY_REPORTS_DIR="" MC_QUARANTINE_RUN_DIR_OVERRIDE=""
    MC_LEGACY_VARS_USED="" MC_PATHS_ERROR=""
    home="${HOME:-}"
    if [ -z "$home" ]; then
        _mc_pe "HOME is not set, so the toolkit folders cannot be located."
        return 2
    fi
    case "$home" in
        /*) ;;
        *) _mc_pe "HOME must be an absolute path."; return 2 ;;
    esac
    home="$(_mc_clean "$home")"
    if [ -n "$root" ]; then
        root="$( cd "$root" 2>/dev/null && pwd -P )" || root="$1"
    else
        root="$(mc_toolkit_root)"
    fi

    # program
    value="${MACOS_CLEANUP_HOME:-}"
    if [ -n "$value" ]; then
        _mc_abs_override MACOS_CLEANUP_HOME "$value" || return 2
        MC_PROGRAM_DIR="$REPLY"
        MC_PATHS_MODE="env"
    elif [ -e "$root/.git" ]; then
        MC_PROGRAM_DIR="$root"
        MC_PATHS_MODE="checkout"
    elif [ -f "$root/.install-info" ]; then
        MC_PROGRAM_DIR="$root"
        MC_PATHS_MODE="installed"
    else
        MC_PROGRAM_DIR="$home/.local/share/$_MC_PATHS_NAME"
        MC_PATHS_MODE="default"
    fi

    # config
    value="${MACOS_CLEANUP_CONFIG_DIR:-}"
    if [ -n "$value" ]; then
        _mc_abs_override MACOS_CLEANUP_CONFIG_DIR "$value" || return 2
        MC_CONFIG_DIR="$REPLY"
    else
        base="$home/.config"
        case "${XDG_CONFIG_HOME:-}" in
            /*) base="$(_mc_clean "$XDG_CONFIG_HOME")" ;;
        esac
        MC_CONFIG_DIR="$base/$_MC_PATHS_NAME"
    fi

    # state
    value="${MACOS_CLEANUP_STATE_DIR:-}"
    if [ -n "$value" ]; then
        _mc_abs_override MACOS_CLEANUP_STATE_DIR "$value" || return 2
        MC_STATE_DIR="$REPLY"
    else
        base="$home/.local/state"
        case "${XDG_STATE_HOME:-}" in
            /*) base="$(_mc_clean "$XDG_STATE_HOME")" ;;
        esac
        MC_STATE_DIR="$base/$_MC_PATHS_NAME"
    fi

    # quarantine: new override, then legacy QUARANTINE_ROOT, then the default
    value="${MACOS_CLEANUP_QUARANTINE_DIR:-}"
    if [ -n "$value" ]; then
        _mc_quarantine_format "$value" MACOS_CLEANUP_QUARANTINE_DIR || return 2
        MC_QUARANTINE_DIR="$(_mc_clean "$value")"
    elif [ -n "${QUARANTINE_ROOT:-}" ] && [ "${QUARANTINE_ROOT}" != "${MC_ENGINE_QUARANTINE_ROOT:-}" ]; then
        # (a value the engine itself set in config/defaults.sh is not a user override)
        _mc_quarantine_format "$QUARANTINE_ROOT" QUARANTINE_ROOT || return 2
        MC_QUARANTINE_DIR="$(_mc_clean "$QUARANTINE_ROOT")"
        MC_LEGACY_VARS_USED="${MC_LEGACY_VARS_USED} QUARANTINE_ROOT"
    else
        MC_QUARANTINE_DIR="$home/Library/Application Support/macOS_cleanup/quarantine"
    fi

    # quarantine run dir override: an immediate child of the quarantine dir (F14)
    value="${MACOS_CLEANUP_QUARANTINE_RUN_DIR:-}"
    base="MACOS_CLEANUP_QUARANTINE_RUN_DIR"
    if [ -z "$value" ] && [ -n "${QUARANTINE_RUN_DIR:-}" ] && [ "${QUARANTINE_RUN_DIR}" != "${MC_ENGINE_QUARANTINE_RUN_DIR:-}" ]; then
        value="$QUARANTINE_RUN_DIR"
        base="QUARANTINE_RUN_DIR"
        MC_LEGACY_VARS_USED="${MC_LEGACY_VARS_USED} QUARANTINE_RUN_DIR"
    fi
    if [ -n "$value" ]; then
        _mc_abs_override "$base" "$value" || return 2
        value="$REPLY"
        if [ "${value%/*}" != "$MC_QUARANTINE_DIR" ] || ! _mc_run_id_safe "${value##*/}"; then
            _mc_pe "$base must be an immediate child of the quarantine folder."
            return 2
        fi
        MC_QUARANTINE_RUN_DIR_OVERRIDE="$value"
    fi

    # legacy artifact overrides, honoured for 4.x (deprecated)
    if [ -n "${LOGS_DIR:-}" ]; then
        _mc_abs_override LOGS_DIR "$LOGS_DIR" || return 2
        MC_LEGACY_LOGS_DIR="$REPLY"
        MC_LEGACY_VARS_USED="${MC_LEGACY_VARS_USED} LOGS_DIR"
    fi
    if [ -n "${REPORTS_DIR:-}" ]; then
        _mc_abs_override REPORTS_DIR "$REPORTS_DIR" || return 2
        MC_LEGACY_REPORTS_DIR="$REPLY"
        MC_LEGACY_VARS_USED="${MC_LEGACY_VARS_USED} REPORTS_DIR"
    fi
    MC_LEGACY_VARS_USED="${MC_LEGACY_VARS_USED# }"
    return 0
}

# Quarantine is a rename(2): the dir (or its deepest existing ancestor, when it
# does not exist yet) must be on the same device as $HOME. Needs mc_paths_init.
mc_quarantine_check() {
    local q anc home_dev q_dev
    q="${MC_QUARANTINE_DIR:-}"
    if [ -z "$q" ]; then
        _mc_pe "The paths are not initialised."
        return 2
    fi
    anc="$q"
    while [ ! -d "$anc" ] && [ "$anc" != "/" ] && [ -n "$anc" ]; do
        anc="${anc%/*}"
        [ -n "$anc" ] || anc="/"
    done
    home_dev="$(_mc_dev "${HOME:-/nonexistent}")" || home_dev=""
    q_dev="$(_mc_dev "$anc")" || q_dev=""
    if [ -z "$home_dev" ] || [ -z "$q_dev" ]; then
        _mc_pe "The device of the quarantine folder or of HOME cannot be read."
        return 2
    fi
    if [ "$home_dev" != "$q_dev" ]; then
        _mc_pe "The quarantine folder $q is not on the same volume as HOME, so quarantine mode is refused."
        return 2
    fi
    return 0
}

mc_run_dir() {
    local id="${1:-}"
    [ -n "${MC_STATE_DIR:-}" ] || { _mc_pe "The paths are not initialised."; return 2; }
    _mc_run_id_safe "$id" || { _mc_pe "Unusable run id."; return 2; }
    printf '%s/runs/%s\n' "$MC_STATE_DIR" "$id"
}

mc_log_dir() {
    if [ -n "${MC_LEGACY_LOGS_DIR:-}" ]; then
        printf '%s\n' "$MC_LEGACY_LOGS_DIR"
    else
        mc_run_dir "${1:-}"
    fi
}

mc_report_dir() {
    if [ -n "${MC_LEGACY_REPORTS_DIR:-}" ]; then
        printf '%s\n' "$MC_LEGACY_REPORTS_DIR"
    else
        mc_run_dir "${1:-}"
    fi
}

mc_quarantine_run_dir() {
    local id="${1:-}"
    [ -n "${MC_QUARANTINE_DIR:-}" ] || { _mc_pe "The paths are not initialised."; return 2; }
    if [ -n "${MC_QUARANTINE_RUN_DIR_OVERRIDE:-}" ]; then
        printf '%s\n' "$MC_QUARANTINE_RUN_DIR_OVERRIDE"
        return 0
    fi
    _mc_run_id_safe "$id" || { _mc_pe "Unusable run id."; return 2; }
    printf '%s/%s\n' "$MC_QUARANTINE_DIR" "$id"
}

# Create a directory (0700) and print it. kind: config | state | quarantine |
# run <run_id>. Refuses a directory inside, or a symlink into, the program dir:
# that tree is replaced on every update. A quarantine dir must also be on the
# HOME device. Needs mc_paths_init.
mc_ensure_dir() {
    local kind="${1:-}" id="${2:-}" target label phys prog
    [ -n "${MC_STATE_DIR:-}" ] || { _mc_pe "The paths are not initialised."; return 2; }
    case "$kind" in
        config) target="$MC_CONFIG_DIR" ;;
        state) target="$MC_STATE_DIR" ;;
        quarantine) target="$MC_QUARANTINE_DIR" ;;
        run)
            _mc_run_id_safe "$id" || { _mc_pe "Unusable run id."; return 2; }
            target="$MC_STATE_DIR/runs/$id" ;;
        *) _mc_pe "Only the config, state, quarantine and run folders are created on demand."; return 2 ;;
    esac
    label="$kind"
    prog="$(_mc_physical "$MC_PROGRAM_DIR")"
    if _mc_inside "$(_mc_physical "$target")" "$prog"; then
        _mc_pe "The $label folder is inside the program folder, which is replaced on every update."
        return 2
    fi
    if [ "$kind" = quarantine ]; then
        mc_quarantine_check || return 2
    fi
    if [ ! -d "$target" ]; then
        ( umask 077; mkdir -p "$target" ) 2>/dev/null || {
            _mc_pe "The $label folder $target cannot be created."
            return 2
        }
        chmod 700 "$target" 2>/dev/null || true
    fi
    phys="$(_mc_physical "$target")"
    if _mc_inside "$phys" "$prog"; then
        _mc_pe "The $label folder is a link into the program folder, which is replaced on every update."
        return 2
    fi
    printf '%s\n' "$target"
    return 0
}

# =============================================================================
# User configuration layer (V4 section 5.3, F03)
#
# Everything here only READS files in <config>: settings.conf, excludes.txt,
# rules.local.yaml, category-modes.tsv. None of them is ever sourced or eval'ed.
# Problems never abort a run: a bad line is ignored and reported once through
# MC_STARTUP_WARNINGS (one line per problem), which cleanup_all.sh prints once
# the run folder exists.
#
#   mc_load_settings        settings.conf -> engine variables, with precedence
#                           CLI flag > MACOS_CLEANUP_* env > legacy env > settings.conf > default
#                           (CLI flags are parsed later and simply overwrite)
#   mc_load_excludes        excludes.txt -> NEVER_TOUCH_PATHS / EXCLUDED_PATHS
#   mc_apply_rules_overlay  rules.local.yaml -> policy rules, raise-only
#   mc_load_category_modes  category-modes.tsv + section 13 defaults
#   mc_category_mode <id>   prints (and sets REPLY) auto|review|skip;
#                           MC_CATEGORY_MODE_SOURCE is user|default
# =============================================================================

MC_STARTUP_WARNINGS="${MC_STARTUP_WARNINGS:-}"

mc_startup_warn() {
    MC_STARTUP_WARNINGS="${MC_STARTUP_WARNINGS}${MC_STARTUP_WARNINGS:+$'\n'}$1"
}

# Print the collected startup warnings through print_warn, to stderr (the
# --json stdout stays clean), then forget them.
mc_flush_startup_warnings() {
    local line
    [ -n "${MC_STARTUP_WARNINGS:-}" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if type print_warn >/dev/null 2>&1; then
            print_warn "$line" >&2
        else
            printf '%s\n' "$line" >&2
        fi
    done <<EOF
$MC_STARTUP_WARNINGS
EOF
    MC_STARTUP_WARNINGS=""
}

# Trim blanks around $1 into REPLY.
_mc_trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    REPLY="$v"
}

# _mc_setting_spec <key> — sets _S_KEY (canonical), _S_VAR (engine variable),
# _S_ENV (MACOS_CLEANUP_* name), _S_LEGACY (legacy variable or ""), _S_KIND
# (int|lang|bool|remove_mode|time|weekday), _S_MIN, _S_MAX, _S_DEF (default for
# a legacy value that turns out invalid). Accepts the schema key or the env
# name. Returns 1 for a key that is not on the whitelist.
_mc_setting_spec() {
    _S_KEY="" _S_VAR="" _S_ENV="" _S_LEGACY="" _S_KIND="int" _S_MIN=0 _S_MAX=0 _S_DEF=""
    case "$1" in
        language|MACOS_CLEANUP_LANG)
            _S_KEY=language _S_VAR=LANG_CODE _S_ENV=MACOS_CLEANUP_LANG _S_LEGACY=LANG_CODE _S_KIND=lang ;;
        remove_mode|MACOS_CLEANUP_REMOVE_MODE)
            _S_KEY=remove_mode _S_VAR=REMOVE_MODE _S_ENV=MACOS_CLEANUP_REMOVE_MODE _S_KIND=remove_mode _S_DEF=quarantine ;;
        quarantine_retention_days|MACOS_CLEANUP_QUARANTINE_RETENTION_DAYS)
            _S_KEY=quarantine_retention_days _S_VAR=QUARANTINE_RETENTION_DAYS _S_ENV=MACOS_CLEANUP_QUARANTINE_RETENTION_DAYS _S_MIN=1 _S_MAX=365 _S_DEF=30 ;;
        recent_days|MACOS_CLEANUP_RECENT_DAYS)
            _S_KEY=recent_days _S_VAR=RECENT_DAYS _S_ENV=MACOS_CLEANUP_RECENT_DAYS _S_MIN=0 _S_MAX=90 _S_DEF=0 ;;
        backup_max_age_days|MACOS_CLEANUP_BACKUP_MAX_AGE_DAYS)
            _S_KEY=backup_max_age_days _S_VAR=BACKUP_MAX_AGE_DAYS _S_ENV=MACOS_CLEANUP_BACKUP_MAX_AGE_DAYS _S_MIN=1 _S_MAX=90 _S_DEF=14 ;;
        redact|MACOS_CLEANUP_REDACT)
            _S_KEY=redact _S_VAR=REDACT_PATHS _S_ENV=MACOS_CLEANUP_REDACT _S_LEGACY=REDACT_PATHS _S_KIND=bool _S_DEF=0 ;;
        log_max_age_days|MACOS_CLEANUP_LOG_MAX_AGE_DAYS)
            _S_KEY=log_max_age_days _S_VAR=LOG_MAX_AGE_DAYS _S_ENV=MACOS_CLEANUP_LOG_MAX_AGE_DAYS _S_MIN=1 _S_MAX=365 _S_DEF=30 ;;
        dmg_max_age_days|MACOS_CLEANUP_DMG_MAX_AGE_DAYS)
            _S_KEY=dmg_max_age_days _S_VAR=DMG_MAX_AGE_DAYS _S_ENV=MACOS_CLEANUP_DMG_MAX_AGE_DAYS _S_MIN=1 _S_MAX=365 _S_DEF=30 ;;
        device_support_min_age_days|MACOS_CLEANUP_DEVICE_SUPPORT_MIN_AGE_DAYS)
            _S_KEY=device_support_min_age_days _S_VAR=DEVICE_SUPPORT_MIN_AGE_DAYS _S_ENV=MACOS_CLEANUP_DEVICE_SUPPORT_MIN_AGE_DAYS _S_MIN=30 _S_MAX=720 _S_DEF=180 ;;
        scan_jobs|MACOS_CLEANUP_SCAN_JOBS)
            _S_KEY=scan_jobs _S_VAR=SCAN_JOBS _S_ENV=MACOS_CLEANUP_SCAN_JOBS _S_MIN=1 _S_MAX=8 _S_DEF=4 ;;
        home_top_timeout|MACOS_CLEANUP_HOME_TOP_TIMEOUT)
            _S_KEY=home_top_timeout _S_VAR=HOME_TOP_DIRS_TIMEOUT _S_ENV=MACOS_CLEANUP_HOME_TOP_TIMEOUT _S_LEGACY=HOME_TOP_DIRS_TIMEOUT _S_MIN=0 _S_MAX=120 _S_DEF=20 ;;
        artifact_retention_days|MACOS_CLEANUP_ARTIFACT_RETENTION_DAYS)
            _S_KEY=artifact_retention_days _S_VAR=ARTIFACT_RETENTION_DAYS _S_ENV=MACOS_CLEANUP_ARTIFACT_RETENTION_DAYS _S_LEGACY=ARTIFACT_RETENTION_DAYS _S_MIN=0 _S_MAX=365 _S_DEF=30 ;;
        schedule_time|MACOS_CLEANUP_SCHEDULE_TIME)
            _S_KEY=schedule_time _S_VAR=SCHEDULE_TIME _S_ENV=MACOS_CLEANUP_SCHEDULE_TIME _S_KIND=time _S_DEF=10:30 ;;
        schedule_weekday|MACOS_CLEANUP_SCHEDULE_WEEKDAY)
            _S_KEY=schedule_weekday _S_VAR=SCHEDULE_WEEKDAY _S_ENV=MACOS_CLEANUP_SCHEDULE_WEEKDAY _S_KIND=weekday _S_DEF=sun ;;
        *) return 1 ;;
    esac
    return 0
}

_MC_SETTING_KEYS="language remove_mode quarantine_retention_days recent_days backup_max_age_days redact log_max_age_days dmg_max_age_days device_support_min_age_days scan_jobs home_top_timeout artifact_retention_days schedule_time schedule_weekday"

# What a value must look like, for the warning text.
_mc_setting_need() {
    case "$_S_KIND" in
        int) printf 'an integer %s-%s' "$_S_MIN" "$_S_MAX" ;;
        lang) printf 'one of en, pl, de, es, fr, it, pt' ;;
        bool) printf 'true or false' ;;
        remove_mode) printf 'quarantine or permanent' ;;
        time) printf 'HH:MM' ;;
        weekday) printf 'daily, mon, tue, wed, thu, fri, sat or sun' ;;
    esac
}

# _mc_setting_valid <value> — against the spec loaded by _mc_setting_spec.
# Sets REPLY to the normalised value.
_mc_setting_valid() {
    local v="$1" lower
    case "$v" in *[[:cntrl:]]*) return 1 ;; esac
    lower="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    case "$_S_KIND" in
        int)
            case "$v" in ''|*[!0-9]*) return 1 ;; esac
            [ "${#v}" -le 6 ] || return 1
            v=$((10#$v))
            [ "$v" -ge "$_S_MIN" ] && [ "$v" -le "$_S_MAX" ] || return 1
            REPLY="$v" ;;
        lang)
            case "$lower" in en|pl|de|es|fr|it|pt) REPLY="$lower" ;; *) return 1 ;; esac ;;
        bool)
            case "$lower" in true|1|yes|on) REPLY=1 ;; false|0|no|off) REPLY=0 ;; *) return 1 ;; esac ;;
        remove_mode)
            case "$lower" in quarantine|permanent) REPLY="$lower" ;; *) return 1 ;; esac ;;
        time)
            case "$v" in
                [0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) REPLY="$v" ;;
                *) return 1 ;;
            esac ;;
        weekday)
            case "$lower" in daily|mon|tue|wed|thu|fri|sat|sun) REPLY="$lower" ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    return 0
}

# mc_load_settings — see the header of this section. Needs mc_paths_init.
mc_load_settings() {
    local file="${MC_CONFIG_DIR:-}/settings.conf" line n=0 key value k
    local fileval envval legacy_val use_legacy
    [ -n "${MC_CONFIG_DIR:-}" ] || return 0

    # 1. read the file: every line is validated, the last valid one per key wins
    if [ -e "$file" ] || [ -L "$file" ]; then
        if [ -L "$file" ] || [ ! -f "$file" ]; then
            mc_startup_warn "settings.conf is not a regular file; ignored."
        elif [ "$(wc -c < "$file" 2>/dev/null | tr -d ' ')" -gt 65536 ]; then
            mc_startup_warn "settings.conf is larger than 64 KiB; ignored."
        else
            while IFS= read -r line || [ -n "$line" ]; do
                n=$((n + 1))
                line="${line%$'\r'}"
                _mc_trim "$line"; line="$REPLY"
                case "$line" in ''|'#'*) continue ;; esac
                case "$line" in
                    *=*) ;;
                    *) mc_startup_warn "settings.conf line ${n}: not KEY=VALUE; ignored."; continue ;;
                esac
                _mc_trim "${line%%=*}"; key="$REPLY"
                _mc_trim "${line#*=}"; value="$REPLY"
                case "$value" in
                    \"*\") value="${value#\"}"; value="${value%\"}" ;;
                    \'*\') value="${value#\'}"; value="${value%\'}" ;;
                esac
                if ! _mc_setting_spec "$key"; then
                    mc_startup_warn "settings.conf line ${n}: unknown key '${key}' ignored."
                    continue
                fi
                if ! _mc_setting_valid "$value"; then
                    mc_startup_warn "settings.conf line ${n}: invalid value for '${_S_KEY}' (need $(_mc_setting_need)); ignored."
                    continue
                fi
                eval "_MC_SF_${_S_KEY}=\$REPLY"
            done < "$file"
        fi
    fi

    # 2. apply, key by key
    for k in $_MC_SETTING_KEYS; do
        _mc_setting_spec "$k"
        fileval=""
        eval "fileval=\"\${_MC_SF_${k}:-}\""
        # remove_mode is never taken from the environment: consent and the
        # removal mode come from CLI flags or settings.conf only (F14, 10.4)
        if [ "$_S_KEY" = remove_mode ]; then
            if [ -n "${!_S_ENV:-}" ]; then
                mc_startup_warn "${_S_ENV} in the environment is ignored; use --permanent or --quarantine, or remove_mode in settings.conf."
            fi
            if [ -n "$fileval" ]; then printf -v "$_S_VAR" '%s' "$fileval"; fi
            continue
        fi
        # prefixed env
        envval="${!_S_ENV:-}"
        if [ -n "$envval" ]; then
            if _mc_setting_valid "$envval"; then
                printf -v "$_S_VAR" '%s' "$REPLY"
                _mc_setting_post "$_S_KEY" "$REPLY"
                continue
            fi
            mc_startup_warn "${_S_ENV} has an invalid value (need $(_mc_setting_need)); ignored."
        fi
        # legacy env (only when the user's environment, not the engine, set it)
        use_legacy=0
        if [ -n "$_S_LEGACY" ]; then
            case " ${MC_LEGACY_ENV_SET:-} " in *" ${_S_LEGACY} "*) use_legacy=1 ;; esac
        fi
        if [ "$use_legacy" = 1 ]; then
            legacy_val="${!_S_LEGACY:-}"
            if _mc_setting_valid "$legacy_val"; then
                printf -v "$_S_VAR" '%s' "$REPLY"
                _mc_setting_post "$_S_KEY" "$REPLY"
                continue
            fi
            mc_startup_warn "${_S_LEGACY} has an invalid value (need $(_mc_setting_need)); ignored."
            if [ "$_S_KEY" = language ]; then
                _S_DEF="$(detect_lang_code 2>/dev/null)" || _S_DEF=en
            fi
            printf -v "$_S_VAR" '%s' "$_S_DEF"
        fi
        # settings.conf
        if [ -n "$fileval" ]; then
            printf -v "$_S_VAR" '%s' "$fileval"
            _mc_setting_post "$_S_KEY" "$fileval"
        fi
    done
    return 0
}

# Side effects of a setting that other code keys off.
_mc_setting_post() {
    case "$1:$2" in
        redact:1) type _redact_init >/dev/null 2>&1 && _redact_init ;;
    esac
    return 0
}

# mc_load_excludes — <config>/excludes.txt: one absolute or ~ path per line,
# '#' comments. Entries join NEVER_TOUCH_PATHS (scan and removal both honour it)
# and EXCLUDED_PATHS (listed in the banner). Needs normalize_path.
mc_load_excludes() {
    local file="${MC_CONFIG_DIR:-}/excludes.txt" line n=0 path
    [ -n "${MC_CONFIG_DIR:-}" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        _mc_trim "$line"; line="$REPLY"
        case "$line" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2088  # the file holds a literal ~/ prefix, expanded by hand
        case "$line" in
            *[[:cntrl:]]*) mc_startup_warn "excludes.txt line ${n}: contains a control character; ignored."; continue ;;
            '~') path="$HOME" ;;
            '~/'*) path="$HOME/${line#'~/'}" ;;
            /*) path="$line" ;;
            *) mc_startup_warn "excludes.txt line ${n}: not an absolute or ~ path; ignored."; continue ;;
        esac
        path="$(normalize_path "$path" 2>/dev/null || echo "$path")"
        NEVER_TOUCH_PATHS+=("$path")
        EXCLUDED_PATHS+=("$path")
    done < "$file"
    return 0
}

# Safety words ranked: safe < ask < never.
_mc_safety_rank() {
    case "$(printf '%s' "${1:-ask}" | tr '[:upper:]' '[:lower:]')" in
        safe) echo 0 ;;
        never|dangerous) echo 2 ;;
        *) echo 1 ;;
    esac
}

# _mc_overlay_entry <path> <safety> <type> — one rule of rules.local.yaml.
_mc_overlay_entry() {
    local raw="$1" safety="$2" type="${3:-other}" norm idx shipped_rank local_rank
    [ -n "$raw" ] && [ -n "$safety" ] || return 0
    # shellcheck disable=SC2088  # the file holds a literal ~/ prefix, expanded by hand
    case "$raw" in
        '~') raw="$HOME" ;;
        '~/'*) raw="$HOME/${raw#'~/'}" ;;
        '$HOME'|'$HOME/'*) raw="$HOME${raw#'$HOME'}" ;;
    esac
    case "$raw" in /*) ;; *) mc_startup_warn "rules.local.yaml: rule '${raw}' is not an absolute or ~ path; rejected."; return 0 ;; esac
    norm="$(normalize_path "$raw" 2>/dev/null || echo "$raw")"
    idx="$(policy_rule_index_for_path "$norm")"
    if [ "$idx" != "-1" ]; then
        shipped_rank="$(_mc_safety_rank "${POLICY_RULE_SAFETY[$idx]}")"
    else
        shipped_rank=1   # the default risk of an unlisted path is REVIEW (ask)
    fi
    local_rank="$(_mc_safety_rank "$safety")"
    if [ "$local_rank" -lt "$shipped_rank" ]; then
        mc_startup_warn "rules.local.yaml: rule for ${norm} would lower the risk (${safety}); rejected. A local rule can only raise risk."
        return 0
    fi
    if [ "$idx" != "-1" ] && [ "${POLICY_RULE_PATHS[$idx]}" = "$norm" ]; then
        POLICY_RULE_SAFETY[$idx]="$(printf '%s' "$safety" | tr '[:upper:]' '[:lower:]')"
    else
        policy_add_rule "$norm" "$safety" "$type" "local rule"
    fi
    return 0
}

# mc_apply_rules_overlay — <config>/rules.local.yaml, same schema as the
# shipped rules (path/safety entries). Raise-only: a rule that would lower a
# shipped risk is rejected with a warning. Call after load_policy_rules_from_yaml
# and before apply_policy_never_paths. Needs lib/policy.sh.
mc_apply_rules_overlay() {
    local file="${MC_CONFIG_DIR:-}/rules.local.yaml" line value cur_path="" cur_safety="" cur_type=""
    [ -n "${MC_CONFIG_DIR:-}" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        _mc_trim "$line"; line="$REPLY"
        [ -n "$line" ] || continue
        case "$line" in
            "- path:"*|"path:"*)
                _mc_overlay_entry "$cur_path" "$cur_safety" "$cur_type"
                value="${line#*path:}"
                _mc_trim "$value"; value="$REPLY"
                value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
                cur_path="$value"; cur_safety=""; cur_type="" ;;
            "type:"*)
                _mc_trim "${line#type:}"; cur_type="$REPLY" ;;
            "safety:"*)
                _mc_trim "${line#safety:}"; value="$REPLY"
                value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
                cur_safety="$value" ;;
        esac
    done < "$file"
    _mc_overlay_entry "$cur_path" "$cur_safety" "$cur_type"
    return 0
}

# --- category modes (V4 sections 4.4, 13) ------------------------------------
_MC_CATMODES_LOADED=0
# shellcheck disable=SC2034  # read by callers of mc_category_mode
MC_CATEGORY_MODE_SOURCE="default"

# mc_load_category_modes — idempotent. Defaults come from share/categories.tsv
# (tier): app-caches auto; every other regenerable and every review category
# review; report categories skip. <config>/category-modes.tsv overrides:
# id<TAB>mode<TAB>source, mode auto|review|skip, source user.
mc_load_category_modes() {
    local tsv="${PROJECT_DIR:-}/share/categories.tsv" file="${MC_CONFIG_DIR:-}/category-modes.tsv"
    local id _section tier _rest key n=0 mode source _extra known
    [ "$_MC_CATMODES_LOADED" = 1 ] && return 0
    _MC_CATMODES_LOADED=1
    [ -n "${PROJECT_DIR:-}" ] || tsv="$(mc_toolkit_root)/share/categories.tsv"
    if [ -f "$tsv" ]; then
        while IFS=$'\t' read -r id _section tier _rest || [ -n "$id" ]; do
            case "$id" in ''|'#'*) continue ;; esac
            key="${id//-/_}"
            case "$key" in *[!a-z0-9_]*) continue ;; esac
            eval "_MC_CATTIER_${key}=\$tier"
        done < "$tsv"
    fi
    [ -f "$file" ] && [ ! -L "$file" ] || return 0
    while IFS=$'\t' read -r id mode source _extra || [ -n "$id" ]; do
        n=$((n + 1))
        id="${id%$'\r'}"; source="${source%$'\r'}"; mode="${mode%$'\r'}"
        case "$id" in ''|'#'*) continue ;; esac
        case "$id" in
            [a-z]*) ;;
            *) mc_startup_warn "category-modes.tsv line ${n}: invalid category id; ignored."; continue ;;
        esac
        case "$id" in *[!a-z0-9-]*) mc_startup_warn "category-modes.tsv line ${n}: invalid category id; ignored."; continue ;; esac
        case "$mode" in
            auto|review|skip) ;;
            *) mc_startup_warn "category-modes.tsv line ${n}: mode must be auto, review or skip; ignored."; continue ;;
        esac
        if [ "$source" != "user" ]; then
            mc_startup_warn "category-modes.tsv line ${n}: source must be user; ignored."
            continue
        fi
        key="${id//-/_}"
        known=""
        eval "known=\"\${_MC_CATTIER_${key}:-}\""
        if [ -z "$known" ] && [ -f "$tsv" ]; then
            mc_startup_warn "category-modes.tsv line ${n}: unknown category '${id}'; ignored."
            continue
        fi
        eval "_MC_CATMODE_${key}=\$mode"
    done < "$file"
    return 0
}

mc_category_mode() {
    local id="${1:-}" key tier mode=""
    mc_load_category_modes
    key="${id//-/_}"
    case "$key" in ''|*[!a-z0-9_]*) return 1 ;; esac
    eval "mode=\"\${_MC_CATMODE_${key}:-}\""
    if [ -n "$mode" ]; then
        MC_CATEGORY_MODE_SOURCE="user"
    else
        eval "tier=\"\${_MC_CATTIER_${key}:-}\""
        [ -n "$tier" ] || return 1
        # shellcheck disable=SC2034  # read by callers
        MC_CATEGORY_MODE_SOURCE="default"
        case "$id:$tier" in
            app-caches:regenerable) mode=auto ;;
            *:report) mode=skip ;;
            *) mode=review ;;
        esac
    fi
    REPLY="$mode"
    printf '%s\n' "$mode"
}

mc_paths_print() {
    printf 'program=%s\nconfig=%s\nstate=%s\nquarantine=%s\nmode=%s\n' \
        "$MC_PROGRAM_DIR" "$MC_CONFIG_DIR" "$MC_STATE_DIR" "$MC_QUARANTINE_DIR" "$MC_PATHS_MODE"
}

_mc_paths_cli() {
    local root="" command="" arg1="" arg2="" n=0 rc=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --root)
                [ -n "${2:-}" ] || { echo "--root needs a directory." >&2; return 2; }
                root="$2"; shift 2 ;;
            *)
                n=$((n + 1))
                case "$n" in
                    1) command="$1" ;;
                    2) arg1="$1" ;;
                    3) arg2="$1" ;;
                    *) command="?" ;;
                esac
                shift ;;
        esac
    done
    command="${command:-print}"
    case "$command" in
        print|program|config|state|quarantine|mode|check-quarantine|ensure|run-dir) ;;
        *)
            echo "Usage: paths.sh [print|program|config|state|quarantine|mode|check-quarantine|ensure <kind> [run_id]|run-dir <id>] [--root DIR]" >&2
            return 2 ;;
    esac
    mc_paths_init "$root" || { printf '%s\n' "$MC_PATHS_ERROR" >&2; return 2; }
    case "$command" in
        print) mc_paths_print ;;
        program) printf '%s\n' "$MC_PROGRAM_DIR" ;;
        config) printf '%s\n' "$MC_CONFIG_DIR" ;;
        state) printf '%s\n' "$MC_STATE_DIR" ;;
        quarantine) printf '%s\n' "$MC_QUARANTINE_DIR" ;;
        mode) printf '%s\n' "$MC_PATHS_MODE" ;;
        check-quarantine) mc_quarantine_check || rc=2 ;;
        run-dir) mc_run_dir "$arg1" || rc=2 ;;
        ensure)
            if [ -z "$arg1" ]; then
                echo "Usage: paths.sh ensure config|state|quarantine|run <run_id>" >&2
                return 2
            fi
            mc_ensure_dir "$arg1" "$arg2" || rc=2 ;;
    esac
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$MC_PATHS_ERROR" >&2
    fi
    return "$rc"
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    _mc_paths_cli "$@"
    exit $?
fi
