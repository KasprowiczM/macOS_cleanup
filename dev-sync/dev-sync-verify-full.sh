#!/usr/bin/env bash
# ============================================================
# dev-sync-verify-full.sh — Full verification: git + cloud sync
# ============================================================
# Wrapper script that calls the Python backend
# ============================================================

set -eu
exec python3 "$(dirname "$0")/dev_sync_verify_full.py" "$@"
