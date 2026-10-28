#!/usr/bin/env bash
# =============================================================================
# lib/policy.sh — Risk policy helpers
# Bash 3.2 compatible.
# =============================================================================

declare -a POLICY_RULE_PATHS=()
declare -a POLICY_RULE_SAFETY=()
declare -a POLICY_RULE_TYPES=()
declare -a POLICY_RULE_NOTES=()

policy_safety_to_risk() {
    local safety
    safety="$(printf '%s' "${1:-ask}" | tr '[:upper:]' '[:lower:]')"
    case "$safety" in
        safe)  echo "SAFE" ;;
        ask|review) echo "REVIEW" ;;
        never|dangerous) echo "DANGEROUS" ;;
        *) echo "REVIEW" ;;
    esac
}

policy_risk_to_safety() {
    case "${1:-REVIEW}" in
        SAFE) echo "safe" ;;
        DANGEROUS) echo "never" ;;
        *) echo "ask" ;;
    esac
}

policy_add_rule() {
    local path="$1"
    local safety="${2:-ask}"
    local type="${3:-other}"
    local notes="${4:-}"
    local normalized

    [[ -z "$path" ]] && return 0
    normalized="$(normalize_path "$path" || echo "$path")"
    POLICY_RULE_PATHS+=("$normalized")
    POLICY_RULE_SAFETY+=("$(printf '%s' "$safety" | tr '[:upper:]' '[:lower:]')")
    POLICY_RULE_TYPES+=("$type")
    POLICY_RULE_NOTES+=("$notes")
}

policy_reset_rules() {
    POLICY_RULE_PATHS=()
    POLICY_RULE_SAFETY=()
    POLICY_RULE_TYPES=()
    POLICY_RULE_NOTES=()
}

load_policy_rules_from_yaml() {
    local rules_file="${RULES_FILE:-}"
    [[ -n "$rules_file" && -f "$rules_file" ]] || return 0

    policy_reset_rules

    local line value current_path="" current_type="" current_safety="" current_notes=""
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        case "$line" in
            "- path:"*)
                if [[ -n "$current_path" && -n "$current_safety" ]]; then
                    policy_add_rule "$current_path" "$current_safety" "$current_type" "$current_notes"
                fi
                value="${line#- path:}"
                value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
                current_path="$value"
                current_type=""
                current_safety=""
                current_notes=""
                ;;
            "path:"*)
                if [[ -n "$current_path" && -n "$current_safety" ]]; then
                    policy_add_rule "$current_path" "$current_safety" "$current_type" "$current_notes"
                fi
                value="${line#path:}"
                value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
                current_path="$value"
                current_type=""
                current_safety=""
                current_notes=""
                ;;
            "type:"*)
                current_type="${line#type:}"
                current_type="$(printf '%s' "$current_type" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                ;;
            "safety:"*)
                current_safety="${line#safety:}"
                current_safety="$(printf '%s' "$current_safety" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                current_safety="${current_safety%\"}"; current_safety="${current_safety#\"}"
                current_safety="${current_safety%\'}"; current_safety="${current_safety#\'}"
                ;;
            "notes:"*)
                current_notes="${line#notes:}"
                current_notes="$(printf '%s' "$current_notes" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                ;;
        esac
    done < "$rules_file"

    if [[ -n "$current_path" && -n "$current_safety" ]]; then
        policy_add_rule "$current_path" "$current_safety" "$current_type" "$current_notes"
    fi
}

