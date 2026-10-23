#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home home
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "$HOME/.config"
    mkdir -p "$HOME"
}

@test "mo_spinner_chars returns centered 2x2 sequence" {
    result="$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; mo_spinner_chars")"
    [ "$result" = $'⠖\n⠲\n⠴\n⠦' ]
}

@test "detect_architecture maps current CPU to friendly label" {
    expected="Intel"
    if [[ "$(uname -m)" == "arm64" ]]; then
        expected="Apple Silicon"
    fi
    result="$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; detect_architecture")"
    [ "$result" = "$expected" ]
}

@test "get_free_space returns a non-empty value" {
    result="$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; get_free_space")"
    [[ -n "$result" ]]
}

@test "get_free_space uses decimal formatting from df kilobytes" {
    local mock_bin="$HOME/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/df" <<'MOCK'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk1 200000000 126599680 73400320 64%% /\n'
MOCK
    chmod +x "$mock_bin/df"

    output="$(
        HOME="$HOME" PATH="$mock_bin:$PATH" /bin/bash --noprofile --norc <<'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
get_free_space_kb
get_free_space
format_free_space_kb 73400320
format_free_space_kb invalid
format_free_space_delta_kb 1024
format_free_space_delta_kb -1024
EOF
    )"

    lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done <<< "$output"

    [ "${lines[0]}" = "73400320" ]
    [ "${lines[1]}" = "75.16GB" ]
    [ "${lines[2]}" = "75.16GB" ]
    [ "${lines[3]}" = "Unknown" ]
    [ "${lines[4]}" = "+1.0MB" ]
    [ "${lines[5]}" = "-1.0MB" ]
}

@test "cleanup_result_color_kb always returns green" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

small_kb=1
large_kb=$(((MOLE_ONE_GB_BYTES * 2) / 1024))

if [[ "$(cleanup_result_color_kb "$small_kb")" == "$GREEN" ]] &&
    [[ "$(cleanup_result_color_kb "$large_kb")" == "$GREEN" ]]; then
    echo "ok"
fi
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "mole_is_reverse_dns_bundle_id rejects defaults domains and glob-like ids" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

for valid in "com.example.App" "andriiliakh.Artpaper" "dev.zed.Zed-Nightly" "org.keepassxc.KeePassXC"; do
    mole_is_reverse_dns_bundle_id "$valid" || {
        echo "valid rejected: $valid"
        exit 1
    }
done

for invalid in "-g" "NSGlobalDomain" "com-example" "com.foo.*" "com.foo.[abc]" "unknown" ""; do
    if mole_is_reverse_dns_bundle_id "$invalid"; then
        echo "invalid accepted: $invalid"
        exit 1
    fi
done
EOF

    [ "$status" -eq 0 ]
}

@test "mole_name_has_bundle_id_boundary rejects sibling bundle prefixes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

bundle_id="com.example.TestApp"

for valid in \
    "com.example.TestApp.plist" \
    "com.example.TestApp.helper.plist" \
    "/tmp/com.example.TestApp.pkg.bom"; do
    mole_name_starts_with_bundle_id_boundary "$valid" "$bundle_id" || {
        echo "valid start boundary rejected: $valid"
        exit 1
    }
done

for invalid in \
    "group.com.example.TestApp" \
    "TEAM.com.example.TestApp.FileProvider" \
    "com.example.TestApplication.plist"; do
    if mole_name_starts_with_bundle_id_boundary "$invalid" "$bundle_id"; then
        echo "sibling start boundary accepted: $invalid"
        exit 1
    fi
done

for valid in \
    "com.example.TestApp.plist" \
    "com.example.TestApp.helper.plist" \
    "group.com.example.TestApp" \
    "TEAM.com.example.TestApp.FileProvider" \
    "/tmp/com.example.TestApp.pkg.bom"; do
    mole_name_has_bundle_id_boundary "$valid" "$bundle_id" || {
        echo "valid boundary rejected: $valid"
        exit 1
    }
done

for invalid in \
    "com.example.TestApplication.plist" \
    "group.com.example.TestApplication" \
    "xcom.example.TestApp" \
    "com.example.TestAppHelper.plist" \
    "com-example-TestApp.plist"; do
    if mole_name_has_bundle_id_boundary "$invalid" "$bundle_id"; then
        echo "sibling boundary accepted: $invalid"
        exit 1
    fi
done
EOF

    [ "$status" -eq 0 ]
}

@test "log_info prints message and appends to log file" {
    local message="Informational message from test"
    local stdout_output
    stdout_output="$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; log_info '$message'")"
    [[ "$stdout_output" == *"$message"* ]] || return 1

    local log_file="$HOME/Library/Logs/mole/mole.log"
    [[ -f "$log_file" ]] || return 1
    grep -q "INFO: $message" "$log_file"
}

@test "log_error writes to stderr and log file" {
    local message="Something went wrong"
    local stderr_file="$HOME/log_error_stderr.txt"

    HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; log_error '$message' 1>/dev/null 2>'$stderr_file'"

    [[ -s "$stderr_file" ]] || return 1
    grep -q "$message" "$stderr_file"

    local log_file="$HOME/Library/Logs/mole/mole.log"
    [[ -f "$log_file" ]] || return 1
    grep -q "ERROR: $message" "$log_file"
}

@test "log_operation recreates operations log if the log directory disappears mid-session" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
rm -rf "$HOME/Library/Logs/mole"
log_operation "clean" "REMOVED" "/tmp/example" "1KB"
EOF
    [ "$status" -eq 0 ]

    local oplog="$HOME/Library/Logs/mole/operations.log"
    [[ -f "$oplog" ]] || return 1
    grep -Fq "[clean] REMOVED /tmp/example (1KB)" "$oplog"
}

@test "should_protect_path protects Mole runtime logs" {
    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc -c \
            'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$HOME/Library/Logs/mole/operations.log" && echo protected || echo not-protected'
    )"
    [ "$result" = "protected" ]
}

