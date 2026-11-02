#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home app-caches

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    mole_test_teardown_home
}

make_fusion_version_dir() {
    local version_dir="$1"
    local version="$2"
    local bundle_id="${3:-com.autodesk.fusion360}"
    local app_name="${4:-Autodesk Fusion.app}"
    local info_plist="$version_dir/$app_name/Contents/Info.plist"
    mkdir -p "$(dirname "$info_plist")" "$version_dir/$app_name/Contents/MacOS"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" \
        -c "Add :CFBundleVersion string $version" \
        -c "Add :CFBundleExecutable string Autodesk Fusion" \
        "$info_plist" > /dev/null
    touch "$version_dir/$app_name/Contents/MacOS/Autodesk Fusion"
    chmod +x "$version_dir/$app_name/Contents/MacOS/Autodesk Fusion"
}

assert_cache_final_owner_guard() {
    run env HOME="$BATS_TEST_TMPDIR/cache-home" PROJECT_ROOT="$PROJECT_ROOT" \
        scenario="$1" family="$2" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
if [[ "$family" == shared ]]; then
    fixture_entry="$HOME/Library/Application Support/CodeBuddyExtension/Cache/entry"
else
    fixture_entry="$HOME/Library/Application Support/discord/Cache/entry"
fi
mkdir -p "${fixture_entry%/*}"
printf payload > "$fixture_entry"
mkdir -p "$HOME/authored"
printf keep > "$HOME/authored/entry"
pgrep() {
    printf '%s %s\n' "$1" "${2:-}" >> "$HOME/probes"
    [[ "$scenario" != initial-running ]] || return 0
    if [[ -f "$HOME/final-stage" || "$scenario" == post-size-swap ]]; then
        case "$scenario" in
            final-swap|post-size-swap)
                if [[ ! -L "${fixture_entry%/*}" ]]; then
                    mv "${fixture_entry%/*}" "${fixture_entry%/*}.old"
                    ln -s "$HOME/authored" "${fixture_entry%/*}"
                fi
                return 1 ;;
            final-running|outer-start) return 0 ;;
            final-unknown) return 2 ;;
        esac
    fi
    return 1
}
note_activity() { :; }
get_cleanup_path_size_kb() { printf '1\n'; }
clean_editor_obsolete_extensions() { :; }
eval "$(declare -f validate_path_for_deletion | sed '1s/validate_path_for_deletion/_original_validate/')"
validate_path_for_deletion() {
    _original_validate "$@" || return $?
    [[ "$scenario" == outer-* ]] || touch "$HOME/final-stage"
}
outer_guard() {
    printf 'outer\n' >> "$HOME/outer-calls"
    case "$scenario" in
        outer-deny) return 1 ;;
        outer-signal) return 130 ;;
        outer-start) touch "$HOME/final-stage" ;;
    esac
    return 0
}
_MOLE_SAFE_REMOVE_FINAL_GUARD=outer_guard
rc=0
if [[ "$family" == shared ]]; then
    clean_code_editors || rc=$?
else
    mole_safe_clean_app_cache Discord "$fixture_entry" 'Discord cache' || rc=$?
fi
[[ "$_MOLE_SAFE_REMOVE_FINAL_GUARD" == outer_guard ]] || exit 1
case "$scenario" in
    idle) [[ ! -e "$fixture_entry" ]] || exit 1 ;;
    *) [[ -f "$fixture_entry" ]] || exit 1 ;;
esac
if [[ "$scenario" == outer-* || "$scenario" == idle ]]; then
    [[ -s "$HOME/outer-calls" ]] || exit 1
fi
if [[ "$scenario" == final-swap || "$scenario" == post-size-swap ]]; then
    [[ -f "$HOME/authored/entry" && -f "${fixture_entry%/*}.old/entry" ]] || exit 1
fi
if [[ "$scenario" == outer-signal ]]; then
    [[ "$rc" == 130 && "${MOLE_CLEAN_CANCEL_STATUS:-0}" == 130 ]] || exit 1
fi
printf 'PASS\n'
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *PASS* ]]
}


@test "clean_xcode_tools skips derived data when Xcode running" {
    local fixture_home="$HOME/xcode-running-derived-data"
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Developer/Xcode/DerivedData/FixtureProject"
mkdir -p "$target"
touch "$target/build.bin"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
running=true
pgrep() {
    printf '%s\n' "$*" >> "$HOME/process-trace"
    [[ "$running" == "true" && "$1" == -*x && "|$2|" == *"|Xcode|"* ]]
}
safe_clean() { printf '%s\n' "$@" >> "$HOME/clean-trace"; }
safe_remove() { printf '%s\n' "$1" >> "$HOME/clean-trace"; }
get_path_size_kb() { printf '1\n'; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
clean_xcode_tools
grep -qE -- '^-x (.*[|])?Xcode([|].*)?$' "$HOME/process-trace" || exit 1
[[ ! -e "$HOME/clean-trace" && -f "$target/build.bin" ]] || exit 1

# The same eligible project must reach the real cleanup path once Xcode exits.
running=false
clean_xcode_tools
grep -qxF "$target" "$HOME/clean-trace" || exit 1
printf 'PASS\n'
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PASS"* ]]
}

@test "clean_xcode_tools preserves device logs and user documentation stores" {
    local ios_log="$HOME/Library/Developer/Xcode/iOS Device Logs/sentinel.log"
    local watch_log="$HOME/Library/Developer/Xcode/watchOS Device Logs/sentinel.log"
    local doc_cache="$HOME/Library/Developer/Xcode/DocumentationCache/sentinel.doc"
    local doc_index="$HOME/Library/Developer/Xcode/DocumentationIndex/sentinel.index"
    mkdir -p "$(dirname "$ios_log")" "$(dirname "$watch_log")" \
        "$(dirname "$doc_cache")" "$(dirname "$doc_index")"
    touch "$ios_log" "$watch_log" "$doc_cache" "$doc_index"
    mkdir -p "$HOME/Library/Caches/com.apple.dt.Xcode"
    mkdir -p "$HOME/Library/Developer/Xcode/Products"
    touch "$HOME/Library/Caches/com.apple.dt.Xcode/candidate"
    touch "$HOME/Library/Developer/Xcode/Products/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "$2"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    # Xcode cache and build products are positive controls proving the cleanup
    # body ran; diagnostics and downloaded documentation must stay review-only.
    [[ "$output" == *"Xcode cache"* ]] || return 1
    [[ "$output" == *"Xcode build products"* ]] || return 1
    [[ "$output" != *"iOS device logs"* ]] || return 1
    [[ "$output" != *"watchOS device logs"* ]] || return 1
    [[ "$output" != *"Xcode documentation cache"* ]] || return 1
    [[ "$output" != *"Xcode documentation index"* ]] || return 1
    [[ "$output" != *"Xcode archives"* ]] || return 1
    [[ -f "$ios_log" && -f "$watch_log" && -f "$doc_cache" && -f "$doc_index" ]]
}

@test "clean_xcode_tools skips Xcode paths while xcodebuild is active" {
    local fixture_home="$HOME/xcodebuild-running-paths"
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache="$HOME/Library/Caches/com.apple.dt.Xcode/candidate"
product="$HOME/Library/Developer/Xcode/Products/candidate"
mkdir -p "${cache%/*}" "${product%/*}"
touch "$cache" "$product"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
running=true
pgrep() {
    printf '%s\n' "$*" >> "$HOME/process-trace"
    [[ "$running" == "true" && "$1" == -*x && "|$2|" == *"|xcodebuild|"* ]]
}
safe_clean() { printf '%s\n' "$@" >> "$HOME/clean-trace"; }
clean_xcode_tools
grep -qE -- '^-x (.*[|])?xcodebuild([|].*)?$' "$HOME/process-trace" || exit 1
[[ ! -e "$HOME/clean-trace" && -f "$cache" && -f "$product" ]] || exit 1

running=false
clean_xcode_tools
grep -qxF "$cache" "$HOME/clean-trace" || exit 1
grep -qxF "$product" "$HOME/clean-trace" || exit 1
printf 'PASS\n'
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"PASS"* ]]
}

@test "clean_xcode_tools fails closed when process state is unknown" {
    mkdir -p "$HOME/Library/Caches/com.apple.dt.Xcode"
    touch "$HOME/Library/Caches/com.apple.dt.Xcode/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 2; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"process state unknown"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_3d_tools defers Autodesk cache while Fusion helper is active (#1390)" {
    mkdir -p "$HOME/Library/Caches/com.autodesk.AcCoreConsole"
    touch "$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 0; }
safe_clean() {
    case "${!#}" in
        "Autodesk cache") echo "UNEXPECTED_CLEAN:${!#}" ;;
    esac
}
mole_defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_3d_tools
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Autodesk"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_3d_tools cleans Autodesk cache when Fusion is not running (#1390)" {
    mkdir -p "$HOME/Library/Caches/com.autodesk.AcCoreConsole"
    touch "$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "CLEAN:${!#}"; }
clean_3d_tools
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"CLEAN:Autodesk cache"* ]] || return 1
}

@test "clean_xcode_tools does not defer empty Xcode and Simulator roots" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
rm -rf "$HOME/Library/Caches/com.apple.dt.Xcode" \
    "$HOME/Library/Developer/Xcode/Products" \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    "$HOME/Library/Developer/CoreSimulator/Caches" \
    "$HOME/Library/Developer/CoreSimulator/Devices" \
    "$HOME/Library/Logs/CoreSimulator"
mkdir -p "$HOME/Library/Caches/com.apple.dt.Xcode" \
    "$HOME/Library/Developer/Xcode/Products" \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    "$HOME/Library/Developer/CoreSimulator/Caches" \
    "$HOME/Library/Developer/CoreSimulator/Devices" \
    "$HOME/Library/Logs/CoreSimulator"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]] || return 1
    [[ "$output" != *"process state unknown"* ]]
}

@test "clean_xcode_tools does not defer broken-symlink-only Xcode roots" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
rm -rf "$HOME/Library/Caches/com.apple.dt.Xcode" \
    "$HOME/Library/Developer/Xcode/Products" \
    "$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$HOME/Library/Caches/com.apple.dt.Xcode"
ln -s "$HOME/missing-xcode-cache" "$HOME/Library/Caches/com.apple.dt.Xcode/broken"
mkdir -p "$HOME/Library/Caches/com.apple.dt.Xcode/compiled/com.apple.e5rt.e5bundlecache"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_xcode_tools does not defer after a cache-only pass completes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
rm -rf "$HOME/Library/Caches/com.apple.dt.Xcode" \
    "$HOME/Library/Developer/Xcode/Products" \
    "$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$HOME/Library/Caches/com.apple.dt.Xcode"
touch "$HOME/Library/Caches/com.apple.dt.Xcode/candidate"

probe_round=0
_xcode_cleanup_process_state() {
    probe_round=$((probe_round + 1))
    [[ $probe_round -gt 2 ]] && return 0
    return 1
}
_app_cache_safe_clean_guarded() {
    local state=0
    _xcode_cleanup_process_state || state=$?
    [[ $state -eq 1 ]] || return 75
    command rm -f "$HOME/Library/Caches/com.apple.dt.Xcode/candidate"
    echo "CLEANED:Xcode cache"
}
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
clean_xcode_tools
[[ ! -e "$HOME/Library/Caches/com.apple.dt.Xcode/candidate" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"CLEANED:Xcode cache"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER"* ]]
}

@test "clean_xcode_tools ignores active whitelist-only candidates" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
rm -rf "$HOME/Library/Caches/com.apple.dt.Xcode" \
    "$HOME/Library/Developer/Xcode/Products" \
    "$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$HOME/Library/Caches/com.apple.dt.Xcode"
target="$HOME/Library/Caches/com.apple.dt.Xcode/whitelisted"
touch "$target"
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_xcode_tools removes per-device simulator data whole, only on shut-down devices" {
    local fixture_home="$HOME/simulator-device-leaves"
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
devices="$HOME/Library/Developer/CoreSimulator/Devices"
make_device() {
    mkdir -p "$devices/$1"
    /usr/bin/plutil -create xml1 "$devices/$1/device.plist"
    [[ -z "$2" ]] || /usr/bin/plutil -insert state -integer "$2" "$devices/$1/device.plist"
}
make_device OFF 1
make_device BOOTED 3
make_device UNKNOWN ""
make_device GONE 1
/usr/bin/plutil -insert isDeleted -bool true "$devices/GONE/device.plist"
store="$devices/OFF/data/Library/Application Support/PRBPosterExtensionDataStore"
mkdir -p "$store/descriptors" "$store/staticdescriptors" "$store/configurations"
touch "$store/staticdescriptors/render.heic"
mkdir -p "$devices/OFF/data/Library/Application Support/FileProvider"
touch "$devices/OFF/data/Library/Application Support/FileProvider/keep.db"
mkdir -p "$devices/OFF/data/Library/Caches/com.apple.Maps"
mkdir -p "$devices/OFF/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_Font"
mkdir -p "$devices/OFF/data/var/db/diagnostics"
for other in BOOTED UNKNOWN GONE; do
    mkdir -p "$devices/$other/data/Library/Caches/com.apple.Maps"
done
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
running=false
pgrep() { [[ "$running" == "true" && "$*" == *Simulator* ]]; }
safe_clean() { printf '%s\n' "$@" >> "$HOME/clean-trace"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
mole_defer_cleanup_family() { printf 'deferred %s\n' "$1" >> "$HOME/clean-trace"; }

running=true
clean_xcode_tools
! grep -q "PRBPosterExtensionDataStore\|/data/Library/Caches" "$HOME/clean-trace" || exit 1

: > "$HOME/clean-trace"
running=false
clean_xcode_tools
trace="$HOME/clean-trace"
grep -qxF "$store" "$trace" || exit 2
grep -qxF "$devices/OFF/data/Library/Caches" "$trace" || exit 3
grep -qxF "$devices/OFF/data/private/var/MobileAsset/AssetsV2" "$trace" || exit 4
# The store goes whole, never as its gallery descriptors; its siblings stay.
! grep -q "PRBPosterExtensionDataStore/" "$trace" || exit 5
! grep -q "FileProvider" "$trace" || exit 6
# An empty leaf is not listed, and only a shut-down, undeleted device counts.
! grep -q "var/db/diagnostics" "$trace" || exit 7
! grep -q "/BOOTED/\|/UNKNOWN/\|/GONE/" "$trace" || exit 8
printf 'PASS\n'
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PASS"* ]]
}

@test "simulator device leaves refuse links on the way and recheck the device before deleting" {
    local fixture_home="$HOME/simulator-device-guard"
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
devices="$HOME/Library/Developer/CoreSimulator/Devices"
for device in OFF LINKED; do
    mkdir -p "$devices/$device"
    /usr/bin/plutil -create xml1 "$devices/$device/device.plist"
    /usr/bin/plutil -insert state -integer 1 "$devices/$device/device.plist"
done
mkdir -p "$devices/OFF/data/Library/Caches/com.apple.Maps"
mkdir -p "$HOME/elsewhere/Library/Caches/keep"
mkdir -p "$devices/LINKED/data"
ln -s "$HOME/elsewhere/Library" "$devices/LINKED/data/Library"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }

listed=$(_simulator_device_leaf_targets)
[[ "$listed" == "$devices/OFF/data/Library/Caches" ]] || exit 1

leaf="$devices/OFF/data/Library/Caches"
_simulator_device_leaf_delete_guard_allows "$leaf" || exit 2
# The device booted after the scan: only this leaf is skipped.
/usr/bin/plutil -replace state -integer 3 "$devices/OFF/device.plist"
rc=0
_simulator_device_leaf_delete_guard_allows "$leaf" || rc=$?
[[ $rc -ne 0 && "$_MOLE_SAFE_CLEAN_SKIP_PATH" == "$leaf" ]] || exit 3
# A path outside the listed leaves is never accepted.
/usr/bin/plutil -replace state -integer 1 "$devices/OFF/device.plist"
mkdir -p "$devices/OFF/data/Documents"
! _simulator_device_leaf_is_eligible "$devices/OFF/data/Documents" || exit 4
printf 'PASS\n'
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PASS"* ]]
}

