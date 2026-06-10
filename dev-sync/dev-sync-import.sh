#!/usr/bin/env bash
# ============================================================
# dev-sync-import.sh — Import private files from cloud storage
# ============================================================
# Wrapper script that calls the Python backend
# ============================================================

set -eu
exec python3 "$(dirname "$0")/dev_sync_import.py" "$@"
