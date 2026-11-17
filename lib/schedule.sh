#!/usr/bin/env bash
# =============================================================================
# lib/schedule.sh - opt-in LaunchAgent for unattended runs (contract V4 2.2)
# Bash 3.2 compatible. Sourcing has no side effects.
#
#   mc_schedule_run <install|remove|status> [--time HH:MM] [--weekday W] [--json]
#       The command-line entry point (cleanup_all.sh --schedule <verb>).
#   mc_schedule_install [HH:MM] [weekday]
#   mc_schedule_remove
#   mc_schedule_status
#   mc_schedule_render_plist <HH:MM> <weekday> <program> <state> [config] [quarantine]
#   mc_schedule_validate_time <HH:MM>        sets MC_SC_TIME, MC_SC_HOUR, MC_SC_MINUTE
#   mc_schedule_validate_weekday <word>      sets MC_SC_WEEKDAY, MC_SC_WEEKDAY_NUM
#   mc_schedule_read_plist [file]            file-only facts, no launchctl (used by doctor)
#   mc_schedule_next_run <HH:MM> <weekday>   sets REPLY
#   mc_schedule_last_run <state_dir>         sets REPLY (newest unattended run)
#
# The job runs `/bin/bash <program>/cleanup_all.sh --cli --unattended`: the
# regenerable tier through quarantine, then purge of expired quarantine runs.
# Nothing in this file runs a cleanup. The only thing it ever deletes is its
# own plist (and only that file name). Everything except the plist and the
# log folder is read-only. Directories come from the contract variables
# MC_PROGRAM_DIR, MC_STATE_DIR, MC_CONFIG_DIR, MC_QUARANTINE_DIR (lib/paths.sh)
# and HOME; the cadence defaults come from settings MACOS_CLEANUP_SCHEDULE_TIME
# (10:30) and MACOS_CLEANUP_SCHEDULE_WEEKDAY (sun).
# =============================================================================

if ! command -v _rm_json_str >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]:-$0}")/readmodels.sh"
fi

MC_SCHEDULE_LABEL="com.github.kasprowiczm.macos-cleanup"
# launchd's default PATH lacks Homebrew; cover Apple Silicon and Intel.
_SC_LAUNCHD_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
_SC_LAUNCHCTL_TIMEOUT=10
_SC_PLUTIL_TIMEOUT=10
# Flags a scheduled job must never carry (mutating or interactive beyond what
# --unattended itself performs, or a different mode altogether).
_SC_FORBIDDEN_ARGS=" --permanent --include-review --interactive --auto-safe --yes --apply --restore --purge-quarantine --prune-artifacts --schedule --dry-run --from-plan --tui "

MC_SC_MSG=""
MC_SC_OK=0

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# Strict HH:MM, 24 hour, two digits each (00:00 .. 23:59). Nothing else.
mc_schedule_validate_time() {
    local t="${1-}"
    MC_SC_TIME=""; MC_SC_HOUR=""; MC_SC_MINUTE=""
    case "$t" in
        [01][0123456789]:[012345][0123456789]|2[0123]:[012345][0123456789]) ;;
        *) return 1 ;;
    esac
    MC_SC_TIME="$t"
    MC_SC_HOUR=$((10#${t:0:2}))
    MC_SC_MINUTE=$((10#${t:3:2}))
}

# daily | mon tue wed thu fri sat sun  (launchd: Sunday = 0)
mc_schedule_validate_weekday() {
    MC_SC_WEEKDAY=""; MC_SC_WEEKDAY_NUM=""
    case "${1-}" in
        daily) MC_SC_WEEKDAY="daily" ;;
        sun) MC_SC_WEEKDAY="sun"; MC_SC_WEEKDAY_NUM=0 ;;
        mon) MC_SC_WEEKDAY="mon"; MC_SC_WEEKDAY_NUM=1 ;;
        tue) MC_SC_WEEKDAY="tue"; MC_SC_WEEKDAY_NUM=2 ;;
        wed) MC_SC_WEEKDAY="wed"; MC_SC_WEEKDAY_NUM=3 ;;
        thu) MC_SC_WEEKDAY="thu"; MC_SC_WEEKDAY_NUM=4 ;;
        fri) MC_SC_WEEKDAY="fri"; MC_SC_WEEKDAY_NUM=5 ;;
        sat) MC_SC_WEEKDAY="sat"; MC_SC_WEEKDAY_NUM=6 ;;
        *) return 1 ;;
    esac
}

