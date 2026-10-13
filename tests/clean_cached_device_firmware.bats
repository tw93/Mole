#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home device-firmware

    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
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
    rm -rf "$HOME/Library"
    rm -f "$HOME/probes" "$HOME/firmware-open" "$HOME/firmware-sized"
}

@test "clean_cached_device_firmware is a no-op when no .ipsw files exist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware
echo "Items: $total_items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Items: 0"* ]] || return 1
    [[ "$output" != *"Cached device firmware"* ]]
}

@test "clean_cached_device_firmware reports .ipsw files in dry-run from iTunes dirs" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

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
    [[ "$output" == *"Cached device firmware"* ]] || return 1
    [[ "$output" == *"3 files"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"Files: 3 Items: 1"* ]]
}

@test "clean_cached_device_firmware finds .ipsw in Apple Configurator 2 nested cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

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
    [[ "$output" == *"Cached device firmware"* ]] || return 1
    [[ "$output" == *"Files: 1"* ]]
}

@test "clean_cached_device_firmware removes .ipsw files when not dry-run" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

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
    [[ "$output" == *"Cached device firmware"* ]] || return 1
    [[ "$output" == *"DELETED"* ]]
}

@test "clean_cached_device_firmware dry-run leaves real filesystem untouched (no safe_remove mock)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

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

# Do NOT mock safe_remove: real function must honor DRY_RUN
clean_cached_device_firmware

if [[ ! -f "$IPSW" ]]; then
    echo "FAIL: dry-run deleted the file"
    exit 20
fi
echo "PRESERVED"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached device firmware"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"PRESERVED"* ]]
}

@test "clean_cached_device_firmware respects whitelist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

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
    [[ "$output" == *"Files: 0"* ]] || return 1
    [[ "$output" != *"Cached device firmware"* ]]
}

@test "clean_cached_device_firmware does not report success when deletion fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

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
    [[ "$output" == *"Files: 0 Items: 0 Size: 0"* ]] || return 1
    [[ "$output" == *"PRESENT"* ]] || return 1
    [[ "$output" != *"Cached device firmware"* ]]
}

@test "clean_cached_device_firmware reports .ipsw files from Apple TV Software Updates" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Existing behavior cases use conclusively idle firmware; guard cases override it.
_mole_paths_have_open_handle() { return 1; }

TV_DIR="$HOME/Library/iTunes/Apple TV Software Updates"
mkdir -p "$TV_DIR"
touch "$TV_DIR/AppleTV5,3_16.0_20J373_Restore.ipsw"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "2097152"; }  # 2GB
bytes_to_human() { echo "2.0G"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_cached_device_firmware
echo "Files: $files_cleaned Items: $total_items"

[[ -f "$TV_DIR/AppleTV5,3_16.0_20J373_Restore.ipsw" ]] || exit 11
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached device firmware"* ]] || return 1
    [[ "$output" == *"1 files"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"Files: 1 Items: 1"* ]]
}


@test "firmware guard retains open unknown and timed-out IPSW files in preview and cleanup" {
    for mode in true false; do
        for probe_status in 0 2 124; do
            run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN="$mode" PROBE_STATUS="$probe_status" /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
file="$HOME/Library/iTunes/Apple TV Software Updates/restore.ipsw"
mkdir -p "${file%/*}"
printf firmware > "$file"
_mole_paths_have_open_handle() { printf 'probe\n' >> "$HOME/probes"; return "$PROBE_STATUS"; }
get_path_size_kb() { echo 1; }
safe_remove() { echo UNEXPECTED_DELETE; return 0; }
files_cleaned=0 total_size_cleaned=0 total_items=0
MOLE_CURRENT_COMMAND=clean
clean_cached_device_firmware
[[ -s "$HOME/probes" && -f "$file" ]] || exit 1
[[ "$files_cleaned" == 0 && "${MOLE_CLEAN_CANCEL_STATUS:-0}" == 0 ]] || exit 1
EOF
            [ "$status" -eq 0 ]
            [[ "$output" != *UNEXPECTED_DELETE* && "$output" != *"Cached device firmware"* ]] || return 1
        done
    done
}

