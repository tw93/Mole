#!/bin/bash
# Sudo Session Manager
# Unified sudo authentication and keepalive management

set -euo pipefail

# ============================================================================
# Touch ID and Clamshell Detection
# ============================================================================

check_touchid_support() {
    # Check sudo_local first (Sonoma+)
    if [[ -f /etc/pam.d/sudo_local ]]; then
        grep -q "pam_tid.so" /etc/pam.d/sudo_local 2> /dev/null
        return $?
    fi

    # Fallback to checking sudo directly
    if [[ -f /etc/pam.d/sudo ]]; then
        grep -q "pam_tid.so" /etc/pam.d/sudo 2> /dev/null
        return $?
    fi
    return 1
}

# Detect clamshell mode (lid closed)
is_clamshell_mode() {
    # ioreg is missing (not macOS) -> treat as lid open
    if ! command -v ioreg > /dev/null 2>&1; then
        return 1
    fi

    # Check if lid is closed; ignore pipeline failures so set -e doesn't exit
    local clamshell_state=""
    clamshell_state=$( (ioreg -r -k AppleClamshellState -d 4 2> /dev/null |
        grep "AppleClamshellState" |
        head -1) || true)

    if [[ "$clamshell_state" =~ \"AppleClamshellState\"\ =\ Yes ]]; then
        return 0 # Lid is closed
    fi
    return 1 # Lid is open
}

_request_password() {
    local tty_path="$1"

    sudo -k 2> /dev/null

    local stty_orig
    stty_orig=$(stty -g < "$tty_path" 2> /dev/null || echo "")
    trap '[[ -n "${stty_orig:-}" ]] && stty "${stty_orig:-}" < "$tty_path" 2> /dev/null || true' RETURN

    if check_touchid_support; then
        echo -e "${GRAY}Note: Touch ID dialog may appear once more, just cancel it${NC}" > "$tty_path"
    fi

    echo -e "${PURPLE}${ICON_ARROW}${NC} Enter your credentials:" > "$tty_path"

    # shellcheck disable=SC2024,SC2094
    # Intentionally route sudo's native prompt to the same TTY device it reads from.
    if sudo -v < "$tty_path" > /dev/null 2> "$tty_path"; then
        return 0
    fi

    return 1
}

request_sudo_access() {
    local prompt_msg="${1:-Admin access required}"

    # Check if already have sudo access
    if sudo -n true 2> /dev/null; then
        return 0
    fi

    # Tests must never trigger real password or Touch ID prompts.
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    # Detect if running in TTY environment
    local tty_path="/dev/tty"
    local is_gui_mode=false

    if [[ ! -r "$tty_path" || ! -w "$tty_path" ]]; then
        tty_path=$(tty 2> /dev/null || echo "")
        if [[ -z "$tty_path" || ! -r "$tty_path" || ! -w "$tty_path" ]]; then
            is_gui_mode=true
        fi
    fi

    # GUI mode: use osascript for password dialog
    if [[ "$is_gui_mode" == true ]]; then
        # Clear sudo cache before attempting authentication
        sudo -k 2> /dev/null

        # Display native macOS password dialog
        local password
        password=$(osascript -e "display dialog \"$prompt_msg\" default answer \"\" with title \"Mole\" with icon caution with hidden answer" -e 'text returned of result' 2> /dev/null)

        if [[ -z "$password" ]]; then
            # User cancelled the dialog
            unset password
            return 1
        fi

        # Attempt sudo authentication with the provided password
        if printf '%s\n' "$password" | sudo -S -p "" -v > /dev/null 2>&1; then
            unset password
            return 0
        fi

        # Password was incorrect
        unset password
        return 1
    fi

    sudo -k

    # Check if in clamshell mode - if yes, skip Touch ID entirely
    if is_clamshell_mode; then
        local clear_lines=3
        if check_touchid_support; then
            clear_lines=4
        fi
        echo -e "${PURPLE}${ICON_ARROW}${NC} ${prompt_msg}"
        if _request_password "$tty_path"; then
            # Clear all prompt lines (use safe clearing method)
            safe_clear_lines "$clear_lines" "$tty_path"
            return 0
        fi
        return 1
    fi

    # Not in clamshell mode - try Touch ID if configured
    if ! check_touchid_support; then
        echo -e "${PURPLE}${ICON_ARROW}${NC} ${prompt_msg}"
        if _request_password "$tty_path"; then
            # Clear all prompt lines (use safe clearing method)
            safe_clear_lines 3 "$tty_path"
            return 0
        fi
        return 1
    fi

    # Touch ID is available and not in clamshell mode
    echo -e "${PURPLE}${ICON_ARROW}${NC} ${prompt_msg} ${GRAY}, Touch ID or password${NC}"

    # Start sudo in background so we can monitor and control it
    sudo -v < /dev/null > /dev/null 2>&1 &
    local sudo_pid=$!

    # Wait for sudo to complete or timeout (5 seconds)
    local elapsed=0
    local timeout=50 # 50 * 0.1s = 5 seconds
    while ((elapsed < timeout)); do
        if ! kill -0 "$sudo_pid" 2> /dev/null; then
            # Process exited
            wait "$sudo_pid" 2> /dev/null
            local exit_code=$?
            if [[ $exit_code -eq 0 ]] && sudo -n true 2> /dev/null; then
                # Touch ID succeeded - clear the prompt line
                safe_clear_lines 1 "$tty_path"
                return 0
            fi
            # Touch ID failed or cancelled
            break
        fi
        sleep 0.1
        elapsed=$((elapsed + 1))
    done

    # Touch ID failed/cancelled - clean up thoroughly before password input

    # Kill the sudo process if still running
    if kill -0 "$sudo_pid" 2> /dev/null; then
        kill -9 "$sudo_pid" 2> /dev/null
        wait "$sudo_pid" 2> /dev/null || true
    fi

    # Clear sudo state immediately
    sudo -k 2> /dev/null

    # IMPORTANT: Wait longer for macOS to fully close Touch ID UI and SecurityAgent
    # Without this delay, subsequent sudo calls may re-trigger Touch ID
    sleep 1

    # Clear any leftover prompts on the screen
    safe_clear_line "$tty_path"

    # Now use our password input (this should not trigger Touch ID again)
    if _request_password "$tty_path"; then
        # Clear all prompt lines (use safe clearing method)
        safe_clear_lines 3 "$tty_path"
        return 0
    fi
    return 1
}

# ============================================================================
# Sudo Session Management
# ============================================================================

# Global state
MOLE_SUDO_KEEPALIVE_PID=""
MOLE_SUDO_ESTABLISHED="false"

# Start sudo keepalive
_start_sudo_keepalive() {
    # Start background keepalive process with all outputs redirected
    # This is critical: command substitution waits for all file descriptors to close
    (
        # Initial delay to let sudo cache stabilize after password entry
        # This prevents immediately triggering Touch ID again
        sleep 2

        local retry_count=0
        while true; do
            if ! sudo -n -v 2> /dev/null; then
                retry_count=$((retry_count + 1))
                if [[ $retry_count -ge 3 ]]; then
                    exit 1
                fi
                sleep 5
                continue
            fi
            retry_count=0
            sleep 30
            kill -0 "$$" 2> /dev/null || exit
        done
    ) > /dev/null 2>&1 &

    local pid=$!
    echo $pid
}

# Stop sudo keepalive
_stop_sudo_keepalive() {
    local pid="${1:-}"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2> /dev/null || true
        wait "$pid" 2> /dev/null || true
    fi
}

# Check if sudo session is active
has_sudo_session() {
    sudo -n true 2> /dev/null
}

# Request administrative access
request_sudo() {
    local prompt_msg="${1:-Admin access required}"

    if has_sudo_session; then
        return 0
    fi

    # Use the robust implementation from common.sh
    if request_sudo_access "$prompt_msg"; then
        return 0
    else
        return 1
    fi
}

# Maintain active sudo session with keepalive
ensure_sudo_session() {
    local prompt="${1:-Admin access required}"

    # Check if already established
    if has_sudo_session && [[ "$MOLE_SUDO_ESTABLISHED" == "true" ]]; then
        return 0
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    # Stop old keepalive if exists
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi

    # Request sudo access
    if ! request_sudo "$prompt"; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    # Start keepalive
    MOLE_SUDO_KEEPALIVE_PID=$(_start_sudo_keepalive)

    MOLE_SUDO_ESTABLISHED="true"
    return 0
}

# Stop sudo session and cleanup
stop_sudo_session() {
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi
    MOLE_SUDO_ESTABLISHED="false"
}

# Register cleanup on script exit
register_sudo_cleanup() {
    trap stop_sudo_session EXIT INT TERM
}

# Predict if operation requires administrative access
will_need_sudo() {
    local -a operations=("$@")
    for op in "${operations[@]}"; do
        case "$op" in
            system_update | appstore_update | macos_update | firewall | touchid | rosetta | system_fix)
                return 0
                ;;
        esac
    done
    return 1
}
