#!/bin/bash
# Mole - Application Protection
# System critical and data-protected application lists

set -euo pipefail

if [[ -n "${MOLE_APP_PROTECTION_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_APP_PROTECTION_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"

# Declare WHITELIST_PATTERNS if not already set (used by is_path_whitelisted)
if ! declare -p WHITELIST_PATTERNS &> /dev/null; then
    declare -a WHITELIST_PATTERNS=()
fi

# Bundle ID / pattern data is sourced from a sibling file so this file
# stays focused on logic. See app_protection_data.sh for the lists.
# shellcheck source=lib/core/app_protection_data.sh
source "$_MOLE_CORE_DIR/app_protection_data.sh"

# Centralized check for critical system components (case-insensitive)
is_critical_system_component() {
    local token="$1"
    [[ -z "$token" ]] && return 1

    local lower
    lower=$(echo "$token" | LC_ALL=C tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *backgroundtaskmanagement* | *loginitems* | *systempreferences* | *systemsettings* | *settings* | *preferences* | *controlcenter* | *biometrickit* | *sfl* | *tcc*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if bundle ID matches pattern (glob support)
bundle_matches_pattern() {
    local bundle_id="$1"
    local pattern="$2"

    [[ -z "$pattern" ]] && return 1

    # Use bash [[  ]] for glob pattern matching (works with variables in bash 3.2+)
    # shellcheck disable=SC2053  # allow glob pattern matching
    if [[ "$bundle_id" == $pattern ]]; then
        return 0
    fi
    return 1
}

# Helper to build regex from array (Bash 3.2 compatible - no namerefs)
# $1: Variable name to store result
# $2...: Array elements (passed as expanded list)
build_regex_var() {
    local var_name="$1"
    shift
    local regex=""
    for pattern in "$@"; do
        # Escape dots . -> \.
        local p="${pattern//./\\.}"
        # Convert * to .*
        p="${p//\*/.*}"
        # Start and end anchors
        p="^${p}$"

        if [[ -z "$regex" ]]; then
            regex="$p"
        else
            regex="$regex|$p"
        fi
    done
    # eval: indirect write by name; bash 3.2 has no nameref
    eval "$var_name=\"\$regex\""
}

# Lazy-loaded regex (only built when needed)
APPLE_UNINSTALLABLE_REGEX=""
SYSTEM_CRITICAL_REGEX=""

_ensure_uninstall_regex() {
    if [[ -z "$SYSTEM_CRITICAL_REGEX" ]]; then
        build_regex_var APPLE_UNINSTALLABLE_REGEX "${APPLE_UNINSTALLABLE_APPS[@]}"
        build_regex_var SYSTEM_CRITICAL_REGEX "${SYSTEM_CRITICAL_BUNDLES[@]}"
    fi
}

# Check if application is a protected system component
should_protect_from_uninstall() {
    local bundle_id="$1"

    _ensure_uninstall_regex

    if [[ "$bundle_id" =~ $APPLE_UNINSTALLABLE_REGEX ]]; then
        return 1
    fi

    if [[ "$bundle_id" =~ $SYSTEM_CRITICAL_REGEX ]]; then
        return 0
    fi

    return 1
}

# Print the vendor name when an app must be removed through its official
# uninstaller instead of Mole's generic Trash/delete path.
official_uninstaller_vendor() {
    local bundle_id="${1:-}"
    local display_name="${2:-}"
    local app_path="${3:-}"
    local normalized_bundle normalized_name normalized_path
    normalized_bundle=$(printf '%s' "$bundle_id" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    normalized_name=$(printf '%s' "$display_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    normalized_path=$(basename "${app_path:-}" .app | LC_ALL=C tr '[:upper:]' '[:lower:]')

    local rule vendor prefixes fragments prefix fragment
    local -a _prefixes _fragments
    for rule in "${OFFICIAL_UNINSTALLER_RULES[@]}"; do
        IFS='|' read -r vendor prefixes fragments <<< "$rule"
        IFS=',' read -r -a _prefixes <<< "$prefixes"
        for prefix in "${_prefixes[@]}"; do
            [[ -n "$prefix" && "$normalized_bundle" == "$prefix"* ]] && {
                printf '%s\n' "$vendor"
                return 0
            }
        done

        IFS=',' read -r -a _fragments <<< "$fragments"
        for fragment in "${_fragments[@]}"; do
            if [[ -n "$fragment" ]] &&
                { [[ "$normalized_name" == *"$fragment"* ]] || [[ "$normalized_path" == *"$fragment"* ]]; }; then
                printf '%s\n' "$vendor"
                return 0
            fi
        done
    done

    return 1
}

# Check if application data should be protected during cleanup
should_protect_data() {
    local bundle_id="$1"

    case "$bundle_id" in
        com.apple.* | loginwindow | dock | systempreferences | finder | safari)
            return 0
            ;;
        # CUPS is an OS-provided subsystem with no user-facing app; without this
        # guard `~/Library/Preferences/org.cups.PrintingPrefs.plist` (which holds
        # the default printer and recent printers) looks orphaned. See #731.
        org.cups.*)
            return 0
            ;;
        backgroundtaskmanagement* | keychain* | security* | bluetooth* | wifi* | network* | tcc)
            return 0
            ;;
        notification* | accessibility* | universalaccess* | HIToolbox*)
            return 0
            ;;
        *inputmethod* | *InputMethod* | *IME | textinput* | TextInput*)
            return 0
            ;;
        keyboard* | Keyboard* | inputsource* | InputSource* | keylayout* | KeyLayout*)
            return 0
            ;;
        GlobalPreferences | .GlobalPreferences | org.pqrs.Karabiner*)
            return 0
            ;;
        com.1password.* | com.agilebits.* | com.lastpass.* | com.dashlane.* | com.bitwarden.*)
            return 0
            ;;
        com.jetbrains.* | JetBrains* | com.microsoft.* | com.visualstudio.*)
            return 0
            ;;
        com.sublimetext.* | com.sublimehq.* | Cursor | Claude | ChatGPT | com.openai.codex | Codex | codex-runtimes | Ollama)
            return 0
            ;;
        # Specific match to avoid ShellCheck redundancy warning with com.clash.*
        com.clash.app)
            return 0
            ;;
        com.nssurge.* | com.v2ray.* | com.clash.* | ClashX* | Surge* | Shadowrocket* | Quantumult*)
            return 0
            ;;
        clash-* | Clash-* | *-clash | *-Clash | clash.* | Clash.* | clash_* | *clash-verge* | *Clash-Verge* | clashverge* | ClashVerge*)
            return 0
            ;;
        com.docker.* | com.getpostman.* | com.insomnia.*)
            return 0
            ;;
        com.tencent.* | com.sogou.* | com.baidu.* | com.googlecode.* | im.rime.*)
            # These might have wildcards, check detailed list
            for pattern in "${DATA_PROTECTED_BUNDLES[@]}"; do
                if bundle_matches_pattern "$bundle_id" "$pattern"; then
                    return 0
                fi
            done
            return 1
            ;;
    esac

    # Fallback: check against the full DATA_PROTECTED_BUNDLES list
    for pattern in "${DATA_PROTECTED_BUNDLES[@]}"; do
        if bundle_matches_pattern "$bundle_id" "$pattern"; then
            return 0
        fi
    done

    return 1
}

