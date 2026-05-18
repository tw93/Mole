#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-system-clean.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

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

@test "clean_deep_system issues safe sudo deletions" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        case "$2" in
            /Library/Caches) printf '%s\0' "/Library/Caches/test.log" ;;
            /private/var/log) printf '%s\0' "/private/var/log/system.log" ;;
        esac
        return 0
    fi
    if [[ "$1" == "stat" ]]; then
        echo "0"
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/Library/Caches"* ]]
    [[ "$output" == *"/private/tmp"* ]]
    [[ "$output" == *"/private/var/log"* ]]
}

@test "clean_deep_system does not touch /Library/Updates when directory absent" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls_skip.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() { return 0; }
safe_sudo_find_delete() { return 0; }
safe_sudo_remove() {
    echo "REMOVE:$1" >> "$CALL_LOG"
    return 0
}
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"/Library/Updates"* ]]
}

@test "clean_deep_system cleans third-party adobe logs conservatively" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls_adobe.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        case "$2" in
            /Library/Caches) printf '%s\0' "/Library/Caches/test.log" ;;
            /private/var/log) printf '%s\0' "/private/var/log/system.log" ;;
            /Library/Logs) echo "/Library/Logs/adobegc.log" ;;
        esac
        return 0
    fi
    if [[ "$1" == "stat" ]]; then
        echo "0"
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/Adobe:*"* ]]
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/CreativeCloud:*"* ]]
    [[ "$output" == *"safe_sudo_remove:/Library/Logs/adobegc.log"* ]]
}

@test "clean_deep_system does not report third-party adobe log success when no old files exist" {
    run bash --noprofile --norc << 'EOF2'
set -euo pipefail
CALL_LOG="$HOME/system_calls_adobe_empty.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        return 0
    fi
    if [[ "$1" == "stat" ]]; then
        echo "0"
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "command" && "${2:-}" == "find" && "${3:-}" == "/private/var/folders" ]]; then
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF2

    [ "$status" -eq 0 ]
    [[ "$output" != *"SUCCESS:Third-party system logs"* ]]
    [[ "$output" != *"safe_sudo_find_delete:/Library/Logs/Adobe:*"* ]]
    [[ "$output" != *"safe_sudo_find_delete:/Library/Logs/CreativeCloud:*"* ]]
    [[ "$output" != *"safe_sudo_remove:/Library/Logs/adobegc.log"* ]]
}

@test "clean_deep_system does not report third-party adobe log success when deletion fails" {
    run bash --noprofile --norc << 'EOF3'
set -euo pipefail
CALL_LOG="$HOME/system_calls_adobe_fail.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        case "$2" in
            /Library/Logs/Adobe) echo "/Library/Logs/Adobe/old.log" ;;
            /Library/Logs/CreativeCloud) return 0 ;;
            /Library/Logs) return 0 ;;
        esac
        return 0
    fi
    if [[ "$1" == "stat" ]]; then
        echo "0"
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 1
}
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "command" && "${2:-}" == "find" && "${3:-}" == "/private/var/folders" ]]; then
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF3

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/Adobe:*"* ]]
    [[ "$output" != *"SUCCESS:Third-party system logs"* ]]
}

@test "clean_time_machine_failed_backups exits when tmutil has no destinations" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


tmutil() {
    if [[ "$1" == "destinationinfo" ]]; then
        echo "No destinations configured"
        return 0
    fi
    return 0
}
pgrep() { return 1; }
find() { return 0; }

clean_time_machine_failed_backups
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No incomplete backups found"* ]]
}

@test "clean_local_snapshots reports snapshot count" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


run_with_timeout() {
    printf '%s\n' \
        "com.apple.TimeMachine.2023-10-25-120000" \
        "com.apple.TimeMachine.2023-10-24-120000"
}
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ return 1; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Time Machine local snapshots:"* ]]
    [[ "$output" == *"tmutil listlocalsnapshots /"* ]]
}

@test "clean_local_snapshots is quiet when no snapshots" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


run_with_timeout() { echo "Snapshots for disk /:"; }
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ return 1; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Time Machine local snapshots"* ]]
}

@test "clean_homebrew skips when cleaned recently" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole"
date +%s > "$HOME/.cache/mole/brew_last_cleanup"

brew() { return 0; }

clean_homebrew
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"cleaned"* ]]
}