@test "clean_xcode_tools reports no simulator skip when every device leaf is whitelisted" {
    local fixture_home="$HOME/simulator-leaves-whitelisted"
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
devices="$HOME/Library/Developer/CoreSimulator/Devices"
mkdir -p "$devices/OFF/data/Library/Caches/com.apple.Maps"
/usr/bin/plutil -create xml1 "$devices/OFF/device.plist"
/usr/bin/plutil -insert state -integer 1 "$devices/OFF/device.plist"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
WHITELIST_PATTERNS=("$HOME/Library/Developer/CoreSimulator*")
pgrep() { [[ "$*" == *Simulator* ]]; }
safe_clean() { printf 'cleaned %s\n' "$@" >> "$HOME/clean-trace"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
mole_defer_cleanup_family() { printf 'deferred %s\n' "$1" >> "$HOME/clean-trace"; }
: > "$HOME/clean-trace"
[[ -n "$(_simulator_device_leaf_targets)" ]] || { echo "NO_LEAF_LISTED"; exit 1; }
clean_xcode_tools
if grep -q "deferred Simulator" "$HOME/clean-trace"; then cat "$HOME/clean-trace"; exit 1; fi
printf 'PASS\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"PASS"* ]]
}

@test "simulator device leaves go through the real sink, skipping only a device that booted" {
    local fixture_home="$HOME/simulator-leaves-real-sink"
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" \
        MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME"
devices="$HOME/Library/Developer/CoreSimulator/Devices"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
# The host may have a simulator booted; the fixture devices are what count.
_coresimulator_activity_state() { return 1; }
make_devices() {
    local device
    for device in A_BOOTS B_OFF; do
        mkdir -p "$devices/$device/data/Library/Caches/com.apple.Maps" \
            "$devices/$device/data/private/var/MobileAsset/AssetsV2/font"
        printf 'tile' > "$devices/$device/data/Library/Caches/com.apple.Maps/tile"
        printf 'asset' > "$devices/$device/data/private/var/MobileAsset/AssetsV2/font/asset"
        rm -f "$devices/$device/device.plist"
        /usr/bin/plutil -create xml1 "$devices/$device/device.plist"
        /usr/bin/plutil -insert state -integer 1 "$devices/$device/device.plist"
    done
}
# A_BOOTS is listed while shut down, then boots before its leaves are removed.
_simulator_app_cache_delete_guard_allows() {
    /usr/bin/plutil -replace state -integer 3 "$devices/A_BOOTS/device.plist"
    return 0
}
for DRY_RUN in true false; do
    export DRY_RUN
    make_devices
    clean_xcode_tools > "$HOME/out-$DRY_RUN.txt" 2>&1
    for leaf in data/Library/Caches data/private/var/MobileAsset/AssetsV2; do
        [[ -d "$devices/A_BOOTS/$leaf" ]] || { echo "BOOTED_LEAF_REMOVED:$DRY_RUN:$leaf"; exit 1; }
        if [[ "$DRY_RUN" == false ]]; then
            [[ ! -e "$devices/B_OFF/$leaf" ]] || { echo "OFF_LEAF_KEPT:$leaf"; cat "$HOME/out-$DRY_RUN.txt"; exit 1; }
        else
            [[ -d "$devices/B_OFF/$leaf" ]] || { echo "DRY_RUN_REMOVED:$leaf"; exit 1; }
        fi
    done
    [[ -d "$devices/B_OFF/data" && -f "$devices/B_OFF/device.plist" ]] || { echo "DEVICE_DAMAGED:$DRY_RUN"; exit 1; }
    grep -q "Simulator device data" "$HOME/out-$DRY_RUN.txt" || { echo "NO_ROW:$DRY_RUN"; cat "$HOME/out-$DRY_RUN.txt"; exit 1; }
done
printf 'PASS\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"PASS"* ]]
}

@test "clean_xcode_tools does not duplicate unavailable simulator cleanup" {
    run grep -n "simctl" "$PROJECT_ROOT/lib/clean/app_caches.sh"

    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "standalone guarded app-cache cleanup rechecks before falling back to safe_clean" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
unset -f safe_clean_guarded 2> /dev/null || true
deny_delete() { return 1; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }
note_activity() { :; }

rc=0
_app_cache_safe_clean_guarded deny_delete "Guarded cache" "$HOME/cache" "Guarded cache" || rc=$?
[[ $rc -ne 0 ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
}

@test "standalone simulator probe ignores idle launchd services" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() {
    [[ "$1" == "-x" && ("$2" == "CoreSimulatorService" || "$2" == "simdiskimaged") ]]
}

probe_status=0
_simulator_cleanup_process_state || probe_status=$?
[[ $probe_status -eq 1 ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "clean_media_players protects spotify offline cache when bnk has content" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
mkdir -p "$HOME/Library/Application Support/Spotify/PersistentCache/Storage"
dd if=/dev/zero of="$HOME/Library/Application Support/Spotify/PersistentCache/Storage/offline.bnk" bs=1024 count=2 2>/dev/null
safe_clean() { echo "CLEAN:$2"; }
clean_media_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"CLEAN:Spotify cache"* ]] || return 1
    [[ "$output" == *"CLEAN:Apple Music cache"* ]]
}

@test "clean_media_players preserves spotify cache when bnk is empty" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
mkdir -p "$HOME/Library/Application Support/Spotify/PersistentCache/Storage"
> "$HOME/Library/Application Support/Spotify/PersistentCache/Storage/offline.bnk"
safe_clean() { echo "CLEAN:$2"; }
clean_media_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Spotify cache protected"* ]] || return 1
    [[ "$output" != *"CLEAN:Spotify cache"* ]]
}

@test "clean_user_gui_applications calls all sections" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
stop_section_spinner() { :; }
safe_clean() { :; }
clean_xcode_tools() { echo "xcode"; }
clean_code_editors() { echo "editors"; }
clean_communication_apps() { echo "comm"; }
clean_dingtalk() { echo "dingtalk"; }
clean_ai_apps() { echo "ai"; }
clean_user_gui_applications
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"xcode"* ]] || return 1
    [[ "$output" != *"editors"* ]] || return 1
    [[ "$output" == *"comm"* ]] || return 1
    [[ "$output" == *"dingtalk"* ]] || return 1
    [[ "$output" == *"ai"* ]]
}

@test "clean_user_gui_applications restarts the spinner before every app group" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
start_section_spinner() { echo "START"; }
stop_section_spinner() { echo "STOP"; }
for group in clean_communication_apps clean_dingtalk clean_ai_apps clean_design_tools \
    clean_video_tools clean_3d_tools clean_productivity_apps clean_media_players \
    clean_video_players clean_download_managers clean_gaming_platforms \
    clean_translation_apps clean_screenshot_tools clean_email_clients clean_task_apps \
    clean_shell_utils clean_system_utils clean_note_apps clean_launcher_apps \
    clean_remote_desktop; do
    eval "$group() { echo GROUP; }"
done
clean_user_gui_applications
echo "RC=$?"
clean_download_managers() { return 130; }
rc=0
clean_user_gui_applications || rc=$?
echo "CANCEL_RC=$rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local first_run
    first_run=$(printf '%s\n' "$output" | sed -n '1,/^RC=/p' | tr '\n' ' ')
    # Twenty groups, each one preceded by its own spinner start, then one stop.
    [ "$(printf '%s\n' "$output" | sed -n '1,/^RC=/p' | grep -c '^START$')" -eq 20 ] || { echo "$first_run"; return 1; }
    [[ "$first_run" != *"GROUP GROUP"* ]] || { echo "$first_run"; return 1; }
    [[ "$first_run" == *"GROUP STOP RC=0"* ]] || { echo "$first_run"; return 1; }
    # A cancelled download-manager group still stops the spinner and returns its status.
    [[ "$output" == *$'STOP\nCANCEL_RC=130'* ]] || { echo "$output"; return 1; }
}

@test "clean_jianying_pro_generated_caches targets only whitelisted regenerable subdirs" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

cache_root="$HOME/Movies/JianyingPro/User Data/Cache"
# Regenerable (should be cleaned)
mkdir -p "$cache_root/recognize"
mkdir -p "$cache_root/frameThumbnail"
mkdir -p "$cache_root/audioWave"
mkdir -p "$cache_root/AlgorithmCache"
# Draft-referenced / downloaded assets (must be preserved)
mkdir -p "$cache_root/effect"
mkdir -p "$cache_root/music"
mkdir -p "$cache_root/AigcMaterailCache"
mkdir -p "$cache_root/agencycache"
# Copies of user-imported material (must be preserved, see the exclusion note)
mkdir -p "$cache_root/image"
mkdir -p "$cache_root/importcache3"
# The user's editable drafts (must never be touched)
mkdir -p "$HOME/Movies/JianyingPro/User Data/Projects/com.lveditor.draft/my-project"

pgrep() { return 1; }
safe_clean() {
    local arg
    for arg in "$@"; do
        printf 'CLEAN:%s\n' "$arg"
    done
}

clean_jianying_pro_generated_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/Movies/JianyingPro/User Data/Cache/recognize"* ]] || return 1
    [[ "$output" == *"CLEAN:$HOME/Movies/JianyingPro/User Data/Cache/frameThumbnail"* ]] || return 1
    [[ "$output" == *"CLEAN:$HOME/Movies/JianyingPro/User Data/Cache/audioWave"* ]] || return 1
    [[ "$output" == *"CLEAN:$HOME/Movies/JianyingPro/User Data/Cache/AlgorithmCache"* ]] || return 1
    [[ "$output" == *"CLEAN:JianyingPro generated cache"* ]] || return 1
    [[ "$output" != *"Cache/effect"* ]] || return 1
    [[ "$output" != *"Cache/music"* ]] || return 1
    [[ "$output" != *"Cache/image"* ]] || return 1
    [[ "$output" != *"importcache3"* ]] || return 1
    [[ "$output" != *"AigcMaterailCache"* ]] || return 1
    [[ "$output" != *"agencycache"* ]] || return 1
    [[ "$output" != *"Projects"* ]] || return 1
}

@test "jianying_pro_is_running ignores the resident menu-bar tray helper" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

# Faithful pgrep mock for a process table that contains ONLY the always-on
# tray helper: -x compares the pattern against the process name exactly,
# and -f substring-matches the pattern against the command line, like real
# pgrep does.
helper_name="VideoFusion-macOSTrayHelper"
helper_cmdline="/Applications/VideoFusion-macOS.app/Contents/Frameworks/VideoFusion-macOSTrayHelper.app/Contents/MacOS/VideoFusion-macOSTrayHelper"
pgrep() {
    local mode="$1"
    local pattern="${!#}"
    if [[ "$mode" == "-x" ]]; then
        [[ "$helper_name" == "$pattern" ]] && return 0
        return 1
    fi
    case "$helper_cmdline" in
        *"$pattern"*) return 0 ;;
    esac
    return 1
}

# Mock fidelity check: the historical broad probe DOES match the helper's
# command line. Without this, a lazy mock would pass even if the production
# probe were widened back to "/VideoFusion-macOS.app/".
if pgrep -f "/VideoFusion-macOS.app/" > /dev/null 2>&1; then
    echo "MOCK-FAITHFUL: broad pattern matches helper"
fi

if jianying_pro_is_running; then
    echo "WRONG: reported running"
else
    echo "OK: not running"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK-FAITHFUL: broad pattern matches helper"* ]] || return 1
    [[ "$output" == *"OK: not running"* ]] || return 1
    [[ "$output" != *"WRONG"* ]] || return 1
}

@test "clean_jianying_pro_generated_caches skips while JianyingPro is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

mkdir -p "$HOME/Movies/JianyingPro/User Data/Cache/recognize"
pgrep() { return 0; }
safe_clean() {
    echo "unexpected safe_clean"
    return 1
}

clean_jianying_pro_generated_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"JianyingPro generated caches · skipped (JianyingPro running)"* ]] || return 1
    [[ "$output" != *"unexpected safe_clean"* ]] || return 1
}

@test "clean_jianying_pro_generated_caches fails closed when the process probe errors" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

mkdir -p "$HOME/Movies/JianyingPro/User Data/Cache/recognize"
pgrep() { return 2; }
safe_clean() {
    echo "unexpected safe_clean"
    return 1
}

clean_jianying_pro_generated_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"unexpected safe_clean"* ]] || return 1
}

@test "clean_jianying_pro_generated_caches is a no-op when cache root is absent" {
    local empty_home
    empty_home="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-app-caches.XXXXXX")"
    run env HOME="$empty_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

pgrep() { return 1; }
safe_clean() {
    echo "unexpected safe_clean"
    return 1
}

clean_jianying_pro_generated_caches
EOF
    rm -rf "$empty_home"

    [ "$status" -eq 0 ]
    [[ "$output" != *"unexpected safe_clean"* ]] || return 1
}

@test "clean_ai_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
note_activity() { :; }
clean_ai_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"ChatGPT cache"* ]] || return 1
    [[ "$output" == *"Claude desktop cache"* ]] || return 1
    [[ "$output" != *"Google Clearcut logs"* ]] || return 1
    [[ "$output" == *"LM Studio cache"* ]] || return 1
    [[ "$output" != *"Codex"* ]]
}

