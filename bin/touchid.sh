#!/bin/bash
# Mole - Touch ID Configuration Helper
# Automatically configure Touch ID for sudo

set -euo pipefail

# Determine script location and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Source common functions
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

readonly PAM_SUDO_FILE="/etc/pam.d/sudo"
readonly PAM_TID_LINE="auth       sufficient     pam_tid.so"

# Check if Touch ID is already configured
is_touchid_configured() {
    if [[ ! -f "$PAM_SUDO_FILE" ]]; then
        return 1
    fi
    grep -q "pam_tid.so" "$PAM_SUDO_FILE" 2> /dev/null
}

# Check if system supports Touch ID
supports_touchid() {
    # Check if bioutil exists and has Touch ID capability
    if command -v bioutil &> /dev/null; then
        bioutil -r 2> /dev/null | grep -q "Touch ID" && return 0
    fi

    # Fallback: check if running on Apple Silicon or modern Intel Mac
    local arch
    arch=$(uname -m)
    if [[ "$arch" == "arm64" ]]; then
        return 0
    fi

    # For Intel Macs, check if it's 2018 or later (approximation)
    local model_year
    model_year=$(system_profiler SPHardwareDataType 2> /dev/null | grep "Model Identifier" | grep -o "[0-9]\{4\}" | head -1)
    if [[ -n "$model_year" ]] && [[ "$model_year" -ge 2018 ]]; then
        return 0
    fi

    return 1
}

# Show current Touch ID status
show_status() {
    if is_touchid_configured; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} $(t "touchid_enabled")"
    else
        echo -e "${YELLOW}☻${NC} $(t "touchid_not_configured")"
    fi
}

# Enable Touch ID for sudo
enable_touchid() {
    # First check if system supports Touch ID
    if ! supports_touchid; then
        log_warning "$(t "touchid_maybe_not_supported")"
        read -rp "$(t "continue_anyway") [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}$(t "cancelled")${NC}"
            return 1
        fi
        echo ""
    fi

    # Check if already configured
    if is_touchid_configured; then
        echo -e "${GREEN}${ICON_SUCCESS} $(t "touchid_already_enabled")${NC}"
        return 0
    fi

    # Create backup and apply changes
    if ! sudo cp "$PAM_SUDO_FILE" "${PAM_SUDO_FILE}.mole-backup" 2> /dev/null; then
        log_error "$(t "failed_create_backup")"
        return 1
    fi

    # Create temp file with the modification
    local temp_file
    temp_file=$(mktemp)

    # Insert pam_tid.so after the first comment block
    awk '
        BEGIN { inserted = 0 }
        /^#/ { print; next }
        !inserted && /^[^#]/ {
            print "'"$PAM_TID_LINE"'"
            inserted = 1
        }
        { print }
    ' "$PAM_SUDO_FILE" > "$temp_file"

    # Apply the changes
    if sudo mv "$temp_file" "$PAM_SUDO_FILE" 2> /dev/null; then
        echo -e "${GREEN}${ICON_SUCCESS} $(t "touchid_enabled")${NC} ${GRAY}- sudo ls${NC}"
        echo ""
        return 0
    else
        rm -f "$temp_file" 2> /dev/null || true
        log_error "$(t "failed_enable_touchid")"
        return 1
    fi
}

# Disable Touch ID for sudo
disable_touchid() {
    if ! is_touchid_configured; then
        echo -e "${YELLOW}$(t "touchid_not_enabled")${NC}"
        return 0
    fi

    # Create backup and remove configuration
    if ! sudo cp "$PAM_SUDO_FILE" "${PAM_SUDO_FILE}.mole-backup" 2> /dev/null; then
        log_error "$(t "failed_create_backup")"
        return 1
    fi

    # Remove pam_tid.so line
    local temp_file
    temp_file=$(mktemp)
    grep -v "pam_tid.so" "$PAM_SUDO_FILE" > "$temp_file"

    if sudo mv "$temp_file" "$PAM_SUDO_FILE" 2> /dev/null; then
        echo -e "${GREEN}${ICON_SUCCESS} $(t "touchid_disabled")${NC}"
        echo ""
        return 0
    else
        rm -f "$temp_file" 2> /dev/null || true
        log_error "$(t "failed_disable_touchid")"
        return 1
    fi
}

# Interactive menu
show_menu() {
    echo ""
    show_status
    if is_touchid_configured; then
        echo -ne "${PURPLE}☛${NC} $(t "press_enter_disable"), ${GRAY}Q${NC} $(t "quit_short"): "
        IFS= read -r -s -n1 key || key=""
        drain_pending_input # Clean up any escape sequence remnants
        echo ""

        case "$key" in
            $'\e') # ESC
                return 0
                ;;
            "" | $'\n' | $'\r')   # Enter
                printf "\r\033[K" # Clear the prompt line
                disable_touchid
                ;;
            *)
                echo ""
                log_error "$(t "invalid_key")"
                ;;
        esac
    else
        echo -ne "${PURPLE}☛${NC} $(t "press_enter_enable"), ${GRAY}Q${NC} $(t "quit_short"): "
        IFS= read -r -s -n1 key || key=""
        drain_pending_input # Clean up any escape sequence remnants

        case "$key" in
            $'\e') # ESC
                return 0
                ;;
            "" | $'\n' | $'\r')   # Enter
                printf "\r\033[K" # Clear the prompt line
                enable_touchid
                ;;
            *)
                echo ""
                log_error "$(t "invalid_key")"
                ;;
        esac
    fi
}

# Main
main() {
    local command="${1:-}"

    case "$command" in
        enable)
            enable_touchid
            ;;
        disable)
            disable_touchid
            ;;
        status)
            show_status
            ;;
        "")
            show_menu
            ;;
        *)
            log_error "$(t "unknown_command"): $command"
            exit 1
            ;;
    esac
}

main "$@"