@test "should_protect_path protects wallpaper and aerial assets" {
    local path result
    for path in \
        "$HOME/Library/Application Support/com.apple.idleassetsd" \
        "$HOME/Library/Application Support/com.apple.idleassetsd/Customer/video.mov" \
        "/Library/Application Support/com.apple.idleassetsd/Customer/video.mov" \
        "$HOME/Library/Application Support/com.apple.wallpaper/aerials/video.mov" \
        "$HOME/Library/Application Support/com.apple.wallpaper/aerials/thumbnails/video.png"; do
        result=$(HOME="$HOME" TARGET_PATH="$path" /bin/bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo protected || echo unprotected')
        [ "$result" = "protected" ] || return 1
    done

    path="$HOME/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/rebuildable.bin"
    result=$(HOME="$HOME" TARGET_PATH="$path" /bin/bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo protected || echo unprotected')
    [ "$result" = "unprotected" ]
}

@test "should_protect_path protects Calendar data and cache paths (#1508)" {
    local path result
    for path in \
        "$HOME/Library/Calendars" \
        "$HOME/Library/Calendars/Calendar Cache" \
        "$HOME/Library/Calendars/Calendar Cache-shm" \
        "$HOME/Library/Calendars/Calendar Cache-wal" \
        "$HOME/Library/Calendars/01234567-89AB-CDEF-0123-456789ABCDEF"; do
        result=$(HOME="$HOME" TARGET_PATH="$path" /bin/bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo protected || echo unprotected')
        [ "$result" = "protected" ] || return 1
    done
}

@test "xcode_build_tooling_process_state recognizes command-line build owners" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
pgrep() {
    [[ "$1" == -*x && "|$2|" == *"|xcodebuild|"* ]]
}
xcode_build_tooling_process_state
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "xcode_build_tooling_process_state reports unknown on probe errors and missing pgrep" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
pgrep() { return 2; }
process_state=0
xcode_build_tooling_process_state || process_state=$?
[[ "$process_state" -eq 2 ]] || exit 2
unset -f pgrep
PATH=/nonexistent
process_state=0
xcode_build_tooling_process_state || process_state=$?
[[ "$process_state" -eq 2 ]] || exit 3
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "Xcode and CoreSimulator process probes each run one pgrep" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
rm -f "$HOME/pgrep-calls"
pgrep() { printf x >> "$HOME/pgrep-calls"; return 1; }
calls() { wc -c < "$HOME/pgrep-calls" | tr -d ' '; }
debug_log() { :; }
process_state=0
xcode_build_tooling_process_state || process_state=$?
[[ "$process_state" -eq 1 && "$(calls)" -eq 1 ]] || { echo "xcode calls=$(calls) state=$process_state"; exit 1; }
rm -f "$HOME/pgrep-calls"; process_state=0
_coresimulator_cache_process_running || process_state=$?
[[ "$process_state" -eq 1 && "$(calls)" -eq 1 ]] || { echo "simulator calls=$(calls) state=$process_state"; exit 1; }
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "xcode_build_tooling_process_state reports reliable no-match" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
pgrep() { return 1; }
process_state=0
xcode_build_tooling_process_state || process_state=$?
[[ "$process_state" -eq 1 ]]
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "rotate_log_once only checks log size once per session" {
    local log_file="$HOME/Library/Logs/mole/mole.log"
    mkdir -p "$(dirname "$log_file")"
    if command -v mkfile > /dev/null 2>&1; then
        mkfile -n 1100k "$log_file"
    else
        truncate -s 1100k "$log_file"
    fi

    # log.sh calls rotate_log_once at source time and exports MOLE_LOG_ROTATED.
    # scripts/test.sh sources file_ops.sh, so the whole bats run already carries the
    # marker and a child would skip rotation. Clear it to get a fresh session.
    env -u MOLE_LOG_ROTATED HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'"
    [[ -f "${log_file}.old" ]] || return 1

    result=$(HOME="$HOME" MOLE_LOG_ROTATED=1 /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_LOG_ROTATED")
    [[ "$result" == "1" ]]
}

@test "drain_pending_input clears stdin buffer under the system Bash" {
    run /bin/bash --noprofile --norc <<'EOF'
export MOLE_BASE_LOADED=1
source "$PROJECT_ROOT/lib/core/ui.sh"
printf 'test\ninput' | {
    drain_pending_input
    if IFS= read -r -s -n 1 -t 1 remaining; then
        printf 'LEAK:%s\n' "$remaining"
    else
        printf 'DRAINED\n'
    fi
}
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "DRAINED" ]
}

@test "drain_pending_input still drains when the optional Perl helper fails" {
    run /bin/bash --noprofile --norc <<'EOF'
export MOLE_BASE_LOADED=1
source "$PROJECT_ROOT/lib/core/ui.sh"
_mole_drain_with_perl() { return 127; }
printf 'pending\n' | {
    drain_pending_input
    if IFS= read -r -s -n 1 -t 1 remaining; then
        printf 'LEAK:%s\n' "$remaining"
    else
        printf 'DRAINED\n'
    fi
}
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "DRAINED" ]
}

@test "drain_pending_input retains the byte bound under the system Bash" {
    run /bin/bash --noprofile --norc <<'EOF'
export MOLE_BASE_LOADED=1
source "$PROJECT_ROOT/lib/core/ui.sh"
printf '%0101dZ' 0 | {
    drain_pending_input
    IFS= read -r -s -n 1 -t 1 remaining || exit 1
    printf 'REMAINING:%s\n' "$remaining"
}
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "REMAINING:Z" ]
}

@test "drain_pending_input does not wait a second for each idle pipe" {
    run python3 - <<'PY'
import subprocess

script = '''
export MOLE_BASE_LOADED=1
source "$PROJECT_ROOT/lib/core/ui.sh"
for ((i=0; i<10; i++)); do drain_pending_input; done
printf 'DONE\\n'
'''
process = subprocess.Popen(
    ["/bin/bash", "--noprofile", "--norc", "-c", script],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
try:
    # Keep the writer open and empty: EOF would make even a long read timeout
    # return immediately and would not test the idle wait.
    process.wait(timeout=3)
    assert process.returncode == 0
    assert process.stdout.read() == b"DONE\n"
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    process.stdin.close()
    process.stdout.close()
    process.stderr.close()
PY
    [ "$status" -eq 0 ]
}

@test "drain_pending_input does not stall a terminal when Perl fails" {
    run python3 - <<'PY'
import os
import pty
import subprocess
import time

script = '''
export MOLE_BASE_LOADED=1
source "$PROJECT_ROOT/lib/core/ui.sh"
_mole_drain_with_perl() { return 127; }
for ((i=0; i<3; i++)); do drain_pending_input; done
printf 'DONE\\n'
'''
master, slave = pty.openpty()
process = None
try:
    started = time.monotonic()
    process = subprocess.Popen(
        ["/bin/bash", "--noprofile", "--norc", "-c", script],
        stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    stdout, stderr = process.communicate(timeout=10)
    elapsed = time.monotonic() - started
    assert process.returncode == 0, (stdout, stderr)
    assert stdout == b"DONE\n", (stdout, stderr)
    # The integer fallback blocks one second per call on an idle terminal.
    assert elapsed < 1.5, elapsed
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    os.close(slave)
PY
    [ "$status" -eq 0 ]
}

@test "drain_pending_input clears terminal input and preserves terminal settings" {
    run python3 - <<'PY'
import os
import pty
import subprocess
import termios

script = '''
export MOLE_BASE_LOADED=1
source "$PROJECT_ROOT/lib/core/ui.sh"
drain_pending_input 0.1
printf 'DONE\\n'
'''
for pending in [b"\n", b"\x1b[A"]:
    master, slave = pty.openpty()
    process = None
    try:
        original = termios.tcgetattr(slave)
        os.write(master, pending)
        process = subprocess.Popen(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode == 0, (stdout, stderr)
        assert stdout == b"DONE\n", (pending, stdout, stderr)
        restored = termios.tcgetattr(slave)
        # Darwin's transient input-reprocessing bit is not a mode change.
        original[3] &= ~getattr(termios, "PENDIN", 0)
        restored[3] &= ~getattr(termios, "PENDIN", 0)
        assert restored == original, (original, restored)
        # Read the remaining kernel queue directly. A second Bash read can
        # flush queued input while setting its own modes and mask a failed drain.
        probe = termios.tcgetattr(slave)
        probe[3] &= ~(termios.ICANON | termios.ECHO)
        probe[6][termios.VMIN] = 0
        probe[6][termios.VTIME] = 0
        termios.tcsetattr(slave, termios.TCSANOW, probe)
        remaining = os.read(slave, 1024)
        assert remaining == b"", (pending, remaining)
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
PY
    [ "$status" -eq 0 ]
}

@test "mole_ascii_lowercase matches LC_ALL=C tr byte for byte" {
    run /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
while IFS= read -r sample; do
    expected=$(printf '%s' "$sample" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    actual=""
    mole_ascii_lowercase actual "$sample"
    [[ "$actual" == "$expected" ]] || { printf 'MISMATCH [%s] [%s] [%s]\n' "$sample" "$actual" "$expected"; exit 1; }
done << 'SAMPLES'
com.Apple.SystemSettings
Zed Nightly
ÄÖÜ Café ÉCOLE
微信 WeChat
[A-Z]*?{Glob}
  Leading And Trailing  

SAMPLES
echo OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = OK ]
}

@test "is_root_user answers from EUID without forking id" {
    run /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
id() { echo called >> "$HOME/id-calls"; command id "$@"; }
rc=0
is_root_user || rc=$?
expected=1
[[ "$(command id -u)" == "0" ]] && expected=0
[[ $rc -eq $expected ]] || { echo "RC=$rc EXPECTED=$expected"; exit 1; }
[[ ! -e "$HOME/id-calls" ]] || { echo "FORKED_ID"; exit 1; }
echo OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = OK ]
}

@test "is_critical_system_component ignores case and leaves nocasematch as it was" {
    run /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
for token in com.apple.SystemSettings "System Preferences" LoginItems com.apple.TCC ControlCenter; do
    is_critical_system_component "$token" || { echo "MISSED $token"; exit 1; }
done
for token in com.example.app Slack "Visual Studio Code"; do
    ! is_critical_system_component "$token" || { echo "FLAGGED $token"; exit 1; }
done
shopt -q nocasematch && { echo "LEFT_ON"; exit 1; }
shopt -s nocasematch
is_critical_system_component "LoginItems" || exit 1
shopt -q nocasematch || { echo "TURNED_OFF"; exit 1; }
echo OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = OK ]
}

@test "bytes_to_human converts byte counts into readable units" {
    output="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
bytes_to_human 512
bytes_to_human 2000
bytes_to_human 5000000
bytes_to_human 3000000000
EOF
    )"

    bytes_lines=()
    while IFS= read -r line; do
        bytes_lines+=("$line")
    done <<< "$output"

    [ "${bytes_lines[0]}" = "512B" ]
    [ "${bytes_lines[1]}" = "2KB" ]
    [ "${bytes_lines[2]}" = "5.0MB" ]
    [ "${bytes_lines[3]}" = "3.00GB" ]
}

@test "percent_encode_path encodes spaces and multibyte characters per byte" {
    output="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
percent_encode_path "/Users/x/Library/Application Support/中文 dir"
printf '\n'
percent_encode_path "/plain/path-1.2_3~ok"
printf '\n'
EOF
    )"

    encode_lines=()
    while IFS= read -r line; do
        encode_lines+=("$line")
    done <<< "$output"

    [ "${encode_lines[0]}" = "/Users/x/Library/Application%20Support/%E4%B8%AD%E6%96%87%20dir" ]
    [ "${encode_lines[1]}" = "/plain/path-1.2_3~ok" ]
}

