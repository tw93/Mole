#!/bin/bash
# Mole - Touch ID command.
# Configures sudo with Touch ID.
# Guided toggle with safety checks.

set -euo pipefail

# Determine script location and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Source common functions
# shellcheck source=../lib/core/common.sh
source "$LIB_DIR/core/common.sh"

readonly PAM_SUDO_FILE="${MOLE_PAM_SUDO_FILE:-/etc/pam.d/sudo}"
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
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Touch ID is enabled for sudo"
    else
        echo -e "${YELLOW}☻${NC} Touch ID is not configured for sudo"
    fi
}

# Enable Touch ID for sudo
enable_touchid() {
    # Cleanup trap
    local temp_file=""
    trap '[[ -n "${temp_file:-}" ]] && rm -f -- "${temp_file:-}"' EXIT

    # First check if system supports Touch ID
    if ! supports_touchid; then
        log_warning "This Mac may not support Touch ID"
        read -rp "Continue anyway? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Cancelled${NC}"
            return 1
        fi
        echo ""
    fi

    # Check if already configured
    if is_touchid_configured; then
        echo -e "${GREEN}${ICON_SUCCESS} Touch ID is already enabled${NC}"
        return 0
    fi

    # Create backup only if it doesn't exist to preserve original state
    if [[ ! -f "${PAM_SUDO_FILE}.mole-backup" ]]; then
        if ! sudo cp -- "$PAM_SUDO_FILE" "${PAM_SUDO_FILE}.mole-backup" 2> /dev/null; then
            log_error "Failed to create backup"
            return 1
        fi
    fi

    # Create temp file
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

    # Verify content change
    if cmp -s "$PAM_SUDO_FILE" "$temp_file"; then
        log_error "Failed to modify configuration"
        return 1
    fi

    # Apply the changes
    if sudo mv -- "$temp_file" "$PAM_SUDO_FILE" 2> /dev/null; then
        log_success "Touch ID enabled - try: sudo ls"
        return 0
    else
        log_error "Failed to enable Touch ID"
        return 1
    fi
}

# Disable Touch ID for sudo
disable_touchid() {
    # Cleanup trap
    local temp_file=""
    trap '[[ -n "${temp_file:-}" ]] && rm -f -- "${temp_file:-}"' EXIT

    if ! is_touchid_configured; then
        echo -e "${YELLOW}Touch ID is not currently enabled${NC}"
        return 0
    fi

    # Create backup only if it doesn't exist
    if [[ ! -f "${PAM_SUDO_FILE}.mole-backup" ]]; then
        if ! sudo cp -- "$PAM_SUDO_FILE" "${PAM_SUDO_FILE}.mole-backup" 2> /dev/null; then
            log_error "Failed to create backup"
            return 1
        fi
    fi

    # Remove pam_tid.so line
    temp_file=$(mktemp)
    grep -v "pam_tid.so" "$PAM_SUDO_FILE" > "$temp_file"

    if sudo mv -- "$temp_file" "$PAM_SUDO_FILE" 2> /dev/null; then
        echo -e "${GREEN}${ICON_SUCCESS} Touch ID disabled${NC}"
        echo ""
        return 0
    else
        log_error "Failed to disable Touch ID"
        return 1
    fi
}

# Interactive menu
show_menu() {
    echo ""
    show_status
    if is_touchid_configured; then
        echo -ne "${PURPLE}☛${NC} Press ${GREEN}Enter${NC} to disable, ${GRAY}Q${NC} to quit: "
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
                log_error "Invalid key"
                ;;
        esac
    else
        echo -ne "${PURPLE}☛${NC} Press ${GREEN}Enter${NC} to enable, ${GRAY}Q${NC} to quit: "
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
                log_error "Invalid key"
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
            log_error "Unknown command: $command"
            exit 1
            ;;
    esac
}

main "$@"
