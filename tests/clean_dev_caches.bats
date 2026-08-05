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
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_dev_npm prunes pnpm store without deleting orphaned global store" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"pnpm cache"* ]] || return 1
    [[ "$output" != *"Orphaned pnpm store"* ]] || return 1
    [[ "$output" != *"pnpm store"* ]]
}

@test "clean_dev_npm cleans default npm residual directories" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" == *"npm npx cache|$HOME/.npm/_npx/*"* ]] || return 1
    [[ "$output" == *"npm logs|$HOME/.npm/_logs/*"* ]] || return 1
    [[ "$output" == *"npm prebuilds|$HOME/.npm/_prebuilds/*"* ]]
}

@test "clean_dev_jvm never enters daemon cleanup while Gradle is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 0; }
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"SAFE_CLEAN:Gradle daemon"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Gradle workers"* ]]
}

@test "clean_dev_jvm fails closed when the Gradle process probe errors" {
    mkdir -p "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    touch "$HOME/.gradle/daemon/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 2; }
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Gradle daemon/workers · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Gradle daemon"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Gradle workers"* ]]
}

@test "clean_dev_jvm ignores empty Gradle daemon roots while active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
rm -rf "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
mkdir -p "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
gradle_daemon_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle daemon"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle workers"* ]] || return 1
    [[ "$output" != *"process state unknown"* ]]
}

@test "clean_dev_jvm ignores broken-symlink-only Gradle roots while active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
rm -rf "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
mkdir -p "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
ln -s "$HOME/missing-gradle-daemon" "$HOME/.gradle/daemon/broken"
ln -s "$HOME/missing-gradle-worker" "$HOME/.gradle/workers/broken"
mkdir -p "$HOME/.gradle/daemon/compiled/com.apple.e5rt.e5bundlecache"
gradle_daemon_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle daemon"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle workers"* ]]
}

@test "clean_dev_jvm ignores active whitelist-only Gradle daemon entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
rm -rf "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
mkdir -p "$HOME/.gradle/daemon"
target="$HOME/.gradle/daemon/whitelisted"
touch "$target"
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
gradle_daemon_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { :; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER:Gradle"* ]]
}

@test "clean_conda_metadata_caches honors package cache whitelist before conda clean" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
WHITELIST_PATTERNS=("$HOME/anaconda3/pkgs")
conda() { echo "conda called"; return 0; }
export -f conda
clean_conda_metadata_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"conda index/tarball/log caches · skipped (whitelist)"* ]] || return 1
    [[ "$output" != *"conda called"* ]]
}

@test "clean_dev_npm cleans custom npm cache path when detected" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" == *"npm cache directory (custom path)|/tmp/mole-custom-npm-cache/_cacache/*"* ]] || return 1
    [[ "$output" == *"npm npx cache (custom path)|/tmp/mole-custom-npm-cache/_npx/*"* ]] || return 1
    [[ "$output" == *"npm logs (custom path)|/tmp/mole-custom-npm-cache/_logs/*"* ]] || return 1
    [[ "$output" == *"npm prebuilds (custom path)|/tmp/mole-custom-npm-cache/_prebuilds/*"* ]]
}

@test "clean_dev_npm falls back to default cache when npm path is invalid" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" != *"(custom path)"* ]]
}

@test "clean_dev_npm treats default cache path with trailing slash as same path" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
        echo "$HOME/.npm/"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" != *"(custom path)"* ]]
}

@test "clean_dev_npm cleans default bun cache when bun is unavailable" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() { return 1; }
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bun cache|$HOME/.bun/install/cache/*"* ]] || return 1
    [[ "$output" != *"bun cache|bun cache bun pm cache rm"* ]] || return 1
    [[ "$output" != *"Orphaned bun cache"* ]]
}

@test "clean_dev_npm uses bun cache command for default bun cache path" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "$HOME/.bun/install/cache"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"bun cache"* ]] || return 1
    [[ "$output" != *"Bun cache|$HOME/.bun/install/cache/*"* ]] || return 1
    [[ "$output" != *"Orphaned bun cache"* ]]
}

@test "clean_dev_npm cleans orphaned default bun cache when custom path is configured" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "/tmp/mole-bun-cache"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"bun cache"* ]] || return 1
    [[ "$output" == *"Orphaned bun cache|$HOME/.bun/install/cache/*"* ]]
}

@test "clean_dev_npm treats default bun cache path with trailing slash as same path" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "$HOME/.bun/install/cache/"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"bun cache"* ]] || return 1
    [[ "$output" != *"Orphaned bun cache"* ]]
}

@test "clean_dev_npm falls back to filesystem cleanup when bun cache command fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 1
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "/tmp/mole-bun-cache"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bun cache|/tmp/mole-bun-cache/*"* ]] || return 1
    [[ "$output" == *"Orphaned bun cache|$HOME/.bun/install/cache/*"* ]]
}

@test "clean_dev_docker skips daemon-managed cleanup by default" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { echo "$2"; }
note_activity() { :; }
debug_log() { :; }
docker() { echo "docker called"; return 0; }
export -f docker
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker unused data · review with docker system df"* ]] || return 1
    [[ "$output" == *"Docker BuildX cache"* ]] || return 1
    [[ "$output" != *"docker called"* ]]
}

@test "clean_dev_docker keeps BuildX cache cleanup" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
debug_log() { :; }
docker() { return 0; }
export -f docker
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker BuildX cache|$HOME/.docker/buildx/cache/*"* ]]
}

@test "clean_dev_docker reports OrbStack data without deleting disk images" {
    local orb_data="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"
    mkdir -p "$orb_data"
    touch "$orb_data/data.img.raw" "$orb_data/swap.img"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf '%s|%s\n' "$2" "$1"; }
note_activity() { :; }
debug_log() { :; }
get_path_size_kb() { echo "4096"; }
bytes_to_human() { echo "4M"; }
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"OrbStack container data · 4M · review with docker system df"* ]] || return 1
    [[ "$output" == *"Docker BuildX cache|$HOME/.docker/buildx/cache/*"* ]] || return 1
    [[ "$output" != *"data.img.raw"* ]] || return 1
    [[ "$output" != *"swap.img"* ]]
}

@test "clean_dev_docker stops before BuildX cleanup when OrbStack sizing times out" {
    local orb_data="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"
    mkdir -p "$orb_data"
    touch "$orb_data/data.img.raw"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "UNEXPECTED_BUILDX:$2|$1"; }
get_path_size_kb() { return 124; }
note_activity() { :; }
debug_log() { :; }
set +e
clean_dev_docker
rc=$?
set -e
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=124 CANCEL=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_BUILDX"* ]]
}

@test "clean_dev_docker no longer depends on whitelist to avoid prune" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { :; }
is_path_whitelisted() {
    [[ "$1" == "$HOME/.docker" ]] && return 0
    return 1
}
export -f is_path_whitelisted
docker() { echo "docker called"; return 0; }
export -f docker
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker unused data · review with docker system df"* ]] || return 1
    [[ "$output" != *"whitelisted"* ]] || return 1
    [[ "$output" != *"mo clean --whitelist"* ]] || return 1
    [[ "$output" != *"docker called"* ]]
}

@test "codex_desktop_running recognizes current and legacy app aliases (#1305)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

matched_query=""
pgrep() {
    [[ "$*" == "$matched_query" ]]
}

for matched_query in "-x Codex" "-f /Codex.app/" "-x ChatGPT" "-f /ChatGPT.app/"; do
    codex_desktop_running || exit 1
done

matched_query="-x unrelated"
if codex_desktop_running; then
    exit 1
fi
printf 'CODEX_DESKTOP_ALIASES_OK\n'
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"CODEX_DESKTOP_ALIASES_OK"* ]] || return 1
}

@test "standalone Xcode guarded cleanup rechecks before safe_clean fallback" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
unset -f safe_clean_guarded 2> /dev/null || true
deny_xcode_delete() { return 1; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN"; }
note_activity() { :; }

rc=0
_xcode_safe_clean_guarded deny_xcode_delete "Xcode cache" "$HOME/cache" "Xcode cache" || rc=$?
[[ $rc -ne 0 ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
}

@test "ChatGPT running keeps Codex runtime and update staging cleanup dormant (#1305)" {
    local case_home="$HOME/chatgpt-running-case"
    local runtime_root="$case_home/.cache/codex-runtimes"
    local staging_root="$case_home/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$case_home"
    mkdir -p "$runtime_root/incomplete-install" "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { [[ "$1" == "-x" && "$2" == "ChatGPT" ]]; }
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }

clean_codex_runtimes
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"Codex runtimes · skipped"* ]] || return 1
    [[ "$output" != *"Codex Desktop update staging · skipped"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]] || return 1
}

@test "clean_codex_runtimes reports active runtime for manual review" {
    mkdir -p "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/runtime.json"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex runtimes · manual review (1M)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Codex CLI runtimes|$HOME/.cache/codex-runtimes/codex-primary-runtime"* ]]
}

@test "clean_codex_runtimes cleans only stale incomplete runtime dirs" {
    mkdir -p "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin"
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/runtime.json"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Codex CLI runtimes|$HOME/.cache/codex-runtimes/incomplete-old"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Codex CLI runtimes|$HOME/.cache/codex-runtimes/codex-primary-runtime"* ]]
}

@test "clean_codex_runtimes skips all runtimes while Codex is running" {
    mkdir -p "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin"
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/runtime.json"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 0; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Codex runtimes · skipped"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]]
}

@test "clean_codex_runtimes skips incomplete runtimes while lowercase Codex CLI is running" {
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { [[ "$*" == "-x codex" ]]; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$2|$1"; }
defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Codex"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
}

@test "clean_codex_runtimes does not defer compiled-model-only stale runtimes" {
    local case_home="$HOME/codex-compiled-only"
    local runtime_dir="$case_home/.cache/codex-runtimes/incomplete-old"
    mkdir -p "$runtime_dir/com.apple.e5rt.e5bundlecache"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$1"; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_codex_runtimes respects whitelist" {
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { [[ "$1" == "$HOME/.cache/codex-runtimes"* || "$1" == "$HOME/.cache/codex-runtimes/incomplete-old" ]]; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex runtimes · skipped (whitelist)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]]
}

@test "clean_codex_runtimes respects child runtime whitelist" {
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { [[ "$1" == "$HOME/.cache/codex-runtimes/incomplete-old" ]]; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex runtimes · manual review"* ]] || return 1
    [[ "$output" == *"Codex runtimes · skipped (whitelist)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]]
}

@test "empty Codex cache leaves and fresh staging do not register active cleanup" {
    local case_home="$HOME/codex-empty-active"
    local cache_root="$case_home/Library/Caches/Codex/Default/Cache"
    local staging_root="$case_home/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    mkdir -p "$cache_root" "$staging_root/fresh"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$2|$1"; }
is_path_whitelisted() { return 1; }
note_activity() { :; }
clean_codex_desktop_caches
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
}

@test "clean_codex_desktop_staging selects only stale first-level installation directories" {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/stale/Codex.app" "$staging_root/fresh/Codex.app"
    touch -t 202001010000 "$staging_root/stale"
    # A newly staged app may preserve an old bundle timestamp. The fresh outer
    # Sparkle directory, not its nested app, is the retention boundary.
    touch -t 202001010000 "$staging_root/fresh/Codex.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Codex Desktop stale update staging|$staging_root/stale"* ]] || return 1
    [[ "$output" != *"$staging_root/fresh"* ]] || return 1
    [[ "$output" != *"$HOME/.codex"* ]] || return 1
    [[ "$output" != *"$HOME/Library/Application Support/Codex"* ]] || return 1
    [[ "$output" != *"$HOME/Library/Logs/com.openai.codex"* ]] || return 1
}

@test "clean_codex_desktop_staging rejects a symlinked staging ancestor" {
    local case_home="$HOME/codex-staging-ancestor-link"
    local sparkle_parent="$case_home/Library/Caches/com.openai.codex"
    local outside="$case_home/Documents/StagingVictim"
    local outside_entry="$outside/Installation/stale"
    mkdir -p "$sparkle_parent" "$outside_entry"
    touch "$outside_entry/OUTSIDE_SENTINEL"
    touch -t 202001010000 "$outside_entry"
    ln -s "$outside" "$sparkle_parent/org.sparkle-project.Sparkle"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
codex_sparkle_staging_has_open_files() { return 1; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_codex_desktop_staging
[[ -f "$HOME/Documents/StagingVictim/Installation/stale/OUTSIDE_SENTINEL" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DELETE"* ]]
}

@test "clean_codex_desktop_staging rechecks physical containment after sizing" {
    local case_home="$HOME/codex-staging-containment-race"
    local sparkle_parent="$case_home/Library/Caches/com.openai.codex"
    local sparkle_root="$sparkle_parent/org.sparkle-project.Sparkle"
    local staging_entry="$sparkle_root/Installation/stale"
    local outside="$case_home/Documents/StagingVictim"
    mkdir -p "$staging_entry" "$outside/Installation/stale"
    touch "$staging_entry/owned" "$outside/Installation/stale/OUTSIDE_SENTINEL"
    touch -t 202001010000 "$staging_entry" "$outside/Installation/stale"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
codex_sparkle_staging_has_open_files() { return 1; }
get_cleanup_path_size_kb() {
    if [[ ! -e "$HOME/switched-staging-root" ]]; then
        : > "$HOME/switched-staging-root"
        mv "$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle" "$HOME/original-sparkle"
        ln -s "$HOME/Documents/StagingVictim" "$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle"
    fi
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_codex_desktop_staging
[[ -f "$HOME/Documents/StagingVictim/Installation/stale/OUTSIDE_SENTINEL" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DELETE"* ]]
}

@test "clean_codex_desktop_staging does not defer compiled-model-only candidates" {
    local case_home="$HOME/codex-staging-compiled-only"
    local stale="$case_home/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation/stale"
    mkdir -p "$stale/com.apple.e5rt.e5bundlecache"
    touch -t 202001010000 "$stale"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
codex_desktop_process_state() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$1"; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "clean_codex_desktop_staging skips while Codex or Sparkle updater is running" {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { [[ "$1" == "-x" && "$2" == "Codex" ]]; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"skipped (Codex running)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]] || return 1

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { [[ "$1" == "-f" && "$2" == *"sparkle-project"* ]]; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"skipped (updater running)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]] || return 1
}

@test "clean_codex_desktop_staging skips open files and honors whitelist" {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
lsof() { printf 'n%s\n' "$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation/stale/Codex.app"; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"skipped (files in use)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]] || return 1

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { return 124; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped (open-file check unavailable)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]] || return 1

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
is_path_whitelisted() { [[ "$1" == "$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation" ]]; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"would skip (whitelist)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]] || return 1
}

@test "clean_codex_desktop_staging fails closed when lsof is unavailable" {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

probe_rc=0
PATH=/nonexistent codex_sparkle_staging_has_open_files "$HOME/missing" || probe_rc=$?
[[ $probe_rc -eq 2 ]] || { echo "WRONG_LSOF_RC:$probe_rc"; exit 1; }

pgrep() { return 1; }
is_path_whitelisted() { return 1; }
codex_sparkle_staging_has_open_files() { return 2; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"open-file check unavailable"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
}

@test "codex staging treats lsof exit one with stderr as unknown" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
lsof() { return 1; }
run_with_timeout() {
    echo "lsof: cannot stat test path" >&2
    return 1
}
probe_rc=0
codex_sparkle_staging_has_open_files "$HOME/missing" || probe_rc=$?
[[ $probe_rc -eq 2 ]] || { echo "WRONG_LSOF_RC:$probe_rc"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "clean_codex_desktop_staging rechecks Codex at the deletion boundary" {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root" "$HOME/codex-staging-probes"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
codex_desktop_process_state() {
    printf 'probe\n' >> "$HOME/codex-staging-probes"
    [[ $(wc -l < "$HOME/codex-staging-probes" | tr -d ' ') -ge 2 ]]
}
codex_sparkle_updater_running() { return 1; }
codex_sparkle_staging_has_open_files() { return 1; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$2|$1"; }
defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Codex"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
    [ -d "$staging_root/stale" ]
}

@test "clean_codex_desktop_staging revalidates candidate age before deletion" {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root" "$HOME/codex-staging-age-probes"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
codex_desktop_process_state() {
    if [[ ! -e "$HOME/codex-staging-age-probes" ]]; then
        : > "$HOME/codex-staging-age-probes"
        touch "$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation/stale"
    fi
    return 1
}
codex_sparkle_updater_running() { return 1; }
codex_sparkle_staging_has_open_files() { return 1; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
    [ -d "$staging_root/stale" ]
}

@test "clean_codex_desktop_staging routes dry-run candidates through safe_clean" {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$DRY_RUN|$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:true|Codex Desktop stale update staging|$staging_root/stale"* ]] || return 1
}

@test "clean_dev_mise respects MISE_CACHE_DIR and only targets cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MISE_CACHE_DIR="/tmp/mise-cache" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_tool_cache() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
clean_dev_mise
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"mise cache|/tmp/mise-cache/*"* ]] || return 1
    [[ "$output" != *".local/share/mise"* ]]
}

@test "clean_dev_rust follows CARGO_HOME and RUSTUP_HOME" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CARGO_HOME="$HOME/.local/share/mise/cargo" RUSTUP_HOME="$HOME/.local/share/mise/rustup" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Rust cargo cache|$HOME/.local/share/mise/cargo/registry/cache/*"* ]] || return 1
    [[ "$output" == *"Cargo git cache|$HOME/.local/share/mise/cargo/git/*"* ]] || return 1
    [[ "$output" == *"Rust downloads cache|$HOME/.local/share/mise/rustup/downloads/*"* ]] || return 1
    [[ "$output" != *"$HOME/.cargo"* ]]
}

@test "clean_dev_rust falls back to default homes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Rust cargo cache|$HOME/.cargo/registry/cache/*"* ]] || return 1
    [[ "$output" == *"Cargo git cache|$HOME/.cargo/git/*"* ]] || return 1
    [[ "$output" == *"Rust downloads cache|$HOME/.rustup/downloads/*"* ]] || return 1
}

@test "clean_dev_rust rejects unsafe custom homes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CARGO_HOME="/" RUSTUP_HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN|$2|$1"; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CARGO_HOME="relative/cargo" RUSTUP_HOME="relative/rustup" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN|$2|$1"; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]] || return 1
}

@test "clean_dev_other_langs cleans configured composer cache paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" COMPOSER_HOME="$HOME/.config/composer-home" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PHP Composer cache (legacy)|"* ]] || return 1
    [[ "$output" == *"PHP Composer cache|"* ]]
}

@test "clean_developer_tools runs key stages" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/dev.sh"
stop_section_spinner() { :; }
clean_sqlite_temp_files() { :; }
clean_dev_npm() { echo "npm"; }
clean_homebrew() { echo "brew"; }
clean_project_caches() { :; }
clean_dev_python() { :; }
clean_dev_go() { :; }
clean_dev_mise() { echo "mise"; }
clean_dev_rust() { :; }
check_rust_toolchains() { :; }
clean_dev_ruby() { :; }
clean_dev_perl() { :; }
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
clean_code_editors() { :; }
clean_dev_jetbrains_toolbox() { :; }
clean_xcode_tools() { :; }
safe_clean() { :; }
debug_log() { :; }
clean_developer_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm"* ]] || return 1
    [[ "$output" == *"mise"* ]] || return 1
    [[ "$output" == *"brew"* ]]
}

@test "clean_dev_ruby cleans rbenv, gem, and bundler caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_ruby
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"rbenv download cache|"* ]] || return 1
    [[ "$output" == *"gem spec cache|"* ]] || return 1
    [[ "$output" == *"gem package cache|"* ]] || return 1
    [[ "$output" == *"Ruby Bundler cache|"* ]]
}

@test "clean_dev_perl cleans CPAN build and source caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_perl
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CPAN build artifacts|"* ]] || return 1
    [[ "$output" == *"CPAN source cache|"* ]]
}

@test "clean_dev_other_langs no longer includes Ruby Bundler cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Ruby Bundler cache"* ]]
}

@test "clean_project_caches cleans flutter .dart_tool and build directories" {
    mkdir -p "$HOME/Code/flutter_app/.dart_tool" "$HOME/Code/flutter_app/build"
    touch "$HOME/Code/flutter_app/.dart_tool/cache.bin"
    touch "$HOME/Code/flutter_app/build/output.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"Flutter build cache (.dart_tool)"* ]] || return 1
    [[ "$output" == *"Flutter build cache (build/)"* ]]
}

@test "project cache processing stops after a Python size timeout" {
    local python_root="$HOME/Code/A"
    local next_root="$HOME/Code/B"
    mkdir -p "$python_root/__pycache__" "$next_root/.next/cache"
    touch "$python_root/__pycache__/module.pyc" "$next_root/.next/cache/output"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
matches_file=$(mktemp)
printf '%s\t%s\n' "$HOME/Code/A" "$HOME/Code/A/__pycache__" > "$matches_file"
printf '%s\t%s\n' "$HOME/Code/B" "$HOME/Code/B/.next" >> "$matches_file"
get_path_size_kb() { return 124; }
safe_clean() { echo "UNEXPECTED_CONTINUATION:$2|$1"; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; }

set +e
process_project_cache_matches "$matches_file"
rc=$?
set -e
rm -f "$matches_file"
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=124 CANCEL=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CONTINUATION"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE"* ]]
}

@test "clean_dev_misc includes Chrome DevTools MCP cache when server not running" {
    mkdir -p "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache"
    touch "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
pgrep() { return 1; }
safe_clean() { echo "$2"; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_dev_misc
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Chrome DevTools MCP browser cache"* ]] || return 1
    [[ "$output" != *"Chrome DevTools MCP cache"* ]]
}

@test "clean_dev_misc skips Chrome DevTools MCP cache when server is running" {
    mkdir -p "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache"
    touch "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
pgrep() { return 0; }
safe_clean() { echo "$2"; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_dev_misc
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Chrome DevTools MCP caches · skipped"* ]] || return 1
    [[ "$output" != *"Chrome DevTools MCP browser cache"* ]]
}

@test "clean_chrome_devtools_mcp_caches preserves profile state" {
    profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    mkdir -p "$profile/Default/Cache" "$profile/Default/Code Cache" "$profile/Default/GPUCache"
    mkdir -p "$profile/Default/Service Worker/CacheStorage"
    mkdir -p "$profile/Default/Local Storage/leveldb"
    touch "$profile/Default/Cache/data" "$profile/Default/Code Cache/data" "$profile/Default/GPUCache/data"
    touch "$profile/Default/Service Worker/CacheStorage/data"
    touch "$profile/Default/Cookies" "$profile/Default/Local Storage/leveldb/state"
    touch "$profile/Local State"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1|$2"; }
clean_chrome_devtools_mcp_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP browser cache|$profile/Default/Cache/"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP code cache|$profile/Default/Code Cache/"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP GPU cache|$profile/Default/GPUCache/"* ]] || return 1
    [[ "$output" == *"SWC:Chrome DevTools MCP|$profile/Default/Service Worker/CacheStorage"* ]] || return 1
    [[ "$output" != *"Cookies"* ]] || return 1
    [[ "$output" != *"Local Storage"* ]] || return 1
    [[ "$output" != *"Local State"* ]]
}

@test "clean_chrome_devtools_mcp_caches ignores an empty active profile" {
    profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    rm -rf "$profile"
    mkdir -p "$profile/Default/Cache" "$profile/Default/Service Worker/CacheStorage"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; }
clean_service_worker_cache() { echo "UNEXPECTED_SWC"; }
clean_chrome_devtools_mcp_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SWC"* ]] || return 1
    [[ "$output" != *"process state unknown"* ]]
}

@test "clean_chrome_devtools_mcp_caches recognizes root-level cache candidates" {
    profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    rm -rf "$profile"
    mkdir -p "$profile/extensions_crx_cache"
    touch "$profile/extensions_crx_cache/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { :; }
clean_chrome_devtools_mcp_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP extension cache|$profile/extensions_crx_cache/candidate"* ]]
}

@test "report_agent_worktree_candidates reports large worktree containers as review only" {
    mkdir -p "$HOME/code/proj/.claude/worktrees/wt-one"
    echo "data" > "$HOME/code/proj/.claude/worktrees/wt-one/file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { echo "2097152"; }
report_agent_worktree_candidates
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"AI agent worktrees"* ]] || return 1
    [[ "$output" == *"GB"* ]] || return 1
    [[ "$output" == *".claude/worktrees"* ]] || return 1
    # Report only: the worktree must still exist afterwards.
    [ -d "$HOME/code/proj/.claude/worktrees/wt-one" ]
}

@test "report_agent_worktree_candidates stays silent below the 1GB bar" {
    mkdir -p "$HOME/code/proj/.claude/worktrees/wt-one"
    echo "data" > "$HOME/code/proj/.claude/worktrees/wt-one/file"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { echo "512000"; }
report_agent_worktree_candidates
EOF

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