# Check if a path is protected from deletion
# Centralized logic to protect system settings, control center, and critical apps
#
# In uninstall mode (MOLE_UNINSTALL_MODE=1), only system-critical components are protected.
# Data-protected apps (VPNs, dev tools, etc.) can be uninstalled when user explicitly chooses to.
#
# Args: $1 - path to check
# Returns: 0 if protected, 1 if safe to delete
should_protect_path() {
    local path="$1"
    [[ -z "$path" ]] && return 1

    local _container_cache_path=false

    # 1. Keyword-based matching for system components (case-insensitive via character classes)
    case "$path" in
        *[Ss]ystem[Ss]ettings* | *[Ss]ystem[Pp]references* | *[Cc]ontrol[Cc]enter*)
            return 0
            ;;
        *com.apple.[Ss]ettings* | *com.apple.[Ss]ETTINGS*)
            return 0
            ;;
        *com.apple.[Nn]otes* | *com.apple.[Nn]OTES*)
            return 0
            ;;
    esac

    # 2. Protect caches critical for system UI rendering
    # These caches are essential for modern macOS (Sonoma/Sequoia) system UI rendering
    case "$path" in
        # System Settings and Control Center caches (CRITICAL - prevents blank panel bug)
        *com.apple.systempreferences.cache* | *com.apple.Settings.cache* | *com.apple.controlcenter.cache*)
            return 0
            ;;
        # Finder and Dock (system essential)
        *com.apple.finder.cache* | *com.apple.dock.cache*)
            return 0
            ;;
        # System XPC services and sandboxed containers
        */Library/Containers/com.apple.Settings* | */Library/Containers/com.apple.SystemSettings* | */Library/Containers/com.apple.controlcenter*)
            return 0
            ;;
        */Library/Group\ Containers/com.apple.systempreferences* | */Library/Group\ Containers/com.apple.Settings*)
            return 0
            ;;
        # OrbStack group containers hold live container filesystem images.
        */Library/Group\ Containers/*dev.orbstack | */Library/Group\ Containers/*dev.orbstack/* | */.orbstack | */.orbstack/*)
            return 0
            ;;
        # Shared file lists for System Settings (macOS Sequoia) - Issue #136
        */com.apple.sharedfilelist/*com.apple.Settings* | */com.apple.sharedfilelist/*com.apple.SystemSettings* | */com.apple.sharedfilelist/*systempreferences*)
            return 0
            ;;
    esac

    # 3. Extract bundle ID from sandbox paths
    # Matches: .../Library/Containers/bundle.id/...
    # Matches: .../Library/Group Containers/group.id/...
    if [[ "$path" =~ /Library/Containers/([^/]+) ]] || [[ "$path" =~ /Library/Group\ Containers/([^/]+) ]]; then
        local bundle_id="${BASH_REMATCH[1]}"
        # Cache and tmp directories inside containers are regenerable by definition.
        # safe_clean calls explicitly target these; let them through instead of
        # blocking on the blanket com.apple.* match in should_protect_data.
        if [[ "$path" == */Data/Library/Caches/* || "$path" == */Data/tmp/* ]]; then
            _container_cache_path=true
        elif [[ "${MOLE_UNINSTALL_MODE:-0}" != "1" ]] && should_protect_data "$bundle_id"; then
            return 0
        fi
    fi

    # 4. Check for specific hardcoded critical patterns
    case "$path" in
        *com.apple.Settings* | *com.apple.SystemSettings* | *com.apple.controlcenter* | *com.apple.finder* | *com.apple.dock*)
            return 0
            ;;
    esac

    # 5. Protect critical preference files and user data
    case "$path" in
        */Library/Preferences/com.apple.dock.plist | */Library/Preferences/com.apple.finder.plist)
            return 0
            ;;
        # Protect Mole's own runtime logs so cleanup cannot delete its active log targets.
        */Library/Logs/mole | */Library/Logs/mole/ | */Library/Logs/mole/*)
            return 0
            ;;
        # Codex Desktop and CLI keep conversation indexes and app state in cache-
        # shaped paths. Default cleanup must not remove those records.
        */Library/Application\ Support/Codex | */Library/Application\ Support/Codex/* | \
            */Library/Logs/com.openai.codex | */Library/Logs/com.openai.codex/* | \
            */.codex/sessions | */.codex/sessions/* | \
            */.codex/auth.json | */.codex/history.jsonl | \
            */.codex/state_*.sqlite | */.codex/logs_*.sqlite | \
            */.codex/session_index.jsonl | */.codex/cache/session_index.jsonl | \
            */.codex/cache/codex_app_directory | */.codex/cache/codex_app_directory/*)
            return 0
            ;;
        # Bluetooth and WiFi configurations
        */ByHost/com.apple.bluetooth.* | */ByHost/com.apple.wifi.*)
            return 0
            ;;
        # NetworkExtension stores VPN tunnel state and provider preferences.
        */Library/Preferences/com.apple.networkextension*.plist)
            return 0
            ;;
        # iCloud Drive - protect user's cloud synced data
        */Library/Mobile\ Documents* | */Mobile\ Documents*)
            return 0
            ;;
        # High-risk cleanup denylist: these cache/preferences paths are known
        # to contain license, account, plugin, MDM, or system-service state
        # despite cache-like names. Keep this as a protection overlay only; it
        # is not a cleanup allowlist.
        */Library/Accounts | */Library/Accounts/* | \
            */Library/Keychains | */Library/Keychains/* | \
            */Library/Mail | */Library/Mail/* | \
            */Library/Calendars | \
            */Library/Contacts | */Library/Contacts/*)
            return 0
            ;;
        /Library/Audio/Plug-Ins/Components | /Library/Audio/Plug-Ins/Components/* | \
            /Library/Audio/Plug-Ins/VST | /Library/Audio/Plug-Ins/VST/* | \
            /Library/Audio/Plug-Ins/VST3 | /Library/Audio/Plug-Ins/VST3/* | \
            /Library/Application\ Support/iZotope | /Library/Application\ Support/iZotope/* | \
            */Library/Application\ Support/iZotope | */Library/Application\ Support/iZotope/* | \
            /Library/Application\ Support/LaserSoft\ Imaging | /Library/Application\ Support/LaserSoft\ Imaging/*)
            return 0
            ;;
        */Library/Preferences/com.native-instruments* | \
            */Library/Preferences/com.avid.mediacomposer*.plist | \
            */Library/Preferences/com.fabfilter.*.[0-9].plist | \
            */Library/Preferences/com.fabfilter.*.[0-9][0-9].plist | \
            */Library/Preferences/com.paceap.*.plist)
            return 0
            ;;
        /private/var/folders/*/C/com.native-instruments* | \
            /private/var/folders/*/C/com.avid.mediacomposer* | \
            /private/var/folders/*/C/com.paceap.eden.iLokLicenseManager*)
            return 0
            ;;
        */Library/Caches/ms-playwright | */Library/Caches/ms-playwright/* | \
            */Library/Caches/app.cotypist.Cotypist | */Library/Caches/app.cotypist.Cotypist/* | \
            */Library/Caches/com.displaylink.DisplayLinkUserAgent | */Library/Caches/com.displaylink.DisplayLinkUserAgent/* | \
            */Library/Caches/com.lasersoft-imaging.SilverFast9 | */Library/Caches/com.lasersoft-imaging.SilverFast9/* | \
            */Library/Caches/com.lasersoft-imaging.SilverFast-9-Installer | */Library/Caches/com.lasersoft-imaging.SilverFast-9-Installer/* | \
            */Library/Caches/Adobe\ * | \
            */Library/Caches/*\ Adobe* | \
            */Library/Caches/com.apple.containermanagerd | */Library/Caches/com.apple.containermanagerd/* | \
            */Library/Caches/com.apple.homed | */Library/Caches/com.apple.homed/* | \
            */Library/Caches/com.apple.ap.adprivacyd | */Library/Caches/com.apple.ap.adprivacyd/* | \
            */Library/Caches/FamilyCircle | */Library/Caches/FamilyCircle/* | \
            */Library/Caches/com.apple.HomeKit | */Library/Caches/com.apple.HomeKit/* | \
            */Library/Caches/com.apple.WorkflowKit.BackgroundShortcutRunner.ShortcutsSandboxCache | */Library/Caches/com.apple.WorkflowKit.BackgroundShortcutRunner.ShortcutsSandboxCache/* | \
            */Library/Caches/com.apple.siriactionsd.ShortcutsSandboxCache | */Library/Caches/com.apple.siriactionsd.ShortcutsSandboxCache/*)
            return 0
            ;;
        # CoreAudio and audio subsystem caches (issue #553)
        # Cleaning these can cause audio output loss on Intel Macs
        *com.apple.coreaudio* | *com.apple.audio.* | *coreaudiod*)
            return 0
            ;;
    esac

    # 6. Match full path against protected patterns
    # This catches things like /Users/tw93/Library/Caches/Claude when pattern is *Claude*
    # Skip for container cache/tmp paths: bundle ID was already checked in step 3,
    # and critical containers are caught by steps 1/4/5.
    if [[ "$_container_cache_path" != "true" ]]; then
        if [[ "${MOLE_UNINSTALL_MODE:-0}" == "1" ]]; then
            # Uninstall mode: first check if it's an uninstallable Apple app
            for pattern in "${APPLE_UNINSTALLABLE_APPS[@]}"; do
                if bundle_matches_pattern "$path" "$pattern"; then
                    return 1 # Can be uninstalled
                fi
            done
            # Then check system-critical components
            for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}"; do
                if bundle_matches_pattern "$path" "$pattern"; then
                    return 0
                fi
            done
        else
            # Normal mode (cleanup): protect both system-critical and data-protected bundles
            for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}"; do
                if bundle_matches_pattern "$path" "$pattern"; then
                    return 0
                fi
            done
        fi

        # 7. Check if the filename itself matches any protected patterns
        # Skip in uninstall mode - user explicitly chose to remove this app
        if [[ "${MOLE_UNINSTALL_MODE:-0}" != "1" ]]; then
            local filename="${path##*/}"
            if should_protect_data "$filename"; then
                return 0
            fi
        fi
    fi

    return 1
}