@test "clean_homebrew runs cleanup with timeout stubs" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

    start_inline_spinner(){ :; }
    stop_inline_spinner(){ :; }
    note_activity(){ :; }
    run_with_timeout() {
        local duration="$1"
        shift
        if [[ "$1" == "du" ]]; then
            echo "51201 $3"
            return 0
        fi
        "$@"
    }

    brew() {
        case "$1" in
            cleanup)
            echo "Removing: package"
            return 0
            ;;
        autoremove)
            echo "Uninstalling pkg"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

    clean_homebrew
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew cleanup"* ]]
}

@test "run_with_timeout succeeds without GNU timeout" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 0.1
    '
    [ "$status" -eq 0 ]
}

@test "run_with_timeout enforces timeout and returns 124" {
    run bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 3
    '
    [ "$status" -eq 124 ]
}

@test "opt_saved_state_cleanup removes old saved states" {
    local state_dir="$HOME/Library/Saved Application State"
    mkdir -p "$state_dir/com.example.app.savedState"
    touch "$state_dir/com.example.app.savedState/data.plist"

    touch -t 202301010000 "$state_dir/com.example.app.savedState/data.plist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
}

@test "opt_saved_state_cleanup handles missing state directory" {
    rm -rf "$HOME/Library/Saved Application State"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"App saved states optimized"* ]]
}

@test "opt_saved_state_cleanup continues on permission denied (silent exit)" {
    local state_dir="$HOME/Library/Saved Application State"
    mkdir -p "$state_dir/com.example.old.savedState"
    touch -t 202301010000 "$state_dir/com.example.old.savedState" 2> /dev/null || true

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
safe_remove() { return 1; }
opt_saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"App saved states optimized"* ]]
}

@test "opt_cache_refresh continues on permission denied (silent exit)" {
    local cache_dir="$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
    mkdir -p "$cache_dir"
    touch "$cache_dir/test.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
qlmanage() { return 0; }
safe_remove() { return 1; }
opt_cache_refresh
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"QuickLook thumbnails refreshed"* ]]
}

@test "opt_cache_refresh cleans Quick Look cache" {
    mkdir -p "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
    touch "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache/test.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
qlmanage() { return 0; }
cleanup_path() {
    local path="$1"
    local label="${2:-}"
    [[ -e "$path" ]] && rm -rf "$path" 2>/dev/null || true
}
export -f qlmanage cleanup_path
opt_cache_refresh
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"QuickLook thumbnails refreshed"* ]]
}

@test "get_path_size_kb returns zero for missing directory" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "/nonexistent/path")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_path_size_kb calculates directory size" {
    mkdir -p "$HOME/test_size"
    dd if=/dev/zero of="$HOME/test_size/file.dat" bs=1024 count=10 2> /dev/null

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "$HOME/test_size")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    [ "$output" -ge 10 ]
}

@test "opt_fix_broken_configs reports fixes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

fix_broken_preferences() {
    echo 2
}

opt_fix_broken_configs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Repaired 2 corrupted preference files"* ]]
}

@test "clean_deep_system cleans memory exception reports" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/memory_exception_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        echo "sudo_find:$*" >> "$CALL_LOG"
        if [[ "$2" == "/private/var/db/reportmemoryexception/MemoryLimitViolations" ]]; then
            printf '%s\0' "/private/var/db/reportmemoryexception/MemoryLimitViolations/report.bin"
        fi
        return 0
    fi
    if [[ "$1" == "stat" ]]; then
        echo "1024"
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"reportmemoryexception/MemoryLimitViolations"* ]]
    [[ "$output" == *"-mtime +30"* ]] # 30-day retention
    [[ "$output" == *"safe_sudo_find_delete"* ]]
}

@test "clean_deep_system memory exception respects DRY_RUN flag" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/memory_exception_dryrun_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        [[ "$2" == "/private/var/db/reportmemoryexception/MemoryLimitViolations" ]] && return 0
        return 1
    fi
    if [[ "$1" == "find" ]]; then
        if [[ "$2" == "/private/var/db/reportmemoryexception/MemoryLimitViolations" ]]; then
            printf '%s\0' "/private/var/db/reportmemoryexception/MemoryLimitViolations/report.bin"
        fi
        return 0
    fi
    if [[ "$1" == "stat" ]]; then
        echo "1024"
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { :; }
log_info() { echo "$*"; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] Would remove"* ]]
    [[ "$output" != *"safe_sudo_find_delete:/private/var/db/reportmemoryexception/MemoryLimitViolations"* ]]
}

