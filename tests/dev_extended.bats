#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-dev-extended.XXXXXX")"
    export HOME

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

@test "clean_dev_elixir cleans hex cache" {
    mkdir -p "$HOME/.mix" "$HOME/.hex"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_elixir
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Hex cache"* ]]
}

@test "clean_dev_elixir does not clean mix archives" {
    mkdir -p "$HOME/.mix/archives"
    touch "$HOME/.mix/archives/test_tool.ez"

    # Source and run the function
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/clean/dev.sh"
    # shellcheck disable=SC2329
    safe_clean() { :; }
    clean_dev_elixir > /dev/null 2>&1 || true

    # Verify the file still exists
    [ -f "$HOME/.mix/archives/test_tool.ez" ]
}

@test "clean_dev_haskell cleans cabal install cache" {
    mkdir -p "$HOME/.cabal" "$HOME/.stack"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_haskell
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cabal install cache"* ]]
}

@test "clean_dev_haskell does not clean stack programs" {
    mkdir -p "$HOME/.stack/programs/x86_64-osx"
    touch "$HOME/.stack/programs/x86_64-osx/ghc-9.2.8.tar.xz"

    # Source and run the function
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/clean/dev.sh"
    # shellcheck disable=SC2329
    safe_clean() { :; }
    clean_dev_haskell > /dev/null 2>&1 || true

    # Verify the file still exists
    [ -f "$HOME/.stack/programs/x86_64-osx/ghc-9.2.8.tar.xz" ]
}

@test "clean_dev_ocaml cleans opam cache" {
    mkdir -p "$HOME/.opam"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_ocaml
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Opam cache"* ]]
}

@test "check_android_ndk reports multiple NDK versions" {
    run /bin/bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/Library/Android/sdk/ndk"/{21.0.1,22.0.0,20.0.0} && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_REVIEW="☞" && check_android_ndk' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Android NDK versions · 3 found"* ]]
}

@test "check_android_ndk silent when only one NDK" {
    run /bin/bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/Library/Android/sdk/ndk/22.0.0" && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_REVIEW="☞" && check_android_ndk' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"NDK versions"* ]]
}

@test "clean_xcode_device_support handles empty directories under nounset" {
    local ds_dir="$HOME/EmptyDeviceSupport"
    mkdir -p "$ds_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { :; }
clean_xcode_device_support "$HOME/EmptyDeviceSupport" "iOS DeviceSupport"
echo "survived"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}

@test "empty Xcode roots do not register active cleanup families" {
    local doc_root="$HOME/DocumentationCacheSingle"
    local simulator_root="$HOME/SystemCoreSimulatorCachesEmpty"
    mkdir -p "$doc_root" "$simulator_root"
    touch "$doc_root/DeveloperDocumentation.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" \
        MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$simulator_root" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
note_activity() { :; }
clean_xcode_documentation_cache
clean_xcode_system_coresimulator_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]]
}

@test "clean_xcode_device_support skips while Xcode tooling is active" {
    local ds_dir="$HOME/ActiveDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { [[ "$*" == *"xcodebuild"* ]]; }
safe_clean() { echo "UNEXPECTED_CLEAN:$*"; }
clean_xcode_device_support "$HOME/ActiveDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"iOS DeviceSupport · skipped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]] || return 1
}

@test "clean_xcode_device_support preserves every version when metadata is unreadable" {
    local ds_dir="$HOME/UnreadableDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
stat() { return 9; }
safe_clean() { echo "UNEXPECTED_CLEAN:$*"; }
clean_xcode_device_support "$HOME/UnreadableDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"iOS DeviceSupport · skipped (metadata unavailable)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]] || return 1
}

@test "clean_xcode_device_support keeps two newest versions and removes only older versions" {
    local ds_dir="$HOME/RetainedDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
safe_remove() { command rm -rf "$1"; }
safe_clean() { :; }
clean_xcode_device_support "$HOME/RetainedDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ ! -e "$ds_dir/17.0" ]] || return 1
    [[ -d "$ds_dir/17.1" && -d "$ds_dir/17.2" ]]
}

@test "clean_xcode_device_support keeps newline-containing paths byte-exact" {
    local ds_dir="$HOME/NewlineDeviceSupport"
    local newline_a="$ds_dir/Current"$'\n'"A"
    local newline_b="$ds_dir/Current"$'\n'"B"
    mkdir -p "$ds_dir/Current" "$newline_a" "$newline_b" "$ds_dir/Old"
    touch -t 202601010000 "$ds_dir/Old"
    touch -t 202602010000 "$newline_b"
    touch -t 202603010000 "$newline_a"
    touch -t 202604010000 "$ds_dir/Current"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
safe_remove() { command rm -rf "$1"; }
safe_clean() { :; }
clean_xcode_device_support "$HOME/NewlineDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -d "$ds_dir/Current" && -d "$newline_a" ]] || return 1
    [[ ! -e "$newline_b" && ! -e "$ds_dir/Old" ]]
}

@test "clean_xcode_device_support fails closed when process state is unknown" {
    local ds_dir="$HOME/UnknownProcessDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 2; }
safe_remove() { echo "UNEXPECTED_REMOVE:$*"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$*"; }
clean_xcode_device_support "$HOME/UnknownProcessDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"iOS DeviceSupport · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]] || return 1
    [[ -d "$ds_dir/17.0" && -d "$ds_dir/17.1" && -d "$ds_dir/17.2" ]]
}

@test "clean_xcode_device_support rechecks tooling before destructive work" {
    local ds_dir="$HOME/RacingDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
probe_round=0
_xcode_xctest_devices_process_running() {
    probe_round=$((probe_round + 1))
    [[ $probe_round -ge 2 ]]
}
safe_remove() { echo "UNEXPECTED_REMOVE:$*"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$*"; }
clean_xcode_device_support "$HOME/RacingDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"iOS DeviceSupport · stopped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]] || return 1
    [[ -d "$ds_dir/17.0" && -d "$ds_dir/17.1" && -d "$ds_dir/17.2" ]]
}

@test "clean_xcode_device_support reports completed removals before a tooling race stops it" {
    local ds_dir="$HOME/PartialDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2" "$ds_dir/17.3"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"
    touch -t 202604010000 "$ds_dir/17.3"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
cleanup_result_color_kb() { echo ""; }
bytes_to_human() { echo "$1 bytes"; }
get_path_size_kb() { echo 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() { command rm -rf "$1"; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }

probe_round=0
_xcode_xctest_devices_process_running() {
    probe_round=$((probe_round + 1))
    if [[ $probe_round -le 3 ]]; then
        return 1
    fi
    return 0
}

clean_xcode_device_support "$HOME/PartialDeviceSupport" "iOS DeviceSupport"
remaining=$(command find "$HOME/PartialDeviceSupport" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[[ "$remaining" -eq 3 ]] || { echo "WRONG_REMAINING:$remaining"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"iOS DeviceSupport · removed 1 old versions"* ]] || return 1
    [[ "$output" != *"iOS DeviceSupport · stopped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
}

@test "clean_xcode_device_support does not defer after the only stale version is removed" {
    local ds_dir="$HOME/CompletedDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
cleanup_result_color_kb() { echo ""; }
bytes_to_human() { echo "$1 bytes"; }
get_path_size_kb() { echo 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
_xcode_xctest_devices_process_running() {
    [[ -e "$HOME/device-support-removal-complete" ]] && return 0
    return 1
}
safe_remove() {
    command rm -rf "$1"
    : > "$HOME/device-support-removal-complete"
}
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }

clean_xcode_device_support "$HOME/CompletedDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"iOS DeviceSupport · removed 1 old versions"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
    [[ ! -e "$ds_dir/17.0" && -d "$ds_dir/17.1" && -d "$ds_dir/17.2" ]]
}

@test "clean_xcode_device_support does not defer when only whitelisted inner caches remain" {
    local ds_dir="$HOME/CompletedWhitelistedDeviceSupport"
    local kept_cache="$ds_dir/17.2/Symbols/System/Library/Caches/whitelisted"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$(dirname "$kept_cache")"
    touch "$kept_cache"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
target="$HOME/CompletedWhitelistedDeviceSupport/17.2/Symbols/System/Library/Caches/whitelisted"
note_activity() { :; }
cleanup_result_color_kb() { echo ""; }
bytes_to_human() { echo "$1 bytes"; }
get_path_size_kb() { echo 1; }
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
_xcode_xctest_devices_process_running() {
    [[ -e "$HOME/device-support-whitelist-removal-complete" ]] && return 0
    return 1
}
safe_remove() {
    command rm -rf "$1"
    : > "$HOME/device-support-whitelist-removal-complete"
}
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }

clean_xcode_device_support "$HOME/CompletedWhitelistedDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"iOS DeviceSupport · removed 1 old versions"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
    [[ ! -e "$ds_dir/17.0" && -f "$kept_cache" ]]
}

@test "clean_xcode_device_support ignores active whitelist-only stale versions" {
    local ds_dir="$HOME/WhitelistedDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
target="$HOME/WhitelistedDeviceSupport/17.0"
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
_xcode_xctest_devices_process_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; }

clean_xcode_device_support "$HOME/WhitelistedDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_xcode_device_support ignores active compiled-model-only stale versions" {
    local ds_dir="$HOME/CompiledDeviceSupport"
    mkdir -p "$ds_dir/17.0/com.apple.e5rt.e5bundlecache" "$ds_dir/17.1" "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_xcode_xctest_devices_process_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$1"; }
clean_xcode_device_support "$HOME/CompiledDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_xcode_device_support dry run does not double-count stale inner caches" {
    local ds_dir="$HOME/PreviewDeviceSupport"
    mkdir -p \
        "$ds_dir/17.0/Symbols/System/Library/Caches/stale-cache" \
        "$ds_dir/17.1/Symbols/System/Library/Caches/kept-cache" \
        "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
bytes_to_human() { echo "$1 bytes"; }
get_path_size_kb() { echo 1; }
_xcode_xctest_devices_process_running() { return 1; }
record_dry_run_cleanup_target() { printf 'RECORD:%s\n' "$1"; }
safe_clean() {
    local count=$# index=1 arg
    for arg in "$@"; do
        [[ $index -lt $count ]] && printf 'SAFE:%s\n' "$arg"
        index=$((index + 1))
    done
}
clean_xcode_device_support "$HOME/PreviewDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RECORD:$ds_dir/17.0"* ]] || return 1
    [[ "$output" == *"SAFE:$ds_dir/17.1/Symbols/System/Library/Caches/kept-cache"* ]] || return 1
    [[ "$output" != *"SAFE:$ds_dir/17.0/Symbols/System/Library/Caches/stale-cache"* ]]
}