@test "clean_ai_apps targets app cache but never the legacy LM Studio home" {
    mkdir -p "$HOME/Library/Caches/com.lmstudio.lmstudio"
    echo "cache" > "$HOME/Library/Caches/com.lmstudio.lmstudio/cache.bin"
    mkdir -p "$HOME/.cache/lm-studio/models"
    echo "model" > "$HOME/.cache/lm-studio/models/keep.gguf"
    mkdir -p "$HOME/.lmstudio/models"
    echo "model" > "$HOME/.lmstudio/models/keep.gguf"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { printf 'CLEAN:%s\n' "${@:1:$#-1}"; }
note_activity() { :; }
clean_ai_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/Library/Caches/com.lmstudio.lmstudio/cache.bin"* ]] || return 1
    [[ "$output" != *"$HOME/.cache/lm-studio"* ]] || return 1
    [[ "$output" != *"$HOME/.lmstudio"* ]] || return 1
}

@test "clean_ai_apps skips Codex Desktop state by default" {
    mkdir -p "$HOME/Library/Application Support/Codex/Cache" "$HOME/Library/Logs/com.openai.codex"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
note_activity() { echo "NOTE_ACTIVITY"; }
clean_ai_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Codex Desktop state"* ]] || return 1
    [[ "$output" != *"NOTE_ACTIVITY"* ]] || return 1
    [[ "$output" != *"Codex cache"* ]] || return 1
    [[ "$output" != *"Codex CLI logs"* ]]
}

@test "clean_design_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
pgrep() { return 1; }
clean_design_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sketch cache"* ]] || return 1
    [[ "$output" == *"Figma cache"* ]]
}

# Adobe's video apps read and write Common/Media Cache Files while open, and
# their bundle names carry a year. Each holder in the list must keep the row;
# an unrelated Adobe app must not, and the sibling Media Cache database is
# never a target.
@test "clean_design_tools holds shared Adobe caches while an Adobe app runs but not for Creative Cloud residents" {
    mkdir -p "$HOME/Library/Caches/Adobe/Camera Raw 2" "$HOME/Library/Caches/com.adobe.dunamis"
    touch "$HOME/Library/Caches/Adobe/Camera Raw 2/cache.dat" "$HOME/Library/Caches/com.adobe.dunamis/blob"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "SAFE_CLEAN:${!#}|$*"; }
defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
FAKE_PROCESS=""
pgrep() {
    [[ "$1" == "-f" ]] || return 1
    [[ -n "$FAKE_PROCESS" ]] || return 1
    printf '%s\n' "$FAKE_PROCESS" | grep -Eq -- "$2"
}
holders=(
    "/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app/Contents/MacOS/Adobe Photoshop 2025"
    "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic"
    "/Applications/Adobe Bridge 2025/Adobe Bridge 2025.app/Contents/MacOS/Adobe Bridge 2025"
    "/Applications/Adobe Acrobat Reader.app/Contents/MacOS/AdobeReader"
)
for FAKE_PROCESS in "${holders[@]}"; do
    out=$(clean_design_tools)
    if [[ "$out" == *"SAFE_CLEAN:Adobe cache"* || "$out" == *"SAFE_CLEAN:Adobe app caches"* ]]; then
        echo "NOT_HELD|$FAKE_PROCESS"
    fi
done
residents=(
    "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app/Contents/MacOS/Creative Cloud"
    "/Applications/Utilities/Adobe Creative Cloud Experience/CCXProcess/CCXProcess.app/Contents/MacOS/CCXProcess"
    "/Library/Application Support/Adobe/Adobe Desktop Common/ADS/Adobe Desktop Service.app/Contents/MacOS/Adobe Desktop Service"
)
for FAKE_PROCESS in "${residents[@]}"; do
    out=$(clean_design_tools)
    if [[ "$out" != *"SAFE_CLEAN:Adobe cache|"*"Camera Raw 2"* || "$out" != *"SAFE_CLEAN:Adobe app caches|"*"com.adobe.dunamis"* ]]; then
        echo "HELD_BY_RESIDENT|$FAKE_PROCESS"
    fi
done
echo DONE
EOF
    rm -rf "$HOME/Library/Caches/Adobe" "$HOME/Library/Caches/com.adobe.dunamis"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"DONE"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"NOT_HELD|"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"HELD_BY_RESIDENT|"* ]] || { echo "$output"; return 1; }
}

@test "clean_design_tools holds Adobe media cache files while an Adobe video app runs" {
    mkdir -p "$HOME/Library/Application Support/Adobe/Common/Media Cache Files" \
        "$HOME/Library/Application Support/Adobe/Common/Media Cache"
    touch "$HOME/Library/Application Support/Adobe/Common/Media Cache Files/peak.pek" \
        "$HOME/Library/Application Support/Adobe/Common/Media Cache/Media Cache Database.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "SAFE_CLEAN:${!#}|$*"; }
defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
FAKE_PROCESS=""
pgrep() {
    [[ "$1" == "-f" ]] || return 1
    [[ -n "$FAKE_PROCESS" ]] || return 1
    printf '%s\n' "$FAKE_PROCESS" | grep -Eq -- "$2"
}
holders=(
    "/Applications/Adobe Premiere Pro 2025/Adobe Premiere Pro 2025.app/Contents/MacOS/Adobe Premiere Pro 2025"
    "/Applications/Adobe After Effects 2025/Adobe After Effects 2025.app/Contents/MacOS/After Effects"
    "/Applications/Adobe Media Encoder 2025/Adobe Media Encoder 2025.app/Contents/MacOS/Adobe Media Encoder 2025"
    "/Applications/Adobe Audition 2025/Adobe Audition 2025.app/Contents/MacOS/Adobe Audition 2025"
    "/Applications/Adobe Prelude 2022/Adobe Prelude 2022.app/Contents/MacOS/Adobe Prelude 2022"
    "/Applications/Adobe Character Animator 2025/Adobe Character Animator 2025.app/Contents/MacOS/Character Animator"
    "/Applications/Adobe Premiere Elements 2024/Adobe Premiere Elements 2024.app/Contents/MacOS/Adobe Premiere Elements 2024"
    "/Applications/Adobe Premiere Rush.app/Contents/MacOS/Adobe Premiere Rush"
)
for FAKE_PROCESS in "${holders[@]}"; do
    out=$(clean_design_tools)
    if [[ "$out" == *"SAFE_CLEAN:Adobe media cache files"* || "$out" != *"DEFER:Adobe"* ]]; then
        echo "NOT_HELD|$FAKE_PROCESS"
    fi
done
FAKE_PROCESS="/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app/Contents/MacOS/Adobe Photoshop 2025"
clean_design_tools
EOF
    rm -rf "$HOME/Library/Application Support/Adobe"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"NOT_HELD|"* ]] || { echo "$output"; return 1; }
    # Control: with only Photoshop open the row still reaches its cleaner.
    [[ "$output" == *"SAFE_CLEAN:Adobe media cache files|$HOME/Library/Application Support/Adobe/Common/Media Cache Files/peak.pek"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Media Cache Database.db"* ]] || return 1
    [[ "$output" != *"/Common/Media Cache/"* ]]
}

@test "clean_dingtalk calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p ~/Library/Application\ Support/iDingTalk
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_dingtalk
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DingTalk iDingTalk cache"* ]] || return 1
    [[ "$output" == *"DingTalk logs"* ]]
}

@test "clean_download_managers calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_download_managers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Aria2 cache"* ]] || return 1
    [[ "$output" == *"qBittorrent cache"* ]]
}

@test "clean_productivity_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_productivity_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"MiaoYan cache"* ]] || return 1
    [[ "$output" == *"Flomo cache"* ]]
}

@test "clean_screenshot_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_screenshot_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CleanShot cache"* ]] || return 1
    [[ "$output" == *"Xnip cache"* ]]
}

@test "clean_office_applications calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
clean_office_applications
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Microsoft Word cache"* ]] || return 1
    [[ "$output" == *"Apple iWork cache"* ]]
}

@test "clean_communication_apps includes Microsoft Teams legacy caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p ~/Library/Application\ Support/Microsoft/Teams
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "$2"; }
clean_communication_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Microsoft Teams legacy cache"* ]] || return 1
    [[ "$output" == *"Microsoft Teams legacy logs"* ]]
}

@test "clean_communication_apps cleans Vesktop session caches only while Vesktop is not running" {
    local mode root kept
    for mode in idle running; do
        root="$BATS_TEST_TMPDIR/vesktop-$mode/Library/Application Support/vesktop"
        run env HOME="$BATS_TEST_TMPDIR/vesktop-$mode" PROJECT_ROOT="$PROJECT_ROOT" MODE="$mode" \
            /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
root="$HOME/Library/Application Support/vesktop"
mkdir -p "$root/sessionData/Cache/Cache_Data" "$root/sessionData/Code Cache/js" \
    "$root/sessionData/vencordFiles" "$root/sessionData/Local Storage/leveldb" \
    "$root/sessionData/IndexedDB" "$root/settings" "$root/themes"
touch "$root/sessionData/Cache/Cache_Data/data_0" "$root/sessionData/Code Cache/js/index" \
    "$root/sessionData/vencordFiles/vencordDesktopMain.js" \
    "$root/sessionData/Local Storage/leveldb/CURRENT" "$root/sessionData/IndexedDB/entry" \
    "$root/settings/settings.json" "$root/themes/theme.css" "$root/settings.json" "$root/state.json"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
# Vesktop's executable is lowercase, so only its bundle path names the app.
procs=/sbin/launchd
[[ "$MODE" == idle ]] || procs+=$'\n/Applications/Vesktop.app/Contents/MacOS/vesktop'
pgrep() {
    local line
    while IFS= read -r line; do
        case "$1" in
            -x) [[ "${line##*/}" =~ ^($2)$ ]] && return 0 ;;
            -f) [[ "$line" =~ $2 ]] && return 0 ;;
        esac
    done <<<"$procs"
    return 1
}
safe_clean() { printf 'CLEAN:%s\n' "$@"; }
clean_communication_apps
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        if [[ "$mode" == idle ]]; then
            [[ "$output" == *"CLEAN:$root/sessionData/Cache/Cache_Data"* ]] || { echo "$output"; return 1; }
            [[ "$output" == *"CLEAN:$root/sessionData/Code Cache/js"* ]] || { echo "$output"; return 1; }
        else
            [[ "$output" != *"vesktop/sessionData"* ]] || { echo "$output"; return 1; }
        fi
        for kept in sessionData/vencordFiles "sessionData/Local Storage" sessionData/IndexedDB \
            settings themes settings.json state.json; do
            [[ "$output" != *"CLEAN:$root/$kept"* ]] || { echo "$mode kept $kept: $output"; return 1; }
        done
    done
}

@test "named Application Support caches keep running and unknown owners and recheck after sizing" {
    for mode in running unknown starts-during-size idle; do
        run env HOME="$BATS_TEST_TMPDIR/named-$mode" PROJECT_ROOT="$PROJECT_ROOT" MODE="$mode" \
            MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Application Support/discord/Cache"
target="$HOME/Library/Application Support/discord/Cache/entry"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
note_activity() { :; }
pgrep() {
    case "$MODE" in
        running) return 0 ;;
        unknown) return 2 ;;
        starts-during-size) [[ -e "$HOME/started" ]] ;;
        idle) return 1 ;;
    esac
}
get_cleanup_path_size_kb() { touch "$HOME/started"; echo 1; }
safe_remove() { printf 'SINK:%s\n' "$1"; }
clean_communication_apps || true
[[ -f "$HOME/Library/Application Support/discord/Cache/entry" ]] || exit 1
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        if [[ "$mode" == idle ]]; then
            [[ "$output" == *"SINK:"*"discord/Cache/entry"* ]] || { echo "$output"; return 1; }
        else
            [[ "$output" != *"SINK:"* ]] || { echo "$mode: $output"; return 1; }
        fi
    done
}

@test "clean_communication_apps cleans Feishu embedded webview Service Worker per profile" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
feishu_base="$HOME/Library/Application Support/LarkShell/aha/users"
lark_base="$HOME/Library/Application Support/LarkInternational/aha/users"
mkdir -p "$feishu_base/57bea93a/profile_explorer/Service Worker/CacheStorage"
mkdir -p "$feishu_base/6ef03470/profile_explorer/Service Worker/CacheStorage"
mkdir -p "$lark_base/70ac6ef0/profile_explorer/Service Worker/CacheStorage"
# A non-profile sibling under users/ must be ignored.
mkdir -p "$feishu_base/global"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "SC|$2"; }
feishu_or_lark_running() { return 1; }
clean_service_worker_cache() { echo "SW|$1|$2|$3|$4"; }
clean_communication_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SW|Feishu|$HOME/Library/Application Support/LarkShell/aha/users/57bea93a/profile_explorer/Service Worker/CacheStorage|_feishu_service_worker_delete_guard_allows|"* ]] || return 1
    [[ "$output" == *"SW|Feishu|$HOME/Library/Application Support/LarkShell/aha/users/6ef03470/profile_explorer/Service Worker/CacheStorage|_feishu_service_worker_delete_guard_allows|"* ]] || return 1
    [[ "$output" == *"SW|Lark|$HOME/Library/Application Support/LarkInternational/aha/users/70ac6ef0/profile_explorer/Service Worker/CacheStorage|_feishu_service_worker_delete_guard_allows|"* ]] || return 1
    [[ "$output" != *"users/global/"* ]] || return 1
}

@test "clean_communication_apps reaches the Feishu iron engine and the sandboxed build" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
shell="$HOME/Library/Application Support/LarkShell"
sandbox="$HOME/Library/Containers/com.bytedance.macos.feishu/Data/Library"
mkdir -p "$shell/iron/users/b6eb487b/profile_main/Service Worker/CacheStorage"
mkdir -p "$shell/iron/users/b6eb487b/profile_main/IndexedDB"
mkdir -p "$shell/iron/users/b6eb487b/profile_explorer/Service Worker/CacheStorage"
mkdir -p "$sandbox/Application Support/LarkShell/aha/users/b6eb487b/profile_explorer/Service Worker/CacheStorage"
mkdir -p "$sandbox/Application Support/LarkShell/iron/users/b6eb487b/profile_main/Service Worker/CacheStorage"
mkdir -p "$HOME/Library/Caches/LarkShell/iron" "$sandbox/Caches/LarkShell"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { :; }
# Roots sharing a label arrive as one call, so print every target.
safe_clean_guarded() { echo "SCG|$1|${*:2}"; }
mole_cleanup_targets_exist() { return 0; }
feishu_or_lark_running() { return 1; }
clean_service_worker_cache() { echo "SW|$1|$2"; }
clean_communication_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SW|Feishu|$HOME/Library/Application Support/LarkShell/iron/users/b6eb487b/profile_main/Service Worker/CacheStorage"* ]] || return 1
    [[ "$output" == *"SW|Feishu|$HOME/Library/Containers/com.bytedance.macos.feishu/Data/Library/Application Support/LarkShell/aha/users/b6eb487b/profile_explorer/Service Worker/CacheStorage"* ]] || return 1
    [[ "$output" == *"SW|Feishu|$HOME/Library/Containers/com.bytedance.macos.feishu/Data/Library/Application Support/LarkShell/iron/users/b6eb487b/profile_main/Service Worker/CacheStorage"* ]] || return 1
    [[ "$output" != *"iron/users/b6eb487b/profile_explorer"* ]] || return 1
    [[ "$output" != *"IndexedDB"* ]] || return 1
    [[ "$output" == *"SCG|_feishu_disk_cache_delete_guard_allows|$HOME/Library/Caches/LarkShell/iron"* ]] || return 1
    # Both disk caches share one label, so they clean in the same call and row.
    [[ "$output" == *"SCG|_feishu_disk_cache_delete_guard_allows|$HOME/Library/Caches/LarkShell/iron"*" $HOME/Library/Containers/com.bytedance.macos.feishu/Data/Library/Caches/LarkShell"* ]]
}

