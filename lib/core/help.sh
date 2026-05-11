#!/bin/bash

show_clean_help() {
    echo "Usage: mo clean [OPTIONS]"
    echo ""
    echo "Clean up disk space by removing caches, logs, temporary files, and app leftovers from already-uninstalled apps."
    echo ""
    echo "Options:"
    echo "  --dry-run, -n     Preview cleanup without making changes"
    echo "  --external PATH   Clean OS metadata from a mounted external volume"
    echo "  --whitelist       Manage protected paths"
    echo "  --debug           Show detailed operation logs"
    echo "  -h, --help        Show this help message"
}

show_installer_help() {
    echo "Usage: mo installer [OPTIONS]"
    echo ""
    echo "Find and remove installer files (.dmg, .pkg, .iso, .xip, .zip)."
    echo ""
    echo "Options:"
    echo "  --dry-run         Preview installer cleanup without making changes"
    echo "  --debug           Show detailed operation logs"
    echo "  -h, --help        Show this help message"
}

show_optimize_help() {
    echo "Usage: mo optimize [OPTIONS]"
    echo ""
    echo "Refresh system caches and services, repair safe maintenance issues."
    echo ""
    echo "Options:"
    echo "  --dry-run         Preview optimization without making changes"
    echo "  --whitelist       Manage protected items"
    echo "  --debug           Show detailed operation logs"
    echo "  -h, --help        Show this help message"
}

show_touchid_help() {
    echo "Usage: mo touchid [COMMAND]"
    echo ""
    echo "Configure Touch ID for sudo authentication."
    echo ""
    echo "Commands:"
    echo "  enable            Enable Touch ID for sudo"
    echo "  disable           Disable Touch ID for sudo"
    echo "  status            Show current Touch ID status"
    echo ""
    echo "Options:"
    echo "  --dry-run         Preview Touch ID changes without modifying sudo config"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "If no command is provided, an interactive menu is shown."
}

show_uninstall_help() {
    echo "Usage: mo uninstall [OPTIONS] [APP_NAME ...]"
    echo ""
    echo "Interactively remove applications and their leftover files."
    echo "Optionally specify one or more app names to uninstall directly."
    echo "If the .app was already manually deleted, mo uninstall will detect"
    echo "leftover files and offer to clean them."
    echo ""
    echo "Examples:"
    echo "  mo uninstall                   Open interactive app selector"
    echo "  mo uninstall slack             Uninstall Slack"
    echo "  mo uninstall slack zoom        Uninstall Slack and Zoom"
    echo "  mo uninstall --dry-run slack   Preview Slack uninstallation"
    echo "  mo uninstall --list            Show installed apps and the names mo uninstall accepts"
    echo ""
    echo "Options:"
    echo "  --list            List installed apps with the exact name mo uninstall accepts"
    echo "  --dry-run         Preview app uninstallation without making changes"
    echo "  --permanent       Bypass macOS Trash and rm -rf immediately"
    echo "  --whitelist       Not supported for uninstall (use clean/optimize)"
    echo "  --debug           Show detailed operation logs"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "By default, uninstalled files go to the macOS Trash so they can be"
    echo "recovered. Use --permanent to skip the Trash step."
}
