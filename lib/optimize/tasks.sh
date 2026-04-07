#!/bin/bash
# Optimization Tasks

set -euo pipefail

# Config constants (override via env).
readonly MOLE_TM_THIN_TIMEOUT=180
readonly MOLE_TM_THIN_VALUE=9999999999
readonly MOLE_SQLITE_MAX_SIZE=104857600 # 100MB

# Dry-run aware output.
opt_msg() {
    local message="$1"
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $message"
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $message"
    fi
}

run_launchctl_unload() {
    local plist_file="$1"
    local need_sudo="${2:-false}"

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    if [[ "$need_sudo" == "true" ]]; then
        sudo launchctl unload "$plist_file" 2> /dev/null || true
    else
        launchctl unload "$plist_file" 2> /dev/null || true
    fi
}

needs_permissions_repair() {
    local owner
    owner=$(stat -f %Su "$HOME" 2> /dev/null || echo "")
    if [[ -n "$owner" && "$owner" != "$USER" ]]; then
        return 0
    fi

    local -a paths=(
        "$HOME"
        "$HOME/Library"
        "$HOME/Library/Preferences"
    )
    local path
    for path in "${paths[@]}"; do
        if [[ -e "$path" && ! -w "$path" ]]; then
            return 0
        fi
    done

    return 1
}

has_bluetooth_hid_connected() {
    local bt_report
    bt_report=$(system_profiler SPBluetoothDataType 2> /dev/null || echo "")
    if ! echo "$bt_report" | grep -q "Connected: Yes"; then
        return 1
    fi

    if echo "$bt_report" | grep -Eiq "Keyboard|Trackpad|Mouse|HID"; then
        return 0
    fi

    return 1
}

is_ac_power() {
    pmset -g batt 2> /dev/null | grep -q "AC Power"
}

is_memory_pressure_high() {
    if ! command -v memory_pressure > /dev/null 2>&1; then
        return 1
    fi

    local mp_output
    mp_output=$(memory_pressure -Q 2> /dev/null || echo "")
    if echo "$mp_output" | grep -Eiq "warning|critical"; then
        return 0
    fi

    return 1
}

flush_dns_cache() {
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        MOLE_DNS_FLUSHED=1
        return 0
    fi

    if sudo dscacheutil -flushcache 2> /dev/null && sudo killall -HUP mDNSResponder 2> /dev/null; then
        MOLE_DNS_FLUSHED=1
        return 0
    fi
    return 1
}

# Basic system maintenance.
opt_system_maintenance() {
    if flush_dns_cache; then
        opt_msg "DNS cache flushed"
    fi

    local spotlight_status
    spotlight_status=$(mdutil -s / 2> /dev/null || echo "")
    if echo "$spotlight_status" | grep -qi "Indexing disabled"; then
        echo -e "  ${GRAY}${ICON_EMPTY}${NC} Spotlight indexing disabled"
    else
        opt_msg "Spotlight index verified"
    fi
}

# Refresh Finder caches (QuickLook/icon services).
opt_cache_refresh() {
    local total_cache_size=0

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Finder Cache Refresh" "Refresh QuickLook thumbnails and icon services"
        debug_operation_detail "Method" "Remove cache files and rebuild via qlmanage"
        debug_operation_detail "Expected outcome" "Faster Finder preview generation, fixed icon display issues"
        debug_risk_level "LOW" "Caches are automatically rebuilt"

        local -a cache_targets=(
            "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
            "$HOME/Library/Caches/com.apple.iconservices.store"
            "$HOME/Library/Caches/com.apple.iconservices"
        )

        debug_operation_detail "Files to be removed" ""
        for target_path in "${cache_targets[@]}"; do
            if [[ -e "$target_path" ]]; then
                local size_kb
                size_kb=$(get_path_size_kb "$target_path" 2> /dev/null || echo "0")
                local size_human="unknown"
                if [[ "$size_kb" -gt 0 ]]; then
                    size_human=$(bytes_to_human "$((size_kb * 1024))")
                fi
                debug_file_action "  Will remove" "$target_path" "$size_human" ""
            fi
        done
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        qlmanage -r cache > /dev/null 2>&1 || true
        qlmanage -r > /dev/null 2>&1 || true
    fi

    local -a cache_targets=(
        "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
        "$HOME/Library/Caches/com.apple.iconservices.store"
        "$HOME/Library/Caches/com.apple.iconservices"
    )

    for target_path in "${cache_targets[@]}"; do
        if [[ -e "$target_path" ]]; then
            if ! should_protect_path "$target_path"; then
                local size_kb
                size_kb=$(get_path_size_kb "$target_path" 2> /dev/null || echo "0")
                if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
                    total_cache_size=$((total_cache_size + size_kb))
                fi
                safe_remove "$target_path" true > /dev/null 2>&1 || true
            fi
        fi
    done

    export OPTIMIZE_CACHE_CLEANED_KB="${total_cache_size}"
    opt_msg "QuickLook thumbnails refreshed"
    opt_msg "Icon services cache rebuilt"
}