_sc_weekday_from_num() { # sets REPLY
    case "${1-}" in
        0|7) REPLY="sun" ;; 1) REPLY="mon" ;; 2) REPLY="tue" ;; 3) REPLY="wed" ;;
        4) REPLY="thu" ;; 5) REPLY="fri" ;; 6) REPLY="sat" ;; *) REPLY="" ;;
    esac
}

mc_schedule_plist_path() {
    printf '%s/Library/LaunchAgents/%s.plist' "${HOME%/}" "$MC_SCHEDULE_LABEL"
}

# ---------------------------------------------------------------------------
# Plist generation
# ---------------------------------------------------------------------------

# XML text escaping into REPLY. Control characters cannot be represented in
# XML 1.0 at all, so a value that contains one is refused (return 1).
_sc_xml_escape() {
    local s="${1-}"
    case "$s" in *[[:cntrl:]]*) REPLY=""; return 1 ;; esac
    # bash 5.2+ treats an unquoted & in a replacement as "the matched text"
    # (patsub_replacement); the replacements below need a literal &.
    shopt -u patsub_replacement 2>/dev/null || true
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    REPLY="$s"
}

# Sets the array MC_SC_ARGS to the job's command line.
mc_schedule_program_args() {
    MC_SC_ARGS=("/bin/bash" "${1%/}/cleanup_all.sh" "--cli" "--unattended")
}

# 0 when MC_SC_ARGS (or the arguments given) carry --unattended and none of
# the forbidden flags.
_sc_args_safe() {
    local a seen_unattended=0
    for a in "$@"; do
        case "$a" in
            --unattended) seen_unattended=1 ;;
        esac
        case "$_SC_FORBIDDEN_ARGS" in *" $a "*) return 1 ;; esac
    done
    [ "$seen_unattended" -eq 1 ]
}

_sc_env_entry() { # <key> <value> -> appended to _SC_ENV_XML
    local k v
    _sc_xml_escape "$1" || return 1; k="$REPLY"
    _sc_xml_escape "$2" || return 1; v="$REPLY"
    _SC_ENV_XML="${_SC_ENV_XML}        <key>${k}</key>
        <string>${v}</string>
"
}

