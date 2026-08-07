# i18n/en.sh — English localization dictionary for macOS_cleanup (Bash 3.2 compatible)

i18n_get_en() {
    case "${1:-}" in
        banner_title) echo "macOS Cleanup — Professional System Cleaner" ;;
        mode_dry_run) echo "Mode: ANALYSIS (dry-run) — nothing will be deleted" ;;
        mode_plan) echo "Mode: PLAN (plan) — execution plan generated" ;;
        mode_quarantine) echo "Mode: QUARANTINE (quarantine) — files moved to quarantine" ;;
        mode_permanent) echo "Mode: PERMANENT REMOVAL (permanent) — files will be deleted permanently" ;;
        disk_overview) echo "Disk Overview" ;;
        user_caches) echo "User Caches" ;;
        app_caches) echo "Application Caches" ;;
        developer_env) echo "Developer Environment" ;;
        system_caches) echo "System Caches (/Library/Caches)" ;;
        trash) echo "Trash" ;;
        total_potential) echo "Total space that can be freed" ;;
        *) return 1 ;;
    esac
}