@test "clean_xcode_device_support previews eligible inner cache under an excluded stale root" {
    local ds_dir="$HOME/PreviewExcludedDeviceSupport"
    mkdir -p \
        "$ds_dir/17.0/com.apple.e5rt.e5bundlecache" \
        "$ds_dir/17.0/Symbols/System/Library/Caches/eligible" \
        "$ds_dir/17.1" \
        "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
bytes_to_human() { echo "$1 bytes"; }
get_path_size_kb() { echo 1; }
_xcode_xctest_devices_process_running() { return 1; }
record_dry_run_cleanup_target() { printf 'RECORD:%s\n' "$1"; }
safe_clean() {
    local count=$# index=1 arg
    for arg in "$@"; do
        [[ $index -lt $count ]] && printf 'SAFE:%s\n' "$arg"
        index=$((index + 1))
    done
}
clean_xcode_device_support "$HOME/PreviewExcludedDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"RECORD:$ds_dir/17.0"* ]] || return 1
    [[ "$output" == *"SAFE:$ds_dir/17.0/Symbols/System/Library/Caches/eligible"* ]]
}

@test "clean_xcode_device_support rechecks tooling after the destructive size probe" {
    local ds_dir="$HOME/PostSizeDeviceSupport"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }

get_path_size_kb() {
    printf 'size\n' >> "$HOME/device-size-probes"
    size_round=$(wc -l < "$HOME/device-size-probes" | tr -d ' ')
    [[ $size_round -ge 1 ]] && touch "$HOME/xcode-started"
    echo 1
}
_xcode_xctest_devices_process_running() {
    [[ -e "$HOME/xcode-started" ]] && return 0
    return 1
}

rm -f "$HOME/xcode-started" "$HOME/device-size-probes"
clean_xcode_device_support "$HOME/PostSizeDeviceSupport" "iOS DeviceSupport"
[[ -d "$HOME/PostSizeDeviceSupport/17.0" ]] || { echo "WRONG: old version removed"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"iOS DeviceSupport · stopped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]]
}

@test "clean_xcode_device_support passes its measured size to the real deletion sink" {
    local ds_dir="$HOME/DeviceSupportRealSink"
    mkdir -p "$ds_dir/17.0" "$ds_dir/17.1" "$ds_dir/17.2"
    touch -t 202601010000 "$ds_dir/17.0"
    touch -t 202602010000 "$ds_dir/17.1"
    touch -t 202603010000 "$ds_dir/17.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DEVICE_SUPPORT_KEEP=2 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
safe_clean() { :; }
get_path_size_kb() {
    printf 'size\n' >> "$HOME/device-real-size-probes"
    local round
    round=$(wc -l < "$HOME/device-real-size-probes" | tr -d ' ')
    [[ $round -ge 2 ]] && touch "$HOME/xcode-started"
    echo 1
}
_xcode_xctest_devices_process_running() {
    [[ -e "$HOME/xcode-started" ]] && return 0
    return 1
}

rm -f "$HOME/xcode-started" "$HOME/device-real-size-probes"
clean_xcode_device_support "$HOME/DeviceSupportRealSink" "iOS DeviceSupport"
[[ ! -e "$HOME/DeviceSupportRealSink/17.0" ]] || { echo "WRONG: old version remains"; exit 1; }
[[ ! -e "$HOME/xcode-started" ]] || { echo "WRONG: deletion sink repeated size probe"; exit 1; }
[[ "$(wc -l < "$HOME/device-real-size-probes" | tr -d ' ')" -eq 1 ]] || exit 1
printf 'COUNTERS:%s:%s:%s\n' "$files_cleaned" "$total_size_cleaned" "$total_items"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"COUNTERS:1:1:1"* ]]
}

@test "clean_xcode_documentation_cache keeps newest DeveloperDocumentation index" {
    local doc_root="$HOME/DocumentationCache"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index"
    touch "$doc_root/DeveloperDocumentation-16.0.index"
    touch -t 202402010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202401010000 "$doc_root/DeveloperDocumentation-16.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
# Without this the real pgrep runs against the host, so the result depends on
# whether the developer happens to have Xcode open. The sibling case mocks the
# running side; this one has to mock the not-running side.
pgrep() { return 1; }
_coresimulator_booted_device_state() { return 1; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
_sim_runtime_size_kb() { echo 2; }
safe_sudo_remove() {
    local target="$1"
    echo "CLEAN:$target:Xcode documentation cache (old indexes)"
}
clean_xcode_documentation_cache
printf 'COUNTERS:%s:%s:%s\n' "$files_cleaned" "$total_size_cleaned" "$total_items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$doc_root/DeveloperDocumentation-16.0.index:Xcode documentation cache (old indexes)"* ]] || return 1
    [[ "$output" != *"CLEAN:$doc_root/DeveloperDocumentation.index:Xcode documentation cache (old indexes)"* ]] || return 1
    [[ "$output" == *"COUNTERS:1:2:1"* ]]
}

@test "clean_xcode_documentation_cache skips when Xcode is running" {
    local doc_root="$HOME/DocumentationCache"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index"
    touch "$doc_root/DeveloperDocumentation-16.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 0; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }
clean_xcode_documentation_cache
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Xcode documentation cache · skipped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]]
}

@test "clean_xcode_documentation_cache does not defer whitelist-only stale indexes" {
    local doc_root="$HOME/DocumentationCacheWhitelistOnly"
    local stale="$doc_root/DeveloperDocumentation-16.0.index"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index" "$stale"
    touch -t 202602010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202601010000 "$stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
target="$MOLE_XCODE_DOCUMENTATION_CACHE_DIR/DeveloperDocumentation-16.0.index"
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
_xcode_xctest_devices_process_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_xcode_documentation_cache
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_documentation_cache ignores symlink and compiled-model-only stale indexes" {
    local doc_root="$HOME/DocumentationCachePolicyOnly"
    local outside="$HOME/DocumentationCachePolicyOutside"
    mkdir -p "$doc_root/DeveloperDocumentation-15.0.index/com.apple.e5rt.e5bundlecache"
    touch "$doc_root/DeveloperDocumentation.index" "$outside"
    ln -s "$outside" "$doc_root/DeveloperDocumentation-16.0.index"
    touch -t 202603010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202602010000 "$outside"
    touch -t 202601010000 "$doc_root/DeveloperDocumentation-15.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_xcode_xctest_devices_process_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_DRY_CLEAN:$1"; }
safe_sudo_remove() { echo "UNEXPECTED_REAL_CLEAN:$1"; }
for DRY_RUN in false true; do
    clean_xcode_documentation_cache
done
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DRY_CLEAN"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REAL_CLEAN"* ]]
}

@test "clean_xcode_documentation_cache preserves newline-containing index paths" {
    local doc_root="$HOME/DocumentationCacheNewline"
    local newline_index=$'DeveloperDocumentation-16.0\njunk.index'
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index" \
        "$doc_root/DeveloperDocumentation-15.0.index" \
        "$doc_root/$newline_index"
    touch -t 202603010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202601010000 "$doc_root/DeveloperDocumentation-15.0.index"
    touch -t 202602010000 "$doc_root/$newline_index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
newline_index=$'DeveloperDocumentation-16.0\njunk.index'
_xcode_xctest_devices_process_running() { return 1; }
has_sudo_session() { return 0; }
_sim_runtime_size_kb() { echo 1; }
safe_sudo_remove() { command rm -rf "$1"; }
clean_xcode_documentation_cache
[[ -e "$MOLE_XCODE_DOCUMENTATION_CACHE_DIR/DeveloperDocumentation.index" ]] || exit 1
[[ ! -e "$MOLE_XCODE_DOCUMENTATION_CACHE_DIR/DeveloperDocumentation-15.0.index" ]] || exit 1
[[ ! -e "$MOLE_XCODE_DOCUMENTATION_CACHE_DIR/$newline_index" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "clean_xcode_documentation_cache skips when the process probe fails" {
    local doc_root="$HOME/DocumentationCacheProbeError"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index" "$doc_root/DeveloperDocumentation-16.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 2; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }
clean_xcode_documentation_cache
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode documentation cache · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]]
}

