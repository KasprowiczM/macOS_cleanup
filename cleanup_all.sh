#!/usr/bin/env bash
# =============================================================================
# cleanup_all.sh — Professional macOS System Cleaner
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
#   plan                  Analyze and write a machine-readable plan.json in the run folder
#   apply --from-plan P   Apply a plan; default executes SAFE operations only
#   --interactive         Ask for confirmation before each category
#   --auto-safe           Remove only explicitly safe app caches/tmp, ask for the rest
#   --category <name>     Only process the specified section or category id
#                         Sections: trash | system | user-caches | logs |
#                                 app-leftovers | dev | time-machine | large-files
#   --only <id[,id]>      Only these category ids (combinable with every mode)
#   --unattended          Scheduled run: quarantine only the categories whose
#                         mode is auto, then purge expired quarantine
#   --exclude <path>      Add a path to the exclusion list (repeatable)
#   --include <category>  Alias of --category
#   --restore <run_id|latest|file>
#                         Restore files from a quarantine run (latest = newest restorable run);
#                         with --dry-run it only previews (add --json for the preview object)
#   --items-file <file>   With --restore: restore only these original paths (one per line)
#   --list-quarantine     List quarantine runs
#   --prune-artifacts     Delete aged run folders under the state dir (artifact_retention_days; 0 disables)
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
#   --cli                  Plain text mode (accepted; the default for this script)
#   --tui                  Require the terminal interface (exit 2 without a terminal; combinable only
#                          with --dry-run). A run without arguments on a terminal opens it too
#   --non-interactive      Run without tty prompts (recommended for CI)
#   --yes                  Auto-confirm SAFE risk categories only (use with --non-interactive)
#   --no-color             Disable colored output
#   --log-level <level>   DEBUG | INFO | WARN | ERROR (default: INFO)
#   --json                Print machine-readable JSON run summary to stdout
#   --redact              Hide user name, home path and host name in the report,
#                         --json summary, log and journal (the plan file and the
#                         restore manifest keep real paths: apply and restore need them)
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

# v4 standalone commands (--doctor, --history, ...): 255 means "not mine".
if [ -f "$SCRIPT_DIR/lib/cli_v4.sh" ]; then . "$SCRIPT_DIR/lib/cli_v4.sh"; mc_early_rc=0; mc_cli_early "$@" || mc_early_rc=$?; [ "$mc_early_rc" -eq 255 ] || exit "$mc_early_rc"; fi

# V4 5.1: the terminal interface. A run without arguments on a terminal and
# --tui go through mc_tui_route (lib/tui.sh); --cli, any other argument and the
# marker the interface sets on the engine runs it spawns never do. A started
# interface (or a refusal) decides the exit status; mc_tui_route returning 0
# alone means "continue in the plain CLI" only while MC_TUI_STARTED is not 1.
# The engine's traps have nothing to clean up yet and must not fire while the
# interface owns the terminal: drop them, and put them back for the CLI.
if [ "${MACOS_CLEANUP_TUI_CHILD:-0}" != 1 ] && [ -f "$SCRIPT_DIR/lib/tui.sh" ]; then
    . "$SCRIPT_DIR/lib/tui.sh"
    mc_tui_traps="$(trap -p)"
    trap - EXIT ERR INT TERM
    mc_tui_rc=0
    mc_tui_route "$@" || mc_tui_rc=$?
    if [ "${MC_TUI_STARTED:-0}" = 1 ]; then exit "$mc_tui_rc"; fi
    if [ -n "$mc_tui_traps" ]; then eval "$mc_tui_traps"; fi
fi

# ---------------------------------------------------------------------------
# User settings: <config>/settings.conf (whitelisted KEY=VALUE, parsed, never
# sourced). Precedence: CLI flag > MACOS_CLEANUP_* env > legacy env > file >
# default; CLI flags are parsed below and simply overwrite. Problems are
# collected and printed once the run folder exists (mc_flush_startup_warnings).
# ---------------------------------------------------------------------------
mc_load_settings

