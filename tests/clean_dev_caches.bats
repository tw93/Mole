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
    # Real file on PATH so type -P prefers the stub over any host pnpm.
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/pnpm" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    --version) echo "11.0.0"; exit 0 ;;
    store)
        [[ "${2:-}" == "path" ]] && { echo "/tmp/pnpm-store"; exit 0; }
        [[ "${2:-}" == "prune" ]] && exit 0
        ;;
esac
exit 2
SCRIPT
    chmod +x "$HOME/bin/pnpm"

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { echo "$1|$2"; }
safe_clean() { echo "$2"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pgrep() { return 1; }
npm() { return 0; }
export -f pgrep npm
clean_dev_npm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"pnpm cache|/tmp/pnpm-store"* ]] || return 1
    [[ "$output" != *"Orphaned pnpm store"* ]] || return 1
}

@test "clean_pnpm_stores prunes each distinct store from installed majors" {
    # issue #1370: active PATH pnpm (v11) plus a mise-installed pnpm 10.
    mkdir -p "$HOME/bin" "$HOME/.local/share/mise/installs/pnpm/10.34.5"
    cat > "$HOME/bin/pnpm" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    --version) echo "11.17.0"; exit 0 ;;
    store)
        if [[ "${2:-}" == "path" ]]; then
            echo "$HOME/Library/pnpm/store/v11"
            exit 0
        fi
        if [[ "${2:-}" == "prune" ]]; then
            echo "PRUNE_V11"
            exit 0
        fi
        ;;
esac
exit 2
SCRIPT
    chmod +x "$HOME/bin/pnpm"
    cat > "$HOME/.local/share/mise/installs/pnpm/10.34.5/pnpm" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    --version) echo "10.34.5"; exit 0 ;;
    store)
        if [[ "${2:-}" == "path" ]]; then
            echo "$HOME/.local/share/pnpm/store/v10"
            exit 0
        fi
        if [[ "${2:-}" == "prune" ]]; then
            echo "PRUNE_V10"
            exit 0
        fi
        ;;
esac
exit 2
SCRIPT
    chmod +x "$HOME/.local/share/mise/installs/pnpm/10.34.5/pnpm"

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
export -f pgrep
clean_tool_cache() {
    local description="$1"
    local cache_path="$2"
    shift 2
    echo "CACHE:$description|$cache_path"
    "$@"
}
clean_pnpm_stores
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"CACHE:pnpm cache|$HOME/Library/pnpm/store/v11"* ]] || return 1
    [[ "$output" == *"CACHE:pnpm cache|$HOME/.local/share/pnpm/store/v10"* ]] || return 1
    [[ "$output" == *"PRUNE_V11"* ]] || return 1
    [[ "$output" == *"PRUNE_V10"* ]] || return 1
}

@test "clean_pnpm_stores skips when pnpm is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { printf 'DEBUG:%s\n' "$*"; }
pgrep() { return 0; }
pnpm() { echo "UNEXPECTED"; return 0; }
export -f pgrep pnpm
clean_pnpm_stores
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"skipping store prune"* ]] || return 1
    [[ "$output" != *"UNEXPECTED"* ]] || return 1
}

@test "clean_orphaned_pnpm_store_generations removes generations no pnpm resolves" {
    rm -rf "$HOME/Library/pnpm" "$HOME/bin"
    mkdir -p "$HOME/bin" "$HOME/Library/pnpm/store/v3" "$HOME/Library/pnpm/store/v10" "$HOME/Library/pnpm/store/v11"
    touch "$HOME/Library/pnpm/store/v3/entry" "$HOME/Library/pnpm/store/v10/entry" "$HOME/Library/pnpm/store/v11/entry"
    cat > "$HOME/bin/pnpm" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    --version) echo "11.17.0"; exit 0 ;;
    store)
        if [[ "${2:-}" == "path" ]]; then
            echo "$HOME/Library/pnpm/store/v11"
            exit 0
        fi
        ;;
esac
exit 2
SCRIPT
    chmod +x "$HOME/bin/pnpm"

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
export -f pgrep
clean_orphaned_pnpm_store_generations
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE_CLEAN:Orphaned pnpm store generation (v3)|$HOME/Library/pnpm/store/v3"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Orphaned pnpm store generation (v10)|$HOME/Library/pnpm/store/v10"* ]] || return 1
    [[ "$output" != *"|$HOME/Library/pnpm/store/v11"* ]] || return 1
}

