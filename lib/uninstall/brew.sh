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

# Run a read-only Homebrew probe under a hard deadline. The bash wrapper keeps
# exported test doubles working while production still resolves the real brew
# executable from PATH. More importantly, timeout/signal statuses remain
# distinguishable from a legitimate "not installed" result.
_mole_brew_probe() {
    local duration="$1"
    shift

    if declare -F brew > /dev/null 2>&1; then
        export -f brew
    fi

    HOMEBREW_NO_ENV_HINTS=1 run_with_timeout "$duration" \
        /bin/bash --noprofile --norc -c 'brew "$@"' mole-brew-probe "$@"
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

    local cask_list=""
    local list_rc=0
    cask_list=$(_mole_brew_probe "$MOLE_TIMEOUT_PKG_LIST_SEC" \
        list --cask 2> /dev/null) || list_rc=$?
    [[ $list_rc -eq 124 || $list_rc -ge 128 ]] && return "$list_rc"
    [[ $list_rc -eq 0 ]] || return 2
    grep -qxF "$cask_name" <<< "$cask_list"
}

# Extract cask token from a Caskroom path
# Args: $1 - path (must be inside Caskroom)
# Prints: cask token to stdout
# Returns: 0 if valid token extracted, 1 otherwise
_extract_cask_token_from_path() {
    local path="$1"

    # Check if path is inside Caskroom. Quote literals so Homebrew bottle
    # relocation cannot break parsing when the prefix contains spaces.
    case "$path" in
        "/opt/homebrew/Caskroom/"* | "/usr/local/Caskroom/"*) ;;
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
        [[ "$(basename "$resolved")" == "$(basename "$app_path")" ]] || return 1
        _extract_cask_token_from_path "$resolved" && return 0
    fi
    return 1
}