@test "clean_communication_apps leaves Feishu disk caches while Feishu runs" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Caches/LarkShell/iron"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { :; }
safe_clean_guarded() { echo "SCG|$2"; }
mole_cleanup_targets_exist() { return 0; }
mole_defer_cleanup_family() { echo "DEFER|$1"; }
feishu_or_lark_running() { return 0; }
clean_service_worker_cache() { echo "SW|$2"; }
clean_communication_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"SCG|$HOME/Library/Caches/LarkShell"* ]] || return 1
    [[ "$output" == *"DEFER|Feishu/Lark"* ]]
}

@test "clean_notion_service_worker_caches targets CacheStorage in every Electron partition" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
partitions="$HOME/Library/Application Support/Notion/Partitions"
mkdir -p "$partitions/notion/Service Worker/CacheStorage"
mkdir -p "$partitions/notion-second/Service Worker/CacheStorage"
# A partition with no Service Worker cache, and the siblings that must survive.
mkdir -p "$partitions/empty-partition"
mkdir -p "$partitions/notion/Service Worker/ScriptCache"
mkdir -p "$partitions/notion/Service Worker/Database"
mkdir -p "$partitions/notion/Local Storage"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
notion_running() { return 1; }
clean_service_worker_cache() { echo "SW|$1|$2|$3"; }
clean_notion_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    local base="$HOME/Library/Application Support/Notion/Partitions"
    [[ "$output" == *"SW|Notion|$base/notion/Service Worker/CacheStorage|_notion_service_worker_delete_guard_allows"* ]] || return 1
    [[ "$output" == *"SW|Notion|$base/notion-second/Service Worker/CacheStorage|_notion_service_worker_delete_guard_allows"* ]] || return 1
    [[ "$output" != *"empty-partition"* ]] || return 1
    [[ "$output" != *"ScriptCache"* ]] || return 1
    [[ "$output" != *"Database"* ]] || return 1
    [[ "$output" != *"Local Storage"* ]]
}

@test "clean_notion_service_worker_caches defers every partition while Notion is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage/origin/cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
notion_running() { return 0; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
clean_notion_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER:Notion"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_notion_service_worker_caches fails closed on unknown owner state" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage/origin/cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
notion_running() { return 2; }
mole_defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
note_activity() { :; }
clean_notion_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Notion Service Worker · stopped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER"* ]]
}

@test "clean_notion_service_worker_caches refuses a symlinked partitions root" {
    local iso="$HOME/iso-notion-root-symlink"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Application Support/Notion" "$HOME/outside/notion/Service Worker/CacheStorage"
touch "$HOME/outside/notion/Service Worker/CacheStorage/private"
ln -s "$HOME/outside" "$HOME/Library/Application Support/Notion/Partitions"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
notion_running() { return 1; }
clean_service_worker_cache() { echo "SW|$2"; }
clean_notion_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"outside"* ]] || return 1
    [[ "$output" != *"SW|"* ]]
}

@test "clean_futu_update_downloads cleans the update folder only while Futu is closed" {
    local base="$HOME/iso-futu"
    local state
    for state in idle running unknown sink-flip symlink; do
        run env HOME="$base-$state" PROJECT_ROOT="$PROJECT_ROOT" STATE="$state" \
            /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
container="$HOME/Library/Containers/cn.futu.niuniu.nx/Data/Library/Application Support"
if [[ "$STATE" == "symlink" ]]; then
    mkdir -p "$container/LiveUpdate" "$HOME/outside"
    echo dmg > "$HOME/outside/private.dmg"
    ln -s "$HOME/outside" "$container/LiveUpdate/mac_qtnn"
else
    mkdir -p "$container/LiveUpdate/mac_qtnn"
    echo dmg > "$container/LiveUpdate/mac_qtnn/FTNN_15.40.dmg"
fi
mkdir -p "$container/Futu"
echo keep > "$container/Futu/account.db"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
futu_running() {
    case "$STATE" in
        running) return 0 ;;
        unknown) return 2 ;;
        *) return 1 ;;
    esac
}
note_activity() { :; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
safe_clean() { echo "UNGUARDED:$*"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    [[ "$STATE" == "sink-flip" ]] && return 75
    "$guard" || return 75
    echo "CLEAN:$guard:$*"
}
clean_futu_update_downloads
EOF
        [ "$status" -eq 0 ] || return 1
        [[ "$output" != *"UNGUARDED"* ]] || return 1
        [[ "$output" != *"account.db"* ]] || return 1
        case "$state" in
            idle)
                [[ "$output" == *"CLEAN:_futu_update_delete_guard_allows:$base-idle/Library/Containers/cn.futu.niuniu.nx/Data/Library/Application Support/LiveUpdate/mac_qtnn/FTNN_15.40.dmg Futu update downloads"* ]] || return 1
                ;;
            running | sink-flip)
                [[ "$output" == *"DEFER:Futu"* ]] || return 1
                [[ "$output" != *"CLEAN:"* ]] || return 1
                ;;
            unknown)
                [[ "$output" == *"Futu update downloads · stopped (process state unknown)"* ]] || return 1
                [[ "$output" != *"CLEAN:"* ]] || return 1
                ;;
            symlink)
                [[ "$output" != *"CLEAN:"* ]] || return 1
                [[ "$output" != *"DEFER:"* ]] || return 1
                ;;
        esac
    done
}

@test "futu_running sees the app and its helpers but not look-alike names" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() {
    local selector="$1" pattern="$2" line
    for line in "${PROC_LINES[@]}"; do
        if [[ "$selector" == "-x" ]]; then
            [[ "${line##*/}" == "$pattern" ]] && return 0
        elif printf '%s\n' "$line" | grep -Eq -- "$pattern"; then
            return 0
        fi
    done
    return 1
}
probe() {
    PROC_LINES=("$@")
    local rc=0
    futu_running || rc=$?
    echo "$rc"
}
echo "main=$(probe '/Applications/富途牛牛.app/Contents/MacOS/FTNN')"
echo "helper=$(probe '/Applications/富途牛牛.app/Contents/Frameworks/FTNN Helper (GPU).app/Contents/MacOS/FTNN Helper (GPU) --type=gpu-process')"
echo "other=$(probe '/Applications/Other.app/Contents/MacOS/FTNNX' '/usr/bin/vim notes-about-FTNN.txt')"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"main=0"* ]] || return 1
    [[ "$output" == *"helper=0"* ]] || return 1
    [[ "$output" == *"other=1"* ]]
}

@test "clean_notion_service_worker_caches refuses a symlinked cache child" {
    local iso="$HOME/iso-notion-child-symlink"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
sw="$HOME/Library/Application Support/Notion/Partitions/notion/Service Worker"
mkdir -p "$sw" "$HOME/outside"
touch "$HOME/outside/private"
ln -s "$HOME/outside" "$sw/CacheStorage"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
notion_running() { return 1; }
clean_service_worker_cache() { echo "SW|$2"; }
clean_notion_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"outside"* ]] || return 1
    [[ "$output" != *"SW|"* ]]
}

@test "clean_feishu_service_worker_caches preserves pipe characters in profile paths" {
    local pipe_home="$HOME/home|pipe"
    run env HOME="$pipe_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache="$HOME/Library/Application Support/LarkShell/aha/users/57bea93a/profile_explorer/Service Worker/CacheStorage"
mkdir -p "$cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
feishu_or_lark_running() { return 1; }
clean_service_worker_cache() { printf 'SW:%s:%s\n' "$1" "$2"; }
clean_feishu_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SW:Feishu:$pipe_home/Library/Application Support/LarkShell/aha/users/57bea93a/profile_explorer/Service Worker/CacheStorage"* ]]
}

@test "clean_feishu_service_worker_caches skips all profiles while owner is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache="$HOME/Library/Application Support/LarkShell/aha/users/57bea93a/profile_explorer/Service Worker/CacheStorage"
mkdir -p "$cache/origin/cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
feishu_or_lark_running() { return 0; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
clean_feishu_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER:Feishu/Lark"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_feishu_service_worker_caches fails closed on unknown owner state" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache="$HOME/Library/Application Support/LarkShell/aha/users/57bea93a/profile_explorer/Service Worker/CacheStorage"
mkdir -p "$cache/origin/cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
feishu_or_lark_running() { return 2; }
mole_defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
note_activity() { :; }
clean_feishu_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Feishu/Lark Service Worker · stopped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER"* ]]
}

@test "clean_feishu_service_worker_caches rechecks owner after sizing" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
marker="$HOME/feishu-started"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
declare -a PROTECTED_SW_DOMAINS=("never.invalid")
cache="$HOME/Library/Application Support/LarkShell/aha/users/57bea93a/profile_explorer/Service Worker/CacheStorage"
candidate="$cache/origin/cache"
mkdir -p "$candidate"
feishu_or_lark_running() { [[ -e "$marker" ]] && return 0 || return 1; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
note_activity() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "sh" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if [[ "$1" == "du" ]]; then
        touch "$marker"
        printf '512\t%s\n' "$candidate"
        return 0
    fi
    "$@"
}
clean_feishu_service_worker_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER:Feishu/Lark"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_feishu_service_worker_caches is a no-op when the aha profile root is absent" {
    local empty_home
    empty_home="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-app-caches.XXXXXX")"
    run env HOME="$empty_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
clean_service_worker_cache() { echo "unexpected SW call"; }
clean_feishu_service_worker_caches
echo "done-no-op"
EOF
    rm -rf "$empty_home"

    [ "$status" -eq 0 ]
    [[ "$output" != *"unexpected SW call"* ]] || return 1
    [[ "$output" == *"done-no-op"* ]] || return 1
}

@test "clean_gaming_platforms includes steam and minecraft related caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p ~/Library/Application\ Support/Steam ~/Library/Application\ Support/Battle.net
mkdir -p ~/Library/Application\ Support/minecraft ~/.lunarclient
mkdir -p ~/Library/Application\ Support/PCSX2 ~/Library/Application\ Support/rpcs3
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_gaming_platforms
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Steam app cache"* ]] || return 1
    [[ "$output" == *"Steam shader cache"* ]] || return 1
    [[ "$output" == *"Minecraft logs"* ]] || return 1
    [[ "$output" == *"Lunar Client logs"* ]]
}

@test "clean_code_editors includes Zed caches" {
    mkdir -p "$HOME/Library/Application Support/Zed/node/cache/_cacache"
    mkdir -p "$HOME/Library/Application Support/Zed/node/node-v24.11.0-darwin-arm64/cache/_cacache"
    mkdir -p "$HOME/Library/Application Support/Zed/node/node-v24.11.0-darwin-arm64/bin"
    mkdir -p "$HOME/Library/Application Support/Zed/db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "CLEAN:$1|$2"; }
clean_code_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Zed cache"* ]] || return 1
    [[ "$output" == *"CLEAN:$HOME/Library/Application Support/Zed/node/cache/_cacache|Zed npm cache"* ]] || return 1
    [[ "$output" == *"CLEAN:$HOME/Library/Application Support/Zed/node/node-v24.11.0-darwin-arm64/cache/_cacache|Zed npm cache"* ]] || return 1
    [[ "$output" != *"$HOME/Library/Application Support/Zed/db"* ]] || return 1
    [[ "$output" != *"node-v24.11.0-darwin-arm64/bin"* ]] || return 1
    [[ "$output" == *"Zed logs"* ]] || return 1
}

@test "clean_code_editors includes VS Code WebStorage CacheStorage only" {
    mkdir -p "$HOME/Library/Application Support/Code/WebStorage/29/CacheStorage/uuid-1"
    mkdir -p "$HOME/Library/Application Support/Code/WebStorage/29/Local Storage"
    touch "$HOME/Library/Application Support/Code/WebStorage/29/QuotaManager"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "CLEAN:$1|$2"; }
clean_code_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/Library/Application Support/Code/WebStorage/29/CacheStorage/uuid-1|VS Code webview cache"* ]] || return 1
    [[ "$output" != *"Local Storage"* ]] || return 1
    [[ "$output" != *"QuotaManager"* ]]
}

@test "clean_shell_utils includes Warp and Ghostty caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_shell_utils
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Warp cache"* ]] || return 1
    [[ "$output" == *"Warp log"* ]] || return 1
    [[ "$output" == *"Warp Sentry crash reports"* ]] || return 1
    [[ "$output" == *"Ghostty cache"* ]]
}

@test "clean_video_players includes Stremio caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p ~/Library/Application\ Support/stremio
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_video_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Stremio cache"* ]] || return 1
    [[ "$output" == *"Stremio server cache"* ]]
}

@test "clean_video_players cleans SenPlayer videoCache but not sibling data (#1070)" {
    local sen="$HOME/Library/Containers/com.wuziqi.SenPlayer/Data"
    mkdir -p "$sen/tmp/videoCache" "$sen/Documents"
    touch "$sen/tmp/videoCache/segment.mp4" "$sen/Documents/saved.mp4"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { local arg; for arg in "$@"; do printf 'CLEAN:%s\n' "$arg"; done; }
clean_video_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/Library/Containers/com.wuziqi.SenPlayer/Data/tmp/videoCache/segment.mp4"* &&
        "$output" != *"SenPlayer/Data/Documents"* ]]
}

@test "clean_productivity_apps cleans Folo Cache_Data but not sibling data (#1070)" {
    local folo="$HOME/Library/Containers/is.follow/Data/Library/Application Support/Folo"
    mkdir -p "$folo/Cache/Cache_Data"
    touch "$folo/Cache/Cache_Data/blob" "$folo/Cache/other.bin" "$folo/db.sqlite"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { local arg; for arg in "$@"; do printf 'CLEAN:%s\n' "$arg"; done; }
clean_productivity_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/Library/Containers/is.follow/Data/Library/Application Support/Folo/Cache/Cache_Data/blob"* &&
        "$output" != *"Folo/Cache/other.bin"* &&
        "$output" != *"db.sqlite"* ]]
}