@test "clean_orphaned_pnpm_store_generations fails closed when no resolved generation lives in root" {
    rm -rf "$HOME/Library/pnpm" "$HOME/bin" "$HOME/.local"
    mkdir -p "$HOME/bin" "$HOME/Library/pnpm/store/v10"
    touch "$HOME/Library/pnpm/store/v10/entry"
    cat > "$HOME/bin/pnpm" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    --version) echo "10.34.5"; exit 0 ;;
    store)
        if [[ "${2:-}" == "path" ]]; then
            echo "$HOME/.local/share/pnpm/store/v10"
            exit 0
        fi
        ;;
esac
exit 2
SCRIPT
    chmod +x "$HOME/bin/pnpm"

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
export -f pgrep
clean_orphaned_pnpm_store_generations
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"SAFE_CLEAN"* ]] || return 1
}

@test "clean_orphaned_pnpm_store_generations skips while pnpm is running" {
    rm -rf "$HOME/Library/pnpm"
    mkdir -p "$HOME/Library/pnpm/store/v3"
    touch "$HOME/Library/pnpm/store/v3/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { printf 'DEBUG:%s\n' "$*"; }
pgrep() { return 0; }
pnpm() { echo "UNEXPECTED"; return 0; }
export -f pgrep pnpm
clean_orphaned_pnpm_store_generations
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"skipping orphaned store generation cleanup"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN"* ]] || return 1
    [[ "$output" != *"UNEXPECTED"* ]] || return 1
}

@test "clean_orphaned_pnpm_store_generations leaves generations alone without pnpm" {
    rm -rf "$HOME/Library/pnpm" "$HOME/bin"
    mkdir -p "$HOME/Library/pnpm/store/v3" "$HOME/Library/pnpm/store/v10"
    touch "$HOME/Library/pnpm/store/v3/entry" "$HOME/Library/pnpm/store/v10/entry"

    run env HOME="$HOME" PATH="/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
export -f pgrep
clean_orphaned_pnpm_store_generations
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"SAFE_CLEAN"* ]] || return 1
}

# Corepack and npm-installed pnpm run as `node .../pnpm.cjs`, so the busy
# guard has to match the invoked program, not the process name. `-x pnpm`
# saw only the standalone binary and let a prune race a live install.
@test "pnpm busy guard sees a corepack pnpm and ignores a lockfile mention" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

# Stand in for the real process table: pgrep -f matches its pattern against
# each full argv line.
PROCESS_TABLE=""
pgrep() {
    [[ "$1" == "-f" ]] || return 1
    printf '%s\n' "$PROCESS_TABLE" | grep -qE "$2"
}

PROCESS_TABLE="node /Users/x/.cache/node/corepack/v1/pnpm/9.1.0/bin/pnpm.cjs install"
printf 'COREPACK=%s\n' "$(pnpm_process_blocks_prune && echo block || echo allow)"
PROCESS_TABLE="vim /Users/x/project/pnpm-lock.yaml"
printf 'LOCKFILE=%s\n' "$(pnpm_process_blocks_prune && echo block || echo allow)"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"COREPACK=block"* ]] || return 1
    [[ "$output" == *"LOCKFILE=allow"* ]]
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

@test "clean_dev_jvm fails closed for every Gradle target when the process probe errors" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

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
    [[ "$output" == *"Gradle targets · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Gradle"* ]] || return 1
}

@test "clean_dev_jvm defers every Gradle target while Gradle is running" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 0; }
defer_cleanup_family() { echo "DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Gradle"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle"* ]] || return 1
}

@test "clean_dev_jvm cleans every Gradle target when idle" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE_CLEAN:Gradle build cache|"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Gradle notifications cache|"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:"*".gradle/daemon/8.14"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:"*".gradle/workers/worker-1"* ]] || return 1
    rm -rf "$HOME/.gradle"
}