@test "clean_xcode_documentation_cache rechecks tooling after sudo authorization" {
    local doc_root="$HOME/DocumentationCacheSudoRace"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index" "$doc_root/DeveloperDocumentation-16.0.index"
    touch -t 202602010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202601010000 "$doc_root/DeveloperDocumentation-16.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
has_sudo_session() { return 1; }
ensure_sudo_session() { touch "$HOME/xcode-started"; return 0; }
_sim_runtime_size_kb() { echo 1; }
_xcode_xctest_devices_process_running() {
    [[ -e "$HOME/xcode-started" ]] && return 0
    return 1
}
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }

rm -f "$HOME/xcode-started"
clean_xcode_documentation_cache
[[ -e "$MOLE_XCODE_DOCUMENTATION_CACHE_DIR/DeveloperDocumentation-16.0.index" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Xcode documentation cache · stopped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_documentation_cache reports a stop after partial removal" {
    local doc_root="$HOME/DocumentationCachePartialRace"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index" "$doc_root/DeveloperDocumentation-16.0.index" "$doc_root/DeveloperDocumentation-15.0.index"
    touch -t 202603010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202602010000 "$doc_root/DeveloperDocumentation-16.0.index"
    touch -t 202601010000 "$doc_root/DeveloperDocumentation-15.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
has_sudo_session() { return 0; }
_sim_runtime_size_kb() { echo 1; }
_xcode_xctest_devices_process_running() {
    [[ -e "$HOME/xcode-started" ]] && return 0
    return 1
}
safe_sudo_remove() {
    command rm -rf "$1"
    touch "$HOME/xcode-started"
}

rm -f "$HOME/xcode-started"
clean_xcode_documentation_cache
remaining=$(command find "$MOLE_XCODE_DOCUMENTATION_CACHE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
[[ "$remaining" -eq 2 ]] || { echo "WRONG_REMAINING:$remaining"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode documentation cache · removed 1 old indexes"* ]] || return 1
    [[ "$output" != *"Xcode documentation cache · stopped"* ]]
}

@test "clean_xcode_documentation_cache does not report clean after a protected item and stop" {
    local doc_root="$HOME/DocumentationCacheProtectedRace"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index" "$doc_root/DeveloperDocumentation-16.0.index" "$doc_root/DeveloperDocumentation-15.0.index"
    touch -t 202603010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202602010000 "$doc_root/DeveloperDocumentation-16.0.index"
    touch -t 202601010000 "$doc_root/DeveloperDocumentation-15.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
is_path_whitelisted() { return 1; }
should_protect_path() {
    if [[ "$1" == *"DeveloperDocumentation-16.0.index" ]]; then
        touch "$HOME/xcode-started"
        return 0
    fi
    return 1
}
has_sudo_session() { return 0; }
_sim_runtime_size_kb() { echo 1; }
_xcode_xctest_devices_process_running() {
    [[ -e "$HOME/xcode-started" ]] && return 0
    return 1
}
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }

rm -f "$HOME/xcode-started"
clean_xcode_documentation_cache
remaining=$(command find "$MOLE_XCODE_DOCUMENTATION_CACHE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
[[ "$remaining" -eq 3 ]] || { echo "WRONG_REMAINING:$remaining"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode documentation cache · skipped 1 protected items"* ]] || return 1
    [[ "$output" != *"Xcode documentation cache · stopped"* ]] || return 1
    [[ "$output" != *"already clean"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_device_support skips all deletion paths while build tooling owns it" {
    local ds_dir="$HOME/OwnedDeviceSupport"
    mkdir -p "$ds_dir/17.0/Symbols/System/Library/Caches" "$ds_dir/17.1" "$ds_dir/17.2"
    touch "$ds_dir/17.0/Symbols/System/Library/Caches/cache" "$ds_dir/device.log"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { [[ "$1" == "-x" && "$2" == "swift-frontend" ]]; }
safe_remove() { echo "UNEXPECTED_SAFE_REMOVE:$1"; return 0; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$1"; return 0; }
clean_xcode_device_support "$HOME/OwnedDeviceSupport" "iOS DeviceSupport"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"iOS DeviceSupport · skipped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_"* ]]
}

@test "clean_xcode_system_coresimulator_caches removes only direct cache children" {
    local cache_root="$HOME/SystemCoreSimulatorCaches"
    mkdir -p "$cache_root/dyld/runtime" "$cache_root/metadata"
    touch "$cache_root/dyld/runtime/cache" "$cache_root/metadata/index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
_coresimulator_booted_device_state() { return 1; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
get_path_size_kb() { echo 3; }
safe_sudo_remove() { echo "REMOVE:$1"; }
clean_xcode_system_coresimulator_caches
printf 'COUNTERS:%s:%s:%s\n' "$files_cleaned" "$total_size_cleaned" "$total_items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"REMOVE:$cache_root/dyld"* ]] || return 1
    [[ "$output" == *"REMOVE:$cache_root/metadata"* ]] || return 1
    [[ "$output"$'\n' != *"REMOVE:$cache_root"$'\n'* ]] || return 1
    [[ "$output" == *"COUNTERS:2:6:1"* ]]
}

@test "clean_xcode_system_coresimulator_caches skips while CoreSimulator is active" {
    local cache_root="$HOME/SystemCoreSimulatorCaches"
    mkdir -p "$cache_root/dyld"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() {
    [[ "$1" == "-x" && "$2" == "Simulator" ]]
}
debug_log() { echo "DEBUG:$*"; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }
clean_xcode_system_coresimulator_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Xcode Simulator system cache · skipped"* ]] || return 1
    [[ "$output" == *"DEBUG:CoreSimulator process detected: Simulator"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]]
}

@test "clean_xcode_system_coresimulator_caches does not defer whitelist-only entries" {
    local cache_root="$HOME/SystemCoreSimulatorWhitelistOnly"
    local target="$cache_root/dyld"
    mkdir -p "$target"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
target="$MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR/dyld"
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
_coresimulator_activity_state() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_xcode_system_coresimulator_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_system_coresimulator_caches ignores symlink and compiled-model-only entries" {
    local cache_root="$HOME/SystemCoreSimulatorPolicyOnly"
    local outside="$HOME/SystemCoreSimulatorPolicyOutside"
    mkdir -p "$cache_root/compiled/com.apple.e5rt.e5bundlecache" "$outside"
    ln -s "$outside" "$cache_root/symlink"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_coresimulator_activity_state() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_xcode_system_coresimulator_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_system_coresimulator_caches fails closed when pgrep fails (#1304)" {
    local cache_root
    cache_root="$HOME/SystemCoreSimulatorCaches"
    mkdir -p "$cache_root/dyld"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 2; }
debug_log() { echo "DEBUG:$*"; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }
clean_xcode_system_coresimulator_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Xcode Simulator system cache · skipped (process state unknown)"* ]] || return 1
    [[ "$output" == *"DEBUG:CoreSimulator process check failed: Xcode (exit=2)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]] || return 1
}

@test "CoreSimulator process guard reports the exact matched probe (#1304)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { :; }
pgrep() {
    [[ "$1" == "$EXPECTED_MODE" && "$2" == "$EXPECTED_PATTERN" ]]
}

while IFS='|' read -r EXPECTED_MODE EXPECTED_PATTERN expected_label; do
    [[ -n "$EXPECTED_PATTERN" ]] || continue
    _coresimulator_cache_process_running || exit 1
    [[ "$_MOLE_XCODE_PROCESS_MATCH" == "$expected_label" ]] || exit 2
    printf 'matched:%s\n' "$_MOLE_XCODE_PROCESS_MATCH"
done <<'CASES'
-x|Xcode|Xcode
-x|Simulator|Simulator
-x|xcodebuild|xcodebuild
-x|xctest|xctest
-x|XCTRunner|XCTRunner
-x|simctl|simctl
CASES
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"matched:Xcode"* ]] || return 1
    [[ "$output" == *"matched:Simulator"* ]] || return 1
    [[ "$output" == *"matched:xcodebuild"* ]] || return 1
    [[ "$output" == *"matched:simctl"* ]] || return 1
}

@test "persistent services and generic compilers do not block cleanup without a booted device (#1319)" {
    local cache_root="$HOME/SystemCoreSimulatorCachesPersistentServices"
    mkdir -p "$cache_root/dyld"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() {
    case "$2" in
        CoreSimulatorService | simdiskimaged | com.apple.CoreSimulator | XCBBuildService | swift-frontend) return 0 ;;
        *) return 1 ;;
    esac
}
_coresimulator_booted_device_state() { return 1; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
get_path_size_kb() { echo 1; }
safe_sudo_remove() { echo "REMOVE:$1"; }
clean_xcode_system_coresimulator_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"REMOVE:$cache_root/dyld"* ]] || return 1
    [[ "$output" != *"skipped (CoreSimulator running)"* ]] || return 1
}

@test "foreground simulator tooling blocks cleanup before a device is booted (#1319)" {
    local cache_root="$HOME/SystemCoreSimulatorCachesForegroundTooling"
    mkdir -p "$cache_root/dyld"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
_coresimulator_booted_device_state() { return 1; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }

for ACTIVE_PROCESS in simctl xcodebuild; do
    pgrep() { [[ "$1" == "-x" && "$2" == "$ACTIVE_PROCESS" ]]; }
    clean_xcode_system_coresimulator_caches
    printf 'BLOCKED:%s\n' "$ACTIVE_PROCESS"
done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"BLOCKED:simctl"* ]] || return 1
    [[ "$output" == *"BLOCKED:xcodebuild"* ]] || return 1
    [[ "$output" != *"skipped (CoreSimulator running)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]] || return 1
}

@test "booted or unknown simulator state blocks system cache cleanup (#1319)" {
    local cache_root="$HOME/SystemCoreSimulatorCachesBootedState"
    mkdir -p "$cache_root/dyld"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }

for SIMULATOR_STATE in 0 2; do
    _coresimulator_booted_device_state() { return "$SIMULATOR_STATE"; }
    clean_xcode_system_coresimulator_caches
done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"skipped (CoreSimulator running)"* ]] || return 1
    [[ "$output" == *"skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]] || return 1
}

@test "booted simulator probe distinguishes active empty and unknown states (#1319)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { :; }
_MOLE_SIMCTL_RESOLUTION_STATUS="ready"
_run_simctl() {
    case "$PROBE_CASE" in
        active) printf '%s\n' '{"devices":{"runtime":[{"udid":"ABC"}]}}' ;;
        empty) printf '%s\n' '{"devices":{}}' ;;
        malformed) printf '%s\n' 'not-json' ;;
        failed) return 124 ;;
    esac
}

