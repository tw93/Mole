#!/bin/bash

show_clean_help() {
    echo "${TR_HELP_CLEAN_USAGE:-Usage: mo clean [OPTIONS]}"
    echo ""
    echo "${TR_HELP_CLEAN_DESC:-Clean up disk space by removing caches, logs, temporary files, and app leftovers from already-uninstalled apps.}"
    echo ""
    echo "${TR_HELP_OPTIONS:-Options:}"
    echo "  --dry-run, -n     ${TR_HELP_CLEAN_DRY:-Preview cleanup without making changes}"
    echo "  --external ${TR_HELP_PATH_ARG:-PATH}   ${TR_HELP_CLEAN_EXTERNAL:-Clean OS metadata from a mounted external volume}"
    echo "  --whitelist       ${TR_HELP_CLEAN_WHITELIST:-Manage protected paths}"
    echo "  --debug           ${TR_HELP_DEBUG:-Show detailed operation logs}"
    echo "  -h, --help        ${TR_HELP_SHOW_HELP:-Show this help message}"
}

show_installer_help() {
    echo "${TR_HELP_INST_USAGE:-Usage: mo installer [OPTIONS]}"
    echo ""
    echo "${TR_HELP_INST_DESC:-Find and remove installer files (.dmg, .pkg, .iso, .xip, .zip).}"
    echo ""
    echo "${TR_HELP_OPTIONS:-Options:}"
    echo "  --dry-run         ${TR_HELP_INST_DRY:-Preview installer cleanup without making changes}"
    echo "  --debug           ${TR_HELP_DEBUG:-Show detailed operation logs}"
    echo "  -h, --help        ${TR_HELP_SHOW_HELP:-Show this help message}"
}

show_optimize_help() {
    echo "${TR_HELP_OPT_USAGE:-Usage: mo optimize [OPTIONS]}"
    echo ""
    echo "${TR_HELP_OPT_DESC:-Check and maintain system health, apply optimizations.}"
    echo ""
    echo "${TR_HELP_OPTIONS:-Options:}"
    echo "  --dry-run         ${TR_HELP_OPT_DRY:-Preview optimization without making changes}"
    echo "  --whitelist       ${TR_HELP_OPT_WHITELIST:-Manage protected items}"
    echo "  --debug           ${TR_HELP_DEBUG:-Show detailed operation logs}"
    echo "  -h, --help        ${TR_HELP_SHOW_HELP:-Show this help message}"
}

show_touchid_help() {
    echo "${TR_HELP_TID_USAGE:-Usage: mo touchid [COMMAND]}"
    echo ""
    echo "${TR_HELP_TID_DESC:-Configure Touch ID for sudo authentication.}"
    echo ""
    echo "${TR_HELP_COMMANDS:-Commands:}"
    echo "  enable            ${TR_HELP_TID_ENABLE:-Enable Touch ID for sudo}"
    echo "  disable           ${TR_HELP_TID_DISABLE:-Disable Touch ID for sudo}"
    echo "  status            ${TR_HELP_TID_STATUS:-Show current Touch ID status}"
    echo ""
    echo "${TR_HELP_OPTIONS:-Options:}"
    echo "  --dry-run         ${TR_HELP_TID_DRY:-Preview Touch ID changes without modifying sudo config}"
    echo "  -h, --help        ${TR_HELP_SHOW_HELP:-Show this help message}"
    echo ""
    echo "${TR_HELP_TID_FOOTER:-If no command is provided, an interactive menu is shown.}"
}

show_uninstall_help() {
    echo "${TR_HELP_UNI_USAGE:-Usage: mo uninstall [OPTIONS] [APP_NAME ...]}"
    echo ""
    echo "${TR_HELP_UNI_DESC_1:-Interactively remove applications and their leftover files.}"
    echo "${TR_HELP_UNI_DESC_2:-Optionally specify one or more app names to uninstall directly.}"
    echo "${TR_HELP_UNI_DESC_3:-For leftovers from apps that are already gone, use mo clean.}"
    echo ""
    echo "${TR_HELP_EXAMPLES:-Examples:}"
    echo "  mo uninstall                   ${TR_HELP_UNI_EX_1:-Open interactive app selector}"
    echo "  mo uninstall slack             ${TR_HELP_UNI_EX_2:-Uninstall Slack}"
    echo "  mo uninstall slack zoom        ${TR_HELP_UNI_EX_3:-Uninstall Slack and Zoom}"
    echo "  mo uninstall --dry-run slack   ${TR_HELP_UNI_EX_4:-Preview Slack uninstallation}"
    echo ""
    echo "${TR_HELP_OPTIONS:-Options:}"
    echo "  --dry-run         ${TR_HELP_UNI_DRY:-Preview app uninstallation without making changes}"
    echo "  --whitelist       ${TR_HELP_UNI_WHITELIST:-Not supported for uninstall (use clean/optimize)}"
    echo "  --debug           ${TR_HELP_DEBUG:-Show detailed operation logs}"
    echo "  -h, --help        ${TR_HELP_SHOW_HELP:-Show this help message}"
}
