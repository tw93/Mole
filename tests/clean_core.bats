#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-home.XXXXXX")"
    export HOME

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
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole"
}

@test "mo clean --dry-run skips system cleanup in non-interactive mode" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry Run Mode"* ]]
    [[ "$output" != *"Deep system-level cleanup"* ]]
}

@test "mo clean --dry-run includes system preview when sudo is cached" {
    local mock_bin="$HOME/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/sudo" << 'MOCK'
#!/bin/bash
# Shim: sudo -n true succeeds, all other sudo calls are no-ops.
if [[ "$1" == "-n" && "$2" == "true" ]]; then exit 0; fi
if [[ "$1" == "test" ]]; then exit 1; fi
if [[ "$1" == "find" ]]; then exit 0; fi
exit 0
MOCK
    chmod +x "$mock_bin/sudo"

    run env HOME="$HOME" MOLE_TEST_MODE=1 PATH="$mock_bin:$PATH" \
        "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"system preview included"* ]]
}

@test "mo clean --dry-run shows hint when sudo is not cached" {
    local mock_bin="$HOME/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/sudo" << 'MOCK'
#!/bin/bash
# Shim: sudo -n always fails (no cached credentials).
exit 1
MOCK
    chmod +x "$mock_bin/sudo"

    run env HOME="$HOME" MOLE_TEST_MODE=1 PATH="$mock_bin:$PATH" \
        "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"sudo -v"* ]]
    [[ "$output" == *"full preview"* ]]
}

@test "mo clean --dry-run reports user cache without deleting it" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    echo "cache data" > "$HOME/Library/Caches/TestApp/cache.tmp"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"User app cache"* ]]
    [[ "$output" == *"Potential space"* ]]
    [ -f "$HOME/Library/Caches/TestApp/cache.tmp" ]
}

@test "mo clean honors whitelist entries" {
    mkdir -p "$HOME/Library/Caches/WhitelistedApp"
    echo "keep me" > "$HOME/Library/Caches/WhitelistedApp/data.tmp"

    cat > "$HOME/.config/mole/whitelist" << EOF
$HOME/Library/Caches/WhitelistedApp*
EOF

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Protected"* ]]
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
    [[ "$output" == *"Protected"* ]]
    [ -f "$HOME/Library/Caches/WhitelistedApp/data.tmp" ]
}

@test "mo clean protects Maven repository by default" {
    mkdir -p "$HOME/.m2/repository/org/example"
    echo "dependency" > "$HOME/.m2/repository/org/example/lib.jar"

    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    [ -f "$HOME/.m2/repository/org/example/lib.jar" ]
    [[ "$output" != *"Maven repository cache"* ]]
}

@test "FINDER_METADATA_SENTINEL in whitelist protects .DS_Store files" {
    mkdir -p "$HOME/Documents"
    touch "$HOME/Documents/.DS_Store"

    cat > "$HOME/.config/mole/whitelist" << EOF
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

    dd if=/dev/zero of="$HOME/Library/Mail Downloads/dummy.dat" bs=1024 count=6000 2>/dev/null

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

clean_time_machine_failed_backups
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Time Machine backup in progress, skipping cleanup"* ]]
}