set +e
PROBE_CASE=active; _coresimulator_booted_device_state; active_rc=$?
PROBE_CASE=empty; _coresimulator_booted_device_state; empty_rc=$?
PROBE_CASE=malformed; _coresimulator_booted_device_state; malformed_rc=$?
PROBE_CASE=failed; _coresimulator_booted_device_state; failed_rc=$?
set -e
printf 'active=%s empty=%s malformed=%s failed=%s\n' "$active_rc" "$empty_rc" "$malformed_rc" "$failed_rc"
[[ "$active_rc" -eq 0 && "$empty_rc" -eq 1 && "$malformed_rc" -eq 2 && "$failed_rc" -eq 2 ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"active=0 empty=1 malformed=2 failed=2"* ]] || return 1
}

@test "simulator activity checks recheck foreground owners after the booted probe (#1319)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { :; }
pgrep() {
    [[ -e "$HOME/foreground-started" && "$1" == "-x" && "$2" == "xcodebuild" ]]
}
_coresimulator_booted_device_state() {
    touch "$HOME/foreground-started"
    return 1
}

rm -f "$HOME/foreground-started"
set +e
_coresimulator_activity_state
coresimulator_rc=$?
rm -f "$HOME/foreground-started"
_xctest_devices_activity_state
xctest_rc=$?
set -e
printf 'coresimulator=%s xctest=%s\n' "$coresimulator_rc" "$xctest_rc"
[[ "$coresimulator_rc" -eq 0 && "$xctest_rc" -eq 0 ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"coresimulator=0 xctest=0"* ]] || return 1
}

@test "clean_xcode_system_coresimulator_caches reports completed removals before a process race stops it" {
    local cache_root="$HOME/PartialSystemCoreSimulatorCaches"
    mkdir -p "$cache_root/first" "$cache_root/second"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
cleanup_result_color_kb() { echo ""; }
bytes_to_human() { echo "$1 bytes"; }
get_path_size_kb() { echo 1; }
simulator_started=false
safe_sudo_remove() {
    command rm -rf "$1"
    simulator_started=true
}
_coresimulator_cache_process_running() {
    [[ "$simulator_started" == "true" ]]
}
_coresimulator_booted_device_state() { return 1; }

clean_xcode_system_coresimulator_caches
remaining=$(command find "$MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
[[ "$remaining" -eq 1 ]] || { echo "WRONG_REMAINING:$remaining"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode Simulator system cache · removed 1"* ]] || return 1
    [[ "$output" != *"Xcode Simulator system cache · stopped"* ]]
}

@test "clean_xcode_system_coresimulator_caches rechecks after the size probe" {
    local cache_root="$HOME/PostSizeSystemCoreSimulatorCaches"
    mkdir -p "$cache_root/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
get_path_size_kb() { touch "$HOME/simulator-started"; echo 1; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; }
_coresimulator_cache_process_running() {
    [[ -e "$HOME/simulator-started" ]] && return 0
    return 1
}
_coresimulator_booted_device_state() { return 1; }

rm -f "$HOME/simulator-started"
clean_xcode_system_coresimulator_caches
[[ -d "$MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR/entry" ]] || { echo "WRONG: cache removed"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Xcode Simulator system cache · stopped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_system_coresimulator_caches reports deletion failures" {
    local cache_root="$HOME/FailedSystemCoreSimulatorCaches"
    mkdir -p "$cache_root/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR="$cache_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
get_path_size_kb() { echo 1; }
_coresimulator_cache_process_running() { return 1; }
_coresimulator_booted_device_state() { return 1; }
safe_sudo_remove() { return 1; }
clean_xcode_system_coresimulator_caches
[[ -d "$MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR/entry" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode Simulator system cache · could not remove 1 entries"* ]] || return 1
    [[ "$output" != *"already clean"* ]]
}

@test "clean_xcode_xctest_devices targets only exact XCTestDevices directory" {
    local developer_root="$HOME/Library/Developer"
    mkdir -p "$developer_root/XCTestDevices" "$developer_root/XCTestDevices-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
_coresimulator_booted_device_state() { return 1; }
safe_clean() { printf 'SAFE:%s|%s\n' "$1" "$2"; }
clean_xcode_xctest_devices
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE:$developer_root/XCTestDevices|Xcode XCTestDevices test data"* ]] || return 1
    [[ "$output" != *"XCTestDevices-old"* ]]
}

@test "clean_xcode_xctest_devices skips while XCTest process is active" {
    local xctest_root="$HOME/Library/Developer/XCTestDevices"
    mkdir -p "$xctest_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() {
    [[ "$*" == *"xcodebuild"* ]]
}
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }
clean_xcode_xctest_devices
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Xcode or XCTest running"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
}

@test "clean_xcode_xctest_devices fails closed for booted or unknown simulator state (#1319)" {
    local xctest_root="$HOME/Library/Developer/XCTestDevices"
    mkdir -p "$xctest_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }

for SIMULATOR_STATE in 0 2; do
    _coresimulator_booted_device_state() { return "$SIMULATOR_STATE"; }
    clean_xcode_xctest_devices
done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"Xcode XCTestDevices · skipped (Xcode or XCTest running)"* ]] || return 1
    [[ "$output" == *"Xcode XCTestDevices · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
}

@test "clean_xcode_xctest_devices rechecks after safe_clean sizing" {
    local xctest_root="$HOME/PostSizeXCTestDevices"
    mkdir -p "$xctest_root/device"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_XCODE_XCTEST_DEVICES_DIR="$xctest_root" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
note_activity() { :; }
get_cleanup_path_size_kb() { touch "$HOME/xctest-started"; echo 1; }
pgrep() { [[ -e "$HOME/xctest-started" ]]; }
_coresimulator_booted_device_state() { return 1; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; command rm -rf "$1"; }

rm -f "$HOME/xctest-started"
clean_xcode_xctest_devices
[[ -d "$MOLE_XCODE_XCTEST_DEVICES_DIR/device" ]] || { echo "WRONG: XCTestDevices removed"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Xcode XCTestDevices · stopped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_xctest_devices dry-run keeps XCTestDevices directory" {
    local xctest_root="$HOME/Library/Developer/XCTestDevices"
    mkdir -p "$xctest_root"
    touch "$xctest_root/test-device"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
MOLE_DRY_RUN=1
pgrep() { return 1; }
_coresimulator_booted_device_state() { return 1; }
clean_xcode_xctest_devices
[[ -d "$HOME/Library/Developer/XCTestDevices" ]] && echo "STILL_EXISTS"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode XCTestDevices test data"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"STILL_EXISTS"* ]]
}

@test "clean_xcode_xctest_devices respects whitelist" {
    local xctest_root="$HOME/Library/Developer/XCTestDevices"
    mkdir -p "$xctest_root"
    touch "$xctest_root/test-device"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
WHITELIST_PATTERNS=("$HOME/Library/Developer/XCTestDevices")
pgrep() { return 1; }
_coresimulator_booted_device_state() { return 1; }
clean_xcode_xctest_devices
[[ -d "$HOME/Library/Developer/XCTestDevices" ]] && echo "STILL_EXISTS"
printf 'WHITELIST_SKIPPED:%s\n' "$whitelist_skipped_count"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"STILL_EXISTS"* ]] || return 1
    [[ "$output" == *"WHITELIST_SKIPPED:1"* ]]
}

@test "clean_xcode_xctest_devices does not defer a whitelisted root" {
    local xctest_root="$HOME/WhitelistedXCTestDevices"
    mkdir -p "$xctest_root"
    touch "$xctest_root/test-device"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_XCTEST_DEVICES_DIR="$xctest_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$MOLE_XCODE_XCTEST_DEVICES_DIR" ]]; }
_xctest_devices_activity_state() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$1"; }
clean_xcode_xctest_devices
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "check_rust_toolchains reports multiple toolchains" {
    run /bin/bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/.rustup/toolchains"/{stable,nightly,1.75.0}-aarch64-apple-darwin && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_REVIEW="☞" && rustup() { :; } && export -f rustup && check_rust_toolchains' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Rust toolchains · 3 found"* ]]
}

@test "check_rust_toolchains silent when only one toolchain" {
    run /bin/bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/.rustup/toolchains/stable-aarch64-apple-darwin" && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_REVIEW="☞" && rustup() { :; } && export -f rustup && check_rust_toolchains' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"Rust toolchains"* ]]
}

