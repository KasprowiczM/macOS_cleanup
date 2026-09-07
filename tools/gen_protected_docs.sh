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

# Rewrite an expanded $HOME prefix to ~ so generated docs stay portable
# when --check runs with an isolated HOME. Keep /Library and /System as-is.
portable_never_touch_path() {
    local path="$1"
    local home="${HOME%/}"
    if [[ -z "$home" || "$home" == "/" ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    case "$path" in
        "$home")
            printf '%s\n' '~'
            ;;
        "$home"/*)
            printf '%s\n' "~${path#"$home"}"
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

generate_docs() {
    cat << 'EOF'
# Protected Paths & Exclusions Policy

> ⚠️ **IMPORTANT**: Quarantine is not a backup and reclaims no space until purged. Files placed in quarantine remain safely isolated on disk until explicitly restored (`--restore`) or purged (`--purge-quarantine`).

## Non-Negotiable Protected Paths (`NEVER_TOUCH_PATHS`)

The `macOS_cleanup` script **never touches** the following locations under any circumstances:

EOF

    for path in "${NEVER_TOUCH_PATHS[@]}"; do
        printf -- '- `%s`\n' "$(portable_never_touch_path "$path")"
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

generate_readme_list() {
    for path in "${NEVER_TOUCH_PATHS[@]}"; do
        printf -- '- `%s`\n' "$(portable_never_touch_path "$path")"
    done
}

inject_into_readme() {
    local readme_file="$1"
    [[ -f "$readme_file" ]] || return 0

    local list_content
    list_content="$(generate_readme_list)"

    python3 -c "
import sys, re
readme_path = sys.argv[1]
list_str = sys.argv[2]
with open(readme_path, 'r', encoding='utf-8') as f:
    content = f.read()

pattern = r'(<!-- BEGIN NEVER_TOUCH_PATHS -->\n)(.*?)(<!-- END NEVER_TOUCH_PATHS -->)'
replacement = r'\g<1>' + list_str + '\n' + r'\g<3>'
if re.search(pattern, content, flags=re.DOTALL):
    new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)
    with open(readme_path, 'w', encoding='utf-8') as f:
        f.write(new_content)
" "$readme_file" "$list_content"
}

check_readme_sync() {
    local readme_file="$1"
    [[ -f "$readme_file" ]] || return 0
    local list_content
    list_content="$(generate_readme_list)"
    python3 -c "
import sys, re
readme_path = sys.argv[1]
expected_list = sys.argv[2].strip()
with open(readme_path, 'r', encoding='utf-8') as f:
    content = f.read()

m = re.search(r'<!-- BEGIN NEVER_TOUCH_PATHS -->\n(.*?)<!-- END NEVER_TOUCH_PATHS -->', content, flags=re.DOTALL)
if not m or m.group(1).strip() != expected_list:
    sys.exit(1)
" "$readme_file" "$list_content"
}

readmes=("${PROJ_DIR}/README.md" "${PROJ_DIR}/README.pl.md" "${PROJ_DIR}/README.de.md" "${PROJ_DIR}/README.es.md" "${PROJ_DIR}/README.fr.md" "${PROJ_DIR}/README.it.md" "${PROJ_DIR}/README.pt.md")

if [[ "${1:-}" == "--check" ]]; then
    TMP_DOC=$(mktemp)
    trap 'rm -f "$TMP_DOC"' EXIT
    generate_docs > "$TMP_DOC"
    if ! cmp -s "$TMP_DOC" "$DOC_FILE"; then
        echo "❌ Protected path documentation out of date! Run: bash tools/gen_protected_docs.sh"
        exit 1
    fi
    for r in "${readmes[@]}"; do
        if ! check_readme_sync "$r"; then
            echo "❌ README protected paths out of date in $(basename "$r")! Run: bash tools/gen_protected_docs.sh"
            exit 1
        fi
    done
    echo "✅ Protected path documentation and all READMEs are up to date."
    exit 0
else
    generate_docs > "$DOC_FILE"
    for r in "${readmes[@]}"; do
        inject_into_readme "$r"
    done
    echo "Updated ${DOC_FILE} and injected into all README files."
fi
