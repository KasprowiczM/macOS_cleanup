#!/usr/bin/env bash
# ============================================================
# dev-sync-purge-quarantine.sh — Delete reviewed quarantine
# ============================================================

set -eu
exec python3 "$(dirname "$0")/dev_sync_purge_quarantine.py" "$@"
