#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-app-caches.XXXXXX")"
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

@test "clean_xcode_tools skips derived data when Xcode running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
    pgrep() { [[ "$1" == "-x" && "$2" == "xcodebuild" ]]; }
safe_clean() { echo "$2"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Xcode DerivedData · skipped"* ]] || return 1
    [[ "$output" != *"derived data"* ]] || return 1
    [[ "$output" != *"documentation cache"* ]]
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { [[ "$2" == "xcodebuild" ]]; }
safe_clean() {
    case "${!#}" in
        "Xcode cache" | "Xcode build products") echo "UNEXPECTED_XCODE_CLEAN:${!#}" ;;
    esac
}
clean_xcode_tools
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Xcode cache/build products · skipped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_XCODE_CLEAN"* ]]
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
    [[ "$output" == *"Spotify cache protected"* ]]
}

@test "clean_media_players cleans spotify cache when bnk is empty" {
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
    [[ "$output" == *"CLEAN:Spotify cache"* ]]
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

@test "clean_final_cut_pro_generated_caches targets only safe generated media in Movies libraries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

mkdir -p "$HOME/Movies/Project.fcpbundle/Event/Render Files/High Quality Media"
mkdir -p "$HOME/Movies/Project.fcpbundle/Event/Transcoded Media/Proxy Media"
mkdir -p "$HOME/Movies/Project.fcpbundle/Event/Transcoded Media/High Quality Media"
mkdir -p "$HOME/Movies/Project.fcpbundle/Event/Analysis Files/Stabilization"
mkdir -p "$HOME/Movies/Project.fcpbundle/Event/Original Media/Render Files/High Quality Media"
mkdir -p "$HOME/Documents/Other.fcpbundle/Event/Render Files/High Quality Media"

touch "$HOME/Movies/Project.fcpbundle/Event/Render Files/High Quality Media/render.mov"
touch "$HOME/Movies/Project.fcpbundle/Event/Transcoded Media/Proxy Media/proxy.mov"

pgrep() { return 1; }
safe_clean() {
    local arg
    for arg in "$@"; do
        printf 'CLEAN:%s\n' "$arg"
    done
}

clean_final_cut_pro_generated_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/Movies/Project.fcpbundle/Event/Render Files/High Quality Media"* ]] || return 1
    [[ "$output" == *"CLEAN:$HOME/Movies/Project.fcpbundle/Event/Transcoded Media/Proxy Media"* ]] || return 1
    [[ "$output" == *"CLEAN:Final Cut Pro generated cache"* ]] || return 1
    [[ "$output" != *"Transcoded Media/High Quality Media"* ]] || return 1
    [[ "$output" != *"Analysis Files"* ]] || return 1
    [[ "$output" != *"Original Media"* ]] || return 1
    [[ "$output" != *"Documents/Other.fcpbundle"* ]]
}

@test "clean_final_cut_pro_generated_caches skips while Final Cut Pro is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

mkdir -p "$HOME/Movies/Project.fcpbundle/Event/Render Files/High Quality Media"
pgrep() { return 0; }
safe_clean() {
    echo "unexpected safe_clean"
    return 1
}

clean_final_cut_pro_generated_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Final Cut Pro generated caches · skipped"* ]] || return 1
    [[ "$output" != *"unexpected safe_clean"* ]]
}

@test "clean_final_cut_pro_generated_caches does not defer whitelist-only targets" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

target="$HOME/Movies/Whitelisted.fcpbundle/Event/Render Files/High Quality Media"
mkdir -p "$target"
touch "$target/render.mov"
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_final_cut_pro_generated_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_final_cut_pro_generated_caches rechecks activity after sizing" {
    run env HOME="$HOME/fcp-size-race" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
target="$HOME/Movies/Race.fcpbundle/Event/Render Files/High Quality Media"
mkdir -p "$target"
touch "$target/render.mov"
pgrep() {
    [[ -e "$HOME/fcp-started" ]] && return 0
    return 1
}
get_cleanup_path_size_kb() {
    : > "$HOME/fcp-started"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
rm -f "$HOME/fcp-started"
clean_final_cut_pro_generated_caches
[[ -f "$target/render.mov" ]] || exit 1
printf 'DEFER:%s\n' "$(format_deferred_cleanup_families)"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DELETE"* ]] || return 1
    [[ "$output" == *"DEFER:Final Cut Pro"* ]]
}

