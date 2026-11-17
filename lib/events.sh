#!/usr/bin/env bash
# lib/events.sh - JSON-lines event channel for user interfaces (Bash 3.2+, no forks).
#
# Contract: V4 architecture §3 (event contract) and §11 (run phases).
#
# When MACOS_CLEANUP_EVENT_FILE is set (absolute path) and mc_events_init found it
# usable, every wrapper appends ONE JSON object per call with a single
# `printf >>` (O_APPEND). The channel never writes to stdout/stderr and never
# changes an exit status; with the variable unset every helper returns 0 at once.
#
# Public API (all return 0):
#   mc_events_init                        once, after paths; sets MC_EVENTS_ON MC_EPOCH0
#                                         MC_EVENT_SEQ MC_RUN_ID
#   mc_run_id_init                        set MC_RUN_ID (preset, adopted from
#                                         MACOS_CLEANUP_RUN_ID, or generated)
#   mc_json_str <value>                   REPLY = JSON string literal, quotes included
#   mc_event <type> [k=s:v|k=n:123|k=b:true|k=j:<raw-json>]...
#   mc_run_start <mode> <remove_mode> <dry_run> <groups> <action> <phases> [version]
#   mc_phase <phase> start | mc_phase <phase> end <result> [seconds]
#   mc_group_start <group> <scan|clean>
#   mc_group_total <group> <n>
#   mc_group_sized <group> <bytes> <items> <partial 0|1> [unit]
#   mc_item_start <group> <id> <name> <path> <est_bytes> <action> <undo>
#   mc_item_progress <group> <id> <phase> [percent]
#   mc_item_end <group> <id> <result> <reason> <est_bytes> <freed_bytes> [detail] [name]
#   mc_group_end <group> <scan|clean> <seconds>
#   mc_prompt <id-stem> <yesno|text> <text> [default] [group]
#   mc_warning <code> <text>
#   mc_disk_space <before|after>          forks diskutil/df and tmutil (twice per run)
#   mc_plan_written <path> <operations> <executable_bytes> <report_only_bytes>
#   mc_run_end <result> <exit_code> [estimated_bytes] [freed_bytes|""] [quarantined_bytes] [summary_file]
#
# Values outside the contract's vocabularies are rejected: the call emits nothing,
# except `reason`, which is normalised to "unknown". Do not assign SECONDS in the
# engine: `ts` is MC_EPOCH0 + SECONDS (integer epoch seconds, no fork; bash 3.2 has
# no printf %(%s)T).

_MC_ELLIPSIS=$'\342\200\246'

_MC_L_MODE="dry-run plan interactive auto-safe apply-plan restore list-quarantine purge-quarantine prune-artifacts unattended doctor"
_MC_L_REMOVE="quarantine permanent"
_MC_L_WCODE="fda_missing backup_missing snapshots_retain_space legacy_layout scan_partial rules_overlay_invalid env_ignored consent_no_terminal"
_MC_L_DPHASE="before after"
_MC_L_TIER="regenerable review report"
_MC_L_GPHASE="scan clean"
_MC_L_ACTION="remove native report"
_MC_L_UNDO="quarantine none"
_MC_L_IPHASE="measuring checking moving deleting running verifying"
_MC_L_RESULT="cleaned quarantined restored skipped failed unavailable report_only dry_run"
_MC_L_REASON="in_use protected_path permission_denied fda_missing too_recent user_declined native_failed timeout not_found needs_permanent identity_changed risk_escalated review_not_included dangerous_blocked backup_running unreadable outside_category_root plan_rejected unknown"
_MC_L_RUNRES="ok warn error cancelled"
_MC_L_PHASE="preflight scan plan clean verify report"
_MC_L_PHRES="ok warn error skipped"
_MC_L_UNIT="bytes count"
_MC_L_KIND="yesno text"