@test "format_path_link falls back to plain tilde path without a TTY" {
    output="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
format_path_link "$HOME/Library/Application Support/MobileSync/Backup"
printf '\n'
EOF
    )"

    # Captured output is not a TTY, so no OSC 8 escapes may leak into pipes.
    # shellcheck disable=SC2088  # literal tilde is the expected display form
    [ "$output" = "~"'/Library/Application Support/MobileSync/Backup' ]
}

@test "format_path_link shows a short label inside a link to the full path" {
    output="$(
        HOME="$HOME" MOLE_ANSI_SUPPORTED_CACHE=0 /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
format_path_link "$HOME/Library/Application Support/MobileSync/Backup" "…/MobileSync/Backup"
EOF
    )"

    local st=$'\033\\'
    local expected_link="]8;;file://$HOME/Library/Application%20Support/MobileSync/Backup${st}"
    [[ "$output" == *"$expected_link…/MobileSync/Backup"$'\033'* ]] || { printf '%q\n' "$output"; return 1; }
    [[ "$output" != *"${st}~/Library"* ]] || { printf '%q\n' "$output"; return 1; }
}

@test "format_path_link keeps the full path in plain text despite a short label" {
    output="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
format_path_link "$HOME/Library/Application Support/MobileSync/Backup" "…/MobileSync/Backup"
printf '\n'
EOF
    )"

    # Without a link nothing carries the full path, so the label is ignored.
    # shellcheck disable=SC2088  # literal tilde is the expected display form
    [ "$output" = "~"'/Library/Application Support/MobileSync/Backup' ]
}

@test "colorize_human_size colors dry-run size units by suffix" {
    output="$(
        env -u NO_COLOR HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
colorize_human_size "1.00GB"
printf '\n'
colorize_human_size "5.0MB"
printf '\n'
colorize_human_size "180KB"
printf '\n'
colorize_human_size "0B"
printf '\n'
colorize_human_size "3.27GB+"
printf '\n'
EOF
    )"

    color_lines=()
    while IFS= read -r line; do
        color_lines+=("$line")
    done <<< "$output"

    [ "${color_lines[0]}" = $'\033[0;31m1.00GB\033[0m' ]
    [ "${color_lines[1]}" = $'\033[0;33m5.0MB\033[0m' ]
    [ "${color_lines[2]}" = $'\033[0;32m180KB\033[0m' ]
    [ "${color_lines[3]}" = $'\033[0;38;5;244m0B\033[0m' ] || return 1
    # A lower-bound total keeps its unit's color.
    [ "${color_lines[4]}" = $'\033[0;31m3.27GB+\033[0m' ]
}

