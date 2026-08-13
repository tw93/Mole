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

# clean_deep_system reaches its two /private/var/folders sweeps through
# `/usr/bin/find`, which a shell-function `find` mock cannot intercept, and a
# plain "drop the timeout and run it" wrapper mock removes the production
# bound as well. Each test then walked the host's real temp tree twice,
# unbounded, for seconds. Intercept at the wrapper instead and hand back an
# empty result, the same seam the code_sign_clone and GPU-cache tests below
# already use to inject their fixtures.
mock_run_with_timeout_skipping_var_folders() {
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

@test "materialize_completed_system_scan discards a timed-out partial prefix" {
    local slow_scan="$HOME/partial-system-scan.sh"
    local trace="$HOME/partial-system-scan.trace"
    cat > "$slow_scan" <<'SCRIPT'
#!/bin/bash
printf 'started\n' >> "$SYSTEM_SCAN_TRACE"
printf 'partial\0'
exec sleep 4
SCRIPT
    chmod +x "$slow_scan"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" SLOW_SCAN="$slow_scan" \
        SYSTEM_SCAN_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"
scan_file=$(create_temp_file)
rc=0
materialize_completed_system_scan "$scan_file" 1 "$SLOW_SCAN" || rc=$?
printf 'RC=%s\n' "$rc"
printf 'BYTES=%s\n' "$(wc -c < "$scan_file" | tr -d ' ')"
rm -f -- "$scan_file"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$(< "$trace")" == "started" ]] || return 1
    [[ "$output" == *"BYTES=0"* ]]
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
scan_file=$(create_temp_file)
materialize_completed_system_scan "$scan_file" 1 "$PRODUCER"
record=""
IFS= read -r -d '' record < "$scan_file" || true
[[ "$record" == $'/Volumes/Backup/line\nbreak.inProgress' ]]
printf 'PRESERVED\n'
rm -f -- "$scan_file"
SCRIPT

    [ "$status" -eq 0 ] || return 1
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
    [[ "$output" == *"Time Machine local snapshots ·"* ]] || return 1
    [[ "$output" == *"tmutil listlocalsnapshots /"* ]]
}

@test "clean_local_snapshots is quiet when no snapshots" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"Homebrew autoremove would remove"* ]] || return 1
    [[ "$output" == *"python@3.14"* ]] || return 1
    [[ "$output" == *"Homebrew autoremove · skipped"* ]] || return 1
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
[[ -L "$TEST_BREW_PREFIX/bin/node" ]]
[[ "$(readlink "$TEST_BREW_PREFIX/bin/node")" == "../Cellar/node/26.4.0/bin/node" ]]
[[ "$(readlink "$TEST_BREW_PREFIX/bin/npx")" == "../Cellar/node/26.5.0/bin/npx" ]]
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
[[ ! -e "$TEST_BREW_PREFIX/bin/node" && ! -L "$TEST_BREW_PREFIX/bin/node" ]]
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
[[ -L "$link_path" ]]
[[ "$(readlink "$link_path")" == "$target" ]]
grep -Fq "/bin/ln -s $target $link_path" "$calls"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Homebrew links · restored 1 active executable(s)"* ]]
}

@test "clean_homebrew dry-run shows brew autoremove preview without removing formulae" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

calls="$HOME/brew_dry_run_calls.log"
: > "$calls"

DRY_RUN=true
run_with_timeout() {
    local duration="$1"
    shift
    printf 'CALL:%s\n' "$*" >> "$calls"
    "$@"
}
brew() {
    case "$*" in
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
    [[ "$output" == *"Homebrew · would cleanup"* ]] || return 1
    [[ "$output" == *"Homebrew autoremove would remove"* ]] || return 1
    [[ "$output" == *"python@3.14"* ]] || return 1
    [[ "$output" == *"CALL:brew autoremove --dry-run"* ]] || return 1
    [[ "$output" != *"CALL:brew cleanup --prune=30"* ]] || return 1
    [[ "$output" != *"REAL_AUTOREMOVE"* ]]
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
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

@test "clean_deep_system cleans code_sign_clone caches via safe_sudo_remove" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
find() { return 0; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "/usr/bin/find" && "${2:-}" == "/private/var/folders" ]]; then
        printf '%s\0' "/private/var/folders/test/a/X/demo.code_sign_clone"
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/X/demo.code_sign_clone"* ]] || return 1
    [[ "$output" == *"SUCCESS:Browser code signature caches"* ]]
}

@test "clean_deep_system skips code_sign_clone success when removal fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
find() { return 0; }
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "/usr/bin/find" && "${2:-}" == "/private/var/folders" ]]; then
        printf '%s\0' "/private/var/folders/test/a/X/demo.code_sign_clone"
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/X/demo.code_sign_clone"* ]] || return 1
    [[ "$output" != *"SUCCESS:Browser code signature caches"* ]]
}