# mc_schedule_render_plist <HH:MM> <weekday> <program_dir> <state_dir> [config_dir] [quarantine_dir]
# Prints the plist. Returns 2 on an invalid time or weekday, 1 when a value
# cannot be expressed in XML.
mc_schedule_render_plist() {
    local time="${1-}" wday="${2-}" program="${3-}" state="${4-}" config="${5-}" quar="${6-}"
    local a args_xml="" cal_xml="" label_x out_x err_x
    mc_schedule_validate_time "$time" || return 2
    mc_schedule_validate_weekday "$wday" || return 2
    mc_schedule_program_args "$program"
    _sc_args_safe "${MC_SC_ARGS[@]}" || return 1
    for a in "${MC_SC_ARGS[@]}"; do
        _sc_xml_escape "$a" || return 1
        args_xml="${args_xml}        <string>${REPLY}</string>
"
    done
    _SC_ENV_XML=""
    _sc_env_entry PATH "$_SC_LAUNCHD_PATH" || return 1
    _sc_env_entry MACOS_CLEANUP_STATE_DIR "$state" || return 1
    [ -z "$config" ] || _sc_env_entry MACOS_CLEANUP_CONFIG_DIR "$config" || return 1
    [ -z "$quar" ] || _sc_env_entry MACOS_CLEANUP_QUARANTINE_DIR "$quar" || return 1
    if [ "$MC_SC_WEEKDAY" = "daily" ]; then
        cal_xml="        <key>Hour</key>
        <integer>${MC_SC_HOUR}</integer>
        <key>Minute</key>
        <integer>${MC_SC_MINUTE}</integer>"
    else
        cal_xml="        <key>Weekday</key>
        <integer>${MC_SC_WEEKDAY_NUM}</integer>
        <key>Hour</key>
        <integer>${MC_SC_HOUR}</integer>
        <key>Minute</key>
        <integer>${MC_SC_MINUTE}</integer>"
    fi
    _sc_xml_escape "$MC_SCHEDULE_LABEL" || return 1; label_x="$REPLY"
    _sc_xml_escape "${state%/}/logs/launchd.out" || return 1; out_x="$REPLY"
    _sc_xml_escape "${state%/}/logs/launchd.err" || return 1; err_x="$REPLY"
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label_x}</string>
    <key>ProgramArguments</key>
    <array>
${args_xml}    </array>
    <key>EnvironmentVariables</key>
    <dict>
${_SC_ENV_XML}    </dict>
    <key>StartCalendarInterval</key>
    <dict>
${cal_xml}
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${out_x}</string>
    <key>StandardErrorPath</key>
    <string>${err_x}</string>
</dict>
</plist>
PLIST
}

# ---------------------------------------------------------------------------
# Reading the installed plist (files only, no launchctl)
# ---------------------------------------------------------------------------

_sc_xml_unescape() { # sets REPLY
    local s="${1-}"
    shopt -u patsub_replacement 2>/dev/null || true   # see _sc_xml_escape
    s="${s//&lt;/<}"; s="${s//&gt;/>}"; s="${s//&quot;/\"}"; s="${s//&apos;/\'}"; s="${s//&amp;/&}"
    REPLY="$s"
}

# Sets MC_SC_P_EXISTS (0|1), MC_SC_P_TIME (HH:MM or ""), MC_SC_P_WEEKDAY (word or ""),
# MC_SC_P_ARGS (array). Returns 1 when the file does not exist.
mc_schedule_read_plist() {
    local file="${1:-$(mc_schedule_plist_path)}" line key="" in_args=0 hour="" minute="" wnum="" v
    MC_SC_P_EXISTS=0; MC_SC_P_TIME=""; MC_SC_P_WEEKDAY=""; MC_SC_P_ARGS=()
    [ -f "$file" ] || [ -L "$file" ] || return 1
    MC_SC_P_EXISTS=1
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *'<key>ProgramArguments</key>'*) in_args=1; continue ;;
            *'</array>'*) in_args=0; continue ;;
            *'<key>'*'</key>'*)
                key="${line#*<key>}"; key="${key%%</key>*}"; continue ;;
            *'<string>'*'</string>'*)
                if [ "$in_args" -eq 1 ]; then
                    v="${line#*<string>}"; v="${v%%</string>*}"
                    _sc_xml_unescape "$v"
                    MC_SC_P_ARGS[${#MC_SC_P_ARGS[@]}]="$REPLY"
                fi
                ;;
            *'<integer>'*'</integer>'*)
                v="${line#*<integer>}"; v="${v%%</integer>*}"
                case "$key" in
                    Hour) hour="$v" ;; Minute) minute="$v" ;; Weekday) wnum="$v" ;;
                esac
                ;;
        esac
    done < "$file"
    case "$hour" in ''|*[!0-9]*) hour="" ;; esac
    case "$minute" in ''|*[!0-9]*) minute="" ;; esac
    if [ -n "$hour" ] && [ -n "$minute" ] && [ "$((10#$hour))" -le 23 ] && [ "$((10#$minute))" -le 59 ]; then
        printf -v MC_SC_P_TIME '%02d:%02d' "$((10#$hour))" "$((10#$minute))"
    fi
    if [ -n "$MC_SC_P_TIME" ]; then
        if [ -n "$wnum" ]; then
            _sc_weekday_from_num "$wnum"; MC_SC_P_WEEKDAY="$REPLY"
        else
            MC_SC_P_WEEKDAY="daily"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Next and last run
