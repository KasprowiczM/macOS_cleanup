#!/usr/bin/env bash
# =============================================================================
# lib/registry.sh — category registry loader and query API
#
# Reads share/categories.tsv (and share/app_caches.tsv) once into parallel
# indexed arrays. Every layer that needs to know a category — analyzer,
# planner, executor, reporter, events, UI — asks this file; nothing else keeps
# a category list (audit finding F17; v4 architecture contract, section 6).
#
# Bash 3.2 compatible: no associative arrays, no namerefs, no mapfile, no
# ${x,,}. Every array expansion that can be empty is guarded. Safe under
# `set -euo pipefail`. Sourcing defines functions and empty state only: it
# reads no file, creates nothing and never exits.
#
# Fail closed. A registry that does not parse or does not satisfy its
# invariants is not loaded at all: reg_load clears every array, sets
# REG_LOADED=0, prints one message naming the file, row and column, and
# returns 2. On an unloaded registry reg_is_id, reg_root_allows and every
# lookup answer "no".
#
# Public API (REPLY-style functions never fork):
#   reg_load [categories.tsv [app_caches.tsv]]   parse + validate; 0 or 2
#   registry_validate [categories.tsv [app_caches.tsv]]   same as reg_load
#   reg_validate                                 re-check the loaded registry
#   reg_index <id>                               REPLY = row index
#   reg_get <id> <column>                        REPLY = field ('' for '-')
#   reg_get_at <index> <column>                  REPLY = field
#   reg_ids [<section> | --tier <t> | --analyzer <fn>]   one id per line
#   reg_ids_for_analyzer <fn>                    one id per line
#   reg_sections [--cli]                         sections in table order
#   reg_is_id <x>   reg_is_section <x>
#   reg_count
#   reg_expand_path <p>                          REPLY = p with ~ -> $HOME
#   reg_root_allows <id> <normalized-path>       0 when under a root of <id>
#   reg_check_protected                          roots vs NEVER_TOUCH_PATHS
#   reg_app_cache_count
#   reg_app_cache_get <index> <label|path|category>
#   reg_app_cache_category <label>               REPLY = category id
#   reg_app_cache_labels [<category>]            one label per line
#   reg_missing_keys <i18n-file> [label|explain|both]   one 'id column key' per line
#
# State: REG_LOADED REG_COUNT REG_FILE REG_APPC_FILE REG_ERROR and the arrays
# REG_ID REG_SECTION REG_TIER REG_ACTION REG_UNDO REG_ANALYZER REG_ROOTS
# REG_NATIVE_CMD REG_TOOL REG_IN_USE REG_UNATTENDED REG_UNIT REG_FROM_FILE
# REG_LABEL_KEY REG_EXPLAIN_KEY REG_ORDER REG_LINE, and REG_APPC_LABEL
# REG_APPC_PATH REG_APPC_CATEGORY REG_APPC_LINE.
# =============================================================================
# shellcheck disable=SC2034,SC2088  # REG_* state is the API; a quoted ~ is a literal tilde on purpose

REG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REG_DEFAULT_FILE="${REG_LIB_DIR}/../share/categories.tsv"
REG_DEFAULT_APPC_FILE="${REG_LIB_DIR}/../share/app_caches.tsv"

# Column order of share/categories.tsv. The header line must match exactly.
REG_COLUMNS="id section tier action undo analyzer roots native_cmd tool in_use unattended unit from_file label_key explain_key order"
REG_NCOLS=16
REG_SECTIONS_ALLOWED=" trash user-caches logs system dev app-leftovers time-machine large-files overview "

REG_LOADED=0
REG_COUNT=0
REG_FILE=""
REG_APPC_FILE=""
REG_ERROR=""
REG_APPC_COUNT=0

REG_ID=()
REG_SECTION=()
REG_TIER=()
REG_ACTION=()
REG_UNDO=()
REG_ANALYZER=()
REG_ROOTS=()
REG_NATIVE_CMD=()
REG_TOOL=()
REG_IN_USE=()
REG_UNATTENDED=()
REG_UNIT=()
REG_FROM_FILE=()
REG_LABEL_KEY=()
REG_EXPLAIN_KEY=()
REG_ORDER=()
REG_LINE=()
REG_APPC_LABEL=()
REG_APPC_PATH=()
REG_APPC_CATEGORY=()
REG_APPC_LINE=()

# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------

# _reg_key <id> — id with '-' as '_' (the catbytes_set naming); the caller has
# already checked the id against [a-z0-9-].
_reg_key() {
    REPLY="${1//-/_}"
}

# _reg_safe_id <x> — true for a well-formed id; never evaluates the value.
_reg_safe_id() {
    case "${1:-}" in
        ''|*[!a-z0-9-]*) return 1 ;;
        [a-z]*) ;;
        *) return 1 ;;
    esac
    [ "${#1}" -ge 2 ] && [ "${#1}" -le 31 ]
}

# _reg_col_name <index> — REPLY = column name at 0-based index.
_reg_col_name() {
    local i=0 name
    REPLY=""
    for name in $REG_COLUMNS; do
        if [ "$i" -eq "$1" ]; then
            REPLY="$name"
            return 0
        fi
        i=$(( i + 1 ))
    done
    return 1
}

