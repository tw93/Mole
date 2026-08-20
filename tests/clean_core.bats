#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-home.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    # Two tests below run the real pipeline (MOLE_TEST_MODE=0), which otherwise
    # scans the host: du -sk over every mounted CoreSimulator runtime volume
    # plus a full lsregister -dump. That cost ~32s per test and scaled with
    # whatever Xcode and LaunchServices happened to hold, which made this file
    # the critical path of the whole CI suite. Neither scan feeds an assertion
    # here, so point both at nothing. The paths stay absent: setup() wipes
    # $HOME between tests.
    MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$HOME/absent-sim-runtime-volumes"
    MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/absent-sim-runtime-cryptex"
    MOLE_LSREGISTER_PATH=""
    export MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT
    export MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT
    export MOLE_LSREGISTER_PATH

    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    export TERM="xterm-256color"
    rm -rf "${HOME:?}"/*
    rm -rf "$HOME/Library" "$HOME/.config"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole"
    unset TEST_MOCK_BIN MOCK_TOOLCHAIN_BIN
}

set_mock_sudo_cached() {
    TEST_MOCK_BIN="$HOME/bin"
    mkdir -p "$TEST_MOCK_BIN"
    cat > "$TEST_MOCK_BIN/sudo" << 'MOCK'
#!/bin/bash
# Shim: sudo -n true succeeds, all other sudo calls are no-ops.
if [[ "$1" == "-n" && "$2" == "true" ]]; then exit 0; fi
if [[ "$1" == "test" ]]; then exit 1; fi
if [[ "$1" == "find" ]]; then exit 0; fi
exit 0
MOCK
    chmod +x "$TEST_MOCK_BIN/sudo"
}

set_mock_sudo_uncached() {
    local mock_home="${1:-$HOME}"
    TEST_MOCK_BIN="$mock_home/bin"
    mkdir -p "$TEST_MOCK_BIN"
    cat > "$TEST_MOCK_BIN/sudo" << 'MOCK'
#!/bin/bash
# Shim: sudo -n always fails (no cached credentials).
exit 1
MOCK
    chmod +x "$TEST_MOCK_BIN/sudo"
}

run_clean_dry_run() {
    local test_path="$PATH"
    if [[ -n "${TEST_MOCK_BIN:-}" ]]; then
        test_path="$TEST_MOCK_BIN:$PATH"
    fi

    run env HOME="$HOME" MOLE_TEST_MODE=1 PATH="$test_path" \
        "$PROJECT_ROOT/mole" clean --dry-run
}

# Stub the two host toolchains the real pipeline shells out to, so what these
# tests measure does not depend on the machine's Homebrew or Xcode. brew is
# required to be mocked by project policy: no verification run may reach a real
# package manager. xcrun follows for the same reason, and returning non-zero is
# the CLT-only shape clean already handles. Neither tool feeds an assertion.
#
# These stubs are correctness, not speed. They were first added expecting a cold
# runner's brew and CoreSimulator startup to be the bulk of the ~30s each of
# these tests costs on CI; a timed dry-run on a runner disproved that. The whole
# pipeline takes ~10s there with these seams applied, and the rest is contention
# from running the suite at more jobs than the runner has cores.
set_mock_host_toolchains() {
    local mock_home="${1:-$HOME}"
    MOCK_TOOLCHAIN_BIN="$mock_home/toolchain-bin"
    mkdir -p "$MOCK_TOOLCHAIN_BIN"

    cat > "$MOCK_TOOLCHAIN_BIN/brew" << 'MOCK'
#!/bin/bash
# Shim: report an empty Homebrew so cleanup has nothing to preview or remove.
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK

    cat > "$MOCK_TOOLCHAIN_BIN/xcrun" << 'MOCK'
#!/bin/bash
# Shim: no simulator toolchain, which is the CLT-only shape clean handles.
exit 1
MOCK

    chmod +x "$MOCK_TOOLCHAIN_BIN/brew" "$MOCK_TOOLCHAIN_BIN/xcrun"
}

@test "safe_clean item count reflects cleaned items, not raw target count" {
    local base="$HOME/safe_clean_count"
    mkdir -p "$base"
    printf 'xxxx' > "$base/a"
    printf 'xxxx' > "$base/b"
    printf 'xxxx' > "$base/keep"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
# One of the three targets is whitelisted, so only two are actually cleaned.
is_path_whitelisted() { [[ "\$1" == "$base/keep" ]]; }
safe_remove() { /bin/rm -rf "\$1"; return 0; }
safe_clean "$base/a" "$base/b" "$base/keep" "Test cache"
EOF

    [ "$status" -eq 0 ] || return 1
    # Two items were removed, so the detail column must say "2 items", not "3".
    # Every assertion ends with || return 1: bare [[ ]] failures mid-test can be
    # swallowed and let the test pass vacuously (same shape as #886).
    [[ "$output" == *"2 items"* ]] || return 1
    [[ "$output" != *"3 items"* ]] || return 1
    [[ ! -e "$base/a" ]] || return 1
    [[ ! -e "$base/b" ]] || return 1
    [[ -e "$base/keep" ]] || return 1

    rm -rf "$base"
}

@test "safe_clean_guarded rechecks after parallel size probes before deletion" {
    local base="$HOME/safe_clean_guarded"
    mkdir -p "$base/a" "$base/b" "$base/c" "$base/d"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() { touch "$base/process-started"; echo 1; }
delete_guard() { [[ ! -e "$base/process-started" ]]; }
safe_remove() { echo "UNEXPECTED_REMOVE:\$1"; /bin/rm -rf "\$1"; }

rc=0
safe_clean_guarded delete_guard \
    "$base/a" "$base/b" "$base/c" "$base/d" \
    "Guarded cache" || rc=\$?
[[ \$rc -eq 75 ]] || { echo "WRONG_RC:\$rc"; exit 1; }
for path in "$base/a" "$base/b" "$base/c" "$base/d"; do
    [[ -d "\$path" ]] || { echo "WRONG: removed \$path"; exit 1; }
done
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "safe_clean_guarded dry-run consults the guard before registering preview targets" {
    local base="$HOME/safe_clean_guarded_dry"
    mkdir -p "$base/a" "$base/b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
delete_guard() { return 1; }
register_dry_run_cleanup_target() { echo "UNEXPECTED_REGISTER:\$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:\$1"; }

# A guard that refuses must stop the preview the same way it stops the real
# run, before any dry-run target is registered into the summary ledger.
rc=0
safe_clean_guarded delete_guard \
    "$base/a" "$base/b" \
    "Guarded cache" || rc=\$?
[[ \$rc -eq 75 ]] || { echo "WRONG_RC:\$rc"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_REGISTER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"would clean"* ]]
}

@test "safe_clean_guarded dry-run stops at the first target-specific denial" {
    local base="$HOME/safe_clean_guarded_dry_targets"
    mkdir -p "$base/a" "$base/b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() { echo 1; }
delete_guard() {
    echo "GUARD:\$1"
    [[ "\$1" == "$base/a" ]]
}
register_dry_run_cleanup_target() { echo "REGISTER:\$1"; return 0; }

rc=0
safe_clean_guarded delete_guard \
    "$base/a" "$base/b" \
    "Target guard preview" || rc=\$?
printf 'RC=%s FILES=%s\n' "\$rc" "\$files_cleaned"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"GUARD:$base/a"* ]] || return 1
    [[ "$output" == *"GUARD:$base/b"* ]] || return 1
    [[ "$output" == *"REGISTER:$base/a"* ]] || return 1
    [[ "$output" != *"REGISTER:$base/b"* ]] || return 1
    [[ "$output" == *"RC=75 FILES=1"* ]] || return 1
    [[ "$output" != *"2 items"* ]]
}

@test "safe_clean_guarded filters ineligible targets before the dry-run guard" {
    local base="$HOME/safe_clean_guarded_filtered"
    mkdir -p "$base/protected" "$base/whitelisted"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
should_protect_path() { [[ "\$1" == "$base/protected" ]]; }
is_path_whitelisted() { [[ "\$1" == "$base/whitelisted" ]]; }
holds_compiled_model_cache() { return 1; }
delete_guard() { echo "UNEXPECTED_GUARD:\$1"; return 1; }
register_dry_run_cleanup_target() { echo "UNEXPECTED_REGISTER:\$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:\$1"; }

rc=0
safe_clean_guarded delete_guard \
    "$base/missing" "$base/protected" "$base/whitelisted" \
    "Filtered guarded cache" || rc=\$?
[[ \$rc -eq 0 ]] || { echo "WRONG_RC:\$rc"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_GUARD"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REGISTER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "safe_clean propagates an interrupted parallel size worker before deletion" {
    local base="$HOME/safe_clean_parallel_interrupt"
    mkdir -p "$base/a" "$base/b" "$base/c" "$base/d"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() {
    [[ "\$1" == "$base/b" ]] && return 130
    echo 1
}
safe_remove() { echo "UNEXPECTED_REMOVE:\$1"; /bin/rm -rf "\$1"; }

rc=0
safe_clean "$base/a" "$base/b" "$base/c" "$base/d" \
    "Interrupted size batch" || rc=\$?
[[ \$rc -eq 130 ]] || { echo "WRONG_RC:\$rc"; exit 1; }
for path in "$base/a" "$base/b" "$base/c" "$base/d"; do
    [[ -d "\$path" ]] || { echo "WRONG: removed \$path"; exit 1; }
done
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "safe_clean stops a multi-target batch when deletion is interrupted" {
    local base="$HOME/safe_clean_delete_interrupt"
    mkdir -p "$base/a" "$base/b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() { echo 1; }
safe_remove() {
    echo "REMOVE:\$1"
    [[ "\$1" == "$base/a" ]] && return 130
    /bin/rm -rf "\$1"
}

rc=0
safe_clean "$base/a" "$base/b" "Interrupted delete batch" || rc=\$?
[[ \$rc -eq 130 ]] || { echo "WRONG_RC:\$rc"; exit 1; }
[[ -d "$base/a" && -d "$base/b" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"REMOVE:$base/a"* ]] || return 1
    [[ "$output" != *"REMOVE:$base/b"* ]]
}

@test "safe_clean keeps cancellation sticky across best-effort callers" {
    local base="$HOME/safe_clean_sticky_interrupt"
    mkdir -p "$base/a" "$base/b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() { echo 1; }
safe_remove() {
    echo "REMOVE:\$1"
    return 130
}

# Simulate an older best-effort cleanup family swallowing the first status.
safe_clean "$base/a" "Interrupted first cleanup" || true
safe_remove() {
    echo "UNEXPECTED_REMOVE:\$1"
    /bin/rm -rf "\$1"
}
rc=0
safe_clean "$base/b" "Later cleanup" || rc=\$?
[[ \$rc -eq 130 ]] || { echo "WRONG_RC:\$rc"; exit 1; }
[[ -d "$base/a" && -d "$base/b" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"REMOVE:$base/a"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "safe_clean treats a real directory size timeout as size-unknown and keeps cleaning" {
    local base="$HOME/safe-clean-real-timeout"
    mkdir -p "$base/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
unset MOLE_CLEAN_SIZING_TIMEOUTS
run_with_timeout() { return 124; }
safe_remove() { echo "REMOVE:\$1"; /bin/rm -rf "\$1"; }

rc=0
safe_clean "$base/candidate" "Timed out directory" || rc=\$?
printf 'RC=%s CANCEL=%s TIMEOUTS=%s\n' "\$rc" "\${MOLE_CLEAN_CANCEL_STATUS:-0}" "\${MOLE_CLEAN_SIZING_TIMEOUTS:-0}"
[[ ! -e "$base/candidate" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=0 CANCEL=0 TIMEOUTS=1"* ]] || return 1
    [[ "$output" == *"REMOVE:$base/candidate"* ]] || return 1
}

@test "safe_clean keeps cleaning when a parallel size worker times out (#1374)" {
    local base="$HOME/safe_clean_parallel_timeout"
    mkdir -p "$base/a" "$base/b" "$base/c" "$base/d" "$base/e"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
files_cleaned=0
total_size_cleaned=0
total_items=0
unset MOLE_CLEAN_SIZING_TIMEOUTS
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() {
    [[ "\$1" == "$base/c" ]] && return 124
    echo 1
}
safe_remove() { echo "REMOVE:\$1"; /bin/rm -rf "\$1"; }

rc=0
safe_clean "$base/a" "$base/b" "$base/c" "$base/d" "$base/e" \
    "Timed out size batch" || rc=\$?
printf 'RC=%s CANCEL=%s TIMEOUTS=%s\n' "\$rc" "\${MOLE_CLEAN_CANCEL_STATUS:-0}" "\${MOLE_CLEAN_SIZING_TIMEOUTS:-0}"
for path in "$base/a" "$base/b" "$base/c" "$base/d" "$base/e"; do
    if [[ -d "\$path" ]]; then
        echo "WRONG: kept \$path"
        exit 1
    fi
done
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=0 CANCEL=0 TIMEOUTS=1"* ]] || return 1
    [[ "$output" == *"REMOVE:$base/c"* ]] || return 1
}

@test "safe_clean keeps cleaning when a removal times out (#1384)" {
    local base="$HOME/safe_clean_removal_timeout"
    mkdir -p "$base/a" "$base/b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
export MO_NO_OPLOG=1
files_cleaned=0
total_size_cleaned=0
total_items=0
unset MOLE_CLEAN_SIZING_TIMEOUTS MOLE_CLEAN_REMOVAL_TIMEOUTS
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() { echo 1; }
run_with_timeout() {
    [[ "\${2:-}" == "rm" ]] && return 124
    "\$@"
}

rc=0
safe_clean "$base/a" "$base/b" "Removal timeout batch" || rc=\$?
printf 'RC=%s CANCEL=%s REMOVAL=%s\n' "\$rc" "\${MOLE_CLEAN_CANCEL_STATUS:-0}" "\${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0}"
[[ -d "$base/a" && -d "$base/b" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=0 CANCEL=0 REMOVAL=2"* ]] || return 1
}

@test "safe_clean keeps cleaning when a parallel removal times out (#1384)" {
    local base="$HOME/safe_clean_parallel_removal_timeout"
    mkdir -p "$base/a" "$base/b" "$base/c" "$base/d" "$base/e"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
export MO_NO_OPLOG=1
files_cleaned=0
total_size_cleaned=0
total_items=0
unset MOLE_CLEAN_SIZING_TIMEOUTS MOLE_CLEAN_REMOVAL_TIMEOUTS
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() { echo 1; }
run_with_timeout() {
    [[ "\${2:-}" == "rm" ]] && return 124
    "\$@"
}

rc=0
safe_clean "$base/a" "$base/b" "$base/c" "$base/d" "$base/e" \
    "Parallel removal timeout batch" || rc=\$?
printf 'RC=%s CANCEL=%s REMOVAL=%s\n' "\$rc" "\${MOLE_CLEAN_CANCEL_STATUS:-0}" "\${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0}"
for path in "$base/a" "$base/b" "$base/c" "$base/d" "$base/e"; do
    [[ -d "\$path" ]] || echo "WRONG: missing \$path"
done
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=0 CANCEL=0 REMOVAL=5"* ]] || return 1
    [[ "$output" != *"WRONG"* ]] || return 1
}

@test "safe_clean still cancels on an interrupted removal (>=128)" {
    local base="$HOME/safe_clean_removal_interrupt"
    mkdir -p "$base/a" "$base/b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        /bin/bash --noprofile --norc << EOF
set -euo pipefail
source "\$PROJECT_ROOT/lib/core/common.sh"
source "\$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
export MO_NO_OPLOG=1
files_cleaned=0
total_size_cleaned=0
total_items=0
unset MOLE_CLEAN_SIZING_TIMEOUTS MOLE_CLEAN_REMOVAL_TIMEOUTS
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
get_cleanup_path_size_kb() { echo 1; }
run_with_timeout() {
    [[ "\${2:-}" == "rm" ]] && return 130
    "\$@"
}

rc=0
safe_clean "$base/a" "$base/b" "Interrupted removal batch" || rc=\$?
printf 'RC=%s CANCEL=%s REMOVAL=%s\n' "\$rc" "\${MOLE_CLEAN_CANCEL_STATUS:-0}" "\${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0}"
[[ -d "$base/a" && -d "$base/b" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=130 CANCEL=130 REMOVAL=0"* ]] || return 1
}

@test "mo clean --dry-run skips system cleanup in non-interactive mode" {
    set_mock_sudo_uncached
    run_clean_dry_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry Run Mode"* ]] || return 1
    [[ "$output" == *"sudo -v && mo clean --dry-run"* ]]
    [[ "$output" != *"system preview included"* ]]
}

@test "MOLE_DRY_RUN enables the complete clean preview without deleting Trash" {
    mkdir -p "$HOME/.Trash"
    printf 'keep\n' > "$HOME/.Trash/env-dry-run-sentinel"

    run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_DRY_RUN=1 \
        "$PROJECT_ROOT/mole" clean

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Dry Run Mode"* ]] || return 1
    [[ -f "$HOME/.Trash/env-dry-run-sentinel" ]]
}

@test "mo clean --dry-run does not probe sudo in test mode" {
    set_mock_sudo_cached
    cat > "$TEST_MOCK_BIN/sudo" << 'MOCK'
#!/bin/bash
echo "sudo should not be called" >&2
exit 99
MOCK
    chmod +x "$TEST_MOCK_BIN/sudo"

    run_clean_dry_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo -v && mo clean --dry-run"* ]]
    [[ "$output" != *"sudo should not be called"* ]]
}

@test "mo clean rejects removed cleanup selection flags" {
    local removed_flag
    for removed_flag in "--select" "--categories" "--exclude"; do
        run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean "$removed_flag"
        [ "$status" -eq 1 ]
        [[ "$output" == *"was removed in this release"* ]] || return 1
        [[ "$output" == *"mo clean --dry-run"* ]] || return 1
    done
}

@test "mo clean --dry-run shows hint when sudo is not cached" {
    set_mock_sudo_uncached
    run_clean_dry_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo -v"* ]] || return 1
    [[ "$output" == *"full preview"* ]]
}

@test "mo clean adopts cached sudo before system cleanup (#1084)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
TRACE="$HOME/sudo-adopt.log"
> "$TRACE"

source "$PROJECT_ROOT/bin/clean.sh"

DRY_RUN=false
EXTERNAL_VOLUME_TARGET=""

sudo() {
    printf 'sudo %s\n' "$*" >> "$TRACE"
    [[ "${1:-}" == "-n" && "${2:-}" == "-v" ]]
}
_start_sudo_keepalive() {
    printf 'keepalive\n' >> "$TRACE"
    echo "keepalive-pid"
}
_stop_sudo_keepalive() { :; }

start_cleanup
cat "$TRACE"
printf 'SYSTEM_CLEAN=%s\n' "$SYSTEM_CLEAN"
printf 'MOLE_SUDO_ESTABLISHED=%s\n' "$MOLE_SUDO_ESTABLISHED"
printf 'MOLE_SUDO_KEEPALIVE_PID=%s\n' "$MOLE_SUDO_KEEPALIVE_PID"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo -n -v"* ]] || return 1
    [[ "$output" == *"keepalive"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=true"* ]] || return 1
    [[ "$output" == *"MOLE_SUDO_ESTABLISHED=true"* ]] || return 1
    [[ "$output" == *"MOLE_SUDO_KEEPALIVE_PID=keepalive-pid"* ]]
}

@test "clean main restores the terminal and exits with an interrupted cleanup status" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

start_cleanup() { :; }
hide_cursor() { printf 'HIDE\n'; }
perform_cleanup() { return 130; }
show_cursor() { printf 'SHOW\n'; }

main
SCRIPT

    [ "$status" -eq 130 ]
    [[ "$output" == *"HIDE"* ]] || return 1
    [[ "$output" == *"SHOW"* ]]
}

@test "mo clean sudo prompt preserves a directly typed password (#1059)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

ensure_sudo_session() {
    echo "ENSURE_PLAIN"
    return 0
}
ensure_sudo_session_with_password() {
    echo "ENSURE_PASSWORD=$1"
    [[ "$1" == "secret" ]]
}
drain_pending_input() { :; }
# A user who expects a password prompt may start typing immediately. The first
# printable key and the rest of the line must reach authentication together.
read_key() {
    echo "CHAR:s"
}
read_clean_sudo_password_remainder() {
    printf -v "$1" '%s' "ecret"
}

prompt_for_system_clean
printf '\nSYSTEM_CLEAN=%s\n' "$SYSTEM_CLEAN"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"continue"* ]] || return 1
    [[ "$output" != *"Enter"*"password"* ]] || return 1
    [[ "$output" == *"ENSURE_PASSWORD=secret"* ]] || return 1
    [[ "$output" != *"ENSURE_PLAIN"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=true"* ]] || return 1
    [[ "$output" != *"Skipped"* ]]
}

@test "mo clean sudo prompt still skips on explicit Space (#1059)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

ensure_sudo_session() {
    echo "ENSURE_SUDO"
    return 0
}
drain_pending_input() { :; }
read_key() {
    echo "SPACE"
}

prompt_for_system_clean
printf '\nSYSTEM_CLEAN=%s\n' "$SYSTEM_CLEAN"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped"* ]] || return 1
    [[ "$output" != *"ENSURE_SUDO"* ]] || return 1
    [[ "$output" == *"SYSTEM_CLEAN=false"* ]]
}

@test "cloud and office timeout path uses helper function instead of bash -c" {
    run /bin/bash -c "grep -Eq 'run_with_shell_timeout 300 run_cloud_and_office_cleanup' '$PROJECT_ROOT/bin/clean.sh'"
    [ "$status" -eq 0 ]

    run /bin/bash -c "! grep -Eq 'run_with_timeout 300[[:space:]]+bash[[:space:]]+-c' '$PROJECT_ROOT/bin/clean.sh'"
    [ "$status" -eq 0 ]
}

@test "mo clean summary separates tracked cleanup from free space change" {
    local mock_bin="$HOME/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/df" << 'MOCK'
#!/bin/bash
count_file="${MOLE_DF_COUNT:?}"
count=0
if [[ -f "$count_file" ]]; then
    count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

available=73400320
if [[ "$count" -ge 2 ]]; then
    available=74400320
fi

printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk1 200000000 126599680 %s 64%% /\n' "$available"
MOCK
    chmod +x "$mock_bin/df"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$mock_bin:$PATH" MOLE_DF_COUNT="$HOME/df.count" MOLE_TEST_MODE=0 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

DRY_RUN=false
SYSTEM_CLEAN=false
EXTERNAL_VOLUME_TARGET=""
WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()

check_tcc_permissions() { :; }
start_section() { :; }
end_section() { :; }
log_operation_session_end() { :; }
run_with_shell_timeout() { shift; "$@"; }

clean_user_essentials() {
    total_size_cleaned=$((total_size_cleaned + 1000000))
    files_cleaned=$((files_cleaned + 1))
    total_items=$((total_items + 1))
}
clean_finder_metadata() { :; }
clean_app_caches() { :; }
clean_browsers() { :; }
run_cloud_and_office_cleanup() { :; }
clean_developer_tools() { :; }
clean_user_gui_applications() { :; }
clean_virtualization_tools() { :; }
clean_application_support_logs() { :; }
clean_orphaned_app_data() { :; }
clean_orphaned_system_services() { :; }
clean_orphaned_container_stubs() { :; }
show_user_launch_agent_hint_notice() { :; }
clean_apple_silicon_caches() { :; }
clean_cached_device_firmware() { :; }
clean_time_machine_failed_backups() { :; }
check_large_file_candidates() { :; }
show_project_artifact_hint_notice() { :; }

perform_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Free space: 75.16GB"* ]] || return 1
    [[ "$output" == *"Tracked cleanup:"* ]] || return 1
    [[ "$output" == *"1.02GB"* ]] || return 1
    [[ "$output" == *"Free space: 76.19GB (+1.02GB)"* ]] || return 1
    [[ "$output" != *"Space freed:"* ]] || return 1
    [ "$(cat "$HOME/df.count")" = "2" ]
}

@test "mo clean --dry-run survives an unwritable TMPDIR" {
    local blocked_tmp="$HOME/blocked-tmp"
    mkdir -p "$blocked_tmp"
    chmod 500 "$blocked_tmp"

    set_mock_sudo_uncached
    local test_path="$PATH"
    if [[ -n "${TEST_MOCK_BIN:-}" ]]; then
        test_path="$TEST_MOCK_BIN:$PATH"
    fi

    run env HOME="$HOME" TMPDIR="$blocked_tmp" MOLE_TEST_MODE=1 PATH="$test_path" \
        "$PROJECT_ROOT/mole" clean --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" != *"mktemp:"* ]] || return 1
    [[ "$output" != *"Failed to create temporary file"* ]] || return 1
    [ -d "$HOME/.cache/mole/tmp" ]
}

@test "mo clean --dry-run reports user cache without deleting it" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    echo "cache data" > "$HOME/Library/Caches/TestApp/cache.tmp"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"User app cache"* ]] || return 1
    [[ "$output" == *"Potential space"* ]] || return 1
    [ -f "$HOME/Library/Caches/TestApp/cache.tmp" ]
}

@test "mo clean --dry-run reports stale login item without deleting it" {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.example.stale.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.stale</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Missing.app/Contents/MacOS/Missing</string>
    </array>
</dict>
</plist>
PLIST

    # MOLE_TEST_MODE=1 short-circuits clean into a stub that never reaches
    # the App leftovers section, so the report assertion needs the real
    # sections to run. Dry-run keeps this side-effect free.
    set_mock_host_toolchains
    run env HOME="$HOME" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 \
        PATH="$MOCK_TOOLCHAIN_BIN:$PATH" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stale login item · ~/Library/LaunchAgents/com.example.stale.plist"* ]] || return 1
    [[ "$output" == *"review before removing"* ]] || return 1
    [ -f "$HOME/Library/LaunchAgents/com.example.stale.plist" ]
}

@test "mo clean --dry-run does not export duplicate targets across sections" {
    mkdir -p "$HOME/Library/Application Support/Code/CachedData"
    echo "cache" > "$HOME/Library/Application Support/Code/CachedData/data.bin"

    set_mock_host_toolchains
    run env HOME="$HOME" MOLE_TEST_MODE=0 \
        PATH="$MOCK_TOOLCHAIN_BIN:$PATH" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]

    run grep -c "Application Support/Code/CachedData" "$HOME/.config/mole/clean-list.txt"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "mo clean --dry-run keeps container totals and preview paths consistent (#1282)" {
    # This assertion depends on an exact total. Give it a private HOME so
    # hidden directories left by earlier cases cannot add cleanup candidates.
    local test_home
    test_home="$(mktemp -d "${BATS_TEST_TMPDIR}/clean-1282-home.XXXXXX")"
    mkdir -p "$test_home/.config/mole"

    local explicit_cache="$test_home/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches"
    local generic_cache="$test_home/Library/Containers/com.example.generic/Data/Library/Caches"
    local compiled_cache="$generic_cache/com.apple.e5rt.e5bundlecache"
    local whitelisted_cache="$test_home/Library/Containers/com.example.whitelisted/Data/Library/Caches"
    local protected_cache="$test_home/Library/Containers/com.apple.Safari/Data/Library/Caches"
    mkdir -p "$explicit_cache" "$generic_cache" "$compiled_cache" "$whitelisted_cache" "$protected_cache"
    dd if=/dev/zero of="$explicit_cache/explicit.bin" bs=1024 count=1024 2> /dev/null
    dd if=/dev/zero of="$generic_cache/generic.bin" bs=1024 count=1024 2> /dev/null
    dd if=/dev/zero of="$compiled_cache/model.bin" bs=1024 count=1024 2> /dev/null
    dd if=/dev/zero of="$whitelisted_cache/keep.bin" bs=1024 count=1024 2> /dev/null
    dd if=/dev/zero of="$protected_cache/protected.bin" bs=1024 count=1024 2> /dev/null
    printf '%s\n' "$whitelisted_cache/keep.bin" > "$test_home/.config/mole/whitelist"
    set_mock_sudo_uncached "$test_home"
    set_mock_host_toolchains "$test_home"
    run env HOME="$test_home" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 \
        PATH="$TEST_MOCK_BIN:$MOCK_TOOLCHAIN_BIN:$PATH" \
        "$PROJECT_ROOT/mole" clean --dry-run

    [ "$status" -eq 0 ] || return 1
    local preview="$test_home/.config/mole/clean-list.txt"
    [[ -f "$preview" ]] || return 1
    [[ "$(grep -cF "$explicit_cache/explicit.bin" "$preview")" -eq 1 ]] || return 1
    [[ "$(grep -cF "$generic_cache/generic.bin" "$preview")" -eq 1 ]] || return 1
    [[ "$(grep -cF "$compiled_cache/model.bin" "$preview")" -eq 0 ]] || return 1
    [[ "$(grep -cF "$whitelisted_cache/keep.bin" "$preview")" -eq 0 ]] || return 1
    [[ "$(grep -cF "$protected_cache/protected.bin" "$preview")" -eq 0 ]] || return 1
    local preview_total preview_items preview_categories
    preview_total=$(sed -n 's/^# Potential cleanup: //p' "$preview")
    preview_items=$(sed -n 's/^# Items: //p' "$preview")
    preview_categories=$(sed -n 's/^# Categories: //p' "$preview")
    [[ -n "$preview_total" && "$preview_items" =~ ^[0-9]+$ && "$preview_categories" =~ ^[0-9]+$ ]] || return 1
    [[ "$output" != *"Category total"* ]] || return 1
    printf '%s\n' "$output" | grep -F "Potential space:" |
        grep -F "Items: $preview_items" |
        grep -F "Categories: $preview_categories" |
        grep -qF "$preview_total" || return 1
}

@test "dry-run ledger keeps shell-timeout child candidates and unknown sizes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

DRY_RUN=true
CLEAN_PREVIEW_FINAL_FILE="$HOME/ledger-preview.txt"
prepare_clean_preview_file
CURRENT_SECTION="Cloud & Office"
candidate="$HOME/Library/Application Support/Cloud/cache.bin"
mkdir -p "$(dirname "$candidate")"
touch "$candidate"

record_timeout_candidate() {
    record_dry_run_cleanup_target "$candidate" 0 1 false
}
run_with_shell_timeout 5 record_timeout_candidate < /dev/null

render_clean_preview_from_ledger
printf 'PARTIAL=%s\n' "$DRY_RUN_TOTAL_PARTIAL"
cat "$EXPORT_LIST_FILE"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PARTIAL=true"* ]] || return 1
    [[ "$output" == *"Cloud & Office"* ]] || return 1
    [[ "$output" == *"cache.bin  # size unknown"* ]] || return 1
}

@test "mo clean --dry-run never previews a live SQLite database family (#1390)" {
    local test_home
    test_home="$(mktemp -d "${BATS_TEST_TMPDIR}/clean-1390-home.XXXXXX")"
    mkdir -p "$test_home/.config/mole" \
        "$test_home/Library/Caches/com.autodesk.AcCoreConsole" \
        "$test_home/toolchain-bin"

    local db="$test_home/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"
    printf 'cache-db' > "$db"
    printf 'wal' > "$db-wal"
    printf 'shm' > "$db-shm"

    cat > "$test_home/toolchain-bin/lsof" << 'MOCK'
#!/bin/bash
# Shim: pretend every SQLite family member is held open by a process.
exit 0
MOCK
    chmod +x "$test_home/toolchain-bin/lsof"

    # Dry-run must not list the family even though the sweep reaches it: a
    # live WAL-mode database stays put, and the preview must agree with the
    # real run so the promised totals are the ones actually reclaimable.
    # Real-run preservation is pinned at the deletion boundary by
    # validate_path_for_deletion (tests/core_safe_functions.bats).
    set_mock_host_toolchains
    run env HOME="$test_home" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 \
        PATH="$test_home/toolchain-bin:$MOCK_TOOLCHAIN_BIN:$PATH" "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ] || return 1
    [[ "$(grep -cF "Cache.db" "$test_home/.config/mole/clean-list.txt")" -eq 0 ]] || return 1
    [[ -f "$db" && -f "$db-wal" && -f "$db-shm" ]] || return 1
}

@test "mo clean honors whitelist entries" {
    mkdir -p "$HOME/Library/Caches/WhitelistedApp"
    echo "keep me" > "$HOME/Library/Caches/WhitelistedApp/data.tmp"

    cat > "$HOME/.config/mole/whitelist" << EOF
$HOME/Library/Caches/WhitelistedApp*
EOF

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protected"* ]] || return 1
    [ -f "$HOME/Library/Caches/WhitelistedApp/data.tmp" ]
}

@test "mo clean honors whitelist entries with $HOME literal" {
    mkdir -p "$HOME/Library/Caches/WhitelistedApp"
    echo "keep me" > "$HOME/Library/Caches/WhitelistedApp/data.tmp"

    cat > "$HOME/.config/mole/whitelist" << 'EOF'
$HOME/Library/Caches/WhitelistedApp*
EOF

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protected"* ]] || return 1
    [ -f "$HOME/Library/Caches/WhitelistedApp/data.tmp" ]
}

@test "mo clean protects Maven repository by default" {
    mkdir -p "$HOME/.m2/repository/org/example"
    echo "dependency" > "$HOME/.m2/repository/org/example/lib.jar"

    # A custom whitelist file replaces DEFAULT_WHITELIST_PATTERNS wholesale, so
    # the old default row stopped protecting Maven for exactly the users most
    # likely to have one. The repository is the store Maven resolves from, so
    # the delete path is gone instead: there is nothing left to whitelist.
    mkdir -p "$HOME/.config/mole"
    printf '%s\n' "$HOME/.cache/unrelated-entry/*" > "$HOME/.config/mole/whitelist"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ] || return 1
    [ -f "$HOME/.m2/repository/org/example/lib.jar" ] || return 1

    # Assert the behaviour, not the source text: the old delete path built the
    # path into a variable one line above the safe_clean call, so a grep for
    # the literal beside the sink name passed while the bug was live.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 1; }
safe_clean() { printf 'TARGET=%s\n' "$*"; }
clean_dev_jvm
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *".m2"* ]] || {
        echo "$output"
        return 1
    }
}

@test "FINDER_METADATA_SENTINEL in whitelist protects .DS_Store files" {
    mkdir -p "$HOME/Documents"
    touch "$HOME/Documents/.DS_Store"

    # The sentinel's value is FINDER_METADATA; FINDER_METADATA_SENTINEL is the
    # variable name and matches nothing in a whitelist file.
    cat > "$HOME/.config/mole/whitelist" << EOF
FINDER_METADATA
EOF

    # Two halves of the real mechanism: load_whitelist must surface the sentinel so
    # bin/clean.sh's scan can see it, and clean_finder_metadata must bail once that
    # scan has flipped the flag. The previous version called is_whitelisted, which
    # answers "is this exact pattern already in the whitelist" for the management UI
    # and never matches a file path, so it asserted nothing.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
load_whitelist
sentinel_loaded=false
if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for entry in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
            sentinel_loaded=true
            break
        fi
    done
fi
echo "sentinel_loaded=$sentinel_loaded"

PROTECT_FINDER_METADATA=true
clean_ds_store_tree() { echo "CLEANED:$1"; }
clean_finder_metadata
echo "done"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"sentinel_loaded=true"* ]] || return 1
    [[ "$output" != *"CLEANED:"* ]] || return 1
    [[ "$output" == *"done"* ]] || return 1
    [ -f "$HOME/Documents/.DS_Store" ]
}

@test "custom whitelist without FINDER_METADATA still protects .DS_Store via safety merge (#1396)" {
    mkdir -p "$HOME/Documents" "$HOME/.config/mole"
    touch "$HOME/Documents/.DS_Store"
    # Pre-FINDER_METADATA user file: custom path only, no sentinel.
    printf '%s\n' "$HOME/.cache/custom-keep/*" > "$HOME/.config/mole/whitelist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Mirror bin/clean.sh load + safety merge + protect flag.
declare -a WHITELIST_PATTERNS=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    WHITELIST_PATTERNS+=("$line")
done < "$HOME/.config/mole/whitelist"
ensure_safety_whitelist_patterns

PROTECT_FINDER_METADATA=false
for entry in "${WHITELIST_PATTERNS[@]}"; do
    if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
        PROTECT_FINDER_METADATA=true
        break
    fi
done
echo "protect=$PROTECT_FINDER_METADATA"

clean_ds_store_tree() { echo "CLEANED:$1"; }
clean_finder_metadata
echo "done"
SCRIPT

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"protect=true"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"CLEANED:"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"done"* ]] || return 1
    [ -f "$HOME/Documents/.DS_Store" ]
}

@test "_clean_recent_items removes shared file lists" {
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    mkdir -p "$shared_dir"
    touch "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl2"
    touch "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() {
    echo "safe_clean $1"
}
_clean_recent_items
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Recent"* ]]
}

@test "_clean_recent_items handles missing shared directory" {
    rm -rf "$HOME/Library/Application Support/com.apple.sharedfilelist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() {
    echo "safe_clean $1"
}
_clean_recent_items
EOF

    [ "$status" -eq 0 ]
}

@test "_clean_mail_downloads skips cleanup when size below threshold" {
    mkdir -p "$HOME/Library/Mail Downloads"
    echo "test" > "$HOME/Library/Mail Downloads/small.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
_clean_mail_downloads
EOF

    [ "$status" -eq 0 ]
    [ -f "$HOME/Library/Mail Downloads/small.txt" ]
}

@test "_clean_mail_downloads removes old attachments" {
    mkdir -p "$HOME/Library/Mail Downloads"
    touch "$HOME/Library/Mail Downloads/old.pdf"
    touch -t 202301010000 "$HOME/Library/Mail Downloads/old.pdf"

    if command -v mkfile > /dev/null 2>&1; then
        mkfile -n 6000k "$HOME/Library/Mail Downloads/dummy.dat"
    else
        truncate -s 6000k "$HOME/Library/Mail Downloads/dummy.dat"
    fi

    [ -f "$HOME/Library/Mail Downloads/old.pdf" ]

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
_clean_mail_downloads
EOF

    [ "$status" -eq 0 ]
    [ ! -f "$HOME/Library/Mail Downloads/old.pdf" ]
}

@test "_clean_mail_downloads uses dry-run wording and keeps attachments" {
    mkdir -p "$HOME/Library/Mail Downloads"
    touch "$HOME/Library/Mail Downloads/old.pdf"
    touch -t 202301010000 "$HOME/Library/Mail Downloads/old.pdf"

    # MOLE_MAIL_DOWNLOADS_MIN_KB is readonly in base.sh, so an env override is
    # discarded and the sweep stays below threshold. Grow the directory instead,
    # the same way the non-dry-run case above does.
    if command -v mkfile > /dev/null 2>&1; then
        mkfile -n 6000k "$HOME/Library/Mail Downloads/dummy.dat"
    else
        truncate -s 6000k "$HOME/Library/Mail Downloads/dummy.dat"
    fi

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
_clean_mail_downloads
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Would clean 1 mail attachments"* ]] || return 1
    [[ "$output" != *"Cleaned 1 mail attachments"* ]] || return 1
    [ -f "$HOME/Library/Mail Downloads/old.pdf" ]
}

@test "clean_time_machine_failed_backups detects running backup correctly" {
    if ! command -v tmutil > /dev/null 2>&1; then
        skip "tmutil not available"
    fi

    local mock_bin="$HOME/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/tmutil" << 'MOCK_TMUTIL'
#!/bin/bash
if [[ "$1" == "status" ]]; then
    cat << 'TMUTIL_OUTPUT'
Backup session status:
{
    ClientID = "com.apple.backupd";
    Running = 0;
}
TMUTIL_OUTPUT
elif [[ "$1" == "destinationinfo" ]]; then
    cat << 'DEST_OUTPUT'
====================================================
Name          : TestBackup
Kind          : Local
Mount Point   : /Volumes/TestBackup
ID            : 12345678-1234-1234-1234-123456789012
====================================================
DEST_OUTPUT
fi
MOCK_TMUTIL
    chmod +x "$mock_bin/tmutil"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$mock_bin:$PATH" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


clean_time_machine_failed_backups
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Time Machine cleanup · skipped (backup in progress)"* ]]
}

@test "clean_time_machine_failed_backups skips when backup is actually running" {
    if ! command -v tmutil > /dev/null 2>&1; then
        skip "tmutil not available"
    fi

    local mock_bin="$HOME/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/tmutil" << 'MOCK_TMUTIL'
#!/bin/bash
if [[ "$1" == "status" ]]; then
    cat << 'TMUTIL_OUTPUT'
Backup session status:
{
    ClientID = "com.apple.backupd";
    Running = 1;
}
TMUTIL_OUTPUT
elif [[ "$1" == "destinationinfo" ]]; then
    cat << 'DEST_OUTPUT'
====================================================
Name          : TestBackup
Kind          : Local
Mount Point   : /Volumes/TestBackup
ID            : 12345678-1234-1234-1234-123456789012
====================================================
DEST_OUTPUT
fi
MOCK_TMUTIL
    chmod +x "$mock_bin/tmutil"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$mock_bin:$PATH" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


clean_time_machine_failed_backups
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Time Machine cleanup · skipped (backup in progress)"* ]]
}

@test "start_section recycles an idle section header in place on a TTY" {
    if ! /usr/bin/script -q /dev/null /bin/true > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi

    raw="$HOME/section-recycle.raw"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 TERM=xterm-256color \
        /usr/bin/script -q "$raw" /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            start_section "Idle Alpha"
            end_section
            start_section "Active Beta"
            note_activity
            echo "  row output"
            end_section
        ' > /dev/null 2>&1

    raw_content="$(cat "$raw")"
    # Idle header painted, then the next header overwrites its line in place.
    [[ "$raw_content" == *"Idle Alpha"* ]] || return 1
    [[ "$raw_content" == *$'\033[1A\r\033[2K'*"Active Beta"* ]] || return 1
    # TTY path must not fall back to the piped-output placeholder row.
    [[ "$raw_content" != *"Nothing to clean"* ]] || return 1
}

@test "log_success rows mark section activity so headers keep their blank separator" {
    if ! /usr/bin/script -q /dev/null /bin/true > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi

    raw="$HOME/section-log-activity.raw"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 TERM=xterm-256color \
        /usr/bin/script -q "$raw" /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            start_section "System"
            log_success "System crash reports"
            end_section
            start_section "User essentials"
            note_activity
            end_section
        ' > /dev/null 2>&1

    raw_content="$(cat "$raw")"
    # The log_success row counts as activity: the section is not idle, so the
    # next header must not recycle (and eat) the row line.
    [[ "$raw_content" == *"System crash reports"* ]] || return 1
    [[ "$raw_content" != *$'\033[1A'* ]] || return 1
    [[ "$raw_content" != *"Nothing to clean"* ]] || return 1
}

@test "sections whose rows come only from log_success are not marked idle in pipes" {
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            start_section "System"
            log_success "System crash reports"
            end_section
        '
    [ "$status" -eq 0 ]
    [[ "$output" == *"System crash reports"* ]] || return 1
    [[ "$output" != *"Nothing to clean"* ]] || return 1
}

@test "safe_clean skips caches that hold a compiled model cache" {
    export_file="$HOME/e5rt-list.txt"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            DRY_RUN=true
            # Set after sourcing: clean.sh assigns EXPORT_LIST_FILE at load time.
            EXPORT_LIST_FILE="$HOME/e5rt-list.txt"
            : > "$EXPORT_LIST_FILE"
            e5rt_cache="$HOME/Library/Caches/com.example.ocr/com.apple.e5rt.e5bundlecache"
            mkdir -p "$e5rt_cache" "$HOME/Library/Caches/com.example.plain"
            # Both need real bytes: zero-sized entries never reach the export list.
            dd if=/dev/zero of="$e5rt_cache/model.e5" bs=1024 count=200 2> /dev/null
            dd if=/dev/zero of="$HOME/Library/Caches/com.example.plain/junk" bs=1024 count=300 2> /dev/null
            safe_clean "$HOME"/Library/Caches/* "User app cache"
        '
    [ "$status" -eq 0 ] || return 1
    list_content="$(cat "$export_file")"
    [[ "$list_content" == *"com.example.plain"* ]] || return 1
    [[ "$list_content" != *"com.example.ocr"* ]] || return 1
}

@test "active clean sections rely on the final total" {
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            start_section "First"
            total_size_cleaned=$((total_size_cleaned + 3000))
            note_activity
            end_section
            start_section "Second"
            total_size_cleaned=$((total_size_cleaned + 2000))
            note_activity
            end_section
        '
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"First"*"Second"* ]] || return 1
    [[ "$output" != *"Category total"* ]] || return 1
}

@test "active cleanup families are deduplicated for the final summary" {
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            defer_cleanup_family "Xcode"
            defer_cleanup_family "Simulator"
            defer_cleanup_family "Xcode"
            defer_cleanup_family "Codex"
            format_deferred_cleanup_families
        '
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == "Xcode, Simulator, Codex" ]]
}

@test "timeout worker cleanup families reach the parent summary" {
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            DEFERRED_CLEANUP_FAMILIES=()
            DEFERRED_CLEANUP_FAMILIES_FILE=$(create_temp_file)
            run_with_shell_timeout 5 defer_cleanup_family "Dropbox"
            sync_deferred_cleanup_families
            format_deferred_cleanup_families
        '
    [[ "$status" -eq 0 ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == "Dropbox" ]]
}

@test "report-only clean sections omit the category total" {
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            start_section "Large files"
            log_success "iOS backups"
            end_section
        '
    [[ "$status" -eq 0 ]] || return 1
    [[ "$output" == *"iOS backups"* ]] || return 1
    # A hint row is activity but reclaims nothing: a "0B" footer under a row
    # quoting a huge directory reads as a bug, so there must be no footer.
    [[ "$output" != *"Category total"* ]] || return 1
}

@test "log rows do not trigger purge's export-only note_activity override" {
    export_file="$HOME/purge-log-activity.txt"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" EXPORT_LIST_FILE="$export_file" \
        MOLE_SKIP_MAIN=1 MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/purge.sh"
            start_section "Project artifacts"
            log_success "Project cache"
            end_section
            [[ ! -s "$EXPORT_LIST_FILE" ]] || return 1
        '
    [ "$status" -eq 0 ]
    [[ "$output" == *"Project cache"* ]] || return 1
}

@test "root preview staging is published through the invoking-user boundary" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

calls="$HOME/preview-user-boundary.calls"
CLEAN_PREVIEW_STAGING_FILE="$HOME/root-owned-preview.stage"
CLEAN_PREVIEW_FINAL_FILE="$HOME/user-config/clean-list.txt"
EXPORT_LIST_FILE="$CLEAN_PREVIEW_STAGING_FILE"
SUDO_USER="preview-user"
printf 'preview content\n' > "$CLEAN_PREVIEW_STAGING_FILE"

run_clean_preview_as_invoking_user() {
    printf '%s\n' "$*" >> "$calls"
    "$@"
}

publish_clean_preview_file
[[ "$EXPORT_LIST_FILE" == "$CLEAN_PREVIEW_FINAL_FILE" ]] || exit 1
[[ "$(cat "$CLEAN_PREVIEW_FINAL_FILE")" == "preview content" ]] || exit 1
grep -q '^/bin/mkdir -p ' "$calls"
grep -q '^/usr/bin/tee ' "$calls"
EOF

    [ "$status" -eq 0 ]
}

@test "end_section keeps the Nothing-to-clean fallback for piped output" {
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/bin/clean.sh"
            start_section "Idle Alpha"
            end_section
        '
    [ "$status" -eq 0 ]
    [[ "$output" == *"Idle Alpha"* ]] || return 1
    [[ "$output" == *"Nothing to clean"* ]] || return 1
    [[ "$output" != *"Category total"* ]] || return 1
}

@test "cleanup libs share one engine-absent shim instead of forking their own" {
    # bin/clean.sh owns the deferred-family ledger and is the only production
    # entry point that sources lib/clean/*, so a cleanup lib reaches it through
    # a `declare -f` probe. Three byte-identical copies of that probe grew in
    # dev.sh, user.sh, and app_caches.sh before it was hoisted into
    # mole_defer_cleanup_family. Pin the shape so a fourth cannot appear: a
    # forked copy drifts silently, and this one sits on the path that decides
    # whether a running app's cache is left alone.
    local shim_definitions
    shim_definitions=$(command grep -rn 'declare -f defer_cleanup_family' "$PROJECT_ROOT/lib" | wc -l | tr -d ' ')
    [ "$shim_definitions" -eq 1 ] || {
        echo "expected exactly one defer shim in lib/, found $shim_definitions:"
        command grep -rn 'declare -f defer_cleanup_family' "$PROJECT_ROOT/lib"
        return 1
    }
    command grep -rn 'declare -f defer_cleanup_family' "$PROJECT_ROOT/lib" | command grep -q 'lib/core/base.sh' || {
        echo "the defer shim moved out of lib/core/base.sh"
        return 1
    }
}

@test "engine-absent cleanup fallbacks stay at their audited count" {
    # Each `declare -f safe_clean_guarded` branch is a second, degraded copy of
    # the delete guard: production always has bin/clean.sh loaded and never runs
    # them, while standalone Bats cases always do. That split is tolerated for
    # the ten audited sites and must not grow, because every new one is another
    # place the guarded and unguarded verdicts can disagree without a user ever
    # exercising the branch that was reviewed.
    #
    # Adding cleanup code? Call safe_clean_guarded directly and let the test
    # provide it, rather than hand-rolling an eleventh fallback. Lowering this
    # baseline after removing one is expected; raising it needs a stated reason.
    local fallbacks
    fallbacks=$(command grep -rn 'declare -f safe_clean_guarded' "$PROJECT_ROOT/lib" | wc -l | tr -d ' ')
    [ "$fallbacks" -eq 10 ] || {
        echo "engine-absent fallback count is $fallbacks, audited baseline is 10:"
        command grep -rn 'declare -f safe_clean_guarded' "$PROJECT_ROOT/lib"
        return 1
    }
}

@test "mole_clean_process_guard denies on an unknown process state" {
    # Every cleanup delete guard now funnels its process question through this
    # one translator, so its tri-state contract is the single place a slip
    # would turn "Mole could not tell" into "safe to delete" across the whole
    # clean command. Pin all three states, including that 2 denies.
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

running() { return 0; }
not_running() { return 1; }
unknown() { return 2; }

_MOLE_CLEAN_GUARD_REASON=""
mole_clean_process_guard not_running "App started" || exit 1
[[ -z "$_MOLE_CLEAN_GUARD_REASON" ]] || exit 1

rc=0
mole_clean_process_guard running "App started" || rc=$?
[[ $rc -eq 1 ]] || exit 1
[[ "$_MOLE_CLEAN_GUARD_REASON" == "App started" ]] || exit 1

rc=0
mole_clean_process_guard unknown "App started" || rc=$?
[[ $rc -eq 1 ]] || exit 1
[[ "$_MOLE_CLEAN_GUARD_REASON" == "process state unknown" ]] || exit 1

rc=0
mole_clean_process_guard unknown "Updater started" "updater state unknown" || rc=$?
[[ $rc -eq 1 ]] || exit 1
[[ "$_MOLE_CLEAN_GUARD_REASON" == "updater state unknown" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "cleanup delete guards do not re-implement the process-state translation" {
    # Nine guards open-coded the same six lines. The failure mode is not
    # duplication, it is that one transcription slip folds state 2 into "not
    # running" and deletes a live app's files, while the other eight copies
    # still read correctly in review.
    local open_coded
    open_coded=$(
        command awk '
            /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { fn = $0; sub(/\(\).*/, "", fn) }
            fn ~ /_delete_guard_allows$/ && /\|\| process_state=\$\?/ { print FILENAME ":" FNR " " fn }
        ' "$PROJECT_ROOT"/lib/clean/*.sh
    )
    [ -z "$open_coded" ] || {
        echo "these guards translate the process state themselves instead of calling mole_clean_process_guard:"
        echo "$open_coded"
        return 1
    }
}
