#!/bin/bash
# System Checks Module
# Combines configuration, security, updates, and health checks

set -euo pipefail

# ============================================================================
# Helper Functions
# ============================================================================

list_login_items() {
    if ! command -v osascript > /dev/null 2>&1; then
        return
    fi

    local raw_items
    raw_items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2> /dev/null || echo "")
    [[ -z "$raw_items" || "$raw_items" == "missing value" ]] && return

    IFS=',' read -ra login_items_array <<< "$raw_items"
    for entry in "${login_items_array[@]}"; do
        local trimmed
        trimmed=$(echo "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -n "$trimmed" ]] && printf "%s\n" "$trimmed"
    done
}

# ============================================================================
# Configuration Checks
# ============================================================================

check_touchid_sudo() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_touchid"; then return; fi
    # Check if Touch ID is configured for sudo
    local pam_file="/etc/pam.d/sudo"
    if [[ -f "$pam_file" ]] && grep -q "pam_tid.so" "$pam_file" 2> /dev/null; then
        echo -e "  ${GREEN}✓${NC} Touch ID     Enabled for sudo"
    else
        # Check if Touch ID is supported
        local is_supported=false
        if command -v bioutil > /dev/null 2>&1; then
            if bioutil -r 2> /dev/null | grep -q "Touch ID"; then
                is_supported=true
            fi
        elif [[ "$(uname -m)" == "arm64" ]]; then
            is_supported=true
        fi

        if [[ "$is_supported" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Touch ID     ${YELLOW}Not configured${NC} for sudo"
            export TOUCHID_NOT_CONFIGURED=true
        fi
    fi
}

check_rosetta() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_rosetta"; then return; fi
    # Check Rosetta 2 (for Apple Silicon Macs)
    if [[ "$(uname -m)" == "arm64" ]]; then
        if [[ -f "/Library/Apple/usr/share/rosetta/rosetta" ]]; then
            echo -e "  ${GREEN}✓${NC} Rosetta 2    Installed"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Rosetta 2    ${YELLOW}Not installed${NC}"
            export ROSETTA_NOT_INSTALLED=true
        fi
    fi
}

check_git_config() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_git_config"; then return; fi
    # Check basic Git configuration
    if command -v git > /dev/null 2>&1; then
        local git_name=$(git config --global user.name 2> /dev/null || echo "")
        local git_email=$(git config --global user.email 2> /dev/null || echo "")

        if [[ -n "$git_name" && -n "$git_email" ]]; then
            echo -e "  ${GREEN}✓${NC} Git Config   Configured"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Git Config   ${YELLOW}Not configured${NC}"
        fi
    fi
}

check_all_config() {
    check_touchid_sudo
    check_rosetta
    check_git_config
}

# ============================================================================
# Security Checks
# ============================================================================

check_filevault() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_filevault"; then return; fi
    # Check FileVault encryption status
    if command -v fdesetup > /dev/null 2>&1; then
        local fv_status=$(fdesetup status 2> /dev/null || echo "")
        if echo "$fv_status" | grep -q "FileVault is On"; then
            echo -e "  ${GREEN}✓${NC} FileVault    Enabled"
        else
            echo -e "  ${RED}✗${NC} FileVault    ${RED}Disabled${NC} (Recommend enabling)"
            export FILEVAULT_DISABLED=true
        fi
    fi
}

check_firewall() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "firewall"; then return; fi
    # Check firewall status
    unset FIREWALL_DISABLED
    local firewall_status=$(defaults read /Library/Preferences/com.apple.alf globalstate 2> /dev/null || echo "0")
    if [[ "$firewall_status" == "1" || "$firewall_status" == "2" ]]; then
        echo -e "  ${GREEN}✓${NC} Firewall     Enabled"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Firewall     ${YELLOW}Disabled${NC} (Consider enabling)"
        echo -e "    ${GRAY}System Settings → Network → Firewall, or run:${NC}"
        echo -e "    ${GRAY}sudo defaults write /Library/Preferences/com.apple.alf globalstate -int 1${NC}"
        export FIREWALL_DISABLED=true
    fi
}

check_gatekeeper() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "gatekeeper"; then return; fi
    # Check Gatekeeper status
    if command -v spctl > /dev/null 2>&1; then
        local gk_status=$(spctl --status 2> /dev/null || echo "")
        if echo "$gk_status" | grep -q "enabled"; then
            echo -e "  ${GREEN}✓${NC} Gatekeeper   Active"
            unset GATEKEEPER_DISABLED
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Gatekeeper   ${YELLOW}Disabled${NC}"
            echo -e "    ${GRAY}Enable via System Settings → Privacy & Security, or:${NC}"
            echo -e "    ${GRAY}sudo spctl --master-enable${NC}"
            export GATEKEEPER_DISABLED=true
        fi
    fi
}