@test "clean_editor_obsolete_extensions reads JSON when plutil -p rejects raw file (#1512)" {
    local ext_root="$HOME/.vscode/extensions"
    mkdir -p "$ext_root/pub.ext-old-1.0.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "pub.ext-old-1.0.0": true
}
JSON

    local mock_bin="$HOME/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/plutil" << 'MOCK'
#!/bin/bash
if [[ "$1" == "-p" && "$2" == *"/.obsolete" ]]; then
    echo "Unexpected character { at line 1" >&2
    exit 1
fi
exec /usr/bin/plutil "$@"
MOCK
    chmod +x "$mock_bin/plutil"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$mock_bin:$PATH" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "CLEAN:$1"; }
clean_editor_obsolete_extensions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/.vscode/extensions/pub.ext-old-1.0.0"* ]] || return 1
}

@test "clean_editor_obsolete_extensions removes only dirs listed in .obsolete (#910)" {
    local ext_root="$HOME/.vscode/extensions"
    mkdir -p "$ext_root/pub.ext-old-1.0.0" "$ext_root/pub.ext-new-1.1.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "pub.ext-old-1.0.0": true
}
JSON

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "CLEAN:$1"; }
clean_editor_obsolete_extensions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/.vscode/extensions/pub.ext-old-1.0.0"* ]] || return 1
    [[ "$output" != *"pub.ext-new-1.1.0"* ]]
}

@test "clean_editor_obsolete_extensions rejects path-traversal keys in .obsolete (#910)" {
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor"
    local ext_root="$HOME/.cursor/extensions"
    mkdir -p "$ext_root"
    mkdir -p "$HOME/obsolete-victim"
    # A legitimate entry alongside the malicious ones. Without it the function has
    # nothing to clean, output is empty, and "no CLEAN: line" cannot distinguish
    # "traversal rejected" from "never ran".
    mkdir -p "$ext_root/publisher.legit-1.0.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "../../obsolete-victim": true,
  "..": true,
  "publisher.legit-1.0.0": true
}
JSON

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "CLEAN:$1"; }
clean_editor_obsolete_extensions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$ext_root/publisher.legit-1.0.0"* ]] || return 1
    [[ "$output" != *"obsolete-victim"* ]] || return 1
    [[ "$output" != *"CLEAN:$HOME/.cursor\""* ]] || return 1
    [ -d "$HOME/obsolete-victim" ]
}

make_extension_dir() {
    local ext_root="$1" dir_name="$2" publisher="$3" name="$4" version="$5"
    mkdir -p "$ext_root/$dir_name"
    printf '{"publisher":"%s","name":"%s","version":"%s"}\n' \
        "$publisher" "$name" "$version" > "$ext_root/$dir_name/package.json"
}

write_extension_registry() {
    local registry="$1"
    shift
    mkdir -p "$(dirname "$registry")"
    {
        printf '['
        local first=true dir
        for dir in "$@"; do
            [[ "$first" == "true" ]] || printf ','
            first=false
            printf '{"relativeLocation":"%s","location":{"path":"/x/%s","scheme":"file"}}' "$dir" "$dir"
        done
        printf ']\n'
    } > "$registry"
}

run_editor_extension_cleanup() {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "CLEAN:$1"; }
note_activity() { :; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
clean_editor_obsolete_extensions
EOF
}

@test "a directory named by .obsolete is not offered twice (#1461)" {
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor" "$HOME/Library/Application Support/Code"
    local ext_root="$HOME/.vscode/extensions"
    make_extension_dir "$ext_root" "pub.ext-1.0.0" "Pub" "ext" "1.0.0"
    write_extension_registry "$ext_root/extensions.json" "pub.registered-9.9.9"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "pub.ext-1.0.0": true
}
JSON
    mkdir -p "$HOME/Library/Application Support/Code/User/profiles"

    run_editor_extension_cleanup

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local hits
    hits=$(printf '%s\n' "$output" | grep -c "CLEAN:$ext_root/pub.ext-1.0.0" || true)
    [ "$hits" -eq 1 ] || { echo "expected 1 offer, got $hits"; echo "$output"; return 1; }
    [[ "$output" == *"Obsolete VS Code extension"* ]] || [[ "$output" == *"CLEAN:"* ]]
}

@test "manual private extensions absent from the registry are preserved (#1461)" {
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor" "$HOME/Library/Application Support/Code"
    local ext_root="$HOME/.vscode/extensions"
    make_extension_dir "$ext_root" "pub.private-1.0.0" "Pub" "private" "1.0.0"
    make_extension_dir "$ext_root" "pub.obsolete-0.9.0" "Pub" "obsolete" "0.9.0"
    write_extension_registry "$ext_root/extensions.json" "pub.registered-9.9.9"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "pub.obsolete-0.9.0": true
}
JSON
    mkdir -p "$HOME/Library/Application Support/Code/User/profiles"

    run_editor_extension_cleanup

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLEAN:$ext_root/pub.obsolete-0.9.0"* ]] || return 1
    [[ "$output" != *"CLEAN:$ext_root/pub.private-1.0.0"* ]] || return 1
}

@test "only a root-level .obsolete key marks an extension, never a nested one (#1512)" {
    # The old parser read `plutil -p` text, which carries no nesting, so a key
    # inside a nested dict or array came back looking like a top-level
    # extension directory name. A user whose extensions root happened to hold a
    # directory of that name had it offered for deletion: a wrong deletion, not
    # a missed one. RED on V1.55.0, which offers both nested names.
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor" "$HOME/Library/Application Support/Code"
    local ext_root="$HOME/.vscode/extensions"
    make_extension_dir "$ext_root" "nested-in-dict" "Pub" "nd" "1.0.0"
    make_extension_dir "$ext_root" "nested-in-array" "Pub" "na" "1.0.0"
    make_extension_dir "$ext_root" "at-root" "Pub" "rk" "1.0.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "outer": { "nested-in-dict": true },
  "arr": [ { "nested-in-array": true } ],
  "at-root": true
}
JSON
    mkdir -p "$HOME/Library/Application Support/Code/User/profiles"

    run_editor_extension_cleanup

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLEAN:$ext_root/at-root"* ]] || return 1
    [[ "$output" != *"CLEAN:$ext_root/nested-in-dict"* ]] || return 1
    [[ "$output" != *"CLEAN:$ext_root/nested-in-array"* ]] || return 1
}

@test "an empty .obsolete container does not hide the keys after it (#1512)" {
    # plutil spells an empty container as a self-closing <dict/> / <array/>.
    # Counting those as an opening tag desyncs the depth upward and silently
    # drops every later root key, so the whole cleanup goes quiet. Key order in
    # the fixture is deliberate: plutil sorts keys, so the real one must sort
    # last to actually sit behind both empty containers.
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor" "$HOME/Library/Application Support/Code"
    local ext_root="$HOME/.vscode/extensions"
    make_extension_dir "$ext_root" "zz-after-empty" "Pub" "ae" "1.0.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "aa-emptydict": {},
  "ab-emptyarray": [],
  "zz-after-empty": true
}
JSON
    mkdir -p "$HOME/Library/Application Support/Code/User/profiles"

    run_editor_extension_cleanup

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLEAN:$ext_root/zz-after-empty"* ]] || return 1
}

@test ".obsolete keys carrying XML entities resolve to their real names (#1512)" {
    # plutil escapes &, < and > inside a <key>. Decoding &amp; before the other
    # two turns a key holding the literal text "&lt;" into a real "<", so the
    # name no longer matches the directory on disk and the entry is skipped.
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor" "$HOME/Library/Application Support/Code"
    local ext_root="$HOME/.vscode/extensions"
    make_extension_dir "$ext_root" 'amp&key' "Pub" "am" "1.0.0"
    make_extension_dir "$ext_root" 'lit&lt;key' "Pub" "li" "1.0.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "amp&key": true,
  "lit&lt;key": true
}
JSON
    mkdir -p "$HOME/Library/Application Support/Code/User/profiles"

    run_editor_extension_cleanup

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLEAN:$ext_root/amp&key"* ]] || return 1
    [[ "$output" == *"CLEAN:$ext_root/lit&lt;key"* ]] || return 1
}

@test "a .obsolete value must be boolean true, not 1 or the string true (#1512)" {
    # The journal marks an entry stale with a boolean. Widening the match to
    # accept anything that merely prints as 1 (which is how macOS 15 renders a
    # boolean) would also accept a real integer, so the type has to come from
    # the XML tag rather than from rendered text.
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor" "$HOME/Library/Application Support/Code"
    local ext_root="$HOME/.vscode/extensions"
    make_extension_dir "$ext_root" "val-int-one" "Pub" "vi" "1.0.0"
    make_extension_dir "$ext_root" "val-string-true" "Pub" "vs" "1.0.0"
    make_extension_dir "$ext_root" "val-false" "Pub" "vf" "1.0.0"
    make_extension_dir "$ext_root" "val-true" "Pub" "vt" "1.0.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "val-int-one": 1,
  "val-string-true": "true",
  "val-false": false,
  "val-true": true
}
JSON
    mkdir -p "$HOME/Library/Application Support/Code/User/profiles"

    run_editor_extension_cleanup

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLEAN:$ext_root/val-true"* ]] || return 1
    [[ "$output" != *"CLEAN:$ext_root/val-int-one"* ]] || return 1
    [[ "$output" != *"CLEAN:$ext_root/val-string-true"* ]] || return 1
    [[ "$output" != *"CLEAN:$ext_root/val-false"* ]] || return 1
}

@test "clean_code_editors includes CodeBuddy Extension caches when directory exists" {
    mkdir -p "$HOME/Library/Application Support/CodeBuddyExtension"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_code_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CodeBuddy Extension cache"* ]] || return 1
    [[ "$output" == *"CodeBuddy Extension logs"* ]]
}

@test "clean_code_editors includes CodeBuddy CN caches when directory exists" {
    mkdir -p "$HOME/Library/Application Support/CodeBuddy CN"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_code_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CodeBuddy CN cache"* ]] || return 1
    [[ "$output" == *"CodeBuddy CN logs"* ]] || return 1
    [[ "$output" == *"CodeBuddy CN GPU cache"* ]]
}

@test "clean_code_editors skips CodeBuddy when directories are absent" {
    rm -rf "$HOME/Library/Application Support/CodeBuddyExtension" "$HOME/Library/Application Support/CodeBuddy CN"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_code_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"CodeBuddy"* ]]
}

@test "clean_media_players includes QQ Music Mac container caches" {
    mkdir -p "$HOME/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_media_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"QQ Music Mac cache"* ]] || return 1
    [[ "$output" == *"QQ Music streaming cache"* ]] || return 1
    [[ "$output" == *"QQ Music logs"* ]] || return 1
    [[ "$output" == *"QQ Music container cache"* ]]
}

@test "clean_media_players does not reference iDownloadProxy" {
    mkdir -p "$HOME/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$1 $2"; }
clean_media_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"iDownloadProxy"* ]]
}

@test "clean_video_players includes Tencent Video container caches" {
    mkdir -p "$HOME/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_video_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Tencent Video old installer"* ]] || return 1
    [[ "$output" == *"Tencent Video native cache"* ]] || return 1
    [[ "$output" == *"Tencent Video document cache"* ]]
}

@test "clean_productivity_apps includes Spacedrive thumbnail cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_productivity_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Spacedrive thumbnail cache"* ]]
}

@test "clean_neatdm_stale_segments removes segments older than threshold" {
    local neatdm_dir="$HOME/Library/Application Support/com.NeatDownloadManager"
    rm -rf "$neatdm_dir"
    mkdir -p "$neatdm_dir/12345"
    touch "$neatdm_dir/12345/seg.x0"
    # Set mtime to 31 days ago
    touch -t "$(/bin/date -v-31d '+%Y%m%d%H%M.%S')" "$neatdm_dir/12345/seg.x0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_neatdm_stale_segments
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"NeatDM stale downloads"* ]] || return 1
    [[ "$output" == *"1 item,"* ]]
}

@test "clean_neatdm_stale_segments skips recent segments" {
    local neatdm_dir="$HOME/Library/Application Support/com.NeatDownloadManager"
    rm -rf "$neatdm_dir"
    mkdir -p "$neatdm_dir/67890"
    touch "$neatdm_dir/67890/seg.x0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_neatdm_stale_segments
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"NeatDM stale downloads"* ]] || return 1
    # The absence of a label is weak evidence on its own: this run prints nothing at
    # all, so assert the survival the test is actually named for.
    [ -f "$neatdm_dir/67890/seg.x0" ]
    [ -d "$neatdm_dir/67890" ]
}

@test "clean_neatdm_stale_segments skips non-numeric segment-like directories" {
    local neatdm_dir="$HOME/Library/Application Support/com.NeatDownloadManager"
    rm -rf "$neatdm_dir"
    mkdir -p "$neatdm_dir/history-backup"
    touch "$neatdm_dir/history-backup/seg.x0"
    touch -t "$(/bin/date -v-31d '+%Y%m%d%H%M.%S')" "$neatdm_dir/history-backup/seg.x0"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_neatdm_stale_segments
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"NeatDM stale downloads"* ]] || return 1
    # This path prints nothing, so the absence check alone cannot fail. Assert the
    # survival the test is named for.
    [ -f "$neatdm_dir/history-backup/seg.x0" ]
    [ -d "$neatdm_dir/history-backup" ]
}

@test "clean_neatdm_stale_segments skips when directory absent" {
    rm -rf "$HOME/Library/Application Support/com.NeatDownloadManager"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_neatdm_stale_segments
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "clean_launcher_apps does not touch Raycast cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
mkdir -p "$HOME/Library/Caches/com.raycast.macos/urlcache"
mkdir -p "$HOME/Library/Caches/com.raycast.macos/fsCachedData"
safe_clean() { echo "CLEAN:$2|$1"; }
clean_launcher_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Raycast"* ]] && [[ "$output" != *"raycast"* ]]
}

@test "Xcode DerivedData cleanup keeps deleting through a size timeout and stops on a signal" {
    # Sizing only feeds the freed total (bugs reference, section 15): a timeout
    # leaves the project eligible and marks the total partial, a signal stops
    # the run before any deletion.
    local isolated_home="$HOME/xcode-derived-timeout"
    mkdir -p "$isolated_home/Library/Developer/Xcode/DerivedData/App-abc"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
DRY_RUN=false
_xcode_cleanup_process_state() { return 1; }
safe_remove() { echo "DELETE:$1"; }
note_activity() { :; }
for size_status in 124 130; do
    MOLE_CLEAN_CANCEL_STATUS=0
    MOLE_CLEAN_SIZING_TIMEOUTS=0
    eval "get_path_size_kb() { return $size_status; }"
    rc=0
    clean_xcode_derived_data || rc=$?
    printf 'SIZE=%s RC=%s CANCEL=%s PARTIAL=%s\n' "$size_status" "$rc" \
        "$MOLE_CLEAN_CANCEL_STATUS" "$MOLE_CLEAN_SIZING_TIMEOUTS"
done
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"DELETE:$isolated_home/Library/Developer/Xcode/DerivedData/App-abc"*"SIZE=124 RC=0 CANCEL=0 PARTIAL=1"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SIZE=130 RC=130 CANCEL=130 PARTIAL=0"* ]] || { echo "$output"; return 1; }
    [[ "$(printf '%s\n' "$output" | grep -c '^DELETE:')" -eq 1 ]]
}