# Removed: opt_maintenance_scripts - macOS handles log rotation automatically via launchd

# Removed: opt_radio_refresh - Interrupts active user connections (WiFi, Bluetooth), degrading UX

# Old saved states cleanup.
opt_saved_state_cleanup() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "App Saved State Cleanup" "Remove old application saved states"
        debug_operation_detail "Method" "Find and remove .savedState folders older than $MOLE_SAVED_STATE_AGE_DAYS days"
        debug_operation_detail "Location" "$HOME/Library/Saved Application State"
        debug_operation_detail "Expected outcome" "Reduced disk usage, apps start with clean state"
        debug_risk_level "LOW" "Old saved states, apps will create new ones"
    fi

    local state_dir="$HOME/Library/Saved Application State"

    if [[ -d "$state_dir" ]]; then
        while IFS= read -r -d '' state_path; do
            if should_protect_path "$state_path"; then
                continue
            fi
            safe_remove "$state_path" true > /dev/null 2>&1 || true
        done < <(command find "$state_dir" -type d -name "*.savedState" -mtime "+$MOLE_SAVED_STATE_AGE_DAYS" -print0 2> /dev/null)
    fi

    opt_msg "App saved states optimized"
}

# Removed: opt_swap_cleanup - Direct virtual memory operations pose system crash risk

# Removed: opt_startup_cache - Modern macOS has no such mechanism

# Removed: opt_local_snapshots - Deletes user Time Machine recovery points, breaks backup continuity

opt_fix_broken_configs() {
    local spinner_started="false"
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking preferences..."
        spinner_started="true"
    fi

    local broken_prefs=$(fix_broken_preferences)

    if [[ "$spinner_started" == "true" ]]; then
        stop_inline_spinner
    fi

    export OPTIMIZE_CONFIGS_REPAIRED="${broken_prefs}"
    if [[ $broken_prefs -gt 0 ]]; then
        opt_msg "Repaired $broken_prefs corrupted preference files"
    else
        opt_msg "All preference files valid"
    fi
}

# DNS cache refresh.
opt_network_optimization() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Network Optimization" "Refresh DNS cache and restart mDNSResponder"
        debug_operation_detail "Method" "Flush DNS cache via dscacheutil and killall mDNSResponder"
        debug_operation_detail "Expected outcome" "Faster DNS resolution, fixed network connectivity issues"
        debug_risk_level "LOW" "DNS cache is automatically rebuilt"
    fi

    if [[ "${MOLE_DNS_FLUSHED:-0}" == "1" ]]; then
        opt_msg "DNS cache already refreshed"
        opt_msg "mDNSResponder already restarted"
        return 0
    fi

    if flush_dns_cache; then
        opt_msg "DNS cache refreshed"
        opt_msg "mDNSResponder restarted"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to refresh DNS cache"
    fi
}

# Quarantine database cleanup (Gatekeeper download history).
opt_quarantine_cleanup() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Quarantine Database Cleanup" "Clear Gatekeeper download tracking history"
        debug_operation_detail "Method" "DELETE + VACUUM on QuarantineEventsV2 SQLite database"
        debug_operation_detail "Safety" "Only clears download tracking metadata, does not affect file quarantine flags"
        debug_operation_detail "Expected outcome" "Reduced database size, cleared download tracking history"
        debug_risk_level "LOW" "Database is automatically recreated by macOS"
    fi

    if ! command -v sqlite3 > /dev/null 2>&1; then
        echo -e "  ${GRAY}-${NC} Quarantine cleanup skipped, sqlite3 unavailable"
        return 0
    fi

    local quarantine_db="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

    if [[ ! -f "$quarantine_db" ]]; then
        opt_msg "Quarantine database already clean"
        return 0
    fi

    if should_protect_path "$quarantine_db"; then
        opt_msg "Quarantine database already clean"
        return 0
    fi

    # Check if database has any entries worth cleaning.
    local row_count
    row_count=$(run_with_timeout 5 sqlite3 "$quarantine_db" "SELECT COUNT(*) FROM LSQuarantineEvent;" 2> /dev/null || echo "0")

    if [[ ! "$row_count" =~ ^[0-9]+$ ]] || [[ "$row_count" -eq 0 ]]; then
        opt_msg "Quarantine database already clean"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        local exit_code=0
        set +e
        run_with_timeout 10 sqlite3 "$quarantine_db" "DELETE FROM LSQuarantineEvent; VACUUM;" 2> /dev/null
        exit_code=$?
        set -e

        if [[ $exit_code -eq 0 ]]; then
            opt_msg "Quarantine history cleared ($row_count entries)"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to clean quarantine database"
        fi
    else
        opt_msg "Quarantine history cleared ($row_count entries)"
    fi
}

