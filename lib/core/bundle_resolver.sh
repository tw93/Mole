#!/bin/bash
# Mole - Bundle ID resolution.
# Resolves whether a bundle ID belongs to an installed application on this system.
# Spotlight (mdfind) is unreliable: indexing can be off for /Applications, Homebrew
# installs sometimes skip metadata importers, and Spotlight rarely indexes helpers
# embedded inside .app bundles. This resolver falls back to a direct filesystem
# scan that reads each app's Info.plist and checks SMJobBless-registered helpers.

if [[ -n "${_MOLE_BUNDLE_RESOLVER_LOADED:-}" ]]; then
    return 0
fi
readonly _MOLE_BUNDLE_RESOLVER_LOADED=1

# Session cache. Parallel indexed arrays because macOS ships bash 3.2 which has
# no associative arrays. Cache is expected to stay small (dozens of entries at
# most), so linear scan is fine.
_MOLE_BUNDLE_CACHE_KEYS=()
_MOLE_BUNDLE_CACHE_VALS=()

# Standard locations for installed apps on macOS.
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=(
    "/Applications"
    "/Applications/Setapp"
    "/Applications/Utilities"
    "$HOME/Applications"
)

# Reset the resolver cache. Intended for tests.
# shellcheck disable=SC2329
mole_bundle_resolver_reset_cache() {
    _MOLE_BUNDLE_CACHE_KEYS=()
    _MOLE_BUNDLE_CACHE_VALS=()
}

# Lookup in the parallel-array cache. Echoes the cached value ("YES"/"NO") or
# empty if the key is not cached.
_mole_bundle_cache_get() {
    local key="$1"
    local i
    for i in "${!_MOLE_BUNDLE_CACHE_KEYS[@]}"; do
        if [[ "${_MOLE_BUNDLE_CACHE_KEYS[$i]}" == "$key" ]]; then
            printf '%s\n' "${_MOLE_BUNDLE_CACHE_VALS[$i]}"
            return 0
        fi
    done
    return 1
}

_mole_bundle_cache_put() {
    local key="$1"
    local value="$2"
    _MOLE_BUNDLE_CACHE_KEYS+=("$key")
    _MOLE_BUNDLE_CACHE_VALS+=("$value")
}

# Return 0 if some installed app either has the given CFBundleIdentifier, or
# registers a privileged helper with that ID via SMJobBless
# (Contents/Library/LaunchServices/<id>). Return 1 otherwise.
#
# Intended for orphan/stale detection: answering "is this launchagent or
# privileged helper associated with an app that still exists on disk?"
bundle_has_installed_app() {
    local bundle_id="$1"
    [[ -z "$bundle_id" ]] && return 1

    # Reject obviously malformed IDs to avoid feeding junk into mdfind/find.
    [[ "$bundle_id" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1

    local cached
    if cached=$(_mole_bundle_cache_get "$bundle_id"); then
        [[ "$cached" == "YES" ]]
        return $?
    fi

    # Fast path: Spotlight. Gated with a timeout because mdfind has been known
    # to wedge on misconfigured indexes.
    if command -v mdfind > /dev/null 2>&1; then
        local hit
        if declare -f run_with_timeout > /dev/null 2>&1; then
            hit=$(run_with_timeout 2 mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1)
        else
            hit=$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1)
        fi
        if [[ -n "$hit" ]]; then
            _mole_bundle_cache_put "$bundle_id" "YES"
            return 0
        fi
    fi

    # Slow path: walk known app roots. Reads each Info.plist CFBundleIdentifier
    # and checks for an SMJobBless helper registered under this bundle ID. This
    # covers the two classes of false positive we saw:
    #   - App-owned launch agents whose bundle ID Spotlight failed to index
    #     (e.g. org.keepassxc.KeePassXC from Homebrew) -- issue #732
    #   - Privileged helpers embedded in a parent .app under
    #     Contents/Library/LaunchServices/<helper-bundle-id> (e.g. the Adobe
    #     ARMDC helpers shipped inside Adobe Acrobat DC.app) -- issue #733
    local app_root app info app_bundle
    for app_root in "${_MOLE_BUNDLE_RESOLVER_APP_ROOTS[@]}"; do
        [[ -d "$app_root" ]] || continue
        while IFS= read -r -d '' app; do
            if [[ -e "$app/Contents/Library/LaunchServices/$bundle_id" ]]; then
                _mole_bundle_cache_put "$bundle_id" "YES"
                return 0
            fi
            info="$app/Contents/Info.plist"
            [[ -f "$info" ]] || continue
            app_bundle=$(plutil -extract CFBundleIdentifier raw "$info" 2> /dev/null || echo "")
            if [[ "$app_bundle" == "$bundle_id" ]]; then
                _mole_bundle_cache_put "$bundle_id" "YES"
                return 0
            fi
        done < <(find "$app_root" -maxdepth 1 -name "*.app" -print0 2> /dev/null)
    done

    _mole_bundle_cache_put "$bundle_id" "NO"
    return 1
}