@test "check_rust_toolchains follows RUSTUP_HOME" {
    run /bin/bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/.local/share/mise/rustup/toolchains"/{stable,nightly,1.75.0}-aarch64-apple-darwin && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_REVIEW="☞" && rustup() { :; } && export -f rustup && RUSTUP_HOME="$HOME/.local/share/mise/rustup" check_rust_toolchains' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Rust toolchains · 3 found"* ]]
}

@test "clean_dev_jetbrains_toolbox cleans old versions and bypasses toolbox whitelist" {
    local toolbox_channel="$HOME/Library/Application Support/JetBrains/Toolbox/apps/IDEA/ch-0"
    mkdir -p "$toolbox_channel/241.1" "$toolbox_channel/241.2" "$toolbox_channel/241.3"
    ln -s "241.3" "$toolbox_channel/current"
    touch -t 202401010000 "$toolbox_channel/241.1"
    touch -t 202402010000 "$toolbox_channel/241.2"
    touch -t 202403010000 "$toolbox_channel/241.3"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
toolbox_root="$HOME/Library/Application Support/JetBrains/Toolbox/apps"
WHITELIST_PATTERNS=("$toolbox_root"* "$HOME/Library/Application Support/JetBrains*")
note_activity() { :; }
safe_clean() {
    local target="$1"
    for pattern in "${WHITELIST_PATTERNS[@]+${WHITELIST_PATTERNS[@]}}"; do
        if [[ "$pattern" == "$toolbox_root"* ]]; then
            echo "WHITELIST_NOT_REMOVED"
            exit 1
        fi
    done
    echo "$target"
}
MOLE_JETBRAINS_TOOLBOX_KEEP=1
clean_dev_jetbrains_toolbox
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/241.1"* ]] || return 1
    [[ "$output" != *"/241.2"* ]]
}

@test "clean_dev_jetbrains_toolbox keeps current directory and removes older versions" {
    local toolbox_channel="$HOME/Library/Application Support/JetBrains/Toolbox/apps/IDEA/ch-0"
    mkdir -p "$toolbox_channel/241.1" "$toolbox_channel/241.2" "$toolbox_channel/current"
    touch -t 202401010000 "$toolbox_channel/241.1"
    touch -t 202402010000 "$toolbox_channel/241.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1"; }
MOLE_JETBRAINS_TOOLBOX_KEEP=1
clean_dev_jetbrains_toolbox
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/241.1"* ]] || return 1
    [[ "$output" != *"/241.2"* ]]
}

@test "clean_dev_ai_agents keeps newest version and removes older ones by mtime" {
    local claude_root="$HOME/.local/share/claude/versions"
    local cursor_root="$HOME/.local/share/cursor-agent/versions"
    local copilot_root="$HOME/.copilot/pkg/universal"
    mkdir -p "$claude_root" "$cursor_root" "$copilot_root"
    touch -t 202604170829 "$claude_root/2.1.112"
    touch -t 202604180902 "$claude_root/2.1.113"
    touch -t 202604181002 "$claude_root/2.1.114"
    mkdir -p "$cursor_root/2026.04.08-old" "$cursor_root/2026.04.15-new"
    touch -t 202604080000 "$cursor_root/2026.04.08-old"
    touch -t 202604150000 "$cursor_root/2026.04.15-new"
    mkdir -p "$copilot_root/1.0.5" "$copilot_root/1.0.32" "$copilot_root/1.0.34"
    touch -t 202604010000 "$copilot_root/1.0.5"
    touch -t 202604200000 "$copilot_root/1.0.32"
    touch -t 202604250000 "$copilot_root/1.0.34"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1|$2"; }
clean_dev_ai_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/2.1.112|Claude Code old version"* ]] || return 1
    [[ "$output" == *"/2.1.113|Claude Code old version"* ]] || return 1
    [[ "$output" != *"/2.1.114|"* ]] || return 1
    [[ "$output" == *"/2026.04.08-old|Cursor Agent old version"* ]] || return 1
    [[ "$output" != *"/2026.04.15-new|"* ]] || return 1
    [[ "$output" == *"/1.0.5|GitHub Copilot CLI old version"* ]] || return 1
    [[ "$output" == *"/1.0.32|GitHub Copilot CLI old version"* ]] || return 1
    [[ "$output" != *"/1.0.34|"* ]]
}

@test "clean_dev_ai_agents protects the active version pointed at by ~/.local/bin/<agent>" {
    local claude_root="$HOME/.local/share/claude/versions"
    local cursor_root="$HOME/.local/share/cursor-agent/versions"
    local bin_dir="$HOME/.local/bin"
    rm -rf "$claude_root" "$cursor_root" "$bin_dir"
    mkdir -p "$claude_root" "$cursor_root" "$bin_dir"

    mkdir -p "$claude_root/2.1.112" "$claude_root/2.1.113" "$claude_root/2.1.114"
    touch -t 202604170000 "$claude_root/2.1.112"
    touch -t 202604180000 "$claude_root/2.1.113"
    touch -t 202604200000 "$claude_root/2.1.114"
    ln -s "$claude_root/2.1.113" "$bin_dir/claude"

    mkdir -p "$cursor_root/2026.04.01-old" "$cursor_root/2026.04.10-active" "$cursor_root/2026.04.20-newest"
    touch -t 202604010000 "$cursor_root/2026.04.01-old"
    touch -t 202604100000 "$cursor_root/2026.04.10-active"
    touch -t 202604200000 "$cursor_root/2026.04.20-newest"
    : > "$cursor_root/2026.04.10-active/cursor-agent"
    ln -s "$cursor_root/2026.04.10-active/cursor-agent" "$bin_dir/cursor-agent"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1|$2"; }
clean_dev_ai_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/2.1.112|Claude Code old version"* ]] || return 1
    [[ "$output" != *"/2.1.113|"* ]] || return 1
    [[ "$output" != *"/2.1.114|"* ]] || return 1
    [[ "$output" == *"/2026.04.01-old|Cursor Agent old version"* ]] || return 1
    [[ "$output" != *"/2026.04.10-active|"* ]] || return 1
    [[ "$output" != *"/2026.04.20-newest|"* ]]
}

@test "clean_dev_ai_agents skips cleanup entirely when the active symlink is broken" {
    local claude_root="$HOME/.local/share/claude/versions"
    local bin_dir="$HOME/.local/bin"
    rm -rf "$claude_root" "$bin_dir"
    mkdir -p "$claude_root" "$bin_dir"

    mkdir -p "$claude_root/2.1.112" "$claude_root/2.1.113" "$claude_root/2.1.114"
    touch -t 202604170000 "$claude_root/2.1.112"
    touch -t 202604180000 "$claude_root/2.1.113"
    touch -t 202604200000 "$claude_root/2.1.114"
    ln -s "$claude_root/2.1.999-missing" "$bin_dir/claude"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1|$2"; }
clean_dev_ai_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"|Claude Code old version"* ]] || return 1
    [[ "$output" == *"Claude Code old version · skipped (active symlink broken)"* ]] || return 1

    rm -f "$bin_dir/claude"
}

@test "clean_dev_ai_agents respects MOLE_AI_AGENTS_KEEP and skips missing roots" {
    local claude_root="$HOME/.local/share/claude/versions"
    # Earlier cases in this file seed versions under the shared HOME; without a
    # reset this sees five versions instead of three and KEEP=2 sweeps 2.1.101 too.
    rm -rf "$claude_root"
    mkdir -p "$claude_root"
    touch -t 202604170000 "$claude_root/2.1.100"
    touch -t 202604180000 "$claude_root/2.1.101"
    touch -t 202604190000 "$claude_root/2.1.102"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1"; }
MOLE_AI_AGENTS_KEEP=2 clean_dev_ai_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/2.1.100"* ]] || return 1
    [[ "$output" != *"/2.1.101"* ]] || return 1
    [[ "$output" != *"/2.1.102"* ]]
}