@test "clean_deep_system skips EDR code_sign clones (CrowdStrike Falcon tamper)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
CALL_LOG="$HOME/edr_code_sign_calls.log"
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
run_with_timeout() {
    local _timeout="$1"
    shift
    if [[ "${1:-}" == "/usr/bin/find" && "${2:-}" == "/private/var/folders" ]]; then
        printf '%s\0' \
            "/private/var/folders/test/a/X/com.crowdstrike.falcon.App.code_sign_clone" \
            "/private/var/folders/test/a/X/demo.code_sign_clone"
        return 0
    fi
    "$@"
}

clean_deep_system
cat "$CALL_LOG"
EOF

    [ "$status" -eq 0 ]
    # A normal (browser-style) code-sign clone is still reclaimed.
    [[ "$output" == *"safe_sudo_remove:/private/var/folders/test/a/X/demo.code_sign_clone"* ]] || return 1
    # The EDR agent's code-sign clone must never be deleted.
    [[ "$output" != *"com.crowdstrike"* ]] || return 1
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
! is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/T/com.example.App/com.apple.metal"
! is_rebuildable_gpu_cache_dir "/private/var/folders/test/a/C/com.example.App/not-a-gpu-cache"
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
run_with_timeout() {
    local _timeout="$1"
    shift
    # Answer only the GPU-cache scan. Matching on the bare "find /private/var/folders"
    # prefix also swallowed the code_sign_clone sweep, which then received this GPU
    # list and removed every entry in it, including the /T/ path this test asserts is
    # never touched.
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

macos_installer_candidate_identity() { printf '1:2:0\n'; }
if macos_installer_candidate_still_eligible "$installer" '1:2:0' 14 "$deadline"; then
    echo 'INVALID_MTIME_ACCEPTED'
    exit 1
fi
unset -f macos_installer_candidate_identity
source "$PROJECT_ROOT/lib/clean/system.sh"
software_update_pending_or_unknown() { return 1; }

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
    # match, so the step times out on every run. Same shape for the X/-only
    # code-sign scan. Pin both prunes.
    run grep -cF -- '\( -depth 3 ! -name C \) -prune' "$PROJECT_ROOT/lib/clean/system.sh"
    [ "$status" -eq 0 ] || return 1
    [ "$output" -ge 1 ] || return 1

    run grep -cF -- '\( -depth 3 ! -name X \) -prune' "$PROJECT_ROOT/lib/clean/system.sh"
    [ "$status" -eq 0 ] || return 1
    [ "$output" -ge 1 ]
}

@test "clean_homebrew_tmp_staged removes leftover .staged cask staging trees" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

TEST_BREW_PREFIX="$HOME/homebrew"
STAGED_ROOT="$TEST_BREW_PREFIX/var/homebrew/tmp/.caskroom"
mkdir -p "$STAGED_ROOT/docker-desktop/4.86.0,236216/Docker.app/Contents"
mkdir -p "$STAGED_ROOT/lark/7.72.9,f0c167f0"
printf 'payload' > "$STAGED_ROOT/docker-desktop/4.86.0,236216/Docker.app/Contents/Info.plist"
printf 'payload' > "$STAGED_ROOT/lark/7.72.9,f0c167f0/app"
ln -s "$STAGED_ROOT/docker-desktop/4.86.0,236216" "$STAGED_ROOT/docker-desktop/4.86.0,236216.staged"
ln -s "$STAGED_ROOT/lark/7.72.9,f0c167f0" "$STAGED_ROOT/lark/7.72.9,f0c167f0.staged"

pgrep() { return 1; }
run_with_timeout() { shift; "$@"; }
brew() {
    case "${1:-}" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        *) return 0 ;;
    esac
}

clean_homebrew_tmp_staged > "$HOME/staged_cleanup.out" 2>&1

[[ ! -e "$STAGED_ROOT/docker-desktop/4.86.0,236216" ]] || { echo "docker target still present" >&2; exit 1; }
[[ ! -L "$STAGED_ROOT/docker-desktop/4.86.0,236216.staged" ]] || { echo "docker .staged link still present" >&2; exit 1; }
[[ ! -e "$STAGED_ROOT/lark/7.72.9,f0c167f0" ]] || { echo "lark target still present" >&2; exit 1; }
[[ ! -L "$STAGED_ROOT/lark/7.72.9,f0c167f0.staged" ]] || { echo "lark .staged link still present" >&2; exit 1; }
grep -q "Homebrew cask staging · removed 2 leftover(s)" "$HOME/staged_cleanup.out" || { echo "missing summary: $(cat "$HOME/staged_cleanup.out")" >&2; exit 1; }
EOF

    [ "$status" -eq 0 ]
}

@test "clean_homebrew_tmp_staged is a no-op without staged leftovers" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

TEST_BREW_PREFIX="$HOME/homebrew"
mkdir -p "$TEST_BREW_PREFIX/var/homebrew/tmp/.caskroom/docker-desktop/4.83.0,234302"

pgrep() { return 1; }
run_with_timeout() { shift; "$@"; }
brew() {
    case "${1:-}" in
        --prefix) printf '%s\n' "$TEST_BREW_PREFIX" ;;
        *) return 0 ;;
    esac
}

clean_homebrew_tmp_staged
[[ -d "$TEST_BREW_PREFIX/var/homebrew/tmp/.caskroom/docker-desktop/4.83.0,234302" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}
