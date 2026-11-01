#!/bin/bash
# Mole CLI (Linux) - load the core libraries.

set -euo pipefail

_MOLE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MOLE_COMMON_DIR/base.sh"
source "$_MOLE_COMMON_DIR/ui.sh"
source "$_MOLE_COMMON_DIR/log.sh"
source "$_MOLE_COMMON_DIR/delete.sh"

# Refuse root: user state must never be touched with inherited privileges.
mole_refuse_root() {
    if [[ "$EUID" -eq 0 ]]; then
        printf '%s\n' 'Run Mole without sudo; it asks for sudo itself when a step needs it.' >&2
        exit 1
    fi
}

# Ask once for sudo when a step needs it. Returns 0 when sudo is usable.
mole_sudo_ready() {
    sudo -n true 2> /dev/null && return 0
    [[ -t 0 ]] || return 1
    echo -e "${PURPLE}${ICON_ADMIN}${NC} $1"
    sudo -v 2> /dev/null
}

# Y/Enter confirms, anything else cancels.
mole_confirm() {
    local prompt="$1" key
    echo -ne "${PURPLE}${ICON_ARROW}${NC} ${prompt}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "
    key=$(read_key) || key="QUIT"
    echo ""
    [[ "$key" == "ENTER" || "$key" == "CHAR:y" || "$key" == "CHAR:Y" ]]
}
