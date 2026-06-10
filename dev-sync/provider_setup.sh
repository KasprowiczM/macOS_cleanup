#!/bin/bash
#
# provider_setup.sh — Interactive cloud provider setup wizard
# bash 3.2+ compatible (no arrays, no mapfile)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.dev_sync_config.json"
PROJECT_NAME="$(basename "$SCRIPT_DIR")"

# ANSI colors for terminal output
COLOR_BOLD="\033[1m"
COLOR_GREEN="\033[32m"
COLOR_RED="\033[31m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_RESET="\033[0m"

print_header() {
    echo ""
    printf "${COLOR_BOLD}${COLOR_BLUE}%s${COLOR_RESET}\n" "$1"
    echo "─────────────────────────────────────────────────────"
}

print_success() {
    printf "${COLOR_GREEN}✓${COLOR_RESET} %s\n" "$1"
}

print_error() {
    printf "${COLOR_RED}✗${COLOR_RESET} %s\n" "$1"
}

print_warning() {
    printf "${COLOR_YELLOW}!${COLOR_RESET} %s\n" "$1"
}

# Detect installed cloud apps and their paths
detect_icloud() {
    local path="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
    if [ -d "$path" ]; then
        echo "$path"
    fi
}

detect_google_drive() {
    local cloud_storage="$HOME/Library/CloudStorage"
    if [ -d "$cloud_storage" ]; then
        local gdrive_path
        gdrive_path=$(find "$cloud_storage" -maxdepth 1 -type d -name "*GoogleDrive*" 2>/dev/null | head -1)
        if [ -n "$gdrive_path" ] && [ -d "$gdrive_path/My Drive" ]; then
            echo "$gdrive_path/My Drive"
        elif [ -n "$gdrive_path" ]; then
            echo "$gdrive_path"
        fi
    fi
}

detect_onedrive() {
    local cloud_storage="$HOME/Library/CloudStorage"
    if [ -d "$cloud_storage" ]; then
        find "$cloud_storage" -maxdepth 1 -type d -name "*OneDrive*" 2>/dev/null | head -1
    fi
}

detect_proton_drive() {
    local cloud_storage="$HOME/Library/CloudStorage"
    if [ -d "$cloud_storage" ]; then
        find "$cloud_storage" -maxdepth 1 -type d -name "*ProtonDrive*" 2>/dev/null | head -1
    fi
}

detect_mega() {
    local mega_path="$HOME/MEGAsync"
    if [ -d "$mega_path" ]; then
        echo "$mega_path"
    fi
}

# Check if rclone is installed and list remotes
detect_rclone() {
    if command -v rclone &> /dev/null; then
        return 0
    fi
    return 1
}

list_rclone_remotes() {
    if command -v rclone &> /dev/null; then
        rclone listremotes 2>/dev/null || echo ""
    fi
}

create_config_json() {
    local provider="$1"
    local provider_path="$2"
    local rclone_remote="$3"
    local rclone_remote_path="$4"
    local project_folder="$5"

    cat > "$CONFIG_FILE" <<EOF
{
  "project_name": "$project_folder",
  "provider": "$provider",
  "provider_path": "$provider_path",
  "rclone_remote": "$rclone_remote",
  "rclone_remote_path": "$rclone_remote_path",
  "proton_project_root": "",
  "exclude_patterns": [
    ".git/",
    ".agent/skills/",
    ".agent/superpowers/",
    ".claude/skills/",
    ".claude/settings.local.json",
    ".gemini/skills/",
    ".gemini/settings.local.json",
    "node_modules/",
    ".node_modules*/",
    "dist/",
    "dist*/",
    "build/",
    "build*/",
    ".next/",
    ".open-next/",
    ".turbo/",
    ".cache/",
    ".vite/",
    ".wrangler/",
    ".parcel-cache/",
    ".rollup.cache/",
    ".temp/",
    ".output/",
    "__pycache__/",
    ".venv/",
    "venv/",
    ".npm-cache/",
    ".bun-cache/",
    ".pytest_cache/",
    "coverage/",
    "playwright-report/",
    ".playwright-mcp/",
    "test-results/",
    ".nyc_output/",
    "out/",
    "output/",
    "logs/",
    "reports/",
    "graphify-out/",
    "*.log",
    "*.tmp",
    "*.bak",
    "*.backup",
    "*.orig",
    "*.rej",
    "*.tsbuildinfo",
    ".env*.example",
    ".env*.sample",
    ".env*.template",
    "supabase/migrations/.env",
    "secrets/",
    ".ssh/",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.crt",
    "*.cer",
    ".fuse_hidden*",
    ".DS_Store",
    ".dev_sync_manifest.json",
    "dev_sync_cleanup_plan*.json",
    "dev_sync_logs/",
    "dev_sync_quarantine/"
  ],
  "include_always": [
    ".dev_sync_config.json",
    ".env",
    ".env.local",
    ".env.*.local",
    ".env.*.local.*",
    ".dev.vars",
    ".dev.vars.*",
    ".vscode/",
    ".idea/"
  ]
}
EOF
}

main() {
    print_header "Cloud Storage Provider Setup"
    echo "Configure where to store your private project files."
    echo ""

    icloud_path=$(detect_icloud)
    gdrive_path=$(detect_google_drive)
    onedrive_path=$(detect_onedrive)
    proton_path=$(detect_proton_drive)
    mega_path=$(detect_mega)
    has_rclone=$(detect_rclone && echo "yes" || echo "no")

    echo "Auto-detected providers:"
    echo ""

    provider_count=1

    if [ -n "$icloud_path" ]; then
        echo "  ${COLOR_GREEN}${provider_count})${COLOR_RESET} iCloud Drive       ${COLOR_GREEN}✓${COLOR_RESET} found at:"
        echo "     $icloud_path"
        provider_count=$((provider_count + 1))
    else
        echo "  ${COLOR_RED}1)${COLOR_RESET} iCloud Drive       ${COLOR_RED}✗${COLOR_RESET} not found"
        provider_count=2
    fi

    if [ -n "$gdrive_path" ]; then
        echo "  ${COLOR_GREEN}${provider_count})${COLOR_RESET} Google Drive      ${COLOR_GREEN}✓${COLOR_RESET} found at:"
        echo "     $gdrive_path"
    else
        echo "  ${COLOR_RED}${provider_count})${COLOR_RESET} Google Drive      ${COLOR_RED}✗${COLOR_RESET} not found"
    fi
    provider_count=$((provider_count + 1))

    if [ -n "$onedrive_path" ]; then
        echo "  ${COLOR_GREEN}${provider_count})${COLOR_RESET} OneDrive          ${COLOR_GREEN}✓${COLOR_RESET} found at:"
        echo "     $onedrive_path"
    else
        echo "  ${COLOR_RED}${provider_count})${COLOR_RESET} OneDrive          ${COLOR_RED}✗${COLOR_RESET} not found"
    fi
    provider_count=$((provider_count + 1))

    if [ -n "$proton_path" ]; then
        echo "  ${COLOR_GREEN}${provider_count})${COLOR_RESET} Proton Drive      ${COLOR_GREEN}✓${COLOR_RESET} found at:"
        echo "     $proton_path"
    else
        echo "  ${COLOR_RED}${provider_count})${COLOR_RESET} Proton Drive      ${COLOR_RED}✗${COLOR_RESET} not found"
    fi
    provider_count=$((provider_count + 1))

    if [ -n "$mega_path" ]; then
        echo "  ${COLOR_GREEN}${provider_count})${COLOR_RESET} Mega.nz           ${COLOR_GREEN}✓${COLOR_RESET} found at:"
        echo "     $mega_path"
    else
        echo "  ${COLOR_RED}${provider_count})${COLOR_RESET} Mega.nz           ${COLOR_RED}✗${COLOR_RESET} not found"
    fi
    provider_count=$((provider_count + 1))

    if [ "$has_rclone" = "yes" ]; then
        echo "  ${COLOR_GREEN}${provider_count})${COLOR_RESET} rclone remote     ${COLOR_GREEN}✓${COLOR_RESET} installed"
    else
        echo "  ${COLOR_RED}${provider_count})${COLOR_RESET} rclone remote     ${COLOR_RED}✗${COLOR_RESET} not installed"
    fi
    provider_count=$((provider_count + 1))

    echo "  ${COLOR_BLUE}${provider_count})${COLOR_RESET} Local/Custom       (any folder)"
    echo ""

    # Read user choice
    read -p "Select provider [1-${provider_count}]: " choice
    choice=$(echo "$choice" | tr -d ' ')

    if ! echo "$choice" | grep -qE '^[0-9]+$'; then
        print_error "Invalid choice. Please enter a number."
        return 1
    fi

    selected_provider=""
    selected_path=""
    selected_rclone=""
    selected_rclone_path=""

    case "$choice" in
        1)
            if [ -n "$icloud_path" ]; then
                selected_provider="icloud"
                selected_path="$icloud_path"
                print_success "Selected: iCloud Drive"
            else
                print_error "iCloud Drive not found."
                return 1
            fi
            ;;
        2)
            if [ -n "$gdrive_path" ]; then
                selected_provider="googledrive"
                selected_path="$gdrive_path"
                print_success "Selected: Google Drive"
            else
                print_error "Google Drive not found."
                return 1
            fi
            ;;
        3)
            if [ -n "$onedrive_path" ]; then
                selected_provider="onedrive"
                selected_path="$onedrive_path"
                print_success "Selected: OneDrive"
            else
                print_error "OneDrive not found."
                return 1
            fi
            ;;
        4)
            if [ -n "$proton_path" ]; then
                selected_provider="protondrive"
                selected_path="$proton_path"
                print_success "Selected: Proton Drive"
            else
                print_error "Proton Drive not found."
                return 1
            fi
            ;;
        5)
            if [ -n "$mega_path" ]; then
                selected_provider="mega"
                selected_path="$mega_path"
                print_success "Selected: Mega.nz"
            else
                print_error "Mega.nz not found."
                return 1
            fi
            ;;
        6)
            if [ "$has_rclone" = "yes" ]; then
                selected_provider="rclone"
                print_success "Selected: rclone remote"
            else
                print_error "rclone not found."
                return 1
            fi
            ;;
        7)
            selected_provider="local"
            print_success "Selected: Local/Custom"
            ;;
        *)
            print_error "Invalid choice. Please enter a number from 1 to 7."
            return 1
            ;;
    esac

    echo ""

    if [ "$selected_provider" = "rclone" ]; then
        echo "Configured rclone remotes:"
        rclone_remotes=$(list_rclone_remotes)
        if [ -z "$rclone_remotes" ]; then
            print_error "No rclone remotes configured."
            echo "Run 'rclone config' to set up a remote."
            return 1
        fi
        echo "$rclone_remotes"
        echo ""
        read -p "Enter rclone remote name: " selected_rclone
        selected_rclone=$(echo "$selected_rclone" | tr -d ' ' | sed 's/:$//')

        if ! echo "$rclone_remotes" | grep -q "^${selected_rclone}:$"; then
            print_warning "Remote '$selected_rclone' not found in configured remotes."
        fi

        read -p "Enter path within rclone remote [default: '']: " selected_rclone_path
    elif [ "$selected_provider" = "local" ]; then
        read -p "Enter full path to cloud folder: " selected_path
        selected_path=$(echo "$selected_path" | xargs)
        if [ ! -d "$selected_path" ]; then
            print_error "Path does not exist: $selected_path"
            return 1
        fi
        print_success "Path confirmed: $selected_path"
    fi

    echo ""
    echo "Project folder name in cloud storage:"
    read -p "  [$PROJECT_NAME]: " project_folder
    project_folder=${project_folder:-$PROJECT_NAME}
    project_folder=$(echo "$project_folder" | xargs)

    echo ""
    print_header "Configuration Summary"
    echo "  Provider:           $selected_provider"
    if [ -n "$selected_path" ]; then
        echo "  Provider path:      $selected_path"
    fi
    if [ -n "$selected_rclone" ]; then
        echo "  Rclone remote:      $selected_rclone"
        echo "  Rclone path:        $selected_rclone_path"
    fi
    echo "  Project folder:     $project_folder"
    echo ""

    read -p "Save configuration? [y/n]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_error "Configuration cancelled."
        return 1
    fi

    create_config_json "$selected_provider" "$selected_path" "$selected_rclone" "$selected_rclone_path" "$project_folder"
    print_success "Configuration saved to: $CONFIG_FILE"
    echo ""
    echo "Next steps:"
    echo "  1. Review the configuration: cat $CONFIG_FILE"
    echo "  2. Test export: bash dev-sync-export.sh --dry-run"
    echo "  3. If config is correct, run: bash dev-sync-export.sh"
}

main "$@"
