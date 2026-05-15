#!/bin/bash

show_clean_help() {
    msg HELP_CLEAN_USAGE; echo
    echo
    msg HELP_CLEAN_DESC; echo
    echo
    printf '%s:\n' "$(msg HELP_OPTIONS)"
    printf '  --dry-run, -n     %s\n' "$(msg HELP_CLEAN_DRY_RUN)"
    printf '  --external PATH   %s\n' "$(msg HELP_CLEAN_EXTERNAL)"
    printf '  --whitelist       %s\n' "$(msg HELP_CLEAN_WHITELIST)"
    printf '  --debug           %s\n' "$(msg HELP_CLEAN_DEBUG)"
    printf '  -h, --help        %s\n' "$(msg HELP_CLEAN_HELP)"
}

show_installer_help() {
    msg HELP_INSTALLER_USAGE; echo
    echo
    msg HELP_INSTALLER_DESC; echo
    echo
    printf '%s:\n' "$(msg HELP_OPTIONS)"
    printf '  --dry-run         %s\n' "$(msg HELP_INSTALLER_DRY_RUN)"
    printf '  --debug           %s\n' "$(msg HELP_CLEAN_DEBUG)"
    printf '  -h, --help        %s\n' "$(msg HELP_CLEAN_HELP)"
}

show_optimize_help() {
    msg HELP_OPTIMIZE_USAGE; echo
    echo
    msg HELP_OPTIMIZE_DESC; echo
    echo
    printf '%s:\n' "$(msg HELP_OPTIONS)"
    printf '  --dry-run         %s\n' "$(msg HELP_OPTIMIZE_DRY_RUN)"
    printf '  --whitelist       %s\n' "$(msg HELP_OPTIMIZE_WHITELIST)"
    printf '  --debug           %s\n' "$(msg HELP_CLEAN_DEBUG)"
    printf '  -h, --help        %s\n' "$(msg HELP_CLEAN_HELP)"
}

show_touchid_help() {
    msg HELP_TOUCHID_USAGE; echo
    echo
    msg HELP_TOUCHID_DESC; echo
    echo
    printf '%s:\n' "$(msg HELP_COMMANDS)"
    printf '  enable            %s\n' "$(msg HELP_TOUCHID_ENABLE)"
    printf '  disable           %s\n' "$(msg HELP_TOUCHID_DISABLE)"
    printf '  status            %s\n' "$(msg HELP_TOUCHID_STATUS)"
    echo
    printf '%s:\n' "$(msg HELP_OPTIONS)"
    printf '  --dry-run         %s\n' "$(msg HELP_TOUCHID_DRY_RUN)"
    printf '  -h, --help        %s\n' "$(msg HELP_CLEAN_HELP)"
    echo
    msg HELP_TOUCHID_NO_CMD; echo
}

show_uninstall_help() {
    msg HELP_UNINSTALL_USAGE; echo
    echo
    msg HELP_UNINSTALL_DESC; echo
    msg HELP_UNINSTALL_DESC2; echo
    msg HELP_UNINSTALL_DESC3; echo
    echo
    printf '%s:\n' "$(msg HELP_UNINSTALL_EXAMPLES)"
    printf '  mo uninstall                   %s\n' "$(msg HELP_UNINSTALL_EXAMPLE_INTERACTIVE)"
    printf '  mo uninstall slack             %s\n' "$(msg HELP_UNINSTALL_EXAMPLE_SINGLE)"
    printf '  mo uninstall slack zoom        %s\n' "$(msg HELP_UNINSTALL_EXAMPLE_MULTI)"
    printf '  mo uninstall --dry-run slack   %s\n' "$(msg HELP_UNINSTALL_EXAMPLE_DRY)"
    printf '  mo uninstall --list            %s\n' "$(msg HELP_UNINSTALL_EXAMPLE_LIST)"
    echo
    printf '%s:\n' "$(msg HELP_OPTIONS)"
    printf '  --list            %s\n' "$(msg HELP_UNINSTALL_LIST)"
    printf '  --dry-run         %s\n' "$(msg HELP_UNINSTALL_DRY_RUN)"
    printf '  --permanent       %s\n' "$(msg HELP_UNINSTALL_PERMANENT)"
    printf '  --whitelist       %s\n' "$(msg HELP_UNINSTALL_WHITELIST)"
    printf '  --debug           %s\n' "$(msg HELP_CLEAN_DEBUG)"
    printf '  -h, --help        %s\n' "$(msg HELP_CLEAN_HELP)"
    echo
    msg HELP_UNINSTALL_TRASH_NOTE; echo
    msg HELP_UNINSTALL_TRASH_NOTE2; echo
}
