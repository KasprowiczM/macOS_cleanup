#!/usr/bin/env bash
# =============================================================================
# config/defaults.sh — Default configuration for cleanup_all.sh
# Bash 3.2 compatible.
# =============================================================================
# shellcheck disable=SC2034,SC2155

# ---------------------------------------------------------------------------
# Script identity & versioning
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="cleanup_all.sh"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The version lives in one place: the top-level VERSION file. A missing or
# malformed file is not fatal, it just never reaches a report verbatim.
_mc_ver=""
IFS= read -r _mc_ver < "${PROJECT_DIR}/VERSION" 2>/dev/null || true
if [[ ! "$_mc_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    _mc_ver="0.0.0-unknown"
fi
readonly SCRIPT_VERSION="$_mc_ver"
unset _mc_ver

# ---------------------------------------------------------------------------
# Runtime directories (V4 architecture section 1)
#
# The engine and the user's data live apart. The resolver in lib/paths.sh
# yields four folders:
#   program     this toolkit (read-only at runtime; replaced by an upgrade)
#   config      ~/.config/macos-cleanup           (settings, excludes, overlays)
#   state       ~/.local/state/macos-cleanup      (runs/<run_id>/: log, plan, report, ...)
#   quarantine  ~/Library/Application Support/macOS_cleanup/quarantine (restore point)
# Every run owns <state>/runs/<run_id>/. Restore metadata (manifest.tsv,
# journal.jsonl, run-info.json) lives inside the quarantine run, never here.
#
# Legacy overrides stay honoured for 4.x and are logged once as deprecated:
#   LOGS_DIR        directory for the log, unreadable list and size memo
#   REPORTS_DIR     directory for report, plan and journal
#   QUARANTINE_ROOT / QUARANTINE_RUN_DIR   (see lib/paths.sh)
#   CLEANUP_JOURNAL_FILE   explicit run-journal file
# CLEANUP_RESTORE_MANIFEST is no longer read: the manifest always sits in the
# quarantine run next to the payload it describes (F01).
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091  # followed only when shellcheck runs with -x
# shellcheck source=../lib/paths.sh
source "${PROJECT_DIR}/lib/paths.sh"

# Run id: YYYY-MM-DD_HHMMSS_PID. A well-formed MACOS_CLEANUP_RUN_ID (the UI
# creates the run directory before it starts the engine) is adopted.
if mc_run_id_valid "${MACOS_CLEANUP_RUN_ID:-}"; then
    readonly RUN_TIMESTAMP="$MACOS_CLEANUP_RUN_ID"
else
    readonly RUN_TIMESTAMP="$(date '+%Y-%m-%d_%H%M%S')_$$"
fi

MC_JOURNAL_FILE_OVERRIDE="${CLEANUP_JOURNAL_FILE:-}"
MC_PATHS_INIT_RC=0
mc_paths_init "$PROJECT_DIR" || MC_PATHS_INIT_RC=$?
if (( MC_PATHS_INIT_RC == 0 )); then
    MC_RUN_DIR="$(mc_run_dir "$RUN_TIMESTAMP")" || MC_PATHS_INIT_RC=2
fi
if (( MC_PATHS_INIT_RC == 0 )); then
    readonly QUARANTINE_ROOT="$MC_QUARANTINE_DIR"
    readonly QUARANTINE_RUN_DIR="$(mc_quarantine_run_dir "$RUN_TIMESTAMP")"
    if [[ -n "$MC_LEGACY_LOGS_DIR" ]]; then
        readonly LOG_FILE="${MC_LEGACY_LOGS_DIR}/cleanup_${RUN_TIMESTAMP}.log"
        readonly MC_UNREADABLE_FILE="${MC_LEGACY_LOGS_DIR}/unreadable_${RUN_TIMESTAMP}.txt"
        readonly MC_SIZE_MEMO_FILE="${MC_LEGACY_LOGS_DIR}/size_memo_${RUN_TIMESTAMP}.tsv"
    else
        readonly LOG_FILE="${MC_RUN_DIR}/engine.log"
        readonly MC_UNREADABLE_FILE="${MC_RUN_DIR}/unreadable.tsv"
        readonly MC_SIZE_MEMO_FILE="${MC_RUN_DIR}/size_memo.tsv"
    fi
    if [[ -n "$MC_LEGACY_REPORTS_DIR" ]]; then
        readonly REPORT_FILE="${MC_LEGACY_REPORTS_DIR}/report_${RUN_TIMESTAMP}.md"
        readonly PLAN_FILE_DEFAULT="${MC_LEGACY_REPORTS_DIR}/plan_${RUN_TIMESTAMP}.json"
        readonly CLEANUP_JOURNAL_FILE="${CLEANUP_JOURNAL_FILE:-${MC_LEGACY_REPORTS_DIR}/journal_${RUN_TIMESTAMP}.jsonl}"
    else
        readonly REPORT_FILE="${MC_RUN_DIR}/report.md"
        readonly PLAN_FILE_DEFAULT="${MC_RUN_DIR}/plan.json"
        readonly CLEANUP_JOURNAL_FILE="${CLEANUP_JOURNAL_FILE:-${MC_RUN_DIR}/journal.jsonl}"
    fi
    readonly RUN_JSON_FILE="${MC_RUN_DIR}/run.json"
else
    # A setting is unusable (cleanup_all.sh reports MC_PATHS_ERROR and exits 2).
    # Library callers that bypass the entry point still fail closed: the values
    # below keep the validators (validate_quarantine_root, _run_dir) rejecting.
    MC_RUN_DIR=""
    readonly QUARANTINE_ROOT="${QUARANTINE_ROOT:-${HOME}/Library/Application Support/macOS_cleanup/quarantine}"
    readonly QUARANTINE_RUN_DIR="${QUARANTINE_RUN_DIR:-${QUARANTINE_ROOT}/${RUN_TIMESTAMP}}"
    readonly LOG_FILE="/dev/null"
    readonly MC_UNREADABLE_FILE="/dev/null"
    readonly MC_SIZE_MEMO_FILE=""
    readonly REPORT_FILE="/dev/null"
    readonly PLAN_FILE_DEFAULT="/dev/null"
    readonly CLEANUP_JOURNAL_FILE="/dev/null"
    readonly RUN_JSON_FILE=""
fi
# Remember which values are the engine's own, so a later mc_paths_init (in this
# shell, e.g. lib/cli_v4.sh) does not mistake them for user overrides.
MC_ENGINE_QUARANTINE_ROOT="$QUARANTINE_ROOT"
MC_ENGINE_QUARANTINE_RUN_DIR="$QUARANTINE_RUN_DIR"
readonly CLEANUP_RESTORE_MANIFEST="${QUARANTINE_RUN_DIR}/manifest.tsv"
readonly CLEANUP_QUARANTINE_JOURNAL="${QUARANTINE_RUN_DIR}/journal.jsonl"
readonly CLEANUP_QUARANTINE_RUN_INFO="${QUARANTINE_RUN_DIR}/run-info.json"
RULES_FILE="${RULES_FILE:-${PROJECT_DIR}/cleanup_rules.yaml}"

# ---------------------------------------------------------------------------
# Default operating mode
# Progressive model: always dry-run first, then ask per category before acting.
#
# MODE values:
#   dry-run      — analyze only, no deletions, generate report
#   interactive  — ask per-category with warnings, then act
#   auto-safe    — act on "safe" items only, report the rest
# ---------------------------------------------------------------------------
DEFAULT_MODE="dry-run"

# V4 section 10.4: consent and the removal mode never come from the inherited
# environment. Unprefixed AUTO_YES and REMOVE_MODE are ignored (one warning line
# each, naming what to use instead). Unprefixed NON_INTERACTIVE can only reduce
# interactivity, so it is honoured with a deprecation note;
# MACOS_CLEANUP_NON_INTERACTIVE=1 is the supported form. The warnings are
# printed once the run folder exists (mc_flush_startup_warnings).
_mc_ni=0
case "${AUTO_YES:-}" in
    ''|0) ;;
    *) mc_startup_warn "AUTO_YES in the environment is ignored; use --yes (consent comes from CLI flags only)." ;;
