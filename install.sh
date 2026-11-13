#!/usr/bin/env bash
# =============================================================================
# install.sh — one-line installer for macOS Cleanup.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
#
# SAFETY: this installer ONLY clones (or updates) the repository and prints the
# next steps. It NEVER deletes anything and NEVER runs a cleanup. The cleanup
# itself is always opt-in, starts with a read-only dry-run, and asks for consent.
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/KasprowiczM/macOS_cleanup.git"
RELEASE_TAG="v3.0.7"
TARGET_REF="$RELEASE_TAG"
DEST="${MACOS_CLEANUP_DIR:-$HOME/Dev_Env/macOS_cleanup}"

for arg in "$@"; do
    if [[ "$arg" == "--edge" ]]; then
        TARGET_REF="main"
    fi
done

say() { printf '%s\n' "$*"; }

origin_is_official() {
    local url="${1%/}"
    url="${url%.git}"
    case "$url" in
        https://github.com/KasprowiczM/macOS_cleanup|git@github.com:KasprowiczM/macOS_cleanup)
            return 0
            ;;
    esac
    return 1
}

# --- Pre-flight -------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    say "✖  macOS Cleanup is for macOS only (detected: $(uname -s))."
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    say "✖  git is required. Install the Xcode Command Line Tools first:"
    say "       xcode-select --install"
    exit 1
fi
if ! command -v shasum >/dev/null 2>&1; then
    say "✖  shasum is required to verify the checkout and was not found."
    exit 1
fi

# --- Clone or update --------------------------------------------------------
if [[ -d "$DEST/.git" ]]; then
    say "↻  Updating existing checkout at: $DEST (ref: $TARGET_REF)"
    origin_url="$(git -C "$DEST" remote get-url origin 2>/dev/null || true)"
    if ! origin_is_official "$origin_url"; then
        say "✖  Refusing to update $DEST: origin is not KasprowiczM/macOS_cleanup (https or git@)."
        [[ -n "$origin_url" ]] && say "    origin: $origin_url"
        exit 1
    fi
    if [[ -n "$(git -C "$DEST" status --porcelain)" ]]; then
        say "✖  Refusing to update $DEST: working tree is not clean."
        say "    Commit, stash, or move local changes before running the installer."
        exit 1
    fi
    git -C "$DEST" fetch origin "$TARGET_REF"
    if [[ "$TARGET_REF" != "main" ]] && git -C "$DEST" show-ref --verify --quiet "refs/tags/$TARGET_REF"; then
        local_release="$(git -C "$DEST" rev-parse "refs/tags/$TARGET_REF^{commit}")"
        fetched_release="$(git -C "$DEST" rev-parse 'FETCH_HEAD^{commit}')"
        if [[ "$local_release" != "$fetched_release" ]]; then
            say "✖  Refusing to update: the local release tag differs from the official release."
            say "    The repository history may have changed. Your local tag and files were not replaced."
            say "    Set MACOS_CLEANUP_DIR to a fresh directory and rerun this installer."
            exit 1
        fi
    fi
    if ! git -C "$DEST" checkout "$TARGET_REF"; then
        say "✖  Failed to checkout $TARGET_REF at $DEST."
        say "    Local files were not rewritten."
        exit 1
    fi
else
    say "⇣  Cloning macOS Cleanup into: $DEST (ref: $TARGET_REF)"
    mkdir -p "$(dirname "$DEST")"
    git clone --depth 1 --branch "$TARGET_REF" "$REPO_URL" "$DEST"
fi

if [[ ! -f "$DEST/SHA256SUMS" ]]; then
    say "✖  SHA256SUMS is missing in $DEST, so the checkout cannot be verified. Aborting."
    exit 1
fi
say "✓  Verifying checksums in $DEST/SHA256SUMS"
if ! sums_out="$(cd "$DEST" && shasum -a 256 -c --quiet --strict SHA256SUMS 2>&1)"; then
    say "✖  SHA256SUMS checksum mismatch. Aborting."
    printf '%s\n' "$sums_out" | sed 's/^/    /'
    exit 1
fi

chmod +x "$DEST/cleanup_all.sh" 2>/dev/null || true

# --- Next steps -------------------------------------------------------------
cat <<EOF

✅  Installed to: $DEST

This installer did NOT delete anything and did NOT run any cleanup.

1) Safe, read-only analysis first (nothing is deleted):

       cd "$DEST"
       bash cleanup_all.sh --dry-run

2) When ready — interactive cleaning (quarantine by default, full consent,
   default answer is always "no"):

       bash cleanup_all.sh --interactive

Restore anything later:   bash cleanup_all.sh --restore latest
Docs:                     $DEST/README.md  ·  $DEST/user_guide.md
EOF
