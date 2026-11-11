#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home system-clean

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    mole_test_teardown_home
}

# clean_deep_system reaches its two /private/var/folders sweeps through
# `/usr/bin/find`, which a shell-function `find` mock cannot intercept, and a
# plain "drop the timeout and run it" wrapper mock removes the production
# bound as well. Each test then walked the host's real temp tree twice,
# unbounded, for seconds. Intercept at the wrapper instead and hand back an
# empty result, the same seam the GPU-cache tests below use to inject their
# fixtures. The browser clone stage reads the host's per-user temp dir (by
# uid, not HOME) with the real ps, lsof and safe_remove, so tests that do not
# exercise it run with the stage stubbed; tests/browser_clones.bats covers it
# against fixtures. A test with its own run_with_timeout stubs it by hand.
mock_run_with_timeout_skipping_var_folders() {
    # shellcheck disable=SC2329  # Invoked by lib/clean/system.sh once defined.
    clean_browser_code_sign_clones() { :; }
    # shellcheck disable=SC2329  # Invoked by lib/clean/system.sh once defined.
    run_with_timeout() {
        shift
        if [[ "${1:-}" == "/usr/bin/find" && "${2:-}" == "/private/var/folders" ]]; then
            return 0
        fi
        "$@"
    }
}
export -f mock_run_with_timeout_skipping_var_folders

@test "materialize_completed_system_scan discards every failed producer prefix" {
    local producer="$HOME/partial-system-scan.sh"
    local trace="$HOME/partial-system-scan.trace"
    cat > "$producer" <<'SCRIPT'
#!/bin/bash
printf 'started:%s\n' "$PRODUCER_RC" >> "$SYSTEM_SCAN_TRACE"
printf 'partial\0'
exit "$PRODUCER_RC"
SCRIPT
    chmod +x "$producer"

    local code
    for code in 124 1 130; do
        : > "$trace"
        run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PRODUCER="$producer" \
            SYSTEM_SCAN_TRACE="$trace" PRODUCER_RC="$code" \
            /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
# The timeout backend has its own real-clock tests. This case exercises the
# materializer's command boundary and complete-output contract deterministically.
run_with_timeout() {
    [[ $# -eq 2 && "$1" == 5 && "$2" == "$PRODUCER" ]] || return 99
    shift
    "$@"
}
scan_file=$(create_temp_file)
rc=0
materialize_completed_system_scan "$scan_file" 5 "$PRODUCER" || rc=$?
printf 'RC=%s\n' "$rc"
printf 'BYTES=%s\n' "$(wc -c < "$scan_file" | tr -d ' ')"
rm -f -- "$scan_file"
SCRIPT

        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"RC=$code"* ]] || return 1
        [[ "$(< "$trace")" == "started:$code" ]] || return 1
        [[ "$output" == *"BYTES=0"* ]] || return 1
    done
}

@test "materialize_completed_system_scan preserves NUL-delimited paths with newlines" {
    local producer="$HOME/newline-system-scan.sh"
    cat > "$producer" <<'SCRIPT'
#!/bin/bash
printf '/Volumes/Backup/line\nbreak.inProgress\0'
SCRIPT
    chmod +x "$producer"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PRODUCER="$producer" \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
run_with_timeout() {
    [[ $# -eq 2 && "$1" == 5 && "$2" == "$PRODUCER" ]] || return 99
    shift
    "$@"
}
scan_file=$(create_temp_file)
materialize_completed_system_scan "$scan_file" 5 "$PRODUCER"
record=""
IFS= read -r -d '' record < "$scan_file" || exit 1
[[ "$record" == $'/Volumes/Backup/line\nbreak.inProgress' ]] || exit 1
[[ "$(wc -c < "$scan_file" | tr -d ' ')" == 38 ]] || exit 1
printf 'PRESERVED\n'
rm -f -- "$scan_file"
SCRIPT

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "PRESERVED" ]]
}

@test "clean_deep_system stops later scans after its overall budget" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
calls=0
safe_sudo_find_delete() {
    calls=$((calls + 1))
    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0
    SECONDS=$((SECONDS + 121))
    return 0
}
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_deep_system
printf 'CALLS=%s\n' "$calls"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"CALLS=1"* ]] || return 1
    [[ "$output" == *"time limit reached"* ]]
}

@test "clean_deep_system propagates an interrupted privileged cleanup" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
calls=0
safe_sudo_find_delete() {
    calls=$((calls + 1))
    return 130
}
start_section_spinner() { :; }
stop_section_spinner() { :; }
rc=0
clean_deep_system || rc=$?
printf 'RC=%s\nCALLS=%s\n' "$rc" "$calls"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=130"* ]] || return 1
    [[ "$output" == *"CALLS=1"* ]]
}

@test "clean_deep_system propagates an interrupted macOS version probe" {
    run /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
safe_sudo_find_delete() {
    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0
    return 0
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 99
}
show_large_active_powerlog_notice() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
run_with_timeout() {
    local _duration="$1"
    shift
    if [[ "${1:-}" == "sw_vers" ]]; then
        printf 'SW_VERS_INTERRUPTED\n'
        return 130
    fi
    "$@"
}
rc=0
clean_deep_system || rc=$?
printf 'RC=%s\n' "$rc"
SCRIPT

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_deep_system issues safe sudo deletions" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    [[ "${1:-}" == "-n" ]] && shift
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
    echo "safe_sudo_find_delete:$1:$2:$3:$4:${5:-default}:${6:-none}:${7:-none}:${8:-none}" >> "$CALL_LOG"
    return 0
}
show_large_active_powerlog_notice() { echo "powerlog_notice" >> "$CALL_LOG"; }
safe_sudo_remove() {
    echo "safe_sudo_remove:$1" >> "$CALL_LOG"
    return 0
}
log_success() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/Library/Caches"* ]] || return 1
    [[ "$output" =~ safe_sudo_find_delete:/Library/Caches:\*\.cache:7:f:5:[0-9]+ ]] || return 1
    [[ "$output" =~ safe_sudo_find_delete:/Library/Caches:\*\.cache:7:f:5:[0-9]+:\*\.tmp:\*\.log ]] || return 1
    # Generic shared temp roots are not exact cleanup targets: age alone does
    # not authorize deleting third-party runtime state from them.
    [[ "$output" != *"safe_sudo_find_delete:/private/tmp:"* ]] || return 1
    [[ "$output" != *"safe_sudo_find_delete:/private/var/tmp:"* ]] || return 1
    [[ "$output" == *"/private/var/log"* ]] || return 1
    [[ "$output" =~ safe_sudo_find_delete:/private/var/log:\*\.log:7:f:3:[0-9]+ ]] || return 1
    [[ "$output" =~ safe_sudo_find_delete:/private/var/log:\*\.log:7:f:3:[0-9]+:\*\.gz:\*\.asl ]] || return 1
    [[ "$output" =~ safe_sudo_find_delete:/private/var/db/powerlog:\*:7:f:5:[0-9]+ ]] || return 1
    [[ "$output" == *"powerlog_notice"* ]]
}

@test "clean_deep_system does not touch /Library/Updates when directory absent" {
    run /bin/bash --noprofile --norc << 'EOF'
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
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"/Library/Updates"* ]]
}

@test "clean_deep_system cleans third-party adobe logs conservatively" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls_adobe.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        case "$2" in
            /Library/Caches) printf '%s\0' "/Library/Caches/test.log" ;;
            /private/var/log) printf '%s\0' "/private/var/log/system.log" ;;
            /Library/Logs) echo "/Library/Logs/adobegc.log" ;;
            /Library/Logs/Adobe) printf '%s\0' "/Library/Logs/Adobe/old.log" ;;
            /Library/Logs/CreativeCloud) printf '%s\0' "/Library/Logs/CreativeCloud/old.log" ;;
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
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/Adobe:*"* ]] || return 1
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/CreativeCloud:*"* ]] || return 1
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs:adobegc.log"* ]]
}

@test "clean_deep_system removes stale idleassetsd aerial downloads scoped to the temp dir (#1253)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls_idle.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

IDLE_DIR="/private/var/folders/zz/abcdef/T/com.apple.idleassetsd"
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        # Locator: enumerate idleassetsd temp dirs under the root-owned tree.
        if [[ "$2" == "/private/var/folders" ]]; then
            printf '%s\0' "$IDLE_DIR"
            return 0
        fi
        # Probe: report a stale aborted download inside that dir.
        if [[ "$2" == "$IDLE_DIR" ]]; then
            echo "$IDLE_DIR/CFNetworkDownload_abc.tmp"
            return 0
        fi
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
    if [[ "$1" == "$IDLE_DIR" ]]; then
        MOLE_SAFE_SUDO_FIND_DELETE_COUNT=1
    else
        MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0
    fi
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    # Scoped to the idleassetsd temp dir and the aborted-download name only:
    # never a bare CFNetworkDownload_*.tmp sweep across all of /private/var/folders.
    [[ "$output" == *"safe_sudo_find_delete:/private/var/folders/zz/abcdef/T/com.apple.idleassetsd:CFNetworkDownload_*.tmp"* ]] || return 1
    [[ "$output" == *"SUCCESS:Stale wallpaper downloads"* ]] || return 1
}

@test "clean_deep_system does not report idleassetsd success when no stale download exists (#1253)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/system_calls_idle_empty.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

IDLE_DIR="/private/var/folders/zz/abcdef/T/com.apple.idleassetsd"
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    if [[ "$1" == "test" ]]; then
        return 0
    fi
    if [[ "$1" == "find" ]]; then
        # Locator returns the dir, but the probe finds nothing stale in it.
        if [[ "$2" == "/private/var/folders" ]]; then
            printf '%s\0' "$IDLE_DIR"
            return 0
        fi
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
start_section_spinner() { :; }
stop_section_spinner() { :; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_find_delete:/private/var/folders/zz/abcdef/T/com.apple.idleassetsd:CFNetworkDownload_*.tmp"* ]] || return 1
    [[ "$output" != *"SUCCESS:Stale wallpaper downloads"* ]] || return 1
}