# ---------------------------------------------------------------------------
# Runtime state (set by argument parsing)
# ---------------------------------------------------------------------------
MODE="${DEFAULT_MODE}"          # dry-run | interactive | auto-safe
DRY_RUN=1                       # 1 = don't delete, 0 = delete (set by mode)
EXPLICIT_DRY_RUN=0              # --dry-run is a hard no-delete request
SELECTED_CATEGORIES=()          # Empty = all categories (sections or ids)
ONLY_IDS=()                     # --only: category ids
UNATTENDED=0                    # --unattended
SAW_PERMANENT=0                 # --permanent was given (refused with --unattended)
SAW_INTERACTIVE=0               # --interactive was given (refused with --unattended)
ACTIVE_CATEGORIES=()            # Real category list used at runtime
EXCLUDED_PATHS=()               # Extra paths to exclude
RESTORE_TARGET=""               # run id, latest, or manifest path
RESTORE_ITEMS_FILE=""           # --items-file: selective restore (V4 12.1)
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
# Set by apply/restore/purge so _on_exit can report a run that fails early.
REPORT_PENDING_MODE=""
SUMMARY_PENDING=0
# When --json is active this fd points to the original stdout so the
# JSON summary reaches the caller even though fd 1 is redirected to stderr.
JSON_OUTPUT_FD=1
SUDO_KEEPALIVE_PID=""
RUN_STARTED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"
RUN_EXIT_CODE=0

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

add_only_arg() {
    local raw="$1"
    local old_ifs="$IFS"
    local token
    IFS=','
    for token in $raw; do
        token="$(printf '%s' "$token" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$token" ]] && continue
        ONLY_IDS+=("$token")
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

