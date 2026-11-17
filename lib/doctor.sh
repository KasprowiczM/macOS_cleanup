#!/usr/bin/env bash
# =============================================================================
# lib/doctor.sh - read-only diagnostics (contract V4 section 4.5)
# Bash 3.2 compatible. Sourcing has no side effects.
#
#   mc_doctor_run [--json]     collect + print; returns 1 when a check failed
#   mc_doctor_collect          run every probe once, fill MC_DR_* (no output)
#   mc_doctor_json             print the doctor read model from the last collect
#   mc_doctor_text             print the plain-text report from the last collect
#   mc_fda_probe [home]        Full Disk Access preflight (also used at engine
#                              preflight): sets MC_FDA_STATUS, MC_FDA_VERDICT,
#                              MC_FDA_GUIDANCE_KEY and the MC_FDA_PATH[] /
#                              MC_FDA_RESULT[] probe arrays; returns 0
#                              likely_granted, 1 likely_missing, 2 unknown
#   mc_doctor_guidance_text <key>  one-line English guidance, sets REPLY
#
# Nothing here changes anything: no file is created, copied or deleted, file
# contents are never read, launchctl is not called. Every external command
# runs under _rm_run_timeout (stock macOS has no timeout(1)); a probe that
# times out or fails is reported as unknown, never as zero.
# Directories come from the contract variables MC_PROGRAM_DIR, MC_CONFIG_DIR,
# MC_STATE_DIR, MC_QUARANTINE_DIR, MC_PATHS_MODE (lib/paths.sh) and HOME.
# =============================================================================

if ! command -v _rm_json_str >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]:-$0}")/readmodels.sh"
fi
if ! command -v mc_schedule_read_plist >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]:-$0}")/schedule.sh"
fi

# Seconds (shell variables, not environment: tests assign them).
MC_DR_TIMEOUT=3
MC_DR_DU_TIMEOUT=8
# Free space thresholds in bytes.
_DR_DISK_WARN=10737418240    # 10 GiB
_DR_DISK_FAIL=2147483648     # 2 GiB

# ---------------------------------------------------------------------------
# Full Disk Access preflight
# ---------------------------------------------------------------------------
# Apple offers no API to ask whether Full Disk Access is granted. The
# supported approach is to try to read what the tool needs: a directory
# listing (names only, never contents) of locations that macOS protects.
#   strong: ~/Library/Mail, ~/Library/Safari, the user TCC folder
#   weak:   ~/Library/Containers (listing it is not itself protected on all
#           macOS versions, so it can only confirm a denial, never a grant)
# per probe:   readable | denied | absent | unknown (timed out)
# overall:     likely_granted | likely_missing | unknown

_dr_probe_dir() { # <path>  sets REPLY
    local p="$1"
    RM_DISCARD=1 _rm_run_timeout "$MC_DR_TIMEOUT" ls -A "$p" || true
    if [ "$RM_RC" -eq 0 ]; then
        REPLY="readable"
    elif [ "$RM_TIMED_OUT" = "1" ]; then
        REPLY="unknown"
    elif [ -e "$p" ] || [ -L "$p" ]; then
        REPLY="denied"
    else
        REPLY="absent"
    fi
}

