#!/bin/bash

# Shared command list for help text and completions.
MOLE_COMMANDS=(
    "clean:${TR_CMD_CLEAN:-Free up disk space}"
    "uninstall:${TR_CMD_UNINSTALL:-Remove apps completely}"
    "optimize:${TR_CMD_OPTIMIZE:-Check and maintain system}"
    "analyze:${TR_CMD_ANALYZE:-Explore disk usage}"
    "status:${TR_CMD_STATUS:-Monitor system health}"
    "purge:${TR_CMD_PURGE:-Remove old project artifacts}"
    "installer:${TR_CMD_INSTALLER:-Find and remove installer files}"
    "touchid:${TR_CMD_TOUCHID:-Configure Touch ID for sudo}"
    "completion:${TR_CMD_COMPLETION:-Setup shell tab completion}"
    "update:${TR_CMD_UPDATE:-Update to latest version}"
    "remove:${TR_CMD_REMOVE:-Remove Mole from system}"
    "help:${TR_CMD_HELP:-Show help}"
    "version:${TR_CMD_VERSION:-Show version}"
)
