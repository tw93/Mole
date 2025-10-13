#!/bin/bash
# App selection functionality

set -euo pipefail

# Format app info for display
format_app_display() {
    local display_name="$1" size="$2" last_used="$3"

    # Truncate long names
    local truncated_name="$display_name"
    if [[ ${#display_name} -gt 24 ]]; then
        truncated_name="${display_name:0:21}..."
    fi

    # Format size
    local size_str="Unknown"
    [[ "$size" != "0" && "$size" != "" && "$size" != "Unknown" ]] && size_str="$size"

    printf "%-24s (%s) | %s" "$truncated_name" "$size_str" "$last_used"
}

# Global variable to store selection result (bash 3.2 compatible)
MOLE_SELECTION_RESULT=""

# Main app selection function
# shellcheck disable=SC2154  # apps_data is set by caller
select_apps_for_uninstall() {
    if [[ ${#apps_data[@]} -eq 0 ]]; then
        log_warning "No applications available for uninstallation"
        return 1
    fi

    # Build menu options
    local -a menu_options=()
    # Prepare metadata (comma-separated) for sorting/filtering inside the menu
    local epochs_csv=""
    local sizekb_csv=""
    local idx=0
    for app_data in "${apps_data[@]}"; do
        # Keep extended field 7 (size_kb) if present
        IFS='|' read -r epoch _ display_name _ size last_used size_kb <<< "$app_data"
        menu_options+=("$(format_app_display "$display_name" "$size" "$last_used")")
        # Build csv lists (avoid trailing commas)
        if [[ $idx -eq 0 ]]; then
            epochs_csv="${epoch:-0}"
            sizekb_csv="${size_kb:-0}"
        else
            epochs_csv+=",${epoch:-0}"
            sizekb_csv+=",${size_kb:-0}"
        fi
        ((idx++))
    done

    # Expose metadata for the paginated menu (optional inputs)
    # - MOLE_MENU_META_EPOCHS: numeric last_used_epoch per item
    # - MOLE_MENU_META_SIZEKB: numeric size in KB per item
    # The menu will gracefully fallback if these are unset or malformed.
    export MOLE_MENU_META_EPOCHS="$epochs_csv"
    export MOLE_MENU_META_SIZEKB="$sizekb_csv"
    # Optional: allow default sort override via env (date|name|size)
    # export MOLE_MENU_SORT_DEFAULT="${MOLE_MENU_SORT_DEFAULT:-date}"

    # Use paginated menu - result will be stored in MOLE_SELECTION_RESULT
    # Note: paginated_multi_select enters alternate screen and handles clearing
    MOLE_SELECTION_RESULT=""
    paginated_multi_select "Select Apps to Remove" "${menu_options[@]}"
    local exit_code=$?

    # Clean env leakage for safety
    unset MOLE_MENU_META_EPOCHS MOLE_MENU_META_SIZEKB
    # leave MOLE_MENU_SORT_DEFAULT untouched if user set it globally

    if [[ $exit_code -ne 0 ]]; then
        echo "Cancelled"
        return 1
    fi

    if [[ -z "$MOLE_SELECTION_RESULT" ]]; then
        echo "No apps selected"
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
