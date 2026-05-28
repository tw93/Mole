#!/bin/bash
# Roomy - Touch ID command.
# Configures sudo with Touch ID.
# Guided toggle with safety checks.

set -euo pipefail

# Determine script location and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# Source common functions
# shellcheck source=../lib/core/common.sh
source "$LIB_DIR/core/common.sh"

# Set up global cleanup trap
trap cleanup_temp_files EXIT INT TERM

PAM_SUDO_FILE="${ROOMY_PAM_SUDO_FILE:-/etc/pam.d/sudo}"
PAM_SUDO_LOCAL_FILE="${ROOMY_PAM_SUDO_LOCAL_FILE:-$(dirname "$PAM_SUDO_FILE")/sudo_local}"
readonly PAM_SUDO_FILE
readonly PAM_SUDO_LOCAL_FILE
readonly PAM_TID_LINE="auth       sufficient     pam_tid.so"

touchid_require_regular_pam_target() {
    local path="$1"
    local label="$2"
    local require_exists="${3:-false}"

    if [[ -L "$path" ]]; then
        log_error "$label must not be a symlink: $path"
        return 1
    fi

    if [[ "$require_exists" == "true" && ! -e "$path" ]]; then
        log_error "$label not found: $path"
        return 1
    fi

    if [[ -e "$path" && ! -f "$path" ]]; then
        log_error "$label must be a regular file: $path"
        return 1
    fi
}

touchid_validate_pam_targets() {
    touchid_require_regular_pam_target "$PAM_SUDO_FILE" "PAM sudo file" true || return 1
    touchid_require_regular_pam_target "$PAM_SUDO_LOCAL_FILE" "PAM sudo_local file" false || return 1
}

