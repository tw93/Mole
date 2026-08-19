#!/usr/bin/env bats

# Tests for the system-cache confirmation in bin/clean.sh.
#
# A cached sudo timestamp authenticates the user; it does not say this run was
# meant to sweep system caches, so an interactive run is asked every time. The
# non-interactive contract from #1084 is unchanged: credentials the caller
# already established are reused for the whole run.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-confirm.XXXXXX")"
    export SANDBOX
    export MOLE_TEST_MODE=1
    export MOLE_TEST_NO_AUTH=1
}

teardown() {
    rm -rf "$SANDBOX"
}

source_clean() {
    cat <<EOF
set -euo pipefail
export HOME="$SANDBOX/home"
mkdir -p "\$HOME"
export MOLE_TEST_MODE=1
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
EOF
}

@test "an interactive run with a cached sudo session is still asked" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
clean_stdin_is_tty() { return 0; }
adopt_sudo_session() { return 0; }
prompt_for_system_clean() { echo "PROMPTED cached=\$1"; SYSTEM_CLEAN=false; }
start_cleanup < /dev/null
echo "SYSTEM_CLEAN=\$SYSTEM_CLEAN"
EOF

    [ "$status" -eq 0 ] || return 1
    # The prompt appears, and it knows the password step is already done.
    [[ "$output" == *"PROMPTED cached=true"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=false"* ]] || return 1
}

@test "an interactive run without a cached session is asked the same way" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
clean_stdin_is_tty() { return 0; }
adopt_sudo_session() { return 1; }
prompt_for_system_clean() { echo "PROMPTED cached=\$1"; SYSTEM_CLEAN=false; }
start_cleanup < /dev/null
echo "SYSTEM_CLEAN=\$SYSTEM_CLEAN"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PROMPTED cached=false"* ]] || return 1
}

@test "the prompt says admin access is already active when it is" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
read_clean_sudo_choice() { echo "SPACE"; }
prompt_for_system_clean true
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"admin access already active"* ]] || return 1
    [[ "$output" != *"need sudo"* ]] || return 1
}

@test "a non-interactive run still reuses an established sudo session (#1084)" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
clean_stdin_is_tty() { return 1; }
adopt_sudo_session() { return 0; }
start_cleanup < /dev/null
echo "SYSTEM_CLEAN=\$SYSTEM_CLEAN"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=true"* ]] || return 1
    [[ "$output" == *"sudo session active"* ]] || return 1
}

@test "a non-interactive run without sudo skips system cleanup" {
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
clean_stdin_is_tty() { return 1; }
adopt_sudo_session() { return 1; }
start_cleanup < /dev/null
echo "SYSTEM_CLEAN=\$SYSTEM_CLEAN"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=false"* ]] || return 1
    [[ "$output" == *"requires sudo"* ]] || return 1
}
