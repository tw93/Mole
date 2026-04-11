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
    echo "Check and maintain system health, apply optimizations."
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
    echo "Usage: mo uninstall [APP_NAME...] [OPTIONS]"
    echo ""
    echo "Remove applications and their leftover files."
    echo "Without app names, launches interactive selector."
    echo "With app names, directly uninstalls the matching apps."
    echo "For leftovers from apps that are already gone, use mo clean."
    echo ""
    echo "Examples:"
    echo "  mo uninstall                   Interactive app selector"
    echo "  mo uninstall WeChat            Uninstall WeChat directly"
    echo "  mo uninstall WeChat Slack      Uninstall multiple apps"
    echo "  mo uninstall --dry-run WeChat  Preview without changes"
    echo ""
    echo "Options:"
    echo "  --dry-run         Preview app uninstallation without making changes"
    echo "  --whitelist       Not supported for uninstall (use clean/optimize)"
    echo "  --debug           Show detailed operation logs"
    echo "  -h, --help        Show this help message"
}
