#!/bin/bash
# System-Level Cleanup Module
# Deep system cleanup (requires sudo) and Time Machine failed backups

set -euo pipefail

# Deep system cleanup (requires sudo)
clean_deep_system() {
    # Clean old system caches
    safe_sudo_find_delete "/Library/Caches" "*.cache" "$MOLE_TEMP_FILE_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/Library/Caches" "*.tmp" "$MOLE_TEMP_FILE_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/Library/Caches" "*.log" "$MOLE_LOG_AGE_DAYS" "f" || true

    # Clean temporary files (macOS /tmp is a symlink to /private/tmp)
    local tmp_cleaned=0
    safe_sudo_find_delete "/private/tmp" "*" "${MOLE_TEMP_FILE_AGE_DAYS}" "f" && tmp_cleaned=1 || true
    safe_sudo_find_delete "/private/var/tmp" "*" "${MOLE_TEMP_FILE_AGE_DAYS}" "f" && tmp_cleaned=1 || true
    [[ $tmp_cleaned -eq 1 ]] && log_success "System temp files"

    # Clean crash reports
    safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*" "$MOLE_CRASH_REPORT_AGE_DAYS" "f" || true
    log_success "System crash reports"

    # Clean system logs (macOS /var is a symlink to /private/var)
    safe_sudo_find_delete "/private/var/log" "*.log" "$MOLE_LOG_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/private/var/log" "*.gz" "$MOLE_LOG_AGE_DAYS" "f" || true
    log_success "System logs"

    # Clean Library Updates safely (skip if SIP is enabled)
    if [[ -d "/Library/Updates" && ! -L "/Library/Updates" ]]; then
        if ! is_sip_enabled; then
            # SIP is disabled, attempt cleanup with restricted flag check
            local updates_cleaned=0
            while IFS= read -r -d '' item; do
                # Validate path format (must be direct child of /Library/Updates)
                if [[ -z "$item" ]] || [[ ! "$item" =~ ^/Library/Updates/[^/]+$ ]]; then
                    debug_log "Skipping malformed path: $item"
                    continue
                fi

                # Skip system-protected files (restricted flag)
                local item_flags
                item_flags=$($STAT_BSD -f%Sf "$item" 2> /dev/null || echo "")
                if [[ "$item_flags" == *"restricted"* ]]; then
                    continue
                fi

                if safe_sudo_remove "$item"; then
                    ((updates_cleaned++))
                fi
            done < <(find /Library/Updates -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
            [[ $updates_cleaned -gt 0 ]] && log_success "System library updates"
        fi
    fi

    # Clean macOS Install Data (legacy upgrade leftovers)
    if [[ -d "/macOS Install Data" ]]; then
        local mtime=$(get_file_mtime "/macOS Install Data")
        local age_days=$((($(date +%s) - mtime) / 86400))

        debug_log "Found macOS Install Data (age: ${age_days} days)"

        if [[ $age_days -ge 30 ]]; then
            local size_kb=$(get_path_size_kb "/macOS Install Data")
            if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
                local size_human=$(bytes_to_human "$((size_kb * 1024))")
                debug_log "Cleaning macOS Install Data: $size_human (${age_days} days old)"

                if safe_sudo_remove "/macOS Install Data"; then
                    log_success "macOS Install Data ($size_human)"
                fi
            fi
        else
            debug_log "Keeping macOS Install Data (only ${age_days} days old, needs 30+)"
        fi
    fi

    # Clean browser code signature caches
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning system caches..."
    fi
    local code_sign_cleaned=0
    local found_count=0

    # Efficient stream processing for large directories
    while IFS= read -r -d '' cache_dir; do
        if safe_remove "$cache_dir" true; then
            ((code_sign_cleaned++))
        fi
        ((found_count++))

        # Update progress spinner periodically
        if [[ -t 1 ]] && ((found_count % 50 == 0)); then
            stop_inline_spinner
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning system caches... ($found_count found)"
        fi
    done < <(run_with_timeout 5 command find /private/var/folders -type d -name "*.code_sign_clone" -path "*/X/*" -print0 2> /dev/null || true)

    if [[ -t 1 ]]; then stop_inline_spinner; fi

    [[ $code_sign_cleaned -gt 0 ]] && log_success "Browser code signature caches ($code_sign_cleaned items)"

    # Clean system diagnostics logs
    safe_sudo_find_delete "/private/var/db/diagnostics/Special" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/private/var/db/diagnostics/Persist" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    safe_sudo_find_delete "/private/var/db/DiagnosticPipeline" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    log_success "System diagnostic logs"

    # Clean power logs
    safe_sudo_find_delete "/private/var/db/powerlog" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    log_success "Power logs"
}

# Clean incomplete Time Machine backups
clean_time_machine_failed_backups() {
    local tm_cleaned=0

    # Check if tmutil is available
    if ! command -v tmutil > /dev/null 2>&1; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi

    # Start spinner early (before potentially slow tmutil command)
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking Time Machine configuration..."
    fi
    local spinner_active=true

    # Check if Time Machine is configured (with short timeout for faster response)
    local tm_info
    tm_info=$(run_with_timeout 2 tmutil destinationinfo 2>&1 || echo "failed")
    if [[ "$tm_info" == *"No destinations configured"* || "$tm_info" == "failed" ]]; then
        if [[ "$spinner_active" == "true" && -t 1 ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi

    if [[ ! -d "/Volumes" ]]; then
        if [[ "$spinner_active" == "true" && -t 1 ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi

    # Skip if backup is running
    if pgrep -x "backupd" > /dev/null 2>&1; then
        if [[ "$spinner_active" == "true" && -t 1 ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${YELLOW}!${NC} Time Machine backup in progress, skipping cleanup"
        return 0
    fi

    # Update spinner message for volume scanning
    if [[ "$spinner_active" == "true" && -t 1 ]]; then
        stop_inline_spinner
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking backup volumes..."
    fi

    # Fast pre-scan: check which volumes have Backups.backupdb (avoid expensive tmutil checks)
    local -a backup_volumes=()
    for volume in /Volumes/*; do
        [[ -d "$volume" ]] || continue
        [[ "$volume" == "/Volumes/MacintoshHD" || "$volume" == "/" ]] && continue
        [[ -L "$volume" ]] && continue

        # Quick check: does this volume have backup directories?
        if [[ -d "$volume/Backups.backupdb" ]] || [[ -d "$volume/.MobileBackups" ]]; then
            backup_volumes+=("$volume")
        fi
    done

    # If no backup volumes found, stop spinner and return
    if [[ ${#backup_volumes[@]} -eq 0 ]]; then
        if [[ "$spinner_active" == "true" && -t 1 ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi

    # Update spinner message: we have potential backup volumes, now scan them
    if [[ "$spinner_active" == "true" && -t 1 ]]; then
        stop_inline_spinner
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning backup volumes..."
    fi
    for volume in "${backup_volumes[@]}"; do
        # Skip network volumes (quick check)
        local fs_type
        fs_type=$(run_with_timeout 1 command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}' || echo "unknown")
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav | unknown) continue ;;
        esac

        # HFS+ style backups (Backups.backupdb)
        local backupdb_dir="$volume/Backups.backupdb"
        if [[ -d "$backupdb_dir" ]]; then
            while IFS= read -r inprogress_file; do
                [[ -d "$inprogress_file" ]] || continue

                # Only delete old incomplete backups (safety window)
                local file_mtime=$(get_file_mtime "$inprogress_file")
                local current_time=$(date +%s)
                local hours_old=$(((current_time - file_mtime) / 3600))

                if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                    continue
                fi

                local size_kb=$(get_path_size_kb "$inprogress_file")
                [[ "$size_kb" -le 0 ]] && continue

                # Stop spinner before first output
                if [[ "$spinner_active" == "true" ]]; then
                    if [[ -t 1 ]]; then stop_inline_spinner; fi
                    spinner_active=false
                fi

                local backup_name=$(basename "$inprogress_file")
                local size_human=$(bytes_to_human "$((size_kb * 1024))")

                if [[ "$DRY_RUN" == "true" ]]; then
                    echo -e "  ${YELLOW}→${NC} Incomplete backup: $backup_name ${YELLOW}($size_human dry)${NC}"
                    ((tm_cleaned++))
                    note_activity
                    continue
                fi

                # Real deletion
                if ! command -v tmutil > /dev/null 2>&1; then
                    echo -e "  ${YELLOW}!${NC} tmutil not available, skipping: $backup_name"
                    continue
                fi

                if tmutil delete "$inprogress_file" 2> /dev/null; then
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Incomplete backup: $backup_name ${GREEN}($size_human)${NC}"
                    ((tm_cleaned++))
                    ((files_cleaned++))
                    ((total_size_cleaned += size_kb))
                    ((total_items++))
                    note_activity
                else
                    echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name (try manually with sudo)"
                fi
            done < <(run_with_timeout 15 find "$backupdb_dir" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
        fi

        # APFS style backups (.backupbundle or .sparsebundle)
        for bundle in "$volume"/*.backupbundle "$volume"/*.sparsebundle; do
            [[ -e "$bundle" ]] || continue
            [[ -d "$bundle" ]] || continue

            # Check if bundle is mounted
            local bundle_name=$(basename "$bundle")
            local mounted_path=$(hdiutil info 2> /dev/null | grep -A 5 "image-path.*$bundle_name" | grep "/Volumes/" | awk '{print $1}' | head -1 || echo "")

            if [[ -n "$mounted_path" && -d "$mounted_path" ]]; then
                while IFS= read -r inprogress_file; do
                    [[ -d "$inprogress_file" ]] || continue

                    # Only delete old incomplete backups (safety window)
                    local file_mtime=$(get_file_mtime "$inprogress_file")
                    local current_time=$(date +%s)
                    local hours_old=$(((current_time - file_mtime) / 3600))

                    if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                        continue
                    fi

                    local size_kb=$(get_path_size_kb "$inprogress_file")
                    [[ "$size_kb" -le 0 ]] && continue

                    # Stop spinner before first output
                    if [[ "$spinner_active" == "true" ]]; then
                        if [[ -t 1 ]]; then stop_inline_spinner; fi
                        spinner_active=false
                    fi

                    local backup_name=$(basename "$inprogress_file")
                    local size_human=$(bytes_to_human "$((size_kb * 1024))")

                    if [[ "$DRY_RUN" == "true" ]]; then
                        echo -e "  ${YELLOW}→${NC} Incomplete APFS backup in $bundle_name: $backup_name ${YELLOW}($size_human dry)${NC}"
                        ((tm_cleaned++))
                        note_activity
                        continue
                    fi

                    # Real deletion
                    if ! command -v tmutil > /dev/null 2>&1; then
                        continue
                    fi

                    if tmutil delete "$inprogress_file" 2> /dev/null; then
                        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Incomplete APFS backup in $bundle_name: $backup_name ${GREEN}($size_human)${NC}"
                        ((tm_cleaned++))
                        ((files_cleaned++))
                        ((total_size_cleaned += size_kb))
                        ((total_items++))
                        note_activity
                    else
                        echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                    fi
                done < <(run_with_timeout 15 find "$mounted_path" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
            fi
        done
    done

    # Stop spinner if still active (no backups found)
    if [[ "$spinner_active" == "true" ]]; then
        if [[ -t 1 ]]; then stop_inline_spinner; fi
    fi

    if [[ $tm_cleaned -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
    fi
}

# Clean local APFS snapshots (older than 24 hours)
clean_local_snapshots() {
    # Check if tmutil is available
    if ! command -v tmutil > /dev/null 2>&1; then
        return 0
    fi

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking local snapshots..."
    fi

    # Check for local snapshots
    local snapshot_list
    snapshot_list=$(tmutil listlocalsnapshots / 2> /dev/null)

    if [[ -t 1 ]]; then stop_inline_spinner; fi

    [[ -z "$snapshot_list" ]] && return 0

    # Parse and clean snapshots
    local cleaned_count=0
    local total_cleaned_size=0 # Estimation not possible without thin

    # Get current time
    local current_ts=$(date +%s)
    local one_day_ago=$((current_ts - 86400))

    while IFS= read -r line; do
        # Format: com.apple.TimeMachine.2023-10-25-120000
        if [[ "$line" =~ com\.apple\.TimeMachine\.([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6}) ]]; then
            local date_str="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]:0:2}:${BASH_REMATCH[4]:2:2}:${BASH_REMATCH[4]:4:2}"
            local snap_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$date_str" "+%s" 2> /dev/null || echo "0")

            # Skip if parsing failed
            [[ "$snap_ts" == "0" ]] && continue

            # If snapshot is older than 24 hours
            if [[ $snap_ts -lt $one_day_ago ]]; then
                local snap_name="${BASH_REMATCH[0]}"

                if [[ "$DRY_RUN" == "true" ]]; then
                    echo -e "  ${YELLOW}→${NC} Old local snapshot: $snap_name ${YELLOW}(dry)${NC}"
                    ((cleaned_count++))
                    note_activity
                else
                    # Secure removal
                    if safe_sudo tmutil deletelocalsnapshots "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}-${BASH_REMATCH[4]}" > /dev/null 2>&1; then
                        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Removed snapshot: $snap_name"
                        ((cleaned_count++))
                        note_activity
                    else
                        echo -e "  ${YELLOW}!${NC} Failed to remove: $snap_name"
                    fi
                fi
            fi
        fi
    done <<< "$snapshot_list"

    if [[ $cleaned_count -gt 0 && "$DRY_RUN" != "true" ]]; then
        log_success "Cleaned $cleaned_count old local snapshots"
    fi
}
