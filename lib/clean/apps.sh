#!/bin/bash
# Application Data Cleanup Module
set -euo pipefail

readonly ORPHAN_AGE_THRESHOLD=${ORPHAN_AGE_THRESHOLD:-${MOLE_ORPHAN_AGE_DAYS:-30}}
readonly CLAUDE_VM_ORPHAN_AGE_THRESHOLD=${MOLE_CLAUDE_VM_ORPHAN_AGE_DAYS:-7}
readonly INSTALLED_APPS_CACHE_COMPLETE_MARKER="# mole-installed-apps-cache:v3:complete"
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
    local -a find_cmd=("find" "$target")
    if [[ "$target" == "$HOME" ]]; then
        find_cmd+=("-maxdepth" "5")
    fi
    find_cmd+=("${exclude_paths[@]}" "-type" "f" "-name" ".DS_Store" "-print0")
    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    run_with_timeout "$MOLE_TIMEOUT_HINT_SCAN_SEC" "${find_cmd[@]}" \
        > "$scan_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        [[ "$spinner_active" == "true" ]] && stop_section_spinner
        [[ $scan_rc -eq 124 || $scan_rc -ge 128 ]] && return "$scan_rc"
        return 1
    fi

    local delete_rc=0
    while IFS= read -r -d '' ds_file; do
        local size
        size=$(get_file_size "$ds_file")
        if [[ "$DRY_RUN" == "true" ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
            local preview_size_kb=$(((size + 1023) / 1024))
            local preview_rc=0
            record_dry_run_cleanup_target "$ds_file" "$preview_size_kb" 1 true || preview_rc=$?
            if [[ $preview_rc -eq 124 || $preview_rc -ge 128 ]]; then
                delete_rc=$preview_rc
                break
            elif [[ $preview_rc -ne 0 ]]; then
                continue
            fi
        fi
        if [[ "$DRY_RUN" != "true" ]]; then
            local remove_rc=0
            safe_remove "$ds_file" true 2> /dev/null || remove_rc=$?
            if [[ $remove_rc -eq 124 || $remove_rc -ge 128 ]]; then
                delete_rc=$remove_rc
                break
            elif [[ $remove_rc -ne 0 ]]; then
                continue
            fi
        fi
        total_bytes=$((total_bytes + size))
        file_count=$((file_count + 1))
        if [[ $file_count -ge $MOLE_MAX_DS_STORE_FILES ]]; then
            break
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $file_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$total_bytes")
        local size_kb=$(((total_bytes + 1023) / 1024))
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label${NC} · ${YELLOW}$file_count files, $size_human dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$size_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} $label${NC} · ${line_color}$file_count files, $size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + file_count))
        total_size_cleaned=$((total_size_cleaned + size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
    if [[ $delete_rc -ne 0 ]]; then
        return "$delete_rc"
    fi
    return 0
}
publish_installed_apps_cache() {
    local installed_bundles="$1"
    local cache_file="$2"
    local cache_dir
    cache_dir=$(dirname "$cache_file")

    ensure_user_dir "$cache_dir"
    [[ -d "$cache_dir" ]] || return 1

    # The staging file must share the cache filesystem so rename is atomic.
    local cache_stage=""
    if ! cache_stage=$(mktemp "${cache_file}.tmp.XXXXXX" 2> /dev/null); then
        return 1
    fi
    if ! command cat "$installed_bundles" > "$cache_stage" 2> /dev/null; then
        command rm -f "$cache_stage" 2> /dev/null || true # SAFE: This function created the same-directory cache staging file.
        return 1
    fi
    if ! printf '%s\n' "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" >> "$cache_stage"; then
        command rm -f "$cache_stage" 2> /dev/null || true # SAFE: This function created the same-directory cache staging file.
        return 1
    fi
    if ! mv -f "$cache_stage" "$cache_file" 2> /dev/null; then
        command rm -f "$cache_stage" 2> /dev/null || true # SAFE: This function created the same-directory cache staging file.
        return 1
    fi
    ensure_user_file "$cache_file"
    return 0
}

# Orphaned app data (30+ days inactive). Env: ORPHAN_AGE_THRESHOLD, DRY_RUN
# Usage: scan_installed_apps "output_file"
scan_installed_apps() {
    local installed_bundles="$1"
    # Reset the failure detail so a retry cannot report a stale bundle.
    MOLE_APP_SCAN_FAILURE_DETAIL=""
    # Cache installed app scans briefly. Only a current-schema file with the
    # completeness footer can authorize orphan decisions.
    local cache_file="$HOME/.cache/mole/installed_apps_cache"
    local cache_age_seconds=300 # 5 minutes
    if [[ -f "$cache_file" ]]; then
        local cache_mtime=""
        local current_time=""
        local age=""
        cache_mtime=$(get_file_mtime "$cache_file" 2> /dev/null || true)
        current_time=$(get_epoch_seconds)
        if [[ "$cache_mtime" =~ ^[0-9]+$ && "$current_time" =~ ^[0-9]+$ ]]; then
            age=$((current_time - cache_mtime))
        fi
        if [[ "$age" =~ ^[0-9]+$ && $age -ge 0 && $age -lt $cache_age_seconds ]]; then
            debug_log "Using cached app list, age: ${age}s"
            if [[ -r "$cache_file" ]] && [[ -s "$cache_file" ]]; then
                local cache_footer=""
                local cached_bundles=""
                cache_footer=$(tail -n 1 "$cache_file" 2> /dev/null || true)
                if [[ "$cache_footer" != "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" ]]; then
                    debug_log "Warning: Installed app cache is incomplete or from an older schema, rebuilding"
                elif cached_bundles=$(sed '$d' "$cache_file" 2> /dev/null); then
                    if [[ -n "$cached_bundles" ]]; then
                        if ! printf '%s\n' "$cached_bundles" > "$installed_bundles"; then
                            debug_log "Failed to copy installed application cache into scan output"
                            return 1
                        fi
                    else
                        if ! : > "$installed_bundles"; then
                            debug_log "Failed to initialize installed application scan output from cache"
                            return 1
                        fi
                    fi
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
    if ! : > "$installed_bundles"; then
        debug_log "Failed to initialize installed application scan output"
        return 1
    fi
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
    # Temp dir avoids write contention across parallel scans. The temp registry
    # owns cleanup because safe_remove intentionally rejects root's private tree.
    local scan_tmp_dir
    if ! scan_tmp_dir=$(create_temp_dir); then
        debug_log "Failed to create installed application scan temp directory"
        return 1
    fi
    local app_scan_pids=()
    local auxiliary_pids=()
    local dir_idx=0
    for app_dir in "${app_dirs[@]}"; do
        [[ -d "$app_dir" ]] || continue
        (
            local app_paths
            if ! app_paths=$(command find "$app_dir" -maxdepth 3 -type d -name '*.app' 2> /dev/null); then
                printf '%s\n' "$app_dir" >> "$scan_tmp_dir/scan_failures.list"
                exit 1
            fi
            while IFS= read -r app_path; do
                [[ -n "$app_path" ]] || continue
                # The wrapped payload inside an iOS app is the same install as
                # the bundle containing it, and the outer one already reports
                # that id. Enumerating it separately only produced a bundle
                # whose plist is not under Contents/, which then failed the
                # scan. Helper bundles nested elsewhere are left alone.
                case "$app_path" in
                    */Wrapper/*.app) continue ;;
                esac
                local plist_path="$app_path/Contents/Info.plist"
                # iOS and iPadOS apps installed on Apple Silicon have no
                # Contents/ at all; their plist sits under Wrapper/<name>.app.
                # Reading only the Contents/ path made every one of them look
                # unreadable, and because an incomplete app list cannot
                # authorize orphan decisions, one of them skipped the whole
                # App leftovers section.
                if [[ ! -f "$plist_path" ]]; then
                    local wrapped_plist=""
                    for wrapped_plist in "$app_path"/Wrapper/*.app/Info.plist; do
                        if [[ -f "$wrapped_plist" ]]; then
                            plist_path="$wrapped_plist"
                            break
                        fi
                    done
                fi
                local bundle_id=""
                if [[ ! -f "$plist_path" || ! -r "$plist_path" ]] ||
                    ! bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist_path" 2> /dev/null) ||
                    [[ -z "$bundle_id" || "$bundle_id" == "missing value" ]]; then
                    # A plist that parses and simply carries no
                    # CFBundleIdentifier is an answer, not a failed read.
                    # Vendor uninstallers and Steam launchers ship those, and a
                    # bundle with no id owns no bundle-id-named leftovers, so
                    # leaving it out of the list cannot invent an orphan.
                    # No plist at all (absent Contents/ and no Wrapper/ found,
                    # e.g. an iOS app whose WrappedBundle symlink is dangling)
                    # is the same: the bundle cannot own any bundle-id-named
                    # leftovers and cannot be mistaken for one.
                    # Anything that will not parse still fails the scan closed,
                    # because there the id may exist and simply be unreadable,
                    # which is what would turn a live app's data into an orphan.
                    if [[ ! -f "$plist_path" ]] || /usr/bin/plutil -lint "$plist_path" > /dev/null 2>&1; then
                        continue
                    fi
                    printf '%s\n' "$app_path" >> "$scan_tmp_dir/scan_failures.list"
                    exit 1
                fi
                echo "$bundle_id"
            done <<< "$app_paths"
        ) > "$scan_tmp_dir/apps_${dir_idx}.txt" &
        app_scan_pids+=($!)
        dir_idx=$((dir_idx + 1))
    done
    # Collect running apps and LaunchAgents to avoid false orphan cleanup.
    (
        : > "$scan_tmp_dir/running.txt"
        local running_probe_succeeded=0
        # Skip AppleScript during tests to avoid permission dialogs
        if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
            local running_apps=""
            if command -v osascript > /dev/null 2>&1 &&
                running_apps=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" osascript -e 'tell application "System Events" to get bundle identifier of every application process' 2> /dev/null); then
                printf '%s\n' "$running_apps" | tr ',' '\n' |
                    sed -e 's/^ *//;s/ *$//' -e '/^$/d' -e '/^missing value$/d' > "$scan_tmp_dir/running.txt"
                running_probe_succeeded=1
            fi
        else
            running_probe_succeeded=1
        fi
        # Fallback: lsappinfo is more reliable than osascript
        if command -v lsappinfo > /dev/null 2>&1; then
            local lsappinfo_output=""
            if lsappinfo_output=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" lsappinfo list 2> /dev/null); then
                printf '%s\n' "$lsappinfo_output" |
                    sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p' >> "$scan_tmp_dir/running.txt"
                running_probe_succeeded=1
            fi
        fi
        [[ $running_probe_succeeded -eq 1 ]] || exit 1
    ) < /dev/null &
    auxiliary_pids+=($!)
    (
        : > "$scan_tmp_dir/agents.txt"
        local -a agent_dirs=()
        [[ -d "$HOME/Library/LaunchAgents" ]] && agent_dirs+=("$HOME/Library/LaunchAgents")
        [[ -d /Library/LaunchAgents ]] && agent_dirs+=("/Library/LaunchAgents")
        [[ ${#agent_dirs[@]} -gt 0 ]] || exit 0

        local agent_paths_file="$scan_tmp_dir/agent_paths.nul"
        if ! run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find "${agent_dirs[@]}" \
            -name "*.plist" -type f -print0 > "$agent_paths_file" 2> /dev/null; then
            exit 1
        fi
        local agent_path=""
        while IFS= read -r -d '' agent_path; do
            basename "$agent_path" .plist
        done < "$agent_paths_file" > "$scan_tmp_dir/agents.txt"
    ) < /dev/null &
    auxiliary_pids+=($!)
    debug_log "Waiting for $((${#app_scan_pids[@]} + ${#auxiliary_pids[@]})) background processes"
    local app_scan_failed=0
    if [[ ${#app_scan_pids[@]} -gt 0 ]]; then
        for pid in "${app_scan_pids[@]}"; do
            if ! wait "$pid" 2> /dev/null; then
                app_scan_failed=1
            fi
        done
    fi
    if [[ ${#auxiliary_pids[@]} -gt 0 ]]; then
        for pid in "${auxiliary_pids[@]}"; do
            if ! wait "$pid" 2> /dev/null; then
                app_scan_failed=1
            fi
        done
    fi
    debug_log "All background processes completed"
    if [[ $app_scan_failed -ne 0 ]]; then
        # Surface the first unreadable bundle so the skip message is actionable
        # without --debug. Workers append before exiting nonzero.
        MOLE_APP_SCAN_FAILURE_DETAIL=""
        if [[ -s "$scan_tmp_dir/scan_failures.list" ]]; then
            local raw_failure_detail=""
            raw_failure_detail=$(head -1 "$scan_tmp_dir/scan_failures.list")
            MOLE_APP_SCAN_FAILURE_DETAIL=$(mole_terminal_safe_text "${raw_failure_detail##*/}")
        fi
        debug_log "Failed to scan one or more installed application directories"
        return 1
    fi
    if ! cat "$scan_tmp_dir"/*.txt >> "$installed_bundles" 2> /dev/null; then
        debug_log "Failed to aggregate installed application scan results"
        return 1
    fi
    if ! sort -u "$installed_bundles" -o "$installed_bundles"; then
        debug_log "Failed to normalize installed application scan results"
        return 1
    fi
    local cache_publish_status=0
    publish_installed_apps_cache "$installed_bundles" "$cache_file" || cache_publish_status=$?
    if [[ $cache_publish_status -ne 0 ]]; then
        debug_log "Warning: Failed to publish installed application cache; using current scan"
    fi
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
# Newline-delimited strings checked via case glob, no subprocess per lookup.
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
            # Capture mdfind's own exit code, not head's: on timeout (124)
            # the piped form yielded empty output and was cached as "not
            # installed", so a transient Spotlight stall marked a live app as
            # an orphan and deleted its data. On timeout/error, keep the app
            # and do not poison the cache.
            local app_exists _mdfind_rc=0
            app_exists=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null) || _mdfind_rc=$?
            if [[ $_mdfind_rc -eq 124 || $_mdfind_rc -ge 128 ]]; then
                return "$_mdfind_rc"
            elif [[ $_mdfind_rc -ne 0 ]]; then
                return 1
            elif [[ -n "$app_exists" ]]; then
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
        # On mdfind timeout/error keep the app (see is_bundle_orphaned).
        local app_exists _mdfind_rc=0
        app_exists=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemCFBundleIdentifier == '$claude_bundle_id'" 2> /dev/null) || _mdfind_rc=$?
        if [[ $_mdfind_rc -eq 124 || $_mdfind_rc -ge 128 ]]; then
            return "$_mdfind_rc"
        elif [[ $_mdfind_rc -ne 0 ]]; then
            return 1
        elif [[ -n "$app_exists" ]]; then
            _mdfind_cache_store "$claude_bundle_id" "true"
            return 1
        fi
        _mdfind_cache_store "$claude_bundle_id" "false"
    fi

    return 0
}

orphan_cleanup_candidate_identity() {
    local path="$1"
    run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$STAT_BSD" -f%d:%i:%m "$path" < /dev/null 2> /dev/null
}

# Capture one coherent deletion capability for a candidate. The mtime check
# preserves the existing "unchanged since discovery" contract, while the
# parent and target identities are passed through safe_clean_guarded into
# safe_remove's final sink check.
orphan_cleanup_candidate_snapshot() {
    local path="$1"
    _ORPHAN_CANDIDATE_IDENTITY=""
    _ORPHAN_CANDIDATE_PARENT=""
    _ORPHAN_CANDIDATE_PARENT_ID=""
    _ORPHAN_CANDIDATE_TARGET_ID=""

    _mole_snapshot_path_identity "$path" || return 1
    local snapshot_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local snapshot_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local snapshot_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    local identity=""
    local identity_rc=0
    identity=$(orphan_cleanup_candidate_identity "$path") || identity_rc=$?
    [[ $identity_rc -eq 124 || $identity_rc -ge 128 ]] && return "$identity_rc"
    [[ $identity_rc -eq 0 && "${identity%:*}" == "$snapshot_target_id" ]] || return 1

    _ORPHAN_CANDIDATE_IDENTITY="$identity"
    _ORPHAN_CANDIDATE_PARENT="$snapshot_parent"
    _ORPHAN_CANDIDATE_PARENT_ID="$snapshot_parent_id"
    _ORPHAN_CANDIDATE_TARGET_ID="$snapshot_target_id"
}

# Dynamic inputs are set immediately around safe_clean_guarded below. Recheck
# both the exact object and current app presence after every size probe, without
# trusting the negative mdfind cache used during the broad discovery pass.
orphan_cleanup_candidate_still_eligible() {
    local path="$1"

    if [[ "${_ORPHAN_CLEANUP_KIND:-bundle}" == "claude" ]]; then
        local process_rc=0
        pgrep -x "Claude" > /dev/null 2>&1 || process_rc=$?
        [[ $process_rc -eq 124 || $process_rc -ge 128 ]] && return "$process_rc"
        [[ $process_rc -eq 1 ]] || return 1
    fi

    local resolver_rc=0
    bundle_has_installed_app "${_ORPHAN_CLEANUP_BUNDLE_ID:-}" \
        "$((SECONDS + MOLE_TIMEOUT_MEDIUM_PROBE_SEC))" || resolver_rc=$?
    [[ $resolver_rc -eq 124 || $resolver_rc -ge 128 ]] && return "$resolver_rc"
    # Resolver 0 means installed or unknown; only an exact 1 authorizes cleanup.
    [[ $resolver_rc -eq 1 ]] || return 1

    local _ORPHAN_CANDIDATE_IDENTITY=""
    local _ORPHAN_CANDIDATE_PARENT=""
    local _ORPHAN_CANDIDATE_PARENT_ID=""
    local _ORPHAN_CANDIDATE_TARGET_ID=""
    local snapshot_rc=0
    orphan_cleanup_candidate_snapshot "$path" || snapshot_rc=$?
    [[ $snapshot_rc -eq 124 || $snapshot_rc -ge 128 ]] && return "$snapshot_rc"
    [[ $snapshot_rc -eq 0 ]] || return 1
    [[ "$_ORPHAN_CANDIDATE_IDENTITY" == "${_ORPHAN_CLEANUP_EXPECTED_IDENTITY:-}" ]] || return 1
    [[ "$_ORPHAN_CANDIDATE_PARENT" == "${_ORPHAN_CLEANUP_EXPECTED_PARENT:-}" ]] || return 1
    [[ "$_ORPHAN_CANDIDATE_PARENT_ID" == "${_ORPHAN_CLEANUP_EXPECTED_PARENT_ID:-}" ]] || return 1
    [[ "$_ORPHAN_CANDIDATE_TARGET_ID" == "${_ORPHAN_CLEANUP_EXPECTED_TARGET_ID:-}" ]] || return 1

    _MOLE_SAFE_CLEAN_BOUND_PATH="$path"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$_ORPHAN_CANDIDATE_PARENT"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$_ORPHAN_CANDIDATE_PARENT_ID"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$_ORPHAN_CANDIDATE_TARGET_ID"
    return 0
}

# Orphaned app data sweep.
clean_orphaned_app_data() {
    if ! ls "$HOME/Library/Caches" > /dev/null 2>&1; then
        stop_section_spinner
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipped: No permission to access Library folders"
        note_activity
        return 0
    fi
    start_section_spinner "Scanning installed apps..."
    local installed_bundles=""
    local scan_status=0
    # Explicit if-not capture keeps the graceful skip below reachable even for
    # a caller running with errexit enabled; a bare call would abort the shell
    # before the skip message prints.
    if ! installed_bundles=$(create_temp_file); then
        scan_status=1
    fi
    if [[ $scan_status -eq 0 && -n "$installed_bundles" ]]; then
        if ! scan_installed_apps "$installed_bundles"; then
            scan_status=1
        fi
    fi
    if [[ $scan_status -ne 0 || -z "$installed_bundles" ]]; then
        stop_section_spinner
        local scan_detail="${MOLE_APP_SCAN_FAILURE_DETAIL:-}"
        if [[ -n "$scan_detail" ]]; then
            printf '  %b Skipped: Unable to scan installed applications (%s)\n' \
                "${GRAY}${ICON_WARNING}${NC}" "$scan_detail"
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipped: Unable to scan installed applications"
        fi
        note_activity
        return 0
    fi
    stop_section_spinner
    local app_count=$(wc -l < "$installed_bundles" 2> /dev/null | tr -d ' ')
    debug_log "Found $app_count active/installed apps"
    local orphaned_count=0
    local total_orphaned_kb=0
    start_section_spinner "Scanning orphaned app resources..."

    # Dynamically discover Claude VM bundles (path may vary across versions).
    local claude_support_dir="$HOME/Library/Application Support/Claude"
    if [[ -d "$claude_support_dir" ]]; then
        local claude_scan_file=""
        claude_scan_file=$(create_temp_file) || {
            rm -f -- "$installed_bundles" 2> /dev/null || true # SAFE: exact tracked temp file created above
            return 1
        }
        local claude_scan_rc=0
        run_with_timeout "$MOLE_TIMEOUT_HINT_SCAN_SEC" find "$claude_support_dir" \
            -maxdepth 3 -name "*.bundle" -type d -print0 \
            > "$claude_scan_file" 2> /dev/null || claude_scan_rc=$?
        if [[ $claude_scan_rc -ne 0 ]]; then
            rm -f -- "$claude_scan_file" 2> /dev/null || true  # SAFE: exact tracked temp file created above
            rm -f -- "$installed_bundles" 2> /dev/null || true # SAFE: exact tracked temp file created above
            return "$claude_scan_rc"
        fi
        local claude_result_rc=0
        while IFS= read -r -d '' claude_vm_bundle; do
            local claude_orphan_rc=0
            is_claude_vm_bundle_orphaned \
                "$claude_vm_bundle" "$installed_bundles" || claude_orphan_rc=$?
            if [[ $claude_orphan_rc -eq 124 || $claude_orphan_rc -ge 128 ]]; then
                claude_result_rc=$claude_orphan_rc
                break
            elif [[ $claude_orphan_rc -eq 0 ]]; then
                if is_path_whitelisted "$claude_vm_bundle"; then
                    debug_log "Skipping whitelisted orphan: $claude_vm_bundle"
                    continue
                fi
                local _ORPHAN_CANDIDATE_IDENTITY=""
                local _ORPHAN_CANDIDATE_PARENT=""
                local _ORPHAN_CANDIDATE_PARENT_ID=""
                local _ORPHAN_CANDIDATE_TARGET_ID=""
                local claude_vm_snapshot_rc=0
                orphan_cleanup_candidate_snapshot \
                    "$claude_vm_bundle" || claude_vm_snapshot_rc=$?
                if [[ $claude_vm_snapshot_rc -eq 124 || $claude_vm_snapshot_rc -ge 128 ]]; then
                    claude_result_rc=$claude_vm_snapshot_rc
                    break
                elif [[ $claude_vm_snapshot_rc -ne 0 || -z "$_ORPHAN_CANDIDATE_IDENTITY" ]]; then
                    continue
                fi
                local claude_vm_identity="$_ORPHAN_CANDIDATE_IDENTITY"
                local claude_vm_parent="$_ORPHAN_CANDIDATE_PARENT"
                local claude_vm_parent_id="$_ORPHAN_CANDIDATE_PARENT_ID"
                local claude_vm_target_id="$_ORPHAN_CANDIDATE_TARGET_ID"
                local claude_vm_size_kb
                local claude_vm_size_rc=0
                claude_vm_size_kb=$(get_path_size_kb "$claude_vm_bundle") || claude_vm_size_rc=$?
                if [[ $claude_vm_size_rc -eq 124 || $claude_vm_size_rc -ge 128 ]]; then
                    claude_result_rc=$claude_vm_size_rc
                    break
                fi
                if [[ -n "$claude_vm_size_kb" && "$claude_vm_size_kb" != "0" ]]; then
                    local _ORPHAN_CLEANUP_EXPECTED_IDENTITY="$claude_vm_identity"
                    local _ORPHAN_CLEANUP_EXPECTED_PARENT="$claude_vm_parent"
                    local _ORPHAN_CLEANUP_EXPECTED_PARENT_ID="$claude_vm_parent_id"
                    local _ORPHAN_CLEANUP_EXPECTED_TARGET_ID="$claude_vm_target_id"
                    local _ORPHAN_CLEANUP_BUNDLE_ID="com.anthropic.claudefordesktop"
                    local _ORPHAN_CLEANUP_KIND="claude"
                    local claude_clean_rc=0
                    safe_clean_guarded orphan_cleanup_candidate_still_eligible \
                        "$claude_vm_bundle" \
                        "Orphaned Claude workspace VM" || claude_clean_rc=$?
                    if [[ $claude_clean_rc -eq 124 || $claude_clean_rc -ge 128 ]]; then
                        claude_result_rc=$claude_clean_rc
                        break
                    elif [[ $claude_clean_rc -eq 0 ]]; then
                        orphaned_count=$((orphaned_count + 1))
                        total_orphaned_kb=$((total_orphaned_kb + claude_vm_size_kb))
                    fi
                fi
            fi
        done < "$claude_scan_file"
        rm -f -- "$claude_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        if [[ $claude_result_rc -ne 0 ]]; then
            rm -f -- "$installed_bundles" 2> /dev/null || true # SAFE: exact tracked temp file created above
            return "$claude_result_rc"
        fi
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
                    local orphan_rc=0
                    is_bundle_orphaned "$bundle_id" "$match" "$installed_bundles" || orphan_rc=$?
                    if [[ $orphan_rc -eq 124 || $orphan_rc -ge 128 ]]; then
                        rm -f -- "$installed_bundles" 2> /dev/null || true # SAFE: exact tracked temp file created above
                        return "$orphan_rc"
                    elif [[ $orphan_rc -eq 0 ]]; then
                        if is_path_whitelisted "$match"; then
                            debug_log "Skipping whitelisted orphan: $match"
                            continue
                        fi
                        local _ORPHAN_CANDIDATE_IDENTITY=""
                        local _ORPHAN_CANDIDATE_PARENT=""
                        local _ORPHAN_CANDIDATE_PARENT_ID=""
                        local _ORPHAN_CANDIDATE_TARGET_ID=""
                        local candidate_snapshot_rc=0
                        orphan_cleanup_candidate_snapshot \
                            "$match" || candidate_snapshot_rc=$?
                        if [[ $candidate_snapshot_rc -eq 124 || $candidate_snapshot_rc -ge 128 ]]; then
                            rm -f -- "$installed_bundles" 2> /dev/null || true # SAFE: exact tracked temp file created above
                            return "$candidate_snapshot_rc"
                        elif [[ $candidate_snapshot_rc -ne 0 || -z "$_ORPHAN_CANDIDATE_IDENTITY" ]]; then
                            continue
                        fi
                        local candidate_identity="$_ORPHAN_CANDIDATE_IDENTITY"
                        local candidate_parent="$_ORPHAN_CANDIDATE_PARENT"
                        local candidate_parent_id="$_ORPHAN_CANDIDATE_PARENT_ID"
                        local candidate_target_id="$_ORPHAN_CANDIDATE_TARGET_ID"
                        local size_kb
                        local size_rc=0
                        size_kb=$(get_path_size_kb "$match") || size_rc=$?
                        if [[ $size_rc -eq 124 || $size_rc -ge 128 ]]; then
                            rm -f -- "$installed_bundles" 2> /dev/null || true # SAFE: exact tracked temp file created above
                            return "$size_rc"
                        fi
                        if [[ -z "$size_kb" || "$size_kb" == "0" ]]; then
                            continue
                        fi
                        local _ORPHAN_CLEANUP_EXPECTED_IDENTITY="$candidate_identity"
                        local _ORPHAN_CLEANUP_EXPECTED_PARENT="$candidate_parent"
                        local _ORPHAN_CLEANUP_EXPECTED_PARENT_ID="$candidate_parent_id"
                        local _ORPHAN_CLEANUP_EXPECTED_TARGET_ID="$candidate_target_id"
                        local _ORPHAN_CLEANUP_BUNDLE_ID="$bundle_id"
                        local _ORPHAN_CLEANUP_KIND="bundle"
                        local clean_rc=0
                        safe_clean_guarded orphan_cleanup_candidate_still_eligible \
                            "$match" "Orphaned $label: $bundle_id" || clean_rc=$?
                        if [[ $clean_rc -eq 124 || $clean_rc -ge 128 ]]; then
                            rm -f -- "$installed_bundles" 2> /dev/null || true # SAFE: exact tracked temp file created above
                            return "$clean_rc"
                        elif [[ $clean_rc -eq 0 ]]; then
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
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Would clean $orphaned_count items, about ${orphaned_mb}MB"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $orphaned_count items, about ${orphaned_mb}MB"
        fi
        note_activity
    fi
    rm -f "$installed_bundles"
}

_privileged_helper_bundle_id_from_binary() {
    local binary="$1"
    local deadline_seconds="${2:-}"
    local helper_bundle_id=""

    case "$binary" in
        /Library/PrivilegedHelperTools/*.bundle/Contents/MacOS/*)
            local helper_bundle_dir info_plist
            helper_bundle_dir="${binary%/Contents/MacOS/*}"
            info_plist="$helper_bundle_dir/Contents/Info.plist"
            local plist_timeout="$MOLE_TIMEOUT_QUICK_DETECT_SEC"
            local plist_rc=0
            if [[ -n "$deadline_seconds" ]]; then
                plist_timeout=$(_mole_timeout_with_deadline "$plist_timeout" \
                    "$deadline_seconds") || plist_rc=$?
            fi
            if [[ $plist_rc -eq 0 ]]; then
                if declare -F plutil > /dev/null 2>&1; then
                    helper_bundle_id=$(plutil -extract CFBundleIdentifier raw \
                        "$info_plist" 2> /dev/null) || plist_rc=$?
                else
                    helper_bundle_id=$(run_with_timeout "$plist_timeout" plutil \
                        -extract CFBundleIdentifier raw "$info_plist" 2> /dev/null) || plist_rc=$?
                fi
            fi
            [[ $plist_rc -eq 124 || $plist_rc -ge 128 ]] && return "$plist_rc"
            [[ -n "$helper_bundle_id" ]] || helper_bundle_id=$(basename "$helper_bundle_dir" .bundle)
            ;;
        *)
            helper_bundle_id=$(basename "$binary")
            helper_bundle_id="${helper_bundle_id%.plist}"
            ;;
    esac

    printf '%s\n' "$helper_bundle_id"
}

# Clean orphaned system-level services (LaunchDaemons, LaunchAgents, PrivilegedHelperTools)
# These are left behind when apps are uninstalled but their system services remain
clean_orphaned_system_services() {
    # Requires sudo
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 0
    fi
    local service_cleanup_deadline=$((SECONDS + 60))
    local service_auth_rc=0
    local service_auth_timeout=""
    service_auth_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$service_cleanup_deadline") || service_auth_rc=$?
    if [[ $service_auth_rc -eq 0 ]]; then
        _mole_bounded_sudo "$service_auth_timeout" \
            -n true < /dev/null 2> /dev/null || service_auth_rc=$?
    fi
    if [[ $service_auth_rc -eq 124 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}authorization check timed out, skipped cleanup${NC}"
        note_activity
        return 0
    elif [[ $service_auth_rc -ge 128 ]]; then
        return "$service_auth_rc"
    fi
    [[ $service_auth_rc -eq 0 ]] || return 0

    start_section_spinner "Scanning orphaned system services..."

    local orphaned_count=0
    local -a orphaned_files=()
    local -a orphaned_identities=()
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
        # Intego (One, VirusBarrier, NetBarrier) – self-protecting AV whose
        # /Library/Intego tree is root-only readable; never treat its services
        # as orphans while any Intego install evidence exists. See #1188.
        "com.intego.*:/Library/Intego|/Applications/Intego|/Library/Application Support/Intego"
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
                # On mdfind timeout/error assume the app exists (return 0 =
                # installed here) so a transient Spotlight stall never flags a
                # live app's service/container as an orphan; do not cache.
                local app_found _mdfind_rc=0
                local mdfind_timeout=""
                mdfind_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
                    "$service_cleanup_deadline") || _mdfind_rc=$?
                if [[ $_mdfind_rc -eq 0 ]]; then
                    app_found=$(run_with_timeout "$mdfind_timeout" \
                        mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null) || _mdfind_rc=$?
                fi
                if [[ $_mdfind_rc -ge 128 ]]; then
                    return "$_mdfind_rc"
                elif [[ $_mdfind_rc -ne 0 ]]; then
                    return 0
                elif [[ -n "$app_found" ]]; then
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
        local plist_probe_rc=0
        local plist_probe_timeout=""
        plist_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            "$service_cleanup_deadline") || plist_probe_rc=$?
        if [[ $plist_probe_rc -eq 0 ]]; then
            value=$(_mole_bounded_sudo "$plist_probe_timeout" \
                -n /usr/libexec/PlistBuddy -c "Print :$key" "$plist" < /dev/null 2> /dev/null) || plist_probe_rc=$?
        fi

        if [[ $plist_probe_rc -eq 124 || $plist_probe_rc -ge 128 ]]; then
            return "$plist_probe_rc"
        fi
        [[ $plist_probe_rc -eq 0 ]] || return 1

        [[ -z "$value" ]] && return 1
        [[ "$value" != /* ]] && return 1

        printf '%s\n' "$value"
    }

    # Read the program binary from a plist (Program or ProgramArguments[0]).
    # Prints the path; returns 1 if no usable absolute Program key found.
    _plist_binary_path() {
        local plist="$1"
        local binary=""
        local binary_probe_rc=0
        binary=$(_plist_program_value "$plist" "ProgramArguments:0") || binary_probe_rc=$?
        if [[ $binary_probe_rc -eq 124 || $binary_probe_rc -ge 128 ]]; then
            return "$binary_probe_rc"
        fi
        if [[ -z "$binary" ]]; then
            binary_probe_rc=0
            binary=$(_plist_program_value "$plist" "Program") || binary_probe_rc=$?
            if [[ $binary_probe_rc -eq 124 || $binary_probe_rc -ge 128 ]]; then
                return "$binary_probe_rc"
            fi
        fi
        [[ -z "$binary" ]] && return 1
        printf '%s\n' "$binary"
    }

    # Returns 0 if the binary path is managed by a package manager or lives in a
    # system directory; these should never be treated as orphans even when missing.
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
        local binary=""
        local binary_path_rc=0
        binary=$(_plist_binary_path "$plist") || binary_path_rc=$?
        if [[ $binary_path_rc -eq 124 || $binary_path_rc -ge 128 ]]; then
            return "$binary_path_rc"
        fi
        [[ $binary_path_rc -eq 0 ]] || return 1 # no Program key → skip

        # Self-protecting software (Intego and similar antivirus / endpoint
        # agents) makes its install directories root-only readable, so an
        # unprivileged -e probe reports the daemon binary missing even though
        # it exists. The plist was discovered with sudo; re-probe the binary
        # with sudo before treating it as missing. See #1188.
        local binary_exists=false
        if [[ -e "$binary" ]]; then
            binary_exists=true
        else
            local binary_probe_rc=0
            local binary_probe_timeout=""
            binary_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                "$service_cleanup_deadline") || binary_probe_rc=$?
            if [[ $binary_probe_rc -eq 0 ]]; then
                _mole_bounded_sudo "$binary_probe_timeout" \
                    -n test -e "$binary" < /dev/null 2> /dev/null || binary_probe_rc=$?
            fi
            if [[ $binary_probe_rc -eq 0 ]]; then
                binary_exists=true
            elif [[ $binary_probe_rc -eq 1 ]]; then
                # Status 1 can also mean sudo authorization expired. Only a
                # live follow-up credential proves the path predicate was false.
                local binary_auth_rc=0
                local binary_auth_timeout=""
                binary_auth_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                    "$service_cleanup_deadline") || binary_auth_rc=$?
                if [[ $binary_auth_rc -eq 0 ]]; then
                    _mole_bounded_sudo "$binary_auth_timeout" \
                        -n true < /dev/null 2> /dev/null || binary_auth_rc=$?
                fi
                if [[ $binary_auth_rc -eq 124 || $binary_auth_rc -ge 128 ]]; then
                    return "$binary_auth_rc"
                elif [[ $binary_auth_rc -ne 0 ]]; then
                    return 1
                fi
            else
                # Timeout/exec failure is unknown, never evidence of absence.
                if [[ $binary_probe_rc -eq 124 || $binary_probe_rc -ge 128 ]]; then
                    return "$binary_probe_rc"
                fi
                return 1
            fi
        fi

        # If the binary still exists, check if it's in PrivilegedHelperTools.
        # If so, verify the parent app is still installed. If the parent app
        # is gone, the binary itself is orphaned, so this plist is too. See #1082.
        if [[ "$binary_exists" == "true" ]]; then
            if [[ "$binary" == /Library/PrivilegedHelperTools/* ]]; then
                local helper_bundle_id
                local helper_id_rc=0
                helper_bundle_id=$(_privileged_helper_bundle_id_from_binary \
                    "$binary" "$service_cleanup_deadline") || helper_id_rc=$?
                if [[ $helper_id_rc -eq 124 || $helper_id_rc -ge 128 ]]; then
                    return "$helper_id_rc"
                fi
                local helper_resolver_rc=0
                bundle_has_installed_app "$helper_bundle_id" \
                    "$service_cleanup_deadline" || helper_resolver_rc=$?
                if [[ $helper_resolver_rc -eq 0 ]]; then
                    return 1 # Parent app still installed, plist is healthy
                elif [[ $helper_resolver_rc -ge 128 ]]; then
                    return "$helper_resolver_rc"
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
            local protect_rc=0
            _system_service_app_exists "$bundle_id" "$app_path" || protect_rc=$?
            if [[ $protect_rc -eq 0 ]]; then
                return 1
            elif [[ $protect_rc -ge 128 ]]; then
                return "$protect_rc"
            fi
            # Pattern matched and app is gone → don't protect (fall through).
            break
        done

        return 0 # orphaned
    }

    _orphan_service_identity() {
        local candidate="$1"
        local identity_timeout=""
        local identity=""
        local identity_rc=0
        identity_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$service_cleanup_deadline") || identity_rc=$?
        if [[ $identity_rc -eq 0 ]]; then
            identity=$(_mole_bounded_sudo "$identity_timeout" \
                -n "$STAT_BSD" -f%d:%i:%m "$candidate" < /dev/null 2> /dev/null) || identity_rc=$?
        fi
        if [[ $identity_rc -ne 0 ]]; then
            return "$identity_rc"
        fi
        [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
        printf '%s\n' "$identity"
    }

    _record_orphan_service_candidate() {
        local candidate="$1"
        local identity=""
        identity=$(_orphan_service_identity "$candidate") || return $?
        orphaned_files+=("$candidate")
        orphaned_identities+=("$identity")
        orphaned_count=$((orphaned_count + 1))
    }

    _orphan_service_candidate_still_eligible() {
        local candidate="$1"
        local expected_identity="$2"
        [[ $SECONDS -lt $service_cleanup_deadline ]] || return 124

        local current_identity=""
        current_identity=$(_orphan_service_identity "$candidate") || return $?
        [[ "$current_identity" == "$expected_identity" ]] || return 1

        local filename
        filename=$(basename "$candidate")
        local bundle_id="${filename%.plist}"
        if [[ "$candidate" == *.plist ]]; then
            _plist_is_orphaned "$candidate" "$bundle_id" || return $?
        else
            local pattern_entry
            for pattern_entry in "${known_protect_patterns[@]}"; do
                local file_pattern="${pattern_entry%%:*}"
                local app_path="${pattern_entry#*:}"
                # shellcheck disable=SC2053
                [[ "$filename" == $file_pattern || "$bundle_id" == $file_pattern ]] || continue
                local protect_rc=0
                _system_service_app_exists "$bundle_id" "$app_path" || protect_rc=$?
                if [[ $protect_rc -eq 0 ]]; then
                    return 1
                elif [[ $protect_rc -ge 128 ]]; then
                    return "$protect_rc"
                fi
                break
            done
            local helper_resolver_rc=0
            bundle_has_installed_app "$bundle_id" \
                "$service_cleanup_deadline" || helper_resolver_rc=$?
            if [[ $helper_resolver_rc -eq 0 ]]; then
                return 1
            elif [[ $helper_resolver_rc -ge 128 ]]; then
                return "$helper_resolver_rc"
            fi
            [[ $SECONDS -lt $service_cleanup_deadline ]] || return 124
        fi

        # Classification may touch Spotlight and application bundles. Reject a
        # concurrent installer replacement before unload/removal.
        current_identity=$(_orphan_service_identity "$candidate") || return $?
        [[ "$current_identity" == "$expected_identity" ]]
    }

    # Materialize each privileged inventory before consuming it. If any root
    # cannot be scanned completely, keep every candidate from this pass: a
    # partial inventory is not enough evidence for service deletion.
    local service_scan_file=""
    local service_scan_status=0
    if ! service_scan_file=$(create_temp_file 2> /dev/null); then
        stop_section_spinner
        debug_log "Skipping orphaned system services: could not create scan file"
        return 0
    fi

    # Scan system LaunchDaemons
    if [[ -d /Library/LaunchDaemons ]]; then
        local launch_daemon_scan_rc=0
        local launch_daemon_scan_timeout=""
        launch_daemon_scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            "$service_cleanup_deadline") || launch_daemon_scan_rc=$?
        if [[ $launch_daemon_scan_rc -eq 0 ]]; then
            _mole_materialize_bounded_sudo_find "$service_scan_file" \
                "$launch_daemon_scan_timeout" /Library/LaunchDaemons \
                -maxdepth 1 -name "*.plist" -print0 || launch_daemon_scan_rc=$?
        fi
        if [[ $launch_daemon_scan_rc -eq 0 ]]; then
            while IFS= read -r -d '' plist; do
                if [[ $SECONDS -ge $service_cleanup_deadline ]]; then
                    service_scan_status=124
                    break
                fi
                local filename
                filename=$(basename "$plist")

                # Skip Apple system files
                [[ "$filename" == com.apple.* ]] && continue

                local bundle_id="${filename%.plist}"

                # Generic detection: binary-existence check.
                local daemon_orphan_rc=0
                _plist_is_orphaned "$plist" "$bundle_id" || daemon_orphan_rc=$?
                if [[ $daemon_orphan_rc -eq 0 ]]; then
                    local daemon_record_rc=0
                    _record_orphan_service_candidate "$plist" || daemon_record_rc=$?
                    if [[ $daemon_record_rc -eq 124 || $daemon_record_rc -ge 128 ]]; then
                        service_scan_status=$daemon_record_rc
                        break
                    fi
                elif [[ $daemon_orphan_rc -eq 124 || $daemon_orphan_rc -ge 128 ]]; then
                    service_scan_status=$daemon_orphan_rc
                    break
                fi
            done < "$service_scan_file"
        else
            service_scan_status=$launch_daemon_scan_rc
        fi
    fi

    # Scan system LaunchAgents
    if [[ $service_scan_status -eq 0 && -d /Library/LaunchAgents ]]; then
        local launch_agent_scan_rc=0
        local launch_agent_scan_timeout=""
        launch_agent_scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            "$service_cleanup_deadline") || launch_agent_scan_rc=$?
        if [[ $launch_agent_scan_rc -eq 0 ]]; then
            _mole_materialize_bounded_sudo_find "$service_scan_file" \
                "$launch_agent_scan_timeout" /Library/LaunchAgents \
                -maxdepth 1 -name "*.plist" -print0 || launch_agent_scan_rc=$?
        fi
        if [[ $launch_agent_scan_rc -eq 0 ]]; then
            while IFS= read -r -d '' plist; do
                if [[ $SECONDS -ge $service_cleanup_deadline ]]; then
                    service_scan_status=124
                    break
                fi
                local filename
                filename=$(basename "$plist")

                # Skip Apple system files
                [[ "$filename" == com.apple.* ]] && continue

                local bundle_id="${filename%.plist}"

                # Generic detection: binary-existence check.
                local agent_orphan_rc=0
                _plist_is_orphaned "$plist" "$bundle_id" || agent_orphan_rc=$?
                if [[ $agent_orphan_rc -eq 0 ]]; then
                    local agent_record_rc=0
                    _record_orphan_service_candidate "$plist" || agent_record_rc=$?
                    if [[ $agent_record_rc -eq 124 || $agent_record_rc -ge 128 ]]; then
                        service_scan_status=$agent_record_rc
                        break
                    fi
                elif [[ $agent_orphan_rc -eq 124 || $agent_orphan_rc -ge 128 ]]; then
                    service_scan_status=$agent_orphan_rc
                    break
                fi
            done < "$service_scan_file"
        else
            service_scan_status=$launch_agent_scan_rc
        fi
    fi

    # Scan PrivilegedHelperTools
    if [[ $service_scan_status -eq 0 && -d /Library/PrivilegedHelperTools ]]; then
        local helper_scan_rc=0
        local helper_scan_timeout=""
        helper_scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            "$service_cleanup_deadline") || helper_scan_rc=$?
        if [[ $helper_scan_rc -eq 0 ]]; then
            _mole_materialize_bounded_sudo_find "$service_scan_file" \
                "$helper_scan_timeout" /Library/PrivilegedHelperTools \
                -maxdepth 1 -type f -print0 || helper_scan_rc=$?
        fi
        if [[ $helper_scan_rc -eq 0 ]]; then
            while IFS= read -r -d '' helper; do
                if [[ $SECONDS -ge $service_cleanup_deadline ]]; then
                    service_scan_status=124
                    break
                fi
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
                local protect_interrupt_rc=0
                local pattern_entry
                for pattern_entry in "${known_protect_patterns[@]}"; do
                    local file_pattern="${pattern_entry%%:*}"
                    local app_path="${pattern_entry#*:}"
                    # shellcheck disable=SC2053
                    [[ "$filename" == $file_pattern || "$bundle_id" == $file_pattern ]] || continue
                    local protect_rc=0
                    _system_service_app_exists "$bundle_id" "$app_path" || protect_rc=$?
                    if [[ $protect_rc -eq 0 ]]; then
                        is_protected=true
                        break
                    elif [[ $protect_rc -ge 128 ]]; then
                        protect_interrupt_rc=$protect_rc
                        break
                    fi
                    # Pattern matched but app is absent → not protected; stop searching.
                    break
                done
                if [[ $protect_interrupt_rc -ge 128 ]]; then
                    service_scan_status=$protect_interrupt_rc
                    break
                fi
                [[ "$is_protected" == "true" ]] && continue

                # Generic detection: bundle-ID-style helpers registered via SMJobBless
                # ship inside the parent app bundle (Contents/Library/LaunchServices/<id>),
                # which Spotlight doesn't index directly. Use the shared resolver so we do
                # not falsely flag Adobe / 1Password / Docker helpers when their parent app
                # is installed. See #733.
                if [[ "$bundle_id" =~ ^(com|org|net|io)\. ]]; then
                    local helper_resolver_rc=0
                    bundle_has_installed_app "$bundle_id" \
                        "$service_cleanup_deadline" || helper_resolver_rc=$?
                    if [[ $helper_resolver_rc -ge 128 ]]; then
                        service_scan_status=$helper_resolver_rc
                        break
                    elif [[ $helper_resolver_rc -eq 1 ]]; then
                        local helper_record_rc=0
                        _record_orphan_service_candidate "$helper" || helper_record_rc=$?
                        if [[ $helper_record_rc -eq 124 || $helper_record_rc -ge 128 ]]; then
                            service_scan_status=$helper_record_rc
                            break
                        fi
                    fi
                fi
            done < "$service_scan_file"
        else
            service_scan_status=$helper_scan_rc
        fi
    fi

    if [[ $service_scan_status -eq 0 && $SECONDS -ge $service_cleanup_deadline ]]; then
        service_scan_status=124
    fi
    rm -f -- "$service_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    stop_section_spinner

    if [[ $service_scan_status -ne 0 ]]; then
        debug_log "Skipping orphaned system services: privileged scan incomplete (status $service_scan_status)"
        if [[ $service_scan_status -ge 128 ]]; then
            return "$service_scan_status"
        fi
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}scan incomplete, skipped cleanup${NC}"
        note_activity
        return 0
    fi

    # Drop whitelisted entries before reporting/cleaning.
    if [[ $orphaned_count -gt 0 && ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local -a kept_files=()
        local -a kept_identities=()
        local whitelist_index=0
        for ((whitelist_index = 0; whitelist_index < orphaned_count; whitelist_index++)); do
            local orphan_file="${orphaned_files[$whitelist_index]}"
            if is_path_whitelisted "$orphan_file"; then
                debug_log "Skipping whitelisted orphan service: $orphan_file"
                continue
            fi
            kept_files+=("$orphan_file")
            kept_identities+=("${orphaned_identities[$whitelist_index]}")
        done
        orphaned_count=${#kept_files[@]}
        # Guard the empty-array expansion: macOS /bin/bash is 3.2, which treats
        # "${empty[@]}" as an unbound variable under `set -u`. When every orphan
        # is whitelisted kept_files is empty, so a bare expansion would abort the
        # whole clean run. See #1127.
        if ((orphaned_count > 0)); then
            orphaned_files=("${kept_files[@]}")
            orphaned_identities=("${kept_identities[@]}")
        else
            orphaned_files=()
            orphaned_identities=()
        fi
    fi

    # Report and clean
    if [[ $orphaned_count -gt 0 ]]; then
        debug_log "Found $orphaned_count orphaned system services"

        local removed_count=0
        local skipped_protected_count=0
        local failed_count=0
        local removed_kb=0

        local orphan_index=0
        for ((orphan_index = 0; orphan_index < orphaned_count; orphan_index++)); do
            local orphan_file="${orphaned_files[$orphan_index]}"
            local expected_identity="${orphaned_identities[$orphan_index]}"
            local eligibility_rc=0
            _orphan_service_candidate_still_eligible "$orphan_file" "$expected_identity" || eligibility_rc=$?
            if [[ $eligibility_rc -eq 124 ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}time limit reached, stopped cleanup${NC}"
                note_activity
                return 0
            elif [[ $eligibility_rc -ge 128 ]]; then
                return "$eligibility_rc"
            elif [[ $eligibility_rc -ne 0 ]]; then
                debug_log "Keeping changed or no-longer-orphaned service: $orphan_file"
                continue
            fi
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
                local orphan_size_kb=0
                local orphan_size_rc=0
                local orphan_size_timeout=""
                orphan_size_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    "$service_cleanup_deadline") || orphan_size_rc=$?
                if [[ $orphan_size_rc -eq 0 ]]; then
                    orphan_size_kb=$(_mole_bounded_sudo "$orphan_size_timeout" \
                        -n du -skP "$orphan_file" < /dev/null 2> /dev/null | awk '{print $1}') || orphan_size_rc=$?
                fi
                if [[ $orphan_size_rc -eq 124 ]]; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}time limit reached, stopped cleanup${NC}"
                    note_activity
                    return 0
                fi
                if [[ $orphan_size_rc -ge 128 ]]; then
                    return "$orphan_size_rc"
                fi
                [[ $orphan_size_rc -eq 0 && "$orphan_size_kb" =~ ^[0-9]+$ ]] || orphan_size_kb=0
                if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                    record_dry_run_cleanup_target "$orphan_file" "$orphan_size_kb" 1 true || continue
                elif [[ -n "${EXPORT_LIST_FILE:-}" && -f "$EXPORT_LIST_FILE" ]]; then
                    # Standalone module tests do not prepare the clean ledger.
                    echo "$orphan_file  # $(bytes_to_human "$((orphan_size_kb * 1024))")" >> "$EXPORT_LIST_FILE"
                fi
            else
                local file_size_kb=0
                local file_size_rc=0
                local file_size_timeout=""
                file_size_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    "$service_cleanup_deadline") || file_size_rc=$?
                if [[ $file_size_rc -eq 0 ]]; then
                    file_size_kb=$(_mole_bounded_sudo "$file_size_timeout" \
                        -n du -skP "$orphan_file" < /dev/null 2> /dev/null | awk '{print $1}') || file_size_rc=$?
                fi
                if [[ $file_size_rc -eq 124 ]]; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}time limit reached, stopped cleanup${NC}"
                    note_activity
                    return 0
                fi
                if [[ $file_size_rc -ge 128 ]]; then
                    return "$file_size_rc"
                fi
                [[ $file_size_rc -eq 0 && "$file_size_kb" =~ ^[0-9]+$ ]] || file_size_kb=0

                # Unload if it's a LaunchDaemon/LaunchAgent
                if [[ "$orphan_file" == *.plist ]]; then
                    local pre_unload_rc=0
                    _orphan_service_candidate_still_eligible "$orphan_file" \
                        "$expected_identity" || pre_unload_rc=$?
                    if [[ $pre_unload_rc -eq 124 ]]; then
                        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}time limit reached, stopped cleanup${NC}"
                        note_activity
                        return 0
                    elif [[ $pre_unload_rc -ge 128 ]]; then
                        return "$pre_unload_rc"
                    elif [[ $pre_unload_rc -ne 0 ]]; then
                        debug_log "Keeping changed or no-longer-orphaned service before unload: $orphan_file"
                        continue
                    fi
                    local unload_rc=0
                    local unload_timeout=""
                    unload_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
                        "$service_cleanup_deadline") || unload_rc=$?
                    if [[ $unload_rc -eq 0 ]]; then
                        _mole_bounded_sudo "$unload_timeout" \
                            -n launchctl unload "$orphan_file" < /dev/null 2> /dev/null || unload_rc=$?
                    fi
                    if [[ $unload_rc -eq 124 ]]; then
                        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}unload timed out, stopped cleanup${NC}"
                        note_activity
                        return 0
                    elif [[ $unload_rc -ge 128 ]]; then
                        return "$unload_rc"
                    fi
                fi
                local final_eligibility_rc=0
                _orphan_service_candidate_still_eligible "$orphan_file" \
                    "$expected_identity" || final_eligibility_rc=$?
                if [[ $final_eligibility_rc -eq 124 ]]; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}time limit reached, stopped cleanup${NC}"
                    note_activity
                    return 0
                elif [[ $final_eligibility_rc -ge 128 ]]; then
                    return "$final_eligibility_rc"
                elif [[ $final_eligibility_rc -ne 0 ]]; then
                    debug_log "Keeping changed or no-longer-orphaned service before removal: $orphan_file"
                    continue
                fi
                local remove_rc=0
                safe_sudo_remove "$orphan_file" "" "$service_cleanup_deadline" || remove_rc=$?
                if [[ $remove_rc -eq 0 ]]; then
                    debug_log "Removed orphaned service: $orphan_file"
                    removed_count=$((removed_count + 1))
                    removed_kb=$((removed_kb + file_size_kb))
                elif [[ $remove_rc -eq $MOLE_ERR_PROTECTED_PATH ]]; then
                    debug_log "Skipping protected orphaned service: $orphan_file"
                    skipped_protected_count=$((skipped_protected_count + 1))
                elif [[ $remove_rc -eq 124 ]]; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Orphaned system services · ${GRAY}removal timed out, stopped cleanup${NC}"
                    note_activity
                    return 0
                elif [[ $remove_rc -ge 128 ]]; then
                    return "$remove_rc"
                else
                    debug_log "Failed to remove orphaned service: $orphan_file"
                    failed_count=$((failed_count + 1))
                fi
            fi
        done

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Orphaned services · ${YELLOW}${orphaned_count} found dry${NC}"
            note_activity
        elif [[ $removed_count -gt 0 ]]; then
            local orphaned_kb_display
            orphaned_kb_display=$(bytes_to_human "$((removed_kb * 1024))")
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Orphaned services · cleaned ${removed_count}, ${orphaned_kb_display}"
            note_activity
        fi
        # Surface protected/failed counts in BOTH dry-run and real-clean so the
        # two modes agree on what gets touched. Before #886, dry-run silently
        # reported protected files under "Would remove" and real-clean then
        # skipped them, leaving the user confused about which files actually
        # disappeared.
        if [[ $skipped_protected_count -gt 0 || $failed_count -gt 0 ]]; then
            local issue_note=""
            if [[ $skipped_protected_count -gt 0 ]]; then
                issue_note="skipped ${skipped_protected_count} protected"
            fi
            if [[ $failed_count -gt 0 ]]; then
                issue_note+="${issue_note:+, }${failed_count} failed"
            fi
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Orphaned services · ${issue_note}"
            note_activity
        fi
    fi

}

# Policy: mo clean does NOT touch user LaunchAgents (~/Library/LaunchAgents),
# they are user-owned automation and not generic cleanup targets.

# ============================================================================
# Orphaned container stubs
# ============================================================================

# Whether a stub container's app is still installed anywhere Mole scans.
# Defined at file scope so callers and tests can pin it deterministically.
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
            # On mdfind timeout/error assume the app exists (return 0 =
            # installed here) so a transient Spotlight stall never flags a
            # live app's service/container as an orphan; do not cache.
            local app_found _mdfind_rc=0
            app_found=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2> /dev/null) || _mdfind_rc=$?
            if [[ $_mdfind_rc -eq 124 || $_mdfind_rc -ge 128 ]]; then
                return "$_mdfind_rc"
            elif [[ $_mdfind_rc -ne 0 ]]; then
                return 0
            elif [[ -n "$app_found" ]]; then
                _mdfind_cache_store "$bundle_id" "true"
                return 0
            fi
            _mdfind_cache_store "$bundle_id" "false"
        fi
    fi

    return 1
}

# Remove stub-only ~/Library/Containers directories left by uninstalled apps.
# A stub container contains only .com.apple.containermanagerd.metadata.plist
# with no Data/ subdirectory, it holds no user data and is safe to remove.
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

    # SAFE: deliberate carve-out from safe_remove, do NOT "unify" this back
    # into the shared helper. should_protect_path blankets ~/Library/Containers
    # (container interiors are user data), so safe_remove refuses BOTH paths and
    # routing through it silently disables this cleaner entirely (verified: both
    # validate_path_for_deletion calls return 1). The removal stays narrow by
    # construction instead: the caller matches a hardcoded app allowlist, and the
    # guards above pin the target to a non-symlink directory whose ONLY entry is
    # the exact containermanagerd metadata plist, i.e. a stub with no Data/ dir
    # and no user content. rmdir (not rm -r) means a container that gains any
    # file between the check and the removal survives untouched.
    command rm -f -- "$metadata_plist" || return 1
    command rmdir -- "$container_dir"
}

clean_orphaned_container_stubs() {
    local containers_dir="$HOME/Library/Containers"
    [[ -d "$containers_dir" ]] || return 0

    # Keep the section spinner alive: the mdfind probes below can take
    # seconds, and without a spinner the section looks hung after the
    # previous step's output (per-step loading feedback).
    start_section_spinner "Scanning orphaned containers..."

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
            local sibling_entry=""
            local sibling_scan_rc=0
            sibling_entry=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" find \
                "$container_dir" -mindepth 1 -maxdepth 1 \
                ! -name ".com.apple.containermanagerd.metadata.plist" \
                -print -quit 2> /dev/null) || sibling_scan_rc=$?
            if [[ $sibling_scan_rc -eq 124 || $sibling_scan_rc -ge 128 ]]; then
                eval "$_ng_state"
                stop_section_spinner
                return "$sibling_scan_rc"
            elif [[ $sibling_scan_rc -ne 0 ]]; then
                continue
            elif [[ -n "$sibling_entry" ]]; then
                continue
            fi

            local bundle_id="${container_dir##*/}"

            local stub_app_rc=0
            _container_stub_app_exists "$bundle_id" "$app_path" || stub_app_rc=$?
            if [[ $stub_app_rc -eq 0 ]]; then
                continue
            elif [[ $stub_app_rc -eq 124 || $stub_app_rc -ge 128 ]]; then
                eval "$_ng_state"
                stop_section_spinner
                return "$stub_app_rc"
            fi

            if is_path_whitelisted "$container_dir" 2> /dev/null; then
                debug_log "Skipping whitelisted stub container: $container_dir"
                continue
            fi

            if [[ "$DRY_RUN" != "true" ]]; then
                # These directories have already passed the narrow stub-only
                # checks above. Remove only the exact metadata file, then rmdir,
                # so any new content that appears before deletion is preserved.
                local stub_remove_rc=0
                _remove_verified_container_stub \
                    "$container_dir" "$metadata_plist" > /dev/null 2>&1 || stub_remove_rc=$?
                if [[ $stub_remove_rc -eq 124 || $stub_remove_rc -ge 128 ]]; then
                    eval "$_ng_state"
                    stop_section_spinner
                    return "$stub_remove_rc"
                elif [[ $stub_remove_rc -eq 0 ]]; then
                    removed_count=$((removed_count + 1))
                    log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$container_dir" "stub-container"
                else
                    debug_log "Failed to remove stub container: $container_dir"
                    failed_count=$((failed_count + 1))
                    log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$container_dir" "stub-container"
                fi
            else
                if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                    local stub_size_kb
                    local stub_size_rc=0
                    stub_size_kb=$(get_path_size_kb "$container_dir" 2> /dev/null) || stub_size_rc=$?
                    [[ $stub_size_rc -eq 124 || $stub_size_rc -ge 128 ]] && {
                        eval "$_ng_state"
                        stop_section_spinner
                        return "$stub_size_rc"
                    }
                    [[ "$stub_size_kb" =~ ^[0-9]+$ ]] || stub_size_kb=0
                    local stub_record_rc=0
                    record_dry_run_cleanup_target \
                        "$container_dir" "$stub_size_kb" 1 true || stub_record_rc=$?
                    if [[ $stub_record_rc -eq 124 || $stub_record_rc -ge 128 ]]; then
                        eval "$_ng_state"
                        stop_section_spinner
                        return "$stub_record_rc"
                    elif [[ $stub_record_rc -ne 0 ]]; then
                        continue
                    fi
                fi
                removed_count=$((removed_count + 1))
                log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$container_dir" "dry-run stub-container"
            fi
        done
    done

    # eval: restore shopt state captured by $(shopt -p)
    eval "$_ng_state"

    stop_section_spinner
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
        # Keep the warning visible past the idle-section erase.
        note_activity
    fi
}