@test "muted text avoids theme-defined ANSI bright black" {
	run grep -R -I -nF '0;90m' \
        "$PROJECT_ROOT/lib" \
        "$PROJECT_ROOT/bin" \
        "$PROJECT_ROOT/mole" \
        "$PROJECT_ROOT/cmd/analyze"

    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "mole_pgrep_any distinguishes active, inactive, and unknown probes" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

pgrep() {
    case "$2" in
        active) return 0 ;;
        missing) return 1 ;;
        broken) return 2 ;;
    esac
    return 1
}

mole_pgrep_any -x missing -f active
set +e
mole_pgrep_any -x missing -f absent
inactive_rc=$?
mole_pgrep_any -x missing -f broken
unknown_rc=$?
set -e
printf 'inactive=%s unknown=%s\n' "$inactive_rc" "$unknown_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"inactive=1 unknown=2"* ]]
}

@test "mole_darwin_user_cache_root validates trusted getconf output" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

resolver_mode=valid
run_with_timeout() {
    [[ "$2" == "/usr/bin/getconf" && "$3" == "DARWIN_USER_CACHE_DIR" ]] || return 3
    case "$resolver_mode" in
        valid) printf '/var/folders/example/C/\n' ;;
        relative) printf 'tmp/cache\n' ;;
        traversal) printf '/var/folders/../private\n' ;;
        root) printf '/\n' ;;
        timeout) return 124 ;;
    esac
}

valid=$(mole_darwin_user_cache_root)
relative_rc=0
traversal_rc=0
root_rc=0
timeout_rc=0
resolver_mode=relative
mole_darwin_user_cache_root > /dev/null 2>&1 || relative_rc=$?
resolver_mode=traversal
mole_darwin_user_cache_root > /dev/null 2>&1 || traversal_rc=$?
resolver_mode=root
mole_darwin_user_cache_root > /dev/null 2>&1 || root_rc=$?
resolver_mode=timeout
mole_darwin_user_cache_root > /dev/null 2>&1 || timeout_rc=$?
printf 'valid=%s relative=%s traversal=%s root=%s timeout=%s\n' \
    "$valid" "$relative_rc" "$traversal_rc" "$root_rc" "$timeout_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"valid=/var/folders/example/C relative=1 traversal=1 root=1 timeout=124"* ]]
}

@test "mole_go_cache_root validates owner output and propagates timeout" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

go() { :; }
resolver_mode=valid
run_with_timeout() {
    [[ "$2" == "go" && "$3" == "env" ]] || return 3
    case "$resolver_mode:$4" in
        valid:GOCACHE) printf '%s/custom-go-build/\n' "$HOME" ;;
        valid:GOMODCACHE) printf '%s/custom-go-mod/\n' "$HOME" ;;
        relative:*) printf 'tmp/go-cache\n' ;;
        traversal:*) printf '%s/cache/../private\n' "$HOME" ;;
        broad:*) printf '%s/go\n' "$HOME" ;;
        timeout:*) return 124 ;;
    esac
}

build=$(mole_go_cache_root GOCACHE)
module=$(mole_go_cache_root GOMODCACHE)
relative_rc=0
traversal_rc=0
broad_rc=0
timeout_rc=0
resolver_mode=relative
mole_go_cache_root GOCACHE > /dev/null 2>&1 || relative_rc=$?
resolver_mode=traversal
mole_go_cache_root GOCACHE > /dev/null 2>&1 || traversal_rc=$?
resolver_mode=broad
mole_go_cache_root GOMODCACHE > /dev/null 2>&1 || broad_rc=$?
resolver_mode=timeout
mole_go_cache_root GOCACHE > /dev/null 2>&1 || timeout_rc=$?
printf 'build=%s module=%s relative=%s traversal=%s broad=%s timeout=%s\n' \
    "$build" "$module" "$relative_rc" "$traversal_rc" "$broad_rc" "$timeout_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"build=$HOME/custom-go-build module=$HOME/custom-go-mod relative=1 traversal=1 broad=1 timeout=124"* ]]
}

@test "mole_deno_cache_root accepts narrow absolute roots and rejects unsafe ones" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

default=$(mole_deno_cache_root)
DENO_DIR="$HOME/custom-deno/"
custom=$(mole_deno_cache_root)
relative_rc=0
traversal_rc=0
broad_rc=0
DENO_DIR="tmp/deno"
mole_deno_cache_root > /dev/null 2>&1 || relative_rc=$?
DENO_DIR="$HOME/cache/../deno"
mole_deno_cache_root > /dev/null 2>&1 || traversal_rc=$?
DENO_DIR="$HOME/Library/Caches"
mole_deno_cache_root > /dev/null 2>&1 || broad_rc=$?
printf 'default=%s custom=%s relative=%s traversal=%s broad=%s\n' \
    "$default" "$custom" "$relative_rc" "$traversal_rc" "$broad_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"default=$HOME/Library/Caches/deno custom=$HOME/custom-deno relative=1 traversal=1 broad=1"* ]]
}

@test "create_temp_file and create_temp_dir are tracked and cleaned" {
    HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
create_temp_file > "$HOME/temp_file_path.txt"
create_temp_dir > "$HOME/temp_dir_path.txt"
cleanup_temp_files
EOF

    file_path="$(cat "$HOME/temp_file_path.txt")"
    dir_path="$(cat "$HOME/temp_dir_path.txt")"
    [ ! -e "$file_path" ]
    [ ! -e "$dir_path" ]
    rm -f "$HOME/temp_file_path.txt" "$HOME/temp_dir_path.txt"
}


@test "should_protect_data protects system and critical apps" {
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.apple.Safari' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.clash.app' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'io.github.clash-verge-rev.clash-verge-rev' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.amnezia.awg' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.wireguard.macos' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.example.RegularApp' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]
}

# Regression: CUPS prefs have a bundle-ID-style name but no parent .app,
# so the orphan sweep deleted them and users lost their default printer
# and recent-printer list. See #731.
@test "should_protect_data protects CUPS printing prefs (#731)" {
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.cups.PrintingPrefs' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.cups.printers' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]
}

