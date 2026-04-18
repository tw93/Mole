#!/bin/bash
# Auto-fix Manager
# Unified auto-fix suggestions and execution

set -euo pipefail

# Show system suggestions with auto-fix markers
show_suggestions() {
    local has_suggestions=false
    local can_auto_fix=false
    local -a auto_fix_items=()
    local -a manual_items=()
    local skip_security_autofix=false
    if [[ "${MOLE_SECURITY_FIXES_SHOWN:-}" == "true" ]]; then
        skip_security_autofix=true
    fi

    # Security suggestions
    if [[ "$skip_security_autofix" == "false" && -n "${FIREWALL_DISABLED:-}" && "${FIREWALL_DISABLED}" == "true" ]]; then
        auto_fix_items+=("${TR_FIX_FW_SUGGEST:-Enable Firewall for better security}")
        has_suggestions=true
        can_auto_fix=true
    fi

    if [[ -n "${FILEVAULT_DISABLED:-}" && "${FILEVAULT_DISABLED}" == "true" ]]; then
        manual_items+=("${TR_FIX_FV_SUGGEST:-Enable FileVault}|${TR_FIX_FV_HINT:-System Settings → Privacy & Security → FileVault}")
        has_suggestions=true
    fi

    # Configuration suggestions
    if [[ "$skip_security_autofix" == "false" && -n "${TOUCHID_NOT_CONFIGURED:-}" && "${TOUCHID_NOT_CONFIGURED}" == "true" ]]; then
        auto_fix_items+=("${TR_FIX_TID_SUGGEST:-Enable Touch ID for sudo}")
        has_suggestions=true
        can_auto_fix=true
    fi

    if [[ -n "${ROSETTA_NOT_INSTALLED:-}" && "${ROSETTA_NOT_INSTALLED}" == "true" ]]; then
        auto_fix_items+=("${TR_FIX_ROSETTA_SUGGEST:-Install Rosetta 2 for Intel app support}")
        has_suggestions=true
        can_auto_fix=true
    fi

    # Health suggestions
    if [[ -n "${CACHE_SIZE_GB:-}" ]]; then
        local cache_gb="${CACHE_SIZE_GB:-0}"
        if (($(echo "$cache_gb > 5" | bc -l 2> /dev/null || echo 0))); then
            manual_items+=("${TR_FIX_CACHE_SUGGEST:-Free up ${cache_gb}GB by cleaning caches}|${TR_FIX_CACHE_HINT:-Run: mo clean}")
            has_suggestions=true
        fi
    fi

    if [[ -n "${BREW_HAS_WARNINGS:-}" && "${BREW_HAS_WARNINGS}" == "true" ]]; then
        manual_items+=("${TR_FIX_BREW_SUGGEST:-Fix Homebrew warnings}|${TR_FIX_BREW_HINT:-Run: brew doctor to see details}")
        has_suggestions=true
    fi

    if [[ -n "${DISK_FREE_GB:-}" && "${DISK_FREE_GB:-0}" -lt 50 ]]; then
        if [[ -z "${CACHE_SIZE_GB:-}" ]] || (($(echo "${CACHE_SIZE_GB:-0} <= 5" | bc -l 2> /dev/null || echo 1))); then
            manual_items+=("${TR_FIX_DISK_SUGGEST:-Low disk space, ${DISK_FREE_GB}GB free}|${TR_FIX_DISK_HINT:-Run: mo analyze to find large files}")
            has_suggestions=true
        fi
    fi

    # Display suggestions
    echo -e "${BLUE}${ICON_ARROW}${NC} ${TR_FIX_SUGGESTIONS:-Suggestions}"

    if [[ "$has_suggestions" == "false" ]]; then
        echo -e "  ${GREEN}✓${NC} ${TR_FIX_ALL_GOOD:-All looks good}"
        export HAS_AUTO_FIX_SUGGESTIONS="false"
        return
    fi

    # Show auto-fix items
    if [[ ${#auto_fix_items[@]} -gt 0 ]]; then
        for item in "${auto_fix_items[@]}"; do
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${item} ${GREEN}${TR_FIX_AUTO_LABEL:-[auto]}${NC}"
        done
    fi

    # Show manual items
    if [[ ${#manual_items[@]} -gt 0 ]]; then
        for item in "${manual_items[@]}"; do
            local title="${item%%|*}"
            local hint="${item#*|}"
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${title}"
            echo -e "    ${GRAY}${hint}${NC}"
        done
    fi

    # Export for use in auto-fix
    export HAS_AUTO_FIX_SUGGESTIONS="$can_auto_fix"
}

# Ask user if they want to auto-fix
# Returns: 0 if yes, 1 if no
ask_for_auto_fix() {
    if [[ "${HAS_AUTO_FIX_SUGGESTIONS:-false}" != "true" ]]; then
        return 1
    fi

    echo -ne "${PURPLE}${ICON_ARROW}${NC} ${TR_FIX_PROMPT:-Auto-fix issues now?} ${GRAY}${TR_FIX_PROMPT_HINT:-Enter confirm / Space cancel}${NC}: "

    local key
    if ! key=$(read_key); then
        echo "no"
        echo ""
        return 1
    fi

    if [[ "$key" == "ENTER" ]]; then
        echo "yes"
        echo ""
        return 0
    else
        echo "no"
        echo ""
        return 1
    fi
}

# Perform auto-fixes
# Returns: number of fixes applied
perform_auto_fix() {
    local fixed_count=0
    local -a fixed_items=()

    # Ensure sudo access
    if ! has_sudo_session; then
        if ! ensure_sudo_session "${TR_FIX_ADMIN_REQUIRED:-System fixes require admin access}"; then
            echo -e "${YELLOW}${TR_FIX_ADMIN_SKIP:-Skipping auto fixes, admin authentication required}${NC}"
            echo ""
            return 0
        fi
    fi

    # Fix Firewall
    if [[ -n "${FIREWALL_DISABLED:-}" && "${FIREWALL_DISABLED}" == "true" ]]; then
        echo -e "${BLUE}${TR_FIX_FW_ENABLING:-Enabling Firewall...}${NC}"
        if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} ${TR_FIX_FW_ENABLED:-Firewall enabled}"
            fixed_count=$((fixed_count + 1))
            fixed_items+=("${TR_FIX_FW_ENABLED:-Firewall enabled}")
        else
            echo -e "${RED}✗${NC} ${TR_FIX_FW_FAIL:-Failed to enable Firewall}"
        fi
        echo ""
    fi

    # Fix Touch ID
    if [[ -n "${TOUCHID_NOT_CONFIGURED:-}" && "${TOUCHID_NOT_CONFIGURED}" == "true" ]]; then
        echo -e "${BLUE}${ICON_ARROW}${NC} ${TR_FIX_TID_CONFIGURING:-Configuring Touch ID for sudo...}"
        local pam_file="/etc/pam.d/sudo"
        if sudo bash -c "grep -q 'pam_tid.so' '$pam_file' 2>/dev/null || sed -i '' '2i\\
auth       sufficient     pam_tid.so
' '$pam_file'" 2> /dev/null; then
            echo -e "${GREEN}✓${NC} ${TR_FIX_TID_CONFIGURED:-Touch ID configured}"
            fixed_count=$((fixed_count + 1))
            fixed_items+=("${TR_FIX_TID_CONFIGURED:-Touch ID configured for sudo}")
        else
            echo -e "${RED}✗${NC} ${TR_FIX_TID_FAIL:-Failed to configure Touch ID}"
        fi
        echo ""
    fi

    # Install Rosetta 2
    if [[ -n "${ROSETTA_NOT_INSTALLED:-}" && "${ROSETTA_NOT_INSTALLED}" == "true" ]]; then
        echo -e "${BLUE}${TR_FIX_ROSETTA_INSTALLING:-Installing Rosetta 2...}${NC}"
        if sudo softwareupdate --install-rosetta --agree-to-license 2>&1 | grep -qE "(Installing|Installed|already installed)"; then
            echo -e "${GREEN}✓${NC} ${TR_FIX_ROSETTA_INSTALLED:-Rosetta 2 installed}"
            fixed_count=$((fixed_count + 1))
            fixed_items+=("${TR_FIX_ROSETTA_INSTALLED:-Rosetta 2 installed}")
        else
            echo -e "${RED}✗${NC} ${TR_FIX_ROSETTA_FAIL:-Failed to install Rosetta 2}"
        fi
        echo ""
    fi

    if [[ $fixed_count -gt 0 ]]; then
        AUTO_FIX_SUMMARY="${TR_FIX_SUMMARY_APPLIED:-Auto fixes applied: ${fixed_count} issues}"
        if [[ ${#fixed_items[@]} -gt 0 ]]; then
            AUTO_FIX_DETAILS=$(printf '%s\n' "${fixed_items[@]}")
        else
            AUTO_FIX_DETAILS=""
        fi
    else
        AUTO_FIX_SUMMARY="${TR_FIX_SUMMARY_SKIPPED:-Auto fixes skipped: No changes were required}"
        AUTO_FIX_DETAILS=""
    fi
    export AUTO_FIX_SUMMARY AUTO_FIX_DETAILS
    return 0
}
