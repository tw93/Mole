#!/usr/bin/env bats

# Tests for `mo clean --trash` (MOLE_CLEAN_TRASH=1).
#
# Cache cleanup deletes permanently by default; trash mode swaps the final
# action in safe_remove / safe_sudo_remove for a Trash move. The contract under
# test is that the swap happens everywhere and that a failed move is never
# downgraded to a permanent delete. MOLE_TEST_TRASH_DIR keeps Finder and
# AppleScript out of the run.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-trash.XXXXXX")"
    export SANDBOX
    export MOLE_TEST_TRASH_DIR="$SANDBOX/Trash"
    export MOLE_TEST_NO_AUTH=1
    unset MOLE_CLEAN_TRASH
    unset MOLE_DRY_RUN
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat <<EOF
set -euo pipefail
export HOME="$SANDBOX/home"
mkdir -p "\$HOME"
export MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR"
export MOLE_TEST_NO_AUTH=1
export MOLE_CURRENT_COMMAND=clean
source "$PROJECT_ROOT/lib/core/common.sh"
EOF
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
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
EOF
}

@test "safe_remove moves the target to the Trash when MOLE_CLEAN_TRASH=1" {
    local victim="$SANDBOX/cache_dir"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_CLEAN_TRASH=1
safe_remove "$victim"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$victim" ]] || return 1
    [[ -n "$(ls -A "$MOLE_TEST_TRASH_DIR" 2> /dev/null || true)" ]] || return 1
}

@test "safe_remove deletes permanently by default and leaves the Trash empty" {
    local victim="$SANDBOX/cache_default"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
safe_remove "$victim"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$victim" ]] || return 1
    [[ -z "$(ls -A "$MOLE_TEST_TRASH_DIR" 2> /dev/null || true)" ]] || return 1
}

@test "safe_remove refuses a permanent delete when the Trash is unavailable" {
    local victim="$SANDBOX/cache_no_trash"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    # With the harness Trash cleared and MOLE_TEST_NO_AUTH=1 every Trash
    # route fails. The target must survive rather than fall back to rm -rf.
    run /bin/bash --noprofile --norc <<EOF
set -euo pipefail
unset MOLE_TEST_TRASH_DIR
export HOME="$SANDBOX/home"
mkdir -p "\$HOME"
export MOLE_TEST_NO_AUTH=1
export MOLE_CURRENT_COMMAND=clean
source "$PROJECT_ROOT/lib/core/common.sh"
export MOLE_CLEAN_TRASH=1
safe_remove "$victim"
EOF

    [ "$status" -ne 0 ] || return 1
    [[ -d "$victim" ]] || return 1
    [[ -f "$victim/data.txt" ]] || return 1
}

@test "trash mode records TRASHED rather than REMOVED in the operations log" {
    local victim="$SANDBOX/cache_logged"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_CLEAN_TRASH=1
safe_remove "$victim"
EOF

    [ "$status" -eq 0 ] || return 1

    local log="$SANDBOX/home/Library/Logs/mole/operations.log"
    [[ -f "$log" ]] || return 1
    grep -q "TRASHED $victim" "$log" || return 1
    ! grep -q "REMOVED $victim" "$log" || return 1
}

@test "dry-run in trash mode touches nothing" {
    local victim="$SANDBOX/cache_dry"
    mkdir -p "$victim"

    run /bin/bash --noprofile --norc <<EOF
$(prelude)
export MOLE_CLEAN_TRASH=1
export MOLE_DRY_RUN=1
safe_remove "$victim"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ -d "$victim" ]] || return 1
    [[ -z "$(ls -A "$MOLE_TEST_TRASH_DIR" 2> /dev/null || true)" ]] || return 1
}

@test "safe_clean routes through the Trash in trash mode" {
    local victim="$SANDBOX/pipeline_cache"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
export MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR"
export MOLE_CLEAN_TRASH=1
start_section "Developer tools"
safe_clean "$victim" "Test cache"
end_section
EOF

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$victim" ]] || return 1
    [[ -n "$(ls -A "$MOLE_TEST_TRASH_DIR" 2> /dev/null || true)" ]] || return 1
}

@test "safe_clean leaves items in place when the Trash is unavailable" {
    local victim="$SANDBOX/pipeline_no_trash"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    # Clear the harness Trash so every Trash route fails; `run` would
    # otherwise inherit the directory setup() exported.
    run /bin/bash --noprofile --norc <<EOF
$(source_clean)
unset MOLE_TEST_TRASH_DIR
export MOLE_CLEAN_TRASH=1
start_section "Developer tools"
safe_clean "$victim" "Test cache"
end_section
echo "failures=\${MOLE_CLEAN_TRASH_FAILURES:-0}"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ -f "$victim/data.txt" ]] || return 1
    # The summary reads off this counter, so a silent failure would look clean.
    [[ "$output" == *"failures=1"* ]] || return 1
}