@test "clean_3d_tools skips Autodesk cache while AcCoreConsole is running (#1390)" {
    mkdir -p "$HOME/Library/Caches/com.autodesk.AcCoreConsole"
    touch "$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"
    touch "$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db-shm"
    touch "$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db-wal"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() {
    if [[ "$*" == *AcCoreConsole* ]] || [[ "$*" == *com.autodesk.* ]]; then
        return 0
    fi
    return 1
}
safe_clean() {
    local desc="${*: -1}"
    case "$desc" in
        "Autodesk cache") echo "UNEXPECTED_AUTODESK:$desc" ;;
    esac
}
safe_clean_guarded() { echo "UNEXPECTED_GUARDED:$*"; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_3d_tools
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEFER:Autodesk"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_AUTODESK"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_GUARDED"* ]] || return 1
    [[ -f "$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db" ]]
}

@test "clean_3d_tools removes Autodesk cache when no Autodesk process is running" {
    rm -rf "$HOME/Library/Caches/com.autodesk.AcCoreConsole"
    mkdir -p "$HOME/Library/Caches/com.autodesk.AcCoreConsole"
    touch "$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() {
    local desc="${*: -1}"
    echo "SAFE_CLEAN:$desc"
    local arg
    for arg in "${@:1:$#-1}"; do
        echo "PATH:$arg"
    done
}
safe_clean_guarded() { shift; safe_clean "$@"; }
note_activity() { :; }
clean_3d_tools
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Autodesk cache"* ]] || return 1
    [[ "$output" == *"PATH:"*"com.autodesk.AcCoreConsole"* ]] || return 1
}

@test "safe_remove refuses a live reverse-DNS user cache (#1390)" {
    mkdir -p "$HOME/Library/Caches/com.autodesk.AcCoreConsole"
    local db="$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"
    touch "$db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
# The owner probe reads one `ps` snapshot rather than forking pgrep per
# candidate, so a live helper is simulated by the table it would appear in.
ps() {
    cat <<'TABLE'
  PID  PPID COMM             ARGS
  901     1 /Applications/Autodesk Fusion.app/Contents/MacOS/AcCoreConsole /Applications/Autodesk Fusion.app/Contents/MacOS/AcCoreConsole
TABLE
}
oplog_enabled() { return 1; }
log_operation() { :; }
debug_log() { :; }
db="$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"
set +e
safe_remove "$db" true
rc=$?
set -e
[[ $rc -ne 0 ]] || exit 1
[[ -f "$db" ]]
INNER

    [ "$status" -eq 0 ]
    [[ -f "$db" ]]
}

@test "safe_remove deletes an idle reverse-DNS user cache" {
    mole_test_fake_command lsof 'exit 1'
    mkdir -p "$HOME/Library/Caches/com.example.idleapp"
    local db="$HOME/Library/Caches/com.example.idleapp/Cache.db"
    touch "$db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
ps() { printf '%s\n' '  PID  PPID COMM ARGS'; }
oplog_enabled() { return 1; }
log_operation() { :; }
debug_log() { :; }
validate_path_for_deletion() { return 0; }
db="$HOME/Library/Caches/com.example.idleapp/Cache.db"
safe_remove "$db" true
[[ ! -e "$db" ]]
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ ! -e "$db" ]]
}

@test "clean_autodesk_fusion_old_bundles removes only strictly older versions and keeps every staged version" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local staged_one="$prod/cccccccccccccccccccccccccccccccccccccccc"
    local staged_two="$prod/dddddddddddddddddddddddddddddddddddddddd"
    local equal="$prod/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    make_fusion_version_dir "$staged_one" "2.0.300"
    make_fusion_version_dir "$staged_two" "3.0.1"
    make_fusion_version_dir "$equal" "2.0.200"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
get_path_size_kb() { echo "1024"; }
note_activity() { :; }
debug_log() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ ! -d "$old" ]] || return 1
    [[ -d "$current" && -d "$staged_one" && -d "$staged_two" && -d "$equal" ]]
}

@test "clean_autodesk_fusion_old_bundles preserves non-hash and unverified siblings" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local wrong_id="$prod/cccccccccccccccccccccccccccccccccccccccc"
    local no_app="$prod/dddddddddddddddddddddddddddddddddddddddd"
    local no_executable="$prod/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    local non_hash="$prod/cache"
    local external="$HOME/fusion-external-version"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    make_fusion_version_dir "$wrong_id" "2.0.50" "com.example.not-fusion"
    make_fusion_version_dir "$no_executable" "2.0.25"
    rm "$no_executable/Autodesk Fusion.app/Contents/MacOS/Autodesk Fusion"
    mkdir -p "$no_app/config" "$non_hash"
    make_fusion_version_dir "$non_hash" "2.0.1"
    make_fusion_version_dir "$external" "2.0.1"
    ln -s "$external" "$prod/ffffffffffffffffffffffffffffffffffffffff"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
get_path_size_kb() { echo "1"; }
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ ! -d "$old" ]] || return 1
    [[ -d "$wrong_id" && -d "$no_app" && -d "$no_executable" && -d "$non_hash" && -L "$prod/ffffffffffffffffffffffffffffffffffffffff" ]]
}

@test "clean_autodesk_fusion_old_bundles refuses a symlinked production root" {
    local autodesk="$HOME/Library/Application Support/Autodesk"
    local external="$HOME/outside-fusion-production"
    rm -rf "$autodesk" "$external"
    mkdir -p "$autodesk/webdeploy" "$external"
    local current="$external/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$external/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$external/Autodesk Fusion.app"
    ln -s "$external" "$autodesk/webdeploy/production"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"production root not trusted"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles skips when Autodesk is running" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 0; }
get_path_size_kb() { echo "1024"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER:Autodesk Fusion"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles skips while the Autodesk streamer updater is running" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { [[ "$*" == *streamer* ]]; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER:Autodesk Fusion"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles skips when Autodesk process state is unknown" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
autodesk_cache_process_state() { return 2; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles skips when current alias is broken" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Autodesk Fusion.app" \
        "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; return 0; }
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"current version unknown"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles stops when the current alias changes during sizing" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
get_path_size_kb() {
    local alias="$HOME/Library/Application Support/Autodesk/webdeploy/production/Autodesk Fusion.app"
    rm "$alias"
    ln -s "$1/Autodesk Fusion.app" "$alias"
    echo "1"
}
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"stopped (current version changed)"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles stops when Autodesk starts during sizing" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
marker="$HOME/autodesk-started"
pgrep() { [[ -e "$marker" ]]; }
get_path_size_kb() { : > "$marker"; echo "1"; }
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"stopped (Autodesk started)"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles rejects a candidate replaced during sizing" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk" "$HOME/fusion-replacement"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local replacement="$HOME/fusion-replacement"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    make_fusion_version_dir "$replacement" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
old="$HOME/Library/Application Support/Autodesk/webdeploy/production/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
pgrep() { return 1; }
get_path_size_kb() {
    mv "$old" "$HOME/original-old-fusion"
    mv "$HOME/fusion-replacement" "$old"
    echo "1"
}
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"stopped (candidate replaced)"* ]] || return 1
    [[ -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles reports a failed removal and continues" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old_one="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local old_two="$prod/cccccccccccccccccccccccccccccccccccccccc"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old_one" "2.0.100"
    make_fusion_version_dir "$old_two" "2.0.150"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
old_one="$HOME/Library/Application Support/Autodesk/webdeploy/production/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
pgrep() { return 1; }
get_path_size_kb() { echo "1"; }
safe_remove() {
    if [[ "$1" == "$old_one" ]]; then
        return 1
    fi
    command rm -rf "$1"
}
note_activity() { :; }
debug_log() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
DRY_RUN=false
clean_autodesk_fusion_old_bundles
printf 'COUNTS:%s:%s:%s\n' "$files_cleaned" "$total_size_cleaned" "$total_items"
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"1 failed"* ]] || return 1
    [[ "$output" == *"COUNTS:1:1:1"* ]] || return 1
    [[ -d "$old_one" && ! -d "$old_two" ]]
}

@test "clean_autodesk_fusion_old_bundles avoids a duplicate real-mode post-size guard" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
get_path_size_kb() { echo "1"; }
guard_calls=0
_autodesk_fusion_delete_guard_allows() {
    guard_calls=$((guard_calls + 1))
    return 0
}
safe_remove() {
    local final_guard="${_MOLE_SAFE_REMOVE_FINAL_GUARD:-}"
    [[ -n "$final_guard" ]] || return 99
    "$final_guard" "$1" || return $?
    command rm -rf "$1"
}
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
clean_autodesk_fusion_old_bundles
printf 'GUARD_CALLS:%s\n' "$guard_calls"
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"GUARD_CALLS:2"* ]] || return 1
    [[ ! -d "$old" ]]
}

@test "clean_autodesk_fusion_old_bundles propagates a final sink interrupt" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
get_path_size_kb() { echo "1"; }
guard_calls=0
_autodesk_fusion_delete_guard_allows() {
    guard_calls=$((guard_calls + 1))
    [[ $guard_calls -lt 2 ]] && return 0
    _MOLE_AUTODESK_FUSION_GUARD_REASON="interrupted"
    return 130
}
note_activity() { :; }
debug_log() { :; }
DRY_RUN=false
MOLE_CLEAN_CANCEL_STATUS=0
set +e
clean_autodesk_fusion_old_bundles
cleanup_rc=$?
set -e
printf 'RC:%s CANCEL:%s CALLS:%s\n' \
    "$cleanup_rc" "$MOLE_CLEAN_CANCEL_STATUS" "$guard_calls"
[[ $cleanup_rc -eq 130 ]]
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC:130 CANCEL:130 CALLS:2"* ]] || return 1
    [[ -d "$old" ]]
}

@test "Autodesk Fusion final guard catches the streamer starting during metadata probes" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
marker="$HOME/streamer-started"
autodesk_cache_process_state() { [[ -e "$marker" ]]; }
_autodesk_fusion_resolve_current_version() {
    _MOLE_AUTODESK_FUSION_RESOLVED_DIR="$current"
    _MOLE_AUTODESK_FUSION_RESOLVED_VERSION="2.0.200"
    : > "$marker"
}
_mole_snapshot_path_identity "$old"
_MOLE_AUTODESK_FUSION_GUARD_ROOT="$prod"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR="$current"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION="2.0.200"
_MOLE_AUTODESK_FUSION_GUARD_DEADLINE=$((SECONDS + 10))
_MOLE_AUTODESK_FUSION_GUARD_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
set +e
_autodesk_fusion_delete_guard_allows "$old"
guard_rc=$?
set -e
printf 'RC:%s REASON:%s\n' "$guard_rc" "$_MOLE_AUTODESK_FUSION_GUARD_REASON"
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC:1 REASON:Autodesk started"* ]] || return 1
    [[ -d "$old" ]]
}

@test "Autodesk Fusion final guard catches the current alias switching during candidate probes" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
alias_path="$prod/Autodesk Fusion.app"
pgrep() { return 1; }
plutil_counter="$HOME/plutil-counter"
: > "$plutil_counter"
run_with_timeout() {
    shift
    if [[ "$1" == "/usr/bin/plutil" ]]; then
        local plutil_calls
        plutil_calls=$(wc -l < "$plutil_counter")
        plutil_calls=$((plutil_calls + 1))
        printf '%s\n' "$plutil_calls" >> "$plutil_counter"
        if [[ $plutil_calls -eq 4 ]]; then
            rm "$alias_path"
            ln -s "$old/Autodesk Fusion.app" "$alias_path"
        fi
    fi
    "$@"
}
_mole_snapshot_path_identity "$old"
_MOLE_AUTODESK_FUSION_GUARD_ROOT="$prod"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR="$current"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION="2.0.200"
_MOLE_AUTODESK_FUSION_GUARD_DEADLINE=$((SECONDS + 10))
_MOLE_AUTODESK_FUSION_GUARD_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
set +e
_autodesk_fusion_delete_guard_allows "$old"
guard_rc=$?
set -e
plutil_calls=$(wc -l < "$plutil_counter" | tr -d '[:space:]')
printf 'RC:%s REASON:%s PLUTIL:%s\n' \
    "$guard_rc" "$_MOLE_AUTODESK_FUSION_GUARD_REASON" "$plutil_calls"
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC:1 REASON:current version changed"* ]] || return 1
    [[ -d "$old" ]]
}

@test "Autodesk Fusion final guard catches the current alias switching during its final process probe" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
alias_path="$prod/Autodesk Fusion.app"
process_calls=0
autodesk_cache_process_state() {
    process_calls=$((process_calls + 1))
    if [[ $process_calls -eq 2 ]]; then
        rm "$alias_path"
        ln -s "$old/Autodesk Fusion.app" "$alias_path"
    fi
    return 1
}
_mole_snapshot_path_identity "$old"
_MOLE_AUTODESK_FUSION_GUARD_ROOT="$prod"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR="$current"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION="2.0.200"
_MOLE_AUTODESK_FUSION_GUARD_DEADLINE=$((SECONDS + 10))
_MOLE_AUTODESK_FUSION_GUARD_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
set +e
_autodesk_fusion_delete_guard_allows "$old"
guard_rc=$?
set -e
printf 'RC:%s REASON:%s PROCESS:%s\n' \
    "$guard_rc" "$_MOLE_AUTODESK_FUSION_GUARD_REASON" "$process_calls"
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC:1 REASON:current version changed PROCESS:2"* ]] || return 1
    [[ -d "$old" ]]
}

@test "Autodesk Fusion final current resolver rebinds the alias after metadata probes" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    make_fusion_version_dir "$current" "2.0.200"
    make_fusion_version_dir "$old" "2.0.100"
    ln -s "$current/Autodesk Fusion.app" "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
