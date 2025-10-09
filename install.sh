#!/bin/bash
# Mole Installation Script

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Simple spinner
_SPINNER_PID=""
start_line_spinner() {
    local msg="$1"; [[ ! -t 1 ]] && { echo -e "${BLUE}|${NC} $msg"; return; }
    local chars="${MO_SPINNER_CHARS:-|/-\\}"; [[ -z "$chars" ]] && chars='|/-\\'
    local i=0
    ( while true; do c="${chars:$((i % ${#chars})):1}"; printf "\r${BLUE}%s${NC} %s" "$c" "$msg"; ((i++)); sleep 0.12; done ) &
    _SPINNER_PID=$!
}
stop_line_spinner() { if [[ -n "$_SPINNER_PID" ]]; then kill "$_SPINNER_PID" 2>/dev/null || true; wait "$_SPINNER_PID" 2>/dev/null || true; _SPINNER_PID=""; printf "\r\033[K"; fi; }


# Verbosity (0 = quiet, 1 = verbose)
VERBOSE=1

# Icons (duplicated from lib/common.sh - necessary as install.sh runs standalone)
readonly ICON_SUCCESS="✓"
readonly ICON_ADMIN="●"
readonly ICON_CONFIRM="◎"
readonly ICON_ERROR="✗"

# Logging functions
log_info() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}$1${NC}"; }
log_success() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} $1"; }
log_warning() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}${ICON_ERROR}${NC} $1"; }
log_admin() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}${ICON_ADMIN}${NC} $1"; }
log_confirm() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}${ICON_CONFIRM}${NC} $1"; }

# Default installation directory
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/mole"
SOURCE_DIR=""

# Default action (install|update)
ACTION="install"

show_help() {
    cat << 'EOF'
Mole Installation Script
========================

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    --prefix PATH       Install to custom directory (default: /usr/local/bin)
    --config PATH       Config directory (default: ~/.config/mole)
    --update            Update Mole to the latest version
    --uninstall         Uninstall mole
    --help, -h          Show this help

EXAMPLES:
    ./install.sh                    # Install to /usr/local/bin
    ./install.sh --prefix ~/.local/bin  # Install to custom directory
    ./install.sh --update           # Update Mole in place
    ./install.sh --uninstall       # Uninstall mole

The installer will:
1. Copy mole binary and scripts to the install directory
2. Set up config directory with all modules
3. Make the mole command available system-wide
EOF
    echo ""
}

