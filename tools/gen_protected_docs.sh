#!/usr/bin/env bash
# =============================================================================
# tools/gen_protected_docs.sh — Protected Paths Documentation Generator
# =============================================================================

set -eu

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source defaults to read NEVER_TOUCH_PATHS
# shellcheck disable=SC1091
source "${PROJ_DIR}/config/defaults.sh"

DOC_FILE="${PROJ_DIR}/docs/PROTECTED_PATHS.md"
mkdir -p "${PROJ_DIR}/docs"

generate_docs() {
    cat << 'EOF'
# Protected Paths & Exclusions Policy

> ⚠️ **IMPORTANT**: Quarantine is not a backup and reclaims no space until purged. Files placed in quarantine remain safely isolated on disk until explicitly restored (`--restore`) or purged (`--purge-quarantine`).

## Non-Negotiable Protected Paths (`NEVER_TOUCH_PATHS`)

The `macOS_cleanup` script **never touches** the following locations under any circumstances:

EOF

    for path in "${NEVER_TOUCH_PATHS[@]}"; do
        echo "- \`${path}\`"
    done

    cat << 'EOF'

## Disposable Cache & Log Roots (`userDisposableRoots`)

Cleanup is strictly bounded to allowed disposable roots:
- `~/Library/Caches/*`
- `~/Library/Logs/*`
- `~/Library/Developer/Xcode/DerivedData/*`
- `~/Library/Developer/Xcode/Archives/*`
- `~/Library/Developer/Xcode/iOS DeviceSupport/*`
- `~/Library/Developer/CoreSimulator/Devices/*`
- `~/.cache/*`
- `~/.npm/_cacache/*`
- `~/.yarn/berry/cache/*`
- `~/.Trash/*`
- `~/Downloads/*.dmg` / `*.pkg` (older than 30 days)
EOF
}

if [[ "${1:-}" == "--check" ]]; then
    TMP_DOC=$(mktemp)
    trap 'rm -f "$TMP_DOC"' EXIT
    generate_docs > "$TMP_DOC"
    if [[ -f "$DOC_FILE" ]] && cmp -s "$TMP_DOC" "$DOC_FILE"; then
        echo "✅ Protected path documentation is up to date."
        exit 0
    else
        echo "❌ Protected path documentation out of date! Run: bash tools/gen_protected_docs.sh"
        exit 1
    fi
else
    generate_docs > "$DOC_FILE"
    echo "Updated ${DOC_FILE}"
fi