old="$prod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
alias_path="$prod/Autodesk Fusion.app"
pgrep() { return 1; }
plutil_counter="$HOME/final-resolver-plutil-counter"
: > "$plutil_counter"
run_with_timeout() {
    shift
    if [[ "$1" == "/usr/bin/plutil" ]]; then
        local plutil_calls
        plutil_calls=$(wc -l < "$plutil_counter")
        plutil_calls=$((plutil_calls + 1))
        printf '%s\n' "$plutil_calls" >> "$plutil_counter"
        if [[ $plutil_calls -eq 7 ]]; then
            rm "$alias_path"
            ln -s "$old/Autodesk Fusion.app" "$alias_path"
        fi
    fi
    "$@"
}
_mole_snapshot_path_identity "$old"
_MOLE_AUTODESK_FUSION_GUARD_ROOT="$prod"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR="$current"
_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION="2.0.200"
_MOLE_AUTODESK_FUSION_GUARD_DEADLINE=$((SECONDS + 10))
_MOLE_AUTODESK_FUSION_GUARD_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
set +e
_autodesk_fusion_delete_guard_allows "$old"
guard_rc=$?
set -e
plutil_calls=$(wc -l < "$plutil_counter" | tr -d '[:space:]')
printf 'RC:%s REASON:%s PLUTIL:%s\n' \
    "$guard_rc" "$_MOLE_AUTODESK_FUSION_GUARD_REASON" "$plutil_calls"
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC:1 REASON:current version unknown PLUTIL:9"* ]] || return 1
    [[ -d "$old" ]]
}

@test "Finder alias resolver passes the alias path as inert argv" {
    local prod="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    rm -rf "$HOME/Library/Application Support/Autodesk"
    local current="$prod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    make_fusion_version_dir "$current" "2.0.200"
    touch "$prod/Autodesk Fusion.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
alias_path="$HOME/Library/Application Support/Autodesk/webdeploy/production/Autodesk Fusion.app"
target="$HOME/Library/Application Support/Autodesk/webdeploy/production/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Autodesk Fusion.app"
run_with_timeout() {
    shift
    if [[ "$1" == "/usr/bin/osascript" ]]; then
        [[ "${!#}" == "$alias_path" ]] || return 79
        printf '%s\n' "$target"
        return 0
    fi
    "$@"
}
_autodesk_fusion_resolve_current_version \
    "$HOME/Library/Application Support/Autodesk/webdeploy/production" \
    "$((SECONDS + 10))"
printf 'CURRENT:%s|%s\n' \
    "$_MOLE_AUTODESK_FUSION_RESOLVED_DIR" \
    "$_MOLE_AUTODESK_FUSION_RESOLVED_VERSION"
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"CURRENT:$current|2.0.200"* ]]
}

@test "clean_wechat_container_caches cleans sandboxed containers and spares chat data" {
    local iso="$HOME/iso-wechat-targets"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
wechat="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
wecom="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
mkdir -p "$wechat/Documents/app_data/log" "$wechat/.wxapplet/WMPF"
mkdir -p "$wecom/Library/Application Support/WXWork/Log"
mkdir -p "$wecom/Documents/cefcache/wew_1/Service Worker/CacheStorage/origin"
mkdir -p "$wecom/Documents/cefcache/wew_1/Service Worker/Database"
mkdir -p "$wecom/Documents/cefcache/wew_1/Service Worker/ScriptCache"
mkdir -p "$wecom/Documents/cefcache/wew_1/Cache"
mkdir -p "$wecom/Documents/cefcache/wew_1/Code Cache"
mkdir -p "$wecom/Documents/cefcache/wew_1/GPUCache"
touch "$wechat/Documents/app_data/log/wechat.log"
touch "$wechat/.wxapplet/WMPF/mini-program.cache"
touch "$wecom/Library/Application Support/WXWork/Log/wecom.log"
touch "$wecom/Documents/cefcache/wew_1/Cache/web.cache"
touch "$wecom/Documents/cefcache/wew_1/Code Cache/code.cache"
touch "$wecom/Documents/cefcache/wew_1/GPUCache/gpu.cache"
# User data siblings that must never be reached.
mkdir -p "$wechat/Documents/xwechat_files/acct_1/db_storage"
mkdir -p "$wechat/Documents/app_data/radium/users"
mkdir -p "$wecom/Documents/Profiles/AAA/Messages1"
mkdir -p "$wecom/Documents/Profiles/AAA/Publishsys/pkg"
mkdir -p "$wecom/Documents/cefcache/wew_1/Local Storage"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 1; }
wecom_running() { return 1; }
safe_clean_guarded() { shift; echo "SC|$*"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Documents/app_data/log/"*"WeChat logs"* ]] || return 1
    [[ "$output" == *".wxapplet/WMPF/"*"WeChat mini program cache"* ]] || return 1
    [[ "$output" == *"WXWork/Log/"*"WeCom logs"* ]] || return 1
    [[ "$output" == *"cefcache/wew_1/Service Worker/CacheStorage/"*"WeCom service worker cache"* ]] || return 1
    [[ "$output" == *"cefcache/wew_1/Cache/"*"WeCom web cache"* ]] || return 1
    [[ "$output" == *"cefcache/wew_1/Code Cache/"*"WeCom code cache"* ]] || return 1
    [[ "$output" == *"cefcache/wew_1/GPUCache/"*"WeCom GPU cache"* ]] || return 1
    # Chat databases, account state and unmeasured payloads stay untouched.
    [[ "$output" != *"xwechat_files"* ]] || return 1
    [[ "$output" != *"radium/users"* ]] || return 1
    [[ "$output" != *"Messages1"* ]] || return 1
    [[ "$output" != *"Publishsys"* ]] || return 1
    [[ "$output" != *"Local Storage"* ]] || return 1
    [[ "$output" != *"Service Worker/Database"* ]] || return 1
    [[ "$output" != *"Service Worker/ScriptCache"* ]] || return 1
}

@test "clean_wechat_container_caches takes only the web profile caches" {
    local iso="$HOME/iso-wechat-radium"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
profile="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/web/profiles/multitab_a1"
mkdir -p "$profile/Cache" "$profile/Service Worker/CacheStorage" "$profile/IndexedDB" "$profile/WebStorage"
touch "$profile/Cache/data_0" "$profile/Service Worker/CacheStorage/index"
touch "$profile/IndexedDB/site.db" "$profile/WebStorage/store"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 1; }
wecom_running() { return 1; }
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${*: -1}"
    local path
    for path in "${@:1:$#-1}"; do
        if "$guard" "$path"; then echo "OK|$path|$label"; else echo "NO|$path"; fi
    done
}
clean_wechat_container_caches
if _wechat_container_delete_guard_allows "$profile/IndexedDB/site.db"; then echo "LEAK|IndexedDB"; fi
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"OK|$iso/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/web/profiles/multitab_a1/Cache/data_0|WeChat web cache"* ]] || return 1
    [[ "$output" == *"OK|"*"multitab_a1/Service Worker/CacheStorage/index|WeChat service worker cache"* ]] || return 1
    [[ "$output" != *"IndexedDB"* ]] || return 1
    [[ "$output" != *"WebStorage"* ]] || return 1
    [[ "$output" != *"NO|"* ]] || return 1
}

@test "clean_wechat_container_caches skips every target while an owner is running" {
    local iso="$HOME/iso-wechat-running"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
wecom="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
mkdir -p "$wecom/Documents/cefcache/wew_1/Cache"
mkdir -p "$wecom/Library/Application Support/WXWork/Log"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 0; }
wecom_running() { return 0; }
safe_clean_guarded() { shift; echo "SC|$*"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"SC|"* ]] || return 1
}

@test "clean_wechat_container_caches fails closed when process state is unknown" {
    local iso="$HOME/iso-wechat-unknown"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
wecom="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
mkdir -p "$wecom/Documents/cefcache/wew_1/Cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 1; }
wecom_running() { return 2; }
safe_clean_guarded() { shift; echo "SC|$*"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"SC|"* ]] || return 1
}

@test "clean_wechat_container_caches refuses a symlinked WeCom profile" {
    local iso="$HOME/iso-wechat-symlink"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
wecom="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
mkdir -p "$wecom/Documents/cefcache"
mkdir -p "$HOME/elsewhere/Cache"
ln -s "$HOME/elsewhere" "$wecom/Documents/cefcache/wew_evil"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 1; }
wecom_running() { return 1; }
safe_clean_guarded() { shift; echo "SC|$*"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"elsewhere"* ]] || return 1
    [[ "$output" != *"wew_evil"* ]] || return 1
}

@test "clean_wechat_container_caches ignores WeCom component payloads under cefcache" {
    local iso="$HOME/iso-wechat-components"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cef="$HOME/Library/Containers/com.tencent.WeWorkMac/Data/Documents/cefcache"
# A real profile owns Chromium cache directories.
mkdir -p "$cef/Default/Cache" "$cef/Default/Service Worker/CacheStorage/origin"
mkdir -p "$cef/wew_1688857906463120/Cache"
# Component-updater payloads sit beside profiles and hold version directories.
mkdir -p "$cef/AutofillStates/2024.11.26.0"
mkdir -p "$cef/CertificateRevocation/2025.6.13.84507" "$cef/CertificateRevocation/Cache"
mkdir -p "$cef/CookieReadinessList/2024.11.26.0"
touch "$cef/CertificateRevocation/Cache/component-sentinel"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 1; }
wecom_running() { return 1; }
safe_clean_guarded() { shift; echo "SC|$*"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"cefcache/Default/Cache/"* ]] || return 1
    [[ "$output" == *"cefcache/wew_1688857906463120/Cache/"* ]] || return 1
    [[ "$output" != *"AutofillStates"* ]] || return 1
    [[ "$output" != *"CertificateRevocation"* ]] || return 1
    [[ "$output" != *"CookieReadinessList"* ]] || return 1
}

@test "clean_wechat_container_caches stays quiet when every cache root is empty" {
    local iso="$HOME/iso-wechat-empty"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Containers/com.tencent.xinWeChat/Data"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 0; }
wecom_running() { return 1; }
mole_report_guard_stop() { echo "DEFER"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ -z "$output" ]]
}

@test "clean_wechat_container_caches does not let a running WeChat block idle WeCom" {
    local iso="$HOME/iso-messaging-independent"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
wechat="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
wecom="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
mkdir -p "$wechat/Documents/app_data/log" "$wecom/Documents/cefcache/wew_1/Cache"
touch "$wechat/Documents/app_data/log/wechat.log" "$wecom/Documents/cefcache/wew_1/Cache/wecom.cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 0; }
wecom_running() { return 1; }
safe_clean_guarded() { shift; echo "SC|$*"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"wechat.log"* ]] || return 1
    [[ "$output" == *"wecom.cache"* ]]
}

@test "wecom_running recognizes the localized main process" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
mole_pgrep_any() {
    while [[ $# -ge 2 ]]; do
        [[ "$1" == "-x" && "$2" == "企业微信" ]] && return 0
        shift 2
    done
    return 1
}
wecom_running
EOF

    [ "$status" -eq 0 ]
}

@test "clean_wechat_container_caches refuses a symlinked WeCom cache root" {
    local iso="$HOME/iso-wecom-cache-symlink"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
profile="$HOME/Library/Containers/com.tencent.WeWorkMac/Data/Documents/cefcache/wew_1"
mkdir -p "$profile" "$HOME/outside"
touch "$HOME/outside/private"
ln -s "$HOME/outside" "$profile/Cache"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_running() { return 1; }
wecom_running() { return 1; }
safe_clean_guarded() { shift; echo "SC|$*"; }
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"outside/private"* ]] || return 1
    [[ "$output" != *"WeCom web cache"* ]]
}

@test "clean_wechat_container_caches refuses a WeCom cache child symlink" {
    local iso="$HOME/iso-wecom-cache-child-symlink"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache_root="$HOME/Library/Containers/com.tencent.WeWorkMac/Data/Documents/cefcache/wew_1/Cache"
mkdir -p "$cache_root" "$HOME/outside"
touch "$HOME/outside/private"
ln -s "$HOME/outside" "$cache_root/escaped"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_or_wecom_running() { return 1; }
wechat_running() { return 1; }
wecom_running() { return 1; }
safe_clean_guarded() {
    local guard="$1"
    local path="$2"
    "$guard" "$path" && echo "UNSAFE:$path"
    return 0
}
clean_wechat_container_caches
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"UNSAFE:"* ]]
}

@test "clean_wechat_container_caches refuses a symlinked WeChat Data root" {
    local iso="$HOME/iso-wechat-data-symlink"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
container="$HOME/Library/Containers/com.tencent.xinWeChat"
outside="$HOME/outside-data"
mkdir -p "$container" "$outside/Documents/app_data/log"
touch "$outside/Documents/app_data/log/private"
ln -s "$outside" "$container/Data"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
wechat_or_wecom_running() { return 1; }
_wechat_container_process_guard_allows() { return 0; }
_mole_should_refuse_live_user_cache_path() { return 1; }
export MOLE_UNINSTALL_MODE=1
target="$container/Data/Documents/app_data/log/private"
_MOLE_SAFE_CLEAN_BOUND_PATH=""
_MOLE_SAFE_CLEAN_EXPECTED_PARENT=""
_MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID=""
_MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID=""
guard_rc=0
_wechat_container_delete_guard_allows "$target" || guard_rc=$?
if [[ $guard_rc -eq 0 ]]; then
    safe_remove "$target" true 1 "" \
        "$_MOLE_SAFE_CLEAN_EXPECTED_PARENT" \
        "$_MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID" \
        "$_MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID" || true
fi
printf 'GUARD:%s EXISTS:%s\n' "$guard_rc" \
    "$(test -f "$outside/Documents/app_data/log/private" && echo yes || echo no)"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"GUARD:1 EXISTS:yes"* ]]
}

@test "WeChat delete guard binds an exact in-container candidate" {
    local iso="$HOME/iso-wechat-binding"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache_root="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/log"
target_path="$cache_root/wechat.log"
mkdir -p "$cache_root"
touch "$target_path"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
_wechat_container_process_guard_allows() { return 0; }
_MOLE_SAFE_CLEAN_BOUND_PATH=""
_MOLE_SAFE_CLEAN_EXPECTED_PARENT=""
_MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID=""
_MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID=""
_wechat_container_delete_guard_allows "$target_path"
printf 'BOUND:%s\nPARENT:%s\n' \
    "$_MOLE_SAFE_CLEAN_BOUND_PATH" "$_MOLE_SAFE_CLEAN_EXPECTED_PARENT"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"BOUND:$iso/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/log/wechat.log"* ]] || return 1
    [[ "$output" == *"PARENT:$iso/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/log"* ]]
}

@test "obsolete false and nonboolean values preserve installed extensions" {
    local ext_root="$HOME/.vscode/extensions"
    mkdir -p "$ext_root/keep-false" "$ext_root/keep-string" "$ext_root/remove-true"
    printf '%s\n' '{"keep-false":false,"keep-string":"true","remove-true":true}' > "$ext_root/.obsolete"
    run_editor_extension_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$ext_root/remove-true"* ]] || return 1
    [[ "$output" != *"CLEAN:$ext_root/keep-"* ]] || return 1
}