@test "clean_deep_system does not report third-party adobe log success when no old files exist" {
    run /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
CALL_LOG="$HOME/system_calls_adobe_empty.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    [[ "${1:-}" == "-n" ]] && shift
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
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
clean_browser_code_sign_clones() { :; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "/usr/bin/find" && "${2:-}" == "/private/var/folders" ]]; then
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF2

    [ "$status" -eq 0 ]
    [[ "$output" != *"SUCCESS:Third-party system logs"* ]] || return 1
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/Adobe:*"* ]] || return 1
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/CreativeCloud:*"* ]] || return 1
    [[ "$output" != *"safe_sudo_remove:/Library/Logs/adobegc.log"* ]]
}

@test "clean_deep_system does not report third-party adobe log success when deletion fails" {
    run /bin/bash --noprofile --norc << 'EOF3'
set -euo pipefail
CALL_LOG="$HOME/system_calls_adobe_fail.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    [[ "${1:-}" == "-n" ]] && shift
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
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 0; }
find() { return 0; }
clean_browser_code_sign_clones() { :; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "/usr/bin/find" && "${2:-}" == "/private/var/folders" ]]; then
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF3

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_find_delete:/Library/Logs/Adobe:*"* ]] || return 1
    [[ "$output" != *"SUCCESS:Third-party system logs"* ]]
}

@test "clean_time_machine_failed_backups exits when tmutil has no destinations" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    # The no-destinations path is silent now (debug-only); an idle Time
    # Machine section collapses instead of printing a reassurance row.
    [ -z "$output" ]
}

@test "clean_local_snapshots reports snapshot count" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() { echo "/dev/disk3s1s1 on / (apfs, local, journaled)"; }

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
    [[ "$output" == *"Time Machine local snapshots · "*"2"*"macOS removes them when space runs low"* ]] || return 1
    [[ "$output" != *"tmutil"* ]]
}

@test "clean_local_snapshots is quiet when no snapshots" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() { echo "/dev/disk3s1s1 on / (apfs, local, journaled)"; }

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

@test "clean_local_snapshots reports backup app snapshots without Time Machine (#1916)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() { echo "/dev/disk3s1s1 on / (apfs, local, journaled)"; }

defaults() { return 1; }
run_with_timeout() {
    printf '%s\n' \
        "Snapshots for disk /:" \
        "com.synology.activebackup.F0yvGv9C" \
        "com.bombich.ccc.6F2A7C1E-1D3B-4C55-9A0B-2E8F1C7D4B10" \
        "com.bombich.ccc.0B9D2E44-7A61-4F0C-8E3B-5C1A9F6D2E77.2026-11-04-020000" \
        "com.apple.os.update-MSUPrepareUpdate" \
        "com.apple.TimeMachine.2023-10-25-120000.local"
}
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ echo "ACTIVITY"; }
tm_is_running(){ echo "UNEXPECTED_TM_PROBE"; return 1; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"APFS snapshots · "*"3"*"from com.synology.activebackup and com.bombich.ccc, deleted files keep using space until removed"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"ACTIVITY"* ]] || { echo "$output"; return 1; }
    # No Time Machine configured: no Time Machine probe and no Time Machine row.
    [[ "$output" != *"UNEXPECTED_TM_PROBE"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Time Machine local snapshots"* ]] || { echo "$output"; return 1; }
}

@test "clean_local_snapshots still reports backup app snapshots during a Time Machine backup (#1916)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() { echo "/dev/disk3s1s1 on / (apfs, local, journaled)"; }

defaults() { echo "1"; }
run_with_timeout() {
    printf '%s\n' \
        "com.apple.TimeMachine.2023-10-25-120000.local" \
        "com.synology.activebackup.F0yvGv9C"
}
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ return 0; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Time Machine snapshots · skipped (backup in progress)"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"APFS snapshots · "*"1"*"from com.synology.activebackup"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Time Machine local snapshots"* ]] || { echo "$output"; return 1; }
}

@test "clean_local_snapshots prints both rows when Time Machine is configured and idle (#1916)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() { echo "/dev/disk3s1s1 on / (apfs, local, journaled)"; }

defaults() { echo "1"; }
run_with_timeout() {
    printf '%s\n' \
        "com.apple.TimeMachine.2023-10-25-120000.local" \
        "com.apple.TimeMachine.2023-10-24-120000.local" \
        "com.synology.activebackup.F0yvGv9C"
}
start_section_spinner(){ echo "START:$1"; }
stop_section_spinner(){ echo "STOP"; }
note_activity(){ :; }
tm_is_running(){ return 1; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Time Machine local snapshots · "*"2"*"macOS removes them when space runs low"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"APFS snapshots · "*"1"*"from com.synology.activebackup"* ]] || { echo "$output"; return 1; }
    # An idle Time Machine changes the spinner text in place, no stop between.
    [[ "$output" == *"START:Checking Time Machine status..."$'\n'"START:Checking local snapshots..."* ]] || { echo "$output"; return 1; }
}

@test "clean_local_snapshots lists backup app snapshots when Time Machine status is unknown (#1916)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() { echo "/dev/disk3s1s1 on / (apfs, local, journaled)"; }

defaults() { echo "1"; }
run_with_timeout() {
    printf '%s\n' \
        "com.apple.TimeMachine.2023-10-25-120000.local" \
        "com.synology.activebackup.F0yvGv9C"
}
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ return 2; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Time Machine snapshots · skipped (status unknown)"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"APFS snapshots · "*"1"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Time Machine local snapshots"* ]] || { echo "$output"; return 1; }
}

@test "clean_local_snapshots stops before listing when the Time Machine probe is interrupted (#1916)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() { echo "/dev/disk3s1s1 on / (apfs, local, journaled)"; }

defaults() { echo "1"; }
run_with_timeout() { echo "UNEXPECTED_LISTING"; }
start_section_spinner(){ :; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ return 130; }

rc=0
clean_local_snapshots || rc=$?
echo "RC=$rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=130"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"UNEXPECTED_LISTING"* ]] || { echo "$output"; return 1; }
}

@test "mole_network_volume_mounted reads the local flag of every mount table entry" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/snapshots.sh"
debug_log() { echo "DEBUG: $*"; }

LOCAL_TABLE='/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
devfs on /dev (devfs, local, nobrowse)
map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
/dev/disk5s1 on /Volumes/Disk (with) parens (apfs, local, nodev, nosuid, journaled)
devices -- file:///Users/me/Library/Containers/x/Data/ on /Users/me/DeviceFS (devicefs, local, nodev, nosuid, noowners, fskit, mounted by me)'
verdict() {
    local rc=0
    mole_network_volume_mounted || rc=$?
    echo "$1=$rc"
}
TABLE="$LOCAL_TABLE"
TABLE_RC=0
_mole_mount_table() { printf '%s\n' "$TABLE"; return "$TABLE_RC"; }
verdict local
TABLE="$LOCAL_TABLE"$'\n''//me@192.168.1.2/share on /Volumes/share (smbfs, nodev, nosuid, mounted by me)'
verdict smb
TABLE="$LOCAL_TABLE"$'\n''nas:/export on /Volumes/export (nfs, asynchronous)'
verdict nfs
TABLE="$LOCAL_TABLE"$'\n''//me@nas/share on /Volumes/share (apfs, local, copy) (smbfs, nodev, nosuid, mounted by me)'
verdict smbparen
TABLE="something this parser does not know"
verdict unknown
TABLE=""
verdict empty
TABLE="$LOCAL_TABLE"
TABLE_RC=124
verdict timeout
TABLE_RC=130
verdict signal
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local expected
    for expected in local=1 smb=0 nfs=0 smbparen=0 unknown=0 empty=0 timeout=0 signal=130; do
        [[ "$output" == *"$expected"* ]] || { echo "missing $expected"; echo "$output"; return 1; }
    done
    [[ "$output" == *"DEBUG: Snapshot rows skipped: unparsed mount table line: something this parser does not know"* ]] ||
        { echo "the unparsed line was not logged"; echo "$output"; return 1; }
}

@test "clean_local_snapshots runs no tmutil while a network share is mounted" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
_mole_mount_table() {
    printf '%s\n' '/dev/disk3s1s1 on / (apfs, local, journaled)' \
        '//me@nas/share on /Volumes/share (smbfs, nodev, nosuid, mounted by me)'
}

defaults() { echo "1"; }
run_with_timeout() { echo "UNEXPECTED_TMUTIL:$*"; }
tmutil() { echo "UNEXPECTED_TMUTIL:$*"; }
start_section_spinner(){ echo "SPINNER:$1"; }
stop_section_spinner(){ :; }
note_activity(){ :; }
tm_is_running(){ echo "UNEXPECTED_TM_PROBE"; return 1; }

