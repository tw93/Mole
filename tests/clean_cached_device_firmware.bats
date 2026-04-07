#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-device-firmware.XXXXXX")"
    export HOME

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

setup() {
    rm -rf "$HOME/Library"
}

@test "clean_cached_device_firmware is a no-op when no .ipsw files exist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware
echo "Items: $total_items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Items: 0"* ]]
    [[ "$output" != *"Cached device firmware"* ]]
}

@test "clean_cached_device_firmware reports .ipsw files in dry-run from iTunes dirs" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

IPHONE_DIR="$HOME/Library/iTunes/iPhone Software Updates"
IPAD_DIR="$HOME/Library/iTunes/iPad Software Updates"
mkdir -p "$IPHONE_DIR" "$IPAD_DIR"
touch "$IPHONE_DIR/iPhone17,1_18.0_22A000_Restore.ipsw"
touch "$IPHONE_DIR/iPhone15,2_17.5_21F000_Restore.ipsw"
touch "$IPAD_DIR/iPad14,1_18.0_22A000_Restore.ipsw"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "5242880"; }  # 5GB
bytes_to_human() { echo "5.0G"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware
echo "Files: $files_cleaned Items: $total_items"

# Verify files still exist (dry-run must not delete)
[[ -f "$IPHONE_DIR/iPhone17,1_18.0_22A000_Restore.ipsw" ]] || exit 11
[[ -f "$IPAD_DIR/iPad14,1_18.0_22A000_Restore.ipsw" ]] || exit 12
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached device firmware"* ]]
    [[ "$output" == *"3 files"* ]]
    [[ "$output" == *"dry"* ]]
    [[ "$output" == *"Files: 3 Items: 1"* ]]
}

@test "clean_cached_device_firmware finds .ipsw in Apple Configurator 2 nested cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

CONFIG_DIR="$HOME/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware/iPhone"
mkdir -p "$CONFIG_DIR"
touch "$CONFIG_DIR/nested_firmware.ipsw"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "6291456"; }
bytes_to_human() { echo "6G"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware
echo "Files: $files_cleaned"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached device firmware"* ]]
    [[ "$output" == *"Files: 1"* ]]
}

@test "clean_cached_device_firmware removes .ipsw files when not dry-run" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

IPHONE_DIR="$HOME/Library/iTunes/iPhone Software Updates"
mkdir -p "$IPHONE_DIR"
IPSW="$IPHONE_DIR/test_firmware.ipsw"
touch "$IPSW"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
safe_remove() { rm -f "$1"; return 0; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity safe_remove

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware

if [[ -f "$IPSW" ]]; then
    echo "FAIL: ipsw still present"
    exit 10
fi
echo "DELETED"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached device firmware"* ]]
    [[ "$output" == *"DELETED"* ]]
}

@test "clean_cached_device_firmware dry-run leaves real filesystem untouched (no safe_remove mock)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

IPHONE_DIR="$HOME/Library/iTunes/iPhone Software Updates"
mkdir -p "$IPHONE_DIR"
IPSW="$IPHONE_DIR/preserve.ipsw"
touch "$IPSW"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

# Do NOT mock safe_remove — real function must honor DRY_RUN
clean_cached_device_firmware

if [[ ! -f "$IPSW" ]]; then
    echo "FAIL: dry-run deleted the file"
    exit 20
fi
echo "PRESERVED"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached device firmware"* ]]
    [[ "$output" == *"dry"* ]]
    [[ "$output" == *"PRESERVED"* ]]
}

@test "clean_cached_device_firmware respects whitelist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

IPHONE_DIR="$HOME/Library/iTunes/iPhone Software Updates"
mkdir -p "$IPHONE_DIR"
touch "$IPHONE_DIR/keep.ipsw"

is_path_whitelisted() { return 0; }
get_path_size_kb() { echo "5242880"; }
bytes_to_human() { echo "5G"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware
echo "Files: $files_cleaned"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Files: 0"* ]]
    [[ "$output" != *"Cached device firmware"* ]]
}

@test "clean_cached_device_firmware does not report success when deletion fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

IPHONE_DIR="$HOME/Library/iTunes/iPhone Software Updates"
mkdir -p "$IPHONE_DIR"
IPSW="$IPHONE_DIR/fail_firmware.ipsw"
touch "$IPSW"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
safe_remove() { return 1; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity safe_remove

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware
echo "Files: $files_cleaned Items: $total_items Size: $total_size_cleaned"

if [[ ! -f "$IPSW" ]]; then
    echo "FAIL: file deleted"
    exit 30
fi
echo "PRESENT"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Files: 0 Items: 0 Size: 0"* ]]
    [[ "$output" == *"PRESENT"* ]]
    [[ "$output" != *"Cached device firmware"* ]]
}