@test "should_protect_data protects Codex runtime identifiers" {
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'Codex' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.openai.codex' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'codex-runtimes' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    local codex_runtimes_path="$HOME/.cache/codex-runtimes"
    result=$(HOME="$HOME" TARGET_PATH="$codex_runtimes_path" /bin/bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo "protected" || echo "not-protected"')
    [ "$result" = "protected" ]

    for codex_state_path in \
        "$HOME/Library/Application Support/Codex/Cache/index" \
        "$HOME/Library/Logs/com.openai.codex/codex.log" \
        "$HOME/.codex/sessions/2026/06/session.jsonl" \
        "$HOME/.codex/cache/session_index.jsonl" \
        "$HOME/.codex/cache/codex_app_directory/index.json" \
        "$HOME/.codex/state_5.sqlite" \
        "$HOME/.codex/logs_2.sqlite"; do
        result=$(HOME="$HOME" TARGET_PATH="$codex_state_path" /bin/bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo "protected" || echo "not-protected"')
        [ "$result" = "protected" ]
    done
}

@test "should_protect_data covers Raycast wildcard variants" {
    for id in com.raycast.macos com.raycast.shared com.raycast.macos.BrowserExtension com.raycast-x.macos; do
        result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data '$id' && echo 'protected' || echo 'not-protected'")
        [ "$result" = "protected" ]
    done

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.raycastfoo.bar' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]
}

@test "should_protect_path protects NetworkExtension VPN preferences" {
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_path '/Volumes/Data/Library/Preferences/com.apple.networkextension.plist' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    local user_network_ext_pref="$HOME/Library/Preferences/com.apple.networkextension.necp.plist"
    result=$(HOME="$HOME" TARGET_PATH="$user_network_ext_pref" /bin/bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo "protected" || echo "not-protected"')
    [ "$result" = "protected" ]
}

@test "input methods are protected during cleanup but allowed for uninstall" {
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.tencent.inputmethod.QQInput' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.sogou.inputmethod.pinyin' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.tencent.inputmethod.QQInput' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.inputmethod.SCIM' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]
}

@test "Karabiner-Elements is protected during cleanup but allowed for uninstall" {
    # Keyboard config and preferences stay protected during clean
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.pqrs.Karabiner-Elements.Settings' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    # But the app itself is a third-party app, not a system component, so it can be uninstalled
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'org.pqrs.Karabiner-Elements.Settings' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # The main app bundle id (the actual `mo uninstall --list` key) behaves the same:
    # removable from uninstall, still data-protected during clean.
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'org.pqrs.Karabiner-Elements' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.pqrs.Karabiner-Elements' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]
}

@test "Apple apps from App Store can be uninstalled (Issue #386)" {
    # Xcode should NOT be protected from uninstall
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.dt.Xcode' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # Final Cut Pro should NOT be protected from uninstall
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.FinalCutPro' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # GarageBand should NOT be protected from uninstall
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.GarageBand' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # iWork apps should NOT be protected from uninstall
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.iWork.Pages' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # But Safari (system app) should still be protected
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.Safari' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    # And Finder should still be protected
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.finder' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]
}

@test "print_summary_block formats output correctly" {
    result=$(HOME="$HOME" /bin/bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; print_summary_block 'success' 'Test Summary' 'Detail 1' 'Detail 2'")
    [[ "$result" == *"Test Summary"* ]] || return 1
    [[ "$result" == *"Detail 1"* ]] || return 1
    [[ "$result" == *"Detail 2"* ]]
}

@test "start_inline_spinner and stop_inline_spinner work in non-TTY" {
    result=$(HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
MOLE_SPINNER_PREFIX="  " start_inline_spinner "Testing..."
sleep 0.1
stop_inline_spinner
echo "done"
EOF
    )
    [[ "$result" == *"done"* ]]
}

@test "start_inline_spinner ignores PATH-provided sleep in TTY mode" {
    if ! /usr/bin/script -q /dev/null /usr/bin/true < /dev/null > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi

    local fake_bin="$HOME/fake-bin"
    local marker="$HOME/fake-sleep.marker"

    mkdir -p "$fake_bin"
    cat > "$fake_bin/sleep" <<EOF
#!/bin/bash
echo "fake" >> "$marker"
exec /bin/sleep "\$@"
EOF
    chmod +x "$fake_bin/sleep"

    PATH="$fake_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" \
        /usr/bin/script -q /dev/null /bin/bash --noprofile --norc -c \
        "source \"\$PROJECT_ROOT/lib/core/common.sh\"; start_inline_spinner \"Testing...\"; /bin/sleep 0.15; stop_inline_spinner" \
        < /dev/null > /dev/null 2>&1

    [ ! -f "$marker" ]
}

@test "start_inline_spinner emits complete UTF-8 frames in C locale" {
    if ! /usr/bin/script -q /dev/null /usr/bin/true < /dev/null > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi

    local raw="$HOME/spinner-c-locale.raw"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" TERM=xterm-256color LC_ALL=C \
        /usr/bin/script -q "$raw" /bin/bash --noprofile --norc -c \
        'source "$PROJECT_ROOT/lib/core/common.sh"; start_inline_spinner "Testing..."; /bin/sleep 0.95; stop_inline_spinner' \
        < /dev/null > /dev/null 2>&1

    /usr/bin/iconv -f UTF-8 -t UTF-8 "$raw" > /dev/null || return 1
    raw_content="$(cat "$raw")"
    # The old byte-slicing implementation emitted invalid UTF-8 here. Do not
    # require a full animation cycle: CI startup time can consume part of this
    # bounded capture even though the spinner itself is healthy.
    [[ "$raw_content" == *"⠖"* ]]
}

@test "update_inline_spinner_message returns 1 without an active spinner" {
    run /bin/bash --noprofile --norc -c \
        "source '$PROJECT_ROOT/lib/core/common.sh'; update_inline_spinner_message 'New text'"
    [ "$status" -eq 1 ]
}

@test "update_inline_spinner_message swaps a live TTY spinner's text in place" {
    if ! /usr/bin/script -q /dev/null /usr/bin/true < /dev/null > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi

    local raw="$HOME/spinner-update.raw"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    # -F flushes each write, so the inner shell can watch its own frames.
    PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" TERM=xterm-256color RAW="$raw" \
        /usr/bin/script -qF "$raw" /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/lib/core/common.sh"
            # A loaded runner can take longer than a fixed sleep to draw the
            # next frame, so wait for the text itself, up to 3 s.
            wait_for_frame() {
                local tries=0
                until /usr/bin/grep -q "$1" "$RAW" 2> /dev/null || [[ $tries -ge 30 ]]; do
                    /bin/sleep 0.1
                    tries=$((tries + 1))
                done
            }
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Phase one..."
            pid_before="$INLINE_SPINNER_PID"
            control_dir="$INLINE_SPINNER_CONTROL_DIR"
            control_mode=$(/usr/bin/stat -f%Lp "$control_dir")
            [[ "$INLINE_SPINNER_MSG_FILE" == "$control_dir/message" && "$control_mode" == "700" ]] && echo "CONTROL_PRIVATE"
            wait_for_frame "Phase one"
            update_inline_spinner_message "Phase two..." || echo "UPDATE_FAILED"
            wait_for_frame "Phase two"
            pid_after="$INLINE_SPINNER_PID"
            stop_inline_spinner
            [[ "$pid_before" == "$pid_after" && -n "$pid_before" ]] && echo "PID_STABLE"
        ' < /dev/null > /dev/null 2>&1

    raw_content="$(cat "$raw")"
    [[ "$raw_content" == *"Phase one..."* ]] || return 1
    [[ "$raw_content" == *"Phase two..."* ]] || return 1
    [[ "$raw_content" != *"UPDATE_FAILED"* ]] || return 1
    [[ "$raw_content" == *"PID_STABLE"* ]] || return 1
    [[ "$raw_content" == *"CONTROL_PRIVATE"* ]] || return 1
}

@test "update_progress_if_needed updates spinner text without restarting it" {
    if ! /usr/bin/script -q /dev/null /usr/bin/true < /dev/null > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi

    local raw="$HOME/spinner-progress.raw"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" TERM=xterm-256color \
        /usr/bin/script -q "$raw" /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/lib/core/common.sh"
            start_section_spinner "Scanning items... 0/10"
            pid_before="$INLINE_SPINNER_PID"
            last_tick=0
            update_progress_if_needed 5 10 last_tick 1
            pid_after="$INLINE_SPINNER_PID"
            /bin/sleep 0.2
            stop_inline_spinner
            [[ "$pid_before" == "$pid_after" && -n "$pid_before" ]] && echo "PID_STABLE"
        ' < /dev/null > /dev/null 2>&1

    raw_content="$(cat "$raw")"
    # This case failed once on a CI runner and could not be reproduced in
    # about 70 local runs; print the PTY capture so the next failure explains
    # itself instead of being retuned blind.
    [[ "$raw_content" == *"Scanning items... 5/10"* ]] || { cat -v "$raw"; return 1; }
    [[ "$raw_content" == *"PID_STABLE"* ]] || { cat -v "$raw"; return 1; }
}

@test "update_progress_if_needed reads the epoch clock once per shell" {
    local calls="$HOME/epoch-calls"
    local spins="$HOME/spinner-text"
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env PROJECT_ROOT="$PROJECT_ROOT" CALLS="$calls" SPINS="$spins" \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/lib/core/common.sh"
            get_epoch_seconds() { printf "x\n" >> "$CALLS"; echo 1000000; }
            start_section_spinner() { printf "%s\n" "$1" >> "$SPINS"; }
            last_tick=0
            for i in 1 2 3 4 5 6 7 8 9 10; do
                update_progress_if_needed "$i" 10 last_tick 60 || true
            done
            echo "last_tick=$last_tick"
        '
    [ "$status" -eq 0 ]
    [[ "$(wc -l < "$calls" | tr -d ' ')" == "1" ]] || return 1
    [[ "$(cat "$spins")" == "Scanning items... 1/10" ]] || return 1
    [[ "$output" == "last_tick=1000000" || "$output" == "last_tick=1000001" ]]
}

@test "update_progress_if_needed lets the shell clock advance the throttle" {
    local spins="$HOME/spinner-advance"
    # The epoch is read once and frozen by the stub, so only $SECONDS can move
    # the clock. Jump it instead of sleeping: the throttle must hold inside the
    # interval, then fire once the clock passes it.
    # shellcheck disable=SC2016  # inner bash expands these from its environment
    run env PROJECT_ROOT="$PROJECT_ROOT" SPINS="$spins" \
        /bin/bash --noprofile --norc -c '
            source "$PROJECT_ROOT/lib/core/common.sh"
            get_epoch_seconds() { echo 1000000; }
            start_section_spinner() { printf "%s\n" "$1" >> "$SPINS"; }
            SECONDS=100
            last_tick=0
            update_progress_if_needed 1 10 last_tick 60 || exit 11
            rc=0
            update_progress_if_needed 2 10 last_tick 60 || rc=$?
            [[ $rc -eq 1 ]] || exit 12
            SECONDS=$((SECONDS + 100))
            update_progress_if_needed 3 10 last_tick 60 || exit 13
            echo "last_tick=$last_tick"
        '
    [ "$status" -eq 0 ] || { echo "status=$status"; return 1; }
    [[ "$output" =~ ^last_tick=[0-9]+$ ]] || return 1
    [ "${output#last_tick=}" -ge 1000100 ] || return 1
    [[ "$(cat "$spins")" == $'Scanning items... 1/10\nScanning items... 3/10' ]]
}

@test "safe_clear_lines emits the same erase sequence per line to the target device" {
    local out="$HOME/clear-lines.out"
    run /bin/bash --noprofile --norc -c \
        "export MOLE_ANSI_SUPPORTED_CACHE=0; source '$PROJECT_ROOT/lib/core/common.sh'; safe_clear_lines 2 '$out'"
    [ "$status" -eq 0 ]

    expected="$(printf '\033[1A\r\033[2K\033[1A\r\033[2K')"
    [ "$(cat "$out")" = "$expected" ]
}

@test "read_key maps j/k/h/l to navigation" {
    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'j' | read_key"
    [ "$output" = "DOWN" ]

    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'k' | read_key"
    [ "$output" = "UP" ]

    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'h' | read_key"
    [ "$output" = "LEFT" ]

    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'l' | read_key"
    [ "$output" = "RIGHT" ]
}

@test "read_key maps uppercase J/K/H/L to navigation" {
    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'J' | read_key"
    [ "$output" = "DOWN" ]

    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'K' | read_key"
    [ "$output" = "UP" ]
}

@test "read_key maps gg to TOP and a lone g to OTHER" {
    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; printf 'gg' | read_key"
    [ "$output" = "TOP" ]

    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; printf 'g' | read_key"
    [ "$output" = "OTHER" ]
}

@test "read_key gg works on macOS default Bash 3.2 (fractional read -t rejected)" {
    # macOS ships /bin/bash 3.2.57, which rejects fractional `read -t` timeouts.
    # Exercise the shortcut under that exact interpreter when present so the
    # portability regression is caught on macOS even if bats runs under bash 4+.
    [[ -x /bin/bash ]] || skip "/bin/bash not available"
    local major
    major=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2> /dev/null || echo 99)
    [[ "$major" -lt 4 ]] || skip "/bin/bash is not a 3.x build"

    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; printf 'gg' | read_key"
    [ "$output" = "TOP" ]
}

@test "read_key decodes physical paging and home keys in navigation and text modes" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash <<'EOF'
export MOLE_BASE_LOADED=1
source "$PROJECT_ROOT/lib/core/ui.sh"
for mode in 0 1; do
    export MOLE_READ_KEY_FORCE_CHAR=$mode
    for pair in '5~ LEFT' '6~ RIGHT' 'H TOP' 'F BOTTOM' '1~ TOP' '4~ BOTTOM' '7~ TOP' '8~ BOTTOM'; do
        sequence=${pair%% *}
        expected=${pair#* }
        actual=$(printf '\033[%s' "$sequence" | read_key)
        [[ "$actual" == "$expected" ]] || exit 1
    done
done
EOF
    [ "$status" -eq 0 ]
}

@test "truncate_by_display_width prints strings that look like echo options" {
    run /bin/bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; truncate_by_display_width '-n' 10; truncate_by_display_width '-e' 10"
    [ "$status" -eq 0 ]
    [ "$output" = $'-n\n-e' ]
}

@test "read_key respects MOLE_READ_KEY_FORCE_CHAR" {
    run /bin/bash -c "export MOLE_BASE_LOADED=1; export MOLE_READ_KEY_FORCE_CHAR=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'j' | read_key"
    [ "$output" = "CHAR:j" ]
}

@test "read_key keeps Ctrl-C as quit when forcing printable characters" {
    run /bin/bash -c "export MOLE_BASE_LOADED=1; export MOLE_READ_KEY_FORCE_CHAR=1; source '$PROJECT_ROOT/lib/core/ui.sh'; printf '\\003' | read_key"
    [ "$output" = "QUIT" ]
}

@test "ensure_sudo_session returns 1 and sets MOLE_SUDO_ESTABLISHED=false in test mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'SCRIPT'
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
MOLE_SUDO_ESTABLISHED=""
ensure_sudo_session "Test prompt" && rc=0 || rc=$?
echo "EXIT=$rc"
echo "FLAG=$MOLE_SUDO_ESTABLISHED"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=1"* ]] || return 1
    [[ "$output" == *"FLAG=false"* ]]
}

@test "sudo helpers do not invoke sudo in no-auth test mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'SCRIPT'
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
sudo() {
    echo "SUDO_CALLED:$*" >&2
    exit 99
}
export -f sudo

has_sudo_session && has_rc=0 || has_rc=$?
request_sudo_access "Test prompt" && request_rc=0 || request_rc=$?
ensure_sudo_session "Test prompt" && ensure_rc=0 || ensure_rc=$?

echo "HAS=$has_rc"
echo "REQUEST=$request_rc"
echo "ENSURE=$ensure_rc"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"HAS=1"* ]] || return 1
    [[ "$output" == *"REQUEST=1"* ]] || return 1
    [[ "$output" == *"ENSURE=1"* ]] || return 1
    [[ "$output" != *"SUDO_CALLED"* ]]
}