@test "clean_deep_system does not log memory exception success when nothing cleaned" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/memory_exception_success_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        [[ "$2" == "/private/var/db/reportmemoryexception/MemoryLimitViolations" ]] && return 0
        return 1
    fi
    if [[ "$1" == "find" ]]; then
        return 0
    fi
    if [[ "$1" == "stat" ]]; then
        echo "0"
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"SUCCESS:Memory exception reports"* ]]
}

@test "clean_deep_system cleans diagnostic trace logs" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/diag_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        echo "sudo_find:$*" >> "$CALL_LOG"
        if [[ "$2" == "/private/var/db/diagnostics" ]]; then
            printf '%s\0' \
                "/private/var/db/diagnostics/Persist/test.tracev3" \
                "/private/var/db/diagnostics/Special/test.tracev3"
        fi
        return 0
    fi
    return 0
}
safe_sudo_find_delete() {
    echo "safe_sudo_find_delete:$1:$2" >> "$CALL_LOG"
    return 0
}
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"diagnostics/Persist"* ]]
    [[ "$output" == *"diagnostics/Special"* ]]
    [[ "$output" == *"tracev3"* ]]
}

@test "clean_deep_system cleans code_sign_clone caches via safe_sudo_remove" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/code_sign_clone_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 1
    fi
    if [[ "$1" == "find" ]]; then
        return 0
    fi
    return 0
}
safe_sudo_find_delete() { return 0; }
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "command" && "${2:-}" == "find" && "${3:-}" == "/private/var/folders" ]]; then
        printf '%s\0' "/private/var/folders/test/a/X/demo.code_sign_clone"
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/X/demo.code_sign_clone"* ]]
    [[ "$output" == *"SUCCESS:Browser code signature caches"* ]]
}

@test "clean_deep_system skips code_sign_clone success when removal fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/code_sign_clone_fail_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 1
    fi
    if [[ "$1" == "find" ]]; then
        return 0
    fi
    return 0
}
safe_sudo_find_delete() { return 0; }
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 1
}
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "command" && "${2:-}" == "find" && "${3:-}" == "/private/var/folders" ]]; then
        printf '%s\0' "/private/var/folders/test/a/X/demo.code_sign_clone"
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/X/demo.code_sign_clone"* ]]
    [[ "$output" != *"SUCCESS:Browser code signature caches"* ]]
}

@test "clean_deep_system cleans CleanMyMac-observed rebuildable system caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/rebuildable_cache_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        case "$3" in
            /Library/Caches/com.apple.iconservices.store)
                return 0
                ;;
        esac
        return 1
    fi
    if [[ "$1" == "find" ]]; then
        return 0
    fi
    return 0
}
safe_sudo_find_delete() { return 0; }
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
run_with_timeout() { shift; "$@"; }

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/Library/Caches/com.apple.iconservices.store"* ]]
    [[ "$output" == *"SUCCESS:Rebuildable system caches, 1 item"* ]]
}

@test "is_rebuildable_gpu_cache_dir only allows C GPU cache shards" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/com.apple.metal"
is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/com.apple.metalfe"
is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/com.apple.gpuarchiver"
! is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/T/com.example.App/com.apple.metal"
! is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/not-a-gpu-cache"
! is_rebuildable_gpu_cache_dir "/Library/Extensions/com.example.driver/com.apple.metal"
EOF

    [ "$status" -eq 0 ]
}

@test "gpu_cache_dir_is_stale uses contained file mtimes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

stale_dir="$HOME/gpu-stale"
active_dir="$HOME/gpu-active"
mkdir -p "$stale_dir" "$active_dir"
touch "$stale_dir/functions.data" "$active_dir/functions.data"
touch -t 202001010000 "$stale_dir/functions.data"

gpu_cache_dir_is_stale "$stale_dir" 1
! gpu_cache_dir_is_stale "$active_dir" 1
EOF

    [ "$status" -eq 0 ]
}

