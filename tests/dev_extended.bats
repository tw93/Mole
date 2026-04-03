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
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_dev_elixir cleans hex cache" {
    mkdir -p "$HOME/.mix" "$HOME/.hex"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_ocaml
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Opam cache"* ]]
}

@test "clean_dev_editors cleans VS Code and Zed caches" {
    mkdir -p "$HOME/Library/Caches/com.microsoft.VSCode" "$HOME/Library/Application Support/Code" "$HOME/Library/Caches/Zed"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_service_worker_cache() { :; }
clean_dev_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"VS Code cached data"* ]]
    [[ "$output" == *"Zed cache"* ]]
}

@test "clean_dev_editors does not clean VS Code workspace storage" {
    mkdir -p "$HOME/Library/Application Support/Code/User/workspaceStorage/abc123"
    touch "$HOME/Library/Application Support/Code/User/workspaceStorage/abc123/workspace.json"

    # Source and run the function
    source "$PROJECT_ROOT/lib/core/common.sh"
    source "$PROJECT_ROOT/lib/clean/dev.sh"
    # shellcheck disable=SC2329
    safe_clean() { :; }
    clean_dev_editors > /dev/null 2>&1 || true

    # Verify the file still exists
    [ -f "$HOME/Library/Application Support/Code/User/workspaceStorage/abc123/workspace.json" ]
}

@test "check_android_ndk reports multiple NDK versions" {
    run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/Library/Android/sdk/ndk"/{21.0.1,22.0.0,20.0.0} && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && check_android_ndk' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Android NDK versions: 3 found"* ]]
}

@test "check_android_ndk silent when only one NDK" {
    run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/Library/Android/sdk/ndk/22.0.0" && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && check_android_ndk' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"NDK versions"* ]]
}

@test "clean_xcode_device_support handles empty directories under nounset" {
    local ds_dir="$HOME/EmptyDeviceSupport"
    mkdir -p "$ds_dir"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

@test "clean_xcode_documentation_cache keeps newest DeveloperDocumentation index" {
    local doc_root="$HOME/DocumentationCache"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index"
    touch "$doc_root/DeveloperDocumentation-16.0.index"
    touch -t 202402010000 "$doc_root/DeveloperDocumentation.index"
    touch -t 202401010000 "$doc_root/DeveloperDocumentation-16.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
has_sudo_session() { return 0; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
safe_sudo_remove() {
    local target="$1"
    echo "CLEAN:$target:Xcode documentation cache (old indexes)"
}
clean_xcode_documentation_cache
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$doc_root/DeveloperDocumentation-16.0.index:Xcode documentation cache (old indexes)"* ]]
    [[ "$output" != *"CLEAN:$doc_root/DeveloperDocumentation.index:Xcode documentation cache (old indexes)"* ]]
}

@test "clean_xcode_documentation_cache skips when Xcode is running" {
    local doc_root="$HOME/DocumentationCache"
    mkdir -p "$doc_root"
    touch "$doc_root/DeveloperDocumentation.index"
    touch "$doc_root/DeveloperDocumentation-16.0.index"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_DOCUMENTATION_CACHE_DIR="$doc_root" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 0; }
safe_sudo_remove() { echo "UNEXPECTED_SAFE_SUDO_REMOVE"; }
clean_xcode_documentation_cache
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping documentation cache cleanup"* ]]
    [[ "$output" != *"UNEXPECTED_SAFE_SUDO_REMOVE"* ]]
}

@test "check_rust_toolchains reports multiple toolchains" {
    run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/.rustup/toolchains"/{stable,nightly,1.75.0}-aarch64-apple-darwin && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && rustup() { :; } && export -f rustup && check_rust_toolchains' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Rust toolchains: 3 found"* ]]
}