# ---------------------------------------------------------------------------

# REPLY = YYYY-MM-DDTHH:MM of the next fire time, or "" when it cannot be derived.
mc_schedule_next_run() {
    local time="${1-}" wday="${2-}" now w hh mm now_min target_min delta anchor day parts
    REPLY=""
    mc_schedule_validate_time "$time" || return 1
    mc_schedule_validate_weekday "$wday" || return 1
    _rm_now; now="$REPLY"
    [ "$now" -gt 0 ] || return 1
    parts="$(date -r "$now" '+%w %H %M' 2>/dev/null)" || return 1
    read -r w hh mm <<EOF
$parts
EOF
    case "$w$hh$mm" in ''|*[!0-9]*) return 1 ;; esac
    now_min=$(( 10#$hh * 60 + 10#$mm ))
    target_min=$(( MC_SC_HOUR * 60 + MC_SC_MINUTE ))
    if [ "$MC_SC_WEEKDAY" = "daily" ]; then
        delta=0
    else
        delta=$(( (MC_SC_WEEKDAY_NUM - w + 7) % 7 ))
    fi
    if [ "$delta" -eq 0 ] && [ "$target_min" -le "$now_min" ]; then
        if [ "$MC_SC_WEEKDAY" = "daily" ]; then delta=1; else delta=7; fi
    fi
    # Anchor at noon of the target day so a DST shift cannot change the date.
    anchor=$(( now + delta * 86400 + (720 - now_min) * 60 ))
    day="$(date -r "$anchor" '+%Y-%m-%d' 2>/dev/null)" || return 1
    REPLY="${day}T${MC_SC_TIME}"
}

# REPLY = started_at of the newest unattended run under <state>/runs, or "".
mc_schedule_last_run() {
    local runs="${1%/}/runs" d n=0 mode started
    local -a dirs=()
    REPLY=""
    [ -d "$runs" ] || return 1
    for d in "$runs"/*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        dirs[${#dirs[@]}]="$d"
    done
    n=${#dirs[@]}
    while [ "$n" -gt 0 ] && [ "$n" -gt $(( ${#dirs[@]} - 200 )) ]; do
        n=$(( n - 1 ))
        d="${dirs[$n]}"
        if _rm_flat_get "$d/run.json" mode; then
            mode="$REPLY"
            if [ "$mode" = "unattended" ]; then
                if _rm_flat_get "$d/run.json" started_at; then
                    started="$REPLY"
                else
                    started="${d##*/}"
                fi
                REPLY="$started"
                return 0
            fi
        fi
    done
    REPLY=""
    return 1
}

# ---------------------------------------------------------------------------
# launchctl wrappers (every call under a timeout; stderr kept for the report)
# ---------------------------------------------------------------------------

# After one timeout the remaining calls of the same command are skipped
# (reported as timed out) so a hung launchd costs one timeout, not seven.
_SC_HUNG=0
_sc_launchctl() {
    if [ "$_SC_HUNG" = "1" ]; then
        RM_OUT=""; RM_RC=124; RM_TIMED_OUT=1
        return 124
    fi
    RM_MERGE_ERR=1 _rm_run_timeout "$_SC_LAUNCHCTL_TIMEOUT" launchctl "$@" || {
        [ "$RM_TIMED_OUT" != "1" ] || _SC_HUNG=1
        return "$RM_RC"
    }
}

# One-line, bounded excerpt of RM_OUT for messages.
_sc_excerpt() {
    local s="${RM_OUT-}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "${s:0:300}"
}