# Stage 2: Search Caskroom by app bundle name using find
# Catches apps where the .app in /Applications doesn't link to Caskroom
# Only succeeds if exactly one cask matches (avoids wrong uninstall)
_detect_cask_via_caskroom_search() {
    local app_bundle_name="$1"
    local app_path="${2:-}"
    [[ -z "$app_bundle_name" ]] && return 1

    local -a tokens=()
    local room match token
    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_deadline=$((SECONDS + MOLE_TIMEOUT_PKG_LIST_SEC))

    for room in "/opt/homebrew/Caskroom" "/usr/local/Caskroom"; do
        [[ -d "$room" ]] || continue
        local scan_timeout=""
        local scan_rc=0
        scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            "$scan_deadline") || scan_rc=$?
        if [[ $scan_rc -eq 0 ]]; then
            : > "$scan_file" || scan_rc=1
        fi
        if [[ $scan_rc -eq 0 ]]; then
            run_with_timeout "$scan_timeout" find "$room" -maxdepth 3 \
                -name "$app_bundle_name" < /dev/null > "$scan_file" \
                2> /dev/null || scan_rc=$?
        fi
        if [[ $scan_rc -ne 0 ]]; then
            : > "$scan_file" || true
            rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
            return "$scan_rc"
        fi
        while IFS= read -r match; do
            [[ -n "$match" ]] || continue
            token=$(_extract_cask_token_from_path "$match" 2> /dev/null) || continue
            [[ -n "$token" ]] && tokens+=("$token")
        done < "$scan_file"
    done
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    # Need at least one token
    ((${#tokens[@]} > 0)) || return 1

    # Deduplicate and check count
    local -a uniq=()
    local candidate existing seen
    for candidate in "${tokens[@]}"; do
        seen=false
        for existing in "${uniq[@]+"${uniq[@]}"}"; do
            if [[ "$candidate" == "$existing" ]]; then
                seen=true
                break
            fi
        done
        [[ "$seen" == true ]] || uniq+=("$candidate")
    done

    # Only succeed if exactly one unique token found and it's installed
    if ((${#uniq[@]} == 1)) && [[ -n "${uniq[0]}" ]]; then
        local cask_list=""
        local list_rc=0
        cask_list=$(_mole_brew_probe "$MOLE_TIMEOUT_PKG_LIST_SEC" \
            list --cask 2> /dev/null) || list_rc=$?
        [[ $list_rc -eq 124 || $list_rc -ge 128 ]] && return "$list_rc"
        [[ $list_rc -eq 0 ]] || return 2
        grep -qxF "${uniq[0]}" <<< "$cask_list" || return 1

        local info_output=""
        local info_rc=0
        info_output=$(_mole_brew_probe "$MOLE_TIMEOUT_PKG_LIST_SEC" \
            info --cask "${uniq[0]}" 2> /dev/null) || info_rc=$?
        [[ $info_rc -eq 124 || $info_rc -ge 128 ]] && return "$info_rc"
        if [[ $info_rc -ne 0 ]]; then
            # The exact Caskroom bundle path plus an installed cask token is
            # already sufficient ownership evidence here. `brew info` cannot
            # resolve some third-party tap casks by their short token even
            # though `brew list --cask` can report the installed token. Keep
            # this optional verification from aborting the whole uninstall;
            # brew_uninstall_cask remains the final operation and reports any
            # inability to remove the recorded cask.
            debug_log "Homebrew info unavailable for cask '${uniq[0]}'; using exact Caskroom match"
        elif [[ -n "$app_path" ]]; then
            if grep -qF "$app_path" <<< "$info_output"; then
                :
            elif [[ "$app_path" == "/Applications/$app_bundle_name" ]] && grep -qF "$app_bundle_name" <<< "$info_output"; then
                :
            else
                return 1
            fi
        fi
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
    [[ "$(basename "$target")" == "$(basename "$app_path")" ]] || return 1
    _extract_cask_token_from_path "$target"
}

# Stage 4: Query brew list --cask and verify with brew info (slowest fallback)
_detect_cask_via_brew_list() {
    local app_path="$1"
    local app_bundle_name="$2"
    local app_base_name
    local app_name_lower
    app_base_name="${app_bundle_name%.[aA][pP][pP]}"
    app_name_lower=$(printf '%s' "$app_base_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')

    local cask_list=""
    local list_rc=0
    cask_list=$(_mole_brew_probe "$MOLE_TIMEOUT_PKG_LIST_SEC" \
        list --cask 2> /dev/null) || list_rc=$?
    [[ $list_rc -eq 124 || $list_rc -ge 128 ]] && return "$list_rc"
    [[ $list_rc -eq 0 ]] || return 2

    local cask_name=""
    cask_name=$(grep -Fix "$app_name_lower" <<< "$cask_list") || return 1

    # Verify this cask actually owns this app path or app bundle.
    local info_output=""
    local info_rc=0
    info_output=$(_mole_brew_probe "$MOLE_TIMEOUT_PKG_LIST_SEC" \
        info --cask "$cask_name" 2> /dev/null) || info_rc=$?
    [[ $info_rc -eq 124 || $info_rc -ge 128 ]] && return "$info_rc"
    [[ $info_rc -eq 0 ]] || return 2
    if grep -qF "$app_path" <<< "$info_output"; then
        echo "$cask_name"
        return 0
    fi
    if [[ "$app_path" == "/Applications/$app_bundle_name" ]] && grep -qF "$app_bundle_name" <<< "$info_output"; then
        echo "$cask_name"
        return 0
    fi
    return 1
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
    local detect_rc=0
    _detect_cask_via_resolved_path "$app_path" || detect_rc=$?
    [[ $detect_rc -eq 0 ]] && return 0
    [[ $detect_rc -eq 1 ]] || return "$detect_rc"

    detect_rc=0
    _detect_cask_via_caskroom_search "$app_bundle_name" "$app_path" || detect_rc=$?
    [[ $detect_rc -eq 0 ]] && return 0
    [[ $detect_rc -eq 1 ]] || return "$detect_rc"

    detect_rc=0
    _detect_cask_via_symlink_check "$app_path" || detect_rc=$?
    [[ $detect_rc -eq 0 ]] && return 0
    [[ $detect_rc -eq 1 ]] || return "$detect_rc"

    detect_rc=0
    _detect_cask_via_brew_list "$app_path" "$app_bundle_name" || detect_rc=$?
    [[ $detect_rc -eq 0 ]] && return 0
    [[ $detect_rc -eq 1 ]] || return "$detect_rc"

    return 1
}

# Uninstall a Homebrew cask and verify removal
# Args: $1 - cask_name, $2 - app_path (optional, for verification),
#       $3 - zap mode: "nozap" runs a plain uninstall without --zap. Used when
#            another install shares the cask's bundle id: zap stanzas delete
#            bundle-id-keyed prefs/caches that the surviving install still
#            uses (iterm2 and iterm2-beta both zap com.googlecode.iterm2).
# Returns: 0 on success, 1 on ordinary failure, 124 on timeout, or the
# original signal-style status when the operation is interrupted.
brew_uninstall_cask() {
    local cask_name="$1"
    local app_path="${2:-}"
    local zap_mode="${3:-zap}"

    local -a uninstall_args=(uninstall --cask)
    if [[ "$zap_mode" != "nozap" ]]; then
        uninstall_args+=(--zap)
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would brew ${uninstall_args[*]} $cask_name"
        return 0
    fi

    is_homebrew_available || return 1
    [[ -z "$cask_name" ]] && return 1

    debug_log "Attempting brew ${uninstall_args[*]} $cask_name"

    local uninstall_ok=false
    local brew_exit=0

    # Calculate timeout based on app size (large apps need more time)
    local timeout=300 # Default 5 minutes
    if [[ -n "$app_path" && -d "$app_path" ]]; then
        local size_kb=0
        local size_rc=0
        size_kb=$(get_path_size_kb "$app_path") || size_rc=$?
        [[ $size_rc -eq 124 || $size_rc -ge 128 ]] && return "$size_rc"
        [[ $size_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        local size_gb=$((size_kb / 1048576))
        if [[ $size_gb -gt 15 ]]; then
            timeout=900 # 15 minutes for very large apps (Xcode, Adobe, etc.)
        elif [[ $size_gb -gt 5 ]]; then
            timeout=600 # 10 minutes for large apps
        fi
        debug_log "App size: ${size_gb}GB, timeout: ${timeout}s"
    fi

    # Run with timeout to prevent hangs from problematic cask scripts.
    if [[ -n "${SUDO_USER:-}" ]]; then
        if run_with_timeout "$timeout" sudo -u "$SUDO_USER" env \
            HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
            brew "${uninstall_args[@]}" "$cask_name" 2>&1; then
            uninstall_ok=true
        else
            brew_exit=$?
        fi
    elif HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
        run_with_timeout "$timeout" brew "${uninstall_args[@]}" "$cask_name" 2>&1; then
        uninstall_ok=true
    else
        brew_exit=$?
    fi

    if [[ "$uninstall_ok" != "true" ]]; then
        debug_log "brew uninstall timeout or failed with exit code: $brew_exit"
        # Timeout and signal statuses are cancellation, not evidence that a
        # partially completed cask action can safely fall back to direct app
        # deletion. Preserve them before any verification.
        if [[ $brew_exit -eq 124 ]]; then
            debug_log "brew uninstall timed out after ${timeout}s, returning failure"
            return 124
        elif [[ $brew_exit -ge 128 ]]; then
            return "$brew_exit"
        fi
    fi

    # Verify removal (only if not timed out)
    local cask_gone=true app_gone=true
    local cask_state=0
    if is_brew_cask_installed "$cask_name"; then
        cask_gone=false
    else
        cask_state=$?
        [[ $cask_state -ge 128 ]] && return "$cask_state"
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