# Resolve the directory containing source files (supports curl | bash)
resolve_source_dir() {
    if [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" && -f "$SOURCE_DIR/mole" ]]; then
        return 0
    fi

    # 1) If script is on disk, use its directory (only when mole executable present)
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$script_dir/mole" ]]; then
            SOURCE_DIR="$script_dir"
            return 0
        fi
    fi

    # 2) If CLEAN_SOURCE_DIR env is provided, honor it
    if [[ -n "${CLEAN_SOURCE_DIR:-}" && -d "$CLEAN_SOURCE_DIR" && -f "$CLEAN_SOURCE_DIR/mole" ]]; then
        SOURCE_DIR="$CLEAN_SOURCE_DIR"
        return 0
    fi

    # 3) Fallback: fetch repository to a temp directory (works for curl | bash)
    local tmp
    tmp="$(mktemp -d)"
    # Expand tmp now so trap doesn't depend on local scope
    trap "rm -rf '$tmp'" EXIT

    start_line_spinner "Fetching Mole source..."
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL -o "$tmp/mole.tar.gz" "https://github.com/tw93/mole/archive/refs/heads/main.tar.gz"; then
            stop_line_spinner
            tar -xzf "$tmp/mole.tar.gz" -C "$tmp"
            # Extracted folder name: mole-main
            if [[ -d "$tmp/mole-main" ]]; then
                SOURCE_DIR="$tmp/mole-main"
                return 0
            fi
        fi
    fi
    stop_line_spinner

    start_line_spinner "Cloning Mole source..."
    if command -v git >/dev/null 2>&1; then
        if git clone --depth=1 https://github.com/tw93/mole.git "$tmp/mole" >/dev/null 2>&1; then
            stop_line_spinner
            SOURCE_DIR="$tmp/mole"
            return 0
        fi
    fi
    stop_line_spinner

    log_error "Failed to fetch source files. Ensure curl or git is available."
    exit 1
}

get_source_version() {
    local source_mole="$SOURCE_DIR/mole"
    if [[ -f "$source_mole" ]]; then
        sed -n 's/^VERSION="\(.*\)"$/\1/p' "$source_mole" | head -n1
    fi
}

get_installed_version() {
    local binary="$INSTALL_DIR/mole"
    if [[ -x "$binary" ]]; then
        "$binary" --version 2>/dev/null | awk 'NF {print $NF; exit}'
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --prefix)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --config)
                CONFIG_DIR="$2"
                shift 2
                ;;
            --update)
                ACTION="update"
                shift 1
                ;;
            --uninstall)
                uninstall_mole
                exit 0
                ;;
            --verbose|-v)
                VERBOSE=1
                shift 1
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Check system requirements
check_requirements() {
    # Check if running on macOS
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_error "This tool is designed for macOS only"
        exit 1
    fi

    # Check if already installed via Homebrew
    if command -v brew >/dev/null 2>&1 && brew list mole >/dev/null 2>&1; then
        if [[ "$ACTION" == "update" ]]; then
            return 0
        fi

        echo -e "${YELLOW}Mole is installed via Homebrew${NC}"
        echo ""
        echo "Choose one:"
        echo -e "  1. Update via Homebrew: ${GREEN}brew upgrade mole${NC}"
        echo -e "  2. Switch to manual: ${GREEN}brew uninstall mole${NC} then re-run this"
        echo ""
        exit 1
    fi

    # Check if install directory exists and is writable
    if [[ ! -d "$(dirname "$INSTALL_DIR")" ]]; then
        log_error "Parent directory $(dirname "$INSTALL_DIR") does not exist"
        exit 1
    fi
}

# Create installation directories
create_directories() {
    # Create install directory if it doesn't exist
    if [[ ! -d "$INSTALL_DIR" ]]; then
        if [[ "$INSTALL_DIR" == "/usr/local/bin" ]] && [[ ! -w "$(dirname "$INSTALL_DIR")" ]]; then
            sudo mkdir -p "$INSTALL_DIR"
        else
            mkdir -p "$INSTALL_DIR"
        fi
    fi

    # Create config directory
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR/bin"
    mkdir -p "$CONFIG_DIR/lib"

}