# Sets MC_SC_LOADED to 1, 0 or "" (unknown: launchctl hung or cannot run) and
# MC_SC_PRINT to the `launchctl print` text.
_sc_probe_loaded() {
    MC_SC_LOADED=""; MC_SC_PRINT=""
    if _sc_launchctl print "gui/${UID}/${MC_SCHEDULE_LABEL}"; then
        MC_SC_LOADED=1; MC_SC_PRINT="$RM_OUT"
    elif [ "$RM_TIMED_OUT" = "1" ] || [ "$RM_RC" -eq 127 ]; then
        MC_SC_LOADED=""
    else
        MC_SC_LOADED=0
    fi
}

# ---------------------------------------------------------------------------
# Status collection
# ---------------------------------------------------------------------------

# Fills MC_SC_INSTALLED, MC_SC_LOADED, MC_SC_TIME_R, MC_SC_WEEKDAY_R,
# MC_SC_NEXT, MC_SC_LASTEXIT, MC_SC_LASTRUN, MC_SC_UNATTENDED. Read-only.
_sc_collect() {
    local plist re
    plist="$(mc_schedule_plist_path)"
    MC_SC_INSTALLED=0; MC_SC_TIME_R=""; MC_SC_WEEKDAY_R=""; MC_SC_NEXT=""
    MC_SC_LASTEXIT=""; MC_SC_LASTRUN=""; MC_SC_UNATTENDED=0
    mc_schedule_read_plist "$plist" || true
    [ "$MC_SC_P_EXISTS" -eq 1 ] && MC_SC_INSTALLED=1
    MC_SC_TIME_R="$MC_SC_P_TIME"; MC_SC_WEEKDAY_R="$MC_SC_P_WEEKDAY"
    if [ "${#MC_SC_P_ARGS[@]}" -gt 0 ] && _sc_args_safe "${MC_SC_P_ARGS[@]}"; then
        MC_SC_UNATTENDED=1
    fi
    _sc_probe_loaded
    re='last exit code = (-?[0-9]+)'
    if [ "$MC_SC_LOADED" = "1" ] && [[ "$MC_SC_PRINT" =~ $re ]]; then
        MC_SC_LASTEXIT="${BASH_REMATCH[1]}"
    fi
    if [ -n "$MC_SC_TIME_R" ] && [ "$MC_SC_INSTALLED" -eq 1 ]; then
        if mc_schedule_next_run "$MC_SC_TIME_R" "$MC_SC_WEEKDAY_R"; then
            MC_SC_NEXT="$REPLY"
        fi
    fi
    if [ -n "${MC_STATE_DIR:-}" ] && mc_schedule_last_run "$MC_STATE_DIR"; then
        MC_SC_LASTRUN="$REPLY"
    fi
}

