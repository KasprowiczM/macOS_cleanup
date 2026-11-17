#!/usr/bin/env bash
# =============================================================================
# lib/cli_v4.sh - read-only listings and standalone commands of v4
# (contract V4 section 2.2). Bash 3.2 compatible. Sourcing has no side effects.
#
#   mc_cli_early "$@"      called by cleanup_all.sh before parse_args.
#       Returns 255 when the arguments are not a v4 standalone command (the
#       engine continues normally); otherwise the command ran and the return
#       value is the exit status. None of these commands scans or cleans.
#   mc_cli_v4_help         plain-text help lines for the flags below
#
#   --doctor [--json]                     mc_doctor_run                0 | 1 problem found
#   --history [--json] [--limit N]        mc_rm_history                0 | 2
#   --list-categories [--json]            mc_rm_categories             0 | 1 registry unreadable
#   --list-quarantine --json              mc_rm_quarantine             0 | 2
#   --schedule install|remove|status [--time HH:MM] [--weekday W] [--json] [--yes]
#                                         mc_schedule_run              0 | 1 | 2
#   --version                             prints 'macos-cleanup <VERSION>' 0
#
# Tolerated next to a command (no effect here): --cli --no-color --plain
# --quiet --non-interactive --lang <code> --log-level <level>. Anything else
# is a usage error (exit 2). --list-quarantine without --json, --version
# without a VERSION file and --cli alone are left to the engine (255).
# The only things written are the LaunchAgent plist and its log folder
# (--schedule install|remove); everything else is read-only.
# =============================================================================

# The MC_* and LANG_CODE variables below are read by the modules this file loads.
# shellcheck disable=SC2034
_CLI_V4_FILE="${BASH_SOURCE[0]:-$0}"
_CLI_V4_ROOT="$( cd "$(dirname "$_CLI_V4_FILE")/.." 2>/dev/null && pwd -P )"

# Translated message; falls back to the key when the dictionaries are absent.
_cli_t() {
    if command -v t >/dev/null 2>&1; then
        t "$@"
    else
        printf '%s\n' "$*"
    fi
}

_cli_usage() { # <message...>  -> exit status 2 for the caller to return
    printf '%s\n' "$*" >&2
    printf '%s\n' "$(_cli_t cli_see_help)" >&2
    return 2
}

# Source lib/<name>.sh for each name; a missing module is a clear exit 2.
_cli_load() {
    local m f
    for m in "$@"; do
        f="${_CLI_V4_ROOT}/lib/${m}.sh"
        if [ ! -r "$f" ]; then
            printf '%s\n' "$(_cli_t cli_v4_missing_module "lib/${m}.sh")" >&2
            return 2
        fi
        # shellcheck disable=SC1090
        . "$f"
    done
    return 0
}

# Resolve the toolkit directories (sets MC_* via lib/paths.sh, in this shell).
# Inside the engine config/defaults.sh has already set the quarantine defaults;
# mc_paths_init recognises them as the engine's own (MC_ENGINE_*), not as user
# overrides.
_cli_paths() {
    if ! type mc_paths_init >/dev/null 2>&1; then
        _cli_load paths || return 2
    fi
    if ! mc_paths_init "$_CLI_V4_ROOT"; then
        printf '%s\n' "${MC_PATHS_ERROR:-paths}" >&2
        return 2
    fi
    MC_LEGACY_LOGS_DIR="" MC_LEGACY_REPORTS_DIR="" MC_QUARANTINE_RUN_DIR_OVERRIDE="" MC_LEGACY_VARS_USED=""
    return 0
}

# _cli_field <json-row> <key>  -> REPLY (unquoted); 0 when the key is present.
_cli_field() {
    local row="$1" key="$2" re
    REPLY=""
    re="\"${key}\": ?(\"([^\"]*)\"|[^,}]*)"
    if [[ "$row" =~ $re ]]; then
        if [ -n "${BASH_REMATCH[2]}" ] || [ "${BASH_REMATCH[1]#\"}" != "${BASH_REMATCH[1]}" ]; then
            REPLY="${BASH_REMATCH[2]}"
        else
            REPLY="${BASH_REMATCH[1]}"
        fi
        return 0
    fi
    return 1
}

