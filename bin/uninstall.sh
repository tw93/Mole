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

# Initialize global variables
selected_apps=()
declare -a apps_data=()
declare -a selection_state=()
total_items=0
files_cleaned=0
total_size_cleaned=0

# Scan applications and collect information
scan_applications() {
    # Application scan with intelligent caching (24h TTL)
    # This speeds up repeated scans significantly by caching app metadata
    local cache_dir="$HOME/.cache/mole"
    local cache_file="$cache_dir/app_scan_cache"
    local cache_ttl=86400 # 24 hours
    local force_rescan="${1:-false}"

    ensure_user_dir "$cache_dir"

    # Check if cache exists and is fresh
    if [[ $force_rescan == false && -f "$cache_file" ]]; then
        local cache_age=$(($(date +%s) - $(get_file_mtime "$cache_file")))
        [[ $cache_age -eq $(date +%s) ]] && cache_age=86401 # Handle mtime read failure
        if [[ $cache_age -lt $cache_ttl ]]; then
            # Cache hit - show brief feedback and return cached results
            if [[ -t 2 ]]; then
                echo -e "${GREEN}Loading from cache...${NC}" >&2
                sleep 0.3 # Brief pause so user sees the message
            fi
            echo "$cache_file"
            return 0
        fi
    fi

    # Cache miss - perform full scan
    local inline_loading=false
    if [[ -t 1 && -t 2 ]]; then
        inline_loading=true
        printf "\033[2J\033[H" >&2 # Clear screen for inline loading
    fi

    local temp_file
    temp_file=$(create_temp_file)

    # Pre-cache current epoch to avoid repeated date calls
    local current_epoch
    current_epoch=$(date "+%s")

    # First pass: quickly collect all valid app paths and bundle IDs
    # This pass does NOT call mdls (slow) - only reads plists (fast)
    local -a app_data_tuples=()
    local -a app_dirs=(
        "/Applications"
        "$HOME/Applications"
    )

    for app_dir in "${app_dirs[@]}"; do
        if [[ ! -d "$app_dir" ]]; then continue; fi

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

            # Get bundle ID (fast plist read, no mdls call yet)
            local bundle_id="unknown"
            if [[ -f "$app_path/Contents/Info.plist" ]]; then
                bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2> /dev/null || echo "unknown")
            fi

            # Skip system critical apps (input methods, system components, etc.)
            if should_protect_from_uninstall "$bundle_id"; then
                continue
            fi

            # Store tuple: app_path|app_name|bundle_id
            # Display name and metadata will be resolved in parallel later (second pass)
            app_data_tuples+=("${app_path}|${app_name}|${bundle_id}")
        done < <(command find "$app_dir" -name "*.app" -maxdepth 3 -print0 2> /dev/null)
    done

    # Second pass: process each app with parallel metadata extraction
    # This pass calls mdls (slow) and calculates sizes, but does so in parallel
    local app_count=0
    local total_apps=${#app_data_tuples[@]}
    # Bound parallelism - for metadata queries, can go higher since it's mostly waiting
    local max_parallel
    max_parallel=$(get_optimal_parallel_jobs "io")
    if [[ $max_parallel -lt 8 ]]; then
        max_parallel=8 # At least 8 for good performance
    elif [[ $max_parallel -gt 32 ]]; then
        max_parallel=32 # Cap at 32 to avoid too many processes
    fi
    local pids=()

    process_app_metadata() {
        local app_data_tuple="$1"
        local output_file="$2"
        local current_epoch="$3"

        IFS='|' read -r app_path app_name bundle_id <<< "$app_data_tuple"

        # Get localized display name (moved from first pass for better performance)
        # Priority order for name selection (prefer localized names):
        # 1. System metadata display name (kMDItemDisplayName) - respects system language
        # 2. CFBundleDisplayName - usually localized
        # 3. CFBundleName - fallback
        # 4. App folder name - last resort
        local display_name="$app_name"
        if [[ -f "$app_path/Contents/Info.plist" ]]; then
            # Try to get localized name from system metadata (best for i18n)
            local md_display_name
            md_display_name=$(run_with_timeout 0.05 mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")

            # Get bundle names from plist
            local bundle_display_name
            bundle_display_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist" 2> /dev/null)
            local bundle_name
            bundle_name=$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist" 2> /dev/null)

            # Sanitize metadata values (prevent paths, pipes, and newlines)
            if [[ "$md_display_name" == /* ]]; then md_display_name=""; fi
            md_display_name="${md_display_name//|/-}"
            md_display_name="${md_display_name//[$'\t\r\n']/}"

            bundle_display_name="${bundle_display_name//|/-}"
            bundle_display_name="${bundle_display_name//[$'\t\r\n']/}"

            bundle_name="${bundle_name//|/-}"
            bundle_name="${bundle_name//[$'\t\r\n']/}"

            # Select best available name
            if [[ -n "$md_display_name" && "$md_display_name" != "(null)" && "$md_display_name" != "$app_name" ]]; then
                display_name="$md_display_name"
            elif [[ -n "$bundle_display_name" && "$bundle_display_name" != "(null)" ]]; then
                display_name="$bundle_display_name"
            elif [[ -n "$bundle_name" && "$bundle_name" != "(null)" ]]; then
                display_name="$bundle_name"
            fi
        fi

        # Final safety check: if display_name looks like a path, revert to app_name
        if [[ "$display_name" == /* ]]; then
            display_name="$app_name"
        fi
        # Ensure no pipes or newlines in final display name
        display_name="${display_name//|/-}"
        display_name="${display_name//[$'\t\r\n']/}"

        # Calculate app size (in parallel for performance)
        local app_size="N/A"
        local app_size_kb="0"
        if [[ -d "$app_path" ]]; then
            # Get size in KB, then format for display
            app_size_kb=$(get_path_size_kb "$app_path")
            app_size=$(bytes_to_human "$((app_size_kb * 1024))")
        fi

        # Get last used date with fallback strategy
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

        echo "${last_used_epoch}|${app_path}|${display_name}|${bundle_id}|${app_size}|${last_used}|${app_size_kb}" >> "$output_file"
    }

    export -f process_app_metadata

    local progress_file="${temp_file}.progress"
    echo "0" > "$progress_file"

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
        process_app_metadata "$app_data_tuple" "$temp_file" "$current_epoch" &
        pids+=($!)
        echo "$app_count" > "$progress_file"

        if ((${#pids[@]} >= max_parallel)); then
            wait "${pids[0]}" 2> /dev/null
            pids=("${pids[@]:1}")
        fi
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2> /dev/null
    done

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

    if [[ ! -s "$temp_file" ]]; then
        echo "No applications found to uninstall" >&2
        rm -f "$temp_file"
        return 1
    fi

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

    if [[ $total_apps -gt 50 ]]; then
        if [[ $inline_loading == true ]]; then
            printf "\033[H\033[2K" >&2
        else
            printf "\r\033[K" >&2
        fi
    fi

    ensure_user_file "$cache_file"
    cp "${temp_file}.sorted" "$cache_file" 2> /dev/null || true

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

    apps_data=()
    selection_state=()

    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
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

    hide_cursor

    # Main interaction loop
    while true; do
        local needs_scanning=true
        local cache_file="$HOME/.cache/mole/app_scan_cache"
        if [[ $force_rescan == false && -f "$cache_file" ]]; then
            local cache_age=$(($(date +%s) - $(get_file_mtime "$cache_file")))
            [[ $cache_age -eq $(date +%s) ]] && cache_age=86401
            [[ $cache_age -lt 86400 ]] && needs_scanning=false
        fi

        if [[ $needs_scanning == true && $use_inline_loading == true ]]; then
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" != "1" ]]; then
                enter_alt_screen
                export MOLE_ALT_SCREEN_ACTIVE=1
                export MOLE_INLINE_LOADING=1
                export MOLE_MANAGED_ALT_SCREEN=1
            fi
            printf "\033[2J\033[H" >&2
        else
            unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN MOLE_ALT_SCREEN_ACTIVE
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
            fi
        fi

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
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
                unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
            fi
            return 1
        fi

        if ! load_applications "$apps_file"; then
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                leave_alt_screen
                unset MOLE_ALT_SCREEN_ACTIVE
                unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
            fi
            rm -f "$apps_file"
            return 1
        fi

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
            printf '\033[2J\033[H' >&2
            rm -f "$apps_file"

            if [[ $exit_code -eq 10 ]]; then
                force_rescan=true
                continue
            fi

            return 0
        fi

        if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
            leave_alt_screen
            unset MOLE_ALT_SCREEN_ACTIVE
            unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN
        fi

        show_cursor
        clear_screen
        printf '\033[2J\033[H' >&2
        local selection_count=${#selected_apps[@]}
        if [[ $selection_count -eq 0 ]]; then
            echo "No apps selected"
            rm -f "$apps_file"
            continue
        fi
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Selected ${selection_count} app(s):"
        local -a summary_rows=()
        local max_name_display_width=0
        local max_size_width=0
        local max_last_width=0
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ _ app_name _ size last_used _ <<< "$selected_app"
            local name_width=$(get_display_width "$app_name")
            [[ $name_width -gt $max_name_display_width ]] && max_name_display_width=$name_width
            local size_display="$size"
            [[ -z "$size_display" || "$size_display" == "0" || "$size_display" == "N/A" ]] && size_display="Unknown"
            [[ ${#size_display} -gt $max_size_width ]] && max_size_width=${#size_display}
            local last_display=$(format_last_used_summary "$last_used")
            [[ ${#last_display} -gt $max_last_width ]] && max_last_width=${#last_display}
        done
        ((max_size_width < 5)) && max_size_width=5
        ((max_last_width < 5)) && max_last_width=5

        local term_width=$(tput cols 2> /dev/null || echo 100)
        local available_for_name=$((term_width - 17 - max_size_width - max_last_width))

        local min_name_width=24
        if [[ $term_width -ge 120 ]]; then
            min_name_width=50
        elif [[ $term_width -ge 100 ]]; then
            min_name_width=42
        elif [[ $term_width -ge 80 ]]; then
            min_name_width=30
        fi

        local name_trunc_limit=$max_name_display_width
        [[ $name_trunc_limit -lt $min_name_width ]] && name_trunc_limit=$min_name_width
        [[ $name_trunc_limit -gt $available_for_name ]] && name_trunc_limit=$available_for_name
        [[ $name_trunc_limit -gt 60 ]] && name_trunc_limit=60

        max_name_display_width=0

        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$selected_app"

            local display_name
            display_name=$(truncate_by_display_width "$app_name" "$name_trunc_limit")

            local current_width
            current_width=$(get_display_width "$display_name")
            [[ $current_width -gt $max_name_display_width ]] && max_name_display_width=$current_width

            local size_display="$size"
            if [[ -z "$size_display" || "$size_display" == "0" || "$size_display" == "N/A" ]]; then
                size_display="Unknown"
            fi

            local last_display
            last_display=$(format_last_used_summary "$last_used")

            summary_rows+=("$display_name|$size_display|$last_display")
        done

        ((max_name_display_width < 16)) && max_name_display_width=16

        local index=1
        for row in "${summary_rows[@]}"; do
            IFS='|' read -r name_cell size_cell last_cell <<< "$row"
            local name_display_width
            name_display_width=$(get_display_width "$name_cell")
            local name_char_count=${#name_cell}
            local padding_needed=$((max_name_display_width - name_display_width))
            local printf_name_width=$((name_char_count + padding_needed))

            printf "%d. %-*s  %*s  |  Last: %s\n" "$index" "$printf_name_width" "$name_cell" "$max_size_width" "$size_cell" "$last_cell"
            ((index++))
        done

        batch_uninstall_applications

        rm -f "$apps_file"

        echo -e "${GRAY}Press Enter to return to application list, any other key to exit...${NC}"
        local key
        IFS= read -r -s -n1 key || key=""
        drain_pending_input

        if [[ -z "$key" ]]; then
            :
        else
            show_cursor
            return 0
        fi

        force_rescan=false
    done
}

main "$@"
