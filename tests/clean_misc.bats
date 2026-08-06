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
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_cloud_storage calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
clean_cloud_storage
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Dropbox cache"* ]] || return 1
    [[ "$output" == *"Google Drive cache"* ]]
}

@test "clean_virtualization_tools hits cache paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
pgrep() { return 1; }
safe_clean() { echo "$2|$1"; }
clean_virtualization_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"VMware Fusion cache"* ]] || return 1
    [[ "$output" == *"Parallels cache"* ]] || return 1
    [[ "$output" == *"UTM app cache|$HOME/Library/Caches/com.utmapp.UTM/"* ]] || return 1
    [[ "$output" == *"UTM sandbox cache|$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Caches/"* ]] || return 1
    [[ "$output" == *"UTM temporary files|$HOME/Library/Containers/com.utmapp.UTM/Data/tmp/"* ]]
}

@test "clean_virtualization_tools skips UTM caches while UTM is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"VMware Fusion cache"* ]] || return 1
    [[ "$output" == *"Parallels cache"* ]] || return 1
    [[ "$output" != *"UTM app cache"* ]] || return 1
    [[ "$output" != *"UTM sandbox cache"* ]]
}

@test "clean_email_clients calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_email_clients
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Spark cache"* ]] || return 1
    [[ "$output" == *"Airmail cache"* ]]
}

@test "clean_virtualization_tools includes Lima download cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
safe_clean() { echo "$2|$1"; }
clean_virtualization_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Lima download cache|$HOME/Library/Caches/lima/download/by-url-sha256/"* ]]
}

@test "clean_tart_caches runs only the native cache-only age prune" {
    rm -rf "$HOME/.tart" "$HOME/tart-args" "$HOME/tart-payload"
    mkdir -p "$HOME/.tart/cache/OCIs"
    : > "$HOME/tart-payload"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { [[ -e "$HOME/tart-payload" ]] && echo 4096 || echo 1024; }
bytes_to_human() { echo "$1 bytes"; }
run_with_timeout() { shift; "$@"; }
tart() {
    printf '%s\n' "$*" > "$HOME/tart-args"
    rm -f "$HOME/tart-payload"
}
clean_tart_caches
EOF

    [ "$status" -eq 0 ]
    [ "$(< "$HOME/tart-args")" = "prune --entries caches --older-than 30" ] || return 1
    [[ "$output" == *"Tart caches · pruned"* ]] || return 1
    [[ "$output" != *"--entries vms"* ]] || return 1
}

@test "clean_tart_caches dry-run shows size, policy, and exact command without execution" {
    rm -rf "$HOME/.tart" "$HOME/tart-called"
    mkdir -p "$HOME/.tart/cache/IPSWs"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 2048; }
bytes_to_human() { echo "2MB"; }
tart() { : > "$HOME/tart-called"; }
clean_tart_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"would prune items older than 30 days (2MB)"* ]] || return 1
    [[ "$output" == *"tart prune --entries caches --older-than 30"* ]] || return 1
    [ ! -e "$HOME/tart-called" ] || return 1
}

@test "clean_tart_caches skips active and whitelisted caches" {
    rm -rf "$HOME/.tart"
    mkdir -p "$HOME/.tart/cache/OCIs"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
pgrep() { [[ "$1" == "-x" && "$2" == "tart" ]]; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 1024; }
bytes_to_human() { echo "1MB"; }
tart() { echo "TART_CALLED"; }
clean_tart_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"skipped (Tart running)"* ]] || return 1
    [[ "$output" != *"TART_CALLED"* ]] || return 1

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
is_path_whitelisted() { [[ "$1" == "$HOME/.tart/cache" ]]; }
get_path_size_kb() { echo 1024; }
tart() { echo "TART_CALLED"; }
clean_tart_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"would skip (whitelist)"* ]] || return 1
    [[ "$output" != *"TART_CALLED"* ]] || return 1
}

