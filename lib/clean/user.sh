#!/bin/bash
# User Data Cleanup Module
set -euo pipefail

_user_process_delete_guard_allows() {
    mole_clean_process_guard "$_MOLE_USER_PROCESS_GUARD_PROBE" "$_MOLE_USER_PROCESS_GUARD_FAMILY started"
}

_user_safe_clean_process_guarded() {
    local probe="$1"
    local family="$2"
    local display_name="$3"
    shift 3
    local _MOLE_USER_PROCESS_GUARD_PROBE="$probe"
    local _MOLE_USER_PROCESS_GUARD_FAMILY="$family"
    local _MOLE_CLEAN_GUARD_REASON="${family} started"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _user_process_delete_guard_allows; then
            mole_report_guard_stop "$display_name" mole_defer_cleanup_family "$family"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded _user_process_delete_guard_allows "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        mole_report_guard_stop "$display_name" mole_defer_cleanup_family "$family"
        return 1
    fi
    return "$guarded_rc"
}

clean_trash() {
    if is_path_whitelisted "$HOME/.Trash"; then
        return 0
    fi
    stop_section_spinner

    # Always count and delete directly. The previous Finder AppleScript path
    # triggered macOS's "Show warning before emptying the Trash" dialog and
    # blocked mo clean on user confirmation. Volume Trashes
    # (/Volumes/*/.Trashes/<uid>/) are not handled here; mo clean only manages
    # the user's home Trash.
    local trash_count
    trash_count=$(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null |
        tr -dc '\0' | wc -c | tr -d ' ' || echo "0")
    [[ "$trash_count" =~ ^[0-9]+$ ]] || trash_count="0"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ $trash_count -gt 0 ]]; then
            local preview_count=0
            local trash_item
            while IFS= read -r -d '' trash_item; do
                [[ -e "$trash_item" ]] || continue
                if is_path_whitelisted "$trash_item" 2> /dev/null ||
                    (declare -f holds_compiled_model_cache > /dev/null 2>&1 &&
                        holds_compiled_model_cache "$trash_item" 2> /dev/null) ||
                    ! validate_path_for_deletion "$trash_item" 2> /dev/null; then
                    continue
                fi
                local trash_item_kb
                local size_rc=0
                trash_item_kb=$(get_path_size_kb "$trash_item" 2> /dev/null) || size_rc=$?
                [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
                [[ $size_rc -eq 0 ]] || return "$size_rc"
                [[ "$trash_item_kb" =~ ^[0-9]+$ ]] || trash_item_kb=0
                if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                    record_dry_run_cleanup_target "$trash_item" "$trash_item_kb" 1 true || continue
                fi
                preview_count=$((preview_count + 1))
            done < <(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
            if [[ $preview_count -gt 0 ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Trash · would empty, $preview_count items"
                note_activity
            fi
        fi
        return 0
    fi

    if [[ $trash_count -eq 0 ]]; then
        debug_log "Trash already empty"
        return 0
    fi

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Emptying trash..."
    fi

    local cleaned_count=0
    local skipped_count=0
    while IFS= read -r -d '' item; do
        if safe_remove "$item" true; then
            cleaned_count=$((cleaned_count + 1))
        else
            skipped_count=$((skipped_count + 1))
        fi
    done < <(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)

    [[ -t 1 ]] && stop_inline_spinner

    if [[ $cleaned_count -gt 0 ]]; then
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Trash · removed $cleaned_count items, $skipped_count skipped"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Trash · emptied, $cleaned_count items"
        fi
        note_activity
    elif [[ $skipped_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Trash · $skipped_count items could not be removed"
        note_activity
    fi
}

# Re-resolve the Deno root at the deletion boundary and refuse any candidate
# that has become it, or that now contains it. Excluding the root while the
# candidate list is built only proves where it pointed at that moment: a
# symlinked DENO_DIR retargeted afterwards makes the sink delete whatever the
# root points at now. Failing closed here costs one skipped cache directory;
# guessing costs the user's Deno state.
_user_cache_deno_delete_guard() {
    local candidate="${1:-}"
    [[ -n "$candidate" ]] || return 1

    local deno_root=""
    deno_root=$(mole_deno_cache_root 2> /dev/null) || return 1

    local candidate_physical=""
    if [[ -d "$candidate" ]]; then
        candidate_physical=$(cd -P "$candidate" 2> /dev/null && pwd -P) || return 1
    fi
    local deno_physical=""
    if [[ -d "$deno_root" ]]; then
        deno_physical=$(cd -P "$deno_root" 2> /dev/null && pwd -P) || return 1
    fi

    local candidate_probe deno_probe
    for candidate_probe in "$candidate" "$candidate_physical"; do
        [[ -n "$candidate_probe" ]] || continue
        for deno_probe in "$deno_root" "$deno_physical"; do
            [[ -n "$deno_probe" ]] || continue
            # The candidate is the root, sits inside it, or contains it.
            case "$deno_probe" in
                "$candidate_probe" | "$candidate_probe"/*) return 1 ;;
            esac
            case "$candidate_probe" in
                "$deno_probe"/*) return 1 ;;
            esac
        done
    done
    return 0
}

clean_user_essentials() {
    start_section_spinner "Scanning caches..."
    # Deno's default root sits inside the otherwise broad user-cache sweep,
    # but `deno clean` removes the entire DENO_DIR, including origin storage
    # and downloaded runtime payloads. Keep the effective root for review and
    # clean every sibling through the normal funnel.
    local deno_cache_root=""
    local deno_cache_root_valid=true
    if ! deno_cache_root=$(mole_deno_cache_root 2> /dev/null); then
        # An explicitly broad or malformed DENO_DIR is not safe to report as a
        # cache root, but sweeping past an unresolved owner root is worse.
        # Keep the generic cache batch empty and continue with the other user
        # cleanup categories.
        deno_cache_root_valid=false
    fi
    local deno_physical_root=""
    if [[ "$deno_cache_root_valid" == "true" && -d "$deno_cache_root" ]]; then
        deno_physical_root=$(cd -P "$deno_cache_root" 2> /dev/null && pwd -P) || deno_physical_root=""
    fi
    local -a user_cache_targets=()
    local user_cache_target
    if [[ "$deno_cache_root_valid" == "true" ]]; then
        for user_cache_target in "$HOME/Library/Caches"/*; do
            [[ -e "$user_cache_target" || -L "$user_cache_target" ]] || continue
            case "$deno_cache_root" in
                "$user_cache_target" | "$user_cache_target"/*) continue ;;
            esac
            if [[ -n "$deno_physical_root" && -d "$user_cache_target" ]]; then
                local user_cache_physical_target=""
                user_cache_physical_target=$(cd -P "$user_cache_target" 2> /dev/null && pwd -P) ||
                    user_cache_physical_target=""
                case "$deno_physical_root" in
                    "$user_cache_physical_target" | "$user_cache_physical_target"/*) continue ;;
                esac
            fi
            user_cache_targets+=("$user_cache_target")
        done
    fi
    if [[ ${#user_cache_targets[@]} -gt 0 ]]; then
        local user_cache_rc=0
        # Ask twice on purpose: safe_clean_guarded filters the batch, and the
        # sink guard re-asks after every other check, immediately before rm,
        # because safe_remove does real work between the two.
        local _MOLE_SAFE_REMOVE_FINAL_GUARD=_user_cache_deno_delete_guard
        safe_clean_guarded _user_cache_deno_delete_guard \
            "${user_cache_targets[@]}" "User app cache" || user_cache_rc=$?
        if [[ $user_cache_rc -eq 75 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} User app cache · stopped (Deno root changed during cleanup)"
            note_activity
        fi
    elif [[ "$deno_cache_root_valid" != "true" ]]; then
        # Refusing here is right, but staying silent about it is not: the whole
        # category would just be missing from the section. Name the cause the
        # way every other guard in this file does.
        echo -e "  ${GRAY}${ICON_WARNING}${NC} User app cache · stopped (DENO_DIR unresolved)"
        note_activity
    fi
    stop_section_spinner

    safe_clean ~/Library/Logs/* "User app logs"

    if [[ "${MOLE_SKIP_TRASH_CLEANUP:-0}" != "1" ]]; then
        clean_trash
    fi
    stop_section_spinner

    # Recent items
    _clean_recent_items

    # Mail downloads
    _clean_mail_downloads
}

# Internal: Remove recent items lists.
_clean_recent_items() {
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    local -a recent_lists=(
        "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentServers.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentHosts.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentServers.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentHosts.sfl"
    )
    if [[ -d "$shared_dir" ]]; then
        for sfl_file in "${recent_lists[@]}"; do
            [[ -e "$sfl_file" ]] && safe_clean "$sfl_file" "Recent items list" || true
        done
    fi
    safe_clean ~/Library/Preferences/com.apple.recentitems.plist "Recent items preferences" || true
}

_incomplete_download_delete_guard_allows() {
    local path="$1"
    _mole_snapshot_path_identity "$path" || return 2
    local expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    local open_state=0
    _mole_paths_have_open_handle "$path" || open_state=$?
    if [[ $open_state -eq 124 || $open_state -ge 128 ]]; then
        _mole_record_clean_cancellation "$open_state"
        return "$open_state"
    fi
    [[ $open_state -eq 1 ]] || return 1
    _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id" || return 2

    _MOLE_SAFE_CLEAN_BOUND_PATH="$path"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$expected_parent"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$expected_parent_id"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$expected_target_id"
    return 0
}

# Internal: Clean incomplete browser downloads only after a complete open-file
# view says the exact file is idle. The guarded cleanup repeats the probe after
# sizing, and safe_remove repeats it again at the real deletion boundary.
_clean_incomplete_downloads() {
    local -a patterns=(
        "$HOME/Downloads/*.download"
        "$HOME/Downloads/*.crdownload"
        "$HOME/Downloads/*.part"
    )
    local labels=("Safari incomplete downloads" "Chrome incomplete downloads" "Partial incomplete downloads")
    local i=0
    for pattern in "${patterns[@]}"; do
        local label="${labels[$i]}"
        i=$((i + 1))
        for f in $pattern; do
            [[ -e "$f" ]] || continue
            local open_state=0
            _mole_paths_have_open_handle "$f" || open_state=$?
            if [[ $open_state -eq 124 || $open_state -ge 128 ]]; then
                _mole_record_clean_cancellation "$open_state"
                return 0
            fi
            if [[ $open_state -eq 0 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipping active download: $(basename "$f")"
                note_activity
                continue
            fi
            if [[ $open_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipping incomplete download (open-file check unavailable): $(basename "$f")"
                note_activity
                continue
            fi
            local guarded_rc=0
            safe_clean_guarded _incomplete_download_delete_guard_allows \
                "$f" "$label" || guarded_rc=$?
            if [[ $guarded_rc -eq 124 || $guarded_rc -ge 128 ]]; then
                _mole_record_clean_cancellation "$guarded_rc"
                return 0
            fi
            if [[ $guarded_rc -eq 75 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipping incomplete download after final open-file check: $(basename "$f")"
                note_activity
            fi
        done
    done
}

# Internal: Clean old mail downloads.
_clean_mail_downloads() {
    local mail_age_days=${MOLE_MAIL_AGE_DAYS:-}
    if ! [[ "$mail_age_days" =~ ^[0-9]+$ ]]; then
        mail_age_days=30
    fi

    if pgrep -x "Mail" > /dev/null 2>&1; then
        debug_log "Mail is running, skipping Mail Downloads cleanup"
        return 0
    fi

    local -a mail_dirs=(
        "$HOME/Library/Mail Downloads"
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    )
    local count=0
    local cleaned_kb=0
    local spinner_active=false
    local dry_run_mode=false
    [[ "${DRY_RUN:-false}" == "true" || "${MOLE_DRY_RUN:-0}" == "1" ]] && dry_run_mode=true
    for target_path in "${mail_dirs[@]}"; do
        if [[ -d "$target_path" ]]; then
            if [[ "$spinner_active" == "false" && -t 1 ]]; then
                start_section_spinner "Cleaning old Mail attachments..."
                spinner_active=true
            fi
            local dir_size_kb=0
            local size_rc=0
            dir_size_kb=$(get_path_size_kb "$target_path") || size_rc=$?
            if [[ $size_rc -ne 0 ]]; then
                if [[ $size_rc -lt 128 ]]; then
                    # A Mail Downloads directory that cannot be sized must not
                    # end the whole run, whether the probe stalled past its
                    # timeout (124) or the protected container refused it
                    # outright (du exits 1 immediately under TCC, the #1366
                    # shape): skip this one target and keep cleaning. Only a
                    # signal keeps its cancellation semantics.
                    [[ "$spinner_active" == "true" ]] && stop_section_spinner
                    spinner_active=false
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Mail Downloads · skipped (sizing unavailable)"
                    note_activity
                    continue
                fi
                _mole_record_clean_cancellation "$size_rc"
                [[ "$spinner_active" == "true" ]] && stop_section_spinner
                return "$size_rc"
            fi
            if ! [[ "$dir_size_kb" =~ ^[0-9]+$ ]]; then
                dir_size_kb=0
            fi
            local min_kb="${MOLE_MAIL_DOWNLOADS_MIN_KB:-}"
            if ! [[ "$min_kb" =~ ^[0-9]+$ ]]; then
                min_kb=5120
            fi
            if [[ "$dir_size_kb" -lt "$min_kb" ]]; then
                continue
            fi
            while IFS= read -r -d '' file_path; do
                if [[ -f "$file_path" ]]; then
                    local file_size_kb
                    size_rc=0
                    file_size_kb=$(get_path_size_kb "$file_path") || size_rc=$?
                    if [[ $size_rc -ne 0 ]]; then
                        if [[ $size_rc -lt 128 ]]; then
                            debug_log "Mail attachment sizing failed (rc=$size_rc), skipping: $file_path"
                            continue
                        fi
                        _mole_record_clean_cancellation "$size_rc"
                        [[ "$spinner_active" == "true" ]] && stop_section_spinner
                        return "$size_rc"
                    fi
                    local remove_rc=1
                    if [[ "$dry_run_mode" == "true" ]]; then
                        if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                            record_dry_run_cleanup_target "$file_path" "$file_size_kb" 1 true || continue
                        fi
                        MOLE_DRY_RUN=1 safe_remove "$file_path" true "$file_size_kb" && remove_rc=0
                    elif safe_remove "$file_path" true "$file_size_kb"; then
                        remove_rc=0
                    fi
                    if [[ $remove_rc -eq 0 ]]; then
                        count=$((count + 1))
                        cleaned_kb=$((cleaned_kb + file_size_kb))
                    fi
                fi
            done < <(command find "$target_path" -type f -mtime +"$mail_age_days" -print0 2> /dev/null || true)
        fi
    done
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $count -gt 0 ]]; then
        local cleaned_mb
        cleaned_mb=$(echo "$cleaned_kb" | awk '{printf "%.1f", $1/1024}' || echo "0.0")
        if [[ "$dry_run_mode" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Would clean $count mail attachments older than ${mail_age_days}d, about ${cleaned_mb}MB"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $count mail attachments older than ${mail_age_days}d, about ${cleaned_mb}MB"
        fi
        note_activity
    fi
}

# Chrome, Edge, and Brave are all Chromium: same versioned framework layout
# (Contents/Frameworks/<X>.framework/Versions with a Current symlink), same
# keep-Current + keep-newer-staged-update rules, same removal and accounting.
# Only four facts differ per browser, so they are parameters here and the three
# public functions below are thin wrappers.
#
# clean_edge_updater_old_versions is deliberately NOT routed through this: it
# keeps the latest by `sort -V` (no Current symlink at all) and never escalates
# to a sudo removal. Merging it would change its semantics.
_clean_chromium_old_versions() {
    local label="$1"
    local framework="$2"
    local running_probe="$3"
    shift 3
    local -a app_paths=("$@")

    local app_path versions_dir
    local cleaned_count=0
    local total_size=0
    local cleaned_any=false
    local stopped_reason=""
    for app_path in "${app_paths[@]}"; do
        [[ -d "$app_path" ]] || continue

        # Every silent skip below logs its reason: "old versions not removed"
        # reports are undiagnosable without knowing which gate bailed (#1216).
        versions_dir="$app_path/Contents/Frameworks/$framework/Versions"
        if [[ ! -d "$versions_dir" ]]; then
            debug_log "${label} old versions: no Versions dir at $versions_dir"
            continue
        fi

        local current_link="$versions_dir/Current"
        if [[ ! -L "$current_link" ]]; then
            debug_log "${label} old versions: no Current symlink in $versions_dir"
            continue
        fi

        local current_version
        current_version=$(readlink "$current_link" 2> /dev/null || true)
        current_version="${current_version##*/}"
        if [[ -z "$current_version" ]]; then
            debug_log "${label} old versions: Current symlink unreadable"
            continue
        fi

        # Verify the Current symlink target exists. If broken, skip to avoid
        # accidentally deleting the active browser version.
        if [[ ! -d "$versions_dir/$current_version" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${label} old versions · skipped (Current symlink broken)"
            note_activity
            continue
        fi

        # Keep a version newer than Current: it is a freshly staged auto-update
        # that Current will point at on next launch.
        local newest_version=""
        local newest_mtime=0
        local current_mtime
        current_mtime=$(stat -f%m "$versions_dir/$current_version" 2> /dev/null || echo "0")
        [[ "$current_mtime" =~ ^[0-9]+$ ]] || current_mtime=0

        local -a old_versions=()
        local dir name
        for dir in "$versions_dir"/*; do
            [[ -d "$dir" && ! -L "$dir" ]] || continue
            name=$(basename "$dir")
            [[ "$name" == "Current" ]] && continue
            local mtime
            mtime=$(stat -f%m "$dir" 2> /dev/null || echo "0")
            if [[ "$mtime" =~ ^[0-9]+$ ]] && [[ "$mtime" -gt "$newest_mtime" ]]; then
                newest_mtime="$mtime"
                newest_version="$name"
            fi
        done
        if [[ "$newest_mtime" -le "$current_mtime" ]]; then
            newest_version=""
        elif [[ -n "$newest_version" ]]; then
            debug_log "${label} old versions: keeping $newest_version (staged auto-update newer than Current=$current_version)"
        fi

        for dir in "$versions_dir"/*; do
            [[ -d "$dir" && ! -L "$dir" ]] || continue
            name=$(basename "$dir")
            [[ "$name" == "Current" ]] && continue
            [[ "$name" == "$current_version" ]] && continue
            [[ -n "$newest_version" && "$name" == "$newest_version" ]] && continue
            if should_protect_path "$dir" || is_path_whitelisted "$dir" || holds_compiled_model_cache "$dir"; then
                continue
            fi
            old_versions+=("$dir")
        done

        if [[ ${#old_versions[@]} -eq 0 ]]; then
            debug_log "${label} old versions: nothing to remove in $versions_dir (Current=$current_version)"
            continue
        fi

        local process_state=0
        "$running_probe" || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            if [[ $process_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} ${label} old versions · skipped (process state unknown)"
                note_activity
            else
                mole_defer_cleanup_family "$label"
            fi
            return 0
        fi

        for dir in "${old_versions[@]}"; do
            process_state=0
            "$running_probe" || process_state=$?
            if [[ $process_state -ne 1 ]]; then
                stopped_reason="${label} started"
                [[ $process_state -eq 2 ]] && stopped_reason="process state unknown"
                break
            fi
            local size_kb=""
            local size_rc=0
            size_kb=$(get_path_size_kb "$dir") || size_rc=$?
            [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
            [[ $size_rc -eq 0 ]] || return "$size_rc"
            size_kb="${size_kb:-0}"
            process_state=0
            "$running_probe" || process_state=$?
            if [[ $process_state -ne 1 ]]; then
                stopped_reason="${label} started"
                [[ $process_state -eq 2 ]] && stopped_reason="process state unknown"
                break
            fi

            if [[ "$DRY_RUN" == "true" ]]; then
                if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                    record_dry_run_cleanup_target "$dir" "$size_kb" 1 true || continue
                fi
                total_size=$((total_size + size_kb))
                cleaned_count=$((cleaned_count + 1))
                cleaned_any=true
                continue
            fi

            local removed=false
            if has_sudo_session; then
                safe_sudo_remove "$dir" "$size_kb" > /dev/null 2>&1 && removed=true
            else
                safe_remove "$dir" true "$size_kb" > /dev/null 2>&1 && removed=true
            fi
            if [[ "$removed" == "true" ]]; then
                total_size=$((total_size + size_kb))
                cleaned_count=$((cleaned_count + 1))
                cleaned_any=true
            else
                debug_log "${label} old version removal failed: $dir"
            fi
        done
        [[ -n "$stopped_reason" ]] && break
    done

    if [[ "$cleaned_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} ${label} old versions${NC} · ${YELLOW}${cleaned_count} dirs, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} ${label} old versions${NC} · ${line_color}${cleaned_count} dirs, $size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size))
        total_items=$((total_items + 1))
        note_activity
    fi
    if [[ -n "$stopped_reason" ]]; then
        if [[ "$stopped_reason" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${label} old versions · stopped (${stopped_reason})"
            note_activity
        else
            mole_defer_cleanup_family "$label"
        fi
    fi
}

# Chrome also runs under a helper process name, so the probe is wider than pgrep -x.
is_google_chrome_running() {
    mole_pgrep_any \
        -x "Google Chrome" \
        -x "Google Chrome Helper" \
        -f "/Google Chrome.app/"
}

# Exact process names only: "Microsoft Edge" must not match Microsoft Teams.
is_microsoft_edge_running() {
    mole_pgrep_any -x "Microsoft Edge"
}

is_brave_browser_running() {
    mole_pgrep_any -x "Brave Browser"
}

_firefox_process_state() {
    mole_pgrep_any -x "Firefox"
}

_dropbox_process_state() {
    mole_pgrep_any -x "Dropbox"
}

_google_drive_process_state() {
    mole_pgrep_any -x "Google Drive"
}

_onedrive_process_state() {
    mole_pgrep_any -x "OneDrive"
}

_clean_chrome_profile_caches_guarded() {
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome app cache" \
        ~/Library/Application\ Support/Google/Chrome/*/Application\ Cache/* "Chrome app cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome code cache" \
        ~/Library/Application\ Support/Google/Chrome/*/Code\ Cache/* "Chrome code cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome GPU cache" \
        ~/Library/Application\ Support/Google/Chrome/*/GPUCache/* "Chrome GPU cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome Dawn cache" \
        ~/Library/Application\ Support/Google/Chrome/*/DawnCache/* "Chrome Dawn cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome GR shader cache" \
        ~/Library/Application\ Support/Google/Chrome/*/GrShaderCache/* "Chrome GR shader cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome Graphite Dawn cache" \
        ~/Library/Application\ Support/Google/Chrome/*/GraphiteDawnCache/* "Chrome Graphite Dawn cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome component CRX cache" \
        ~/Library/Application\ Support/Google/Chrome/component_crx_cache/* "Chrome component CRX cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome shader cache" \
        ~/Library/Application\ Support/Google/Chrome/ShaderCache/* "Chrome shader cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome GR shader cache" \
        ~/Library/Application\ Support/Google/Chrome/GrShaderCache/* "Chrome GR shader cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome Dawn cache" \
        ~/Library/Application\ Support/Google/Chrome/GraphiteDawnCache/* "Chrome Dawn cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome crash reports" \
        ~/Library/Application\ Support/Google/Chrome/Crashpad/completed/* "Chrome crash reports" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome on-device model cache" \
        ~/Library/Application\ Support/Google/Chrome/OptGuideOnDeviceModel/* "Chrome on-device model cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome on-device classifier cache" \
        ~/Library/Application\ Support/Google/Chrome/OptGuideOnDeviceClassifierModel/* "Chrome on-device classifier cache" || return 1
    _user_safe_clean_process_guarded is_google_chrome_running "Chrome" "Chrome optimization guide models" \
        ~/Library/Application\ Support/Google/Chrome/optimization_guide_model_store/* "Chrome optimization guide models" || return 1
}

_clean_firefox_caches_guarded() {
    _user_safe_clean_process_guarded _firefox_process_state "Firefox" "Firefox cache" \
        ~/Library/Caches/Firefox/* "Firefox cache" || return 1
    _user_safe_clean_process_guarded _firefox_process_state "Firefox" "Firefox profile cache" \
        ~/Library/Application\ Support/Firefox/Profiles/*/cache2/* "Firefox profile cache" || return 1
}

_clean_dropbox_caches_guarded() {
    _user_safe_clean_process_guarded _dropbox_process_state "Dropbox" "Dropbox cache" \
        ~/Library/Caches/com.dropbox.* "Dropbox cache" || return 1
    _user_safe_clean_process_guarded _dropbox_process_state "Dropbox" "Dropbox cache" \
        ~/Library/Caches/com.getdropbox.dropbox "Dropbox cache" || return 1
}

# Remove old Google Chrome versions while keeping Current.
clean_chrome_old_versions() {
    local -a app_paths
    if [[ -n "${MOLE_CHROME_APP_PATHS:-}" ]]; then
        IFS=':' read -ra app_paths <<< "$MOLE_CHROME_APP_PATHS"
    else
        app_paths=(
            "/Applications/Google Chrome.app"
            "$HOME/Applications/Google Chrome.app"
        )
    fi

    _clean_chromium_old_versions "Chrome" "Google Chrome Framework.framework" \
        is_google_chrome_running "${app_paths[@]}"
}

# Remove old Microsoft Edge versions while keeping Current.
clean_edge_old_versions() {
    local -a app_paths
    if [[ -n "${MOLE_EDGE_APP_PATHS:-}" ]]; then
        IFS=':' read -ra app_paths <<< "$MOLE_EDGE_APP_PATHS"
    else
        app_paths=(
            "/Applications/Microsoft Edge.app"
            "$HOME/Applications/Microsoft Edge.app"
        )
    fi

    _clean_chromium_old_versions "Edge" "Microsoft Edge Framework.framework" \
        is_microsoft_edge_running "${app_paths[@]}"
}

# Remove old Microsoft EdgeUpdater versions while keeping latest.
clean_edge_updater_old_versions() {
    local updater_dir="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
    [[ -d "$updater_dir" ]] || return 0

    local -a version_dirs=()
    local dir
    for dir in "$updater_dir"/*; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        version_dirs+=("$dir")
    done

    if [[ ${#version_dirs[@]} -eq 0 ]]; then
        return 0
    fi

    # A staged payload is only worth keeping while it is at least as new as
    # the installed Edge. After Edge updates itself the updater leaves the
    # previously staged copy behind, and a bare keep-the-newest rule keeps
    # that stale copy forever when it is the only directory (#1216). With a
    # known installed version, anything strictly older is removable; without
    # one, fall back to the original conservative keep-latest rule.
    local installed_version="" edge_app
    for edge_app in "/Applications/Microsoft Edge.app" "$HOME/Applications/Microsoft Edge.app"; do
        if [[ -f "$edge_app/Contents/Info.plist" ]]; then
            installed_version=$(plutil -extract CFBundleShortVersionString raw "$edge_app/Contents/Info.plist" 2> /dev/null || echo "")
            [[ -n "$installed_version" ]] && break
        fi
    done

    local latest_version=""
    if [[ -z "$installed_version" ]]; then
        if [[ ${#version_dirs[@]} -lt 2 ]]; then
            return 0
        fi
        latest_version=$(printf '%s\n' "${version_dirs[@]##*/}" | sort -V | tail -n 1)
        [[ -n "$latest_version" ]] || return 0
    fi

    local -a cleanable_dirs=()
    for dir in "${version_dirs[@]}"; do
        local name
        name=$(basename "$dir")
        if [[ -n "$installed_version" ]]; then
            # Keep any payload not strictly older than the installed Edge:
            # an equal or newer copy is a pending update, not a leftover.
            if [[ "$name" == "$installed_version" ]] ||
                [[ "$(printf '%s\n%s\n' "$name" "$installed_version" | sort -V | head -n 1)" != "$name" ]]; then
                continue
            fi
        else
            [[ "$name" == "$latest_version" ]] && continue
        fi
        if should_protect_path "$dir" || is_path_whitelisted "$dir" || holds_compiled_model_cache "$dir"; then
            continue
        fi
        cleanable_dirs+=("$dir")
    done
    [[ ${#cleanable_dirs[@]} -gt 0 ]] || return 0

    local process_state=0
    is_microsoft_edge_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Edge updater old versions · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Edge"
        fi
        return 0
    fi

    local cleaned_count=0
    local total_size=0
    local cleaned_any=false
    local stopped_reason=""
    for dir in "${cleanable_dirs[@]}"; do
        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$dir") || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        size_kb="${size_kb:-0}"
        process_state=0
        is_microsoft_edge_running || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            stopped_reason="Edge started"
            [[ $process_state -eq 2 ]] && stopped_reason="process state unknown"
            break
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$dir" "$size_kb" 1 true || continue
            fi
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
            cleaned_any=true
            continue
        fi
        if safe_remove "$dir" true "$size_kb" > /dev/null 2>&1; then
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
            cleaned_any=true
        else
            debug_log "Edge updater old version removal failed: $dir"
        fi
    done

    if [[ "$cleaned_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Edge updater old versions${NC} · ${YELLOW}${cleaned_count} dirs, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Edge updater old versions${NC} · ${line_color}${cleaned_count} dirs, $size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size))
        total_items=$((total_items + 1))
        note_activity
    fi
    if [[ -n "$stopped_reason" ]]; then
        if [[ "$stopped_reason" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Edge updater old versions · stopped (${stopped_reason})"
            note_activity
        else
            mole_defer_cleanup_family "Edge"
        fi
    fi
}

# Remove old Brave Browser versions while keeping Current.
clean_brave_old_versions() {
    local -a app_paths
    if [[ -n "${MOLE_BRAVE_APP_PATHS:-}" ]]; then
        IFS=':' read -ra app_paths <<< "$MOLE_BRAVE_APP_PATHS"
    else
        app_paths=(
            "/Applications/Brave Browser.app"
            "$HOME/Applications/Brave Browser.app"
        )
    fi

    _clean_chromium_old_versions "Brave" "Brave Browser Framework.framework" \
        is_brave_browser_running "${app_paths[@]}"
}

# Finder metadata (.DS_Store).
clean_finder_metadata() {
    if [[ "$PROTECT_FINDER_METADATA" == "true" ]]; then
        return
    fi
    clean_ds_store_tree "$HOME" "Home directory, .DS_Store"
}

# Conservative cleanup for support caches not covered by generic rules.
clean_support_app_data() {
    local support_age_days="${MOLE_SUPPORT_CACHE_AGE_DAYS:-30}"
    [[ "$support_age_days" =~ ^[0-9]+$ ]] || support_age_days=30

    local crash_reporter_dir="$HOME/Library/Application Support/CrashReporter"
    if [[ -d "$crash_reporter_dir" && ! -L "$crash_reporter_dir" ]]; then
        safe_find_delete "$crash_reporter_dir" "*" "$support_age_days" "f" || true
    fi

    # Do not sweep com.apple.idleassetsd here. It stores the aerial screen saver
    # and dynamic wallpaper videos selected in System Settings. Those files are
    # written at download time rather than touched while in use, so age cannot
    # distinguish an active wallpaper from stale data. The shared path guard
    # protects these assets alongside com.apple.wallpaper (#1118).

    # Do not touch Messages attachments, only preview/sticker caches.
    safe_clean ~/Library/Messages/StickerCache/* "Messages sticker cache"
    safe_clean ~/Library/Messages/Caches/Previews/Attachments/* "Messages preview attachment cache"
    safe_clean ~/Library/Messages/Caches/Previews/StickerCache/* "Messages preview sticker cache"
}

# App caches (merged: macOS system caches + Sandboxed apps).
cache_top_level_entry_count_capped() {
    local dir="$1"
    local cap="${2:-101}"
    local count=0
    local _nullglob_state
    local _dotglob_state
    _nullglob_state=$(shopt -p nullglob || true)
    _dotglob_state=$(shopt -p dotglob || true)
    shopt -s nullglob dotglob

    local item
    for item in "$dir"/*; do
        [[ -e "$item" ]] || continue
        count=$((count + 1))
        if ((count >= cap)); then
            break
        fi
    done

    # eval: restore shopt state captured by $(shopt -p)
    eval "$_nullglob_state"
    eval "$_dotglob_state"

    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "$count"
}

directory_has_entries() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1

    local _nullglob_state
    local _dotglob_state
    _nullglob_state=$(shopt -p nullglob || true)
    _dotglob_state=$(shopt -p dotglob || true)
    shopt -s nullglob dotglob

    local item
    for item in "$dir"/*; do
        if [[ -e "$item" ]]; then
            # eval: restore shopt state captured by $(shopt -p)
            eval "$_nullglob_state"
            eval "$_dotglob_state"
            return 0
        fi
    done

    # eval: restore shopt state captured by $(shopt -p)
    eval "$_nullglob_state"
    eval "$_dotglob_state"
    return 1
}

clean_app_caches() {
    # Every App Container handle probe in this section shares one wall-clock
    # budget, including the explicit Apple cache rows before the generic scan.
    local _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=""
    start_section_spinner "Scanning app caches..."

    # macOS system caches (merged from clean_macos_system_caches)
    safe_clean ~/Library/Saved\ Application\ State/* "Saved application states" || true
    safe_clean ~/Library/Caches/com.apple.photoanalysisd "Photo analysis cache" || true
    safe_clean ~/Library/Caches/com.apple.akd "Apple ID cache" || true
    safe_clean ~/Library/Caches/com.apple.WebKit.Networking/* "WebKit network cache" || true
    safe_clean ~/Library/DiagnosticReports/* "Diagnostic reports" || true
    safe_clean ~/Library/Caches/com.apple.QuickLook.thumbnailcache "QuickLook thumbnails" || true
    safe_clean ~/Library/Caches/Quick\ Look/* "QuickLook cache" || true
    safe_clean ~/Library/Caches/com.apple.iconservices* "Icon services cache" || true
    _clean_incomplete_downloads
    # Do not clean ~/Library/Autosave Information by default: it can contain
    # recoverable user documents, not only disposable cache data.
    safe_clean ~/Library/IdentityCaches/* "Identity caches" || true
    safe_clean ~/Library/Suggestions/* "Siri suggestions cache" || true
    # Do not clean ~/Library/Calendars/Calendar Cache*: CalendarAgent keeps this
    # SQLite index open in the background. Deleting it while the daemon is
    # running can crash Calendar.app until logout/login (#1508). Apple treats
    # this as a manual troubleshooting step, not routine cache maintenance.
    safe_clean ~/Library/Application\ Support/AddressBook/Sources/*/Photos.cache "Address Book photo cache" || true
    clean_support_app_data

    # Stop initial scan indicator before entering per-group scans.
    stop_section_spinner

    # Sandboxed app caches
    safe_clean ~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/* "Wallpaper agent cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/* "Media analysis cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/tmp/* "Media analysis temp files"
    safe_clean ~/Library/Containers/com.apple.AppStore/Data/Library/Caches/* "App Store cache"
    safe_clean ~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/* "Apple Configurator temp files"
    safe_clean ~/Library/Containers/com.apple.wallpaper.extension.aerials/Data/tmp/* "Wallpaper aerials temp files"
    safe_clean ~/Library/Containers/com.apple.geod/Data/tmp/* "Geod temp files"
    safe_clean ~/Library/Containers/com.apple.stocks/Data/Library/Caches/* "Stocks cache"
    # Do NOT clean ~/Library/Application Support/com.apple.wallpaper/aerials/
    # thumbnails: those ~50KB PNGs are the wallpaper "cover" previews shown in
    # System Settings > Wallpaper. Deleting them reclaims almost nothing yet
    # blanks every cover into a cloud-download placeholder and forces a
    # re-download on the next open (issue #1118).
    safe_clean ~/Library/Caches/com.apple.helpd/* "macOS Help system cache"
    safe_clean ~/Library/Caches/GeoServices/* "Maps geo tile cache"
    safe_clean ~/Library/Containers/com.apple.AvatarUI.AvatarPickerMemojiPicker/Data/Library/Caches/* "Memoji picker cache"
    safe_clean ~/Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches/* "Music album art cache"
    safe_clean ~/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/* "CoreDevice service cache"
    safe_clean ~/Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Caches/* "Apple Intelligence extension cache"
    safe_clean ~/Library/Containers/com.apple.AppleMediaServicesUI.UtilityExtension/Data/tmp/* "Apple Media Services temp files"
    safe_clean ~/Library/Caches/com.apple.AppleMediaServices/* "Apple Media Services cache"
    safe_clean ~/Library/Caches/com.apple.duetexpertd/* "Duet Expert cache"
    safe_clean ~/Library/Caches/com.apple.parsecd/* "Parsecd cache"
    safe_clean ~/Library/Caches/com.apple.python/* "Apple Python cache"
    # The E5RT bundle cache used to be cleaned here. It is now protected by
    # holds_compiled_model_cache(): wiping it under a running daemon breaks
    # recognition until that daemon restarts, for a few MB.
    local containers_dir="$HOME/Library/Containers"
    [[ ! -d "$containers_dir" ]] && return 0
    start_section_spinner "Scanning sandboxed apps..."
    local total_size=0
    local total_size_partial=false
    local cleaned_count=0
    local found_any=false
    local precise_size_limit="${MOLE_CONTAINER_CACHE_PRECISE_SIZE_LIMIT:-64}"
    [[ "$precise_size_limit" =~ ^[0-9]+$ ]] || precise_size_limit=64
    local precise_size_used=0
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob
    local container_rc=0
    for container_dir in "$containers_dir"/*; do
        [[ -d "$container_dir/Data/Library/Caches" ]] || continue
        process_container_cache "$container_dir" || container_rc=$?
        [[ $container_rc -eq 0 ]] || break
    done
    # eval: restore shopt state captured by $(shopt -p)
    eval "$_ng_state"
    stop_section_spinner
    [[ $container_rc -eq 0 ]] || return "$container_rc"

    if [[ "$found_any" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$total_size_partial" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Sandboxed app caches${NC} · ${YELLOW}dry${NC}"
            else
                local size_human
                size_human=$(bytes_to_human "$((total_size * 1024))")
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Sandboxed app caches${NC} · $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
            fi
        else
            if [[ "$total_size_partial" == "true" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Sandboxed app caches${NC} · ${GREEN}cleaned${NC}"
            else
                local size_human
                size_human=$(bytes_to_human "$((total_size * 1024))")
                local line_color
                line_color=$(cleanup_result_color_kb "$total_size")
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} Sandboxed app caches${NC} · ${line_color}$size_human${NC}"
            fi
        fi
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size))
        total_items=$((total_items + 1))
        note_activity
    fi

    clean_group_container_caches || return $?
    clean_handoff_pasteboard_cache || return $?
}

# Handoff / Universal Clipboard staging cache. useractivityd is supposed to
# prune shared-pasteboard items itself but can leave hundreds of GB behind
# after heavy Command+C use (#1178). Items are ephemeral transfer buffers by
# design; anything modified within the last hour is kept so an in-flight
# clipboard sync between devices is never cut off.
clean_handoff_pasteboard_cache() {
    local pasteboard_dir="$HOME/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard"
    [[ -d "$pasteboard_dir" ]] || return 0
    [[ -L "$pasteboard_dir" ]] && return 0
    if is_path_whitelisted "$pasteboard_dir" 2> /dev/null; then
        return 0
    fi

    local cleaned_count=0
    local total_kb=0
    local item
    while IFS= read -r -d '' item; do
        [[ -e "$item" ]] || continue
        [[ -L "$item" ]] && continue
        if should_protect_path "$item" 2> /dev/null || is_path_whitelisted "$item" 2> /dev/null; then
            continue
        fi
        local item_kb=""
        local size_rc=0
        item_kb=$(get_path_size_kb "$item" 2> /dev/null) || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$item_kb" =~ ^[0-9]+$ ]] || item_kb=0
        if [[ "$DRY_RUN" == "true" ]]; then
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$item" "$item_kb" 1 true || continue
            fi
            cleaned_count=$((cleaned_count + 1))
            total_kb=$((total_kb + item_kb))
            continue
        fi
        if safe_remove "$item" true 2> /dev/null; then
            cleaned_count=$((cleaned_count + 1))
            total_kb=$((total_kb + item_kb))
        fi
    done < <(command find "$pasteboard_dir" -mindepth 1 -maxdepth 1 -mmin +60 -print0 2> /dev/null || true)

    [[ $cleaned_count -gt 0 ]] || return 0

    local size_human
    size_human=$(bytes_to_human "$((total_kb * 1024))")
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Handoff clipboard cache${NC} · $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
    else
        local line_color
        line_color=$(cleanup_result_color_kb "$total_kb")
        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Handoff clipboard cache${NC} · ${line_color}$size_human${NC}"
    fi
    files_cleaned=$((files_cleaned + cleaned_count))
    total_size_cleaned=$((total_size_cleaned + total_kb))
    total_items=$((total_items + 1))
    note_activity
}

# Process a single container cache directory.
process_container_cache() {
    local container_dir="$1"
    [[ -d "$container_dir" ]] || return 0
    [[ -L "$container_dir" ]] && return 0
    local bundle_id="${container_dir##*/}"
    if is_critical_system_component "$bundle_id"; then
        return 0
    fi
    if should_protect_data "$bundle_id"; then
        return 0
    fi
    local cache_dir="$container_dir/Data/Library/Caches"
    [[ -d "$cache_dir" ]] || return 0
    [[ -L "$cache_dir" ]] && return 0
    local item_count
    item_count=$(cache_top_level_entry_count_capped "$cache_dir" 101)
    [[ "$item_count" =~ ^[0-9]+$ ]] || item_count=0
    [[ "$item_count" -eq 0 ]] && return 0
    local measure_item_sizes=true
    if [[ "$item_count" -gt 100 ]]; then
        # Large containers are intentionally cleanup-only: one du per child
        # turns a bounded cache sweep into another long recursive scan.
        measure_item_sizes=false
        total_size_partial=true
    fi

    local _nullglob_state
    local _dotglob_state
    _nullglob_state=$(shopt -p nullglob || true)
    _dotglob_state=$(shopt -p dotglob || true)
    shopt -s nullglob dotglob
    local item
    for item in "$cache_dir"/*; do
        [[ -e "$item" ]] || continue
        [[ -L "$item" ]] && continue
        if holds_compiled_model_cache "$item"; then
            continue
        fi
        # Re-check each item, not just the parent bundle: a user may have
        # whitelisted a specific cache path, and should_protect_path may
        # cover a nested entry. Mirrors clean_group_container_caches.
        if should_protect_path "$item" 2> /dev/null || is_path_whitelisted "$item" 2> /dev/null; then
            continue
        fi

        local item_size_kb=0
        local size_known=false
        if [[ "$measure_item_sizes" == "true" && "$precise_size_used" -lt "$precise_size_limit" ]]; then
            local size_rc=0
            item_size_kb=$(get_path_size_kb "$item" 2> /dev/null) || size_rc=$?
            if [[ $size_rc -ne 0 ]]; then
                _mole_record_clean_cancellation "$size_rc"
                # eval: restore shopt state captured by $(shopt -p)
                eval "$_nullglob_state"
                eval "$_dotglob_state"
                return "$size_rc"
            fi
            [[ "$item_size_kb" =~ ^[0-9]+$ ]] || item_size_kb=0
            precise_size_used=$((precise_size_used + 1))
            size_known=true
        elif [[ "$measure_item_sizes" == "true" ]]; then
            total_size_partial=true
        fi

        local action_rc=0
        if [[ "$DRY_RUN" == "true" ]]; then
            # Dry-run and real mode share this candidate loop. Preview probes
            # once here; real mode probes once at safe_remove's final sink.
            _mole_reset_process_snapshot
            validate_path_for_deletion "$item" 2> /dev/null || action_rc=$?
            if [[ $action_rc -eq 0 ]] && declare -f register_dry_run_cleanup_target > /dev/null 2>&1; then
                register_dry_run_cleanup_target "$item" || action_rc=$?
            fi
            if [[ $action_rc -eq 0 ]] && declare -f append_dry_run_cleanup_target > /dev/null 2>&1; then
                append_dry_run_cleanup_target "$item" "$item_size_kb" 1 "$size_known" || action_rc=$?
            fi
        else
            safe_remove "$item" true "$item_size_kb" || action_rc=$?
        fi
        if [[ $action_rc -ge 128 ]]; then
            _mole_record_clean_cancellation "$action_rc"
            # eval: restore shopt state captured by $(shopt -p)
            eval "$_nullglob_state"
            eval "$_dotglob_state"
            return "$action_rc"
        fi
        [[ $action_rc -eq 0 ]] || continue
        total_size=$((total_size + item_size_kb))
        cleaned_count=$((cleaned_count + 1))
        found_any=true
    done
    # eval: restore shopt state captured by $(shopt -p)
    eval "$_nullglob_state"
    eval "$_dotglob_state"
}

# Group Containers safe cleanup (logs for protected apps, caches/tmp for non-protected apps).
clean_group_container_caches() {
    local group_containers_dir="$HOME/Library/Group Containers"
    [[ -d "$group_containers_dir" ]] || return 0
    if ! directory_has_entries "$group_containers_dir"; then
        return 0
    fi

    start_section_spinner "Scanning Group Containers..."
    local total_size=0
    local total_size_partial=false
    local cleaned_count=0
    local found_any=false
    local _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=""

    local container_dir
    local group_nullglob_state
    group_nullglob_state=$(shopt -p nullglob || true)
    shopt -s nullglob

    for container_dir in "$group_containers_dir"/*; do
        [[ -d "$container_dir" ]] || continue
        [[ -L "$container_dir" ]] && continue
        # Skip containers we cannot read (avoids repeated TCC/privacy prompts on macOS).
        [[ -r "$container_dir" ]] || continue
        local container_id="${container_dir##*/}"

        # Skip Apple-owned shared containers entirely.
        case "$container_id" in
            com.apple.* | group.com.apple.* | systemgroup.com.apple.*)
                continue
                ;;
        esac

        # Skip Safari Web Extension containers: cleaning their caches triggers
        # extension reinitialization and can launch Safari unexpectedly.
        if [[ -d "$HOME/Library/Containers/$container_id" ]]; then
            local _ext_match=false
            local _ext_entry
            for _ext_entry in "$HOME/Library/Containers/$container_id/"*Safari* \
                "$HOME/Library/Containers/$container_id/"*safari*; do
                if [[ -e "$_ext_entry" ]]; then
                    _ext_match=true
                    break
                fi
            done
            if [[ "$_ext_match" == "true" ]]; then
                continue
            fi
        fi
        local normalized_id="$container_id"
        [[ "$normalized_id" == group.* ]] && normalized_id="${normalized_id#group.}"

        local protected_container=false
        if should_protect_data "$container_id" 2> /dev/null || should_protect_data "$normalized_id" 2> /dev/null; then
            protected_container=true
        fi

        local -a candidates=(
            "$container_dir/Logs"
            "$container_dir/Library/Logs"
        )
        if [[ "$protected_container" != "true" ]]; then
            candidates+=(
                "$container_dir/tmp"
                "$container_dir/Library/tmp"
                "$container_dir/Caches"
                "$container_dir/Library/Caches"
            )
        fi

        local candidate
        for candidate in "${candidates[@]}"; do
            [[ -d "$candidate" ]] || continue
            [[ -L "$candidate" ]] && continue
            if is_path_whitelisted "$candidate" 2> /dev/null; then
                continue
            fi

            local item
            local quick_count
            quick_count=$(cache_top_level_entry_count_capped "$candidate" 101)
            [[ "$quick_count" =~ ^[0-9]+$ ]] || quick_count=0
            [[ "$quick_count" -eq 0 ]] && continue

            local candidate_size_kb=0
            local candidate_changed=false
            local candidate_nullglob_state
            local candidate_dotglob_state
            candidate_nullglob_state=$(shopt -p nullglob || true)
            candidate_dotglob_state=$(shopt -p dotglob || true)
            shopt -s nullglob dotglob

            local candidate_size_known=true
            if [[ "$quick_count" -gt 100 ]]; then
                total_size_partial=true
                candidate_size_known=false
            fi
            for item in "$candidate"/*; do
                [[ -e "$item" ]] || continue
                [[ -L "$item" ]] && continue
                if should_protect_path "$item" 2> /dev/null ||
                    is_path_whitelisted "$item" 2> /dev/null ||
                    holds_compiled_model_cache "$item" 2> /dev/null; then
                    continue
                fi

                local item_size=0
                if [[ "$candidate_size_known" == "true" ]]; then
                    local size_rc=0
                    item_size=$(get_path_size_kb "$item" 2> /dev/null) || size_rc=$?
                    [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
                    if [[ $size_rc -ne 0 ]]; then
                        # eval: restore shopt state captured by $(shopt -p)
                        eval "$candidate_nullglob_state"
                        eval "$candidate_dotglob_state"
                        eval "$group_nullglob_state"
                        return "$size_rc"
                    fi
                    [[ "$item_size" =~ ^[0-9]+$ ]] || item_size=0
                fi

                local action_rc=0
                if [[ "$DRY_RUN" == "true" ]]; then
                    _mole_reset_process_snapshot
                    # Match real safe_remove ordering: a compiled-model cache
                    # that appeared during sizing is rejected before the
                    # recursive lsof probe can consume this section's budget.
                    if holds_compiled_model_cache "$item" 2> /dev/null; then
                        action_rc=1
                    fi
                    if [[ $action_rc -eq 0 ]]; then
                        validate_path_for_deletion "$item" 2> /dev/null || action_rc=$?
                    fi
                    if [[ $action_rc -eq 0 ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                        # The path, whitelist, compiled-model, live-owner, and
                        # SQLite guards have all run after sizing. Avoid only
                        # repeating that complete eligibility pass.
                        local _MOLE_DRY_RUN_TARGET_PREVALIDATED=true
                        record_dry_run_cleanup_target \
                            "$item" "$item_size" 1 "$candidate_size_known" || action_rc=$?
                    fi
                else
                    safe_remove "$item" true "$item_size" 2> /dev/null || action_rc=$?
                fi
                if [[ $action_rc -ge 128 ]]; then
                    _mole_record_clean_cancellation "$action_rc"
                    # eval: restore shopt state captured by $(shopt -p)
                    eval "$candidate_nullglob_state"
                    eval "$candidate_dotglob_state"
                    eval "$group_nullglob_state"
                    return "$action_rc"
                fi
                [[ $action_rc -eq 0 ]] || continue
                candidate_changed=true
                candidate_size_kb=$((candidate_size_kb + item_size))
            done
            # eval: restore shopt state captured by $(shopt -p)
            eval "$candidate_nullglob_state"
            eval "$candidate_dotglob_state"

            if [[ "$candidate_changed" == "true" ]]; then
                total_size=$((total_size + candidate_size_kb))
                cleaned_count=$((cleaned_count + 1))
                found_any=true
            fi
        done
    done
    # eval: restore shopt state captured by $(shopt -p)
    eval "$group_nullglob_state"

    stop_section_spinner

    if [[ "$found_any" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$total_size_partial" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Group Containers logs/caches${NC} · ${YELLOW}dry${NC}"
            else
                local size_human
                size_human=$(bytes_to_human "$((total_size * 1024))")
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Group Containers logs/caches${NC} · $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
            fi
        else
            if [[ "$total_size_partial" == "true" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Group Containers logs/caches${NC} · ${GREEN}cleaned${NC}"
            else
                local size_human
                size_human=$(bytes_to_human "$((total_size * 1024))")
                local line_color
                line_color=$(cleanup_result_color_kb "$total_size")
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} Group Containers logs/caches${NC} · ${line_color}$size_human${NC}"
            fi
        fi
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size))
        total_items=$((total_items + 1))
        note_activity
    fi
}

resolve_existing_path() {
    local path="$1"
    [[ -e "$path" ]] || return 1

    if command -v realpath > /dev/null 2>&1; then
        realpath "$path" 2> /dev/null && return 0
    fi

    local dir base
    dir=$(cd -P "$(dirname "$path")" 2> /dev/null && pwd) || return 1
    base=$(basename "$path")
    printf '%s/%s\n' "$dir" "$base"
}

external_volume_root() {
    printf '%s\n' "${MOLE_EXTERNAL_VOLUMES_ROOT:-/Volumes}"
}

validate_external_volume_target() {
    local target="$1"
    local root
    root=$(external_volume_root)
    local resolved_root="$root"
    if [[ -e "$root" ]]; then
        resolved_root=$(resolve_existing_path "$root" 2> /dev/null || printf '%s\n' "$root")
    fi
    resolved_root="${resolved_root%/}"

    if [[ -z "$target" ]]; then
        echo "Missing external volume path" >&2
        return 1
    fi
    if [[ "$target" != /* ]]; then
        echo "External volume path must be absolute: $target" >&2
        return 1
    fi
    if [[ "$target" == "$root" || "$target" == "$resolved_root" ]]; then
        echo "Refusing to clean the volumes root directly: $resolved_root" >&2
        return 1
    fi
    if [[ -L "$target" ]]; then
        echo "Refusing to clean symlinked volume path: $target" >&2
        return 1
    fi

    local resolved
    resolved=$(resolve_existing_path "$target") || {
        echo "External volume path does not exist: $target" >&2
        return 1
    }

    if [[ "$resolved" != "$resolved_root/"* ]]; then
        echo "External volume path must be under $resolved_root: $resolved" >&2
        return 1
    fi

    local relative_path="${resolved#"$resolved_root"/}"
    if [[ -z "$relative_path" || "$relative_path" == "$resolved" || "$relative_path" == */* ]]; then
        echo "External cleanup only supports mounted paths directly under $resolved_root: $resolved" >&2
        return 1
    fi

    local disk_info=""
    disk_info=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" command diskutil info "$resolved" 2> /dev/null || echo "")
    if [[ -n "$disk_info" ]]; then
        if echo "$disk_info" | grep -Eq 'Internal:[[:space:]]+Yes'; then
            echo "Refusing to clean an internal volume: $resolved" >&2
            return 1
        fi

        local protocol=""
        protocol=$(echo "$disk_info" | awk -F: '/Protocol:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
        case "$protocol" in
            SMB | NFS | AFP | CIFS | WebDAV)
                echo "Refusing to clean network volume protocol $protocol: $resolved" >&2
                return 1
                ;;
        esac
    fi

    printf '%s\n' "$resolved"
}

_mole_external_volume_final_guard() {
    local target="$1"
    local previous_guard="${_MOLE_EXTERNAL_VOLUME_PREVIOUS_FINAL_GUARD:-}"
    if [[ -n "$previous_guard" && "$previous_guard" != "_mole_external_volume_final_guard" ]] &&
        declare -f "$previous_guard" > /dev/null 2>&1; then
        "$previous_guard" "$target" || return $?
    fi
    _mole_path_matches_identity \
        "$_MOLE_EXTERNAL_VOLUME_GUARD_PATH" \
        "$_MOLE_EXTERNAL_VOLUME_GUARD_PARENT" \
        "$_MOLE_EXTERNAL_VOLUME_GUARD_PARENT_ID" \
        "$_MOLE_EXTERNAL_VOLUME_GUARD_TARGET_ID"
}

clean_external_volume_target() {
    local volume="$1"
    [[ -d "$volume" ]] || return 1
    [[ -L "$volume" ]] && return 1

    if ! _mole_snapshot_path_identity "$volume"; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} External volume cleanup · ${GRAY}could not bind mounted volume, no changes${NC}"
        note_activity
        return 1
    fi
    local _MOLE_EXTERNAL_VOLUME_GUARD_PATH="$volume"
    local _MOLE_EXTERNAL_VOLUME_GUARD_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
    local _MOLE_EXTERNAL_VOLUME_GUARD_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local _MOLE_EXTERNAL_VOLUME_GUARD_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    local _MOLE_EXTERNAL_VOLUME_PREVIOUS_FINAL_GUARD="${_MOLE_SAFE_REMOVE_FINAL_GUARD:-}"
    local _MOLE_SAFE_REMOVE_FINAL_GUARD="_mole_external_volume_final_guard"

    local -a top_level_targets=(
        "$volume/.TemporaryItems"
        "$volume/.Trashes"
    )
    local cleaned_count=0
    local total_size=0
    local found_any=false
    local volume_name="${volume##*/}"

    start_section_spinner "Scanning external volume..."

    # Materialize the complete AppleDouble inventory before any external-volume
    # mutation. A timed-out find can leave a valid-looking prefix on stdout;
    # consuming that prefix from process substitution used to delete those rows
    # and report success even though the scan itself returned 124.
    local metadata_scan_timeout="${MOLE_EXTERNAL_VOLUME_SCAN_TIMEOUT:-15}"
    [[ "$metadata_scan_timeout" =~ ^[0-9]+$ ]] || metadata_scan_timeout=15
    local metadata_scan_file=""
    if ! metadata_scan_file=$(mktemp_file "external-volume-metadata"); then
        stop_section_spinner
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} External volume cleanup · ${GRAY}could not prepare scan, no changes${NC}"
        note_activity
        return 1
    fi
    local metadata_scan_rc=0
    run_with_timeout "$metadata_scan_timeout" find -P "$volume" -xdev \
        \( -path "$volume/.TemporaryItems" -o -path "$volume/.Trashes" \) -prune -o \
        -type f -name "._*" -print0 > "$metadata_scan_file" 2> /dev/null || metadata_scan_rc=$?
    if [[ $metadata_scan_rc -ne 0 ]]; then
        : > "$metadata_scan_file" || true
        stop_section_spinner
        if [[ $metadata_scan_rc -eq 124 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} External volume cleanup · ${GRAY}scan timed out, no changes${NC}"
        elif [[ $metadata_scan_rc -ge 128 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} External volume cleanup · ${GRAY}scan interrupted, no changes${NC}"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} External volume cleanup · ${GRAY}scan failed, no changes${NC}"
        fi
        note_activity
        _mole_record_clean_cancellation "$metadata_scan_rc"
        return "$metadata_scan_rc"
    fi

    local target_path
    for target_path in "${top_level_targets[@]}"; do
        [[ -e "$target_path" ]] || continue
        [[ -L "$target_path" ]] && continue
        if ! _mole_snapshot_path_identity "$target_path"; then
            continue
        fi
        local target_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        local target_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        local target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        if should_protect_path "$target_path" 2> /dev/null || is_path_whitelisted "$target_path" 2> /dev/null; then
            continue
        fi

        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$target_path" 2> /dev/null) || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" == "true" ]]; then
            if ! _mole_path_matches_identity \
                "$target_path" "$target_parent" "$target_parent_id" "$target_id"; then
                continue
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$target_path" "$size_kb" 1 true || continue
            fi
            found_any=true
            cleaned_count=$((cleaned_count + 1))
            total_size=$((total_size + size_kb))
        elif safe_remove "$target_path" true "$size_kb" "" \
            "$target_parent" "$target_parent_id" "$target_id" > /dev/null 2>&1; then
            found_any=true
            cleaned_count=$((cleaned_count + 1))
            total_size=$((total_size + size_kb))
        fi
    done

    if [[ "$PROTECT_FINDER_METADATA" != "true" ]]; then
        clean_ds_store_tree "$volume" "${volume_name} volume, .DS_Store"
    fi

    while IFS= read -r -d '' metadata_file; do
        [[ -e "$metadata_file" ]] || continue
        [[ -L "$metadata_file" ]] && continue
        if ! _mole_snapshot_path_identity "$metadata_file"; then
            continue
        fi
        local metadata_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        local metadata_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        local metadata_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        if should_protect_path "$metadata_file" 2> /dev/null || is_path_whitelisted "$metadata_file" 2> /dev/null; then
            continue
        fi

        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$metadata_file" 2> /dev/null) || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" == "true" ]]; then
            if ! _mole_path_matches_identity \
                "$metadata_file" "$metadata_parent" "$metadata_parent_id" "$metadata_id"; then
                continue
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$metadata_file" "$size_kb" 1 true || continue
            fi
            found_any=true
            cleaned_count=$((cleaned_count + 1))
            total_size=$((total_size + size_kb))
        elif safe_remove "$metadata_file" true "$size_kb" "" \
            "$metadata_parent" "$metadata_parent_id" "$metadata_id" > /dev/null 2>&1; then
            found_any=true
            cleaned_count=$((cleaned_count + 1))
            total_size=$((total_size + size_kb))
        fi
    done < "$metadata_scan_file"

    stop_section_spinner

    if [[ "$found_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} External volume cleanup${NC} · ${YELLOW}${volume_name}, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} External volume cleanup${NC} · ${line_color}${volume_name}, $size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size))
        total_items=$((total_items + 1))
        note_activity
    fi

    return 0
}

# Browser caches (Safari/Chrome/Edge/Firefox).
clean_browsers() {
    safe_clean ~/Library/Caches/com.apple.Safari/* "Safari cache"
    # Chrome/Chromium.
    safe_clean ~/Library/Caches/Google/Chrome/* "Chrome cache"
    # Do not clean Chromium Service Worker ScriptCache. Even when the browser is
    # closed, removing MV3 extension bytecode can break extension service
    # workers and trigger security warnings during dry-run scans. See #785,
    # #964, and #968.
    local chrome_support_has_targets=false
    if mole_cleanup_targets_exist \
        "$HOME/Library/Application Support/Google/Chrome"/*/Application\ Cache/* \
        "$HOME/Library/Application Support/Google/Chrome"/*/Code\ Cache/* \
        "$HOME/Library/Application Support/Google/Chrome"/*/GPUCache/* \
        "$HOME/Library/Application Support/Google/Chrome"/*/DawnCache/* \
        "$HOME/Library/Application Support/Google/Chrome"/*/GrShaderCache/* \
        "$HOME/Library/Application Support/Google/Chrome"/*/GraphiteDawnCache/* \
        "$HOME/Library/Application Support/Google/Chrome"/component_crx_cache/* \
        "$HOME/Library/Application Support/Google/Chrome"/ShaderCache/* \
        "$HOME/Library/Application Support/Google/Chrome"/GrShaderCache/* \
        "$HOME/Library/Application Support/Google/Chrome"/GraphiteDawnCache/* \
        "$HOME/Library/Application Support/Google/Chrome"/Crashpad/completed/* \
        "$HOME/Library/Application Support/Google/Chrome"/OptGuideOnDeviceModel/* \
        "$HOME/Library/Application Support/Google/Chrome"/OptGuideOnDeviceClassifierModel/* \
        "$HOME/Library/Application Support/Google/Chrome"/optimization_guide_model_store/*; then
        chrome_support_has_targets=true
    fi

    local chrome_state=0
    is_google_chrome_running || chrome_state=$?
    if [[ $chrome_state -eq 1 ]]; then
        # On-device AI model stores managed by Chrome's component updater;
        # re-downloaded on demand and often multiple GB (#1179).
        _clean_chrome_profile_caches_guarded || true
    elif [[ $chrome_state -eq 0 && "$chrome_support_has_targets" == "true" ]]; then
        mole_defer_cleanup_family "Chrome"
    elif [[ "$chrome_support_has_targets" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Chrome profile caches · skipped (process state unknown)"
        note_activity
    fi
    local _chrome_profile
    for _chrome_profile in "$HOME/Library/Application Support/Google/Chrome"/*/; do
        clean_service_worker_cache "Chrome" "${_chrome_profile%/}/Service Worker/CacheStorage"
    done
    safe_clean ~/Library/Application\ Support/Google/GoogleUpdater/crx_cache/* "GoogleUpdater CRX cache"
    safe_clean ~/Library/Application\ Support/Google/GoogleUpdater/*.old "GoogleUpdater old files"
    safe_clean ~/Library/Caches/Chromium/* "Chromium cache"
    safe_clean ~/.cache/puppeteer/* "Puppeteer browser cache"
    safe_clean ~/Library/Caches/com.microsoft.edgemac/* "Edge cache"
    # Arc Browser.
    if [[ -d ~/Library/Application\ Support/Arc ]]; then
        safe_clean ~/Library/Caches/company.thebrowser.Browser/* "Arc cache"
        local _arc_profile
        local _arc_running=false
        pgrep -x "Arc" > /dev/null 2>&1 && _arc_running=true
        if [[ "$_arc_running" != "true" ]]; then
            safe_clean ~/Library/Application\ Support/Arc/*/Code\ Cache/* "Arc code cache"
            safe_clean ~/Library/Application\ Support/Arc/*/GPUCache/* "Arc GPU cache"
            safe_clean ~/Library/Application\ Support/Arc/*/DawnCache/* "Arc Dawn cache"
            safe_clean ~/Library/Application\ Support/Arc/*/GrShaderCache/* "Arc GR shader cache"
            safe_clean ~/Library/Application\ Support/Arc/*/GraphiteDawnCache/* "Arc Graphite Dawn cache"
            safe_clean ~/Library/Application\ Support/Arc/ShaderCache/* "Arc shader cache"
            safe_clean ~/Library/Application\ Support/Arc/GrShaderCache/* "Arc GR shader cache"
            safe_clean ~/Library/Application\ Support/Arc/GraphiteDawnCache/* "Arc Dawn cache"
            safe_clean ~/Library/Application\ Support/Arc/Crashpad/completed/* "Arc crash reports"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/*/Code\ Cache/* "Arc code cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/*/GPUCache/* "Arc GPU cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/*/DawnCache/* "Arc Dawn cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/*/GrShaderCache/* "Arc GR shader cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/*/GraphiteDawnCache/* "Arc Graphite Dawn cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/ShaderCache/* "Arc shader cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/GrShaderCache/* "Arc GR shader cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/GraphiteDawnCache/* "Arc Dawn cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/component_crx_cache/* "Arc component CRX cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/extensions_crx_cache/* "Arc extensions CRX cache"
            safe_clean ~/Library/Application\ Support/Arc/User\ Data/Crashpad/completed/* "Arc crash reports"
        fi
        for _arc_profile in "$HOME/Library/Application Support/Arc"/*/; do
            clean_service_worker_cache "Arc" "${_arc_profile%/}/Service Worker/CacheStorage"
        done
        for _arc_profile in "$HOME/Library/Application Support/Arc/User Data"/*/; do
            [[ -d "$_arc_profile" ]] || continue
            clean_service_worker_cache "Arc" "${_arc_profile%/}/Service Worker/CacheStorage"
        done
    fi
    # Dia Browser. company.thebrowser.dia only holds Sentry crash state; the real
    # caches are the Chromium ones under ~/Library/Caches/Dia/User Data (HTTP and
    # code cache) and ~/Library/Application Support/Dia/User Data (GPU and CRX
    # caches). Dia has no ShaderCache / GrShaderCache / DawnCache / Crashpad tree
    # like Arc, so those rows are intentionally absent.
    safe_clean ~/Library/Caches/company.thebrowser.dia/* "Dia cache"
    if [[ -d ~/Library/Application\ Support/Dia ]]; then
        local _dia_profile
        local _dia_process_state=2
        if command -v pgrep > /dev/null 2>&1; then
            if pgrep -x "Dia" > /dev/null 2>&1; then
                _dia_process_state=0
            else
                _dia_process_state=$?
            fi
        fi
        if [[ $_dia_process_state -eq 1 ]]; then
            safe_clean ~/Library/Caches/Dia/User\ Data/*/Cache/* "Dia HTTP cache"
            safe_clean ~/Library/Caches/Dia/User\ Data/*/Code\ Cache/* "Dia code cache"
            safe_clean ~/Library/Application\ Support/Dia/User\ Data/GraphiteDawnCache/* "Dia Graphite Dawn cache"
            safe_clean ~/Library/Application\ Support/Dia/User\ Data/GPUPersistentCache/* "Dia GPU cache"
            safe_clean ~/Library/Application\ Support/Dia/User\ Data/component_crx_cache/* "Dia component CRX cache"
            safe_clean ~/Library/Application\ Support/Dia/User\ Data/extensions_crx_cache/* "Dia extensions CRX cache"
            safe_clean ~/Library/Application\ Support/Dia/User\ Data/*/DawnGraphiteCache/* "Dia Dawn Graphite cache"
            safe_clean ~/Library/Application\ Support/Dia/User\ Data/*/DawnWebGPUCache/* "Dia Dawn WebGPU cache"
            safe_clean ~/Library/Application\ Support/Dia/User\ Data/*/GPUCache/* "Dia GPU cache"
        else
            local _dia_skip_reason="Dia running"
            [[ $_dia_process_state -gt 1 ]] && _dia_skip_reason="process state unknown"
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Dia Application Support cache · skipped ($_dia_skip_reason)"
            note_activity
        fi
        for _dia_profile in "$HOME/Library/Application Support/Dia/User Data"/*/; do
            [[ -d "$_dia_profile" ]] || continue
            clean_service_worker_cache "Dia" "${_dia_profile%/}/Service Worker/CacheStorage"
        done
    fi
    if [[ -d ~/Library/Application\ Support/BraveSoftware ]]; then
        safe_clean ~/Library/Caches/BraveSoftware/Brave-Browser/* "Brave cache"
        local _brave_profile
        local _brave_running=false
        pgrep -x "Brave Browser" > /dev/null 2>&1 && _brave_running=true
        if [[ "$_brave_running" != "true" ]]; then
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/Application\ Cache/* "Brave app cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/Code\ Cache/* "Brave code cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/GPUCache/* "Brave GPU cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/DawnCache/* "Brave Dawn cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/GrShaderCache/* "Brave GR shader cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/GraphiteDawnCache/* "Brave Graphite Dawn cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/component_crx_cache/* "Brave component CRX cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/ShaderCache/* "Brave shader cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/GrShaderCache/* "Brave GR shader cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/GraphiteDawnCache/* "Brave Dawn cache"
            safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/Crashpad/completed/* "Brave crash reports"
        fi
        for _brave_profile in "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"/*/; do
            clean_service_worker_cache "Brave" "${_brave_profile%/}/Service Worker/CacheStorage"
        done
    fi
    # Helium Browser.
    if [[ -d ~/Library/Application\ Support/net.imput.helium ]]; then
        safe_clean ~/Library/Caches/net.imput.helium/* "Helium cache"
        safe_clean ~/Library/Application\ Support/net.imput.helium/*/GPUCache/* "Helium GPU cache"
        safe_clean ~/Library/Application\ Support/net.imput.helium/component_crx_cache/* "Helium component cache"
        safe_clean ~/Library/Application\ Support/net.imput.helium/extensions_crx_cache/* "Helium extensions cache"
        safe_clean ~/Library/Application\ Support/net.imput.helium/GrShaderCache/* "Helium shader cache"
        safe_clean ~/Library/Application\ Support/net.imput.helium/GraphiteDawnCache/* "Helium Dawn cache"
        safe_clean ~/Library/Application\ Support/net.imput.helium/ShaderCache/* "Helium shader cache"
        safe_clean ~/Library/Application\ Support/net.imput.helium/*/Application\ Cache/* "Helium app cache"
    fi
    # Yandex Browser.
    if [[ -d ~/Library/Application\ Support/Yandex ]]; then
        safe_clean ~/Library/Caches/Yandex/YandexBrowser/* "Yandex cache"
        safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/ShaderCache/* "Yandex shader cache"
        safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/GrShaderCache/* "Yandex GR shader cache"
        safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/GraphiteDawnCache/* "Yandex Dawn cache"
        safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/*/GPUCache/* "Yandex GPU cache"
    fi
    local firefox_state=0
    _firefox_process_state || firefox_state=$?
    local firefox_cache_targets=false
    local firefox_profile_cache_targets=false
    mole_cleanup_targets_exist "$HOME/Library/Caches/Firefox"/* && firefox_cache_targets=true
    mole_cleanup_targets_exist "$HOME/Library/Application Support/Firefox/Profiles"/*/cache2/* && firefox_profile_cache_targets=true
    if [[ $firefox_state -eq 0 ]]; then
        if [[ "$firefox_cache_targets" == "true" || "$firefox_profile_cache_targets" == "true" ]]; then
            mole_defer_cleanup_family "Firefox"
        fi
    elif [[ $firefox_state -eq 1 ]]; then
        _clean_firefox_caches_guarded || true
    elif [[ "$firefox_cache_targets" == "true" || "$firefox_profile_cache_targets" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Firefox caches · skipped (process state unknown)"
        note_activity
    fi
    safe_clean ~/Library/Caches/com.operasoftware.Opera/* "Opera cache"
    # Vivaldi Browser.
    if [[ -d ~/Library/Application\ Support/Vivaldi ]]; then
        safe_clean ~/Library/Caches/com.vivaldi.Vivaldi/* "Vivaldi cache"
        local _vivaldi_profile
        local _vivaldi_running=false
        pgrep -x "Vivaldi" > /dev/null 2>&1 && _vivaldi_running=true
        if [[ "$_vivaldi_running" != "true" ]]; then
            safe_clean ~/Library/Application\ Support/Vivaldi/*/Code\ Cache/* "Vivaldi code cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/*/GPUCache/* "Vivaldi GPU cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/*/DawnCache/* "Vivaldi Dawn cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/*/GrShaderCache/* "Vivaldi GR shader cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/*/GraphiteDawnCache/* "Vivaldi Graphite Dawn cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/ShaderCache/* "Vivaldi shader cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/GrShaderCache/* "Vivaldi GR shader cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/GraphiteDawnCache/* "Vivaldi Dawn cache"
            safe_clean ~/Library/Application\ Support/Vivaldi/Crashpad/completed/* "Vivaldi crash reports"
        fi
        for _vivaldi_profile in "$HOME/Library/Application Support/Vivaldi"/*/; do
            clean_service_worker_cache "Vivaldi" "${_vivaldi_profile%/}/Service Worker/CacheStorage"
        done
    fi
    safe_clean ~/Library/Caches/Comet/* "Comet cache"
    safe_clean ~/Library/Caches/com.kagi.kagimacOS/* "Orion cache"
    safe_clean ~/Library/Caches/zen/* "Zen cache"
    clean_chrome_old_versions || return $?
    clean_edge_old_versions || return $?
    clean_edge_updater_old_versions || return $?
    clean_brave_old_versions || return $?
    # QQ Browser 3 (Chromium-based).
    if [[ -d ~/Library/Application\ Support/QQBrowser3 ]]; then
        safe_clean ~/Library/Caches/com.tencent.QQBrowser3/* "QQ Browser cache"
        local _qqbrowser_running=false
        pgrep -x "QQBrowser3" > /dev/null 2>&1 && _qqbrowser_running=true
        if [[ "$_qqbrowser_running" != "true" ]]; then
            safe_clean ~/Library/Application\ Support/QQBrowser3/*/Code\ Cache/* "QQ Browser code cache"
            safe_clean ~/Library/Application\ Support/QQBrowser3/*/GPUCache/* "QQ Browser GPU cache"
            safe_clean ~/Library/Application\ Support/QQBrowser3/ShaderCache/* "QQ Browser shader cache"
            safe_clean ~/Library/Application\ Support/QQBrowser3/GrShaderCache/* "QQ Browser GR shader cache"
            safe_clean ~/Library/Application\ Support/QQBrowser3/GraphiteDawnCache/* "QQ Browser Dawn cache"
            safe_clean ~/Library/Application\ Support/QQBrowser3/component_crx_cache/* "QQ Browser component cache"
            safe_clean ~/Library/Application\ Support/QQBrowser3/Crashpad/completed/* "QQ Browser crash reports"
        fi
    fi
}

# Cloud storage caches.
clean_cloud_storage() {
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] Cleaning cloud storage caches..." >&2
    fi
    local dropbox_state=0
    _dropbox_process_state || dropbox_state=$?
    if [[ $dropbox_state -eq 0 ]]; then
        if mole_cleanup_targets_exist \
            "$HOME/Library/Caches/com.getdropbox.dropbox" \
            "$HOME/Library/Caches"/com.dropbox.*; then
            mole_defer_cleanup_family "Dropbox"
        fi
    elif [[ $dropbox_state -eq 1 ]]; then
        _clean_dropbox_caches_guarded || true
    elif mole_cleanup_targets_exist \
        "$HOME/Library/Caches/com.getdropbox.dropbox" \
        "$HOME/Library/Caches"/com.dropbox.*; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Dropbox cache · skipped (process state unknown)"
        note_activity
    fi
    local google_drive_state=0
    _google_drive_process_state || google_drive_state=$?
    if [[ $google_drive_state -eq 0 ]]; then
        if mole_cleanup_targets_exist "$HOME/Library/Caches/com.google.GoogleDrive"; then
            mole_defer_cleanup_family "Google Drive"
        fi
    elif [[ $google_drive_state -eq 1 ]]; then
        _user_safe_clean_process_guarded \
            _google_drive_process_state \
            "Google Drive" \
            "Google Drive cache" \
            ~/Library/Caches/com.google.GoogleDrive \
            "Google Drive cache" || true
    elif mole_cleanup_targets_exist "$HOME/Library/Caches/com.google.GoogleDrive"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Google Drive cache · skipped (process state unknown)"
        note_activity
    fi
    safe_clean ~/Library/Caches/com.baidu.netdisk "Baidu Netdisk cache"
    safe_clean ~/Library/Caches/com.alibaba.teambitiondisk "Alibaba Cloud cache"
    safe_clean ~/Library/Caches/com.box.desktop "Box cache"
    local onedrive_state=0
    _onedrive_process_state || onedrive_state=$?
    if [[ $onedrive_state -eq 0 ]]; then
        if mole_cleanup_targets_exist "$HOME/Library/Caches/com.microsoft.OneDrive"; then
            mole_defer_cleanup_family "OneDrive"
        fi
    elif [[ $onedrive_state -eq 1 ]]; then
        _user_safe_clean_process_guarded \
            _onedrive_process_state \
            "OneDrive" \
            "OneDrive cache" \
            ~/Library/Caches/com.microsoft.OneDrive \
            "OneDrive cache" || true
    elif mole_cleanup_targets_exist "$HOME/Library/Caches/com.microsoft.OneDrive"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} OneDrive cache · skipped (process state unknown)"
        note_activity
    fi
}

# Office app caches.
clean_office_applications() {
    # Bound every explicit Office App Container probe as one section.
    local _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=""
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] Cleaning office application caches..." >&2
    fi
    safe_clean ~/Library/Caches/com.microsoft.Word "Microsoft Word cache"
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] Cleaning Word container cache..." >&2
    fi
    safe_clean ~/Library/Containers/com.microsoft.Word/Data/Library/Caches/* "Microsoft Word container cache"
    safe_clean ~/Library/Containers/com.microsoft.Word/Data/tmp/* "Microsoft Word temp files"
    safe_clean ~/Library/Containers/com.microsoft.Word/Data/Library/Logs/* "Microsoft Word container logs"
    safe_clean ~/Library/Caches/com.microsoft.Excel "Microsoft Excel cache"
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] Cleaning Excel container cache..." >&2
    fi
    safe_clean ~/Library/Containers/com.microsoft.Excel/Data/Library/Caches/* "Microsoft Excel container cache"
    safe_clean ~/Library/Containers/com.microsoft.Excel/Data/tmp/* "Microsoft Excel temp files"
    safe_clean ~/Library/Containers/com.microsoft.Excel/Data/Library/Logs/* "Microsoft Excel container logs"
    safe_clean ~/Library/Caches/com.microsoft.Powerpoint "Microsoft PowerPoint cache"
    safe_clean ~/Library/Caches/com.microsoft.Outlook/* "Microsoft Outlook cache"
    safe_clean ~/Library/Caches/com.apple.iWork.* "Apple iWork cache"
    safe_clean ~/Library/Caches/com.kingsoft.wpsoffice.mac "WPS Office cache"
    safe_clean ~/Library/Caches/org.mozilla.thunderbird/* "Thunderbird cache"
    safe_clean ~/Library/Caches/com.apple.mail/* "Apple Mail cache"
}

# Virtualization caches.
clean_utm_caches() {
    local _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=""
    if pgrep -x "UTM" > /dev/null 2>&1; then
        debug_log "Skipping UTM caches while UTM is running"
        return 0
    fi

    safe_clean ~/Library/Caches/com.utmapp.UTM/* "UTM app cache"
    safe_clean ~/Library/Containers/com.utmapp.UTM/Data/Library/Caches/* "UTM sandbox cache"
    safe_clean ~/Library/Containers/com.utmapp.UTM/Data/tmp/* "UTM temporary files"
}

clean_tart_caches() {
    local cache_root="$HOME/.tart/cache"
    [[ -d "$cache_root" ]] || return 0
    command -v tart > /dev/null 2>&1 || return 0

    local cache_size_kb=0
    local size_rc=0
    cache_size_kb=$(get_path_size_kb "$cache_root" 2> /dev/null) || size_rc=$?
    [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
    [[ $size_rc -eq 0 ]] || return "$size_rc"
    [[ "$cache_size_kb" =~ ^[0-9]+$ ]] || cache_size_kb=0
    [[ "$cache_size_kb" -gt 0 ]] || return 0

    if is_path_whitelisted "$cache_root"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Tart caches · would skip (whitelist)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Tart caches · skipped (whitelist)"
        fi
        note_activity
        return 0
    fi

    local tart_state=0
    mole_pgrep_any -x "tart" || tart_state=$?
    if [[ $tart_state -ne 1 ]]; then
        if [[ $tart_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Tart caches · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Tart"
        fi
        return 0
    fi

    local cache_size_human
    cache_size_human=$(bytes_to_human "$((cache_size_kb * 1024))")
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Tart caches · would prune items older than ${MOLE_ORPHAN_AGE_DAYS} days (${cache_size_human})"
        echo -e "    ${GRAY}tart prune --entries caches --older-than ${MOLE_ORPHAN_AGE_DAYS}${NC}"
        note_activity
        return 0
    fi

    if [[ -t 1 ]]; then
        start_section_spinner "Pruning Tart caches..."
    fi
    local prune_succeeded=false
    tart_state=0
    mole_pgrep_any -x "tart" || tart_state=$?
    if [[ $tart_state -ne 1 ]]; then
        [[ -t 1 ]] && stop_section_spinner
        if [[ $tart_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Tart caches · stopped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Tart"
        fi
        return 0
    elif run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" tart prune --entries caches --older-than "$MOLE_ORPHAN_AGE_DAYS" > /dev/null 2>&1; then
        prune_succeeded=true
    fi
    if [[ -t 1 ]]; then
        stop_section_spinner
    fi

    if [[ "$prune_succeeded" != "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Tart caches · prune failed"
        debug_log "tart prune failed for cache-only ${MOLE_ORPHAN_AGE_DAYS}-day policy"
        note_activity
        return 0
    fi

    local remaining_kb=0
    size_rc=0
    remaining_kb=$(get_path_size_kb "$cache_root" 2> /dev/null) || size_rc=$?
    [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
    [[ $size_rc -eq 0 ]] || return "$size_rc"
    [[ "$remaining_kb" =~ ^[0-9]+$ ]] || remaining_kb=0
    local reclaimed_kb=$((cache_size_kb - remaining_kb))
    [[ "$reclaimed_kb" -ge 0 ]] || reclaimed_kb=0

    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Tart caches · pruned, $(bytes_to_human "$((reclaimed_kb * 1024))") reclaimed"
    note_activity
}

clean_virtualization_tools() {
    stop_section_spinner
    safe_clean ~/Library/Caches/com.vmware.fusion "VMware Fusion cache"
    safe_clean ~/Library/Caches/com.parallels.* "Parallels cache"
    clean_utm_caches
    safe_clean ~/VirtualBox\ VMs/.cache "VirtualBox cache"
    safe_clean ~/Library/Caches/lima/download/by-url-sha256/* "Lima download cache"
    safe_clean ~/.vagrant.d/tmp/* "Vagrant temporary files"
    clean_tart_caches
}

# Estimate item size for Application Support cleanup.
# Files use stat; directories use du with timeout to avoid long blocking scans.
app_support_entry_count_capped() {
    local dir="$1"
    local maxdepth="${2:-1}"
    local cap="${3:-101}"
    local count=0

    while IFS= read -r -d '' _entry; do
        count=$((count + 1))
        if ((count >= cap)); then
            break
        fi
    done < <(command find "$dir" -mindepth 1 -maxdepth "$maxdepth" -print0 2> /dev/null)

    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "$count"
}

app_support_item_size_bytes() {
    local item="$1"
    local timeout_seconds="${2:-0.4}"

    if [[ -f "$item" && ! -L "$item" ]]; then
        local file_bytes
        file_bytes=$(stat -f%z "$item" 2> /dev/null || echo "0")
        [[ "$file_bytes" =~ ^[0-9]+$ ]] || return 1
        printf '%s\n' "$file_bytes"
        return 0
    fi

    if [[ -d "$item" && ! -L "$item" ]]; then
        # Fast path: if directory has too many items, skip detailed size calculation
        # to avoid hanging on deep directories (e.g., node_modules, .git)
        local item_count
        item_count=$(app_support_entry_count_capped "$item" 2 10001)
        if [[ "$item_count" -gt 10000 ]]; then
            # Return 1 to signal "too many items, size unknown"
            return 1
        fi

        local du_output
        # Use stricter timeout for directories
        if ! du_output=$(run_with_timeout "$timeout_seconds" du -skP "$item" 2> /dev/null); then
            return 1
        fi

        local size_kb="${du_output%%[^0-9]*}"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || return 1
        printf '%s\n' "$((size_kb * 1024))"
        return 0
    fi

    return 1
}

app_support_dir_has_regenerable_cache_markers() {
    local app_dir="$1"
    local marker

    for marker in \
        "$app_dir/Code Cache" \
        "$app_dir/GPUCache" \
        "$app_dir/DawnCache" \
        "$app_dir/GrShaderCache" \
        "$app_dir/GraphiteDawnCache" \
        "$app_dir/DawnGraphiteCache" \
        "$app_dir/DawnWebGPUCache" \
        "$app_dir/Crashpad"; do
        [[ -e "$marker" ]] && return 0
    done

    return 1
}

# Application Support logs/caches.
clean_application_support_logs() {
    if [[ ! -d "$HOME/Library/Application Support" ]] || ! ls "$HOME/Library/Application Support" > /dev/null 2>&1; then
        note_activity
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipped: No permission to access Application Support"
        return 0
    fi
    start_section_spinner "Scanning Application Support..."
    local total_size_bytes=0
    local total_size_partial=false
    local cleaned_count=0
    local found_any=false
    local size_timeout_seconds="${MOLE_APP_SUPPORT_ITEM_SIZE_TIMEOUT_SEC:-0.4}"
    if [[ ! "$size_timeout_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        size_timeout_seconds=0.4
    fi
    # Enable nullglob for safe globbing.
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob
    local app_count=0
    local total_apps
    # Temporarily disable pipefail here so that a partial find failure (e.g. TCC
    # restrictions on macOS 26+) does not propagate through the pipeline and abort
    # the whole scan via set -e.
    local pipefail_was_set=false
    if [[ -o pipefail ]]; then
        pipefail_was_set=true
        set +o pipefail
    fi
    total_apps=$(command find "$HOME/Library/Application Support" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l | tr -d ' ')
    [[ "$total_apps" =~ ^[0-9]+$ ]] || total_apps=0
    local last_progress_update
    last_progress_update=$(get_epoch_seconds)
    for app_dir in ~/Library/Application\ Support/*; do
        [[ -d "$app_dir" ]] || continue
        local app_name="${app_dir##*/}"
        app_count=$((app_count + 1))
        update_progress_if_needed "$app_count" "$total_apps" last_progress_update 1 || true
        local is_protected=false
        if is_path_whitelisted "$app_dir" 2> /dev/null; then
            is_protected=true
        elif should_protect_path "$app_dir" 2> /dev/null; then
            is_protected=true
        elif should_protect_data "$app_name"; then
            is_protected=true
        else
            local app_name_lower
            app_name_lower=$(echo "$app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            if should_protect_data "$app_name_lower"; then
                is_protected=true
            fi
        fi
        if [[ "$is_protected" == "true" ]]; then
            continue
        fi
        if is_critical_system_component "$app_name"; then
            continue
        fi
        # Application Support can hold licenses, databases, offline assets and
        # session state. Keep this generic pass to explicit, regenerable cache
        # subtrees only; app-specific log/cache cleanup belongs in allowlisted
        # app modules above.
        local -a start_candidates=(
            "$app_dir/Code Cache"
            "$app_dir/GPUCache"
            "$app_dir/DawnCache"
            "$app_dir/GrShaderCache"
            "$app_dir/GraphiteDawnCache"
            "$app_dir/DawnGraphiteCache"
            "$app_dir/DawnWebGPUCache"
            "$app_dir/Crashpad/completed"
        )
        if app_support_dir_has_regenerable_cache_markers "$app_dir"; then
            start_candidates+=(
                "$app_dir/Cache"
                "$app_dir/CachedData"
            )
        fi
        for candidate in "${start_candidates[@]}"; do
            if [[ -d "$candidate" ]]; then
                if should_protect_path "$candidate" 2> /dev/null || is_path_whitelisted "$candidate" 2> /dev/null; then
                    continue
                fi
                # Quick count check - skip if too many items to avoid hanging
                local quick_count
                quick_count=$(app_support_entry_count_capped "$candidate" 1 101)
                if [[ "$quick_count" -gt 100 ]]; then
                    # Too many items - use bulk removal instead of item-by-item
                    local app_label="$app_name"
                    if [[ ${#app_label} -gt 24 ]]; then
                        app_label="${app_label:0:21}..."
                    fi
                    stop_section_spinner
                    start_section_spinner "Scanning Application Support... $app_count/$total_apps [$app_label, bulk clean]"
                    if [[ "$DRY_RUN" == "true" ]]; then
                        if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                            record_dry_run_cleanup_target "$candidate" 0 1 false || continue
                        fi
                    else
                        # Remove entire candidate directory in one go
                        safe_remove "$candidate" true > /dev/null 2>&1 || true
                    fi
                    found_any=true
                    cleaned_count=$((cleaned_count + 1))
                    total_size_partial=true
                    continue
                fi

                local item_found=false
                local candidate_size_bytes=0
                local candidate_size_partial=false
                local candidate_item_count=0
                while IFS= read -r -d '' item; do
                    [[ -e "$item" ]] || continue
                    if should_protect_path "$item" 2> /dev/null || is_path_whitelisted "$item" 2> /dev/null; then
                        continue
                    fi
                    local item_size_known=false
                    local item_size_kb=0
                    local item_size_bytes=""
                    if [[ ! -L "$item" && (-f "$item" || -d "$item") ]]; then
                        if item_size_bytes=$(app_support_item_size_bytes "$item" "$size_timeout_seconds"); then
                            if [[ "$item_size_bytes" =~ ^[0-9]+$ ]]; then
                                item_size_kb=$(((item_size_bytes + 1023) / 1024))
                                item_size_known=true
                            else
                                candidate_size_partial=true
                            fi
                        else
                            candidate_size_partial=true
                        fi
                    fi
                    if [[ "$DRY_RUN" == "true" ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                        record_dry_run_cleanup_target "$item" "$item_size_kb" 1 "$item_size_known" || continue
                    fi
                    if [[ "$item_size_known" == "true" ]]; then
                        candidate_size_bytes=$((candidate_size_bytes + item_size_bytes))
                    fi
                    item_found=true
                    candidate_item_count=$((candidate_item_count + 1))
                    if ((candidate_item_count % 250 == 0)); then
                        local current_time
                        current_time=$(get_epoch_seconds)
                        if [[ "$current_time" =~ ^[0-9]+$ ]] && ((current_time - last_progress_update >= 1)); then
                            local app_label="$app_name"
                            if [[ ${#app_label} -gt 24 ]]; then
                                app_label="${app_label:0:21}..."
                            fi
                            stop_section_spinner
                            start_section_spinner "Scanning Application Support... $app_count/$total_apps [$app_label, $candidate_item_count items]"
                            last_progress_update=$current_time
                        fi
                    fi
                    if [[ "$DRY_RUN" != "true" ]]; then
                        if [[ "$item_size_known" == "true" ]]; then
                            safe_remove "$item" true "$item_size_kb" > /dev/null 2>&1 || true
                        else
                            safe_remove "$item" true > /dev/null 2>&1 || true
                        fi
                    fi
                done < <(command find "$candidate" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
                if [[ "$item_found" == "true" ]]; then
                    total_size_bytes=$((total_size_bytes + candidate_size_bytes))
                    [[ "$candidate_size_partial" == "true" ]] && total_size_partial=true
                    cleaned_count=$((cleaned_count + 1))
                    found_any=true
                fi
            fi
        done
    done
    # Group Containers logs (explicit allowlist).
    local known_group_containers=(
        "group.com.apple.contentdelivery"
    )
    for container in "${known_group_containers[@]}"; do
        local container_path="$HOME/Library/Group Containers/$container"
        local -a gc_candidates=("$container_path/Logs" "$container_path/Library/Logs")
        for candidate in "${gc_candidates[@]}"; do
            if [[ -d "$candidate" ]]; then
                # Quick count check - skip if too many items
                local quick_count
                quick_count=$(app_support_entry_count_capped "$candidate" 1 101)
                if [[ "$quick_count" -gt 100 ]]; then
                    local container_label="$container"
                    if [[ ${#container_label} -gt 24 ]]; then
                        container_label="${container_label:0:21}..."
                    fi
                    stop_section_spinner
                    start_section_spinner "Scanning Application Support... group [$container_label, bulk clean]"
                    if [[ "$DRY_RUN" == "true" ]]; then
                        if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                            record_dry_run_cleanup_target "$candidate" 0 1 false || continue
                        fi
                    else
                        safe_remove "$candidate" true > /dev/null 2>&1 || true
                    fi
                    found_any=true
                    cleaned_count=$((cleaned_count + 1))
                    total_size_partial=true
                    continue
                fi

                local item_found=false
                local candidate_size_bytes=0
                local candidate_size_partial=false
                local candidate_item_count=0
                while IFS= read -r -d '' item; do
                    [[ -e "$item" ]] || continue
                    local item_size_known=false
                    local item_size_kb=0
                    local item_size_bytes=""
                    if [[ ! -L "$item" && (-f "$item" || -d "$item") ]]; then
                        if item_size_bytes=$(app_support_item_size_bytes "$item" "$size_timeout_seconds"); then
                            if [[ "$item_size_bytes" =~ ^[0-9]+$ ]]; then
                                item_size_kb=$(((item_size_bytes + 1023) / 1024))
                                item_size_known=true
                            else
                                candidate_size_partial=true
                            fi
                        else
                            candidate_size_partial=true
                        fi
                    fi
                    if [[ "$DRY_RUN" == "true" ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                        record_dry_run_cleanup_target "$item" "$item_size_kb" 1 "$item_size_known" || continue
                    fi
                    if [[ "$item_size_known" == "true" ]]; then
                        candidate_size_bytes=$((candidate_size_bytes + item_size_bytes))
                    fi
                    item_found=true
                    candidate_item_count=$((candidate_item_count + 1))
                    if ((candidate_item_count % 250 == 0)); then
                        local current_time
                        current_time=$(get_epoch_seconds)
                        if [[ "$current_time" =~ ^[0-9]+$ ]] && ((current_time - last_progress_update >= 1)); then
                            local container_label="$container"
                            if [[ ${#container_label} -gt 24 ]]; then
                                container_label="${container_label:0:21}..."
                            fi
                            stop_section_spinner
                            start_section_spinner "Scanning Application Support... group [$container_label, $candidate_item_count items]"
                            last_progress_update=$current_time
                        fi
                    fi
                    if [[ "$DRY_RUN" != "true" ]]; then
                        if [[ "$item_size_known" == "true" ]]; then
                            safe_remove "$item" true "$item_size_kb" > /dev/null 2>&1 || true
                        else
                            safe_remove "$item" true > /dev/null 2>&1 || true
                        fi
                    fi
                done < <(command find "$candidate" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
                if [[ "$item_found" == "true" ]]; then
                    total_size_bytes=$((total_size_bytes + candidate_size_bytes))
                    [[ "$candidate_size_partial" == "true" ]] && total_size_partial=true
                    cleaned_count=$((cleaned_count + 1))
                    found_any=true
                fi
            fi
        done
    done
    # Restore pipefail if it was previously set
    if [[ "$pipefail_was_set" == "true" ]]; then
        set -o pipefail
    fi
    # eval: restore shopt state captured by $(shopt -p)
    eval "$_ng_state"
    stop_section_spinner
    if [[ "$found_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$total_size_bytes")
        local total_size_kb=$(((total_size_bytes + 1023) / 1024))
        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$total_size_partial" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Application Support logs/caches${NC} · ${YELLOW}at least $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
            else
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Application Support logs/caches${NC} · $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
            fi
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size_kb")
            if [[ "$total_size_partial" == "true" ]]; then
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} Application Support logs/caches${NC} · ${line_color}at least $size_human${NC}"
            else
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} Application Support logs/caches${NC} · ${line_color}$size_human${NC}"
            fi
        fi
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
}
# Remove cached device firmware (.ipsw) from iTunes, Finder, and Apple Configurator 2.
# These are installers for firmware already applied (or superseded); macOS will
# re-download them on demand. Typical size: 5-8GB per file. Never touches backups.
clean_cached_device_firmware() {
    local -a shallow_dirs=(
        "$HOME/Library/iTunes/iPhone Software Updates"
        "$HOME/Library/iTunes/iPad Software Updates"
        "$HOME/Library/iTunes/iPod Software Updates"
    )

    # Apple Configurator 2 nests firmware under per-team-id group containers.
    local -a configurator_dirs=()
    local gc
    for gc in "$HOME/Library/Group Containers"/*.group.com.apple.configurator; do
        [[ -d "$gc" ]] || continue
        configurator_dirs+=("$gc")
    done

    local cleaned_count=0
    local total_size_kb=0
    local cleaned_any=false

    _process_ipsw_file() {
        local ipsw="$1"
        [[ -f "$ipsw" ]] || return 0
        if is_path_whitelisted "$ipsw"; then
            return 0
        fi
        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$ipsw") || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        size_kb="${size_kb:-0}"
        if [[ "$DRY_RUN" == "true" ]]; then
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$ipsw" "$size_kb" 1 true || return 0
            fi
            total_size_kb=$((total_size_kb + size_kb))
            cleaned_count=$((cleaned_count + 1))
            cleaned_any=true
            return 0
        fi

        if safe_remove "$ipsw" true > /dev/null 2>&1; then
            total_size_kb=$((total_size_kb + size_kb))
            cleaned_count=$((cleaned_count + 1))
            cleaned_any=true
        fi
    }

    local dir ipsw
    for dir in "${shallow_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' ipsw; do
            _process_ipsw_file "$ipsw" || return $?
        done < <(command find "$dir" -maxdepth 1 -type f -name "*.ipsw" -print0 2> /dev/null)
    done

    if [[ ${#configurator_dirs[@]} -gt 0 ]]; then
        for dir in "${configurator_dirs[@]}"; do
            [[ -d "$dir" ]] || continue
            while IFS= read -r -d '' ipsw; do
                _process_ipsw_file "$ipsw" || return $?
            done < <(command find "$dir" -type f -name "*.ipsw" -print0 2> /dev/null)
        done
    fi

    unset -f _process_ipsw_file

    if [[ "$cleaned_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size_kb * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Cached device firmware${NC} · ${YELLOW}${cleaned_count} files, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Cached device firmware${NC} · ${line_color}${cleaned_count} files, $size_human${NC}"
        fi
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
}

# List JetBrains per-version data dirs that are not the newest version of
# their IDE (e.g. GoLand2025.1 when GoLand2025.2 exists). Prints one dir name
# per line; never prints the newest version, unversioned dirs, or Toolbox.
# Data source for the review-only large-dir report (#1179).
jetbrains_stale_version_dirs() {
    local jetbrains_support="$1"
    [[ -d "$jetbrains_support" ]] || return 0
    command find "$jetbrains_support" -mindepth 1 -maxdepth 1 -type d 2> /dev/null |
        awk -F'/' '
            {
                name = $NF
                if (match(name, /[0-9][0-9][0-9][0-9]\.[0-9]+$/) && RSTART > 1) {
                    base = substr(name, 1, RSTART - 1)
                    split(substr(name, RSTART), v, ".")
                    key = v[1] * 100 + v[2]
                    n[base]++
                    names[base, n[base]] = name
                    keys[base, n[base]] = key
                    if (key > maxk[base]) maxk[base] = key
                }
            }
            END {
                for (b in n)
                    for (i = 1; i <= n[b]; i++)
                        if (keys[b, i] < maxk[b]) print names[b, i]
            }
        '
}

# AI coding agents (Claude Code and similar) create full checkouts under
# <project>/.claude/worktrees/ that accumulate silently across repos. Report
# only, same 1GB bar as other large candidates; removal stays a manual
# `git worktree remove` decision because a worktree may hold agent work.
report_agent_worktree_candidates() {
    local threshold_kb=$((1024 * 1024)) # 1GB
    local -a roots=(
        "$HOME/code" "$HOME/Code" "$HOME/dev" "$HOME/Projects"
        "$HOME/GitHub" "$HOME/Workspace" "$HOME/Repos"
        "$HOME/Development" "$HOME/www" "$HOME/src"
    )
    local root container size_kb size_rc
    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' container; do
            size_rc=0
            size_kb=$(get_path_size_kb "$container" 2> /dev/null) || size_rc=$?
            [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
            [[ $size_rc -eq 0 ]] || return "$size_rc"
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            [[ "$size_kb" -ge "$threshold_kb" ]] || continue
            echo -e "  ${YELLOW}${ICON_REVIEW}${NC} AI agent worktrees · ${GREEN}$(bytes_to_human "$((size_kb * 1024))")${NC} · ${GRAY}$(format_path_link "$container")${NC}"
            note_activity
        done < <(run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" command find "$root" -maxdepth 6 -type d -path "*/.claude/worktrees" -prune -print0 2> /dev/null)
    done
    return 0
}

# Large file candidates (report only, no deletion).
check_large_file_candidates() {
    local threshold_kb=$((1024 * 1024)) # 1GB
    local found_any=false
    local size_rc=0

    _large_candidate_size_kb() {
        local path="$1"
        local timeout_seconds="${2:-${MOLE_LARGE_CANDIDATE_SIZE_TIMEOUT:-3}}"
        [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=3
        local du_output=""
        du_output=$(run_with_timeout "$timeout_seconds" du -skP "$path" 2> /dev/null || true)
        local size_kb="${du_output%%[^0-9]*}"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || return 1
        printf '%s\n' "$size_kb"
    }

    # Date of the newest immediate child. Only for rows holding irreplaceable
    # data that goes stale, where size alone cannot decide: 100GB of last
    # month's phone backup is the only copy of that phone, and 100GB from a
    # device sold two years ago is dead weight. Rebuildable caches get no date
    # because their age never changes the answer.
    # One bounded command, materialized whole: a partial listing would report
    # an older date than the truth, which is worse than reporting none. On
    # timeout or any nonzero status the row falls back to no date.
    _large_dir_newest_date() {
        local path="$1"
        local mtimes="" newest=""
        mtimes=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" \
            command find "$path" -mindepth 1 -maxdepth 1 -exec stat -f '%m' {} + 2> /dev/null) || return 1
        [[ -n "$mtimes" ]] || return 1
        newest=$(printf '%s\n' "$mtimes" | sort -n | tail -1)
        [[ "$newest" =~ ^[0-9]+$ ]] || return 1
        date -r "$newest" '+%Y-%m-%d' 2> /dev/null || return 1
    }

    # One row per large item: "label · size · path", with an optional date
    # between size and path. Bare date, no leading word: it sits right after a
    # short size field, so it lands in a stable column and reads as a date on
    # its own. The review icon carries the review-only semantics;
    # format_path_link keeps the path clickable even with spaces (OSC 8 link,
    # not terminal auto-linking).
    _report_large_review_row() {
        local label="$1"
        local size_human="$2"
        local path="$3"
        local newest_date="${4:-}"
        local date_part=""
        [[ -n "$newest_date" ]] && date_part=" · ${GRAY}${newest_date}${NC}"
        stop_section_spinner
        echo -e "  ${YELLOW}${ICON_REVIEW}${NC} ${label} · ${GREEN}${size_human}${NC}${date_part} · ${GRAY}$(format_path_link "$path")${NC}"
        found_any=true
        start_section_spinner "Scanning large files..."
    }

    # Pass "date" as $4 on rows where staleness decides the action. Rows left
    # without it stay two fields wide.
    _report_large_review_dir() {
        local label="$1"
        local path="$2"
        local probe_timeout="${3:-}"
        local want_date="${4:-}"
        [[ -d "$path" ]] || return 0
        local size_kb=""
        size_kb=$(_large_candidate_size_kb "$path" "$probe_timeout") || return 0
        [[ "$size_kb" -ge "$threshold_kb" ]] || return 0
        local size_human
        size_human=$(bytes_to_human "$((size_kb * 1024))")
        local detail=""
        if [[ "$want_date" == "date" ]]; then
            detail=$(_large_dir_newest_date "$path") || detail=""
        fi
        _report_large_review_row "$label" "$size_human" "$path" "$detail"
    }

    # The du probes below (Mail, backups, package stores) take seconds in
    # total; keep loading feedback on screen between rows.
    start_section_spinner "Scanning large files..."

    local mail_dir="$HOME/Library/Mail"
    if [[ -d "$mail_dir" ]]; then
        local mail_kb
        size_rc=0
        mail_kb=$(get_path_size_kb "$mail_dir") || size_rc=$?
        if [[ $size_rc -ne 0 ]]; then
            _mole_record_clean_cancellation "$size_rc"
            stop_section_spinner
            return "$size_rc"
        fi
        if [[ "$mail_kb" -ge "$threshold_kb" ]]; then
            local mail_human
            mail_human=$(bytes_to_human "$((mail_kb * 1024))")
            _report_large_review_row "Mail data" "$mail_human" "$mail_dir"
        fi
    fi

    local mail_downloads="$HOME/Library/Mail Downloads"
    if [[ -d "$mail_downloads" ]]; then
        local downloads_kb
        size_rc=0
        downloads_kb=$(get_path_size_kb "$mail_downloads") || size_rc=$?
        if [[ $size_rc -ne 0 ]]; then
            _mole_record_clean_cancellation "$size_rc"
            stop_section_spinner
            return "$size_rc"
        fi
        if [[ "$downloads_kb" -ge "$threshold_kb" ]]; then
            local downloads_human
            downloads_human=$(bytes_to_human "$((downloads_kb * 1024))")
            _report_large_review_row "Mail downloads" "$downloads_human" "$mail_downloads"
        fi
    fi

    local installer_path
    for installer_path in /Applications/Install\ macOS*.app; do
        if [[ -e "$installer_path" ]]; then
            local installer_kb
            size_rc=0
            installer_kb=$(get_path_size_kb "$installer_path") || size_rc=$?
            if [[ $size_rc -ne 0 ]]; then
                _mole_record_clean_cancellation "$size_rc"
                stop_section_spinner
                return "$size_rc"
            fi
            if [[ "$installer_kb" -gt 0 ]]; then
                local installer_human
                installer_human=$(bytes_to_human "$((installer_kb * 1024))")
                _report_large_review_row "macOS installer" "$installer_human" "$installer_path"
            fi
        fi
    done

    local updates_dir="$HOME/Library/Updates"
    if [[ -d "$updates_dir" ]]; then
        local updates_kb
        size_rc=0
        updates_kb=$(get_path_size_kb "$updates_dir") || size_rc=$?
        if [[ $size_rc -ne 0 ]]; then
            _mole_record_clean_cancellation "$size_rc"
            stop_section_spinner
            return "$size_rc"
        fi
        if [[ "$updates_kb" -ge "$threshold_kb" ]]; then
            local updates_human
            updates_human=$(bytes_to_human "$((updates_kb * 1024))")
            _report_large_review_row "macOS updates cache" "$updates_human" "$updates_dir"
        fi
    fi

    if [[ "${SYSTEM_CLEAN:-false}" != "true" ]] && command -v tmutil > /dev/null 2>&1 &&
        defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        local snapshot_list snapshot_count
        snapshot_list=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" tmutil listlocalsnapshots / 2> /dev/null || true)
        if [[ -n "$snapshot_list" ]]; then
            snapshot_count=$(echo "$snapshot_list" | { grep -Eo 'com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true; } | wc -l | awk '{print $1}')
            if [[ "$snapshot_count" =~ ^[0-9]+$ && "$snapshot_count" -gt 0 ]]; then
                stop_section_spinner
                echo -e "  ${YELLOW}${ICON_REVIEW}${NC} Time Machine local snapshots · ${GREEN}${snapshot_count}${NC}"
                found_any=true
                start_section_spinner "Scanning large files..."
            fi
        fi
    fi

    local docker_reported=false
    if command -v docker > /dev/null 2>&1; then
        local docker_output
        docker_output=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2> /dev/null || true)
        if [[ -n "$docker_output" ]]; then
            local docker_detail=""
            while IFS=$'\t' read -r dtype dsize dreclaim; do
                [[ -z "$dtype" ]] && continue
                docker_detail+="${docker_detail:+ · }${dtype} ${dsize} (${dreclaim} reclaimable)"
            done <<< "$docker_output"
            if [[ -n "$docker_detail" ]]; then
                stop_section_spinner
                echo -e "  ${YELLOW}${ICON_REVIEW}${NC} Docker storage · ${GRAY}${docker_detail}${NC}"
                found_any=true
                docker_reported=true
                start_section_spinner "Scanning large files..."
            fi
        else
            docker_output=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" docker system df 2> /dev/null || true)
            if [[ -n "$docker_output" ]]; then
                stop_section_spinner
                echo -e "  ${YELLOW}${ICON_REVIEW}${NC} Docker storage · ${GRAY}docker system df${NC}"
                found_any=true
                docker_reported=true
                start_section_spinner "Scanning large files..."
            fi
        fi
    fi

    _report_large_review_dir "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"
    # Archives hold the dSYMs that symbolicate crashes from shipped builds, so
    # the newest date separates the releases still worth keeping from repeated
    # export attempts left behind on one afternoon.
    _report_large_review_dir "Xcode archives" "$HOME/Library/Developer/Xcode/Archives" "" "date"
    _report_large_review_dir "Simulator data" "$HOME/Library/Developer/CoreSimulator/Devices"
    if [[ "$docker_reported" != "true" ]]; then
        _report_large_review_dir "Docker Desktop data" "$HOME/Library/Containers/com.docker.docker/Data"
    fi
    # Device backups reach 100GB+ with millions of small files; the default
    # 3s du budget times out cold and silently drops the most valuable row,
    # so give this probe the hint-scan budget instead.
    _report_large_review_dir "iOS backups" "$HOME/Library/Application Support/MobileSync/Backup" "$MOLE_TIMEOUT_HINT_SCAN_SEC" "date"
    _report_large_review_dir "LM Studio models" "$HOME/.lmstudio/models"
    local orbstack_data
    for orbstack_data in "$HOME"/Library/Group\ Containers/*dev.orbstack/data "$HOME/OrbStack"; do
        _report_large_review_dir "OrbStack data" "$orbstack_data"
    done
    _report_large_review_dir "Lima data" "$HOME/.lima"
    _report_large_review_dir "Maven local repository" "$HOME/.m2/repository"
    _report_large_review_dir "Ivy local repository" "$HOME/.ivy2/cache"
    _report_large_review_dir "NuGet packages" "$HOME/.nuget/packages"
    local deno_module_cache=""
    if deno_module_cache=$(mole_deno_cache_root 2> /dev/null); then
        _report_large_review_dir "Deno module cache" "$deno_module_cache"
    fi
    _report_large_review_dir "pnpm store" "$HOME/Library/pnpm/store"
    _report_large_review_dir "Conda packages" "$HOME/.conda/pkgs"
    _report_large_review_dir "Anaconda packages" "$HOME/anaconda3/pkgs"

    # JetBrains keeps one data dir per IDE version (GoLand2025.1, ...). After
    # an upgrade the previous version's dir lingers forever with plugins and
    # settings inside. Report every dir that is not the newest version of its
    # IDE, review-only: these enable downgrades and must never be auto-deleted
    # (#1179).
    local jetbrains_support="$HOME/Library/Application Support/JetBrains"
    local jb_stale
    while IFS= read -r jb_stale; do
        [[ -n "$jb_stale" ]] || continue
        _report_large_review_dir "JetBrains old version data" "$jetbrains_support/$jb_stale"
    done < <(jetbrains_stale_version_dirs "$jetbrains_support")

    report_agent_worktree_candidates

    stop_section_spinner

    unset -f _large_candidate_size_kb _large_dir_newest_date _report_large_review_dir _report_large_review_row

    # Only mark activity when something was reported so an empty section can
    # collapse instead of printing a reassurance row.
    if [[ "$found_any" == "true" ]]; then
        note_activity
    else
        debug_log "Large files: no candidates above threshold"
    fi
    return 0
}

# Apple Silicon specific caches (IS_M_SERIES).
clean_apple_silicon_caches() {
    if [[ "${IS_M_SERIES:-false}" != "true" ]]; then
        return 0
    fi
    start_section "Apple Silicon updates"
    safe_clean /Library/Apple/usr/share/rosetta/rosetta_update_bundle "Rosetta 2 cache"
    safe_clean ~/Library/Caches/com.apple.rosetta.update "Rosetta 2 user cache"
    safe_clean ~/Library/Caches/com.apple.amp.mediasevicesd "Apple Silicon media service cache"
    end_section
}
