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

    # Skip AppleScript during tests to avoid permission dialogs
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
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
        echo -e "  ${GREEN}✓${NC} Touch ID     Biometric authentication enabled"
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
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Touch ID     ${YELLOW}Not configured for sudo${NC}"
            export TOUCHID_NOT_CONFIGURED=true
        fi
    fi
}

check_rosetta() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_rosetta"; then return; fi
    # Check Rosetta 2 (for Apple Silicon Macs) - informational only, not auto-fixed
    if [[ "$(uname -m)" == "arm64" ]]; then
        if [[ -f "/Library/Apple/usr/share/rosetta/rosetta" ]]; then
            echo -e "  ${GREEN}✓${NC} Rosetta 2    Intel app translation ready"
        else
            echo -e "  ${GRAY}${ICON_EMPTY}${NC} Rosetta 2    ${GRAY}Not installed${NC}"
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
            echo -e "  ${GREEN}✓${NC} Git          Global identity configured"
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Git          ${YELLOW}User identity not set${NC}"
        fi
    fi
}

check_all_config() {
    echo -e "${BLUE}${ICON_ARROW}${NC} System Configuration"
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
            echo -e "  ${GREEN}✓${NC} FileVault    Disk encryption active"
        else
            echo -e "  ${RED}✗${NC} FileVault    ${RED}Disk encryption disabled${NC}"
            export FILEVAULT_DISABLED=true
        fi
    fi
}

check_firewall() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "firewall"; then return; fi

    unset FIREWALL_DISABLED

    # Check third-party firewalls first (lightweight path-based detection, no sudo required)
    local third_party_firewall=""
    if [[ -d "/Applications/Little Snitch.app" ]] || [[ -d "/Library/Little Snitch" ]]; then
        third_party_firewall="Little Snitch"
    elif [[ -d "/Applications/LuLu.app" ]]; then
        third_party_firewall="LuLu"
    elif [[ -d "/Applications/Radio Silence.app" ]]; then
        third_party_firewall="Radio Silence"
    elif [[ -d "/Applications/Hands Off!.app" ]]; then
        third_party_firewall="Hands Off!"
    elif [[ -d "/Applications/Murus.app" ]]; then
        third_party_firewall="Murus"
    elif [[ -d "/Applications/Vallum.app" ]]; then
        third_party_firewall="Vallum"
    fi

    if [[ -n "$third_party_firewall" ]]; then
        echo -e "  ${GREEN}✓${NC} Firewall     ${third_party_firewall} active"
        return
    fi

    # Fall back to macOS built-in firewall check
    local firewall_output=$(sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2> /dev/null || echo "")
    if [[ "$firewall_output" == *"State = 1"* ]] || [[ "$firewall_output" == *"State = 2"* ]]; then
        echo -e "  ${GREEN}✓${NC} Firewall     Network protection enabled"
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Firewall     ${YELLOW}Network protection disabled${NC}"
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
            echo -e "  ${GREEN}✓${NC} Gatekeeper   App download protection active"
            unset GATEKEEPER_DISABLED
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Gatekeeper   ${YELLOW}App security disabled${NC}"
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
            echo -e "  ${GREEN}✓${NC} SIP          System integrity protected"
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} SIP          ${YELLOW}System protection disabled${NC}"
        fi
    fi
}

check_all_security() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Security Status"
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
    SOFTWARE_UPDATE_LIST_LOADED="false"
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

    local cache_age=$(($(get_epoch_seconds) - $(get_file_mtime "$cache_file")))
    [[ $cache_age -lt $ttl ]]
}

# Cache software update list to avoid calling softwareupdate twice
SOFTWARE_UPDATE_LIST=""
SOFTWARE_UPDATE_LIST_LOADED="false"

software_update_has_entries() {
    printf '%s\n' "$1" | grep -qE '^[[:space:]]*\* Label:'
}

is_macos_software_update_text() {
    local text
    text=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')

    case "$text" in
        *macos* | *background\ security\ improvement* | *rapid\ security\ response* | *security\ response*)
            return 0
            ;;
    esac

    return 1
}

get_first_macos_software_update_summary() {
    printf '%s\n' "$1" | awk '
        /^\* Label:/ {
            label=$0
            sub(/^[[:space:]]*\* Label: */, "", label)
            next
        }
        /^[[:space:]]*Title:/ {
            title=$0
            sub(/^[[:space:]]*Title: */, "", title)
            sub(/, Version:.*/, "", title)
            sub(/, Size:.*/, "", title)
            combined=tolower(label " " title)
            if (combined ~ /macos|background security improvement|rapid security response|security response/) {
                print title
                exit
            }
        }
    '
}

