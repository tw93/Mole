#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-home.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    ROOMY_TEST_MODE=1
    export ROOMY_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    export TERM="xterm-256color"
    rm -rf "${HOME:?}"/*
    rm -rf "$HOME/Library" "$HOME/.config"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/roomy"
    unset TEST_MOCK_BIN
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
    TEST_MOCK_BIN="$HOME/bin"
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

    run env HOME="$HOME" ROOMY_TEST_MODE=1 PATH="$test_path" \
        "$PROJECT_ROOT/roomy" clean --dry-run
}

@test "roomy clean --dry-run skips system cleanup in non-interactive mode" {
    set_mock_sudo_uncached
    run_clean_dry_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry Run Mode"* ]]
    [[ "$output" == *"sudo -v && roomy clean --dry-run"* ]]
    [[ "$output" != *"system preview included"* ]]
}

@test "roomy clean --dry-run does not probe sudo in test mode" {
    set_mock_sudo_cached
    cat > "$TEST_MOCK_BIN/sudo" << 'MOCK'
#!/bin/bash
echo "sudo should not be called" >&2
exit 99
MOCK
    chmod +x "$TEST_MOCK_BIN/sudo"

    run_clean_dry_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo -v && roomy clean --dry-run"* ]]
    [[ "$output" != *"sudo should not be called"* ]]
}

@test "roomy clean requires values for cleanup selection flags" {
    local include_flag
    for include_flag in "--select" "--categories"; do
        run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" clean "$include_flag"
        [ "$status" -eq 1 ]
        [[ "$output" == *"Missing value for --categories"* ]]
    done

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" clean "--exclude"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing value for --exclude"* ]]
}

@test "roomy clean --dry-run shows hint when sudo is not cached" {
    set_mock_sudo_uncached
    run_clean_dry_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo -v"* ]]
    [[ "$output" == *"full preview"* ]]
}

@test "cloud and office timeout path uses helper function instead of bash -c" {
    run bash -c "grep -Eq 'run_with_shell_timeout 300 run_cloud_and_office_cleanup' '$PROJECT_ROOT/bin/clean.sh'"
    [ "$status" -eq 0 ]

    run bash -c "! grep -Eq 'run_with_timeout 300[[:space:]]+bash[[:space:]]+-c' '$PROJECT_ROOT/bin/clean.sh'"
    [ "$status" -eq 0 ]
}

@test "roomy clean --dry-run survives an unwritable TMPDIR" {
    local blocked_tmp="$HOME/blocked-tmp"
    mkdir -p "$blocked_tmp"
    chmod 500 "$blocked_tmp"

    set_mock_sudo_uncached
    local test_path="$PATH"
    if [[ -n "${TEST_MOCK_BIN:-}" ]]; then
        test_path="$TEST_MOCK_BIN:$PATH"
    fi

    run env HOME="$HOME" TMPDIR="$blocked_tmp" ROOMY_TEST_MODE=1 PATH="$test_path" \
        "$PROJECT_ROOT/roomy" clean --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" != *"mktemp:"* ]]
    [[ "$output" != *"Failed to create temporary file"* ]]
    [ -d "$HOME/.cache/roomy/tmp" ]
}

@test "roomy clean --dry-run reports user cache without deleting it" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    echo "cache data" > "$HOME/Library/Caches/TestApp/cache.tmp"

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"User app cache"* ]]
    [[ "$output" == *"Potential space"* ]]
    [ -f "$HOME/Library/Caches/TestApp/cache.tmp" ]
}

@test "roomy clean --dry-run reports stale login item without deleting it" {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.example.stale.plist" <<'PLIST'
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

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Potential stale login item: com.example.stale.plist"* ]]
    [ -f "$HOME/Library/LaunchAgents/com.example.stale.plist" ]
}

@test "roomy clean --dry-run does not export duplicate targets across sections" {
    mkdir -p "$HOME/Library/Application Support/Code/CachedData"
    echo "cache" > "$HOME/Library/Application Support/Code/CachedData/data.bin"

    run env HOME="$HOME" ROOMY_TEST_MODE=0 "$PROJECT_ROOT/roomy" clean --dry-run
    [ "$status" -eq 0 ]

    run grep -c "Application Support/Code/CachedData" "$HOME/.config/roomy/clean-list.txt"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "roomy clean honors whitelist entries" {
    mkdir -p "$HOME/Library/Caches/WhitelistedApp"
    echo "keep me" > "$HOME/Library/Caches/WhitelistedApp/data.tmp"

    cat > "$HOME/.config/roomy/whitelist" << EOF
$HOME/Library/Caches/WhitelistedApp*
EOF

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protected"* ]]
    [ -f "$HOME/Library/Caches/WhitelistedApp/data.tmp" ]
}

@test "roomy clean honors whitelist entries with $HOME literal" {
    mkdir -p "$HOME/Library/Caches/WhitelistedApp"
    echo "keep me" > "$HOME/Library/Caches/WhitelistedApp/data.tmp"

    cat > "$HOME/.config/roomy/whitelist" << 'EOF'
$HOME/Library/Caches/WhitelistedApp*
EOF

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protected"* ]]
    [ -f "$HOME/Library/Caches/WhitelistedApp/data.tmp" ]
}

@test "roomy clean protects Maven repository by default" {
    mkdir -p "$HOME/.m2/repository/org/example"
    echo "dependency" > "$HOME/.m2/repository/org/example/lib.jar"

    run env HOME="$HOME" ROOMY_TEST_MODE=1 "$PROJECT_ROOT/roomy" clean --dry-run
    [ "$status" -eq 0 ]
    [ -f "$HOME/.m2/repository/org/example/lib.jar" ]
    [[ "$output" != *"Maven repository cache"* ]]
}

@test "FINDER_METADATA_SENTINEL in whitelist protects .DS_Store files" {
    mkdir -p "$HOME/Documents"
    touch "$HOME/Documents/.DS_Store"

    cat > "$HOME/.config/roomy/whitelist" << EOF
FINDER_METADATA_SENTINEL
EOF

    # Test whitelist logic directly instead of running full clean
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
load_whitelist
if is_whitelisted "$HOME/Documents/.DS_Store"; then
    echo "protected by whitelist"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"protected by whitelist"* ]]
    [ -f "$HOME/Documents/.DS_Store" ]
}

@test "_clean_recent_items removes shared file lists" {
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    mkdir -p "$shared_dir"
    touch "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl2"
    touch "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
_clean_mail_downloads
EOF

    [ "$status" -eq 0 ]
    [ ! -f "$HOME/Library/Mail Downloads/old.pdf" ]
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$mock_bin:$PATH" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


clean_time_machine_failed_backups
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Time Machine backup in progress, skipping cleanup"* ]]
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$mock_bin:$PATH" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/system.sh"

defaults() { echo "1"; }


clean_time_machine_failed_backups
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Time Machine backup in progress, skipping cleanup"* ]]
}