# _cli_bytes <n|null>  -> REPLY, binary units with one decimal, "-" when unknown.
_cli_bytes() {
    local n="$1" unit="B" whole frac
    case "$n" in ''|null|*[!0-9]*) REPLY="-"; return 0 ;; esac
    if [ "$n" -lt 1024 ]; then REPLY="${n} B"; return 0; fi
    whole="$n"; frac=0
    for unit in KiB MiB GiB TiB; do
        frac=$(( (whole % 1024) * 10 / 1024 ))
        whole=$(( whole / 1024 ))
        [ "$whole" -ge 1024 ] || break
    done
    REPLY="${whole}.${frac} ${unit}"
}

# ---------------------------------------------------------------------------
# History: newest first, one line per run
# ---------------------------------------------------------------------------
_cli_history_text() { # reads the JSON document on stdin
    local line n=0 rid date mode result est freed
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *'{"run_id"'*) ;;
            *) continue ;;
        esac
        _cli_field "$line" run_id; rid="$REPLY"
        _cli_field "$line" started_at || true; date="${REPLY:0:16}"; date="${date/T/ }"
        _cli_field "$line" mode || true; mode="${REPLY:-?}"
        _cli_field "$line" result || true; result="${REPLY:-?}"
        [ "$result" != "null" ] || result="?"
        [ "$mode" != "null" ] || mode="?"
        _cli_field "$line" estimated_bytes || true; _cli_bytes "$REPLY"; est="$REPLY"
        _cli_field "$line" measured_freed_bytes || true; _cli_bytes "$REPLY"; freed="$REPLY"
        [ -n "$date" ] || date="$rid"
        printf '%-16s  %-12s  %-9s  %s: %-10s  %s: %s\n' "$date" "$mode" "$result" \
            "$(_cli_t cli_v4_history_est)" "$est" "$(_cli_t cli_v4_history_freed)" "$freed"
        n=$(( n + 1 ))
    done
    [ "$n" -gt 0 ] || printf '%s\n' "$(_cli_t cli_v4_history_empty)"
}

_cli_categories_text() { # reads the JSON document on stdin
    local line n=0 id tier mode
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *'{"id"'*) ;;
            *) continue ;;
        esac
        _cli_field "$line" id; id="$REPLY"
        [ "$id" != "id" ] || continue   # a registry header row, not a category
        _cli_field "$line" tier || true; tier="$REPLY"
        _cli_field "$line" mode || true; mode="$REPLY"
        printf '%-22s  %-12s  %s\n' "$id" "$tier" "$mode"
        n=$(( n + 1 ))
    done
    [ "$n" -gt 0 ] || printf '%s\n' "$(_cli_t cli_v4_categories_empty)"
}

