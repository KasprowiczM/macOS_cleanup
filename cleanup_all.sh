#!/usr/bin/env bash
# =============================================================================
# cleanup_all.sh — Professional macOS System Cleaner
# Version: 3.0.0
#
# SYNOPSIS
#   bash cleanup_all.sh [OPTIONS]
#
# DESCRIPTION
#   Analyzes your macOS system and safely frees up disk space.
#   Default behavior: full dry-run analysis → show results → offer to clean.
#   Nothing is ever deleted without your explicit confirmation.
#
# OPTIONS
#   --dry-run             Analyze only; generate report; don't delete anything (default)
#   analyze               Alias for --dry-run
#   plan                  Analyze and write machine-readable reports/plan_*.json
#   apply --from-plan P   Apply a plan; default executes SAFE operations only
#   --interactive         Ask for confirmation before each category
#   --auto-safe           Remove only explicitly safe app caches/tmp, ask for the rest
#   --category <name>     Only process the specified category
#                         Values: trash | system | user-caches | logs |
#                                 app-leftovers | dev | time-machine | large-files
#   --exclude <path>      Add a path to the exclusion list (repeatable)
#   --include <category>  Re-include a previously excluded category
#   --include <category>  Alias to --category
#   --restore <id|file>   Restore files from a previous quarantine manifest
#   --list-quarantine     List quarantine runs
#   --prune-artifacts     Delete aged run logs/reports (ARTIFACT_RETENTION_DAYS; 0 disables)
#   --purge-quarantine <latest|id|all>
#                         Permanently remove quarantine run(s); requires --apply
#   --quarantine          Move user-scope removals to restoreable quarantine (default)
#   --permanent           Permanently delete safe_remove() targets after guardrails
#   --apply               Actually apply a purge-quarantine operation
#   --from-plan <file>    Plan JSON to apply
#   --plan-file <file>    Output plan path for plan mode
#   --include-review      Allow REVIEW operations during plan apply (interactive)
#   --require-typing-path Require typing the full path for REVIEW removals
#   --retention-days <n>  Retention for --purge-quarantine expired
#   --non-interactive      Run without tty prompts (recommended for CI)
#   --yes                  Auto-confirm SAFE risk categories only (use with --non-interactive)
#   --no-color             Disable colored output
#   --log-level <level>   DEBUG | INFO | WARN | ERROR (default: INFO)
#   --json                Print machine-readable JSON run summary to stdout
#   --help                Show this help message
#   --version             Print version number
#
# SAFETY
#   This script NEVER touches: Mail data, Keychains, browser profiles,
#   password managers, ~/Documents, ~/Desktop, Photos Library.
#   Any ambiguous item is reported but NOT deleted.
#
# EXAMPLES
#   bash cleanup_all.sh                      # Full dry-run (safe default)
#   bash cleanup_all.sh --interactive        # Interactive cleaning
#   bash cleanup_all.sh --category dev       # Only developer environment
#   bash cleanup_all.sh --dry-run            # Explicit dry-run mode
#
# =============================================================================
#
# EXIT CODES
#   0   Success
#   1   General error
#   2   Bad arguments
#   3   macOS version incompatible (requires 10.15+)
#   99  Safety violation — operation blocked, run continues (logged + journalled)
#
# =============================================================================

set -euo pipefail
# Ensure errexit doesn't prevent cleanup on exit
trap '_on_exit' EXIT
trap '_on_error $LINENO' ERR
trap '_on_interrupt' INT TERM

# ---------------------------------------------------------------------------
# Resolve script location so we can source lib files regardless of CWD
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SELF="${BASH_SOURCE[0]}"

# ---------------------------------------------------------------------------
# Source configuration and libraries (order matters!)
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/config/defaults.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/pathguard.sh"
source "${SCRIPT_DIR}/lib/policy.sh"
source "${SCRIPT_DIR}/lib/interactive.sh"
source "${SCRIPT_DIR}/lib/analyzer.sh"
source "${SCRIPT_DIR}/lib/cleaner.sh"
source "${SCRIPT_DIR}/lib/planner.sh"
source "${SCRIPT_DIR}/lib/reporter.sh"
source "${SCRIPT_DIR}/lib/json_summary.sh"

