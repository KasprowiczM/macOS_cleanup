#!/usr/bin/env bash
# ============================================================
# dev-sync-proton-status.sh — Check Proton upload/offload status
# ============================================================

set -eu
exec python3 "$(dirname "$0")/dev_sync_proton_status.py" "$@"