mc_fda_probe() {
    local home="${1:-${HOME:-}}" rel kind i n tilde
    local strong_read=0 strong_denied=0 weak_read=0 weak_denied=0
    MC_FDA_PATH=(); MC_FDA_RESULT=(); MC_FDA_KIND=()
    MC_FDA_STATUS="unknown"; MC_FDA_VERDICT="unknown"; MC_FDA_GUIDANCE_KEY="fda_unknown"
    case "$home" in /*) ;; *) return 2 ;; esac
    home="${home%/}"
    for rel in "Library/Mail:strong" "Library/Safari:strong" \
        "Library/Application Support/com.apple.TCC:strong" "Library/Containers:weak"; do
        kind="${rel##*:}"; rel="${rel%:*}"
        _dr_probe_dir "${home}/${rel}"
        tilde="~"
        MC_FDA_PATH[${#MC_FDA_PATH[@]}]="${tilde}/${rel}"
        MC_FDA_RESULT[${#MC_FDA_RESULT[@]}]="$REPLY"
        MC_FDA_KIND[${#MC_FDA_KIND[@]}]="$kind"
    done
    n=${#MC_FDA_RESULT[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
        case "${MC_FDA_KIND[$i]}:${MC_FDA_RESULT[$i]}" in
            strong:readable) strong_read=$(( strong_read + 1 )) ;;
            strong:denied) strong_denied=$(( strong_denied + 1 )) ;;
            weak:readable) weak_read=$(( weak_read + 1 )) ;;
            weak:denied) weak_denied=$(( weak_denied + 1 )) ;;
        esac
        i=$(( i + 1 ))
    done
    if [ "$strong_read" -gt 0 ]; then
        MC_FDA_VERDICT="likely_granted"
    elif [ "$strong_denied" -gt 0 ]; then
        MC_FDA_VERDICT="likely_missing"
    elif [ "$weak_denied" -gt 0 ]; then
        MC_FDA_VERDICT="likely_missing"
    else
        MC_FDA_VERDICT="unknown"
    fi
    : "$weak_read"
    case "$MC_FDA_VERDICT" in
        likely_granted) MC_FDA_STATUS="granted"; MC_FDA_GUIDANCE_KEY="fda_granted"; return 0 ;;
        likely_missing) MC_FDA_STATUS="denied"; MC_FDA_GUIDANCE_KEY="fda_missing"; return 1 ;;
        *) MC_FDA_STATUS="unknown"; MC_FDA_GUIDANCE_KEY="fda_unknown"; return 2 ;;
    esac
}

mc_doctor_guidance_text() {
    case "${1-}" in
        fda_granted) REPLY="Full Disk Access looks granted." ;;
        fda_missing) REPLY="Full Disk Access looks missing: open System Settings > Privacy & Security > Full Disk Access, enable your terminal app, then restart it." ;;
        *) REPLY="Full Disk Access could not be checked; if a scan reports unreadable folders, grant it in System Settings > Privacy & Security > Full Disk Access." ;;
    esac
}

# ---------------------------------------------------------------------------
# Small parsers
# ---------------------------------------------------------------------------

_dr_trim() { # sets REPLY
    local v="${1-}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    REPLY="$v"
}

# "  Label:   1.2 TB (1248873226240 Bytes) (exactly ...)" -> REPLY = bytes
_dr_bytes_in() {
    local re='\(([0-9]+) Bytes\)'
    REPLY=""
    if [[ "${1-}" =~ $re ]]; then
        REPLY="${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Parse `diskutil info /` text from $1. Sets MC_DR_DISK_*; unknown stays "".
_dr_parse_diskutil() {
    local text="$1" line val
    MC_DR_DISK_VOLUME=""; MC_DR_DISK_FS=""; MC_DR_DISK_CTOTAL=""; MC_DR_DISK_CFREE=""
    MC_DR_DISK_VFREE=""; MC_DR_DISK_VUSED=""; MC_DR_DISK_PURGEABLE=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *"Volume Name:"*)
                _dr_trim "${line#*:}"; if [ -z "$MC_DR_DISK_VOLUME" ]; then MC_DR_DISK_VOLUME="$REPLY"; fi ;;
            *"File System Personality:"*)
                _dr_trim "${line#*:}"; if [ -z "$MC_DR_DISK_FS" ]; then MC_DR_DISK_FS="$REPLY"; fi ;;
            *"Container Total Space:"*)
                val="${line#*:}"; if _dr_bytes_in "$val"; then MC_DR_DISK_CTOTAL="$REPLY"; fi ;;
            *"Container Free Space:"*)
                val="${line#*:}"; if _dr_bytes_in "$val"; then MC_DR_DISK_CFREE="$REPLY"; fi ;;
            *"Volume Free Space:"*|*"Volume Available Space:"*)
                val="${line#*:}"; if _dr_bytes_in "$val"; then MC_DR_DISK_VFREE="$REPLY"; fi ;;
            *"Volume Used Space:"*)
                val="${line#*:}"; if _dr_bytes_in "$val"; then MC_DR_DISK_VUSED="$REPLY"; fi ;;
            *"Purgeable"*:*)
                val="${line#*:}"; if _dr_bytes_in "$val"; then MC_DR_DISK_PURGEABLE="$REPLY"; fi ;;
        esac
    done <<EOF
$text
EOF
    return 0
}

# Parse `tmutil listlocalsnapshots /` text. Sets MC_DR_SNAP_COUNT, MC_DR_SNAP_NEWEST (ISO).
_dr_parse_snapshots() {
    local text="$1" line n=0 newest="" stamp
    local re='com\.apple\.TimeMachine\.([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})'
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ $re ]]; then
            n=$(( n + 1 ))
            stamp="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}T${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
            if [ -z "$newest" ] || [[ "$stamp" > "$newest" ]]; then newest="$stamp"; fi
        fi
    done <<EOF
$text
EOF
    MC_DR_SNAP_COUNT="$n"
    MC_DR_SNAP_NEWEST="$newest"
}

_dr_human_gib() { # <bytes> -> REPLY "12.3 GiB"
    local b="$1" whole tenth
    whole=$(( b / 1073741824 ))
    tenth=$(( (b * 10 / 1073741824) % 10 ))
    REPLY="${whole}.${tenth} GiB"
}

_dr_count_dirs() { # <dir> -> REPLY count of immediate subdirectories (no symlinks)
    local d n=0
    for d in "${1%/}"/*; do
        if [ -d "$d" ] && [ ! -L "$d" ]; then n=$(( n + 1 )); fi
    done
    REPLY="$n"
}

# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------

_dr_check() { # <id> <ok|warn|fail> <text>
    MC_DR_CHK_ID[${#MC_DR_CHK_ID[@]}]="$1"
    MC_DR_CHK_STATUS[${#MC_DR_CHK_STATUS[@]}]="$2"
    MC_DR_CHK_TEXT[${#MC_DR_CHK_TEXT[@]}]="$3"
}

# Device number of the nearest existing ancestor of <path>; REPLY "" when unknown.
_dr_device_of() {
    local p="$1"
    REPLY=""
    while [ -n "$p" ] && [ ! -e "$p" ] && [ "$p" != "/" ]; do p="${p%/*}"; [ -n "$p" ] || p="/"; done
    if _rm_run_timeout "$MC_DR_TIMEOUT" stat -f %d "$p" && [ -n "$RM_OUT" ]; then
        REPLY="$RM_OUT"
    elif _rm_run_timeout "$MC_DR_TIMEOUT" stat -c %d "$p" && [ -n "$RM_OUT" ]; then
        REPLY="$RM_OUT"
    fi
    case "$REPLY" in ''|*[!0-9]*) REPLY="" ;; esac
}

_dr_collect_runtime() {
    local re_ver='^[0-9]+(\.[0-9]+){0,2}$' re_py='^([0-9]+)\.([0-9]+)'
    MC_DR_BASH="${BASH_VERSION%%(*}"
    MC_DR_PY=""; MC_DR_PY_STATE="missing"
    if _rm_python; then
        if _rm_run_timeout "$MC_DR_TIMEOUT" "$_RM_PY_BIN" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' \
            && [[ "$RM_OUT" =~ $re_ver ]]; then
            MC_DR_PY="$RM_OUT"
            if [[ "$RM_OUT" =~ $re_py ]] \
                && { [ "${BASH_REMATCH[1]}" -gt 3 ] || { [ "${BASH_REMATCH[1]}" -eq 3 ] && [ "${BASH_REMATCH[2]}" -ge 9 ]; }; }; then
                MC_DR_PY_STATE="ok"
            else
                MC_DR_PY_STATE="old"
            fi
        elif [ "$RM_TIMED_OUT" = "1" ]; then
            MC_DR_PY_STATE="unknown"
        else
            MC_DR_PY_STATE="unusable"
        fi
    fi
    MC_DR_MACOS=""
    if _rm_run_timeout "$MC_DR_TIMEOUT" sw_vers -productVersion && [[ "$RM_OUT" =~ $re_ver ]]; then
        MC_DR_MACOS="$RM_OUT"
    fi
    MC_DR_ARCH=""
    if _rm_run_timeout "$MC_DR_TIMEOUT" uname -m; then
        case "$RM_OUT" in ''|*[!A-Za-z0-9_]*) ;; *) MC_DR_ARCH="$RM_OUT" ;; esac
    fi
    MC_DR_LANG="${MACOS_CLEANUP_LANG:-}"
    if [ -z "$MC_DR_LANG" ]; then
        MC_DR_LANG="${LANG:-}"
        MC_DR_LANG="${MC_DR_LANG%%[_.]*}"
        case "$MC_DR_LANG" in en|pl|de|es|fr|it|pt) ;; *) MC_DR_LANG="en" ;; esac
    fi
}

_dr_collect_disk() {
    MC_DR_DISK_STATE="unknown"
    _dr_parse_diskutil ""
    if _rm_run_timeout "$MC_DR_TIMEOUT" diskutil info / && [ -n "$RM_OUT" ]; then
        _dr_parse_diskutil "$RM_OUT"
        if [ -n "$MC_DR_DISK_CFREE$MC_DR_DISK_VFREE" ]; then MC_DR_DISK_STATE="ok"; fi
    fi
    return 0
}

_dr_collect_snapshots() {
    MC_DR_SNAP_COUNT=""; MC_DR_SNAP_NEWEST=""; MC_DR_TM_LATEST=""; MC_DR_TM_AGE=""
    local re='([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})' now epoch
    if _rm_run_timeout "$MC_DR_TIMEOUT" tmutil listlocalsnapshots /; then
        _dr_parse_snapshots "$RM_OUT"
    fi
    if _rm_run_timeout "$MC_DR_TIMEOUT" tmutil latestbackup && [[ "${RM_OUT##*/}" =~ $re ]]; then
        MC_DR_TM_LATEST="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}T${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        if _rm_iso_to_epoch "$MC_DR_TM_LATEST"; then
            epoch="$REPLY"
            _rm_now; now="$REPLY"
            if [ "$now" -gt 0 ]; then
                MC_DR_TM_AGE=$(( (now - epoch) / 86400 ))
                if [ "$MC_DR_TM_AGE" -lt 0 ]; then MC_DR_TM_AGE=0; fi
            fi
        fi
    fi
}

