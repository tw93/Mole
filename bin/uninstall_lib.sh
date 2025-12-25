#!/bin/bash
# Mole - Uninstall Module
# Interactive application uninstaller with keyboard navigation
#
# Usage:
#   uninstall.sh                  # Launch interactive uninstaller
#   uninstall.sh --force-rescan   # Rescan apps and refresh cache

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/../lib/ui/app_selector.sh"
source "$SCRIPT_DIR/../lib/uninstall/batch.sh"

# Note: Bundle preservation logic is now in lib/core/common.sh

# Initialize global variables
selected_apps=() # Global array for app selection
declare -a apps_data=()
declare -a selection_state=()
total_items=0
files_cleaned=0
total_size_cleaned=0

# Compact the "last used" descriptor for aligned summaries
format_last_used_summary() {
    local value="$1"

    case "$value" in
        "" | "Unknown")
            echo "Unknown"
            return 0
            ;;
        "Never" | "Recent" | "Today" | "Yesterday" | "This year" | "Old")
            echo "$value"
            return 0
            ;;
    esac

    if [[ $value =~ ^([0-9]+)[[:space:]]+days?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}d ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+weeks?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}w ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+months?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+month\(s\)\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+years?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}y ago"
        return 0
    fi
    echo "$value"
}

# Scan applications and collect information
scan_applications() {
    # Simplified cache: only check timestamp (24h TTL)
    local cache_dir="$HOME/.cache/mole"
    local cache_file="$cache_dir/app_scan_cache"
    local cache_ttl=86400 # 24 hours
    local force_rescan="${1:-false}"

    ensure_user_dir "$cache_dir"

    # Check if cache exists and is fresh
    if [[ $force_rescan == false && -f "$cache_file" ]]; then
        local cache_age=$(($(date +%s) - $(get_file_mtime "$cache_file")))
        [[ $cache_age -eq $(date +%s) ]] && cache_age=86401 # Handle missing file
        if [[ $cache_age -lt $cache_ttl ]]; then
            # Cache hit - return immediately
            # Show brief flash of cache usage if in interactive mode
            if [[ -t 2 ]]; then
                echo -e "${GREEN}Loading from cache...${NC}" >&2
                # Small sleep to let user see it (optional, but good for "feeling" the speed vs glitch)
                sleep 0.3
            fi
            echo "$cache_file"
            return 0
        fi
    fi

    # Cache miss - prepare for scanning
    local inline_loading=false
    if [[ -t 1 && -t 2 ]]; then
        inline_loading=true
        # Clear screen for inline loading
        printf "\033[2J\033[H" >&2
    fi

    local temp_file
    temp_file=$(create_temp_file)

    # Pre-cache current epoch to avoid repeated calls
    local current_epoch
    current_epoch=$(date "+%s")

    # First pass: quickly collect all valid app paths and bundle IDs (NO mdls calls)
    local -a app_data_tuples=()
    while IFS= read -r -d '' app_path; do
        if [[ ! -e "$app_path" ]]; then continue; fi

        local app_name
        app_name=$(basename "$app_path" .app)

        # Skip nested apps (e.g. inside Wrapper/ or Frameworks/ of another app)
        # Check if parent path component ends in .app (e.g. /Foo.app/Bar.app or /Foo.app/Contents/Bar.app)
        # This prevents false positives like /Old.apps/Target.app
        local parent_dir
        parent_dir=$(dirname "$app_path")
        if [[ "$parent_dir" == *".app" || "$parent_dir" == *".app/"* ]]; then
            continue
        fi

        # Get bundle ID only (fast, no mdls calls in first pass)
        local bundle_id="unknown"
        if [[ -f "$app_path/Contents/Info.plist" ]]; then
            bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2> /dev/null || echo "unknown")
        fi

        # Skip system critical apps (input methods, system components)
        if should_protect_from_uninstall "$bundle_id"; then
            continue
        fi

        # Store tuple: app_path|app_name|bundle_id (display_name will be resolved in parallel later)
        app_data_tuples+=("${app_path}|${app_name}|${bundle_id}")
    done < <(
        # Scan both system and user application directories
        # Using maxdepth 3 to find apps in subdirectories (e.g., Adobe apps in /Applications/Adobe X/)
        command find /Applications -name "*.app" -maxdepth 3 -print0 2> /dev/null
        command find ~/Applications -name "*.app" -maxdepth 3 -print0 2> /dev/null
    )

    # Second pass: process each app with parallel size calculation
    local app_count=0
    local total_apps=${#app_data_tuples[@]}
    # Bound parallelism - for metadata queries, can go higher since it's mostly waiting
    local max_parallel
    max_parallel=$(get_optimal_parallel_jobs "io")
    if [[ $max_parallel -lt 8 ]]; then
        max_parallel=8
    elif [[ $max_parallel -gt 32 ]]; then
        max_parallel=32
    fi
    local pids=()
    # inline_loading variable already set above (line ~92)

    # Process app metadata extraction function
    process_app_metadata() {
        local app_data_tuple="$1"
        local output_file="$2"
        local current_epoch="$3"

        IFS='|' read -r app_path app_name bundle_id <<< "$app_data_tuple"

        # Get localized display name (moved from first pass for better performance)
        local display_name="$app_name"
        if [[ -f "$app_path/Contents/Info.plist" ]]; then
            # Try to get localized name from system metadata (best for i18n)
            local md_display_name
            md_display_name=$(run_with_timeout 0.05 mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")

            # Get bundle names
            local bundle_display_name
            bundle_display_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist" 2> /dev/null)
            local bundle_name
            bundle_name=$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist" 2> /dev/null)

            # Priority order for name selection (prefer localized names):
            # 1. System metadata display name (kMDItemDisplayName) - respects system language
            # 2. CFBundleDisplayName - usually localized
            # 3. CFBundleName - fallback
            # 4. App folder name - last resort

            if [[ -n "$md_display_name" && "$md_display_name" != "(null)" && "$md_display_name" != "$app_name" ]]; then
                display_name="$md_display_name"
            elif [[ -n "$bundle_display_name" && "$bundle_display_name" != "(null)" ]]; then
                display_name="$bundle_display_name"
            elif [[ -n "$bundle_name" && "$bundle_name" != "(null)" ]]; then
                display_name="$bundle_name"
            fi
        fi

        # Parallel size calculation
        local app_size="N/A"
        local app_size_kb="0"
        if [[ -d "$app_path" ]]; then
            # Get size in KB, then format for display
            app_size_kb=$(get_path_size_kb "$app_path")
            app_size=$(bytes_to_human "$((app_size_kb * 1024))")
        fi

        # Get last used date
        local last_used="Never"
        local last_used_epoch=0

        if [[ -d "$app_path" ]]; then
            # Try mdls first with short timeout (0.1s) for accuracy, fallback to mtime for speed
            local metadata_date
            metadata_date=$(run_with_timeout 0.1 mdls -name kMDItemLastUsedDate -raw "$app_path" 2> /dev/null || echo "")

            if [[ "$metadata_date" != "(null)" && -n "$metadata_date" ]]; then
                last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$metadata_date" "+%s" 2> /dev/null || echo "0")
            fi

            # Fallback if mdls failed or returned nothing
            if [[ "$last_used_epoch" -eq 0 ]]; then
                last_used_epoch=$(get_file_mtime "$app_path")
            fi

            if [[ $last_used_epoch -gt 0 ]]; then
                local days_ago=$(((current_epoch - last_used_epoch) / 86400))

                if [[ $days_ago -eq 0 ]]; then
                    last_used="Today"
                elif [[ $days_ago -eq 1 ]]; then
                    last_used="Yesterday"
                elif [[ $days_ago -lt 7 ]]; then
                    last_used="${days_ago} days ago"
                elif [[ $days_ago -lt 30 ]]; then
                    local weeks_ago=$((days_ago / 7))
                    [[ $weeks_ago -eq 1 ]] && last_used="1 week ago" || last_used="${weeks_ago} weeks ago"
                elif [[ $days_ago -lt 365 ]]; then
                    local months_ago=$((days_ago / 30))
                    [[ $months_ago -eq 1 ]] && last_used="1 month ago" || last_used="${months_ago} months ago"
                else
                    local years_ago=$((days_ago / 365))
                    [[ $years_ago -eq 1 ]] && last_used="1 year ago" || last_used="${years_ago} years ago"
                fi
            fi
        fi

        # Write to output file atomically
        # Fields: epoch|app_path|display_name|bundle_id|size_human|last_used|size_kb
        echo "${last_used_epoch}|${app_path}|${display_name}|${bundle_id}|${app_size}|${last_used}|${app_size_kb}" >> "$output_file"
    }

    export -f process_app_metadata

    # Create a temporary file to track progress
    local progress_file="${temp_file}.progress"
    echo "0" > "$progress_file"

    # Start a background spinner that reads progress from file
    local spinner_pid=""
    (
        trap 'exit 0' TERM INT EXIT
        local spinner_chars="|/-\\"
        local i=0
        while true; do
            local completed=$(cat "$progress_file" 2> /dev/null || echo 0)
            local c="${spinner_chars:$((i % 4)):1}"
            if [[ $inline_loading == true ]]; then
                printf "\033[H\033[2K%s Scanning applications... %d/%d\n" "$c" "$completed" "$total_apps" >&2
            else
                printf "\r\033[K%s Scanning applications... %d/%d" "$c" "$completed" "$total_apps" >&2
            fi
            ((i++))
            sleep 0.1 2> /dev/null || sleep 1
        done
    ) &
    spinner_pid=$!

    # Process apps in parallel batches
    for app_data_tuple in "${app_data_tuples[@]}"; do
        ((app_count++))

        # Launch background process
        process_app_metadata "$app_data_tuple" "$temp_file" "$current_epoch" &
        pids+=($!)

        # Update progress to show scanning progress (use app_count as it increments smoothly)
        echo "$app_count" > "$progress_file"

        # Wait if we've hit max parallel limit
        if ((${#pids[@]} >= max_parallel)); then
            wait "${pids[0]}" 2> /dev/null
            pids=("${pids[@]:1}") # Remove first pid
        fi
    done

    # Wait for remaining background processes
    for pid in "${pids[@]}"; do
        wait "$pid" 2> /dev/null
    done

    # Stop the spinner and clear the line
    if [[ -n "$spinner_pid" ]]; then
        kill -TERM "$spinner_pid" 2> /dev/null || true
        wait "$spinner_pid" 2> /dev/null || true
    fi
    if [[ $inline_loading == true ]]; then
        printf "\033[H\033[2K" >&2
    else
        echo -ne "\r\033[K" >&2
    fi
    rm -f "$progress_file"

    # Check if we found any applications
    if [[ ! -s "$temp_file" ]]; then
        echo "No applications found to uninstall" >&2
        rm -f "$temp_file"
        return 1
    fi

    # Sort by last used (oldest first) and cache the result
    # Show brief processing message for large app lists
    if [[ $total_apps -gt 50 ]]; then
        if [[ $inline_loading == true ]]; then
            printf "\033[H\033[2KProcessing %d applications...\n" "$total_apps" >&2
        else
            printf "\rProcessing %d applications...    " "$total_apps" >&2
        fi
    fi

    sort -t'|' -k1,1n "$temp_file" > "${temp_file}.sorted" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    # Clear processing message
    if [[ $total_apps -gt 50 ]]; then
        if [[ $inline_loading == true ]]; then
            printf "\033[H\033[2K" >&2
        else
            printf "\r\033[K" >&2
        fi
    fi

    # Save to cache (simplified - no metadata)
    ensure_user_file "$cache_file"
    cp "${temp_file}.sorted" "$cache_file" 2> /dev/null || true

    # Return sorted file
    if [[ -f "${temp_file}.sorted" ]]; then
        echo "${temp_file}.sorted"
    else
        return 1
    fi
}

load_applications() {
    local apps_file="$1"

    if [[ ! -f "$apps_file" || ! -s "$apps_file" ]]; then
        log_warning "No applications found for uninstallation"
        return 1
    fi

    # Clear arrays
    apps_data=()
    selection_state=()

    # Read apps into array, skip non-existent apps
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        # Skip if app path no longer exists
        [[ ! -e "$app_path" ]] && continue

        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
        selection_state+=(false)
    done < "$apps_file"

    if [[ ${#apps_data[@]} -eq 0 ]]; then
        log_warning "No applications available for uninstallation"
        return 1
    fi

    return 0
}

# Cleanup function - restore cursor and clean up
cleanup() {
    # Restore cursor using common function
    if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
        leave_alt_screen
        unset MOLE_ALT_SCREEN_ACTIVE
    fi
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2> /dev/null || true
        wait "$sudo_keepalive_pid" 2> /dev/null || true
        sudo_keepalive_pid=""
    fi
    show_cursor
    exit "${1:-0}"
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

main() {
    local force_rescan=false
    for arg in "$@"; do
        case "$arg" in
            "--debug")
                export MO_DEBUG=1
                ;;
            "--force-rescan")
                force_rescan=true
                ;;
        esac
    done

    local use_inline_loading=false
    if [[ -t 1 && -t 2 ]]; then
        use_inline_loading=true
    fi

    # Hide cursor during operation
    hide_cursor

    # Main interaction loop
    while true; do
        # Simplified: always check if we need alt screen for scanning
        # (scan_applications handles cache internally)
        local needs_scanning=true
        local cache_file="$HOME/.cache/mole/app_scan_cache"
        if [[ $force_rescan == false && -f "$cache_file" ]]; then
            local cache_age=$(($(date +%s) - $(get_file_mtime "$cache_file")))
            [[ $cache_age -eq $(date +%s) ]] && cache_age=86401 # Handle missing file
            [[ $cache_age -lt 86400 ]] && needs_scanning=false
        fi

        # Only enter alt screen if we need scanning (shows progress)
        if [[ $needs_scanning == true && $use_inline_loading == true ]]; then
            # Only enter if not already active
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" != "1" ]]; then
                enter_alt_screen
                export MOLE_ALT_SCREEN_ACTIVE=1
                export MOLE_INLINE_LOADING=1
                export MOLE_MANAGED_ALT_SCREEN=1
            fi
            printf "\033[2J\033[H" >&2
        else
            # If we don't need scanning but have alt screen from previous iteration, keep it?
            # Actually, scan_applications might output to stderr.
            # Let's just unset the flags if we don't need scanning, but keep alt screen if it was active?
            # No, select_apps_for_uninstall will handle its own screen management.
            unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN MOLE_ALT_SCREEN_ACTIVE
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
            fi
        fi

        # Scan applications
        local apps_file=""
        if ! apps_file=$(scan_applications "$force_rescan"); then
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                printf "\033[2J\033[H" >&2
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
                unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
            fi
            return 1
        fi

        if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
            printf "\033[2J\033[H" >&2
        fi

        if [[ ! -f "$apps_file" ]]; then
            # Error message already shown by scan_applications
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
                unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
            fi
            return 1
        fi

        # Load applications
        if ! load_applications "$apps_file"; then
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
                unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
            fi
            rm -f "$apps_file"
            return 1
        fi

        # Interactive selection using paginated menu
        set +e
        select_apps_for_uninstall
        local exit_code=$?
        set -e

        if [[ $exit_code -ne 0 ]]; then
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
                unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
            fi
            show_cursor
            clear_screen
            printf '\033[2J\033[H' >&2 # Also clear stderr
            rm -f "$apps_file"

            # Handle Refresh (code 10)
            if [[ $exit_code -eq 10 ]]; then
                force_rescan=true
                continue
            fi

            # User cancelled selection, exit the loop
            return 0
        fi

        # Always clear on exit from selection, regardless of alt screen state
        if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
            leave_alt_screen
            unset MOLE_ALT_SCREEN_ACTIVE
            unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
        fi

        # Restore cursor and clear screen (output to both stdout and stderr for reliability)
        show_cursor
        clear_screen
        printf '\033[2J\033[H' >&2 # Also clear stderr in case of mixed output
        local selection_count=${#selected_apps[@]}
        if [[ $selection_count -eq 0 ]]; then
            echo "No apps selected"
            rm -f "$apps_file"
            # Loop back or exit? If select_apps_for_uninstall returns 0 but empty selection,
            # it technically shouldn't happen based on that function's logic.
            continue
        fi
        # Show selected apps with clean alignment
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Selected ${selection_count} app(s):"
        local -a summary_rows=()
        local max_name_width=0
        local max_size_width=0
        local max_last_width=0
        # First pass: get actual max widths for all columns
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ _ app_name _ size last_used _ <<< "$selected_app"
            [[ ${#app_name} -gt $max_name_width ]] && max_name_width=${#app_name}
            local size_display="$size"
            [[ -z "$size_display" || "$size_display" == "0" || "$size_display" == "N/A" ]] && size_display="Unknown"
            [[ ${#size_display} -gt $max_size_width ]] && max_size_width=${#size_display}
            local last_display=$(format_last_used_summary "$last_used")
            [[ ${#last_display} -gt $max_last_width ]] && max_last_width=${#last_display}
        done
        ((max_size_width < 5)) && max_size_width=5
        ((max_last_width < 5)) && max_last_width=5

        # Calculate name width: use actual max, but constrain by terminal width
        # Fixed elements: "99. " (4) + "  " (2) + "  |  Last: " (11) = 17
        local term_width=$(tput cols 2> /dev/null || echo 100)
        local available_for_name=$((term_width - 17 - max_size_width - max_last_width))

        # Dynamic minimum for better spacing on wide terminals
        local min_name_width=24
        if [[ $term_width -ge 120 ]]; then
            min_name_width=50
        elif [[ $term_width -ge 100 ]]; then
            min_name_width=42
        elif [[ $term_width -ge 80 ]]; then
            min_name_width=30
        fi

        # Constrain name width: dynamic min, max min(actual_max, available, 60)
        local name_trunc_limit=$max_name_width
        [[ $name_trunc_limit -lt $min_name_width ]] && name_trunc_limit=$min_name_width
        [[ $name_trunc_limit -gt $available_for_name ]] && name_trunc_limit=$available_for_name
        [[ $name_trunc_limit -gt 60 ]] && name_trunc_limit=60

        # Reset for second pass
        max_name_width=0

        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$selected_app"

            local display_name="$app_name"
            if [[ ${#display_name} -gt $name_trunc_limit ]]; then
                display_name="${display_name:0:$((name_trunc_limit - 3))}..."
            fi
            [[ ${#display_name} -gt $max_name_width ]] && max_name_width=${#display_name}

            local size_display="$size"
            if [[ -z "$size_display" || "$size_display" == "0" || "$size_display" == "N/A" ]]; then
                size_display="Unknown"
            fi

            local last_display
            last_display=$(format_last_used_summary "$last_used")

            summary_rows+=("$display_name|$size_display|$last_display")
        done

        ((max_name_width < 16)) && max_name_width=16

        local index=1
        for row in "${summary_rows[@]}"; do
            IFS='|' read -r name_cell size_cell last_cell <<< "$row"
            printf "%d. %-*s  %*s  |  Last: %s\n" "$index" "$max_name_width" "$name_cell" "$max_size_width" "$size_cell" "$last_cell"
            ((index++))
        done

        # Execute batch uninstallation (handles confirmation)
        batch_uninstall_applications

        # Cleanup current apps file
        rm -f "$apps_file"

        # Pause before looping back
        echo -e "${GRAY}Press Enter to return to application list, ESC to exit...${NC}"
        local key
        IFS= read -r -s -n1 key || key=""
        drain_pending_input # Clean up any escape sequence remnants
        case "$key" in
            $'\e' | q | Q)
                show_cursor
                return 0
                ;;
            *)
                # Continue loop
                ;;
        esac

        # Reset force_rescan to false for subsequent loops,
        # but relying on batch_uninstall's cache deletion for actual update
        force_rescan=false
    done
}

# Run main function