clean_local_snapshots
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "large files lists snapshots with only local volumes and runs no tmutil beside a network share" {
    local review_home="$HOME/large-review-network-share"
    mkdir -p "$review_home"

    local mounts
    for mounts in local share; do
        rm -f "$review_home/tmutil.calls"
        run env HOME="$review_home" PROJECT_ROOT="$PROJECT_ROOT" MOUNTS="$mounts" \
            /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
docker() { return 1; }
defaults() { return 1; }
_mole_mount_table() {
    echo '/dev/disk3s1s1 on / (apfs, local, journaled)'
    if [[ "$MOUNTS" == share ]]; then
        echo '//me@nas/share on /Volumes/share (smbfs, nodev, nosuid, mounted by me)'
    fi
}
tmutil() {
    echo "$*" >> "$HOME/tmutil.calls"
    printf '%s\n' "Snapshots for disk /:" "com.synology.activebackup.F0yvGv9C"
}
run_with_timeout() {
    shift
    "$@"
}
check_large_file_candidates
EOF
        [ "$status" -eq 0 ] || { echo "$mounts: $output"; return 1; }
        if [[ "$mounts" == local ]]; then
            grep -qFx "listlocalsnapshots /" "$review_home/tmutil.calls" || { echo "$output"; return 1; }
            [[ "$output" == *"APFS snapshots · "*"from com.synology.activebackup"* ]] || { echo "$output"; return 1; }
        else
            [[ ! -e "$review_home/tmutil.calls" ]] || { cat "$review_home/tmutil.calls"; return 1; }
            [[ "$output" != *"snapshot"* ]] || { echo "$output"; return 1; }
            [ -z "$output" ] || { echo "$output"; return 1; }
        fi
    done
}

@test "clean_homebrew skips when cleaned recently" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole"
date +%s > "$HOME/.cache/mole/brew_last_cleanup"

brew() { return 0; }

clean_homebrew
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "brew_cleanup_ran_recently treats a stamp from the future as expired" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

stamp="$HOME/brew-stamp"
date +%s > "$stamp"
brew_cleanup_ran_recently "$stamp" || { echo "recent stamp ignored"; exit 1; }
echo $(( $(date +%s) + 2 * 86400 )) > "$stamp"
if brew_cleanup_ran_recently "$stamp"; then
    echo "future stamp counted as recent"
    exit 1
fi
echo "brew-clock ok"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"brew-clock ok"* ]]
}

@test "clean_homebrew runs cleanup with timeout stubs" {
    run /bin/bash --noprofile --norc << 'EOF'
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

@test "clean_homebrew runs cleanup even when the download cache is small" {
    # Old formula versions live in the Cellar, not in ~/Library/Caches/Homebrew,
    # so a nearly empty cache said nothing about what cleanup would free. On
    # the maintainer's Mac 881MB of 930MB was old Cellar versions.
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole" "$HOME/Library/Caches/Homebrew"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

    start_inline_spinner(){ :; }
    stop_inline_spinner(){ :; }
    note_activity(){ :; }
    run_with_timeout() {
        shift
        if [[ "$1" == "du" ]]; then
            echo "1024 $3"
            return 0
        fi
        "$@"
    }
    brew() {
        case "$1" in
            cleanup)
                echo "Removing: /opt/homebrew/Cellar/node/24.1.0... (2,011 files, 88.5MB)"
                echo "==> This operation has freed approximately 88.5MB of disk space."
                return 0
                ;;
            *) return 0 ;;
        esac
    }

    clean_homebrew
    [[ -s "$HOME/.cache/mole/brew_last_cleanup" ]] || { echo "no timestamp after success"; exit 1; }
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Homebrew cleanup"* ]] || { echo "$output"; return 1; }
}

@test "clean_homebrew leaves no timestamp when cleanup times out" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

    start_inline_spinner(){ :; }
    stop_inline_spinner(){ :; }
    note_activity(){ :; }
    run_with_timeout() {
        shift
        if [[ "$1" == "brew" && "$2" == "cleanup" ]]; then
            return 124
        fi
        "$@"
    }
    brew() { return 0; }

    clean_homebrew
    [[ ! -e "$HOME/.cache/mole/brew_last_cleanup" ]] || { echo "a timed-out cleanup was stamped"; exit 1; }
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"timed out"* ]] || { echo "$output"; return 1; }
}

@test "clean_homebrew stops on an interrupted cleanup after restoring active links" {
    # Ctrl-C while `brew cleanup` holds the terminal reaches only the child.
    # A signal stops the run once the active links are back; a plain failure
    # or a timeout leaves the stamp unset and carries on to the autoremove
    # preview.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_CURRENT_COMMAND=clean \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

TEST_BREW_PREFIX="$HOME/homebrew-interrupt"
TEST_BREW_CELLAR="$TEST_BREW_PREFIX/Cellar"
TEST_TRACE="$HOME/homebrew-interrupt.trace"
mkdir -p "$TEST_BREW_PREFIX/bin" "$TEST_BREW_CELLAR/node/26.4.0/bin" "$HOME/Library/Caches/Homebrew" "$HOME/.cache/mole"
printf '#!/bin/sh\n' > "$TEST_BREW_CELLAR/node/26.4.0/bin/node"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
debug_log() { :; }
ensure_user_file() { mkdir -p "$(dirname "$1")"; : > "$1"; }
run_with_timeout() { shift; "$@"; }
brew() {
    case "$*" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        --cellar) printf '%s\n' "$TEST_BREW_CELLAR" ;;
        "cleanup --prune=30")
            rm -f "$TEST_BREW_PREFIX/bin/node"
            return "$BREW_CLEANUP_RC"
            ;;
        "autoremove --dry-run") echo autoremove >> "$TEST_TRACE" ;;
        *) return 0 ;;
    esac
}

for BREW_CLEANUP_RC in 130 143 1 124; do
    rm -f "$HOME/.cache/mole/brew_last_cleanup" "$TEST_TRACE" "$TEST_BREW_PREFIX/bin/node"
    : > "$TEST_TRACE"
    ln -s ../Cellar/node/26.4.0/bin/node "$TEST_BREW_PREFIX/bin/node"
    MOLE_CLEAN_CANCEL_STATUS=0
    rc=0
    clean_homebrew > /dev/null || rc=$?
    restored=no
    [[ -L "$TEST_BREW_PREFIX/bin/node" ]] && restored=yes
    stamped=no
    [[ -e "$HOME/.cache/mole/brew_last_cleanup" ]] && stamped=yes
    printf 'BREW=%s RC=%s CANCEL=%s RESTORED=%s STAMPED=%s AUTOREMOVE=%s\n' \
        "$BREW_CLEANUP_RC" "$rc" "$MOLE_CLEAN_CANCEL_STATUS" "$restored" "$stamped" \
        "$(grep -c '^autoremove$' "$TEST_TRACE" || true)"
done
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"BREW=130 RC=130 CANCEL=130 RESTORED=yes STAMPED=no AUTOREMOVE=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"BREW=143 RC=143 CANCEL=143 RESTORED=yes STAMPED=no AUTOREMOVE=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"BREW=1 RC=0 CANCEL=0 RESTORED=yes STAMPED=no AUTOREMOVE=1"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"BREW=124 RC=0 CANCEL=0 RESTORED=yes STAMPED=no AUTOREMOVE=1"* ]] || { echo "$output"; return 1; }
}

@test "clean_homebrew prevents cleanup from implicitly autoremoving formulae" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole" "$HOME/Library/Caches/Homebrew"
rm -f "$HOME/.cache/mole/brew_last_cleanup"
calls="$HOME/brew_calls.log"
: > "$calls"

start_inline_spinner(){ :; }
stop_inline_spinner(){ :; }
note_activity(){ :; }
run_with_timeout() {
    local duration="$1"
    shift
    printf 'CALL:%s env_no_autoremove=%s\n' "$*" "${HOMEBREW_NO_AUTOREMOVE:-}" >> "$calls"
    if [[ "$1" == "du" ]]; then
        echo "51201 $3"
        return 0
    fi
    "$@"
}

brew() {
    case "$*" in
        "cleanup --prune=30")
            echo "Removing: package"
            return 0
            ;;
        "autoremove --dry-run")
            echo "==> Would autoremove 1 unneeded formula:"
            echo "python@3.14"
            return 0
            ;;
        "autoremove")
            echo "REAL_AUTOREMOVE"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

clean_homebrew
cat "$calls"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CALL:brew cleanup --prune=30 env_no_autoremove=1"* ]] || return 1
    [[ "$output" == *"Homebrew unused dependencies · python@3.14 · remove with"*"brew autoremove"* ]] || return 1
    [[ "$output" != *"==>"* ]] || return 1
    [[ "$output" != *"skipped"* ]] || return 1
    [[ "$output" == *"CALL:brew autoremove --dry-run"* ]] || return 1
    [[ "$output" != *"REAL_AUTOREMOVE"* ]]
}

@test "clean_homebrew restores an active Cellar link removed by cleanup (#1206)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

TEST_BREW_PREFIX="$HOME/homebrew"
TEST_BREW_CELLAR="$TEST_BREW_PREFIX/Cellar"
node_target="$TEST_BREW_CELLAR/node/26.4.0/bin/node"
npx_target="$TEST_BREW_CELLAR/node/26.4.0/bin/npx"
replacement_npx_target="$TEST_BREW_CELLAR/node/26.5.0/bin/npx"
mkdir -p "$TEST_BREW_PREFIX/bin" "$TEST_BREW_CELLAR/node/26.4.0/bin" "$TEST_BREW_CELLAR/node/26.5.0/bin" "$HOME/Library/Caches/Homebrew"
printf '#!/bin/sh\n' > "$node_target"
printf '#!/bin/sh\n' > "$npx_target"
printf '#!/bin/sh\n' > "$replacement_npx_target"
ln -s ../Cellar/node/26.4.0/bin/node "$TEST_BREW_PREFIX/bin/node"
ln -s ../Cellar/node/26.4.0/bin/npx "$TEST_BREW_PREFIX/bin/npx"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
ensure_user_file() { mkdir -p "$(dirname "$1")"; : > "$1"; }
run_with_timeout() {
    shift
    if [[ "$1" == "du" ]]; then
        echo "51201 $3"
        return 0
    fi
    "$@"
}
brew() {
    case "$*" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        --cellar) printf '%s\n' "$TEST_BREW_CELLAR" ;;
        "cleanup --prune=30")
            rm -f "$TEST_BREW_PREFIX/bin/node" "$TEST_BREW_PREFIX/bin/npx"
            ln -s ../Cellar/node/26.5.0/bin/npx "$TEST_BREW_PREFIX/bin/npx"
            ;;
        "autoremove --dry-run") : ;;
        *) return 0 ;;
    esac
}