# SQLite vacuum for Mail/Messages/Safari (safety checks applied).
opt_sqlite_vacuum() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Database Optimization" "Vacuum SQLite databases for Mail, Safari, and Messages"
        debug_operation_detail "Method" "Run VACUUM command on databases after integrity check"
        debug_operation_detail "Safety checks" "Skip if apps are running, verify integrity first, 20s timeout"
        debug_operation_detail "Expected outcome" "Reduced database size, faster app performance"
        debug_risk_level "LOW" "Only optimizes databases, does not delete data"
    fi

    if ! command -v sqlite3 > /dev/null 2>&1; then
        echo -e "  ${GRAY}-${NC} Database optimization already optimal, sqlite3 unavailable"
        return 0
    fi

    local -a busy_apps=()
    local -a check_apps=("Mail" "Safari" "Messages")
    local app
    for app in "${check_apps[@]}"; do
        if pgrep -x "$app" > /dev/null 2>&1; then
            busy_apps+=("$app")
        fi
    done

    if [[ ${#busy_apps[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Close these apps before database optimization: ${busy_apps[*]}"
        return 0
    fi

    local spinner_started="false"
    if [[ "${MOLE_DRY_RUN:-0}" != "1" && -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Optimizing databases..."
        spinner_started="true"
    fi

    local -a db_paths=(
        "$HOME/Library/Mail/V*/MailData/Envelope Index*"
        "$HOME/Library/Messages/chat.db"
        "$HOME/Library/Safari/History.db"
        "$HOME/Library/Safari/TopSites.db"
    )

    local vacuumed=0
    local timed_out=0
    local failed=0
    local skipped=0

    for pattern in "${db_paths[@]}"; do
        while IFS= read -r db_file; do
            [[ ! -f "$db_file" ]] && continue
            [[ "$db_file" == *"-wal" || "$db_file" == *"-shm" ]] && continue

            should_protect_path "$db_file" && continue

            if ! file "$db_file" 2> /dev/null | grep -q "SQLite"; then
                continue
            fi

            # Skip large DBs (>100MB).
            local file_size
            file_size=$(get_file_size "$db_file")
            if [[ "$file_size" -gt "$MOLE_SQLITE_MAX_SIZE" ]]; then
                skipped=$((skipped + 1))
                continue
            fi

            # Skip if freelist is tiny (already compact).
            local page_info=""
            page_info=$(run_with_timeout 5 sqlite3 "$db_file" "PRAGMA page_count; PRAGMA freelist_count;" 2> /dev/null || echo "")
            local page_count=""
            local freelist_count=""
            page_count=$(echo "$page_info" | awk 'NR==1 {print $1}' 2> /dev/null || echo "")
            freelist_count=$(echo "$page_info" | awk 'NR==2 {print $1}' 2> /dev/null || echo "")
            if [[ "$page_count" =~ ^[0-9]+$ && "$freelist_count" =~ ^[0-9]+$ && "$page_count" -gt 0 ]]; then
                if ((freelist_count * 100 < page_count * 5)); then
                    skipped=$((skipped + 1))
                    continue
                fi
            fi

            # Verify integrity before VACUUM.
            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                local integrity_check=""
                set +e
                integrity_check=$(run_with_timeout 10 sqlite3 "$db_file" "PRAGMA integrity_check;" 2> /dev/null)
                local integrity_status=$?
                set -e

                if [[ $integrity_status -ne 0 ]] || ! echo "$integrity_check" | grep -q "ok"; then
                    skipped=$((skipped + 1))
                    continue
                fi
            fi

            local exit_code=0
            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                set +e
                run_with_timeout 20 sqlite3 "$db_file" "VACUUM;" 2> /dev/null
                exit_code=$?
                set -e

                if [[ $exit_code -eq 0 ]]; then
                    vacuumed=$((vacuumed + 1))
                elif [[ $exit_code -eq 124 ]]; then
                    timed_out=$((timed_out + 1))
                else
                    failed=$((failed + 1))
                fi
            else
                vacuumed=$((vacuumed + 1))
            fi
        done < <(compgen -G "$pattern" || true)
    done

    if [[ "$spinner_started" == "true" ]]; then
        stop_inline_spinner
    fi

    export OPTIMIZE_DATABASES_COUNT="${vacuumed}"
    if [[ $vacuumed -gt 0 ]]; then
        opt_msg "Optimized $vacuumed databases for Mail, Safari, Messages"
    elif [[ $timed_out -eq 0 && $failed -eq 0 ]]; then
        opt_msg "All databases already optimized"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Database optimization incomplete"
    fi

    if [[ $skipped -gt 0 ]]; then
        opt_msg "Already optimal for $skipped databases"
    fi

    if [[ $timed_out -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Timed out on $timed_out databases"
    fi

    if [[ $failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed on $failed databases"
    fi
}

# LaunchServices rebuild ("Open with" issues).
opt_launch_services_rebuild() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "LaunchServices Rebuild" "Rebuild LaunchServices database"
        debug_operation_detail "Method" "Run lsregister -gc then force rescan with -r -f on local, user, and system domains"
        debug_operation_detail "Purpose" "Fix \"Open with\" menu issues, file associations, and stale app metadata"
        debug_operation_detail "Expected outcome" "Correct app associations, fixed duplicate entries, fewer stale app listings"
        debug_risk_level "LOW" "Database is automatically rebuilt"
    fi

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Repairing LaunchServices..."
    fi

    local lsregister
    lsregister=$(get_lsregister_path)

    if [[ -n "$lsregister" ]]; then
        local success=0

        if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
            set +e
            "$lsregister" -gc > /dev/null 2>&1 || true
            "$lsregister" -r -f -domain local -domain user -domain system > /dev/null 2>&1
            success=$?
            if [[ $success -ne 0 ]]; then
                "$lsregister" -r -f -domain local -domain user > /dev/null 2>&1
                success=$?
            fi
            set -e
        else
            success=0
        fi

        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi

        if [[ $success -eq 0 ]]; then
            opt_msg "LaunchServices repaired"
            opt_msg "File associations refreshed"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to rebuild LaunchServices"
        fi
    else
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} lsregister not found"
    fi
}

# Font cache rebuild.
browser_family_is_running() {
    local browser_name="$1"

    case "$browser_name" in
        "Firefox")
            pgrep -if "Firefox|org\\.mozilla\\.firefox|firefox .*contentproc|firefox .*plugin-container|firefox .*crashreporter" > /dev/null 2>&1
            ;;
        "Zen Browser")
            pgrep -if "Zen Browser|org\\.mozilla\\.zen|Zen Browser Helper|zen .*contentproc" > /dev/null 2>&1
            ;;
        *)
            pgrep -ix "$browser_name" > /dev/null 2>&1
            ;;
    esac
}

opt_font_cache_rebuild() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Font Cache Rebuild" "Clear and rebuild font cache"
        debug_operation_detail "Method" "Run atsutil databases -remove"
        debug_operation_detail "Safety checks" "Skip when browsers or browser helpers are running to avoid cache rebuild conflicts"
        debug_operation_detail "Expected outcome" "Fixed font display issues, removed corrupted font cache"
        debug_risk_level "LOW" "System automatically rebuilds font database"
    fi

    local success=false

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        # Some browsers can keep stale GPU/text caches in /var/folders if system font
        # databases are reset while browser/helper processes are still running.
        local -a running_browsers=()

        local browser_name
        local -a browser_checks=(
            "Firefox"
            "Safari"
            "Google Chrome"
            "Chromium"
            "Brave Browser"
            "Microsoft Edge"
            "Arc"
            "Opera"
            "Vivaldi"
            "Zen Browser"
            "Helium"
        )
        for browser_name in "${browser_checks[@]}"; do
            if browser_family_is_running "$browser_name"; then
                running_browsers+=("$browser_name")
            fi
        done

        if [[ ${#running_browsers[@]} -gt 0 ]]; then
            local running_list
            running_list=$(printf "%s, " "${running_browsers[@]}")
            running_list="${running_list%, }"
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Font cache rebuild skipped · ${running_list} still running"
            return 0
        fi

        if sudo atsutil databases -remove > /dev/null 2>&1; then
            success=true
        fi
    else
        success=true
    fi

    if [[ "$success" == "true" ]]; then
        opt_msg "Font cache cleared"
        opt_msg "System will rebuild font database automatically"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to clear font cache"
    fi
}

# Removed high-risk optimizations:
# - opt_startup_items_cleanup: Risk of deleting legitimate app helpers
# - opt_dyld_cache_update: Low benefit, time-consuming, auto-managed by macOS
# - opt_system_services_refresh: Risk of data loss when killing system services

# Memory pressure relief.
opt_memory_pressure_relief() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Memory Pressure Relief" "Release inactive memory if pressure is high"
        debug_operation_detail "Method" "Run purge command to clear inactive memory"
        debug_operation_detail "Condition" "Only runs if memory pressure is warning/critical"
        debug_operation_detail "Expected outcome" "More available memory, improved responsiveness"
        debug_risk_level "LOW" "Safe system command, does not affect active processes"
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if ! is_memory_pressure_high; then
            opt_msg "Memory pressure already optimal"
            return 0
        fi

        if sudo purge > /dev/null 2>&1; then
            opt_msg "Inactive memory released"
            opt_msg "System responsiveness improved"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to release memory pressure"
        fi
    else
        opt_msg "Inactive memory released"
        opt_msg "System responsiveness improved"
    fi
}

# Network stack reset (route + ARP).
opt_network_stack_optimize() {
    local route_flushed="false"
    local arp_flushed="false"

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        local route_ok=true
        local dns_ok=true

        if ! route -n get default > /dev/null 2>&1; then
            route_ok=false
        fi
        if ! dscacheutil -q host -a name "example.com" > /dev/null 2>&1; then
            dns_ok=false
        fi

        if [[ "$route_ok" == "true" && "$dns_ok" == "true" ]]; then
            opt_msg "Network stack already optimal"
            return 0
        fi

        if sudo route -n flush > /dev/null 2>&1; then
            route_flushed="true"
        fi

        if sudo arp -a -d > /dev/null 2>&1; then
            arp_flushed="true"
        fi
    else
        route_flushed="true"
        arp_flushed="true"
    fi

    if [[ "$route_flushed" == "true" ]]; then
        opt_msg "Network routing table refreshed"
    fi
    if [[ "$arp_flushed" == "true" ]]; then
        opt_msg "ARP cache cleared"
    else
        if [[ "$route_flushed" == "true" ]]; then
            return 0
        fi
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to optimize network stack"
    fi
}

# User directory permissions repair.
opt_disk_permissions_repair() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Disk Permissions Repair" "Reset user directory permissions"
        debug_operation_detail "Method" "Run diskutil resetUserPermissions on user home directory"
        debug_operation_detail "Condition" "Only runs if permissions issues are detected"
        debug_operation_detail "Expected outcome" "Fixed file access issues, correct ownership"
        debug_risk_level "MEDIUM" "Requires sudo, modifies permissions"
    fi

    local user_id
    user_id=$(id -u)

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if ! needs_permissions_repair; then
            opt_msg "User directory permissions already optimal"
            return 0
        fi

        if [[ -t 1 ]]; then
            start_inline_spinner "Repairing disk permissions..."
        fi

        local success=false
        if sudo diskutil resetUserPermissions / "$user_id" > /dev/null 2>&1; then
            success=true
        fi

        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi

        if [[ "$success" == "true" ]]; then
            opt_msg "User directory permissions repaired"
            opt_msg "File access issues resolved"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to repair permissions, may not be needed"
        fi
    else
        opt_msg "User directory permissions repaired"
        opt_msg "File access issues resolved"
    fi
}

# Bluetooth reset (skip if HID/audio active).
opt_bluetooth_reset() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Bluetooth Reset" "Restart Bluetooth daemon"
        debug_operation_detail "Method" "Kill bluetoothd daemon (auto-restarts)"
        debug_operation_detail "Safety" "Skips if active Bluetooth keyboard/mouse/audio detected"
        debug_operation_detail "Expected outcome" "Fixed Bluetooth connectivity issues"
        debug_risk_level "LOW" "Daemon auto-restarts, connections auto-reconnect"
    fi

    local spinner_started="false"
    local disconnect_notice="Bluetooth devices may disconnect briefly during refresh"
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking Bluetooth..."
        spinner_started="true"
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if has_bluetooth_hid_connected; then
            if [[ "$spinner_started" == "true" ]]; then
                stop_inline_spinner
            fi
            opt_msg "Bluetooth already optimal"
            return 0
        fi

        local bt_audio_active=false

        local audio_info
        audio_info=$(system_profiler SPAudioDataType 2> /dev/null || echo "")

        local default_output
        default_output=$(echo "$audio_info" | awk '/Default Output Device: Yes/,/^$/' 2> /dev/null || echo "")

        if echo "$default_output" | grep -qi "Transport:.*Bluetooth"; then
            bt_audio_active=true
        fi

        if [[ "$bt_audio_active" == "false" ]]; then
            if system_profiler SPBluetoothDataType 2> /dev/null | grep -q "Connected: Yes"; then
                local -a media_apps=("Music" "Spotify" "VLC" "QuickTime Player" "TV" "Podcasts" "Safari" "Google Chrome" "Chrome" "Firefox" "Arc" "IINA" "mpv")
                for app in "${media_apps[@]}"; do
                    if pgrep -x "$app" > /dev/null 2>&1; then
                        bt_audio_active=true
                        break
                    fi
                done
            fi
        fi

        if [[ "$bt_audio_active" == "true" ]]; then
            if [[ "$spinner_started" == "true" ]]; then
                stop_inline_spinner
            fi
            opt_msg "Bluetooth already optimal"
            return 0
        fi

        if sudo pkill -TERM bluetoothd > /dev/null 2>&1; then
            if [[ "$spinner_started" == "true" ]]; then
                stop_inline_spinner
            fi
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${GRAY}${disconnect_notice}${NC}"
            sleep 1
            if pgrep -x bluetoothd > /dev/null 2>&1; then
                sudo pkill -KILL bluetoothd > /dev/null 2>&1 || true
            fi
            opt_msg "Bluetooth module restarted"
            opt_msg "Connectivity issues resolved"
        else
            if [[ "$spinner_started" == "true" ]]; then
                stop_inline_spinner
            fi
            opt_msg "Bluetooth already optimal"
        fi
    else
        if [[ "$spinner_started" == "true" ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} ${disconnect_notice}"
        opt_msg "Bluetooth module restarted"
        opt_msg "Connectivity issues resolved"
    fi
}

# Spotlight index check/rebuild (only if slow).
opt_spotlight_index_optimize() {
    local spotlight_status
    spotlight_status=$(mdutil -s / 2> /dev/null || echo "")

    if echo "$spotlight_status" | grep -qi "Indexing disabled"; then
        echo -e "  ${GRAY}${ICON_EMPTY}${NC} Spotlight indexing is disabled"
        return 0
    fi

    if echo "$spotlight_status" | grep -qi "Indexing enabled" && ! echo "$spotlight_status" | grep -qi "Indexing and searching disabled"; then
        local slow_count=0
        local test_start test_end test_duration
        for _ in 1 2; do
            test_start=$(get_epoch_seconds)
            mdfind "kMDItemFSName == 'Applications'" > /dev/null 2>&1 || true
            test_end=$(get_epoch_seconds)
            test_duration=$((test_end - test_start))
            if [[ $test_duration -gt 3 ]]; then
                slow_count=$((slow_count + 1))
            fi
            sleep 1
        done

        if [[ $slow_count -ge 2 ]]; then
            if ! is_ac_power; then
                opt_msg "Spotlight index already optimal"
                return 0
            fi

            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                echo -e "  ${BLUE}${ICON_INFO}${NC} Spotlight search is slow, rebuilding index, may take 1-2 hours"
                if sudo mdutil -E / > /dev/null 2>&1; then
                    opt_msg "Spotlight index rebuild started"
                    echo -e "  ${GRAY}Indexing will continue in background${NC}"
                else
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to rebuild Spotlight index"
                fi
            else
                opt_msg "Spotlight index rebuild started"
            fi
        else
            opt_msg "Spotlight index already optimal"
        fi
    else
        opt_msg "Spotlight index verified"
    fi
}

# Dock cache refresh.
opt_dock_refresh() {
    local dock_support="$HOME/Library/Application Support/Dock"
    local refreshed=false

    if [[ -d "$dock_support" ]]; then
        while IFS= read -r db_file; do
            if [[ -f "$db_file" ]]; then
                safe_remove "$db_file" true > /dev/null 2>&1 && refreshed=true
            fi
        done < <(command find "$dock_support" -name "*.db" -type f 2> /dev/null || true)
    fi

    local dock_plist="$HOME/Library/Preferences/com.apple.dock.plist"
    if [[ -f "$dock_plist" ]]; then
        touch "$dock_plist" 2> /dev/null || true
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        killall Dock 2> /dev/null || true
    fi

    if [[ "$refreshed" == "true" ]]; then
        opt_msg "Dock cache cleared"
    fi
    opt_msg "Dock refreshed"
}

# Prevent .DS_Store on network and USB volumes.
# Idempotent: writes two user defaults that stop Finder from creating
# .DS_Store files on SMB/AFP/NFS shares and removable USB volumes.
# Reversible with: defaults delete com.apple.desktopservices DSDontWrite{Network,USB}Stores
opt_prevent_network_dsstore() {
    local domain="com.apple.desktopservices"
    local -a keys=("DSDontWriteNetworkStores" "DSDontWriteUSBStores")
    local changed=0
    local already=0

    for key in "${keys[@]}"; do
        local current
        current=$(defaults read "$domain" "$key" 2> /dev/null || echo "")
        if [[ "$current" == "1" ]]; then
            already=$((already + 1))
            continue
        fi

        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            changed=$((changed + 1))
            continue
        fi

        if defaults write "$domain" "$key" -bool true 2> /dev/null; then
            changed=$((changed + 1))
        fi
    done

    if [[ $changed -eq 0 && $already -gt 0 ]]; then
        opt_msg ".DS_Store prevention already enabled on network & USB volumes"
        return 0
    fi

    if [[ $changed -gt 0 ]]; then
        opt_msg ".DS_Store prevention enabled on network & USB volumes"
    fi
}

# Broken LaunchAgent cleanup.
opt_launch_agents_cleanup() {
    local agents_dir="$HOME/Library/LaunchAgents"

    if [[ ! -d "$agents_dir" ]]; then
        opt_msg "Launch Agents all healthy"
        return 0
    fi

    local broken_count=0
    local -a broken_plists=()

    for plist in "$agents_dir"/*.plist; do
        [[ -f "$plist" ]] || continue

        local binary=""
        binary=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist" 2> /dev/null || true)
        if [[ -z "$binary" ]]; then
            binary=$(/usr/libexec/PlistBuddy -c "Print :Program" "$plist" 2> /dev/null || true)
        fi

        if [[ -n "$binary" && ! -e "$binary" ]]; then
            broken_count=$((broken_count + 1))
            broken_plists+=("$plist")
        fi
    done

    if [[ $broken_count -eq 0 ]]; then
        opt_msg "Launch Agents all healthy"
        return 0
    fi

    for plist in "${broken_plists[@]}"; do
        run_launchctl_unload "$plist"
        safe_remove "$plist" true > /dev/null 2>&1 || true
    done

    opt_msg "Cleaned $broken_count broken Launch Agent(s)"
}

# macOS periodic maintenance scripts (daily/weekly/monthly).
# Log path is configurable via MOLE_PERIODIC_LOG for testing; defaults to /var/log/daily.out.
# A missing log file is treated as stale and triggers maintenance.
opt_periodic_maintenance() {
    local daily_log="${MOLE_PERIODIC_LOG:-/var/log/daily.out}"
    local stale_days=7

    if [[ -f "$daily_log" ]]; then
        local last_mod now age_days
        last_mod=$(stat -f %m "$daily_log" 2> /dev/null || echo "0")
        now=$(get_epoch_seconds)
        age_days=$(((now - last_mod) / 86400))

        if [[ $age_days -lt $stale_days ]]; then
            opt_msg "Periodic maintenance already current (${age_days}d ago)"
            return 0
        fi
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if sudo periodic daily weekly monthly 2> /dev/null; then
            opt_msg "Periodic maintenance triggered"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to run periodic maintenance"
        fi
    else
        opt_msg "Periodic maintenance triggered"
    fi
}

# Repair corrupted shared file list databases (Finder favorites, recent docs).
opt_shared_file_list_repair() {
    local sfl_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    if [[ ! -d "$sfl_dir" ]]; then
        opt_msg "Shared file lists directory not found"
        return 0
    fi

    local repaired=0
    while IFS= read -r sfl_file; do
        [[ -f "$sfl_file" ]] || continue
        # Skip recent-documents list (user data, not a cache)
        [[ "$sfl_file" == *"ApplicationRecentDocuments"* ]] && continue
        if ! plutil -lint "$sfl_file" > /dev/null 2>&1; then
            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                safe_remove "$sfl_file" true > /dev/null 2>&1 || true
            fi
            repaired=$((repaired + 1))
        fi
    done < <(command find "$sfl_dir" \( -name "*.sfl2" -o -name "*.sfl3" \) -type f 2> /dev/null || true)

    if [[ $repaired -gt 0 ]]; then
        opt_msg "Repaired $repaired corrupted shared file list(s)"
    else
        opt_msg "Shared file lists all healthy"
    fi
}

# Clean old delivered notifications from NotificationCenter database.
opt_notification_cleanup() {
    local nc_db_dir
    nc_db_dir="$(getconf DARWIN_USER_DIR 2> /dev/null || true)/com.apple.notificationcenter/db2"
    local nc_db="$nc_db_dir/db"

    if [[ ! -f "$nc_db" ]]; then
        opt_msg "Notification Center database not found"
        return 0
    fi

    local db_size
    db_size=$(command du -sk "$nc_db" 2> /dev/null | awk '{print $1}')
    db_size=${db_size:-0}

    # Only clean if database exceeds 50MB (51200 KB)
    if [[ $db_size -lt 51200 ]]; then
        opt_msg "Notification Center database is healthy ($(bytes_to_human $((db_size * 1024))))"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if command -v sqlite3 > /dev/null 2>&1; then
            local sql_ok=0
            sqlite3 "$nc_db" \
                "DELETE FROM record WHERE delivered_date < strftime('%s','now','-30 days'); VACUUM;" \
                2> /dev/null || sql_ok=$?
            if [[ $sql_ok -eq 0 ]]; then
                killall NotificationCenter 2> /dev/null || true
                opt_msg "Notification Center database cleaned (was $(bytes_to_human $((db_size * 1024))))"
            else
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Notification Center cleanup skipped (database busy or locked)"
            fi
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} sqlite3 not available"
        fi
    else
        opt_msg "Notification Center database cleaned (was $(bytes_to_human $((db_size * 1024))))"
    fi
}

# Verify filesystem integrity via diskutil.
opt_disk_verify() {
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        opt_msg "Disk verify · skipped in dry-run"
        return 0
    fi

    local output
    output=$(diskutil verifyVolume / 2>&1 || true)

    if echo "$output" | grep -qi "appears to be OK\|volume appears to be ok"; then
        opt_msg "Disk filesystem verified OK"
    elif echo "$output" | grep -qi "error\|corrupt\|invalid"; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Disk issues detected · run: sudo diskutil repairVolume /"
    else
        opt_msg "Disk verify complete"
    fi
}

# Clean Knowledge/CoreDuet usage tracking databases.
opt_coreduet_cleanup() {
    local knowledge_dir="$HOME/Library/Application Support/Knowledge"
    local knowledge_db="$knowledge_dir/knowledgeC.db"

    if [[ ! -f "$knowledge_db" ]]; then
        opt_msg "Knowledge database not found"
        return 0
    fi

    # Check combined size of WAL/SHM files + database
    local wal_file="$knowledge_db-wal"
    local shm_file="$knowledge_db-shm"
    local total_size=0

    for f in "$knowledge_db" "$wal_file" "$shm_file"; do
        if [[ -f "$f" ]]; then
            local fsize
            fsize=$(command du -sk "$f" 2> /dev/null | awk '{print $1}')
            total_size=$((total_size + ${fsize:-0}))
        fi
    done

    # Skip if combined size < 100MB (102400 KB)
    if [[ $total_size -lt 102400 ]]; then
        opt_msg "Knowledge database is healthy ($(bytes_to_human $((total_size * 1024))))"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        # Remove WAL and SHM files safely (auto-regenerated by SQLite)
        for f in "$wal_file" "$shm_file"; do
            [[ -f "$f" ]] && safe_remove "$f" true > /dev/null 2>&1 || true
        done
        # Remove ZOBJECT entries older than 90 days (CoreTime is Mac epoch: seconds since 2001-01-01)
        if command -v sqlite3 > /dev/null 2>&1; then
            local sql_ok=0
            sqlite3 "$knowledge_db" \
                "DELETE FROM ZOBJECT WHERE ZCREATIONDATE < (strftime('%s','now','-90 days') - strftime('%s','2001-01-01')); VACUUM;" \
                2> /dev/null || sql_ok=$?
            if [[ $sql_ok -eq 0 ]]; then
                opt_msg "Knowledge database cleaned (was $(bytes_to_human $((total_size * 1024))))"
            else
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Knowledge database cleanup skipped (database busy or locked)"
            fi
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} sqlite3 not available"
        fi
    else
        opt_msg "Knowledge database cleaned (was $(bytes_to_human $((total_size * 1024))))"
    fi
}

# Audit login items for broken entries referencing missing apps.
opt_login_items_audit() {
    if [[ "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        opt_msg "Login items audit · skipped in test mode"
        return 0
    fi

    local items_output
    items_output=$(osascript -e 'tell application "System Events" to get the name of every login item' 2> /dev/null || true)

    if [[ -z "$items_output" ]]; then
        opt_msg "No login items found"
        return 0
    fi

    local broken=0
    local checked=0
    # Split on ", " (comma-space) to preserve multi-word names like "Top Calendar" and "mihomo-party"
    local old_ifs="$IFS"
    IFS=',' read -ra items_list <<< "$items_output"
    IFS="$old_ifs"
    for item in "${items_list[@]}"; do
        # Strip leading/trailing spaces from each token
        item="${item# }"
        item="${item% }"
        [[ -z "$item" ]] && continue
        checked=$((checked + 1))
        # Skip items with single quotes to avoid breaking the mdfind query string
        [[ "$item" == *"'"* ]] && continue
        if ! mdfind "kMDItemFSName == '${item}.app'" 2> /dev/null | grep -q .; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Broken login item: $item (app not found)"
            broken=$((broken + 1))
        fi
    done

    if [[ $broken -eq 0 ]]; then
        opt_msg "Login items all healthy ($checked checked)"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} $broken broken login item(s) · remove via System Settings > General > Login Items"
    fi
}

# Dispatch optimization by action name.
execute_optimization() {
    local action="$1"
    local path="${2:-}"

    case "$action" in
        system_maintenance) opt_system_maintenance ;;
        cache_refresh) opt_cache_refresh ;;
        saved_state_cleanup) opt_saved_state_cleanup ;;
        fix_broken_configs) opt_fix_broken_configs ;;
        network_optimization) opt_network_optimization ;;
        quarantine_cleanup) opt_quarantine_cleanup ;;
        sqlite_vacuum) opt_sqlite_vacuum ;;
        launch_services_rebuild) opt_launch_services_rebuild ;;
        font_cache_rebuild) opt_font_cache_rebuild ;;
        dock_refresh) opt_dock_refresh ;;
        prevent_network_dsstore) opt_prevent_network_dsstore ;;
        memory_pressure_relief) opt_memory_pressure_relief ;;
        network_stack_optimize) opt_network_stack_optimize ;;
        disk_permissions_repair) opt_disk_permissions_repair ;;
        bluetooth_reset) opt_bluetooth_reset ;;
        spotlight_index_optimize) opt_spotlight_index_optimize ;;
        launch_agents_cleanup) opt_launch_agents_cleanup ;;
        periodic_maintenance) opt_periodic_maintenance ;;
        shared_file_list_repair) opt_shared_file_list_repair ;;
        notification_cleanup) opt_notification_cleanup ;;
        disk_verify) opt_disk_verify ;;
        coreduet_cleanup) opt_coreduet_cleanup ;;
        login_items_audit) opt_login_items_audit ;;
        *)
            echo -e "${YELLOW}${ICON_ERROR}${NC} Unknown action: $action"
            return 1
            ;;
    esac
}
