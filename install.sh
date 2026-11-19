#!/usr/bin/env bash
# ============================================================
# install.sh - install or upgrade macos-cleanup from a release archive
# ============================================================
# No git, no sudo, no prompts. Works as a pipe and as a local file:
#
#   curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh | bash
#   curl -fsSL <that URL> | bash -s -- --version 4.0.4 --configure-shell
#   bash install.sh --dry-run
#
# Prerequisites: macOS 11 or later and Python 3.9 or later (the terminal UI
# needs Python; the Command Line Tools provide it). Apple Silicon is the
# officially supported architecture; an Intel Mac is not blocked, only unsupported.
#
# It checks the Mac, downloads macos-cleanup-<version>.tar.gz and SHA256SUMS,
# verifies the checksum, unpacks next to the target folder, swaps it in
# atomically (the old version stays as <dir>.previous) and links the launcher at
# ~/.local/bin/macos-cleanup. Re-running upgrades in place. The program folder
# never disappears during an upgrade: on APFS the new and old folders trade
# places in one renamex_np(RENAME_SWAP) call; elsewhere it falls back to renames.
#
# The same file is the self-update engine: scripts/update_self.sh (macos-cleanup update-self)
# runs the installed copy of this script with --check, --update or --rollback, so the
# download, verification, unpack and swap code exists exactly once. It stays a single
# self-contained file on purpose: piped from curl it needs no other file next to it.
# Releases are checked against a published SHA-256 checksum; they are not signed.
#
# It never touches your settings folder (~/.config/macos-cleanup), the state
# folder (~/.local/state/macos-cleanup) or the quarantine, never edits a shell
# profile unless you pass --configure-shell, never installs a LaunchAgent, never
# runs a cleanup, never uses sudo and never starts the Command Line Tools
# installer for you.
# ============================================================

usage() {
    cat <<'USAGE_TEXT'
Usage: install.sh [options]

  --version X        install release X (default: the latest release)
  --dir DIR          program folder (default: $MACOS_CLEANUP_HOME or ~/.local/share/macos-cleanup)
  --dry-run          print what would happen; writes nothing and uses no network
  --configure-shell  add ~/.local/bin to PATH in your zsh or bash profile
  --quiet            print only warnings and errors
  -h, --help         show this help

Self-update (what `macos-cleanup update-self` runs; installed copies only):
  --check [--json]   read-only: compare the installed version with the latest release.
                     Exit 0 answered, 3 when the latest release could not be looked up
                     ("latest": null, never a false "up to date"). Downloads nothing.
  --update           update the installed copy to the latest release (or --version X);
                     refuses a git checkout and refuses while a cleanup run holds the lock
  --rollback         swap the installed copy back to <dir>.previous; no network

Environment:
  MACOS_CLEANUP_RELEASE_BASE     release download base laid out as <base>/v<version>/<file>;
                                 without --version it also needs <base>/LATEST (mirrors, tests)
  MACOS_CLEANUP_INSTALL_VERSION  same as --version
  MACOS_CLEANUP_HOME             program folder
  MACOS_CLEANUP_LEGACY_DIR       a v3 git checkout to mention in the migrate hint
  NO_COLOR                       plain output

Needs macOS 11 or later and Python 3.9 or later. Apple Silicon is the supported
architecture; an Intel Mac gets a warning, not a refusal.

Releases are verified against a published SHA-256 checksum; they are not cryptographically signed.
The install, update and rollback paths never touch your settings, state or quarantine folders
and never run a cleanup.

Exit codes: 0 done, 1 failed, 2 bad usage (or a git checkout in update mode), 3 this Mac is
missing a prerequisite (--check: the network lookup failed).
USAGE_TEXT
}