@test "clean_deep_system cleans only narrow private var GPU cache shards" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/gpu_cache_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 1
    fi
    if [[ "$1" == "find" ]]; then
        return 0
    fi
    return 0
}
safe_sudo_find_delete() { return 0; }
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_sip_enabled() { return 1; }
find() { return 0; }
gpu_cache_dir_is_stale() { return 0; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "command" && "${2:-}" == "find" && "${3:-}" == "/private/var/folders" ]]; then
        printf 'find_args:%s\n' "$*" >> "$CALL_LOG"
        printf '%s\0' \
            "/private/var/folders/test/a/C/com.example.App/com.apple.metal" \
            "/private/var/folders/test/a/C/com.example.App/com.apple.metalfe" \
            "/private/var/folders/test/a/C/com.example.App/com.apple.gpuarchiver" \
            "/private/var/folders/test/a/T/com.example.App/com.apple.metal" \
            "/private/var/folders/test/a/C/com.example.App/not-a-gpu-cache"
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/C/com.example.App/com.apple.metal"* ]]
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/C/com.example.App/com.apple.metalfe"* ]]
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/C/com.example.App/com.apple.gpuarchiver"* ]]
    [[ "$output" != *"/private/var/folders/test/a/T/com.example.App/com.apple.metal"* ]]
    [[ "$output" != *"not-a-gpu-cache"* ]]
    [[ "$output" != *"-mtime +1"* ]]
    [[ "$output" == *"SUCCESS:Accessible rebuildable GPU caches, 3 items"* ]]
}

@test "dirs_cleaner audit reports large staging entries without deletion" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DIRS_CLEANER_WARN_MB=1 MOLE_DIRS_CLEANER_AGE_DAYS=30 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 400000; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { echo "NOTE_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 1; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/stuck"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/stuck" ]]; then
                if [[ "$*" == *"-print -quit"* ]]; then
                    return 0
                fi
                echo "1000"
                return 0
            fi
            return 0
            ;;
        du)
            echo "2048 $3"
            return 0
            ;;
        stat)
            if [[ "$3" == "%d" ]]; then
                echo "100"
                return 0
            fi
            echo "root|drwxr-xr-x|none|1000"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

report_stuck_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Stuck macOS cleanup staging detected"* ]]
    [[ "$output" == *"/private/var/dirs_cleaner/stuck"* ]]
    [[ "$output" == *"2.1MB"* ]]
    [[ "$output" == *"owner root, drwxr-xr-x"* ]]
    [[ "$output" == *"Review: sudo du -xhd 2 /private/var/dirs_cleaner"* ]]
    [[ "$output" == *"Review open handles: sudo lsof +D /private/var/dirs_cleaner"* ]]
    [[ "$output" == *"NOTE_ACTIVITY"* ]]
    [[ "$output" == *"OP:WARNING:/private/var/dirs_cleaner/stuck"* ]]
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "dirs_cleaner audit skips fresh small entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DIRS_CLEANER_WARN_MB=1 MOLE_DIRS_CLEANER_AGE_DAYS=30 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 200000; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }
log_operation() { echo "UNEXPECTED_OP"; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/fresh"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/fresh" ]]; then
                if [[ "$*" == *"-print -quit"* ]]; then
                    return 0
                fi
                echo "200000"
                return 0
            fi
            return 0
            ;;
        du)
            echo "512 $3"
            return 0
            ;;
        stat)
            if [[ "$3" == "%d" ]]; then
                echo "100"
                return 0
            fi
            echo "root|drwxr-xr-x|none|200000"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

report_stuck_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Stuck macOS cleanup staging detected"* ]]
    [[ "$output" != *"UNEXPECTED"* ]]
}

@test "dirs_cleaner audit refuses symlinked children" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DIRS_CLEANER_WARN_MB=0 MOLE_DIRS_CLEANER_AGE_DAYS=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" && "$3" == "/private/var/dirs_cleaner/link" ]]; then
                return 0
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/link"
                return 0
            fi
            return 0
            ;;
        du)
            echo "UNEXPECTED_DU"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

report_stuck_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Stuck macOS cleanup staging detected"* ]]
    [[ "$output" != *"UNEXPECTED"* ]]
}

@test "dirs_cleaner audit refuses symlinked root" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { echo "NOTE_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            return 1
            ;;
        find)
            echo "UNEXPECTED_FIND"
            return 0
            ;;
    esac
    return 0
}

