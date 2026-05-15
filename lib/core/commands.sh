#!/bin/bash

# Shared command list for help text and completions.
# Descriptions are resolved via the i18n module (lib/core/i18n.sh).
# If i18n is not yet loaded, raw keys are returned as a safe fallback.
_mole_cmd_desc() {
    if declare -F msg > /dev/null 2>&1; then
        msg "$1"
    else
        printf '%s' "$1"
    fi
}

MOLE_COMMANDS=(
    "clean:$(_mole_cmd_desc CMD_CLEAN)"
    "uninstall:$(_mole_cmd_desc CMD_UNINSTALL)"
    "optimize:$(_mole_cmd_desc CMD_OPTIMIZE)"
    "analyze:$(_mole_cmd_desc CMD_ANALYZE)"
    "status:$(_mole_cmd_desc CMD_STATUS)"
    "purge:$(_mole_cmd_desc CMD_PURGE)"
    "installer:$(_mole_cmd_desc CMD_INSTALLER)"
    "touchid:$(_mole_cmd_desc CMD_TOUCHID)"
    "completion:$(_mole_cmd_desc CMD_COMPLETION)"
    "update:$(_mole_cmd_desc CMD_UPDATE)"
    "remove:$(_mole_cmd_desc CMD_REMOVE)"
    "help:$(_mole_cmd_desc CMD_HELP)"
    "version:$(_mole_cmd_desc CMD_VERSION)"
)

