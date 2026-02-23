#!/bin/bash
# Mole - Purge command.
# Cleans heavy project build artifacts.
# Interactive selection by project.

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

# Set up cleanup trap for temporary files
trap cleanup_temp_files EXIT INT TERM
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
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="purge"
    log_operation_session_start "purge"

    # Clear screen for better UX
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n'

    # Initialize stats file in user cache directory
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    ensure_user_dir "$stats_dir"
    ensure_user_file "$stats_dir/purge_stats"
    ensure_user_file "$stats_dir/purge_count"
    ensure_user_file "$stats_dir/purge_scanning"
    echo "0" > "$stats_dir/purge_stats"
    echo "0" > "$stats_dir/purge_count"
    echo "" > "$stats_dir/purge_scanning"
}

# Perform the purge
perform_purge() {
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    local monitor_pid=""

    # Cleanup function - use flag to prevent duplicate execution
    _cleanup_done=false
    cleanup_monitor() {
        # Prevent multiple cleanup executions from trap conflicts
        [[ "$_cleanup_done" == "true" ]] && return
        _cleanup_done=true

        # Remove scanning file to stop monitor
        rm -f "$stats_dir/purge_scanning" 2> /dev/null || true

        if [[ -n "$monitor_pid" ]]; then
            kill "$monitor_pid" 2> /dev/null || true
            wait "$monitor_pid" 2> /dev/null || true
        fi
        if [[ -t 1 ]]; then
            printf '\r\033[K\n\033[K\033[A'
        fi
    }

    # Set up trap for cleanup
    trap cleanup_monitor INT TERM

    # Show scanning with spinner on same line as title
    if [[ -t 1 ]]; then
        # Print title first
        printf '%s' "${PURPLE_BOLD}Purge Project Artifacts${NC} "

        # Start background monitor with ASCII spinner
        (
            local spinner_chars="|/-\\"
            local spinner_idx=0
            local last_path=""

            # Set up trap to exit cleanly
            trap 'exit 0' INT TERM

            # Function to truncate path in the middle
            truncate_path() {
                local path="$1"
                local term_cols
                term_cols=$(tput cols 2> /dev/null || echo 80)
                # Reserve some space for the spinner and text (approx 20 chars)
                local max_len=$((term_cols - 20))
                # Ensure a reasonable minimum width
                if ((max_len < 40)); then
                    max_len=40
                fi

                if [[ ${#path} -le $max_len ]]; then
                    echo "$path"
                    return
                fi

                # Calculate how much to show on each side
                local side_len=$(((max_len - 3) / 2))
                local start="${path:0:$side_len}"
                local end="${path: -$side_len}"
                echo "${start}...${end}"
            }

            while [[ -f "$stats_dir/purge_scanning" ]]; do
                local current_path=$(cat "$stats_dir/purge_scanning" 2> /dev/null || echo "")
                local display_path=""

                if [[ -n "$current_path" ]]; then
                    display_path="${current_path/#$HOME/~}"
                    display_path=$(truncate_path "$display_path")
                    last_path="$display_path"
                elif [[ -n "$last_path" ]]; then
                    display_path="$last_path"
                fi

                # Get current spinner character
                local spin_char="${spinner_chars:$spinner_idx:1}"
                spinner_idx=$(((spinner_idx + 1) % ${#spinner_chars}))

                # Show title on first line, spinner and scanning info on second line
                if [[ -n "$display_path" ]]; then
                    # Line 1: Move to start, clear, print title
                    printf '\r\033[K%s\n' "${PURPLE_BOLD}Purge Project Artifacts${NC}"
                    # Line 2: Move to start, clear, print scanning info
                    printf '\r\033[K%s %sScanning %s' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}" "$display_path"
                    # Move up THEN to start (important order!)
                    printf '\033[A\r'
                else
                    printf '\r\033[K%s\n' "${PURPLE_BOLD}Purge Project Artifacts${NC}"
                    printf '\r\033[K%s %sScanning...' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}"
                    printf '\033[A\r'
                fi

                sleep 0.05
            done
            exit 0
        ) &
        monitor_pid=$!
    else
        echo -e "${PURPLE_BOLD}Purge Project Artifacts${NC}"
    fi

    clean_project_artifacts
    local exit_code=$?

    # Clean up
    trap - INT TERM
    cleanup_monitor

    if [[ -t 1 ]]; then
        echo -e "${PURPLE_BOLD}Purge Project Artifacts${NC}"
    fi

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

    if [[ -f "$stats_dir/purge_stats" ]]; then
        total_size_cleaned=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
        rm -f "$stats_dir/purge_stats"
    fi

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

    # Log session end
    log_operation_session_end "purge" "${total_items_cleaned:-0}" "${total_size_cleaned:-0}"

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

# Dry-run: scan and list all artifacts without interactive menu
perform_purge_dry_run() {
    export MOLE_PURGE_DRY_RUN=1
    clean_project_artifacts
    local exit_code=$?
    unset MOLE_PURGE_DRY_RUN
    return $exit_code
}

# Show help message
show_help() {
    echo -e "${PURPLE_BOLD}Mole Purge${NC}, Clean old project build artifacts"
    echo ""
    echo -e "${YELLOW}Usage:${NC} mo purge [options]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --dry-run, -n   List all project artifacts without interactive menu"
    echo "  --paths         Edit custom scan directories"
    echo "  --debug         Enable debug logging"
    echo "  --help          Show this help message"
    echo ""
    echo -e "${YELLOW}Default Paths:${NC}"
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        echo "  * $path"
    done
}

# Main entry point
main() {
    # Set up signal handling
    trap 'show_cursor; exit 130' INT TERM

    # Parse arguments
    local dry_run=false
    for arg in "$@"; do
        case "$arg" in
            "--paths")
                source "$SCRIPT_DIR/../lib/manage/purge_paths.sh"
                manage_purge_paths
                exit 0
                ;;
            "--help")
                show_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                dry_run=true
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Use 'mo purge --help' for usage information"
                exit 1
                ;;
        esac
    done

    if [[ $dry_run == true ]]; then
        export MOLE_PURGE_DRY_RUN=1
        start_purge
        perform_purge_dry_run
        return 0
    fi

    start_purge
    hide_cursor
    perform_purge
    show_cursor
}

main "$@"
