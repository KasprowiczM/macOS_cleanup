#!/usr/bin/env bash
# ============================================================
# dev-sync-prune-excluded.sh — Plan/quarantine cloud overlay junk
# ============================================================

set -eu
exec python3 "$(dirname "$0")/dev_sync_prune_excluded.py" "$@"