check_sip() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_sip"; then return; fi
    # Check System Integrity Protection
    if command -v csrutil > /dev/null 2>&1; then
        local sip_status=$(csrutil status 2> /dev/null || echo "")
        if echo "$sip_status" | grep -q "enabled"; then
            echo -e "  ${GREEN}✓${NC} SIP          Enabled"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} SIP          ${YELLOW}Disabled${NC}"
            echo -e "    ${GRAY}Restart into Recovery → Utilities → Terminal → run: csrutil enable${NC}"
        fi
    fi
}

check_all_security() {
    check_filevault
    check_firewall
    check_gatekeeper
    check_sip
}

# ============================================================================
# Software Update Checks
# ============================================================================

# Cache configuration
CACHE_DIR="${HOME}/.cache/mole"
CACHE_TTL=600 # 10 minutes in seconds

# Ensure cache directory exists
ensure_user_dir "$CACHE_DIR"

clear_cache_file() {
    local file="$1"
    rm -f "$file" 2> /dev/null || true
}

reset_brew_cache() {
    clear_cache_file "$CACHE_DIR/brew_updates"
}

reset_softwareupdate_cache() {
    clear_cache_file "$CACHE_DIR/softwareupdate_list"
    SOFTWARE_UPDATE_LIST=""
}

reset_mole_cache() {
    clear_cache_file "$CACHE_DIR/mole_version"
}

# Check if cache is still valid
is_cache_valid() {
    local cache_file="$1"
    local ttl="${2:-$CACHE_TTL}"

    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    local cache_age=$(($(date +%s) - $(get_file_mtime "$cache_file")))
    [[ $cache_age -lt $ttl ]]
}

# Cache software update list to avoid calling softwareupdate twice
SOFTWARE_UPDATE_LIST=""

get_software_updates() {
    local cache_file="$CACHE_DIR/softwareupdate_list"

    # Optimized: Use defaults to check if updates are pending (much faster)
    local pending_updates
    pending_updates=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate LastRecommendedUpdatesAvailable 2> /dev/null || echo "0")

    if [[ "$pending_updates" -gt 0 ]]; then
        echo "Updates Available"
    else
        echo ""
    fi
}

check_appstore_updates() {
    # Skipped for speed optimization - consolidated into check_macos_update
    # We can't easily distinguish app store vs macos updates without the slow softwareupdate -l call
    export APPSTORE_UPDATE_COUNT=0
}

check_macos_update() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_macos_updates"; then return; fi

    # Fast check using system preferences
    local updates_available="false"
    if [[ $(get_software_updates) == "Updates Available" ]]; then
        updates_available="true"

        # Verify with softwareupdate -l (short timeout) to reduce false positives
        local sw_output=""
        local sw_status=0
        local spinner_started=false
        if [[ -t 1 ]]; then
            start_inline_spinner "Checking macOS updates..."
            spinner_started=true
        fi

        if ! sw_output=$(run_with_timeout 5 softwareupdate -l 2> /dev/null); then
            sw_status=$?
        fi

        if [[ "$spinner_started" == "true" ]]; then
            stop_inline_spinner
        fi

        # If command failed, timed out, or returned empty, treat as no updates to avoid false positives
        if [[ $sw_status -ne 0 || -z "$sw_output" ]]; then
            updates_available="false"
        elif echo "$sw_output" | grep -q "No new software available"; then
            updates_available="false"
        fi
    fi

    export MACOS_UPDATE_AVAILABLE="$updates_available"

    if [[ "$updates_available" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} macOS        ${YELLOW}Update available${NC}"
    else
        echo -e "  ${GREEN}✓${NC} macOS        Up to date"
    fi
}

