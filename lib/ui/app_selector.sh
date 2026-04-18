#!/bin/bash
# App selection functionality

set -euo pipefail

# Note: get_display_width() is now defined in lib/core/ui.sh

# Format app info for display
format_app_display() {
    local display_name="$1" size="$2" last_used="$3"

    # Use common function from ui.sh to format last used time
    local compact_last_used
    compact_last_used=$(format_last_used_summary "$last_used")
    if [[ -z "$compact_last_used" || "$compact_last_used" == "Never" || "$compact_last_used" == "Hiç" ]]; then
        compact_last_used="${TR_UNKNOWN:-Unknown}"
    fi

    # Format size
    local size_str="--"
    [[ "$size" != "0" && "$size" != "" && "$size" != "Unknown" && "$size" != "N/A" && "$size" != "--" ]] && size_str="$size"

    # Calculate available width for app name based on terminal width
    # Accept pre-calculated max_name_width (5th param) to avoid recalculation in loops
    local terminal_width="${4:-$(tput cols 2> /dev/null || echo 80)}"
    local max_name_width="${5:-}"
    local available_width

    if [[ -n "$max_name_width" ]]; then
        # Use pre-calculated width from caller
        available_width=$max_name_width
    else
        # Fallback: calculate it (slower, but works for standalone calls)
        # Fixed elements: "  ○ " (4) + " " (1) + size (9) + " | " (3) + max_last (7) = 24
        local fixed_width=24
        available_width=$((terminal_width - fixed_width))

        # Dynamic minimum for better spacing on wide terminals
        local min_width=18
        if [[ $terminal_width -ge 120 ]]; then
            min_width=48
        elif [[ $terminal_width -ge 100 ]]; then
            min_width=38
        elif [[ $terminal_width -ge 80 ]]; then
            min_width=25
        fi

        [[ $available_width -lt $min_width ]] && available_width=$min_width
        [[ $available_width -gt 60 ]] && available_width=60
    fi

    # Truncate long names if needed (based on display width, not char count)
    local truncated_name
    truncated_name=$(truncate_by_display_width "$display_name" "$available_width")

    # Get actual display width after truncation
    local current_display_width
    current_display_width=$(get_display_width "$truncated_name")

    # Calculate padding needed
    # Formula: char_count + (available_width - display_width) = padding to add
    local char_count=${#truncated_name}
    local padding_needed=$((available_width - current_display_width))
    local printf_width=$((char_count + padding_needed))

    # Use dynamic column width with corrected padding
    printf "%-*s %9s | %s" "$printf_width" "$truncated_name" "$size_str" "$compact_last_used"
}

# Global variable to store selection result (bash 3.2 compatible)
MOLE_SELECTION_RESULT=""

# Main app selection function
# shellcheck disable=SC2154  # apps_data is set by caller
select_apps_for_uninstall() {
    if [[ ${#apps_data[@]} -eq 0 ]]; then
        log_warning "${TR_APPSEL_NO_APPS:-No applications available for uninstallation}"
        return 1
    fi

    # Build menu options
    # Show loading for large lists (formatting can be slow due to width calculations)
    local app_count=${#apps_data[@]}
    local terminal_width=$(tput cols 2> /dev/null || echo 80)
    if [[ $app_count -gt 100 ]]; then
        if [[ -t 2 ]]; then
            printf "\r${TR_APPSEL_PREPARING:-Preparing %d applications...}    " "$app_count" >&2
        fi
    fi

    # Pre-scan to get actual max name width
    local max_name_width=0
    for app_data in "${apps_data[@]}"; do
        IFS='|' read -r _ _ display_name _ _ _ _ <<< "$app_data"
        local name_width=$(get_display_width "$display_name")
        [[ $name_width -gt $max_name_width ]] && max_name_width=$name_width
    done
    # Constrain based on terminal width: fixed=24, min varies by terminal width, max=60
    local fixed_width=24
    local available=$((terminal_width - fixed_width))

    # Dynamic minimum: wider terminals get larger minimum for better spacing
    local min_width=18
    if [[ $terminal_width -ge 120 ]]; then
        min_width=48 # Wide terminals: very generous spacing
    elif [[ $terminal_width -ge 100 ]]; then
        min_width=38 # Medium-wide terminals: generous spacing
    elif [[ $terminal_width -ge 80 ]]; then
        min_width=25 # Standard terminals
    fi

    [[ $max_name_width -lt $min_width ]] && max_name_width=$min_width
    [[ $available -lt $max_name_width ]] && max_name_width=$available
    [[ $max_name_width -gt 60 ]] && max_name_width=60

    local -a menu_options=()
    local epochs_csv=""
    local sizekb_csv=""
    local -a names_arr=()
    local has_epoch_metadata=false
    local has_size_metadata=false
    local idx=0
    for app_data in "${apps_data[@]}"; do
        IFS='|' read -r epoch _ display_name _ size last_used size_kb <<< "$app_data"
        menu_options+=("$(format_app_display "$display_name" "$size" "$last_used" "$terminal_width" "$max_name_width")")
        [[ "${epoch:-0}" =~ ^[0-9]+$ && "${epoch:-0}" -gt 0 ]] && has_epoch_metadata=true
        [[ "${size_kb:-0}" =~ ^[0-9]+$ && "${size_kb:-0}" -gt 0 ]] && has_size_metadata=true
        if [[ $idx -eq 0 ]]; then
            epochs_csv="${epoch:-0}"
            sizekb_csv="${size_kb:-0}"
        else
            epochs_csv+=",${epoch:-0}"
            sizekb_csv+=",${size_kb:-0}"
        fi
        names_arr+=("$display_name")
        idx=$((idx + 1))
    done
    # Use newline separator for names (safe for names with commas)
    local names_newline
    names_newline=$(printf '%s\n' "${names_arr[@]}")

    # Clear loading message
    if [[ $app_count -gt 100 ]]; then
        if [[ -t 2 ]]; then
            printf "\r\033[K" >&2
        fi
    fi

    # Expose metadata for the paginated menu (optional inputs)
    # - MOLE_MENU_META_EPOCHS: numeric last_used_epoch per item
    # - MOLE_MENU_META_SIZEKB: numeric size in KB per item
    # The menu will gracefully fallback if these are unset or malformed.
    if [[ $has_epoch_metadata == true ]]; then
        export MOLE_MENU_META_EPOCHS="$epochs_csv"
    else
        unset MOLE_MENU_META_EPOCHS
    fi
    if [[ $has_size_metadata == true ]]; then
        export MOLE_MENU_META_SIZEKB="$sizekb_csv"
    else
        unset MOLE_MENU_META_SIZEKB
    fi
    export MOLE_MENU_FILTER_NAMES="$names_newline"

    # Use paginated menu - result will be stored in MOLE_SELECTION_RESULT
    # Note: paginated_multi_select enters alternate screen and handles clearing
    MOLE_SELECTION_RESULT=""
    paginated_multi_select "${TR_UNINSTALL_SELECT:-Select Apps to Remove}" "${menu_options[@]}"
    local exit_code=$?

    # Clean env leakage for safety
    unset MOLE_MENU_META_EPOCHS MOLE_MENU_META_SIZEKB MOLE_MENU_FILTER_NAMES
    # leave MOLE_MENU_SORT_DEFAULT untouched if user set it globally

    if [[ $exit_code -ne 0 ]]; then
        return 1
    fi

    if [[ -z "$MOLE_SELECTION_RESULT" ]]; then
        echo "${TR_UNINSTALL_NO_SELECTED:-No apps selected}"
        return 1
    fi

    # Build selected apps array (global variable in bin/uninstall.sh)
    selected_apps=()

    # Parse indices and build selected apps array
    IFS=',' read -r -a indices_array <<< "$MOLE_SELECTION_RESULT"

    for idx in "${indices_array[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ $idx -ge 0 ]] && [[ $idx -lt ${#apps_data[@]} ]]; then
            selected_apps+=("${apps_data[idx]}")
        fi
    done

    return 0
}

# Export function for external use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library file. Source it from other scripts." >&2
    exit 1
fi
