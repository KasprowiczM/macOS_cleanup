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

policy_rule_index_for_path() {
    local candidate="$1"
    local normalized_candidate
    local best_idx="-1"
    local best_len=0
    local i rule_path len

    normalized_candidate="$(normalize_path "$candidate" || echo "$candidate")"

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

policy_explicit_risk_for_path() {
    local idx
    idx="$(policy_rule_index_for_path "$1")"
    if [[ "$idx" == "-1" ]]; then
        echo ""
        return 1
    fi
    policy_safety_to_risk "${POLICY_RULE_SAFETY[$idx]}"
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
    if [[ "$explicit_risk" == "SAFE" && "$default_risk" == "REVIEW" ]]; then
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
            echo "Slack/Electron cache: miniatury, skompilowany JavaScript i GPU cache. Nie zawiera historii rozmów ani workspace settings." ;;
        "VS Code (Cache)"|"VS Code (Code Cache)"|"VS Code (CachedData)")
            echo "VS Code cache: odtwarzalne dane UI, extension host i skompilowany kod JS. Nie usuwa projektów, ustawień ani rozszerzeń." ;;
        "VS Code (CachedExtensionVSIXs)")
            echo "VS Code CachedExtensionVSIXs: lokalne kopie paczek rozszerzeń. Usunięcie może wymusić ponowne pobranie rozszerzeń przy update/reinstall." ;;
        Cursor*)
            echo "Cursor cache: odtwarzalne cache aplikacji opartej o VS Code/Electron. Nie usuwa projektów ani ustawień edytora." ;;
        "Figma (Cache)")
            echo "Figma cache: lokalne cache plików i zasobów UI. Zwykle odtwarzalne, ale może spowolnić ponowne otwieranie dużych projektów offline." ;;
        "JetBrains IDEs (Cache)")
            echo "JetBrains cache: indeksy, symbole i cache IDE. Projekty nie znikną, ale IDE może długo odbudowywać indeksy." ;;
        "JetBrains IDEs (Logs)")
            echo "JetBrains logs: stare logi diagnostyczne IDE. Usuń tylko jeśli nie diagnozujesz problemów z IDE/pluginami." ;;
        "Adobe (Cache)")
            echo "Adobe cache: cache aplikacji Adobe. Zwykle odtwarzalne, ale pierwsze uruchomienie lub otwarcie projektów może być wolniejsze." ;;
        "Adobe Media Cache Files"|"Adobe Media Cache")
            echo "Adobe Media Cache: podglądy, conform audio/video i media cache. Usunięcie nie usuwa źródłowych projektów, ale Premiere/After Effects może długo odbudowywać cache." ;;
        "Microsoft Teams"*)
            echo "Teams cache: cache Electron, web assets i skompilowany JS. Nie usuwa czatów z chmury ani konta." ;;
        "Spotify (Cache)")
            echo "Spotify cache: streaming cache muzyki/podcastów. Aplikacja pobierze dane ponownie; ustawienia i konto zostają." ;;
        "Spotify (PersistentCache)")
            echo "Spotify PersistentCache: większy cache offline/streaming. Review zalecany, bo może wpływać na lokalnie pobrane dane i ponowne pobieranie." ;;
        Discord*)
            echo "Discord cache: odtwarzalne web assets, obrazy i skompilowany JS. Nie usuwa konta ani historii z serwera." ;;
        "Zoom (Cache)")
            echo "Zoom cache: tymczasowe cache klienta. Nie usuwa nagrań zapisanych w Documents/Zoom ani konfiguracji konta." ;;
        "Xcode (Cache)")
            echo "Xcode cache: odtwarzalne cache narzędzi deweloperskich. Nie usuwa kodu źródłowego ani DerivedData." ;;
        "CleanMyMac (Cache)")
            echo "CleanMyMac cache: odtwarzalne cache aplikacji. Nie usuwa ustawień ani licencji." ;;
        *)
            echo "Cache aplikacji: potencjalnie odtwarzalne dane pomocnicze. Przejrzyj ścieżkę i nazwę aplikacji przed usunięciem." ;;
    esac
}

app_cache_recommendation() {
    local label="$1"

    case "$label" in
        "VS Code (CachedExtensionVSIXs)")
            echo "REVIEW: usuń tylko jeśli akceptujesz ponowne pobieranie paczek rozszerzeń." ;;
        "Figma (Cache)")
            echo "REVIEW: bezpieczne technicznie, ale sprawdź, czy nie polegasz na pracy offline w Figmie." ;;
        "JetBrains IDEs (Cache)")
            echo "REVIEW: usuń gdy masz czas na odbudowę indeksów; pierwszy start IDE/build może być wolniejszy." ;;
        "JetBrains IDEs (Logs)")
            echo "REVIEW: zachowaj, jeśli diagnozujesz awarie IDE lub pluginów." ;;
        "Adobe (Cache)"|"Adobe Media Cache Files"|"Adobe Media Cache")
            echo "REVIEW: usuń, jeśli masz źródłowe media/projekty i akceptujesz ponowne generowanie podglądów." ;;
        "Spotify (PersistentCache)")
            echo "REVIEW: usuń, jeśli akceptujesz ponowne pobieranie większych danych Spotify." ;;
        *)
            if app_cache_auto_safe "$label"; then
                echo "SAFE: można usunąć przez auto-safe; aplikacja odtworzy cache bez utraty danych użytkownika."
            else
                echo "REVIEW: skrypt pokaże tę pozycję w planie, ale nie usunie automatycznie."
            fi
            ;;
    esac
}