clean_homebrew
[[ -L "$TEST_BREW_PREFIX/bin/node" ]] || exit 1
[[ "$(readlink "$TEST_BREW_PREFIX/bin/node")" == "../Cellar/node/26.4.0/bin/node" ]] || exit 1
[[ "$(readlink "$TEST_BREW_PREFIX/bin/npx")" == "../Cellar/node/26.5.0/bin/npx" ]] || exit 1
[[ -x "$node_target" || -f "$node_target" ]]
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew links · restored 1 active executable(s)"* ]] || {
        echo "$output"
        return 1
    }
}

@test "clean_homebrew does not restore a link after its Cellar target is removed (#1206)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

TEST_BREW_PREFIX="$HOME/homebrew-removed"
TEST_BREW_CELLAR="$TEST_BREW_PREFIX/Cellar"
node_target="$TEST_BREW_CELLAR/node/26.4.0/bin/node"
mkdir -p "$TEST_BREW_PREFIX/bin" "$TEST_BREW_CELLAR/node/26.4.0/bin" "$HOME/Library/Caches/Homebrew"
printf '#!/bin/sh\n' > "$node_target"
ln -s ../Cellar/node/26.4.0/bin/node "$TEST_BREW_PREFIX/bin/node"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
ensure_user_file() { mkdir -p "$(dirname "$1")"; : > "$1"; }
run_with_timeout() {
    shift
    if [[ "$1" == "du" ]]; then
        echo "51201 $3"
        return 0
    fi
    "$@"
}
brew() {
    case "$*" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        --cellar) printf '%s\n' "$TEST_BREW_CELLAR" ;;
        "cleanup --prune=30")
            rm -f "$TEST_BREW_PREFIX/bin/node" "$node_target"
            ;;
        "autoremove --dry-run") : ;;
        *) return 0 ;;
    esac
}

clean_homebrew
[[ ! -e "$TEST_BREW_PREFIX/bin/node" && ! -L "$TEST_BREW_PREFIX/bin/node" ]]
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Homebrew links · restored"* ]]
}

@test "clean_homebrew does not restore executable links outside the Cellar (#1206)" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

TEST_BREW_PREFIX="$HOME/homebrew-external"
TEST_BREW_CELLAR="$TEST_BREW_PREFIX/Cellar"
external_target="$HOME/custom-tools/node"
mkdir -p "$TEST_BREW_PREFIX/bin" "$TEST_BREW_CELLAR" "$(dirname "$external_target")" "$HOME/Library/Caches/Homebrew"
printf '#!/bin/sh\n' > "$external_target"
ln -s "$external_target" "$TEST_BREW_PREFIX/bin/node"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
ensure_user_file() { mkdir -p "$(dirname "$1")"; : > "$1"; }
run_with_timeout() {
    shift
    if [[ "$1" == "du" ]]; then
        echo "51201 $3"
        return 0
    fi
    "$@"
}
brew() {
    case "$*" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        --cellar) printf '%s\n' "$TEST_BREW_CELLAR" ;;
        "cleanup --prune=30") rm -f "$TEST_BREW_PREFIX/bin/node" ;;
        "autoremove --dry-run") : ;;
        *) return 0 ;;
    esac
}

clean_homebrew
[[ ! -e "$TEST_BREW_PREFIX/bin/node" && ! -L "$TEST_BREW_PREFIX/bin/node" ]] || exit 1
[[ -f "$external_target" ]]
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Homebrew links · restored"* ]]
}

@test "restore_homebrew_active_links rejects paths outside Homebrew bin roots" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

TEST_BREW_PREFIX="$HOME/homebrew-forged"
TEST_BREW_CELLAR="$TEST_BREW_PREFIX/Cellar"
target="$TEST_BREW_CELLAR/node/26.4.0/bin/node"
forged_link="$HOME/outside-homebrew/node"
mkdir -p "$TEST_BREW_PREFIX/bin" "$(dirname "$target")" "$(dirname "$forged_link")"
printf '#!/bin/sh\n' > "$target"

run_with_timeout() {
    shift
    "$@"
}
brew() {
    case "$*" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        --cellar) printf '%s\n' "$TEST_BREW_CELLAR" ;;
        *) return 0 ;;
    esac
}
note_activity() { :; }

BREW_ACTIVE_PREFIX="$TEST_BREW_PREFIX"
BREW_ACTIVE_CELLAR="$TEST_BREW_CELLAR"
BREW_ACTIVE_LINK_PATHS=("$forged_link")
BREW_ACTIVE_LINK_TARGETS=("$target")
BREW_ACTIVE_RESOLVED_TARGETS=("$target")

restore_homebrew_active_links
[[ ! -e "$forged_link" && ! -L "$forged_link" ]]
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Homebrew links · restored"* ]]
}

@test "root Homebrew link restoration drops to the invoking user" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

HOME=$(cd -P "$HOME" && pwd)
TEST_BREW_PREFIX="$HOME/homebrew-root-boundary"
TEST_BREW_CELLAR="$TEST_BREW_PREFIX/Cellar"
target="$TEST_BREW_CELLAR/node/26.4.0/bin/node"
link_path="$TEST_BREW_PREFIX/bin/node"
calls="$HOME/homebrew-root-boundary.calls"
mkdir -p "$TEST_BREW_PREFIX/bin" "$(dirname "$target")"
printf '#!/bin/sh\n' > "$target"

run_with_timeout() {
    shift
    "$@"
}
brew() {
    case "$*" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        --cellar) printf '%s\n' "$TEST_BREW_CELLAR" ;;
        *) return 0 ;;
    esac
}
note_activity() { :; }
is_root_user() { return 0; }
run_homebrew_link_restore_as_invoking_user() {
    printf '%s\n' "$*" >> "$calls"
    "$@"
}

SUDO_USER="brew-user"
BREW_ACTIVE_PREFIX="$TEST_BREW_PREFIX"
BREW_ACTIVE_CELLAR="$TEST_BREW_CELLAR"
BREW_ACTIVE_LINK_PATHS=("$link_path")
BREW_ACTIVE_LINK_TARGETS=("$target")
BREW_ACTIVE_RESOLVED_TARGETS=("$target")

restore_homebrew_active_links
[[ -L "$link_path" ]] || exit 1
[[ "$(readlink "$link_path")" == "$target" ]] || exit 1
grep -Fq "/bin/ln -s $target $link_path" "$calls"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew links · restored 1 active executable(s)"* ]]
}

@test "clean_homebrew dry-run previews cleanup and autoremove without removing anything" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

calls="$HOME/brew_dry_run_calls.log"
: > "$calls"
rm -f "$HOME/.cache/mole/brew_last_cleanup"

DRY_RUN=true
run_with_timeout() {
    local duration="$1"
    shift
    printf 'CALL:%s\n' "$*" >> "$calls"
    "$@"
}
brew() {
    case "$*" in
        "cleanup --prune=30 --dry-run")
            echo "Warning: Skipping aom: most recent version 3.15.1 not installed"
            echo "Would remove: /opt/homebrew/Cellar/openjdk/26.0.2.1 (549 files, 397.6MB)"
            echo "Would remove: $HOME/Library/Caches/Homebrew/wimlib--1.14.5_1 (0B)"
            echo "Would remove: $HOME/Library/Caches/Homebrew/bootsnap/d2fe (1,587 files, 14MB)"
            echo "Would remove (empty directory): /opt/homebrew/share/man/man4"
            echo "==> This operation would free approximately 411.6MB of disk space."
            return 0
            ;;
        "autoremove --dry-run")
            echo "==> Would autoremove 1 unneeded formula:"
            echo "python@3.14"
            return 0
            ;;
        "cleanup --prune=30" | "autoremove")
            echo "REAL_BREW_WRITE:$*"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

clean_homebrew
cat "$calls"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Homebrew cleanup · would free 411.6MB"* ]] || return 1
    [[ "$output" == *"    openjdk 26.0.2.1 · 397.6MB"* ]] || return 1
    [[ "$output" == *"    ~/Library/Caches/Homebrew/bootsnap/d2fe · 14MB"* ]] || return 1
    [[ "$output" != *"wimlib"* ]] || return 1
    [[ "$output" != *"Skipping"* ]] || return 1
    [[ "$output" != *"man4"* ]] || return 1
    [[ "$output" != *"Homebrew · would cleanup"* ]] || return 1
    [[ "$output" == *"Homebrew unused dependencies · python@3.14 · remove with"*"brew autoremove"* ]] || return 1
    [[ "$output" != *"Would autoremove"* ]] || return 1
    [[ "$output" == *"CALL:brew cleanup --prune=30 --dry-run"* ]] || return 1
    [[ "$output" == *"CALL:brew autoremove --dry-run"* ]] || return 1
    [[ "$output" != *$'CALL:brew cleanup --prune=30\n'* ]] || return 1
    [[ "$output" != *"REAL_BREW_WRITE"* ]]
}

@test "clean_homebrew dry-run previews nothing when the real run would skip" {
    # The real run skips within 7 days of a finished cleanup, so the preview
    # must not promise one.
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

mkdir -p "$HOME/.cache/mole"
date +%s > "$HOME/.cache/mole/brew_last_cleanup"

DRY_RUN=true
calls="$HOME/brew-calls.log"
: > "$calls"
# Pass through so the brew() stub below is what the previews reach.
run_with_timeout() {
    shift
    "$@"
}
brew() {
    echo "CALL:brew $*" >> "$calls"
    case "$*" in
        "cleanup --prune=30 --dry-run")
            echo "UNEXPECTED_CLEANUP_PREVIEW"
            return 0
            ;;
        "autoremove --dry-run")
            echo "==> Would autoremove 1 unneeded formula:"
            echo "UNEXPECTED_AUTOREMOVE_PREVIEW"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

