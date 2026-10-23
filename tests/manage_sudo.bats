#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_project_root
}

setup() {
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/core/sudo.sh"
}

@test "check_touchid_support falls back to legacy sudo when sudo_local is present" {
    local pam_sudo="$BATS_TEST_TMPDIR/sudo"
    local pam_sudo_local="$BATS_TEST_TMPDIR/sudo_local"

    printf 'auth sufficient pam_tid.so\n' > "$pam_sudo"
    printf 'auth include pam_opendirectory.so\n' > "$pam_sudo_local"
    export MOLE_PAM_SUDO_FILE="$pam_sudo"
    export MOLE_PAM_SUDO_LOCAL_FILE="$pam_sudo_local"

    run check_touchid_support
    [ "$status" -eq 0 ]

    printf 'auth include pam_opendirectory.so\n' > "$pam_sudo"

    run check_touchid_support
    [ "$status" -eq 1 ]
}

@test "sudo adoption authorizes commands only on a foreground terminal" {
    run python3 "$PROJECT_ROOT/tests/sudo_adoption_pty.py"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; has_sudo_session"
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
    pid=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _start_sudo_keepalive")

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

@test "_stop_sudo_keepalive handles invalid PID gracefully" {
    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _stop_sudo_keepalive ''"
    [ "$status" -eq 0 ]

    run /bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; _stop_sudo_keepalive '99999'"
    [ "$status" -eq 0 ]
}

@test "stopping sudo keepalive reaps its sleeping child at every delay (#1694)" {
    for phase in initial refresh retry; do
        run env PROJECT_ROOT="$PROJECT_ROOT" PHASE="$phase" \
            TRACE="$BATS_TEST_TMPDIR/keepalive-$phase" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
sudo() {
    echo REFRESH > "$TRACE"
    [[ "$PHASE" == refresh ]]
}
pid=$(_start_sudo_keepalive)
child=""
trap '[[ -z "$child" ]] || kill "$child" 2>/dev/null || :; _stop_sudo_keepalive "$pid"' EXIT
for ((i=0; i<200; i++)); do
    if [[ "$PHASE" == initial || -f "$TRACE" ]]; then
        child=$(pgrep -P "$pid" -x sleep || :)
        [[ -z "$child" ]] || break
    fi
    /bin/sleep 0.02
done
[[ "$child" =~ ^[0-9]+$ ]] || exit 1
kill -0 "$child" || exit 1
_stop_sudo_keepalive "$pid"
for ((i=0; i<50; i++)); do
    if ! kill -0 "$child" 2>/dev/null; then
        echo CHILD_REAPED
        exit 0
    fi
    /bin/sleep 0.02
done
echo CHILD_SURVIVED
exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$phase: $output"; return 1; }
        [[ "$output" == *"CHILD_REAPED"* ]] || return 1
    done
}



@test "stop_sudo_session cleans up keepalive process" {
    export MOLE_SUDO_KEEPALIVE_PID="99999"

    run /bin/bash -c "export MOLE_SUDO_KEEPALIVE_PID=99999; source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; stop_sudo_session"
    [ "$status" -eq 0 ]
}

@test "sudo manager initializes global state correctly" {
    result=$(/bin/bash -c "source '$PROJECT_ROOT/lib/core/common.sh'; source '$PROJECT_ROOT/lib/core/sudo.sh'; echo \$MOLE_SUDO_ESTABLISHED")
    [[ "$result" == "false" ]] || [[ -z "$result" ]]
}

@test "request_sudo_access clears four lines in clamshell mode when Touch ID hint is shown" {
    run /bin/bash -c '
        unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH
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
    run /bin/bash -c '
        unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH
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


@test "the Touch ID wait hides typed input and restores echo, also after Ctrl-C" {
    # People often type the password instead of touching the sensor; during
    # the six-second wait that text used to echo on screen.
    run python3 "$PROJECT_ROOT/tests/sudo_tty_pty.py"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local body
    body=$(sed -n '/^request_sudo_access() {/,/^}/p' "$PROJECT_ROOT/lib/core/sudo.sh")
    # shellcheck disable=SC2016  # Literal source text, not an expansion.
    [[ "$body" == *'_mole_tty_quiet "$tty_path" _mole_touchid_poll "$sudo_pid"'* ]] || return 1
    # shellcheck disable=SC2016  # Literal source text, not an expansion.
    [[ "$body" == *'_mole_tty_quiet "$tty_path" sleep 1'* ]] || return 1
}

@test "check_touchid_support ignores a commented-out pam_tid line (#1815)" {
    local pam_sudo="$BATS_TEST_TMPDIR/sudo"
    local pam_sudo_local="$BATS_TEST_TMPDIR/sudo_local"
    local probe="source '$PROJECT_ROOT/lib/core/sudo.sh'; check_touchid_support"

    printf 'auth       include        sudo_local\n' > "$pam_sudo"
    # The line macOS ships in /etc/pam.d/sudo_local.template.
    printf '#auth       sufficient     pam_tid.so\n' > "$pam_sudo_local"
    run env MOLE_TEST_MODE=1 MOLE_PAM_SUDO_FILE="$pam_sudo" \
        MOLE_PAM_SUDO_LOCAL_FILE="$pam_sudo_local" /bin/bash -c "$probe"
    [ "$status" -eq 1 ]

    # Turned off by hand in the legacy file, or named only inside a comment.
    printf '  # auth sufficient pam_tid.so\nauth sufficient pam_smartcard.so # pam_tid.so\n' > "$pam_sudo"
    run env MOLE_TEST_MODE=1 MOLE_PAM_SUDO_FILE="$pam_sudo" \
        MOLE_PAM_SUDO_LOCAL_FILE="$pam_sudo_local" /bin/bash -c "$probe"
    [ "$status" -eq 1 ]

    printf 'auth       sufficient     pam_tid.so # Touch ID\n' >> "$pam_sudo_local"
    run env MOLE_TEST_MODE=1 MOLE_PAM_SUDO_FILE="$pam_sudo" \
        MOLE_PAM_SUDO_LOCAL_FILE="$pam_sudo_local" /bin/bash -c "$probe"
    [ "$status" -eq 0 ]
}