# Install files
install_files() {

    resolve_source_dir

    local source_dir_abs
    local install_dir_abs
    local config_dir_abs
    source_dir_abs="$(cd "$SOURCE_DIR" && pwd)"
    install_dir_abs="$(cd "$INSTALL_DIR" && pwd)"
    config_dir_abs="$(cd "$CONFIG_DIR" && pwd)"

    # Copy main executable when destination differs
    if [[ -f "$SOURCE_DIR/mole" ]]; then
        if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
            if [[ "$INSTALL_DIR" == "/usr/local/bin" ]] && [[ ! -w "$INSTALL_DIR" ]]; then
                log_admin "Admin access required for /usr/local/bin"
                sudo cp "$SOURCE_DIR/mole" "$INSTALL_DIR/mole"
                sudo chmod +x "$INSTALL_DIR/mole"
            else
                cp "$SOURCE_DIR/mole" "$INSTALL_DIR/mole"
                chmod +x "$INSTALL_DIR/mole"
            fi
            log_success "Installed mole to $INSTALL_DIR"
        fi
    else
        log_error "mole executable not found in ${SOURCE_DIR:-unknown}"
        exit 1
    fi

    # Install mo alias for Mole if available
    if [[ -f "$SOURCE_DIR/mo" ]]; then
        if [[ "$source_dir_abs" == "$install_dir_abs" ]]; then
            log_success "mo alias already present"
        else
            if [[ "$INSTALL_DIR" == "/usr/local/bin" ]] && [[ ! -w "$INSTALL_DIR" ]]; then
                sudo cp "$SOURCE_DIR/mo" "$INSTALL_DIR/mo"
                sudo chmod +x "$INSTALL_DIR/mo"
            else
                cp "$SOURCE_DIR/mo" "$INSTALL_DIR/mo"
                chmod +x "$INSTALL_DIR/mo"
            fi
            log_success "Installed mo alias"
        fi
    fi

    # Copy configuration and modules
    if [[ -d "$SOURCE_DIR/bin" ]]; then
        local source_bin_abs="$(cd "$SOURCE_DIR/bin" && pwd)"
        local config_bin_abs="$(cd "$CONFIG_DIR/bin" && pwd)"
        if [[ "$source_bin_abs" == "$config_bin_abs" ]]; then
            log_success "Modules already synced"
        else
            cp -r "$SOURCE_DIR/bin"/* "$CONFIG_DIR/bin/"
            chmod +x "$CONFIG_DIR/bin"/*
            log_success "Installed modules"
        fi
    fi

    if [[ -d "$SOURCE_DIR/lib" ]]; then
        local source_lib_abs="$(cd "$SOURCE_DIR/lib" && pwd)"
        local config_lib_abs="$(cd "$CONFIG_DIR/lib" && pwd)"
        if [[ "$source_lib_abs" == "$config_lib_abs" ]]; then
            log_success "Libraries already synced"
        else
            cp -r "$SOURCE_DIR/lib"/* "$CONFIG_DIR/lib/"
            log_success "Installed libraries"
        fi
    fi

    # Copy other files if they exist and directories differ
    if [[ "$config_dir_abs" != "$source_dir_abs" ]]; then
        for file in README.md LICENSE install.sh; do
            if [[ -f "$SOURCE_DIR/$file" ]]; then
                cp -f "$SOURCE_DIR/$file" "$CONFIG_DIR/"
            fi
        done
    fi

    if [[ -f "$CONFIG_DIR/install.sh" ]]; then
        chmod +x "$CONFIG_DIR/install.sh"
    fi

    # Update the mole script to use the config directory when installed elsewhere
    if [[ "$source_dir_abs" != "$install_dir_abs" ]]; then
        if [[ "$INSTALL_DIR" == "/usr/local/bin" ]] && [[ ! -w "$INSTALL_DIR" ]]; then
            sudo sed -i '' "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$CONFIG_DIR\"|" "$INSTALL_DIR/mole"
        else
            sed -i '' "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$CONFIG_DIR\"|" "$INSTALL_DIR/mole"
        fi
    fi
}

# Verify installation
verify_installation() {

    if [[ -x "$INSTALL_DIR/mole" ]] && [[ -f "$CONFIG_DIR/lib/common.sh" ]]; then

        # Test if mole command works
        if "$INSTALL_DIR/mole" --help >/dev/null 2>&1; then
            return 0
        else
            log_warning "Mole command installed but may not be working properly"
        fi
    else
        log_error "Installation verification failed"
        exit 1
    fi
}

# Add to PATH if needed
setup_path() {
    # Check if install directory is in PATH
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        return
    fi

    # Only suggest PATH setup for custom directories
    if [[ "$INSTALL_DIR" != "/usr/local/bin" ]]; then
        log_warning "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "To use mole from anywhere, add this line to your shell profile:"
        echo "export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
        echo "For example, add it to ~/.zshrc or ~/.bash_profile"
    fi
}

print_usage_summary() {
    local action="$1"
    local new_version="$2"
    local previous_version="${3:-}"

    if [[ ${VERBOSE} -ne 1 ]]; then
        return
    fi

    echo ""
    
    local message="Mole ${action} successfully"

    if [[ "$action" == "updated" && -n "$previous_version" && -n "$new_version" && "$previous_version" != "$new_version" ]]; then
        message+=" (${previous_version} -> ${new_version})"
    elif [[ -n "$new_version" ]]; then
        message+=" (version ${new_version})"
    fi

    log_confirm "$message"

    echo ""
    echo "Usage:"
    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        echo "  mo                # Interactive menu"
        echo "  mo clean          # System cleanup"
        echo "  mo uninstall      # Remove applications"
        echo "  mo update         # Update Mole to the latest version"
        echo "  mo remove         # Remove Mole from the system"
        echo "  mo --version      # Show installed version"
        echo "  mo --help         # Show this help message"
    else
        echo "  $INSTALL_DIR/mo                # Interactive menu"
        echo "  $INSTALL_DIR/mo clean          # System cleanup"
        echo "  $INSTALL_DIR/mo uninstall      # Remove applications"
        echo "  $INSTALL_DIR/mo update         # Update Mole to the latest version"
        echo "  $INSTALL_DIR/mo remove         # Remove Mole from the system"
        echo "  $INSTALL_DIR/mo --version      # Show installed version"
        echo "  $INSTALL_DIR/mo --help         # Show this help message"
    fi
    echo ""
}

# Uninstall function
uninstall_mole() {
    log_confirm "Uninstalling Mole"
    echo ""

    # Remove executable
    if [[ -f "$INSTALL_DIR/mole" ]]; then
        if [[ "$INSTALL_DIR" == "/usr/local/bin" ]] && [[ ! -w "$INSTALL_DIR" ]]; then
            log_admin "Admin access required"
            sudo rm -f "$INSTALL_DIR/mole"
        else
            rm -f "$INSTALL_DIR/mole"
        fi
        log_success "Removed mole executable"
    fi

    if [[ -f "$INSTALL_DIR/mo" ]]; then
        if [[ "$INSTALL_DIR" == "/usr/local/bin" ]] && [[ ! -w "$INSTALL_DIR" ]]; then
            sudo rm -f "$INSTALL_DIR/mo"
        else
            rm -f "$INSTALL_DIR/mo"
        fi
        log_success "Removed mo alias"
    fi

    # SAFETY CHECK: Verify config directory is safe to remove
    # Only allow removal of mole-specific directories
    local is_safe=0

    # Additional safety: never delete system critical paths (check first)
    case "$CONFIG_DIR" in
        /|/usr|/usr/local|/usr/local/bin|/usr/local/lib|/usr/local/share|\
        /Library|/System|/bin|/sbin|/etc|/var|/opt|"$HOME"|"$HOME/Library"|\
        /usr/local/lib/*|/usr/local/share/*|/Library/*|/System/*)
            is_safe=0
            ;;
        *)
            # Safe patterns: must be in user's home and end with 'mole'
            if [[ "$CONFIG_DIR" == "$HOME/.config/mole" ]] ||
               [[ "$CONFIG_DIR" == "$HOME"/.*/mole ]]; then
                is_safe=1
            fi
            ;;
    esac

    # Ask before removing config directory
    if [[ -d "$CONFIG_DIR" ]]; then
        if [[ $is_safe -eq 0 ]]; then
            log_warning "Config directory $CONFIG_DIR is not safe to auto-remove"
            log_warning "Skipping automatic removal for safety"
            echo ""
            echo "Please manually review and remove mole-specific files from:"
            echo "  $CONFIG_DIR"
        else
            echo ""
            read -p "Remove configuration directory $CONFIG_DIR? (y/N): " -n 1 -r; echo ""; if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf "$CONFIG_DIR"
                log_success "Removed configuration"
            else
                log_success "Configuration preserved"
            fi
        fi
    fi

    echo ""
    log_confirm "Mole uninstalled successfully"
}