report_stuck_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"macOS cleanup staging audit skipped: symlinked path"* ]]
    [[ "$output" == *"NOTE_ACTIVITY"* ]]
    [[ "$output" == *"OP:SKIPPED:/private/var/dirs_cleaner"* ]]
    [[ "$output" != *"UNEXPECTED_FIND"* ]]
}

@test "dirs_cleaner audit skips top-level mountpoint children" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DIRS_CLEANER_WARN_MB=0 MOLE_DIRS_CLEANER_AGE_DAYS=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/mounted"
                return 0
            fi
            echo "UNEXPECTED_CHILD_FIND"
            return 0
            ;;
        stat)
            if [[ "$4" == "/private/var/dirs_cleaner" ]]; then
                echo "100"
                return 0
            fi
            if [[ "$4" == "/private/var/dirs_cleaner/mounted" ]]; then
                echo "200"
                return 0
            fi
            return 1
            ;;
        du)
            echo "UNEXPECTED_DU"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

report_stuck_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Stuck macOS cleanup staging detected"* ]]
    [[ "$output" == *"OP:SKIPPED:/private/var/dirs_cleaner/mounted"* ]]
    [[ "$output" != *"UNEXPECTED"* ]]
}

@test "dirs_cleaner audit reports traversal failures with manual review command" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { echo "NOTE_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            echo "permission denied" >&2
            return 2
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

report_stuck_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not fully inspect macOS cleanup staging"* ]]
    [[ "$output" == *"Review: sudo du -xhd 2 /private/var/dirs_cleaner"* ]]
    [[ "$output" == *"NOTE_ACTIVITY"* ]]
    [[ "$output" == *"OP:FAILED:/private/var/dirs_cleaner"* ]]
}

@test "dirs_cleaner cleanup dry-run removes only eligible stale top-level entries through safe_sudo_remove" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_DRY_RUN=1 MOLE_DIRS_CLEANER_AGE_DAYS=3 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 400000; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { echo "NOTE_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }
safe_sudo_remove() {
    if [[ "$1" == "/private/var/dirs_cleaner/J1" ]]; then
        echo "UNEXPECTED_PARENT_REMOVE:$1"
        return 1
    fi
    echo "safe_sudo_remove:$1"
    return 0
}

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/stuck"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/stuck" ]]; then
                echo "1000"
                return 0
            fi
            return 0
            ;;
        du)
            echo "2048 $3"
            return 0
            ;;
        stat)
            if [[ "$3" == "%d" ]]; then
                echo "100"
                return 0
            fi
            echo "root|drwxr-xr-x|none|1000"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

clean_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/private/var/dirs_cleaner/stuck"* ]]
    [[ "$output" == *"Stale macOS cleanup staging, 1 items"* ]]
    [[ "$output" == *"dry"* ]]
    [[ "$output" == *"OP:DRY_RUN:/private/var/dirs_cleaner/stuck"* ]]
    [[ "$output" != *"OP:REMOVED"* ]]
}

@test "dirs_cleaner cleanup removes stale shallow children instead of non-empty top-level buckets" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_DRY_RUN=1 MOLE_DIRS_CLEANER_AGE_DAYS=3 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 400000; }
note_activity() { echo "NOTE_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }
safe_sudo_remove() { echo "safe_sudo_remove:$1"; return 0; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner/J1" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0%s\0' "/private/var/dirs_cleaner/J1" "/private/var/dirs_cleaner/J1/stuck"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/J1" ]]; then
                if [[ "$*" == *"-print -quit"* ]]; then
                    echo "/private/var/dirs_cleaner/J1/stuck"
                    return 0
                fi
                echo "300000"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/J1/stuck" ]]; then
                if [[ "$*" == *"-print -quit"* ]]; then
                    return 0
                fi
                echo "1000"
                return 0
            fi
            return 0
            ;;
        du)
            echo "2048 $3"
            return 0
            ;;
        stat)
            if [[ "$3" == "%d" ]]; then
                echo "100"
                return 0
            fi
            echo "root|drwxr-xr-x|none|1000"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

clean_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_PARENT_REMOVE"* ]]
    [[ "$output" == *"safe_sudo_remove:/private/var/dirs_cleaner/J1/stuck"* ]]
    [[ "$output" == *"OP:DRY_RUN:/private/var/dirs_cleaner/J1/stuck"* ]]
    [[ "$output" == *"Stale macOS cleanup staging, 1 items"* ]]
}