_dr_collect_quarantine() {
    local q="${MC_QUARANTINE_DIR:-}" kb home_dev q_dev
    MC_DR_Q_BYTES=""; MC_DR_Q_RUNS=""; MC_DR_Q_DEVICE_OK=""
    MC_DR_LOCK_HELD=0; MC_DR_LOCK_PID=""; MC_DR_LOCK_STALE=0
    [ -n "$q" ] || return 0
    if [ -d "$q" ]; then
        _dr_count_dirs "$q"; MC_DR_Q_RUNS="$REPLY"
        _rm_run_timeout "$MC_DR_DU_TIMEOUT" du -sk "$q" || true
        if [ "$RM_TIMED_OUT" != "1" ]; then
            kb="${RM_OUT%%[[:space:]]*}"
            case "$kb" in ''|*[!0-9]*) ;; *) MC_DR_Q_BYTES=$(( kb * 1024 )) ;; esac
        fi
    else
        MC_DR_Q_RUNS=0; MC_DR_Q_BYTES=0
    fi
    # same device as HOME (quarantine is a rename)
    _dr_device_of "${HOME:-}"; home_dev="$REPLY"
    _dr_device_of "$q"; q_dev="$REPLY"
    if [ -n "$home_dev" ] && [ -n "$q_dev" ]; then
        if [ "$home_dev" = "$q_dev" ]; then MC_DR_Q_DEVICE_OK=1; else MC_DR_Q_DEVICE_OK=0; fi
    fi
    # apply lock: <quarantine>/.apply.lock/pid
    if [ -d "${q%/}/.apply.lock" ]; then
        local pid=""
        if [ -r "${q%/}/.apply.lock/pid" ]; then
            IFS= read -r pid < "${q%/}/.apply.lock/pid" 2>/dev/null || true
        fi
        case "$pid" in ''|*[!0-9]*) pid="" ;; esac
        MC_DR_LOCK_PID="$pid"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            MC_DR_LOCK_HELD=1
        else
            MC_DR_LOCK_STALE=1
        fi
    fi
}

