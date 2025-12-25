#!/bin/bash
# Mole - Project purge command (mo purge)
# Remove old project build artifacts and dependencies

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/core/log.sh"
source "$SCRIPT_DIR/../lib/clean/project.sh"

# Configuration
CURRENT_SECTION=""

# Section management
start_section() {
    local section_name="$1"
    CURRENT_SECTION="$section_name"
    printf '\n'
    echo -e "${BLUE}━━━ ${section_name} ━━━${NC}"
}

end_section() {
    CURRENT_SECTION=""
}

# Note activity for export list
note_activity() {
    if [[ -n "$CURRENT_SECTION" ]]; then
        printf '%s\n' "$CURRENT_SECTION" >> "$EXPORT_LIST_FILE"
    fi
}

# Main purge function
start_purge() {
    # Clear screen for better UX
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n'
    echo -e "${PURPLE_BOLD}Purge Project Artifacts${NC}"

    # Initialize stats file in user cache directory
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    ensure_user_dir "$stats_dir"
    ensure_user_file "$stats_dir/purge_stats"
    ensure_user_file "$stats_dir/purge_count"
    echo "0" > "$stats_dir/purge_stats"
    echo "0" > "$stats_dir/purge_count"
}

# Perform the purge
perform_purge() {
    clean_project_artifacts
    local exit_code=$?

    # Exit codes:
    # 0 = success, show summary
    # 1 = user cancelled
    # 2 = nothing to clean
    if [[ $exit_code -ne 0 ]]; then
        return 0
    fi

    # Final summary (matching clean.sh format)
    echo ""

    local summary_heading="Purge complete"
    local -a summary_details=()
    local total_size_cleaned=0
    local total_items_cleaned=0

    # Read stats from user cache directory
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"

    if [[ -f "$stats_dir/purge_stats" ]]; then
        total_size_cleaned=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
        rm -f "$stats_dir/purge_stats"
    fi

    # Read count
    if [[ -f "$stats_dir/purge_count" ]]; then
        total_items_cleaned=$(cat "$stats_dir/purge_count" 2> /dev/null || echo "0")
        rm -f "$stats_dir/purge_count"
    fi

    if [[ $total_size_cleaned -gt 0 ]]; then
        local freed_gb
        freed_gb=$(echo "$total_size_cleaned" | awk '{printf "%.2f", $1/1024/1024}')

        summary_details+=("Space freed: ${GREEN}${freed_gb}GB${NC}")
        summary_details+=("Free space now: $(get_free_space)")

        if [[ $total_items_cleaned -gt 0 ]]; then
            summary_details+=("Items cleaned: $total_items_cleaned")
        fi
    else
        summary_details+=("No old project artifacts to clean.")
        summary_details+=("Free space now: $(get_free_space)")
    fi

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

# Main entry point
main() {
    # Set up signal handling
    trap 'show_cursor; exit 130' INT TERM

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            "--debug")
                export MO_DEBUG=1
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Use 'mo --help' for usage information"
                exit 1
                ;;
        esac
    done

    start_purge
    hide_cursor
    perform_purge
    show_cursor
}

main "$@"