@test "clean_dev_jetbrains_logs only targets JetBrains logs" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf '%s|%s\n' "$1" "$2"; }
clean_dev_jetbrains_logs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/Library/Logs/JetBrains/*|JetBrains IDE logs"* ]] || return 1
    [[ "$output" != *"Library/Caches/JetBrains"* ]]
}

@test "clean_developer_tools includes JetBrains logs but not JetBrains cache sweep" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
stop_section_spinner() { :; }
note_activity() { :; }
safe_clean() { printf '%s|%s\n' "$1" "$2"; }
clean_tool_cache() { :; }
check_rust_toolchains() { :; }
clean_dev_npm() { :; }
clean_dev_python() { :; }
clean_dev_go() { :; }
clean_dev_mise() { :; }
clean_dev_rust() { :; }
clean_dev_docker() { :; }
clean_dev_cloud() { :; }
clean_dev_nix() { :; }
clean_dev_shell() { :; }
clean_dev_frontend() { :; }
clean_project_caches() { :; }
clean_dev_mobile() { :; }
clean_dev_jvm() { :; }
clean_dev_jetbrains_toolbox() { :; }
clean_dev_ai_agents() { :; }
clean_dev_other_langs() { :; }
clean_dev_cicd() { :; }
clean_dev_database() { :; }
clean_dev_api_tools() { :; }
clean_dev_network() { :; }
clean_dev_misc() { :; }
clean_dev_elixir() { :; }
clean_dev_haskell() { :; }
clean_dev_ocaml() { :; }
clean_xcode_tools() { :; }
clean_code_editors() { :; }
clean_homebrew() { :; }
clean_developer_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/Library/Logs/JetBrains/*|JetBrains IDE logs"* ]] || return 1
    [[ "$output" != *"Library/Caches/JetBrains"* ]] || return 1
    [[ "$output" == *"$HOME/Library/Caches/Homebrew/downloads/*|Homebrew cache"* ]] || return 1
    [[ "$output" != *"$HOME/Library/Caches/Homebrew/*|Homebrew cache"* ]] || return 1
    [[ "$output" != *"Library/Caches/Homebrew/api"* ]] || return 1
    [[ "$output" != *"Library/Caches/Homebrew/bootsnap"* ]]
}

@test "clean_dev_misc protects Claude Code and OpenCode recovery state" {
    mkdir -p "$HOME/.claude/projects/project-a/memory"
    mkdir -p "$HOME/.claude/plugins/cache/plugin-a"
    mkdir -p "$HOME/.claude/plugins/marketplaces"
    mkdir -p "$HOME/.claude/paste-cache"
    mkdir -p "$HOME/.claude/tmp"
    mkdir -p "$HOME/.claude/session-env"
    mkdir -p "$HOME/.claude/shell-snapshots"
    mkdir -p "$HOME/.local/share/opencode/snapshot/project"
    mkdir -p "$HOME/.local/share/opencode/log"
    mkdir -p "$HOME/.cache/opencode"
    mkdir -p "$HOME/Library/Application Support/Claude/pending-uploads"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf 'SAFE:%s|%s\n' "$1" "$2"; }
safe_find_delete() { printf 'FIND:%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }
clean_service_worker_cache() { :; }
clean_dev_misc
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"$HOME/.claude/projects"* ]] || return 1
    [[ "$output" != *"$HOME/.claude/plugins/cache"* ]] || return 1
    [[ "$output" != *"$HOME/.claude/plugins/marketplaces"* ]] || return 1
    [[ "$output" != *"$HOME/.claude/paste-cache"* ]] || return 1
    [[ "$output" != *"$HOME/.claude/tmp"* ]] || return 1
    [[ "$output" != *"$HOME/.claude/session-env"* ]] || return 1
    [[ "$output" != *"$HOME/.local/share/opencode/snapshot"* ]] || return 1
    [[ "$output" != *"$HOME/.local/share/opencode/log"* ]] || return 1
    [[ "$output" != *"$HOME/Library/Application Support/Claude/pending-uploads"* ]] || return 1
    [[ "$output" == *"$HOME/.cache/opencode"* ]] || return 1
    [[ "$output" != *"$HOME/.claude/shell-snapshots"* ]]
}

@test "clean_xcode_simulator_runtime_volumes shows scan progress and skips sizing in-use volumes" {
    local volumes_root="$HOME/sim-volumes"
    local cryptex_root="$HOME/sim-cryptex"
    mkdir -p "$volumes_root/in-use-runtime" "$volumes_root/unused-runtime"
    mkdir -p "$cryptex_root"

    # The "scanning N entries" line is deliberately gated behind MO_DEBUG (the
    # spinner carries the feedback otherwise), so this case has to ask for it.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$volumes_root" MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$cryptex_root" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

size_log="$HOME/size-calls.log"
: > "$size_log"
DRY_RUN=false

note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
_sim_runtime_mount_points() {
    printf '%s\n' "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/in-use-runtime"
}
_sim_runtime_size_kb() {
    local target_path="$1"
    echo "$target_path" >> "$size_log"
    echo "1"
}
safe_sudo_remove() {
    local target_path="$1"
    echo "REMOVE:$target_path"
    return 0
}

clean_xcode_simulator_runtime_volumes
echo "SIZE_LOG_START"
cat "$size_log"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode runtime volumes · scanning 2 entries"* ]] || return 1
    # 16a8bcaf consolidated the per-stage "cleaning N unused" line into one final
    # result message; assert the line that survived.
    [[ "$output" == *"Xcode runtime volumes · removed 1 ("* ]] || return 1
    [[ "$output" == *"REMOVE:$volumes_root/unused-runtime"* ]] || return 1
    [[ "$output" == *"$volumes_root/unused-runtime"* ]] || return 1
    [[ "$output" != *"$volumes_root/in-use-runtime"* ]]
}

@test "clean_xcode_simulator_runtime_volumes deletes nothing when mount enumeration fails" {
    local volumes_root="$HOME/sim-volumes"
    mkdir -p "$volumes_root/runtime-a" "$volumes_root/runtime-b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$volumes_root" MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/none" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

DRY_RUN=false
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
# mount failed: no lines. Without the guard every runtime is UNUSED and deleted.
_sim_runtime_mount_points() { printf ''; }
_sim_runtime_size_kb() { echo "1"; }
safe_sudo_remove() { echo "REMOVE:$1"; return 0; }

clean_xcode_simulator_runtime_volumes

# Positive control. The guard makes this path print nothing at all, so "no
# REMOVE line" alone cannot tell a working guard from a run that never reached
# the deletion branch. Same fixture, this time with mounts enumerable.
echo "CONTROL"
_sim_runtime_mount_points() { printf '%s\n' "/"; }
clean_xcode_simulator_runtime_volumes
EOF

    [ "$status" -eq 0 ] || return 1
    guarded="${output%%CONTROL*}"
    control="${output#*CONTROL}"
    [[ "$guarded" != *"REMOVE:"* ]] || {
        echo "deleted a volume despite unknown mount state"
        return 1
    }
    [[ "$control" == *"REMOVE:"* ]] || {
        echo "control run removed nothing, so the guarded run proves nothing"
        return 1
    }
}

@test "clean_xcode_simulator_runtime_volumes rechecks mounts after sizing" {
    local volumes_root="$HOME/sim-volumes-race"
    mkdir -p "$volumes_root/runtime-a"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$volumes_root" MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/none" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
_sim_runtime_mount_points() {
    printf 'probe\n' >> "$HOME/mount-probes"
    local round
    round=$(wc -l < "$HOME/mount-probes" | tr -d ' ')
    if [[ $round -eq 1 ]]; then
        printf '%s\n' "/"
    else
        printf '%s\n' "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/runtime-a"
    fi
}
_sim_runtime_size_kb() { echo 1; }
safe_sudo_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }

rm -f "$HOME/mount-probes"
clean_xcode_simulator_runtime_volumes
[[ -d "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/runtime-a" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode runtime volumes · stopped (runtime became mounted)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_xcode_simulator_runtime_volumes reports deletion failures" {
    local volumes_root="$HOME/sim-volumes-failed"
    mkdir -p "$volumes_root/runtime-a"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$volumes_root" MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/none" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
_sim_runtime_mount_points() { printf '%s\n' "/"; }
_sim_runtime_size_kb() { echo 1; }
safe_sudo_remove() { return 1; }
clean_xcode_simulator_runtime_volumes
[[ -d "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/runtime-a" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode runtime volumes · could not remove 1 entries"* ]] || return 1
    [[ "$output" != *"already clean"* ]]
}

@test "clean_xcode_simulator_runtime_volumes reports a mount stop after an earlier failure" {
    local volumes_root="$HOME/sim-volumes-failure-stop"
    mkdir -p "$volumes_root/runtime-a" "$volumes_root/runtime-b"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$volumes_root" MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/none" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
_sim_runtime_mount_points() {
    printf 'probe\n' >> "$HOME/mount-failure-stop-probes"
    local round
    round=$(wc -l < "$HOME/mount-failure-stop-probes" | tr -d ' ')
    if [[ $round -le 2 ]]; then
        printf '%s\n' "/"
    else
        printf '%s\n' "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/runtime-b"
    fi
}
_sim_runtime_size_kb() { echo 1; }
safe_sudo_remove() { return 1; }

rm -f "$HOME/mount-failure-stop-probes"
clean_xcode_simulator_runtime_volumes
[[ -d "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/runtime-a" ]] || exit 1
[[ -d "$MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT/runtime-b" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Xcode runtime volumes · could not remove 1 entries"* ]] || return 1
    [[ "$output" == *"Xcode runtime volumes · stopped (runtime became mounted)"* ]]
}

@test "clean_dev_mobile leaves an idle section when no unavailable simulator exists" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=true \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
_xcode_safe_clean_guarded() { :; }
xcrun() { :; }
_resolve_simctl_developer_dir() {
    _MOLE_SIMCTL_RESOLUTION_STATUS="ready"
    _MOLE_SIMCTL_DEVELOPER_DIR="$HOME/Xcode.app/Contents/Developer"
}
_run_simctl() { return 0; }
debug_log() { :; }
DRY_RUN=true
start_section "Developer tools"
clean_dev_mobile
end_section
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Developer tools"*"Nothing to clean"* ]]
}

@test "clean_dev_mobile continues cleanup when simctl is unavailable" {
    local tmp_bin
    tmp_bin="$HOME/simctl-unavailable-bin"
    mkdir -p "$tmp_bin"
    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
exit 1
XEOF
    cat > "$tmp_bin/xcode-select" << 'XEOF'
#!/bin/bash
printf '/Library/Developer/CommandLineTools\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

_MOLE_SIMCTL_XCODE_APP_ROOTS=("$HOME/EmptyApplications")
mkdir -p "${_MOLE_SIMCTL_XCODE_APP_ROOTS[0]}"
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { echo "DEVICE_SUPPORT:$2"; }
safe_clean() { echo "SAFE_CLEAN:$2"; }
safe_clean_guarded() { echo "SAFE_CLEAN_GUARDED:$1:${*: -1}"; }
note_activity() { :; }
debug_log() { :; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"simctl could not be resolved"* ]] || return 1
    [[ "$output" == *"DEVICE_SUPPORT:iOS DeviceSupport"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN_GUARDED:_coresimulator_delete_guard_allows:Simulator runtime cache"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN_GUARDED:_xcode_delete_guard_allows:Xcode Interface Builder cache"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Android SDK cache"* ]] || return 1
}

@test "clean_dev_mobile retries simctl probe on cold-boot timeout (#890)" {
    # Exercises the timeout-retry branch (the only path the #890 fix touches).
    # Strategy:
    #   - put a real `xcrun` shim on PATH so `command -v xcrun` succeeds AND
    #     `declare -F xcrun` returns false → function falls into the else branch.
    #   - stub `run_with_timeout` so the first probe returns 124 (timeout) and
    #     the second returns 0, mirroring a cold-boot CoreSimulatorService
    #     warmup.
    #   - the shim itself returns empty for the post-probe
    #     `xcrun simctl list devices unavailable` call so we take the
    #     "already clean" branch and don't try to delete anything.
    local tmp_bin
    tmp_bin="$HOME/simctl-retry-bin"
    mkdir -p "$tmp_bin" "$HOME/Xcode.app/Contents/Developer"
    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
exit 0
XEOF
    cat > "$tmp_bin/xcode-select" << XEOF
#!/bin/bash
printf '$HOME/Xcode.app/Contents/Developer\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { echo "debug: $*"; }
sleep() { echo "UNEXPECTED_SLEEP:$*"; return 99; }

# First call (5s timeout) simulates cold-boot warmup → return 124.
# Second call (8s timeout) succeeds.
__rwt_count=0
run_with_timeout() {
    shift
    case " $* " in
        *" xcrun simctl list devices ")
            __rwt_count=$((__rwt_count + 1))
            if [[ $__rwt_count -eq 1 ]]; then
                return 124
            fi
            ;;
    esac
    "$@"
}

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"simctl probe succeeded on retry"* ]] || return 1
    [[ "$output" != *"simctl not available"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SLEEP"* ]] || return 1
}

@test "clean_dev_mobile classifies simctl probe failures and sanitizes debug output (#1304)" {
    local tmp_bin
    tmp_bin="$HOME/simctl-classification-bin"
    mkdir -p "$tmp_bin" "$HOME/Xcode.app/Contents/Developer"
    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
exit 0
XEOF
    chmod +x "$tmp_bin/xcrun"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { echo "DEBUG:$*"; }
_resolve_simctl_developer_dir() {
    _MOLE_SIMCTL_DEVELOPER_DIR="$HOME/Xcode.app/Contents/Developer"
    _MOLE_SIMCTL_RESOLUTION_STATUS="ready"
}

_run_simctl() {
    local timeout_seconds="$1"
    shift
    if [[ "$*" == "list devices" ]]; then
        __probe_call=$((__probe_call + 1))
        printf '%b' "$PROBE_STDERR" >&2
        if [[ $__probe_call -eq 1 ]]; then
            return "$PROBE_FIRST_STATUS"
        fi
        return "$PROBE_RETRY_STATUS"
    fi
    if [[ "$*" == "list devices unavailable" ]]; then
        return 0
    fi
    return 1
}

run_probe_case() {
    local label="$1"
    PROBE_FIRST_STATUS="$2"
    PROBE_RETRY_STATUS="$3"
    __probe_call=0
    PROBE_STDERR="$HOME/Library/Developer/private"$'\n\033[31mprobe failed\033[0m\n'
    printf 'CASE:%s\n' "$label"
    clean_dev_mobile
}

run_probe_case retry-success 124 0
run_probe_case timeout 124 124
run_probe_case failure 7 7
run_probe_case failure-then-timeout 7 124
run_probe_case timeout-then-failure 124 7
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEBUG:simctl probe statuses: first=124 retry=0"* ]] || return 1
    [[ "$output" == *"Xcode unavailable simulators · simctl probe timed out"* ]] || return 1
    [[ "$output" == *"Xcode unavailable simulators · simctl probe failed (exit=7)"* ]] || return 1
    [[ "$output" == *"DEBUG:simctl probe statuses: first=7 retry=124"* ]] || return 1
    [[ "$output" == *"DEBUG:simctl probe first stderr: ~/Library/Developer/private [31mprobe failed[0m"* ]] || return 1
    [[ "$output" != *"$HOME/Library/Developer/private"* ]] || return 1
}

@test "clean_dev_mobile uses the sole Xcode Beta candidate when CLT is selected (#1261)" {
    local tmp_bin candidate developer_dir
    tmp_bin="$HOME/simctl-single-bin"
    candidate="$HOME/Applications/Xcode-Beta.app"
    developer_dir="$candidate/Contents/Developer"
    mkdir -p "$tmp_bin" "$developer_dir"

    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
if [[ "$*" == "--find simctl" ]]; then
    [[ "${DEVELOPER_DIR:-}" == "$EXPECTED_DEVELOPER_DIR" ]] || exit 1
    exit
fi
printf '%s|%s\n' "${DEVELOPER_DIR:-}" "$*" >> "$SIMCTL_CALL_LOG"
case "$*" in
    "simctl list devices")
        exit 0
        ;;
    "simctl list devices unavailable")
        printf '    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)\n'
        exit 0
        ;;
esac
exit 1
XEOF
    cat > "$tmp_bin/xcode-select" << 'XEOF'
#!/bin/bash
printf '/Library/Developer/CommandLineTools\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" \
        DRY_RUN=true EXPECTED_DEVELOPER_DIR="$developer_dir" \
        SIMCTL_CALL_LOG="$HOME/simctl-single.log" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

_MOLE_SIMCTL_XCODE_APP_ROOTS=("$HOME/Applications")
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { :; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Xcode unavailable simulators · would clean 1"* ]] || return 1
    [[ -s "$HOME/simctl-single.log" ]] || return 1
    while IFS= read -r call; do
        [[ "$call" == "$developer_dir|"* ]] || return 1
    done < "$HOME/simctl-single.log"
}

@test "clean_dev_mobile skips ambiguous Xcode candidates without choosing one (#1261)" {
    local tmp_bin
    tmp_bin="$HOME/simctl-ambiguous-bin"
    mkdir -p "$tmp_bin"
    for app in Xcode.app Xcode-Beta.app; do
        mkdir -p "$HOME/Applications/$app/Contents/Developer"
    done

    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
if [[ "$*" == "--find simctl" ]]; then
    [[ "${DEVELOPER_DIR:-}" == "$HOME/Applications/Xcode.app/Contents/Developer" ||
        "${DEVELOPER_DIR:-}" == "$HOME/Applications/Xcode-Beta.app/Contents/Developer" ]]
    exit
fi
printf '%s\n' "$*" >> "$SIMCTL_CALL_LOG"
exit 0
XEOF
    cat > "$tmp_bin/xcode-select" << 'XEOF'
#!/bin/bash
printf '/Library/Developer/CommandLineTools\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" \
        SIMCTL_CALL_LOG="$HOME/simctl-ambiguous.log" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

_MOLE_SIMCTL_XCODE_APP_ROOTS=("$HOME/Applications")
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { echo "DEBUG:$*"; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"multiple Xcode apps found; set DEVELOPER_DIR"* ]] || return 1
    [[ "$output" == *"DEBUG:simctl Xcode candidate: $HOME/Applications/Xcode.app"* ]] || return 1
    [[ "$output" == *"DEBUG:simctl Xcode candidate: $HOME/Applications/Xcode-Beta.app"* ]] || return 1
    [[ ! -e "$HOME/simctl-ambiguous.log" ]] || return 1
}

@test "clean_dev_mobile does not replace a selected full Xcode when simctl is unavailable" {
    local tmp_bin selected candidate
    tmp_bin="$HOME/simctl-selected-invalid-bin"
    selected="$HOME/Applications/Xcode-Selected.app/Contents/Developer"
    candidate="$HOME/Applications/Xcode-Beta.app/Contents/Developer"
    mkdir -p "$tmp_bin" "$selected" "$candidate"

    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
printf '%s|%s\n' "${DEVELOPER_DIR:-}" "$*" >> "$SIMCTL_CALL_LOG"
if [[ "${DEVELOPER_DIR:-}" == "$CANDIDATE_DEVELOPER_DIR" ]]; then
    exit 0
fi
exit 1
XEOF
    cat > "$tmp_bin/xcode-select" << XEOF
#!/bin/bash
printf '$selected\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    # GitHub's macOS image exports DEVELOPER_DIR. This case exercises the
    # xcode-select branch, so inherited toolchain state must not change it.
    run env -u DEVELOPER_DIR HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" \
        CANDIDATE_DEVELOPER_DIR="$candidate" \
        SIMCTL_CALL_LOG="$HOME/simctl-selected-invalid.log" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

_MOLE_SIMCTL_XCODE_APP_ROOTS=("$HOME/Applications")
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { :; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"simctl could not be resolved"* ]] || return 1
    local actual_calls
    actual_calls=$(cat "$HOME/simctl-selected-invalid.log")
    [[ -n "$actual_calls" ]] || return 1
    local actual_call
    while IFS= read -r actual_call; do
        if [[ "$actual_call" != "$selected|--find simctl" ]]; then
            printf 'unexpected simctl resolution call: %q\n' "$actual_call" >&2
            return 1
        fi
    done <<< "$actual_calls"
    [[ "$actual_calls" != *"$candidate|"* ]] || return 1
}

@test "clean_dev_mobile does not override an invalid explicit DEVELOPER_DIR (#1261)" {
    local tmp_bin candidate
    tmp_bin="$HOME/simctl-explicit-invalid-bin"
    candidate="$HOME/Applications/Xcode-Beta.app/Contents/Developer"
    mkdir -p "$tmp_bin" "$candidate"

    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SIMCTL_CALL_LOG"
exit 0
XEOF
    cat > "$tmp_bin/xcode-select" << 'XEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$XCODE_SELECT_CALL_LOG"
printf '/Library/Developer/CommandLineTools\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" \
        DEVELOPER_DIR="$HOME/MissingXcode.app/Contents/Developer" \
        SIMCTL_CALL_LOG="$HOME/simctl-explicit-invalid.log" \
        XCODE_SELECT_CALL_LOG="$HOME/xcode-select-explicit-invalid.log" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

_MOLE_SIMCTL_XCODE_APP_ROOTS=("$HOME/Applications")
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { :; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEVELOPER_DIR has no simctl"* ]] || return 1
    [[ ! -e "$HOME/simctl-explicit-invalid.log" ]] || return 1
    [[ ! -e "$HOME/xcode-select-explicit-invalid.log" ]] || return 1
}

@test "clean_dev_mobile does not race a timed-out simctl delete with manual removal" {
    local tmp_bin developer_dir
    tmp_bin="$HOME/simctl-delete-failure-bin"
    developer_dir="$HOME/Xcode-delete-failure.app/Contents/Developer"
    mkdir -p "$tmp_bin" "$developer_dir" \
        "$HOME/Library/Developer/CoreSimulator/Devices/ABCDEF01-2345-6789-ABCD-EF0123456789"

    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
case "$*" in
    "--find simctl" | "simctl list devices")
        exit 0
        ;;
    "simctl list devices unavailable")
        printf '    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)\n'
        exit 0
        ;;
    "simctl delete unavailable")
        exit 124
        ;;
esac
exit 1
XEOF
    cat > "$tmp_bin/xcode-select" << XEOF
#!/bin/bash
printf '$developer_dir\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" \
        DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
safe_remove() { echo "UNEXPECTED_FALLBACK:$1"; return 1; }
note_activity() { :; }
debug_log() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Xcode unavailable simulators · cleanup timed out"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_FALLBACK"* ]] || return 1
    [[ "$output" != *"Xcode unavailable simulators · removed"* ]] || return 1
}

@test "clean_dev_mobile does not bypass simctl when a device becomes busy" {
    local tmp_bin developer_dir
    tmp_bin="$HOME/simctl-busy-bin"
    developer_dir="$HOME/Xcode-busy.app/Contents/Developer"
    mkdir -p "$tmp_bin" "$developer_dir" \
        "$HOME/Library/Developer/CoreSimulator/Devices/ABCDEF01-2345-6789-ABCD-EF0123456789"

    cat > "$tmp_bin/xcrun" << 'XEOF'
#!/bin/bash
case "$*" in
    "--find simctl" | "simctl list devices")
        exit 0
        ;;
    "simctl list devices unavailable")
        printf '    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)\n'
        exit 0
        ;;
    "simctl delete unavailable")
        printf 'device is busy\n' >&2
        exit 1
        ;;
esac
exit 1
XEOF
    cat > "$tmp_bin/xcode-select" << XEOF
#!/bin/bash
printf '$developer_dir\n'
XEOF
    chmod +x "$tmp_bin/xcrun" "$tmp_bin/xcode-select"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$tmp_bin:$PATH" \
        DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
safe_remove() { echo "UNEXPECTED_FALLBACK:$1"; return 1; }
note_activity() { :; }
debug_log() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"cleanup failed (device in use)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_FALLBACK"* ]] || return 1
    [[ "$output" != *"Xcode unavailable simulators · removed"* ]] || return 1
}

@test "clean_dev_mobile never deletes from a timed-out list or reports a timed-out recount as success" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        SIMCTL_SAFETY_LOG="$HOME/simctl-safety.log" \
        SIMCTL_RECOUNT_STATE="$HOME/simctl-recount.state" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
get_path_size_kb() { echo "1"; }
note_activity() { :; }
debug_log() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
cleanup_result_color_kb() { printf '%s' "$GREEN"; }
xcrun() { return 0; }
_resolve_simctl_developer_dir() {
    _MOLE_SIMCTL_DEVELOPER_DIR="$HOME/Xcode.app/Contents/Developer"
    _MOLE_SIMCTL_RESOLUTION_STATUS="ready"
}

scenario="list-timeout"
_run_simctl() {
    shift
    case "$*" in
        "list devices")
            return 0
            ;;
        "list devices unavailable")
            if [[ "$scenario" == "list-timeout" ]]; then
                echo "    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)"
                return 124
            fi
            if [[ ! -e "$SIMCTL_RECOUNT_STATE" ]]; then
                touch "$SIMCTL_RECOUNT_STATE"
                echo "    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)"
                return 0
            fi
            return 124
            ;;
        "delete unavailable")
            printf 'DELETE\n' >> "$SIMCTL_SAFETY_LOG"
            return 0
            ;;
    esac
    return 1
}

clean_dev_mobile
if [[ -e "$SIMCTL_SAFETY_LOG" ]]; then
    echo "UNEXPECTED_DELETE_AFTER_LIST_TIMEOUT"
fi

scenario="recount-timeout"
clean_dev_mobile
printf 'DELETE_COUNT=%s\n' "$(wc -l < "$SIMCTL_SAFETY_LOG" | tr -d ' ')"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"simctl list failed (exit=124)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE_AFTER_LIST_TIMEOUT"* ]] || return 1
    [[ "$output" == *"cleanup completed, unable to verify remaining devices"* ]] || return 1
    [[ "$output" == *"DELETE_COUNT=1"* ]] || return 1
    [[ "$output" != *"removed 1"* ]] || return 1
}

@test "clean_dev_mobile stops before simctl delete when unavailable-device sizing times out" {
    local case_home="$HOME/simctl-size-timeout"
    local udid="ABCDEF01-2345-6789-ABCD-EF0123456789"
    mkdir -p "$case_home/Library/Developer/CoreSimulator/Devices/$udid"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        SIMCTL_CALL_LOG="$case_home/simctl-calls.log" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_system_coresimulator_caches() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_xctest_devices() { :; }
clean_xcode_device_support() { :; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { :; }
xcrun() { :; }
_resolve_simctl_developer_dir() {
    _MOLE_SIMCTL_DEVELOPER_DIR="$HOME/Xcode.app/Contents/Developer"
    _MOLE_SIMCTL_RESOLUTION_STATUS="ready"
}
_run_simctl() {
    shift
    printf '%s\n' "$*" >> "$SIMCTL_CALL_LOG"
    case "$*" in
        "list devices") return 0 ;;
        "list devices unavailable")
            printf '    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)\n'
            return 0
            ;;
        "delete unavailable") return 0 ;;
    esac
    return 1
}
get_path_size_kb() { return 124; }

set +e
clean_dev_mobile
rc=$?
set -e
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=124 CANCEL=124"* ]] || return 1
    [[ -f "$case_home/simctl-calls.log" ]] || return 1
    if grep -q '^delete unavailable$' "$case_home/simctl-calls.log"; then
        return 1
    fi
}

@test "clean_dev_ai_agents protects the copilot version pointed at by ~/.local/bin/copilot" {
    local copilot_root="$HOME/.copilot/pkg/universal"
    local bin_dir="$HOME/.local/bin"
    rm -rf "$HOME/.copilot" "$HOME/.local/share/claude" "$HOME/.local/share/cursor-agent" "$bin_dir"
    mkdir -p "$copilot_root" "$bin_dir"

    mkdir -p "$copilot_root/1.0.5" "$copilot_root/1.0.32" "$copilot_root/1.0.34"
    : > "$copilot_root/1.0.32/copilot"
    ln -s "../../.copilot/pkg/universal/1.0.32/copilot" "$bin_dir/copilot"

    # Keep the active version older than a pre-downloaded update. The launcher,
    # not mtime order, must decide which version remains pinned.
    touch -t 202604010000 "$copilot_root/1.0.5"
    touch -t 202604200000 "$copilot_root/1.0.32"
    touch -t 202604250000 "$copilot_root/1.0.34"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1|$2"; }
clean_dev_ai_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/1.0.5|GitHub Copilot CLI old version"* ]] || return 1
    [[ "$output" != *"/1.0.32|"* ]] || return 1
    [[ "$output" != *"/1.0.34|"* ]]
}

@test "developer cleanup stops before later tools after agent inventory cancellation" {
    run env HOME="$HOME/developer-aggregate-timeout" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
stop_section_spinner() { :; }
for fn in \
    clean_dev_npm clean_dev_python clean_dev_go clean_dev_mise clean_dev_rust \
    check_rust_toolchains clean_dev_ruby clean_dev_perl clean_dev_docker \
    clean_dev_cloud clean_dev_nix clean_dev_shell clean_dev_frontend \
    clean_project_caches clean_dev_mobile clean_dev_jvm \
    clean_dev_jetbrains_toolbox clean_dev_jetbrains_logs; do
    eval "$fn() { :; }"
done
clean_dev_ai_agents() {
    _mole_record_clean_cancellation 124
    return 124
}
clean_dev_other_langs() { echo "UNEXPECTED_LATER_DELETE"; }
set +e
clean_developer_tools
rc=$?
set -e
printf 'DEVELOPER_RC:%s CANCEL:%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEVELOPER_RC:124 CANCEL:124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_LATER_DELETE"* ]]
}