clean_homebrew
cat "$calls"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"UNEXPECTED_CLEANUP_PREVIEW"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_AUTOREMOVE_PREVIEW"* ]] || return 1
    [[ "$output" != *"CALL:brew"* ]] || return 1
    [[ "$output" != *"Homebrew cleanup"* ]] || return 1
    [[ "$output" != *"would cleanup"* ]]
}

@test "clean_homebrew dry-run names the manual command when the cleanup preview times out" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

rm -f "$HOME/.cache/mole/brew_last_cleanup"
DRY_RUN=true
run_with_timeout() {
    local duration="$1"
    shift
    if [[ "$*" == "brew cleanup --prune=30 --dry-run" ]]; then
        return 124
    fi
    "$@"
}
brew() { return 0; }

clean_homebrew
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Homebrew cleanup preview timed out · run "* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"brew cleanup --dry-run"*" manually"* ]]
}

@test "run_with_timeout succeeds without GNU timeout" {
    run /bin/bash --noprofile --norc -c '
        set -euo pipefail
        PATH="/usr/bin:/bin"
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN
        source "'"$PROJECT_ROOT"'/lib/core/common.sh"
        run_with_timeout 1 sleep 0.1
    '
    [ "$status" -eq 0 ]
}

@test "run_with_timeout enforces timeout and returns 124" {
    run /bin/bash --noprofile --norc -c '
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
}

@test "opt_saved_state_cleanup handles missing state directory" {
    rm -rf "$HOME/Library/Saved Application State"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"App saved states optimized"* ]]
}

@test "opt_saved_state_cleanup reports a removal failure" {
    local state_dir="$HOME/Library/Saved Application State"
    mkdir -p "$state_dir/com.example.old.savedState"
    touch -t 202301010000 "$state_dir/com.example.old.savedState" 2> /dev/null || true

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
safe_remove() { return 1; }
execute_optimization saved_state_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed to remove 1 old saved state(s)"* ]]
}

@test "opt_cache_refresh reports a removal failure" {
    local cache_dir="$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
    mkdir -p "$cache_dir"
    touch "$cache_dir/test.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
qlmanage() { return 0; }
should_protect_path() { return 1; }
safe_remove() { return 1; }
execute_optimization cache_refresh
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed to remove 1 Finder cache target(s)"* ]]
}

@test "opt_cache_refresh cleans Quick Look cache" {
    mkdir -p "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
    touch "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache/test.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
execute_optimization cache_refresh
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"QuickLook thumbnails refreshed"* ]]
}

@test "get_path_size_kb returns zero for missing directory" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 /bin/bash --noprofile --norc << 'EOF'
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=0 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
size=$(get_path_size_kb "$HOME/test_size")
echo "$size"
EOF

    [ "$status" -eq 0 ]
    [ "$output" -ge 10 ]
}

@test "opt_fix_broken_configs reports fixes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

fix_broken_preferences() {
    echo 2
}

execute_optimization fix_broken_configs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Repaired 2 corrupted preference files"* ]]
}

@test "clean_deep_system cleans memory exception reports" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/memory_exception_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    # Production calls sudo -n, so without this the first argument is always "-n"
    # and every branch below falls through to the bare return.
    if [[ "${1:-}" == "-n" ]]; then shift; fi
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
    if [[ "$1" == "/private/var/db/reportmemoryexception/MemoryLimitViolations" ]]; then
        MOLE_SAFE_SUDO_FIND_DELETE_COUNT=1
    else
        MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0
    fi
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { :; }
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"reportmemoryexception/MemoryLimitViolations"* ]] || return 1
    [[ "$output" == *"-mtime +30"* ]] || return 1 # 30-day retention
    [[ "$output" == *"safe_sudo_find_delete:/private/var/db/reportmemoryexception/MemoryLimitViolations:*"* ]]
}

@test "clean_deep_system memory exception respects DRY_RUN flag" {
    # bin/clean.sh --dry-run sets both; safe_remove honours only MOLE_DRY_RUN.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_DRY_RUN=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/memory_exception_dryrun_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    # Production calls sudo -n; without stripping it every branch below is skipped.
    if [[ "${1:-}" == "-n" ]]; then shift; fi
    if [[ "$1" == "test" ]]; then
        [[ "$*" == *"/private/var/db/reportmemoryexception/MemoryLimitViolations"* ]] && return 0  # call is `sudo -n test -d <dir>`, dir is $3
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
    if [[ "$1" == "/private/var/db/reportmemoryexception/MemoryLimitViolations" ]]; then
        MOLE_SAFE_SUDO_FIND_DELETE_COUNT=1
    else
        MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0
    fi
    return 0
}
safe_sudo_remove() { return 0; }
log_success() { :; }
log_info() { echo "$*"; }
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] Would remove"* ]] || return 1
    [[ "$output" == *"1 old memory exception reports"* ]]
}

@test "clean_deep_system does not log memory exception success when nothing cleaned" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/memory_exception_success_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        [[ "$*" == *"/private/var/db/reportmemoryexception/MemoryLimitViolations"* ]] && return 0  # call is `sudo -n test -d <dir>`, dir is $3
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
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"SUCCESS:Memory exception reports"* ]]
}

@test "clean_deep_system uses one broad diagnostic log scan" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/diag_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    # Production calls sudo -n; without stripping it every branch below is skipped.
    if [[ "${1:-}" == "-n" ]]; then shift; fi
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
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_find_delete:/private/var/db/diagnostics:*"* ]] || return 1
    [[ "$output" == *"safe_sudo_find_delete:/private/var/db/DiagnosticPipeline:*"* ]] || return 1
    [[ "$output" != *"safe_sudo_find_delete:/private/var/db/diagnostics:*.tracev3"* ]]
}

@test "show_large_active_powerlog_notice reports an abnormal database in real and dry-run modes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    if [[ "${1:-}" == "$STAT_BSD" && "${2:-}" == "-f%z" && "${3:-}" == "$MOLE_ACTIVE_POWERLOG_DB_PATH" ]]; then
        echo $((10 * 1024 * 1024 * 1024))
        return 0
    fi
    return 1
}
bytes_to_human() { echo "10.00GB"; }
format_path_link() { printf '%s\n' "$1"; }

MOLE_DRY_RUN=0
live_output=$(show_large_active_powerlog_notice)
MOLE_DRY_RUN=1
dry_output=$(show_large_active_powerlog_notice)

[[ "$live_output" == "$dry_output" ]] || exit 1
printf '%s\n' "$live_output"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Power telemetry database"* ]] || return 1
    [[ "$output" == *"10.00GB"* ]] || return 1
    [[ "$output" == *"CurrentBackgroundProcessingDB.BGSQL"* ]] || return 1
    [[ "$output" == *"active, kept"* ]]
}

@test "show_large_active_powerlog_notice fails closed on small or invalid size probes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

mock_size=""
probe_succeeds=1
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    if [[ "$probe_succeeds" == "1" && "${1:-}" == "$STAT_BSD" && "${2:-}" == "-f%z" && "${3:-}" == "$MOLE_ACTIVE_POWERLOG_DB_PATH" ]]; then
        printf '%s\n' "$mock_size"
        return 0
    fi
    return 1
}

mock_size=$((10 * 1024 * 1024 * 1024 - 1))
small_output=$(show_large_active_powerlog_notice)
mock_size="not-a-size"
invalid_output=$(show_large_active_powerlog_notice)
probe_succeeds=0
failed_output=$(show_large_active_powerlog_notice)

