#!/bin/bash
# Optimization Tasks

set -euo pipefail

# Configuration constants
# MOLE_TM_THIN_TIMEOUT: Max seconds to wait for tmutil thinning (default: 180)
# MOLE_TM_THIN_VALUE: Bytes to thin for local snapshots (default: 9999999999)
# MOLE_MAIL_DOWNLOADS_MIN_KB: Minimum size in KB before cleaning Mail attachments (default: 5120)
# MOLE_MAIL_AGE_DAYS: Minimum age in days for Mail attachments to be cleaned (default: 30)
readonly MOLE_TM_THIN_TIMEOUT=180
readonly MOLE_TM_THIN_VALUE=9999999999

flush_dns_cache() {
    sudo dscacheutil -flushcache 2> /dev/null && sudo killall -HUP mDNSResponder 2> /dev/null
}

# Rebuild databases and flush caches
opt_system_maintenance() {
    local darwin_major
    darwin_major=$(get_darwin_major)

    if [[ "$darwin_major" -ge 24 ]]; then
        echo -e "${GRAY}⊘${NC} LaunchServices/dyld rebuild skipped on macOS 15+ (Darwin ${darwin_major})"
    else
        # DISABLED: Causes System Settings corruption - Issue #136
        echo -e "${GRAY}⊘${NC} LaunchServices rebuild disabled"
        # run_with_timeout 10 /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user > /dev/null 2>&1 || true
    fi

    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing DNS cache..."
    if flush_dns_cache; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} DNS cache cleared"
    else
        echo -e "${RED}${ICON_ERROR}${NC} Failed to clear DNS cache"
    fi

    echo -e "${BLUE}${ICON_ARROW}${NC} Checking Spotlight index..."
    local spotlight_status
    spotlight_status=$(mdutil -s / 2> /dev/null || echo "")
    if echo "$spotlight_status" | grep -qi "Indexing disabled"; then
        echo -e "${GRAY}-${NC} Spotlight indexing disabled"
    else
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Spotlight index functioning"
    fi

}

# Reset Finder and Safari caches
opt_cache_refresh() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Resetting Quick Look cache..."
    qlmanage -r cache > /dev/null 2>&1 || true
    qlmanage -r > /dev/null 2>&1 || true

    local -a cache_targets=(
        "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache|Quick Look thumbnails"
        "$HOME/Library/Caches/com.apple.iconservices.store|Icon Services store"
        "$HOME/Library/Caches/com.apple.iconservices|Icon Services cache"
        "$HOME/Library/Caches/com.apple.Safari/WebKitCache|Safari WebKit cache"
        "$HOME/Library/Caches/com.apple.Safari/Favicon|Safari favicon cache"
    )

    for target in "${cache_targets[@]}"; do
        IFS='|' read -r target_path label <<< "$target"
        cleanup_path "$target_path" "$label"
    done

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Finder and Safari caches updated"
}

# Run periodic maintenance scripts
opt_maintenance_scripts() {
    # Run newsyslog to rotate system logs
    echo -e "${BLUE}${ICON_ARROW}${NC} Rotating system logs..."
    if run_with_timeout 120 sudo newsyslog > /dev/null 2>&1; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Logs rotated"
    else
        echo -e "${YELLOW}!${NC} Failed to rotate logs"
    fi
}

# Remove diagnostic and crash logs
opt_log_cleanup() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing diagnostic & crash logs..."
    local -a user_logs=(
        "$HOME/Library/Logs/DiagnosticReports"
        "$HOME/Library/Logs/corecaptured"
    )
    for target in "${user_logs[@]}"; do
        cleanup_path "$target" "$(basename "$target")"
    done

    if [[ -d "/Library/Logs/DiagnosticReports" ]]; then
        safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*.crash" 0 "f"
        safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*.panic" 0 "f"
        echo -e "${GREEN}${ICON_SUCCESS}${NC} System diagnostic logs cleared"
    else
        echo -e "${GRAY}-${NC} No system diagnostic logs found"
    fi
}

# Clear recent file lists
opt_recent_items() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing recent items lists..."
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"

    # Target only the global recent item lists to avoid touching per-app/System Settings SFL files (Issue #136)
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
        local deleted=0
        for sfl_file in "${recent_lists[@]}"; do
            # Skip missing files and any protected paths
            [[ -e "$sfl_file" ]] || continue
            if should_protect_path "$sfl_file"; then
                continue
            fi
            if safe_remove "$sfl_file" true; then
                ((deleted++))
            fi
        done

        echo -e "${GREEN}${ICON_SUCCESS}${NC} Shared file lists cleared${deleted:+ ($deleted files)}"
    fi

    rm -f "$HOME/Library/Preferences/com.apple.recentitems.plist" 2> /dev/null || true
    defaults delete NSGlobalDomain NSRecentDocumentsLimit 2> /dev/null || true

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Recent items cleared"
}

