# i18n/pl.sh — Polish localization dictionary for macOS_cleanup (Bash 3.2 compatible)

i18n_get_pl() {
    case "${1:-}" in
        banner_title) echo "macOS Cleanup — Professional System Cleaner" ;;
        mode_dry_run) echo "Tryb: ANALIZA (dry-run) — nic nie zostanie usunięte" ;;
        mode_plan) echo "Tryb: PLAN (plan) — utworzono plan wykonania" ;;
        mode_quarantine) echo "Tryb: KWARANTANNA (quarantine) — pliki trafiają do kwarantanny" ;;
        mode_permanent) echo "Tryb: TRWAŁE USUWANIE (permanent) — pliki zostaną trwale usunięte" ;;
        disk_overview) echo "Przegląd dysku" ;;
        user_caches) echo "Cache użytkownika" ;;
        app_caches) echo "Cache konkretnych aplikacji" ;;
        developer_env) echo "Środowisko developerskie" ;;
        system_caches) echo "Cache systemowe (/Library/Caches)" ;;
        trash) echo "Kosz (Trash)" ;;
        total_potential) echo "Łącznie potencjalnie do zwolnienia" ;;
        *) return 1 ;;
    esac
}
