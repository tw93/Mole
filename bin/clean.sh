#!/bin/bash
# Mole - Deeper system cleanup
# Complete cleanup with smart password handling

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/core/sudo.sh"
source "$SCRIPT_DIR/../lib/clean/brew.sh"
source "$SCRIPT_DIR/../lib/clean/caches.sh"
source "$SCRIPT_DIR/../lib/clean/apps.sh"
source "$SCRIPT_DIR/../lib/clean/dev.sh"
source "$SCRIPT_DIR/../lib/clean/app_caches.sh"
source "$SCRIPT_DIR/../lib/clean/system.sh"
source "$SCRIPT_DIR/../lib/clean/user.sh"

SYSTEM_CLEAN=false
DRY_RUN=false
PROTECT_FINDER_METADATA=false
IS_M_SERIES=$([[ "$(uname -m)" == "arm64" ]] && echo "true" || echo "false")

EXPORT_LIST_FILE="$HOME/.config/mole/clean-list.txt"
CURRENT_SECTION=""
readonly PROTECTED_SW_DOMAINS=(
    "capcut.com"
    "photopea.com"
    "pixlr.com"
)

declare -a WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
if [[ -f "$HOME/.config/mole/whitelist" ]]; then
    while IFS= read -r line; do
        # shellcheck disable=SC2295
        line="${line#"${line%%[![:space:]]*}"}"
        # shellcheck disable=SC2295
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        [[ "$line" == ~* ]] && line="${line/#~/$HOME}"
        if [[ "$line" =~ \.\. ]]; then
            WHITELIST_WARNINGS+=("Path traversal not allowed: $line")
            continue
        fi

        if [[ "$line" != "$FINDER_METADATA_SENTINEL" ]]; then
            if [[ ! "$line" =~ ^[a-zA-Z0-9/_.@\ *-]+$ ]]; then
                WHITELIST_WARNINGS+=("Invalid path format: $line")
                continue
            fi

            if [[ "$line" != /* ]]; then
                WHITELIST_WARNINGS+=("Must be absolute path: $line")
                continue
            fi
        fi

        if [[ "$line" =~ // ]]; then
            WHITELIST_WARNINGS+=("Consecutive slashes: $line")
            continue
        fi

        case "$line" in
            / | /System | /System/* | /bin | /bin/* | /sbin | /sbin/* | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | /etc | /etc/* | /var/db | /var/db/*)
                WHITELIST_WARNINGS+=("Protected system path: $line")
                continue
                ;;
        esac

        duplicate="false"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$line" == "$existing" ]]; then
                    duplicate="true"
                    break
                fi
            done
        fi
        [[ "$duplicate" == "true" ]] && continue
        WHITELIST_PATTERNS+=("$line")
    done < "$HOME/.config/mole/whitelist"
else
    WHITELIST_PATTERNS=("${DEFAULT_WHITELIST_PATTERNS[@]}")
fi

if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for entry in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
            PROTECT_FINDER_METADATA=true
            break
        fi
    done
fi
total_items=0

# Tracking variables
TRACK_SECTION=0
SECTION_ACTIVITY=0
files_cleaned=0
total_size_cleaned=0
whitelist_skipped_count=0

note_activity() {
    if [[ $TRACK_SECTION -eq 1 ]]; then
        SECTION_ACTIVITY=1
    fi
}

# Cleanup background processes
CLEANUP_DONE=false
cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    # Prevent multiple executions
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    # Stop all spinners and clear the line
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        kill "$INLINE_SPINNER_PID" 2> /dev/null || true
        wait "$INLINE_SPINNER_PID" 2> /dev/null || true
        INLINE_SPINNER_PID=""
    fi

    # Clear any spinner output - spinner outputs to stderr
    if [[ -t 1 ]]; then
        printf "\r\033[K" >&2
    fi

    # Stop sudo session
    stop_sudo_session

    show_cursor

    # If interrupted, show message
    if [[ "$signal" == "INT" ]] || [[ $exit_code -eq 130 ]]; then
        printf "\r\033[K" >&2
        echo -e "${YELLOW}Interrupted by user${NC}" >&2
    fi
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"

    # Write section header to export list in dry-run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        ensure_user_file "$EXPORT_LIST_FILE"
        echo "" >> "$EXPORT_LIST_FILE"
        echo "=== $1 ===" >> "$EXPORT_LIST_FILE"
    fi
}

end_section() {
    if [[ $TRACK_SECTION -eq 1 && $SECTION_ACTIVITY -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to clean"
    fi
    TRACK_SECTION=0
}

safe_clean() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local description
    local -a targets

    if [[ $# -eq 1 ]]; then
        description="$1"
        targets=("$1")
    else
        # Get last argument as description
        description="${*: -1}"
        # Get all arguments except last as targets array
        targets=("${@:1:$#-1}")
    fi

    local removed_any=0
    local total_size_bytes=0
    local total_count=0
    local skipped_count=0

    # Optimized parallel processing for better performance
    local -a existing_paths=()
    for path in "${targets[@]}"; do
        local skip=false

        # Centralized protection for critical apps and system components
        if should_protect_path "$path"; then
            skip=true
            ((skipped_count++))
        fi

        [[ "$skip" == "true" ]] && continue

        # Check user-defined whitelist
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for w in "${WHITELIST_PATTERNS[@]}"; do
                # Match both exact path and glob pattern
                # shellcheck disable=SC2053
                if [[ "$path" == "$w" ]] || [[ $path == $w ]]; then
                    skip=true
                    ((skipped_count++))
                    break
                fi
            done
        fi
        [[ "$skip" == "true" ]] && continue
        [[ -e "$path" ]] && existing_paths+=("$path")
    done

    debug_log "Cleaning: $description (${#existing_paths[@]} items)"

    # Update global whitelist skip counter
    if [[ $skipped_count -gt 0 ]]; then
        ((whitelist_skipped_count += skipped_count))
    fi

    if [[ ${#existing_paths[@]} -eq 0 ]]; then
        return 0
    fi

    # Show progress indicator for potentially slow operations
    if [[ ${#existing_paths[@]} -gt 3 ]]; then
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning $total_paths items..."; fi
        local temp_dir
        # create_temp_dir uses mktemp -d for secure temporary directory creation
        temp_dir=$(create_temp_dir)

        # Parallel processing (bash 3.2 compatible)
        local -a pids=()
        local idx=0
        local completed=0
        for path in "${existing_paths[@]}"; do
            (
                local size
                size=$(get_path_size_kb "$path")
                # Use index + PID for unique filename
                local tmp_file="$temp_dir/result_${idx}.$$"
                # Optimization: Skip expensive file counting. Size is the key metric.
                # Just indicate presence if size > 0
                if [[ "$size" -gt 0 ]]; then
                    echo "$size 1" > "$tmp_file"
                else
                    echo "0 0" > "$tmp_file"
                fi
                mv "$tmp_file" "$temp_dir/result_${idx}" 2> /dev/null || true
            ) &
            pids+=($!)
            ((idx++))

            if ((${#pids[@]} >= MOLE_MAX_PARALLEL_JOBS)); then
                wait "${pids[0]}" 2> /dev/null || true
                pids=("${pids[@]:1}")
                ((completed++))
                # Update progress less frequently to reduce overhead
                if [[ -t 1 ]] && ((completed % 20 == 0)); then
                    stop_inline_spinner
                    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning items ($completed/$total_paths)..."
                fi
            fi
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2> /dev/null || true
            ((completed++))
        done

        # Read results using same index
        idx=0
        for path in "${existing_paths[@]}"; do
            local result_file="$temp_dir/result_${idx}"
            if [[ -f "$result_file" ]]; then
                read -r size count < "$result_file" 2> /dev/null || true
                if [[ "$count" -gt 0 && "$size" -gt 0 ]]; then
                    if [[ "$DRY_RUN" != "true" ]]; then
                        # Update spinner to show cleaning progress
                        if [[ -t 1 ]] && ((idx % 5 == 0)); then
                            stop_inline_spinner
                            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Cleaning items ($idx/$total_paths)..."
                        fi
                        # Handle symbolic links separately (only remove the link, not the target)
                        if [[ -L "$path" ]]; then
                            rm "$path" 2> /dev/null || true
                        else
                            safe_remove "$path" true || true
                        fi
                    fi
                    ((total_size_bytes += size))
                    ((total_count += 1))
                    removed_any=1
                fi
            fi
            ((idx++))
        done

        # Temp dir will be auto-cleaned by cleanup_temp_files
    else
        # Show progress for small batches too (simpler jobs)
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning $total_paths items..."; fi

        local idx=0
        for path in "${existing_paths[@]}"; do
            local size_bytes
            size_bytes=$(get_path_size_kb "$path")

            # Optimization: Skip expensive file counting
            if [[ "$size_bytes" -gt 0 ]]; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    # Update spinner to show cleaning progress for slow operations
                    if [[ -t 1 ]]; then
                        stop_inline_spinner
                        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Cleaning $description..."
                    fi
                    # Handle symbolic links separately (only remove the link, not the target)
                    if [[ -L "$path" ]]; then
                        rm "$path" 2> /dev/null || true
                    else
                        safe_remove "$path" true || true
                    fi
                fi
                ((total_size_bytes += size_bytes))
                ((total_count += 1))
                removed_any=1
            fi
            ((idx++))
        done
    fi

    # Clear progress / stop spinner before showing result
    if [[ -t 1 ]]; then
        stop_inline_spinner
        echo -ne "\r\033[K"
    fi

    if [[ $removed_any -eq 1 ]]; then
        # Convert KB to bytes for bytes_to_human()
        local size_human=$(bytes_to_human "$((total_size_bytes * 1024))")

        local label="$description"
        if [[ ${#targets[@]} -gt 1 ]]; then
            label+=" ${#targets[@]} items"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}→${NC} $label ${YELLOW}($size_human dry)${NC}"

            # Group paths by parent directory for export (Bash 3.2 compatible)
            local paths_temp=$(create_temp_file)

            idx=0
            for path in "${existing_paths[@]}"; do
                local size=0

                # Get size from result file if it exists (parallel processing with temp_dir)
                if [[ -n "${temp_dir:-}" && -f "$temp_dir/result_${idx}" ]]; then
                    read -r size count < "$temp_dir/result_${idx}" 2> /dev/null || true
                else
                    # Get size directly (small batch processing or no temp_dir)
                    size=$(get_path_size_kb "$path" 2> /dev/null || echo "0")
                fi

                [[ "$size" == "0" || -z "$size" ]] && {
                    ((idx++))
                    continue
                }

                # Write parent|size|path to temp file
                echo "$(dirname "$path")|$size|$path" >> "$paths_temp"
                ((idx++))
            done

            # Group and export paths
            if [[ -f "$paths_temp" && -s "$paths_temp" ]]; then
                # Sort by parent directory to group children together
                sort -t'|' -k1,1 "$paths_temp" | awk -F'|' '
                {
                    parent = $1
                    size = $2
                    path = $3

                    parent_size[parent] += size
                    if (parent_count[parent] == 0) {
                        parent_first[parent] = path
                    }
                    parent_count[parent]++
                }
                END {
                    for (parent in parent_size) {
                        if (parent_count[parent] > 1) {
                            printf "%s|%d|%d\n", parent, parent_size[parent], parent_count[parent]
                        } else {
                            printf "%s|%d|1\n", parent_first[parent], parent_size[parent]
                        }
                    }
                }
                ' | while IFS='|' read -r display_path total_size child_count; do
                    local size_human=$(bytes_to_human "$((total_size * 1024))")
                    if [[ $child_count -gt 1 ]]; then
                        echo "$display_path  # $size_human ($child_count items)" >> "$EXPORT_LIST_FILE"
                    else
                        echo "$display_path  # $size_human" >> "$EXPORT_LIST_FILE"
                    fi
                done

                rm -f "$paths_temp"
            fi
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label ${GREEN}($size_human)${NC}"
        fi
        ((files_cleaned += total_count))
        ((total_size_cleaned += total_size_bytes))
        ((total_items++))
        note_activity
    fi

    return 0
}

start_cleanup() {
    if [[ -t 1 ]]; then
        # Avoid relying on TERM since CI often runs without it
        printf '\033[2J\033[H'
    fi
    printf '\n'
    echo -e "${PURPLE_BOLD}Clean Your Mac${NC}"
    echo ""

    if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
        echo -e "${GRAY}${ICON_SOLID} Use --dry-run to preview, --whitelist to manage protected paths${NC}"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Dry Run Mode${NC} - Preview only, no deletions"
        echo ""
        SYSTEM_CLEAN=false

        # Initialize export list file
        ensure_user_file "$EXPORT_LIST_FILE"
        cat > "$EXPORT_LIST_FILE" << EOF
# Mole Cleanup Preview - $(date '+%Y-%m-%d %H:%M:%S')
#
# How to protect files:
# 1. Copy any path below to ~/.config/mole/whitelist
# 2. Run: mo clean --whitelist
#
# Example:
#   /Users/*/Library/Caches/com.example.app
#

EOF
        return
    fi

    if [[ -t 0 ]]; then
        echo -ne "${PURPLE}${ICON_ARROW}${NC} System caches need sudo — ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "

        # Use read_key to properly handle all key inputs
        local choice
        choice=$(read_key)

        # Check for cancel (ESC or Q)
        if [[ "$choice" == "QUIT" ]]; then
            echo -e " ${GRAY}Canceled${NC}"
            exit 0
        fi

        # Space = skip
        if [[ "$choice" == "SPACE" ]]; then
            echo -e " ${GRAY}Skipped${NC}"
            echo ""
            SYSTEM_CLEAN=false
        # Enter = yes, do system cleanup
        elif [[ "$choice" == "ENTER" ]]; then
            printf "\r\033[K" # Clear the prompt line
            if ensure_sudo_session "System cleanup requires admin access"; then
                SYSTEM_CLEAN=true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                echo ""
            else
                SYSTEM_CLEAN=false
                echo ""
                echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
            fi
        else
            # Other keys (including arrow keys) = skip, no message needed
            SYSTEM_CLEAN=false
            echo -e " ${GRAY}Skipped${NC}"
            echo ""
        fi
    else
        SYSTEM_CLEAN=false
        echo ""
        echo "Running in non-interactive mode"
        echo "  • System-level cleanup skipped (requires interaction)"
        echo "  • User-level cleanup will proceed automatically"
        echo ""
    fi
}

# Clean Service Worker CacheStorage with domain protection

perform_cleanup() {
    echo -e "${BLUE}${ICON_ADMIN}${NC} $(detect_architecture) | Free space: $(get_free_space)"

    # Pre-check TCC permissions upfront (delegated to clean_caches module)
    check_tcc_permissions

    # Show whitelist info if patterns are active
    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        # Count predefined vs custom patterns
        local predefined_count=0
        local custom_count=0

        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local is_predefined=false
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                if [[ "$pattern" == "$default" ]]; then
                    is_predefined=true
                    break
                fi
            done

            if [[ "$is_predefined" == "true" ]]; then
                ((predefined_count++))
            else
                ((custom_count++))
            fi
        done

        # Display whitelist status
        if [[ $custom_count -gt 0 && $predefined_count -gt 0 ]]; then
            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $predefined_count core + $custom_count custom patterns active"
        elif [[ $custom_count -gt 0 ]]; then
            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $custom_count custom patterns active"
        elif [[ $predefined_count -gt 0 ]]; then
            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $predefined_count core patterns active"
        fi
    fi

    # Initialize counters
    total_items=0
    files_cleaned=0
    total_size_cleaned=0

    # ===== 1. Deep system cleanup (if admin) - Do this first while sudo is fresh =====
    if [[ "$SYSTEM_CLEAN" == "true" ]]; then
        start_section "Deep system"
        # Deep system cleanup (delegated to clean_system module)
        clean_deep_system
        clean_local_snapshots
        end_section
    fi

    # Show whitelist warnings if any
    if [[ ${#WHITELIST_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        for warning in "${WHITELIST_WARNINGS[@]}"; do
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Whitelist: $warning"
        done
    fi

    # ===== 2. User essentials =====
    start_section "User essentials"
    # User essentials cleanup (delegated to clean_user_data module)
    clean_user_essentials
    scan_external_volumes
    end_section

    start_section "Finder metadata"
    # Finder metadata cleanup (delegated to clean_user_data module)
    clean_finder_metadata
    end_section

    # ===== 3. macOS system caches =====
    start_section "macOS system caches"
    # macOS system caches cleanup (delegated to clean_user_data module)
    clean_macos_system_caches
    end_section

    # ===== 4. Sandboxed app caches =====
    start_section "Sandboxed app caches"
    # Sandboxed app caches cleanup (delegated to clean_user_data module)
    clean_sandboxed_app_caches
    end_section

    # ===== 5. Browsers =====
    start_section "Browsers"
    # Browser caches cleanup (delegated to clean_user_data module)
    clean_browsers
    end_section

    # ===== 6. Cloud storage =====
    start_section "Cloud storage"
    # Cloud storage caches cleanup (delegated to clean_user_data module)
    clean_cloud_storage
    end_section

    # ===== 7. Office applications =====
    start_section "Office applications"
    # Office applications cleanup (delegated to clean_user_data module)
    clean_office_applications
    end_section

    # ===== 8. Developer tools =====
    start_section "Developer tools"
    # Developer tools cleanup (delegated to clean_dev module)
    clean_developer_tools
    end_section

    # ===== 9. Development applications =====
    start_section "Development applications"
    # User GUI applications cleanup (delegated to clean_user_apps module)
    clean_user_gui_applications
    end_section

    # ===== 10. Virtualization tools =====
    start_section "Virtual machine tools"
    # Virtualization tools cleanup (delegated to clean_user_data module)
    clean_virtualization_tools
    end_section

    # ===== 11. Application Support logs and caches cleanup =====
    start_section "Application Support"
    # Clean logs, Service Worker caches, Code Cache, Crashpad, stale updates, Group Containers
    clean_application_support_logs
    end_section

    # ===== 12. Orphaned app data cleanup =====
    # Only touch apps missing from scan + 60+ days inactive
    # Skip protected vendors, keep Preferences/Application Support
    start_section "Uninstalled app data"
    clean_orphaned_app_data
    end_section

    # ===== 13. Apple Silicon optimizations =====
    clean_apple_silicon_caches

    # ===== 14. iOS device backups =====
    start_section "iOS device backups"
    # iOS device backups check (delegated to clean_user_data module)
    check_ios_device_backups
    end_section

    # ===== 15. Time Machine incomplete backups =====
    start_section "Time Machine incomplete backups"
    # Time Machine incomplete backups cleanup (delegated to clean_system module)
    clean_time_machine_failed_backups
    end_section

    # ===== Final summary =====
    echo ""

    local summary_heading=""
    local summary_status="success"
    if [[ "$DRY_RUN" == "true" ]]; then
        summary_heading="Dry run complete - no changes made"
    else
        summary_heading="Cleanup complete"
    fi

    local -a summary_details=()

    if [[ $total_size_cleaned -gt 0 ]]; then
        local freed_gb
        freed_gb=$(echo "$total_size_cleaned" | awk '{printf "%.2f", $1/1024/1024}')

        if [[ "$DRY_RUN" == "true" ]]; then
            # Build compact stats line for dry run
            local stats="Potential space: ${GREEN}${freed_gb}GB${NC}"
            [[ $files_cleaned -gt 0 ]] && stats+=" | Items: $files_cleaned"
            [[ $total_items -gt 0 ]] && stats+=" | Categories: $total_items"
            summary_details+=("$stats")

            # Add summary to export file
            {
                echo ""
                echo "# ============================================"
                echo "# Summary"
                echo "# ============================================"
                echo "# Potential cleanup: ${freed_gb}GB"
                echo "# Items: $files_cleaned"
                echo "# Categories: $total_items"
            } >> "$EXPORT_LIST_FILE"

            summary_details+=("Detailed file list: ${GRAY}$EXPORT_LIST_FILE${NC}")
            summary_details+=("Use ${GRAY}mo clean --whitelist${NC} to add protection rules")
        else
            # Build summary line: Space freed + Items cleaned
            local summary_line="Space freed: ${GREEN}${freed_gb}GB${NC}"

            if [[ $files_cleaned -gt 0 && $total_items -gt 0 ]]; then
                summary_line+=" | Items cleaned: $files_cleaned | Categories: $total_items"
            elif [[ $files_cleaned -gt 0 ]]; then
                summary_line+=" | Items cleaned: $files_cleaned"
            elif [[ $total_items -gt 0 ]]; then
                summary_line+=" | Categories: $total_items"
            fi

            summary_details+=("$summary_line")

            if [[ $(echo "$freed_gb" | awk '{print ($1 >= 1) ? 1 : 0}') -eq 1 ]]; then
                local movies
                movies=$(echo "$freed_gb" | awk '{printf "%.0f", $1/4.5}')
                if [[ $movies -gt 0 ]]; then
                    summary_details+=("Equivalent to ~$movies 4K movies of storage.")
                fi
            fi

            # Free space now at the end
            summary_details+=("Free space now: $(get_free_space)")
        fi
    else
        summary_status="info"
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_details+=("No significant reclaimable space detected (system already clean).")
        else
            summary_details+=("System was already clean; no additional space freed.")
        fi
        summary_details+=("Free space now: $(get_free_space)")
    fi

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

main() {
    for arg in "$@"; do
        case "$arg" in
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                DRY_RUN=true
                ;;
            "--whitelist")
                source "$SCRIPT_DIR/../lib/manage/whitelist.sh"
                manage_whitelist "clean"
                exit 0
                ;;
        esac
    done

    start_cleanup
    hide_cursor
    perform_cleanup
    show_cursor
}

main "$@"
