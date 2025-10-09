#!/bin/bash
# Mole - Uninstall Module
# Interactive application uninstaller with keyboard navigation
#
# Usage:
#   uninstall.sh          # Launch interactive uninstaller
#   uninstall.sh --help   # Show help information

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/paginated_menu.sh"
source "$SCRIPT_DIR/../lib/app_selector.sh"
source "$SCRIPT_DIR/../lib/batch_uninstall.sh"

# Note: Bundle preservation logic is now in lib/common.sh

# Help information
show_help() {
    echo "Usage: mole uninstall"
    echo ""
    echo "Interactive application uninstaller - Remove apps completely"
    echo ""
    echo "Keyboard Controls:"
    echo "  ↑/↓         Navigate items"
    echo "  Space       Select/deselect"
    echo "  Enter       Confirm and uninstall"
    echo "  Q / ESC     Quit"
    echo ""
    echo "What gets cleaned:"
    echo "  • Application bundle"
    echo "  • Application Support data (12+ locations)"
    echo "  • Cache files"
    echo "  • Preference files"
    echo "  • Log files"
    echo "  • Saved application state"
    echo "  • Container data (sandboxed apps)"
    echo "  • WebKit storage, HTTP storage, cookies"
    echo "  • Extensions, plugins, services"
    echo ""
    echo "Examples:"
    echo "  mole uninstall         Launch interactive uninstaller"
    echo ""
}

# Parse arguments
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

# Initialize global variables
selected_apps=()  # Global array for app selection
declare -a apps_data=()
declare -a selection_state=()
current_line=0
total_items=0
files_cleaned=0
total_size_cleaned=0

# Get app last used date in human readable format
get_app_last_used() {
    local app_path="$1"
    local last_used=$(mdls -name kMDItemLastUsedDate -raw "$app_path" 2>/dev/null)

    if [[ "$last_used" == "(null)" || -z "$last_used" ]]; then
        echo "Never"
    else
        local last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$last_used" "+%s" 2>/dev/null)
        local current_epoch=$(date "+%s")
        local days_ago=$(( (current_epoch - last_used_epoch) / 86400 ))

        if [[ $days_ago -eq 0 ]]; then
            echo "Today"
        elif [[ $days_ago -eq 1 ]]; then
            echo "Yesterday"
        elif [[ $days_ago -lt 30 ]]; then
            echo "${days_ago} days ago"
        elif [[ $days_ago -lt 365 ]]; then
            local months_ago=$(( days_ago / 30 ))
            echo "${months_ago} month(s) ago"
        else
            local years_ago=$(( days_ago / 365 ))
            echo "${years_ago} year(s) ago"
        fi
    fi
}

