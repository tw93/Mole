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
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label${NC}, ${YELLOW}$file_count files, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
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
            local running_apps=$(run_with_timeout 5 osascript -e 'tell application "System Events" to get bundle identifier of every application process' 2> /dev/null || echo "")
            echo "$running_apps" | tr ',' '\n' | sed -e 's/^ *//;s/ *$//' -e '/^$/d' -e '/^missing value$/d' > "$scan_tmp_dir/running.txt"
        fi
        # Fallback: lsappinfo is more reliable than osascript
        if command -v lsappinfo > /dev/null 2>&1; then
            run_with_timeout 3 lsappinfo list 2> /dev/null | grep -o '"CFBundleIdentifier"="[^"]*"' | cut -d'"' -f4 >> "$scan_tmp_dir/running.txt" 2> /dev/null || true
        fi
    ) &
    pids+=($!)
    (
        run_with_timeout 5 find ~/Library/LaunchAgents /Library/LaunchAgents \
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

# Cache file for mdfind results (Bash 3.2 compatible, no associative arrays)
ORPHAN_MDFIND_CACHE_FILE=""

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

    # 6. Slow path: mdfind fallback with file-based caching (Bash 3.2 compatible)
    # This catches apps installed in non-standard locations
    if [[ -n "$bundle_id" ]] && [[ "$bundle_id" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ ${#bundle_id} -ge 5 ]]; then
        # Initialize cache file if needed
        if [[ -z "$ORPHAN_MDFIND_CACHE_FILE" ]]; then
            ensure_mole_temp_root
            ORPHAN_MDFIND_CACHE_FILE=$(mktemp "$MOLE_RESOLVED_TMPDIR/mole_mdfind_cache.XXXXXX")
            register_temp_file "$ORPHAN_MDFIND_CACHE_FILE"
        fi

        # Check cache first (grep is fast for small files)
        if grep -Fxq "FOUND:$bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
            return 1
        fi
        if grep -Fxq "NOTFOUND:$bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
            # Already checked, not found - continue to return 0
            :
        else
            # Query mdfind with strict timeout (2 seconds max)
            local app_exists
            app_exists=$(run_with_timeout 5 mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1 || echo "")
            if [[ -n "$app_exists" ]]; then
                echo "FOUND:$bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
                return 1
            else
                echo "NOTFOUND:$bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
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

    if [[ -z "$ORPHAN_MDFIND_CACHE_FILE" ]]; then
        ensure_mole_temp_root
        ORPHAN_MDFIND_CACHE_FILE=$(mktemp "$MOLE_RESOLVED_TMPDIR/mole_mdfind_cache.XXXXXX")
        register_temp_file "$ORPHAN_MDFIND_CACHE_FILE"
    fi

    if grep -Fxq "FOUND:$claude_bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
        return 1
    fi
    if ! grep -Fxq "NOTFOUND:$claude_bundle_id" "$ORPHAN_MDFIND_CACHE_FILE" 2> /dev/null; then
        local app_exists
        app_exists=$(run_with_timeout 5 mdfind "kMDItemCFBundleIdentifier == '$claude_bundle_id'" 2> /dev/null | head -1 || echo "")
        if [[ -n "$app_exists" ]]; then
            echo "FOUND:$claude_bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
            return 1
        fi
        echo "NOTFOUND:$claude_bundle_id" >> "$ORPHAN_MDFIND_CACHE_FILE"
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

    local mdfind_cache_file=""
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

        if [[ -n "$bundle_id" ]] && [[ "$bundle_id" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ ${#bundle_id} -ge 5 ]]; then
            if [[ -z "$mdfind_cache_file" ]]; then
                ensure_mole_temp_root
                mdfind_cache_file=$(mktemp "$MOLE_RESOLVED_TMPDIR/mole_mdfind_cache.XXXXXX")
                register_temp_file "$mdfind_cache_file"
            fi

            if grep -Fxq "FOUND:$bundle_id" "$mdfind_cache_file" 2> /dev/null; then
                return 0
            fi
            if ! grep -Fxq "NOTFOUND:$bundle_id" "$mdfind_cache_file" 2> /dev/null; then
                local app_found
                app_found=$(run_with_timeout 5 mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1 || echo "")
                if [[ -n "$app_found" ]]; then
                    echo "FOUND:$bundle_id" >> "$mdfind_cache_file"
                    return 0
                fi
                echo "NOTFOUND:$bundle_id" >> "$mdfind_cache_file"
            fi
        fi

        return 1
    }

    # Read the program binary from a plist (Program or ProgramArguments[0]).
    # Prints the path; returns 1 if no Program key found.
    _plist_binary_path() {
        local plist="$1"
        local binary=""
        binary=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist" 2> /dev/null || true)
        if [[ -z "$binary" ]]; then
            binary=$(/usr/libexec/PlistBuddy -c "Print :Program" "$plist" 2> /dev/null || true)
        fi
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

        # If the binary still exists, the service is healthy.
        [[ -e "$binary" ]] && return 1

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
        done < <(sudo find /Library/LaunchDaemons -maxdepth 1 -name "*.plist" -print0 2> /dev/null)
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
        done < <(sudo find /Library/LaunchAgents -maxdepth 1 -name "*.plist" -print0 2> /dev/null)
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
        done < <(sudo find /Library/PrivilegedHelperTools -maxdepth 1 -type f -print0 2> /dev/null)
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
        orphaned_files=("${kept_files[@]}")
    fi

    # Report and clean
    if [[ $orphaned_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Found $orphaned_count orphaned system services"

        local removed_count=0
        local skipped_protected_count=0
        local failed_count=0
        local removed_kb=0

        for orphan_file in "${orphaned_files[@]}"; do
            if [[ "$DRY_RUN" == "true" ]]; then
                debug_log "[DRY RUN] Would remove orphaned service: $orphan_file"
            else
                if should_protect_path "$orphan_file"; then
                    debug_log "Skipping protected orphaned service: $orphan_file"
                    skipped_protected_count=$((skipped_protected_count + 1))
                    continue
                fi

                local file_size_kb
                file_size_kb=$(sudo du -skP "$orphan_file" 2> /dev/null | awk '{print $1}' || echo "0")

                # Unload if it's a LaunchDaemon/LaunchAgent
                if [[ "$orphan_file" == *.plist ]]; then
                    sudo launchctl unload "$orphan_file" 2> /dev/null || true
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
            if [[ $skipped_protected_count -gt 0 || $failed_count -gt 0 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Orphaned services skipped $skipped_protected_count protected, failed $failed_count"
            fi
        fi
    fi

}

# ============================================================================
# User LaunchAgents
# ============================================================================

# User-level LaunchAgents are user-owned automation/configuration, not generic
# cleanup targets. `mo clean` must not delete them automatically.
clean_orphaned_launch_agents() {
    return 0
}

# ============================================================================
# Orphaned container stubs
# ============================================================================

# Remove stub-only ~/Library/Containers directories left by uninstalled apps.
# A stub container contains only .com.apple.containermanagerd.metadata.plist
# with no Data/ subdirectory — it holds no user data and is safe to remove.
# Only targets a hardcoded allowlist of apps known to leave such stubs.
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

        if [[ "$bundle_id" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ ${#bundle_id} -ge 5 ]]; then
            local app_found
            app_found=$(run_with_timeout 5 mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null | head -1 || echo "")
            [[ -n "$app_found" ]] && return 0
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
                # checks above. Use direct removal so broad app-protection rules
                # for the parent vendor bundle do not keep empty metadata stubs.
                # safe_remove cannot be used here: it runs should_protect_path
                # which intentionally vetos vendor-bundle paths we just verified.
                if command rm -rf -- "$container_dir" > /dev/null 2>&1; then # SAFE: verified stub-only container
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