# Check if Touch ID is already configured
is_touchid_configured() {
    # Check sudo_local first
    if [[ -f "$PAM_SUDO_LOCAL_FILE" && ! -L "$PAM_SUDO_LOCAL_FILE" ]]; then
        grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE" 2> /dev/null && return 0
    fi

    # Fallback to standard sudo file
    if [[ ! -f "$PAM_SUDO_FILE" || -L "$PAM_SUDO_FILE" ]]; then
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

touchid_dry_run_enabled() {
    [[ "${ROOMY_DRY_RUN:-0}" == "1" ]]
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
    # Cleanup trap handled by global EXIT trap
    local temp_file=""

    if touchid_dry_run_enabled; then
        if is_touchid_configured; then
            echo -e "${GREEN}${ICON_SUCCESS} Touch ID is already enabled, no changes needed${NC}"
        else
            echo -e "${GREEN}${ICON_SUCCESS} [DRY RUN] Would enable Touch ID for sudo${NC}"
            echo -e "${GRAY}${ICON_REVIEW} Target files: ${PAM_SUDO_FILE} and/or ${PAM_SUDO_LOCAL_FILE}${NC}"
        fi
        return 0
    fi

    touchid_validate_pam_targets || return 1

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

    # Check if we should use sudo_local (Sonoma+)
    if grep -q "sudo_local" "$PAM_SUDO_FILE"; then
        # Check if already correctly configured in sudo_local
        if [[ -f "$PAM_SUDO_LOCAL_FILE" ]] && grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE"; then
            # It is in sudo_local, but let's check if it's ALSO in sudo (incomplete migration)
            if grep -q "pam_tid.so" "$PAM_SUDO_FILE"; then
                # Clean up legacy config
                temp_file=$(create_temp_file)
                grep -v "pam_tid.so" "$PAM_SUDO_FILE" > "$temp_file"
                if sudo mv "$temp_file" "$PAM_SUDO_FILE" 2> /dev/null; then
                    echo -e "${GREEN}${ICON_SUCCESS} Cleanup legacy configuration${NC}"
                fi
            fi
            echo -e "${GREEN}${ICON_SUCCESS} Touch ID is already enabled${NC}"
            return 0
        fi

        # Not configured in sudo_local yet.
        # Check if configured in sudo (Legacy)
        local is_legacy_configured=false
        if grep -q "pam_tid.so" "$PAM_SUDO_FILE"; then
            is_legacy_configured=true
        fi

        # Function to write to sudo_local
        local write_success=false
        if [[ ! -f "$PAM_SUDO_LOCAL_FILE" ]]; then
            # Create the file
            echo "# sudo_local: local customizations for sudo" | sudo tee "$PAM_SUDO_LOCAL_FILE" > /dev/null
            echo "$PAM_TID_LINE" | sudo tee -a "$PAM_SUDO_LOCAL_FILE" > /dev/null
            sudo chmod 444 "$PAM_SUDO_LOCAL_FILE"
            sudo chown root:wheel "$PAM_SUDO_LOCAL_FILE"
            write_success=true
        else
            # Append if not present
            if ! grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE"; then
                temp_file=$(create_temp_file)
                cp "$PAM_SUDO_LOCAL_FILE" "$temp_file"
                echo "$PAM_TID_LINE" >> "$temp_file"
                sudo mv "$temp_file" "$PAM_SUDO_LOCAL_FILE"
                sudo chmod 444 "$PAM_SUDO_LOCAL_FILE"
                sudo chown root:wheel "$PAM_SUDO_LOCAL_FILE"
                write_success=true
            else
                write_success=true # Already there (should be caught by first check, but safe fallback)
            fi
        fi

        if $write_success; then
            # If we migrated from legacy, clean it up now
            if $is_legacy_configured; then
                temp_file=$(create_temp_file)
                grep -v "pam_tid.so" "$PAM_SUDO_FILE" > "$temp_file"
                sudo mv "$temp_file" "$PAM_SUDO_FILE"
                log_success "Touch ID migrated to sudo_local"
            else
                log_success "Touch ID enabled, via sudo_local, try: sudo ls"
            fi
            return 0
        else
            log_error "Failed to write to sudo_local"
            return 1
        fi
    fi

    # Legacy method: Modify sudo file directly

    # Check if already configured (Legacy)
    if is_touchid_configured; then
        echo -e "${GREEN}${ICON_SUCCESS} Touch ID is already enabled${NC}"
        return 0
    fi

    # Create backup only if it doesn't exist to preserve original state
    if [[ ! -f "${PAM_SUDO_FILE}.roomy-backup" ]]; then
        if ! sudo cp "$PAM_SUDO_FILE" "${PAM_SUDO_FILE}.roomy-backup" 2> /dev/null; then
            log_error "Failed to create backup"
            return 1
        fi
    fi

    # Create temp file
    temp_file=$(create_temp_file)

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
    if sudo mv "$temp_file" "$PAM_SUDO_FILE" 2> /dev/null; then
        log_success "Touch ID enabled, try: sudo ls"
        return 0
    else
        log_error "Failed to enable Touch ID"
        return 1
    fi
}

# Disable Touch ID for sudo
disable_touchid() {
    # Cleanup trap handled by global EXIT trap
    local temp_file=""

    if touchid_dry_run_enabled; then
        if ! is_touchid_configured; then
            echo -e "${YELLOW}Touch ID is not currently enabled${NC}"
        else
            echo -e "${GREEN}${ICON_SUCCESS} [DRY RUN] Would disable Touch ID for sudo${NC}"
            echo -e "${GRAY}${ICON_REVIEW} Target files: ${PAM_SUDO_FILE} and/or ${PAM_SUDO_LOCAL_FILE}${NC}"
        fi
        return 0
    fi

    touchid_validate_pam_targets || return 1

    if ! is_touchid_configured; then
        echo -e "${YELLOW}Touch ID is not currently enabled${NC}"
        return 0
    fi

    # Check sudo_local first
    if [[ -f "$PAM_SUDO_LOCAL_FILE" ]] && grep -q "pam_tid.so" "$PAM_SUDO_LOCAL_FILE"; then
        # Remove from sudo_local
        temp_file=$(create_temp_file)
        grep -v "pam_tid.so" "$PAM_SUDO_LOCAL_FILE" > "$temp_file"

        if sudo mv "$temp_file" "$PAM_SUDO_LOCAL_FILE" 2> /dev/null; then
            # Since we modified sudo_local, we should also check if it's in sudo file (legacy cleanup)
            if grep -q "pam_tid.so" "$PAM_SUDO_FILE"; then
                temp_file=$(create_temp_file)
                grep -v "pam_tid.so" "$PAM_SUDO_FILE" > "$temp_file"
                sudo mv "$temp_file" "$PAM_SUDO_FILE"
            fi
            echo -e "${GREEN}${ICON_SUCCESS} Touch ID disabled, removed from sudo_local${NC}"
            echo ""
            return 0
        else
            log_error "Failed to disable Touch ID from sudo_local"
            return 1
        fi
    fi

    # Fallback to sudo file (legacy)
    if grep -q "pam_tid.so" "$PAM_SUDO_FILE"; then
        # Create backup only if it doesn't exist
        if [[ ! -f "${PAM_SUDO_FILE}.roomy-backup" ]]; then
            if ! sudo cp "$PAM_SUDO_FILE" "${PAM_SUDO_FILE}.roomy-backup" 2> /dev/null; then
                log_error "Failed to create backup"
                return 1
            fi
        fi

        # Remove pam_tid.so line
        temp_file=$(create_temp_file)
        grep -v "pam_tid.so" "$PAM_SUDO_FILE" > "$temp_file"

        if sudo mv "$temp_file" "$PAM_SUDO_FILE" 2> /dev/null; then
            echo -e "${GREEN}${ICON_SUCCESS} Touch ID disabled${NC}"
            echo ""
            return 0
        else
            log_error "Failed to disable Touch ID"
            return 1
        fi
    fi

    # Should not reach here if is_touchid_configured was true
    log_error "Could not find Touch ID configuration to disable"
    return 1
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
            $'\e' | q | Q) # ESC or Q
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
            $'\e' | q | Q) # ESC or Q
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
    local command=""
    local arg

    for arg in "$@"; do
        case "$arg" in
            "--dry-run" | "-n")
                export ROOMY_DRY_RUN=1
                ;;
            "--help" | "-h")
                show_touchid_help
                return 0
                ;;
            enable | disable | status)
                if [[ -z "$command" ]]; then
                    command="$arg"
                else
                    log_error "Only one touchid command is supported per run"
                    return 1
                fi
                ;;
            *)
                log_error "Unknown command: $arg"
                return 1
                ;;
        esac
    done

    if touchid_dry_run_enabled; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No sudo authentication files will be modified"
        echo ""
    fi

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

if [[ "${ROOMY_SKIP_MAIN:-0}" == "1" ]]; then
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 0
    else
        exit 0
    fi
fi

main "$@"
