#!/usr/bin/env bash
# =============================================================================
# lib/readmodels.sh - read-only JSON listings (contract V4 section 4)
# Bash 3.2 compatible. Sourcing has no side effects.
#
#   mc_rm_history     [state_dir] [quarantine_dir] [limit]     (--history --json)
#   mc_rm_quarantine  [quarantine_dir] [retention_days] [legacy_report_dirs]
#                                                              (--list-quarantine --json)
#   mc_rm_categories  <registry_tsv> [modes_tsv] [state_dir]   (--list-categories --json)
#
# Every function writes one JSON document to stdout and never modifies
# anything. Directories come from arguments, falling back to the contract's
# MC_STATE_DIR / MC_QUARANTINE_DIR / MC_PROGRAM_DIR / MC_PATHS_MODE variables
# (lib/paths.sh); nothing here needs lib/paths.sh to be loaded.
#
# This file also carries the helpers shared with lib/doctor.sh and
# lib/schedule.sh (both source it):
#   _rm_json_str <v>            sets REPLY to a JSON string literal (pure bash)
#                               NOTE for the integrator: private twin of
#                               mc_json_str from lib/events.sh; deduplicate.
#   _rm_run_timeout <s> cmd...  portable timeout (no GNU timeout); sets
#                               RM_OUT, RM_RC, RM_TIMED_OUT
#   _rm_python                  finds a usable python3 (never the CLT shim)
#   _rm_iso_to_epoch <iso>      sets REPLY (pure arithmetic, no fork)
# JSON parsing of run.json / plan.json / manifests is done by one embedded,
# read-only python3 program (stdlib only). Without a usable python3 the
# listings degrade to nulls and say so in "warnings"; they never print zeros
# for facts they could not read.
# =============================================================================

_RM_FILE="${BASH_SOURCE[0]:-$0}"
_RM_CTL_READY=0
_RM_PY_CHECKED=0
_RM_PY_BIN=""
# The stock /usr/bin/python3 is a shim that pops an installer dialog when the
# Command Line Tools are missing; it is only used after `xcode-select -p`.
_RM_PY_SHIM="/usr/bin/python3"
# Timeouts in seconds (shell variables, not environment: tests assign them).
_RM_DU_TIMEOUT=40
_RM_PY_TIMEOUT=30

RM_OUT=""
RM_RC=0
RM_TIMED_OUT=0
RM_DISCARD=0

# ---------------------------------------------------------------------------
# JSON string escaping (pure bash, no fork)
# ---------------------------------------------------------------------------

