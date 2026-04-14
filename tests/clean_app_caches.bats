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
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_xcode_tools skips derived data when Xcode running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 0; }
safe_clean() { echo "$2"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode is running"* ]]
    [[ "$output" != *"derived data"* ]]
    [[ "$output" != *"archives"* ]]
    [[ "$output" != *"documentation cache"* ]]
}

@test "clean_xcode_tools cleans documentation caches when Xcode is not running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "$2"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode derived data"* ]]
    [[ "$output" == *"Xcode archives"* ]]
    [[ "$output" == *"Xcode documentation cache"* ]]
    [[ "$output" == *"Xcode documentation index"* ]]
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
    [[ "$output" != *"CLEAN:Spotify cache"* ]]
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
    [[ "$output" != *"Spotify cache protected"* ]]
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
    [[ "$output" != *"xcode"* ]]
    [[ "$output" != *"editors"* ]]
    [[ "$output" == *"comm"* ]]
    [[ "$output" == *"dingtalk"* ]]
    [[ "$output" == *"ai"* ]]
}

@test "clean_ai_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_ai_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"ChatGPT cache"* ]]
    [[ "$output" == *"Claude desktop cache"* ]]
}

@test "clean_design_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_design_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sketch cache"* ]]
    [[ "$output" == *"Figma cache"* ]]
}

@test "clean_dingtalk calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_dingtalk
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DingTalk iDingTalk cache"* ]]
    [[ "$output" == *"DingTalk logs"* ]]
}

@test "clean_download_managers calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_download_managers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Aria2 cache"* ]]
    [[ "$output" == *"qBittorrent cache"* ]]
}

@test "clean_productivity_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_productivity_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"MiaoYan cache"* ]]
    [[ "$output" == *"Flomo cache"* ]]
}

@test "clean_screenshot_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_screenshot_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CleanShot cache"* ]]
    [[ "$output" == *"Xnip cache"* ]]
}

@test "clean_office_applications calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
clean_office_applications
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Microsoft Word cache"* ]]
    [[ "$output" == *"Apple iWork cache"* ]]
}

@test "clean_communication_apps includes Microsoft Teams legacy caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_communication_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Microsoft Teams legacy cache"* ]]
    [[ "$output" == *"Microsoft Teams legacy logs"* ]]
}

@test "clean_gaming_platforms includes steam and minecraft related caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_gaming_platforms
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Steam app cache"* ]]
    [[ "$output" == *"Steam shader cache"* ]]
    [[ "$output" == *"Minecraft logs"* ]]
    [[ "$output" == *"Lunar Client logs"* ]]
}

@test "clean_code_editors includes Zed caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_code_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Zed cache"* ]]
    [[ "$output" == *"Zed logs"* ]]
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
    [[ "$output" == *"Warp cache"* ]]
    [[ "$output" == *"Warp log"* ]]
    [[ "$output" == *"Warp Sentry crash reports"* ]]
    [[ "$output" == *"Ghostty cache"* ]]
}

@test "clean_xcode_tools handles zero unavailable simulators without syntax error" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "$2"; }
xcrun() {
    if [[ "$*" == "simctl list devices unavailable" ]]; then
        echo "== Devices =="
        echo "-- iOS 17.0 --"
        return 0
    fi
    return 0
}
export -f xcrun
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"syntax error"* ]]
    [[ "$output" != *"Unavailable simulators"* ]]
}

@test "clean_xcode_tools reports unavailable simulators when present" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "$2"; }
xcrun() {
    if [[ "$*" == "simctl list devices unavailable" ]]; then
        echo "== Devices =="
        echo "-- Unavailable --"
        echo "    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)"
        echo "    iPhone 13 (12345678-90AB-CDEF-1234-567890ABCDEF) (Shutdown) (unavailable)"
        return 0
    fi
    return 0
}
export -f xcrun
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"syntax error"* ]]
    [[ "$output" == *"would delete 2 devices"* ]]
}

@test "clean_video_players includes Stremio caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_video_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Stremio cache"* ]]
    [[ "$output" == *"Stremio server cache"* ]]
}
