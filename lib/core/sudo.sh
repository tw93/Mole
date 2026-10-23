#!/bin/bash
# Sudo Session Manager
# Unified sudo authentication and keepalive management

set -euo pipefail

# ============================================================================
# Touch ID and Clamshell Detection
# ============================================================================

check_touchid_support() {
    local pam_sudo_file="${MOLE_PAM_SUDO_FILE:-/etc/pam.d/sudo}"
    local pam_sudo_local_file="${MOLE_PAM_SUDO_LOCAL_FILE:-$(dirname "$pam_sudo_file")/sudo_local}"

    # Check sudo_local first (Sonoma+)
    if [[ -f "$pam_sudo_local_file" ]] && mole_pam_enables_touchid "$pam_sudo_local_file"; then
        return 0
    fi

    # Fallback to checking sudo directly
    if [[ -f "$pam_sudo_file" ]]; then
        mole_pam_enables_touchid "$pam_sudo_file"
        return $?
    fi
    return 1
}

# A commented pam_tid.so line enables nothing: macOS ships sudo_local.template
# with it commented out, and commenting it out is how people turn Touch ID off
# by hand. Only a line with no "#" before pam_tid.so counts.
mole_pam_enables_touchid() {
    grep -q '^[^#]*pam_tid\.so' "$1" 2> /dev/null
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

# Run a command with terminal echo off and restore the original mode on every
# exit, Ctrl-C included. A subshell owns the restore, so it never depends on
# the caller's traps. Typed input stays buffered for the next reader.
_mole_tty_quiet() (
    # No `local`: the EXIT trap runs after the function scope ends, and the
    # subshell already keeps these names away from the caller.
    _quiet_tty="$1"
    shift
    _quiet_saved=$({ stty -g < "$_quiet_tty"; } 2> /dev/null) || _quiet_saved=""
    if [[ -n "$_quiet_saved" ]]; then
        trap 'stty "$_quiet_saved" < "$_quiet_tty" 2> /dev/null || true' EXIT
        trap 'exit 130' INT TERM HUP
        stty -echo < "$_quiet_tty" 2> /dev/null || true
    fi
    "$@"
)

# Poll a background Touch ID sudo for up to 5 seconds: 0 once it exited,
# 1 when it is still waiting.
_mole_touchid_poll() {
    local sudo_pid="$1"
    local elapsed=0
    while ((elapsed < 50)); do
        kill -0 "$sudo_pid" 2> /dev/null || return 0
        sleep 0.1
        elapsed=$((elapsed + 1))
    done
    return 1
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

    # Tests must never trigger real password or Touch ID prompts.
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    # Check if already have sudo access
    if sudo -n true 2> /dev/null; then
        return 0
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

        # Display native macOS password dialog. prompt_msg can carry on-disk
        # app display names (batch uninstall builds it from ${sudo_apps[*]}),
        # so escape backslashes and double quotes before embedding it in the
        # AppleScript string literal, or an app named with an embedded quote
        # could break out and run `do shell script`. Same escaping as
        # force_kill_app and remove_login_item.
        local escaped_msg="${prompt_msg//\\/\\\\}"
        escaped_msg="${escaped_msg//\"/\\\"}"
        local password
        password=$(osascript -e "display dialog \"$escaped_msg\" default answer \"\" with title \"Mole\" with icon caution with hidden answer" -e 'text returned of result' 2> /dev/null)

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

    # Wait for sudo to complete or timeout (5 seconds). People often type the
    # password instead of touching the sensor; keep it off the screen while
    # it waits for the password prompt that reads it.
    local poll_rc=0
    _mole_tty_quiet "$tty_path" _mole_touchid_poll "$sudo_pid" || poll_rc=$?
    if [[ $poll_rc -eq 0 ]]; then
        local exit_code=0
        wait "$sudo_pid" 2> /dev/null || exit_code=$?
        if [[ $exit_code -eq 0 ]] && sudo -n true 2> /dev/null; then
            # Touch ID succeeded - clear the prompt line
            safe_clear_lines 1 "$tty_path"
            return 0
        fi
    fi

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
    _mole_tty_quiet "$tty_path" sleep 1 || true

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

request_sudo_access_with_password() {
    local password="$1"
    local prompt_msg="${2:-Admin access required}"

    # Tests must never trigger real password or Touch ID prompts.
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    if [[ -z "$password" ]]; then
        request_sudo_access "$prompt_msg"
        return $?
    fi

    sudo -k 2> /dev/null

    if printf '%s\n' "$password" | sudo -S -p "" -v > /dev/null 2>&1; then
        unset password
        return 0
    fi

    unset password
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
        # Subshell-only state must survive function-local unwinding at EXIT.
        child_pid=""
        local delay=2
        # A foreground sleep delays shell traps and can outlive the worker.
        # Wait on an owned child instead, then reap it before this worker exits.
        trap 'if [[ -n "$child_pid" ]]; then kill "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi' EXIT
        trap 'exit 0' HUP INT TERM
        while true; do
            # The initial delay lets the credential cache settle after login.
            sleep "$delay" &
            child_pid=$!
            wait "$child_pid" || true
            child_pid=""
            kill -0 "$$" 2> /dev/null || exit
            sudo -n -v 2> /dev/null &
            child_pid=$!
            if wait "$child_pid"; then
                delay=30
            else
                # A failed refresh is harmless and often transient (authd
                # busy, machine waking). Giving up after a few misses is what
                # let the timestamp lapse minutes into a long install and
                # forced a second authentication prompt; `-n` never prompts,
                # so retrying costs nothing. Exit only with the parent.
                delay=5
            fi
            child_pid=""
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
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    sudo -n true 2> /dev/null
}

adopt_sudo_session() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    if [[ "$MOLE_SUDO_ESTABLISHED" == "true" && -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        if has_sudo_session; then
            return 0
        fi
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
        MOLE_SUDO_ESTABLISHED="false"
    fi

    local adoption_rc=0
    if [[ -t 0 ]] && declare -F mole_tty_is_foreground > /dev/null && mole_tty_is_foreground; then
        # Validate command access before cleanup can hide a deferred prompt.
        has_sudo_session || adoption_rc=$?
    else
        sudo -n -v 2> /dev/null || adoption_rc=$?
    fi
    if [[ $adoption_rc -ne 0 ]]; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi

    MOLE_SUDO_KEEPALIVE_PID=$(_start_sudo_keepalive)
    MOLE_SUDO_ESTABLISHED="true"
    return 0
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

ensure_sudo_session_with_password() {
    local password="$1"
    local prompt="${2:-Admin access required}"

    # Check if already established
    if has_sudo_session && [[ "$MOLE_SUDO_ESTABLISHED" == "true" ]]; then
        unset password
        return 0
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        MOLE_SUDO_ESTABLISHED="false"
        unset password
        return 1
    fi

    # Stop old keepalive if exists
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi

    # Request sudo access
    if ! request_sudo_access_with_password "$password" "$prompt"; then
        MOLE_SUDO_ESTABLISHED="false"
        unset password
        return 1
    fi

    unset password

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