mc_schedule_status() {
    _SC_HUNG=0
    _sc_collect
    MC_SC_OK=1
    if [ "$MC_SC_INSTALLED" -eq 0 ]; then
        MC_SC_MSG="The schedule is not installed."
    elif [ "$MC_SC_LOADED" = "1" ]; then
        MC_SC_MSG="The schedule is installed and loaded."
    elif [ "$MC_SC_LOADED" = "0" ]; then
        MC_SC_MSG="The plist exists but launchd has not loaded it."
    else
        MC_SC_MSG="The plist exists; launchd did not answer, so it is not known whether it is loaded."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# install / remove
# ---------------------------------------------------------------------------

_sc_fail() { MC_SC_OK=0; MC_SC_MSG="$1"; }

mc_schedule_install() {
    local time="${1:-${MACOS_CLEANUP_SCHEDULE_TIME:-10:30}}"
    local wday="${2:-${MACOS_CLEANUP_SCHEDULE_WEEKDAY:-sun}}"
    local program="${MC_PROGRAM_DIR:-}" state="${MC_STATE_DIR:-}"
    local plist agents tmp lint_note="" domain boot_err="" label="$MC_SCHEDULE_LABEL" rc
    _SC_HUNG=0

    if ! mc_schedule_validate_time "$time"; then
        _sc_fail "Invalid time '${time}': use HH:MM, 24 hour clock (for example 10:30)."
        _sc_collect; return 2
    fi
    if ! mc_schedule_validate_weekday "$wday"; then
        _sc_fail "Invalid weekday '${wday}': use daily, mon, tue, wed, thu, fri, sat or sun."
        _sc_collect; return 2
    fi
    case "${HOME:-}" in /*) ;; *) _sc_fail "HOME is not an absolute path."; _sc_collect; return 2 ;; esac
    case "$program" in /*) ;; *) _sc_fail "The program directory is not known (MC_PROGRAM_DIR)."; _sc_collect; return 2 ;; esac
    case "$state" in /*) ;; *) _sc_fail "The state directory is not known (MC_STATE_DIR)."; _sc_collect; return 2 ;; esac
    if [ ! -f "${program%/}/cleanup_all.sh" ]; then
        _sc_fail "Nothing to schedule: ${program%/}/cleanup_all.sh does not exist."
        _sc_collect; return 1
    fi

    plist="$(mc_schedule_plist_path)"
    agents="${plist%/*}"
    domain="gui/${UID}"
    if ! mkdir -p "$agents" 2>/dev/null; then
        _sc_fail "Could not create ${agents}."
        _sc_collect; return 1
    fi
    if ! mkdir -p "${state%/}/logs" 2>/dev/null; then
        _sc_fail "Could not create the log folder ${state%/}/logs."
        _sc_collect; return 1
    fi
    chmod 700 "${state%/}/logs" 2>/dev/null || true

    tmp="${plist}.tmp.$$"
    if ! mc_schedule_render_plist "$time" "$wday" "$program" "$state" "${MC_CONFIG_DIR:-}" "${MC_QUARANTINE_DIR:-}" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        _sc_fail "Could not generate the plist: a path contains a character that cannot be written."
        _sc_collect; return 1
    fi
    if command -v plutil >/dev/null 2>&1; then
        if _rm_run_timeout "$_SC_PLUTIL_TIMEOUT" plutil -lint "$tmp"; then
            lint_note=""
        elif [ "$RM_TIMED_OUT" = "1" ]; then
            lint_note=" (plutil -lint timed out, so the plist was not validated)"
        else
            rm -f "$tmp"
            _sc_fail "The generated plist failed plutil -lint; nothing was installed."
            _sc_collect; return 1
        fi
    fi
    chmod 644 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$plist" 2>/dev/null; then
        rm -f "$tmp"
        _sc_fail "Could not write ${plist}."
        _sc_collect; return 1
    fi

    # Replace a running instance: bootout (failure is fine, it may not be
    # loaded), clear a stale "disabled" override, bootstrap, and fall back to
    # the legacy `load -w`.
    _sc_launchctl bootout "${domain}/${label}" || _sc_launchctl bootout "$domain" "$plist" || true
    _sc_launchctl enable "${domain}/${label}" || true
    if ! _sc_launchctl bootstrap "$domain" "$plist"; then
        boot_err="$(_sc_excerpt)"
        if ! _sc_launchctl load -w "$plist"; then
            boot_err="${boot_err:+${boot_err} / }$(_sc_excerpt)"
        fi
    fi
    _sc_launchctl enable "${domain}/${label}" || true

    # Never claim success without proof that launchd has the job.
    _sc_probe_loaded
    if [ "$MC_SC_LOADED" = "1" ]; then
        MC_SC_OK=1
        MC_SC_MSG="Installed and loaded: ${wday} at ${MC_SC_TIME}.${lint_note}"
        rc=0
    else
        MC_SC_OK=0
        if [ "$MC_SC_LOADED" = "0" ]; then
            MC_SC_MSG="The plist was written but launchd did not load it${boot_err:+ (${boot_err})}. It will be picked up at the next login; run the install again from a logged-in desktop session to load it now."
        else
            MC_SC_MSG="The plist was written but launchctl did not answer, so it is not known whether it is loaded${boot_err:+ (${boot_err})}."
        fi
        rc=1
    fi
    _sc_collect
    return "$rc"
}

mc_schedule_remove() {
    local plist domain label="$MC_SCHEDULE_LABEL" removed=0 rc=0
    _SC_HUNG=0
    plist="$(mc_schedule_plist_path)"
    domain="gui/${UID}"

    _sc_probe_loaded
    if [ "$MC_SC_LOADED" != "0" ]; then
        # loaded, or launchd did not answer: try to boot it out either way.
        _sc_launchctl bootout "${domain}/${label}" || _sc_launchctl bootout "$domain" "$plist" || true
    fi
    if [ -e "$plist" ] || [ -L "$plist" ]; then
        # Only this tool's own plist, never anything else.
        if [ "${plist##*/}" = "${label}.plist" ] && rm -f "$plist" 2>/dev/null; then
            removed=1
        else
            _sc_fail "Could not delete ${plist}."
            _sc_collect; return 1
        fi
    fi
    _sc_probe_loaded
    if [ "$MC_SC_LOADED" = "1" ]; then
        MC_SC_OK=0
        MC_SC_MSG="The plist is gone, but launchd still has the job loaded. Run: launchctl bootout ${domain}/${label}"
        rc=1
    elif [ "$MC_SC_LOADED" = "" ]; then
        MC_SC_OK=0
        MC_SC_MSG="launchctl did not answer, so it is not known whether the job is still loaded."
        rc=1
    else
        MC_SC_OK=1
        if [ "$removed" -eq 1 ]; then
            MC_SC_MSG="The schedule was removed."
        else
            MC_SC_MSG="The schedule was not installed; nothing to remove."
        fi
    fi
    _sc_collect
    return "$rc"
}

