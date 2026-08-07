#!/usr/bin/env bash
# =============================================================================
# tests/fixtures/make_fake_home.sh — Deterministic fake $HOME generator
#
# Usage:  bash tests/fixtures/make_fake_home.sh <target_directory>
#
# Creates a deterministic, reproducible fake $HOME for testing.
# Fixed sizes via dd, fixed mtimes via touch -t.
# Idempotent: safe to re-run on the same directory.
#
# SAFETY: Refuses to run if target is not under /tmp, /var/folders,
#         /private/tmp, /private/var/folders, or $TMPDIR.
# Bash 3.2 compatible.
# =============================================================================
set -euo pipefail

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <target_directory>" >&2
    exit 1
fi

# Safety: only allow temp directories
_is_safe_target() {
    local resolved
    # Resolve the target's parent (target may not exist yet)
    local parent
    parent="$(dirname "$TARGET")"
    if [[ -d "$parent" ]]; then
        resolved="$(cd "$parent" && pwd -P)/$(basename "$TARGET")"
    else
        resolved="$TARGET"
    fi

    case "$resolved" in
        /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
            return 0 ;;
    esac

    # Check $TMPDIR
    if [[ -n "${TMPDIR:-}" ]]; then
        local tmpdir_resolved
        tmpdir_resolved="$(cd "$TMPDIR" 2>/dev/null && pwd -P)" || true
        if [[ -n "$tmpdir_resolved" && "$resolved" == "$tmpdir_resolved"/* ]]; then
            return 0
        fi
    fi

    return 1
}

if ! _is_safe_target; then
    echo "ERROR: Target must be under /tmp, /var/folders, or \$TMPDIR." >&2
    echo "  Got: $TARGET" >&2
    exit 2
fi

H="$TARGET"
mkdir -p "$H"

# Helper: create a file of a specific size (in KB)
_mkfile_kb() {
    local path="$1" kb="$2"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/zero of="$path" bs=1024 count="$kb" 2>/dev/null
}

# Helper: create a file of a specific size (in bytes)
_mkfile_bytes() {
    local path="$1" bytes="$2"
    mkdir -p "$(dirname "$path")"
    dd if=/dev/zero of="$path" bs=1 count="$bytes" 2>/dev/null
}

# Helper: create a file with content
_mkfile() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$path")"
    printf '%s' "$*" > "$path"
}

# Helper: set mtime to a fixed date (YYYYMMDDHHMM format for touch -t)
_set_mtime() {
    touch -t "$2" "$1" 2>/dev/null || true
}

# ─── .Trash — 3 items of known sizes ──────────────────────────────
mkdir -p "$H/.Trash"
_mkfile_kb "$H/.Trash/old_document.pdf" 512
_mkfile_kb "$H/.Trash/unused_image.png" 256
_mkfile_kb "$H/.Trash/temp_archive.zip" 1024
_set_mtime "$H/.Trash/old_document.pdf"  "202601150900"
_set_mtime "$H/.Trash/unused_image.png"  "202602200800"
_set_mtime "$H/.Trash/temp_archive.zip"  "202603100700"

# ─── Library/Caches — required app caches ─────────────────────────
mkdir -p "$H/Library/Caches/com.example.app1"
_mkfile_kb "$H/Library/Caches/com.example.app1/cache.db" 128

mkdir -p "$H/Library/Caches/Homebrew/downloads"
_mkfile_kb "$H/Library/Caches/Homebrew/downloads/pkg1.tar.gz" 2048

mkdir -p "$H/Library/Caches/pip/http"
_mkfile_kb "$H/Library/Caches/pip/http/cache1" 512

mkdir -p "$H/Library/Caches/CocoaPods/Pods"
_mkfile_kb "$H/Library/Caches/CocoaPods/Pods/spec1" 256

mkdir -p "$H/Library/Caches/org.swift.swiftpm/repositories"
_mkfile_kb "$H/Library/Caches/org.swift.swiftpm/repositories/repo1" 384

mkdir -p "$H/Library/Caches/composer"
_mkfile_kb "$H/Library/Caches/composer/files1" 128

mkdir -p "$H/Library/Caches/JetBrains/IntelliJIdea2024.1"
_mkfile_kb "$H/Library/Caches/JetBrains/IntelliJIdea2024.1/caches" 1024

mkdir -p "$H/Library/Caches/com.spotify.client/Data"
_mkfile_kb "$H/Library/Caches/com.spotify.client/Data/stream1" 768

mkdir -p "$H/Library/Caches/com.apple.dt.Xcode"
_mkfile_kb "$H/Library/Caches/com.apple.dt.Xcode/cache1" 512

mkdir -p "$H/Library/Caches/Yarn/v6"
_mkfile_kb "$H/Library/Caches/Yarn/v6/pkg1" 256

# ─── Library/Application Support — Slack, Code, Spotify, orphan ───
mkdir -p "$H/Library/Application Support/Slack/Cache"
_mkfile_kb "$H/Library/Application Support/Slack/Cache/data_0" 384

mkdir -p "$H/Library/Application Support/Code/Cache"
_mkfile_kb "$H/Library/Application Support/Code/Cache/data_0" 256

mkdir -p "$H/Library/Application Support/Code/CachedExtensionVSIXs"
_mkfile_kb "$H/Library/Application Support/Code/CachedExtensionVSIXs/ext1.vsix" 512

mkdir -p "$H/Library/Application Support/Spotify/PersistentCache"
_mkfile_kb "$H/Library/Application Support/Spotify/PersistentCache/data_0" 1024

# Orphan reverse-DNS directory (leftover from uninstalled app)
mkdir -p "$H/Library/Application Support/com.orphanapp.deleted"
_mkfile_kb "$H/Library/Application Support/com.orphanapp.deleted/prefs.db" 64

# Protect macOS_cleanup's own quarantine directory
mkdir -p "$H/Library/Application Support/macOS_cleanup/quarantine"

# ─── Library/Logs — aged files ────────────────────────────────────
mkdir -p "$H/Library/Logs"
_mkfile_kb "$H/Library/Logs/old_app.log" 64
_set_mtime "$H/Library/Logs/old_app.log" "202601010800"  # >30 days old

_mkfile_kb "$H/Library/Logs/recent_app.log" 32
# recent_app.log keeps its current mtime (< 30 days old)

_mkfile_kb "$H/Library/Logs/DiagnosticReports/crash_report.crash" 16
_set_mtime "$H/Library/Logs/DiagnosticReports/crash_report.crash" "202601100900"

# ─── Library/Developer/Xcode — DerivedData, Archives, DeviceSupport ─
mkdir -p "$H/Library/Developer/Xcode/DerivedData/MyProject-abcdef"
_mkfile_kb "$H/Library/Developer/Xcode/DerivedData/MyProject-abcdef/Build/Products/main.o" 2048
_set_mtime "$H/Library/Developer/Xcode/DerivedData/MyProject-abcdef" "202603010800"

mkdir -p "$H/Library/Developer/Xcode/Archives/2026-01-15"
_mkfile_kb "$H/Library/Developer/Xcode/Archives/2026-01-15/MyApp.xcarchive/Info.plist" 4
_set_mtime "$H/Library/Developer/Xcode/Archives/2026-01-15" "202601150800"

mkdir -p "$H/Library/Developer/Xcode/iOS DeviceSupport/16.0 (20A362)"
_mkfile_kb "$H/Library/Developer/Xcode/iOS DeviceSupport/16.0 (20A362)/Symbols/System/Library/dummy" 4096
# Set old mtime (>180 days)
_set_mtime "$H/Library/Developer/Xcode/iOS DeviceSupport/16.0 (20A362)" "202510010800"

# ─── Documents, Desktop, Downloads ────────────────────────────────
mkdir -p "$H/Documents"
_mkfile "$H/Documents/important.txt" "This is important user data"

mkdir -p "$H/Desktop"
_mkfile "$H/Desktop/notes.txt" "Desktop notes"

mkdir -p "$H/Downloads"
# Old large DMG (>10MB, >30 days old)
_mkfile_kb "$H/Downloads/OldApp-v1.0.dmg" 11264   # ~11 MB
_set_mtime "$H/Downloads/OldApp-v1.0.dmg" "202601010800"

# Recent DMG (should not be cleaned)
_mkfile_kb "$H/Downloads/NewApp-v2.0.dmg" 11264
# Keeps current mtime

# Small file (should not be cleaned - under 10MB)
_mkfile_kb "$H/Downloads/readme.pdf" 512

# ─── Cloud storage directories ────────────────────────────────────
mkdir -p "$H/Library/Mobile Documents/com~apple~CloudDocs"
_mkfile "$H/Library/Mobile Documents/com~apple~CloudDocs/cloud_file.txt" "iCloud synced file"

mkdir -p "$H/Library/CloudStorage/Dropbox"
_mkfile "$H/Library/CloudStorage/Dropbox/synced_file.txt" "Dropbox synced file"

# ─── Developer directories ────────────────────────────────────────
mkdir -p "$H/Dropbox"
_mkfile "$H/Dropbox/file.txt" "Dropbox root file"

mkdir -p "$H/Developer"
_mkfile "$H/Developer/project.txt" "Developer project"

mkdir -p "$H/Projects/myapp"
_mkfile "$H/Projects/myapp/main.swift" "import Foundation"

mkdir -p "$H/src/repo"
_mkfile "$H/src/repo/main.go" "package main"

# ─── Credential and config files ──────────────────────────────────
mkdir -p "$H/.ssh"
_mkfile "$H/.ssh/id_rsa" "FAKE_PRIVATE_KEY_DO_NOT_USE"
chmod 600 "$H/.ssh/id_rsa"

mkdir -p "$H/.gnupg"
_mkfile "$H/.gnupg/pubring.kbx" "FAKE_KEYRING"
chmod 700 "$H/.gnupg"

mkdir -p "$H/.config/gh"
_mkfile "$H/.config/gh/hosts.yml" "github.com:\n  oauth_token: fake_token"

mkdir -p "$H/.kube"
_mkfile "$H/.kube/config" "apiVersion: v1\nclusters: []"

mkdir -p "$H/.docker"
_mkfile "$H/.docker/config.json" '{"auths":{}}'

_mkfile "$H/.netrc" "machine github.com login user password fake"
chmod 600 "$H/.netrc"

_mkfile "$H/.zshrc" "# Fake zshrc"
_mkfile "$H/.npmrc" "registry=https://registry.npmjs.org/"

# ─── Dev tool caches (for dev-cache testing) ──────────────────────
mkdir -p "$H/.npm/_cacache"
_mkfile_kb "$H/.npm/_cacache/content1" 256

mkdir -p "$H/.yarn/cache"
_mkfile_kb "$H/.yarn/cache/pkg1.zip" 128

mkdir -p "$H/.pnpm-store/v3"
_mkfile_kb "$H/.pnpm-store/v3/files1" 192

mkdir -p "$H/.gradle/caches/modules-2"
_mkfile_kb "$H/.gradle/caches/modules-2/files1" 512

mkdir -p "$H/.cargo/registry/cache"
_mkfile_kb "$H/.cargo/registry/cache/crate1" 256

mkdir -p "$H/.gem/cache"
_mkfile_kb "$H/.gem/cache/gem1.gem" 128

mkdir -p "$H/.bundle/cache"
_mkfile_kb "$H/.bundle/cache/bundle1" 64

mkdir -p "$H/.composer/cache"
_mkfile_kb "$H/.composer/cache/composer1" 96

mkdir -p "$H/.swiftpm/cache"
_mkfile_kb "$H/.swiftpm/cache/swift1" 128

# ─── Adversarial cases ────────────────────────────────────────────
# Symlink from Caches to Documents (must be protected)
ln -sf "$H/Documents" "$H/Library/Caches/SymToDocs" 2>/dev/null || true

# Symlink cycle A <-> B
ln -sf "$H/Library/Caches/SymCycleB" "$H/Library/Caches/SymCycleA" 2>/dev/null || true
ln -sf "$H/Library/Caches/SymCycleA" "$H/Library/Caches/SymCycleB" 2>/dev/null || true

# File with weird name (quotes and special chars - no actual newline in filename
# as that's filesystem-dependent and hard to handle in older bash)
_mkfile "$H/Library/Caches/weird name'with\"quotes" "weird content"

# Zero-byte file
touch "$H/Library/Caches/empty_file"

# chmod 000 directory (caller must restore in their trap)
mkdir -p "$H/Library/Caches/locked_dir"
_mkfile_kb "$H/Library/Caches/locked_dir/data" 32
chmod 000 "$H/Library/Caches/locked_dir"

# ─── /tmp-like area (for tmp file testing) ────────────────────────
mkdir -p "$H/tmp_area"
_mkfile_kb "$H/tmp_area/old_tmp_file" 16
_set_mtime "$H/tmp_area/old_tmp_file" "202601010800"

# ─── iOS backups area ─────────────────────────────────────────────
mkdir -p "$H/Library/Application Support/MobileSync/Backup/abc123"
_mkfile_kb "$H/Library/Application Support/MobileSync/Backup/abc123/Manifest.db" 64
_mkfile "$H/Library/Application Support/MobileSync/Backup/abc123/Info.plist" \
    '<?xml version="1.0"?>
<plist version="1.0">
<dict>
  <key>Device Name</key>
  <string>Test iPhone</string>
</dict>
</plist>'

echo "Fixture home created at: $H"
echo "To restore chmod 000 dirs, run: chmod 755 $H/Library/Caches/locked_dir"
