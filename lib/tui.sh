#!/usr/bin/env bash
# Shared routing for the optional terminal interface (Bash 3.2 compatible).
#
#   mc_tui_route <args...>
#
# Returns 0 to continue in the plain CLI; any other status is the caller's exit
# status (the interface ran, or a refusal message was printed). It sets
# MC_TUI_STARTED=1 when the interface was started or refused. The view to open
# comes from MC_TUI_VIEW (default: dashboard).
#
# Rules:
#   --cli                      always the plain CLI
#   child marker               MACOS_CLEANUP_TUI_CHILD=1 never routes (no recursion)
#   no arguments + a terminal  the interface
#   --tui [--dry-run]          the interface; other options: message "options", exit 2
#   --tui without a terminal, or with --non-interactive: message "terminal", exit 2
#   interface unavailable      with --tui exit 2; otherwise one "fallback" line and the CLI
#
# SCRIPT_DIR must name the program directory (the folder that has lib/python).

mc_tui_message() {
    local reason="$1" lang="${MACOS_CLEANUP_LANG:-}" line key value
    if [ -z "$lang" ]; then
        local conf="${MACOS_CLEANUP_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/macos-cleanup}/settings.conf"
        if [ -f "$conf" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                key="${line%%=*}"
                value="${line#*=}"
                if [ "$key" = MACOS_CLEANUP_LANG ]; then
                    lang="$value"
                    break
                fi
            done < "$conf"
        fi
    fi
    if [ -z "$lang" ]; then
        case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
            pl*) lang=pl ;; de*) lang=de ;; es*) lang=es ;; fr*) lang=fr ;; it*) lang=it ;; pt*) lang=pt ;;
        esac
    fi
    # shellcheck disable=SC1112 # the typographic apostrophe is part of the French message
    case "${lang:-en}:$reason" in
        pl:terminal) echo 'Interfejs terminalowy wymaga terminala.' ;;
        pl:options) echo 'Opcję --tui można łączyć tylko z --dry-run.' ;;
        pl:unavailable) echo 'Interfejs terminalowy jest niedostępny.' ;;
        pl:fallback) echo 'Interfejs terminalowy jest niedostępny. Uruchamianie trybu CLI.' ;;
        de:terminal) echo 'Die Terminaloberfläche benötigt ein Terminal.' ;;
        de:options) echo '--tui kann nur mit --dry-run kombiniert werden.' ;;
        de:unavailable) echo 'Terminaloberfläche nicht verfügbar.' ;;
        de:fallback) echo 'Terminaloberfläche nicht verfügbar. CLI wird gestartet.' ;;
        fr:terminal) echo 'Un terminal est nécessaire pour cette interface.' ;;
        fr:options) echo '--tui ne peut être associé qu’à --dry-run.' ;;
        fr:unavailable) echo 'Interface terminal indisponible.' ;;
        fr:fallback) echo 'Interface terminal indisponible. Démarrage du CLI.' ;;
        es:terminal) echo 'Esta interfaz necesita un terminal.' ;;
        es:options) echo '--tui solo se puede combinar con --dry-run.' ;;
        es:unavailable) echo 'Interfaz de terminal no disponible.' ;;
        es:fallback) echo 'Interfaz de terminal no disponible. Se inicia el CLI.' ;;
        it:terminal) echo 'Questa interfaccia richiede un terminale.' ;;
        it:options) echo '--tui può essere combinato solo con --dry-run.' ;;
        it:unavailable) echo 'Interfaccia terminale non disponibile.' ;;
        it:fallback) echo 'Interfaccia terminale non disponibile. Avvio della CLI.' ;;
        pt:terminal) echo 'Esta interface requer um terminal.' ;;
        pt:options) echo '--tui só pode ser combinado com --dry-run.' ;;
        pt:unavailable) echo 'Interface de terminal indisponível.' ;;
        pt:fallback) echo 'Interface de terminal indisponível. A iniciar a CLI.' ;;
        *:terminal) echo 'A terminal is required for the terminal interface.' ;;
        *:options) echo '--tui can only be combined with --dry-run.' ;;
        *:unavailable) echo 'Terminal interface unavailable.' ;;
        *) echo 'Terminal interface unavailable. Starting the plain CLI.' ;;
    esac >&2
}

# Python 3.9 or newer, found on PATH (never installs anything).
mc_tui_python_usable() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1
}

# shellcheck disable=SC2034 # MC_TUI_STARTED is read by the caller (bin/macos-cleanup)
mc_tui_route() {
    local arg explicit=0 force_cli=0 other=0 noninteractive=0 dry=0 view="${MC_TUI_VIEW:-dashboard}" count=0
    MC_TUI_STARTED=0
    for arg in "$@"; do
        count=$((count + 1))
        case "$arg" in
            --tui) explicit=1 ;;
            --cli) force_cli=1 ;;
            --dry-run) dry=1 ;;
            --non-interactive) noninteractive=1; other=1 ;;
            *) other=1 ;;
        esac
    done
    [ "$force_cli" = 1 ] && return 0
    [ "${MACOS_CLEANUP_TUI_CHILD:-0}" = 1 ] && return 0
    if [ "$explicit" = 1 ] && [ "$other" = 1 ] && [ "$noninteractive" = 0 ]; then
        mc_tui_message options
        MC_TUI_STARTED=1
        return 2
    fi
    if [ "$explicit" = 0 ]; then
        [ "$count" -eq 0 ] || return 0
        [ "${NON_INTERACTIVE:-0}" != 1 ] || return 0
        [ -t 0 ] && [ -t 1 ] || return 0
    elif [ "$noninteractive" = 1 ] || ! [ -t 0 ] || ! [ -t 1 ]; then
        mc_tui_message terminal
        MC_TUI_STARTED=1
        return 2
    fi
    if [ "${TERM:-dumb}" = dumb ] || ! mc_tui_python_usable ||
       ! python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import curses, terminal_app' "$SCRIPT_DIR/lib/python" >/dev/null 2>&1; then
        if [ "$explicit" = 1 ]; then
            mc_tui_message unavailable
            MC_TUI_STARTED=1
            return 2
        fi
        mc_tui_message fallback
        return 0
    fi
    MC_TUI_STARTED=1
    if [ "$dry" = 1 ]; then
        python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from terminal_app import run; sys.exit(run(*sys.argv[2:]))' "$SCRIPT_DIR/lib/python" "$SCRIPT_DIR" "$view" --dry-run
    else
        python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from terminal_app import run; sys.exit(run(*sys.argv[2:]))' "$SCRIPT_DIR/lib/python" "$SCRIPT_DIR" "$view"
    fi
}