check_mole_update() {
    # Check if Mole has updates
    # Auto-detect version from mole main script
    local current_version
    if [[ -f "${SCRIPT_DIR:-/usr/local/bin}/mole" ]]; then
        current_version=$(grep '^VERSION=' "${SCRIPT_DIR:-/usr/local/bin}/mole" 2> /dev/null | head -1 | sed 's/VERSION="\(.*\)"/\1/' || echo "unknown")
    else
        current_version="${VERSION:-unknown}"
    fi

    local latest_version=""
    local cache_file="$CACHE_DIR/mole_version"

    export MOLE_UPDATE_AVAILABLE="false"

    # Check cache first
    if is_cache_valid "$cache_file"; then
        latest_version=$(cat "$cache_file" 2> /dev/null || echo "")
    else
        # Show spinner while checking
        if [[ -t 1 ]]; then
            start_inline_spinner "Checking Mole version..."
        fi

        # Try to get latest version from GitHub
        if command -v curl > /dev/null 2>&1; then
            latest_version=$(curl -fsSL https://api.github.com/repos/tw93/mole/releases/latest 2> /dev/null | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/' || echo "")
            # Save to cache
            if [[ -n "$latest_version" ]]; then
                ensure_user_file "$cache_file"
                echo "$latest_version" > "$cache_file" 2> /dev/null || true
            fi
        fi

        # Stop spinner
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
    fi

    # Normalize version strings (remove leading 'v' or 'V')
    current_version="${current_version#v}"
    current_version="${current_version#V}"
    latest_version="${latest_version#v}"
    latest_version="${latest_version#V}"

    if [[ -n "$latest_version" && "$current_version" != "$latest_version" ]]; then
        # Compare versions
        if [[ "$(printf '%s\n' "$current_version" "$latest_version" | sort -V | head -1)" == "$current_version" ]]; then
            export MOLE_UPDATE_AVAILABLE="true"
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Mole         ${YELLOW}${latest_version} available${NC} (current: ${current_version})"
            echo -e "    ${GRAY}Run: ${GREEN}mo update${NC}"
        else
            echo -e "  ${GREEN}✓${NC} Mole         Up to date (${current_version})"
        fi
    else
        echo -e "  ${GREEN}✓${NC} Mole         Up to date (${current_version})"
    fi
}

check_all_updates() {
    # Reset spinner flag for softwareupdate
    unset SOFTWAREUPDATE_SPINNER_SHOWN

    # Preload software update data to avoid delays between subsequent checks
    # Only redirect stdout, keep stderr for spinner display
    get_software_updates > /dev/null

    check_appstore_updates
    check_macos_update
    check_mole_update
}

get_appstore_update_labels() {
    get_software_updates | awk '
        /^\*/ {
            label=$0
            sub(/^[[:space:]]*\* Label: */, "", label)
            sub(/,.*/, "", label)
            lower=tolower(label)
            if (index(lower, "macos") == 0) {
                print label
            }
        }
    '
}

get_macos_update_labels() {
    get_software_updates | awk '
        /^\*/ {
            label=$0
            sub(/^[[:space:]]*\* Label: */, "", label)
            sub(/,.*/, "", label)
            lower=tolower(label)
            if (index(lower, "macos") != 0) {
                print label
            }
        }
    '
}

# ============================================================================
# System Health Checks
# ============================================================================

check_disk_space() {
    local free_gb=$(command df -H / | awk 'NR==2 {print $4}' | sed 's/G//')
    local free_num=$(echo "$free_gb" | tr -d 'G' | cut -d'.' -f1)

    export DISK_FREE_GB=$free_num

    if [[ $free_num -lt 20 ]]; then
        echo -e "  ${RED}✗${NC} Disk Space   ${RED}${free_gb}GB free${NC} (Critical)"
    elif [[ $free_num -lt 50 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Disk Space   ${YELLOW}${free_gb}GB free${NC} (Low)"
    else
        echo -e "  ${GREEN}✓${NC} Disk Space   ${free_gb}GB free"
    fi
}

check_memory_usage() {
    local mem_total
    mem_total=$(sysctl -n hw.memsize 2> /dev/null || echo "0")
    if [[ -z "$mem_total" || "$mem_total" -le 0 ]]; then
        echo -e "  ${GRAY}-${NC} Memory       Unable to determine"
        return
    fi

    local vm_output
    vm_output=$(vm_stat 2> /dev/null || echo "")

    local page_size
    page_size=$(echo "$vm_output" | awk '/page size of/ {print $8}')
    [[ -z "$page_size" ]] && page_size=4096

    local free_pages inactive_pages spec_pages
    free_pages=$(echo "$vm_output" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    inactive_pages=$(echo "$vm_output" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
    spec_pages=$(echo "$vm_output" | awk '/Pages speculative/ {gsub(/\./,"",$3); print $3}')

    free_pages=${free_pages:-0}
    inactive_pages=${inactive_pages:-0}
    spec_pages=${spec_pages:-0}

    # Estimate used percent: (total - free - inactive - speculative) / total
    local total_pages=$((mem_total / page_size))
    local free_total=$((free_pages + inactive_pages + spec_pages))
    local used_pages=$((total_pages - free_total))
    if ((used_pages < 0)); then
        used_pages=0
    fi

    local used_percent
    used_percent=$(awk "BEGIN {printf \"%.0f\", ($used_pages / $total_pages) * 100}")
    ((used_percent > 100)) && used_percent=100
    ((used_percent < 0)) && used_percent=0

    if [[ $used_percent -gt 90 ]]; then
        echo -e "  ${RED}✗${NC} Memory       ${RED}${used_percent}% used${NC} (Critical)"
    elif [[ $used_percent -gt 80 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Memory       ${YELLOW}${used_percent}% used${NC} (High)"
    else
        echo -e "  ${GREEN}✓${NC} Memory       ${used_percent}% used"
    fi
}

check_login_items() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_login_items"; then return; fi
    local login_items_count=0
    local -a login_items_list=()

    if [[ -t 0 ]]; then
        # Show spinner while getting login items
        if [[ -t 1 ]]; then
            start_inline_spinner "Checking login items..."
        fi

        while IFS= read -r login_item; do
            [[ -n "$login_item" ]] && login_items_list+=("$login_item")
        done < <(list_login_items || true)
        login_items_count=${#login_items_list[@]}

        # Stop spinner before output
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
    fi

    if [[ $login_items_count -gt 15 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Login Items  ${YELLOW}${login_items_count} apps${NC} auto-start (High)"
    elif [[ $login_items_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Login Items  ${login_items_count} apps auto-start"
    else
        echo -e "  ${GREEN}✓${NC} Login Items  None"
        return
    fi

    # Show items in a single line
    local preview_limit=5
    ((preview_limit > login_items_count)) && preview_limit=$login_items_count

    local items_display=""
    for ((i = 0; i < preview_limit; i++)); do
        if [[ $i -eq 0 ]]; then
            items_display="${login_items_list[$i]}"
        else
            items_display="${items_display}, ${login_items_list[$i]}"
        fi
    done

    if ((login_items_count > preview_limit)); then
        local remaining=$((login_items_count - preview_limit))
        items_display="${items_display}, and ${remaining} more"
    fi

    echo -e "    ${GRAY}${items_display}${NC}"
    echo -e "    ${GRAY}Manage in System Settings → Login Items${NC}"
}

check_cache_size() {
    local cache_size_kb=0

    # Check common cache locations
    local -a cache_paths=(
        "$HOME/Library/Caches"
        "$HOME/Library/Logs"
    )

    # Show spinner while calculating cache size
    if [[ -t 1 ]]; then
        start_inline_spinner "Scanning cache..."
    fi

    for cache_path in "${cache_paths[@]}"; do
        if [[ -d "$cache_path" ]]; then
            local size_output
            size_output=$(get_path_size_kb "$cache_path")
            [[ "$size_output" =~ ^[0-9]+$ ]] || size_output=0
            cache_size_kb=$((cache_size_kb + size_output))
        fi
    done

    local cache_size_gb=$(echo "scale=1; $cache_size_kb / 1024 / 1024" | bc)
    export CACHE_SIZE_GB=$cache_size_gb

    # Stop spinner before output
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Convert to integer for comparison
    local cache_size_int=$(echo "$cache_size_gb" | cut -d'.' -f1)

    if [[ $cache_size_int -gt 10 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Cache Size   ${YELLOW}${cache_size_gb}GB${NC} cleanable"
    elif [[ $cache_size_int -gt 5 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Cache Size   ${YELLOW}${cache_size_gb}GB${NC} cleanable"
    else
        echo -e "  ${GREEN}✓${NC} Cache Size   ${cache_size_gb}GB"
    fi
}

check_swap_usage() {
    # Check swap usage
    if command -v sysctl > /dev/null 2>&1; then
        local swap_info=$(sysctl vm.swapusage 2> /dev/null || echo "")
        if [[ -n "$swap_info" ]]; then
            local swap_used=$(echo "$swap_info" | grep -o "used = [0-9.]*[GM]" | awk '{print $3}' || echo "0M")
            local swap_num="${swap_used//[GM]/}"

            if [[ "$swap_used" == *"G"* ]]; then
                local swap_gb=${swap_num%.*}
                if [[ $swap_gb -gt 2 ]]; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Swap Usage   ${YELLOW}${swap_used}${NC} (High)"
                else
                    echo -e "  ${GREEN}✓${NC} Swap Usage   ${swap_used}"
                fi
            else
                echo -e "  ${GREEN}✓${NC} Swap Usage   ${swap_used}"
            fi
        fi
    fi
}

check_brew_health() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_brew_health"; then return; fi
}

check_system_health() {
    check_disk_space
    check_memory_usage
    check_swap_usage
    check_login_items
    check_cache_size
    # Time Machine check is optional; skip by default to avoid noise on systems without backups
}