@test "ensure_sudo_session short-circuits to 0 when session already established" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
has_sudo_session() { return 0; }
export -f has_sudo_session
MOLE_SUDO_ESTABLISHED="true"
ensure_sudo_session "Test prompt"
echo "EXIT=$?"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=0"* ]]
}

@test "adopt_sudo_session starts keepalive for cached sudo" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"

sudo() {
    printf 'SUDO:%s\n' "$*"
    [[ "${1:-}" == "-n" && "${2:-}" == "-v" ]]
}
_start_sudo_keepalive() {
    echo "keepalive-pid"
}
_stop_sudo_keepalive() { :; }

adopt_sudo_session
echo "EXIT=$?"
echo "FLAG=$MOLE_SUDO_ESTABLISHED"
echo "PID=$MOLE_SUDO_KEEPALIVE_PID"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"SUDO:-n -v"* ]] || return 1
    [[ "$output" == *"EXIT=0"* ]] || return 1
    [[ "$output" == *"FLAG=true"* ]] || return 1
    [[ "$output" == *"PID=keepalive-pid"* ]]
}

# A cleanup lib sourced without an entry point must not abort on an unset
# DRY_RUN: the read sites are unguarded by convention, so the default lives in
# base.sh. Reproduces the "DRY_RUN: unbound variable" abort from lib/clean/caches.sh.
@test "cleanup libs run under set -u without an entry point assigning DRY_RUN" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
[[ "${DRY_RUN:-unset}" != "unset" ]] || { echo "DRY_RUN still unset after sourcing common.sh"; exit 1; }
echo "DRY_RUN=$DRY_RUN"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY_RUN=false"* ]]
}

