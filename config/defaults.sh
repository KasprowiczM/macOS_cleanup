#!/usr/bin/env bash
# =============================================================================
# config/defaults.sh — Default configuration for cleanup_all.sh
# Bash 3.2 compatible.
# =============================================================================
# shellcheck disable=SC2034,SC2155

# ---------------------------------------------------------------------------
# Script identity & versioning
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="3.0.6"
readonly SCRIPT_NAME="cleanup_all.sh"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Runtime directories
# ---------------------------------------------------------------------------
readonly LOGS_DIR="${LOGS_DIR:-${PROJECT_DIR}/logs}"
readonly REPORTS_DIR="${REPORTS_DIR:-${PROJECT_DIR}/reports}"
RULES_FILE="${RULES_FILE:-${PROJECT_DIR}/cleanup_rules.yaml}"

# ---------------------------------------------------------------------------
# Timestamp used for log/report filenames
# ---------------------------------------------------------------------------
readonly RUN_TIMESTAMP="$(date '+%Y-%m-%d_%H%M%S')_$$"
readonly LOG_FILE="${LOGS_DIR}/cleanup_${RUN_TIMESTAMP}.log"
readonly REPORT_FILE="${REPORTS_DIR}/report_${RUN_TIMESTAMP}.md"
readonly PLAN_FILE_DEFAULT="${REPORTS_DIR}/plan_${RUN_TIMESTAMP}.json"
readonly CLEANUP_JOURNAL_FILE="${CLEANUP_JOURNAL_FILE:-${REPORTS_DIR}/journal_${RUN_TIMESTAMP}.jsonl}"
readonly CLEANUP_RESTORE_MANIFEST="${CLEANUP_RESTORE_MANIFEST:-${REPORTS_DIR}/restore_${RUN_TIMESTAMP}.tsv}"
readonly QUARANTINE_ROOT="${QUARANTINE_ROOT:-${HOME}/Library/Application Support/macOS_cleanup/quarantine}"
readonly QUARANTINE_RUN_DIR="${QUARANTINE_RUN_DIR:-${QUARANTINE_ROOT}/${RUN_TIMESTAMP}}"

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
REMOVE_MODE="${REMOVE_MODE:-quarantine}"  # quarantine | permanent

# Global accounting totals (bytes)
TOTAL_WOULD_FREE_BYTES=0
TOTAL_FREED_BYTES=0
TOTAL_INFORMATIONAL_BYTES=0

# Privacy & Security
REDACT_PATHS="${REDACT_PATHS:-0}"

# Accessibility & i18n
PLAIN_OUTPUT="${PLAIN_OUTPUT:-0}"
QUIET_OUTPUT="${QUIET_OUTPUT:-0}"
LANG_CODE="${LANG_CODE:-pl}"
SHOW_EXPLAIN="${SHOW_EXPLAIN:-0}"

# Interactive control (safe defaults: no destructive prompts in automation context)
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
AUTO_YES="${AUTO_YES:-0}"

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
    "$HOME/Library/Keychains"
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
    "$HOME/.config/gh"
)

# ---------------------------------------------------------------------------
# Categories available for --category flag
# ORDER MATTERS: trash first (safest, quickest win)
# ---------------------------------------------------------------------------
ALL_CATEGORIES=(
    "trash"
    "user-caches"
    "logs"
    "system"
    "dev"
    "app-leftovers"
    "time-machine"
    "large-files"
)

# ---------------------------------------------------------------------------
# Run-artifact retention (logs/ and reports/), in days. 0 disables pruning.
# ---------------------------------------------------------------------------
: "${ARTIFACT_RETENTION_DAYS:=30}"

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
