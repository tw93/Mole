#!/bin/bash
# Mole - Homebrew Cask Uninstallation Support
# Detects Homebrew-managed casks via Caskroom linkage and uninstalls them via brew

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_BREW_UNINSTALL_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_BREW_UNINSTALL_LOADED=1

# Resolve a path to its absolute real path (follows symlinks)
# Args: $1 - path to resolve
# Returns: Absolute resolved path, or empty string on failure
resolve_path() {
    local p="$1"
    [[ -e "$p" ]] || return 1

    # macOS 12.3+ and Linux have realpath
    if realpath "$p" 2> /dev/null; then
        return 0
    fi

    # Fallback: use cd -P to resolve directory, then append basename
    local dir base
    dir=$(cd -P "$(dirname "$p")" 2> /dev/null && pwd) || return 1
    base=$(basename "$p")
    echo "$dir/$base"
}

# Check if Homebrew is installed and accessible
# Returns: 0 if brew is available, 1 otherwise
is_homebrew_available() {
    command -v brew > /dev/null 2>&1
}

# Run brew, dropping privileges when invoked as root.
# Homebrew refuses to run under EUID 0 ("Running Homebrew as root is extremely
# dangerous..."). When mole is launched via `sudo mo …`, transparently re-run
# brew as the invoking user so uninstall/list operations succeed.
# Exits non-zero (and prints an error) when root but no SUDO_USER is available.
mole_brew() {
    if [[ "$(id -u)" -ne 0 ]]; then
        brew "$@"
        return
    fi

    local drop_user="${SUDO_USER:-}"
    if [[ -z "$drop_user" || "$drop_user" == "root" ]]; then
        printf 'Error: Homebrew cannot run as root. Re-run mole without sudo.\n' >&2
        return 1
    fi

    sudo --preserve-env=HOMEBREW_NO_ENV_HINTS,HOMEBREW_NO_AUTO_UPDATE,HOMEBREW_NO_ANALYTICS,NONINTERACTIVE \
        -u "$drop_user" -H -- brew "$@"
}

# Check whether a cask is still recorded as installed in Homebrew.
# Exit codes:
#   0 - cask is installed
#   1 - cask is not installed
#   2 - install state could not be determined
is_brew_cask_installed() {
    local cask_name="$1"
    [[ -n "$cask_name" ]] || return 2
    is_homebrew_available || return 2

    local cask_list
    cask_list=$(HOMEBREW_NO_ENV_HINTS=1 mole_brew list --cask 2> /dev/null) || return 2
    grep -qxF "$cask_name" <<< "$cask_list"
}