_dr_collect_legacy() {
    local cand="" c d f id reports_dir logs_dir restore_dir n
    MC_DR_LEG_CHECKOUT=""; MC_DR_LEG_LOGS=0; MC_DR_LEG_REPORTS=0; MC_DR_LEG_ORPHANS=0; MC_DR_LEG_MIGRATED=0
    for c in "${MACOS_CLEANUP_LEGACY_DIR:-}" "${HOME:-}/Dev_Env/macOS_cleanup" \
        "$( [ "${MC_PATHS_MODE:-}" = "checkout" ] && printf '%s' "${MC_PROGRAM_DIR:-}" )"; do
        [ -n "$c" ] || continue
        if [ -d "$c" ] && [ -f "${c%/}/cleanup_all.sh" ]; then cand="${c%/}"; break; fi
    done
    if [ -n "$cand" ]; then
        MC_DR_LEG_CHECKOUT="$cand"
        logs_dir="${cand}/logs"; reports_dir="${cand}/reports"
        n=0; for f in "$logs_dir"/cleanup_*.log; do if [ -e "$f" ]; then n=$(( n + 1 )); fi; done
        MC_DR_LEG_LOGS="$n"
        n=0; for f in "$reports_dir"/report_*.md; do if [ -e "$f" ]; then n=$(( n + 1 )); fi; done
        MC_DR_LEG_REPORTS="$n"
        n=0
        for f in "$reports_dir"/restore_*.tsv; do
            [ -e "$f" ] || continue
            id="${f##*/restore_}"; id="${id%.tsv}"
            restore_dir="${MC_STATE_DIR:-}/legacy/reports/restore_${id}.tsv"
            if [ ! -d "${MC_QUARANTINE_DIR:-/nonexistent}/${id}" ] && [ ! -e "$restore_dir" ]; then
                n=$(( n + 1 ))
            fi
        done
        MC_DR_LEG_ORPHANS="$n"
    fi
    # runs already carried over by `migrate` (run.json with "legacy": true)
    n=0
    if [ -n "${MC_STATE_DIR:-}" ]; then
        local re='"legacy"[[:space:]]*:[[:space:]]*true' content seen=0
        for d in "${MC_STATE_DIR%/}"/runs/*; do
            [ -d "$d" ] && [ -f "$d/run.json" ] && [ ! -L "$d/run.json" ] || continue
            seen=$(( seen + 1 )); [ "$seen" -le 2000 ] || break
            content="$(<"$d/run.json")" 2>/dev/null || continue
            [ "${#content}" -le 1048576 ] || continue
            if [[ "$content" =~ $re ]]; then n=$(( n + 1 )); fi
        done
    fi
    MC_DR_LEG_MIGRATED="$n"
}

_dr_collect_schedule() {
    MC_DR_SCH_INSTALLED=0; MC_DR_SCH_TIME=""; MC_DR_SCH_WEEKDAY=""; MC_DR_SCH_LASTRUN=""
    mc_schedule_read_plist || true
    if [ "$MC_SC_P_EXISTS" -eq 1 ]; then
        MC_DR_SCH_INSTALLED=1
        MC_DR_SCH_TIME="$MC_SC_P_TIME"; MC_DR_SCH_WEEKDAY="$MC_SC_P_WEEKDAY"
    fi
    if [ -n "${MC_STATE_DIR:-}" ] && mc_schedule_last_run "$MC_STATE_DIR"; then
        MC_DR_SCH_LASTRUN="$REPLY"
    fi
}

_dr_build_checks() {
    local free g re_mac='^([0-9]+)\.([0-9]+)'
    MC_DR_CHK_ID=(); MC_DR_CHK_STATUS=(); MC_DR_CHK_TEXT=()

    # bash
    if [[ "$BASH_VERSION" =~ ^([0-9]+)\.([0-9]+) ]] \
        && { [ "${BASH_REMATCH[1]}" -gt 3 ] || { [ "${BASH_REMATCH[1]}" -eq 3 ] && [ "${BASH_REMATCH[2]}" -ge 2 ]; }; }; then
        _dr_check bash ok "bash ${MC_DR_BASH}"
    else
        _dr_check bash fail "bash ${MC_DR_BASH} is older than 3.2, which the engine needs"
    fi
    # python3
    case "$MC_DR_PY_STATE" in
        ok) _dr_check python3 ok "python3 ${MC_DR_PY}; the interactive UI needs 3.9 or newer" ;;
        old) _dr_check python3 warn "python3 ${MC_DR_PY} is older than 3.9: the interactive UI is unavailable, the command line works" ;;
        unknown) _dr_check python3 warn "python3 did not answer in time" ;;
        unusable) _dr_check python3 warn "python3 is present but could not run" ;;
        *) _dr_check python3 warn "python3 not found: the interactive UI and history listings need it, the command line cleanup works without" ;;
    esac
    # macOS
    if [ -z "$MC_DR_MACOS" ]; then
        _dr_check macos warn "macOS version could not be read"
    elif [[ "$MC_DR_MACOS" =~ $re_mac ]] && [ "${BASH_REMATCH[1]}" -eq 10 ] && [ "${BASH_REMATCH[2]}" -lt 15 ]; then
        _dr_check macos warn "macOS ${MC_DR_MACOS} is older than 10.15, which the tool supports"
    else
        _dr_check macos ok "macOS ${MC_DR_MACOS}${MC_DR_ARCH:+ (${MC_DR_ARCH})}"
    fi
    # Full Disk Access
    mc_doctor_guidance_text "$MC_FDA_GUIDANCE_KEY"
    if [ "$MC_FDA_VERDICT" = "likely_granted" ]; then
        _dr_check fda ok "$REPLY"
    else
        _dr_check fda warn "$REPLY"
    fi
    # disk
    free="${MC_DR_DISK_CFREE:-$MC_DR_DISK_VFREE}"
    if [ -z "$free" ]; then
        _dr_check disk warn "free disk space could not be read from diskutil"
    else
        _dr_human_gib "$free"; g="$REPLY"
        if [ "$free" -lt "$_DR_DISK_FAIL" ]; then
            _dr_check disk fail "only ${g} free: cleaning needs room to work"
        elif [ "$free" -lt "$_DR_DISK_WARN" ]; then
            _dr_check disk warn "${g} free, below 10 GiB"
        else
            _dr_check disk ok "${g} free"
        fi
    fi
    # local snapshots
    if [ -z "$MC_DR_SNAP_COUNT" ]; then
        _dr_check snapshots warn "local Time Machine snapshots could not be listed"
    elif [ "$MC_DR_SNAP_COUNT" -gt 0 ]; then
        _dr_check snapshots warn "${MC_DR_SNAP_COUNT} local Time Machine snapshot(s) can keep deleted space in use until they are thinned"
    else
        _dr_check snapshots ok "no local Time Machine snapshots"
    fi
    # paths
    if [ -n "${MC_PROGRAM_DIR:-}" ] && [ -n "${MC_CONFIG_DIR:-}" ] && [ -n "${MC_STATE_DIR:-}" ] && [ -n "${MC_QUARANTINE_DIR:-}" ]; then
        _dr_check paths ok "program, config, state and quarantine folders resolved (${MC_PATHS_MODE:-unknown} install)"
    else
        _dr_check paths warn "the program, config, state or quarantine folder is not resolved"
    fi
    # quarantine
    if [ -z "${MC_QUARANTINE_DIR:-}" ]; then
        _dr_check quarantine warn "no quarantine folder"
    elif [ "$MC_DR_Q_DEVICE_OK" = "0" ]; then
        _dr_check quarantine fail "the quarantine folder is on a different volume than HOME: quarantine mode is refused"
    elif [ -z "$MC_DR_Q_BYTES" ]; then
        # Slow to add up is not a problem with the quarantine: informational, not a warning.
        _dr_check quarantine ok "${MC_DR_Q_RUNS:-?} run(s); the size could not be measured in time"
    else
        _dr_human_gib "$MC_DR_Q_BYTES"
        _dr_check quarantine ok "${MC_DR_Q_RUNS} run(s), ${REPLY}"
    fi
    # lock
    if [ "$MC_DR_LOCK_HELD" -eq 1 ]; then
        _dr_check lock warn "another run holds the apply lock (pid ${MC_DR_LOCK_PID})"
    elif [ "$MC_DR_LOCK_STALE" -eq 1 ]; then
        _dr_check lock warn "a stale apply lock folder exists${MC_DR_LOCK_PID:+ (no process ${MC_DR_LOCK_PID})}"
    else
        _dr_check lock ok "no run is in progress"
    fi
    # schedule
    if [ "$MC_DR_SCH_INSTALLED" -eq 1 ]; then
        _dr_check schedule ok "LaunchAgent installed${MC_DR_SCH_TIME:+: ${MC_DR_SCH_WEEKDAY} at ${MC_DR_SCH_TIME}}"
    else
        _dr_check schedule ok "no LaunchAgent (opt-in: macos-cleanup schedule install)"
    fi
    # legacy v3 data
    if [ -n "$MC_DR_LEG_CHECKOUT" ] && [ $(( MC_DR_LEG_LOGS + MC_DR_LEG_REPORTS + MC_DR_LEG_ORPHANS )) -gt 0 ]; then
        if [ "$MC_DR_LEG_MIGRATED" -gt 0 ]; then
            _dr_check legacy ok "v3 data in the old checkout was already migrated (${MC_DR_LEG_MIGRATED} run(s))"
        else
            _dr_check legacy warn "v3 data found in an old checkout (${MC_DR_LEG_LOGS} log(s), ${MC_DR_LEG_REPORTS} report(s), ${MC_DR_LEG_ORPHANS} manifest(s) without a quarantine run): run macos-cleanup migrate --preview"
        fi
    else
        _dr_check legacy ok "no v3 data to migrate"
    fi
}

mc_doctor_collect() {
    _rm_tool_version
    # a swapped-out previous install (<program>.previous) means rollback is possible
    MC_DR_ROLLBACK=0
    if [ -n "${MC_PROGRAM_DIR:-}" ] && [ -d "${MC_PROGRAM_DIR%/}.previous" ]; then MC_DR_ROLLBACK=1; fi
    mc_fda_probe "${HOME:-}" || true
    _dr_collect_runtime
    _dr_collect_disk
    _dr_collect_snapshots
    _dr_collect_quarantine
    _dr_collect_legacy
    _dr_collect_schedule
    _dr_build_checks
    MC_DR_N_OK=0; MC_DR_N_WARN=0; MC_DR_N_FAIL=0
    local i=0 n=${#MC_DR_CHK_STATUS[@]}
    while [ "$i" -lt "$n" ]; do
        case "${MC_DR_CHK_STATUS[$i]}" in
            ok) MC_DR_N_OK=$(( MC_DR_N_OK + 1 )) ;;
            warn) MC_DR_N_WARN=$(( MC_DR_N_WARN + 1 )) ;;
            fail) MC_DR_N_FAIL=$(( MC_DR_N_FAIL + 1 )) ;;
        esac
        i=$(( i + 1 ))
    done
    return 0
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

_dr_j() { # <string-or-empty> -> JSON string or null into REPLY
    _rm_str_or_null "$1"
}

mc_doctor_json() {
    local i n first lit
    _rm_header
    # paths
    printf ',\n  "paths": {'
    _dr_j "${MC_PROGRAM_DIR:-}"; printf '"program": %s' "$REPLY"
    _dr_j "${MC_CONFIG_DIR:-}"; printf ', "config": %s' "$REPLY"
    _dr_j "${MC_STATE_DIR:-}"; printf ', "state": %s' "$REPLY"
    _dr_j "${MC_QUARANTINE_DIR:-}"; printf ', "quarantine": %s' "$REPLY"
    _dr_j "${MC_PATHS_MODE:-}"; printf ', "mode": %s' "$REPLY"
    _rm_bool "$MC_DR_ROLLBACK"; printf ', "rollback_available": %s}' "$REPLY"
    # runtime
    printf ',\n  "runtime": {"bash": '
    _rm_json_str "$MC_DR_BASH"; printf '%s' "$REPLY"
    _dr_j "$MC_DR_PY"; printf ', "python3": %s' "$REPLY"
    [ "$MC_DR_PY_STATE" = "ok" ] && lit=true || lit=false
    printf ', "python3_ok": %s' "$lit"
    _dr_j "$MC_DR_MACOS"; printf ', "macos": %s' "$REPLY"
    _dr_j "$MC_DR_ARCH"; printf ', "arch": %s' "$REPLY"
    _dr_j "$MC_DR_LANG"; printf ', "lang": %s}' "$REPLY"
    # fda
    mc_doctor_guidance_text "$MC_FDA_GUIDANCE_KEY"
    printf ',\n  "fda": {"status": "%s", "verdict": "%s", "guidance_key": "%s", "guidance": ' \
        "$MC_FDA_STATUS" "$MC_FDA_VERDICT" "$MC_FDA_GUIDANCE_KEY"
    _rm_json_str "$REPLY"; printf '%s, "probes": [' "$REPLY"
    n=${#MC_FDA_PATH[@]}; i=0; first=1
    while [ "$i" -lt "$n" ]; do
        [ "$first" -eq 1 ] && first=0 || printf ', '
        _rm_json_str "${MC_FDA_PATH[$i]}"
        [ "${MC_FDA_RESULT[$i]}" = "readable" ] && lit=true || lit=false
        printf '{"path": %s, "result": "%s", "readable": %s}' "$REPLY" "${MC_FDA_RESULT[$i]}" "$lit"
        i=$(( i + 1 ))
    done
    printf ']}'
    # disk
    printf ',\n  "disk": {'
    _dr_j "$MC_DR_DISK_VOLUME"; printf '"volume": %s' "$REPLY"
    _dr_j "$MC_DR_DISK_FS"; printf ', "filesystem": %s' "$REPLY"
    _rm_num "$MC_DR_DISK_CTOTAL"; printf ', "container_total_bytes": %s' "$REPLY"
    _rm_num "$MC_DR_DISK_CFREE"; printf ', "container_free_bytes": %s' "$REPLY"
    _rm_num "$MC_DR_DISK_VFREE"; printf ', "volume_free_bytes": %s' "$REPLY"
    _rm_num "$MC_DR_DISK_VUSED"; printf ', "volume_used_bytes": %s' "$REPLY"
    _rm_num "$MC_DR_DISK_PURGEABLE"; printf ', "purgeable_bytes": %s' "$REPLY"
    printf ', "source": "%s"}' "$([ "$MC_DR_DISK_STATE" = ok ] && echo diskutil || echo unknown)"
    # snapshots / time machine
    _rm_num "$MC_DR_SNAP_COUNT"; printf ',\n  "snapshots": {"count": %s' "$REPLY"
    _dr_j "$MC_DR_SNAP_NEWEST"; printf ', "newest": %s}' "$REPLY"
    _dr_j "$MC_DR_TM_LATEST"; printf ',\n  "time_machine": {"latest_backup": %s' "$REPLY"
    _rm_num "$MC_DR_TM_AGE"; printf ', "age_days": %s}' "$REPLY"
    # quarantine / lock
    _rm_num "$MC_DR_Q_BYTES"; printf ',\n  "quarantine": {"bytes": %s' "$REPLY"
    _rm_num "$MC_DR_Q_RUNS"; printf ', "runs": %s' "$REPLY"
    _rm_bool "$MC_DR_Q_DEVICE_OK"; printf ', "same_device_as_home": %s}' "$REPLY"
    [ "$MC_DR_LOCK_HELD" -eq 1 ] && lit=true || lit=false
    printf ',\n  "lock": {"held": %s' "$lit"
    _rm_num "$MC_DR_LOCK_PID"; printf ', "pid": %s' "$REPLY"
    [ "$MC_DR_LOCK_STALE" -eq 1 ] && lit=true || lit=false
    printf ', "stale": %s}' "$lit"
    # legacy
    _dr_j "$MC_DR_LEG_CHECKOUT"; printf ',\n  "legacy": {"checkout": %s' "$REPLY"
    printf ', "logs": %s, "reports": %s, "orphan_manifests": %s, "migrated": %s}' \
        "$MC_DR_LEG_LOGS" "$MC_DR_LEG_REPORTS" "$MC_DR_LEG_ORPHANS" "$MC_DR_LEG_MIGRATED"
    # schedule
    [ "$MC_DR_SCH_INSTALLED" -eq 1 ] && lit=true || lit=false
    printf ',\n  "schedule": {"installed": %s, "label": "%s"' "$lit" "$MC_SCHEDULE_LABEL"
    _dr_j "$MC_DR_SCH_TIME"; printf ', "time": %s' "$REPLY"
    _dr_j "$MC_DR_SCH_WEEKDAY"; printf ', "weekday": %s' "$REPLY"
    _dr_j "$MC_DR_SCH_LASTRUN"; printf ', "last_run": %s}' "$REPLY"
    # checks
    printf ',\n  "checks": ['
    n=${#MC_DR_CHK_ID[@]}; i=0; first=1
    while [ "$i" -lt "$n" ]; do
        [ "$first" -eq 1 ] && first=0 || printf ','
        _rm_json_str "${MC_DR_CHK_TEXT[$i]}"
        printf '\n    {"id": "%s", "status": "%s", "text": %s}' "${MC_DR_CHK_ID[$i]}" "${MC_DR_CHK_STATUS[$i]}" "$REPLY"
        i=$(( i + 1 ))
    done
    printf '\n  ]'
    printf ',\n  "summary": {"ok": %s, "warn": %s, "fail": %s}\n}\n' "$MC_DR_N_OK" "$MC_DR_N_WARN" "$MC_DR_N_FAIL"
}

mc_doctor_text() {
    local i n tag
    printf 'macOS Cleanup %s - doctor\n\nChecks\n' "$RM_VERSION"
    n=${#MC_DR_CHK_ID[@]}; i=0
    while [ "$i" -lt "$n" ]; do
        case "${MC_DR_CHK_STATUS[$i]}" in ok) tag=" ok " ;; warn) tag="warn" ;; *) tag="FAIL" ;; esac
        printf '  [%s]  %-10s %s\n' "$tag" "${MC_DR_CHK_ID[$i]}" "${MC_DR_CHK_TEXT[$i]}"
        i=$(( i + 1 ))
    done
    printf '\nFolders (%s install%s)\n' "${MC_PATHS_MODE:-unknown}" "$([ "$MC_DR_ROLLBACK" = 1 ] && printf ', rollback available')"
    printf '  program:     %s\n  config:      %s\n  state:       %s\n  quarantine:  %s\n' \
        "${MC_PROGRAM_DIR:-unknown}" "${MC_CONFIG_DIR:-unknown}" "${MC_STATE_DIR:-unknown}" "${MC_QUARANTINE_DIR:-unknown}"
    printf '\nFull Disk Access probes\n'
    n=${#MC_FDA_PATH[@]}; i=0
    while [ "$i" -lt "$n" ]; do
        printf '  %-8s  %s\n' "${MC_FDA_RESULT[$i]}" "${MC_FDA_PATH[$i]}"
        i=$(( i + 1 ))
    done
    printf '\nResult: %s ok, %s warning(s), %s problem(s)\n' "$MC_DR_N_OK" "$MC_DR_N_WARN" "$MC_DR_N_FAIL"
}

# mc_doctor_run [--json]  ->  0, or 1 when a check failed (warnings are not failures)
mc_doctor_run() {
    local json=0
    case "${1-}" in --json) json=1 ;; esac
    mc_doctor_collect
    if [ "$json" -eq 1 ]; then
        mc_doctor_json
    else
        mc_doctor_text
    fi
    [ "$MC_DR_N_FAIL" -eq 0 ]
}