get_software_updates() {
    local cache_file="$CACHE_DIR/softwareupdate_list"
    if [[ "${SOFTWARE_UPDATE_LIST_LOADED:-false}" == "true" ]]; then
        printf '%s\n' "$SOFTWARE_UPDATE_LIST"
        return 0
    fi

    if is_cache_valid "$cache_file"; then
        SOFTWARE_UPDATE_LIST=$(cat "$cache_file" 2> /dev/null || true)
        SOFTWARE_UPDATE_LIST_LOADED="true"
        printf '%s\n' "$SOFTWARE_UPDATE_LIST"
        return 0
    fi

    local spinner_started=false
    if [[ -t 1 && -z "${SOFTWAREUPDATE_SPINNER_SHOWN:-}" ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking system updates..."
        spinner_started=true
        export SOFTWAREUPDATE_SPINNER_SHOWN=1
    fi

    local output=""
    local sw_status=0
    if output=$(run_with_timeout 10 softwareupdate -l --no-scan 2> /dev/null); then
        SOFTWARE_UPDATE_LIST="$output"
        ensure_user_file "$cache_file"
        printf '%s' "$SOFTWARE_UPDATE_LIST" > "$cache_file" 2> /dev/null || true
    else
        sw_status=$?
        SOFTWARE_UPDATE_LIST=""
        if [[ -f "$cache_file" ]]; then
            SOFTWARE_UPDATE_LIST=$(cat "$cache_file" 2> /dev/null || true)
        fi
        if [[ -n "${MO_DEBUG:-}" ]]; then
            echo "[DEBUG] softwareupdate preload exit status: $sw_status" >&2
        fi
    fi

    if [[ "$spinner_started" == "true" ]]; then
        stop_inline_spinner
    fi

    SOFTWARE_UPDATE_LIST_LOADED="true"
    printf '%s\n' "$SOFTWARE_UPDATE_LIST"
}

check_homebrew_updates() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_homebrew_updates"; then return; fi

    export BREW_OUTDATED_COUNT=0
    export BREW_FORMULA_OUTDATED_COUNT=0
    export BREW_CASK_OUTDATED_COUNT=0

    if ! command -v brew > /dev/null 2>&1; then
        printf "  ${GRAY}${ICON_EMPTY}${NC} %-12s %s\n" "Homebrew" "Not installed"
        return
    fi

    local cache_file="$CACHE_DIR/brew_updates"
    local formula_count=0
    local cask_count=0
    local total_count=0
    local use_cache=false

    if is_cache_valid "$cache_file"; then
        local cached_formula=""
        local cached_cask=""
        IFS=' ' read -r cached_formula cached_cask < "$cache_file" || true
        if [[ "$cached_formula" =~ ^[0-9]+$ && "$cached_cask" =~ ^[0-9]+$ ]]; then
            formula_count="$cached_formula"
            cask_count="$cached_cask"
            use_cache=true
        fi
    fi

    if [[ "$use_cache" == "false" ]]; then
        local formula_outdated=""
        local cask_outdated=""
        local formula_status=0
        local cask_status=0
        local spinner_started=false

        if [[ -t 1 ]]; then
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking Homebrew updates..."
            spinner_started=true
        fi

        local _brew_formula_tmp _brew_cask_tmp
        _brew_formula_tmp=$(mktemp_file "brew_formula")
        _brew_cask_tmp=$(mktemp_file "brew_cask")
        (
            run_with_timeout 8 brew outdated --formula --quiet > "$_brew_formula_tmp" 2> /dev/null
            echo $? > "${_brew_formula_tmp}.status"
        ) &
        local _formula_pid=$!
        (
            run_with_timeout 8 brew outdated --cask --quiet > "$_brew_cask_tmp" 2> /dev/null
            echo $? > "${_brew_cask_tmp}.status"
        ) &
        local _cask_pid=$!
        wait "$_formula_pid" 2> /dev/null || true
        wait "$_cask_pid" 2> /dev/null || true
        formula_outdated=$(cat "$_brew_formula_tmp" 2> /dev/null || true)
        cask_outdated=$(cat "$_brew_cask_tmp" 2> /dev/null || true)
        formula_status=$(cat "${_brew_formula_tmp}.status" 2> /dev/null || echo "1")
        cask_status=$(cat "${_brew_cask_tmp}.status" 2> /dev/null || echo "1")
        rm -f "$_brew_formula_tmp" "$_brew_cask_tmp" "${_brew_formula_tmp}.status" "${_brew_cask_tmp}.status" 2> /dev/null || true

        if [[ "$spinner_started" == "true" ]]; then
            stop_inline_spinner
        fi

        if [[ $formula_status -eq 0 || $cask_status -eq 0 ]]; then
            formula_count=$(printf '%s\n' "$formula_outdated" | awk 'NF {count++} END {print count + 0}')
            cask_count=$(printf '%s\n' "$cask_outdated" | awk 'NF {count++} END {print count + 0}')
            # Only cache when both calls succeeded; partial results (one side failed)
            # must not be written as zeros — next run should retry the failed side.
            if [[ $formula_status -eq 0 && $cask_status -eq 0 ]]; then
                ensure_user_file "$cache_file"
                printf '%s %s\n' "$formula_count" "$cask_count" > "$cache_file" 2> /dev/null || true
            fi
        elif [[ $formula_status -eq 124 || $cask_status -eq 124 ]]; then
            printf "  ${GRAY}${ICON_WARNING}${NC} %-12s ${YELLOW}%s${NC}\n" "Homebrew" "Check timed out"
            return
        else
            printf "  ${GRAY}${ICON_WARNING}${NC} %-12s ${YELLOW}%s${NC}\n" "Homebrew" "Check failed"
            return
        fi
    fi

    total_count=$((formula_count + cask_count))
    export BREW_FORMULA_OUTDATED_COUNT="$formula_count"
    export BREW_CASK_OUTDATED_COUNT="$cask_count"
    export BREW_OUTDATED_COUNT="$total_count"

    if [[ $total_count -gt 0 ]]; then
        local detail=""
        if [[ $formula_count -gt 0 ]]; then
            detail="${formula_count} formula"
        fi
        if [[ $cask_count -gt 0 ]]; then
            [[ -n "$detail" ]] && detail="${detail}, "
            detail="${detail}${cask_count} cask"
        fi
        [[ -z "$detail" ]] && detail="${total_count} updates"
        printf "  ${GRAY}%s${NC} %-12s ${YELLOW}%s${NC}\n" "$ICON_WARNING" "Homebrew" "${detail} available"
    else
        printf "  ${GREEN}✓${NC} %-12s %s\n" "Homebrew" "Up to date"
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

    local updates_available="false"
    local macos_update_summary=""
    local sw_output=""
    sw_output=$(get_software_updates)

    if [[ -n "${MO_DEBUG:-}" ]]; then
        echo "[DEBUG] softwareupdate cached output lines: $(printf '%s\n' "$sw_output" | wc -l | tr -d ' ')" >&2
    fi

    if software_update_has_entries "$sw_output"; then
        macos_update_summary=$(get_first_macos_software_update_summary "$sw_output")
        if [[ -n "$macos_update_summary" ]] || is_macos_software_update_text "$sw_output"; then
            updates_available="true"
        fi
    fi

    export MACOS_UPDATE_AVAILABLE="$updates_available"

    if [[ "$updates_available" == "true" ]]; then
        if [[ -n "$macos_update_summary" ]]; then
            printf "  ${GRAY}%s${NC} %-12s ${YELLOW}%s${NC}\n" "$ICON_WARNING" "macOS" "$macos_update_summary"
        else
            printf "  ${GRAY}%s${NC} %-12s ${YELLOW}%s${NC}\n" "$ICON_WARNING" "macOS" "Update available"
        fi
    else
        printf "  ${GREEN}✓${NC} %-12s %s\n" "macOS" "System up to date"
    fi
}

check_mole_update() {
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_mole_update"; then return; fi

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
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking Mole version..."
        fi

        # Try to get latest version from GitHub
        if command -v curl > /dev/null 2>&1; then
            # Run in background to allow Ctrl+C to interrupt
            local temp_version
            temp_version=$(mktemp_file "mole_version_check")
            curl -fsSL --connect-timeout 3 --max-time 5 https://api.github.com/repos/tw93/mole/releases/latest 2> /dev/null | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/' > "$temp_version" &
            local curl_pid=$!

            # Wait for curl to complete (allows Ctrl+C to interrupt)
            if wait "$curl_pid" 2> /dev/null; then
                latest_version=$(cat "$temp_version" 2> /dev/null || echo "")
                # Save to cache
                if [[ -n "$latest_version" ]]; then
                    ensure_user_file "$cache_file"
                    echo "$latest_version" > "$cache_file" 2> /dev/null || true
                fi
            fi
            rm -f "$temp_version" 2> /dev/null || true
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
            printf "  ${GRAY}%s${NC} %-12s ${YELLOW}%s${NC}, running %s\n" "$ICON_WARNING" "Mole" "${latest_version} available" "${current_version}"
        else
            printf "  ${GREEN}✓${NC} %-12s %s\n" "Mole" "Latest version ${current_version}"
        fi
    else
        printf "  ${GREEN}✓${NC} %-12s %s\n" "Mole" "Latest version ${current_version}"
    fi
}

check_all_updates() {
    # Reset spinner flag for softwareupdate
    unset SOFTWAREUPDATE_SPINNER_SHOWN

    # Preload software update data to avoid delays between subsequent checks
    # Only redirect stdout, keep stderr for spinner display
    get_software_updates > /dev/null

    echo -e "${BLUE}${ICON_ARROW}${NC} System Updates"
    check_homebrew_updates
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
            if (lower !~ /macos|background security improvement|rapid security response|security response/) {
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
            if (lower ~ /macos|background security improvement|rapid security response|security response/) {
                print label
            }
        }
    '
}

# ============================================================================
# System Health Checks
# ============================================================================

check_disk_space() {
    # Use df -k to get KB values (always numeric), then calculate GB via math
    # This avoids unit suffix parsing issues (df -H can return MB or GB)
    local free_kb=$(command df -k / | awk 'NR==2 {print $4}')
    local free_gb=$(awk "BEGIN {printf \"%.1f\", $free_kb / 1048576}")
    local free_num=$(awk "BEGIN {printf \"%d\", $free_kb / 1048576}")

    export DISK_FREE_GB=$free_num

    if [[ $free_num -lt 20 ]]; then
        echo -e "  ${RED}✗${NC} Disk Space   ${RED}${free_gb}GB free${NC}, Critical"
    elif [[ $free_num -lt 50 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Disk Space   ${YELLOW}${free_gb}GB free${NC}, Low"
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
        echo -e "  ${RED}✗${NC} Memory       ${RED}${used_percent}% used${NC}, Critical"
    elif [[ $used_percent -gt 80 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Memory       ${YELLOW}${used_percent}% used${NC}, High"
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
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking login items..."
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
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Login Items  ${YELLOW}${login_items_count} apps${NC}"
    elif [[ $login_items_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Login Items  ${login_items_count} apps"
    else
        echo -e "  ${GREEN}✓${NC} Login Items  None"
        return
    fi

    # Show items in a single line (compact)
    local preview_limit=3
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
        items_display="${items_display} +${remaining}"
    fi

    echo -e "    ${GRAY}${items_display}${NC}"
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
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning cache..."
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
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Cache Size   ${YELLOW}${cache_size_gb}GB${NC} cleanable"
    elif [[ $cache_size_int -gt 5 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Cache Size   ${YELLOW}${cache_size_gb}GB${NC} cleanable"
    else
        echo -e "  ${GREEN}✓${NC} Cache Size   ${cache_size_gb}GB"
    fi
}

check_swap_usage() {
    # Check swap usage
    if command -v sysctl > /dev/null 2>&1; then
        local swap_info=$(sysctl vm.swapusage 2> /dev/null || echo "")
        if [[ -n "$swap_info" ]]; then
            local swap_used=$(echo "$swap_info" | grep -o "used = [0-9.]*[GM]" | awk 'NR==1{print $3}')
            swap_used=${swap_used:-0M}
            local swap_num="${swap_used//[GM]/}"

            if [[ "$swap_used" == *"G"* ]]; then
                local swap_gb=${swap_num%.*}
                if [[ $swap_gb -gt 2 ]]; then
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Swap Usage   ${YELLOW}${swap_used}${NC}, High"
                else
                    echo -e "  ${GREEN}✓${NC} Swap Usage   ${swap_used}"
                fi
            else
                echo -e "  ${GREEN}✓${NC} Swap Usage   ${swap_used}"
            fi
        fi
    fi
}

check_disk_smart() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_disk_smart"; then return; fi

    if ! command -v diskutil > /dev/null 2>&1; then
        return
    fi

    local smart_status
    smart_status=$(diskutil info disk0 2> /dev/null | awk -F: '/SMART Status/ {gsub(/^[ \t]+/, "", $2); print $2}')

    if [[ -z "$smart_status" ]]; then
        return
    fi

    if [[ "$smart_status" == "Verified" ]]; then
        echo -e "  ${GREEN}✓${NC} Disk Health  SMART Verified"
    elif [[ "$smart_status" == "Failing" ]]; then
        echo -e "  ${RED}✗${NC} Disk Health  ${RED}SMART Failing — back up immediately${NC}"
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Disk Health  ${YELLOW}SMART: ${smart_status}${NC}"
    fi
}

check_brew_health() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_brew_health"; then return; fi
}

check_system_health() {
    echo -e "${BLUE}${ICON_ARROW}${NC} System Health"
    check_disk_space
    check_memory_usage
    check_swap_usage
    check_login_items
    check_disk_smart
    check_cache_size
    # Time Machine check is optional; skip by default to avoid noise on systems without backups
}