[[ -z "$small_output" ]] || exit 1
[[ -z "$invalid_output" ]] || exit 1
[[ -z "$failed_output" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "clean_deep_system routes signing clones through current-user guarded cleanup" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
sudo() { return 1; }
safe_sudo_find_delete() { return 0; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
find() { return 0; }
run_with_timeout() { return 0; }
safe_sudo_remove() { echo "UNEXPECTED_PARENT_REMOVAL:$1"; return 1; }
clean_browser_code_sign_clones() { echo "GUARDED_CLONE_CLEANUP"; code_sign_cleaned=1; }
log_success() { echo "SUCCESS:$1"; }
clean_deep_system
SCRIPT
    [ "$status" -eq 0 ]
    [[ "$output" == *"GUARDED_CLONE_CLEANUP"* ]] || return 1
    [[ "$output" == *"SUCCESS:Browser code signature caches"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_PARENT_REMOVAL"* ]]
}

@test "clean_deep_system does not report retained clones as cleaned" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
sudo() { return 1; }
safe_sudo_find_delete() { return 0; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
find() { return 0; }
run_with_timeout() { return 0; }
clean_browser_code_sign_clones() { return 0; }
log_success() { echo "SUCCESS:$1"; }
clean_deep_system
SCRIPT
    [ "$status" -eq 0 ]
    [[ "$output" != *"SUCCESS:Browser code signature caches"* ]]
}

@test "clean_deep_system cleans CleanMyMac-observed rebuildable system caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
find() { return 0; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/Library/Caches/com.apple.iconservices.store"* ]] || return 1
    [[ "$output" == *"SUCCESS:Rebuildable system caches, 1 item"* ]]
}

@test "clean_deep_system does not report an absent rebuildable system cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
CALL_LOG="$HOME/rebuildable_cache_absent_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

safe_sudo_find_delete() {
    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0
    return 0
}
_mole_bounded_sudo() { return 1; }
safe_sudo_remove() {
    echo "UNEXPECTED_REMOVE:$1" >> "$CALL_LOG"
    return 0
}
log_success() { echo "SUCCESS:$1" >> "$CALL_LOG"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
mock_run_with_timeout_skipping_var_folders

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_REMOVE:/Library/Caches/com.apple.iconservices.store"* ]] || return 1
    [[ "$output" != *"SUCCESS:Rebuildable system caches"* ]]
}

@test "is_rebuildable_gpu_cache_dir only allows C GPU cache shards" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/com.apple.metal"
is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/com.apple.metalfe"
is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/com.apple.gpuarchiver"
! is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/T/com.example.App/com.apple.metal" || exit 1
! is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/not-a-gpu-cache" || exit 1
! is_rebuildable_gpu_cache_dir "/Library/Extensions/com.example.driver/com.apple.metal"
EOF

    [ "$status" -eq 0 ]
}

@test "gpu_cache_dir_is_stale uses contained file mtimes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
find() { return 0; }
gpu_cache_dir_is_stale() { return 0; }
clean_browser_code_sign_clones() { :; }
run_with_timeout() {
    local _timeout="$1"
    shift
    # Answer only the GPU-cache scan, which is the one carrying the com.apple.metal
    # pattern; any other /private/var/folders find must not receive this list.
    if [[ "${1:-}" == "/usr/bin/find" && "${2:-}" == "/private/var/folders" && "$*" == *"com.apple.metal"* ]]; then
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
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/C/com.example.App/com.apple.metal"* ]] || return 1
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/C/com.example.App/com.apple.metalfe"* ]] || return 1
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/C/com.example.App/com.apple.gpuarchiver"* ]] || return 1
    [[ "$output" != *"/private/var/folders/test/a/T/com.example.App/com.apple.metal"* ]] || return 1
    [[ "$output" != *"not-a-gpu-cache"* ]] || return 1
    [[ "$output" != *"-mtime +1"* ]] || return 1
    [[ "$output" == *"SUCCESS:Accessible rebuildable GPU caches, 3 items"* ]]
}

@test "clean_deep_system skips EDR/security-agent GPU caches (CrowdStrike Falcon tamper)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/gpu_cache_edr_calls.log"
> "$CALL_LOG"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

sudo() {
    if [[ "$1" == "test" ]]; then
        return 1
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
find() { return 0; }
gpu_cache_dir_is_stale() { return 0; }
clean_browser_code_sign_clones() { :; }
run_with_timeout() {
    local _timeout="$1"
    shift
    # The GPU-cache sweep is the deep walk (maxdepth 8); feed candidates only to
    # it and let every other find scan return nothing so this exercises just it.
    if [[ "${1:-}" == "/usr/bin/find" && "${4:-}" == "8" ]]; then
        printf '%s\0' \
            "/private/var/folders/test/a/C/com.crowdstrike.falcon.App/com.apple.metalfe" \
            "/private/var/folders/test/a/C/com.sentinelone.agent/com.apple.metal" \
            "/private/var/folders/test/a/C/com.example.App/com.apple.metalfe"
        return 0
    fi
    if [[ "${1:-}" == "/usr/bin/find" ]]; then
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    # The normal third-party GPU cache is still reclaimed.
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/C/com.example.App/com.apple.metalfe"* ]] || return 1
    # EDR agent caches must never be touched (tamper alert -> corporate malware report).
    [[ "$output" != *"com.crowdstrike"* ]] || return 1
    [[ "$output" != *"com.sentinelone"* ]] || return 1
    [[ "$output" == *"SUCCESS:Accessible rebuildable GPU caches, 1 item"* ]] || return 1
}

@test "opt_network_stack_optimize skips when network is healthy" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mock_bin="$HOME/network-healthy-bin"
mkdir -p "$mock_bin"
printf '#!/bin/bash\nexit 0\n' > "$mock_bin/route"
printf '#!/bin/bash\necho "ip_address: 93.184.216.34"\n' > "$mock_bin/dscacheutil"
chmod +x "$mock_bin/route" "$mock_bin/dscacheutil"
PATH="$mock_bin:$PATH"

route() {
    return 0
}
export -f route

dscacheutil() {
    echo "ip_address: 93.184.216.34"
    return 0
}
export -f dscacheutil

execute_optimization network_stack_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Network stack already optimal"* ]]
}

@test "opt_network_stack_optimize skips when VPN is active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=1 /bin/bash --noprofile --norc << 'EOF'
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

execute_optimization network_stack_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Network stack refresh skipped, active VPN detected"* ]] || return 1
    [[ "$output" != *"unexpected-route"* ]] || return 1
    [[ "$output" != *"unexpected-sudo"* ]]
}

@test "opt_network_stack_optimize flushes when network has issues" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mock_bin="$HOME/network-failure-bin"
mkdir -p "$mock_bin"
printf '#!/bin/bash\nexit 1\n' > "$mock_bin/route"
printf '#!/bin/bash\nexit 1\n' > "$mock_bin/dscacheutil"
chmod +x "$mock_bin/route" "$mock_bin/dscacheutil"
PATH="$mock_bin:$PATH"

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
execute_optimization network_stack_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Network routing table refreshed"* ]] || return 1
    [[ "$output" == *"ARP cache cleared"* ]]
}

@test "opt_disk_permissions_repair skips when permissions are fine" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

test() {
    if [[ "$1" == "-e" || "$1" == "-w" ]]; then
        return 0
    fi
    command test "$@"
}
export -f test

execute_optimization disk_permissions_repair
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"User directory permissions already optimal"* ]]
}

@test "opt_disk_permissions_repair calls diskutil when needed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

USER="not-the-home-owner"
export USER

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
execute_optimization disk_permissions_repair
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"User directory permissions repaired"* ]]
}

@test "opt_spotlight_index_optimize skips when search is fast" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

# run_with_timeout hands its command to gtimeout, which execs a binary and
# never sees the function mocks above; run it in-shell so they apply.
run_with_timeout() {
    shift
    "$@"
}

execute_optimization spotlight_index_optimize
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Spotlight index already optimal"* ]]
}

@test "software_update_pending_or_unknown fails closed and trusts only an empty RecommendedUpdates array" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

fixture_dir="$HOME/su_probe"
mkdir -p "$fixture_dir"

cat > "$fixture_dir/pending.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>RecommendedUpdates</key>
    <array>
        <dict>
            <key>Display Name</key>
            <string>macOS Update</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

cat > "$fixture_dir/empty.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>RecommendedUpdates</key>
    <array/>
</dict>
</plist>
PLIST

cat > "$fixture_dir/nokey.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LastSuccessfulDate</key>
    <string>never</string>
</dict>
</plist>
PLIST

printf 'not a plist' > "$fixture_dir/corrupt.plist"

# Queued updates block cleanup.
software_update_pending_or_unknown "$fixture_dir/pending.plist" || exit 1
# Only a readable, explicitly empty array clears the gate.
if software_update_pending_or_unknown "$fixture_dir/empty.plist"; then exit 1; fi
# Missing key, unreadable state, and a missing file all fail closed.
software_update_pending_or_unknown "$fixture_dir/nokey.plist" || exit 1
software_update_pending_or_unknown "$fixture_dir/corrupt.plist" || exit 1
software_update_pending_or_unknown "$fixture_dir/does-not-exist.plist" || exit 1
echo "GATES_OK"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"GATES_OK"* ]]
}

@test "software_update_pending_or_unknown propagates an interrupted plist probe" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
fixture="$HOME/software-update.plist"
touch "$fixture"
run_with_timeout() { return 130; }
rc=0
software_update_pending_or_unknown "$fixture" || rc=$?
printf 'RC=%s\n' "$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]]
}

@test "time_machine_candidate_still_eligible rejects replacement symlink and active backup races" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

candidate="$HOME/old.inProgress"
mkdir -p "$candidate"
deadline=$((SECONDS + 10))
expected=$(time_machine_candidate_identity "$candidate" "$deadline")
expected_mtime="${expected##*:}"
get_epoch_seconds() { echo "$((expected_mtime + 49 * 3600))"; }
tm_is_running() { return 1; }

time_machine_candidate_still_eligible "$candidate" "$expected" 48 "$deadline"

replacement="$HOME/replacement.inProgress"
mkdir -p "$replacement"
rm -rf "$candidate"
mv "$replacement" "$candidate"
if time_machine_candidate_still_eligible "$candidate" "$expected" 48 "$deadline"; then
    echo "REPLACEMENT_ACCEPTED"
    exit 1
fi

rm -rf "$candidate"
mkdir -p "$HOME/real-backup"
ln -s "$HOME/real-backup" "$candidate"
if time_machine_candidate_still_eligible "$candidate" "$expected" 48 "$deadline"; then
    echo "SYMLINK_ACCEPTED"
    exit 1
fi

rm -f "$candidate"
mkdir -p "$candidate"
expected=$(time_machine_candidate_identity "$candidate" "$deadline")
expected_mtime="${expected##*:}"
tm_is_running() { return 0; }
if time_machine_candidate_still_eligible "$candidate" "$expected" 48 "$deadline"; then
    echo "ACTIVE_ACCEPTED"
    exit 1
fi
echo "RACES_REJECTED"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RACES_REJECTED"* ]] || return 1
    [[ "$output" != *"ACCEPTED"* ]]
}

@test "macos_installer_is_apple_signed takes only Apple-signed InstallAssistant bundles" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

