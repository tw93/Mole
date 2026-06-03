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
pgrep() { return 0; }
safe_clean() { echo "$2"; }
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode is running"* ]]
    [[ "$output" != *"derived data"* ]]
    [[ "$output" != *"documentation cache"* ]]
}

@test "clean_xcode_tools cleans documentation caches but not archives when Xcode is not running" {
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
    [[ "$output" != *"Xcode archives"* ]]
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

@test "clean_final_cut_pro_generated_caches targets only safe generated media in Movies libraries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"CLEAN:$HOME/Movies/Project.fcpbundle/Event/Render Files/High Quality Media"* ]]
    [[ "$output" == *"CLEAN:$HOME/Movies/Project.fcpbundle/Event/Transcoded Media/Proxy Media"* ]]
    [[ "$output" == *"CLEAN:Final Cut Pro generated cache"* ]]
    [[ "$output" != *"Transcoded Media/High Quality Media"* ]]
    [[ "$output" != *"Analysis Files"* ]]
    [[ "$output" != *"Original Media"* ]]
    [[ "$output" != *"Documents/Other.fcpbundle"* ]]
}

@test "clean_final_cut_pro_generated_caches skips while Final Cut Pro is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"Final Cut Pro is running"* ]]
    [[ "$output" != *"unexpected safe_clean"* ]]
}

@test "is_final_cut_pro_generated_cache_target rejects protected sibling paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
note_activity() { :; }
clean_ai_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"ChatGPT cache"* ]]
    [[ "$output" == *"Claude desktop cache"* ]]
    [[ "$output" != *"Codex"* ]]
}

@test "clean_ai_apps skips Codex Desktop state by default" {
    mkdir -p "$HOME/Library/Application Support/Codex/Cache" "$HOME/Library/Logs/com.openai.codex"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
note_activity() { echo "NOTE_ACTIVITY"; }
clean_ai_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex Desktop state · skipped by default"* ]]
    [[ "$output" == *"NOTE_ACTIVITY"* ]]
    [[ "$output" != *"Codex cache"* ]]
    [[ "$output" != *"Codex CLI logs"* ]]
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
mkdir -p ~/Library/Application\ Support/iDingTalk
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
mkdir -p ~/Library/Application\ Support/Microsoft/Teams
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
mkdir -p ~/Library/Application\ Support/Steam ~/Library/Application\ Support/Battle.net
mkdir -p ~/Library/Application\ Support/minecraft ~/.lunarclient
mkdir -p ~/Library/Application\ Support/PCSX2 ~/Library/Application\ Support/rpcs3
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

# Previously the cleanup path used '|| true' followed by an unconditional
# green SUCCESS echo, so a simctl timeout (124) or any failure was reported
# as "deleted N devices". Capture exit code and branch on it.
@test "clean_xcode_tools reports failure when simctl delete returns non-zero" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "$2"; }
xcrun() {
    case "$*" in
        "simctl list devices unavailable")
            echo "== Devices =="
            echo "-- Unavailable --"
            echo "    iPhone 12 (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown) (unavailable)"
            return 0
            ;;
        "simctl delete unavailable")
            return 124   # simulate run_with_timeout firing
            ;;
    esac
    return 0
}
export -f xcrun
clean_xcode_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"deleted 1 devices"* ]]
    [[ "$output" == *"simctl delete failed"* ]]
    [[ "$output" == *"exit=124"* ]]
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
    [[ "$output" == *"Stremio cache"* ]]
    [[ "$output" == *"Stremio server cache"* ]]
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
    [[ "$output" == *"CLEAN:$HOME/.vscode/extensions/pub.ext-old-1.0.0"* ]]
    [[ "$output" != *"pub.ext-new-1.1.0"* ]]
}

@test "clean_editor_obsolete_extensions rejects path-traversal keys in .obsolete (#910)" {
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor"
    local ext_root="$HOME/.cursor/extensions"
    mkdir -p "$ext_root"
    mkdir -p "$HOME/obsolete-victim"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "../../obsolete-victim": true,
  "..": true
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
    [[ "$output" != *"CLEAN:"* ]]
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
    [[ "$output" == *"CodeBuddy Extension cache"* ]]
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
    [[ "$output" == *"CodeBuddy CN cache"* ]]
    [[ "$output" == *"CodeBuddy CN logs"* ]]
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
    [[ "$output" == *"QQ Music Mac cache"* ]]
    [[ "$output" == *"QQ Music streaming cache"* ]]
    [[ "$output" == *"QQ Music logs"* ]]
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
    [[ "$output" == *"Tencent Video old installer"* ]]
    [[ "$output" == *"Tencent Video native cache"* ]]
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
    [[ "$output" == *"NeatDM stale downloads"* ]]
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
    [[ "$output" != *"NeatDM stale downloads"* ]]
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
    [[ "$output" != *"NeatDM stale downloads"* ]]
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
