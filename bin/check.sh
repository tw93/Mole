#!/bin/bash

set -euo pipefail

# Fix locale issues (similar to Issue #83)
export LC_ALL=C
export LANG=C

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/core/sudo.sh"
source "$SCRIPT_DIR/lib/manage/update.sh"
source "$SCRIPT_DIR/lib/manage/autofix.sh"

source "$SCRIPT_DIR/lib/check/all.sh"

cleanup_all() {
    stop_inline_spinner 2> /dev/null || true
    stop_sudo_session
    cleanup_temp_files
}

handle_interrupt() {
    cleanup_all
    exit 130
}

main() {
    # Register unified cleanup handler
    trap cleanup_all EXIT
    trap handle_interrupt INT TERM

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            "--debug")
                export MO_DEBUG=1
                ;;
            "-h" | "--help")
                echo -e "Usage: mo check [OPTIONS]"
                echo ""
                echo "Run system health checks, security audits, and configuration validation."
                echo ""
                echo "Options:"
                echo "  --debug           Show detailed operation logs"
                echo "  -h, --help        Show this help message"
                exit 0
                ;;
        esac
    done

    if [[ -t 1 ]]; then
        clear
    fi

    printf '\n'

    # Create temp files for parallel execution
    local updates_file=$(mktemp_file)
    local health_file=$(mktemp_file)
    local security_file=$(mktemp_file)
    local config_file=$(mktemp_file)

    # Run all checks in parallel with spinner
    if [[ -t 1 ]]; then
        echo -ne "${PURPLE_BOLD}System Check${NC}  "
        start_inline_spinner "Running checks..."
    else
        echo -e "${PURPLE_BOLD}System Check${NC}"
        echo ""
    fi

    # Parallel execution
    {
        check_all_updates > "$updates_file" 2>&1 &
        check_system_health > "$health_file" 2>&1 &
        check_all_security > "$security_file" 2>&1 &
        check_all_config > "$config_file" 2>&1 &
        wait
    }

    if [[ -t 1 ]]; then
        stop_inline_spinner
        printf '\n'
    fi

    # Display results
    echo -e "${BLUE}${ICON_ARROW}${NC} System updates"
    cat "$updates_file"

    printf '\n'
    echo -e "${BLUE}${ICON_ARROW}${NC} System health"
    cat "$health_file"

    printf '\n'
    echo -e "${BLUE}${ICON_ARROW}${NC} Security posture"
    cat "$security_file"

    printf '\n'
    echo -e "${BLUE}${ICON_ARROW}${NC} Configuration"
    cat "$config_file"

    # Show suggestions
    show_suggestions

    # Ask about auto-fix
    if ask_for_auto_fix; then
        perform_auto_fix
    fi

    # Ask about updates
    if ask_for_updates; then
        perform_updates
    fi

    printf '\n'
}

main "$@"
