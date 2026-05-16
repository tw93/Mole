#!/bin/bash
# System Configuration Maintenance Module.
# Fix broken preferences and login items.

set -euo pipefail

_preference_plist_is_protected() {
    local plist_file="$1"
    local protect_loginwindow="${2:-false}"
    local filename="${plist_file##*/}"

    case "$filename" in
        com.apple.* | .GlobalPreferences*)
            return 0
            ;;
        loginwindow.plist)
            [[ "$protect_loginwindow" == "true" ]]
            return
            ;;
    esac

    return 1
}

_repair_preference_plists_in_dir() {
    local search_dir="$1"
    local maxdepth="$2"
    local protect_loginwindow="${3:-false}"
    [[ -d "$search_dir" ]] || {
        echo "0"
        return 0
    }

    local -a find_args=("$search_dir")
    if [[ "$maxdepth" -gt 0 ]]; then
        find_args+=("-maxdepth" "$maxdepth")
    fi
    find_args+=("-name" "*.plist" "-type" "f")

    local broken_count=0
    local plist_file=""
    while IFS= read -r plist_file; do
        [[ -f "$plist_file" ]] || continue
        _preference_plist_is_protected "$plist_file" "$protect_loginwindow" && continue

        plutil -lint "$plist_file" > /dev/null 2>&1 && continue

        if [[ "${MO_DEBUG:-}" == "1" ]]; then
            debug_file_action "  Removing corrupted plist" "$plist_file"
        fi
        safe_remove "$plist_file" true > /dev/null 2>&1 || true
        broken_count=$((broken_count + 1))
    done < <(command find "${find_args[@]}" 2> /dev/null || true)

    echo "$broken_count"
}

# Remove corrupted preference files.
fix_broken_preferences() {
    local prefs_dir="$HOME/Library/Preferences"
    [[ -d "$prefs_dir" ]] || return 0

    local broken_count=0
    local repaired_count=0

    repaired_count=$(_repair_preference_plists_in_dir "$prefs_dir" 1 true)
    broken_count=$((broken_count + repaired_count))

    # Check ByHost preferences recursively.
    repaired_count=$(_repair_preference_plists_in_dir "$prefs_dir/ByHost" 0 false)
    broken_count=$((broken_count + repaired_count))

    echo "$broken_count"
}
