# Shared setup for the bats suites. Each test gets its own HOME; the code under
# test runs in a child bash (it sets -euo pipefail, which must not leak into
# bats itself).

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
    TEST_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mole-test.XXXXXX")"
    export HOME="$TEST_ROOT/home"
    mkdir -p "$HOME" "$TEST_ROOT/bin"
    unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
    export PATH="$TEST_ROOT/bin:$PATH"
    export MOLE_TEST_REPO="$REPO"
}

teardown() {
    [[ -n "${OWNER_PID:-}" ]] && kill "$OWNER_PID" 2> /dev/null || true
    chmod -R u+w "$TEST_ROOT" 2> /dev/null || true
    rm -rf -- "$TEST_ROOT"
}

# Run bash code with Mole's libraries loaded. $1 is one of: core, clean, uninstall, optimize.
mole_run() {
    local what="$1" code="$2" prelude
    case "$what" in
        core) prelude='SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/lib/core/common.sh"' ;;
        clean) prelude='SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/bin/clean.sh"' ;;
        uninstall) prelude='SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/bin/uninstall.sh"' ;;
        optimize) prelude='SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/lib/core/common.sh"; source "$MOLE_TEST_REPO/lib/uninstall/inventory.sh"; source "$MOLE_TEST_REPO/lib/optimize/tasks.sh"' ;;
    esac
    run bash -c "$prelude
$code"
}

# A stand-in for an external command, first on PATH.
fake_command() {
    local name="$1" body="$2"
    printf '#!/bin/bash\n%s\n' "$body" > "$TEST_ROOT/bin/$name"
    chmod +x "$TEST_ROOT/bin/$name"
}

# A fake /proc entry under $1 for code that reads _MOLE_PROC_ROOT:
# fake_proc <root> <pid> <uid> <comm> <exe or -> [argv...]
fake_proc() {
    local root="$1" pid="$2" uid="$3" comm="$4" exe="$5"
    shift 5
    mkdir -p "$root/self" "$root/$pid"
    printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$uid" "$uid" "$uid" "$uid" > "$root/$pid/status"
    printf '%s\n' "$comm" > "$root/$pid/comm"
    [[ "$exe" != - ]] && ln -s "$exe" "$root/$pid/exe"
    if [[ $# -gt 0 ]]; then printf '%s\0' "$@" > "$root/$pid/cmdline"; else : > "$root/$pid/cmdline"; fi
}