# ---------------------------------------------------------------------------
# Runtime state (set by argument parsing)
# ---------------------------------------------------------------------------
MODE="${DEFAULT_MODE}"          # dry-run | interactive | auto-safe
DRY_RUN=1                       # 1 = don't delete, 0 = delete (set by mode)
EXPLICIT_DRY_RUN=0              # --dry-run is a hard no-delete request
SELECTED_CATEGORIES=()          # Empty = all categories
ACTIVE_CATEGORIES=()            # Real category list used at runtime
EXCLUDED_PATHS=()               # Extra paths to exclude
RESTORE_TARGET=""               # restore_<run>.tsv, run id, or manifest path
PURGE_TARGET=""                 # latest | run id | all
APPLY_PURGE=0
PLAN_FILE="$PLAN_FILE_DEFAULT"
PLAN_FROM_FILE=""
INCLUDE_REVIEW=0
REQUIRE_TYPING_PATH=0
RETENTION_DAYS="$QUARANTINE_RETENTION_DAYS"
SHOW_HELP=0
SHOW_VERSION=0
JSON_OUTPUT=0
# When --json is active this fd points to the original stdout so the
# JSON summary reaches the caller even though fd 1 is redirected to stderr.
JSON_OUTPUT_FD=1
SUDO_KEEPALIVE_PID=""

configure_colors() {
    if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
        C_RESET='\033[0m'
        C_RED='\033[0;31m'
        C_GREEN='\033[0;32m'
        C_YELLOW='\033[1;33m'
        C_BLUE='\033[0;34m'
        C_CYAN='\033[0;36m'
        C_BOLD='\033[1m'
        C_DIM='\033[2m'
    else
        C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM=''
    fi
}

add_category_arg() {
    local raw="$1"
    local old_ifs="$IFS"
    local token
    IFS=',' 
    for token in $raw; do
        token="$(printf '%s' "$token" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$token" ]] && continue
        SELECTED_CATEGORIES+=("$token")
    done
    IFS="$old_ifs"
}

validate_log_level() {
    local lvl="$1"
    case "$lvl" in
        DEBUG|INFO|WARN|ERROR) return 0 ;;
        *) return 1 ;;
    esac
}

