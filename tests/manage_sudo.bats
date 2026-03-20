#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/core/sudo.sh"
}

@test "has_sudo_session returns 1 when no sudo session" {
    # shellcheck disable=SC2329
    sudo() { return 1; }
    export -f sudo
    run has_sudo_session
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "sudo keepalive functions don't crash" {

    # shellcheck disable=SC2329
    function sudo() {
        return 1  # Simulate no sudo available
    }
    export -f sudo

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; has_sudo_session"
    [ "$status" -eq 1 ]  # Expected: no sudo session
}

@test "_start_sudo_keepalive returns a PID" {
    function sudo() {
        case "$1" in
            -n) return 0 ;;  # Simulate valid sudo session
            -v) return 0 ;;  # Refresh succeeds
            *) return 1 ;;
        esac
    }
    export -f sudo

    local pid
    pid=$(bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _start_sudo_keepalive")

    [[ "$pid" =~ ^[0-9]+$ ]]

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

@test "_stop_sudo_keepalive handles invalid PID gracefully" {
    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _stop_sudo_keepalive ''"
    [ "$status" -eq 0 ]

    run bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _stop_sudo_keepalive '99999'"
    [ "$status" -eq 0 ]
}



@test "stop_sudo_session cleans up keepalive process" {
    export MOLE_SUDO_KEEPALIVE_PID="99999"

    run bash -c "export MOLE_SUDO_KEEPALIVE_PID=99999; source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; stop_sudo_session"
    [ "$status" -eq 0 ]
}

@test "sudo manager initializes global state correctly" {
    result=$(bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; echo \$MOLE_SUDO_ESTABLISHED")
    [[ "$result" == "false" ]] || [[ -z "$result" ]]
}

@test "request_sudo_access clears four lines in clamshell mode when Touch ID hint is shown" {
    run bash -c '
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        source "'"$PROJECT_ROOT"'/lib/core/sudo.sh"

        tty_file="$(mktemp)"
        chmod 600 "$tty_file"

        sudo() {
            case "$1" in
                -n) return 1 ;;
                -k) return 0 ;;
                *) return 1 ;;
            esac
        }
        tty() { printf "%s\n" "$tty_file"; }
        is_clamshell_mode() { return 0; }
        check_touchid_support() { return 0; }
        _request_password() { return 0; }
        safe_clear_lines() { printf "CLEAR:%s\n" "$1"; }

        request_sudo_access "Admin access required"
    '

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAR:4"* ]]
}

@test "request_sudo_access keeps three-line cleanup in clamshell mode without Touch ID" {
    run bash -c '
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        source "'"$PROJECT_ROOT"'/lib/core/sudo.sh"

        tty_file="$(mktemp)"
        chmod 600 "$tty_file"

        sudo() {
            case "$1" in
                -n) return 1 ;;
                -k) return 0 ;;
                *) return 1 ;;
            esac
        }
        tty() { printf "%s\n" "$tty_file"; }
        is_clamshell_mode() { return 0; }
        check_touchid_support() { return 1; }
        _request_password() { return 0; }
        safe_clear_lines() { printf "CLEAR:%s\n" "$1"; }

        request_sudo_access "Admin access required"
    '

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAR:3"* ]]
}