_rm_ctl_init() {
    local i oct c esc
    _RM_CTL_CHARS=()
    _RM_CTL_ESCS=()
    i=1
    while [ "$i" -le 127 ]; do
        case "$i" in
            8|9|10|12|13) ;;                      # \b \t \n \f \r have short forms
            [1-9]|[12][0-9]|3[01]|127)
                printf -v oct '%03o' "$i"
                # shellcheck disable=SC2059  # the format is the octal escape built just above
                printf -v c "\\$oct"
                printf -v esc '\\u%04x' "$i"
                _RM_CTL_CHARS[${#_RM_CTL_CHARS[@]}]="$c"
                _RM_CTL_ESCS[${#_RM_CTL_ESCS[@]}]="$esc"
                ;;
        esac
        i=$(( i + 1 ))
    done
    _RM_CTL_READY=1
}

# _rm_json_str <value>  ->  REPLY = "escaped literal" (with quotes).
_rm_json_str() {
    # shellcheck disable=SC1003  # a lone backslash in single quotes is intended
    local v="${1-}" bs='\' q='"' i n
    local nl=$'\n' cr=$'\r' tb=$'\t' bsp=$'\b' ff=$'\f'
    case "$v" in
        *[\"\\]*) ;;
        *[[:cntrl:]]*) ;;
        *) REPLY="\"$v\""; return 0 ;;
    esac
    v=${v//"$bs"/"$bs$bs"}
    v=${v//"$q"/"$bs$q"}
    v=${v//"$nl"/"${bs}n"}
    v=${v//"$cr"/"${bs}r"}
    v=${v//"$tb"/"${bs}t"}
    v=${v//"$bsp"/"${bs}b"}
    v=${v//"$ff"/"${bs}f"}
    if [[ "$v" == *[[:cntrl:]]* ]]; then
        [ "$_RM_CTL_READY" = "1" ] || _rm_ctl_init
        n=${#_RM_CTL_CHARS[@]}
        i=0
        while [ "$i" -lt "$n" ]; do
            v=${v//"${_RM_CTL_CHARS[$i]}"/"${_RM_CTL_ESCS[$i]}"}
            i=$(( i + 1 ))
        done
    fi
    REPLY="\"$v\""
}

# _rm_num <v>  ->  REPLY = digits, or null when v is not a non-negative integer
_rm_num() {
    case "${1-}" in
        ''|*[!0-9]*) REPLY="null" ;;
        *) REPLY="$((10#$1))" ;;
    esac
}

# _rm_str_or_null <v>  ->  REPLY = JSON string, or null when empty
_rm_str_or_null() {
    if [ -z "${1-}" ]; then
        REPLY="null"
    else
        _rm_json_str "$1"
    fi
}

# _rm_bool <v>  ->  REPLY = true | false | null  (1/true/yes -> true, 0/false/no -> false)
_rm_bool() {
    case "${1-}" in
        1|true|yes) REPLY="true" ;;
        0|false|no) REPLY="false" ;;
        *) REPLY="null" ;;
    esac
}

# The tool version: SCRIPT_VERSION, else VERSION in the program dir, else the
# one next to this file's lib/, else "unknown". Sets RM_VERSION.
_rm_tool_version() {
    local f v=""
    RM_VERSION="${SCRIPT_VERSION:-}"
    [ -z "$RM_VERSION" ] || return 0
    for f in "${MC_PROGRAM_DIR:-}/VERSION" "$(dirname "$_RM_FILE")/../VERSION"; do
        if [ -f "$f" ] && IFS= read -r v < "$f" 2>/dev/null && [ -n "$v" ]; then
            RM_VERSION="$v"
            return 0
        fi
    done
    RM_VERSION="unknown"
}

# Opening lines shared by every model: "{", schema_version, tool, version.
_rm_header() {
    _rm_tool_version
    _rm_json_str "$RM_VERSION"
    printf '{\n  "schema_version": "2.0",\n  "tool": "macos-cleanup",\n  "version": %s' "$REPLY"
}

# ---------------------------------------------------------------------------
# Timeout helper: stock macOS has no timeout(1)
# ---------------------------------------------------------------------------

# _rm_run_timeout <seconds> cmd [args...]
# Runs cmd with stdin from /dev/null and stderr dropped (RM_MERGE_ERR=1 merges
# it into the output instead). stdout goes to RM_OUT (or nowhere when
# RM_DISCARD=1). Sets RM_RC (124 on timeout, 127 when the
# command cannot run) and RM_TIMED_OUT (0|1). Returns RM_RC. A timed-out
# command must be treated as "unknown", never as an empty result.
_rm_run_timeout() {
    local secs="${1-}" f="" pid elapsed=0 tick_ms=20 sleep_s="0.02" limit rc=0
    shift
    RM_OUT=""
    RM_RC=0
    RM_TIMED_OUT=0
    case "$secs" in ''|*[!0-9]*) secs=5 ;; esac
    [ "$secs" -gt 0 ] || secs=1
    limit=$(( secs * 1000 ))
    if [ "${RM_DISCARD:-0}" = "1" ]; then
        "$@" >/dev/null 2>&1 </dev/null &
    else
        f="$(mktemp "${TMPDIR:-/tmp}/mc_rm.XXXXXX")" || { RM_RC=127; return 127; }
        if [ "${RM_MERGE_ERR:-0}" = "1" ]; then
            "$@" >"$f" 2>&1 </dev/null &
        else
            "$@" >"$f" 2>/dev/null </dev/null &
        fi
    fi
    pid=$!
    # The job-status report ("Terminated") is printed by the shell itself when
    # it reaps a killed child, so the whole watch loop runs with stderr closed.
    {
        local kids=""
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$elapsed" -ge "$limit" ]; then
                RM_TIMED_OUT=1
                # Children first (a stub's sleep), then the parent, so the
                # parent cannot carry on after its child died.
                kids="$(pgrep -P "$pid" 2>/dev/null)" || kids=""
                # shellcheck disable=SC2086
                kill -TERM "$pid" $kids 2>/dev/null || true
                sleep 0.2
                if kill -0 "$pid" 2>/dev/null; then
                    # shellcheck disable=SC2086
                    kill -KILL "$pid" $kids 2>/dev/null || true
                fi
                break
            fi
            sleep "$sleep_s"
            elapsed=$(( elapsed + tick_ms ))
            if [ "$elapsed" -ge 1000 ] && [ "$tick_ms" -lt 200 ]; then
                sleep_s="0.2"
                tick_ms=200
            fi
        done
        wait "$pid" || rc=$?
    } 2>/dev/null
    if [ "$RM_TIMED_OUT" = "1" ]; then
        rc=124
    fi
    if [ -n "$f" ]; then
        if [ -r "$f" ]; then
            RM_OUT="$(<"$f")"
        fi
        rm -f "$f"
    fi
    RM_RC="$rc"
    return "$rc"
}

# ---------------------------------------------------------------------------
# python3 discovery (read-only helper programs only)
# ---------------------------------------------------------------------------

# _rm_python  ->  returns 0 and sets _RM_PY_BIN when a usable python3 exists.
_rm_python() {
    local p
    if [ "$_RM_PY_CHECKED" = "1" ]; then
        [ -n "$_RM_PY_BIN" ]
        return
    fi
    _RM_PY_CHECKED=1
    _RM_PY_BIN=""
    p="$(command -v python3 2>/dev/null)" || return 1
    [ -n "$p" ] || return 1
    if [ "$p" = "$_RM_PY_SHIM" ]; then
        RM_DISCARD=1 _rm_run_timeout 3 xcode-select -p || return 1
    fi
    _RM_PY_BIN="python3"
    return 0
}

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

_RM_TZOFF=""

# Local UTC offset in seconds (cached).
_rm_local_offset() {
    local z sign h m
    if [ -z "$_RM_TZOFF" ]; then
        z="$(date +%z 2>/dev/null)" || z=""
        case "$z" in
            [+-][0-9][0-9][0-9][0-9])
                sign=1; [ "${z:0:1}" = "-" ] && sign=-1
                h=$((10#${z:1:2})); m=$((10#${z:3:2}))
                _RM_TZOFF=$(( sign * (h * 3600 + m * 60) ))
                ;;
            *) _RM_TZOFF=0 ;;
        esac
    fi
    REPLY="$_RM_TZOFF"
}

# _rm_iso_to_epoch <iso>  ->  REPLY = epoch seconds; returns 1 when unparsable.
# Accepts 2026-11-15T10:30:00[Z|+0100|+01:00] and run ids 2026-11-15_103000.
_rm_iso_to_epoch() {
    local s="${1-}" re off=0 sign tz
    local y m d hh mm ss era yoe mp doy doe days
    re='^([0-9]{4})-([0-9]{2})-([0-9]{2})[T_ ]([0-9]{2}):?([0-9]{2}):?([0-9]{2})(Z|[+-][0-9]{2}:?[0-9]{2})?'
    [[ "$s" =~ $re ]] || { REPLY=""; return 1; }
    y=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
    hh=$((10#${BASH_REMATCH[4]})); mm=$((10#${BASH_REMATCH[5]})); ss=$((10#${BASH_REMATCH[6]}))
    tz="${BASH_REMATCH[7]}"
    if [ "$m" -lt 1 ] || [ "$m" -gt 12 ] || [ "$d" -lt 1 ] || [ "$d" -gt 31 ] \
        || [ "$hh" -gt 23 ] || [ "$mm" -gt 59 ] || [ "$ss" -gt 60 ]; then
        REPLY=""
        return 1
    fi
    if [ -z "$tz" ]; then
        _rm_local_offset
        off="$REPLY"
    elif [ "$tz" != "Z" ]; then
        sign=1; [ "${tz:0:1}" = "-" ] && sign=-1
        tz="${tz:1}"; tz="${tz//:/}"
        off=$(( sign * (10#${tz:0:2} * 3600 + 10#${tz:2:2} * 60) ))
    fi
    # days since 1970-01-01 (Howard Hinnant's civil-from-days, inverted)
    [ "$m" -le 2 ] && y=$(( y - 1 ))
    era=$(( y / 400 ))
    yoe=$(( y - era * 400 ))
    mp=$(( (m + 9) % 12 ))
    doy=$(( (153 * mp + 2) / 5 + d - 1 ))
    doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
    days=$(( era * 146097 + doe - 719468 ))
    REPLY=$(( days * 86400 + hh * 3600 + mm * 60 + ss - off ))
}

# _rm_now  ->  REPLY = current epoch seconds (one fork of date)
_rm_now() {
    REPLY="$(date +%s 2>/dev/null)" || REPLY=""
    case "$REPLY" in ''|*[!0-9]*) REPLY=0 ;; esac
}

# ---------------------------------------------------------------------------
# Embedded read-only python program
# ---------------------------------------------------------------------------

_rm_py_src() {
    cat <<'PY'
import base64, json, os, stat, sys

MAX_RUN_JSON = 1 << 20
MAX_PLAN_JSON = 32 << 20


def read_json(path, limit):
    try:
        st = os.lstat(path)
    except OSError:
        return None, 'missing'
    if not stat.S_ISREG(st.st_mode) or st.st_size > limit:
        return None, 'bad'
    try:
        with open(path, 'rb') as fh:
            data = json.loads(fh.read().decode('utf-8'))
    except (OSError, ValueError):
        return None, 'bad'
    if not isinstance(data, dict):
        return None, 'bad'
    return data, 'ok'


def num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v if v >= 0 else None
    if isinstance(v, float) and v >= 0:
        return int(round(v))
    return None


def txt(v):
    return v if isinstance(v, str) and v else None


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, separators=(',', ':')) + '\n')


def run_dirs(runs):
    try:
        names = sorted(os.listdir(runs), reverse=True)
    except OSError:
        return
    for name in names[:5000]:
        if name.startswith('.'):
            continue
        d = os.path.join(runs, name)
        try:
            st = os.lstat(d)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode):
            yield name, d


def cmd_history(runs, quar, limit, examine):
    skipped = 0
    seen = 0
    out = 0
    for name, d in run_dirs(runs):
        if out >= limit or seen >= examine:
            break
        seen += 1
        jpath = os.path.join(d, 'run.json')
        data, why = read_json(jpath, MAX_RUN_JSON)
        if data is None:
            skipped += 1
            continue
        totals = data.get('totals') if isinstance(data.get('totals'), dict) else {}
        mpath = os.path.join(quar, name, 'manifest.tsv')
        try:
            restorable = stat.S_ISREG(os.lstat(mpath).st_mode)
        except OSError:
            restorable = False
        emit({
            'run_id': txt(data.get('run_id')) or name,
            'mode': txt(data.get('mode')),
            'started_at': txt(data.get('started_at')),
            'seconds': num(data.get('seconds')),
            'result': txt(data.get('result')),
            'dry_run': data.get('dry_run') if isinstance(data.get('dry_run'), bool) else None,
            'estimated_bytes': num(totals.get('estimated_bytes')),
            'measured_freed_bytes': num(totals.get('measured_freed_bytes')),
            'quarantined_bytes': num(totals.get('quarantined_bytes')),
            'legacy': data.get('legacy') is True,
            'restorable': restorable,
            'summary': jpath,
        })
        out += 1
    sys.stdout.write('#skipped\t%d\n' % skipped)


def restored_paths(journal):
    """Original paths the run journal records as restored (contract 12.1:
    {"op":"restore","path":...,"result":...}; result restored or ok)."""
    done = set()
    try:
        st = os.lstat(journal)
        if not stat.S_ISREG(st.st_mode) or st.st_size > (16 << 20):
            return done
        with open(journal, 'rb') as fh:
            for raw in fh:
                try:
                    rec = json.loads(raw.decode('utf-8'))
                except ValueError:
                    continue
                if (isinstance(rec, dict) and rec.get('op') == 'restore'
                        and rec.get('result') in ('restored', 'ok')
                        and isinstance(rec.get('path'), str)):
                    done.add(os.fsencode(rec['path']))
    except OSError:
        pass
    return done


def cmd_manifests(quar, pairs):
    for pair in pairs:
        rid, _, mpath = pair.partition('=')
        rid_b = os.fsencode(rid)
        run_b = os.path.join(os.fsencode(quar), rid_b)
        marker = b'/' + rid_b + b'/items/'
        done = restored_paths(os.path.join(os.fsdecode(run_b), 'journal.jsonl'))
        restorable = conflicting = restored = remaining = 0
        try:
            with open(mpath, 'rb') as fh:
                for n, raw in enumerate(fh):
                    if n >= 200000:
                        break
                    parts = raw.rstrip(b'\r\n').split(b'\t')
                    if len(parts) < 2:
                        continue
                    try:
                        q = base64.b64decode(parts[0])
                        o = base64.b64decode(parts[1])
                    except ValueError:
                        continue
                    if not q or not o:
                        continue
                    if o in done:
                        restored += 1
                        continue
                    if len(parts) > 2 and parts[2].isdigit():
                        remaining += int(parts[2])
                    if marker in q:
                        payload = os.path.join(run_b, b'items', q.split(marker, 1)[1])
                    else:
                        payload = q
                    if not os.path.lexists(payload):
                        continue
                    if os.path.lexists(o):
                        conflicting += 1
                    else:
                        restorable += 1
        except OSError:
            sys.stdout.write('%s\t-\t-\t-\t-\n' % rid)
            continue
        sys.stdout.write('%s\t%d\t%d\t%d\t%d\n' % (rid, restorable, conflicting, restored, remaining))


def cmd_lastscan(runs, ids):
    found = None
    for name, d in run_dirs(runs):
        data, why = read_json(os.path.join(d, 'run.json'), MAX_RUN_JSON)
        if data is not None and isinstance(data.get('categories'), list) and data['categories']:
            found = (name, d, data)
            break
    cats = {}
    ops = []
    if found is not None:
        for c in found[2]['categories']:
            if isinstance(c, dict) and isinstance(c.get('id'), str):
                cats[c['id']] = c
        plan, why = read_json(os.path.join(found[1], 'plan.json'), MAX_PLAN_JSON)
        if plan is not None and isinstance(plan.get('operations'), list):
            ops = [o for o in plan['operations'] if isinstance(o, dict)]
    for cid in ids:
        c = cats.get(cid)
        scan = None
        if c is not None:
            scan = {'run_id': found[0], 'estimated_bytes': num(c.get('estimated_bytes')),
                    'items': num(c.get('items')), 'partial': c.get('partial') is True}
        top = []
        for o in ops:
            if o.get('category') != cid or not isinstance(o.get('path'), str) or not o['path']:
                continue
            b = num(o.get('estimated_bytes'))
            if b is None:
                b = num(o.get('size'))
            top.append((b or 0, o['path']))
        top.sort(key=lambda t: (-t[0], t[1]))
        top = [{'path': p, 'bytes': b} for b, p in top[:20]]
        sys.stdout.write('%s\t%s\t%s\n' % (
            cid,
            json.dumps(scan, ensure_ascii=True, separators=(',', ':')),
            json.dumps(top, ensure_ascii=True, separators=(',', ':'))))


def main(argv):
    cmd = argv[1]
    if cmd == 'history':
        cmd_history(argv[2], argv[3], int(argv[4]), int(argv[5]))
    elif cmd == 'manifests':
        cmd_manifests(argv[2], argv[3:])
    elif cmd == 'lastscan':
        cmd_lastscan(argv[2], argv[3:])
    else:
        return 2
    return 0


sys.exit(main(sys.argv))
PY
}

# _rm_py <timeout> <subcommand> args...  ->  RM_OUT holds stdout; returns 0 on success.
_rm_py() {
    local secs="$1" src
    shift
    _rm_python || { RM_OUT=""; RM_RC=127; return 127; }
    src="$(_rm_py_src)"
    _rm_run_timeout "$secs" "$_RM_PY_BIN" -I -c "$src" "$@"
}

# Warnings are collected as JSON objects joined by commas.
_rm_warn_add() {
    local code="$1" text="$2" c t
    _rm_json_str "$code"; c="$REPLY"
    _rm_json_str "$text"; t="$REPLY"
    _RM_WARNINGS="${_RM_WARNINGS:+${_RM_WARNINGS}, }{\"code\": ${c}, \"text\": ${t}}"
}

# ---------------------------------------------------------------------------
# History  (--history --json)
# ---------------------------------------------------------------------------

# Newest first, at most 200 runs, from <state>/runs/*/run.json (regular files
# up to 1 MiB, no symlinks). Directories without a readable run.json are
# skipped and counted in "skipped_runs" plus one warning.
mc_rm_history() {
    local state="${1:-${MC_STATE_DIR:-}}" quar="${2:-${MC_QUARANTINE_DIR:-}}" limit="${3:-200}"
    local runs_dir line skipped=0 first=1 rows="" name d rid started
    _RM_WARNINGS=""
    case "$limit" in ''|*[!0-9]*) limit=200 ;; esac
    [ "$limit" -le 200 ] || limit=200
    [ "$limit" -ge 1 ] || limit=1
    if [ -z "$state" ]; then
        echo "mc_rm_history: state dir is not set" >&2
        return 2
    fi
    runs_dir="${state%/}/runs"

    if [ -d "$runs_dir" ]; then
        if _rm_py "$_RM_PY_TIMEOUT" history "$runs_dir" "$quar" "$limit" 1000 && [ "$RM_RC" -eq 0 ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                    "#skipped"*) skipped="${line#*$'\t'}" ;;
                    '{'*)
                        if [ "$first" -eq 1 ]; then first=0; else rows="${rows},"; fi
                        rows="${rows}"$'\n'"    ${line}"
                        ;;
                esac
            done <<EOF
$RM_OUT
EOF
        else
            # No python3 (or it failed): list the run directories by name only.
            _rm_warn_add "python_unavailable" "python3 is not usable; run details are not available."
            local -a names=()
            local n=0
            for d in "$runs_dir"/*; do
                [ -d "$d" ] && [ ! -L "$d" ] || continue
                names[${#names[@]}]="${d##*/}"
            done
            n=${#names[@]}
            while [ "$n" -gt 0 ] && [ "$limit" -gt 0 ]; do
                n=$(( n - 1 )); limit=$(( limit - 1 ))
                name="${names[$n]}"
                _rm_json_str "$name"; rid="$REPLY"
                started="null"
                if _rm_iso_to_epoch "$name"; then
                    _rm_json_str "${name:0:10}T${name:11:2}:${name:13:2}:${name:15:2}"; started="$REPLY"
                fi
                if [ "$first" -eq 1 ]; then first=0; else rows="${rows},"; fi
                rows="${rows}"$'\n'"    {\"run_id\":${rid},\"mode\":null,\"started_at\":${started},\"seconds\":null,\"result\":null,\"dry_run\":null,\"estimated_bytes\":null,\"measured_freed_bytes\":null,\"quarantined_bytes\":null,\"legacy\":null,\"restorable\":null,\"summary\":null}"
            done
        fi
    fi
    case "$skipped" in ''|*[!0-9]*) skipped=0 ;; esac
    if [ "$skipped" -gt 0 ]; then
        _rm_warn_add "run_json_unreadable" "${skipped} run folder(s) skipped: run.json is missing, unreadable or larger than 1 MiB."
    fi

    _rm_header
    if [ -n "$rows" ]; then
        printf ',\n  "runs": [%s\n  ]' "$rows"
    else
        printf ',\n  "runs": []'
    fi
    printf ',\n  "skipped_runs": %s' "$skipped"
    printf ',\n  "warnings": [%s]\n}\n' "$_RM_WARNINGS"
}

# ---------------------------------------------------------------------------
# Quarantine listing  (--list-quarantine --json)
# ---------------------------------------------------------------------------

# First value of a string key in a JSON file up to 1 MiB ("key": "value"), sets
# REPLY. A regex, not a parser: only for simple, unescaped values.
_rm_flat_get() {
    local file="$1" key="$2" content re
    REPLY=""
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    content="$(<"$file")" 2>/dev/null || return 1
    [ "${#content}" -le 1048576 ] || return 1
    re="\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ "$content" =~ $re ]]; then
        REPLY="${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Number of non-empty lines in a file, sets REPLY (no forks).
_rm_count_rows() {
    local line n=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] || n=$(( n + 1 ))
    done < "$1"
    REPLY="$n"
}

# One JSON listing of <root>/<run>/ folders: payload bytes, item count, age,
# whether the restore manifest is current ("ok"), only found in an old v3
# reports folder ("legacy") or absent ("missing"), and whether anything can
# still be restored. Bytes come from one `du` call under a timeout: when du
# times out the sizes are null, never 0.
mc_rm_quarantine() {
    local root="${1:-${MC_QUARANTINE_DIR:-}}"
    local retention="${2:-${MACOS_CLEANUP_QUARANTINE_RETENTION_DAYS:-${QUARANTINE_RETENTION_DAYS:-30}}}"
    local legacy_dirs="${3-__default__}"
    local -a names=() paths=() kbs=() manifests=() mstates=() items=() rest=() confl=() restd=() remain=() pairs_args=()
    local d name i n now old_ifs line kb ld mpath state
    local rows="" first=1 total_bytes=0 bytes_known=1 expired_n=0 run_n=0
    _RM_WARNINGS=""

    if [ -z "$root" ]; then
        echo "mc_rm_quarantine: quarantine dir is not set" >&2
        return 2
    fi
    case "$retention" in ''|*[!0-9]*) retention=30 ;; esac
    root="${root%/}"
    if [ "$legacy_dirs" = "__default__" ]; then
        legacy_dirs="${REPORTS_DIR:-}"
        if [ -n "${MC_STATE_DIR:-}" ]; then
            legacy_dirs="${legacy_dirs:+${legacy_dirs}:}${MC_STATE_DIR%/}/legacy/reports"
        fi
        if [ "${MC_PATHS_MODE:-}" = "checkout" ] && [ -n "${MC_PROGRAM_DIR:-}" ]; then
            legacy_dirs="${legacy_dirs:+${legacy_dirs}:}${MC_PROGRAM_DIR%/}/reports"
        fi
    fi

    if [ -d "$root" ]; then
        for d in "$root"/*; do
            [ -d "$d" ] && [ ! -L "$d" ] || continue
            names[${#names[@]}]="${d##*/}"
        done
    fi
    n=${#names[@]}

    # Newest first: glob order is ascending, run ids sort chronologically.
    local -a sorted=()
    i=$n
    while [ "$i" -gt 0 ]; do
        i=$(( i - 1 ))
        sorted[${#sorted[@]}]="${names[$i]}"
    done
    if [ "$n" -gt 0 ]; then
        names=("${sorted[@]}")
    fi

    # One du call for all runs.
    i=0
    while [ "$i" -lt "$n" ]; do
        paths[$i]="${root}/${names[$i]}"
        kbs[$i]=""
        i=$(( i + 1 ))
    done
    if [ "$n" -gt 0 ]; then
        _rm_run_timeout "$_RM_DU_TIMEOUT" du -sk "${paths[@]}" || true
        if [ -n "$RM_OUT" ]; then
            i=0
            while IFS= read -r line || [ -n "$line" ]; do
                kb="${line%%[[:space:]]*}"
                case "$kb" in ''|*[!0-9]*) continue ;; esac
                [ "$i" -lt "$n" ] && kbs[$i]="$kb"
                i=$(( i + 1 ))
            done <<EOF
$RM_OUT
EOF
        fi
        if [ "$RM_TIMED_OUT" = "1" ]; then
            _rm_warn_add "size_timeout" "Measuring quarantine size timed out; sizes are unknown."
        fi
    fi

    # Manifest state and row counts (pure bash).
    i=0
    while [ "$i" -lt "$n" ]; do
        name="${names[$i]}"
        mpath="${paths[$i]}/manifest.tsv"
        state="missing"
        manifests[$i]=""
        if [ -f "$mpath" ] && [ ! -L "$mpath" ]; then
            state="ok"
            manifests[$i]="$mpath"
        else
            old_ifs="$IFS"; IFS=':'
            for ld in $legacy_dirs; do
                [ -n "$ld" ] || continue
                if [ -f "${ld%/}/restore_${name}.tsv" ] && [ ! -L "${ld%/}/restore_${name}.tsv" ]; then
                    state="legacy"
                    manifests[$i]="${ld%/}/restore_${name}.tsv"
                    break
                fi
            done
            IFS="$old_ifs"
        fi
        mstates[$i]="$state"
        items[$i]=""
        rest[$i]=""
        confl[$i]=""
        restd[$i]=""
        remain[$i]=""
        if [ -n "${manifests[$i]}" ]; then
            _rm_count_rows "${manifests[$i]}"
            items[$i]="$REPLY"
        fi
        i=$(( i + 1 ))
    done

    # restorable / conflicting item counts need base64 decoding: python3.
    i=0
    while [ "$i" -lt "$n" ]; do
        [ -z "${manifests[$i]}" ] || pairs_args[${#pairs_args[@]}]="${names[$i]}=${manifests[$i]}"
        i=$(( i + 1 ))
    done
    if [ "${#pairs_args[@]}" -gt 0 ]; then
        if _rm_py "$_RM_PY_TIMEOUT" manifests "$root" "${pairs_args[@]}" && [ "$RM_RC" -eq 0 ]; then
            while IFS=$'\t' read -r name kb line c4 c5; do
                [ -n "$name" ] || continue
                i=0
                while [ "$i" -lt "$n" ]; do
                    if [ "${names[$i]}" = "$name" ]; then
                        case "$kb" in ''|*[!0-9]*) ;; *) rest[$i]="$kb" ;; esac
                        case "$line" in ''|*[!0-9]*) ;; *) confl[$i]="$line" ;; esac
                        case "$c4" in ''|*[!0-9]*) ;; *) restd[$i]="$c4" ;; esac
                        case "$c5" in ''|*[!0-9]*) ;; *) remain[$i]="$c5" ;; esac
                        break
                    fi
                    i=$(( i + 1 ))
                done
            done <<EOF
