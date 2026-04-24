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
    rm -rf "$HOME"
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

@test "get_apfs_snapshot_space_note explains Finder df gap when snapshots exist" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }
tmutil() { :; }
run_with_timeout() {
    printf '%s\n' \
        "com.apple.TimeMachine.2023-10-25-120000" \
        "com.apple.TimeMachine.2023-10-24-120000"
}

get_apfs_snapshot_space_note
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Finder may show more available space than df"* ]]
    [[ "$output" == *"2 APFS snapshots"* ]]
    [[ "$output" == *"Mole reports df-style free space"* ]]
}

@test "get_apfs_snapshot_space_note is quiet when no snapshots exist" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }
tmutil() { :; }
run_with_timeout() { echo "Snapshots for disk /:"; }

get_apfs_snapshot_space_note
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
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

@test "check_appstore_updates is skipped for performance" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

check_appstore_updates
echo "COUNT=$APPSTORE_UPDATE_COUNT"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=0"* ]]
}

@test "check_homebrew_updates reports counts and exports update variables" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() {
    local timeout="${1:-}"
    shift
    "$@"
}

brew() {
    if [[ "$1" == "outdated" && "$2" == "--formula" && "$3" == "--quiet" ]]; then
        printf "wget\njq\n"
        return 0
    fi
    if [[ "$1" == "outdated" && "$2" == "--cask" && "$3" == "--quiet" ]]; then
        printf "iterm2\n"
        return 0
    fi
    return 0
}

check_homebrew_updates
echo "COUNTS=${BREW_OUTDATED_COUNT}:${BREW_FORMULA_OUTDATED_COUNT}:${BREW_CASK_OUTDATED_COUNT}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]]
    [[ "$output" == *"2 formula, 1 cask available"* ]]
    [[ "$output" == *"COUNTS=3:2:1"* ]]
}

@test "check_homebrew_updates shows timeout warning when brew query times out" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() { return 124; }
brew() { return 0; }
rm -f "$HOME/.cache/mole/brew_updates"

check_homebrew_updates
echo "COUNTS=${BREW_OUTDATED_COUNT}:${BREW_FORMULA_OUTDATED_COUNT}:${BREW_CASK_OUTDATED_COUNT}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]]
    [[ "$output" == *"Check timed out"* ]]
    [[ "$output" == *"COUNTS=0:0:0"* ]]
}

@test "check_homebrew_updates shows failure warning when brew query fails" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() { return 1; }
brew() { return 0; }
rm -f "$HOME/.cache/mole/brew_updates"

check_homebrew_updates
echo "COUNTS=${BREW_OUTDATED_COUNT}:${BREW_FORMULA_OUTDATED_COUNT}:${BREW_CASK_OUTDATED_COUNT}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew"* ]]
    [[ "$output" == *"Check failed"* ]]
    [[ "$output" == *"COUNTS=0:0:0"* ]]
}

@test "check_macos_update reports background security improvements as macOS updates" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        cat <<'OUT'
Software Update Tool

Software Update found the following new or updated software:
* Label: macOS Background Security Improvement (a)-25D771280a
        Title: macOS Background Security Improvement (a), Version: 26.3.1 (a), Size: 208896KiB, Recommended: YES, Action: restart,
OUT
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Background Security Improvement"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update clears update flag when softwareupdate reports no updates" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        cat <<'OUT'
Software Update Tool

Finding available software
No new software available.
OUT
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"System up to date"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=false"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update ignores non-macOS softwareupdate entries" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        cat <<'OUT'
Software Update Tool

Software Update found the following new or updated software:
* Label: Numbers-14.4
        Title: Numbers, Version: 14.4, Size: 51200KiB, Recommended: YES, Action: none,
OUT
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"System up to date"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=false"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "get_software_updates caches softwareupdate output in memory" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

calls=0

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "$timeout" != "10" ]]; then
        echo "BAD_TIMEOUT:$timeout"
        return 124
    fi
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        calls=$((calls + 1))
        cat <<'OUT'
Software Update Tool

No new software available.
OUT
        return 0
    fi
    return 124
}

first="$(get_software_updates)"
second="$(get_software_updates)"
printf 'CALLS=%s\n' "$calls"
printf 'FIRST=%s\n' "$first"
printf 'SECOND=%s\n' "$second"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CALLS=1"* ]]
    [[ "$output" == *"FIRST=Software Update Tool"* ]]
    [[ "$output" == *"SECOND=Software Update Tool"* ]]
    [[ "$output" != *"BAD_TIMEOUT:"* ]]
}

@test "check_macos_update uses cached softwareupdate output when available" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
mkdir -p "$HOME/.cache/mole"
cat > "$HOME/.cache/mole/softwareupdate_list" <<'OUT'
Software Update Tool

Software Update found the following new or updated software:
* Label: macOS 99
        Title: macOS 99, Version: 99.1, Size: 1024KiB, Recommended: YES, Action: restart,
OUT

run_with_timeout() {
    echo "SHOULD_NOT_CALL_SOFTWAREUPDATE"
    return 124
}