@test "clean_tart_caches fails closed when its process probe errors" {
    rm -rf "$HOME/.tart" "$HOME/tart-called"
    mkdir -p "$HOME/.tart/cache/OCIs"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 2; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 1024; }
note_activity() { :; }
tart() { : > "$HOME/tart-called"; }
clean_tart_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Tart caches · skipped (process state unknown)"* ]] || return 1
    [ ! -e "$HOME/tart-called" ]
}

@test "clean_tart_caches rechecks activity before native prune" {
    rm -rf "$HOME/.tart" "$HOME/tart-called" "$HOME/tart-probes"
    mkdir -p "$HOME/.tart/cache/OCIs"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
pgrep() {
    printf 'probe\n' >> "$HOME/tart-probes"
    [[ $(wc -l < "$HOME/tart-probes" | tr -d ' ') -ge 2 ]]
}
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 1024; }
note_activity() { :; }
defer_cleanup_family() { echo "DEFER:$1"; }
tart() { : > "$HOME/tart-called"; }
clean_tart_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Tart"* ]] || return 1
    [ ! -e "$HOME/tart-called" ]
}

@test "clean_tart_caches reports native prune failure without claiming success" {
    rm -rf "$HOME/.tart"
    mkdir -p "$HOME/.tart/cache/OCIs"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 1024; }
bytes_to_human() { echo "1MB"; }
run_with_timeout() { shift; "$@"; }
tart() { return 7; }
clean_tart_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Tart caches · prune failed"* ]] || return 1
    [[ "$output" != *"Tart caches · pruned"* ]] || return 1
}

@test "clean_tart_caches is silent without Tart or a cache" {
    rm -rf "$HOME/.tart"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false PATH="/usr/bin:/bin" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
clean_tart_caches
mkdir -p "$HOME/.tart/cache/OCIs"
clean_tart_caches
EOF

    [ "$status" -eq 0 ]
    [ -z "$output" ] || return 1
}

@test "clean_note_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_note_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Notion cache"* ]] || return 1
    [[ "$output" == *"Obsidian cache"* ]]
}

@test "clean_task_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_task_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Todoist cache"* ]] || return 1
    [[ "$output" == *"Any.do cache"* ]]
}

@test "clean_video_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_video_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"ScreenFlow cache"* ]] || return 1
    [[ "$output" == *"Final Cut Pro cache"* ]]
}

@test "clean_video_players calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_video_players
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"IINA cache"* ]] || return 1
    [[ "$output" == *"VLC cache"* ]]
}

@test "clean_3d_tools calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
pgrep() { return 1; }
safe_clean() { echo "$2"; }
clean_3d_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Blender cache"* ]] || return 1
    [[ "$output" == *"Cinema 4D cache"* ]]
    [[ "$output" == *"Autodesk cache"* ]] || return 1
}

@test "clean_gaming_platforms calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_gaming_platforms
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Steam cache"* ]] || return 1
    [[ "$output" == *"Epic Games cache"* ]]
}

@test "clean_translation_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_translation_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Youdao Dictionary cache"* ]] || return 1
    [[ "$output" == *"Eudict cache"* ]]
}

@test "clean_launcher_apps calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_launcher_apps
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Alfred cache"* ]] || return 1
    [[ "$output" == *"The Unarchiver cache"* ]]
}

@test "clean_remote_desktop calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_remote_desktop
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"TeamViewer cache"* ]] || return 1
    [[ "$output" == *"AnyDesk cache"* ]]
}

@test "clean_system_utils calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_system_utils
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Input Source Pro cache"* ]] || return 1
    [[ "$output" == *"WakaTime cache"* ]]
}

@test "clean_shell_utils calls expected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/app_caches.sh"
safe_clean() { echo "$2"; }
clean_shell_utils
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Zsh completion cache"* ]] || return 1
    [[ "$output" == *"wget HSTS cache"* ]]
}
