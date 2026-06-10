#!/usr/bin/env bash
# ============================================================
# Backward-compatibility wrapper — calls dev-sync/dev-sync-export.sh
# ============================================================
set -eu
exec bash "$(cd "$(dirname "$0")" && pwd)/dev-sync/dev-sync-export.sh" "$@"
