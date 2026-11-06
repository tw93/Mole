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
source "$_MOLE_CORE_DIR/timeouts.sh"
source "$_MOLE_CORE_DIR/file_ops.sh"
source "$_MOLE_CORE_DIR/help.sh"
source "$_MOLE_CORE_DIR/ui.sh"
source "$_MOLE_CORE_DIR/app_protection.sh"
source "$_MOLE_CORE_DIR/bundle_resolver.sh"
source "$_MOLE_CORE_DIR/pkg_receipts.sh"

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
            fs_id=$("$STAT_BSD" -L -f '%d:%i' "$normalized" 2> /dev/null || "$STAT_BSD" -f '%d:%i' "$normalized" 2> /dev/null || true)
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

# Every docker command talks to the endpoint the current context or
# DOCKER_HOST names, which can be a remote engine over TCP or SSH. Mole reports
# and prunes this Mac only, so each Docker query asks first; `docker context
# inspect` reads local configuration and never dials the engine (#1922).
# Returns 0 for a local unix socket, 1 for docker missing or any other
# endpoint, 2 when the answer is unknown, and a signal status unchanged.
mole_docker_endpoint_is_local() {
    command -v docker > /dev/null 2>&1 || return 1
    local host="" rc=0
    host=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" docker context inspect --format '{{.Endpoints.docker.Host}}' 2> /dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        mole_rc_signal "$rc" && return "$rc"
        return 2
    fi
    [[ -n "$host" && "$host" != *$'\n'* ]] || return 2
    [[ "$host" == unix:///* ]] && return 0
    return 1
}

# True when a launcher entry provably belongs to a REMOVED Homebrew keg: a
# dangling symlink into Cellar/mole, or a regular file whose brew-written
# SCRIPT_DIR line names a Cellar/mole path that no longer exists (the #1488
# shape: a stale copy survived an upgrade, ran, and failed sourcing its libs).
# A healthy brew link, a healthy brew wrapper, and a manual install (whose
# SCRIPT_DIR points at the config dir, never Cellar) all return 1.
_mole_brew_entry_references_dead_cellar() {
    local entry="$1"
    [[ -n "$entry" ]] || return 1
    local referenced=""
    if [[ -L "$entry" ]]; then
        referenced=$(readlink "$entry" 2> /dev/null) || return 1
        [[ "$referenced" == *"Cellar/mole"* ]] || return 1
        # A resolvable link is healthy; only a dangling link into a removed
        # keg is evidence.
        [[ -e "$entry" ]] && return 1
        return 0
    fi
    [[ -f "$entry" ]] || return 1
    referenced=$(LC_ALL=C sed -n "s|^SCRIPT_DIR='\(.*/Cellar/mole/[^']*\)'.*$|\1|p" "$entry" 2> /dev/null | head -1)
    [[ -n "$referenced" ]] || return 1
    [[ ! -d "$referenced" ]]
}

# After a brew update/upgrade, make sure the launchers in brew's own bin still
# resolve. `brew upgrade` happily reports success (or "already installed")
# while a stale foreign entry keeps shadowing the real one, because brew never
# overwrites files it does not own; only evidence of a DEAD keg authorizes the
# forced relink, so a live manual install is never touched (#1488).
_mole_repair_stale_brew_entries() {
    command -v brew > /dev/null 2>&1 || return 0
    local brew_prefix=""
    brew_prefix=$(brew --prefix 2> /dev/null) || return 0
    [[ -n "$brew_prefix" && -d "$brew_prefix/bin" ]] || return 0

    local entry stale=false
    for entry in "$brew_prefix/bin/mole" "$brew_prefix/bin/mo"; do
        _mole_brew_entry_references_dead_cellar "$entry" && stale=true
    done
    [[ "$stale" == "true" ]] || return 0

    local relink_rc=0
    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
        run_with_timeout 120 \
        brew link --overwrite mole > /dev/null 2>&1 || relink_rc=$?
    if [[ $relink_rc -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Repaired stale launcher, now pointing at the current Homebrew install"
    else
        log_warning "Launcher still points at a removed Homebrew version"
        printf 'Run: brew link --overwrite mole\n' >&2
    fi
}

# The first items of a release's "### Changelog" list, each cut to its title:
# the release notes write every item as "Title: detail".
mole_release_highlight_titles() {
    local body="$1" limit="${2:-4}" line item in_list=false count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == "### Changelog"* ]]; then
            in_list=true
            continue
        fi
        [[ "$in_list" == true ]] || continue
        [[ "$line" == "### "* ]] && break
        [[ "$line" =~ ^[0-9]+\.[[:space:]]+(.+)$ ]] || continue
        item="${BASH_REMATCH[1]}"
        item="${item%%: *}"
        printf '%s\n' "$item"
        count=$((count + 1))
        if [[ $count -ge $limit ]]; then
            break
        fi
    done <<< "$body"
}

# After a stable update, a few lines on what the new version changed, read from
# its published release (maintainer 2026-11-01). Best effort and terminal only:
# offline, a rate limit or a body without the list prints nothing.
mole_print_release_highlights() {
    local version="${1#[Vv]}" body titles title
    [[ -t 1 ]] || return 0
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    body=$(curl -fsSL --connect-timeout "${MOLE_LOOKUP_CONNECT_TIMEOUT:-2}" --max-time "${MOLE_LOOKUP_MAX_TIME:-3}" \
        "https://api.github.com/repos/tw93/mole/releases/tags/V${version}" 2> /dev/null |
        /usr/bin/plutil -extract body raw -o - - 2> /dev/null) || return 0
    titles=$(mole_release_highlight_titles "$body" 4)
    [[ -n "$titles" ]] || return 0
    printf "What's new in %s\n" "$version"
    while IFS= read -r title; do
        printf '  %s %s\n' "$ICON_LIST" "$title"
    done <<< "$titles"
    printf '  %s\n\n' "${GRAY}https://github.com/tw93/Mole/releases/tag/V${version}${NC}"
}

# Update via Homebrew
update_via_homebrew() {
    local current_version="$1"
    local temp_update temp_upgrade
    temp_update=$(mktemp_file "brew_update")
    temp_upgrade=$(mktemp_file "brew_upgrade")

    # Set up trap for interruption (Ctrl+C) with inline cleanup
    trap 'stop_inline_spinner 2>/dev/null; rm -f "$temp_update" "$temp_upgrade"; echo ""; exit 130' INT TERM # SAFE: own mktemp scratch files

    # Update Homebrew
    if [[ -t 1 ]]; then
        start_inline_spinner "Updating Homebrew..."
    else
        echo "Updating Homebrew..."
    fi

    local brew_update_timeout=120
    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
        run_with_timeout "$brew_update_timeout" brew update > "$temp_update" 2>&1 || true

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Upgrade Mole
    if [[ -t 1 ]]; then
        start_inline_spinner "Upgrading Mole..."
    else
        echo "Upgrading Mole..."
    fi

    local brew_upgrade_timeout=120
    local upgrade_status=0
    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
        run_with_timeout "$brew_upgrade_timeout" brew upgrade mole > "$temp_upgrade" 2>&1 || upgrade_status=$?

    local upgrade_output
    upgrade_output=$(cat "$temp_upgrade")

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Clear trap
    trap - INT TERM

    # Cleanup temp files
    # Own mktemp scratch files: safe_remove would log them as cleanup rows.
    rm -f "$temp_update" "$temp_upgrade" # SAFE: own mktemp scratch files

    if [[ "$upgrade_status" -ne 0 ]]; then
        log_error "Homebrew upgrade failed"
        if [[ -n "$upgrade_output" ]]; then
            printf '%s\n' "$upgrade_output" >&2
        else
            printf 'brew upgrade mole exited with status %s\n' "$upgrade_status" >&2
        fi
        return 1
    elif echo "$upgrade_output" | grep -q "already installed"; then
        local installed_version
        installed_version=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
            run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew list --versions mole 2> /dev/null | awk '{print $2}')
        [[ -z "$installed_version" ]] && installed_version=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            mo --version 2> /dev/null | awk '/Mole version/ {print $3; exit}' || true)
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on latest version, ${installed_version:-$current_version}"
        echo ""
    else
        echo "$upgrade_output" | grep -Ev "^(==>|Updating Homebrew|Warning:)" || true
        local new_version
        new_version=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
            run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew list --versions mole 2> /dev/null | awk '{print $2}')
        [[ -z "$new_version" ]] && new_version=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            mo --version 2> /dev/null | awk '/Mole version/ {print $3; exit}' || true)
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Updated to latest version, ${new_version:-$current_version}"
        echo ""
        # Record the update before the network highlights fetch, so Ctrl-C
        # during that fetch cannot drop the row for a change already made.
        log_operation "update" "REBUILT" "Homebrew mole" "updated to ${new_version:-unknown}"
        mole_print_release_highlights "${new_version:-}"
    fi

    # Both success shapes can leave a stale foreign launcher shadowing the
    # fresh keg (brew never overwrites files it does not own); heal it while
    # the user is right here asking for an update.
    _mole_repair_stale_brew_entries

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
        local bundle_id=""
        local full_path=""

        if [[ "$target" == *"|"* ]]; then
            app_path="${target%%|*}"
            bundle_id="${target#*|}"
        fi

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
        local raw_path="$full_path"

        local dock_array
        for dock_array in persistent-apps persistent-others recent-apps; do
            local i=0
            while true; do
                local tile_type
                tile_type=$(/usr/libexec/PlistBuddy -c "Print :$dock_array:$i:tile-type" "$plist" 2> /dev/null || echo "")
                [[ -z "$tile_type" ]] && break

                local url dock_bundle_id
                url=$(/usr/libexec/PlistBuddy -c "Print :$dock_array:$i:tile-data:file-data:_CFURLString" "$plist" 2> /dev/null || echo "")
                dock_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :$dock_array:$i:tile-data:bundle-identifier" "$plist" 2> /dev/null || echo "")

                if { [[ -n "$bundle_id" && "$dock_bundle_id" == "$bundle_id" ]] ||
                    [[ -n "$encoded_path" && "$url" == *"$encoded_path"* ]] ||
                    [[ -n "$raw_path" && "$url" == *"$raw_path"* ]]; }; then
                    if /usr/libexec/PlistBuddy -c "Delete :$dock_array:$i" "$plist" 2> /dev/null; then
                        changed=true
                        log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "REMOVED" "$full_path" "dock entry"
                        # After deletion, current index i now points to the next item.
                        continue
                    fi
                fi
                i=$((i + 1))
            done
        done
    done

    if [[ "$changed" == "true" ]]; then
        # Restart Dock to apply changes from the plist
        killall Dock 2> /dev/null || true
    fi
}
