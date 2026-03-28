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

# Keep the most specific tail of a long purge path visible on the live scan line.
compact_purge_scan_path() {
    local path="$1"
    local max_path_len="${2:-0}"

    if ! [[ "$max_path_len" =~ ^[0-9]+$ ]] || [[ "$max_path_len" -lt 4 ]]; then
        max_path_len=4
    fi

    if [[ ${#path} -le $max_path_len ]]; then
        echo "$path"
        return
    fi

    local suffix_len=$((max_path_len - 3))
    local suffix="${path: -$suffix_len}"
    local path_tail=""
    local remainder="$path"

    while [[ "$remainder" == */* ]]; do
        local segment="/${remainder##*/}"
        remainder="${remainder%/*}"

        if [[ -z "$path_tail" ]]; then
            if [[ ${#segment} -le $suffix_len ]]; then
                path_tail="$segment"
            else
                break
            fi
            continue
        fi

        if [[ $((${#segment} + ${#path_tail})) -le $suffix_len ]]; then
            path_tail="${segment}${path_tail}"
        else
            break
        fi
    done

    if [[ -n "$path_tail" ]]; then
        echo "...${path_tail}"
        return
    fi

    echo "...$suffix"
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
            printf '\r\033[2K\n' > /dev/tty 2> /dev/null || true
        fi
    }

    # Ensure Ctrl-C/TERM always stops spinner(s) and exits immediately.
    handle_interrupt() {
        cleanup_monitor
        stop_inline_spinner 2> /dev/null || true
        show_cursor 2> /dev/null || true
        printf '\n' >&2
        exit 130
    }

    # Set up trap for cleanup + abort
    trap handle_interrupt INT TERM

    # Show scanning with spinner below the title line
    if [[ -t 1 ]]; then
        # Print title ONCE with newline; spinner occupies the line below
        printf '%s\n' "${PURPLE_BOLD}$(mole_t "Purge Project Artifacts")${NC}"

        # Capture terminal width in parent (most reliable before forking)
        local _parent_cols=80
        local _stty_out
        if _stty_out=$(stty size < /dev/tty 2> /dev/null); then
            _parent_cols="${_stty_out##* }" # "rows cols" -> take cols
        else
            _parent_cols=$(tput cols 2> /dev/null || echo 80)
        fi
        [[ "$_parent_cols" =~ ^[0-9]+$ && $_parent_cols -gt 0 ]] || _parent_cols=80

        # Start background monitor: writes directly to /dev/tty to avoid stdout state issues
        (
            local spinner_chars="|/-\\"
            local spinner_idx=0
            local last_path=""
            # Use parent-captured width; never refresh inside the loop (avoids unreliable tput in bg)
            local term_cols="$_parent_cols"
            # Visible prefix "| Scanning " = 11 chars; reserve 25 total for safety margin
            local max_path_len=$((term_cols - 25))
            ((max_path_len < 5)) && max_path_len=5

            # Set up trap to exit cleanly (erase the spinner line via /dev/tty)
            trap 'printf "\r\033[2K" >/dev/tty 2>/dev/null; exit 0' INT TERM

            while [[ -f "$stats_dir/purge_scanning" ]]; do
                local current_path
                current_path=$(cat "$stats_dir/purge_scanning" 2> /dev/null || echo "")

                if [[ -n "$current_path" ]]; then
                    local display_path="${current_path/#$HOME/~}"
                    display_path=$(compact_purge_scan_path "$display_path" "$max_path_len")
                    last_path="$display_path"
                fi

                local spin_char="${spinner_chars:$spinner_idx:1}"
                spinner_idx=$(((spinner_idx + 1) % ${#spinner_chars}))

                # Write directly to /dev/tty: \033[2K clears entire current line, \r goes to start
                if [[ -n "$last_path" ]]; then
                    printf '\r\033[2K%s %s%s %s%s' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}" "$(mole_t "Scanning")" "$last_path" "${NC}" > /dev/tty 2> /dev/null
                else
                    printf '\r\033[2K%s %s%s...%s' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}" "$(mole_t "Scanning")" "${NC}" > /dev/tty 2> /dev/null
                fi

                sleep 0.05
            done
            printf '\r\033[2K' > /dev/tty 2> /dev/null
            exit 0
        ) &
        monitor_pid=$!
    else
        echo -e "${PURPLE_BOLD}$(mole_t "Purge Project Artifacts")${NC}"
    fi

    clean_project_artifacts
    local exit_code=$?

    # Clean up
    trap - INT TERM
    cleanup_monitor

    # Exit codes:
    # 0 = success, show summary
    # 1 = user cancelled
    # 2 = nothing to clean
    if [[ $exit_code -ne 0 ]]; then
        return 0
    fi

    # Final summary (matching clean.sh format)
    echo ""

    local summary_heading
    summary_heading="$(mole_t "Purge complete")"
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

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        summary_heading="$(mole_t "Dry run complete - no changes made")"
    fi

    if [[ $total_size_cleaned -gt 0 ]]; then
        local freed_size_human
        freed_size_human=$(bytes_to_human_kb "$total_size_cleaned")

        local summary_line="$(mole_t "Space freed:") ${GREEN}${freed_size_human}${NC}"
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            summary_line="$(mole_t "Would free:") ${GREEN}${freed_size_human}${NC}"
        fi
        [[ $total_items_cleaned -gt 0 ]] && summary_line+=" | $(mole_t "Items:") $total_items_cleaned"
        summary_line+=" | $(mole_t "Free:") $(get_free_space)"
        summary_details+=("$summary_line")
    else
        summary_details+=("$(mole_t "No old project artifacts to clean.")")
        summary_details+=("$(mole_t "Free space:") $(get_free_space)")
    fi

    # Log session end
    log_operation_session_end "purge" "${total_items_cleaned:-0}" "${total_size_cleaned:-0}"

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

# Show help message
show_help() {
    echo -e "${PURPLE_BOLD}$(mole_t "Mole Purge")${NC}, $(mole_t "Clean old project build artifacts")"
    echo ""
    echo -e "${YELLOW}$(mole_t "Usage:")${NC} mo purge [$(mole_t "options")]"
    echo ""
    echo -e "${YELLOW}$(mole_t "Options:")${NC}"
    echo "  --paths         $(mole_t "Edit custom scan directories")"
    echo "  --dry-run       $(mole_t "Preview purge actions without making changes")"
    echo "  --debug         $(mole_t "Enable debug logging")"
    echo "  --help          $(mole_t "Show this help message")"
    echo ""
    echo -e "${YELLOW}$(mole_t "Default Paths:")${NC}"
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        echo "  * $path"
    done
}

# Main entry point
main() {
    # Set up signal handling
    trap 'show_cursor; exit 130' INT TERM

    # Parse arguments
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
                export MOLE_DRY_RUN=1
                ;;
            *)
                printf "$(mole_t "Unknown option: %s")\n" "$arg"
                echo "$(mole_t "Use 'mo purge --help' for usage information")"
                exit 1
                ;;
        esac
    done

    start_purge
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} $(mole_t "DRY RUN MODE, No project artifacts will be removed")${NC}"
        printf '\n'
    fi
    hide_cursor
    perform_purge
    show_cursor
}

if [[ "${MOLE_SKIP_MAIN:-0}" == "1" ]]; then
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 0
    else
        exit 0
    fi
fi

main "$@"