# Main installation function
perform_install() {
    resolve_source_dir
    local source_version
    source_version="$(get_source_version || true)"

    check_requirements
    create_directories
    install_files
    verify_installation
    setup_path

    local installed_version
    installed_version="$(get_installed_version || true)"

    if [[ -z "$installed_version" ]]; then
        installed_version="$source_version"
    fi

    print_usage_summary "installed" "$installed_version"
}

perform_update() {
    check_requirements

    if command -v brew >/dev/null 2>&1 && brew list mole >/dev/null 2>&1; then
        # Try to use shared function if available (when running from installed Mole)
        resolve_source_dir 2>/dev/null || true
        if [[ -f "$SOURCE_DIR/lib/common.sh" ]]; then
            # shellcheck disable=SC1090,SC1091
            source "$SOURCE_DIR/lib/common.sh"
            update_via_homebrew "$VERSION"
        else
            # Fallback: inline implementation
            if [[ -t 1 ]]; then
                start_line_spinner "Updating Homebrew..."
            else
                echo "Updating Homebrew..."
            fi
            brew update 2>&1 | grep -Ev "^(==>|Already up-to-date)" || true
            if [[ -t 1 ]]; then
                stop_line_spinner
            fi

            if [[ -t 1 ]]; then
                start_line_spinner "Upgrading Mole..."
            else
                echo "Upgrading Mole..."
            fi
            local upgrade_output
            upgrade_output=$(brew upgrade mole 2>&1) || true
            if [[ -t 1 ]]; then
                stop_line_spinner
            fi

            if echo "$upgrade_output" | grep -q "already installed"; then
                local current_version
                current_version=$(brew list --versions mole 2>/dev/null | awk '{print $2}')
                echo -e "${GREEN}✓${NC} Already on latest version (${current_version:-$VERSION})"
            elif echo "$upgrade_output" | grep -q "Error:"; then
                log_error "Homebrew upgrade failed"
                echo "$upgrade_output" | grep "Error:" >&2
                exit 1
            else
                echo "$upgrade_output" | grep -Ev "^(==>|Updating Homebrew|Warning:)" || true
                local new_version
                new_version=$(brew list --versions mole 2>/dev/null | awk '{print $2}')
                echo -e "${GREEN}✓${NC} Updated to latest version (${new_version:-$VERSION})"
            fi

            rm -f "$HOME/.cache/mole/version_check" "$HOME/.cache/mole/update_message"
        fi
        exit 0
    fi

    local installed_version
    installed_version="$(get_installed_version || true)"

    if [[ -z "$installed_version" ]]; then
        log_warning "Mole is not currently installed in $INSTALL_DIR. Running fresh installation."
        perform_install
        return
    fi

    resolve_source_dir
    local target_version
    target_version="$(get_source_version || true)"

    if [[ -z "$target_version" ]]; then
        log_error "Unable to determine the latest Mole version."
        exit 1
    fi

    if [[ "$installed_version" == "$target_version" ]]; then
        echo -e "${GREEN}✓${NC} Already on latest version ($installed_version)"
        exit 0
    fi

    # Update with minimal output (suppress info/success, show errors only)
    local old_verbose=$VERBOSE
    VERBOSE=0
    create_directories || { VERBOSE=$old_verbose; log_error "Failed to create directories"; exit 1; }
    install_files || { VERBOSE=$old_verbose; log_error "Failed to install files"; exit 1; }
    verify_installation || { VERBOSE=$old_verbose; log_error "Failed to verify installation"; exit 1; }
    setup_path
    VERBOSE=$old_verbose

    local updated_version
    updated_version="$(get_installed_version || true)"

    if [[ -z "$updated_version" ]]; then
        updated_version="$target_version"
    fi

    echo -e "${GREEN}✓${NC} Updated to latest version ($updated_version)"
}

# Run requested action
parse_args "$@"

case "$ACTION" in
    update)
        perform_update
        ;;
    *)
        perform_install
        ;;
esac