apply_policy_never_paths() {
    local i
    for (( i = 0; i < ${#POLICY_RULE_PATHS[@]}; i++ )); do
        if [[ "${POLICY_RULE_SAFETY[$i]}" == "never" ]]; then
            add_never_touch_path "${POLICY_RULE_PATHS[$i]}"
        fi
    done
}

# Longest-prefix rule index for a path, or -1. Pass "fold" as $2 for a
# case-insensitive match: APFS is case-insensitive, so "$HOME/.NPM" is the
# same object as "$HOME/.npm" (P0-2). A folded match may only RAISE risk; see
# policy_explicit_risk_for_path and policy_adjust_risk_for_path.
policy_rule_index_for_path() {
    local candidate="$1"
    local fold="${2:-}"
    local normalized_candidate
    local best_idx="-1"
    local best_len=0
    local i rule_path len saved_nocase=0

    normalized_candidate="$(normalize_path "$candidate" || echo "$candidate")"

    shopt -q nocasematch && saved_nocase=1
    if [[ "$fold" == "fold" ]]; then
        shopt -s nocasematch
    else
        shopt -u nocasematch
    fi

    for (( i = 0; i < ${#POLICY_RULE_PATHS[@]}; i++ )); do
        rule_path="${POLICY_RULE_PATHS[$i]}"
        if [[ "$normalized_candidate" == "$rule_path" || "$normalized_candidate" == "$rule_path/"* ]]; then
            len=${#rule_path}
            if (( len > best_len )); then
                best_idx="$i"
                best_len="$len"
            fi
        fi
    done

    if (( saved_nocase == 1 )); then
        shopt -s nocasematch
    else
        shopt -u nocasematch
    fi

    echo "$best_idx"
}

policy_risk_for_path() {
    local idx
    idx="$(policy_rule_index_for_path "$1")"
    if [[ "$idx" != "-1" ]]; then
        policy_safety_to_risk "${POLICY_RULE_SAFETY[$idx]}"
        return 0
    fi
    if is_protected_path "$1"; then
        echo "DANGEROUS"
    else
        echo "REVIEW"
    fi
}

policy_type_for_path() {
    local idx
    idx="$(policy_rule_index_for_path "$1")"
    if [[ "$idx" != "-1" ]]; then
        echo "${POLICY_RULE_TYPES[$idx]:-other}"
    else
        echo "other"
    fi
}

# Risk of the exact-case longest match only, or "" (return 1).
policy_exact_risk_for_path() {
    local idx
    idx="$(policy_rule_index_for_path "$1")"
    if [[ "$idx" == "-1" ]]; then
        echo ""
        return 1
    fi
    policy_safety_to_risk "${POLICY_RULE_SAFETY[$idx]}"
}

# Higher risk of the exact-case and case-insensitive longest matches, or ""
# (return 1). The folded match can only raise the exact-case result.
policy_explicit_risk_for_path() {
    local exact_risk fold_idx fold_risk=""
    exact_risk="$(policy_exact_risk_for_path "$1" || true)"
    fold_idx="$(policy_rule_index_for_path "$1" fold)"
    if [[ "$fold_idx" != "-1" ]]; then
        fold_risk="$(policy_safety_to_risk "${POLICY_RULE_SAFETY[$fold_idx]}")"
    fi
    if [[ -z "$exact_risk" && -z "$fold_risk" ]]; then
        echo ""
        return 1
    fi
    if [[ -z "$exact_risk" ]]; then
        echo "$fold_risk"
    elif [[ -n "$fold_risk" ]] && (( $(policy_risk_rank "$fold_risk") > $(policy_risk_rank "$exact_risk") )); then
        echo "$fold_risk"
    else
        echo "$exact_risk"
    fi
}

policy_risk_rank() {
    case "${1:-REVIEW}" in
        SAFE) echo 1 ;;
        REVIEW) echo 2 ;;
        DANGEROUS) echo 3 ;;
        *) echo 2 ;;
    esac
}

policy_adjust_risk_for_path() {
    local path="$1"
    local default_risk="${2:-REVIEW}"
    local explicit_risk default_rank explicit_rank

    if is_protected_path "$path"; then
        echo "DANGEROUS"
        return 0
    fi

    explicit_risk="$(policy_explicit_risk_for_path "$path" 2>/dev/null || true)"
    [[ -z "$explicit_risk" ]] && { echo "$default_risk"; return 0; }

    default_rank="$(policy_risk_rank "$default_risk")"
    explicit_rank="$(policy_risk_rank "$explicit_risk")"

    if (( explicit_rank > default_rank )); then
        echo "$explicit_risk"
        return 0
    fi

    # Exact SAFE rules may lower a conservative REVIEW default, for example
    # app-specific cache entries below a broader ~/Library/Caches REVIEW rule.
    # Only an exact-case match may lower; a case variant keeps the default.
    if [[ "$explicit_risk" == "SAFE" && "$default_risk" == "REVIEW" ]] \
        && [[ "$(policy_exact_risk_for_path "$path" 2>/dev/null || true)" == "SAFE" ]]; then
        echo "SAFE"
        return 0
    fi

    echo "$default_risk"
}

app_cache_auto_safe() {
    local label="$1"

    case "$label" in
        "Slack (Electron cache)"|\
        "Slack (Code Cache)"|\
        "Slack (GPU Cache)"|\
        "VS Code (Cache)"|\
        "VS Code (Code Cache)"|\
        "Cursor (Cache)"|\
        "Cursor (Code Cache)"|\
        "Microsoft Teams (Cache)"|\
        "Microsoft Teams (Code Cache)"|\
        "Discord (Cache)"|\
        "Discord (Code Cache)"|\
        "Zoom (Cache)"|\
        "Spotify (Cache)"|\
        "Xcode (Cache)"|\
        "CleanMyMac (Cache)")
            return 0 ;;
    esac

    return 1
}

app_cache_description() {
    local label="$1"

    case "$label" in
        Slack*)
            t "app_cache_desc_slack" ;;
        "VS Code (Cache)"|"VS Code (Code Cache)"|"VS Code (CachedData)")
            t "app_cache_desc_vscode" ;;
        "VS Code (CachedExtensionVSIXs)")
            t "app_cache_desc_vscode_vsix" ;;
        Cursor*)
            t "app_cache_desc_cursor" ;;
        "Figma (Cache)")
            t "app_cache_desc_figma" ;;
        "JetBrains IDEs (Cache)")
            t "app_cache_desc_jetbrains" ;;
        "JetBrains IDEs (Logs)")
            t "app_cache_desc_jetbrains_logs" ;;
        "Adobe (Cache)")
            t "app_cache_desc_adobe" ;;
        "Adobe Media Cache Files"|"Adobe Media Cache")
            t "app_cache_desc_adobe_media" ;;
        "Microsoft Teams"*)
            t "app_cache_desc_teams" ;;
        "Spotify (Cache)")
            t "app_cache_desc_spotify" ;;
        "Spotify (PersistentCache)")
            t "app_cache_desc_spotify_persistent" ;;
        Discord*)
            t "app_cache_desc_discord" ;;
        "Zoom (Cache)")
            t "app_cache_desc_zoom" ;;
        "Xcode (Cache)")
            t "app_cache_desc_xcode" ;;
        "CleanMyMac (Cache)")
            t "app_cache_desc_cleanmymac" ;;
        *)
            t "app_cache_desc_default" ;;
    esac
}

app_cache_recommendation() {
    local label="$1"

    case "$label" in
        "VS Code (CachedExtensionVSIXs)")
            t "app_cache_rec_vscode_vsix" ;;
        "Figma (Cache)")
            t "app_cache_rec_figma" ;;
        "JetBrains IDEs (Cache)")
            t "app_cache_rec_jetbrains" ;;
        "JetBrains IDEs (Logs)")
            t "app_cache_rec_jetbrains_logs" ;;
        "Adobe (Cache)"|"Adobe Media Cache Files"|"Adobe Media Cache")
            t "app_cache_rec_adobe" ;;
        "Spotify (PersistentCache)")
            t "app_cache_rec_spotify_persistent" ;;
        *)
            if app_cache_auto_safe "$label"; then
                t "app_cache_rec_default_safe"
            else
                t "app_cache_rec_default_review"
            fi
            ;;
    esac
}
