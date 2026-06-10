#!/usr/bin/env bash
# ============================================================
# dev-sync-export.sh — Export private files to cloud storage
# ============================================================
# Wrapper script that calls the Python backend
# ============================================================

set -eu
exec python3 "$(dirname "$0")/dev_sync_export.py" "$@"