esac
if [[ -n "${REMOVE_MODE:-}" ]]; then
    mc_startup_warn "REMOVE_MODE in the environment is ignored; use --permanent or --quarantine, or remove_mode in settings.conf."
fi
case "${NON_INTERACTIVE:-}" in
    1|true|yes)
        _mc_ni=1
        mc_startup_warn "NON_INTERACTIVE in the environment is deprecated; use --non-interactive or MACOS_CLEANUP_NON_INTERACTIVE=1." ;;
esac
case "${MACOS_CLEANUP_NON_INTERACTIVE:-}" in 1|true|yes) _mc_ni=1 ;; esac
# Legacy variables the user's own environment provided (not the engine's
# defaults below): mc_load_settings ranks them above settings.conf.
MC_LEGACY_ENV_SET=""
for _mc_v in LANG_CODE ARTIFACT_RETENTION_DAYS HOME_TOP_DIRS_TIMEOUT REDACT_PATHS; do
    if [[ -n "${!_mc_v:-}" ]]; then MC_LEGACY_ENV_SET="${MC_LEGACY_ENV_SET} ${_mc_v}"; fi
done
unset _mc_v
# F14: the removal mode and the consent switches below are NEVER read from the
# inherited environment: a stray REMOVE_MODE=permanent or AUTO_YES=1 in a shell
# profile or CI must not change what a run deletes or approves. Only the
# --permanent / --quarantine / --yes / --non-interactive flags set them.
REMOVE_MODE="quarantine"  # quarantine | permanent

