#!/usr/bin/env bash
# ============================================================
# uninstall.sh - remove macos-cleanup from this Mac
# ============================================================
# Run it as `macos-cleanup uninstall`, or `bash uninstall.sh` from the program folder.
#
# It removes only these known places, nothing else:
#   - the scheduled-run LaunchAgent, if you installed one (stopped first)
#   - the launcher ~/.local/bin/macos-cleanup and its short alias ~/.local/bin/mac-cleanup
#     (only when they are ours: a link into this program, or a file with our marker)
#   - the program folder, its .previous copy and leftovers of an interrupted install
#   - the state folder (run history, caches, migration backups)   default: removed
#   - the config folder (your settings)                          default: kept
# The quarantine (files macos-cleanup moved aside so you can restore them) is never
# removed silently. When it holds runs, uninstall prints its size and location and
# leaves it alone; deleting it takes --purge-quarantine together with --yes.
# It never removes Homebrew, any app or a shell profile, never uses sudo, and
# refuses any path that resolves outside your home folder.
# ============================================================

usage() {
    cat <<'USAGE_TEXT'
Usage: uninstall.sh [options]

  --yes, -y           do not ask; keep settings and remove the state folder unless told otherwise
  --keep-config       keep the settings folder (the default)
  --purge             also remove the settings folder (alias: --purge-data)
  --keep-state        keep the state folder (run history, caches, migration backups)
  --purge-quarantine  also delete the quarantine, the restore points of earlier cleanups.
                      Needs --yes. Without it the quarantine is always kept.
                      (alias: --delete-quarantine)
  --dir DIR           program folder (default: where macos-cleanup is installed)
  --dry-run           show what would be removed; remove nothing
  -h, --help          show this help

Exit codes: 0 done, 1 refused or failed, 2 bad usage.
USAGE_TEXT
}