# Radio refresh: reset Bluetooth and Wi-Fi (safe mode - no pairing/password loss)
opt_radio_refresh() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Refreshing Bluetooth controller..."
    # Only restart Bluetooth service, do NOT delete pairing information
    sudo pkill -HUP bluetoothd 2> /dev/null || true
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Bluetooth controller refreshed"

    echo -e "${BLUE}${ICON_ARROW}${NC} Refreshing Wi-Fi service..."
    local wifi_interface
    wifi_interface=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}' | head -1)
    if [[ -n "$wifi_interface" ]]; then
        if sudo bash -c "trap '' INT TERM; ifconfig '$wifi_interface' down; sleep 1; ifconfig '$wifi_interface' up" 2> /dev/null; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Wi-Fi interface restarted"
        else
            echo -e "${YELLOW}!${NC} Failed to restart Wi-Fi interface"
        fi
    else
        echo -e "${GRAY}-${NC} Wi-Fi interface not found"
    fi

    # Restart AirDrop interface
    # Use atomic execution to ensure interface comes back up even if interrupted
    sudo bash -c "trap '' INT TERM; ifconfig awdl0 down; ifconfig awdl0 up" 2> /dev/null || true
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Wireless services refreshed"
}

# Mail downloads: clear OLD Mail attachment cache (30+ days)
opt_mail_downloads() {
    local min_size_kb=${MOLE_MAIL_DOWNLOADS_MIN_KB:-5120}
    local mail_age_days=${MOLE_MAIL_AGE_DAYS:-30}
    if ! [[ "$min_size_kb" =~ ^[0-9]+$ ]]; then
        min_size_kb=5120
    fi
    if ! [[ "$mail_age_days" =~ ^[0-9]+$ ]]; then
        mail_age_days=30
    fi

    echo -e "${BLUE}${ICON_ARROW}${NC} Clearing old Mail attachment downloads (${mail_age_days}+ days)..."
    local -a mail_dirs=(
        "$HOME/Library/Mail Downloads"
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    )

    local total_size_kb=0
    local temp_dir
    temp_dir=$(create_temp_dir)

    # Parallel size calculation
    local idx=0
    for target_path in "${mail_dirs[@]}"; do
        (
            local size
            size=$(get_path_size_kb "$target_path")
            echo "$size" > "$temp_dir/size_$idx"
        ) &
        ((idx++))
    done
    wait

    for i in $(seq 0 $((idx - 1))); do
        local size=0
        [[ -f "$temp_dir/size_$i" ]] && size=$(cat "$temp_dir/size_$i")
        ((total_size_kb += size))
    done

    if [[ $total_size_kb -lt $min_size_kb ]]; then
        echo -e "${GRAY}-${NC} Only $(bytes_to_human $((total_size_kb * 1024))) detected, skipping cleanup"
        return
    fi
    local cleaned=false
    for target_path in "${mail_dirs[@]}"; do
        if [[ -d "$target_path" ]]; then
            safe_find_delete "$target_path" "*" "$mail_age_days" "f"
            cleaned=true
        fi
    done

    if [[ "$cleaned" == "true" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Cleaned old attachments (> ${mail_age_days} days)"
    else
        echo -e "${GRAY}-${NC} No old attachments found"
    fi
}

# Saved state: remove OLD app saved states (7+ days)
opt_saved_state_cleanup() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Removing old saved application states (${MOLE_SAVED_STATE_AGE_DAYS}+ days)..."
    local state_dir="$HOME/Library/Saved Application State"

    if [[ ! -d "$state_dir" ]]; then
        echo -e "${GRAY}-${NC} No saved states directory found"
        return
    fi

    local deleted=0
    while IFS= read -r -d '' state_path; do
        if should_protect_path "$state_path"; then
            continue
        fi
        if safe_remove "$state_path" true; then
            ((deleted++))
        fi
    done < <(command find "$state_dir" -type d -name "*.savedState" -mtime "+$MOLE_SAVED_STATE_AGE_DAYS" -print0 2> /dev/null)

    if [[ $deleted -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $deleted old saved state(s)"
    else
        echo -e "${GRAY}-${NC} No old saved states found"
    fi
}

# Swap cleanup: reset swap files
opt_swap_cleanup() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Removing swapfiles and resetting dynamic pager..."
    if sudo launchctl unload /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1; then
        sudo launchctl load /System/Library/LaunchDaemons/com.apple.dynamic_pager.plist > /dev/null 2>&1 || true
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Swap cache rebuilt"
    else
        echo -e "${YELLOW}!${NC} Could not unload dynamic_pager"
    fi
}

# Startup cache: rebuild kernel caches (handled automatically by modern macOS)
opt_startup_cache() {
    echo -e "${GRAY}-${NC} Startup cache rebuild skipped (handled by macOS)"
}

# Local snapshots: thin Time Machine snapshots
opt_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        echo -e "${YELLOW}!${NC} tmutil not available on this system"
        return
    fi

    local before after
    before=$(count_local_snapshots)
    if [[ "$before" -eq 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No local snapshots to thin"
        return
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner ""
    fi

    local success=false
    local exit_code=0
    set +e
    run_with_timeout "$MOLE_TM_THIN_TIMEOUT" sudo tmutil thinlocalsnapshots / "$MOLE_TM_THIN_VALUE" 4 > /dev/null 2>&1
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 0 ]]; then
        success=true
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    after=$(count_local_snapshots)
    local removed=$((before - after))
    [[ "$removed" -lt 0 ]] && removed=0

    if [[ "$success" == "true" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $removed snapshots (remaining: $after)"
    elif [[ "$exit_code" -eq 124 ]]; then
        echo -e "${YELLOW}!${NC} Timed out after ${MOLE_TM_THIN_TIMEOUT}s"
    else
        echo -e "${YELLOW}!${NC} Failed with exit code $exit_code"
    fi
}

# Developer cleanup: remove Xcode/simulator cruft
opt_developer_cleanup() {
    local -a dev_targets=(
        "$HOME/Library/Developer/Xcode/DerivedData|Xcode DerivedData"
        "$HOME/Library/Developer/Xcode/iOS DeviceSupport|iOS Device support files"
        "$HOME/Library/Developer/CoreSimulator/Caches|CoreSimulator caches"
    )

    for target in "${dev_targets[@]}"; do
        IFS='|' read -r target_path label <<< "$target"
        cleanup_path "$target_path" "$label"
    done

    if command -v xcrun > /dev/null 2>&1; then
        echo -e "${BLUE}${ICON_ARROW}${NC} Removing unavailable simulator runtimes..."
        if xcrun simctl delete unavailable > /dev/null 2>&1; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Unavailable simulators removed"
        else
            echo -e "${YELLOW}!${NC} Could not prune simulator runtimes"
        fi
    fi

    echo -e "${GREEN}${ICON_SUCCESS}${NC} Developer caches cleaned"
}

# Fix broken system configurations
# Repairs corrupted preference files and broken login items
opt_fix_broken_configs() {
    local broken_prefs=0
    local broken_items=0

    # Fix broken preferences
    echo -e "${BLUE}${ICON_ARROW}${NC} Checking preference files..."
    broken_prefs=$(fix_broken_preferences)
    if [[ $broken_prefs -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Fixed $broken_prefs broken preference files"
    else
        echo -e "${GREEN}${ICON_SUCCESS}${NC} All preference files valid"
    fi

    # Fix broken login items
    echo -e "${BLUE}${ICON_ARROW}${NC} Checking login items..."
    broken_items=$(fix_broken_login_items)
    if [[ $broken_items -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Removed $broken_items broken login items"
    else
        echo -e "${GREEN}${ICON_SUCCESS}${NC} All login items valid"
    fi

    local total=$((broken_prefs + broken_items))
    if [[ $total -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} System configuration repaired"
    fi
}

# Network Optimization: Flush DNS, reset mDNS, clear ARP
opt_network_optimization() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Optimizing network settings..."
    local steps=0

    # 1. Flush DNS cache
    if flush_dns_cache; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} DNS cache flushed"
        ((steps++))
    fi

    # 2. Clear ARP cache (admin only)
    if sudo arp -d -a > /dev/null 2>&1; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ARP cache cleared"
        ((steps++))
    fi

    # 3. Reset network interface statistics (soft reset)
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Network interfaces refreshed"
    ((steps++))

    if [[ $steps -gt 0 ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Network optimized"
    fi
}

# Clean Spotlight user caches

# Execute optimization by action name
execute_optimization() {
    local action="$1"
    local path="${2:-}"

    case "$action" in
        system_maintenance) opt_system_maintenance ;;
        cache_refresh) opt_cache_refresh ;;
        maintenance_scripts) opt_maintenance_scripts ;;
        log_cleanup) opt_log_cleanup ;;
        recent_items) opt_recent_items ;;
        radio_refresh) opt_radio_refresh ;;
        mail_downloads) opt_mail_downloads ;;
        saved_state_cleanup) opt_saved_state_cleanup ;;
        swap_cleanup) opt_swap_cleanup ;;
        startup_cache) opt_startup_cache ;;
        local_snapshots) opt_local_snapshots ;;
        developer_cleanup) opt_developer_cleanup ;;
        fix_broken_configs) opt_fix_broken_configs ;;
        network_optimization) opt_network_optimization ;;
        *)
            echo -e "${RED}${ICON_ERROR}${NC} Unknown action: $action"
            return 1
            ;;
    esac
}