$RM_OUT
EOF
        else
            _rm_warn_add "python_unavailable" "python3 is not usable; restorable item counts are unknown."
        fi
    fi

    _rm_now; now="$REPLY"
    i=0
    while [ "$i" -lt "$n" ]; do
        local created="" tool="" age="" expired="false" epoch="" bytes_lit r_lit c_lit it_lit
        local restorable reason created_lit tool_lit age_lit empty="false" rd_lit br_lit
        name="${names[$i]}"
        d="${paths[$i]}"
        # created_at: run-info.json, else the run id, else unknown.
        _rm_flat_get "$d/run-info.json" created_at && created="$REPLY"
        _rm_flat_get "$d/run-info.json" tool_version && tool="$REPLY"
        [ -n "$created" ] || {
            if _rm_iso_to_epoch "$name"; then
                created="${name:0:10}T${name:11:2}:${name:13:2}:${name:15:2}"
            fi
        }
        if [ -n "$created" ] && _rm_iso_to_epoch "$created"; then
            epoch="$REPLY"
        else
            created=""
            # Last resort: folder mtime (BSD stat, then GNU stat).
            if _rm_run_timeout 3 stat -f %m "$d" && [ -n "$RM_OUT" ]; then
                epoch="$RM_OUT"
            elif _rm_run_timeout 3 stat -c %Y "$d" && [ -n "$RM_OUT" ]; then
                epoch="$RM_OUT"
            fi
            case "$epoch" in ''|*[!0-9]*) epoch="" ;; esac
        fi
        if [ -n "$epoch" ] && [ "$now" -gt 0 ]; then
            age=$(( (now - epoch) / 86400 ))
            [ "$age" -ge 0 ] || age=0
            [ "$age" -gt "$retention" ] && expired="true"
        fi
        if [ "$expired" = "true" ]; then expired_n=$(( expired_n + 1 )); fi
        run_n=$(( run_n + 1 ))

        if [ -n "${kbs[$i]}" ]; then
            bytes_lit=$(( ${kbs[$i]} * 1024 ))
            total_bytes=$(( total_bytes + bytes_lit ))
        else
            bytes_lit="null"
            bytes_known=0
        fi
        _rm_num "${items[$i]}"; it_lit="$REPLY"
        _rm_num "${rest[$i]}"; r_lit="$REPLY"
        _rm_num "${confl[$i]}"; c_lit="$REPLY"
        _rm_num "${restd[$i]}"; rd_lit="$REPLY"
        _rm_num "${remain[$i]}"; br_lit="$REPLY"

        # restorable yes/no and why not
        restorable="true"; reason="null"
        if [ "${mstates[$i]}" = "missing" ]; then
            restorable="false"; reason='"manifest_missing"'
        elif [ -n "${restd[$i]}" ] && [ -n "${items[$i]}" ] && [ "${items[$i]}" -gt 0 ] \
            && [ "${restd[$i]}" -ge "${items[$i]}" ]; then
            # every row is recorded as restored (contract 12.1): an empty run
            empty="true"; restorable="false"; reason='"all_restored"'
        elif [ -n "${rest[$i]}" ]; then
            if [ "${rest[$i]}" -eq 0 ]; then
                restorable="false"
                if [ -n "${confl[$i]}" ] && [ "${confl[$i]}" -gt 0 ]; then
                    reason='"all_originals_exist"'
                else
                    reason='"nothing_left"'
                fi
            fi
        fi

        _rm_json_str "$name"; local rid_lit="$REPLY"
        _rm_json_str "$d"; local path_lit="$REPLY"
        _rm_str_or_null "$created"; created_lit="$REPLY"
        _rm_str_or_null "$tool"; tool_lit="$REPLY"
        _rm_num "$age"; age_lit="$REPLY"
        if [ "$first" -eq 1 ]; then first=0; else rows="${rows},"; fi
        rows="${rows}"$'\n'"    {\"run_id\": ${rid_lit}, \"path\": ${path_lit}, \"bytes\": ${bytes_lit}, \"items\": ${it_lit}, \"items_total\": ${it_lit}, \"items_restored\": ${rd_lit}, \"bytes_remaining\": ${br_lit}, \"empty\": ${empty}, \"created_at\": ${created_lit}, \"age_days\": ${age_lit}, \"expired\": ${expired}, \"manifest\": \"${mstates[$i]}\", \"restorable\": ${restorable}, \"not_restorable_reason\": ${reason}, \"restorable_items\": ${r_lit}, \"conflicting_items\": ${c_lit}, \"tool_version\": ${tool_lit}}"
        i=$(( i + 1 ))
    done

    _rm_header
    _rm_json_str "$root"
    printf ',\n  "root": %s,\n  "retention_days": %s' "$REPLY" "$retention"
    if [ -n "$rows" ]; then
        printf ',\n  "runs": [%s\n  ]' "$rows"
    else
        printf ',\n  "runs": []'
    fi
    if [ "$bytes_known" -eq 1 ]; then
        printf ',\n  "totals": {"bytes": %s, "runs": %s, "expired_runs": %s}' "$total_bytes" "$run_n" "$expired_n"
    else
        printf ',\n  "totals": {"bytes": null, "runs": %s, "expired_runs": %s}' "$run_n" "$expired_n"
    fi
    printf ',\n  "warnings": [%s]\n}\n' "$_RM_WARNINGS"
}

