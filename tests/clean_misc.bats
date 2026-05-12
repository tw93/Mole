#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-extras.XXXXXX")"
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

@test "clean_cloud_storage calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
clean_cloud_storage
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Dropbox cache"* ]]
    [[ "$output" == *"Google Drive cache"* ]]
}

@test "clean_virtualization_tools hits cache paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
pgrep() { return 1; }
safe_clean() { echo "$2|$1"; }
clean_virtualization_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"VMware Fusion cache"* ]]
    [[ "$output" == *"Parallels cache"* ]]
    [[ "$output" == *"UTM app cache|$HOME/Library/Caches/com.utmapp.UTM/"* ]]
    [[ "$output" == *"UTM sandbox cache|$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Caches/"* ]]
    [[ "$output" == *"UTM temporary files|$HOME/Library/Containers/com.utmapp.UTM/Data/tmp/"* ]]
}

@test "clean_virtualization_tools skips UTM caches while UTM is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
debug_log() { :; }
pgrep() {
    [[ "${1:-}" == "-x" && "${2:-}" == "UTM" ]]
}
safe_clean() { echo "$2"; }
clean_virtualization_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"VMware Fusion cache"* ]]
    [[ "$output" == *"Parallels cache"* ]]
    [[ "$output" != *"UTM app cache"* ]]
    [[ "$output" != *"UTM sandbox cache"* ]]
}

@test "clean_email_clients calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_email_clients
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Spark cache"* ]]
    [[ "$output" == *"Airmail cache"* ]]
}

@test "clean_note_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_note_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Notion cache"* ]]
    [[ "$output" == *"Obsidian cache"* ]]
}

@test "clean_task_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_task_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Todoist cache"* ]]
    [[ "$output" == *"Any.do cache"* ]]
}

@test "scan_external_volumes skips when no volumes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
export DRY_RUN="false"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
run_with_timeout() { return 1; }
# Mock missing dependencies and UI to ensure test passes regardless of volumes
clean_ds_store_tree() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
is_path_whitelisted() { return 1; }
WHITELIST_PATTERNS=()
PROTECT_FINDER_METADATA="false"
scan_external_volumes
EOF

    [ "$status" -eq 0 ]
}

@test "clean_video_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_video_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"ScreenFlow cache"* ]]
    [[ "$output" == *"Final Cut Pro cache"* ]]
}

@test "clean_video_players calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_video_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"IINA cache"* ]]
    [[ "$output" == *"VLC cache"* ]]
}

@test "clean_3d_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_3d_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Blender cache"* ]]
    [[ "$output" == *"Cinema 4D cache"* ]]
}

@test "clean_gaming_platforms calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_gaming_platforms
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Steam cache"* ]]
    [[ "$output" == *"Epic Games cache"* ]]
}

@test "clean_translation_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_translation_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Youdao Dictionary cache"* ]]
    [[ "$output" == *"Eudict cache"* ]]
}

@test "clean_launcher_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_launcher_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Alfred cache"* ]]
    [[ "$output" == *"The Unarchiver cache"* ]]
}

@test "clean_remote_desktop calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_remote_desktop
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"TeamViewer cache"* ]]
    [[ "$output" == *"AnyDesk cache"* ]]
}

@test "clean_system_utils calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_system_utils
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Input Source Pro cache"* ]]
    [[ "$output" == *"WakaTime cache"* ]]
}

@test "clean_shell_utils calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_shell_utils
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Zsh completion cache"* ]]
    [[ "$output" == *"wget HSTS cache"* ]]
}