# ---------------------------------------------------------------------------
# Schedule install: explicit confirmation
# ---------------------------------------------------------------------------
# 0 = confirmed, 2 = not confirmed (preview printed).
_cli_schedule_confirm() { # <time> <weekday> <yes>
    local time="${1:-${MACOS_CLEANUP_SCHEDULE_TIME:-10:30}}"
    local wday="${2:-${MACOS_CLEANUP_SCHEDULE_WEEKDAY:-sun}}" yes="$3" ans=""
    # Bad values are reported by mc_schedule_install itself; only gate here.
    [ "$yes" -eq 1 ] && return 0
    printf '%s\n' "$(_cli_t cli_v4_schedule_preview)"
    printf '  %s\n' "$(mc_schedule_plist_path)"
    printf '  %s %s, %s\n' "$(_cli_t cli_v4_schedule_when)" "$time" "$wday"
    printf '  %s /bin/bash %s/cleanup_all.sh --cli --unattended\n' "$(_cli_t cli_v4_schedule_runs)" "${MC_PROGRAM_DIR%/}"
    if [ -t 0 ] && [ -t 1 ]; then
        printf '%s ' "$(_cli_t cli_v4_schedule_ask)"
        IFS= read -r ans || ans=""
        case "$ans" in y|Y|yes|YES|t|T|tak|j|J|ja|s|S|si|sì|o|O|oui|sim) return 0 ;; esac
        printf '%s\n' "$(_cli_t cli_v4_schedule_declined)" >&2
        return 2
    fi
    printf '%s\n' "$(_cli_t cli_v4_schedule_needs_yes)" >&2
    return 2
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
_cli_dispatch() {
    local cmd="" ver=0 json=0 limit="" time="" wday="" yes=0 verb="" other="" a v rc=0
    local lang=""
    while [ "$#" -gt 0 ]; do
        a="$1"
        case "$a" in
            --doctor|--history|--list-categories|--list-quarantine)
                if [ -n "$cmd" ] && [ "$cmd" != "$a" ]; then
                    _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "$a")"; return 2
                fi
                cmd="$a"; shift ;;
            --schedule)
                if [ -n "$cmd" ] && [ "$cmd" != "$a" ]; then
                    _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "$a")"; return 2
                fi
                cmd="$a"; verb="${2-}"
                if [ "$#" -ge 2 ]; then shift 2; else shift; fi ;;
            --version|-V) ver=1; shift ;;
            --json) json=1; shift ;;
            --yes) yes=1; shift ;;
            --limit|--time|--weekday|--lang|--log-level)
                if [ "$#" -lt 2 ]; then
                    _cli_usage "$(_cli_t cli_v4_usage_value "$a")"; return 2
                fi
                v="$2"
                case "$a" in
                    --limit) limit="$v" ;;
                    --time) time="$v" ;;
                    --weekday) wday="$v" ;;
                    --lang) lang="$v" ;;
                    --log-level) ;;
                esac
                shift 2 ;;
            --cli|--no-color|--plain|--quiet|--non-interactive) shift ;;
            *) [ -n "$other" ] || other="$a"; shift ;;
        esac
    done

    # Messages in the requested language when it is one of ours.
    case "$lang" in pl|en|de|es|fr|it|pt) LANG_CODE="$lang" ;; esac

    if [ -z "$cmd" ]; then
        # --version alone with a VERSION file; everything else is the engine's.
        if [ "$ver" -eq 1 ] && [ -z "$other" ] && [ -f "${_CLI_V4_ROOT}/VERSION" ]; then
            local ln=""
            IFS= read -r ln < "${_CLI_V4_ROOT}/VERSION" || true
            printf 'macos-cleanup %s\n' "$ln"
            return 0
        fi
        return 255
    fi
    # The engine lists the quarantine in text itself.
    if [ "$cmd" = "--list-quarantine" ] && [ "$json" -eq 0 ]; then
        return 255
    fi

    # Validation: only options that belong to the command.
    if [ -n "$other" ]; then
        _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "$other")"; return 2
    fi
    if [ "$ver" -eq 1 ]; then
        _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "--version")"; return 2
    fi
    if [ -n "$limit" ] && [ "$cmd" != "--history" ]; then
        _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "--limit")"; return 2
    fi
    if [ "$cmd" != "--schedule" ]; then
        [ -z "$time" ] || { _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "--time")"; return 2; }
        [ -z "$wday" ] || { _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "--weekday")"; return 2; }
        [ "$yes" -eq 0 ] || { _cli_usage "$(_cli_t cli_v4_usage_combo "$cmd" "--yes")"; return 2; }
    fi
    if [ -n "$limit" ]; then
        case "$limit" in
            ''|*[!0-9]*|0) _cli_usage "$(_cli_t cli_v4_usage_value "--limit")"; return 2 ;;
        esac
    fi

    _cli_paths || return 2

    case "$cmd" in
        --doctor)
            _cli_load doctor || return 2
            LANG="${LANG-}"   # doctor.sh reads $LANG; the engine runs with set -u
            if [ "$json" -eq 1 ]; then
                mc_doctor_run --json || rc=$?
            else
                mc_doctor_run || rc=$?
            fi
            return "$rc"
            ;;
        --history)
            _cli_load readmodels || return 2
            if [ "$json" -eq 1 ]; then
                mc_rm_history "$MC_STATE_DIR" "$MC_QUARANTINE_DIR" "${limit:-200}" || rc=$?
            else
                local doc
                doc="$(mc_rm_history "$MC_STATE_DIR" "$MC_QUARANTINE_DIR" "${limit:-200}")" || rc=$?
                if [ "$rc" -eq 0 ]; then printf '%s\n' "$doc" | _cli_history_text; fi
            fi
            return "$rc"
            ;;
        --list-categories)
            _cli_load readmodels || return 2
            local reg="${MC_PROGRAM_DIR%/}/share/categories.tsv"
            [ -r "$reg" ] || reg="${_CLI_V4_ROOT}/share/categories.tsv"
            local modes="${MC_CONFIG_DIR%/}/category-modes.tsv"
            if [ "$json" -eq 1 ]; then
                mc_rm_categories "$reg" "$modes" "$MC_STATE_DIR" || rc=$?
            else
                local cdoc
                cdoc="$(mc_rm_categories "$reg" "$modes" "$MC_STATE_DIR")" || rc=$?
                printf '%s\n' "$cdoc" | _cli_categories_text
            fi
            return "$rc"
            ;;
        --list-quarantine)
            _cli_load readmodels || return 2
            mc_rm_quarantine "$MC_QUARANTINE_DIR" || rc=$?
            return "$rc"
            ;;
        --schedule)
            case "$verb" in
                install|remove|status) ;;
                *) _cli_usage "$(_cli_t cli_v4_schedule_verb "$verb")"; return 2 ;;
            esac
            _cli_load schedule || return 2
            if [ "$verb" = "install" ]; then
                _cli_schedule_confirm "$time" "$wday" "$yes" || return 2
            fi
            local -a sargs=()
            [ -z "$time" ] || sargs=("${sargs[@]+"${sargs[@]}"}" --time "$time")
            [ -z "$wday" ] || sargs=("${sargs[@]+"${sargs[@]}"}" --weekday "$wday")
            [ "$json" -eq 0 ] || sargs=("${sargs[@]+"${sargs[@]}"}" --json)
            if [ "${#sargs[@]}" -gt 0 ]; then
                mc_schedule_run "$verb" "${sargs[@]}" || rc=$?
            else
                mc_schedule_run "$verb" || rc=$?
            fi
            return "$rc"
            ;;
    esac
    return 255
}

