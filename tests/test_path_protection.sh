#!/usr/bin/env bash
# =============================================================================
# tests/test_path_protection.sh — Table-driven protected-path assertions
#
# P0-3 / Task 1.6: Regression-locks the denylist. Append-only from creation.
# Every path listed below MUST be protected (or explicitly unprotected).
# Bash 3.2 compatible.
# =============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${TEST_DIR}/.." && pwd)"

SANDBOX="$(mktemp -d -t macos_cleanup_test_pathprot.XXXXXX)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
export LOG_LEVEL="INFO"
export LOGS_DIR="${SANDBOX}/logs"
export REPORTS_DIR="${SANDBOX}/reports"
export CLEANUP_JOURNAL_FILE="${SANDBOX}/reports/journal_test.jsonl"
export CLEANUP_RESTORE_MANIFEST="${SANDBOX}/reports/restore_test.tsv"
export QUARANTINE_ROOT="${SANDBOX}/quarantine"
mkdir -p "$LOGS_DIR" "$REPORTS_DIR" "$QUARANTINE_ROOT"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"
# shellcheck disable=SC1091
source "${PROJ_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${TEST_DIR}/helpers.sh"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: assert_protected / assert_unprotected
# ---------------------------------------------------------------------------
assert_protected() {
    local path="$1" label="${2:-$1}"
    if is_protected_path "$path"; then
        _pass
    else
        _fail "MUST be protected: ${label} (${path})"
    fi
}

assert_unprotected() {
    local path="$1" label="${2:-$1}"
    if is_protected_path "$path"; then
        _fail "should NOT be protected: ${label} (${path})"
    else
        _pass
    fi
}

# ---------------------------------------------------------------------------
# Table: paths that MUST be protected
# ---------------------------------------------------------------------------
begin_test "Protected: Mail data"
assert_protected "$HOME/Library/Mail"
assert_protected "$HOME/Library/Containers/com.apple.mail"

begin_test "Protected: Keychains"
assert_protected "$HOME/Library/Keychains"
assert_protected "/Library/Keychains"
assert_protected "/System/Library/Keychains"

begin_test "Protected: Password managers"
assert_protected "$HOME/Library/Application Support/1Password"
assert_protected "$HOME/Library/Application Support/Bitwarden"
assert_protected "$HOME/Library/Application Support/LastPass"
assert_protected "$HOME/Library/Application Support/Dashlane"
assert_protected "$HOME/Library/Application Support/Enpass"
assert_protected "$HOME/Library/Application Support/Keybase"
assert_protected "$HOME/Library/Caches/com.1password.1password"
assert_protected "$HOME/Library/Caches/com.bitwarden.desktop"

begin_test "Protected: User data directories"
assert_protected "$HOME/Documents"
assert_protected "$HOME/Desktop"
assert_protected "$HOME/Movies"
assert_protected "$HOME/Pictures/Photos Library.photoslibrary"

begin_test "Protected: iCloud and cloud storage (P0-3)"
assert_protected "$HOME/Library/Mobile Documents"
assert_protected "$HOME/Library/CloudStorage"
assert_protected "$HOME/Dropbox"
assert_protected "$HOME/OneDrive"
assert_protected "$HOME/Google Drive"

begin_test "Protected: Browser profiles"
assert_protected "$HOME/Library/Application Support/Google/Chrome"
assert_protected "$HOME/Library/Application Support/Firefox"
assert_protected "$HOME/Library/Application Support/Microsoft Edge"
assert_protected "$HOME/Library/Application Support/BraveSoftware"
assert_protected "$HOME/Library/Safari"

begin_test "Protected: Developer signing"
assert_protected "$HOME/Library/MobileDevice/Provisioning Profiles"

begin_test "Protected: Developer source trees (P0-3)"
assert_protected "$HOME/Developer"
assert_protected "$HOME/Projects"
assert_protected "$HOME/src"
assert_protected "$HOME/code"
assert_protected "$HOME/repos"

