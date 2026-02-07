#!/bin/bash
# Mole - Uninstall command.
# Interactive app uninstaller.
# Removes app files and leftovers.

set -euo pipefail

# Fix locale issues on non-English systems.
export LC_ALL=C
export LANG=C

# Load shared helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

# Clean temp files on exit.
trap cleanup_temp_files EXIT INT TERM
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/../lib/ui/app_selector.sh"
source "$SCRIPT_DIR/../lib/uninstall/batch.sh"

# State
selected_apps=()
declare -a apps_data=()
declare -a selection_state=()
total_items=0
files_cleaned=0
total_size_cleaned=0

# Scan applications and collect information.
scan_applications() {
    # Cache app scan (24h TTL).
    local cache_dir="$HOME/.cache/mole"
    local cache_file="$cache_dir/app_scan_cache"
    local cache_ttl=86400 # 24 hours
    local force_rescan="${1:-false}"

    ensure_user_dir "$cache_dir"

    if [[ $force_rescan == false && -f "$cache_file" ]]; then
        local cache_age=$(($(get_epoch_seconds) - $(get_file_mtime "$cache_file")))
        [[ $cache_age -eq $(get_epoch_seconds) ]] && cache_age=86401 # Handle mtime read failure
        if [[ $cache_age -lt $cache_ttl ]]; then
            if [[ -t 2 ]]; then
                echo -e "${GREEN}Loading from cache...${NC}" >&2
                sleep 0.3 # Brief pause so user sees the message
            fi
            echo "$cache_file"
            return 0
        fi
    fi

    local inline_loading=false
    if [[ -t 1 && -t 2 ]]; then
        inline_loading=true
        printf "\033[2J\033[H" >&2 # Clear screen for inline loading
    fi

    local temp_file
    temp_file=$(create_temp_file)

    # Local spinner_pid for cleanup
    local spinner_pid=""

    # Trap to handle Ctrl+C during scan
    local scan_interrupted=false
    # shellcheck disable=SC2329  # Function invoked indirectly via trap
    trap_scan_cleanup() {
        scan_interrupted=true
        if [[ -n "$spinner_pid" ]]; then
            kill -TERM "$spinner_pid" 2> /dev/null || true
            wait "$spinner_pid" 2> /dev/null || true
        fi
        printf "\r\033[K" >&2
        rm -f "$temp_file" "${temp_file}.sorted" "${temp_file}.progress" 2> /dev/null || true
        exit 130
    }
    trap trap_scan_cleanup INT

    local current_epoch
    current_epoch=$(get_epoch_seconds)

    # Pass 1: collect app paths and bundle IDs (no mdls).
    local -a app_data_tuples=()
    local -a app_dirs=(
        "/Applications"
        "$HOME/Applications"
        "/Library/Input Methods"
        "$HOME/Library/Input Methods"
    )
    local vol_app_dir
    local nullglob_was_set=0
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for vol_app_dir in /Volumes/*/Applications; do
        [[ -d "$vol_app_dir" && -r "$vol_app_dir" ]] || continue
        if [[ -d "/Applications" && "$vol_app_dir" -ef "/Applications" ]]; then
            continue
        fi
        if [[ -d "$HOME/Applications" && "$vol_app_dir" -ef "$HOME/Applications" ]]; then
            continue
        fi
        app_dirs+=("$vol_app_dir")
    done
    if [[ $nullglob_was_set -eq 0 ]]; then
        shopt -u nullglob
    fi

    for app_dir in "${app_dirs[@]}"; do
        if [[ ! -d "$app_dir" ]]; then continue; fi

        while IFS= read -r -d '' app_path; do
            if [[ ! -e "$app_path" ]]; then continue; fi

            local app_name
            app_name=$(basename "$app_path" .app)

            # Skip nested apps inside another .app bundle.
            local parent_dir
            parent_dir=$(dirname "$app_path")
            if [[ "$parent_dir" == *".app" || "$parent_dir" == *".app/"* ]]; then
                continue
            fi

            # Bundle ID from plist (fast path).
            local bundle_id="unknown"
            if [[ -f "$app_path/Contents/Info.plist" ]]; then
                bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2> /dev/null || echo "unknown")
            fi

            if should_protect_from_uninstall "$bundle_id"; then
                continue
            fi

            # Store tuple for pass 2 (metadata + size).
            app_data_tuples+=("${app_path}|${app_name}|${bundle_id}")
        done < <(command find "$app_dir" -name "*.app" -maxdepth 3 -print0 2> /dev/null)
    done

    if [[ ${#app_data_tuples[@]} -eq 0 ]]; then
        rm -f "$temp_file"
        printf "\r\033[K" >&2
        echo "No applications found to uninstall." >&2
        return 1
    fi
    # Pass 2: metadata + size in parallel (mdls is slow).
    local app_count=0
    local total_apps=${#app_data_tuples[@]}
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

        # Display name priority: mdls display name → bundle display → bundle name → folder.
        local display_name="$app_name"
        if [[ -f "$app_path/Contents/Info.plist" ]]; then
            local md_display_name
            md_display_name=$(run_with_timeout 0.05 mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")

            local bundle_display_name
            bundle_display_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist" 2> /dev/null)
            local bundle_name
            bundle_name=$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist" 2> /dev/null)

            if [[ "$md_display_name" == /* ]]; then md_display_name=""; fi
            md_display_name="${md_display_name//|/-}"
            md_display_name="${md_display_name//[$'\t\r\n']/}"

            bundle_display_name="${bundle_display_name//|/-}"
            bundle_display_name="${bundle_display_name//[$'\t\r\n']/}"

            bundle_name="${bundle_name//|/-}"
            bundle_name="${bundle_name//[$'\t\r\n']/}"

            if [[ -n "$md_display_name" && "$md_display_name" != "(null)" && "$md_display_name" != "$app_name" ]]; then
                display_name="$md_display_name"
            elif [[ -n "$bundle_display_name" && "$bundle_display_name" != "(null)" ]]; then
                display_name="$bundle_display_name"
            elif [[ -n "$bundle_name" && "$bundle_name" != "(null)" ]]; then
                display_name="$bundle_name"
            fi
        fi

        if [[ "$display_name" == /* ]]; then
            display_name="$app_name"
        fi
        display_name="${display_name//|/-}"
        display_name="${display_name//[$'\t\r\n']/}"

        # App size (KB → human).
        local app_size="N/A"
        local app_size_kb="0"
        if [[ -d "$app_path" ]]; then
            app_size_kb=$(get_path_size_kb "$app_path")
            app_size=$(bytes_to_human "$((app_size_kb * 1024))")
        fi

        # Last used: mdls (fast timeout) → mtime.
        local last_used="Never"
        local last_used_epoch=0

        if [[ -d "$app_path" ]]; then
            local metadata_date
            metadata_date=$(run_with_timeout 0.1 mdls -name kMDItemLastUsedDate -raw "$app_path" 2> /dev/null || echo "")

            if [[ "$metadata_date" != "(null)" && -n "$metadata_date" ]]; then
                last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$metadata_date" "+%s" 2> /dev/null || echo "0")
            fi

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

    (
        # shellcheck disable=SC2329  # Function invoked indirectly via trap
        cleanup_spinner() { exit 0; }
        trap cleanup_spinner TERM INT EXIT
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

# Cleanup: restore cursor and kill keepalive.
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
    # Log session end
    log_operation_session_end "uninstall" "${files_cleaned:-0}" "${total_size_cleaned:-0}"
    show_cursor
    exit "${1:-0}"
}

trap cleanup EXIT INT TERM

main() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="uninstall"
    log_operation_session_start "uninstall"

    local force_rescan=false
    # Global flags
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                echo "Usage: mo uninstall [OPTIONS]"
                echo ""
                echo "Interactively remove applications and their leftover files."
                echo ""
                echo "Options:"
                echo "  --debug           Show detailed operation logs"
                echo "  -h, --help        Show this help message"
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
        esac
    done

    local use_inline_loading=false
    if [[ -t 1 && -t 2 ]]; then
        use_inline_loading=true
    fi

    hide_cursor

    while true; do
        local needs_scanning=true
        local cache_file="$HOME/.cache/mole/app_scan_cache"
        if [[ $force_rescan == false && -f "$cache_file" ]]; then
            local cache_age=$(($(get_epoch_seconds) - $(get_file_mtime "$cache_file")))
            [[ $cache_age -eq $(get_epoch_seconds) ]] && cache_age=86401
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
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Selected ${selection_count} apps:"
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