mc_cli_early() {
    local rc=0 saved
    # The engine's EXIT/ERR/INT handlers are defined further down
    # cleanup_all.sh and there is nothing for them to clean up here (no lock,
    # no run directory, no sudo). Drop them while a command runs, even when
    # a module aborts under set -u; put them back for the engine on 255.
    saved="$(trap -p)"
    trap - EXIT ERR INT TERM
    _cli_dispatch "$@" || rc=$?
    if [ "$rc" -eq 255 ] && [ -n "$saved" ]; then
        eval "$saved"
    fi
    return "$rc"
}

# Help fragment for the engine's --help.
mc_cli_v4_help() {
    printf '%s\n' "$(_cli_t cli_v4_help_title):"
    printf '  --doctor [--json]              %s\n' "$(_cli_t cli_v4_help_doctor)"
    printf '  --history [--json] [--limit N] %s\n' "$(_cli_t cli_v4_help_history)"
    printf '  --list-categories [--json]     %s\n' "$(_cli_t cli_v4_help_categories)"
    printf '  --list-quarantine --json       %s\n' "$(_cli_t cli_v4_help_quarantine)"
    printf '  --schedule install|remove|status [--time HH:MM] [--weekday W] [--yes]\n'
    printf '                                 %s\n' "$(_cli_t cli_v4_help_schedule)"
    printf '  --cli                          %s\n' "$(_cli_t cli_v4_help_cli)"
}