# Check if a path is protected by whitelist patterns
# Args: $1 - path to check
# Returns: 0 if whitelisted, 1 if not
is_path_whitelisted() {
    local target_path="$1"
    [[ -z "$target_path" ]] && return 1

    # Normalize path (remove trailing slash, collapse consecutive slashes).
    # Callers sometimes concat a glob expansion that already ends in `/`
    # with a sub-path that begins with `/`, producing `.../Default//Service
    # Worker/...`. Without collapsing, those never match a whitelist entry
    # written with single separators. See #724.
    #
    # Note: on bash 3.2 (macOS default), `${var//\/\//\/}` leaves a literal
    # backslash in the replacement. Indirect variables sidestep that.
    local _slash_single="/"
    local _slash_double="//"
    local normalized_target="${target_path%/}"
    while [[ "$normalized_target" == *"$_slash_double"* ]]; do
        normalized_target="${normalized_target//$_slash_double/$_slash_single}"
    done

    # Empty whitelist means nothing is protected
    [[ ${#WHITELIST_PATTERNS[@]} -eq 0 ]] && return 1

    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        # Pattern is already expanded/normalized in bin/clean.sh
        local check_pattern="${pattern%/}"
        while [[ "$check_pattern" == *"$_slash_double"* ]]; do
            check_pattern="${check_pattern//$_slash_double/$_slash_single}"
        done
        local has_glob="false"
        case "$check_pattern" in
            *\** | *\?* | *\[*)
                has_glob="true"
                ;;
        esac

        # Check for exact match or glob pattern match
        # shellcheck disable=SC2053
        if [[ "$normalized_target" == "$check_pattern" ]] ||
            [[ "$normalized_target" == $check_pattern ]]; then
            return 0
        fi

        # Check if target is a parent directory of a whitelisted path
        # e.g., if pattern is /path/to/dir/subdir and target is /path/to/dir,
        # the target should be protected to preserve its whitelisted children
        if [[ "$check_pattern" == "$normalized_target"/* ]]; then
            return 0
        fi

        # Check if target is a child of a whitelisted directory path
        if [[ "$has_glob" == "false" && "$normalized_target" == "$check_pattern"/* ]]; then
            return 0
        fi
    done

    return 1
}

_mole_uninstall_lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

_mole_uninstall_is_common_app_name() {
    local lower_name
    lower_name=$(_mole_uninstall_lower "${1:-}")
    case "$lower_name" in
        music | notes | photos | finder | safari | preview | calendar | contacts | messages | \
            reminders | clock | weather | stocks | books | news | podcasts | voice | files | \
            store | system | helper | agent | daemon | service | update | sync | backup | \
            cloud | manager | monitor | server | client | worker | runner | launcher | \
            driver | plugin | extension | widget | utility)
            return 0
            ;;
    esac
    return 1
}

_mole_uninstall_vendor_product_tokens() {
    local bundle_id="${1:-}"
    mole_is_reverse_dns_bundle_id "$bundle_id" || return 1

    local product_token="${bundle_id##*.}"
    local without_product="${bundle_id%.*}"
    local vendor_token="${without_product##*.}"

    [[ "$vendor_token" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{2,}$ ]] || return 1
    [[ "$product_token" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{2,}$ ]] || return 1

    printf '%s|%s\n' "$vendor_token" "$product_token"
}

_mole_uninstall_name_variant_matches() {
    local candidate_lower="$1"
    shift

    local variant
    for variant in "$@"; do
        [[ -n "$variant" ]] || continue
        if [[ "$candidate_lower" == "$variant" ||
            "$candidate_lower" == "$variant "* ||
            "$candidate_lower" == "$variant-"* ||
            "$candidate_lower" == "${variant}_"* ||
            "$candidate_lower" == "$variant."* ]]; then
            return 0
        fi
    done

    return 1
}

find_vendor_nested_app_paths() {
    local bundle_id="$1"
    local app_name="$2"
    shift 2

    [[ -n "$app_name" && ${#app_name} -ge 4 ]] || return 0
    _mole_uninstall_is_common_app_name "$app_name" && return 0

    local token_pair
    token_pair=$(_mole_uninstall_vendor_product_tokens "$bundle_id" 2> /dev/null) || return 0
    local vendor_token product_token
    IFS='|' read -r vendor_token product_token <<< "$token_pair"

    local vendor_lower product_lower app_lower nospace_lower hyphen_lower underscore_lower
    vendor_lower=$(_mole_uninstall_lower "$vendor_token")
    product_lower=$(_mole_uninstall_lower "$product_token")
    app_lower=$(_mole_uninstall_lower "$app_name")
    nospace_lower=$(_mole_uninstall_lower "${app_name// /}")
    hyphen_lower=$(_mole_uninstall_lower "${app_name// /-}")
    underscore_lower=$(_mole_uninstall_lower "${app_name// /_}")

    local root candidate parent_dir parent_base parent_lower child_base child_lower
    for root in "$@"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' candidate; do
            parent_dir="${candidate%/*}"
            parent_base="${parent_dir##*/}"
            parent_lower=$(_mole_uninstall_lower "$parent_base")
            [[ "$parent_lower" == "$vendor_lower" ]] || continue

            child_base="${candidate##*/}"
            child_lower=$(_mole_uninstall_lower "$child_base")
            if _mole_uninstall_name_variant_matches "$child_lower" \
                "$app_lower" "$nospace_lower" "$hyphen_lower" "$underscore_lower" "$product_lower"; then
                printf '%s\n' "$candidate"
            fi
        done < <(command find "$root" -mindepth 2 -maxdepth 2 -type d -print0 2> /dev/null)
    done | sort -u
}

find_shared_app_paths() {
    local bundle_id="$1"
    local app_name="$2"
    shift 2

    [[ -n "$app_name" && ${#app_name} -ge 5 ]] || return 0
    _mole_uninstall_is_common_app_name "$app_name" && return 0

    local product_token=""
    local token_pair
    if token_pair=$(_mole_uninstall_vendor_product_tokens "$bundle_id" 2> /dev/null); then
        IFS='|' read -r _ product_token <<< "$token_pair"
    fi

    local app_lower nospace_lower hyphen_lower underscore_lower product_lower
    app_lower=$(_mole_uninstall_lower "$app_name")
    nospace_lower=$(_mole_uninstall_lower "${app_name// /}")
    hyphen_lower=$(_mole_uninstall_lower "${app_name// /-}")
    underscore_lower=$(_mole_uninstall_lower "${app_name// /_}")
    product_lower=$(_mole_uninstall_lower "$product_token")

    local root candidate base lower_base
    for root in "$@"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' candidate; do
            base="${candidate##*/}"
            lower_base=$(_mole_uninstall_lower "$base")
            if _mole_uninstall_name_variant_matches "$lower_base" \
                "$app_lower" "$nospace_lower" "$hyphen_lower" "$underscore_lower" "$product_lower"; then
                printf '%s\n' "$candidate"
            fi
        done < <(command find "$root" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)
    done | sort -u
}

# Return 0 when `path` looks like a dotdir / XDG state directory belonging to
# a standalone CLI tool shipped independently of any same-named GUI app.
# find_app_files uses this to skip candidates that would otherwise nuke
# unrelated CLI state when uninstalling a same-named GUI app (#993).
#
# Lowercase comparison so case-insensitive APFS (~/.Claude vs ~/.claude) is
# handled. Scope is restricted to four well-known parents so we never skip
# legitimate non-dotdir locations.
#
# The deny-list is inlined rather than read from an array because bats 1.x
# does not carry readonly arrays from setup() into the @test body, and a
# regression in any of these names is destructive enough that we never want
# the safeguard to silently no-op in a fresh subshell.
_path_belongs_to_independent_cli() {
    local path="$1"
    [[ -z "$path" ]] && return 1

    local base parent lc_name
    base="${path##*/}"
    parent="${path%/*}"
    lc_name=$(printf '%s' "${base#.}" | tr '[:upper:]' '[:lower:]')
    [[ -z "$lc_name" ]] && return 1

    case "$lc_name" in
        # Standalone CLI tools shipped independently of a same-named GUI app:
        # never delete their dotdirs when uninstalling the GUI namesake.
        # Issue #993: uninstalling Claude.app wiped ~/.claude (Claude Code CLI),
        # OpenCode.app wiped ~/.local/share/opencode. Case-insensitive APFS makes
        # the collision worse. Add new GUI/CLI namesakes here.
        claude | opencode | codex | gemini) ;;
        *) return 1 ;;
    esac

    case "$parent" in
        "$HOME" | "$HOME/.config" | "$HOME/.local/share" | "$HOME/.cache")
            return 0
            ;;
    esac
    return 1
}

# Locate files associated with an application
find_app_files() {
    local bundle_id="$1"
    local app_name="$2"

    # Early validation: require at least one valid identifier
    # Skip scanning if both bundle_id and app_name are invalid
    if [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] &&
        [[ -z "$app_name" || ${#app_name} -lt 2 ]]; then
        return 0 # Silent return to avoid invalid scanning
    fi

    local -a files_to_clean=()

    # Normalize app name for matching - generate all common naming variants
    # Apps use inconsistent naming: "Maestro Studio" vs "maestro-studio" vs "MaestroStudio"
    # Note: Using tr for lowercase conversion (Bash 3.2 compatible, no ${var,,} support)
    local nospace_name="${app_name// /}"                                               # "Maestro Studio" -> "MaestroStudio"
    local underscore_name="${app_name// /_}"                                           # "Maestro Studio" -> "Maestro_Studio"
    local hyphen_name="${app_name// /-}"                                               # "Maestro Studio" -> "Maestro-Studio"
    local lowercase_name=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')              # "Zed Nightly" -> "zed nightly"
    local lowercase_nospace=$(echo "$nospace_name" | tr '[:upper:]' '[:lower:]')       # "MaestroStudio" -> "maestrostudio"
    local lowercase_hyphen=$(echo "$hyphen_name" | tr '[:upper:]' '[:lower:]')         # "Maestro-Studio" -> "maestro-studio"
    local lowercase_underscore=$(echo "$underscore_name" | tr '[:upper:]' '[:lower:]') # "Maestro_Studio" -> "maestro_studio"

    # Extract base name by removing common version/channel suffixes
    # "Zed Nightly" -> "Zed", "Firefox Developer Edition" -> "Firefox"
    local base_name="$app_name"
    local version_suffixes="Nightly|Beta|Alpha|Dev|Canary|Preview|Insider|Edge|Stable|Release|RC|LTS"
    version_suffixes+="|Developer Edition|Technology Preview"
    if [[ "$app_name" =~ ^(.+)[[:space:]]+(${version_suffixes})$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    fi
    local base_lowercase=$(echo "$base_name" | tr '[:upper:]' '[:lower:]') # "Zed" -> "zed"

    # Only use bundle_id in literal paths or find patterns after reverse-DNS
    # validation. A malformed Info.plist should not be able to traverse out of
    # Library subtrees or broaden matches with glob metacharacters.
    local bundle_id_valid="false"
    if mole_is_reverse_dns_bundle_id "$bundle_id"; then
        bundle_id_valid="true"
    fi

    # Standard path patterns for user-level files. App-name templates must never
    # be built from an empty display name, otherwise dotdir/XDG paths collapse to
    # broad roots like "$HOME/." or "$HOME/.config/".
    local -a user_patterns=()
    if [[ -n "$app_name" && ${#app_name} -ge 2 ]]; then
        user_patterns+=(
            "$HOME/Library/Application Support/$app_name"
            "$HOME/Library/Caches/$app_name"
            "$HOME/Library/Logs/$app_name"
            "$HOME/Library/Preferences/$app_name"
            "$HOME/Library/Preferences/$app_name.plist"
            "$HOME/Library/Saved Application State/$app_name.savedState"

            "$HOME/Library/Services/$app_name.workflow"
            "$HOME/Library/QuickLook/$app_name.qlgenerator"
            "$HOME/Library/Internet Plug-Ins/$app_name.plugin"
            "$HOME/Library/Audio/Plug-Ins/Components/$app_name.component"
            "$HOME/Library/Audio/Plug-Ins/VST/$app_name.vst"
            "$HOME/Library/Audio/Plug-Ins/VST3/$app_name.vst3"
            "$HOME/Library/Audio/Plug-Ins/Digidesign/$app_name.dpm"
            "$HOME/Library/PreferencePanes/$app_name.prefPane"
            "$HOME/Library/Input Methods/$app_name.app"
            "$HOME/Library/Screen Savers/$app_name.saver"
            "$HOME/Library/Frameworks/$app_name.framework"
            "$HOME/Library/Contextual Menu Items/$app_name.plugin"
            "$HOME/Library/Spotlight/$app_name.mdimporter"
            "$HOME/Library/ColorPickers/$app_name.colorPicker"
            "$HOME/Library/Workflows/$app_name.workflow"
            "$HOME/.config/$app_name"
            "$HOME/.cache/$app_name"
            "$HOME/.cache/$lowercase_name"
            "$HOME/.local/share/$app_name"
            "$HOME/.$app_name"
            "$HOME/.$app_name"rc
            "$HOME/Library/Address Book Plug-Ins/$app_name.bundle"
            "$HOME/Library/Accessibility/$app_name.bundle"
            "$HOME/Library/Mail/Bundles/$app_name.mailbundle"
        )
    fi

    if [[ "$bundle_id_valid" == "true" ]]; then
        user_patterns+=(
            "$HOME/Library/Application Support/$bundle_id"
            "$HOME/Library/Caches/$bundle_id"
            "$HOME/Library/Logs/$bundle_id"
            "$HOME/Library/Saved Application State/$bundle_id.savedState"
            "$HOME/Library/Containers/$bundle_id"
            "$HOME/Library/WebKit/$bundle_id"
            "$HOME/Library/WebKit/com.apple.WebKit.WebContent/$bundle_id"
            "$HOME/Library/HTTPStorages/$bundle_id"
            "$HOME/Library/HTTPStorages/$bundle_id.binarycookies"
            "$HOME/Library/Cookies/$bundle_id.binarycookies"
            "$HOME/Library/Application Scripts/$bundle_id"
            "$HOME/Library/Input Methods/$bundle_id.app"
            "$HOME/Library/Autosave Information/$bundle_id"
            "$HOME/Library/SyncedPreferences/$bundle_id.plist"
        )
    fi

    # Add all naming variants to cover inconsistent app directory naming
    # Issue #377: Apps create directories with various naming conventions
    if [[ ${#app_name} -gt 3 && "$app_name" =~ [[:space:]] ]]; then
        user_patterns+=(
            # Compound naming (MaestroStudio, Maestro_Studio, Maestro-Studio)
            "$HOME/Library/Application Support/$nospace_name"
            "$HOME/Library/Caches/$nospace_name"
            "$HOME/Library/Logs/$nospace_name"
            "$HOME/Library/Preferences/$nospace_name"
            "$HOME/Library/Preferences/$nospace_name.plist"
            "$HOME/Library/Saved Application State/$nospace_name.savedState"
            "$HOME/Library/Application Support/$underscore_name"
            "$HOME/Library/Application Support/$hyphen_name"
            "$HOME/Library/Preferences/$underscore_name"
            "$HOME/Library/Preferences/$underscore_name.plist"
            "$HOME/Library/Preferences/$hyphen_name"
            "$HOME/Library/Preferences/$hyphen_name.plist"
            # Lowercase variants (maestrostudio, maestro-studio, maestro_studio)
            "$HOME/.config/$lowercase_nospace"
            "$HOME/.config/$lowercase_hyphen"
            "$HOME/.config/$lowercase_underscore"
            "$HOME/.cache/$lowercase_nospace"
            "$HOME/.cache/$lowercase_hyphen"
            "$HOME/.cache/$lowercase_underscore"
            "$HOME/.local/share/$lowercase_nospace"
            "$HOME/.local/share/$lowercase_hyphen"
            "$HOME/.local/share/$lowercase_underscore"
        )
    fi

    # Add base name variants for versioned apps (e.g., "Zed Nightly" -> check for "zed")
    if [[ "$base_name" != "$app_name" && ${#base_name} -gt 2 ]]; then
        user_patterns+=(
            "$HOME/Library/Application Support/$base_name"
            "$HOME/Library/Caches/$base_name"
            "$HOME/Library/Logs/$base_name"
            "$HOME/Library/Preferences/$base_name"
            "$HOME/Library/Preferences/$base_name.plist"
            "$HOME/Library/Saved Application State/$base_name.savedState"
            "$HOME/.config/$base_lowercase"
            "$HOME/.cache/$base_lowercase"
            "$HOME/.local/share/$base_lowercase"
            "$HOME/.$base_lowercase"
        )
    fi

    # Issue #422: Zed channel builds can leave data under another channel bundle id.
    # Example: uninstalling dev.zed.Zed-Nightly should also detect dev.zed.Zed-Preview leftovers.
    if [[ "$bundle_id_valid" == "true" && "$bundle_id" =~ ^dev\.zed\.Zed- ]] && [[ -d "$HOME/Library/HTTPStorages" ]]; then
        while IFS= read -r -d '' zed_http_storage; do
            files_to_clean+=("$zed_http_storage")
        done < <(command find "$HOME/Library/HTTPStorages" -maxdepth 1 -name "dev.zed.Zed-*" -print0 2> /dev/null)
    fi

    # Process standard patterns. user_patterns can be empty when app_name is
    # too short and bundle_id is invalid; bash 3.2 under set -u treats an empty
    # "${arr[@]}" expansion as an unbound variable, so use the +-guard idiom.
    for p in "${user_patterns[@]+"${user_patterns[@]}"}"; do
        local expanded_path="${p/#\~/$HOME}"
        # Skip if path doesn't exist
        [[ ! -e "$expanded_path" ]] && continue

        # Safety check: Skip if path ends with a common directory name (indicates empty app_name/bundle_id)
        # This prevents deletion of entire Library subdirectories when bundle_id is empty
        case "$expanded_path" in
            */Library/Application\ Support | */Library/Application\ Support/ | \
                */Library/Caches | */Library/Caches/ | \
                */Library/Logs | */Library/Logs/ | \
                */Library/Preferences | */Library/Preferences/ | \
                */Library/Preferences/ByHost | */Library/Preferences/ByHost/ | \
                */Library/Containers | */Library/Containers/ | \
                */Library/WebKit | */Library/WebKit/ | \
                */Library/HTTPStorages | */Library/HTTPStorages/ | \
                */Library/Application\ Scripts | */Library/Application\ Scripts/ | \
                */Library/Autosave\ Information | */Library/Autosave\ Information/ | \
                */Library/Group\ Containers | */Library/Group\ Containers/ | \
                */.config | */.config/ | \
                */.cache | */.cache/ | \
                */.local/share | */.local/share/ | \
                "$HOME" | "$HOME"/ | "$HOME"/.)
                continue
                ;;
        esac

        # Skip XDG dotdirs that belong to independent CLI tools sharing a name
        # with the GUI app being uninstalled (issue #993).
        if _path_belongs_to_independent_cli "$expanded_path"; then
            debug_log "Skipping independent CLI dotdir: $expanded_path"
            continue
        fi

        files_to_clean+=("$expanded_path")
    done

    # Vendor-nested support directories, e.g.:
    #   ~/Library/Application Support/Avid/Sibelius
    # Many professional apps store the product under a vendor folder rather
    # than directly under Application Support. Match only when the vendor token
    # comes from the bundle id to avoid broad name-only deletion.
    if [[ "$bundle_id_valid" == "true" ]]; then
        local vendor_nested_path
        while IFS= read -r vendor_nested_path; do
            [[ -n "$vendor_nested_path" && -e "$vendor_nested_path" ]] && files_to_clean+=("$vendor_nested_path")
        done < <(
            find_vendor_nested_app_paths "$bundle_id" "$app_name" \
                "$HOME/Library/Application Support" \
                "$HOME/Library/Caches" \
                "$HOME/Library/Logs"
        )
    fi

    # Handle Preferences and ByHost variants (only if bundle_id is valid).
    # Reverse-DNS check rejects malformed bundle ids before they reach any
    # find -name pattern. Without this, a bundle id containing glob metachars
    # (* ? [) or path separators could over-match unrelated user containers.
    if [[ "$bundle_id_valid" == "true" ]]; then
        [[ -f ~/Library/Preferences/"$bundle_id".plist ]] && files_to_clean+=("$HOME/Library/Preferences/$bundle_id.plist")
        [[ -d ~/Library/Preferences/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Preferences/$bundle_id")
        [[ -d ~/Library/Preferences/ByHost ]] && while IFS= read -r -d '' pref; do
            if mole_name_starts_with_bundle_id_boundary "$pref" "$bundle_id"; then
                files_to_clean+=("$pref")
            fi
        done < <(command find ~/Library/Preferences/ByHost -maxdepth 1 -type f -name "*.plist" -print0 2> /dev/null)

        # User LaunchAgents: wildcard scan for helper plists (e.g., com.example.app.helper.plist)
        [[ -d ~/Library/LaunchAgents ]] && while IFS= read -r -d '' plist; do
            files_to_clean+=("$plist")
        done < <(command find ~/Library/LaunchAgents -maxdepth 1 \( -name "${bundle_id}.plist" -o -name "${bundle_id}.*.plist" \) -print0 2> /dev/null)

        # NSURLSession download caches
        local nsurlsession_dl="$HOME/Library/Caches/com.apple.nsurlsessiond/Downloads/$bundle_id"
        [[ -d "$nsurlsession_dl" ]] && files_to_clean+=("$nsurlsession_dl")

        # Group Containers (special handling)
        if [[ -d ~/Library/Group\ Containers ]]; then
            while IFS= read -r -d '' container; do
                if mole_name_has_bundle_id_boundary "$container" "$bundle_id"; then
                    files_to_clean+=("$container")
                fi
            done < <(command find ~/Library/Group\ Containers -maxdepth 1 -type d -print0 2> /dev/null)
        fi

        # App extensions often use bundle-id-derived directories rather than the
        # main bundle id exactly, for example share extensions or file providers.
        local -a derived_bundle_roots=(
            "$HOME/Library/Application Scripts"
            "$HOME/Library/Containers"
            "$HOME/Library/Application Support/FileProvider"
        )
        local derived_root=""
        local derived_path=""
        local existing_path=""
        local already_added=false
        for derived_root in "${derived_bundle_roots[@]}"; do
            [[ -d "$derived_root" ]] || continue
            while IFS= read -r -d '' derived_path; do
                mole_name_has_bundle_id_boundary "$derived_path" "$bundle_id" || continue
                already_added=false
                for existing_path in "${files_to_clean[@]}"; do
                    if [[ "$existing_path" == "$derived_path" ]]; then
                        already_added=true
                        break
                    fi
                done
                [[ "$already_added" == "true" ]] || files_to_clean+=("$derived_path")
            done < <(command find "$derived_root" -maxdepth 1 -type d -print0 2> /dev/null)
        done
    fi

    # Shared file lists (.sfl4 - recent documents etc.)
    if [[ "$bundle_id_valid" == "true" ]] &&
        [[ -d "$HOME/Library/Application Support/com.apple.sharedfilelist" ]]; then
        while IFS= read -r -d '' sfl4_file; do
            files_to_clean+=("$sfl4_file")
        done < <(command find "$HOME/Library/Application Support/com.apple.sharedfilelist" -maxdepth 2 -name "${bundle_id}.sfl4" -print0 2> /dev/null)
    fi

    # Launch Agents by name (special handling)
    # Note: LaunchDaemons are system-level and handled in find_app_system_files()
    # Minimum 5-char threshold prevents false positives (e.g., "Time" matching system agents)
    # Short-name apps (e.g., Zoom, Arc) are still cleaned via bundle_id matching above
    # Security: Common words are excluded to prevent matching unrelated plist files
    if [[ ${#app_name} -ge 5 ]] && [[ -d ~/Library/LaunchAgents ]]; then
        # Skip generic words that collide with many unrelated LaunchAgents.
        # Shared with the system-level scan in find_app_system_files();
        # defined in app_protection_data.sh.
        if [[ "$app_name" =~ ^(${LAUNCH_AGENT_NAME_COMMON_WORDS})$ ]]; then
            debug_log "Skipping LaunchAgent name search for common word: $app_name"
        else
            while IFS= read -r -d '' plist; do
                local plist_name=$(basename "$plist")
                # Skip Apple's LaunchAgents
                if [[ "$plist_name" =~ ^com\.apple\. ]]; then
                    continue
                fi
                files_to_clean+=("$plist")
            done < <(command find ~/Library/LaunchAgents -maxdepth 1 -name "*$app_name*.plist" -print0 2> /dev/null)
        fi
    fi

    # Handle specialized toolchains and development environments.
    # IMPORTANT: never auto-collect user project source, signing keys, OAuth
    # tokens, AVD images, SDK installs, or other manually-curated data. Only
    # regenerable cache/derived paths belong here. If a toolchain dir is mixed
    # (config + cache), skip the whole tree rather than guess.
    # 1. DevEco-Studio (Huawei)
    if [[ "$app_name" =~ DevEco|deveco ]] || [[ "$bundle_id" =~ huawei.*deveco ]]; then
        # Skipped: ~/DevEcoStudioProjects, ~/HarmonyOS, ~/Huawei (project
        # source); ~/DevEco-Studio (IDE config + license state); ~/Library/
        # Application Support/Huawei, ~/Library/Huawei, ~/.huawei, ~/.ohos
        # (Huawei account tokens, signed device profiles, SDK config). Only
        # sweep cache and log roots; everything else is opt-in.
        for d in ~/Library/Caches/Huawei ~/Library/Logs/Huawei; do
            [[ -d "$d" ]] && files_to_clean+=("$d")
        done
    fi

    # 2. Android Studio (Google)
    if [[ "$app_name" =~ Android.*Studio|android.*studio ]] || [[ "$bundle_id" =~ google.*android.*studio|jetbrains.*android ]]; then
        # Skipped: ~/AndroidStudioProjects (project source), ~/Library/Android
        # (SDK installs, multi-GB), ~/.android root (debug.keystore signing
        # key, adbkey device pairing, avd/ images). Only sweep regenerable
        # caches under ~/.android.
        for d in ~/.android/cache ~/.android/build-cache ~/.android/breakpad; do
            [[ -d "$d" ]] && files_to_clean+=("$d")
        done
        [[ -d ~/Library/Application\ Support/Google ]] && while IFS= read -r -d '' d; do files_to_clean+=("$d"); done < <(command find ~/Library/Application\ Support/Google -maxdepth 1 -name "AndroidStudio*" -print0 2> /dev/null)
    fi

    # 3. Xcode (Apple)
    if [[ "$app_name" =~ Xcode|xcode ]] || [[ "$bundle_id" =~ apple.*xcode ]]; then
        # Skipped: ~/Library/Developer root (Toolchains, Archives, UserData,
        # CoreSimulator/Devices, provisioning profiles). Only sweep
        # regenerable build/device caches.
        for d in \
            "$HOME/Library/Developer/Xcode/DerivedData" \
            "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
            "$HOME/Library/Developer/Xcode/macOS DeviceSupport" \
            "$HOME/Library/Developer/Xcode/watchOS DeviceSupport" \
            "$HOME/Library/Developer/Xcode/tvOS DeviceSupport" \
            "$HOME/Library/Developer/Xcode/xrOS DeviceSupport" \
            "$HOME/Library/Developer/CoreSimulator/Caches"; do
            [[ -d "$d" ]] && files_to_clean+=("$d")
        done
        [[ -d ~/.Xcode ]] && files_to_clean+=("$HOME/.Xcode")
    fi

    # 4. JetBrains (IDE settings)
    if [[ "$bundle_id" =~ jetbrains ]] || [[ "$app_name" =~ IntelliJ|PyCharm|WebStorm|GoLand|RubyMine|PhpStorm|CLion|DataGrip|Rider ]]; then
        for base in ~/Library/Application\ Support/JetBrains ~/Library/Caches/JetBrains ~/Library/Logs/JetBrains; do
            [[ -d "$base" ]] && while IFS= read -r -d '' d; do files_to_clean+=("$d"); done < <(command find "$base" -maxdepth 1 -name "${app_name}*" -print0 2> /dev/null)
        done
    fi

    # 5. Unity / Unreal / Godot
    [[ "$app_name" =~ Unity|unity ]] && [[ -d ~/Library/Unity ]] && files_to_clean+=("$HOME/Library/Unity")
    [[ "$app_name" =~ Unreal|unreal ]] && [[ -d ~/Library/Application\ Support/Epic ]] && files_to_clean+=("$HOME/Library/Application Support/Epic")
    [[ "$app_name" =~ Godot|godot ]] && [[ -d ~/Library/Application\ Support/Godot ]] && files_to_clean+=("$HOME/Library/Application Support/Godot")

    # 6. Tools
    # VS Code stores user data under folder names that don't match the app name
    # ("Visual Studio Code") or bundle id ("com.microsoft.VSCode"). The folder is
    # named "Code" (stable) or "Code - Insiders". Cover both channels explicitly
    # so uninstall removes them. Issue #850.
    if [[ "$bundle_id" =~ microsoft.*[vV][sS][cC]ode ]]; then
        [[ -d "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" ]] && files_to_clean+=("$HOME/Library/Caches/com.microsoft.VSCode.ShipIt")
        [[ -d "$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt" ]] && files_to_clean+=("$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt")
        if [[ "$bundle_id" =~ [iI]nsiders ]]; then
            [[ -d "$HOME/.vscode-insiders" ]] && files_to_clean+=("$HOME/.vscode-insiders")
            [[ -d "$HOME/Library/Application Support/Code - Insiders" ]] && files_to_clean+=("$HOME/Library/Application Support/Code - Insiders")
            [[ -d "$HOME/Library/Caches/com.microsoft.VSCodeInsiders" ]] && files_to_clean+=("$HOME/Library/Caches/com.microsoft.VSCodeInsiders")
        else
            [[ -d "$HOME/.vscode" ]] && files_to_clean+=("$HOME/.vscode")
            [[ -d "$HOME/Library/Application Support/Code" ]] && files_to_clean+=("$HOME/Library/Application Support/Code")
            [[ -d "$HOME/Library/Caches/com.microsoft.VSCode" ]] && files_to_clean+=("$HOME/Library/Caches/com.microsoft.VSCode")
        fi
    fi
    # Docker: ~/.docker holds config.json (Docker Hub auth tokens), contexts/
    # (kubeconfig-style endpoints, possibly with credentials), and cli-plugins.
    # Only sweep regenerable cache subtrees, never the whole tree.
    if [[ "$app_name" =~ Docker ]]; then
        for d in ~/.docker/buildx ~/.docker/scan; do
            [[ -d "$d" ]] && files_to_clean+=("$d")
        done
    fi

    # 6.1 Maestro Studio
    if [[ "$bundle_id" == "com.maestro.studio" ]] || [[ "$lowercase_name" =~ maestro[[:space:]]*studio ]]; then
        [[ -d ~/.mobiledev ]] && files_to_clean+=("$HOME/.mobiledev")
    fi

    # 7. Raycast
    if [[ "$bundle_id" == "com.raycast.macos" ]]; then
        # Standard user directories
        local raycast_dirs=(
            "$HOME/Library/Application Support"
            "$HOME/Library/Application Scripts"
            "$HOME/Library/Containers"
        )
        for dir in "${raycast_dirs[@]}"; do
            [[ -d "$dir" ]] && while IFS= read -r -d '' p; do
                files_to_clean+=("$p")
            done < <(command find "$dir" -maxdepth 1 -type d -iname "*raycast*" -print0 2> /dev/null)
        done

        # Explicit Raycast container directories (hardcoded leftovers)
        [[ -d "$HOME/Library/Containers/com.raycast.macos.BrowserExtension" ]] && files_to_clean+=("$HOME/Library/Containers/com.raycast.macos.BrowserExtension")
        [[ -d "$HOME/Library/Containers/com.raycast.macos.RaycastAppIntents" ]] && files_to_clean+=("$HOME/Library/Containers/com.raycast.macos.RaycastAppIntents")

        # Cache (deeper search)
        [[ -d "$HOME/Library/Caches" ]] && while IFS= read -r -d '' p; do
            files_to_clean+=("$p")
        done < <(command find "$HOME/Library/Caches" -maxdepth 2 -type d -iname "*raycast*" -print0 2> /dev/null)

        # VSCode extension storage
        local vscode_global="$HOME/Library/Application Support/Code/User/globalStorage"
        [[ -d "$vscode_global" ]] && while IFS= read -r -d '' p; do
            files_to_clean+=("$p")
        done < <(command find "$vscode_global" -maxdepth 1 -type d -iname "*raycast*" -print0 2> /dev/null)
    fi

    # CrashReporter plists: named AppName_UUID.plist (not subdirectories)
    local crash_reporter_dir="$HOME/Library/Application Support/CrashReporter"
    if [[ -d "$crash_reporter_dir" && ${#nospace_name} -ge 3 ]]; then
        while IFS= read -r -d '' cr; do
            files_to_clean+=("$cr")
        done < <(command find "$crash_reporter_dir" -maxdepth 1 -type f \
            \( -name "${app_name}_*.plist" -o -name "${nospace_name}_*.plist" \) \
            -print0 2> /dev/null)
    fi

    # Output results
    if [[ ${#files_to_clean[@]} -gt 0 ]]; then
        printf '%s\n' "${files_to_clean[@]}"
    fi
    return 0
}

get_diagnostic_report_paths_for_app() {
    local app_path="$1"
    local app_name="$2"
    local directory="$3"
    local prefix=""
    local exec_name=""
    local nospace_name="${app_name// /}"

    [[ -z "$app_path" || -z "$app_name" || -z "$directory" ]] && return 0
    [[ ! -d "$directory" ]] && return 0

    if [[ -f "$app_path/Contents/Info.plist" ]]; then
        exec_name=$(defaults read "$app_path/Contents/Info.plist" CFBundleExecutable 2> /dev/null || echo "")
        if [[ -z "$exec_name" ]]; then
            exec_name=$(grep -A1 "CFBundleExecutable" "$app_path/Contents/Info.plist" 2> /dev/null | grep "<string>" | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | head -1)
        fi
    fi
    prefix="${exec_name:-$nospace_name}"
    [[ -z "$prefix" || ${#prefix} -lt 3 ]] && return 0

    local dir_abs
    dir_abs=$(cd "$directory" 2> /dev/null && pwd -P 2> /dev/null) || return 0
    while IFS= read -r -d '' f; do
        [[ -z "$f" ]] && continue
        local base
        base=$(basename "$f" 2> /dev/null)
        case "$base" in
            "$prefix".* | "$prefix"_* | "$prefix"-*) ;;
            *) continue ;;
        esac
        case "$base" in
            *.ips | *.crash | *.spin | *.diag) ;;
            *) continue ;;
        esac
        printf '%s\n' "$f"
    done < <(
        find "$dir_abs" -maxdepth 1 -type f \
            \( -name "${prefix}.*" -o -name "${prefix}_*" -o -name "${prefix}-*" \) \
            -print0 2> /dev/null || true
    )
    return 0
}

# Locate system-level application files
find_app_system_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a system_files=()

    # Generate all naming variants (same as find_app_files for consistency)
    local nospace_name="${app_name// /}"
    local underscore_name="${app_name// /_}"
    local hyphen_name="${app_name// /-}"
    local lowercase_name=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
    local lowercase_nospace=$(echo "$nospace_name" | tr '[:upper:]' '[:lower:]')
    local lowercase_hyphen=$(echo "$hyphen_name" | tr '[:upper:]' '[:lower:]')
    local lowercase_underscore=$(echo "$underscore_name" | tr '[:upper:]' '[:lower:]')

    # Standard system path patterns
    local -a system_patterns=(
        "/Library/Application Support/$app_name"
        "/Library/Application Support/$bundle_id"
        "/Library/LaunchAgents/$bundle_id.plist"
        "/Library/LaunchDaemons/$bundle_id.plist"
        "/Library/Preferences/$bundle_id.plist"
        "/Library/Preferences/$app_name"
        "/Library/Preferences/$app_name.plist"
        "/Library/Receipts/$bundle_id.bom"
        "/Library/Receipts/$bundle_id.plist"
        "/Library/Frameworks/$app_name.framework"
        "/Library/Internet Plug-Ins/$app_name.plugin"
        "/Library/Input Methods/$app_name.app"
        "/Library/Input Methods/$bundle_id.app"
        "/Library/Audio/Plug-Ins/Components/$app_name.component"
        "/Library/Audio/Plug-Ins/VST/$app_name.vst"
        "/Library/Audio/Plug-Ins/VST3/$app_name.vst3"
        "/Library/Audio/Plug-Ins/Digidesign/$app_name.dpm"
        "/Library/QuickLook/$app_name.qlgenerator"
        "/Library/PreferencePanes/$app_name.prefPane"
        "/Library/Screen Savers/$app_name.saver"
        "/Library/Caches/$bundle_id"
        "/Library/Caches/$app_name"
        "/Library/Extensions/$app_name.kext"
        "/Library/StartupItems/$app_name"
        "/Library/Logs/$app_name"
        "/Library/Logs/$bundle_id"
    )

    # Add all naming variants for apps with spaces in name
    if [[ ${#app_name} -gt 3 && "$app_name" =~ [[:space:]] ]]; then
        system_patterns+=(
            "/Library/Application Support/$nospace_name"
            "/Library/Caches/$nospace_name"
            "/Library/Logs/$nospace_name"
            "/Library/Application Support/$underscore_name"
            "/Library/Application Support/$hyphen_name"
            "/Library/Preferences/$nospace_name"
            "/Library/Preferences/$nospace_name.plist"
            "/Library/Preferences/$underscore_name"
            "/Library/Preferences/$underscore_name.plist"
            "/Library/Preferences/$hyphen_name"
            "/Library/Preferences/$hyphen_name.plist"
            "/Library/Caches/$hyphen_name"
            "/Library/Caches/$lowercase_hyphen"
        )
    fi

    # Process patterns
    for p in "${system_patterns[@]}"; do
        [[ ! -e "$p" ]] && continue

        # Safety check: Skip if path ends with a common directory name (indicates empty app_name/bundle_id)
        case "$p" in
            /Library/Application\ Support | /Library/Application\ Support/ | \
                /Library/Caches | /Library/Caches/ | \
                /Library/Logs | /Library/Logs/ | \
                /Library/Preferences | /Library/Preferences/)
                continue
                ;;
        esac

        system_files+=("$p")
    done

    # Vendor-nested system support directories, e.g.:
    #   /Library/Application Support/Avid/Sibelius
    local vendor_nested_system_path
    while IFS= read -r vendor_nested_system_path; do
        [[ -n "$vendor_nested_system_path" && -e "$vendor_nested_system_path" ]] && system_files+=("$vendor_nested_system_path")
    done < <(
        find_vendor_nested_app_paths "$bundle_id" "$app_name" \
            "/Library/Application Support" \
            "/Library/Caches" \
            "/Library/Logs"
    )

    # Shared sample/support files are usually outside the user's Library but
    # are app-owned data (for example /Users/Shared/Sibelius ...).
    local shared_app_path
    while IFS= read -r shared_app_path; do
        [[ -n "$shared_app_path" && -e "$shared_app_path" ]] && system_files+=("$shared_app_path")
    done < <(find_shared_app_paths "$bundle_id" "$app_name" "/Users/Shared")

    # System LaunchAgents/LaunchDaemons often use bundle-id-derived helper
    # labels (for example "<bundle>.ProxyConfigHelper.plist"), so scan for
    # validated reverse-DNS bundle-id prefixes before falling back to app name.
    # The two -name patterns are anchored at the dot boundary so that, e.g.,
    # bundle "com.foo" matches "com.foo.plist" and "com.foo.helper.plist" but
    # NOT "com.foobar.plist" from an unrelated vendor.
    if mole_is_reverse_dns_bundle_id "$bundle_id"; then
        for base in /Library/LaunchAgents /Library/LaunchDaemons; do
            [[ -d "$base" ]] && while IFS= read -r -d '' plist; do
                system_files+=("$plist")
            done < <(command find "$base" -maxdepth 1 \( -name "${bundle_id}.plist" -o -name "${bundle_id}.*.plist" \) -print0 2> /dev/null)
        done
    fi

    # System LaunchAgents/LaunchDaemons by name. These live under /Library and
    # are removed with sudo, so mirror the (stricter) user-level guard above:
    # require >=5 chars, skip generic collision words, and skip Apple's own
    # plists. A short or generic app name must not match unrelated system agents.
    if [[ ${#app_name} -ge 5 ]] && ! [[ "$app_name" =~ ^(${LAUNCH_AGENT_NAME_COMMON_WORDS})$ ]]; then
        for base in /Library/LaunchAgents /Library/LaunchDaemons; do
            [[ -d "$base" ]] && while IFS= read -r -d '' plist; do
                local plist_name
                plist_name=$(basename "$plist")
                [[ "$plist_name" =~ ^com\.apple\. ]] && continue
                system_files+=("$plist")
            done < <(command find "$base" -maxdepth 1 \( -name "*$app_name*.plist" \) -print0 2> /dev/null)
        done
    fi

    # Privileged Helper Tools and Receipts (special handling)
    # Only search with bundle_id if it's valid (not empty and not "unknown")
    if mole_is_reverse_dns_bundle_id "$bundle_id"; then
        [[ -d /Library/PrivilegedHelperTools ]] && while IFS= read -r -d '' helper; do
            if mole_name_starts_with_bundle_id_boundary "$helper" "$bundle_id"; then
                system_files+=("$helper")
            fi
        done < <(command find /Library/PrivilegedHelperTools -maxdepth 1 -print0 2> /dev/null)

        [[ -d /private/var/db/receipts ]] && while IFS= read -r -d '' receipt; do
            if mole_name_starts_with_bundle_id_boundary "$receipt" "$bundle_id"; then
                system_files+=("$receipt")
            fi
        done < <(command find /private/var/db/receipts -maxdepth 1 -print0 2> /dev/null)
    fi

    # Some vendors name privileged helpers after the product rather than the
    # bundle id. System remnants are review-only in the CLI, but keep
    # conservative name guards to avoid noisy system matches: reject common app
    # words case-insensitively and require each matched variant to be at least
    # 5 characters, since nospace variants can be shorter than app_name itself.
    local -a helper_name_variants=()
    if ! _mole_uninstall_is_common_app_name "$app_name"; then
        local name_variant
        for name_variant in "$lowercase_name" "$lowercase_nospace" "$lowercase_hyphen" "$lowercase_underscore"; do
            if [[ ${#name_variant} -ge 5 ]]; then
                helper_name_variants+=("$name_variant")
            fi
        done
    fi
    if [[ ${#helper_name_variants[@]} -gt 0 && -d /Library/PrivilegedHelperTools ]]; then
        while IFS= read -r -d '' helper; do
            local helper_name
            local helper_lower
            helper_name=$(basename "$helper")
            [[ "$helper_name" =~ ^com\.apple\. ]] && continue
            helper_lower=$(_mole_uninstall_lower "$helper_name")
            if _mole_uninstall_name_variant_matches "$helper_lower" "${helper_name_variants[@]}"; then
                system_files+=("$helper")
            fi
        done < <(command find /Library/PrivilegedHelperTools -maxdepth 1 -print0 2> /dev/null)
    fi

    # Raycast system-level files
    if [[ "$bundle_id" == "com.raycast.macos" ]]; then
        [[ -d "/Library/Application Support" ]] && while IFS= read -r -d '' p; do
            system_files+=("$p")
        done < <(command find "/Library/Application Support" -maxdepth 1 -type d -iname "*raycast*" -print0 2> /dev/null)
    fi

    local receipt_files=""
    receipt_files=$(find_app_receipt_files "$bundle_id")

    local combined_files=""
    if [[ ${#system_files[@]} -gt 0 ]]; then
        combined_files=$(printf '%s\n' "${system_files[@]}")
    fi

    if [[ -n "$receipt_files" ]]; then
        if [[ -n "$combined_files" ]]; then
            combined_files+=$'\n'
        fi
        combined_files+="$receipt_files"
    fi

    if [[ -n "$combined_files" ]]; then
        printf '%s\n' "$combined_files" | sort -u
    fi
}

# Locate files using installation receipts (BOM)
find_app_receipt_files() {
    local bundle_id="$1"

    # Skip if no bundle ID
    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 0

    # Validate bundle_id format to prevent wildcard or defaults-domain abuse.
    if ! mole_is_reverse_dns_bundle_id "$bundle_id"; then
        debug_log "Invalid bundle_id format: $bundle_id"
        return 0
    fi

    local -a receipt_files=()
    local -a bom_files=()

    # Find receipts matching the bundle ID
    # Usually in /var/db/receipts/
    if [[ -d /private/var/db/receipts ]]; then
        while IFS= read -r -d '' bom; do
            if mole_name_starts_with_bundle_id_boundary "$bom" "$bundle_id"; then
                bom_files+=("$bom")
            fi
        done < <(find /private/var/db/receipts -maxdepth 1 -name "*.bom" -print0 2> /dev/null)
    fi

    # Process bom files if any found
    if [[ ${#bom_files[@]} -gt 0 ]]; then
        for bom_file in "${bom_files[@]}"; do
            [[ ! -f "$bom_file" ]] && continue

            # Parse bom file
            # lsbom -f: file paths only
            # -s: suppress output (convert to text)
            local bom_content
            bom_content=$(lsbom -f -s "$bom_file" 2> /dev/null)

            while IFS= read -r file_path; do
                # Standardize path (remove leading dot)
                local clean_path="${file_path#.}"

                # Ensure absolute path
                if [[ "$clean_path" != /* ]]; then
                    clean_path="/$clean_path"
                fi

                # Path traversal protection: reject paths containing ..
                if [[ "$clean_path" =~ \.\. ]]; then
                    debug_log "Rejected path traversal in BOM: $clean_path"
                    continue
                fi

                # Normalize path (remove duplicate slashes)
                clean_path=$(tr -s "/" <<< "$clean_path")

                if receipt_payload_path_is_allowlisted "$clean_path" "$bundle_id" && [[ -e "$clean_path" ]]; then
                    # Skip top-level directories
                    if [[ "$clean_path" == "/Applications" || "$clean_path" == "/Library" ]]; then
                        continue
                    fi

                    if declare -f should_protect_path > /dev/null 2>&1; then
                        if should_protect_path "$clean_path"; then
                            continue
                        fi
                    fi

                    receipt_files+=("$clean_path")
                fi

            done <<< "$bom_content"
        done
    fi
    if [[ ${#receipt_files[@]} -gt 0 ]]; then
        printf '%s\n' "${receipt_files[@]}"
    fi
}

receipt_payload_path_is_allowlisted() {
    local clean_path="$1"
    local bundle_id="$2"
    local base
    base=$(basename "$clean_path")

    [[ -n "$clean_path" && -n "$bundle_id" ]] || return 1
    mole_is_reverse_dns_bundle_id "$bundle_id" || return 1

    case "$clean_path" in
        /Library/LaunchAgents/*.plist | /Library/LaunchDaemons/*.plist)
            [[ "$base" == "$bundle_id.plist" || "$base" == "$bundle_id."*.plist ]]
            return
            ;;
        /Library/PrivilegedHelperTools/*)
            mole_name_starts_with_bundle_id_boundary "$base" "$bundle_id"
            return
            ;;
        /private/var/db/receipts/*)
            [[ "$base" == "$bundle_id.bom" || "$base" == "$bundle_id.plist" || "$base" == "$bundle_id."* ]]
            return
            ;;
    esac

    return 1
}

# Terminate a running application during uninstall.
# The user has already confirmed removal, so after the graceful Quit Apple
# Event we escalate through SIGTERM and SIGKILL (and one sudo retry when
# non-interactive sudo is already cached) to avoid leaving a zombie process
# after "Uninstall complete". Apps that need to flush state get the graceful
# Quit window first; apps that stall past it lose unsaved work, which the
# user has implicitly accepted by confirming.
force_kill_app() {
    local app_name="$1"
    local app_path="${2:-""}"

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would terminate running app: $app_name"
        return 0
    fi

    # Get the executable name and bundle id from Info.plist when available.
    # bundle id is preferred for the AppleScript Quit step because it is more
    # precise than the display name (which may be localized).
    local exec_name=""
    local bundle_id=""
    if [[ -n "$app_path" && -e "$app_path/Contents/Info.plist" ]]; then
        exec_name=$(defaults read "$app_path/Contents/Info.plist" CFBundleExecutable 2> /dev/null || echo "")
        bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2> /dev/null || echo "")
    fi

    # Use executable name for precise matching, fallback to app name
    local match_pattern="${exec_name:-$app_name}"

    # Defensive guard: even though should_protect_from_uninstall (bin/uninstall.sh)
    # filters protected bundle IDs out of the selection list, match_pattern comes
    # from CFBundleExecutable (a string a third-party .app can set freely). Refuse
    # to AppleScript-Quit or pkill any pattern that exactly matches a critical
    # system process name. force_kill_app is a public function; future callers
    # must not be able to weaponise a spoofed executable name to take down Finder,
    # Dock, loginwindow, etc.
    case "$match_pattern" in
        Finder | Dock | loginwindow | WindowServer | SystemUIServer | launchd | coreaudiod | NotificationCenter | ControlCenter | Spotlight)
            debug_log "force_kill_app: refusing to operate on system process name '$match_pattern'"
            return 1
            ;;
    esac

    # Check if process is running using exact match only
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    # Send a graceful Quit Apple Event first. Many Tauri/Electron/SwiftUI GUI
    # apps install an event loop that ignores SIGTERM but responds to the
    # standard "quit" Apple Event by going through their normal terminate
    # flow (including unsaved-state prompts). osascript is best-effort: we
    # cap the wait so a hung app, an automation-permission dialog, or a
    # missing osascript binary can never stall the uninstall.
    if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]] &&
        command -v osascript > /dev/null 2>&1; then
        local quit_target=""
        if mole_is_reverse_dns_bundle_id "$bundle_id"; then
            quit_target="id \"$bundle_id\""
        else
            # Escape embedded double quotes in app_name before passing into
            # the AppleScript literal.
            local escaped_name="${app_name//\\/\\\\}"
            escaped_name="${escaped_name//\"/\\\"}"
            quit_target="\"$escaped_name\""
        fi
        run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" osascript -e "tell application $quit_target to quit" > /dev/null 2>&1 &
        local quit_pid=$!
        # Poll briefly so the kill ladder skips when the app exits cleanly.
        local quit_wait=20
        while [[ $quit_wait -gt 0 ]] && pgrep -x "$match_pattern" > /dev/null 2>&1; do
            sleep 0.1
            ((quit_wait--))
        done
        wait "$quit_pid" 2> /dev/null || true
    fi

    # Graceful Quit landed: skip the kill ladder entirely.
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    # Escalate: SIGTERM, then SIGKILL, then one sudo SIGKILL retry when a
    # cached sudo session is already available (no new prompt). The user
    # confirmed uninstall, so a still-running process at this point is
    # blocking a clean result and we trade unsaved state for that.
    pkill -x "$match_pattern" 2> /dev/null || true
    sleep 2
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    pkill -9 -x "$match_pattern" 2> /dev/null || true
    sleep 2
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]] &&
        sudo -n true 2> /dev/null; then
        sudo pkill -9 -x "$match_pattern" 2> /dev/null || true
        sleep 2
    fi

    # Final retries for stubborn processes (e.g. apps mid-fsync that need a
    # moment to fully exit after SIGKILL).
    local retries=3
    while [[ $retries -gt 0 ]]; do
        if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((retries--))
    done

    pgrep -x "$match_pattern" > /dev/null 2>&1 && return 1 || return 0
}

# Note: calculate_total_size() is defined in lib/core/file_ops.sh