main() {
    # Never let a child process read the rest of a piped script.
    exec </dev/null

    local GITHUB_REPO="KasprowiczM/macOS_cleanup"
    local DEFAULT_BASE="https://github.com/${GITHUB_REPO}/releases/download"
    local LATEST_PAGE="https://github.com/${GITHUB_REPO}/releases/latest"
    local ISSUES_URL="https://github.com/${GITHUB_REPO}/issues"

    local OPT_VERSION="${MACOS_CLEANUP_INSTALL_VERSION:-}" OPT_DIR="" DRY_RUN=0 CONFIGURE_SHELL=0 QUIET=0
    local MODE=install OPT_JSON=0
    local CUSTOM_BASE=0 BASE
    if [ -n "${MACOS_CLEANUP_RELEASE_BASE:-}" ]; then
        CUSTOM_BASE=1
        BASE="${MACOS_CLEANUP_RELEASE_BASE%/}"
    else
        BASE="$DEFAULT_BASE"
    fi

    local GREEN="" YELLOW="" RED="" BOLD="" NC=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
        GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
    fi

    # ---- output: one row per fact, plain sentences ----
    row_ok()   { [ "$QUIET" = 1 ] || printf '  %s\xe2\x9c\x93%s %s\n' "$GREEN" "$NC" "$1"; }
    row_warn() { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$1"; }
    row_note() { [ "$QUIET" = 1 ] || printf '    %s\n' "$1"; }
    row_plan() { printf '  %s\xe2\x86\x92%s %s\n' "$BOLD" "$NC" "$1"; }
    # die "what happened." "what to do." [exit code]
    die() {
        printf '  %s\xe2\x9c\x97%s %s\n' "$RED" "$NC" "$1" >&2
        printf '    %s\n' "$2" >&2
        exit "${3:-1}"
    }

    # ---- arguments ----
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ -n "${2:-}" ] || die "--version needs a version number." "For example: --version 4.0.1" 2
                OPT_VERSION="$2"; shift 2 ;;
            --version=*) OPT_VERSION="${1#--version=}"; shift ;;
            --dir)
                [ -n "${2:-}" ] || die "--dir needs a folder." "For example: --dir \$HOME/.local/share/macos-cleanup" 2
                OPT_DIR="$2"; shift 2 ;;
            --dir=*) OPT_DIR="${1#--dir=}"; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --configure-shell) CONFIGURE_SHELL=1; shift ;;
            --quiet|-q) QUIET=1; shift ;;
            --check|--update|--rollback)
                [ "$MODE" = install ] || die "${1} cannot be combined with --${MODE}." "Pick one of --check, --update, --rollback." 2
                MODE="${1#--}"; shift ;;
            --json) OPT_JSON=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1" "Run it with --help to see the options." 2 ;;
        esac
    done

    [ "$OPT_JSON" = 0 ] || [ "$MODE" = check ] || die "--json only works together with --check." "Run: install.sh --check --json" 2
    if [ "$MODE" != install ] && [ "$CONFIGURE_SHELL" = 1 ]; then
        die "--configure-shell belongs to a fresh install, not to --${MODE}." "Leave it out." 2
    fi
    if [ "$MODE" = check ] && [ "$OPT_JSON" = 1 ]; then QUIET=1; fi

    local HOME_DIR="${HOME:-}"
    case "$HOME_DIR" in
        /*) ;;
        *) die "HOME is not set to an absolute folder." "Run the installer from a normal terminal session." 1 ;;
    esac
    HOME_DIR="${HOME_DIR%/}"

    if [ "$QUIET" != 1 ]; then
        case "$MODE" in
            install) printf '\n%smacos-cleanup installer%s\n\n' "$BOLD" "$NC" ;;
            check)   printf '\n%smacos-cleanup update check%s\n\n' "$BOLD" "$NC" ;;
            update)  printf '\n%smacos-cleanup self-update%s\n\n' "$BOLD" "$NC" ;;
            rollback) printf '\n%smacos-cleanup rollback%s\n\n' "$BOLD" "$NC" ;;
        esac
    fi

    # ---- 1. platform, 2. python3 and tools (not needed for the read-only --check) ----
    local py=""
    check_prereqs() {
        local os arch macos major
        os="$(uname -s 2>/dev/null || echo unknown)"
        [ "$os" = Darwin ] || die "This installer only runs on macOS." "Run it on a Mac running macOS 11 or later." 3
        arch="$(uname -m 2>/dev/null || echo unknown)"
        macos="$(sw_vers -productVersion 2>/dev/null || echo 0)"
        major="${macos%%.*}"
        case "$major" in ''|*[!0-9]*) major=0 ;; esac
        [ "$major" -ge 11 ] || die "macOS ${macos} is older than the supported macOS 11." \
            "Update macOS first, then run the installer again." 3
        if [ "$arch" = arm64 ]; then
            row_ok "macOS ${macos} on Apple Silicon"
        else
            row_ok "macOS ${macos} (${arch})"
            row_warn "This Mac is not Apple Silicon (${arch}). macos-cleanup is supported on Apple Silicon only; it is not blocked here, but it is untested on this processor."
        fi

        # python3: Apple's /usr/bin/python3 is only a shim until the Command Line Tools exist
        local dev pyver
        py="$(command -v python3 2>/dev/null || true)"
        if [ "$py" = /usr/bin/python3 ]; then
            dev="$(xcode-select -p 2>/dev/null || true)"
            if [ -z "$dev" ] || [ ! -x "$dev/usr/bin/python3" ]; then
                py=""
            fi
        fi
        if [ -z "$py" ]; then
            die "Python 3 is not installed yet: macOS only ships a placeholder until the Command Line Tools are installed, and the macos-cleanup terminal UI needs Python 3.9 or later." \
                "Run \"xcode-select --install\", wait for it to finish, then run this installer again." 3
        fi
        if ! "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
            pyver="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown)"
            die "Python ${pyver} is older than the 3.9 that the macos-cleanup terminal UI needs." \
                "Install a newer Python (the Command Line Tools provide one: \"xcode-select --install\")." 3
        fi
        pyver="$("$py" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo 3)"
        row_ok "Python ${pyver}"

        local tool
        for tool in curl tar shasum; do
            command -v "$tool" >/dev/null 2>&1 \
                || die "${tool} was not found." "Restore /usr/bin/${tool} (it is part of macOS) and try again." 3
        done
    }
    if [ "$MODE" = check ]; then
        command -v curl >/dev/null 2>&1 \
            || die "curl was not found." "Restore /usr/bin/curl (it is part of macOS) and try again." 3
    else
        check_prereqs
    fi

    # ---- 3. program folder ----
    local DIR
    if [ -n "$OPT_DIR" ]; then
        DIR="$OPT_DIR"
    elif [ -n "${MACOS_CLEANUP_HOME:-}" ]; then
        DIR="$MACOS_CLEANUP_HOME"
    else
        DIR="$HOME_DIR/.local/share/macos-cleanup"
    fi
    case "$DIR" in
        /*) ;;
        *) die "The program folder must be an absolute path (got: ${DIR})." \
               "Pass something like --dir \"\$HOME/.local/share/macos-cleanup\"." 2 ;;
    esac
    while [ "${DIR%/}" != "$DIR" ] && [ -n "${DIR%/}" ]; do DIR="${DIR%/}"; done
    local depth
    depth="$(printf '%s' "$DIR" | tr -cd '/' | wc -c | tr -d ' ')"
    if [ "$DIR" = "/" ] || [ "$DIR" = "$HOME_DIR" ] || [ "$depth" -lt 2 ]; then
        die "${DIR} is too broad to use as the program folder." \
            "Choose a folder of its own, for example --dir \"\$HOME/.local/share/macos-cleanup\"." 2
    fi
    case "$DIR" in
        */.|*/..|*/./*|*/../*) die "The program folder path may not contain . or .. parts." "Spell out the full path." 2 ;;
    esac

    local PREV="${DIR}.previous" OLD="${DIR}.swap-old"
    local LAUNCH_DIR="$HOME_DIR/.local/bin"
    local LAUNCHER="$LAUNCH_DIR/macos-cleanup"
    local ALIAS_NAME="mac-cleanup" ALIAS="$LAUNCH_DIR/mac-cleanup"

    # A folder that exists must be ours or empty; never move foreign data aside.
    is_toolkit_dir() { [ -f "$1/cleanup_all.sh" ] && [ -f "$1/VERSION" ]; }
    if [ -e "$DIR" ] || [ -L "$DIR" ]; then
        if [ -e "$DIR/.git" ]; then
            if [ "$MODE" = install ]; then
                die "${DIR} is a git checkout, and the installer will not replace a working copy." \
                    "Pick another place with --dir, or keep using the checkout."
            fi
            die "${DIR} is a git checkout (developer mode); the self-update never replaces a working copy." \
                "Update it with git: git -C \"${DIR}\" pull" 2
        fi
        if [ ! -d "$DIR" ]; then
            die "${DIR} exists and is not a folder." "Remove it or pick another place with --dir."
        fi
        if ! is_toolkit_dir "$DIR" && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
            die "${DIR} already holds files that are not macos-cleanup." "Pick an empty folder with --dir."
        fi
    fi
    local installed=""
    if is_toolkit_dir "$DIR"; then
        installed="$(tr -d '[:space:]' < "$DIR/VERSION" 2>/dev/null || true)"
    fi

    if [ "$MODE" != install ] && { [ -z "$installed" ] || [ ! -f "$DIR/.install-info" ]; }; then
        die "${DIR} is not an installed copy of macos-cleanup (there is no .install-info), so there is nothing to ${MODE}." \
            "Install it first: curl -fsSL https://github.com/${GITHUB_REPO}/releases/latest/download/install.sh | bash" 2
    fi

    # ---- 4. which version ----
    local VERSION="" TAG TARNAME
    version_ok() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$'; }
    if [ -n "$OPT_VERSION" ]; then
        VERSION="${OPT_VERSION#v}"
        version_ok "$VERSION" || die "\"${OPT_VERSION}\" is not a release version." "Use a number like 4.0.1." 2
    fi

    fetch() { # fetch URL DEST
        local url="$1" dest="$2" proto="=https"
        if [ "$CUSTOM_BASE" = 1 ]; then proto="=https,file"; fi
        curl --fail --silent --show-error --location --proto "$proto" --proto-redir "=https" \
            --connect-timeout 15 --max-time 900 --retry 2 -o "$dest" "$url" </dev/null
    }

    # lookup_latest: the newest release number into LOOKED_UP; on failure returns 1 and
    # leaves one sentence of what happened (LOOKUP_WHAT) and one of what to do (LOOKUP_TODO).
    local LOOKED_UP="" LOOKUP_WHAT="" LOOKUP_TODO=""
    lookup_latest() {
        LOOKED_UP=""
        if [ "$CUSTOM_BASE" = 1 ]; then
            local latest_file latest_raw
            latest_file="$(mktemp "${TMPDIR:-/tmp}/macos-cleanup-latest.XXXXXX")" || {
                LOOKUP_WHAT="Could not create a temporary file."
                LOOKUP_TODO="Check that ${TMPDIR:-/tmp} is writable."
                return 1
            }
            if ! fetch "$BASE/LATEST" "$latest_file" 2>/dev/null; then
                rm -f "$latest_file"
                LOOKUP_WHAT="Could not find the latest release at ${BASE}."
                LOOKUP_TODO="Check your internet connection, or choose a release with --version."
                return 1
            fi
            latest_raw="$(head -n 1 "$latest_file" | tr -d '[:space:]')"
            rm -f "$latest_file"
            LOOKED_UP="${latest_raw#v}"
            if ! version_ok "$LOOKED_UP"; then
                LOOKED_UP=""
                LOOKUP_WHAT="The latest-release answer was not a version number."
                LOOKUP_TODO="Choose a release with --version."
                return 1
            fi
        else
            local landed
            landed="$(curl --fail --silent --show-error --location --proto "=https" --proto-redir "=https" \
                --connect-timeout 15 --max-time 60 -o /dev/null -w '%{url_effective}' "$LATEST_PAGE" </dev/null 2>/dev/null)" || {
                LOOKUP_WHAT="Could not look up the latest release."
                LOOKUP_TODO="Check your internet connection, or choose a release with --version."
                return 1
            }
            LOOKED_UP="${landed##*/}"
            LOOKED_UP="${LOOKED_UP#v}"
            if ! version_ok "$LOOKED_UP"; then
                LOOKED_UP=""
                LOOKUP_WHAT="Could not read the latest release number."
                LOOKUP_TODO="Choose a release with --version."
                return 1
            fi
        fi
        return 0
    }

    # version_gt A B: success when A is a newer X.Y.Z than B (suffixes after the third number are ignored)
    version_gt() {
        awk -v a="$1" -v b="$2" 'BEGIN {
            split(a, x, /[^0-9]+/); split(b, y, /[^0-9]+/)
            for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
            exit 1 }'
    }

    # ---- which program does each name start? (read-only; used by --check and after the launchers) ----
    # resolve_file PATH: the physical path after following every symlink (a missing target stays as written).
    resolve_file() {
        local src="$1" dir link n=0
        while [ -L "$src" ] && [ "$n" -lt 40 ]; do
            dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)" || break
            link="$(readlink "$src")"
            case "$link" in
                /*) src="$link" ;;
                *) src="$dir/$link" ;;
            esac
            n=$((n + 1))
        done
        if dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)"; then
            printf '%s/%s\n' "$dir" "$(basename "$src")"
        else
            printf '%s\n' "$src"
        fi
    }

    # name_on_path NAME: sets NAME_FILE (what typing NAME runs, from command -v, or empty) and
    # NAME_STATE: ours (it resolves to this program's launcher), other, or none.
    local NAME_FILE="" NAME_STATE="none"
    name_on_path() {
        NAME_FILE="$(command -v "$1" 2>/dev/null || true)"
        case "$NAME_FILE" in
            /*|./*|../*) ;;
            *) NAME_FILE="" ;;
        esac
        if [ -z "$NAME_FILE" ]; then
            NAME_STATE=none
        elif [ "$(resolve_file "$NAME_FILE")" = "$(resolve_file "$DIR/bin/macos-cleanup")" ]; then
            NAME_STATE=ours
        else
            NAME_STATE=other
        fi
    }

    # report_names: one line per name; a name that starts another program is a warning that names the file.
    report_names() {
        local n
        for n in macos-cleanup "$ALIAS_NAME"; do
            name_on_path "$n"
            case "$NAME_STATE" in
                ours) row_ok "Typing ${n} starts macOS Cleanup (${NAME_FILE})" ;;
                other)
                    row_warn "Typing ${n} runs ${NAME_FILE}, not macOS Cleanup: that other program comes first on your PATH."
                    row_note "Use the other name, or put ${LAUNCH_DIR} before $(dirname "$NAME_FILE") in your PATH, or remove that other file." ;;
                *) [ "$MODE" != check ] || row_note "${n} is not found on your PATH yet." ;;
            esac
        done
    }

    json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
    names_json() { # {"macos-cleanup":{"path":...,"ours":...},"mac-cleanup":{...}}
        local n first=1 p o
        printf '{'
        for n in macos-cleanup "$ALIAS_NAME"; do
            name_on_path "$n"
            case "$NAME_STATE" in
                ours) p="\"$(json_str "$NAME_FILE")\""; o=true ;;
                other) p="\"$(json_str "$NAME_FILE")\""; o=false ;;
                *) p=null; o=null ;;
            esac
            [ "$first" = 1 ] || printf ','
            first=0
            printf '"%s":{"path":%s,"ours":%s}' "$n" "$p" "$o"
        done
        printf '}'
    }

    # ---- --check: read-only, no download, nothing written ----
    if [ "$MODE" = check ]; then
        local checked_at release_url available
        checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ! lookup_latest; then
            if [ "$OPT_JSON" = 1 ]; then
                if [ -n "$installed" ]; then
                    printf '{"current":"%s","latest":null,"update_available":null,"release_url":null,"checked_at":"%s","error":"lookup_failed"}\n' "$installed" "$checked_at"
                else
                    printf '{"current":null,"latest":null,"update_available":null,"release_url":null,"checked_at":"%s","error":"lookup_failed"}\n' "$checked_at"
                fi
            fi
            die "${LOOKUP_WHAT} The installed version could not be compared, so this is not an \"up to date\" answer." "${LOOKUP_TODO}" 3
        fi
        if [ "$CUSTOM_BASE" = 1 ]; then
            release_url="${BASE}/v${LOOKED_UP}/"
        else
            release_url="https://github.com/${GITHUB_REPO}/releases/tag/v${LOOKED_UP}"
        fi
        available=false
        if [ -z "$installed" ] || version_gt "$LOOKED_UP" "$installed"; then available=true; fi
        if [ "$OPT_JSON" = 1 ]; then
            if [ -n "$installed" ]; then
                printf '{"current":"%s","latest":"%s","update_available":%s,"release_url":"%s","checked_at":"%s","commands":%s}\n' \
                    "$installed" "$LOOKED_UP" "$available" "$release_url" "$checked_at" "$(names_json)"
            else
                printf '{"current":null,"latest":"%s","update_available":%s,"release_url":"%s","checked_at":"%s","commands":%s}\n' \
                    "$LOOKED_UP" "$available" "$release_url" "$checked_at" "$(names_json)"
            fi
        else
            row_ok "Installed version: ${installed:-none}"
            row_ok "Latest release:    ${LOOKED_UP}"
            if [ "$available" = true ]; then
                row_plan "A newer release is available: run \"macos-cleanup update-self\" to install it (${release_url})."
            else
                row_ok "You are up to date."
            fi
            report_names
            printf '    %s\n' "Releases are verified against a published SHA-256 checksum; they are not cryptographically signed."
        fi
        return 0
    fi

    if [ -z "$VERSION" ] && [ "$MODE" != rollback ]; then
        if [ "$DRY_RUN" = 1 ]; then
            VERSION="latest"
        else
            lookup_latest || die "$LOOKUP_WHAT" "$LOOKUP_TODO"
            VERSION="$LOOKED_UP"
        fi
    fi
    TAG="v${VERSION}"
    TARNAME="macos-cleanup-${VERSION}.tar.gz"

    # ---- dry run: say everything, write nothing ----
    if [ "$DRY_RUN" = 1 ] && [ "$MODE" = rollback ]; then
        printf '  %sDry run: nothing will be written, downloaded or changed.%s\n\n' "$BOLD" "$NC"
        if [ -d "$PREV" ] && is_toolkit_dir "$PREV"; then
            row_plan "Swap ${DIR} (version ${installed}) with ${PREV} (version $(tr -d '[:space:]' < "$PREV/VERSION" 2>/dev/null)); no network is used."
        else
            row_plan "There is no previous version in ${PREV}, so a rollback would be refused."
        fi
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDry run: nothing will be written, downloaded or changed.%s\n\n' "$BOLD" "$NC"
        if [ -n "$installed" ]; then
            row_plan "Found version ${installed} in ${DIR}."
        else
            row_plan "Nothing is installed in ${DIR} yet."
        fi
        if [ "$VERSION" = latest ]; then
            row_plan "Look up the latest release, then download macos-cleanup-<version>.tar.gz and SHA256SUMS from ${BASE}/v<version>/."
        else
            row_plan "Download ${TARNAME} and SHA256SUMS from ${BASE}/${TAG}/."
        fi
        row_plan "Check the archive against its SHA-256 checksum (releases are checksum-verified, not signed) and stop if it does not match."
        row_plan "Unpack it into a temporary folder next to ${DIR}."
        if [ -n "$installed" ]; then
            row_plan "Swap it in (atomically where the disk allows) and keep version ${installed} as ${PREV}."
        else
            row_plan "Move it into place as ${DIR}."
        fi
        row_plan "Link ${LAUNCHER} to ${DIR}/bin/macos-cleanup."
        row_plan "Link ${ALIAS} to ${DIR}/bin/macos-cleanup too, so that typing ${ALIAS_NAME} starts the same program."
        row_plan "Then check which program each of the two names starts on your PATH, and warn if it is another one."
        if [ "$MODE" = install ]; then
            case ":${PATH:-}:" in
                *":${LAUNCH_DIR}:"*) row_plan "${LAUNCH_DIR} is already on your PATH; nothing to add." ;;
                *) if [ "$CONFIGURE_SHELL" = 1 ]; then
                       row_plan "Add ${LAUNCH_DIR} to your PATH in your shell profile (--configure-shell)."
                   else
                       row_plan "Print the one PATH line to add yourself, because ${LAUNCH_DIR} is not on your PATH."
                   fi ;;
            esac
        fi
        row_plan "Leave your settings, state and quarantine folders, shell profiles and every other file untouched."
        return 0
    fi

    # ---- recovery from an interrupted earlier run, and cleanup on exit ----
    local SWAP_ACTIVE=0 STAGE="" d t c
    recover_interrupted() {
        for d in "${DIR}".tmp.*; do
            [ -e "$d" ] || continue
            # An atomic swap that finished leaves the OLD version inside the staging
            # folder, and the live .install-info names that folder (swap_id). Keep
            # the old version as <dir>.previous instead of throwing it away.
            if [ -f "$DIR/.install-info" ] && grep -qx "swap_id=${d##*/}" "$DIR/.install-info" 2>/dev/null; then
                t=""
                for c in "$d/x" "$d/x"/*; do
                    if [ -d "$c" ] && is_toolkit_dir "$c"; then t="$c"; break; fi
                done
                if [ -n "$t" ]; then
                    rm -rf "$PREV"
                    mv "$t" "$PREV" 2>/dev/null || true
                fi
            fi
            rm -rf "$d"
        done
        if [ -d "$OLD" ]; then
            if [ ! -e "$DIR" ]; then
                if mv "$OLD" "$DIR" 2>/dev/null; then
                    row_warn "An earlier update was interrupted; the previous version was put back."
                fi
            else
                rm -rf "$PREV"
                mv "$OLD" "$PREV" 2>/dev/null || true
            fi
        fi
        return 0
    }
    cleanup() {
        if [ "$SWAP_ACTIVE" = 1 ]; then
            SWAP_ACTIVE=0
            recover_interrupted
        fi
        [ -z "$STAGE" ] || rm -rf "$STAGE"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    mkdir -p "$(dirname "$DIR")" 2>/dev/null \
        || die "Cannot create the folder for ${DIR}." "Check that you can write there, or pick another place with --dir."
    [ -w "$(dirname "$DIR")" ] \
        || die "Cannot write to $(dirname "$DIR")." "Check its permissions, or pick another place with --dir."
    recover_interrupted
    installed=""
    if is_toolkit_dir "$DIR"; then
        installed="$(tr -d '[:space:]' < "$DIR/VERSION" 2>/dev/null || true)"
    fi

    # exchange_dirs A B: swap two folders in one atomic step (macOS renamex_np with
    # RENAME_SWAP, APFS). Fails without changing anything when that is unavailable.
    # MACOS_CLEANUP_INSTALL_NO_EXCHANGE=1 forces that failure; it exists only so the tests can
    # exercise the rename fallback.
    exchange_dirs() {
        [ "${MACOS_CLEANUP_INSTALL_NO_EXCHANGE:-}" != 1 ] || return 1
        "$py" -c '
import ctypes, os, sys
fn = ctypes.CDLL(None, use_errno=True).renamex_np
fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
fn.restype = ctypes.c_int
sys.exit(0 if fn(os.fsencode(sys.argv[2]), os.fsencode(sys.argv[3]), 2) == 0 else 1)
' exchange "$1" "$2" >/dev/null 2>&1
    }

    # engine_lock_held: a cleanup run holds <quarantine>/.apply.lock (the engine's own lock, a
    # folder with a pid file). A lock whose pid is gone is stale and does not count; a lock with
    # no readable pid is treated as held.
    engine_lock_held() {
        local q lock pid
        q="${MACOS_CLEANUP_QUARANTINE_DIR:-${QUARANTINE_ROOT:-$HOME_DIR/Library/Application Support/macOS_cleanup/quarantine}}"
        case "$q" in
            /*) ;;
            *) die "The quarantine folder setting must be an absolute path (got: ${q})." "Fix MACOS_CLEANUP_QUARANTINE_DIR." 2 ;;
        esac
        lock="${q%/}/.apply.lock"
        [ -d "$lock" ] || return 1
        pid="$(head -n 1 "$lock/pid" 2>/dev/null | tr -d '[:space:]')"
        LOCK_PATH="$lock"; LOCK_PID="$pid"
        case "$pid" in ''|*[!0-9]*) return 0 ;; esac
        kill -0 "$pid" 2>/dev/null
    }
    local LOCK_PATH="" LOCK_PID=""
    refuse_if_engine_busy() {
        if engine_lock_held; then
            die "A cleanup run is in progress (it holds ${LOCK_PATH}${LOCK_PID:+, pid ${LOCK_PID}}), and replacing the program folder under it could break it." \
                "Wait for it to finish, then run this again. Nothing was changed."
        fi
    }

    # ---- --rollback: swap the installed copy with <dir>.previous (no network) ----
    if [ "$MODE" = rollback ]; then
        if [ ! -d "$PREV" ] || ! is_toolkit_dir "$PREV"; then
            die "There is no previous version in ${PREV} to go back to." \
                "Rollback is only possible after an update; nothing was changed."
        fi
        refuse_if_engine_busy
        local back_to
        back_to="$(tr -d '[:space:]' < "$PREV/VERSION" 2>/dev/null || true)"
        SWAP_ACTIVE=1
        if exchange_dirs "$PREV" "$DIR"; then
            SWAP_ACTIVE=0
            row_note "Swapped in atomically: ${DIR} was never missing."
        else
            if ! mv "$DIR" "$OLD" 2>/dev/null; then
                SWAP_ACTIVE=0
                die "Could not move the current version aside." \
                    "Close anything using ${DIR} and run it again; nothing was changed."
            fi
            if ! mv "$PREV" "$DIR" 2>/dev/null; then
                mv "$OLD" "$DIR" 2>/dev/null
                SWAP_ACTIVE=0
                die "Could not move the previous version into place; the current version was put back." \
                    "Free some disk space and run it again."
            fi
            mv "$OLD" "$PREV" 2>/dev/null || true
            SWAP_ACTIVE=0
        fi
        row_ok "Rolled back ${installed} to ${back_to} (the version you left is kept in ${PREV}, so you can roll forward again)"
        cleanup
        trap - EXIT
        [ "$QUIET" = 1 ] || printf '\n  %sDone.%s Restart any open macos-cleanup window. Settings, state and quarantine were not touched.\n\n' "$BOLD" "$NC"
        return 0
    fi

    # ---- --update: nothing to do when the installed copy is already the newest ----
    if [ "$MODE" = update ] && [ -z "$OPT_VERSION" ] && ! version_gt "$VERSION" "$installed"; then
        row_ok "macos-cleanup ${installed} is up to date (latest release: ${VERSION})"
        cleanup
        trap - EXIT
        return 0
    fi

    # ---- already current: only make sure the launcher is right ----
    local skip_download=0
    if [ -n "$installed" ] && [ "$installed" = "$VERSION" ] && [ -x "$DIR/bin/macos-cleanup" ] && [ -f "$DIR/.install-info" ]; then
        skip_download=1
        row_ok "Version ${VERSION} is already installed in ${DIR}"
    fi

    if [ "$skip_download" = 0 ]; then
        # a running cleanup must not have its program folder swapped under it
        if [ -n "$installed" ]; then refuse_if_engine_busy; fi
        if [ "$MODE" = update ]; then
            printf '  %s\n' "Releases are verified against a published SHA-256 checksum; they are not cryptographically signed."
        fi
        # ---- 5. download ----
        STAGE="$(mktemp -d "${DIR}.tmp.XXXXXX" 2>/dev/null)" \
            || die "Cannot create a temporary folder next to ${DIR}." \
                   "Free some disk space or check the folder's permissions, then run again."
        mkdir "$STAGE/dl" "$STAGE/x" \
            || die "Cannot create a temporary folder next to ${DIR}." \
                   "Free some disk space or check the folder's permissions, then run again."
        local fname rc
        for fname in "$TARNAME" SHA256SUMS; do
            fetch "${BASE}/${TAG}/${fname}" "$STAGE/dl/${fname}" 2>"$STAGE/curl.err"
            rc=$?
            if [ "$rc" -ne 0 ]; then
                if [ "$rc" = 22 ]; then
                    die "Release ${VERSION} has no file named ${fname}." \
                        "Check the version number, or leave out --version to get the latest release."
                fi
                die "Could not download ${fname}." "Check your internet connection and run the installer again."
            fi
        done
        row_ok "Downloaded ${TARNAME}"

        # ---- 6. checksum ----
        local want got matches
        matches="$(awk -v f="$TARNAME" '{ n = $2; sub(/^\*/, "", n); if (n == f) print $1 }' "$STAGE/dl/SHA256SUMS" | wc -l | tr -d ' ')"
        want="$(awk -v f="$TARNAME" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$STAGE/dl/SHA256SUMS" | tr 'A-F' 'a-f')"
        if [ "$matches" != 1 ] || ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$'; then
            die "SHA256SUMS does not list ${TARNAME} exactly once, so the download cannot be checked." \
                "Nothing was installed. Run the installer again; if it keeps failing, report it at ${ISSUES_URL}."
        fi
        got="$(shasum -a 256 "$STAGE/dl/$TARNAME" | awk '{ print $1 }' | tr 'A-F' 'a-f')"
        if [ "$got" != "$want" ]; then
            die "The downloaded archive does not match its published checksum, so it was thrown away." \
                "Nothing was installed. Run the installer again; if it keeps failing, report it at ${ISSUES_URL}."
        fi
        row_ok "Checksum verified (SHA-256; releases are checksum-verified, not signed)"

        # ---- 7. unpack: refuse absolute paths, .. parts and links that leave the folder ----
        # Every member is checked before anything is extracted: no absolute paths, no ".."
        # parts, no links that leave the archive tree, no devices or other special files.
        local vrc=0
        "$py" -I -c '