installer="$HOME/Install macOS Test.app"
mkdir -p "$installer/Contents"
touch "$installer/Contents/Info.plist"
deadline=$((SECONDS + 10))
BUNDLE_ID=com.apple.InstallAssistant.Seed
CODESIGN_RC=0
run_with_timeout() {
    local _duration="$1"
    shift
    case "${1:-}" in
        /usr/bin/plutil) printf '%s\n' "$BUNDLE_ID" ;;
        /usr/bin/codesign)
            [[ "$*" == *"anchor apple"* ]] || return 99
            echo "$*" >> "$HOME/codesign.calls"
            return "$CODESIGN_RC"
            ;;
        *) "$@" ;;
    esac
}

macos_installer_is_apple_signed "$installer" "$deadline" || { echo 'SIGNED_REJECTED'; exit 1; }
CODESIGN_RC=3
if macos_installer_is_apple_signed "$installer" "$deadline"; then echo 'UNSIGNED_ACCEPTED'; exit 1; fi
CODESIGN_RC=0
for BUNDLE_ID in com.example.InstallAssistant com.apple.InstallAssistantX com.apple.InstallAssistant. ''; do
    rm -f "$HOME/codesign.calls"
    if macos_installer_is_apple_signed "$installer" "$deadline"; then echo "ID_ACCEPTED:$BUNDLE_ID"; exit 1; fi
    [[ ! -e "$HOME/codesign.calls" ]] || { echo "CODESIGN_RAN:$BUNDLE_ID"; exit 1; }
done
BUNDLE_ID=com.apple.InstallAssistant
CODESIGN_RC=124
rc=0
macos_installer_is_apple_signed "$installer" "$deadline" || rc=$?
[[ $rc -eq 124 ]] || { echo "TIMEOUT_RC:$rc"; exit 1; }
rm -f "$installer/Contents/Info.plist"
if macos_installer_is_apple_signed "$installer" "$deadline"; then echo 'NO_PLIST_ACCEPTED'; exit 1; fi
echo 'APPLE_INSTALLER_ONLY'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"APPLE_INSTALLER_ONLY"* ]]
}

@test "macos_installer_candidate_still_eligible rejects invalid age replacement active and pending races" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

installer="$HOME/Install macOS Test.app"
mkdir -p "$installer/Contents"
touch "$installer/Contents/Info.plist"
deadline=$((SECONDS + 10))
expected=$(macos_installer_candidate_identity "$installer" "$deadline")
expected_mtime="${expected##*:}"
get_epoch_seconds() { echo "$((expected_mtime + 15 * 86400))"; }
software_update_pending_or_unknown() { return 1; }
macos_installer_process_is_idle() { return 0; }
macos_installer_is_apple_signed() { return 0; }
run_with_timeout() {
    local _duration="$1"
    shift
    if [[ "${1:-}" == "/usr/libexec/PlistBuddy" ]]; then
        printf '15.0\n'
        return 0
    fi
    "$@"
}

macos_installer_candidate_still_eligible "$installer" "$expected" 14 "$deadline"
macos_installer_is_apple_signed() { return 1; }
if macos_installer_candidate_still_eligible "$installer" "$expected" 14 "$deadline"; then
    echo 'UNSIGNED_ACCEPTED'
    exit 1
fi
macos_installer_is_apple_signed() { return 0; }

macos_installer_candidate_identity() { printf '1:2:0\n'; }
if macos_installer_candidate_still_eligible "$installer" '1:2:0' 14 "$deadline"; then
    echo 'INVALID_MTIME_ACCEPTED'
    exit 1
fi
unset -f macos_installer_candidate_identity
source "$PROJECT_ROOT/lib/clean/system.sh"
software_update_pending_or_unknown() { return 1; }
macos_installer_is_apple_signed() { return 0; }

replacement="$HOME/installer-replacement"
mkdir -p "$replacement/Contents"
touch "$replacement/Contents/Info.plist"
rm -rf "$installer"
mv "$replacement" "$installer"
if macos_installer_candidate_still_eligible "$installer" "$expected" 14 "$deadline"; then
    echo 'REPLACEMENT_ACCEPTED'
    exit 1
fi

expected=$(macos_installer_candidate_identity "$installer" "$deadline")
expected_mtime="${expected##*:}"
macos_installer_process_is_idle() { return 1; }
if macos_installer_candidate_still_eligible "$installer" "$expected" 14 "$deadline"; then
    echo 'ACTIVE_ACCEPTED'
    exit 1
fi
macos_installer_process_is_idle() { return 0; }
software_update_pending_or_unknown() { return 0; }
if macos_installer_candidate_still_eligible "$installer" "$expected" 14 "$deadline"; then
    echo 'PENDING_ACCEPTED'
    exit 1
fi
echo 'INSTALLER_RACES_REJECTED'
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"INSTALLER_RACES_REJECTED"* ]] || return 1
    [[ "$output" != *"ACCEPTED"* ]]
}

@test "clean never deletes Software Update-owned staging trees" {
    run grep -nE \
        'find /Library/Updates|safe_sudo_remove "/macOS Install Data"|install_data_newest_mtime|macos_installer_process_running' \
        "$PROJECT_ROOT/lib/clean/system.sh"

    [ "$status" -eq 1 ] || {
        echo "$output" >&2
        return 1
    }
}

@test "var/folders scans prune non-target containers at depth 3" {
    # find's -path is a test, not a prune: without a container-level prune the
    # GPU scan walks the entire T/ temp tree to depth 8 (measured 217k dirs /
    # 19s on a dev machine, against an 8s budget) even though only C/ can
    # match, so the step times out on every run. Signing clones now use
    # the current user root directly and need no global X/ sweep.
    run grep -cF -- '\( -depth 3 ! -name C \) -prune' "$PROJECT_ROOT/lib/clean/system.sh"
    [ "$status" -eq 0 ] || return 1
    [ "$output" -ge 1 ] || return 1

    run grep -F -- '-name "*.code_sign_clone"' "$PROJECT_ROOT/lib/clean/system.sh"
    [ "$status" -eq 1 ]
}

@test "autoremove preview is one review line naming up to three formulae" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"
preview="$HOME/autoremove-preview"
printf '==> Would autoremove 1 unneeded formula:\nllvm@22\n' > "$preview"
show_brew_autoremove_preview "$preview"
printf '==> Would autoremove 3 unneeded formulae:\nllvm@22\npython@3.13\nz\033]2;x\007std\n' > "$preview"
show_brew_autoremove_preview "$preview"
printf '==> Would autoremove 5 unneeded formulae:\na\nb\nc\nd\ne\n' > "$preview"
show_brew_autoremove_preview "$preview"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | grep -c 'Homebrew unused dependencies')" -eq 3 ] || return 1
    [[ "$output" == *"Homebrew unused dependencies · llvm@22 · remove with"* ]] || return 1
    [[ "$output" == *"· llvm@22, python@3.13, z"* ]] || return 1
    [[ "$output" != *$'\033]2;'* ]] || return 1
    [[ "$output" == *"Homebrew unused dependencies · 5 formulae · remove with"* ]] || return 1
    [[ "$output" != *"==>"* ]]
}

# Homebrew service logs. A fake prefix under the test HOME stands in for
# /opt/homebrew (or /usr/local): `brew --prefix` answers it, lsof is a shell
# function behind a pass-through run_with_timeout, and the real /opt/homebrew
# is never read.
make_brew_service_log_prefix() {
    local prefix="$HOME/brew-prefix"
    rm -rf "$prefix" "$HOME/outside-dir"
    rm -f "$HOME/outside-target.log" "$HOME/hard-twin.log" "$HOME/clean-list.txt"
    mkdir -p "$prefix/var/log/nginx/old" "$prefix/var/mysql" "$HOME/outside-dir"
    printf 'stale\n' > "$prefix/var/log/php-fpm.log"
    printf 'stale\n' > "$prefix/var/log/nginx/access.log"
    printf 'rotated\n' > "$prefix/var/log/redis.log.1"
    printf 'rotated\n' > "$prefix/var/log/nginx/error.log.2.gz"
    printf 'open\n' > "$prefix/var/log/nginx/error.log"
    printf 'fresh\n' > "$prefix/var/log/postgresql@17.log"
    printf 'notes\n' > "$prefix/var/log/notes.txt"
    printf 'deep\n' > "$prefix/var/log/nginx/old/deep.log"
    printf 'db\n' > "$prefix/var/mysql/host.err"
    printf 'db\n' > "$prefix/var/mysql/binlog.log"
    printf 'target\n' > "$HOME/outside-target.log"
    ln -s "$HOME/outside-target.log" "$prefix/var/log/link.log"
    printf 'hard\n' > "$prefix/var/log/hard.log"
    ln "$prefix/var/log/hard.log" "$HOME/hard-twin.log"
    printf 'linked\n' > "$HOME/outside-dir/inner.log"
    ln -s "$HOME/outside-dir" "$prefix/var/log/linked-dir"
    local stale
    for stale in php-fpm.log nginx/access.log redis.log.1 nginx/error.log.2.gz \
        nginx/error.log notes.txt nginx/old/deep.log hard.log; do
        touch -t 202001010000 "$prefix/var/log/$stale"
    done
    touch -t 202001010000 "$prefix/var/mysql/host.err" "$prefix/var/mysql/binlog.log" \
        "$HOME/outside-target.log" "$HOME/outside-dir/inner.log"
}

run_brew_service_log_cleanup() {
    local dry_run="$1"
    local lsof_body="$2"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN_MODE="$dry_run" \
        LSOF_BODY="$lsof_body" BREW_PREFIX="$HOME/brew-prefix" \
        /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
if [[ "$DRY_RUN_MODE" == "true" ]]; then
    DRY_RUN=true
    export MOLE_DRY_RUN=1
else
    DRY_RUN=false
    export MOLE_DRY_RUN=0
fi
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
_MOLE_COMPLETE_LSOF_MODE=direct
EXPORT_LIST_FILE="$HOME/clean-list.txt"
: > "$EXPORT_LIST_FILE"
oplog_enabled() { return 1; }
log_operation() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
brew() {
    [[ "$1" == "--prefix" ]] || return 1
    printf '%s\n' "$BREW_PREFIX"
}
eval "lsof() { $LSOF_BODY; }"
clean_homebrew_service_logs
cat "$EXPORT_LIST_FILE"
EOF2
}