@test "Trash refusal stops the spinner with stdout redirected and clears only a terminal stderr" {
    if ! /usr/bin/script -q /dev/null /usr/bin/true < /dev/null > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi
    local raw="$HOME/trash-spinner.raw"
    local fixture="$HOME/trash-spinner.sh"
    cat > "$fixture" <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
export MOLE_DELETE_MODE=trash
mkdir -p "$HOME/spinner-victim"
_mole_move_to_trash() { return "$MOLE_ERR_PRIVACY_DENIED"; }
start_inline_spinner "Cleaning fixture..."
/bin/sleep 0.15
rc=0
mole_delete "$HOME/spinner-victim" false > /dev/null || rc=$?
after="$INLINE_SPINNER_PID"
printf 'AFTER:%s:%s\n' "$rc" "$after" >&2
stop_inline_spinner
start_inline_spinner "Second fixture..."
/bin/sleep 0.15
stop_inline_spinner 2> "$HOME/non-tty-stop"
/bin/sleep 0.15
[[ $rc -eq $MOLE_ERR_PRIVACY_DENIED && -z "$after" && -d "$HOME/spinner-victim" ]] || exit 1
[[ ! -s "$HOME/non-tty-stop" ]] || exit 1
SCRIPT
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM=xterm-256color \
        /usr/bin/script -q "$raw" /bin/bash --noprofile --norc "$fixture" < /dev/null
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    python3 - "$raw" <<'PY'
import pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes().replace(b'\r\n', b'\n')
assert b'Cleaning fixture...' in raw, raw
assert b'\r\x1b[2KError:' in raw, raw
assert b'AFTER:14:\n' in raw, raw
assert b'Cleaning fixture...' not in raw.split(b'Error:', 1)[1], raw
PY
}

@test "loading Mole appends /usr/sbin and /sbin to a PATH without them" {
    run env -i HOME="$HOME" PATH="/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
echo "PATH=$PATH"
command -v diskutil
bash -c 'command -v lsof'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"PATH=/usr/bin:/bin:/usr/sbin:/sbin"* ]] || return 1
    [[ "$output" == *"/usr/sbin/diskutil"* ]] || return 1
    [[ "$output" == *"/usr/sbin/lsof"* ]] || return 1

    run env -i HOME="$HOME" PATH="/sbin:/usr/bin:/usr/sbin:/bin" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
echo "PATH=$PATH"
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "PATH=/sbin:/usr/bin:/usr/sbin:/bin" ]]
}