# Extract cask token from a Caskroom path
# Args: $1 - path (must be inside Caskroom)
# Prints: cask token to stdout
# Returns: 0 if valid token extracted, 1 otherwise
_extract_cask_token_from_path() {
    local path="$1"

    # Check if path is inside Caskroom
    case "$path" in
        /opt/homebrew/Caskroom/* | /usr/local/Caskroom/*) ;;
        *) return 1 ;;
    esac

    # Extract token from path: /opt/homebrew/Caskroom/<token>/<version>/...
    local token
    token="${path#*/Caskroom/}" # Remove everything up to and including Caskroom/
    token="${token%%/*}"        # Take only the first path component

    # Validate token looks like a valid cask name (lowercase alphanumeric with hyphens)
    if [[ -n "$token" && "$token" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "$token"
        return 0
    fi

    return 1
}

# Stage 1: Deterministic detection via fully resolved path
# Fast, no false positives - follows all symlinks
_detect_cask_via_resolved_path() {
    local app_path="$1"
    local resolved
    if resolved=$(resolve_path "$app_path") && [[ -n "$resolved" ]]; then
        _extract_cask_token_from_path "$resolved" && return 0
    fi
    return 1
}

# Stage 2: Search Caskroom by app bundle name using find
# Catches apps where the .app in /Applications doesn't link to Caskroom
# Only succeeds if exactly one cask matches (avoids wrong uninstall)
_detect_cask_via_caskroom_search() {
    local app_bundle_name="$1"
    [[ -z "$app_bundle_name" ]] && return 1

    local -a tokens=()
    local room match token

    for room in "/opt/homebrew/Caskroom" "/usr/local/Caskroom"; do
        [[ -d "$room" ]] || continue
        while IFS= read -r match; do
            [[ -n "$match" ]] || continue
            token=$(_extract_cask_token_from_path "$match" 2> /dev/null) || continue
            [[ -n "$token" ]] && tokens+=("$token")
        done < <(find "$room" -maxdepth 3 -name "$app_bundle_name" 2> /dev/null)
    done

    # Need at least one token
    ((${#tokens[@]} > 0)) || return 1

    # Deduplicate and check count
    local -a uniq
    IFS=$'\n' read -r -d '' -a uniq < <(printf '%s\n' "${tokens[@]}" | sort -u && printf '\0') || true

    # Only succeed if exactly one unique token found and it's installed
    if ((${#uniq[@]} == 1)) && [[ -n "${uniq[0]}" ]]; then
        HOMEBREW_NO_ENV_HINTS=1 mole_brew list --cask 2> /dev/null | grep -qxF "${uniq[0]}" || return 1
        echo "${uniq[0]}"
        return 0
    fi

    return 1
}

# Stage 3: Check if app_path is a direct symlink to Caskroom
_detect_cask_via_symlink_check() {
    local app_path="$1"
    [[ -L "$app_path" ]] || return 1

    local target
    target=$(readlink "$app_path" 2> /dev/null) || return 1
    _extract_cask_token_from_path "$target"
}

# Stage 4: Query brew list --cask and verify with brew info (slowest fallback)
_detect_cask_via_brew_list() {
    local app_path="$1"
    local app_bundle_name="$2"
    local app_name_lower
    app_name_lower=$(echo "${app_bundle_name%.app}" | LC_ALL=C tr '[:upper:]' '[:lower:]')

    local cask_name
    cask_name=$(HOMEBREW_NO_ENV_HINTS=1 mole_brew list --cask 2> /dev/null | grep -Fix "$app_name_lower") || return 1

    # Verify this cask actually owns this app path
    HOMEBREW_NO_ENV_HINTS=1 mole_brew info --cask "$cask_name" 2> /dev/null | grep -qF "$app_path" || return 1
    echo "$cask_name"
}

# Get Homebrew cask name for an app
# Uses multi-stage detection (fast to slow, deterministic to heuristic):
#   1. Resolve symlinks fully, check if path is in Caskroom (fast, deterministic)
#   2. Search Caskroom by app bundle name using find
#   3. Check if app is a direct symlink to Caskroom
#   4. Query brew list --cask and verify with brew info (slowest)
#
# Args: $1 - app_path
# Prints: cask token to stdout if brew-managed
# Returns: 0 if Homebrew-managed, 1 otherwise
get_brew_cask_name() {
    local app_path="$1"
    [[ -z "$app_path" || ! -e "$app_path" ]] && return 1
    is_homebrew_available || return 1

    local app_bundle_name
    app_bundle_name=$(basename "$app_path")

    # Try each detection method in order (fast to slow)
    _detect_cask_via_resolved_path "$app_path" && return 0
    _detect_cask_via_caskroom_search "$app_bundle_name" && return 0
    _detect_cask_via_symlink_check "$app_path" && return 0
    _detect_cask_via_brew_list "$app_path" "$app_bundle_name" && return 0

    return 1
}

# Uninstall a Homebrew cask and verify removal
# Args: $1 - cask_name, $2 - app_path (optional, for verification)
# Returns: 0 on success, 1 on failure
brew_uninstall_cask() {
    local cask_name="$1"
    local app_path="${2:-}"

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would brew uninstall --cask --zap $cask_name"
        return 0
    fi

    is_homebrew_available || return 1
    [[ -z "$cask_name" ]] && return 1

    debug_log "Attempting brew uninstall --cask --zap $cask_name"

    local uninstall_ok=false
    local brew_exit=0

    # Calculate timeout based on app size (large apps need more time)
    local timeout=300 # Default 5 minutes
    if [[ -n "$app_path" && -d "$app_path" ]]; then
        local size_gb=$(($(get_path_size_kb "$app_path") / 1048576))
        if [[ $size_gb -gt 15 ]]; then
            timeout=900 # 15 minutes for very large apps (Xcode, Adobe, etc.)
        elif [[ $size_gb -gt 5 ]]; then
            timeout=600 # 10 minutes for large apps
        fi
        debug_log "App size: ${size_gb}GB, timeout: ${timeout}s"
    fi

    # Run with timeout to prevent hangs from problematic cask scripts
    local brew_exit=0
    if HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
        run_with_timeout "$timeout" mole_brew uninstall --cask --zap "$cask_name" 2>&1; then
        uninstall_ok=true
    else
        brew_exit=$?
        debug_log "brew uninstall timeout or failed with exit code: $brew_exit"
        # Exit code 124 indicates timeout from run_with_timeout
        # On timeout, fail immediately without verification to avoid inconsistent state
        if [[ $brew_exit -eq 124 ]]; then
            debug_log "brew uninstall timed out after ${timeout}s, returning failure"
            return 1
        fi
    fi

    # Verify removal (only if not timed out)
    local cask_gone=true app_gone=true
    if is_brew_cask_installed "$cask_name"; then
        cask_gone=false
    else
        local cask_state=$?
        [[ $cask_state -eq 1 ]] || cask_gone=false
    fi
    [[ -n "$app_path" && -e "$app_path" ]] && app_gone=false

    # Success: uninstall worked and both are gone, or already uninstalled
    if $cask_gone && $app_gone; then
        debug_log "Successfully uninstalled cask '$cask_name'"
        return 0
    fi

    debug_log "brew uninstall failed: cask_gone=$cask_gone app_gone=$app_gone"
    return 1
}
