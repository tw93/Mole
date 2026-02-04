#!/bin/bash
# Mole - Purge command.
# Cleans heavy project build artifacts.
# Interactive selection by project.
# Supports JSON output for UI integration.

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/core/json_output.sh"

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

    # Cleanup function
    cleanup_monitor() {
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

# Show help message
show_help() {
    echo -e "${PURPLE_BOLD}Mole Purge${NC}, Clean old project build artifacts"
    echo ""
    echo -e "${YELLOW}Usage:${NC} mo purge [options]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --paths         Edit custom scan directories"
    echo "  --dry-run       Scan only, do not delete"
    echo "  --format json   Output machine-readable JSON (implies --dry-run)"
    echo "  --json          Alias for --format json"
    echo "  --debug         Enable debug logging"
    echo "  --help          Show this help message"
    echo ""
    echo -e "${YELLOW}Default Paths:${NC}"
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        echo "  * $path"
    done
}

# JSON Output Mode Functions

# Scan for purgeable artifacts and output as JSON
perform_purge_json() {
    json_reset
    json_set_category "Project Artifacts"

    # Get search paths
    local -a search_paths=()
    if [[ -f "$PURGE_CONFIG_FILE" ]]; then
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            [[ "$line" == ~* ]] && line="${line/#~/$HOME}"
            [[ -d "$line" ]] && search_paths+=("$line")
        done < "$PURGE_CONFIG_FILE"
    fi

    if [[ ${#search_paths[@]} -eq 0 ]]; then
        for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
            [[ -d "$path" ]] && search_paths+=("$path")
        done
    fi

    if [[ ${#search_paths[@]} -eq 0 ]]; then
        json_add_warning "No project directories found to scan"
        json_output_purge "true"
        return 0
    fi

    # Scan for artifacts
    local now
    now=$(get_epoch_seconds)
    local min_age_seconds=$((MIN_AGE_DAYS * 86400))

    for search_path in "${search_paths[@]}"; do
        [[ ! -d "$search_path" ]] && continue

        for target in "${PURGE_TARGETS[@]}"; do
            while IFS= read -r artifact_path; do
                [[ -z "$artifact_path" ]] && continue
                [[ ! -d "$artifact_path" ]] && continue

                # Check age
                local mtime
                mtime=$(get_file_mtime "$artifact_path")
                [[ ! "$mtime" =~ ^[0-9]+$ ]] && continue

                local age_seconds=$((now - mtime))
                [[ $age_seconds -lt $min_age_seconds ]] && continue

                # Get size
                local size_kb
                size_kb=$(get_path_size_kb "$artifact_path" 2> /dev/null || echo "0")
                [[ ! "$size_kb" =~ ^[0-9]+$ ]] && size_kb=0
                [[ $size_kb -eq 0 ]] && continue

                # Get project name from parent
                local project_dir
                project_dir=$(dirname "$artifact_path")
                local project_name
                project_name=$(basename "$project_dir")

                # Create description
                local description="$project_name/$target"
                local age_days=$((age_seconds / 86400))

                # Determine tags based on artifact type
                local tags=""
                case "$target" in
                    node_modules | .next | .nuxt | dist | .turbo | .parcel-cache)
                        tags="nodejs,frontend"
                        ;;
                    target)
                        if [[ -f "$project_dir/Cargo.toml" ]]; then
                            tags="rust"
                        else
                            tags="java,maven"
                        fi
                        ;;
                    venv | .venv | __pycache__ | .pytest_cache | .mypy_cache | .tox | .nox | .ruff_cache)
                        tags="python"
                        ;;
                    build | .gradle)
                        tags="java,gradle"
                        ;;
                    vendor)
                        tags="php"
                        ;;
                    .dart_tool)
                        tags="flutter,dart"
                        ;;
                    .zig-cache | zig-out)
                        tags="zig"
                        ;;
                    .angular | .svelte-kit | .astro)
                        tags="frontend"
                        ;;
                    *)
                        tags="build"
                        ;;
                esac

                # Add item
                json_add_item "$description ($age_days days old)" "$size_kb" "$artifact_path" "false"

            done < <(find "$search_path" -maxdepth "$PURGE_MAX_DEPTH_DEFAULT" -mindepth "$PURGE_MIN_DEPTH_DEFAULT" \
                -type d -name "$target" \
                -not -path "*/.*/*" \
                -not -path "*/.git/*" \
                2> /dev/null || true)
        done
    done

    # Output JSON
    json_output_purge "true"
}

# Main entry point
main() {
    # Set up signal handling
    trap 'show_cursor; exit 130' INT TERM

    local output_format="human"
    local dry_run=false

    # Parse arguments
    local prev_arg=""
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
            "--format=json" | "--json")
                output_format="json"
                export MOLE_JSON_OUTPUT="true"
                ;;
            "--format="*)
                output_format="${arg#--format=}"
                if [[ "$output_format" == "json" ]]; then
                    export MOLE_JSON_OUTPUT="true"
                fi
                ;;
            "--format")
                # Next arg will be the format
                ;;
            *)
                # Check if this is the value for --format
                if [[ "$prev_arg" == "--format" ]]; then
                    output_format="$arg"
                    if [[ "$output_format" == "json" ]]; then
                        export MOLE_JSON_OUTPUT="true"
                    fi
                else
                    echo "Unknown option: $arg"
                    echo "Use 'mo purge --help' for usage information"
                    exit 1
                fi
                ;;
        esac
        prev_arg="$arg"
    done

    # JSON output mode
    if [[ "$output_format" == "json" ]]; then
        perform_purge_json
        exit 0
    fi

    start_purge
    hide_cursor
    perform_purge
    show_cursor
}

main "$@"