@test "clean_dev_jvm stops remaining Gradle cleanup when the delete guard refuses" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 1; }
_dev_process_delete_guard_allows() { return 1; }
defer_cleanup_family() { echo "DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Gradle"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle"* ]] || return 1
    rm -rf "$HOME/.gradle"
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

@test "clean_dev_rust honors CARGO_HOME and RUSTUP_HOME when absolute" {
    # mise and friends relocate cargo/rustup via env; hardcoded ~/.cargo misses
    # the live cache (issue #1378). Scope stays regenerable leaves only.
    mkdir -p \
        "$HOME/.local/share/mise/cargo/registry/cache" \
        "$HOME/.local/share/mise/cargo/registry/src" \
        "$HOME/.local/share/mise/cargo/git"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        CARGO_HOME="$HOME/.local/share/mise/cargo" \
        RUSTUP_HOME="$HOME/.local/share/mise/rustup" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Rust cargo cache|$HOME/.local/share/mise/cargo/registry/cache/*"* ]] || return 1
    [[ "$output" == *"Rust crate sources|$HOME/.local/share/mise/cargo/registry/src/*"* ]] || return 1
    [[ "$output" == *"Cargo git cache|$HOME/.local/share/mise/cargo/git/*"* ]] || return 1
    [[ "$output" == *"Rustup downloads cache|$HOME/.local/share/mise/rustup/downloads/*"* ]] || return 1
    [[ "$output" != *"/registry/index/"* ]] || return 1
    [[ "$output" != *"/.cargo/"* ]] || return 1
    [[ "$output" != *"/.rustup/"* ]] || return 1
}

@test "clean_dev_rust rejects a registry source root that escapes CARGO_HOME" {
    cargo_home="$HOME/custom-cargo"
    outside_root="$HOME/outside-registry-sources"
    mkdir -p "$cargo_home/registry" "$outside_root/crate-data"
    ln -s "$outside_root" "$cargo_home/registry/src"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CARGO_HOME="$cargo_home" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
note_activity() { :; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust crate sources · stopped (cache path leaves CARGO_HOME)"* ]] || return 1
    [[ "$output" != *"DELETE=Rust crate sources"* ]] || return 1
    [[ -d "$outside_root/crate-data" ]]
}

@test "clean_dev_rust falls back to default homes without env" {
    mkdir -p \
        "$HOME/.cargo/registry/cache" \
        "$HOME/.cargo/registry/src" \
        "$HOME/.cargo/git"

    run env -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
unset CARGO_HOME RUSTUP_HOME
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Rust cargo cache|$HOME/.cargo/registry/cache/*"* ]] || return 1
    [[ "$output" == *"Rust crate sources|$HOME/.cargo/registry/src/*"* ]] || return 1
    [[ "$output" == *"Cargo git cache|$HOME/.cargo/git/*"* ]] || return 1
    [[ "$output" == *"Rustup downloads cache|$HOME/.rustup/downloads/*"* ]] || return 1
    [[ "$output" != *"/registry/index/"* ]] || return 1
}

@test "clean_dev_rust skips dependency caches while cargo is active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 0; }
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER=Rust"* ]] || return 1
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
    [[ "$output" != *"DELETE=Rust crate sources"* ]] || return 1
    [[ "$output" != *"DELETE=Cargo git cache"* ]] || return 1
    [[ "$output" == *"DELETE=Rustup downloads cache"* ]]
}

@test "clean_dev_rust fails closed when process state is unknown" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 2; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
note_activity() { :; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust dependency cache · stopped (process state unknown)"* ]] || return 1
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
    [[ "$output" != *"DELETE=Rust crate sources"* ]] || return 1
    [[ "$output" != *"DELETE=Cargo git cache"* ]] || return 1
    [[ "$output" == *"DELETE=Rustup downloads cache"* ]]
}

@test "clean_dev_rust rechecks cargo at the deletion boundary" {
    mkdir -p "$HOME/.cargo/registry/cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
probe_calls=0
rust_build_process_state() {
    probe_calls=$((probe_calls + 1))
    [[ $probe_calls -eq 1 ]] && return 1
    return 0
}
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" || return 75
    safe_clean "$@"
}
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER=Rust"* ]] || return 1
    [[ "$output" != *"DELETE="* ]]
}

@test "clean_dev_rust rechecks Cargo cache containment at the deletion boundary" {
    cache_root="$HOME/.cargo/registry/src"
    outside_root="$HOME/outside-rust-sources"
    mkdir -p "$cache_root/crate" "$outside_root/private-data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    if [[ "$_MOLE_RUST_CACHE_ROOT" == "$HOME/.cargo/registry/src" ]]; then
        mv "$HOME/.cargo/registry/src" "$HOME/.cargo/registry/src-original"
        ln -s "$HOME/outside-rust-sources" "$HOME/.cargo/registry/src"
    fi
    "$guard" || return 75
    safe_clean "$@"
}
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust crate sources · stopped (process or cache path state unknown)"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"DELETE=Rust crate sources"* ]] || return 1
    [[ -d "$outside_root/private-data" ]]
}

@test "clean_dev_rust binds each Cargo cache leaf to its checked root" {
    cargo_home="$HOME/bound-cargo"
    cache_root="$cargo_home/registry/src"
    outside_root="$HOME/outside-rust-sources-after-guard"
    mkdir -p "$cache_root/crate" "$outside_root/crate"
    printf 'inside\n' > "$cache_root/crate/inside-marker"
    printf 'outside\n' > "$outside_root/crate/outside-marker"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
rust_build_process_state() { return 1; }

# Swap the checked Cargo root after the guard returns but before the real
# safe_remove sink performs its final identity comparison.
eval "$(declare -f safe_remove | sed '1s/safe_remove/_real_safe_remove/')"
swapped=0
safe_remove() {
    if [[ $swapped -eq 0 ]]; then
        swapped=1
        mv "$HOME/bound-cargo/registry/src" "$HOME/bound-cargo/registry/src-original"
        ln -s "$HOME/outside-rust-sources-after-guard" "$HOME/bound-cargo/registry/src"
    fi
    _real_safe_remove "$@"
}

clean_rust_dependency_cache_root \
    "$HOME/bound-cargo" \
    "$HOME/bound-cargo/registry/src" \
    "Rust crate sources"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -f "$cache_root-original/crate/inside-marker" ]] || return 1
    [[ -f "$outside_root/crate/outside-marker" ]] || return 1
    [[ "$output" != *"Rust crate sources ·"* ]]
}

@test "resolve_tool_home rejects relative and traversal env values" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
fail=0
expect() {
    local got
    got=$(resolve_tool_home "$1" "$HOME/.cargo")
    if [[ "$got" != "$2" ]]; then
        printf 'UNEXPECTED: env=%q got=%q want=%q\n' "$1" "$got" "$2"
        fail=1
    fi
}
expect "" "$HOME/.cargo"
expect "$HOME/.local/share/mise/cargo" "$HOME/.local/share/mise/cargo"
expect "relative/cargo" "$HOME/.cargo"
expect "$HOME/../evil" "$HOME/.cargo"
expect "/tmp/foo/../bar" "$HOME/.cargo"
exit $fail
EOF

    [ "$status" -eq 0 ]
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

_codex_version_plist() {
	mkdir -p "$(dirname "$1")"
	local bundle_id="${3:-com.openai.codex}"
	cat > "$1" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$bundle_id</string><key>CFBundleVersion</key><string>$2</string></dict></plist>
PLIST
}

@test "codex staging removes a superseded staged build regardless of age (#1359)" {
	local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
	rm -rf "$staging_root"
	mkdir -p "$staging_root/superseded/Codex.app/Contents" "$staging_root/pending/Codex.app/Contents"
	_codex_version_plist "$staging_root/superseded/Codex.app/Contents/Info.plist" "5628"
	_codex_version_plist "$staging_root/pending/Codex.app/Contents/Info.plist" "5900"
	# The pending entry is ancient; version must protect it anyway.
	touch -t 202001010000 "$staging_root/pending"

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
_codex_installed_build_version() { echo "5848"; }
clean_codex_desktop_staging
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"SAFE_CLEAN:Codex Desktop stale update staging|"*"/superseded"* ]] || return 1
	[[ "$output" != *"/pending"* ]] || return 1
}

@test "codex staging removes an equal staged build and keeps invalid metadata on the age rule" {
	local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
	rm -rf "$staging_root"
	mkdir -p "$staging_root/equal/Codex.app/Contents" \
		"$staging_root/badmeta-old/Codex.app/Contents" \
		"$staging_root/badmeta-fresh/Codex.app/Contents"
	_codex_version_plist "$staging_root/equal/Codex.app/Contents/Info.plist" "5848"
	_codex_version_plist "$staging_root/badmeta-old/Codex.app/Contents/Info.plist" "not-a-number"
	_codex_version_plist "$staging_root/badmeta-fresh/Codex.app/Contents/Info.plist" "also.bad"
	touch -t 202001010000 "$staging_root/badmeta-old"

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
_codex_installed_build_version() { echo "5848"; }
clean_codex_desktop_staging
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"/equal"* ]] || return 1
	[[ "$output" == *"/badmeta-old"* ]] || return 1
	[[ "$output" != *"/badmeta-fresh"* ]] || return 1
}

@test "codex staging keeps the age rule when the installed build is unknown" {
	local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
	rm -rf "$staging_root"
	mkdir -p "$staging_root/versioned-fresh/Codex.app/Contents"
	_codex_version_plist "$staging_root/versioned-fresh/Codex.app/Contents/Info.plist" "1"

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
_codex_installed_build_version() { return 1; }
clean_codex_desktop_staging
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"SAFE_CLEAN:"* ]] || return 1
}

@test "codex staging refuses version supersession for a foreign staged bundle id" {
	# A lower version number on a DIFFERENT app proves nothing about
	# Codex's staging; identity gates the comparison, so the entry falls
	# back to the age rule and a fresh one stays.
	local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
	rm -rf "$staging_root"
	mkdir -p "$staging_root/foreign/Other.app/Contents"
	_codex_version_plist "$staging_root/foreign/Other.app/Contents/Info.plist" "1" "com.example.other"

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
_codex_installed_build_version() { echo "5848"; }
clean_codex_desktop_staging
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"SAFE_CLEAN:"* ]] || return 1
}

@test "codex installed-version resolution fails on two copies that disagree" {
	# Both copies share the one staging cache, so a staged build may be the
	# pending update for either. Disagreeing installed versions make
	# ownership ambiguous and must resolve to the age rule, never to the
	# first copy found.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
run_with_timeout() { shift; "$@"; }
mdfind() { return 1; }
_codex_app_build_version() {
    case "$1" in
        "/Applications/Codex.app") echo "5900" ;;
        "$HOME/Applications/Codex.app") echo "5800" ;;
        *) return 1 ;;
    esac
}
mkdir -p "/tmp/nonexistent-guard" 2>/dev/null || true
if _codex_installed_build_version; then
    echo "RESOLVED_DESPITE_CONFLICT"
else
    echo "AMBIGUOUS_FALLS_BACK"
fi
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"AMBIGUOUS_FALLS_BACK"* ]] || return 1
	[[ "$output" != *"RESOLVED_DESPITE_CONFLICT"* ]] || return 1
}

@test "codex resolution treats a failed mdfind as unanswered, not as no-other-copies" {
	# A timed-out or failed mdfind may be hiding an unindexed extra copy
	# whose pending update is the staged build under judgment. Resolution
	# must fail (age rule), even when a fixed-path copy reads cleanly; a
	# clean rc 0 with no rows is the only valid "no other copies".
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
run_with_timeout() { shift; "$@"; }
mkdir -p "$HOME/Applications/Codex.app/Contents"
cat > "$HOME/Applications/Codex.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.openai.codex</string><key>CFBundleVersion</key><string>5800</string></dict></plist>
PLIST
mdfind() { return 2; }
if _codex_installed_build_version; then
    echo "RESOLVED_DESPITE_MDFIND_FAILURE"
fi
mdfind() { return 0; }
resolved=$(_codex_installed_build_version) || { echo "CLEAN_EMPTY_FAILED"; exit 1; }
echo "CLEAN_EMPTY_RESOLVED=$resolved"
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"RESOLVED_DESPITE_MDFIND_FAILURE"* ]] || return 1
	[[ "$output" == *"CLEAN_EMPTY_RESOLVED=5800"* ]] || return 1
}

@test "codex supersession boundary re-verifies the installed set before deleting" {
	# The scan snapshot is not enough: a copy installed or swapped after
	# the scan (an older one whose pending update is exactly this staged
	# build) must void the supersession at the deletion boundary.
	local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
	rm -rf "$staging_root"
	mkdir -p "$staging_root/entry/Codex.app/Contents"
	_codex_version_plist "$staging_root/entry/Codex.app/Contents/Info.plist" "5628"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
run_with_timeout() { shift; "$@"; }
staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
_MOLE_CODEX_STAGING_ROOT="$staging_root"
_MOLE_CODEX_STAGING_ENTRY="$staging_root/entry"
_MOLE_CODEX_STAGING_MODE="superseded"
_MOLE_CODEX_INSTALLED_BUILD="5848"

_codex_installed_build_version() { echo "5900"; }
if _codex_staging_entry_is_still_stale; then
    echo "STALE_DESPITE_CHANGED_INSTALL"
fi
_codex_installed_build_version() { return 1; }
if _codex_staging_entry_is_still_stale; then
    echo "STALE_DESPITE_AMBIGUOUS_INSTALL"
fi
_codex_installed_build_version() { echo "5848"; }
if _codex_staging_entry_is_still_stale; then
    echo "STALE_WITH_STABLE_INSTALL"
fi
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"STALE_DESPITE_CHANGED_INSTALL"* ]] || return 1
	[[ "$output" != *"STALE_DESPITE_AMBIGUOUS_INSTALL"* ]] || return 1
	[[ "$output" == *"STALE_WITH_STABLE_INSTALL"* ]] || return 1
}