begin_test "Protected: SSH/GPG/credentials"
assert_protected "$HOME/.ssh"
assert_protected "$HOME/.gnupg"
assert_protected "$HOME/.aws/credentials"
assert_protected "$HOME/.aws/config"
assert_protected "$HOME/.gitconfig"
assert_protected "$HOME/.git-credentials"

begin_test "Protected: Config/credential dotfiles (P0-3)"
assert_protected "$HOME/.config"
assert_protected "$HOME/.kube"
assert_protected "$HOME/.docker"
assert_protected "$HOME/.netrc"
assert_protected "$HOME/.zshrc"
assert_protected "$HOME/.zprofile"
assert_protected "$HOME/.bashrc"
assert_protected "$HOME/.bash_profile"
assert_protected "$HOME/.npmrc"
assert_protected "$HOME/.config/gh"

begin_test "Protected: macOS_cleanup own data"
assert_protected "$HOME/Library/Application Support/macOS_cleanup"

begin_test "Protected: Broad roots always rejected"
assert_protected "/"
assert_protected "/usr"
assert_protected "/private/var"
assert_protected "/Applications"
assert_protected "$HOME"
assert_protected "$HOME/Library"
assert_protected "$HOME/Library/Caches"
assert_protected "$HOME/Library/Preferences"
assert_protected "$HOME/Library/Containers"

begin_test "Protected: System paths"
assert_protected "/System"
assert_protected "/System/Library"
assert_protected "/Library"

# ---------------------------------------------------------------------------
# Table: paths that SHOULD be cleanable (not protected)
# ---------------------------------------------------------------------------
begin_test "Unprotected: Specific app caches (leaf items)"
assert_unprotected "$HOME/Library/Caches/com.spotify.client"
assert_unprotected "$HOME/Library/Caches/com.apple.dt.Xcode"
assert_unprotected "$HOME/Library/Caches/JetBrains"

begin_test "Unprotected: Xcode DerivedData"
assert_unprotected "$HOME/Library/Developer/Xcode/DerivedData"
assert_unprotected "$HOME/Library/Developer/Xcode/DerivedData/MyProject-abc123"

# .Trash is under $HOME which is a broad root, but safe_remove has
# a special carve-out for .Trash items. is_protected_path correctly
# flags it as protected (it IS under $HOME); the cleaner handles it.
begin_test "Trash: under HOME broad root (protected by is_protected_path)"
assert_protected "$HOME/.Trash"

begin_test "Unprotected: Dev tool caches"
assert_unprotected "$HOME/.npm"
assert_unprotected "$HOME/.yarn"
assert_unprotected "$HOME/.gradle"
assert_unprotected "$HOME/.cargo"
assert_unprotected "$HOME/.gem"

begin_test "Unprotected: Library/Logs (individual old logs)"
assert_unprotected "$HOME/Library/Logs/old_app.log"

begin_test "Unprotected: Downloads individual files"
assert_unprotected "$HOME/Downloads/OldApp.dmg"

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
begin_test "Edge: trailing slash, dot-dot"
assert_protected "$HOME/Documents/"
assert_protected "$HOME/Documents/."
assert_protected "$HOME/Library/../Documents"

begin_test "R-1: Normalizer double-slash fix and protection-bypass prevention"
norm1="$(normalize_path "/tmp/../etc")"
if [[ "$norm1" == "/etc" || "$norm1" == "/private/etc" ]]; then _pass; else _fail "expected /etc or /private/etc, got $norm1"; fi

norm2="$(normalize_path "/var/tmp/../System")"
if [[ "$norm2" == "/System" || "$norm2" == "/private/var/System" || "$norm2" == "/var/System" ]]; then _pass; else _fail "expected /System or /private/var/System, got $norm2"; fi

assert_protected "/tmp/../etc" "traversal to /etc"
assert_protected "/var/tmp/../System" "traversal to /System"
assert_protected "/tmp/../System/Library/Keychains" "traversal to keychains"

print_test_summary