check_macos_update
echo "MACOS_UPDATE_AVAILABLE=$MACOS_UPDATE_AVAILABLE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"macOS 99, Version: 99.1"* ]]
    [[ "$output" == *"MACOS_UPDATE_AVAILABLE=true"* ]]
    [[ "$output" != *"SHOULD_NOT_CALL_SOFTWAREUPDATE"* ]]
}

@test "reset_softwareupdate_cache clears in-memory softwareupdate state" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

calls_file="$HOME/softwareupdate_calls"
printf '0\n' > "$calls_file"
first_file="$HOME/first_updates.txt"
second_file="$HOME/second_updates.txt"
rm -f "$HOME/.cache/mole/softwareupdate_list"
SOFTWARE_UPDATE_LIST=""
SOFTWARE_UPDATE_LIST_LOADED="false"
run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        local calls
        calls=$(cat "$calls_file")
        calls=$((calls + 1))
        printf '%s\n' "$calls" > "$calls_file"
        cat <<OUT
Software Update Tool

* Label: macOS $calls
        Title: macOS $calls, Version: $calls.0, Size: 1024KiB, Recommended: YES, Action: restart,
OUT
        return 0
    fi
    return 124
}

get_software_updates > "$first_file"
reset_softwareupdate_cache
get_software_updates > "$second_file"
printf 'CALLS=%s\n' "$(cat "$calls_file")"
printf 'FIRST=%s\n' "$(cat "$first_file")"
printf 'SECOND=%s\n' "$(cat "$second_file")"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CALLS=2"* ]]
    [[ "$output" == *"FIRST=Software Update Tool"* ]]
    [[ "$output" == *"SECOND=Software Update Tool"* ]]
    [[ "$output" == *"macOS 2"* ]]
}

@test "check_macos_update outputs debug info when MO_DEBUG set" {
    run bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"

export MO_DEBUG=1

run_with_timeout() {
    local timeout="${1:-}"
    shift
    if [[ "${1:-}" == "softwareupdate" && "${2:-}" == "-l" && "${3:-}" == "--no-scan" ]]; then
        echo "No new software available."
        return 0
    fi
    return 124
}

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }

check_macos_update 2>&1
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DEBUG] softwareupdate cached output lines:"* ]]
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
        run_with_timeout 1 sleep 5
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

opt_memory_pressure_relief
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Inactive memory released"* ]]
    [[ "$output" == *"System responsiveness improved"* ]]
}

@test "opt_network_stack_optimize skips when network is healthy" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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

@test "opt_network_stack_optimize flushes when network has issues" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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

opt_disk_permissions_repair
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"User directory permissions repaired"* ]]
}

@test "opt_bluetooth_reset skips when HID device is connected" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

system_profiler() {
    cat << 'PROFILER_OUT'
Bluetooth:
  Apple Magic Keyboard:
    Connected: Yes
    Type: Keyboard
PROFILER_OUT
    return 0
}
export -f system_profiler

opt_bluetooth_reset
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bluetooth already optimal"* ]]
}

@test "opt_bluetooth_reset skips when media apps are running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

system_profiler() {
    cat << 'PROFILER_OUT'
Bluetooth:
  AirPods Pro:
    Connected: Yes
    Type: Headphones
PROFILER_OUT
    return 0
}
export -f system_profiler

pgrep() {
    if [[ "$2" == "Spotify" ]]; then
        echo "12345"
        return 0
    fi
    return 1
}
export -f pgrep

opt_bluetooth_reset
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bluetooth already optimal"* ]]
}

@test "opt_bluetooth_reset skips when Bluetooth audio output is active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

system_profiler() {
    if [[ "$1" == "SPAudioDataType" ]]; then
        cat << 'AUDIO_OUT'
Audio:
    Devices:
        AirPods Pro:
          Default Output Device: Yes
          Manufacturer: Apple Inc.
          Output Channels: 2
          Transport: Bluetooth
          Output Source: AirPods Pro
AUDIO_OUT
        return 0
    elif [[ "$1" == "SPBluetoothDataType" ]]; then
        echo "Bluetooth:"
        return 0
    fi
    return 1
}
export -f system_profiler

awk() {
    if [[ "${*}" == *"Default Output Device"* ]]; then
        cat << 'AWK_OUT'
          Default Output Device: Yes
          Manufacturer: Apple Inc.
          Output Channels: 2
          Transport: Bluetooth
          Output Source: AirPods Pro
AWK_OUT
        return 0
    fi
    command awk "$@"
}
export -f awk

opt_bluetooth_reset
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bluetooth already optimal"* ]]
}

@test "opt_bluetooth_reset restarts when safe" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

system_profiler() {
    cat << 'PROFILER_OUT'
Bluetooth:
  AirPods:
    Connected: Yes
    Type: Audio
PROFILER_OUT
    return 0
}
export -f system_profiler

pgrep() {
    if [[ "$2" == "bluetoothd" ]]; then
        return 1  # bluetoothd not running after TERM
    fi
    return 1
}
export -f pgrep

sudo() {
    if [[ "$1" == "pkill" ]]; then
        echo "pkill:bluetoothd:$2"
        return 0
    fi
    return 1
}
export -f sudo

sleep() { :; }
export -f sleep

opt_bluetooth_reset
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bluetooth devices may disconnect briefly during refresh"* ]]
    [[ "$output" == *"Bluetooth module restarted"* ]]
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