@test "dirs_cleaner cleanup skips stale shallow child when deeper descendant is fresh" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_DRY_RUN=1 MOLE_DIRS_CLEANER_AGE_DAYS=3 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 400000; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 1; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/J1/stuck"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/J1/stuck" ]]; then
                echo "1000"
                echo "399999"
                return 0
            fi
            return 0
            ;;
        du)
            echo "2048 $3"
            return 0
            ;;
        stat)
            if [[ "$3" == "%d" ]]; then
                echo "100"
                return 0
            fi
            echo "root|drwxr-xr-x|none|1000"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

clean_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale macOS cleanup staging found"* ]]
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "dirs_cleaner cleanup skips top-level bucket when child scan fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_DRY_RUN=1 MOLE_DIRS_CLEANER_AGE_DAYS=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 400000; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 1; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner/J1" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/J1"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/J1" ]]; then
                return 124
            fi
            return 0
            ;;
        stat)
            echo "100"
            return 0
            ;;
        du)
            echo "UNEXPECTED_DU"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

clean_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale macOS cleanup staging found"* ]]
    [[ "$output" == *"OP:SKIPPED:/private/var/dirs_cleaner/J1"* ]]
    [[ "$output" != *"UNEXPECTED"* ]]
}

@test "dirs_cleaner cleanup skips fresh entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false MOLE_DRY_RUN=0 MOLE_DIRS_CLEANER_AGE_DAYS=3 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 200000; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }
log_operation() { echo "UNEXPECTED_OP"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 1; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/fresh"
                return 0
            fi
            if [[ "$2" == "/private/var/dirs_cleaner/fresh" ]]; then
                echo "200000"
                return 0
            fi
            return 0
            ;;
        du)
            echo "2048 $3"
            return 0
            ;;
        stat)
            if [[ "$3" == "%d" ]]; then
                echo "100"
                return 0
            fi
            echo "root|drwxr-xr-x|none|200000"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

clean_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale macOS cleanup staging found"* ]]
    [[ "$output" != *"UNEXPECTED"* ]]
}

@test "dirs_cleaner cleanup skips top-level mountpoint children" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false MOLE_DRY_RUN=0 MOLE_DIRS_CLEANER_AGE_DAYS=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 200000; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 1; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/mounted"
                return 0
            fi
            echo "UNEXPECTED_CHILD_FIND"
            return 0
            ;;
        stat)
            if [[ "$4" == "/private/var/dirs_cleaner" ]]; then
                echo "100"
                return 0
            fi
            if [[ "$4" == "/private/var/dirs_cleaner/mounted" ]]; then
                echo "200"
                return 0
            fi
            return 1
            ;;
        du)
            echo "UNEXPECTED_DU"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

clean_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale macOS cleanup staging found"* ]]
    [[ "$output" == *"OP:SKIPPED:/private/var/dirs_cleaner/mounted"* ]]
    [[ "$output" != *"UNEXPECTED"* ]]
}

@test "dirs_cleaner cleanup skips children with nested mountpoints" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false MOLE_DRY_RUN=0 MOLE_DIRS_CLEANER_AGE_DAYS=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

get_epoch_seconds() { echo 400000; }
note_activity() { echo "UNEXPECTED_ACTIVITY"; }
log_operation() { echo "OP:$2:$3:$4"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 1; }
mount() { echo "dev on /private/var/dirs_cleaner/stuck/nested (apfs, local)"; }

sudo() {
    case "$1" in
        test)
            if [[ "$2" == "-d" && "$3" == "/private/var/dirs_cleaner" ]]; then
                return 0
            fi
            if [[ "$2" == "-L" ]]; then
                return 1
            fi
            return 1
            ;;
        find)
            if [[ "$2" == "/private/var/dirs_cleaner" ]]; then
                printf '%s\0' "/private/var/dirs_cleaner/stuck"
                return 0
            fi
            echo "UNEXPECTED_CHILD_FIND"
            return 0
            ;;
        stat)
            echo "100"
            return 0
            ;;
        du)
            echo "UNEXPECTED_DU"
            return 0
            ;;
    esac
    return 0
}

run_with_timeout() {
    local _timeout="$1"
    shift
    "$@"
}