# Global accounting totals (bytes)
TOTAL_WOULD_FREE_BYTES=0
TOTAL_FREED_BYTES=0
TOTAL_INFORMATIONAL_BYTES=0

# Privacy & Security
REDACT_PATHS="${REDACT_PATHS:-0}"

# Accessibility & i18n
PLAIN_OUTPUT="${PLAIN_OUTPUT:-0}"
QUIET_OUTPUT="${QUIET_OUTPUT:-0}"
# F13: the language comes from the user's locale — $LC_ALL, then $LC_MESSAGES,
# then $LANG; with none of them set (launchd, GUI-launched shells) the first
# AppleLanguages entry. Anything unsupported, and the C/POSIX locale, is
# English. An explicit LANG_CODE (or --lang) still wins.
detect_lang_code() {
    local raw="${LC_ALL:-}" code
    [[ -n "$raw" ]] || raw="${LC_MESSAGES:-}"
    [[ -n "$raw" ]] || raw="${LANG:-}"
    if [[ -z "$raw" ]] && command -v defaults >/dev/null 2>&1; then
        raw="$(defaults read -g AppleLanguages 2>/dev/null \
            | sed -n 's/^ *"\{0,1\}\([A-Za-z][A-Za-z]\).*/\1/p' | head -n 1)" || raw=""
    fi
    code="$(printf '%s' "${raw:0:2}" | tr '[:upper:]' '[:lower:]')"
    case "$code" in
        pl|de|es|fr|it|pt|en) printf '%s' "$code" ;;
        *) printf 'en' ;;
    esac
}
LANG_CODE="${LANG_CODE:-$(detect_lang_code)}"
SHOW_EXPLAIN="${SHOW_EXPLAIN:-0}"

# Interactive control (safe defaults: no destructive prompts in automation
# context). CLI-only, see the F14 note above.
NON_INTERACTIVE="$_mc_ni"
unset _mc_ni
AUTO_YES=0

# ---------------------------------------------------------------------------
# Log level: DEBUG | INFO | WARN | ERROR
# ---------------------------------------------------------------------------
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ---------------------------------------------------------------------------
# Age thresholds (only those actually consumed by analyzer/cleaner)
# ---------------------------------------------------------------------------
LOG_MAX_AGE_DAYS=30           # Log files older than this are candidates
TMP_MAX_AGE_HOURS=24          # /tmp / var/folders files older than N hours
DMG_MAX_AGE_DAYS=30           # DMG/PKG installers in ~/Downloads
DEVICE_SUPPORT_MIN_AGE_DAYS=180  # Xcode DeviceSupport versions older than this are candidates
BACKUP_MAX_AGE_DAYS=14        # Warn before destructive work if latest TM backup is older/missing
QUARANTINE_RETENTION_DAYS=30  # Default retention for --purge-quarantine expired
RECENT_DAYS=0                 # Items modified in the last N days are skipped (0 = off)
SCAN_JOBS=4                   # Parallel scan workers
SCHEDULE_TIME="10:30"         # LaunchAgent time (lib/schedule.sh)
SCHEDULE_WEEKDAY="sun"        # daily | mon .. sun

