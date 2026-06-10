#!/usr/bin/env bash
# ============================================================
# Backward-compatibility wrapper — calls dev-sync/dev-sync-purge-quarantine.sh
# ============================================================
set -eu
exec bash "$(cd "$(dirname "$0")" && pwd)/dev-sync/dev-sync-purge-quarantine.sh" "$@"