# _active_add_section <section> — once, in the order given.
_active_add_section() {
    local s
    if (( ${#ACTIVE_CATEGORIES[@]} > 0 )); then
        for s in "${ACTIVE_CATEGORIES[@]}"; do
            [[ "$s" == "$1" ]] && return 0
        done
    fi
    ACTIVE_CATEGORIES+=("$1")
}

# build_active_categories — ACTIVE_CATEGORIES (the sections to analyze) and
# EXEC_ONLY_IDS (the category ids the plan may hold; empty = all). --category
# takes sections and ids; --only takes ids only; both given = intersection.
build_active_categories() {
    local cat id ids_from_category="" restrict_category=0 only=""
    ACTIVE_CATEGORIES=()
    EXEC_ONLY_IDS=""
    registry_require

    if (( ${#ONLY_IDS[@]} > 0 )); then
        for id in "${ONLY_IDS[@]}"; do
            if ! reg_is_id "$id"; then
                print_error "$(t "unknown_category" "'${id}'")"
                echo "$(t cli_only_ids) $(reg_ids | tr '\n' ' ')"
                exit 2
            fi
            only="${only}${id}"$'\n'
        done
    fi

    if (( ${#SELECTED_CATEGORIES[@]} > 0 )); then
        for cat in "${SELECTED_CATEGORIES[@]}"; do
            if reg_is_section "$cat" && [[ "$cat" != "overview" ]]; then
                _active_add_section "$cat"
                while IFS= read -r id; do
                    [[ -n "$id" ]] && ids_from_category="${ids_from_category}${id}"$'\n'
                done < <(reg_ids "$cat")
            elif reg_is_id "$cat"; then
                reg_get "$cat" section
                if [[ "$REPLY" == "overview" ]]; then
                    print_error "$(t "unknown_category" "'${cat}'")"
                    exit 2
                fi
                _active_add_section "$REPLY"
                ids_from_category="${ids_from_category}${cat}"$'\n'
                restrict_category=1
            else
                print_error "$(t "unknown_category" "'${cat}'")"
                echo "$(t "cli_avail_cats"): ${ALL_CATEGORIES[*]}"
                exit 2
            fi
        done
    fi

    if [[ -n "$only" ]]; then
        if (( ${#SELECTED_CATEGORIES[@]} > 0 )); then
            # Intersection with what --category selected.
            local both=""
            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                case $'\n'"${ids_from_category}" in *$'\n'"${id}"$'\n'*) both="${both}${id}"$'\n' ;; esac
            done <<< "$only"
            EXEC_ONLY_IDS="${both:-__none__}"
        else
            EXEC_ONLY_IDS="$only"
            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                reg_get "$id" section
                [[ "$REPLY" == "overview" ]] || _active_add_section "$REPLY"
            done <<< "$only"
        fi
    elif (( restrict_category == 1 )); then
        EXEC_ONLY_IDS="$ids_from_category"
    fi

    # If no explicit categories were passed, run all.
    if (( ${#ACTIVE_CATEGORIES[@]} == 0 )); then
        ACTIVE_CATEGORIES=("${ALL_CATEGORIES[@]}")
    fi
}

# ---------------------------------------------------------------------------
# Signal / exit handlers
# ---------------------------------------------------------------------------
_on_exit() {
    local exit_code=$?
    release_cleanup_lock
    # A failing apply, restore or purge exits before main prints its summary;
    # still write the report, the summary and the --json object.
    if (( exit_code != 0 )) && (( ${SUMMARY_PENDING:-0} == 1 )); then
        SUMMARY_PENDING=0
        set +e
        if [[ -n "${REPORT_PENDING_MODE:-}" ]]; then
            generate_report "$REPORT_PENDING_MODE" >/dev/null 2>&1
        fi
        print_summary_report "$MODE" 2>/dev/null
        if (( JSON_OUTPUT )); then
            emit_json_summary "$MODE" 2>/dev/null 1>&"${JSON_OUTPUT_FD}"
        fi
    fi
    if type remove_plan_temp_files >/dev/null 2>&1; then
        remove_plan_temp_files
    fi
    # <state>/runs/<run_id>/run.json is written for every run that got as far
    # as preparing its run directory, success or not.
    RUN_EXIT_CODE="$exit_code"
    write_run_json || true
    _mc_events_end "$exit_code" || true
    cleanup_sudo_keepalive
    if (( exit_code == 0 )); then
        log_info "Script completed successfully (exit 0)."
    fi
    # bash 3.2 ends with the trap's own status after a `set -u` abort; keep
    # the run's status (an aborted cleanup must not exit 0).
    exit "$exit_code"
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
    echo "macos-cleanup ${SCRIPT_VERSION}"
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
                SAW_INTERACTIVE=1
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
            --only)
                if [[ -z "${2:-}" ]]; then
                    print_error "$(t "cli_cat_req_val")"
                    exit 2
                fi
                add_only_arg "$2"
                shift 2
                ;;
            --unattended)
                MODE="unattended"
                UNATTENDED=1
                DRY_RUN=0
                NON_INTERACTIVE=1
                shift
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
            --items-file)
                if [[ -z "${2:-}" ]]; then
                    print_error "--items-file needs a file of original paths (one per line)."
                    exit 2
                fi
                RESTORE_ITEMS_FILE="$2"
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
                SAW_PERMANENT=1
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
            --cli|--tui) shift ;;   # routing happened before parse_args (mc_tui_route)
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
                _redact_init
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
# Startup: run directory and legacy-override notices
# ---------------------------------------------------------------------------
# require_valid_paths — a setting that selects a toolkit folder is unusable
# (relative path, quarantine dir off the HOME volume, run dir outside the
# quarantine dir ...): one sentence, exit 2, before anything is written.
require_valid_paths() {
    if (( ${MC_PATHS_INIT_RC:-0} != 0 )); then
        print_error "${MC_PATHS_ERROR:-The toolkit folders cannot be resolved.}"
        exit 2
    fi
}

# prepare_run_artifacts — create <state>/runs/<run_id>/ (0700), the legacy
# override directories, and point the size memo at this run. Logs the use of
# deprecated variables once.
prepare_run_artifacts() {
    if ! mc_ensure_dir run "$RUN_TIMESTAMP" >/dev/null; then
        print_error "${MC_PATHS_ERROR:-The run folder cannot be created.}"
        exit 2
    fi
    if [[ -n "${MC_LEGACY_LOGS_DIR:-}" ]]; then
        mkdir -p "$MC_LEGACY_LOGS_DIR"
    fi
    if [[ -n "${MC_LEGACY_REPORTS_DIR:-}" ]]; then
        mkdir -p "$MC_LEGACY_REPORTS_DIR"
    fi

    # Phase 2: analyzer sizes are reused by the plan and the prompts.
    # Removed on exit by remove_plan_temp_files.
    SIZE_MEMO_FILE="$MC_SIZE_MEMO_FILE"

    local legacy="${MC_LEGACY_VARS_USED:-}"
    if [[ -n "${MC_JOURNAL_FILE_OVERRIDE:-}" ]]; then
        legacy="${legacy:+${legacy} }CLEANUP_JOURNAL_FILE"
    fi
    if [[ -n "$legacy" ]]; then
        log_warn "Deprecated variable(s) in use: ${legacy}. Use MACOS_CLEANUP_STATE_DIR / MACOS_CLEANUP_QUARANTINE_DIR; the legacy names are honoured for 4.x."
    fi
    log_info "Run folder: ${MC_RUN_DIR} (paths mode: ${MC_PATHS_MODE})"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    # A bad --category is a usage error: refuse it before any file is created.
    build_active_categories
    _mc_events_begin
    mc_phase preflight start

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

    # Create this run's directory under the state dir (and the legacy
    # LOGS_DIR / REPORTS_DIR when those overrides are set).
    prepare_run_artifacts

    # Artifact retention is --prune-artifacts only. Read-only modes that
    # reach preflight (dry-run, plan, --list-quarantine) must not delete
    # aged logs or journals.

    # The toolkit's own folders are never cleanup targets (V4 section 1.1).
    NEVER_TOUCH_PATHS+=("$MC_PROGRAM_DIR" "$MC_CONFIG_DIR" "$MC_STATE_DIR" "$MC_QUARANTINE_DIR")

    # User layer (V4 section 5.3): excludes.txt joins the protected paths,
    # rules.local.yaml may only raise risk, category-modes.tsv is validated.
    mc_load_excludes
    mc_load_category_modes

    # Apply YAML-driven protected paths and normalize all protected entries.
    load_policy_rules_from_yaml
    mc_apply_rules_overlay
    apply_policy_never_paths
    load_never_paths_from_rules
    normalize_never_touch_paths

    configure_colors
    mc_flush_startup_warnings
    _mc_listed clean && mc_disk_space before
    mc_phase preflight end ok
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
    if [[ "${REDACT_PATHS:-0}" == "1" ]]; then
        echo -e "  $(t "cli_user_label"): ${C_BOLD}(redacted)${C_RESET}"
    else
        echo -e "  $(t "cli_user_label"): ${C_BOLD}$(whoami)${C_RESET}"
    fi
    echo -e "  Log:      ${C_DIM}$(redact_path "$LOG_FILE")${C_RESET}"
    echo -e "  $(t "cli_report_label"):   ${C_DIM}$(redact_path "$REPORT_FILE")${C_RESET}"
    echo -e "  $(t "cli_plan_label"):     ${C_DIM}$(redact_path "$PLAN_FILE")${C_RESET}"
    echo -e "  Journal:  ${C_DIM}$(redact_path "$CLEANUP_JOURNAL_FILE")${C_RESET}"
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
            # The apply phase prints its own "Apply Cleanup Plan" heading right after this block.
            if [[ "$DRY_RUN" == "1" ]]; then
                echo -e "  ${C_YELLOW}$(t "mode_apply_dry_run")${C_RESET}"
            fi
            echo -e "  $(t "cli_plan_label"):     ${C_DIM}${PLAN_FROM_FILE:-"($(t "cli_not_provided"))"}${C_RESET}"
            ;;
        interactive)
            echo -e "  ${C_CYAN}$(t "mode_interactive")${C_RESET}"
            ;;
        auto-safe)
            echo -e "  ${C_GREEN}$(t "mode_auto_safe")${C_RESET}"
            ;;
        restore|list-quarantine|purge-quarantine)
            # Their phase prints the title as a heading straight after the banner: say it once.
            ;;
    esac

    if [[ "$MODE" != "dry-run" && "$MODE" != "restore" && "$MODE" != "list-quarantine" && "$MODE" != "purge-quarantine" ]]; then
        if [[ "$REMOVE_MODE" == "quarantine" && "$MODE" == "plan" ]]; then
            # A plan moves nothing, so there is no quarantine folder to name.
            echo -e "  ${C_BOLD}$(t "cli_deletion_mode"):${C_RESET} $(t "cli_quarantine")"
        elif [[ "$REMOVE_MODE" == "quarantine" ]]; then
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

    # E-B: scan-phase group events (mc_group_start <id> scan, group_sized)
    # come from the analyzers (marker in lib/analyzer.sh).
    mc_phase scan start
    _run_analyzer analyze_disk_overview
    if _is_full_scan; then
        _run_analyzer analyze_application_inventory
        _run_analyzer analyze_mail_storage
        _run_analyzer analyze_browser_storage
    fi

    run_full_analysis "${ACTIVE_CATEGORIES[@]}"
    mc_phase scan end ok

    # P1-1: the headline is the plan's executable sum, not the ledger total.
    # The ledger counted Homebrew twice (cache + brew-stale) and included
    # /tmp and /Library/Logs work that the quarantine mode always skips.
    _mc_listed plan && mc_phase plan start
    build_cleanup_plan_from_analysis
    plan_record_headline_totals

    # Print category summary
    echo
    print_section "$(t "cli_summary_analysis")"
    # Render sorted (size first so -h sort works on whole lines)
    for key in "${ALL_KNOWN_CATEGORY_KEYS[@]}"; do
        local bytes; bytes=$(catbytes_get "$key")
        (( bytes == 0 )) && continue
        if [[ "$(category_class "$key")" == "count" ]]; then
            printf "  %10s  %s\n" "${bytes} $(t "cli_units_pcs")" "${key}:"
        else
            printf "  %10s  %s\n" "$(bytes_to_human "$bytes")" "${key}:"
        fi
    done | sort -rh
    echo -e "  ${C_DIM}──────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_BOLD}$(headline_total_label): ${C_YELLOW}$(bytes_to_human "$TOTAL_WOULD_FREE_BYTES")${C_RESET}"
    if (( TOTAL_INFORMATIONAL_BYTES > 0 )); then
        echo -e "  ${C_DIM}$(t "cli_report_only_total"): $(bytes_to_human "$TOTAL_INFORMATIONAL_BYTES")${C_RESET}"
    fi

    generate_plan_json "$PLAN_FILE"
    _mc_listed plan && mc_phase plan end ok

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
# require_cleanup_lock — every mutating mode holds ${QUARANTINE_ROOT}/.apply.lock,
# or exits 1. P1-7: interactive and auto-safe used to run unlocked, so a
# concurrent `--purge-quarantine latest` could delete the run they were filling.
# ---------------------------------------------------------------------------
require_cleanup_lock() {
    if ! acquire_cleanup_lock; then
        print_error "Another cleanup run (apply, restore, purge, interactive or auto-safe) holds ${QUARANTINE_ROOT}/.apply.lock"
        exit 1
    fi
    # set +e: under errexit `(exit "$rc")` with rc != 0 would end the trap
    # before _on_exit (temp files, sudo keepalive) ever ran.
    trap 'rc=$?; release_cleanup_lock; set +e; (exit "$rc"); _on_exit' EXIT
}

# ---------------------------------------------------------------------------
# run_interactive_phase — the plan through the single executor, consent per
# v3 prompt group (R07)
# ---------------------------------------------------------------------------
run_interactive_phase() {
    print_header "$(t "header_phase2")"
    echo -e "  ${C_DIM}$(t "cli_interact_desc1")${C_RESET}"
    echo -e "  ${C_DIM}$(t "cli_interact_desc2")${C_RESET}"
    echo

    require_cleanup_lock
    DRY_RUN=0

    executor_run interactive

    generate_report "interactive" "${ACTIVE_CATEGORIES[@]}"
}

# ---------------------------------------------------------------------------
# run_auto_clean_phase <auto|unattended> — the plan through the single
# executor; only categories in mode auto (regenerable + quarantine) run (§13)
# ---------------------------------------------------------------------------
run_auto_clean_phase() {
    local provider="$1"
    print_header "$(t "mode_auto_safe")"
    if [[ "$REMOVE_MODE" == "quarantine" ]]; then
        echo -e "  ${C_DIM}$(t "cli_auto_safe_desc1_q")${C_RESET}"
    else
        echo -e "  ${C_DIM}$(t "cli_auto_safe_desc1")${C_RESET}"
    fi
    echo -e "  ${C_DIM}$(t "cli_auto_safe_desc2")${C_RESET}"
    echo

    require_cleanup_lock
    DRY_RUN=0

    executor_run "$provider"

    if [[ "$provider" == "unattended" ]]; then
        # V4 §2.2: an unattended run then purges expired quarantine.
        purge_quarantine expired 1 "$RETENTION_DAYS" || true
    fi
    generate_report "$MODE"
}

# validate_unattended_flags — V4 §2.2: --unattended implies --non-interactive
# --quarantine and refuses --permanent, --include-review and --interactive.
validate_unattended_flags() {
    (( UNATTENDED == 1 )) || return 0
    if (( SAW_PERMANENT == 1 || INCLUDE_REVIEW == 1 || SAW_INTERACTIVE == 1 )); then
        print_error "$(t cli_unattended_conflict)"
        exit 2
    fi
    MODE="unattended"
    NON_INTERACTIVE=1
    AUTO_YES=0
    REMOVE_MODE="quarantine"
}

# enforce_apply_remove_mode — F3: apply --from-plan deletes permanently only
# when --permanent is on its own command line. remove_mode=permanent from
# settings.conf (or --permanent given for an earlier, other purpose) never turns
# a plan apply into permanent deletion.
enforce_apply_remove_mode() {
    [[ "$MODE" == "apply-plan" ]] || return 0
    [[ "$REMOVE_MODE" == "permanent" ]] || return 0
    (( SAW_PERMANENT == 1 )) && return 0
    REMOVE_MODE="quarantine"
    mc_startup_warn "apply: remove_mode=permanent from settings is ignored for a plan; add --permanent to the command to delete permanently."
}

# ---------------------------------------------------------------------------
# run_restore_phase — restore files moved to quarantine
# ---------------------------------------------------------------------------
run_restore_phase() {
    print_header "$(t "mode_restore")"

    if [[ -z "$RESTORE_TARGET" ]]; then
        print_error "$(t "cli_no_manifest")"
        exit 2
    fi

    # --restore ... --dry-run: the preview changes nothing, needs no lock and
    # prints (with --json: only) the preview object of V4 section 12.1.
    if (( EXPLICIT_DRY_RUN == 1 )); then
        if (( JSON_OUTPUT )); then
            restore_preview "$RESTORE_TARGET" 1 >&"${JSON_OUTPUT_FD}" || exit 2
        else
            restore_preview "$RESTORE_TARGET" 0 || exit 2
        fi
        exit 0
    fi

    require_cleanup_lock

    REPORT_PENDING_MODE="restore"; SUMMARY_PENDING=1

    # A restore writes into HOME: never from a pipe against the real home.
    (( EXPLICIT_DRY_RUN == 1 )) || mc_consent_guard "restore"
    # The restore pseudo-group (one item per manifest row) is emitted by
    # restore_quarantine_manifest.
    mc_phase clean start
    restore_quarantine_manifest "$RESTORE_TARGET"
    if (( ${RESTORE_INCOMPLETE:-0} == 1 )); then mc_phase clean end warn; else mc_phase clean end ok; fi
    REPORT_PENDING_MODE=""
    generate_report "restore"
    # P2: a restore that left rows behind is not a success.
    if (( RESTORE_INCOMPLETE == 1 )); then
        print_warn "Restore incomplete: some entries were not restored (see the report)."
        exit 1
    fi
}

run_list_quarantine_phase() {
    print_header "$(t "cli_list_quarantine")"
    list_quarantine_runs
}

run_purge_quarantine_phase() {
    print_header "$(t "mode_purge")"

    require_cleanup_lock

    if [[ -z "$PURGE_TARGET" ]]; then
        print_error "$(t "cli_no_purge_target")"
        exit 2
    fi

    if (( APPLY_PURGE != 1 )); then
        print_warn "$(t "cli_purge_preview_warn")"
    else
        warn_if_no_fresh_backup "purge quarantine" || true
    fi

    SUMMARY_PENDING=1
    (( APPLY_PURGE == 1 )) && REPORT_PENDING_MODE="purge-quarantine"
    (( APPLY_PURGE == 1 )) && mc_consent_guard "purge"
    # The purge pseudo-group: one item per quarantine run (items from
    # purge_one_quarantine_run).
    local purge_t0=$SECONDS purge_rc=0
    if _mc_listed clean; then mc_phase clean start; mc_group_start purge clean; fi
    purge_quarantine "$PURGE_TARGET" "$APPLY_PURGE" "$RETENTION_DAYS" || purge_rc=$?
    if _mc_listed clean; then
        mc_group_end purge clean $(( SECONDS - purge_t0 ))
        if (( purge_rc == 0 )); then mc_phase clean end ok; else mc_phase clean end error; fi
    fi
    (( purge_rc == 0 )) || return "$purge_rc"
    REPORT_PENDING_MODE=""
    if (( APPLY_PURGE == 1 )); then
        generate_report "purge-quarantine"
    fi
}

run_apply_plan_phase() {
    print_header "$(t "mode_apply")"

    require_cleanup_lock

    REPORT_PENDING_MODE="apply-plan"; SUMMARY_PENDING=1
    if [[ -z "$PLAN_FROM_FILE" ]]; then
        print_error "$(t "cli_apply_requires_plan")"
        exit 2
    fi

    # F3/F7: an apply removes things, so it passes the same consent guard as
    # every other mutating run; a preview (--dry-run) changes nothing.
    (( EXPLICIT_DRY_RUN == 1 )) || mc_consent_guard "apply"

    warn_if_no_fresh_backup "apply plan" || true
    # scan and plan are not run for apply: mc_phases_close ends them skipped.
    apply_plan_file "$PLAN_FROM_FILE"
    REPORT_PENDING_MODE=""
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
        interactive|auto-safe|unattended)
            print_warn "--dry-run overrides --${MODE}: analysis only, nothing is removed."
            MODE="dry-run"
            ;;
        purge-quarantine)
            if (( APPLY_PURGE == 1 )); then
                print_warn "--dry-run overrides --apply: purge preview only, nothing is removed."
            fi
            APPLY_PURGE=0
            ;;
        restore)
            # --restore --dry-run is the restore preview (run_restore_phase).
            ;;
        prune-artifacts)
            print_error "--dry-run cannot be combined with --${MODE}: it has no preview form."
            exit 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Event channel (MACOS_CLEANUP_EVENT_FILE, V4 §3 and §11). run_start is the
# first event of a run that has an action; every phase listed in it gets
# exactly one end (mc_phases_close ends the ones that never ran as skipped);
# run_end is the last event (from _on_exit, also on errors and interrupts).
# Modes without an action (previews of restore/purge, listings, prune) emit
# nothing.
# ---------------------------------------------------------------------------
MC_RUN_STARTED=0
MC_RUN_PHASES=""

# _mc_listed <phase> — 0 when this run's run_start listed the phase.
_mc_listed() {
    (( MC_RUN_STARTED == 1 )) || return 1
    case " ${MC_RUN_PHASES} " in *" ${1} "*) return 0 ;; esac
    return 1
}

# _mc_events_begin — action and phases per contract §11; groups are the
# registry ids of the active sections (and --only). Called from
# preflight_checks once the categories are known.
_mc_events_begin() {
    local id phases="" groups="" k sec action=""
    local full="preflight scan plan clean verify report"
    case "$MODE" in
        dry-run)
            if (( EXPLICIT_DRY_RUN == 1 || NON_INTERACTIVE == 1 )); then
                action="scan";       phases="preflight scan report"
            else
                # a default run may go on to an interactive clean
                action="clean_selected"; phases="$full"
            fi ;;
        plan)            action="preview";        phases="preflight scan plan report" ;;
        interactive)     action="clean_selected"; phases="$full" ;;
        auto-safe|unattended) action="clean_safe"; phases="$full" ;;
        apply-plan)      action="apply_plan";     phases="$full" ;;
        restore)
            (( EXPLICIT_DRY_RUN == 1 )) && return 0
            action="restore"; phases="preflight clean verify report"; groups="restore" ;;
        purge-quarantine)
            (( APPLY_PURGE == 1 && EXPLICIT_DRY_RUN != 1 )) || return 0
            action="purge";   phases="preflight clean verify report"; groups="purge" ;;
        *) return 0 ;;
    esac
    mc_events_init
    [[ "${MC_EVENTS_ON:-0}" == 1 ]] || return 0
    if [[ -z "$groups" ]]; then
        for (( k=0; k<REG_COUNT; k++ )); do
            id="${REG_ID[$k]}"
            reg_get "$id" section; sec="$REPLY"
            if (( ${#ACTIVE_CATEGORIES[@]} > 0 )); then
                case " ${ACTIVE_CATEGORIES[*]} " in *" ${sec} "*) ;; *) continue ;; esac
            fi
            plan_category_allowed "$id" || continue
            groups="${groups} ${id}"
        done
    fi
    mc_run_start "$MODE" "${REMOVE_MODE:-quarantine}" "${DRY_RUN:-1}" "${groups# }" "$action" "$phases"
    MC_RUN_STARTED=1
    MC_RUN_PHASES="$phases"
}