@test "check_rust_toolchains silent when only one toolchain" {
    run bash -c 'HOME=$(mktemp -d) && mkdir -p "$HOME/.rustup/toolchains/stable-aarch64-apple-darwin" && source "$0" && note_activity() { :; } && NC="" && GREEN="" && GRAY="" && YELLOW="" && ICON_SUCCESS="✓" && rustup() { :; } && export -f rustup && check_rust_toolchains' "$PROJECT_ROOT/lib/clean/dev.sh"

    [ "$status" -eq 0 ]
    [[ "$output" != *"Rust toolchains"* ]]
}

@test "clean_dev_jetbrains_toolbox cleans old versions and bypasses toolbox whitelist" {
    local toolbox_channel="$HOME/Library/Application Support/JetBrains/Toolbox/apps/IDEA/ch-0"
    mkdir -p "$toolbox_channel/241.1" "$toolbox_channel/241.2" "$toolbox_channel/241.3"
    ln -s "241.3" "$toolbox_channel/current"
    touch -t 202401010000 "$toolbox_channel/241.1"
    touch -t 202402010000 "$toolbox_channel/241.2"
    touch -t 202403010000 "$toolbox_channel/241.3"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
    [[ "$output" == *"/241.1"* ]]
    [[ "$output" != *"/241.2"* ]]
}

@test "clean_dev_jetbrains_toolbox keeps current directory and removes older versions" {
    local toolbox_channel="$HOME/Library/Application Support/JetBrains/Toolbox/apps/IDEA/ch-0"
    mkdir -p "$toolbox_channel/241.1" "$toolbox_channel/241.2" "$toolbox_channel/current"
    touch -t 202401010000 "$toolbox_channel/241.1"
    touch -t 202402010000 "$toolbox_channel/241.2"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "$1"; }
MOLE_JETBRAINS_TOOLBOX_KEEP=1
clean_dev_jetbrains_toolbox
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"/241.1"* ]]
    [[ "$output" != *"/241.2"* ]]
}

@test "clean_dev_jetbrains_logs only targets JetBrains logs" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf '%s|%s\n' "$1" "$2"; }
clean_dev_jetbrains_logs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/Library/Logs/JetBrains/*|JetBrains IDE logs"* ]]
    [[ "$output" != *"Library/Caches/JetBrains"* ]]
}

@test "clean_developer_tools includes JetBrains logs but not JetBrains cache sweep" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
clean_homebrew_old_versions() { :; }
clean_developer_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/Library/Logs/JetBrains/*|JetBrains IDE logs"* ]]
    [[ "$output" != *"Library/Caches/JetBrains"* ]]
}

@test "clean_xcode_simulator_runtime_volumes shows scan progress and skips sizing in-use volumes" {
    local volumes_root="$HOME/sim-volumes"
    local cryptex_root="$HOME/sim-cryptex"
    mkdir -p "$volumes_root/in-use-runtime" "$volumes_root/unused-runtime"
    mkdir -p "$cryptex_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$volumes_root" MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$cryptex_root" bash --noprofile --norc <<'EOF'
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
    [[ "$output" == *"Xcode runtime volumes · scanning 2 entries"* ]]
    [[ "$output" == *"Xcode runtime volumes · cleaning 1 unused"* ]]
    [[ "$output" == *"REMOVE:$volumes_root/unused-runtime"* ]]
    [[ "$output" == *"$volumes_root/unused-runtime"* ]]
    [[ "$output" != *"$volumes_root/in-use-runtime"* ]]
}

@test "clean_dev_mobile continues cleanup when simctl is unavailable" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

check_android_ndk() { :; }
clean_xcode_documentation_cache() { :; }
clean_xcode_simulator_runtime_volumes() { :; }
clean_xcode_device_support() { echo "DEVICE_SUPPORT:$2"; }
safe_clean() { echo "SAFE_CLEAN:$2"; }
note_activity() { :; }
debug_log() { :; }
xcrun() { return 1; }

clean_dev_mobile
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"simctl not available"* ]]
    [[ "$output" == *"DEVICE_SUPPORT:iOS DeviceSupport"* ]]
    [[ "$output" == *"SAFE_CLEAN:Android SDK cache"* ]]
}