# Scan applications and collect information
scan_applications() {
    # Cache configuration
    local cache_dir="$HOME/.cache/mole"
    local cache_file="$cache_dir/app_scan_cache"
    local cache_meta="$cache_dir/app_scan_meta"
    local cache_ttl=3600  # 1 hour cache validity

    mkdir -p "$cache_dir" 2>/dev/null

    # Quick count of current apps (system + user directories)
    local current_app_count=$(
        (find /Applications -name "*.app" -maxdepth 1 2>/dev/null;
         find ~/Applications -name "*.app" -maxdepth 1 2>/dev/null) | wc -l | tr -d ' '
    )

    # Check if cache is valid
    if [[ -f "$cache_file" && -f "$cache_meta" ]]; then
        local cache_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
        local cached_app_count=$(cat "$cache_meta" 2>/dev/null || echo "0")

        # Cache is valid if: age < TTL AND app count matches
        if [[ $cache_age -lt $cache_ttl && "$cached_app_count" == "$current_app_count" ]]; then
            # Only show cache info in debug mode
            [[ -n "${MOLE_DEBUG:-}" ]] && echo "Using cached app list (${cache_age}s old, $current_app_count apps) ✓" >&2
            echo "$cache_file"
            return 0
        fi
    fi

    local temp_file=$(create_temp_file)

    echo "" >&2  # Add space before scanning output without breaking stdout return
    # Pre-cache current epoch to avoid repeated calls
    local current_epoch=$(date "+%s")

    # Spinner for scanning feedback (simple ASCII for compatibility)
    local spinner_chars="|/-\\"
    local spinner_idx=0

    # First pass: quickly collect all valid app paths and bundle IDs
    local -a app_data_tuples=()
    while IFS= read -r -d '' app_path; do
        if [[ ! -e "$app_path" ]]; then continue; fi

        local app_name=$(basename "$app_path" .app)

        # Try to get English name from bundle info, fallback to folder name
        local bundle_id="unknown"
        local display_name="$app_name"
        if [[ -f "$app_path/Contents/Info.plist" ]]; then
            bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")

            # Try to get English name from bundle info
            local bundle_executable=$(defaults read "$app_path/Contents/Info.plist" CFBundleExecutable 2>/dev/null)

            # Smart display name selection - prefer descriptive names over generic ones
            local candidates=()

            # Get all potential names
            local bundle_display_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist" 2>/dev/null)
            local bundle_name=$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist" 2>/dev/null)

            # Check if executable name is generic/technical (should be avoided)
            local is_generic_executable=false
            if [[ -n "$bundle_executable" ]]; then
                case "$bundle_executable" in
                    "pake"|"Electron"|"electron"|"nwjs"|"node"|"helper"|"main"|"app"|"binary")
                        is_generic_executable=true
                        ;;
                esac
            fi

            # Priority order for name selection:
            # 1. App folder name (if ASCII and descriptive) - often the most complete name
            if [[ "$app_name" =~ ^[A-Za-z0-9\ ._-]+$ && ${#app_name} -gt 3 ]]; then
                candidates+=("$app_name")
            fi

            # 2. CFBundleDisplayName (if meaningful and ASCII)
            if [[ -n "$bundle_display_name" && "$bundle_display_name" =~ ^[A-Za-z0-9\ ._-]+$ ]]; then
                candidates+=("$bundle_display_name")
            fi

            # 3. CFBundleName (if meaningful and ASCII)
            if [[ -n "$bundle_name" && "$bundle_name" =~ ^[A-Za-z0-9\ ._-]+$ && "$bundle_name" != "$bundle_display_name" ]]; then
                candidates+=("$bundle_name")
            fi

            # 4. CFBundleExecutable (only if not generic and ASCII)
            if [[ -n "$bundle_executable" && "$bundle_executable" =~ ^[A-Za-z0-9._-]+$ && "$is_generic_executable" == false ]]; then
                candidates+=("$bundle_executable")
            fi

            # 5. Fallback to non-ASCII names if no ASCII found
            if [[ ${#candidates[@]} -eq 0 ]]; then
                [[ -n "$bundle_display_name" ]] && candidates+=("$bundle_display_name")
                [[ -n "$bundle_name" && "$bundle_name" != "$bundle_display_name" ]] && candidates+=("$bundle_name")
                candidates+=("$app_name")
            fi

            # Select the first (best) candidate
            display_name="${candidates[0]:-$app_name}"

            # Apply brand name mapping from common.sh
            display_name="$(get_brand_name "$display_name")"
        fi

        # Skip system critical apps (input methods, system components)
        # Note: Paid apps like CleanMyMac, 1Password are NOT protected here - users can uninstall them
        if should_protect_from_uninstall "$bundle_id"; then
            continue
        fi

        # Store tuple: app_path|app_name|bundle_id|display_name
        app_data_tuples+=("${app_path}|${app_name}|${bundle_id}|${display_name}")
    done < <(
        # Scan both system and user application directories
        find /Applications -name "*.app" -maxdepth 1 -print0 2>/dev/null
        find ~/Applications -name "*.app" -maxdepth 1 -print0 2>/dev/null
    )

    # Second pass: process each app with parallel size calculation
    local app_count=0
    local total_apps=${#app_data_tuples[@]}
    local max_parallel=10  # Process 10 apps in parallel
    local pids=()

    # Process app metadata extraction function
    process_app_metadata() {
        local app_data_tuple="$1"
        local output_file="$2"
        local current_epoch="$3"

        IFS='|' read -r app_path app_name bundle_id display_name <<< "$app_data_tuple"

        # Parallel size calculation
        local app_size="N/A"
        if [[ -d "$app_path" ]]; then
            app_size=$(du -sh "$app_path" 2>/dev/null | cut -f1 || echo "N/A")
        fi

        # Get real last used date from macOS metadata
        local last_used="Never"
        local last_used_epoch=0

        if [[ -d "$app_path" ]]; then
            local metadata_date=$(mdls -name kMDItemLastUsedDate -raw "$app_path" 2>/dev/null)

            if [[ "$metadata_date" != "(null)" && -n "$metadata_date" ]]; then
                last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$metadata_date" "+%s" 2>/dev/null || echo "0")

                if [[ $last_used_epoch -gt 0 ]]; then
                    local days_ago=$(( (current_epoch - last_used_epoch) / 86400 ))

                    if [[ $days_ago -eq 0 ]]; then
                        last_used="Today"
                    elif [[ $days_ago -eq 1 ]]; then
                        last_used="Yesterday"
                    elif [[ $days_ago -lt 7 ]]; then
                        last_used="${days_ago} days ago"
                    elif [[ $days_ago -lt 30 ]]; then
                        local weeks_ago=$(( days_ago / 7 ))
                        [[ $weeks_ago -eq 1 ]] && last_used="1 week ago" || last_used="${weeks_ago} weeks ago"
                    elif [[ $days_ago -lt 365 ]]; then
                        local months_ago=$(( days_ago / 30 ))
                        [[ $months_ago -eq 1 ]] && last_used="1 month ago" || last_used="${months_ago} months ago"
                    else
                        local years_ago=$(( days_ago / 365 ))
                        [[ $years_ago -eq 1 ]] && last_used="1 year ago" || last_used="${years_ago} years ago"
                    fi
                fi
            else
                # Fallback to file modification time
                last_used_epoch=$(stat -f%m "$app_path" 2>/dev/null || echo "0")
                if [[ $last_used_epoch -gt 0 ]]; then
                    local days_ago=$(( (current_epoch - last_used_epoch) / 86400 ))
                    if [[ $days_ago -lt 30 ]]; then
                        last_used="Recent"
                    elif [[ $days_ago -lt 365 ]]; then
                        last_used="This year"
                    else
                        last_used="Old"
                    fi
                fi
            fi
        fi

        # Write to output file atomically
        echo "${last_used_epoch}|${app_path}|${display_name}|${bundle_id}|${app_size}|${last_used}" >> "$output_file"
    }

    export -f process_app_metadata

    # Process apps in parallel batches
    for app_data_tuple in "${app_data_tuples[@]}"; do
        ((app_count++))

        # Launch background process
        process_app_metadata "$app_data_tuple" "$temp_file" "$current_epoch" &
        pids+=($!)

        # Update progress with spinner
        local spinner_char="${spinner_chars:$((spinner_idx % 4)):1}"
        echo -ne "\r\033[K  ${spinner_char} Scanning applications... $app_count/$total_apps" >&2
        ((spinner_idx++))

        # Wait if we've hit max parallel limit
        if (( ${#pids[@]} >= max_parallel )); then
            wait "${pids[0]}" 2>/dev/null
            pids=("${pids[@]:1}")  # Remove first pid
        fi
    done

    # Wait for remaining background processes
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    echo -e "\r\033[K  ✓ Found $app_count applications" >&2
    echo "" >&2

    # Check if we found any applications
    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        return 1
    fi

    # Sort by last used (oldest first) and cache the result
    sort -t'|' -k1,1n "$temp_file" > "${temp_file}.sorted" || { rm -f "$temp_file"; return 1; }
    rm -f "$temp_file"

    # Update cache with app count metadata
    cp "${temp_file}.sorted" "$cache_file" 2>/dev/null || true
    echo "$current_app_count" > "$cache_meta" 2>/dev/null || true

    # Verify sorted file exists before returning
    if [[ -f "${temp_file}.sorted" ]]; then
        echo "${temp_file}.sorted"
    else
        return 1
    fi
}

# Load applications into arrays
load_applications() {
    local apps_file="$1"

    if [[ ! -f "$apps_file" || ! -s "$apps_file" ]]; then
        log_warning "No applications found for uninstallation"
        return 1
    fi

    # Clear arrays
    apps_data=()
    selection_state=()

    # Read apps into array
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used; do
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used")
        selection_state+=(false)
    done < "$apps_file"

    if [[ ${#apps_data[@]} -eq 0 ]]; then
        log_warning "No applications available for uninstallation"
        return 1
    fi

    return 0
}

# Old display_apps function removed - replaced by new menu system

# Read a single key with proper escape sequence handling
# This function has been replaced by the menu.sh library

# Note: App file discovery and size calculation functions moved to lib/common.sh
# Use find_app_files() and calculate_total_size() from common.sh

# Uninstall selected applications
uninstall_applications() {
    local total_size_freed=0

    echo ""
    echo -e "${PURPLE}▶ Uninstalling selected applications${NC}"

    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    for selected_app in "${selected_apps[@]}"; do
        IFS='|' read -r epoch app_path app_name bundle_id size last_used <<< "$selected_app"

        echo ""

        # Check if app is running
        if pgrep -f "$app_name" >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠ $app_name is currently running${NC}"
            read -p "  Force quit $app_name? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                pkill -f "$app_name" 2>/dev/null || true
                sleep 2
            else
                echo -e "  ${BLUE}○${NC} Skipped $app_name"
                continue
            fi
        fi

        # Find related files (user-level)
        local related_files=$(find_app_files "$bundle_id" "$app_name")

        # Find system-level files (requires sudo)
        local system_files=$(find_app_system_files "$bundle_id" "$app_name")

        # Calculate total size
        local app_size_kb=$(du -sk "$app_path" 2>/dev/null | awk '{print $1}' || echo "0")
        local related_size_kb=$(calculate_total_size "$related_files")
        local system_size_kb=$(calculate_total_size "$system_files")
        local total_kb=$((app_size_kb + related_size_kb + system_size_kb))

        # Show what will be removed
        echo -e "${BLUE}◎${NC} $app_name - Files to be removed:"
        echo -e "  ${GREEN}✓${NC} Application: $(echo "$app_path" | sed "s|$HOME|~|")"

        # Show user-level files
        while IFS= read -r file; do
            [[ -n "$file" && -e "$file" ]] && echo -e "  ${GREEN}✓${NC} $(echo "$file" | sed "s|$HOME|~|")"
        done <<< "$related_files"

        # Show system-level files
        if [[ -n "$system_files" ]]; then
            while IFS= read -r file; do
                [[ -n "$file" && -e "$file" ]] && echo -e "  ${BLUE}●${NC} System: $file"
            done <<< "$system_files"
        fi

        if [[ $total_kb -gt 1048576 ]]; then  # > 1GB
            local size_display=$(echo "$total_kb" | awk '{printf "%.2fGB", $1/1024/1024}')
        elif [[ $total_kb -gt 1024 ]]; then  # > 1MB
            local size_display=$(echo "$total_kb" | awk '{printf "%.1fMB", $1/1024}')
        else
            local size_display="${total_kb}KB"
        fi

        echo -e "  ${BLUE}Total size: $size_display${NC}"
        echo

        read -p "  Proceed with uninstalling $app_name? (y/N): " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Remove the application
            if rm -rf "$app_path" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} Removed application"
            else
                echo -e "  ${RED}✗${NC} Failed to remove $app_path"
                continue
            fi

            # Remove user-level related files
            while IFS= read -r file; do
                if [[ -n "$file" && -e "$file" ]]; then
                    if rm -rf "$file" 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} Removed $(echo "$file" | sed "s|$HOME|~|" | xargs basename)"
                    fi
                fi
            done <<< "$related_files"

            # Remove system-level files (requires sudo)
            if [[ -n "$system_files" ]]; then
                echo -e "  ${BLUE}●${NC} Admin access required for system files"
                while IFS= read -r file; do
                    if [[ -n "$file" && -e "$file" ]]; then
                        if sudo rm -rf "$file" 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} Removed $(basename "$file")"
                        else
                            echo -e "  ${YELLOW}⚠${NC} Failed to remove: $file"
                        fi
                    fi
                done <<< "$system_files"
            fi

            ((total_size_freed += total_kb))
            ((files_cleaned++))
            ((total_items++))

            echo -e "  ${GREEN}✓${NC} $app_name uninstalled successfully"
        else
            echo -e "  ${BLUE}○${NC} Skipped $app_name"
        fi
    done

    # Show final summary
    echo ""
    echo -e "${PURPLE}▶ Uninstallation Summary${NC}"

    if [[ $total_size_freed -gt 0 ]]; then
        if [[ $total_size_freed -gt 1048576 ]]; then  # > 1GB
            local freed_display=$(echo "$total_size_freed" | awk '{printf "%.2fGB", $1/1024/1024}')
        elif [[ $total_size_freed -gt 1024 ]]; then  # > 1MB
            local freed_display=$(echo "$total_size_freed" | awk '{printf "%.1fMB", $1/1024}')
        else
            local freed_display="${total_size_freed}KB"
        fi

        echo -e "  ${GREEN}✓${NC} Freed $freed_display of disk space"
    fi

    echo -e "  ${GREEN}✓${NC} Applications uninstalled: $files_cleaned"
    ((total_size_cleaned += total_size_freed))
}

# Cleanup function - restore cursor and clean up
cleanup() {
    # Restore cursor using common function
    show_cursor
    exit "${1:-0}"
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Main function
main() {
    # Hide cursor during operation
    hide_cursor

    # Scan applications
    local apps_file=$(scan_applications)

    if [[ ! -f "$apps_file" ]]; then
        echo ""
        log_error "Failed to scan applications"
        return 1
    fi

    # Load applications
    if ! load_applications "$apps_file"; then
        rm -f "$apps_file"
        return 1
    fi

    # Interactive selection using paginated menu
    if ! select_apps_for_uninstall; then
        rm -f "$apps_file"
        return 0
    fi

    # Restore cursor and show a concise summary before confirmation
    show_cursor
    clear
    local selection_count=${#selected_apps[@]}
    if [[ $selection_count -eq 0 ]]; then
        echo "No apps selected"; rm -f "$apps_file"; return 0
    fi
    # Compact one-line summary (list up to 3 names, aggregate rest)
    local names=()
    local idx=0
    for selected_app in "${selected_apps[@]}"; do
        IFS='|' read -r epoch app_path app_name bundle_id size last_used <<< "$selected_app"
        if (( idx < 3 )); then
            names+=("${app_name}(${size})")
        fi
        ((idx++))
    done
    local extra=$((selection_count-3))
    local list="${names[*]}"
    [[ $extra -gt 0 ]] && list+=" +${extra}"
    echo -e "${BLUE}◎${NC} ${selection_count} apps: ${list}"

    # Execute batch uninstallation (handles confirmation)
    batch_uninstall_applications

    # Cleanup
    rm -f "$apps_file"
}

# Run main function
main "$@"
