#!/bin/bash

show_clean_help() {
    mole_println_t "Usage: mo clean [OPTIONS]"
    echo ""
    mole_println_t "Clean up disk space by removing caches, logs, and temporary files."
    echo ""
    mole_println_t "Options:"
    mole_println_t "  --dry-run, -n     Preview cleanup without making changes"
    mole_println_t "  --external PATH   Clean OS metadata from a mounted external volume"
    mole_println_t "  --whitelist       Manage protected paths"
    mole_println_t "  --debug           Show detailed operation logs"
    mole_println_t "  -h, --help        Show this help message"
}

show_installer_help() {
    mole_println_t "Usage: mo installer [OPTIONS]"
    echo ""
    mole_println_t "Find and remove installer files (.dmg, .pkg, .iso, .xip, .zip)."
    echo ""
    mole_println_t "Options:"
    mole_println_t "  --dry-run         Preview installer cleanup without making changes"
    mole_println_t "  --debug           Show detailed operation logs"
    mole_println_t "  -h, --help        Show this help message"
}

show_optimize_help() {
    mole_println_t "Usage: mo optimize [OPTIONS]"
    echo ""
    mole_println_t "Check and maintain system health, apply optimizations."
    echo ""
    mole_println_t "Options:"
    mole_println_t "  --dry-run         Preview optimization without making changes"
    mole_println_t "  --whitelist       Manage protected items"
    mole_println_t "  --debug           Show detailed operation logs"
    mole_println_t "  -h, --help        Show this help message"
}

show_touchid_help() {
    mole_println_t "Usage: mo touchid [COMMAND]"
    echo ""
    mole_println_t "Configure Touch ID for sudo authentication."
    echo ""
    mole_println_t "Commands:"
    mole_println_t "  enable            Enable Touch ID for sudo"
    mole_println_t "  disable           Disable Touch ID for sudo"
    mole_println_t "  status            Show current Touch ID status"
    echo ""
    mole_println_t "Options:"
    mole_println_t "  --dry-run         Preview Touch ID changes without modifying sudo config"
    mole_println_t "  -h, --help        Show this help message"
    echo ""
    mole_println_t "If no command is provided, an interactive menu is shown."
}

show_uninstall_help() {
    mole_println_t "Usage: mo uninstall [OPTIONS]"
    echo ""
    mole_println_t "Interactively remove applications and their leftover files."
    echo ""
    mole_println_t "Options:"
    mole_println_t "  --dry-run         Preview app uninstallation without making changes"
    mole_println_t "  --whitelist       Not supported for uninstall (use clean/optimize)"
    mole_println_t "  --debug           Show detailed operation logs"
    mole_println_t "  -h, --help        Show this help message"
}

show_language_help() {
    mole_println_t "Usage: mo language [OPTIONS]"
    echo ""
    mole_println_t "Choose or update Mole interface language."
    echo ""
    mole_println_t "Options:"
    mole_println_t "  --set LANG        Set language directly (zh-CN or en-US)"
    mole_println_t "  -h, --help        Show this help message"
}
