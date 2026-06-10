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
BRANCH="main"
DEST="${MACOS_CLEANUP_DIR:-$HOME/Dev_Env/macOS_cleanup}"

say() { printf '%s\n' "$*"; }

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

# --- Clone or update --------------------------------------------------------
if [[ -d "$DEST/.git" ]]; then
    say "↻  Updating existing checkout at: $DEST"
    git -C "$DEST" pull --ff-only origin "$BRANCH"
else
    say "⇣  Cloning macOS Cleanup into: $DEST"
    mkdir -p "$(dirname "$DEST")"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$DEST"
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
