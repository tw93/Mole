#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-dev-caches.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_dev_npm cleans orphaned pnpm store" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { echo "$1"; }
safe_clean() { echo "$2"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pnpm() {
    if [[ "$1" == "store" && "$2" == "prune" ]]; then
        return 0
    fi
    if [[ "$1" == "store" && "$2" == "path" ]]; then
        echo "/tmp/pnpm-store"
        return 0
    fi
    return 0
}
npm() { return 0; }
export -f pnpm npm
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned pnpm store"* ]]
}

@test "clean_dev_npm cleans default npm residual directories" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() {
    if [[ "$1" == "config" && "$2" == "get" && "$3" == "cache" ]]; then
        echo "$HOME/.npm"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]]
    [[ "$output" == *"npm npx cache|$HOME/.npm/_npx/*"* ]]
    [[ "$output" == *"npm logs|$HOME/.npm/_logs/*"* ]]
    [[ "$output" == *"npm prebuilds|$HOME/.npm/_prebuilds/*"* ]]
}

@test "clean_dev_npm cleans custom npm cache path when detected" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() {
    if [[ "$1" == "config" && "$2" == "get" && "$3" == "cache" ]]; then
        echo "/tmp/mole-custom-npm-cache"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]]
    [[ "$output" == *"npm cache directory (custom path)|/tmp/mole-custom-npm-cache/_cacache/*"* ]]
    [[ "$output" == *"npm npx cache (custom path)|/tmp/mole-custom-npm-cache/_npx/*"* ]]
    [[ "$output" == *"npm logs (custom path)|/tmp/mole-custom-npm-cache/_logs/*"* ]]
    [[ "$output" == *"npm prebuilds (custom path)|/tmp/mole-custom-npm-cache/_prebuilds/*"* ]]
}

@test "clean_dev_npm falls back to default cache when npm path is invalid" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() {
    if [[ "$1" == "config" && "$2" == "get" && "$3" == "cache" ]]; then
        echo "relative-cache"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]]
    [[ "$output" != *"(custom path)"* ]]
}

@test "clean_dev_docker skips when daemon not running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
run_with_timeout() { return 1; }
clean_tool_cache() { echo "$1"; }
safe_clean() { echo "$2"; }
debug_log() { echo "$*"; }
docker() { return 1; }
export -f docker
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker daemon not running"* ]]
    [[ "$output" != *"Docker build cache"* ]]
}

@test "clean_developer_tools runs key stages" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/dev.sh"
stop_section_spinner() { :; }
clean_sqlite_temp_files() { :; }
clean_dev_npm() { echo "npm"; }
clean_homebrew() { echo "brew"; }
clean_project_caches() { :; }
clean_dev_python() { :; }
clean_dev_go() { :; }
clean_dev_rust() { :; }
check_rust_toolchains() { :; }
check_android_ndk() { :; }
clean_dev_docker() { :; }
clean_dev_cloud() { :; }
clean_dev_nix() { :; }
clean_dev_shell() { :; }
clean_dev_frontend() { :; }
clean_xcode_documentation_cache() { :; }
clean_dev_mobile() { :; }
clean_dev_jvm() { :; }
clean_dev_other_langs() { :; }
clean_dev_cicd() { :; }
clean_dev_database() { :; }
clean_dev_api_tools() { :; }
clean_dev_network() { :; }
clean_dev_misc() { :; }
clean_dev_elixir() { :; }
clean_dev_haskell() { :; }
clean_dev_ocaml() { :; }
clean_dev_editors() { :; }
safe_clean() { :; }
debug_log() { :; }
clean_developer_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm"* ]]
    [[ "$output" == *"brew"* ]]
}

@test "clean_project_caches cleans flutter .dart_tool and build directories" {
    mkdir -p "$HOME/Code/flutter_app/.dart_tool" "$HOME/Code/flutter_app/build"
    touch "$HOME/Code/flutter_app/.dart_tool/cache.bin"
    touch "$HOME/Code/flutter_app/build/output.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
create_temp_file() { mktemp; }
safe_clean() { echo "$2|$1"; }
DRY_RUN=false
clean_project_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Flutter build cache (.dart_tool)"* ]]
    [[ "$output" == *"Flutter build cache (build/)"* ]]
}