# ---------------------------------------------------------------------------
# Rendering and the CLI entry point
# ---------------------------------------------------------------------------

_sc_weekday_name() { # sets REPLY
    case "${1-}" in
        daily) REPLY="every day" ;; sun) REPLY="Sunday" ;; mon) REPLY="Monday" ;;
        tue) REPLY="Tuesday" ;; wed) REPLY="Wednesday" ;; thu) REPLY="Thursday" ;;
        fri) REPLY="Friday" ;; sat) REPLY="Saturday" ;; *) REPLY="unknown" ;;
    esac
}

mc_schedule_json() { # <action>
    local action="${1-status}" plist a first=1 args_json="" ok loaded
    plist="$(mc_schedule_plist_path)"
    _rm_header
    printf ',\n  "action": "%s"' "$action"
    [ "$MC_SC_OK" -eq 1 ] && ok=true || ok=false
    printf ',\n  "ok": %s' "$ok"
    _rm_json_str "$MC_SC_MSG"; printf ',\n  "message": %s' "$REPLY"
    [ "$MC_SC_INSTALLED" -eq 1 ] && ok=true || ok=false
    printf ',\n  "installed": %s' "$ok"
    case "$MC_SC_LOADED" in 1) loaded=true ;; 0) loaded=false ;; *) loaded=null ;; esac
    printf ',\n  "loaded": %s' "$loaded"
    _rm_json_str "$MC_SCHEDULE_LABEL"; printf ',\n  "label": %s' "$REPLY"
    _rm_json_str "$plist"; printf ',\n  "plist": %s' "$REPLY"
    _rm_str_or_null "$MC_SC_TIME_R"; printf ',\n  "time": %s' "$REPLY"
    _rm_str_or_null "$MC_SC_WEEKDAY_R"; printf ',\n  "weekday": %s' "$REPLY"
    _rm_str_or_null "$MC_SC_NEXT"; printf ',\n  "next_run": %s' "$REPLY"
    _rm_num "$MC_SC_LASTEXIT"
    if [ "$REPLY" = "null" ] && [ -n "$MC_SC_LASTEXIT" ]; then REPLY="$MC_SC_LASTEXIT"; fi
    printf ',\n  "last_exit_status": %s' "$REPLY"
    _rm_str_or_null "$MC_SC_LASTRUN"; printf ',\n  "last_run": %s' "$REPLY"
    if [ "${#MC_SC_P_ARGS[@]}" -gt 0 ]; then
        for a in "${MC_SC_P_ARGS[@]}"; do
            _rm_json_str "$a"
            if [ "$first" -eq 1 ]; then first=0; args_json="$REPLY"; else args_json="${args_json}, ${REPLY}"; fi
        done
    fi
    printf ',\n  "arguments": [%s]' "$args_json"
    [ "$MC_SC_UNATTENDED" -eq 1 ] && ok=true || ok=false
    printf ',\n  "unattended": %s\n}\n' "$ok"
}