# _reg_clear — forget everything (also the per-id index variables).
_reg_clear() {
    local i=0 key
    while [ "$i" -lt "$REG_COUNT" ]; do
        if _reg_safe_id "${REG_ID[$i]}"; then
            _reg_key "${REG_ID[$i]}"
            key="$REPLY"
            unset "_REG_IDX_${key}"
        fi
        i=$(( i + 1 ))
    done
    REG_LOADED=0
    REG_COUNT=0
    REG_APPC_COUNT=0
    REG_ID=(); REG_SECTION=(); REG_TIER=(); REG_ACTION=(); REG_UNDO=()
    REG_ANALYZER=(); REG_ROOTS=(); REG_NATIVE_CMD=(); REG_TOOL=()
    REG_IN_USE=(); REG_UNATTENDED=(); REG_UNIT=(); REG_FROM_FILE=()
    REG_LABEL_KEY=(); REG_EXPLAIN_KEY=(); REG_ORDER=(); REG_LINE=()
    REG_APPC_LABEL=(); REG_APPC_PATH=(); REG_APPC_CATEGORY=(); REG_APPC_LINE=()
}

# _reg_fail_at <row-index> <column> <message> — rows are 0-based here, 1-based
# in the message. Sets REG_ERROR, prints it, returns 2.
_reg_fail_at() {
    local idx="$1" col="$2" msg="$3" id=""
    [ "$idx" -lt "$REG_COUNT" ] && id="${REG_ID[$idx]}"
    REG_ERROR="registry: ${REG_FILE}:${REG_LINE[$idx]:-?}: row $(( idx + 1 )) (id=${id}) column ${col}: ${msg}"
    printf '%s\n' "$REG_ERROR" >&2
    return 2
}

# _reg_fail_file <file> <line> <column> <message> [where] — parse-level
# failure; "where" is an optional "row N (id=X) " prefix once a row is known.
_reg_fail_file() {
    REG_ERROR="registry: ${1}:${2}: ${5:-}column ${3}: ${4}"
    printf '%s\n' "$REG_ERROR" >&2
    return 2
}

# _reg_fail_appc <row-index> <column> <message>
_reg_fail_appc() {
    local idx="$1" col="$2" msg="$3" label=""
    [ "$idx" -lt "$REG_APPC_COUNT" ] && label="${REG_APPC_LABEL[$idx]}"
    REG_ERROR="registry: ${REG_APPC_FILE}:${REG_APPC_LINE[$idx]:-?}: row $(( idx + 1 )) (label=${label}) column ${col}: ${msg}"
    printf '%s\n' "$REG_ERROR" >&2
    return 2
}

# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------

# _reg_parse_categories <file> — fills the arrays. Splitting uses parameter
# expansion on the tab, never IFS, so an empty field cannot collapse.
# shellcheck disable=SC2094  # the loop reads the registry file; the messages go to stderr, not into it
_reg_parse_categories() {
    local file="$1" line lineno=0 saw_header=0 header="" name tab=$'\t'
    local rest val i tabs n where
    local row=()

    for name in $REG_COLUMNS; do
        header="${header}${header:+$tab}${name}"
    done

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$(( lineno + 1 ))
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in
            *$'\r'*)
                where="header line: "
                [ "$saw_header" -eq 1 ] && where="row $(( REG_COUNT + 1 )) "
                _reg_fail_file "$file" "$lineno" "-" "carriage return (CRLF line ending)" "$where"
                return 2 ;;
        esac
        if [ "$saw_header" -eq 0 ]; then
            if [ "$line" != "$header" ]; then
                _reg_fail_file "$file" "$lineno" "header" "first non-comment line must be: ${REG_COLUMNS}"
                return 2
            fi
            saw_header=1
            continue
        fi
        tabs="${line//[^$tab]/}"
        if [ "${#tabs}" -ne $(( REG_NCOLS - 1 )) ]; then
            _reg_fail_file "$file" "$lineno" "-" "expected ${REG_NCOLS} tab-separated columns, found $(( ${#tabs} + 1 ))" \
                "row $(( REG_COUNT + 1 )) (id=${line%%"$tab"*}) "
            return 2
        fi
        rest="$line"
        i=0
        row=()
        while [ "$i" -lt "$REG_NCOLS" ]; do
            if [ "$i" -lt $(( REG_NCOLS - 1 )) ]; then
                val="${rest%%"$tab"*}"
                rest="${rest#*"$tab"}"
            else
                val="$rest"
            fi
            if [ -z "$val" ]; then
                _reg_col_name "$i"
                _reg_fail_file "$file" "$lineno" "$REPLY" "empty field (write '-' for none)" \
                    "row $(( REG_COUNT + 1 )) (id=${line%%"$tab"*}) "
                return 2
            fi
            [ "$val" = "-" ] && val=""
            row[$i]="$val"
            i=$(( i + 1 ))
        done
        n="$REG_COUNT"
        REG_ID[$n]="${row[0]}"
        REG_SECTION[$n]="${row[1]}"
        REG_TIER[$n]="${row[2]}"
        REG_ACTION[$n]="${row[3]}"
        REG_UNDO[$n]="${row[4]}"
        REG_ANALYZER[$n]="${row[5]}"
        REG_ROOTS[$n]="${row[6]}"
        REG_NATIVE_CMD[$n]="${row[7]}"
        REG_TOOL[$n]="${row[8]}"
        REG_IN_USE[$n]="${row[9]}"
        REG_UNATTENDED[$n]="${row[10]}"
        REG_UNIT[$n]="${row[11]}"
        REG_FROM_FILE[$n]="${row[12]}"
        REG_LABEL_KEY[$n]="${row[13]}"
        REG_EXPLAIN_KEY[$n]="${row[14]}"
        REG_ORDER[$n]="${row[15]}"
        REG_LINE[$n]="$lineno"
        REG_COUNT=$(( n + 1 ))
    done < "$file"

    if [ "$saw_header" -eq 0 ]; then
        _reg_fail_file "$file" "0" "header" "no header line found"
        return 2
    fi
    if [ "$REG_COUNT" -eq 0 ]; then
        _reg_fail_file "$file" "0" "-" "registry has no rows"
        return 2
    fi
    return 0
}