@test "firmware guard rechecks open handles after sizing in preview and at the real sink" {
    for mode in true false; do
        run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN="$mode" /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
file="$HOME/Library/iTunes/Apple TV Software Updates/racing.ipsw"
mkdir -p "${file%/*}"
printf firmware > "$file"
rm -f "$HOME/firmware-open"
_mole_paths_have_open_handle() { [[ -f "$HOME/firmware-open" ]]; }
get_path_size_kb() { touch "$HOME/firmware-open"; echo 1; }
files_cleaned=0 total_size_cleaned=0 total_items=0
clean_cached_device_firmware
[[ -f "$file" && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ]
        [[ "$output" != *"Cached device firmware"* ]] || return 1
    done
}

@test "firmware guard preserves identity across sizing and the final handle probe" {
    for phase in size final; do
        run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PHASE="$phase" DRY_RUN=false /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
file="$HOME/Library/iTunes/Apple TV Software Updates/replaced.ipsw"
mkdir -p "${file%/*}"
printf original > "$file"
rm -f "$HOME/firmware-sized"
replace_file() { mv "$file" "$file.original"; printf replacement > "$file"; }
get_path_size_kb() { [[ "$PHASE" != size ]] || replace_file; touch "$HOME/firmware-sized"; echo 1; }
_mole_paths_have_open_handle() {
    if [[ "$PHASE" == final && -f "$HOME/firmware-sized" ]]; then replace_file; fi
    return 1
}
files_cleaned=0 total_size_cleaned=0 total_items=0
clean_cached_device_firmware
[[ -f "$file" && "$(cat "$file")" == replacement && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ]
    done
}

@test "firmware guard signal stops later candidates and remains sticky" {
    for phase in initial final; do
        run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PHASE="$phase" DRY_RUN=false /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
first="$HOME/Library/iTunes/iPhone Software Updates/first.ipsw"
later="$HOME/Library/iTunes/Apple TV Software Updates/later.ipsw"
mkdir -p "${first%/*}" "${later%/*}"
printf firmware > "$first"
printf firmware > "$later"
rm -f "$HOME/firmware-sized"
_mole_paths_have_open_handle() {
    [[ "$1" == "$first" ]] || { echo UNEXPECTED_LATER_PROBE; return 1; }
    if [[ "$PHASE" == initial || -f "$HOME/firmware-sized" ]]; then return 130; fi
    return 1
}
get_path_size_kb() { touch "$HOME/firmware-sized"; echo 1; }
MOLE_CURRENT_COMMAND=clean
files_cleaned=0 total_size_cleaned=0 total_items=0
rc=0
clean_cached_device_firmware || rc=$?
[[ "$rc" == 130 && "${MOLE_CLEAN_CANCEL_STATUS:-0}" == 130 ]] || exit 1
[[ -f "$first" && -f "$later" && "$files_cleaned" == 0 ]] || exit 1
EOF
        [ "$status" -eq 0 ]
        [[ "$output" != *UNEXPECTED_LATER_PROBE* ]] || return 1
    done
}

@test "firmware cleanup keeps symlink roots and ancestors" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
root="$HOME/Library/iTunes"
mkdir -p "$HOME/redirected" "$HOME/Library"
printf firmware > "$HOME/redirected/keep.ipsw"
ln -s "$HOME/redirected" "$root"
_mole_paths_have_open_handle() { echo UNEXPECTED_PROBE; return 1; }
files_cleaned=0 total_size_cleaned=0 total_items=0
# A linked iTunes ancestor must not expose this physical update directory.
mkdir -p "$HOME/redirected/Apple TV Software Updates"
printf firmware > "$root/Apple TV Software Updates/ancestor.ipsw"
clean_cached_device_firmware
[[ -f "$root/Apple TV Software Updates/ancestor.ipsw" ]] || exit 1
rm "$root"
mkdir -p "$root"
ln -s "$HOME/redirected" "$root/Apple TV Software Updates"
clean_cached_device_firmware
[[ -f "$HOME/redirected/keep.ipsw" && "$files_cleaned" == 0 ]] || exit 1
EOF
    [ "$status" -eq 0 ]
    [[ "$output" != *UNEXPECTED_PROBE* ]] || return 1
}

@test "firmware cleanup removes only idle exact IPSW candidates through the real sink" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
root="$HOME/Library/iTunes/Apple TV Software Updates"
mkdir -p "$root/nested" "$HOME/Library/Application Support/MobileSync/Backup"
printf firmware > "$root/idle.ipsw"
printf partial > "$root/downloading.ipsw.download"
printf nested > "$root/nested/keep.ipsw"
printf backup > "$HOME/Library/Application Support/MobileSync/Backup/keep.ipsw"
ln -s "$root/nested/keep.ipsw" "$root/link.ipsw"
_mole_paths_have_open_handle() { printf '%s\n' "$1" >> "$HOME/probes"; return 1; }
get_path_size_kb() { echo 1; }
files_cleaned=0 total_size_cleaned=0 total_items=0
clean_cached_device_firmware
[[ ! -e "$root/idle.ipsw" && "$files_cleaned" == 1 ]] || exit 1
[[ -f "$root/downloading.ipsw.download" && -f "$root/nested/keep.ipsw" && -L "$root/link.ipsw" ]] || exit 1
[[ -f "$HOME/Library/Application Support/MobileSync/Backup/keep.ipsw" ]] || exit 1
[[ "$(wc -l < "$HOME/probes" | tr -d ' ')" == 2 ]] || exit 1
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cached device firmware"* ]] || return 1
}


@test "firmware guard detects a real open file and permits it after close" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
file="$HOME/Library/iTunes/Apple TV Software Updates/open.ipsw"
mkdir -p "${file%/*}"
printf firmware > "$file"
# This fixture owns every handle involved. Use real lsof without asking for sudo;
# production still requires complete process visibility before allowing removal.
_mole_complete_lsof_mode() { _MOLE_COMPLETE_LSOF_MODE=direct; return 0; }
get_path_size_kb() { echo 1; }
files_cleaned=0 total_size_cleaned=0 total_items=0
exec 9< "$file"
clean_cached_device_firmware
[[ -f "$file" && "$files_cleaned" == 0 ]] || exit 1
exec 9<&-
clean_cached_device_firmware
[[ ! -e "$file" && "$files_cleaned" == 1 ]] || exit 1
EOF
    [ "$status" -eq 0 ]
}
