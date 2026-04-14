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

# Standard locations for installed apps on macOS. Overridable from tests.
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=(
    "/Applications"
    "/Applications/Setapp"
    "/Applications/Utilities"
    "$HOME/Applications"
)

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

    # Fast path: Spotlight. Gated with a timeout because mdfind has been known
    # to wedge on misconfigured indexes.
    if command -v mdfind > /dev/null 2>&1; then
        local hit
        if declare -f run_with_timeout > /dev/null 2>&1; then
            hit=$(run_with_timeout 2 mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1)
        else
            hit=$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1)
        fi
        [[ -n "$hit" ]] && return 0
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
                return 0
            fi
            info="$app/Contents/Info.plist"
            [[ -f "$info" ]] || continue
            app_bundle=$(plutil -extract CFBundleIdentifier raw "$info" 2> /dev/null || echo "")
            [[ "$app_bundle" == "$bundle_id" ]] && return 0
        done < <(find "$app_root" -maxdepth 1 -name "*.app" -print0 2> /dev/null)
    done

    return 1
}