# _reg_parse_app_caches <file> — label, path, category.
# shellcheck disable=SC2094  # the loop reads the registry file; the messages go to stderr, not into it
_reg_parse_app_caches() {
    local file="$1" line lineno=0 saw_header=0 tab=$'\t' tabs label rest path cat n where
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$(( lineno + 1 ))
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in
            *$'\r'*)
                where="header line: "
                [ "$saw_header" -eq 1 ] && where="row $(( REG_APPC_COUNT + 1 )) "
                _reg_fail_file "$file" "$lineno" "-" "carriage return (CRLF line ending)" "$where"
                return 2 ;;
        esac
        if [ "$saw_header" -eq 0 ]; then
            if [ "$line" != "label${tab}path${tab}category" ]; then
                _reg_fail_file "$file" "$lineno" "header" "first non-comment line must be: label, path, category (tab-separated)"
                return 2
            fi
            saw_header=1
            continue
        fi
        tabs="${line//[^$tab]/}"
        if [ "${#tabs}" -ne 2 ]; then
            _reg_fail_file "$file" "$lineno" "-" "expected 3 tab-separated columns, found $(( ${#tabs} + 1 ))" \
                "row $(( REG_APPC_COUNT + 1 )) "
            return 2
        fi
        label="${line%%"$tab"*}"
        rest="${line#*"$tab"}"
        path="${rest%%"$tab"*}"
        cat="${rest#*"$tab"}"
        where="row $(( REG_APPC_COUNT + 1 )) "
        if [ -z "$label" ]; then _reg_fail_file "$file" "$lineno" "label" "empty field" "$where"; return 2; fi
        if [ -z "$path" ]; then _reg_fail_file "$file" "$lineno" "path" "empty field" "$where"; return 2; fi
        if [ -z "$cat" ]; then _reg_fail_file "$file" "$lineno" "category" "empty field" "$where"; return 2; fi
        n="$REG_APPC_COUNT"
        REG_APPC_LABEL[$n]="$label"
        REG_APPC_PATH[$n]="$path"
        REG_APPC_CATEGORY[$n]="$cat"
        REG_APPC_LINE[$n]="$lineno"
        REG_APPC_COUNT=$(( n + 1 ))
    done < "$file"
    if [ "$saw_header" -eq 0 ]; then
        _reg_fail_file "$file" "0" "header" "no header line found"
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# root and path checks
# ---------------------------------------------------------------------------

