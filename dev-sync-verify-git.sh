#!/usr/bin/env bash
# ============================================================
# Backward-compatibility wrapper — calls dev-sync/dev-sync-verify-git.sh
# ============================================================
set -eu
exec bash "$(cd "$(dirname "$0")" && pwd)/dev-sync/dev-sync-verify-git.sh" "$@"