main() {
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

    local ASSUME_YES=0 PURGE=0 KEEP_CONFIG_FLAG=0 KEEP_STATE=0 DRY_RUN=0 OPT_DIR="" PURGE_Q=0
    local GREEN="" YELLOW="" RED="" BOLD="" NC=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
        GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
    fi
    row_ok()   { printf '  %s\xe2\x9c\x93%s %s\n' "$GREEN" "$NC" "$1"; }
    row_warn() { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$1"; }
    row_note() { printf '    %s\n' "$1"; }
    row_plan() { printf '  %s\xe2\x86\x92%s %s\n' "$BOLD" "$NC" "$1"; }
    die() { # die "what happened." "what to do." [code]
        printf '  %s\xe2\x9c\x97%s %s\n' "$RED" "$NC" "$1" >&2
        printf '    %s\n' "$2" >&2
        exit "${3:-1}"
    }

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes|-y) ASSUME_YES=1; shift ;;
            --keep-config) KEEP_CONFIG_FLAG=1; shift ;;
            --purge|--purge-data) PURGE=1; shift ;;
            --keep-state) KEEP_STATE=1; shift ;;
            --purge-quarantine|--delete-quarantine) PURGE_Q=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --dir)
                [ -n "${2:-}" ] || die "--dir needs a folder." "For example: --dir \$HOME/.local/share/macos-cleanup" 2
                OPT_DIR="$2"; shift 2 ;;
            --dir=*) OPT_DIR="${1#--dir=}"; shift ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1" "Run it with --help to see the options." 2 ;;
        esac
    done
    if [ "$PURGE" = 1 ] && [ "$KEEP_CONFIG_FLAG" = 1 ]; then
        die "--purge and --keep-config contradict each other." "Choose one of them." 2
    fi
    if [ "$PURGE_Q" = 1 ] && [ "$ASSUME_YES" = 0 ]; then
        die "--purge-quarantine permanently deletes your restore points, so it also needs --yes." \
            "Run it again with both --purge-quarantine and --yes, or leave --purge-quarantine out to keep the quarantine." 2
    fi

    # ---- where things are (same precedence as the program's own path resolver) ----
    clean() {
        local p="$1"
        while [ "${p%/}" != "$p" ] && [ -n "${p%/}" ]; do p="${p%/}"; done
        [ -n "$p" ] || p="/"
        printf '%s' "$p"
    }
    # physical path of something that may not exist yet: the deepest existing
    # ancestor is made physical, the missing tail is appended unchanged
    physical() {
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
    inside() {
        local path="$1" parent="$2"
        parent="${parent%/}"
        case "$path" in
            "$parent"|"$parent"/*) return 0 ;;
        esac
        return 1
    }
    absolute_env() { # absolute_env NAME VALUE
        case "$2" in
            /*) ;;
            *) die "${1} must be an absolute path (got: ${2})." "Nothing was removed. Fix or unset ${1}." 2 ;;
        esac
    }

    case "${HOME:-}" in
        /*) ;;
        *) die "HOME is not set to an absolute folder." "Run it from a normal terminal session." 1 ;;
    esac
    local HOME_DIR HOME_PHYS
    HOME_DIR="$(clean "$HOME")"
    HOME_PHYS="$(physical "$HOME_DIR")"

    local PROGRAM CONFIG STATE QUARANTINE base
    if [ -n "$OPT_DIR" ]; then
        case "$OPT_DIR" in
            /*) PROGRAM="$(clean "$OPT_DIR")" ;;
            *) die "--dir must be an absolute path." "Pass something like --dir \"\$HOME/.local/share/macos-cleanup\"." 2 ;;
        esac
    elif [ -n "${MACOS_CLEANUP_HOME:-}" ]; then
        absolute_env MACOS_CLEANUP_HOME "$MACOS_CLEANUP_HOME"
        PROGRAM="$(clean "$MACOS_CLEANUP_HOME")"
    elif [ -e "$SCRIPT_DIR/.git" ] || [ -f "$SCRIPT_DIR/.install-info" ]; then
        PROGRAM="$SCRIPT_DIR"
    else
        PROGRAM="$HOME_DIR/.local/share/macos-cleanup"
    fi

    if [ -n "${MACOS_CLEANUP_CONFIG_DIR:-}" ]; then
        absolute_env MACOS_CLEANUP_CONFIG_DIR "$MACOS_CLEANUP_CONFIG_DIR"
        CONFIG="$(clean "$MACOS_CLEANUP_CONFIG_DIR")"
    else
        base="$HOME_DIR/.config"
        case "${XDG_CONFIG_HOME:-}" in /*) base="$(clean "$XDG_CONFIG_HOME")" ;; esac
        CONFIG="$base/macos-cleanup"
    fi
    if [ -n "${MACOS_CLEANUP_STATE_DIR:-}" ]; then
        absolute_env MACOS_CLEANUP_STATE_DIR "$MACOS_CLEANUP_STATE_DIR"
        STATE="$(clean "$MACOS_CLEANUP_STATE_DIR")"
    else
        base="$HOME_DIR/.local/state"
        case "${XDG_STATE_HOME:-}" in /*) base="$(clean "$XDG_STATE_HOME")" ;; esac
        STATE="$base/macos-cleanup"
    fi
    if [ -n "${MACOS_CLEANUP_QUARANTINE_DIR:-}" ]; then
        absolute_env MACOS_CLEANUP_QUARANTINE_DIR "$MACOS_CLEANUP_QUARANTINE_DIR"
        QUARANTINE="$(clean "$MACOS_CLEANUP_QUARANTINE_DIR")"
    elif [ -n "${QUARANTINE_ROOT:-}" ]; then
        absolute_env QUARANTINE_ROOT "$QUARANTINE_ROOT"
        QUARANTINE="$(clean "$QUARANTINE_ROOT")"
    else
        QUARANTINE="$HOME_DIR/Library/Application Support/macOS_cleanup/quarantine"
    fi

    local LAUNCHER="$HOME_DIR/.local/bin/macos-cleanup"
    local ALIAS="$HOME_DIR/.local/bin/mac-cleanup"
    local AGENT_DIR="$HOME_DIR/Library/LaunchAgents"
    local UID_NUM LABEL="com.github.kasprowiczm.macos-cleanup"
    UID_NUM="$(id -u 2>/dev/null || echo 0)"

    # ---- path safety: refuse before anything is touched ----
    # safe_path LABEL PATH KIND   (KIND: program | data | quarantine)
    safe_path() {
        local label="$1" p="$2" kind="$3" phys name
        case "$p" in
            /*) ;;
            *) die "The ${label} folder (${p}) is not an absolute path." "Nothing was removed." ;;
        esac
        case "$p" in
            */..|*/../*|*/.|*/./*) die "The ${label} folder (${p}) contains . or .. parts." "Nothing was removed." ;;
        esac
        if [ "$p" = "/" ] || [ "$p" = "$HOME_DIR" ]; then
            die "Refusing to remove ${p}: that is not a macos-cleanup folder." "Nothing was removed."
        fi
        phys="$(physical "$p")"
        if [ "$phys" = "$HOME_PHYS" ] || ! inside "$phys" "$HOME_PHYS"; then
            die "The ${label} folder (${p}) is outside your home folder, so it will not be removed." \
                "Nothing was removed. Remove it yourself if it really belongs to macos-cleanup."
        fi
        name="${p##*/}"
        case "$kind" in
            program)
                if [ -e "$p/.git" ]; then
                    die "${p} is a git checkout (developer mode), and uninstall will not delete a working copy." \
                        "Nothing was removed. Delete the checkout yourself if you want it gone."
                fi
                if [ -e "$p" ] && [ ! -f "$p/.install-info" ] && [ "$name" != "macos-cleanup" ]; then
                    die "${p} was not created by the macos-cleanup installer, so it will not be removed." \
                        "Nothing was removed. Remove it yourself if it really belongs to macos-cleanup."
                fi ;;
            quarantine)
                if [ "$name" != "quarantine" ]; then
                    die "The ${label} folder (${p}) is not named quarantine, so it will not be touched." \
                        "Nothing was removed. Remove it yourself if it really belongs to macos-cleanup."
                fi ;;
            *)
                if [ "$name" != "macos-cleanup" ]; then
                    die "The ${label} folder (${p}) is not named macos-cleanup, so it will not be removed." \
                        "Nothing was removed. Remove it yourself, or rename it to macos-cleanup first."
                fi ;;
        esac
        return 0
    }
    safe_path program "$PROGRAM" program
    safe_path state "$STATE" data
    safe_path config "$CONFIG" data
    safe_path quarantine "$QUARANTINE" quarantine
    local item
    for item in "$CONFIG" "$STATE" "$QUARANTINE"; do
        if inside "$(physical "$item")" "$(physical "$PROGRAM")"; then
            die "${item} is inside the program folder, so removing the program would remove it too." \
                "Nothing was removed. Move it out of ${PROGRAM} first."
        fi
    done

    # ---- the quarantine: count its runs, never touch it unless told twice ----
    local Q_RUNS=0 Q_KB=0 d
    if [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ]; then
        for d in "$QUARANTINE"/*/; do
            [ -d "$d" ] && [ ! -L "${d%/}" ] && Q_RUNS=$((Q_RUNS + 1))
        done
        if [ "$Q_RUNS" -gt 0 ]; then
            Q_KB="$(du -sk "$QUARANTINE" 2>/dev/null | awk '{ print $1 }')"
            case "$Q_KB" in ''|*[!0-9]*) Q_KB=0 ;; esac
        fi
    fi
    human_size() { # KiB -> text
        awk -v k="$1" 'BEGIN {
            if (k >= 1048576) printf "%.1f GB", k / 1048576;
            else if (k >= 1024) printf "%.1f MB", k / 1024;
            else printf "%d KB", k }'
    }

    # ---- decisions ----
    local KEEP_CONFIG=1 REMOVE_STATE=1
    [ "$PURGE" = 1 ] && KEEP_CONFIG=0
    [ "$KEEP_STATE" = 1 ] && REMOVE_STATE=0

    # A removal must never take quarantine runs with it by accident.
    if [ "$Q_RUNS" -gt 0 ] && [ "$PURGE_Q" = 0 ]; then
        local qphys holder
        qphys="$(physical "$QUARANTINE")"
        for holder in "$PROGRAM" "$STATE" "$CONFIG"; do
            if { [ "$holder" = "$STATE" ] && [ "$REMOVE_STATE" = 0 ]; } || { [ "$holder" = "$CONFIG" ] && [ "$KEEP_CONFIG" = 1 ]; }; then
                continue
            fi
            if inside "$qphys" "$(physical "$holder")"; then
                die "The quarantine (${QUARANTINE}) is inside ${holder}, which would be removed with its ${Q_RUNS} restore point(s)." \
                    "Nothing was removed. Move the quarantine out, or add --purge-quarantine --yes to delete it too."
            fi
        done
    fi

    ask() { # ask QUESTION DEFAULT(y|n) : returns 0 for yes
        local question="$1" default="$2" answer hint
        if [ "$default" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
        printf '  %s %s ' "$question" "$hint"
        IFS= read -r answer || answer=""
        [ -n "$answer" ] || answer="$default"
        case "$answer" in y|Y|yes|YES|Yes) return 0 ;; esac
        return 1
    }

    printf '\n%smacos-cleanup uninstall%s\n\n' "$BOLD" "$NC"
    if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
        [ -t 0 ] || die "There is no terminal to ask you anything." "Run it in Terminal, or add --yes (and --purge to remove your settings too)."
        row_plan "This removes the program (${PROGRAM}) and the macos-cleanup launchers (macos-cleanup, mac-cleanup)."
        if [ "$Q_RUNS" -gt 0 ]; then
            row_plan "Your quarantine (${Q_RUNS} run(s), $(human_size "$Q_KB")) is kept; uninstall never deletes it without --purge-quarantine --yes."
        fi
        if [ "$PURGE" = 0 ] && [ "$KEEP_CONFIG_FLAG" = 0 ]; then
            if ask "Keep your settings in ${CONFIG}?" y; then KEEP_CONFIG=1; else KEEP_CONFIG=0; fi
        fi
        if [ "$KEEP_STATE" = 0 ]; then
            if ask "Keep run history, caches and backups in ${STATE}?" n; then REMOVE_STATE=0; else REMOVE_STATE=1; fi
        fi
        ask "Remove macos-cleanup now?" n || { row_note "Nothing was removed."; return 0; }
        echo
    fi

    # ---- 1. scheduled runs ----
    local plist="$AGENT_DIR/${LABEL}.plist"
    if [ -e "$plist" ]; then
        if ! grep -q 'macos-cleanup' "$plist" 2>/dev/null; then
            row_warn "${plist} does not look like a macos-cleanup schedule, so it was left alone."
        elif [ "$DRY_RUN" = 1 ]; then
            row_plan "Stop the scheduled run ${LABEL} and remove ${plist}."
        else
            if command -v launchctl >/dev/null 2>&1; then
                launchctl bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 \
                    || launchctl bootout "gui/${UID_NUM}" "$plist" >/dev/null 2>&1 || true
            fi
            if rm -f "$plist" 2>/dev/null; then
                row_ok "Stopped and removed the scheduled run ${LABEL}"
            else
                row_warn "Could not remove ${plist}."
                row_note "Remove it yourself: rm \"${plist}\""
            fi
        fi
    fi

    # ---- 2. launchers: macos-cleanup and its short alias mac-cleanup, removed on the same condition ----
    local cur link_dir owned lp
    for lp in "$LAUNCHER" "$ALIAS"; do
        owned=0
        if [ -L "$lp" ]; then
            cur="$(readlink "$lp")"
            link_dir="${cur%/bin/macos-cleanup}"
            if [ "$cur" = "$PROGRAM/bin/macos-cleanup" ] || { [ "$link_dir" != "$cur" ] && { [ -f "$link_dir/.install-info" ] || [ ! -e "$cur" ]; }; }; then
                owned=1
            fi
        elif [ -f "$lp" ] && grep -q 'macos-cleanup launcher' "$lp" 2>/dev/null; then
            owned=1
        fi
        if [ -L "$lp" ] || [ -e "$lp" ]; then
            if [ "$owned" = 1 ]; then
                if [ "$DRY_RUN" = 1 ]; then
                    row_plan "Remove the launcher ${lp}."
                elif rm -f "$lp" 2>/dev/null; then
                    row_ok "Removed the launcher ${lp}"
                else
                    row_warn "Could not remove ${lp}."
                    row_note "Remove it yourself: rm \"${lp}\""
                fi
            else
                row_warn "${lp} is not the macos-cleanup launcher, so it was left alone."
            fi
        fi
    done

    # ---- 3. program folder and leftovers ----
    local leftover found=0
    for leftover in "$PROGRAM" "${PROGRAM}.previous" "${PROGRAM}.swap-old" "${PROGRAM}".tmp.*; do
        if [ -e "$leftover" ] || [ -L "$leftover" ]; then
            found=1
            if [ "$DRY_RUN" = 1 ]; then
                row_plan "Remove ${leftover}."
            elif rm -rf "$leftover" 2>/dev/null && [ ! -e "$leftover" ]; then
                row_ok "Removed ${leftover}"
            else
                row_warn "Could not remove ${leftover}."
                row_note "Remove it yourself: rm -rf \"${leftover}\""
            fi
        fi
    done
    [ "$found" = 1 ] || row_ok "No program folder found at ${PROGRAM}"

    # ---- 4. state ----
    if [ "$REMOVE_STATE" = 1 ]; then
        if [ -e "$STATE" ] || [ -L "$STATE" ]; then
            if [ "$DRY_RUN" = 1 ]; then
                row_plan "Remove the state folder ${STATE} (run history, caches, migration backups)."
            elif rm -rf "$STATE" 2>/dev/null && [ ! -e "$STATE" ]; then
                row_ok "Removed the state folder ${STATE}"
            else
                row_warn "Could not remove ${STATE}."
                row_note "Remove it yourself: rm -rf \"${STATE}\""
            fi
        fi
    elif [ -e "$STATE" ]; then
        row_ok "Kept the state folder ${STATE}"
    fi

    # ---- 5. config ----
    if [ "$KEEP_CONFIG" = 0 ]; then
        if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
            if [ "$DRY_RUN" = 1 ]; then
                row_plan "Remove your settings folder ${CONFIG}."
            elif rm -rf "$CONFIG" 2>/dev/null && [ ! -e "$CONFIG" ]; then
                row_ok "Removed your settings folder ${CONFIG}"
            else
                row_warn "Could not remove ${CONFIG}."
                row_note "Remove it yourself: rm -rf \"${CONFIG}\""
            fi
        fi
    elif [ -e "$CONFIG" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            row_plan "Keep your settings folder ${CONFIG}."
        else
            row_ok "Kept your settings folder ${CONFIG}"
        fi
    fi

    # ---- 6. quarantine: only with --purge-quarantine and --yes ----
    if [ "$Q_RUNS" -gt 0 ]; then
        if [ "$PURGE_Q" = 1 ]; then
            if [ "$DRY_RUN" = 1 ]; then
                row_plan "Delete the quarantine ${QUARANTINE} (${Q_RUNS} run(s), $(human_size "$Q_KB")). This cannot be undone."
            else
                chmod -R u+w "$QUARANTINE" 2>/dev/null || true
                if rm -rf "$QUARANTINE" 2>/dev/null && [ ! -e "$QUARANTINE" ]; then
                    row_ok "Deleted the quarantine ${QUARANTINE} (${Q_RUNS} run(s), $(human_size "$Q_KB"))"
                    rmdir "$(dirname "$QUARANTINE")" 2>/dev/null || true
                else
                    row_warn "Could not delete ${QUARANTINE}."
                    row_note "Remove it yourself: rm -rf \"${QUARANTINE}\""
                fi
            fi
        else
            row_warn "Kept the quarantine: ${Q_RUNS} run(s), $(human_size "$Q_KB"), in ${QUARANTINE}"
            row_note "It holds files macos-cleanup moved aside; each run has a manifest.tsv saying where its files came from."
            row_note "To delete it as well, run: bash uninstall.sh --purge-quarantine --yes"
        fi
    elif [ "$PURGE_Q" = 1 ] && [ -e "$QUARANTINE" ]; then
        row_ok "The quarantine at ${QUARANTINE} holds no runs, so nothing was deleted there"
    fi

    # ---- shell profile hint (never edited by uninstall) ----
    local rc
    for rc in "$HOME_DIR/.zshrc" "$HOME_DIR/.bash_profile"; do
        if [ -f "$rc" ] && grep -q '^# >>> macos-cleanup >>>' "$rc" 2>/dev/null; then
            row_note "${rc} still has a small PATH block between \"# >>> macos-cleanup >>>\" and \"# <<< macos-cleanup <<<\"; delete those lines if you like."
        fi
    done

    echo
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDry run: nothing was removed.%s\n\n' "$BOLD" "$NC"
    else
        printf '  %sDone.%s Homebrew, other tools and your apps were not touched.\n\n' "$BOLD" "$NC"
    fi
    return 0
}

main "$@"; exit $?