build_active_categories() {
    ACTIVE_CATEGORIES=()

    # If no explicit categories were passed, run all.
    if (( ${#SELECTED_CATEGORIES[@]} == 0 )); then
        ACTIVE_CATEGORIES=("${ALL_CATEGORIES[@]}")
        return 0
    fi

    local cat valid seen
    for cat in "${SELECTED_CATEGORIES[@]}"; do
        valid=0
        for s in "${ALL_CATEGORIES[@]}"; do
            [[ "$cat" == "$s" ]] && valid=1 && break
        done
        if (( !valid )); then
            print_error "Nieznana kategoria: '${cat}'"
            echo "$(t "cli_avail_cats"): ${ALL_CATEGORIES[*]}"
            exit 2
        fi

        seen=0
        if (( ${#ACTIVE_CATEGORIES[@]} > 0 )); then
            for s in "${ACTIVE_CATEGORIES[@]}"; do
                [[ "$s" == "$cat" ]] && seen=1 && break
            done
        fi
        (( seen == 0 )) && ACTIVE_CATEGORIES+=("$cat")
    done
}

# ---------------------------------------------------------------------------
# Signal / exit handlers
# ---------------------------------------------------------------------------
_on_exit() {
    local exit_code=$?
    release_cleanup_lock
    cleanup_sudo_keepalive
    if (( exit_code == 0 )); then
        log_info "Script completed successfully (exit 0)."
    fi
}

_on_error() {
    local status=$?
    local lineno="$1"
    log_error "$(t "cli_line_error") ${lineno}. $(t "cli_exit_code"): ${status}"
    # Don't exit loudly — the set -e will handle propagation
}

_on_interrupt() {
    echo
    print_warn "$(t "cli_interrupted")"
    log_info "Script interrupted by user signal."
    cleanup_sudo_keepalive
    exit 130
}

# ---------------------------------------------------------------------------
# Usage / version
# ---------------------------------------------------------------------------
show_help() {
    # Extract the banner block: from SYNOPSIS up to (but not including) the
    # first line that is only a comment-separator of equals signs.
    sed -n '/^# SYNOPSIS/,/^# =\{5,\}$/p' "$SCRIPT_SELF" | \
        sed '/^# =\{5,\}$/d' | \
        grep '^#' | sed 's/^# \?//'
    echo
    echo "  --prune-artifacts     $(t "cli_help_prune_artifacts")"
    echo
    echo "$(t "cli_categories"):"
    for cat in "${ALL_CATEGORIES[@]}"; do
        echo "  $cat"
    done
    echo
}

show_version() {
    echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            analyze)
                MODE="dry-run"
                DRY_RUN=1
                EXPLICIT_DRY_RUN=1
                shift
                ;;
            plan)
                MODE="plan"
                DRY_RUN=1
                EXPLICIT_DRY_RUN=1
                shift
                ;;
            apply)
                MODE="apply-plan"
                DRY_RUN=0
                shift
                ;;
            --dry-run)
                # Leave MODE alone: enforce_explicit_dry_run maps it to its
                # preview form after parsing, so flag order cannot matter.
                DRY_RUN=1
                EXPLICIT_DRY_RUN=1
                shift
                ;;
            --interactive)
                MODE="interactive"
                DRY_RUN=0
                shift
                ;;
            --auto-safe)
                MODE="auto-safe"
                DRY_RUN=0
                shift
                ;;
            --category|--include)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_cat_req_val")"
                    exit 2
                fi
                add_category_arg "$2"
                shift 2
                ;;
            --exclude)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_exclude_req_val")"
                    exit 2
                fi
                local normalized_exclude
                normalized_exclude="$(normalize_path "$2" || echo "$2")"
                NEVER_TOUCH_PATHS+=("$normalized_exclude")
                EXCLUDED_PATHS+=("$normalized_exclude")
                shift 2
                ;;
            --restore)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_restore_req_val")"
                    exit 2
                fi
                MODE="restore"
                DRY_RUN=0
                RESTORE_TARGET="$2"
                shift 2
                ;;
            --list-quarantine)
                MODE="list-quarantine"
                shift
                ;;
            --prune-artifacts)
                MODE="prune-artifacts"
                shift
                ;;
            --purge-quarantine)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_purge_req_val")"
                    exit 2
                fi
                MODE="purge-quarantine"
                PURGE_TARGET="$2"
                shift 2
                ;;
            --from-plan)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_from_plan_req_val")"
                    exit 2
                fi
                PLAN_FROM_FILE="$2"
                shift 2
                ;;
            --plan-file)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_plan_file_req_val")"
                    exit 2
                fi
                PLAN_FILE="$2"
                shift 2
                ;;
            --include-review)
                INCLUDE_REVIEW=1
                shift
                ;;
            --require-typing-path)
                REQUIRE_TYPING_PATH=1
                shift
                ;;
            --retention-days)
                if [[ -z "${2:-}" || "${2:-}" == *[!0-9]* ]]; then
                    print_error "$(t "cli_retention_req_val")"
                    exit 2
                fi
                RETENTION_DAYS="$2"
                shift 2
                ;;
            --quarantine)
                REMOVE_MODE="quarantine"
                shift
                ;;
            --permanent)
                REMOVE_MODE="permanent"
                shift
                ;;
            --apply)
                APPLY_PURGE=1
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --yes)
                AUTO_YES=1
                shift
                ;;
            --no-color)
                export NO_COLOR=1
                configure_colors
                shift
                ;;
            --log-level)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_log_level_req_val")"
                    exit 2
                fi
                LOG_LEVEL="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
                validate_log_level "$LOG_LEVEL" || {
                    print_error "$(t "cli_unknown_log_level"): ${LOG_LEVEL}. $(t "cli_allowed"): DEBUG|INFO|WARN|ERROR."
                    exit 2
                }
                shift 2
                ;;
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            --redact)
                REDACT_PATHS=1
                shift
                ;;
            --plain)
                PLAIN_OUTPUT=1
                shift
                ;;
            --quiet|-q)
                QUIET_OUTPUT=1
                shift
                ;;
            --lang)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_lang_req_val")"
                    exit 2
                fi
                LANG_CODE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --explain)
                SHOW_EXPLAIN=1
                shift
                ;;
            --help|-h)
                SHOW_HELP=1
                shift
                ;;
            --version|-V)
                SHOW_VERSION=1
                shift
                ;;
            *)
                print_error "$(t "cli_unknown_arg"): $1"
                echo "$(t "cli_see_help")"
                exit 2
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    # Check macOS (require 10.15 Catalina or newer)
    local macos_version
    macos_version=$(sw_vers -productVersion 2>/dev/null || echo "0.0")
    local macos_major
    macos_major=$(echo "$macos_version" | cut -d. -f1)
    local macos_minor
    macos_minor=$(echo "$macos_version" | cut -d. -f2)

    if (( macos_major < 10 )) || { (( macos_major == 10 )) && (( macos_minor < 15 )); }; then
        print_error "$(t "cli_macos_incompatible")."
        print_error "$(t "cli_your_version"): ${macos_version}"
        exit 3
    fi

    # Ensure we're not running as root (would change $HOME and be dangerous)
    if [[ "$(id -u)" -eq 0 ]]; then
        print_error "$(t "cli_no_root")"
        print_error "$(t "cli_sudo_later")"
        exit 1
    fi

    # Create log and report directories
    mkdir -p "$LOGS_DIR" "$REPORTS_DIR"

    # Artifact retention is --prune-artifacts only. Read-only modes that
    # reach preflight (dry-run, plan, --list-quarantine) must not delete
    # aged logs or journals.

    # Apply YAML-driven protected paths and normalize all protected entries.
    load_policy_rules_from_yaml
    apply_policy_never_paths
    load_never_paths_from_rules
    normalize_never_touch_paths

    build_active_categories
    configure_colors
}

