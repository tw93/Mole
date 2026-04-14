#!/bin/bash
# Mole - Common Functions Library
# Main entry point that loads all core modules

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_COMMON_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core modules
source "$_MOLE_CORE_DIR/base.sh"
prepare_mole_tmpdir > /dev/null
source "$_MOLE_CORE_DIR/log.sh"

source "$_MOLE_CORE_DIR/timeout.sh"
source "$_MOLE_CORE_DIR/file_ops.sh"
source "$_MOLE_CORE_DIR/help.sh"
source "$_MOLE_CORE_DIR/ui.sh"
source "$_MOLE_CORE_DIR/app_protection.sh"
source "$_MOLE_CORE_DIR/bundle_resolver.sh"

# Load sudo management if available
if [[ -f "$_MOLE_CORE_DIR/sudo.sh" ]]; then
    source "$_MOLE_CORE_DIR/sudo.sh"
fi

# Normalize a path for comparisons while preserving root.
mole_normalize_path() {
    local path="$1"
    local normalized="${path%/}"
    [[ -n "$normalized" ]] && printf '%s\n' "$normalized" || printf '%s\n' "$path"
}

# Return a stable identity for an existing path. Prefer dev+inode so aliased
# paths on case-insensitive filesystems or symlinks collapse to one identity.
mole_path_identity() {
    local path="$1"
    local normalized
    normalized=$(mole_normalize_path "$path")

    if [[ -e "$normalized" || -L "$normalized" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local fs_id=""
            fs_id=$(stat -L -f '%d:%i' "$normalized" 2> /dev/null || stat -f '%d:%i' "$normalized" 2> /dev/null || true)
            if [[ "$fs_id" =~ ^[0-9]+:[0-9]+$ ]]; then
                printf 'inode:%s\n' "$fs_id"
                return 0
            fi
        fi
    fi

    printf 'path:%s\n' "$normalized"
}

mole_identity_in_list() {
    local needle="$1"
    shift

    local existing
    for existing in "$@"; do
        [[ "$existing" == "$needle" ]] && return 0
    done
    return 1
}

# Update via Homebrew
update_via_homebrew() {
    local current_version="$1"
    local temp_update temp_upgrade
    temp_update=$(mktemp_file "brew_update")
    temp_upgrade=$(mktemp_file "brew_upgrade")

    # Set up trap for interruption (Ctrl+C) with inline cleanup
    trap 'stop_inline_spinner 2>/dev/null; safe_remove "$temp_update" true; safe_remove "$temp_upgrade" true; echo ""; exit 130' INT TERM

    # Update Homebrew
    if [[ -t 1 ]]; then
        start_inline_spinner "Updating Homebrew..."
    else
        echo "Updating Homebrew..."
    fi

    brew update > "$temp_update" 2>&1 &
    local update_pid=$!
    wait $update_pid 2> /dev/null || true # Continue even if brew update fails

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Upgrade Mole
    if [[ -t 1 ]]; then
        start_inline_spinner "Upgrading Mole..."
    else
        echo "Upgrading Mole..."
    fi

    brew upgrade mole > "$temp_upgrade" 2>&1 &
    local upgrade_pid=$!
    wait $upgrade_pid 2> /dev/null || true # Continue even if brew upgrade fails

    local upgrade_output
    upgrade_output=$(cat "$temp_upgrade")

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Clear trap
    trap - INT TERM

    # Cleanup temp files
    safe_remove "$temp_update" true
    safe_remove "$temp_upgrade" true

    if echo "$upgrade_output" | grep -q "already installed"; then
        local installed_version
        installed_version=$(brew list --versions mole 2> /dev/null | awk '{print $2}')
        [[ -z "$installed_version" ]] && installed_version=$(mo --version 2> /dev/null | awk '/Mole version/ {print $3; exit}')
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest version, ${installed_version:-$current_version}"
        echo ""
    elif echo "$upgrade_output" | grep -q "Error:"; then
        log_error "Homebrew upgrade failed"
        echo "$upgrade_output" | grep "Error:" >&2
        return 1
    else
        echo "$upgrade_output" | grep -Ev "^(==>|Updating Homebrew|Warning:)" || true
        local new_version
        new_version=$(brew list --versions mole 2> /dev/null | awk '{print $2}')
        [[ -z "$new_version" ]] && new_version=$(mo --version 2> /dev/null | awk '/Mole version/ {print $3; exit}')
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Updated to latest version, ${new_version:-$current_version}"
        echo ""
    fi

    # Clear update cache (suppress errors if cache doesn't exist or is locked)
    rm -f "$HOME/.cache/mole/version_check" "$HOME/.cache/mole/update_message" 2> /dev/null || true
}

# Remove applications from Dock
remove_apps_from_dock() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local -a targets=()
    for arg in "$@"; do
        [[ -n "$arg" ]] && targets+=("$arg")
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        return 0
    fi

    # Use pure shell (PlistBuddy) to remove items from Dock
    # This avoids dependencies on Python 3 or osascript (AppleScript)
    local plist="$HOME/Library/Preferences/com.apple.dock.plist"
    [[ -f "$plist" ]] || return 0

    # PlistBuddy is at /usr/libexec/PlistBuddy on macOS
    [[ -x /usr/libexec/PlistBuddy ]] || return 0

    local changed=false
    for target in "${targets[@]}"; do
        local app_path="$target"
        local full_path=""

        if [[ "$app_path" =~ [[:cntrl:]] ]]; then
            debug_log "Skipping dock removal for path with control chars: $app_path"
            continue
        fi

        if [[ -e "$app_path" ]]; then
            if full_path=$(cd "$(dirname "$app_path")" 2> /dev/null && pwd); then
                full_path="$full_path/$(basename "$app_path")"
            else
                continue
            fi
        else
            case "$app_path" in
                ~/*) full_path="$HOME/${app_path#~/}" ;;
                /*) full_path="$app_path" ;;
                *) continue ;;
            esac
        fi

        [[ -z "$full_path" ]] && continue

        local encoded_path="${full_path// /%20}"

        # Find the index of the app in persistent-apps
        local i=0
        while true; do
            local label
            label=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-label" "$plist" 2> /dev/null || echo "")
            [[ -z "$label" ]] && break

            local url
            url=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2> /dev/null || echo "")
            [[ -z "$url" ]] && {
                i=$((i + 1))
                continue
            }

            # Match by URL-encoded path to handle spaces in app names
            if [[ -n "$encoded_path" && "$url" == *"$encoded_path"* ]]; then
                if /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$plist" 2> /dev/null; then
                    changed=true
                    # After deletion, current index i now points to the next item
                    continue
                fi
            fi
            i=$((i + 1))
        done
    done

    if [[ "$changed" == "true" ]]; then
        # Restart Dock to apply changes from the plist
        killall Dock 2> /dev/null || true
    fi
}