# _mc_verify_phase — after the work: disk space after, verify ends ok.
_mc_verify_phase() {
    _mc_listed verify || return 0
    mc_phase verify start
    mc_disk_space after
    mc_phase verify end ok
}

# _mc_events_end <exit_code> — close open phases, then run_end (from _on_exit).
_mc_events_end() {
    local code="${1:-0}" res freed=""
    [[ "${MC_EVENTS_ON:-0}" == 1 && "${MC_RUN_STARTED:-0}" == 1 ]] || return 0
    # The same result run.json records (lib/json_summary.sh).
    case "$code" in
        0)   res="ok"
             if [ "${WARNINGS_LIST+set}" = "set" ] && (( ${#WARNINGS_LIST[@]} > 0 )); then res="warn"; fi ;;
        130) res="cancelled" ;;
        1)   res="error"
             # A restore that only skipped rows whose place is taken did not fail.
             if [[ "${MODE:-}" == "restore" && "${RESTORE_INCOMPLETE:-0}" == "1" && "${RESTORE_HARD_FAIL:-0}" != "1" ]]; then res="warn"; fi ;;
        *)   res="error" ;;
    esac
    case "$res" in
        ok|warn)   mc_phases_close ok ;;
        cancelled) mc_phases_close warn ;;
        *)         mc_phases_close error ;;
    esac
    (( ${DRY_RUN:-1} == 0 )) && freed="${TOTAL_CLEANED_BYTES:-0}"
    mc_run_end "$res" "$code" "${TOTAL_WOULD_FREE_BYTES:-0}" "$freed" "${TOTAL_QUARANTINED_BYTES:-0}"
    MC_RUN_STARTED=0
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

    require_valid_paths
    if [[ -n "$RESTORE_ITEMS_FILE" && "$MODE" != "restore" ]]; then
        print_error "--items-file only works together with --restore."
        exit 2
    fi
    validate_unattended_flags
    enforce_apply_remove_mode
    enforce_explicit_dry_run
    # F16: a no-argument run without a terminal is a read-only scan and report;
    # it asks no removal question, so it can neither be refused nor answered.
    if [[ "$MODE" == "dry-run" ]] && (( EXPLICIT_DRY_RUN == 0 )) && [[ ! -t 0 ]]; then
        NON_INTERACTIVE=1
    fi

    # P0-3: fail closed on misconfiguration before any mode runs.
    validate_remove_mode || exit 2
    validate_quarantine_root || exit 2
    validate_quarantine_run_dir || exit 2

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

    # Events: run_start and the preflight phase come from preflight_checks,
    # scan/plan from run_dry_run_phase, clean from the executor (or the
    # restore/purge phases), verify and report below, run_end from _on_exit.
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
                echo -e "  ${C_BOLD}macos-cleanup clean${C_RESET}          # $(t "cli_full_interactive")"
                echo -e "  ${C_BOLD}macos-cleanup clean --safe${C_RESET}   # $(t "cli_auto_safe_only")"
                echo
            elif ask_proceed_to_interactive; then
                MODE="dry-run-then-interactive"
                DRY_RUN=0
                run_interactive_phase
            else
                echo
                print_info "$(t "cli_report_saved_next")"
                echo
                echo -e "  ${C_BOLD}macos-cleanup clean${C_RESET}          # $(t "cli_full_interactive")"
                echo -e "  ${C_BOLD}macos-cleanup clean --safe${C_RESET}   # $(t "cli_auto_safe_only")"
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
            print_info "$(t "cli_auto_safe_warn")"
            echo
            if consent_auto_confirm; then
                warn_if_no_fresh_backup "auto-safe cleanup" || true
                run_auto_clean_phase auto
            else
                print_skip "$(t "cli_auto_safe_cancelled")"
                generate_report "dry-run"
            fi
            ;;

        # ---------------------------------------------------------------
        # Unattended: analysis, then only the categories in mode auto
        # (quarantine), never a native command, then purge expired.
        # ---------------------------------------------------------------
        unattended)
            run_dry_run_phase
            run_auto_clean_phase unattended
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

    _mc_verify_phase
    _mc_listed report && mc_phase report start
    print_summary_report "$MODE"

    SUMMARY_PENDING=0
    # --json: emit machine-readable summary to original stdout (fd JSON_OUTPUT_FD).
    if (( JSON_OUTPUT )); then
        emit_json_summary "$MODE" >&${JSON_OUTPUT_FD}
    fi
    _mc_listed report && mc_phase report end ok
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main "$@"