mc_schedule_text() { # <action>
    local action="${1-status}" plist
    plist="$(mc_schedule_plist_path)"
    if [ "$MC_SC_OK" -eq 1 ]; then
        printf 'OK: %s\n' "$MC_SC_MSG"
    else
        printf 'NOT OK: %s\n' "$MC_SC_MSG"
    fi
    if [ "$MC_SC_INSTALLED" -eq 1 ] || [ "$action" = "status" ]; then
        printf '  label:     %s\n' "$MC_SCHEDULE_LABEL"
        printf '  plist:     %s\n' "$plist"
        if [ "$MC_SC_INSTALLED" -eq 1 ]; then
            local loaded="unknown"
            case "$MC_SC_LOADED" in 1) loaded="yes" ;; 0) loaded="no" ;; esac
            printf '  loaded:    %s\n' "$loaded"
            if [ -n "$MC_SC_TIME_R" ]; then
                _sc_weekday_name "$MC_SC_WEEKDAY_R"
                printf '  schedule:  %s at %s\n' "$REPLY" "$MC_SC_TIME_R"
            fi
            [ -z "$MC_SC_NEXT" ] || printf '  next run:  %s\n' "$MC_SC_NEXT"
            [ -z "$MC_SC_LASTEXIT" ] || printf '  last exit: %s\n' "$MC_SC_LASTEXIT"
            [ -z "$MC_SC_LASTRUN" ] || printf '  last run:  %s\n' "$MC_SC_LASTRUN"
            if [ "${#MC_SC_P_ARGS[@]}" -gt 0 ]; then
                printf '  command:   %s\n' "${MC_SC_P_ARGS[*]}"
            fi
        fi
    fi
}

# mc_schedule_run <install|remove|status> [--time HH:MM] [--weekday W] [--json]
# Exit status: 0 done, 1 not done (could not load/unload, failure reported
# honestly), 2 usage error (bad verb, time or weekday).
mc_schedule_run() {
    local verb="${1-}" time="" wday="" json=0 rc=0
    shift || true
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --time) time="${2-}"; shift; [ "$#" -gt 0 ] && shift ;;
            --weekday) wday="${2-}"; shift; [ "$#" -gt 0 ] && shift ;;
            --json) json=1; shift ;;
            *)
                echo "schedule: unknown option '$1'" >&2
                return 2
                ;;
        esac
    done
    case "$verb" in
        install) mc_schedule_install "$time" "$wday" || rc=$? ;;
        remove) mc_schedule_remove || rc=$? ;;
        status) mc_schedule_status || rc=$? ;;
        *)
            echo "schedule: use install, remove or status (got '${verb}')" >&2
            return 2
            ;;
    esac
    if [ "$json" -eq 1 ]; then
        mc_schedule_json "$verb"
    else
        mc_schedule_text "$verb"
    fi
    return "$rc"
}
