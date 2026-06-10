#!/usr/bin/env bash
# ============================================================
# Backward-compatibility wrapper — calls dev-sync/dev-sync-import.sh
# ============================================================
set -eu
exec bash "$(cd "$(dirname "$0")" && pwd)/dev-sync/dev-sync-import.sh" "$@"
