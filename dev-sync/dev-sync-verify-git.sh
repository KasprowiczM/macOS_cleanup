#!/usr/bin/env bash
# ============================================================
# dev-sync-verify-git.sh — Verify git state
# ============================================================
# Wrapper script that calls the Python backend
# ============================================================

set -eu
exec python3 "$(dirname "$0")/dev_sync_verify_git.py" "$@"