# ---------------------------------------------------------------------------
# print_banner — welcome screen
# ---------------------------------------------------------------------------
print_banner() {
    echo
    echo -e "${C_BOLD}${C_BLUE}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════════╗
  ║          macOS Cleanup — Professional System Cleaner      ║
  ╚═══════════════════════════════════════════════════════════╝
BANNER
    echo -e "${C_RESET}"
    echo -e "  $(t "cli_version"):   ${C_BOLD}${SCRIPT_VERSION}${C_RESET}"
    echo -e "  macOS:    ${C_BOLD}$(sw_vers -productVersion 2>/dev/null || echo "$(t "cli_unknown")")${C_RESET}"
    echo -e "  $(t "cli_user_label"): ${C_BOLD}$(whoami)${C_RESET}"
    echo -e "  Log:      ${C_DIM}${LOG_FILE}${C_RESET}"
    echo -e "  $(t "cli_report_label"):   ${C_DIM}${REPORT_FILE}${C_RESET}"
    echo -e "  $(t "cli_plan_label"):     ${C_DIM}${PLAN_FILE}${C_RESET}"
    echo -e "  Journal:  ${C_DIM}${CLEANUP_JOURNAL_FILE}${C_RESET}"
    echo

    case "$MODE" in
        dry-run)
            echo -e "  ${C_YELLOW}$(t "mode_dry_run")${C_RESET}"
            ;;
        plan)
            echo -e "  ${C_YELLOW}$(t "mode_plan")${C_RESET}"
            echo -e "  $(t "cli_plan_label"):     ${C_DIM}${PLAN_FILE}${C_RESET}"
            ;;
        apply-plan)
            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "  ${C_YELLOW}$(t "mode_apply_dry_run")${C_RESET}"
            else
                echo -e "  ${C_GREEN}$(t "mode_apply")${C_RESET}"
            fi
            echo -e "  $(t "cli_plan_label"):     ${C_DIM}${PLAN_FROM_FILE:-"($(t "cli_not_provided"))"}${C_RESET}"
            ;;
        interactive)
            echo -e "  ${C_CYAN}$(t "mode_interactive")${C_RESET}"
            ;;
        auto-safe)
            echo -e "  ${C_GREEN}$(t "mode_auto_safe")${C_RESET}"
            ;;
        restore)
            echo -e "  ${C_CYAN}$(t "mode_restore")${C_RESET}"
            ;;
        list-quarantine)
            echo -e "  ${C_CYAN}$(t "mode_list")${C_RESET}"
            ;;
        purge-quarantine)
            echo -e "  ${C_YELLOW}$(t "mode_purge")${C_RESET}"
            ;;
    esac

    if [[ "$MODE" != "dry-run" && "$MODE" != "restore" && "$MODE" != "list-quarantine" && "$MODE" != "purge-quarantine" ]]; then
        if [[ "$REMOVE_MODE" == "quarantine" ]]; then
            echo -e "  ${C_BOLD}$(t "cli_deletion_mode"):${C_RESET} $(t "cli_quarantine") (${QUARANTINE_RUN_DIR})"
        else
            echo -e "  ${C_BOLD}$(t "cli_deletion_mode"):${C_RESET} $(t "cli_permanent")"
        fi
    fi

    if (( ${#ACTIVE_CATEGORIES[@]} > 0 && ${#ACTIVE_CATEGORIES[@]} < ${#ALL_CATEGORIES[@]} )); then
        echo -e "  ${C_BOLD}$(t "cli_selected_cats"):${C_RESET} ${ACTIVE_CATEGORIES[*]}"
    fi

    if (( ${#EXCLUDED_PATHS[@]} > 0 )); then
        echo -e "  ${C_BOLD}$(t "cli_excluded"):${C_RESET}"
        for p in "${EXCLUDED_PATHS[@]}"; do echo "    $p"; done
    fi

    echo
    log_info "=== cleanup_all.sh v${SCRIPT_VERSION} started ==="
    # bash 3.2 set -u: ${empty_array[*]} is safe but [@] is not; build log string explicitly
    local _cats_log="all"
    if [[ ${#ACTIVE_CATEGORIES[@]} -gt 0 && ${#ACTIVE_CATEGORIES[@]} -lt ${#ALL_CATEGORIES[@]} ]]; then
        _cats_log="${ACTIVE_CATEGORIES[*]}"
    fi
    log_info "Mode: ${MODE}, Remove mode: ${REMOVE_MODE}, Categories: ${_cats_log}"
}

# ---------------------------------------------------------------------------
# run_dry_run_phase — full analysis, generate report, offer to continue
# ---------------------------------------------------------------------------
run_dry_run_phase() {
    print_header "$(t "header_phase1")"
    echo -e "  ${C_DIM}$(t "cli_scanning")${C_RESET}"
    echo

    # Set DRY_RUN for all sub-calls
    DRY_RUN=1

    _run_analyzer analyze_disk_overview
    if _is_full_scan; then
        _run_analyzer analyze_application_inventory
        _run_analyzer analyze_mail_storage
        _run_analyzer analyze_browser_storage
    fi

    run_full_analysis "${ACTIVE_CATEGORIES[@]}"

    # Print category summary
    echo
    print_section "$(t "cli_summary_analysis")"
    # Accumulate grand_total first (avoid subshell from piping to sort)
    local grand_total=0
    for key in "${ALL_KNOWN_CATEGORY_KEYS[@]}"; do
        local bytes; bytes=$(catbytes_get "$key")
        (( bytes == 0 )) && continue
        # time-machine stores a snapshot count, not a byte size
        [[ "$key" == "time-machine" ]] && continue
        grand_total=$(( grand_total + bytes ))
    done
    # Render sorted (size first so -h sort works on whole lines)
    for key in "${ALL_KNOWN_CATEGORY_KEYS[@]}"; do
        local bytes; bytes=$(catbytes_get "$key")
        (( bytes == 0 )) && continue
        if [[ "$key" == "time-machine" ]]; then
            printf "  %10s  %s\n" "${bytes} $(t "cli_units_pcs")" "${key}:"
        else
            printf "  %10s  %s\n" "$(bytes_to_human "$bytes")" "${key}:"
        fi
    done | sort -rh
    echo -e "  ${C_DIM}──────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_BOLD}$(t "cli_total_freeable"): ${C_YELLOW}$(bytes_to_human "$grand_total")${C_RESET}"
    TOTAL_WOULD_FREE_BYTES=$grand_total

    build_cleanup_plan_from_analysis
    generate_plan_json "$PLAN_FILE"

    # Plan mode writes its final report after the JSON plan is available.
    if [[ "$MODE" != "plan" ]]; then
        generate_report "dry-run" "${ACTIVE_CATEGORIES[@]}"
    fi
}

run_plan_phase() {
    run_dry_run_phase
    generate_report "plan" "${ACTIVE_CATEGORIES[@]}"
}

# ---------------------------------------------------------------------------
# run_interactive_phase — clean category by category with confirmations
# ---------------------------------------------------------------------------
run_interactive_phase() {
    print_header "$(t "header_phase2")"
    echo -e "  ${C_DIM}$(t "cli_interact_desc1")${C_RESET}"
    echo -e "  ${C_DIM}$(t "cli_interact_desc2")${C_RESET}"
    echo

    DRY_RUN=0

    run_cleanup "${ACTIVE_CATEGORIES[@]}"

    generate_report "interactive" "${ACTIVE_CATEGORIES[@]}"
}

# ---------------------------------------------------------------------------
# run_auto_safe_phase — clean only "safe"-rated items without asking
# ---------------------------------------------------------------------------
run_auto_safe_phase() {
    print_header "$(t "mode_auto_safe")"
    if [[ "$REMOVE_MODE" == "quarantine" ]]; then
        echo -e "  ${C_DIM}$(t "cli_auto_safe_desc1_q")${C_RESET}"
    else
        echo -e "  ${C_DIM}$(t "cli_auto_safe_desc1")${C_RESET}"
    fi
    echo -e "  ${C_DIM}$(t "cli_auto_safe_desc2")${C_RESET}"
    echo

    DRY_RUN=0

    # Run only safe-rated cleanups.
    # Trash is recoverable user intent, so report it for explicit review.
    if (( ${#FOUND_TRASH_ITEMS[@]} > 0 )); then
        local trash_h
        trash_h=$(bytes_to_human "$(catbytes_get "trash")")
        record_user_decision "$(t "cli_trash"): ${trash_h} — $(t "cli_run_interactive_to_empty")"
    fi

    # Generic user caches are mixed-risk. Only explicitly known app caches below
    # are safe enough for auto-safe; the rest need review.
    if (( ${#FOUND_USER_CACHES[@]} > 0 )); then
        local generic_cache_bytes
        generic_cache_bytes=$(catbytes_get "user-caches")
        record_user_decision "$(t "cli_gen_cache"): $(bytes_to_human "$generic_cache_bytes") — $(t "cli_run_interactive_to_review")"
    fi

    if (( ${#FOUND_APP_CACHE_ITEMS[@]} > 0 )); then
        local auto_app_cache_count=0
        local review_app_cache_count=0
        local review_app_cache_bytes=0

        print_section "$(t "cli_cleaning_auto_safe")"
        for entry in "${FOUND_APP_CACHE_ITEMS[@]}"; do
            local label="${entry%%:*}"
            local path="${entry#*:}"
            [[ -d "$path" ]] || continue
            if app_cache_auto_safe "$label"; then
                safe_remove "$path"
                auto_app_cache_count=$(( auto_app_cache_count + 1 ))
            else
                review_app_cache_count=$(( review_app_cache_count + 1 ))
                review_app_cache_bytes=$(( review_app_cache_bytes + $(path_size_bytes "$path") ))
            fi
        done

        if (( auto_app_cache_count == 0 )); then
            print_skip "$(t "cli_no_safe_caches")"
        fi

        if (( review_app_cache_count > 0 )); then
            record_user_decision "$(t "cli_app_caches_review"): $(bytes_to_human "$review_app_cache_bytes") $(t "cli_in") ${review_app_cache_count} $(t "cli_locations")"
        fi
    fi

    # Tmp files — safe
    if (( ${#FOUND_TMP_FILES[@]} > 0 )); then
        if [[ "$REMOVE_MODE" == "quarantine" ]]; then
            record_user_decision "$(t "cli_tmp_files"): $(bytes_to_human "$(catbytes_get "tmp")") — $(t "cli_use_permanent_to_delete")"
        else
            print_section "$(t "cli_cleaning_tmp")"
            for f in "${FOUND_TMP_FILES[@]}"; do
                safe_remove "$f"
            done
        fi
    fi

    # Old logs — ask even in auto-safe (losing logs has diagnostic value)
    if (( ${#FOUND_APP_LOGS[@]} > 0 || ${#FOUND_SYSTEM_LOGS[@]} > 0 )); then
        local total_log_bytes
        total_log_bytes=$(( $(catbytes_get "user-logs") + $(catbytes_get "system-logs") ))
        record_user_decision "$(t "cli_old_logs"): $(bytes_to_human "$total_log_bytes") — $(t "cli_run_interactive_to_clean")"
    fi

    # Everything else → report as needs-decision
    local needs_decision_cats=("dev" "time-machine" "app-leftovers" "large-files")
    for cat in "${needs_decision_cats[@]}"; do
        local bytes; bytes=$(catbytes_get "$cat")
        (( bytes > 0 )) && {
            record_user_decision "$(t "cli_category") '${cat}': $(bytes_to_human "$bytes") — $(t "cli_run_interactive_to_clean")"
        }
    done
    local system_auto_safe_bytes
    system_auto_safe_bytes=$(catbytes_get "system-caches")
    if (( system_auto_safe_bytes > 0 )); then
        record_user_decision "$(t "cli_system"): $(bytes_to_human "$system_auto_safe_bytes") — $(t "cli_run_interactive_to_clean")"
    fi

    generate_report "auto-safe"
}

# ---------------------------------------------------------------------------
# run_restore_phase — restore files moved to quarantine
# ---------------------------------------------------------------------------
run_restore_phase() {
    print_header "$(t "mode_restore")"

    if ! acquire_cleanup_lock; then
        print_error "Another apply, restore, or purge holds ${QUARANTINE_ROOT}/.apply.lock"
        exit 1
    fi
    trap 'rc=$?; release_cleanup_lock; (exit "$rc"); _on_exit' EXIT

    if [[ -z "$RESTORE_TARGET" ]]; then
        print_error "$(t "cli_no_manifest")"
        exit 2
    fi

    restore_quarantine_manifest "$RESTORE_TARGET"
    generate_report "restore"
}

run_list_quarantine_phase() {
    print_header "$(t "cli_list_quarantine")"
    list_quarantine_runs
    generate_report "list-quarantine"
}

run_purge_quarantine_phase() {
    print_header "$(t "mode_purge")"

    if ! acquire_cleanup_lock; then
        print_error "Another apply, restore, or purge holds ${QUARANTINE_ROOT}/.apply.lock"
        exit 1
    fi
    trap 'rc=$?; release_cleanup_lock; (exit "$rc"); _on_exit' EXIT

    if [[ -z "$PURGE_TARGET" ]]; then
        print_error "$(t "cli_no_purge_target")"
        exit 2
    fi

    if (( APPLY_PURGE != 1 )); then
        print_warn "$(t "cli_purge_preview_warn")"
    else
        warn_if_no_fresh_backup "purge quarantine" || true
    fi

    purge_quarantine "$PURGE_TARGET" "$APPLY_PURGE" "$RETENTION_DAYS"
    if (( APPLY_PURGE == 1 )); then
        generate_report "purge-quarantine"
    fi
}

run_apply_plan_phase() {
    print_header "$(t "mode_apply")"

    if ! acquire_cleanup_lock; then
        print_error "Another apply, restore, or purge holds ${QUARANTINE_ROOT}/.apply.lock"
        exit 1
    fi
    trap 'rc=$?; release_cleanup_lock; (exit "$rc"); _on_exit' EXIT

    if [[ -z "$PLAN_FROM_FILE" ]]; then
        print_error "$(t "cli_apply_requires_plan")"
        exit 2
    fi

    warn_if_no_fresh_backup "apply plan" || true
    apply_plan_file "$PLAN_FROM_FILE"
    generate_report "apply-plan"
}

# ---------------------------------------------------------------------------
# enforce_explicit_dry_run — P0-1: an explicit --dry-run (also analyze/plan) is
# a hard no-delete request whatever the flag order. Mutating modes are mapped to
# their preview form; modes without one are refused.
# ---------------------------------------------------------------------------
enforce_explicit_dry_run() {
    if (( EXPLICIT_DRY_RUN != 1 )); then
        # Purge/prune only mutate when explicitly requested; is_dry_run must
        # not block them then.
        case "$MODE" in
            purge-quarantine) (( APPLY_PURGE == 1 )) && DRY_RUN=0 ;;
            prune-artifacts)  DRY_RUN=0 ;;
        esac
        return 0
    fi

    DRY_RUN=1
    case "$MODE" in
        interactive|auto-safe)
            print_warn "--dry-run overrides --${MODE}: analysis only, nothing is removed."
            MODE="dry-run"
            ;;
        purge-quarantine)
            if (( APPLY_PURGE == 1 )); then
                print_warn "--dry-run overrides --apply: purge preview only, nothing is removed."
            fi
            APPLY_PURGE=0
            ;;
        restore|prune-artifacts)
            print_error "--dry-run cannot be combined with --${MODE}: it has no preview form."
            exit 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# main — entry point
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Handle informational flags first (no logging needed)
    if (( SHOW_HELP )); then    show_help;    exit 0; fi
    if (( SHOW_VERSION )); then show_version; exit 0; fi
    if (( SHOW_EXPLAIN )); then explain_categories; exit 0; fi

    enforce_explicit_dry_run

    # P0-3: fail closed on misconfiguration before any mode runs.
    validate_remove_mode || exit 2
    validate_quarantine_root || exit 2

    preflight_checks

    if [[ "$MODE" == "prune-artifacts" ]]; then
        local _pruned
        _pruned="$(rotate_old_artifacts "${ARTIFACT_RETENTION_DAYS:-30}")"
        case "${_pruned}" in
            ''|*[!0-9]*) _pruned=0 ;;
        esac
        print_info "$(t "cli_pruned_artifacts" "$_pruned" "${ARTIFACT_RETENTION_DAYS:-30}")"
        exit 0
    fi

    # --json: redirect all human-readable output (fd 1) to stderr so that
    # only the JSON summary reaches the caller's stdout.  We stash the
    # original fd 1 in JSON_OUTPUT_FD so emit_json_summary can use it.
    if (( JSON_OUTPUT )); then
        exec 3>&1 1>&2
        JSON_OUTPUT_FD=3
    fi

    print_banner

    case "$MODE" in
        # ---------------------------------------------------------------
        # DEFAULT: dry-run → summary → offer to continue interactively
        # ---------------------------------------------------------------
        dry-run)
            run_dry_run_phase

            # Progressive model: no-arg TTY runs may offer cleanup. Explicit
            # dry-run and automation are hard no-delete modes.
            echo
            if (( EXPLICIT_DRY_RUN == 1 || NON_INTERACTIVE == 1 )); then
                print_info "$(t "cli_report_saved_dryrun")"
                echo
                echo -e "  ${C_BOLD}bash cleanup_all.sh --interactive${C_RESET}   # $(t "cli_full_interactive")"
                echo -e "  ${C_BOLD}bash cleanup_all.sh --auto-safe${C_RESET}      # $(t "cli_auto_safe_only")"
                echo
            elif ask_proceed_to_interactive; then
                MODE="dry-run-then-interactive"
                DRY_RUN=0
                run_interactive_phase
            else
                echo
                print_info "$(t "cli_report_saved_next")"
                echo
                echo -e "  ${C_BOLD}bash cleanup_all.sh --interactive${C_RESET}   # $(t "cli_full_interactive")"
                echo -e "  ${C_BOLD}bash cleanup_all.sh --auto-safe${C_RESET}      # $(t "cli_auto_safe_only")"
                echo
            fi
            ;;

        plan)
            run_plan_phase
            ;;

        # ---------------------------------------------------------------
        # Interactive: dry-run phase + immediate per-category confirmation
        # ---------------------------------------------------------------
        interactive)
            # Always show analysis first
            run_dry_run_phase

            echo
            print_info "$(t "cli_analysis_complete")"
            echo

            MODE="dry-run-then-interactive"
            DRY_RUN=0
            warn_if_no_fresh_backup "interactive cleanup" || true
            run_interactive_phase
            ;;

        # ---------------------------------------------------------------
        # Auto-safe: dry-run then clean safe items automatically
        # ---------------------------------------------------------------
        auto-safe)
            run_dry_run_phase

            echo
            print_warn "$(t "cli_auto_safe_warn")"
            echo
            if ask_yes_no "$(t "cli_auto_safe_prompt")" "no"; then
                warn_if_no_fresh_backup "auto-safe cleanup" || true
                run_auto_safe_phase
            else
                print_skip "$(t "cli_auto_safe_cancelled")"
                generate_report "dry-run"
            fi
            ;;

        restore)
            run_restore_phase
            ;;

        apply-plan)
            run_apply_plan_phase
            ;;

        list-quarantine)
            run_list_quarantine_phase
            ;;

        purge-quarantine)
            run_purge_quarantine_phase
            ;;
    esac

    print_summary_report "$MODE"

    # --json: emit machine-readable summary to original stdout (fd JSON_OUTPUT_FD).
    if (( JSON_OUTPUT )); then
        emit_json_summary "$MODE" >&${JSON_OUTPUT_FD}
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main "$@"
