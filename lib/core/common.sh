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
source "$_MOLE_CORE_DIR/log.sh"

source "$_MOLE_CORE_DIR/timeout.sh"
source "$_MOLE_CORE_DIR/file_ops.sh"
source "$_MOLE_CORE_DIR/ui.sh"
source "$_MOLE_CORE_DIR/app_protection.sh"

# Load sudo management if available
if [[ -f "$_MOLE_CORE_DIR/sudo.sh" ]]; then
    source "$_MOLE_CORE_DIR/sudo.sh"
fi

# Update via Homebrew
update_via_homebrew() {
    local current_version="$1"
    local temp_update temp_upgrade
    temp_update=$(mktemp_file "brew_update")
    temp_upgrade=$(mktemp_file "brew_upgrade")

    # Set up trap for interruption (Ctrl+C) with inline cleanup
    trap 'stop_inline_spinner 2>/dev/null; rm -f -- "$temp_update" "$temp_upgrade" 2>/dev/null; echo ""; exit 130' INT TERM

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
    rm -f "$temp_update" "$temp_upgrade"

    if echo "$upgrade_output" | grep -q "already installed"; then
        local installed_version
        installed_version=$(brew list --versions mole 2> /dev/null | awk '{print $2}')
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest version (${installed_version:-$current_version})"
        echo ""
    elif echo "$upgrade_output" | grep -q "Error:"; then
        log_error "Homebrew upgrade failed"
        echo "$upgrade_output" | grep "Error:" >&2
        return 1
    else
        echo "$upgrade_output" | grep -Ev "^(==>|Updating Homebrew|Warning:)" || true
        local new_version
        new_version=$(brew list --versions mole 2> /dev/null | awk '{print $2}')
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Updated to latest version (${new_version:-$current_version})"
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

    local plist="$HOME/Library/Preferences/com.apple.dock.plist"
    [[ -f "$plist" ]] || return 0

    if ! command -v python3 > /dev/null 2>&1; then
        return 0
    fi

    # Prune dock entries using Python helper
    python3 - "$@" << 'PY' 2> /dev/null || return 0
import os
import plistlib
import subprocess
import sys
import urllib.parse

plist_path = os.path.expanduser('~/Library/Preferences/com.apple.dock.plist')
if not os.path.exists(plist_path):
    sys.exit(0)

def normalise(path):
    if not path:
        return ''
    return os.path.normpath(os.path.realpath(path.rstrip('/')))

targets = {normalise(arg) for arg in sys.argv[1:] if arg}
targets = {t for t in targets if t}
if not targets:
    sys.exit(0)

with open(plist_path, 'rb') as fh:
    try:
        data = plistlib.load(fh)
    except Exception:
        sys.exit(0)

apps = data.get('persistent-apps')
if not isinstance(apps, list):
    sys.exit(0)

changed = False
filtered = []
for item in apps:
    try:
        url = item['tile-data']['file-data']['_CFURLString']
    except (KeyError, TypeError):
        filtered.append(item)
        continue

    if not isinstance(url, str):
        filtered.append(item)
        continue

    parsed = urllib.parse.urlparse(url)
    path = urllib.parse.unquote(parsed.path or '')
    if not path:
        filtered.append(item)
        continue

    candidate = normalise(path)
    if any(candidate == t or candidate.startswith(t + os.sep) for t in targets):
        changed = True
        continue

    filtered.append(item)

if not changed:
    sys.exit(0)

data['persistent-apps'] = filtered
with open(plist_path, 'wb') as fh:
    try:
        plistlib.dump(data, fh, fmt=plistlib.FMT_BINARY)
    except Exception:
        plistlib.dump(data, fh)

# Restart Dock to apply changes
try:
    subprocess.run(['killall', 'Dock'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
except Exception:
    pass
PY
}