# ---------------------------------------------------------------------------
# Categories  (--list-categories --json)
# ---------------------------------------------------------------------------

# mc_rm_categories <registry_tsv> [category-modes.tsv] [state_dir]
# Registry columns (contract 6.1): id section tier action undo analyzer roots
# native_cmd tool in_use unattended unit from_file label_key explain_key order.
# '-' means empty. Malformed rows are skipped and counted in a warning.
mc_rm_categories() {
    local reg="${1-}" modes="${2-}" state="${3:-${MC_STATE_DIR:-}}"
    local line id section tier action undo analyzer roots native tool in_use unattended unit
    local from_file label_key explain_key order extra
    local idre='^[a-z][a-z0-9-]{1,30}$' var mode msrc effective
    local rows="" first=1 bad=0 mid mmode msource scan_map=""
    local -a ids=()
    _RM_WARNINGS=""

    if [ -z "$reg" ] || [ ! -r "$reg" ]; then
        _rm_warn_add "registry_unreadable" "The category registry could not be read."
        _rm_header
        printf ',\n  "categories": [],\n  "warnings": [%s]\n}\n' "$_RM_WARNINGS"
        return 1
    fi

    # User modes: id<TAB>mode<TAB>source.  Stored in eval-named scalars; clear
    # any left over from an earlier call first.
    for var in $(compgen -A variable _RM_MODE_); do unset "$var"; done
    if [ -n "$modes" ] && [ -r "$modes" ] && [ ! -L "$modes" ]; then
        # shellcheck disable=SC2034  # columns read for position only
        while IFS=$'\t' read -r mid mmode msource extra || [ -n "$mid" ]; do
            case "$mid" in ''|'#'*) continue ;; esac
            [[ "$mid" =~ $idre ]] || continue
            case "$mmode" in auto|review|skip) ;; *) continue ;; esac
            eval "_RM_MODE_${mid//-/_}=\$mmode"
        done < "$modes"
    fi

    # First pass: ids (for the last-scan lookup).
    # shellcheck disable=SC2034  # columns read for position only
    while IFS=$'\t' read -r id section tier action undo analyzer roots native tool in_use unattended unit from_file label_key explain_key order extra || [ -n "$id" ]; do
        case "$id" in ''|'#'*) continue ;; esac
        [ "$id" = "id" ] && [ "$section" = "section" ] && continue   # registry header row
        [[ "$id" =~ $idre ]] || continue
        [ -n "$explain_key" ] || continue
        ids[${#ids[@]}]="$id"
    done < "$reg"

    # last_scan and top_items: one python call over the newest usable run.
    local py_ok=0
    if [ -n "$state" ] && [ -d "${state%/}/runs" ] && [ "${#ids[@]}" -gt 0 ]; then
        if _rm_py "$_RM_PY_TIMEOUT" lastscan "${state%/}/runs" "${ids[@]}" && [ "$RM_RC" -eq 0 ]; then
            py_ok=1
            scan_map="$RM_OUT"
        else
            _rm_warn_add "python_unavailable" "python3 is not usable; last scan sizes are not available."
        fi
    fi

    # shellcheck disable=SC2034  # columns read for position only
    while IFS=$'\t' read -r id section tier action undo analyzer roots native tool in_use unattended unit from_file label_key explain_key order extra || [ -n "$id" ]; do
        case "$id" in ''|'#'*) continue ;; esac
        [ "$id" = "id" ] && [ "$section" = "section" ] && continue   # registry header row
        if ! [[ "$id" =~ $idre ]] || [ -z "$explain_key" ]; then
            bad=$(( bad + 1 ))
            continue
        fi
        # Contract section 13: only app-caches is auto out of the box; every
        # other regenerable category is offered for review; report tiers skip.
        case "$tier" in
            report) mode="skip" ;;
            *) if [ "$id" = "app-caches" ]; then mode="auto"; else mode="review"; fi ;;
        esac
        msrc="default"
        var="_RM_MODE_${id//-/_}"
        if eval "[ -n \"\${${var}-}\" ]"; then
            eval "mode=\${${var}}"
            msrc="user"
        fi
        # auto consent needs mode auto AND regenerable + quarantine + unattended=yes
        effective="false"
        if [ "$tier" = "regenerable" ] && [ "$mode" = "auto" ] && [ "$undo" = "quarantine" ] && [ "$unattended" = "yes" ]; then
            effective="true"
        fi
        local nat_lit un_lit scan_lit="null" top_lit="[]" sl tl
        if [ "$native" = "-" ] || [ -z "$native" ]; then nat_lit="null"; else _rm_json_str "$native"; nat_lit="$REPLY"; fi
        if [ "$unattended" = "yes" ]; then un_lit="true"; else un_lit="false"; fi
        if [ "$py_ok" -eq 1 ]; then
            while IFS=$'\t' read -r mid sl tl || [ -n "$mid" ]; do
                if [ "$mid" = "$id" ]; then
                    [ -z "$sl" ] || scan_lit="$sl"
                    [ -z "$tl" ] || top_lit="$tl"
                    break
                fi
            done <<EOF