clean_dirs_cleaner_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No stale macOS cleanup staging found"* ]]
    [[ "$output" == *"OP:SKIPPED:/private/var/dirs_cleaner/stuck"* ]]
    [[ "$output" != *"UNEXPECTED"* ]]
}

@test "opt_memory_pressure_relief skips when pressure is normal" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

memory_pressure() {
    echo "System-wide memory free percentage: 50%"
    return 0
}
export -f memory_pressure

opt_memory_pressure_relief
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Memory pressure already optimal"* ]]
}

@test "opt_memory_pressure_relief executes purge when pressure is high" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

memory_pressure() {
    echo "System-wide memory free percentage: warning"
    return 0
}
export -f memory_pressure

sudo() {
    if [[ "$1" == "purge" ]]; then
        echo "purge:executed"
        return 0
    fi
    return 1
}
export -f sudo

# Sudo is mocked above; explicitly opt out of the test-mode short-circuit
# in optimize_sudo_available so this success-path test reaches the mock.
unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH
opt_memory_pressure_relief
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Inactive memory released"* ]]
    [[ "$output" == *"System responsiveness improved"* ]]
}

@test "opt_network_stack_optimize skips when network is healthy" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

route() {
    return 0
}
export -f route

dscacheutil() {
    echo "ip_address: 93.184.216.34"
    return 0
}
export -f dscacheutil

opt_network_stack_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Network stack already optimal"* ]]
}

@test "opt_network_stack_optimize skips when VPN is active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=1 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

route() {
    echo "unexpected-route"
    return 0
}
export -f route

sudo() {
    echo "unexpected-sudo"
    return 0
}
export -f sudo

opt_network_stack_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Network stack refresh skipped, active VPN detected"* ]]
    [[ "$output" != *"unexpected-route"* ]]
    [[ "$output" != *"unexpected-sudo"* ]]
}

@test "opt_network_stack_optimize flushes when network has issues" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

route() {
    if [[ "$2" == "get" ]]; then
        return 1
    fi
    if [[ "$1" == "-n" && "$2" == "flush" ]]; then
        echo "route:flushed"
        return 0
    fi
    return 0
}
export -f route

sudo() {
    if [[ "$1" == "route" || "$1" == "arp" ]]; then
        shift
        route "$@" || arp "$@"
        return 0
    fi
    return 1
}
export -f sudo

arp() {
    echo "arp:cleared"
    return 0
}
export -f arp

dscacheutil() {
    return 1
}
export -f dscacheutil

# Sudo is mocked above; explicitly opt out of the test-mode short-circuit
# in optimize_sudo_available so this success-path test reaches the mock.
unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH
opt_network_stack_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Network routing table refreshed"* ]]
    [[ "$output" == *"ARP cache cleared"* ]]
}

@test "opt_disk_permissions_repair skips when permissions are fine" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

stat() {
    if [[ "$2" == "%Su" ]]; then
        echo "$USER"
        return 0
    fi
    command stat "$@"
}
export -f stat

test() {
    if [[ "$1" == "-e" || "$1" == "-w" ]]; then
        return 0
    fi
    command test "$@"
}
export -f test

opt_disk_permissions_repair
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"User directory permissions already optimal"* ]]
}

@test "opt_disk_permissions_repair calls diskutil when needed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

stat() {
    if [[ "$2" == "%Su" ]]; then
        echo "root"
        return 0
    fi
    command stat "$@"
}
export -f stat

sudo() {
    if [[ "$1" == "diskutil" && "$2" == "resetUserPermissions" ]]; then
        echo "diskutil:resetUserPermissions"
        return 0
    fi
    return 1
}
export -f sudo

id() {
    echo "501"
}
export -f id

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
export -f start_inline_spinner stop_inline_spinner

# Sudo is mocked above; explicitly opt out of the test-mode short-circuit
# in optimize_sudo_available so this success-path test reaches the mock.
unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH
opt_disk_permissions_repair
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"User directory permissions repaired"* ]]
}

@test "opt_spotlight_index_optimize skips when search is fast" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mdutil() {
    if [[ "$1" == "-s" ]]; then
        echo "Indexing enabled."
        return 0
    fi
    return 0
}
export -f mdutil

mdfind() {
    return 0
}
export -f mdfind

date() {
    echo "1000"
}
export -f date

opt_spotlight_index_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Spotlight index already optimal"* ]]
}
