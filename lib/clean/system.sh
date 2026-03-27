#!/bin/bash
# System-Level Cleanup Module (requires sudo).
set -euo pipefail
# System caches, logs, and temp files.
clean_deep_system() {
    stop_section_spinner
    local cache_cleaned=0
    start_section_spinner "Cleaning system caches..."
    # Optimized: Single pass for /Library/Caches (3 patterns in 1 scan)
    if sudo test -d "/Library/Caches" 2> /dev/null; then
        while IFS= read -r -d '' file; do
            if should_protect_path "$file"; then
                continue
            fi
            if safe_sudo_remove "$file"; then
                cache_cleaned=1
            fi
        done < <(sudo find "/Library/Caches" -maxdepth 5 -type f \( \
            \( -name "*.cache" -mtime "+$MOLE_TEMP_FILE_AGE_DAYS" \) -o \
            \( -name "*.tmp" -mtime "+$MOLE_TEMP_FILE_AGE_DAYS" \) -o \
            \( -name "*.log" -mtime "+$MOLE_LOG_AGE_DAYS" \) \
            \) -print0 2> /dev/null || true)
    fi
    stop_section_spinner
    [[ $cache_cleaned -eq 1 ]] && log_success "System caches"
    start_section_spinner "Cleaning system temporary files..."
    local tmp_cleaned=0
    local -a sys_temp_dirs=("/private/tmp" "/private/var/tmp")
    for tmp_dir in "${sys_temp_dirs[@]}"; do
        if sudo find "$tmp_dir" -maxdepth 1 -type f -mtime "+${MOLE_TEMP_FILE_AGE_DAYS}" -print -quit 2> /dev/null | grep -q .; then
            if safe_sudo_find_delete "$tmp_dir" "*" "${MOLE_TEMP_FILE_AGE_DAYS}" "f"; then
                tmp_cleaned=1
            fi
        fi
    done
    stop_section_spinner
    [[ $tmp_cleaned -eq 1 ]] && log_success "System temp files"
    start_section_spinner "Cleaning system crash reports..."
    if sudo find "/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -mtime "+$MOLE_CRASH_REPORT_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*" "$MOLE_CRASH_REPORT_AGE_DAYS" "f" || true
    fi
    stop_section_spinner
    log_success "System crash reports"
    start_section_spinner "Cleaning system logs..."
    if sudo find "/private/var/log" -maxdepth 3 -type f \( -name "*.log" -o -name "*.gz" -o -name "*.asl" \) -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        safe_sudo_find_delete "/private/var/log" "*.log" "$MOLE_LOG_AGE_DAYS" "f" || true
        safe_sudo_find_delete "/private/var/log" "*.gz" "$MOLE_LOG_AGE_DAYS" "f" || true
        safe_sudo_find_delete "/private/var/log" "*.asl" "$MOLE_LOG_AGE_DAYS" "f" || true
    fi
    stop_section_spinner
    log_success "System logs"
    start_section_spinner "Cleaning third-party system logs..."
    local -a third_party_log_dirs=(
        "/Library/Logs/Adobe"
        "/Library/Logs/CreativeCloud"
    )
    local third_party_logs_cleaned=0
    local third_party_log_dir=""
    for third_party_log_dir in "${third_party_log_dirs[@]}"; do
        if sudo test -d "$third_party_log_dir" 2> /dev/null; then
            if sudo find "$third_party_log_dir" -maxdepth 5 -type f -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
                if safe_sudo_find_delete "$third_party_log_dir" "*" "$MOLE_LOG_AGE_DAYS" "f"; then
                    third_party_logs_cleaned=1
                fi
            fi
        fi
    done
    if sudo find "/Library/Logs" -maxdepth 1 -type f -name "adobegc.log" -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        if safe_sudo_remove "/Library/Logs/adobegc.log"; then
            third_party_logs_cleaned=1
        fi
    fi
    stop_section_spinner
    [[ $third_party_logs_cleaned -eq 1 ]] && log_success "Third-party system logs"
    start_section_spinner "Scanning system library updates..."
    if [[ -d "/Library/Updates" && ! -L "/Library/Updates" ]]; then
        local updates_cleaned=0
        while IFS= read -r -d '' item; do
            if [[ -z "$item" ]] || [[ ! "$item" =~ ^/Library/Updates/[^/]+$ ]]; then
                debug_log "Skipping malformed path: $item"
                continue
            fi
            local item_flags
            item_flags=$($STAT_BSD -f%Sf "$item" 2> /dev/null || echo "")
            if [[ "$item_flags" == *"restricted"* ]]; then
                continue
            fi
            if safe_sudo_remove "$item"; then
                updates_cleaned=$((updates_cleaned + 1))
            fi
        done < <(find /Library/Updates -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        stop_section_spinner
        [[ $updates_cleaned -gt 0 ]] && log_success "System library updates"
    else
        stop_section_spinner
    fi
    start_section_spinner "Scanning macOS installer files..."
    if [[ -d "/macOS Install Data" ]]; then
        local mtime
        mtime=$(get_file_mtime "/macOS Install Data")
        local age_days=$((($(get_epoch_seconds) - mtime) / 86400))
        debug_log "Found macOS Install Data, age ${age_days} days"
        if [[ $age_days -ge 14 ]]; then
            local size_kb
            size_kb=$(get_path_size_kb "/macOS Install Data")
            if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
                local size_human
                size_human=$(bytes_to_human "$((size_kb * 1024))")
                debug_log "Cleaning macOS Install Data: $size_human, ${age_days} days old"
                if safe_sudo_remove "/macOS Install Data"; then
                    log_success "macOS Install Data, $size_human"
                fi
            fi
        else
            debug_log "Keeping macOS Install Data, only ${age_days} days old, needs 14+"
        fi
    fi
    # Clean macOS installer apps (e.g., "Install macOS Sequoia.app")
    # Only remove installers older than 14 days, not currently running,
    # and not matching the currently installed macOS version (recovery safety).
    local installer_cleaned=0
    local current_macos_version=""
    current_macos_version=$(sw_vers -productVersion 2> /dev/null | cut -d. -f1 || true)
    for installer_app in /Applications/Install\ macOS*.app; do
        [[ -d "$installer_app" ]] || continue
        local app_name
        app_name=$(basename "$installer_app")
        # Skip if installer is currently running
        if pgrep -f "$installer_app" > /dev/null 2>&1; then
            debug_log "Skipping $app_name: currently running"
            continue
        fi
        # Skip if this installer matches the current macOS major version.
        # Users may need it for recovery or reinstallation.
        if [[ -n "$current_macos_version" ]]; then
            local installer_plist="$installer_app/Contents/Info.plist"
            if [[ -f "$installer_plist" ]]; then
                local installer_version=""
                installer_version=$(/usr/libexec/PlistBuddy -c "Print :DTPlatformVersion" "$installer_plist" 2> /dev/null | cut -d. -f1 || true)
                if [[ -n "$installer_version" && "$installer_version" == *"$current_macos_version"* ]]; then
                    debug_log "Keeping $app_name: matches current macOS version ($current_macos_version)"
                    continue
                fi
            fi
        fi
        # Check age (same 14-day threshold as /macOS Install Data)
        local mtime
        mtime=$(get_file_mtime "$installer_app")
        local age_days=$((($(get_epoch_seconds) - mtime) / 86400))
        if [[ $age_days -lt 14 ]]; then
            debug_log "Keeping $app_name: only ${age_days} days old, needs 14+"
            continue
        fi
        local size_kb
        size_kb=$(get_path_size_kb "$installer_app")
        if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
            local size_human
            size_human=$(bytes_to_human "$((size_kb * 1024))")
            debug_log "Cleaning macOS installer: $app_name, $size_human, ${age_days} days old"
            if safe_sudo_remove "$installer_app"; then
                log_success "$app_name, $size_human"
                installer_cleaned=$((installer_cleaned + 1))
            fi
        fi
    done
    stop_section_spinner
    [[ $installer_cleaned -gt 0 ]] && debug_log "Cleaned $installer_cleaned macOS installer(s)"
    start_section_spinner "Scanning browser code signature caches..."
    local code_sign_cleaned=0
    while IFS= read -r -d '' cache_dir; do
        if safe_sudo_remove "$cache_dir"; then
            code_sign_cleaned=$((code_sign_cleaned + 1))
        fi
    done < <(run_with_timeout 5 command find /private/var/folders -maxdepth 5 -type d -name "*.code_sign_clone" -path "*/X/*" -print0 2> /dev/null || true)
    stop_section_spinner
    [[ $code_sign_cleaned -gt 0 ]] && log_success "Browser code signature caches, $code_sign_cleaned items"

    local diag_base="/private/var/db/diagnostics"
    start_section_spinner "Cleaning system diagnostic logs..."
    safe_sudo_find_delete "$diag_base" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    safe_sudo_find_delete "$diag_base" "*.tracev3" "30" "f" || true
    safe_sudo_find_delete "/private/var/db/DiagnosticPipeline" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    stop_section_spinner
    log_success "System diagnostic logs"

    start_section_spinner "Cleaning power logs..."
    safe_sudo_find_delete "/private/var/db/powerlog" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    stop_section_spinner
    log_success "Power logs"
    start_section_spinner "Cleaning memory exception reports..."
    local mem_reports_dir="/private/var/db/reportmemoryexception/MemoryLimitViolations"
    local mem_cleaned=0
    if sudo test -d "$mem_reports_dir" 2> /dev/null; then
        # Count and size old files before deletion
        local file_count=0
        local total_size_kb=0
        local total_bytes=0
        local stats_out
        stats_out=$(sudo find "$mem_reports_dir" -type f -mtime +30 -exec stat -f "%z" {} + 2> /dev/null | awk '{c++; s+=$1} END {print c+0, s+0}' || true)
        if [[ -n "$stats_out" ]]; then
            read -r file_count total_bytes <<< "$stats_out"
            total_size_kb=$((total_bytes / 1024))
        fi

        if [[ "$file_count" -gt 0 ]]; then
            if [[ "${DRY_RUN:-}" != "true" ]]; then
                if safe_sudo_find_delete "$mem_reports_dir" "*" "30" "f"; then
                    mem_cleaned=1
                fi
                # Log summary to operations.log
                if [[ $mem_cleaned -eq 1 ]] && oplog_enabled && [[ "$total_size_kb" -gt 0 ]]; then
                    local size_human
                    size_human=$(bytes_to_human "$((total_size_kb * 1024))")
                    log_operation "clean" "REMOVED" "$mem_reports_dir" "$file_count files, $size_human"
                fi
            else
                log_info "[DRY-RUN] Would remove $file_count old memory exception reports ($total_size_kb KB)"
            fi
        fi
    fi
    stop_section_spinner
    if [[ $mem_cleaned -eq 1 ]]; then
        log_success "Memory exception reports"
    fi
    return 0
}
# Incomplete Time Machine backups.
clean_time_machine_failed_backups() {
    local tm_cleaned=0
    if ! command -v tmutil > /dev/null 2>&1; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    # Fast pre-check: skip entirely if Time Machine is not configured (no tmutil needed)
    if ! defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    start_section_spinner "Checking Time Machine configuration..."
    local spinner_active=true
    local tm_info
    tm_info=$(run_with_timeout 2 tmutil destinationinfo 2>&1 || echo "failed")
    if [[ "$tm_info" == *"No destinations configured"* || "$tm_info" == "failed" ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if [[ ! -d "/Volumes" ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if tm_is_running; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${YELLOW}!${NC} Time Machine backup in progress, skipping cleanup"
        return 0
    fi
    if [[ "$spinner_active" == "true" ]]; then
        start_section_spinner "Checking backup volumes..."
    fi
    # Fast pre-scan for backup volumes to avoid slow tmutil checks.
    local -a backup_volumes=()
    for volume in /Volumes/*; do
        [[ -d "$volume" ]] || continue
        [[ "$volume" == "/Volumes/MacintoshHD" || "$volume" == "/" ]] && continue
        [[ -L "$volume" ]] && continue
        if [[ -d "$volume/Backups.backupdb" ]] || [[ -d "$volume/.MobileBackups" ]]; then
            backup_volumes+=("$volume")
        fi
    done
    if [[ ${#backup_volumes[@]} -eq 0 ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if [[ "$spinner_active" == "true" ]]; then
        start_section_spinner "Scanning backup volumes..."
    fi
    for volume in "${backup_volumes[@]}"; do
        local fs_type
        fs_type=$(run_with_timeout 1 command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}' || echo "unknown")
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav | unknown) continue ;;
        esac
        local backupdb_dir="$volume/Backups.backupdb"
        if [[ -d "$backupdb_dir" ]]; then
            while IFS= read -r inprogress_file; do
                [[ -d "$inprogress_file" ]] || continue
                # Only delete old incomplete backups (safety window).
                local file_mtime
                file_mtime=$(get_file_mtime "$inprogress_file")
                local current_time
                current_time=$(get_epoch_seconds)
                local hours_old=$(((current_time - file_mtime) / 3600))
                if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                    continue
                fi
                local size_kb
                size_kb=$(get_path_size_kb "$inprogress_file")
                [[ "$size_kb" -le 0 ]] && continue
                if [[ "$spinner_active" == "true" ]]; then
                    stop_section_spinner
                    spinner_active=false
                fi
                local backup_name
                backup_name=$(basename "$inprogress_file")
                local size_human
                size_human=$(bytes_to_human "$((size_kb * 1024))")
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete backup: $backup_name${NC}, ${YELLOW}$size_human dry${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    note_activity
                    continue
                fi
                if ! command -v tmutil > /dev/null 2>&1; then
                    echo -e "  ${YELLOW}!${NC} tmutil not available, skipping: $backup_name"
                    continue
                fi
                if tmutil delete "$inprogress_file" 2> /dev/null; then
                    local line_color
                    line_color=$(cleanup_result_color_kb "$size_kb")
                    echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete backup: $backup_name${NC}, ${line_color}$size_human${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    files_cleaned=$((files_cleaned + 1))
                    total_size_cleaned=$((total_size_cleaned + size_kb))
                    total_items=$((total_items + 1))
                    note_activity
                else
                    echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name · try manually with sudo"
                fi
            done < <(run_with_timeout 15 find "$backupdb_dir" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
        fi
        # APFS bundles.
        for bundle in "$volume"/*.backupbundle "$volume"/*.sparsebundle; do
            [[ -e "$bundle" ]] || continue
            [[ -d "$bundle" ]] || continue
            local bundle_name
            bundle_name=$(basename "$bundle")
            local mounted_path
            mounted_path=$(hdiutil info 2> /dev/null | grep -A 5 "image-path.*$bundle_name" | grep "/Volumes/" | awk '{print $1}' | head -1 || echo "")
            if [[ -n "$mounted_path" && -d "$mounted_path" ]]; then
                while IFS= read -r inprogress_file; do
                    [[ -d "$inprogress_file" ]] || continue
                    local file_mtime
                    file_mtime=$(get_file_mtime "$inprogress_file")
                    local current_time
                    current_time=$(get_epoch_seconds)
                    local hours_old=$(((current_time - file_mtime) / 3600))
                    if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                        continue
                    fi
                    local size_kb
                    size_kb=$(get_path_size_kb "$inprogress_file")
                    [[ "$size_kb" -le 0 ]] && continue
                    if [[ "$spinner_active" == "true" ]]; then
                        stop_section_spinner
                        spinner_active=false
                    fi
                    local backup_name
                    backup_name=$(basename "$inprogress_file")
                    local size_human
                    size_human=$(bytes_to_human "$((size_kb * 1024))")
                    if [[ "$DRY_RUN" == "true" ]]; then
                        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC}, ${YELLOW}$size_human dry${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        note_activity
                        continue
                    fi
                    if ! command -v tmutil > /dev/null 2>&1; then
                        continue
                    fi
                    if tmutil delete "$inprogress_file" 2> /dev/null; then
                        local line_color
                        line_color=$(cleanup_result_color_kb "$size_kb")
                        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC}, ${line_color}$size_human${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        files_cleaned=$((files_cleaned + 1))
                        total_size_cleaned=$((total_size_cleaned + size_kb))
                        total_items=$((total_items + 1))
                        note_activity
                    else
                        echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                    fi
                done < <(run_with_timeout 15 find "$mounted_path" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
            fi
        done
    done
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $tm_cleaned -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
    fi
}
# Returns 0 if a backup is actively running.
# Returns 1 if not running.
# Returns 2 if status cannot be determined
tm_is_running() {
    local st
    st="$(tmutil status 2> /dev/null)" || return 2

    # If we can't find a Running field at all, treat as unknown.
    if ! grep -qE '(^|[[:space:]])("Running"|Running)[[:space:]]*=' <<< "$st"; then
        return 2
    fi

    # Match: Running = 1;   OR   "Running" = 1   (with or without trailing ;)
    grep -qE '(^|[[:space:]])("Running"|Running)[[:space:]]*=[[:space:]]*1([[:space:]]*;|$)' <<< "$st"
}

# Local APFS snapshots (report only).
clean_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        return 0
    fi
    # Fast pre-check: skip entirely if Time Machine is not configured (no tmutil needed)
    if ! defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        return 0
    fi

    start_section_spinner "Checking Time Machine status..."
    local rc_running=0
    tm_is_running || rc_running=$?

    if [[ $rc_running -eq 2 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Could not determine Time Machine status; skipping snapshot check"
        return 0
    fi

    if [[ $rc_running -eq 0 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Time Machine is active; skipping snapshot check"
        return 0
    fi

    start_section_spinner "Checking local snapshots..."
    local snapshot_list
    snapshot_list=$(run_with_timeout 3 tmutil listlocalsnapshots / 2> /dev/null || true)
    stop_section_spinner
    [[ -z "$snapshot_list" ]] && return 0

    local snapshot_count
    snapshot_count=$(echo "$snapshot_list" | { grep -Eo 'com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true; } | wc -l | awk '{print $1}')
    if [[ "$snapshot_count" =~ ^[0-9]+$ && "$snapshot_count" -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Time Machine local snapshots: ${GREEN}${snapshot_count}${NC}"
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${GRAY}Review: tmutil listlocalsnapshots /${NC}"
        note_activity
    fi
}