@test "clean_final_cut_pro_generated_caches fails closed when its process probe errors" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

target="$HOME/Movies/Project.fcpbundle/Event/Render Files/High Quality Media"
mkdir -p "$target"
touch "$target/sentinel"
pgrep() { return 2; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:${!#}"; }
note_activity() { :; }

clean_final_cut_pro_generated_caches
[[ -f "$target/sentinel" ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Final Cut Pro generated caches · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
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

@test "is_final_cut_pro_generated_cache_target rejects protected sibling paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"

library="$HOME/Movies/Project.fcpbundle"
mkdir -p "$library/Event/Render Files/High Quality Media"
mkdir -p "$library/Event/Original Media/Render Files/High Quality Media"
mkdir -p "$library/Event/Transcoded Media/High Quality Media"

is_final_cut_pro_generated_cache_target "$library" "$library/Event/Render Files/High Quality Media"
! is_final_cut_pro_generated_cache_target "$library" "$library/Event/Original Media/Render Files/High Quality Media"
! is_final_cut_pro_generated_cache_target "$library" "$library/Event/Transcoded Media/High Quality Media"
EOF

    [ "$status" -eq 0 ]
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
    [[ "$output" == *"Google Clearcut logs"* ]] || return 1
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
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_design_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sketch cache"* ]] || return 1
    [[ "$output" == *"Figma cache"* ]]
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
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_communication_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Microsoft Teams legacy cache"* ]] || return 1
    [[ "$output" == *"Microsoft Teams legacy logs"* ]]
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
    touch -t "$(date -v-31d '+%Y%m%d%H%M.%S')" "$neatdm_dir/12345/seg.x0"

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
    [[ "$output" == *"1 items"* ]]
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
    touch -t "$(date -v-31d '+%Y%m%d%H%M.%S')" "$neatdm_dir/history-backup/seg.x0"

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

@test "Xcode DerivedData cleanup propagates a size timeout before deletion" {
    local isolated_home="$HOME/xcode-derived-timeout"
    mkdir -p "$isolated_home/Library/Developer/Xcode/DerivedData/App-abc"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
DRY_RUN=false
MOLE_CLEAN_CANCEL_STATUS=0
_xcode_cleanup_process_state() { return 1; }
get_path_size_kb() { return 124; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; }
set +e
clean_xcode_derived_data
rc=$?
set -e
printf 'SIZE_RC:%s CANCEL:%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SIZE_RC:124 CANCEL:124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE"* ]]
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
pgrep() {
    if [[ "$*" == *AcCoreConsole* ]] || [[ "$*" == *com.autodesk.AcCoreConsole* ]]; then
        return 0
    fi
    return 1
}
oplog_enabled() { return 1; }
log_operation() { :; }
debug_log() { :; }
db="$HOME/Library/Caches/com.autodesk.AcCoreConsole/Cache.db"
set +e
safe_remove "$db" true
rc=$?
set -e
[[ $rc -ne 0 ]]
[[ -f "$db" ]]
INNER

    [ "$status" -eq 0 ]
    [[ -f "$db" ]]
}

@test "safe_remove deletes an idle reverse-DNS user cache" {
    mkdir -p "$HOME/Library/Caches/com.example.idleapp"
    local db="$HOME/Library/Caches/com.example.idleapp/Cache.db"
    touch "$db"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=0 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
pgrep() { return 1; }
lsof() { return 1; }
oplog_enabled() { return 1; }
log_operation() { :; }
debug_log() { :; }
validate_path_for_deletion() { return 0; }
db="$HOME/Library/Caches/com.example.idleapp/Cache.db"
safe_remove "$db" true
[[ ! -e "$db" ]]
INNER

    [ "$status" -eq 0 ]
    [[ ! -e "$db" ]]
}