@test "sysctl never resolves through PATH (#1804)" {
    # sysctl lives in /usr/sbin, which a shell PATH may leave out; the lookup
    # then fails and every caller falls back silently. Shell calls go through
    # $SYSCTL_CMD (or the literal /usr/sbin/sysctl), Go through the absolute path.
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
start='(^|[[:space:];(|&`"'"'"']|[$][(])'
pattern="${start}sysctl[[:space:]]"
for probe in '    n=$(sysctl -n hw.ncpu 2> /dev/null || echo 4)' '    sysctl -n vm.swapusage 2> /dev/null || true'; do
    printf '%s\n' "$probe" | grep -qE "$pattern" || { echo "matcher missed: $probe"; exit 1; }
done
for allowed in '    n=$("$SYSCTL_CMD" -n hw.ncpu)' '    [[ "$(/usr/sbin/sysctl -n hw.optional.arm64)" == "1" ]]'; do
    if printf '%s\n' "$allowed" | grep -qE "$pattern"; then
        echo "matcher flagged: $allowed"
        exit 1
    fi
done
matched=$(find "$PROJECT_ROOT/lib" "$PROJECT_ROOT/bin" -name '*.sh' -print0 |
    xargs -0 grep -nE "$pattern" "$PROJECT_ROOT/mole" "$PROJECT_ROOT/install.sh" |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -n "$matched" ]]; then
    echo "sysctl resolved through PATH: $matched"
    exit 1
fi
go_matched=$(find "$PROJECT_ROOT/cmd" -name '*.go' ! -name '*_test.go' -print0 | xargs -0 grep -n '"sysctl"' || true)
if [[ -n "$go_matched" ]]; then
    echo "Go sysctl resolved through PATH: $go_matched"
    exit 1
fi
echo "clean"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "clean" ]]
}

@test "BSD-only stat, date, find and tr forms never resolve through PATH (#1196, #1752)" {
    # GNU coreutils earlier in PATH reads stat -f as file-system status and
    # date -r/-j differently, so these calls go through $STAT_BSD and
    # $_DATE_CMD; GNU find reads `-depth 2` as a path, so use -mindepth/-maxdepth. Match the command position, skip comment lines, and prove
    # the matcher fires on a known positive.
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
# A command word starts after a separator, an opening quote or $( ; an
# absolute /usr/bin/find is the BSD binary and may use -depth N.
start='(^|[[:space:];(|&`"'"'"']|[$][(])'
pattern="${start}(stat[[:space:]]+-|date[[:space:]]+-[A-Za-z]*[jrv]|find[^|;]*[[:space:]]-depth[[:space:]]+[0-9])"
for probe in '    age=$(( now - $(stat -f %m "$d") ))' '    -exec stat -f "%z" {} +' '    d=$(date -r "$n" +%F)' "    'find \"\$1\" -type d -depth 2'"; do
    printf '%s\n' "$probe" | grep -qE "$pattern" || { echo "matcher missed: $probe"; exit 1; }
done
printf '%s\n' '    x=$("$STAT_BSD" -f%m "$f")' | grep -qE "$pattern" && { echo "matcher flagged STAT_BSD"; exit 1; }
printf '%s\n' '    /usr/bin/find /private/var/folders -type d \( -depth 3 ! -name C \) -prune' | grep -qE "$pattern" && { echo "matcher flagged the system find"; exit 1; }
# Join backslash-continued lines first: `run_with_timeout 5 stat \` with the
# flag on the next line slipped past a per-line match once.
joined=$(find "$PROJECT_ROOT/lib" "$PROJECT_ROOT/bin" -name '*.sh' -print0 |
    xargs -0 awk 'FNR == 1 { buf = "" } /\\$/ { if (buf == "") start = FNR; buf = buf substr($0, 1, length($0) - 1) " "; next } { if (buf != "") { print FILENAME ":" start ":" buf $0; buf = "" } else print FILENAME ":" FNR ":" $0 }' \
        "$PROJECT_ROOT/mole" "$PROJECT_ROOT/install.sh")
printf '%s\n' 'x.sh:1:    run_with_timeout 5 stat -f%m "$e"' | grep -qE ":.*$pattern" || { echo "matcher missed a joined line"; exit 1; }
matched=$(printf '%s\n' "$joined" | grep -E "$pattern" |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -n "$matched" ]]; then
    echo "BSD-only flags resolved through PATH: $matched"
    exit 1
fi
# GNU tr folds case byte by byte, so outside LC_ALL=C a locale-aware fold
# (É to é in an app name) needs the system tr.
tr_pattern="${start}tr[[:space:]]+'\[:(upper|lower):\]'"
printf '%s\n' "    lower=\$(printf '%s' \"\$n\" | tr '[:upper:]' '[:lower:]')" | grep -qE "$tr_pattern" || { echo "tr matcher missed"; exit 1; }
tr_matched=$(printf '%s\n' "$joined" | grep -E "$tr_pattern" | grep -v 'LC_ALL=C tr' |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -n "$tr_matched" ]]; then
    echo "locale case folding resolved through PATH tr: $tr_matched"
    exit 1
fi
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "has_full_disk_access reports denied when protected paths exist but cannot be read" {
    mkdir -p "$HOME/Library/Mail/V10" "$HOME/Library/Messages"
    : > "$HOME/Library/Messages/chat.db"
    chmod 000 "$HOME/Library/Mail/V10" "$HOME/Library/Messages/chat.db"

    run env HOME="$HOME" /bin/bash --noprofile --norc -c "
source '$PROJECT_ROOT/lib/core/common.sh'
unset MOLE_HAS_FDA
rc=0
has_full_disk_access || rc=\$?
printf '%s:%s\n' \"\$rc\" \"\$MOLE_HAS_FDA\"
"
    chmod 755 "$HOME/Library/Mail/V10"
    chmod 644 "$HOME/Library/Messages/chat.db"
    rm -rf "$HOME/Library"

    # stat succeeds on a TCC-protected path without Full Disk Access, so only
    # listing a folder or opening a file proves the terminal can read it.
    [ "$output" = "1:0" ]
}

@test "has_full_disk_access reports granted when a protected path can be read" {
    mkdir -p "$HOME/Library/Mail/V10"

    run env HOME="$HOME" /bin/bash --noprofile --norc -c "
source '$PROJECT_ROOT/lib/core/common.sh'
unset MOLE_HAS_FDA
rc=0
has_full_disk_access || rc=\$?
printf '%s:%s\n' \"\$rc\" \"\$MOLE_HAS_FDA\"
"
    rm -rf "$HOME/Library"

    [ "$output" = "0:1" ]
}

@test "has_full_disk_access reports unknown when no protected path exists" {
    rm -rf "$HOME/Library"

    run env HOME="$HOME" /bin/bash --noprofile --norc -c "
source '$PROJECT_ROOT/lib/core/common.sh'
unset MOLE_HAS_FDA
rc=0
has_full_disk_access || rc=\$?
printf '%s:%s\n' \"\$rc\" \"\$MOLE_HAS_FDA\"
"

    [ "$output" = "2:unknown" ]
}