# _reg_root_problem <root> <action> — REPLY = why the root is unacceptable, or
# '' when it is fine. Defense in depth: the protection list proper is
# NEVER_TOUCH_PATHS plus lib/pathguard.sh; this only keeps an obviously
# catastrophic root out of the table.
_reg_root_problem() {
    local root="$1" action="$2" base work
    REPLY=""
    if [ -z "$root" ]; then
        REPLY="empty root (stray ':')"
        return 0
    fi
    case "$root" in
        *[!A-Za-z0-9\ ._@+~/*-]*)
            REPLY="root '${root}' has a character outside [A-Za-z0-9 ._@+~/*-]"
            return 0 ;;
    esac
    base="$root"
    case "$root" in
        */\*) base="${root%"/*"}" ;;
    esac
    case "$base" in
        *'*'*) REPLY="root '${root}': '*' is allowed only as the final '/*'"; return 0 ;;
    esac
    if [ -z "$base" ] || [ "$base" = "/" ]; then
        REPLY="root '${root}' is the filesystem root"
        return 0
    fi
    case "$base" in
        "~") REPLY="root '${root}' is a bare home directory"; return 0 ;;
        "~/"*|/*) ;;
        *) REPLY="root '${root}' must be absolute or ~/-relative"; return 0 ;;
    esac
    work="$base"
    case "$work" in "~/"*) work="/${work#"~/"}" ;; esac
    case "${work}/" in
        *//*|*/./*|*/../*)
            REPLY="root '${root}' has an empty, '.' or '..' path component or a trailing slash"
            return 0 ;;
    esac
    # Never acceptable, bare or as '/*', for any action.
    case "$base" in
        /|/System|/Library|/Applications|/Users|/usr|/bin|/sbin|/etc|/var|/private|/opt|/dev|/cores|/Volumes|/home|/private/etc|/private/var|\
        "~/Library"|"~/Documents"|"~/Desktop"|"~/Pictures"|"~/Movies"|"~/Music"|"~/Applications"|"~/.config"|"~/.local"|"~/.ssh"|"~/.gnupg")
            REPLY="root '${root}' is a protected system or home tree"
            return 0 ;;
        /System/*|/usr/*|/bin/*|/sbin/*|/dev/*|/cores/*|/etc/*|/private/etc/*|/Library/Keychains|/Library/Keychains/*|\
        "~/Documents/"*|"~/Desktop/"*|"~/.ssh/"*|"~/.gnupg/"*|"~/Library/Keychains"|"~/Library/Keychains/"*|"~/Library/Messages"|"~/Library/Messages/"*)
            REPLY="root '${root}' lies inside a protected system or home tree"
            return 0 ;;
    esac
    if [ "$action" != "report" ]; then
        # A destructive category never roots at a shared container as a whole.
        case "$base" in
            "~/Library/Application Support"|"~/Library/Containers"|"~/Library/Group Containers"|"~/Library/Preferences"|"~/Library/Mail"|"~/Library/Safari")
                REPLY="root '${root}' is a shared container; only report rows may use it"
                return 0 ;;
        esac
    fi
    # These must be written as 'X/*' (children only), never as the directory itself.
    case "$root" in
        "~/Library/Caches"|"~/Library/Logs"|"~/.Trash"|"~/Downloads"|"/tmp"|"/private/tmp"|"/var/log"|"/private/var/log"|"/Library/Logs"|"/var/folders"|"/private/var/folders"|\
        "~/Library/Developer"|"~/Library/Developer/Xcode"|"~/Library/Developer/CoreSimulator"|"~/Library/pnpm"|"~/.cache"|"~/Library/Application Support/MobileSync")
            REPLY="root '${root}' is a container directory; write '${root}/*' (children only)"
            return 0 ;;
    esac
    if [ "$action" != "report" ]; then
        case "$root" in
            "/Library/Caches")
                REPLY="root '${root}' is a container directory; write '${root}/*' (children only)"
                return 0 ;;
        esac
    fi
    return 0
}

# reg_expand_path <p> — REPLY = p with a leading ~ replaced by $HOME.
reg_expand_path() {
    local p="${1:-}" home="${REG_HOME:-${HOME:-}}"
    REPLY="$p"
    case "$p" in
        "~"|"~/"*) ;;
        *) return 0 ;;
    esac
    # An empty or relative HOME must not turn ~/x into /x or a relative path:
    # leave the value unexpanded (it then matches no root).
    case "$home" in
        /*) ;;
        *) return 1 ;;
    esac
    home="${home%/}"
    case "$p" in
        "~") REPLY="$home" ;;
        *) REPLY="${home}/${p#"~/"}" ;;
    esac
    return 0
}

# _reg_path_in_roots <roots> <expanded-path> — 0 when the path is allowed by one
# of the ':'-separated roots. 'X/*' = strictly below X; 'X' = X or below.
_reg_path_in_roots() {
    local roots="$1" path="$2" root base rest
    case "$path" in
        /*) ;;
        *) return 1 ;;
    esac
    case "${path}/" in
        *//*|*/./*|*/../*) return 1 ;;
    esac
    path="${path%/}"
    [ -n "$path" ] || return 1
    rest="$roots"
    while [ -n "$rest" ]; do
        case "$rest" in
            *:*) root="${rest%%:*}"; rest="${rest#*:}" ;;
            *) root="$rest"; rest="" ;;
        esac
        [ -n "$root" ] || continue
        reg_expand_path "$root"
        root="$REPLY"
        case "$root" in
            /*) ;;
            *) continue ;;
        esac
        case "$root" in
            */\*)
                base="${root%"/*"}"
                [ -n "$base" ] || continue
                case "$path" in "$base"/?*) return 0 ;; esac
                ;;
            *)
                if [ "$path" = "$root" ]; then return 0; fi
                case "$path" in "$root"/?*) return 0 ;; esac
                ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

# reg_validate — the contract's invariants over the loaded arrays. Returns 0,
# or 2 after printing one message that names the row and column.
reg_validate() {
    local i=0 j id section tier action undo analyzer roots native_cmd tool in_use
    local unatt unit from_file label_key explain_key order key prev_order=0
    local rest root first

    REG_ERROR=""
    if [ "$REG_COUNT" -le 0 ]; then
        REG_ERROR="registry: ${REG_FILE:-<none>}: no rows loaded"
        printf '%s\n' "$REG_ERROR" >&2
        return 2
    fi

    while [ "$i" -lt "$REG_COUNT" ]; do
        id="${REG_ID[$i]}"
        section="${REG_SECTION[$i]}"
        tier="${REG_TIER[$i]}"
        action="${REG_ACTION[$i]}"
        undo="${REG_UNDO[$i]}"
        analyzer="${REG_ANALYZER[$i]}"
        roots="${REG_ROOTS[$i]}"
        native_cmd="${REG_NATIVE_CMD[$i]}"
        tool="${REG_TOOL[$i]}"
        in_use="${REG_IN_USE[$i]}"
        unatt="${REG_UNATTENDED[$i]}"
        unit="${REG_UNIT[$i]}"
        from_file="${REG_FROM_FILE[$i]}"
        label_key="${REG_LABEL_KEY[$i]}"
        explain_key="${REG_EXPLAIN_KEY[$i]}"
        order="${REG_ORDER[$i]}"

        # id: well formed, unique
        if ! _reg_safe_id "$id"; then
            _reg_fail_at "$i" id "must match [a-z][a-z0-9-]{1,30}"; return 2
        fi
        j=0
        while [ "$j" -lt "$i" ]; do
            if [ "${REG_ID[$j]}" = "$id" ]; then
                _reg_fail_at "$i" id "duplicate id (first defined in row $(( j + 1 )))"; return 2
            fi
            j=$(( j + 1 ))
        done
        _reg_key "$id"
        key="$REPLY"

        # section, tier, action, undo: closed vocabularies
        case "$REG_SECTIONS_ALLOWED" in
            *" ${section} "*) ;;
            *) _reg_fail_at "$i" section "unknown section '${section}'"; return 2 ;;
        esac
        case "$tier" in
            regenerable|review|report) ;;
            *) _reg_fail_at "$i" tier "unknown tier '${tier}' (regenerable, review or report)"; return 2 ;;
        esac
        case "$action" in
            remove|native|report) ;;
            *) _reg_fail_at "$i" action "unknown action '${action}' (remove, native or report)"; return 2 ;;
        esac
        case "$undo" in
            quarantine|none) ;;
            *) _reg_fail_at "$i" undo "unknown undo '${undo}' (quarantine or none)"; return 2 ;;
        esac

        # tier and action must agree: the report tier has no destructive method
        if [ "$tier" = "report" ] && [ "$action" != "report" ]; then
            _reg_fail_at "$i" action "tier 'report' has no destructive method, found '${action}'"; return 2
        fi
        if [ "$action" = "report" ] && [ "$tier" != "report" ]; then
            _reg_fail_at "$i" tier "action 'report' requires tier 'report', found '${tier}'"; return 2
        fi
        if [ "$action" != "remove" ] && [ "$undo" != "none" ]; then
            _reg_fail_at "$i" undo "only action 'remove' can quarantine; '${action}' must use 'none'"; return 2
        fi
        if [ "$section" = "overview" ] && [ "$tier" != "report" ]; then
            _reg_fail_at "$i" tier "section 'overview' is analyzed only and must be tier 'report'"; return 2
        fi

        # analyzer: a function name; one analyzer serves one section only
        case "$analyzer" in
            analyze_*) ;;
            *) _reg_fail_at "$i" analyzer "must be an analyze_* function name"; return 2 ;;
        esac
        case "$analyzer" in
            *[!a-z0-9_]*) _reg_fail_at "$i" analyzer "must match analyze_[a-z0-9_]+"; return 2 ;;
        esac
        j=0
        while [ "$j" -lt "$i" ]; do
            if [ "${REG_ANALYZER[$j]}" = "$analyzer" ] && [ "${REG_SECTION[$j]}" != "$section" ]; then
                _reg_fail_at "$i" analyzer "analyzer '${analyzer}' already serves section '${REG_SECTION[$j]}' (row $(( j + 1 )))"; return 2
            fi
            j=$(( j + 1 ))
        done

        # roots: a remove category must name where it may act
        if [ -z "$roots" ] && [ "$action" = "remove" ]; then
            _reg_fail_at "$i" roots "action 'remove' needs at least one root"; return 2
        fi
        rest="$roots"
        while [ -n "$rest" ]; do
            case "$rest" in
                *:*) root="${rest%%:*}"; rest="${rest#*:}"
                     if [ -z "$rest" ]; then _reg_fail_at "$i" roots "trailing ':' (empty root)"; return 2; fi ;;
                *) root="$rest"; rest="" ;;
            esac
            _reg_root_problem "$root" "$action"
            if [ -n "$REPLY" ]; then
                _reg_fail_at "$i" roots "$REPLY"; return 2
            fi
        done

        # native binding
        if [ "$action" = "native" ]; then
            if [ -z "$native_cmd" ]; then
                _reg_fail_at "$i" native_cmd "action 'native' needs a command binding"; return 2
            fi
            if [ -z "$tool" ]; then
                _reg_fail_at "$i" tool "action 'native' needs the tool it runs"; return 2
            fi
            case "$native_cmd" in
                [a-z]*) ;;
                *) _reg_fail_at "$i" native_cmd "must start with a lower-case tool name"; return 2 ;;
            esac
            case "$native_cmd" in
                *[!a-z0-9\ =_.-]*)
                    _reg_fail_at "$i" native_cmd "has a character outside [a-z0-9 =_.-]"; return 2 ;;
            esac
            first="${native_cmd%% *}"
            if [ "$tool" != "$first" ]; then
                _reg_fail_at "$i" tool "tool '${tool}' is not the first word of native_cmd ('${first}')"; return 2
            fi
        else
            if [ -n "$native_cmd" ]; then
                _reg_fail_at "$i" native_cmd "only action 'native' may bind a command"; return 2
            fi
            if [ -n "$tool" ]; then
                _reg_fail_at "$i" tool "only action 'native' may name a tool"; return 2
            fi
        fi

        # in_use: a cache_owner_running key; a report row removes nothing
        if [ -n "$in_use" ]; then
            case "$in_use" in
                [a-z]*) ;;
                *) _reg_fail_at "$i" in_use "must match [a-z][a-z_]*"; return 2 ;;
            esac
            case "$in_use" in
                *[!a-z_]*) _reg_fail_at "$i" in_use "must match [a-z][a-z_]*"; return 2 ;;
            esac
            if [ "$action" = "report" ]; then
                _reg_fail_at "$i" in_use "a report row removes nothing and needs no in-use probe"; return 2
            fi
        fi

        # unattended: only the regenerable tier that quarantines
        case "$unatt" in
            yes|no) ;;
            *) _reg_fail_at "$i" unattended "must be yes or no"; return 2 ;;
        esac
        if [ "$unatt" = "yes" ]; then
            if [ "$tier" != "regenerable" ]; then
                _reg_fail_at "$i" unattended "'yes' is allowed only for tier 'regenerable', found '${tier}'"; return 2
            fi
            if [ "$action" != "remove" ] || [ "$undo" != "quarantine" ]; then
                _reg_fail_at "$i" unattended "'yes' is allowed only for categories that quarantine (action remove, undo quarantine)"; return 2
            fi
        fi

        case "$unit" in
            bytes|count) ;;
            *) _reg_fail_at "$i" unit "must be bytes or count"; return 2 ;;
        esac
        case "$from_file" in
            yes|no) ;;
            *) _reg_fail_at "$i" from_file "must be yes or no"; return 2 ;;
        esac
        if [ "$from_file" = "yes" ] && [ "$action" = "report" ]; then
            _reg_fail_at "$i" from_file "a report row is never executed, so 'yes' is not allowed"; return 2
        fi

        # i18n keys follow the id
        if [ "$label_key" != "cat_${key}" ]; then
            _reg_fail_at "$i" label_key "must be 'cat_${key}', found '${label_key}'"; return 2
        fi
        if [ "$explain_key" != "explain_${key}" ]; then
            _reg_fail_at "$i" explain_key "must be 'explain_${key}', found '${explain_key}'"; return 2
        fi

        # order: unique, ascending integer
        case "$order" in
            ''|*[!0-9]*) _reg_fail_at "$i" order "must be a positive integer"; return 2 ;;
        esac
        if [ "$order" -le "$prev_order" ]; then
            _reg_fail_at "$i" order "order ${order} is not above the previous row's ${prev_order} (rows must ascend, no duplicates)"; return 2
        fi
        prev_order="$order"

        i=$(( i + 1 ))
    done

    _reg_validate_app_caches || return 2
    return 0
}

# _reg_validate_app_caches — every allowlist row names a remove category of the
# user-caches section and lies under one of that category's roots.
_reg_validate_app_caches() {
    local i=0 j label path cat idx roots expanded
    while [ "$i" -lt "$REG_APPC_COUNT" ]; do
        label="${REG_APPC_LABEL[$i]}"
        path="${REG_APPC_PATH[$i]}"
        cat="${REG_APPC_CATEGORY[$i]}"
        j=0
        while [ "$j" -lt "$i" ]; do
            if [ "${REG_APPC_LABEL[$j]}" = "$label" ]; then
                _reg_fail_appc "$i" label "duplicate label (first in row $(( j + 1 )))"; return 2
            fi
            if [ "${REG_APPC_PATH[$j]}" = "$path" ]; then
                _reg_fail_appc "$i" path "duplicate path (first in row $(( j + 1 )))"; return 2
            fi
            j=$(( j + 1 ))
        done
        _reg_root_problem "$path" remove
        if [ -n "$REPLY" ]; then
            _reg_fail_appc "$i" path "$REPLY"; return 2
        fi
        case "$path" in
            *'*'*) _reg_fail_appc "$i" path "a cache path is one directory, not a pattern"; return 2 ;;
        esac
        if ! reg_index "$cat"; then
            _reg_fail_appc "$i" category "unknown category id '${cat}'"; return 2
        fi
        idx="$REPLY"
        if [ "${REG_SECTION[$idx]}" != "user-caches" ] || [ "${REG_ACTION[$idx]}" != "remove" ]; then
            _reg_fail_appc "$i" category "'${cat}' is not a user-caches category with action 'remove'"; return 2
        fi
        roots="${REG_ROOTS[$idx]}"
        reg_expand_path "$path"
        expanded="$REPLY"
        if ! _reg_path_in_roots "$roots" "$expanded"; then
            _reg_fail_appc "$i" path "not under any root of category '${cat}'"; return 2
        fi
        i=$(( i + 1 ))
    done
    return 0
}

# reg_check_protected — no remove/native root may equal or lie inside a path of
# NEVER_TOUCH_PATHS (when the caller has defined it). Returns 0 or 2.
reg_check_protected() {
    local i=0 rest root base prot count n
    count=0
    if [ -n "${NEVER_TOUCH_PATHS+x}" ]; then
        count="${#NEVER_TOUCH_PATHS[@]}"
    fi
    [ "$count" -gt 0 ] || return 0
    while [ "$i" -lt "$REG_COUNT" ]; do
        if [ "${REG_ACTION[$i]}" != "report" ]; then
            rest="${REG_ROOTS[$i]}"
            while [ -n "$rest" ]; do
                case "$rest" in
                    *:*) root="${rest%%:*}"; rest="${rest#*:}" ;;
                    *) root="$rest"; rest="" ;;
                esac
                reg_expand_path "$root"
                base="$REPLY"
                case "$base" in */\*) base="${base%"/*"}" ;; esac
                n=0
                while [ "$n" -lt "$count" ]; do
                    prot="${NEVER_TOUCH_PATHS[$n]}"
                    n=$(( n + 1 ))
                    [ -n "$prot" ] || continue
                    if [ "$base" = "$prot" ]; then
                        _reg_fail_at "$i" roots "root '${root}' is a protected path"; return 2
                    fi
                    case "$base" in
                        "$prot"/*) _reg_fail_at "$i" roots "root '${root}' lies inside protected path '${prot}'"; return 2 ;;
                    esac
                done
            done
        fi
        i=$(( i + 1 ))
    done
    return 0
}

# ---------------------------------------------------------------------------
# load
# ---------------------------------------------------------------------------

# reg_load [categories.tsv [app_caches.tsv]] — parse and validate. With no
# argument the shipped tables load once; a second call is a no-op while they
# are still the loaded ones. With a file
# argument the registry is reloaded from it. A second file argument loads the
# app-cache allowlist; with only the first, no allowlist is loaded.
reg_load() {
    local cat_file app_file="" i key
    if [ "$#" -eq 0 ]; then
        if [ "$REG_LOADED" -eq 1 ] && [ "$REG_FILE" = "$REG_DEFAULT_FILE" ] \
            && [ "$REG_APPC_FILE" = "$REG_DEFAULT_APPC_FILE" ]; then
            return 0
        fi
        cat_file="$REG_DEFAULT_FILE"
        app_file="$REG_DEFAULT_APPC_FILE"
    else
        cat_file="$1"
        app_file="${2:-}"
    fi

    _reg_clear
    REG_ERROR=""
    REG_FILE="$cat_file"
    REG_APPC_FILE="$app_file"

    if [ ! -f "$cat_file" ] || [ ! -r "$cat_file" ]; then
        REG_ERROR="registry: ${cat_file}: cannot read the category registry"
        printf '%s\n' "$REG_ERROR" >&2
        return 2
    fi
    if ! _reg_parse_categories "$cat_file"; then
        _reg_clear
        return 2
    fi
    if [ -n "$app_file" ]; then
        if [ ! -f "$app_file" ] || [ ! -r "$app_file" ]; then
            REG_ERROR="registry: ${app_file}: cannot read the app-cache allowlist"
            printf '%s\n' "$REG_ERROR" >&2
            _reg_clear
            return 2
        fi
        if ! _reg_parse_app_caches "$app_file"; then
            _reg_clear
            return 2
        fi
    fi

    # The per-id index exists before validation: _reg_validate_app_caches
    # resolves categories through reg_index. Ids are checked right here, so a
    # hostile id never reaches the variable name.
    i=0
    while [ "$i" -lt "$REG_COUNT" ]; do
        if _reg_safe_id "${REG_ID[$i]}"; then
            _reg_key "${REG_ID[$i]}"
            key="$REPLY"
            if ! eval "[ -n \"\${_REG_IDX_${key}:-}\" ]"; then
                eval "_REG_IDX_${key}=\"\$i\""
            fi
        fi
        i=$(( i + 1 ))
    done

    if ! reg_validate; then
        _reg_clear
        return 2
    fi
    REG_LOADED=1
    return 0
}

# registry_validate [categories.tsv [app_caches.tsv]] — validate a registry
# file (the shipped one with no argument). Leaves it loaded on success.
registry_validate() {
    if [ "$#" -eq 0 ]; then
        reg_load "$REG_DEFAULT_FILE" "$REG_DEFAULT_APPC_FILE"
    else
        reg_load "$@"
    fi
}

# ---------------------------------------------------------------------------
# queries
# ---------------------------------------------------------------------------

reg_count() {
    printf '%s\n' "$REG_COUNT"
}

# reg_index <id> — REPLY = row index; returns 1 when unknown or not loaded.
reg_index() {
    local key
    REPLY=""
    _reg_safe_id "${1:-}" || return 1
    _reg_key "$1"
    key="$REPLY"
    REPLY=""
    eval "REPLY=\"\${_REG_IDX_${key}:-}\""
    [ -n "$REPLY" ]
}

# reg_get_at <index> <column> — REPLY = field ('' when the file says '-').
reg_get_at() {
    local idx="${1:-}" col="${2:-}"
    REPLY=""
    case "$idx" in ''|*[!0-9]*) return 1 ;; esac
    [ "$idx" -lt "$REG_COUNT" ] || return 1
    case "$col" in
        id) REPLY="${REG_ID[$idx]}" ;;
        section) REPLY="${REG_SECTION[$idx]}" ;;
        tier) REPLY="${REG_TIER[$idx]}" ;;
        action) REPLY="${REG_ACTION[$idx]}" ;;
        undo) REPLY="${REG_UNDO[$idx]}" ;;
        analyzer) REPLY="${REG_ANALYZER[$idx]}" ;;
        roots) REPLY="${REG_ROOTS[$idx]}" ;;
        native_cmd) REPLY="${REG_NATIVE_CMD[$idx]}" ;;
        tool) REPLY="${REG_TOOL[$idx]}" ;;
        in_use) REPLY="${REG_IN_USE[$idx]}" ;;
        unattended) REPLY="${REG_UNATTENDED[$idx]}" ;;
        unit) REPLY="${REG_UNIT[$idx]}" ;;
        from_file) REPLY="${REG_FROM_FILE[$idx]}" ;;
        label_key) REPLY="${REG_LABEL_KEY[$idx]}" ;;
        explain_key) REPLY="${REG_EXPLAIN_KEY[$idx]}" ;;
        order) REPLY="${REG_ORDER[$idx]}" ;;
        *) return 1 ;;
    esac
    return 0
}

# reg_get <id> <column> — REPLY = field; 1 when the id or column is unknown.
reg_get() {
    local idx
    if ! reg_index "${1:-}"; then
        REPLY=""
        return 1
    fi
    idx="$REPLY"
    reg_get_at "$idx" "${2:-}"
}

reg_is_id() {
    reg_index "${1:-}"
}

reg_is_section() {
    local x="${1:-}" i=0
    [ -n "$x" ] || return 1
    while [ "$i" -lt "$REG_COUNT" ]; do
        [ "${REG_SECTION[$i]}" = "$x" ] && return 0
        i=$(( i + 1 ))
    done
    return 1
}

# reg_sections [--cli] — sections in order of first appearance; --cli leaves
# out 'overview', which is no --category value (this is ALL_CATEGORIES).
reg_sections() {
    local cli=0 i=0 seen=" " s
    [ "${1:-}" = "--cli" ] && cli=1
    while [ "$i" -lt "$REG_COUNT" ]; do
        s="${REG_SECTION[$i]}"
        i=$(( i + 1 ))
        case "$seen" in *" ${s} "*) continue ;; esac
        seen="${seen}${s} "
        if [ "$cli" -eq 1 ] && [ "$s" = "overview" ]; then
            continue
        fi
        printf '%s\n' "$s"
    done
    return 0
}

# reg_ids [<section> | --tier <t> | --analyzer <fn>] — ids in table order, one
# per line. Returns 1 for an unknown section, tier or flag, 0 otherwise (an
# empty answer is still 0).
reg_ids() {
    local mode="all" want="" i=0 hit
    case "${1:-}" in
        '') ;;
        --tier)
            mode="tier"; want="${2:-}"
            case "$want" in regenerable|review|report) ;; *) return 1 ;; esac ;;
        --analyzer)
            mode="analyzer"; want="${2:-}"
            [ -n "$want" ] || return 1 ;;
        --*) return 1 ;;
        *)
            mode="section"; want="$1"
            reg_is_section "$want" || return 1 ;;
    esac
    while [ "$i" -lt "$REG_COUNT" ]; do
        hit=1
        case "$mode" in
            section) [ "${REG_SECTION[$i]}" = "$want" ] || hit=0 ;;
            tier) [ "${REG_TIER[$i]}" = "$want" ] || hit=0 ;;
            analyzer) [ "${REG_ANALYZER[$i]}" = "$want" ] || hit=0 ;;
        esac
        [ "$hit" -eq 1 ] && printf '%s\n' "${REG_ID[$i]}"
        i=$(( i + 1 ))
    done
    return 0
}

reg_ids_for_analyzer() {
    [ -n "${1:-}" ] || return 1
    reg_ids --analyzer "$1"
}

# reg_root_allows <id> <normalized-path> — 0 when the (already normalized)
# absolute path lies under a root of <id>. 'X/*' admits strictly below X, 'X'
# admits X and below. Exact-case comparison on purpose: a case variant is
# refused rather than guessed at. Unknown id, no roots, a relative path, '..'
# or an unloaded registry all answer no.
reg_root_allows() {
    local idx roots
    reg_index "${1:-}" || return 1
    idx="$REPLY"
    roots="${REG_ROOTS[$idx]}"
    [ -n "$roots" ] || return 1
    _reg_path_in_roots "$roots" "${2:-}"
}

# ---------------------------------------------------------------------------
# app-cache allowlist
# ---------------------------------------------------------------------------

reg_app_cache_count() {
    printf '%s\n' "$REG_APPC_COUNT"
}

# reg_app_cache_get <index> <label|path|category> — REPLY = field.
reg_app_cache_get() {
    local idx="${1:-}"
    REPLY=""
    case "$idx" in ''|*[!0-9]*) return 1 ;; esac
    [ "$idx" -lt "$REG_APPC_COUNT" ] || return 1
    case "${2:-}" in
        label) REPLY="${REG_APPC_LABEL[$idx]}" ;;
        path) REPLY="${REG_APPC_PATH[$idx]}" ;;
        category) REPLY="${REG_APPC_CATEGORY[$idx]}" ;;
        *) return 1 ;;
    esac
    return 0
}

# reg_app_cache_category <label> — REPLY = category id; 1 for an unknown label.
reg_app_cache_category() {
    local i=0
    REPLY=""
    while [ "$i" -lt "$REG_APPC_COUNT" ]; do
        if [ "${REG_APPC_LABEL[$i]}" = "${1:-}" ]; then
            REPLY="${REG_APPC_CATEGORY[$i]}"
            return 0
        fi
        i=$(( i + 1 ))
    done
    return 1
}

# reg_app_cache_labels [<category>] — labels in table order.
reg_app_cache_labels() {
    local i=0 want="${1:-}"
    while [ "$i" -lt "$REG_APPC_COUNT" ]; do
        if [ -z "$want" ] || [ "${REG_APPC_CATEGORY[$i]}" = "$want" ]; then
            printf '%s\n' "${REG_APPC_LABEL[$i]}"
        fi
        i=$(( i + 1 ))
    done
    return 0
}

# ---------------------------------------------------------------------------
# i18n coverage
# ---------------------------------------------------------------------------

# reg_missing_keys <i18n-file> [label|explain|both] — prints one
# 'id<TAB>column<TAB>key' line per registry key that the dictionary does not
# define. The file is read as text (a key is a case label such as
# '        cat_trash)'); it is never sourced. Returns 0 when nothing is missing,
# 1 when something is, 2 when the file cannot be read.
reg_missing_keys() {
    local file="${1:-}" which="${2:-label}" i=0 missing=0 key col
    [ -n "$file" ] && [ -r "$file" ] || return 2
    while [ "$i" -lt "$REG_COUNT" ]; do
        for col in label_key explain_key; do
            case "${which}:${col}" in
                label:label_key|both:*|explain:explain_key) ;;
                *) continue ;;
            esac
            reg_get_at "$i" "$col"
            key="$REPLY"
            if ! grep -Eq "^[[:space:]]*([A-Za-z0-9_]+\\|)*${key}(\\|[A-Za-z0-9_]+)*\\)" "$file"; then
                printf '%s\t%s\t%s\n' "${REG_ID[$i]}" "$col" "$key"
                missing=1
            fi
        done
        i=$(( i + 1 ))
    done
    [ "$missing" -eq 0 ]
}

# Run directly (bash lib/registry.sh [categories.tsv [app_caches.tsv]]): validate
# and report. Sourcing never reaches this.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if registry_validate "$@"; then
        printf 'registry ok: %s categories, %s app caches (%s)\n' "$REG_COUNT" "$REG_APPC_COUNT" "$REG_FILE"
        exit 0
    fi
    exit 2
fi
