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

_MOLE_BUNDLE_RESOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_TIMEOUTS_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeouts.sh
    source "$_MOLE_BUNDLE_RESOLVER_DIR/timeouts.sh"
fi

# Standard locations for installed apps on macOS. Overridable from tests.
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=(
    "/Applications"
    "/Applications/Setapp"
    "/Applications/Utilities"
    "/System/Applications"
    "/System/Applications/Utilities"
    "$HOME/Applications"
    "$HOME/Library/Application Support/Setapp/Applications"
    "/opt/homebrew/Caskroom"
    "/usr/local/Caskroom"
    "/Library/Input Methods"
    "$HOME/Library/Input Methods"
)

# A few macOS apps (NetBird UI) ship Info.plist and their executable at the
# bundle root with no Contents/ directory. Accept that layout only with the
# evidence of a real app: the plist names a CFBundleExecutable that sits next
# to it as a regular executable file, not a link. A flat directory holding only
# a plist, or a PlayCover alias whose files link into its container, still
# fails, so the caller keeps failing closed there.
mole_flat_bundle_info_plist() {
    local app="$1"
    local info="$app/Info.plist"
    # Launcher aliases in this folder are decided by the strict alias check only.
    [[ "${app%/*}" != "$HOME/Applications/PlayCover" ]] || return 1
    [[ ! -e "$app/Contents" && ! -L "$app/Contents" && -f "$info" && ! -L "$info" ]] || return 1
    local executable=""
    executable=$(/usr/bin/plutil -extract CFBundleExecutable raw "$info" 2> /dev/null) || return 1
    [[ -n "$executable" && "$executable" != */* && "$executable" != . && "$executable" != .. ]] || return 1
    [[ -f "$app/$executable" && -x "$app/$executable" && ! -L "$app/$executable" ]] || return 1
    printf '%s\n' "$info"
}

# Return 0 when Spotlight answers a bundle-id query at all, proven by finding
# Finder; 1 when it does not (indexing off, a broken store, a timeout). A
# Spotlight miss alone cannot rule out an app installed outside the scanned
# roots, so callers that delete a live service ask this before trusting one.
# Statuses of 128 and above are signals and are passed on.
mole_spotlight_answers_bundle_queries() {
    local deadline_seconds="${1:-}"
    command -v mdfind > /dev/null 2>&1 || return 1
    local probe_timeout="$MOLE_TIMEOUT_QUICK_DETECT_SEC"
    if [[ -n "$deadline_seconds" ]] && declare -f _mole_timeout_with_deadline > /dev/null 2>&1; then
        probe_timeout=$(_mole_timeout_with_deadline "$probe_timeout" "$deadline_seconds") || return 1
    fi
    local answer="" probe_rc=0
    if declare -f run_with_timeout > /dev/null 2>&1; then
        answer=$(run_with_timeout "$probe_timeout" mdfind -onlyin /System/Library/CoreServices \
            "kMDItemCFBundleIdentifier == 'com.apple.finder'" 2> /dev/null) || probe_rc=$?
    else
        answer=$(mdfind -onlyin /System/Library/CoreServices \
            "kMDItemCFBundleIdentifier == 'com.apple.finder'" 2> /dev/null) || probe_rc=$?
    fi
    [[ $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 ]] || return 1
    /usr/bin/grep -qxF /System/Library/CoreServices/Finder.app <<< "$answer"
}

# Return 0 if some installed app either has the given CFBundleIdentifier, or
# registers a privileged helper with that ID via SMJobBless
# (Contents/Library/LaunchServices/<id>). Return 1 otherwise.
#
# Intended for orphan/stale detection: answering "is this launchagent or
# privileged helper associated with an app that still exists on disk?"
bundle_has_installed_app() {
    local bundle_id="$1"
    local deadline_seconds="${2:-$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))}"
    [[ -z "$bundle_id" ]] && return 1

    # Reject malformed IDs to avoid feeding junk into mdfind/find.
    mole_is_reverse_dns_bundle_id "$bundle_id" || return 1

    # Bundle IDs are case-insensitive on macOS and helper suffixes ship in both
    # cases (com.foo.app.helper, com.stclairsoft.AppTamer.Helper), so derive the
    # parent ID and compare identifiers on lowercased copies. See #1210.
    local bundle_id_lower
    bundle_id_lower=$(printf '%s' "$bundle_id" | /usr/bin/tr '[:upper:]' '[:lower:]')

    local parent_id_lower=""
    local suffix
    for suffix in ".helper" ".daemon" ".agent" ".xpc" ".service"; do
        if [[ "$bundle_id_lower" == *"$suffix" ]]; then
            parent_id_lower="${bundle_id_lower%"$suffix"}"
            break
        fi
    done

    # Spotlight asks for the parent too: an app installed outside every root
    # below (a Downloads copy, an external disk) answers only to its own id.
    local spotlight_query="kMDItemCFBundleIdentifier == '$bundle_id'c"
    [[ -z "$parent_id_lower" ]] ||
        spotlight_query="$spotlight_query || kMDItemCFBundleIdentifier == '$parent_id_lower'c"

    # Fast path: Spotlight. Gated with a timeout because mdfind has been known
    # to wedge on misconfigured indexes.
    if command -v mdfind > /dev/null 2>&1; then
        # Ordinary lookup failures fall through to the filesystem scan below;
        # signals are propagated so a destructive caller cannot ignore Ctrl-C.
        local hit=""
        if declare -f run_with_timeout > /dev/null 2>&1; then
            local mdfind_timeout="$MOLE_TIMEOUT_QUICK_DETECT_SEC"
            if [[ -n "$deadline_seconds" ]] && declare -f _mole_timeout_with_deadline > /dev/null 2>&1; then
                mdfind_timeout=$(_mole_timeout_with_deadline "$mdfind_timeout" "$deadline_seconds") || return 0
            fi
            local mdfind_rc=0
            hit=$(run_with_timeout "$mdfind_timeout" mdfind \
                "$spotlight_query" 2> /dev/null) || mdfind_rc=$?
            [[ $mdfind_rc -ge 128 ]] && return "$mdfind_rc"
            hit="${hit%%$'\n'*}"
        else
            local mdfind_rc=0
            hit=$(mdfind "$spotlight_query" 2> /dev/null) || mdfind_rc=$?
            [[ $mdfind_rc -ge 128 ]] && return "$mdfind_rc"
            hit="${hit%%$'\n'*}"
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

    local -a mapped_app_bundles=()
    case "$bundle_id" in
        com.microsoft.autoupdate.helper | com.microsoft.office.licensingV2.helper)
            mapped_app_bundles=(
                "com.microsoft.Word"
                "com.microsoft.Excel"
                "com.microsoft.Powerpoint"
                "com.microsoft.Outlook"
                "com.microsoft.OneNote"
            )
            ;;
    esac

    local app_root app info app_bundle
    for app_root in "${_MOLE_BUNDLE_RESOLVER_APP_ROOTS[@]}"; do
        [[ -d "$app_root" ]] || continue
        if [[ $SECONDS -ge $deadline_seconds ]]; then
            return 0
        fi
        local app_scan_file=""
        if ! app_scan_file=$(create_temp_file 2> /dev/null); then
            return 0
        fi
        local app_scan_timeout="$MOLE_TIMEOUT_MEDIUM_PROBE_SEC"
        local app_scan_rc=0
        local app_scan_depth=1
        case "$app_root" in
            */Caskroom | */Setapp/Applications)
                app_scan_depth=3
                ;;
        esac
        app_scan_timeout=$(_mole_timeout_with_deadline "$app_scan_timeout" \
            "$deadline_seconds") || app_scan_rc=$?
        if [[ $app_scan_rc -eq 0 ]]; then
            run_with_timeout "$app_scan_timeout" /usr/bin/find "$app_root" \
                -maxdepth "$app_scan_depth" -iname "*.app" -print0 \
                < /dev/null > "$app_scan_file" 2> /dev/null || app_scan_rc=$?
        fi
        if [[ $app_scan_rc -ne 0 ]]; then
            rm -f -- "$app_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
            [[ $app_scan_rc -ge 128 ]] && return "$app_scan_rc"
            return 0
        fi
        local app_scan_found_or_unknown=false
        local app_scan_interrupt_rc=0
        while IFS= read -r -d '' app; do
            [[ $SECONDS -lt $deadline_seconds ]] || {
                app_scan_found_or_unknown=true
                break
            }
            if [[ -e "$app/Contents/Library/LaunchServices/$bundle_id" ]]; then
                app_scan_found_or_unknown=true
                break
            fi
            info="$app/Contents/Info.plist"
            if [[ ! -f "$info" ]]; then
                info=$(mole_flat_bundle_info_plist "$app") || continue
            fi
            local plist_timeout=""
            plist_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                "$deadline_seconds") || {
                app_scan_found_or_unknown=true
                break
            }
            local plist_probe_rc=0
            app_bundle=$(run_with_timeout "$plist_timeout" plutil \
                -extract CFBundleIdentifier raw "$info" 2> /dev/null) || plist_probe_rc=$?
            if [[ $plist_probe_rc -ne 0 || -z "$app_bundle" ]]; then
                if [[ $plist_probe_rc -ge 128 ]]; then
                    app_scan_interrupt_rc=$plist_probe_rc
                    break
                fi
                app_scan_found_or_unknown=true
                break
            fi
            local app_bundle_lower
            app_bundle_lower=$(printf '%s' "$app_bundle" | /usr/bin/tr '[:upper:]' '[:lower:]')
            if [[ "$app_bundle_lower" == "$bundle_id_lower" ||
                -n "$parent_id_lower" && "$app_bundle_lower" == "$parent_id_lower" ]]; then
                app_scan_found_or_unknown=true
                break
            fi
            if ((${#mapped_app_bundles[@]} > 0)); then
                local mapped_bundle
                for mapped_bundle in "${mapped_app_bundles[@]}"; do
                    if [[ "$app_bundle" == "$mapped_bundle" ]]; then
                        app_scan_found_or_unknown=true
                        break
                    fi
                done
                [[ "$app_scan_found_or_unknown" == "true" ]] && break
            fi
        done < "$app_scan_file"
        rm -f -- "$app_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        [[ $app_scan_interrupt_rc -ne 0 ]] && return "$app_scan_interrupt_rc"
        [[ "$app_scan_found_or_unknown" == "true" ]] && return 0
    done

    return 1
}
