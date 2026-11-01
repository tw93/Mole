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

# Ask for sudo with Mole's own prompt line. sudo still reads the password (and
# any PAM method such as a fingerprint); Mole never holds it. Returns 0 when
# sudo is usable, and keeps the timestamp fresh until mole_sudo_end.
MOLE_SUDO_KEEPALIVE_PID=""
MOLE_SUDO_OWNED=false
mole_sudo_ready() {
    if ! sudo -n true 2> /dev/null; then
        [[ -t 0 && -r /dev/tty && -w /dev/tty ]] || return 1
        local prompt
        prompt=$(printf '%b' "${PURPLE}${ICON_ARROW}${NC} Password: ")
        if ! sudo -v -p "$prompt"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Authentication failed"
            return 1
        fi
        # Replace the password line with the result.
        printf '\033[1A\r\033[K'
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
        MOLE_SUDO_OWNED=true
    fi
    if [[ -z "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        (
            nap=""
            trap '[[ -n "$nap" ]] && kill "$nap" 2> /dev/null; exit 0' TERM
            while kill -0 "$$" 2> /dev/null; do
                sleep 50 &
                nap=$!
                wait "$nap"
                sudo -n -v 2> /dev/null || exit 0
            done
        ) &
        MOLE_SUDO_KEEPALIVE_PID=$!
        disown "$MOLE_SUDO_KEEPALIVE_PID" 2> /dev/null || true
    fi
    return 0
}

# Stop the keepalive; drop the timestamp only when Mole asked for it, so a
# sudo session the user already had stays.
mole_sudo_end() {
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        kill "$MOLE_SUDO_KEEPALIVE_PID" 2> /dev/null || true
        MOLE_SUDO_KEEPALIVE_PID=""
    fi
    if [[ "$MOLE_SUDO_OWNED" == true ]]; then
        sudo -k 2> /dev/null || true
        MOLE_SUDO_OWNED=false
    fi
}

# Y/Enter confirms, anything else cancels.
mole_confirm() {
    local prompt="$1" key
    echo -ne "${PURPLE}${ICON_ARROW}${NC} ${prompt}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "
    key=$(read_key) || key="QUIT"
    echo ""
    [[ "$key" == "ENTER" || "$key" == "CHAR:y" || "$key" == "CHAR:Y" ]]
}
