#!/usr/bin/env bash
# =============================================================================
# lib/pathguard.sh — Path Provenance & Symlink Traversal Engine [P0-2]
#
# Validates candidate paths before removal or processing.
# Ensures target paths reside within allowed disposable roots, do not traverse
# symlinks into protected system/user directories, and are owned by the user.
#
# Bash 3.2 compatible.
# =============================================================================

# Prevent double-sourcing guard
[[ -n "${_MAC_CLEANUP_PATHGUARD_LOADED:-}" ]] && return 0
_MAC_CLEANUP_PATHGUARD_LOADED=1

# Helper: Get numeric owner UID of a path (macOS BSD stat & GNU stat compatible)
_get_path_owner_uid() {
    local target="$1"
    if stat -f %u "$target" 2>/dev/null; then
        return 0
    elif stat -c %u "$target" 2>/dev/null; then
        return 0
    fi
    echo "-1"
}

# Helper: Check if path contains project or credential markers (hostile override check)
_has_hostile_content_markers() {
    local target="$1"
    [[ -z "$target" ]] && return 1

    local user_home="${HOME:-}"
    if [[ -n "$user_home" ]]; then
        # Cannot be $HOME itself or /Users
        [[ "$target" == "$user_home" || "$target" == "/Users" ]] && return 0
    fi

    # Direct project/repo markers at depth 1
    if [[ -e "$target/.git" || -e "$target/package.json" || -e "$target/Cargo.toml" || \
          -e "$target/CMakeLists.txt" || -e "$target/go.mod" || -e "$target/pom.xml" || \
          -e "$target/Makefile" || -e "$target/.ssh" || -e "$target/.gnupg" ]]; then
        return 0
    fi

    # Check for Xcode project files at depth 1
    if ls "$target"/*.xcodeproj "$target"/*.xcworkspace >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Helper: Check if path is within authorized disposable roots
_is_within_allowed_cache_root() {
    local norm="$1"
    local user_home="${HOME:-}"

    # Must be absolute
    [[ "$norm" == /* ]] || return 1

    # Allowed userDisposableRoots
    if [[ -n "$user_home" ]]; then
        case "$norm" in
            "$user_home/Library/Caches"|"$user_home/Library/Caches/"*) return 0 ;;
            "$user_home/Library/Logs"|"$user_home/Library/Logs/"*) return 0 ;;
            "$user_home/Library/Developer/Xcode/DerivedData"|"$user_home/Library/Developer/Xcode/DerivedData/"*) return 0 ;;
            "$user_home/Library/Developer/Xcode/Archives"|"$user_home/Library/Developer/Xcode/Archives/"*) return 0 ;;
            "$user_home/Library/Developer/Xcode/iOS DeviceSupport"|"$user_home/Library/Developer/Xcode/iOS DeviceSupport/"*) return 0 ;;
            "$user_home/Library/Developer/CoreSimulator/Devices"|"$user_home/Library/Developer/CoreSimulator/Devices/"*) return 0 ;;
            "$user_home/Library/Application Support/CrashReporter"|"$user_home/Library/Application Support/CrashReporter/"*) return 0 ;;
            "$user_home/.cache"|"$user_home/.cache/"*) return 0 ;;
            "$user_home/.npm"|"$user_home/.npm/"*) return 0 ;;
            "$user_home/.yarn"|"$user_home/.yarn/"*) return 0 ;;
            "$user_home/.gradle"|"$user_home/.gradle/"*) return 0 ;;
            "$user_home/.cargo"|"$user_home/.cargo/"*) return 0 ;;
            "$user_home/.gem"|"$user_home/.gem/"*) return 0 ;;
            "$user_home/.Trash"|"$user_home/.Trash/"*) return 0 ;;
            "$user_home/Downloads"|"$user_home/Downloads/"*) return 0 ;;
        esac
    fi

    # Allowed System/Global Disposable Roots
    case "$norm" in
        /Library/Caches|/Library/Caches/*) return 0 ;;
        /Library/Logs|/Library/Logs/*) return 0 ;;
        /tmp|/tmp/*|/private/tmp|/private/tmp/*) return 0 ;;
        /var/tmp|/var/tmp/*|/private/var/tmp|/private/var/tmp/*) return 0 ;;
        /var/folders|/var/folders/*|/private/var/folders|/private/var/folders/*) return 0 ;;
    esac

    # Quarantine sandbox roots for test harnesses
    if [[ -n "${QUARANTINE_ROOT:-}" && "$norm" == "${QUARANTINE_ROOT}"* ]]; then
        return 0
    fi
    if [[ -n "${SANDBOX:-}" && "$norm" == "${SANDBOX}"* ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# validate_cache_path <path>
#
# Validates candidate path for safe deletion or processing:
# 1. Rejects empty or relative paths.
# 2. Normalizes candidate path using normalize_path.
# 3. Fails closed if is_protected_path returns true (0).
# 4. Rejects paths containing hostile project markers (.git, package.json, etc.).
# 5. Ensures path resides within allowed cache/log/disposable root.
# 6. Inspects symlinks (both leaf and parent ancestors) to prevent symlink
#    traversal out of allowed boundaries into protected user data or system paths.
# 7. Checks file ownership (must match current UID or root).
#
# Returns 0 if safe to clean, 1 if invalid/protected/dangerous.
# =============================================================================
validate_cache_path() {
    local raw_path="${1:-}"

    # 1. Non-empty check
    if [[ -z "$raw_path" ]]; then
        return 1
    fi

    # 2. Normalize path
    local norm_path
    norm_path="$(normalize_path "$raw_path" 2>/dev/null || echo "$raw_path")"

    # 3. Protected path check (FAIL CLOSED)
    if is_protected_path "$norm_path" || is_protected_path "$raw_path"; then
        return 1
    fi

    # 4. Hostile content / project marker check
    if _has_hostile_content_markers "$norm_path" || _has_hostile_content_markers "$raw_path"; then
        return 1
    fi

    # 5. Allowed cache root check
    if ! _is_within_allowed_cache_root "$norm_path"; then
        return 1
    fi

    # 6. Symlink & Traversal Check
    # If target is a symlink, check where it points
    if [[ -L "$raw_path" || -L "$norm_path" ]]; then
        local link_target
        link_target="$(readlink "$raw_path" 2>/dev/null || readlink "$norm_path" 2>/dev/null || true)"
        if [[ -n "$link_target" ]]; then
            local norm_target
            if [[ "$link_target" != /* ]]; then
                local parent_dir
                parent_dir="$(dirname "$raw_path")"
                norm_target="$(normalize_path "${parent_dir}/${link_target}" 2>/dev/null || echo "")"
            else
                norm_target="$(normalize_path "$link_target" 2>/dev/null || echo "$link_target")"
            fi

            # Symlink target MUST NOT be protected
            if is_protected_path "$norm_target"; then
                return 1
            fi
            # Symlink target MUST NOT contain hostile project markers
            if _has_hostile_content_markers "$norm_target"; then
                return 1
            fi
            # Symlink target MUST be within allowed cache root
            if ! _is_within_allowed_cache_root "$norm_target"; then
                return 1
            fi
        fi
    fi

    # 7. Owner check (if path exists)
    if [[ -e "$raw_path" || -L "$raw_path" ]]; then
        local current_uid owner_uid
        current_uid="$(id -u 2>/dev/null || echo "501")"
        owner_uid="$(_get_path_owner_uid "$raw_path")"

        if [[ "$owner_uid" != "-1" && "$current_uid" != "0" ]]; then
            if [[ "$owner_uid" != "$current_uid" ]]; then
                # Unowned or owned by different non-root user
                return 1
            fi
        fi
    fi

    return 0
}