import posixpath, sys, tarfile
try:
    with tarfile.open(sys.argv[1], "r:gz") as tf:
        for m in tf:
            name = m.name
            parts = name.split("/")
            if name.startswith("/") or ".." in parts or "\\" in name:
                sys.exit(10)
            if m.issym():
                target = m.linkname
                joined = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if target.startswith("/") or joined == ".." or joined.startswith("../"):
                    sys.exit(11)
            elif m.islnk():
                target = m.linkname
                if target.startswith("/") or ".." in target.split("/"):
                    sys.exit(11)
            elif not (m.isfile() or m.isdir()):
                sys.exit(12)
except (tarfile.TarError, OSError, EOFError):
    sys.exit(2)
' "$STAGE/dl/$TARNAME" >/dev/null 2>&1 || vrc=$?
        case "$vrc" in
            0) ;;
            10) die "The archive contains paths outside its own folder, so it was not unpacked." \
                    "Nothing was installed. Report it at ${ISSUES_URL}." ;;
            11) die "The archive contains links that point outside its own folder, so it was not unpacked." \
                    "Nothing was installed. Report it at ${ISSUES_URL}." ;;
            12) die "The archive contains entries that are not plain files, folders or links, so it was not unpacked." \
                    "Nothing was installed. Report it at ${ISSUES_URL}." ;;
            *) die "The archive is damaged and cannot be read." "Nothing was installed. Run the installer again." ;;
        esac
        tar -xzf "$STAGE/dl/$TARNAME" -C "$STAGE/x" 2>"$STAGE/tar.err" \
            || die "The archive could not be unpacked (the disk may be full)." \
                   "Free some disk space and run the installer again; nothing was changed."

        local NEWROOT="$STAGE/x" entries sub
        if [ ! -f "$NEWROOT/VERSION" ]; then
            # shellcheck disable=SC2012  # ls -A: dotfiles count, names are the archive's own
            entries="$(ls -A "$NEWROOT" | wc -l | tr -d ' ')"
            # shellcheck disable=SC2012
            sub="$(ls -A "$NEWROOT" | head -n 1)"
            if [ "$entries" = 1 ] && [ -d "$NEWROOT/$sub" ] && [ -f "$NEWROOT/$sub/VERSION" ]; then
                NEWROOT="$NEWROOT/$sub"
            fi
        fi
        if [ ! -f "$NEWROOT/VERSION" ] || [ ! -f "$NEWROOT/cleanup_all.sh" ] || [ ! -f "$NEWROOT/bin/macos-cleanup" ]; then
            die "The archive is not a complete macos-cleanup release." \
                "Nothing was installed. Report it at ${ISSUES_URL}."
        fi
        if [ "$(tr -d '[:space:]' < "$NEWROOT/VERSION")" != "$VERSION" ]; then
            die "The archive holds version $(tr -d '[:space:]' < "$NEWROOT/VERSION"), not the requested ${VERSION}." \
                "Nothing was installed. Report it at ${ISSUES_URL}."
        fi
        chmod 755 "$NEWROOT/bin/macos-cleanup" "$NEWROOT/cleanup_all.sh" 2>/dev/null || true
        {
            printf 'version=%s\n' "$VERSION"
            printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'source=%s/%s/%s\n' "$BASE" "$TAG" "$TARNAME"
            printf 'sha256=%s\n' "$got"
            printf 'installer=1\n'
            printf 'swap_id=%s\n' "${STAGE##*/}"
        } > "$NEWROOT/.install-info" \
            || die "Cannot write inside the temporary folder." "Free some disk space and run the installer again."
        row_ok "Unpacked ${TARNAME}"

        # ---- 8. swap: the program folder never goes missing; the old version is kept as <dir>.previous ----
        if [ -d "$DIR" ] && [ -z "$(ls -A "$DIR" 2>/dev/null)" ]; then
            rmdir "$DIR" 2>/dev/null || true
        fi
        if [ -e "$DIR" ]; then
            SWAP_ACTIVE=1
            if exchange_dirs "$NEWROOT" "$DIR"; then
                # DIR now holds the new version at once; NEWROOT's path holds the old one.
                rm -rf "$PREV"
                mv "$NEWROOT" "$PREV" 2>/dev/null || true
                SWAP_ACTIVE=0
                if [ -n "$installed" ]; then
                    row_ok "Updated ${installed} to ${VERSION} (previous version kept in ${PREV})"
                else
                    row_ok "Installed ${VERSION} in ${DIR}"
                fi
                row_note "Swapped in atomically: ${DIR} was never missing."
            else
                # Fallback (no APFS exchange): two renames. A crash between them leaves
                # <dir>.swap-old, which the next run puts back (recover_interrupted).
                if ! mv "$DIR" "$OLD" 2>/dev/null; then
                    SWAP_ACTIVE=0
                    die "Could not move the current version aside." \
                        "Close anything using ${DIR} and run the installer again; nothing was changed."
                fi
                if ! mv "$NEWROOT" "$DIR" 2>/dev/null; then
                    mv "$OLD" "$DIR" 2>/dev/null
                    SWAP_ACTIVE=0
                    die "Could not move the new version into place; the old version was put back." \
                        "Free some disk space and run the installer again."
                fi
                rm -rf "$PREV"
                mv "$OLD" "$PREV" 2>/dev/null || true
                SWAP_ACTIVE=0
                if [ -n "$installed" ]; then
                    row_ok "Updated ${installed} to ${VERSION} (previous version kept in ${PREV})"
                else
                    row_ok "Installed ${VERSION} in ${DIR}"
                fi
            fi
        else
            mv "$NEWROOT" "$DIR" 2>/dev/null \
                || die "Could not move the new version into place." \
                       "Check the folder's permissions and free disk space, then run again."
            row_ok "Installed ${VERSION} in ${DIR}"
        fi
    fi

    # ---- 9. launchers: macos-cleanup and its short alias mac-cleanup, one set of rules ----
    local target="$DIR/bin/macos-cleanup" cur link_dir launcher_state=ok tmp_link
    local alias_state=ok
    # link_state PATH: ok-to-link state of one launcher path: same, replace, foreign
    link_state() {
        local lp="$1"
        if [ -L "$lp" ]; then
            cur="$(readlink "$lp")"
            if [ "$cur" = "$target" ]; then
                LINK_STATE=same
            else
                link_dir="${cur%/bin/macos-cleanup}"
                if [ "$link_dir" != "$cur" ] && { [ -f "$link_dir/.install-info" ] || [ ! -e "$cur" ]; }; then
                    LINK_STATE=replace
                else
                    LINK_STATE=foreign
                fi
            fi
        elif [ -e "$lp" ]; then
            LINK_STATE=foreign
        else
            LINK_STATE=replace
        fi
    }
    local LINK_STATE=""
    mkdir -p "$LAUNCH_DIR" 2>/dev/null || { launcher_state=nodir; alias_state=nodir; }
    if [ "$launcher_state" = ok ]; then
        link_state "$LAUNCHER"; launcher_state="$LINK_STATE"
        link_state "$ALIAS"; alias_state="$LINK_STATE"
    fi
    case "$launcher_state" in
        same) row_ok "Launcher is in place: ${LAUNCHER}" ;;
        replace)
            tmp_link="$LAUNCH_DIR/.macos-cleanup.$$"
            if ln -s "$target" "$tmp_link" 2>/dev/null && mv -f "$tmp_link" "$LAUNCHER" 2>/dev/null; then
                row_ok "Launcher linked: ${LAUNCHER}"
            else
                rm -f "$tmp_link" 2>/dev/null
                row_warn "Could not create ${LAUNCHER}. Run macos-cleanup directly with ${target}."
                launcher_state=failed
            fi ;;
        foreign)
            row_warn "${LAUNCHER} already exists and is not from macos-cleanup, so it was left alone."
            row_note "Run macos-cleanup directly with ${target}, or remove that file and run the installer again." ;;
        nodir)
            row_warn "Could not create ${LAUNCH_DIR}. Run macos-cleanup directly with ${target}." ;;
    esac
    # The alias never fails the install: a file of someone else at its path is only reported.
    case "$alias_state" in
        same) row_ok "Alias is in place: ${ALIAS}" ;;
        replace)
            tmp_link="$LAUNCH_DIR/.${ALIAS_NAME}.$$"
            if ln -s "$target" "$tmp_link" 2>/dev/null && mv -f "$tmp_link" "$ALIAS" 2>/dev/null; then
                row_ok "Alias linked: ${ALIAS}"
            else
                rm -f "$tmp_link" 2>/dev/null
                row_warn "Could not create ${ALIAS}. Type macos-cleanup instead of ${ALIAS_NAME}."
                alias_state=failed
            fi ;;
        foreign)
            row_warn "${ALIAS} already exists and is not from macos-cleanup, so it was left alone."
            row_note "Typing ${ALIAS_NAME} will not start macOS Cleanup; use macos-cleanup, or remove that file and run the installer again." ;;
    esac
    # which program does each name start on this PATH?
    report_names

    # ---- 10. PATH: never edits a profile without --configure-shell (fresh installs only) ----
    local path_line='export PATH="$HOME/.local/bin:$PATH"' rc="" shell_name
    case "$MODE:$launcher_state" in
        install:same|install:replace)
            case ":${PATH:-}:" in
                *":${LAUNCH_DIR}:"*) row_ok "${LAUNCH_DIR} is on your PATH" ;;
                *)
                    shell_name="${SHELL##*/}"
                    case "$shell_name" in
                        zsh) rc="$HOME_DIR/.zshrc" ;;
                        bash) rc="$HOME_DIR/.bash_profile" ;;
                    esac
                    if [ "$CONFIGURE_SHELL" = 1 ] && [ -n "$rc" ]; then
                        if [ -f "$rc" ] && grep -q '^# >>> macos-cleanup >>>' "$rc" 2>/dev/null; then
                            row_ok "${rc} already has the macos-cleanup PATH block"
                        elif { printf '\n# >>> macos-cleanup >>>\n%s\n# <<< macos-cleanup <<<\n' "$path_line" >> "$rc"; } 2>/dev/null; then
                            row_ok "Added ${LAUNCH_DIR} to your PATH in ${rc}"
                            row_note "Open a new terminal window for it to take effect."
                        else
                            row_warn "Could not write ${rc}."
                            row_note "Add this line to your shell profile yourself: ${path_line}"
                        fi
                    else
                        row_warn "${LAUNCH_DIR} is not on your PATH yet."
                        row_note "Add this line to your shell profile (or re-run with --configure-shell), then open a new terminal:"
                        row_note "  ${path_line}"
                        if [ "$CONFIGURE_SHELL" = 1 ]; then
                            row_note "Your shell (${shell_name:-unknown}) is not zsh or bash, so no profile was edited."
                        fi
                    fi ;;
            esac ;;
    esac

    # ---- 11. an older (v3) git checkout: one line, nothing is moved or deleted ----
    local legacy="${MACOS_CLEANUP_LEGACY_DIR:-$HOME_DIR/Dev_Env/macOS_cleanup}"
    if [ "$MODE" = install ] && [ "$legacy" != "$DIR" ] && [ -e "$legacy/.git" ] && [ -f "$legacy/cleanup_all.sh" ]; then
        row_note "An older git-based copy was found in ${legacy}. Run \"macos-cleanup migrate --preview\" to see what can be copied over; nothing is moved or deleted."
    fi

    cleanup
    trap - EXIT
    if [ "$QUIET" != 1 ]; then
        if [ "$MODE" = update ]; then
            printf '\n  %sDone.%s Restart any open macos-cleanup window to use the new version. Settings, state and quarantine were not touched; "macos-cleanup update-self --rollback" goes back.\n\n' "$BOLD" "$NC"
        else
            printf '\n  %sDone.%s Run %smacos-cleanup%s to open it. Nothing was cleaned, and your settings, state and quarantine folders were not touched.\n\n' \
                "$BOLD" "$NC" "$BOLD" "$NC"
        fi
    fi
    return 0
}

main "$@"; exit $?