@test "code editor VSIX download caches stay separate from installed extensions (#1654)" {
    mkdir -p "$HOME/.vscode/extensions/keep-active-1654"
    touch "$HOME/.vscode/extensions/keep-active-1654/package.json"
    for editor in Code Cursor; do
        mkdir -p "$HOME/Library/Application Support/$editor/CachedExtensionVSIXs"
        mkdir -p "$HOME/Library/Application Support/$editor/User"
        touch "$HOME/Library/Application Support/$editor/CachedExtensionVSIXs/example.vsix"
        touch "$HOME/Library/Application Support/$editor/User/settings.json"
    done
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { printf 'CLEAN:%s\n' "$1"; }
clean_code_editors
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Code/CachedExtensionVSIXs/example.vsix"* ]] || return 1
    [[ "$output" == *"Cursor/CachedExtensionVSIXs/example.vsix"* ]] || return 1
    [[ "$output" != *"/User/"* ]] || return 1
    [[ "$output" != *"/.vscode/extensions/keep-active-1654"* ]] || return 1
}

@test "ordinary media cleanup keeps rendered footage and Spotify stores without offline markers" {
    run env HOME="$HOME/media-policy" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SH'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
fcp="$HOME/Movies/Project.fcpbundle/Event/Render Files/High Quality Media"
proxy="$HOME/Movies/Project.fcpbundle/Event/Transcoded Media/Proxy Media"
cache="$HOME/Movies/JianyingPro/User Data/Cache"
spotify="$HOME/Library/Caches/com.spotify.client/Data"
mkdir -p "$fcp" "$proxy" "$spotify" "$cache/recognize" "$cache/prerender" "$cache/RemuxCache" "$cache/MotionBlurCache" "$cache/segmentPrerenderCache"
pgrep() { return 1; }
safe_clean() { printf '%s\n' "$@" >> "$HOME/candidates"; }
clean_video_tools
clean_media_players
# A scratch target remains a positive control for the real cleanup path.
grep -qxF "$cache/recognize" "$HOME/candidates" || exit 1
if grep -E 'High Quality Media|Proxy Media|prerender|RemuxCache|MotionBlurCache|segmentPrerenderCache|Spotify|com.spotify.client' "$HOME/candidates"; then exit 1; fi
SH
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "named app cache guard escapes literal names and rechecks every removal" {
    run env HOME="$BATS_TEST_TMPDIR/named-literal" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME/Library/Application Support/App[1]/Cache"
touch "$HOME/Library/Application Support/App[1]/Cache/one" "$HOME/Library/Application Support/App[1]/Cache/two"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
note_activity() { :; }
pgrep() {
    [[ "$2" == 'App\[1\]' || "$2" == '/App\[1\][.]app/' ]] || { echo BAD_PATTERN >&2; return 2; }
    [[ -e "$HOME/started" ]]
}
get_cleanup_path_size_kb() { echo 1; }
safe_remove() { echo "SINK:$1"; touch "$HOME/started"; }
mole_safe_clean_app_cache 'App[1]' "$HOME/Library/Application Support/App[1]/Cache/one" \
    "$HOME/Library/Application Support/App[1]/Cache/two" 'App cache'
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SINK:"*"/one"* ]] || return 1
    [[ "$output" != *"SINK:"*"/two"* ]] || return 1
    [[ "$output" != *BAD_PATTERN* ]]
}

@test "CodeBuddy extension caches preserve each shared owner and late starts" {
    local owner phase
    for owner in CodeBuddy 'CodeBuddy CN' WorkBuddy Unrelated; do
        for phase in initial after-size; do
            run env HOME="$BATS_TEST_TMPDIR/shared-$owner-$phase" PROJECT_ROOT="$PROJECT_ROOT" \
                OWNER="$owner" PHASE="$phase" MOLE_TEST_NO_AUTH=1 /bin/bash <<'SH'
set -euo pipefail
mkdir -p "$HOME/Library/Application Support/CodeBuddyExtension/Cache" "$HOME/Library/Application Support/CodeBuddyExtension/logs"
touch "$HOME/Library/Application Support/CodeBuddyExtension/Cache/entry" "$HOME/Library/Application Support/CodeBuddyExtension/logs/entry"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
note_activity() { :; }
pgrep() {
    [[ "$PHASE" == initial || -e "$HOME/sized" ]] || return 1
    case "$1" in
        -x) [[ "$OWNER" =~ ^($2)$ ]] ;;
        -f) [[ "/Applications/$OWNER.app/Contents/MacOS/Electron" =~ $2 ]] ;;
        *) return 2 ;;
    esac
}
get_cleanup_path_size_kb() { touch "$HOME/sized"; echo 1; }
safe_remove() { printf 'SINK:%s\n' "$1"; }
clean_editor_obsolete_extensions() { :; }
clean_code_editors
SH
            [ "$status" -eq 0 ] || { echo "$owner/$phase: $output"; return 1; }
            if [[ "$owner" == Unrelated ]]; then
                [[ "$output" == *SINK:*CodeBuddyExtension/Cache/entry* && "$output" == *SINK:*CodeBuddyExtension/logs/entry* ]] || { echo "$output"; return 1; }
            else
                [[ "$output" != *SINK:* ]] || { echo "$owner/$phase: $output"; return 1; }
            fi
        done
    done
}

@test "cache final sink named initial-running" {
    assert_cache_final_owner_guard initial-running named
}

@test "cache final sink named final-running" {
    assert_cache_final_owner_guard final-running named
}

@test "cache final sink named final-unknown" {
    assert_cache_final_owner_guard final-unknown named
}

@test "cache final sink named idle" {
    assert_cache_final_owner_guard idle named
}

@test "cache final sink named outer-deny" {
    assert_cache_final_owner_guard outer-deny named
}

@test "cache final sink named outer-signal" {
    assert_cache_final_owner_guard outer-signal named
}

@test "cache final sink named outer-start" {
    assert_cache_final_owner_guard outer-start named
}

@test "cache final sink shared initial-running" {
    assert_cache_final_owner_guard initial-running shared
}

@test "cache final sink shared final-running" {
    assert_cache_final_owner_guard final-running shared
}

@test "cache final sink shared final-unknown" {
    assert_cache_final_owner_guard final-unknown shared
}

@test "cache final sink shared idle" {
    assert_cache_final_owner_guard idle shared
}

@test "cache final sink shared outer-deny" {
    assert_cache_final_owner_guard outer-deny shared
}

@test "cache final sink shared outer-signal" {
    assert_cache_final_owner_guard outer-signal shared
}

@test "cache final sink shared outer-start" {
    assert_cache_final_owner_guard outer-start shared
}

@test "cache final sink named final-swap" {
    assert_cache_final_owner_guard final-swap named
}

@test "cache final sink shared final-swap" {
    assert_cache_final_owner_guard final-swap shared
}

@test "cache final sink named post-size-swap" {
    assert_cache_final_owner_guard post-size-swap named
}

@test "cache final sink shared post-size-swap" {
    assert_cache_final_owner_guard post-size-swap shared
}

@test "legacy analyzer cache sweep removes only flat analyzer files from ~/.cache/mole" {
    run env HOME="$BATS_TEST_TMPDIR/legacy-home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
root="$HOME/.cache/mole"
mkdir -p "$root/analyzer" "$root/tmp"
for i in 1 2 3; do printf x > "$root/abc00$i.cache"; done
printf x > "$root/overview_sizes.json"
printf x > "$root/version_check"
printf x > "$root/update_message"
printf x > "$root/pkg_receipt_apps_v1"
printf x > "$root/analyzer/keep.cache"
mkdir "$root/dir.cache"
source "$PROJECT_ROOT/bin/clean.sh"
sweep_legacy_analyzer_cache_now "$root"
ls -A "$root" | sort | tr '\n' ' '
SCRIPT
    [ "$status" -eq 0 ]
    [ "$output" = "analyzer dir.cache pkg_receipt_apps_v1 tmp update_message version_check " ]
}

@test "legacy analyzer cache sweep skips dry runs and a symlinked cache root" {
    run env HOME="$BATS_TEST_TMPDIR/legacy-skip" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
real="$HOME/elsewhere"
mkdir -p "$real" "$HOME/.cache"
printf x > "$real/a.cache"
ln -s "$real" "$HOME/.cache/mole"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
start_legacy_analyzer_cache_sweep
sweep_legacy_analyzer_cache_now "$HOME/.cache/mole"
rm "$HOME/.cache/mole"; mkdir "$HOME/.cache/mole"; printf x > "$HOME/.cache/mole/b.cache"
DRY_RUN=true
start_legacy_analyzer_cache_sweep
sleep 0.5
ls -A "$real" "$HOME/.cache/mole" | tr '\n' ' '
SCRIPT
    [ "$status" -eq 0 ]
    [[ "$output" == *"a.cache"* ]] || return 1
    [[ "$output" == *"b.cache"* ]]
}

@test "clean starts the legacy analyzer cache sweep in the background" {
    run env HOME="$BATS_TEST_TMPDIR/legacy-bg" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
root="$HOME/.cache/mole"
mkdir -p "$root"
for i in $(seq 1 200); do printf x > "$root/f$i.cache"; done
printf x > "$root/version_check"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
MOLE_DRY_RUN=0
start_legacy_analyzer_cache_sweep
for _ in $(seq 1 50); do
    [[ -z "$(find "$root" -maxdepth 1 -name '*.cache' -print -quit)" ]] && break
    sleep 0.1
done
ls -A "$root" | tr '\n' ' '
SCRIPT
    [ "$status" -eq 0 ]
    [ "$output" = "version_check " ]
}

@test "simulator device metadata timeouts retain the device and signals stop later devices" {
    for field in snapshot metadata; do
        for phase in discovery sink; do
            for probe_rc in 1 124 130 143; do
                run env HOME="$HOME/metadata-$field-$phase-$probe_rc" PROJECT_ROOT="$PROJECT_ROOT" \
                    PATH="/usr/bin:/bin" MOLE_TEST_NO_AUTH=1 FIELD="$field" PHASE="$phase" PROBE_RC="$probe_rc" \
                    /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
_coresimulator_activity_state() { return 1; }
at_sink=false
_simulator_app_cache_delete_guard_allows() { at_sink=true; return 0; }
eval "$(declare -f run_with_timeout | sed '1s/run_with_timeout/original_run_with_timeout/')"
run_with_timeout() {
    if { [[ "$FIELD" == metadata && "$*" == *"/usr/bin/awk"* ]] || [[ "$FIELD" == snapshot && "$*" == *"-convert xml1 "* ]]; } &&
        [[ "${plist:-}" == */A/device.plist ]] &&
        { [[ "$PHASE" == discovery ]] || [[ "$at_sink" == true ]]; }; then
        return "$PROBE_RC"
    fi
    original_run_with_timeout "$@"
}
devices="$HOME/Library/Developer/CoreSimulator/Devices"
for device in A B; do
    mkdir -p "$devices/$device/data/Library/Caches/tiles"
    printf fixture > "$devices/$device/data/Library/Caches/tiles/tile"
    /usr/bin/plutil -create xml1 "$devices/$device/device.plist"
    /usr/bin/plutil -insert state -integer 1 "$devices/$device/device.plist"
done
DRY_RUN=false
rc=0
clean_xcode_tools || rc=$?
printf 'field=%s phase=%s probe=%s returned=%s\n' "$FIELD" "$PHASE" "$PROBE_RC" "$rc"
[[ -f "$devices/A/data/Library/Caches/tiles/tile" ]] || { echo A_REMOVED; exit 1; }
if [[ "$PROBE_RC" -gt 127 ]]; then
    [[ "$rc" -eq "$PROBE_RC" ]] || exit 2
    [[ -f "$devices/B/data/Library/Caches/tiles/tile" ]] || { echo LATER_REMOVED; exit 3; }
else
    [[ "$rc" -eq 0 ]] || exit 4
    [[ ! -e "$devices/B/data/Library/Caches" ]] || { echo LATER_NOT_REACHED; exit 5; }
fi
EOF
                [ "$status" -eq 0 ] || { echo "$output"; return 1; }
            done
        done
    done
}

@test "simulator metadata uses root XML types rather than missing-key diagnostics" {
    run env HOME="$HOME/simulator-xml-types" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="/usr/bin:/bin" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
mkdir -p "$HOME/device"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
for scenario in absent false true string_false integer_zero nested_true empty_neighbor wrong_state; do
    extra=''
    state='<integer>1</integer>'
    expected=1
    case "$scenario" in
        absent) expected=0 ;;
        false) extra='<key>isDeleted</key><false/>'; expected=0 ;;
        true) extra='<key>isDeleted</key><true/>' ;;
        string_false) extra='<key>isDeleted</key><string>false</string>' ;;
        integer_zero) extra='<key>isDeleted</key><integer>0</integer>' ;;
        nested_true) extra='<key>nested</key><dict><key>isDeleted</key><true/></dict>'; expected=0 ;;
        empty_neighbor) extra='<key>empty</key><dict/><key>isDeleted</key><false/>'; expected=0 ;;
        wrong_state) state='<string>1</string>' ;;
    esac
    printf '<plist version="1.0"><dict><key>state</key>%s%s</dict></plist>\n' "$state" "$extra" > "$HOME/device/device.plist"
    rc=0
    _simulator_device_is_shut_down "$HOME/device" || rc=$?
    printf '%s returned=%s expected=%s\n' "$scenario" "$rc" "$expected"
    if [[ "$rc" -ne "$expected" ]]; then
        # Preserve the native host evidence, including macOS 15 diagnostics,
        # without using its prose to make a production cleanup decision.
        for key in state isDeleted; do
            native_rc=0
            native_output=$(/usr/bin/plutil -extract "$key" raw -o - "$HOME/device/device.plist" 2>&1) || native_rc=$?
            printf 'native key=%s status=%s output=<%s>\n' "$key" "$native_rc" "$native_output"
        done
        exit 1
    fi
done
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "clean_wechat_container_caches cleans every web profile in one row per cache kind" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
profiles="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/web/profiles"
for p in one two three; do
    mkdir -p "$profiles/$p/Cache" "$profiles/$p/Service Worker/CacheStorage"
    printf 'x' > "$profiles/$p/Cache/entry"
done
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
_wechat_container_process_guard_allows() { return 0; }
mole_cleanup_targets_exist() { return 0; }
safe_clean_guarded() { echo "SCG|${*: -1}|$(($# - 2))"; }
clean_wechat_container_caches
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | grep -c '^SCG|WeChat web cache|')" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SCG|WeChat web cache|3"* ]] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | grep -c '^SCG|WeChat service worker cache|')" -eq 1 ] || { echo "$output"; return 1; }
}