@test "clean_homebrew_service_logs dry run lists only stale idle user logs" {
    make_brew_service_log_prefix
    local log_root="$HOME/brew-prefix/var/log"
    # nginx holds error.log open, as a running service does.
    run_brew_service_log_cleanup true \
        "printf 'p611\nf5\nn%s\n' \"\$HOME/brew-prefix/var/log/nginx/error.log\"; return 1"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Homebrew service logs"*"4 items"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"$log_root/php-fpm.log  #"* ]] || return 1
    [[ "$output" == *"$log_root/nginx/access.log  #"* ]] || return 1
    [[ "$output" == *"$log_root/redis.log.1  #"* ]] || return 1
    [[ "$output" == *"$log_root/nginx/error.log.2.gz  #"* ]] || return 1
    [[ "$output" != *"$log_root/nginx/error.log  #"* ]] || return 1
    [[ "$output" != *"postgresql@17.log"* ]] || return 1
    [[ "$output" != *"notes.txt"* ]] || return 1
    [[ "$output" != *"deep.log"* ]] || return 1
    [[ "$output" != *"link.log"* ]] || return 1
    [[ "$output" != *"hard.log"* ]] || return 1
    [[ "$output" != *"inner.log"* ]] || return 1
    [[ "$output" != *"mysql"* ]] || return 1
    # Dry run removes nothing.
    [[ -f "$log_root/php-fpm.log" && -f "$log_root/nginx/access.log" ]]
}

@test "clean_homebrew_service_logs removes stale logs and keeps open, fresh, linked and var state" {
    make_brew_service_log_prefix
    local log_root="$HOME/brew-prefix/var/log"
    run_brew_service_log_cleanup false \
        "local a; for a in \"\$@\"; do [[ \"\$a\" == */nginx/error.log ]] && { printf 'p611\nf5\nn%s\n' \"\$a\"; return 0; }; done; return 1"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ ! -e "$log_root/php-fpm.log" ]] || return 1
    [[ ! -e "$log_root/nginx/access.log" ]] || return 1
    [[ ! -e "$log_root/redis.log.1" ]] || return 1
    [[ ! -e "$log_root/nginx/error.log.2.gz" ]] || return 1
    [[ -f "$log_root/nginx/error.log" ]] || return 1
    [[ -f "$log_root/postgresql@17.log" ]] || return 1
    [[ -f "$log_root/notes.txt" ]] || return 1
    [[ -f "$log_root/nginx/old/deep.log" ]] || return 1
    [[ -L "$log_root/link.log" && -f "$HOME/outside-target.log" ]] || return 1
    [[ -f "$log_root/hard.log" && -f "$HOME/hard-twin.log" ]] || return 1
    [[ -L "$log_root/linked-dir" && -f "$HOME/outside-dir/inner.log" ]] || return 1
    [[ -f "$HOME/brew-prefix/var/mysql/host.err" ]] || return 1
    [[ -f "$HOME/brew-prefix/var/mysql/binlog.log" ]]
}

@test "clean_homebrew_service_logs keeps everything when the open state is unknown" {
    make_brew_service_log_prefix
    local log_root="$HOME/brew-prefix/var/log"
    # lsof diagnostics are not a reliable "nothing open". Dry run has no sink
    # probe, so this isolates the batch decision.
    run_brew_service_log_cleanup true \
        "printf 'lsof: WARNING: can not stat\n'; return 1"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -f "$log_root/php-fpm.log" && -f "$log_root/nginx/access.log" ]] || return 1
    [[ "$output" != *"Homebrew service logs"* ]] || return 1

    # A name lsof reports under another spelling matches no candidate, so
    # nothing can be ruled idle.
    run_brew_service_log_cleanup true \
        "printf 'p611\nf5\nn/OPT/HOMEBREW/var/log/nginx/error.log\n'; return 1"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"Homebrew service logs"* ]] || return 1

    # No complete process view at all.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
_MOLE_COMPLETE_LSOF_MODE=unknown
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
brew() { printf '%s\n' "$HOME/brew-prefix"; }
lsof() { return 1; }
clean_homebrew_service_logs
EOF2
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -f "$log_root/php-fpm.log" && -f "$log_root/redis.log.1" ]]
}

@test "clean_homebrew_service_logs re-checks the open state at the sink" {
    make_brew_service_log_prefix
    local log_root="$HOME/brew-prefix/var/log"
    # The batch probe (several names) reports nothing open; the per-file sink
    # probe (one name) finds php-fpm writing again.
    run_brew_service_log_cleanup false \
        "if [[ \$# -le 4 && \"\${*: -1}\" == */php-fpm.log ]]; then printf 'p9\nf3\nn%s\n' \"\${*: -1}\"; return 0; fi; return 1"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -f "$log_root/php-fpm.log" ]] || return 1
    [[ ! -e "$log_root/nginx/access.log" ]]
}

@test "clean_homebrew_service_logs honors the whitelist" {
    make_brew_service_log_prefix
    local log_root="$HOME/brew-prefix/var/log"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
_MOLE_COMPLETE_LSOF_MODE=direct
WHITELIST_PATTERNS=("$HOME/brew-prefix/var/log/nginx")
oplog_enabled() { return 1; }
log_operation() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
brew() { printf '%s\n' "$HOME/brew-prefix"; }
lsof() { return 1; }
clean_homebrew_service_logs
EOF2
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ -f "$log_root/nginx/access.log" ]] || return 1
    [[ ! -e "$log_root/php-fpm.log" ]]
}

@test "brew_service_log_is_eligible rechecks shape, depth, links, owner and age at the sink" {
    make_brew_service_log_prefix
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"
_BREW_SERVICE_LOG_ROOT="$HOME/brew-prefix/var/log"
_BREW_SERVICE_LOG_UID=$(id -u)
r="$_BREW_SERVICE_LOG_ROOT"
check() { if brew_service_log_is_eligible "$1"; then echo "yes:${1#"$r"/}"; else echo "no:${1#"$r"/}"; fi; }
check "$r/php-fpm.log"
check "$r/nginx/error.log.2.gz"
check "$r/postgresql@17.log"
check "$r/notes.txt"
check "$r/nginx/old/deep.log"
check "$r/link.log"
check "$r/hard.log"
check "$r/linked-dir/inner.log"
check "$HOME/brew-prefix/var/mysql/binlog.log"
_BREW_SERVICE_LOG_UID=$(( $(id -u) + 1 ))
check "$r/php-fpm.log"
EOF2
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local expected
    expected=$'yes:php-fpm.log\nyes:nginx/error.log.2.gz\nno:postgresql@17.log\nno:notes.txt\nno:nginx/old/deep.log\nno:link.log\nno:hard.log\nno:linked-dir/inner.log\nno:'"$HOME"$'/brew-prefix/var/mysql/binlog.log\nno:php-fpm.log'
    [[ "$output" == "$expected" ]] || { echo "$output"; return 1; }
}

@test "brew_service_log_is_eligible rejects names carrying a control character" {
    make_brew_service_log_prefix
    local log_root="$HOME/brew-prefix/var/log"
    local newline_name=$'php-fpm.log\nnginx.log'
    local tab_name=$'redis\t.log'
    printf 'stale\n' > "$log_root/$newline_name"
    printf 'stale\n' > "$log_root/nginx/$tab_name"
    touch -t 202001010000 "$log_root/$newline_name" "$log_root/nginx/$tab_name"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"
_BREW_SERVICE_LOG_ROOT="$HOME/brew-prefix/var/log"
_BREW_SERVICE_LOG_UID=$(id -u)
r="$_BREW_SERVICE_LOG_ROOT"
check() { if brew_service_log_is_eligible "$1"; then echo yes; else echo no; fi; }
check "$r/php-fpm.log"
check "$r/"$'php-fpm.log\nnginx.log'
check "$r/nginx/"$'redis\t.log'
EOF2
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == $'yes\nno\nno' ]] || { echo "$output"; return 1; }
}

@test "_brew_service_log_delete_guard refuses a parent swapped for a link before binding" {
    make_brew_service_log_prefix
    local log_root="$HOME/brew-prefix/var/log"
    mkdir -p "$HOME/swap-target"
    printf 'keep\n' > "$HOME/swap-target/access.log"
    touch -t 202001010000 "$HOME/swap-target/access.log"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"
DRY_RUN=false
_BREW_SERVICE_LOG_ROOT="$HOME/brew-prefix/var/log"
_BREW_SERVICE_LOG_UID=$(id -u)
r="$_BREW_SERVICE_LOG_ROOT"
_mole_paths_have_open_handle() { return 1; }
# Swap nginx for a link between the eligibility check and the snapshot.
eval "_orig$(declare -f _mole_snapshot_path_identity)"
_mole_snapshot_path_identity() {
    if [[ ! -L "$r/nginx" ]]; then
        mv "$r/nginx" "$r/nginx.real"
        ln -s "$HOME/swap-target" "$r/nginx"
    fi
    _orig_mole_snapshot_path_identity "$@"
}
rc=0
_brew_service_log_delete_guard "$r/nginx/access.log" || rc=$?
echo "rc=$rc bound=${_MOLE_SAFE_CLEAN_BOUND_PATH:-}"
EOF2
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "rc=1 bound=" ]] || { echo "$output"; return 1; }
    [[ -f "$HOME/swap-target/access.log" ]]
}