# ---------------------------------------------------------------------------
# Paths that are NEVER touched — absolute hard blocks.
# ---------------------------------------------------------------------------
NEVER_TOUCH_PATHS=(
    # Mail data
    "$HOME/Library/Mail"
    "$HOME/Library/Containers/com.apple.mail"
    # Keychains
    "$HOME/Library/Keychains"
    "/Library/Keychains"
    "/System/Library/Keychains"
    # Password managers
    "$HOME/Library/Application Support/1Password"
    "$HOME/Library/Application Support/1Password 7"
    "$HOME/Library/Application Support/com.agilebits"
    "$HOME/Library/Application Support/Bitwarden"
    "$HOME/Library/Application Support/LastPass"
    "$HOME/Library/Application Support/Dashlane"
    "$HOME/Library/Application Support/Enpass"
    "$HOME/Library/Application Support/Keybase"
    "$HOME/Library/Application Support/macOS_cleanup"
    "$HOME/Library/Caches/com.1password.1password"
    "$HOME/Library/Caches/com.agilebits.onepassword7"
    "$HOME/Library/Caches/com.bitwarden.desktop"
    "$HOME/Library/Caches/com.lastpass.LastPass"
    "$HOME/Library/Caches/com.dashlane.Dashlane"
    "$HOME/Library/Caches/in.sinew.Enpass-Desktop"
    # User data directories
    "$HOME/Documents"
    "$HOME/Desktop"
    "$HOME/Pictures/Photos Library.photoslibrary"
    "$HOME/Pictures/Photos Library"
    "$HOME/Music/Music/Music Library.musiclibrary"
    "$HOME/Music/Music Library.musiclibrary"
    "$HOME/Movies"
    # Messages, Calendars, Contacts — local user data (P0-2)
    "$HOME/Library/Messages"
    "$HOME/Library/Calendars"
    "$HOME/Library/Application Support/AddressBook"
    # iCloud and cloud storage (P0-3)
    "$HOME/Library/Mobile Documents"
    "$HOME/Library/CloudStorage"
    "$HOME/Dropbox"
    "$HOME/OneDrive"
    "$HOME/Google Drive"
    "$HOME/Library/Application Support/Google/DriveFS"
    # Browser profiles (passwords, sessions, cookies, history)
    "$HOME/Library/Application Support/Google/Chrome"
    "$HOME/Library/Application Support/Firefox"
    "$HOME/Library/Application Support/Microsoft Edge"
    "$HOME/Library/Application Support/BraveSoftware"
    "$HOME/Library/Application Support/Opera"
    "$HOME/Library/Application Support/Vivaldi"
    "$HOME/Library/Safari"
    # Developer signing & certificates
    "$HOME/Library/MobileDevice/Provisioning Profiles"
    # Developer source trees (P0-3)
    "$HOME/Developer"
    "$HOME/Projects"
    "$HOME/src"
    "$HOME/code"
    "$HOME/repos"
    # SSH keys and credentials
    "$HOME/.ssh"
    "$HOME/.gnupg"
    "$HOME/.aws/credentials"
    "$HOME/.aws/config"
    "$HOME/.aws/sso"
    # Git config (not cache)
    "$HOME/.gitconfig"
    "$HOME/.git-credentials"
    # Additional credential and config dotfiles (P0-3)
    "$HOME/.config"
    "$HOME/.kube"
    "$HOME/.docker"
    "$HOME/.netrc"
    "$HOME/.zshrc"
    "$HOME/.zprofile"
    "$HOME/.zsh_history"
    "$HOME/.bash_profile"
    "$HOME/.bashrc"
    "$HOME/.bash_history"
    "$HOME/.profile"
    "$HOME/.npmrc"
)

# ---------------------------------------------------------------------------
# The --category sections (ALL_CATEGORIES) and every category id come from the
# registry, share/categories.tsv, loaded by lib/common.sh (R06).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run-artifact retention (logs/ and reports/), in days. 0 disables pruning.
# ---------------------------------------------------------------------------
: "${ARTIFACT_RETENTION_DAYS:=30}"
: "${HOME_TOP_DIRS_TIMEOUT:=20}"

# ---------------------------------------------------------------------------
# Colours — set NO_COLOR=1 to disable
# ---------------------------------------------------------------------------
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM=''
fi