$scan_map
EOF
        fi
        local id_l sec_l tier_l act_l undo_l unit_l lab_l exp_l
        _rm_json_str "$id"; id_l="$REPLY"
        _rm_json_str "$section"; sec_l="$REPLY"
        _rm_json_str "$tier"; tier_l="$REPLY"
        _rm_json_str "$action"; act_l="$REPLY"
        _rm_json_str "$undo"; undo_l="$REPLY"
        _rm_json_str "$unit"; unit_l="$REPLY"
        _rm_json_str "$label_key"; lab_l="$REPLY"
        _rm_json_str "$explain_key"; exp_l="$REPLY"
        if [ "$first" -eq 1 ]; then first=0; else rows="${rows},"; fi
        rows="${rows}"$'\n'"    {\"id\": ${id_l}, \"section\": ${sec_l}, \"tier\": ${tier_l}, \"action\": ${act_l}, \"undo\": ${undo_l}, \"native_cmd\": ${nat_lit}, \"unattended\": ${un_lit}, \"unit\": ${unit_l}, \"label_key\": ${lab_l}, \"explain_key\": ${exp_l}, \"mode\": \"${mode}\", \"mode_source\": \"${msrc}\", \"effective_auto\": ${effective}, \"last_scan\": ${scan_lit}, \"top_items\": ${top_lit}}"
    done < "$reg"

    if [ "$bad" -gt 0 ]; then
        _rm_warn_add "registry_rows_skipped" "${bad} malformed registry row(s) were skipped."
    fi
    _rm_header
    if [ -n "$rows" ]; then
        printf ',\n  "categories": [%s\n  ]' "$rows"
    else
        printf ',\n  "categories": []'
    fi
    printf ',\n  "warnings": [%s]\n}\n' "$_RM_WARNINGS"
}