_mc_in() {
    case " $2 " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# ------------------------------------------------------------ JSON strings

_MC_LC_WAS=0
_MC_LC_PREV=""
_mc_lc_enter() {
    if [ "${LC_ALL+x}" = x ]; then
        _MC_LC_PREV="$LC_ALL"
        _MC_LC_WAS=1
    else
        _MC_LC_WAS=0
    fi
    LC_ALL=C
}
_mc_lc_leave() {
    if [ "$_MC_LC_WAS" = 1 ]; then
        LC_ALL="$_MC_LC_PREV"
    else
        unset LC_ALL
    fi
}

# In: $1. Out: REPLY = the escaped text without quotes. Needs LC_ALL=C.
_mc_esc() {
    local v="$1"
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//$'\n'/\\n}
    v=${v//$'\r'/\\r}
    v=${v//$'\t'/\\t}
    v=${v//$'\b'/\\b}
    v=${v//$'\f'/\\f}
    case "$v" in
        *[[:cntrl:]]*)
            v=${v//$'\001'/\\u0001}
            v=${v//$'\002'/\\u0002}
            v=${v//$'\003'/\\u0003}
            v=${v//$'\004'/\\u0004}
            v=${v//$'\005'/\\u0005}
            v=${v//$'\006'/\\u0006}
            v=${v//$'\007'/\\u0007}
            v=${v//$'\013'/\\u000b}
            v=${v//$'\016'/\\u000e}
            v=${v//$'\017'/\\u000f}
            v=${v//$'\020'/\\u0010}
            v=${v//$'\021'/\\u0011}
            v=${v//$'\022'/\\u0012}
            v=${v//$'\023'/\\u0013}
            v=${v//$'\024'/\\u0014}
            v=${v//$'\025'/\\u0015}
            v=${v//$'\026'/\\u0016}
            v=${v//$'\027'/\\u0017}
            v=${v//$'\030'/\\u0018}
            v=${v//$'\031'/\\u0019}
            v=${v//$'\032'/\\u001a}
            v=${v//$'\033'/\\u001b}
            v=${v//$'\034'/\\u001c}
            v=${v//$'\035'/\\u001d}
            v=${v//$'\036'/\\u001e}
            v=${v//$'\037'/\\u001f}
            v=${v//$'\177'/\\u007f}
            ;;
    esac
    REPLY="$v"
}

# Cut $1 to at most $2 bytes without splitting a UTF-8 sequence. Out: REPLY.
# Needs LC_ALL=C (${#} and substrings count bytes).
_mc_cut() {
    local v="$1" max="$2" t c code n=0
    t="${v:0:$max}"
    c="${v:$max:1}"
    code=0
    [ -z "$c" ] || printf -v code '%d' "'$c"
    [ "$code" -ge 0 ] || code=$((code + 256))
    # The next byte is a continuation byte: the cut is inside a sequence.
    if [ "$code" -ge 128 ] && [ "$code" -lt 192 ]; then
        while [ "$n" -lt 4 ] && [ -n "$t" ]; do
            n=$((n + 1))
            c="${t: -1}"
            t="${t%?}"
            printf -v code '%d' "'$c"
            [ "$code" -ge 0 ] || code=$((code + 256))
            [ "$code" -lt 192 ] || break
        done
    fi
    REPLY="$t"
}

# In: $1 (a string). Out: REPLY = the JSON string literal. Needs LC_ALL=C.
# Contract: truncate to 2,048 bytes (then "…") before escaping; if escaping makes
# it longer than 3,600 bytes (control-byte heavy), truncate harder so that no
# event line can pass 8 KiB.
_mc_js() {
    local v="$1" cut=0 lim
    if [ "${#v}" -gt 2048 ]; then
        _mc_cut "$v" 2048
        v="${REPLY}${_MC_ELLIPSIS}"
        cut=1
    fi
    case "$v" in
        *[\"\\[:cntrl:]]*)
            _mc_esc "$v"
            if [ "${#REPLY}" -gt 3600 ]; then
                if [ "$cut" = 1 ]; then v="${v%"$_MC_ELLIPSIS"}"; fi
                for lim in 1024 400; do
                    _mc_cut "$v" "$lim"
                    v="${REPLY}${_MC_ELLIPSIS}"
                    _mc_esc "$v"
                    [ "${#REPLY}" -gt 3600 ] || break
                    v="${v%"$_MC_ELLIPSIS"}"
                done
            fi
            REPLY="\"$REPLY\""
            ;;
        *) REPLY="\"$v\"" ;;
    esac
}

mc_json_str() {
    _mc_lc_enter
    _mc_js "${1-}"
    _mc_lc_leave
    return 0
}

# ------------------------------------------------------------ channel

_mc_runid_ok() {
    case "${1:-}" in
        ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

_mc_runid_strict() {
    local id="${1:-}" pid
    case "$id" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_[0-9]*) ;;
        *) return 1 ;;
    esac
    pid="${id##*_}"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# MC_RUN_ID: an id the engine already set, else MACOS_CLEANUP_RUN_ID when it is
# well formed (YYYY-MM-DD_HHMMSS_PID), else a fresh one (one date fork).
mc_run_id_init() {
    local stamp
    if _mc_runid_ok "${MC_RUN_ID:-}"; then
        :
    elif _mc_runid_strict "${MACOS_CLEANUP_RUN_ID:-}"; then
        MC_RUN_ID="$MACOS_CLEANUP_RUN_ID"
    else
        stamp="$(date '+%Y-%m-%d_%H%M%S' 2>/dev/null)" || stamp="1970-01-01_000000"
        MC_RUN_ID="${stamp}_$$"
    fi
    _MC_RUNID_JSON="\"$MC_RUN_ID\""
    return 0
}

mc_events_init() {
    local f="${MACOS_CLEANUP_EVENT_FILE:-}" now
    MC_EVENTS_ON=0
    MC_EVENT_SEQ=0
    MC_PROMPT_SEQ=0
    _MC_OPEN="|"
    _MC_RUN_QB=0
    _MC_T0=$SECONDS
    _MC_PH_LISTED=" "
    _MC_PH_ENDED=" "
    [ -n "$f" ] || return 0
    case "$f" in /*) ;; *) return 0 ;; esac
    [ ! -L "$f" ] || return 0
    if [ -e "$f" ]; then
        [ -f "$f" ] && [ -O "$f" ] || return 0
    else
        ( umask 077; : >> "$f" ) 2>/dev/null || return 0
    fi
    [ -w "$f" ] || return 0
    now="$(date +%s 2>/dev/null)" || return 0
    case "$now" in ''|*[!0-9]*) return 0 ;; esac
    MC_EPOCH0=$((now - SECONDS))
    mc_run_id_init
    MC_EVENTS_ON=1
    return 0
}

# _mc_emit <type> <fields>   fields = "" or ',"k":v,...' (already JSON)
_mc_emit() {
    local seq=$((${MC_EVENT_SEQ:-0} + 1)) obj
    obj="{\"ts\":$((${MC_EPOCH0:-0} + SECONDS)),\"type\":\"$1\",\"run_id\":${_MC_RUNID_JSON:-\"\"},\"seq\":${seq}${2}}"
    # 8 KiB per line at most, counted in bytes.
    _mc_lc_enter
    if [ "${#obj}" -gt 8192 ]; then _mc_lc_leave; return 0; fi
    _mc_lc_leave
    MC_EVENT_SEQ=$seq
    printf '%s\n' "$obj" 2>/dev/null >> "${MACOS_CLEANUP_EVENT_FILE}" || MC_EVENTS_ON=0
    return 0
}

# mc_event <type> k=s:text k=n:1 k=b:true k=j:<raw json> ...
# "j" values are trusted JSON; the typed wrappers build them from escaped parts.
mc_event() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local type="${1:-}" f="" kv key rest kind val
    case "$type" in ''|[!a-z]*|*[!a-z_]*) return 0 ;; esac
    shift
    _mc_lc_enter
    for kv in "$@"; do
        key="${kv%%=*}"
        [ "$key" != "$kv" ] || continue
        case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        rest="${kv#*=}"
        kind="${rest%%:*}"
        [ "$kind" != "$rest" ] || continue
        val="${rest#*:}"
        case "$kind" in
            s) _mc_js "$val"; f="${f},\"${key}\":${REPLY}" ;;
            n) case "$val" in ''|*[!0-9]*) val=0 ;; esac
               f="${f},\"${key}\":${val}" ;;
            b) [ "$val" = true ] || val=false
               f="${f},\"${key}\":${val}" ;;
            j) [ -n "$val" ] || val=null
               f="${f},\"${key}\":${val}" ;;
        esac
    done
    _mc_lc_leave
    _mc_emit "$type" "$f"
    return 0
}

# ------------------------------------------------------------ registry facts

# Sets _MC_SEC _MC_TIER _MC_LBL _MC_UNIT for a group id. Uses lib/registry.sh
# (reg_get) when it is loaded, else the built-in copy of §3.3.
_mc_reg() {
    local g="$1"
    _MC_SEC="" _MC_TIER="" _MC_LBL="" _MC_UNIT=""
    if type reg_get >/dev/null 2>&1; then
        if reg_get "$g" section 2>/dev/null; then
            _MC_SEC="$REPLY"
            reg_get "$g" tier 2>/dev/null && _MC_TIER="$REPLY"
            reg_get "$g" label_key 2>/dev/null && _MC_LBL="$REPLY"
            reg_get "$g" unit 2>/dev/null && _MC_UNIT="$REPLY"
        fi
    fi
    if [ -z "$_MC_SEC" ]; then
        case "$g" in
            trash) _MC_SEC=trash _MC_TIER=review ;;
            user-caches|app-caches-review) _MC_SEC=user-caches _MC_TIER=review ;;
            app-caches) _MC_SEC=user-caches _MC_TIER=regenerable ;;
            user-logs|system-logs|diagnostic-reports) _MC_SEC=logs _MC_TIER=review ;;
            system-caches) _MC_SEC=system _MC_TIER=report ;;
            tmp) _MC_SEC=system _MC_TIER=review ;;
            xcode-derived|npm|npx|yarn|pnpm|pip|gradle|cocoapods|cargo|swift-pm|bundler|composer)
                _MC_SEC=dev _MC_TIER=regenerable ;;
            xcode-archives|maven|android-avd) _MC_SEC=dev _MC_TIER=report ;;
            simulators|sim-runtimes|device-support|pnpm-stale|brew|gem|docker)
                _MC_SEC=dev _MC_TIER=review ;;
            app-leftovers) _MC_SEC=app-leftovers _MC_TIER=report ;;
            tm-snapshots|ios-backups) _MC_SEC=time-machine _MC_TIER=review ;;
            installers) _MC_SEC=large-files _MC_TIER=review ;;
            browser-caches|browser-data|mail-data|mail-downloads) _MC_SEC=overview _MC_TIER=report ;;
            restore|purge) _MC_SEC="$g" _MC_TIER=review ;;
            *) _MC_SEC="" _MC_TIER=report ;;
        esac
    fi
    [ -n "$_MC_TIER" ] || _MC_TIER=report
    [ -n "$_MC_LBL" ] || _MC_LBL="cat_${g//-/_}"
    if [ -z "$_MC_UNIT" ]; then
        case "$g" in tm-snapshots) _MC_UNIT=count ;; *) _MC_UNIT=bytes ;; esac
    fi
    return 0
}

_mc_gid_ok() {
    case "${1:-}" in
        [a-z]*) ;;
        *) return 1 ;;
    esac
    case "$1" in *[!a-z0-9-]*) return 1 ;; esac
    return 0
}

# ------------------------------------------------------------ counters

# _mc_inc <var> <delta>   var names are built from [A-Za-z0-9_] only
_mc_inc() {
    eval "$1=\$(( \${$1:-0} + $2 ))"
}

_mc_reset_group() {
    local G="${1//[^A-Za-z0-9]/_}" r
    for r in $_MC_L_RESULT declined; do
        eval "_MC_CNT_${G}_${r}=0"
    done
    for r in $_MC_L_REASON; do
        eval "_MC_RSN_${G}_${r}=0"
    done
    eval "_MC_EST_${G}=0 _MC_FRE_${G}=0 _MC_SIZED_${G}=0 _MC_NITEMS_${G}=0"
}

# ------------------------------------------------------------ typed wrappers

# Lists (groups, phases) may be separated by spaces or commas; $1 list, $2 kind
# gid|phase. Out: REPLY = JSON array, or returns 1 on an invalid member.
_mc_json_list() {
    local list="${1//,/ }" item out="" IFS=$' \t\n'
    for item in $list; do
        case "$2" in
            gid) _mc_gid_ok "$item" || return 1 ;;
            phase) _mc_in "$item" "$_MC_L_PHASE" || return 1 ;;
        esac
        out="${out:+${out},}\"${item}\""
    done
    REPLY="[${out}]"
    return 0
}

# _mc_redact <text> — REPLY = the text, redacted when redact_into is loaded and
# --redact is on (events.sh is also sourced on its own by tests).
_mc_redact() {
    REPLY="${1-}"
    if type redact_into >/dev/null 2>&1; then
        redact_into "$REPLY"
        REPLY="$REDACTED_TEXT"
    fi
    return 0
}

mc_run_start() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local mode="${1:-}" rm="${2:-}" dry="${3:-}" groups phases action="${5:-}" version="${7:-${SCRIPT_VERSION:-unknown}}" f
    _mc_in "$mode" "$_MC_L_MODE" || return 0
    _mc_in "$rm" "$_MC_L_REMOVE" || return 0
    case "$dry" in 1|true) dry=true ;; *) dry=false ;; esac
    case "$action" in ''|[!a-z]*|*[!a-z0-9_-]*) return 0 ;; esac
    _mc_json_list "${4:-}" gid || return 0
    groups="$REPLY"
    _mc_json_list "${6:-}" phase || return 0
    phases="$REPLY"
    _MC_PH_LISTED=" ${6:-} "
    _MC_T0=$SECONDS
    _mc_lc_enter
    _mc_js "$version"; f=",\"version\":${REPLY}"
    _mc_js "$mode"; f="${f},\"mode\":${REPLY}"
    _mc_js "$action"; f="${f},\"action\":${REPLY}"
    _mc_js "$rm"; f="${f},\"remove_mode\":${REPLY},\"dry_run\":${dry},\"groups\":${groups},\"phases\":${phases}"
    # F17: the paths carry the user name; under --redact they are redacted like
    # every other path of the stream.
    _mc_redact "${MC_STATE_DIR:-}"; _mc_js "$REPLY"; f="${f},\"paths\":{\"state\":${REPLY}"
    if [ -n "${MC_STATE_DIR:-}" ]; then _mc_redact "${MC_STATE_DIR}/runs/${MC_RUN_ID:-}"; _mc_js "$REPLY"; else _mc_js ""; fi
    f="${f},\"run_dir\":${REPLY}"
    _mc_redact "${MC_QUARANTINE_DIR:-}"; _mc_js "$REPLY"; f="${f},\"quarantine\":${REPLY}}"
    _mc_lc_leave
    _mc_emit run_start "$f"
    return 0
}

# mc_phase <phase> start | mc_phase <phase> end <result> [seconds]
# A phase that is skipped emits just the end event (result skipped).
mc_phase() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local phase="${1:-}" status="${2:-}" res="${3:-}" secs="${4:-}" PV
    _mc_in "$phase" "$_MC_L_PHASE" || return 0
    PV="_MC_PH_${phase}"
    case "$status" in
        start)
            [ "$#" -le 2 ] || return 0
            eval "$PV=\$SECONDS"
            _mc_emit phase ",\"phase\":\"${phase}\",\"status\":\"start\""
            ;;
        end)
            _mc_in "$res" "$_MC_L_PHRES" || return 0
            if [ -z "$secs" ]; then
                eval "secs=\$(( SECONDS - \${$PV:-\$SECONDS} ))"
            fi
            case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
            unset "$PV"
            _MC_PH_ENDED="${_MC_PH_ENDED:- }${phase} "
            _mc_emit phase ",\"phase\":\"${phase}\",\"status\":\"end\",\"result\":\"${res}\",\"seconds\":${secs}"
            ;;
    esac
    return 0
}

mc_group_start() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local g="${1:-}" phase="${2:-}" f
    _mc_gid_ok "$g" || return 0
    _mc_in "$phase" "$_MC_L_GPHASE" || return 0
    _mc_reg "$g"
    _mc_reset_group "$g"
    _mc_lc_enter
    _mc_js "$g"; f=",\"group\":${REPLY}"
    _mc_js "$_MC_SEC"; f="${f},\"section\":${REPLY}"
    _mc_js "$_MC_TIER"; f="${f},\"tier\":${REPLY}"
    _mc_js "$_MC_LBL"; f="${f},\"label_key\":${REPLY},\"phase\":\"${phase}\""
    _mc_lc_leave
    _mc_emit group_start "$f"
    return 0
}

mc_group_total() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local g="${1:-}" n="${2:-}"
    _mc_gid_ok "$g" || return 0
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    _mc_emit group_total ",\"group\":\"${g}\",\"total\":${n}"
    return 0
}

mc_group_sized() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local g="${1:-}" bytes="${2:-0}" items="${3:-0}" partial="${4:-0}" unit="${5:-}" G
    _mc_gid_ok "$g" || return 0
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    case "$items" in ''|*[!0-9]*) items=0 ;; esac
    case "$partial" in 1|true) partial=true ;; *) partial=false ;; esac
    if [ -z "$unit" ]; then _mc_reg "$g"; unit="$_MC_UNIT"; fi
    _mc_in "$unit" "$_MC_L_UNIT" || return 0
    G="${g//[^A-Za-z0-9]/_}"
    eval "_MC_SIZED_${G}=$bytes"
    _mc_emit group_sized ",\"group\":\"${g}\",\"estimated_bytes\":${bytes},\"items\":${items},\"partial\":${partial},\"unit\":\"${unit}\""
    return 0
}

# Open items are tracked as |group/id=undo| entries (only until their item_end).
_mc_ikey() {
    _MC_IKEY="${1//[^A-Za-z0-9_.:-]/_}/${2//[^A-Za-z0-9_.:-]/_}"
}

mc_item_start() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local g="${1:-}" id="${2:-}" name="${3:-}" path="${4:-}" est="${5:-0}" action="${6:-}" undo="${7:-}" f
    _mc_gid_ok "$g" || return 0
    [ -n "$id" ] || return 0
    _mc_in "$action" "$_MC_L_ACTION" || return 0
    _mc_in "$undo" "$_MC_L_UNDO" || return 0
    case "$est" in ''|*[!0-9]*) est=0 ;; esac
    _mc_ikey "$g" "$id"
    case "$_MC_OPEN" in
        *"|${_MC_IKEY}="*) _MC_OPEN="${_MC_OPEN/"|${_MC_IKEY}=quarantine|"/|}"
                           _MC_OPEN="${_MC_OPEN/"|${_MC_IKEY}=none|"/|}" ;;
    esac
    _MC_OPEN="${_MC_OPEN}${_MC_IKEY}=${undo}|"
    _mc_lc_enter
    _mc_js "$g"; f=",\"group\":${REPLY}"
    _mc_js "$id"; f="${f},\"id\":${REPLY}"
    _mc_js "${name:-$id}"; f="${f},\"name\":${REPLY}"
    _mc_js "$path"; f="${f},\"path\":${REPLY},\"estimated_bytes\":${est},\"action\":\"${action}\",\"undo\":\"${undo}\""
    _mc_lc_leave
    _mc_emit item_start "$f"
    return 0
}

mc_item_progress() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local g="${1:-}" id="${2:-}" phase="${3:-}" pct="${4:-}" f
    _mc_gid_ok "$g" || return 0
    [ -n "$id" ] || return 0
    _mc_in "$phase" "$_MC_L_IPHASE" || return 0
    _mc_lc_enter
    _mc_js "$g"; f=",\"group\":${REPLY}"
    _mc_js "$id"; f="${f},\"id\":${REPLY},\"phase\":\"${phase}\""
    _mc_lc_leave
    case "$pct" in
        ''|*[!0-9]*) ;;
        *) [ "${#pct}" -le 3 ] && [ "$pct" -le 100 ] || pct=100
           f="${f},\"percent\":$((10#$pct))" ;;
    esac
    _mc_emit item_progress "$f"
    return 0
}

mc_item_end() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local g="${1:-}" id="${2:-}" res="${3:-}" rsn="${4:-}" est="${5:-0}" fre="${6:-0}"
    local detail="${7:-}" name="${8:-}" undo="" rest G f action
    _mc_gid_ok "$g" || return 0
    [ -n "$id" ] || return 0
    _mc_in "$res" "$_MC_L_RESULT" || return 0
    case "$est" in ''|*[!0-9]*) est=0 ;; esac
    case "$fre" in ''|*[!0-9]*) fre=0 ;; esac
    # reason: "" when the item is ok; skipped/failed always carry one
    case "$res" in
        cleaned|quarantined|restored) rsn="" ;;
        skipped|failed) _mc_in "$rsn" "$_MC_L_REASON" || rsn=unknown ;;
        *) [ -z "$rsn" ] || _mc_in "$rsn" "$_MC_L_REASON" || rsn=unknown ;;
    esac
    # every item_end has an item_start
    _mc_ikey "$g" "$id"
    case "$_MC_OPEN" in
        *"|${_MC_IKEY}="*)
            rest="${_MC_OPEN#*"|${_MC_IKEY}="}"
            undo="${rest%%|*}"
            _MC_OPEN="${_MC_OPEN/"|${_MC_IKEY}=${undo}|"/|}"
            ;;
        *)
            action=remove
            [ "$res" != report_only ] || action=report
            undo=none
            [ "$res" != quarantined ] || undo=quarantine
            mc_item_start "$g" "$id" "${name:-$id}" "" "$est" "$action" "$undo"
            _MC_OPEN="${_MC_OPEN/"|${_MC_IKEY}=${undo}|"/|}"
            ;;
    esac
    case "$res" in
        quarantined) undo=quarantine ;;
        cleaned) undo=none ;;
    esac
    # counters, kept without associative arrays
    G="${g//[^A-Za-z0-9]/_}"
    _mc_inc "_MC_CNT_${G}_${res}" 1
    _mc_inc "_MC_EST_${G}" "$est"
    _mc_inc "_MC_FRE_${G}" "$fre"
    _mc_inc "_MC_NITEMS_${G}" 1
    if [ -n "$rsn" ]; then
        _mc_inc "_MC_RSN_${G}_${rsn}" 1
        [ "$rsn" != user_declined ] || _mc_inc "_MC_CNT_${G}_declined" 1
    fi
    [ "$res" != quarantined ] || _MC_RUN_QB=$(( ${_MC_RUN_QB:-0} + fre ))
    _mc_lc_enter
    _mc_js "$g"; f=",\"group\":${REPLY}"
    _mc_js "$id"; f="${f},\"id\":${REPLY},\"result\":\"${res}\",\"reason\":\"${rsn}\",\"estimated_bytes\":${est},\"freed_bytes\":${fre},\"undo\":\"${undo}\""
    _mc_js "$detail"; f="${f},\"detail\":${REPLY}"
    _mc_js "$name"; f="${f},\"name\":${REPLY}"
    _mc_lc_leave
    _mc_emit item_end "$f"
    return 0
}

# Result and counts come from the counters of this group since its group_start.
# result: failed with nothing done -> error; some done and some not -> warn; all
# done -> ok; all declined by the user -> skipped; other skips -> warn.
mc_group_end() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local g="${1:-}" phase="${2:-}" secs="${3:-0}" G
    local c_cl c_q c_rs c_sk c_f c_un c_ro c_dr c_decl est fre n sized acted res rsn="" r best=0 cnt rs_json="" IFS=$' \t\n'
    _mc_gid_ok "$g" || return 0
    _mc_in "$phase" "$_MC_L_GPHASE" || return 0
    case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
    G="${g//[^A-Za-z0-9]/_}"
    eval "c_cl=\${_MC_CNT_${G}_cleaned:-0} c_q=\${_MC_CNT_${G}_quarantined:-0} c_sk=\${_MC_CNT_${G}_skipped:-0}
          c_f=\${_MC_CNT_${G}_failed:-0} c_un=\${_MC_CNT_${G}_unavailable:-0} c_ro=\${_MC_CNT_${G}_report_only:-0}
          c_dr=\${_MC_CNT_${G}_dry_run:-0} c_decl=\${_MC_CNT_${G}_declined:-0} c_rs=\${_MC_CNT_${G}_restored:-0}
          est=\${_MC_EST_${G}:-0} fre=\${_MC_FRE_${G}:-0} n=\${_MC_NITEMS_${G}:-0} sized=\${_MC_SIZED_${G}:-0}"
    [ "$n" -gt 0 ] || est=$sized
    acted=$((c_cl + c_q + c_rs))
    # restored (restore pseudo-group only) appears in counts when non-zero
    [ "$c_rs" -eq 0 ] || rs_json=",\"restored\":${c_rs}"
    if [ "$c_f" -gt 0 ]; then
        if [ "$acted" -gt 0 ]; then res=warn; else res=error; fi
    elif [ "$acted" -gt 0 ]; then
        if [ $((c_sk + c_un)) -gt 0 ]; then res=warn; else res=ok; fi
    elif [ "$c_sk" -gt 0 ]; then
        if [ "$c_decl" -eq "$c_sk" ] && [ "$c_un" -eq 0 ]; then res=skipped; else res=warn; fi
    elif [ "$c_un" -gt 0 ]; then
        res=warn
    elif [ $((c_dr + c_ro)) -gt 0 ]; then
        res=ok
    elif [ "$phase" = scan ]; then
        res=ok
    else
        res=unknown
    fi
    if [ "$res" != ok ]; then
        for r in $_MC_L_REASON; do
            eval "cnt=\${_MC_RSN_${G}_${r}:-0}"
            if [ "$cnt" -gt "$best" ]; then best=$cnt; rsn=$r; fi
        done
    fi
    _mc_emit group_end ",\"group\":\"${g}\",\"phase\":\"${phase}\",\"result\":\"${res}\",\"counts\":{\"cleaned\":${c_cl},\"quarantined\":${c_q}${rs_json},\"skipped\":${c_sk},\"failed\":${c_f},\"unavailable\":${c_un},\"report_only\":${c_ro},\"dry_run\":${c_dr}},\"estimated_bytes\":${est},\"freed_bytes\":${fre},\"seconds\":${secs},\"reason\":\"${rsn}\""
    return 0
}

# id = <stem>-<n>-<pid>, n counted per process. yesno: options ["y","n"],
# default n (or y when asked); text: options [], default "".
mc_prompt() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local stem="${1:-}" kind="${2:-}" text="${3:-}" def="${4:-}" g="${5:-}" f opts
    [ -n "$stem" ] || return 0
    _mc_in "$kind" "$_MC_L_KIND" || return 0
    if [ -n "$g" ]; then _mc_gid_ok "$g" || g=""; fi
    MC_PROMPT_SEQ=$(( ${MC_PROMPT_SEQ:-0} + 1 ))
    if [ "$kind" = yesno ]; then
        opts='["y","n"]'
        case "$def" in y|n) ;; *) def=n ;; esac
    else
        opts='[]'
        def=""
    fi
    _mc_lc_enter
    _mc_js "${stem}-${MC_PROMPT_SEQ}-$$"; f=",\"id\":${REPLY},\"kind\":\"${kind}\""
    _mc_js "$text"; f="${f},\"text\":${REPLY},\"options\":${opts},\"default\":\"${def}\",\"timeout\":null"
    if [ -n "$g" ]; then _mc_js "$g"; f="${f},\"group\":${REPLY}"; fi
    _mc_lc_leave
    _mc_emit prompt "$f"
    return 0
}

mc_warning() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local code="${1:-}" text="${2:-}" f
    _mc_in "$code" "$_MC_L_WCODE" || return 0
    _mc_lc_enter
    _mc_js "$text"; f=",\"code\":\"${code}\",\"text\":${REPLY}"
    _mc_lc_leave
    _mc_emit warning "$f"
    return 0
}

# _mc_bounded <cmd> [args...] — an external lookup under the scan-tool deadline (analyzer.sh) when it is
# loaded, so a hung diskutil or tmutil cannot stall a run. A timeout leaves the output empty.
_mc_bounded() {
    if type optional_command_with_timeout >/dev/null 2>&1; then
        optional_command_with_timeout "${SCAN_TOOL_TIMEOUT:-20}" "$@"
    else
        "$@"
    fi
}

# Samples free space (diskutil, else df) and local snapshots. Forks.
mc_disk_space() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local phase="${1:-}" out line n free="" src="" snaps=0
    _mc_in "$phase" "$_MC_L_DPHASE" || return 0
    if command -v diskutil >/dev/null 2>&1; then
        out="$(_mc_bounded diskutil info / 2>/dev/null)" || out=""
        while IFS= read -r line; do
            case "$line" in
                *"Container Free Space:"*|*"Volume Free Space:"*)
                    case "$line" in *"("*" Bytes)"*) ;; *) continue ;; esac
                    n="${line#*\(}"
                    n="${n%% *}"
                    n="${n//,/}"
                    case "$n" in ''|*[!0-9]*) continue ;; esac
                    free="$n"
                    src=diskutil
                    break
                    ;;
            esac
        done <<EOF
$out
EOF
    fi
    if [ -z "$free" ]; then
        out="$(_mc_bounded df -k "${HOME:-/}" 2>/dev/null)" || out=""
        line="${out#*$'\n'}"
        line="${line%%$'\n'*}"
        # shellcheck disable=SC2086
        set -- $line
        n="${4:-}"
        case "$n" in
            ''|*[!0-9]*) ;;
            *) free=$(( n * 1024 )); src="df" ;;
        esac
    fi
    [ -n "$free" ] || return 0
    if command -v tmutil >/dev/null 2>&1; then
        out="$(_mc_bounded tmutil listlocalsnapshots / 2>/dev/null)" || out=""
        while IFS= read -r line; do
            case "$line" in *com.apple.TimeMachine*) snaps=$((snaps + 1)) ;; esac
        done <<EOF
$out
EOF
    fi
    _mc_emit disk_space ",\"phase\":\"${phase}\",\"free_bytes\":${free},\"source\":\"${src}\",\"snapshots\":${snaps}"
    return 0
}

mc_plan_written() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local path="${1:-}" ops="${2:-0}" ex="${3:-0}" ro="${4:-0}" f
    case "$ops" in ''|*[!0-9]*) ops=0 ;; esac
    case "$ex" in ''|*[!0-9]*) ex=0 ;; esac
    case "$ro" in ''|*[!0-9]*) ro=0 ;; esac
    _mc_lc_enter
    _mc_js "$path"; f=",\"path\":${REPLY},\"operations\":${ops},\"executable_bytes\":${ex},\"report_only_bytes\":${ro}"
    _mc_lc_leave
    _mc_emit plan_written "$f"
    return 0
}

# mc_run_end <result> <exit_code> [estimated_bytes] [freed_bytes|""] [quarantined_bytes] [summary_file]
# Defaults: estimated 0; freed null (not measured); quarantined = sum of freed
# bytes of the quarantined items seen; summary file <state>/runs/<run>/run.json.
# mc_phases_close [result] — before run_end: every phase listed in run_start
# that has no end yet gets one: <result> (default error) when it started,
# skipped when it never started. Keeps "exactly one end per listed phase".
mc_phases_close() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local res="${1:-error}" phase started
    for phase in ${_MC_PH_LISTED:-}; do
        case "${_MC_PH_ENDED:- }" in *" ${phase} "*) continue ;; esac
        _mc_in "$phase" "$_MC_L_PHASE" || continue
        eval "started=\${_MC_PH_${phase}:-}"
        if [ -n "$started" ]; then
            mc_phase "$phase" end "$res"
        else
            mc_phase "$phase" end skipped
        fi
    done
    return 0
}

mc_run_end() {
    [ "${MC_EVENTS_ON:-0}" = 1 ] && [ -n "${MACOS_CLEANUP_EVENT_FILE:-}" ] || return 0
    local res="${1:-}" code="${2:-0}" est="${3:-0}" fre="${4:-}" qb="${5:-}" sum="${6:-}" f secs
    _mc_in "$res" "$_MC_L_RUNRES" || return 0
    case "$code" in ''|*[!0-9]*) code=0 ;; esac
    case "$est" in ''|*[!0-9]*) est=0 ;; esac
    case "$fre" in ''|*[!0-9]*) fre=null ;; esac
    case "$qb" in ''|*[!0-9]*) qb="${_MC_RUN_QB:-0}" ;; esac
    if [ -z "$sum" ] && [ -n "${MC_STATE_DIR:-}" ]; then sum="${MC_STATE_DIR}/runs/${MC_RUN_ID:-}/run.json"; fi
    secs=$((SECONDS - ${_MC_T0:-0}))
    _mc_lc_enter
    _mc_js "$sum"; f=",\"result\":\"${res}\",\"seconds\":${secs},\"exit_code\":${code},\"summary_file\":${REPLY}"
    _mc_lc_leave
    f="${f},\"estimated_bytes\":${est},\"freed_bytes\":${fre},\"quarantined_bytes\":${qb}"
    _mc_emit run_end "$f"
    return 0
}
