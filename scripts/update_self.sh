#!/usr/bin/env bash
# ============================================================
# update_self.sh - explicit, manual self-update of an installed macos-cleanup
# ============================================================
# Run it as `macos-cleanup update-self ...`. It never runs by itself: there is no
# schedule, no startup hook and no background check anywhere; the tool stays offline
# until you run this.
#
#   update_self.sh --check [--json]   read-only: installed version versus the latest release
#   update_self.sh                    download, verify, swap in; the old version stays as <dir>.previous
#   update_self.sh --rollback         swap back to <dir>.previous (no network)
#   options: --version X (a specific release), --dry-run, --quiet, -h
#
# One implementation: this script is only a guard and a dispatcher. The download,
# checksum check, safe unpack and atomic swap are the code of the installed install.sh,
# which this script runs in its --check/--update/--rollback modes. install.sh stays
# one self-contained file so that `curl ... | bash` works with nothing else on disk, and
# the updater reuses it instead of keeping a second copy of the same logic.
#
# Installed copies only (the folder has .install-info). In a git checkout it prints how
# to update with git and exits 2. It never touches your settings, state or quarantine,
# refuses to run while a cleanup run holds the lock, honours MACOS_CLEANUP_RELEASE_BASE
# (mirrors, tests), and says plainly that releases are checksum-verified, not signed.
#
# Exit codes: 0 done, 1 failed or refused, 2 bad usage or not an installed copy,
# 3 --check could not look up the latest release.
# ============================================================

usage() {
    cat <<'USAGE_TEXT'
Usage: update_self.sh [--check [--json] | --rollback] [--version X] [--dry-run] [--quiet]

  --check            read-only: compare the installed version with the latest release;
                     with --json prints {current, latest, update_available, release_url, checked_at}
                     (exit 3 and "latest": null when the lookup fails)
  (no option)        download the latest release, verify its SHA-256 checksum, swap it in
                     atomically and keep the old version as <dir>.previous
  --rollback         swap back to <dir>.previous (no network)
  --version X        update to release X instead of the latest
  --dry-run          say what would happen; write nothing
  --quiet, -q        only warnings and errors
  -h, --help         show this help

Releases are verified against a published SHA-256 checksum; they are not cryptographically signed.
It never runs automatically, never checks in the background and never touches your settings,
state or quarantine. Environment: MACOS_CLEANUP_RELEASE_BASE for a mirror.
USAGE_TEXT
}

main() {
    local ROOT
    ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"

    local -a pass
    local mode_set=0 have_json=0 have_check=0 have_dry=0
    pass=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) have_check=1; mode_set=$((mode_set + 1)); pass=(${pass[@]+"${pass[@]}"} --check); shift ;;
            --rollback) mode_set=$((mode_set + 1)); pass=(${pass[@]+"${pass[@]}"} --rollback); shift ;;
            --json) have_json=1; pass=(${pass[@]+"${pass[@]}"} --json); shift ;;
            --dry-run|--quiet|-q) [ "$1" != "--dry-run" ] || have_dry=1; pass=(${pass[@]+"${pass[@]}"} "$1"); shift ;;
            --version)
                [ -n "${2:-}" ] || { echo "--version needs a version number, for example --version 4.0.1" >&2; return 2; }
                pass=(${pass[@]+"${pass[@]}"} --version "$2"); shift 2 ;;
            --version=*) pass=(${pass[@]+"${pass[@]}"} "$1"); shift ;;
            -h|--help) usage; return 0 ;;
            *) echo "Unknown option: $1. Run it with --help to see the options." >&2; return 2 ;;
        esac
    done
    if [ "$mode_set" -gt 1 ]; then
        echo "--check and --rollback cannot be combined." >&2
        return 2
    fi
    if [ "$have_json" = 1 ] && [ "$have_check" = 0 ]; then
        echo "--json only works together with --check." >&2
        return 2
    fi
    if [ "$mode_set" = 0 ]; then
        pass=(${pass[@]+"${pass[@]}"} --update)
    fi

    if [ -e "$ROOT/.git" ]; then
        echo "This is a git checkout (developer mode), so the self-update does not apply." >&2
        echo "Update it with git: git -C \"$ROOT\" pull" >&2
        return 2
    fi
    if [ ! -f "$ROOT/.install-info" ]; then
        echo "$ROOT is not an installed copy of macos-cleanup (there is no .install-info), so it cannot update itself." >&2
        echo "Install a release first: curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh | bash" >&2
        return 2
    fi
    if [ ! -f "$ROOT/install.sh" ]; then
        echo "install.sh is missing from $ROOT, so the update cannot run." >&2
        echo "Reinstall: curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh | bash" >&2
        return 1
    fi
    local before after rc old_installer=0
    before="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
    grep -q 'ALIAS_NAME' "$ROOT/install.sh" 2>/dev/null || old_installer=1
    /bin/bash "$ROOT/install.sh" --dir "$ROOT" "${pass[@]}"
    rc=$?
    # The installer that just ran is the OLD copy; one from before 4.0.2 does not know the short
    # name mac-cleanup. The new copy is in place now, so run its launcher step once: no download,
    # no swap, it only links what is missing and checks which program each name starts.
    if [ "$old_installer" = 1 ] && [ "$rc" = 0 ] && [ "$mode_set" = 0 ] && [ "$have_dry" = 0 ] && [ -f "$ROOT/install.sh" ]; then
        after="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            /bin/bash "$ROOT/install.sh" --dir "$ROOT" --update --version "$after" --quiet || true
        fi
    fi
    return "$rc"
}

main "$@"; exit $?
