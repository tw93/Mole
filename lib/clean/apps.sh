#!/bin/bash
# Application Data Cleanup Module
set -euo pipefail

readonly ORPHAN_AGE_THRESHOLD=${ORPHAN_AGE_THRESHOLD:-${MOLE_ORPHAN_AGE_DAYS:-30}}
readonly CLAUDE_VM_ORPHAN_AGE_THRESHOLD=${MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS:-7}
# Args: $1=target_dir, $2=label
clean_ds_store_tree() {
    local target="$1"
    local label="$2"
    [[ -d "$target" ]] || return 0
    local file_count=0
    local total_bytes=0
    local spinner_active="false"
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  "
        start_inline_spinner "Cleaning Finder metadata..."
        spinner_active="true"
    fi
    local -a exclude_paths=(
        -path "*/Library/Application Support/MobileSync" -prune -o
        -path "*/Library/Developer" -prune -o
        -path "*/.Trash" -prune -o
        -path "*/node_modules" -prune -o
        -path "*/.git" -prune -o
        -path "*/Library/Caches" -prune -o
    )
    local -a find_cmd=("command" "find" "$target")
    if [[ "$target" == "$HOME" ]]; then
        find_cmd+=("-maxdepth" "5")
    fi
    find_cmd+=("${exclude_paths[@]}" "-type" "f" "-name" ".DS_Store" "-print0")
    while IFS= read -r -d '' ds_file; do
        local size
        size=$(get_file_size "$ds_file")
        total_bytes=$((total_bytes + size))
        file_count=$((file_count + 1))
        if [[ "$DRY_RUN" != "true" ]]; then
            safe_remove "$ds_file" true 2> /dev/null || true
        fi
        if [[ $file_count -ge $MOLE_MAX_DS_STORE_FILES ]]; then
            break
        fi
    done < <("${find_cmd[@]}" 2> /dev/null || true)
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $file_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$total_bytes")
        local size_kb=$(((total_bytes + 1023) / 1024))
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label${NC}, ${YELLOW}$file_count files, $size_human dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$size_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} $label${NC}, ${line_color}$file_count files, $size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + file_count))
        total_size_cleaned=$((total_size_cleaned + size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
}
# Orphaned app data (30+ days inactive). Env: ORPHAN_AGE_THRESHOLD, DRY_RUN
# Usage: scan_installed_apps "output_file"
scan_installed_apps() {
    local installed_bundles="$1"
    # Cache installed app scan briefly to speed repeated runs.
    local cache_file="$HOME/.cache/mole/installed_apps_cache"
    local cache_age_seconds=300 # 5 minutes
    if [[ -f "$cache_file" ]]; then
        local cache_mtime=$(get_file_mtime "$cache_file")
        local current_time
        current_time=$(get_epoch_seconds)
        local age=$((current_time - cache_mtime))
        if [[ $age -lt $cache_age_seconds ]]; then
            debug_log "Using cached app list, age: ${age}s"
            if [[ -r "$cache_file" ]] && [[ -s "$cache_file" ]]; then
                if cat "$cache_file" > "$installed_bundles" 2> /dev/null; then
                    return 0
                else
                    debug_log "Warning: Failed to read cache, rebuilding"
                fi
            else
                debug_log "Warning: Cache file empty or unreadable, rebuilding"
            fi
        fi
    fi
    debug_log "Scanning installed applications, cache expired or missing"
    local -a app_dirs=(
        "/Applications"
        "/System/Applications"
        "$HOME/Applications"
        # Homebrew Cask locations
        "/opt/homebrew/Caskroom"
        "/usr/local/Caskroom"
        # Setapp applications
        "$HOME/Library/Application Support/Setapp/Applications"
    )
    # Temp dir avoids write contention across parallel scans.
    local scan_tmp_dir=$(create_temp_dir)
    local pids=()
    local dir_idx=0
    for app_dir in "${app_dirs[@]}"; do
        [[ -d "$app_dir" ]] || continue
        (
            local -a app_paths=()
            while IFS= read -r app_path; do
                [[ -n "$app_path" ]] && app_paths+=("$app_path")
            done < <(command find "$app_dir" -maxdepth 3 -type d -name '*.app' 2> /dev/null)
            local count=0
            for app_path in "${app_paths[@]:-}"; do
                local plist_path="$app_path/Contents/Info.plist"
                [[ ! -f "$plist_path" ]] && continue
                local bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist_path" 2> /dev/null || echo "")
                if [[ -n "$bundle_id" && "$bundle_id" != "missing value" ]]; then
                    echo "$bundle_id"
                    count=$((count + 1))
                fi
            done
        ) > "$scan_tmp_dir/apps_${dir_idx}.txt" &
        pids+=($!)
        dir_idx=$((dir_idx + 1))
    done
    # Collect running apps and LaunchAgents to avoid false orphan cleanup.
    (
        # Skip AppleScript during tests to avoid permission dialogs
        if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
            local running_apps=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" osascript -e 'tell application "System Events" to get bundle identifier of every application process' 2> /dev/null || echo "")
            echo "$running_apps" | tr ',' '\n' | sed -e 's/^ *//;s/ *$//' -e '/^$/d' -e '/^missing value$/d' > "$scan_tmp_dir/running.txt"
        fi
        # Fallback: lsappinfo is more reliable than osascript
        if command -v lsappinfo > /dev/null 2>&1; then
            run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" lsappinfo list 2> /dev/null | grep -o '"CFBundleIdentifier"="[^"]*"' | cut -d'"' -f4 >> "$scan_tmp_dir/running.txt" 2> /dev/null || true
        fi
    ) &
    pids+=($!)
    (
        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find ~/Library/LaunchAgents /Library/LaunchAgents \
            -name "*.plist" -type f 2> /dev/null |
            xargs -I {} basename {} .plist > "$scan_tmp_dir/agents.txt" 2> /dev/null || true
    ) &
    pids+=($!)
    debug_log "Waiting for ${#pids[@]} background processes: ${pids[*]}"
    if [[ ${#pids[@]} -gt 0 ]]; then
        for pid in "${pids[@]}"; do
            wait "$pid" 2> /dev/null || true
        done
    fi
    debug_log "All background processes completed"
    cat "$scan_tmp_dir"/*.txt >> "$installed_bundles" 2> /dev/null || true
    safe_remove "$scan_tmp_dir" true
    sort -u "$installed_bundles" -o "$installed_bundles"
    ensure_user_dir "$(dirname "$cache_file")"
    cp "$installed_bundles" "$cache_file" 2> /dev/null || true
    local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
    debug_log "Scanned $app_count unique applications"
}
# Sensitive data patterns that should never be treated as orphaned
# These patterns protect security-critical application data
readonly ORPHAN_NEVER_DELETE_PATTERNS=(
    "*1password*" "*1Password*"
    "*keychain*" "*Keychain*"
    "*bitwarden*" "*Bitwarden*"
    "*lastpass*" "*LastPass*"
    "*keepass*" "*KeePass*"
    "*dashlane*" "*Dashlane*"
    "*enpass*" "*Enpass*"
    "*ssh*" "*gpg*" "*gnupg*"
    "com.apple.keychain*"
)

# In-memory mdfind result cache (Bash 3.2 compatible, no associative arrays).
# Newline-delimited strings checked via case glob — no subprocess per lookup.
_MOLE_MDFIND_FOUND=""
_MOLE_MDFIND_NOTFOUND=""

_mdfind_cache_check() {
    local bundle_id="$1"
    local _nl=$'\n'
    case "${_nl}${_MOLE_MDFIND_FOUND}${_nl}" in
        *"${_nl}${bundle_id}${_nl}"*) return 0 ;;
    esac
    case "${_nl}${_MOLE_MDFIND_NOTFOUND}${_nl}" in
        *"${_nl}${bundle_id}${_nl}"*) return 1 ;;
    esac
    return 2
}

_mdfind_cache_store() {
    local bundle_id="$1"
    local found="$2"
    if [[ "$found" == "true" ]]; then
        _MOLE_MDFIND_FOUND="${_MOLE_MDFIND_FOUND:+${_MOLE_MDFIND_FOUND}
}${bundle_id}"
    else
        _MOLE_MDFIND_NOTFOUND="${_MOLE_MDFIND_NOTFOUND:+${_MOLE_MDFIND_NOTFOUND}
}${bundle_id}"
    fi
}

# Usage: is_bundle_orphaned "bundle_id" "directory_path" "installed_bundles_file"
is_bundle_orphaned() {
    local bundle_id="$1"
    local directory_path="$2"
    local installed_bundles="$3"

    # 1. Fast path: check protection list (in-memory, instant)
    if should_protect_data "$bundle_id"; then
        return 1
    fi

    # 2. Fast path: check sensitive data patterns (in-memory, instant)
    local bundle_lower
    bundle_lower=$(echo "$bundle_id" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    for pattern in "${ORPHAN_NEVER_DELETE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$bundle_lower" == $pattern ]]; then
            return 1
        fi
    done

    # 3. Fast path: check installed bundles file (file read, fast)
    if grep -Fxq "$bundle_id" "$installed_bundles" 2> /dev/null; then
        return 1
    fi

    # 4. Fast path: hardcoded system components
    case "$bundle_id" in
        loginwindow | dock | systempreferences | systemsettings | settings | controlcenter | finder | safari)
            return 1
            ;;
    esac

    # 5. Fast path: 30-day modification check (stat call, fast)
    if [[ -e "$directory_path" ]]; then
        local last_modified_epoch=$(get_file_mtime "$directory_path")
        local current_epoch
        current_epoch=$(get_epoch_seconds)
        local days_since_modified=$(((current_epoch - last_modified_epoch) / 86400))
        if [[ $days_since_modified -lt ${ORPHAN_AGE_THRESHOLD:-30} ]]; then
            return 1
        fi
    fi

    # 6. Slow path: mdfind fallback with in-memory caching (Bash 3.2 compatible)
    # This catches apps installed in non-standard locations
    if mole_is_reverse_dns_bundle_id "$bundle_id"; then
        local _cache_rc=0
        _mdfind_cache_check "$bundle_id" || _cache_rc=$?
        if [[ $_cache_rc -eq 0 ]]; then
            return 1
        elif [[ $_cache_rc -eq 2 ]]; then
            local app_exists
            app_exists=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1 || echo "")
            if [[ -n "$app_exists" ]]; then
                _mdfind_cache_store "$bundle_id" "true"
                return 1
            else
                _mdfind_cache_store "$bundle_id" "false"
            fi
        fi
    fi

    # All checks passed - this is an orphan
    return 0
}

is_claude_vm_bundle_orphaned() {
    local vm_bundle_path="$1"
    local installed_bundles="$2"
    local claude_bundle_id="com.anthropic.claudefordesktop"

    [[ -d "$vm_bundle_path" ]] || return 1

    # Extra guard in case the running-app scan missed Claude Desktop.
    if pgrep -x "Claude" > /dev/null 2>&1; then
        return 1
    fi

    if grep -Fxq "$claude_bundle_id" "$installed_bundles" 2> /dev/null; then
        return 1
    fi

    if [[ -e "$vm_bundle_path" ]]; then
        local last_modified_epoch
        last_modified_epoch=$(get_file_mtime "$vm_bundle_path")
        local current_epoch
        current_epoch=$(get_epoch_seconds)
        local days_since_modified=$(((current_epoch - last_modified_epoch) / 86400))
        if [[ $days_since_modified -lt ${CLAUDE_VM_ORPHAN_AGE_THRESHOLD:-7} ]]; then
            return 1
        fi
    fi

    local _cache_rc=0
    _mdfind_cache_check "$claude_bundle_id" || _cache_rc=$?
    if [[ $_cache_rc -eq 0 ]]; then
        return 1
    elif [[ $_cache_rc -eq 2 ]]; then
        local app_exists
        app_exists=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemCFBundleIdentifier == '$claude_bundle_id'" 2> /dev/null | head -1 || echo "")
        if [[ -n "$app_exists" ]]; then
            _mdfind_cache_store "$claude_bundle_id" "true"
            return 1
        fi
        _mdfind_cache_store "$claude_bundle_id" "false"
    fi

    return 0
}

# Orphaned app data sweep.
clean_orphaned_app_data() {
    if ! ls "$HOME/Library/Caches" > /dev/null 2>&1; then
        stop_section_spinner
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipped: No permission to access Library folders"
        return 0
    fi
    start_section_spinner "Scanning installed apps..."
    local installed_bundles=$(create_temp_file)
    scan_installed_apps "$installed_bundles"
    stop_section_spinner
    local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $app_count active/installed apps"
    local orphaned_count=0
    local total_orphaned_kb=0
    start_section_spinner "Scanning orphaned app resources..."

    # Dynamically discover Claude VM bundles (path may vary across versions).
    local claude_support_dir="$HOME/Library/Application Support/Claude"
    if [[ -d "$claude_support_dir" ]]; then
        while IFS= read -r -d '' claude_vm_bundle; do
            if is_claude_vm_bundle_orphaned "$claude_vm_bundle" "$installed_bundles"; then
                if is_path_whitelisted "$claude_vm_bundle"; then
                    debug_log "Skipping whitelisted orphan: $claude_vm_bundle"
                    continue
                fi
                local claude_vm_size_kb
                claude_vm_size_kb=$(get_path_size_kb "$claude_vm_bundle")
                if [[ -n "$claude_vm_size_kb" && "$claude_vm_size_kb" != "0" ]]; then
                    if safe_clean "$claude_vm_bundle" "Orphaned Claude workspace VM"; then
                        orphaned_count=$((orphaned_count + 1))
                        total_orphaned_kb=$((total_orphaned_kb + claude_vm_size_kb))
                    fi
                fi
            fi
        done < <(find "$claude_support_dir" -maxdepth 3 -name "*.bundle" -type d -print0 2> /dev/null || true)
    fi

    # CRITICAL: NEVER add LaunchAgents or LaunchDaemons (breaks login items/startup apps).
    # CRITICAL: NEVER add Containers/ (managed by containermanagerd, stubs expected).
    # CRITICAL: NEVER add Application Scripts/ (could break Shortcuts/Automator workflows).
    # CRITICAL: NEVER add Group Containers/ (TeamID.BundleID names cause false-positive orphan checks).
    local -a resource_types=(
        "$HOME/Library/Caches|Caches|com.*:org.*:net.*:io.*"
        "$HOME/Library/Logs|Logs|com.*:org.*:net.*:io.*"
        "$HOME/Library/Saved Application State|States|*.savedState"
    )
    for resource_type in "${resource_types[@]}"; do
        IFS='|' read -r base_path label patterns <<< "$resource_type"
        if [[ ! -d "$base_path" ]]; then
            continue
        fi
        if ! ls "$base_path" > /dev/null 2>&1; then
            continue
        fi
        local -a file_patterns=()
        IFS=':' read -ra pattern_arr <<< "$patterns"
        for pat in "${pattern_arr[@]}"; do
            file_patterns+=("$base_path/$pat")
        done
        if [[ ${#file_patterns[@]} -gt 0 ]]; then
            local _nullglob_state
            _nullglob_state=$(shopt -p nullglob || true)
            shopt -s nullglob
            for item_path in "${file_patterns[@]}"; do
                local iteration_count=0
                local old_ifs=$IFS
                IFS=$'\n'
                local -a matches=()
                # shellcheck disable=SC2206
                matches=($item_path)
                IFS=$old_ifs
                if [[ ${#matches[@]} -eq 0 ]]; then
                    continue
                fi
                for match in "${matches[@]}"; do
                    [[ -e "$match" ]] || continue
                    iteration_count=$((iteration_count + 1))
                    if [[ $iteration_count -gt $MOLE_MAX_ORPHAN_ITERATIONS ]]; then
                        break
                    fi
                    local bundle_id=$(basename "$match")
                    bundle_id="${bundle_id%.savedState}"
                    bundle_id="${bundle_id%.binarycookies}"
                    bundle_id="${bundle_id%.plist}"
                    if is_bundle_orphaned "$bundle_id" "$match" "$installed_bundles"; then
                        if is_path_whitelisted "$match"; then
                            debug_log "Skipping whitelisted orphan: $match"
                            continue
                        fi
                        local size_kb
                        size_kb=$(get_path_size_kb "$match")
                        if [[ -z "$size_kb" || "$size_kb" == "0" ]]; then
                            continue
                        fi
                        if safe_clean "$match" "Orphaned $label: $bundle_id"; then
                            orphaned_count=$((orphaned_count + 1))
                            total_orphaned_kb=$((total_orphaned_kb + size_kb))
                        fi
                    fi
                done
            done
            # eval: restore shopt state captured by $(shopt -p)
            eval "$_nullglob_state"
        fi
    done
    stop_section_spinner
    if [[ $orphaned_count -gt 0 ]]; then
        local orphaned_mb=$(echo "$total_orphaned_kb" | awk '{printf "%.1f", $1/1024}')
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $orphaned_count items, about ${orphaned_mb}MB"
        note_activity
    fi
    rm -f "$installed_bundles"
}

# Clean orphaned system-level services (LaunchDaemons, LaunchAgents, PrivilegedHelperTools)
# These are left behind when apps are uninstalled but their system services remain
clean_orphaned_system_services() {
    # Requires sudo
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]] || ! sudo -n true 2> /dev/null; then
        return 0
    fi

    start_section_spinner "Scanning orphaned system services..."

    local orphaned_count=0
    local -a orphaned_files=()
    # Force-protect list: if a plist's bundle ID matches one of these patterns AND
    # the associated app IS installed, skip removal even if the binary appears missing.
    # Format: "bundle_id_glob:pipe-separated app paths"
    # NOTE: This list is now purely protective. Generic binary-existence detection
    # (below) handles discovery; this list prevents false positives for known apps.
    local -a known_protect_patterns=(
        # Sogou Input Method
        "com.sogou.*:/Library/Input Methods/SogouInput.app"
        # ClashX
        "com.west2online.ClashX.*:/Applications/ClashX.app"
        # ClashMac
        "com.clashmac.*:/Applications/ClashMac.app"
        # Nektony App Cleaner
        "com.nektony.AC*:/Applications/App Cleaner & Uninstaller.app"
        # i4tools (爱思助手)
        "cn.i4tools.*:/Applications/i4Tools.app"
        # MacPaw CleanMyMac X / CleanMyMac (MAS and direct)
        "com.macpaw.CleanMyMac*:/Applications/CleanMyMac X.app"
        # Wireshark Foundation – ChmodBPF daemon
        "org.wireshark.ChmodBPF:/Applications/Wireshark.app"
        # Zoom Video Communications – daemon, updater agents, PrivilegedHelperTool
        "us.zoom.*:/Applications/zoom.us.app"
        # remot3.it / Remote.It – CLI daemon
        "it.remote.cli:/Applications/Remote.It.app"
        # Docker – system socket and vmnetd helpers (Docker.app manages these)
        "com.docker.*:/Applications/Docker.app"
        # NetBird / Wiretrustee – CLI-managed daemon (binary in /usr/local/bin)
        "netbird:/usr/local/bin/netbird"
        # Homebrew-managed services (managed by brew services, not .app bundles)
        "homebrew.mxcl.*:"
    )

    # Returns 0 (found/protected) when any app backing a system service is installed.
    # app_path may be a pipe-separated list of candidate .app paths; any match = protected.
    # An empty app_path always returns 0 (unconditionally protected).
    _system_service_app_exists() {
        local bundle_id="$1"
        local app_path_raw="$2"

        # Empty path = unconditionally protected (e.g. homebrew.mxcl.*)
        [[ -z "$app_path_raw" ]] && return 0

        # Split on '|' to support multi-app helpers (e.g. Cindori TEHelper).
        local _IFS_save="$IFS"
        IFS='|'
        # shellcheck disable=SC2206  # intentional word-split on '|' delimiter
        local -a app_paths=($app_path_raw)
        IFS="$_IFS_save"

        local _path
        for _path in "${app_paths[@]}"; do
            [[ -n "$_path" ]] || continue
            # Protect if the app path or binary exists
            [[ -d "$_path" || -e "$_path" ]] && return 0

            local app_name
            app_name=$(basename "$_path")
            case "$_path" in
                /Applications/*)
                    [[ -d "$HOME/Applications/$app_name" ]] && return 0
                    [[ -d "/Applications/Setapp/$app_name" ]] && return 0
                    ;;
                /Library/Input\ Methods/*)
                    [[ -d "$HOME/Library/Input Methods/$app_name" ]] && return 0
                    ;;
            esac
        done

        if mole_is_reverse_dns_bundle_id "$bundle_id"; then
            local _cache_rc=0
            _mdfind_cache_check "$bundle_id" || _cache_rc=$?
            if [[ $_cache_rc -eq 0 ]]; then
                return 0
            elif [[ $_cache_rc -eq 2 ]]; then
                local app_found
                app_found=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1 || echo "")
                if [[ -n "$app_found" ]]; then
                    _mdfind_cache_store "$bundle_id" "true"
                    return 0
                fi
                _mdfind_cache_store "$bundle_id" "false"
            fi
        fi

        return 1
    }

    # Read a launchd program path from a system plist.
    # The plist itself was discovered with sudo, so read it with sudo too (the
    # caller already cleared a `sudo -n true` probe, so keep it non-interactive):
    # unreadable root-owned plists make PlistBuddy print a non-path "File Doesn't
    # Exist, Will Create..." message on stdout, which must never be treated as a
    # missing binary path.
    _plist_program_value() {
        local plist="$1"
        local key="$2"
        local value=""
        value=$(sudo -n /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2> /dev/null || true)

        [[ -z "$value" ]] && return 1
        [[ "$value" != /* ]] && return 1

        printf '%s\n' "$value"
    }

    # Read the program binary from a plist (Program or ProgramArguments[0]).
    # Prints the path; returns 1 if no usable absolute Program key found.
    _plist_binary_path() {
        local plist="$1"
        local binary=""
        binary=$(_plist_program_value "$plist" "ProgramArguments:0" || true)
        [[ -z "$binary" ]] && binary=$(_plist_program_value "$plist" "Program" || true)
        [[ -z "$binary" ]] && return 1
        printf '%s\n' "$binary"
    }

    # Returns 0 if the binary path is managed by a package manager or lives in a
    # system directory — these should never be treated as orphans even when missing.
    _is_package_managed_binary() {
        local binary="$1"
        case "$binary" in
            /usr/local/bin/* | /usr/local/sbin/* | \
                /opt/homebrew/bin/* | /opt/homebrew/sbin/* | \
                /opt/homebrew/opt/*/bin/* | /opt/homebrew/opt/*/sbin/* | \
                /usr/bin/* | /usr/sbin/* | /bin/* | /sbin/* | \
                /usr/libexec/*)
                return 0
                ;;
        esac
        return 1
    }

    # Generic plist orphan check: returns 0 if the plist is orphaned.
    # A plist is orphaned when:
    #   1. Its Program binary path is known and missing from disk, AND
    #   2. The binary is not in a package-manager / system directory, AND
    #   3. No protect pattern covers this bundle ID.
    _plist_is_orphaned() {
        local plist="$1"
        local bundle_id="$2"

        # Read the binary the plist points to.
        local binary
        binary=$(_plist_binary_path "$plist") || return 1 # no Program key → skip

        # If the binary still exists, check if it's in PrivilegedHelperTools.
        # If so, verify the parent app is still installed. If the parent app
        # is gone, the binary itself is orphaned, so this plist is too. See #1082.
        if [[ -e "$binary" ]]; then
            if [[ "$binary" == /Library/PrivilegedHelperTools/* ]]; then
                local helper_bundle_id
                helper_bundle_id=$(basename "$binary")
                helper_bundle_id="${helper_bundle_id%.plist}"
                if bundle_has_installed_app "$helper_bundle_id"; then
                    return 1 # Parent app still installed, plist is healthy
                fi
                # Parent app is gone, binary is orphaned, so plist is orphaned
                return 0
            fi
            return 1 # Binary exists and not in PrivilegedHelperTools, plist is healthy
        fi

        # If the binary is in a package-manager / system path, skip.
        _is_package_managed_binary "$binary" && return 1

        # Check protect patterns: if any matching pattern declares the app as
        # installed, this plist is protected.
        local pattern_entry
        for pattern_entry in "${known_protect_patterns[@]}"; do
            local file_pattern="${pattern_entry%%:*}"
            local app_path="${pattern_entry#*:}"
            # shellcheck disable=SC2053
            [[ "$bundle_id" == $file_pattern ]] || continue
            _system_service_app_exists "$bundle_id" "$app_path" && return 1
            # Pattern matched and app is gone → don't protect (fall through).
            break
        done

        return 0 # orphaned
    }

    # Scan system LaunchDaemons
    if [[ -d /Library/LaunchDaemons ]]; then
        while IFS= read -r -d '' plist; do
            local filename
            filename=$(basename "$plist")

            # Skip Apple system files
            [[ "$filename" == com.apple.* ]] && continue

            local bundle_id="${filename%.plist}"

            # Generic detection: binary-existence check.
            if _plist_is_orphaned "$plist" "$bundle_id"; then
                orphaned_files+=("$plist")
                orphaned_count=$((orphaned_count + 1))
            fi
        done < <(sudo -n find /Library/LaunchDaemons -maxdepth 1 -name "*.plist" -print0 2> /dev/null)
    fi

    # Scan system LaunchAgents
    if [[ -d /Library/LaunchAgents ]]; then
        while IFS= read -r -d '' plist; do
            local filename
            filename=$(basename "$plist")

            # Skip Apple system files
            [[ "$filename" == com.apple.* ]] && continue

            local bundle_id="${filename%.plist}"

            # Generic detection: binary-existence check.
            if _plist_is_orphaned "$plist" "$bundle_id"; then
                orphaned_files+=("$plist")
                orphaned_count=$((orphaned_count + 1))
            fi
        done < <(sudo -n find /Library/LaunchAgents -maxdepth 1 -name "*.plist" -print0 2> /dev/null)
    fi

    # Scan PrivilegedHelperTools
    if [[ -d /Library/PrivilegedHelperTools ]]; then
        while IFS= read -r -d '' helper; do
            local filename
            filename=$(basename "$helper")

            # Skip non-plist data files (configs, JSON, etc.) that are not
            # bundle-ID-named helpers. Only .plist and extensionless files
            # can be orphaned service registrations. See #808.
            case "$filename" in
                *.json | *.cfg | *.conf | *.me2me_enabled | *.log | *.dat | *.db | *.xml | *.yml | *.yaml | *.ini | *.txt | *.pid | *.sock | *.lock)
                    continue
                    ;;
            esac

            local bundle_id="${filename%.plist}"

            # Skip Apple system files
            [[ "$bundle_id" == com.apple.* ]] && continue

            # Check force-protect list first: if the helper's app is still installed,
            # never flag it as orphaned regardless of what bundle_has_installed_app says.
            local is_protected=false
            local pattern_entry
            for pattern_entry in "${known_protect_patterns[@]}"; do
                local file_pattern="${pattern_entry%%:*}"
                local app_path="${pattern_entry#*:}"
                # shellcheck disable=SC2053
                [[ "$filename" == $file_pattern || "$bundle_id" == $file_pattern ]] || continue
                if _system_service_app_exists "$bundle_id" "$app_path"; then
                    is_protected=true
                    break
                fi
                # Pattern matched but app is absent → not protected; stop searching.
                break
            done
            [[ "$is_protected" == "true" ]] && continue

            # Generic detection: bundle-ID-style helpers registered via SMJobBless
            # ship inside the parent app bundle (Contents/Library/LaunchServices/<id>),
            # which Spotlight doesn't index directly. Use the shared resolver so we do
            # not falsely flag Adobe / 1Password / Docker helpers when their parent app
            # is installed. See #733.
            if [[ "$bundle_id" =~ ^(com|org|net|io)\. ]]; then
                if ! bundle_has_installed_app "$bundle_id"; then
                    orphaned_files+=("$helper")
                    orphaned_count=$((orphaned_count + 1))
                fi
            fi
        done < <(sudo -n find /Library/PrivilegedHelperTools -maxdepth 1 -type f -print0 2> /dev/null)
    fi

    stop_section_spinner

    # Drop whitelisted entries before reporting/cleaning.
    if [[ $orphaned_count -gt 0 && ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local -a kept_files=()
        for orphan_file in "${orphaned_files[@]}"; do
            if is_path_whitelisted "$orphan_file"; then
                debug_log "Skipping whitelisted orphan service: $orphan_file"
                continue
            fi
            kept_files+=("$orphan_file")
        done
        orphaned_count=${#kept_files[@]}
        # Guard the empty-array expansion: macOS /bin/bash is 3.2, which treats
        # "${empty[@]}" as an unbound variable under `set -u`. When every orphan
        # is whitelisted kept_files is empty, so a bare expansion would abort the
        # whole clean run. See #1127.
        if ((orphaned_count > 0)); then
            orphaned_files=("${kept_files[@]}")
        else
            orphaned_files=()
        fi
    fi

    # Report and clean
    if [[ $orphaned_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Found $orphaned_count orphaned system services"

        local removed_count=0
        local skipped_protected_count=0
        local failed_count=0
        local removed_kb=0

        for orphan_file in "${orphaned_files[@]}"; do
            # Orphans were already verified to have no installed parent app, so
            # bypass the data-protection filename check (which would otherwise block
            # legitimately orphaned files like Docker helpers) for this single call.
            # MOLE_UNINSTALL_MODE is scoped to the call and never leaks to later
            # cleanup sections; SYSTEM_CRITICAL_BUNDLES stay protected. See #1082.
            if MOLE_UNINSTALL_MODE=1 should_protect_path "$orphan_file"; then
                debug_log "Skipping protected orphaned service: $orphan_file"
                skipped_protected_count=$((skipped_protected_count + 1))
                continue
            fi
            if [[ "$DRY_RUN" == "true" ]]; then
                debug_log "[DRY RUN] Would remove orphaned service: $orphan_file"
            else
                local file_size_kb
                file_size_kb=$(sudo -n du -skP "$orphan_file" 2> /dev/null | awk '{print $1}' || echo "0")

                # Unload if it's a LaunchDaemon/LaunchAgent
                if [[ "$orphan_file" == *.plist ]]; then
                    sudo -n launchctl unload "$orphan_file" 2> /dev/null || true
                fi
                if safe_sudo_remove "$orphan_file"; then
                    debug_log "Removed orphaned service: $orphan_file"
                    removed_count=$((removed_count + 1))
                    removed_kb=$((removed_kb + file_size_kb))
                else
                    debug_log "Failed to remove orphaned service: $orphan_file"
                    failed_count=$((failed_count + 1))
                fi
            fi
        done

        local orphaned_kb_display
        if [[ $removed_kb -gt 1024 ]]; then
            orphaned_kb_display=$(echo "$removed_kb" | awk '{printf "%.1fMB", $1/1024}')
        else
            orphaned_kb_display="${removed_kb}KB"
        fi
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            if [[ $removed_count -gt 0 ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $removed_count orphaned services, about $orphaned_kb_display"
                note_activity
            fi
        fi
        # Surface protected/failed counts in BOTH dry-run and real-clean so the
        # two modes agree on what gets touched. Before #886, dry-run silently
        # reported protected files under "Would remove" and real-clean then
        # skipped them, leaving the user confused about which files actually
        # disappeared.
        if [[ $skipped_protected_count -gt 0 || $failed_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Orphaned services skipped $skipped_protected_count protected, failed $failed_count"
        fi
    fi

}

# Policy: mo clean does NOT touch user LaunchAgents (~/Library/LaunchAgents),
# they are user-owned automation and not generic cleanup targets.

# ============================================================================
# Orphaned container stubs
# ============================================================================

# Remove stub-only ~/Library/Containers directories left by uninstalled apps.
# A stub container contains only .com.apple.containermanagerd.metadata.plist
# with no Data/ subdirectory — it holds no user data and is safe to remove.
# Only targets a hardcoded allowlist of apps known to leave such stubs.
_remove_verified_container_stub() {
    local container_dir="$1"
    local metadata_plist="$2"

    [[ -d "$container_dir" ]] || return 1
    [[ ! -L "$container_dir" ]] || return 1
    [[ "$metadata_plist" == "$container_dir/.com.apple.containermanagerd.metadata.plist" ]] || return 1
    [[ -f "$metadata_plist" ]] || return 1

    if find "$container_dir" -mindepth 1 -maxdepth 1 ! -name ".com.apple.containermanagerd.metadata.plist" -print -quit 2> /dev/null | grep -q .; then
        return 1
    fi

    command rm -f -- "$metadata_plist" || return 1
    command rmdir -- "$container_dir"
}

clean_orphaned_container_stubs() {
    local containers_dir="$HOME/Library/Containers"
    [[ -d "$containers_dir" ]] || return 0

    # Format: "bundle_id_glob:app_path_to_check"
    # The app_path_to_check is the canonical .app location; the stub is removed
    # only when no common install location nor mdfind can locate the app.
    local -a stub_patterns=(
        # MacPaw CleanMyMac X (direct and MAS variants, bare bundle ID)
        "com.macpaw.CleanMyMac*:/Applications/CleanMyMac X.app"
        # MacPaw CleanMyMac X TeamID-prefixed helpers (e.g. S8EX82NJP6.com.macpaw.*)
        "*.com.macpaw.CleanMyMac*:/Applications/CleanMyMac X.app"
    )

    local removed_count=0
    local failed_count=0
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob

    _container_stub_app_exists() {
        local bundle_id="$1"
        local app_path="$2"

        [[ -d "$app_path" || -e "$app_path" ]] && return 0

        local app_name
        app_name=$(basename "$app_path")
        case "$app_path" in
            /Applications/*)
                [[ -d "$HOME/Applications/$app_name" ]] && return 0
                [[ -d "/Applications/Setapp/$app_name" ]] && return 0
                [[ -d "$HOME/Library/Application Support/Setapp/Applications/$app_name" ]] && return 0
                ;;
        esac

        if mole_is_reverse_dns_bundle_id "$bundle_id"; then
            local _cache_rc=0
            _mdfind_cache_check "$bundle_id" || _cache_rc=$?
            if [[ $_cache_rc -eq 0 ]]; then
                return 0
            elif [[ $_cache_rc -eq 2 ]]; then
                local app_found
                app_found=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1 || echo "")
                if [[ -n "$app_found" ]]; then
                    _mdfind_cache_store "$bundle_id" "true"
                    return 0
                fi
                _mdfind_cache_store "$bundle_id" "false"
            fi
        fi

        return 1
    }

    local pattern_entry
    for pattern_entry in "${stub_patterns[@]}"; do
        local bundle_glob="${pattern_entry%%:*}"
        local app_path="${pattern_entry#*:}"

        local container_dir
        for container_dir in "$containers_dir"/$bundle_glob; do
            [[ -d "$container_dir" ]] || continue
            [[ -L "$container_dir" ]] && continue

            local metadata_plist="$container_dir/.com.apple.containermanagerd.metadata.plist"
            [[ -f "$metadata_plist" ]] || continue
            if find "$container_dir" -mindepth 1 -maxdepth 1 ! -name ".com.apple.containermanagerd.metadata.plist" -print -quit 2> /dev/null | grep -q .; then
                continue
            fi

            local bundle_id="${container_dir##*/}"

            _container_stub_app_exists "$bundle_id" "$app_path" && continue

            if is_path_whitelisted "$container_dir" 2> /dev/null; then
                debug_log "Skipping whitelisted stub container: $container_dir"
                continue
            fi

            if [[ "$DRY_RUN" != "true" ]]; then
                # These directories have already passed the narrow stub-only
                # checks above. Remove only the exact metadata file, then rmdir,
                # so any new content that appears before deletion is preserved.
                if _remove_verified_container_stub "$container_dir" "$metadata_plist" > /dev/null 2>&1; then
                    removed_count=$((removed_count + 1))
                    log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$container_dir" "stub-container"
                else
                    debug_log "Failed to remove stub container: $container_dir"
                    failed_count=$((failed_count + 1))
                    log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$container_dir" "stub-container"
                fi
            else
                removed_count=$((removed_count + 1))
                log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$container_dir" "dry-run stub-container"
            fi
        done
    done

    # eval: restore shopt state captured by $(shopt -p)
    eval "$_ng_state"

    if [[ $removed_count -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Orphaned app container stubs, ${YELLOW}${removed_count} stubs dry${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Orphaned app container stubs, ${GREEN}${removed_count} removed${NC}"
            note_activity
        fi
        files_cleaned=$((files_cleaned + removed_count))
        total_items=$((total_items + 1))
    fi
    if [[ $failed_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Orphaned container stubs: $failed_count could not be removed"
    fi
}
