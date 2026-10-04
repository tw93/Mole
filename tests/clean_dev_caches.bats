#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home dev-caches
}

teardown_file() {
    mole_test_teardown_home
}

make_gh_cache_stub() {
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/gh" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_TRACE"
if [[ "${GH_TRACE_CACHE_ROOT:-0}" == "1" ]]; then
    printf 'ROOT:%s\n' "${XDG_CACHE_HOME:-<unset>}" >> "$GH_TRACE"
fi
if [[ "$*" == "config clear-cache --help" ]]; then
    if [[ -n "${GH_SWAP_LINK:-}" && -n "${GH_SWAP_TARGET:-}" ]]; then
        /bin/unlink "$GH_SWAP_LINK"
        /bin/ln -s "$GH_SWAP_TARGET" "$GH_SWAP_LINK"
    fi
    if [[ -n "${GH_REPLACE_ROOT:-}" && -n "${GH_REPLACE_TARGET:-}" ]]; then
        /bin/mv "$GH_REPLACE_ROOT" "$GH_REPLACE_ROOT-old"
        /bin/ln -s "$GH_REPLACE_TARGET" "$GH_REPLACE_ROOT"
    fi
    exit "${GH_HELP_RC:-0}"
fi
if [[ "$*" == "config clear-cache" ]]; then
    exit "${GH_CLEAR_RC:-0}"
fi
exit 2
SCRIPT
    chmod +x "$HOME/bin/gh"
}

@test "clean_github_cli_cache uses gh owner command for the default cache" {
    local trace="$HOME/gh-default.trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
github_cli_process_state() { return 1; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
clean_tool_cache() {
    local description="$1"
    local cache_path="$2"
    shift 2
    printf 'CACHE:%s|%s\n' "$description" "$cache_path"
    "$@"
}
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache"* ]] || return 1
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    [ "$(grep -cFx 'config clear-cache' "$trace")" -eq 1 ] || return 1
}

@test "clean_github_cli_cache dry-run never invokes the mutating command" {
    local trace="$HOME/gh-dry-run.trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=true
run_with_timeout() { shift; "$@"; }
github_cli_process_state() { return 1; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache · would clean"* ]] || return 1
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    run grep -qFx 'config clear-cache' "$trace"
    [ "$status" -eq 1 ] || return 1
}

@test "clean_github_cli_cache honors custom XDG cache whitelists" {
    local trace="$HOME/gh-xdg-whitelist.trace"
    local xdg_cache="$HOME/custom-cache"
    mkdir -p "$xdg_cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$xdg_cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
is_path_whitelisted() { [[ "$1" == "$XDG_CACHE_HOME/gh" ]]; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache · skipped (whitelist)"* ]] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_github_cli_cache honors the physical target of a symlinked XDG root" {
    local trace="$HOME/gh-xdg-symlink.trace"
    local physical_cache="$HOME/physical-cache"
    mkdir -p "$physical_cache/gh"
    ln -s "$physical_cache" "$HOME/xdg-cache"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$HOME/xdg-cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" PHYSICAL_CACHE="$physical_cache/gh" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
is_path_whitelisted() { [[ "$1" == "$PHYSICAL_CACHE" ]]; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache · skipped (whitelist)"* ]] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_github_cli_cache binds the owner command to the verified physical root" {
    local trace="$HOME/gh-xdg-swap.trace"
    local physical_cache="$HOME/physical-cache"
    local swapped_cache="$HOME/swapped-cache"
    local xdg_link="$HOME/xdg-cache"
    rm -rf "$physical_cache" "$swapped_cache" "$xdg_link"
    mkdir -p "$physical_cache/gh" "$swapped_cache/gh"
    ln -s "$physical_cache" "$xdg_link"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$xdg_link" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" GH_TRACE_CACHE_ROOT=1 \
        GH_SWAP_LINK="$xdg_link" GH_SWAP_TARGET="$swapped_cache" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
github_cli_process_state() { return 1; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cFx "ROOT:$physical_cache" "$trace")" -eq 2 ] || return 1
    run grep -qFx "ROOT:$swapped_cache" "$trace"
    [ "$status" -eq 1 ] || return 1
    local link_target
    link_target=$(readlink "$xdg_link" 2> /dev/null || true)
    [ "$link_target" = "$swapped_cache" ] || {
        printf 'expected swapped link %s, got %s\n' "$swapped_cache" "${link_target:-<missing>}"
        return 1
    }
}

@test "clean_github_cli_cache rejects a replaced physical root at the owner command" {
    local trace="$HOME/gh-physical-root-swap.trace"
    local physical_cache="$HOME/replaceable-cache"
    local swapped_cache="$HOME/replacement-cache"
    rm -rf "$physical_cache" "$physical_cache-old" "$swapped_cache"
    mkdir -p "$physical_cache/gh" "$swapped_cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$physical_cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" \
        GH_REPLACE_ROOT="$physical_cache" GH_REPLACE_TARGET="$swapped_cache" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
github_cli_process_state() { return 1; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    run grep -qFx 'config clear-cache' "$trace"
    [ "$status" -eq 1 ] || return 1
    [ -L "$physical_cache" ] || return 1
    [ -d "$swapped_cache/gh" ] || return 1
}

@test "clean_github_cli_cache refuses when gh starts at the owner command boundary" {
    local trace="$HOME/gh-process-race.trace"
    rm -rf "$HOME/.cache/gh"
    rm -f "$trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
mole_defer_cleanup_family() { printf 'DEFER:%s\n' "$1"; }
pgrep_calls=0
pgrep() {
    pgrep_calls=$((pgrep_calls + 1))
    [[ $pgrep_calls -ge 2 ]]
}
clean_github_cli_cache
printf 'PGREP_CALLS=%s\n' "$pgrep_calls"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"DEFER:GitHub CLI"* ]] || return 1
    [[ "$output" == *"PGREP_CALLS=2"* ]] || return 1
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    run grep -qFx 'config clear-cache' "$trace"
    [ "$status" -eq 1 ] || return 1
}

@test "clean_github_cli_cache preserves a symlinked cache leaf" {
    local trace="$HOME/gh-leaf-symlink.trace"
    local cache_target="$HOME/relocated-gh-cache"
    rm -rf "$HOME/.cache/gh" "$cache_target"
    mkdir -p "$HOME/.cache" "$cache_target"
    ln -s "$cache_target" "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
debug_log() { printf 'DEBUG:%s\n' "$*"; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"cache leaf is not a real directory"* ]] || return 1
    [ -L "$HOME/.cache/gh" ] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_github_cli_cache rejects unsafe XDG paths before probing gh" {
    local trace="$HOME/gh-invalid-xdg.trace"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="relative/cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
debug_log() { printf 'DEBUG:%s\n' "$*" >&2; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"unsafe XDG_CACHE_HOME"* ]] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_dev_cloud continues when gh cache clearing fails" {
    local trace="$HOME/gh-failure.trace"
    rm -rf "$HOME/.cache/gh"
    rm -f "$trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" GH_CLEAR_RC=2 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
github_cli_process_state() { return 1; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_clean() { printf 'SAFE:%s\n' "$2"; }
clean_dev_cloud
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cFx 'config clear-cache' "$trace")" -eq 1 ] || return 1
    [[ "$output" == *"GitHub CLI cache · stopped (owner cleanup failed)"* ]] || return 1
    [[ "$output" == *"SAFE:AWS CLI cache"* ]] || return 1
    [[ "$output" == *"SAFE:Google Cloud logs"* ]] || return 1
}

@test "clean_dev_cloud stops on GitHub CLI probe or clear cancellation" {
    local failure_phase failure_rc
    for failure_phase in help clear; do
        for failure_rc in 124 130; do
            local trace="$HOME/gh-$failure_phase-$failure_rc.trace"
            local help_rc=0
            local clear_rc=0
            if [[ "$failure_phase" == "help" ]]; then
                help_rc="$failure_rc"
            else
                clear_rc="$failure_rc"
            fi
            rm -rf "$HOME/.cache/gh"
            rm -f "$trace"
            mkdir -p "$HOME/.cache/gh"
            make_gh_cache_stub

            run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
                GH_TRACE="$trace" GH_HELP_RC="$help_rc" GH_CLEAR_RC="$clear_rc" \
                MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
                /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
github_cli_process_state() { return 1; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_clean() { printf 'UNEXPECTED:%s\n' "$2"; }
set +e
_run_developer_cleanup_step clean_dev_cloud
rc=$?
set -e
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
EOF

            [ "$status" -eq 0 ] || { echo "$output"; return 1; }
            [[ "$output" == *"RC=$failure_rc CANCEL=$failure_rc"* ]] || return 1
            [[ "$output" != *"UNEXPECTED:"* ]] || return 1
        done
    done
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        /bin/bash --noprofile --norc << 'EOF'
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

@test "clean_dev_docker keeps the OrbStack row and BuildX cleanup when sizing times out" {
    # The OrbStack row is advisory and never deletes, so a size timeout drops
    # only the size and later cleanup continues. A signal still stops the run.
    local orb_data="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"
    mkdir -p "$orb_data"
    touch "$orb_data/data.img.raw"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "BUILDX:$2|$1"; }
note_activity() { :; }
debug_log() { :; }
get_path_size_kb() { return 124; }
rc=0
clean_dev_docker || rc=$?
printf 'TIMEOUT RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
get_path_size_kb() { return 130; }
rc=0
clean_dev_docker || rc=$?
printf 'SIGNAL RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"OrbStack container data · review with docker system df"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"BUILDX:Docker BuildX cache"*"TIMEOUT RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SIGNAL RC=130 CANCEL=130"* ]] || { echo "$output"; return 1; }
    [[ "$(printf '%s\n' "$output" | grep -c 'BUILDX:')" -eq 1 ]]
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
_MOLE_COMPLETE_LSOF_MODE=direct
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

@test "clean_codex_runtimes keeps the review row and the run when sizing times out" {
    # The review row is advisory and never deletes, so a slow size probe drops
    # only the size. A signal still stops the run.
    local iso="$HOME/iso-runtime-size-timeout"
    mkdir -p "$iso/.cache/codex-runtimes/codex-primary-runtime/dependencies/node"
    touch "$iso/.cache/codex-runtimes/codex-primary-runtime/runtime.json"

    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
note_activity() { :; }
_mole_record_clean_cancellation() { echo "CANCELLED:$1"; }
get_path_size_kb() { return 124; }
rc=0
clean_codex_runtimes || rc=$?
echo "TIMEOUT_RC=$rc"
get_path_size_kb() { return 130; }
rc=0
clean_codex_runtimes || rc=$?
echo "SIGNAL_RC=$rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Codex runtimes · manual review"$'\n'"TIMEOUT_RC=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"CANCELLED:124"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"CANCELLED:130"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SIGNAL_RC=130"* ]]
}

@test "clean_codex_runtimes sizes manual review by what survives the run" {
    local iso="$HOME/iso-runtime-survivors"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node"
touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/runtime.json"
mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; rmdir "$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() {
    case "$1" in
        */codex-primary-runtime) echo 1024 ;;
        */incomplete-old) echo 4096 ;;
        */codex-runtimes)
            if [[ -d "$1/incomplete-old" ]]; then echo 5120; else echo 1024; fi ;;
        *) return 1 ;;
    esac
}
bytes_to_human() { echo "$(($1 / 1024))KB"; }
note_activity() { :; }
clean_codex_runtimes
[[ ! -d "$HOME/.cache/codex-runtimes/incomplete-old" ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SAFE_CLEAN:"*"incomplete-old"* ]] || return 1
    [[ "$output" == *"Codex runtimes · manual review (1024KB)"* ]] || return 1
    [[ "$output" != *"5120KB"* ]] || return 1
}

@test "clean_codex_runtimes includes stale directories kept by the cleanup sink" {
    local iso="$HOME/iso-runtime-refused"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.cache/codex-runtimes/active/dependencies/node"
touch "$HOME/.cache/codex-runtimes/active/runtime.json"
mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
# The real safe_clean contract returns zero when a target is kept after a
# permission failure or an eligibility filter. A success code is not removal.
safe_clean() { echo "KEPT:$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() {
    case "$1" in
        */active) echo 1024 ;;
        */incomplete-old) echo 4096 ;;
        */codex-runtimes) echo 5120 ;;
        *) return 1 ;;
    esac
}
bytes_to_human() { echo "$(($1 / 1024))KB"; }
note_activity() { :; }
clean_codex_runtimes
[[ -d "$HOME/.cache/codex-runtimes/incomplete-old" ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"KEPT:"*"incomplete-old"* ]] || return 1
    [[ "$output" == *"Codex runtimes · manual review (5120KB)"* ]] || return 1
}

@test "clean_codex_runtimes dry-run does not predict retained bytes" {
    local iso="$HOME/iso-runtime-preview"
    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.cache/codex-runtimes/active/dependencies/node"
touch "$HOME/.cache/codex-runtimes/active/runtime.json"
mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "PREVIEW:$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 1024; }
bytes_to_human() { echo "1MB"; }
note_activity() { :; }
clean_codex_runtimes
[[ -d "$HOME/.cache/codex-runtimes/incomplete-old" ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PREVIEW:"*"incomplete-old"* ]] || return 1
    [[ "$output" == *"Codex runtimes · manual review"* ]] || return 1
    [[ "$output" != *"manual review ("* ]] || return 1
}

@test "clean_codex_runtimes stops before survivor sizing when cleanup is cancelled" {
    local iso="$HOME/iso-runtime-cancel"
    local cancel_rc
    for cancel_rc in 124 130; do
        run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" CANCEL_RC="$cancel_rc" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
mkdir -p "$HOME/.cache/codex-runtimes/incomplete-first" "$HOME/.cache/codex-runtimes/incomplete-second"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo UNEXPECTED_SIZE; }
guard_calls=0
_codex_runtime_safe_clean_guarded() {
    guard_calls=$((guard_calls + 1))
    echo "GUARD:$guard_calls"
    return "$CANCEL_RC"
}
clean_codex_runtimes
EOF

        [ "$status" -eq "$cancel_rc" ] || return 1
        [[ "$output" == *"GUARD:1"* ]] || return 1
        [[ "$output" != *"GUARD:2"* ]] || return 1
        [[ "$output" != *"UNEXPECTED_SIZE"* ]] || return 1
        [[ "$output" != *"manual review"* ]] || return 1
    done
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
_MOLE_COMPLETE_LSOF_MODE=direct
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { return 124; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
clean_codex_desktop_staging
printf 'CANCEL=%s\n' "$MOLE_CLEAN_CANCEL_STATUS"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped (open-file check unavailable)"* ]] || return 1
    [[ "$output" == *"CANCEL=0"* ]] || return 1
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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

@test "the debug flag never changes the codex staging open-file verdict" {
    # The stderr file is evidence: lsof exit 1 counts as "idle" only when it
    # is empty. run_with_timeout traces into that stream under MO_DEBUG=1, so
    # without MO_DEBUG=0 on the capture every idle staging root read as
    # "could not tell" under --debug. The stub reproduces the trace on purpose.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
mkdir -p "$HOME/codex-staging-idle"
lsof() { return 1; }
run_with_timeout() {
    local duration="$1"
    shift
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[TIMEOUT] Running with ${duration}s timeout: $*" >&2
    fi
    "$@"
}
export MO_DEBUG=0
quiet=0
codex_sparkle_staging_has_open_files "$HOME/codex-staging-idle" || quiet=$?
export MO_DEBUG=1
loud=0
codex_sparkle_staging_has_open_files "$HOME/codex-staging-idle" || loud=$?
printf 'QUIET=%s LOUD=%s\n' "$quiet" "$loud"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"QUIET=1 LOUD=1"* ]] || { echo "$output"; return 1; }
}

@test "codex staging treats lsof exit one with stderr as unknown" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
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

@test "codex staging refuses an incomplete root-process lsof view (#1471)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
trace_file=$(mktemp)
lsof() {
    case " $* " in
        *" -p 1 "*) printf 'visibility\n' >> "$trace_file"; return 1 ;;
        *) printf 'target\n' >> "$trace_file"; return 1 ;;
    esac
}
run_with_timeout() { shift; "$@"; }
probe_rc=0
codex_sparkle_staging_has_open_files "$HOME/missing" || probe_rc=$?
printf 'RC=%s TRACE=%s\n' "$probe_rc" "$(tr '\n' ',' < "$trace_file")"
command rm -f "$trace_file"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=2 TRACE=visibility,"* ]]
}

@test "clean_codex_desktop_staging rechecks Codex at the deletion boundary" {
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    rm -rf "$staging_root"
    mkdir -p "$staging_root/stale"
    touch -t 202001010000 "$staging_root/stale"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MISE_CACHE_DIR="/tmp/mise-cache" /bin/bash --noprofile --norc << 'EOF'
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

@test "PyInstaller cleanup keeps non-bincache state" {
    local cache_root="$HOME/Library/Application Support/pyinstaller"
    mkdir -p "$cache_root/bincache00py311" "$cache_root/hooks"
    printf 'state\n' > "$cache_root/config.json"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pyinstaller_build_process_state() { return 1; }
safe_clean() {
    local description="${!#}"
    while [[ $# -gt 1 ]]; do
        printf 'CLEAN=%s|%s\n' "$description" "$1"
        shift
    done
}
clean_pyinstaller_bincache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLEAN=PyInstaller binary cache|$cache_root/bincache00py311"* ]] || return 1
    [[ "$output" != *"$cache_root/hooks"* ]] || return 1
    [[ "$output" != *"$cache_root/config.json"* ]]
}

@test "PyInstaller cleanup reaches the guarded deletion sink" {
    local cache_root="$HOME/Library/Application Support/pyinstaller"
    mkdir -p "$cache_root/bincache00py310"
    printf 'cache\n' > "$cache_root/bincache00py310/module.bin"
    printf 'keep\n' > "$cache_root/config.json"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
pyinstaller_build_process_state() { return 1; }
clean_pyinstaller_bincache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$cache_root/bincache00py310" ] || return 1
    [ -f "$cache_root/config.json" ]
}

@test "PyInstaller cleanup fails closed when the process state is unknown" {
    local cache_root="$HOME/Library/Application Support/pyinstaller"
    mkdir -p "$cache_root/bincache00py312"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pyinstaller_build_process_state() { return 2; }
safe_clean() { printf 'UNEXPECTED_CLEAN=%s\n' "$1"; }
note_activity() { :; }
clean_pyinstaller_bincache
EOF

    if [[ -L "$cache_root" && -d "$cache_root-original" ]]; then
        /bin/unlink "$cache_root"
        /bin/mv "$cache_root-original" "$cache_root"
    fi
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PyInstaller binary cache · stopped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN="* ]]
}

@test "PyInstaller cleanup rechecks the process at the deletion boundary" {
    local cache_root="$HOME/Library/Application Support/pyinstaller"
    mkdir -p "$cache_root/bincache00py313"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
probe_calls=0
pyinstaller_build_process_state() {
    probe_calls=$((probe_calls + 1))
    [[ $probe_calls -eq 1 ]] && return 1
    return 0
}
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
safe_clean() { printf 'UNEXPECTED_CLEAN=%s\n' "$1"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" "$1" || return 75
    safe_clean "$@"
}
clean_pyinstaller_bincache
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER=PyInstaller"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN="* ]]
}

@test "PyInstaller cleanup rejects a root replaced before deletion" {
    local cache_root="$HOME/Library/Application Support/pyinstaller"
    local outside_root="$HOME/outside-pyinstaller"
    mkdir -p "$cache_root/bincache00py314" "$outside_root/bincache00py314"
    printf 'keep\n' > "$outside_root/bincache00py314/private-data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pyinstaller_build_process_state() { return 1; }
safe_clean() { printf 'UNEXPECTED_CLEAN=%s\n' "$1"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    local cache_root="$HOME/Library/Application Support/pyinstaller"
    /bin/mv "$cache_root" "$cache_root-original"
    /bin/ln -s "$HOME/outside-pyinstaller" "$cache_root"
    "$guard" "$1" || return 75
    safe_clean "$@"
}
note_activity() { :; }
clean_pyinstaller_bincache
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"PyInstaller binary cache · stopped (process or cache path state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN="* ]] || return 1
    [ -f "$outside_root/bincache00py314/private-data" ]
}

@test "Clang cleanup uses the macOS cache root and keeps symlink entries" {
    local darwin_cache="$HOME/darwin-cache"
    local cache_root="$darwin_cache/clang"
    local outside_root="$HOME/outside-clang"
    mkdir -p "$cache_root/module-cache" "$cache_root/.locks" "$outside_root/private-data"
    ln -s "$outside_root" "$cache_root/redirected"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DARWIN_CACHE="$darwin_cache" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_darwin_user_cache_root() { printf '%s\n' "$DARWIN_CACHE"; }
clang_module_cache_process_state() { return 1; }
safe_clean() {
    local description="${!#}"
    while [[ $# -gt 1 ]]; do
        printf 'CLEAN=%s|%s\n' "$description" "$1"
        shift
    done
}
clean_clang_module_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLEAN=Clang module cache|$cache_root/module-cache"* ]] || return 1
    [[ "$output" == *"CLEAN=Clang module cache|$cache_root/.locks"* ]] || return 1
    [[ "$output" != *"$cache_root/redirected"* ]] || return 1
    [ -d "$outside_root/private-data" ]
}

@test "clean_dev_rust honors CARGO_HOME and RUSTUP_HOME when absolute" {
    # mise and friends relocate cargo/rustup via env; hardcoded ~/.cargo misses
    # the live cache (issue #1378). Scope stays redundant download copies only.
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
    # registry/src keeps offline builds working after registry/cache is emptied.
    [[ "$output" != *"/registry/src"* ]] || return 1
    # Cargo owns age-aware GC for git checkouts; Mole must not sweep the store.
    [[ "$output" != *"/cargo/git"* ]] || return 1
    [[ "$output" == *"Rustup downloads cache|$HOME/.local/share/mise/rustup/downloads/*"* ]] || return 1
    [[ "$output" != *"/registry/index/"* ]] || return 1
    [[ "$output" != *"/.cargo/"* ]] || return 1
    [[ "$output" != *"/.rustup/"* ]] || return 1
}

@test "clean_dev_rust rejects a registry cache root that escapes CARGO_HOME" {
    cargo_home="$HOME/custom-cargo"
    outside_root="$HOME/outside-registry-cache"
    mkdir -p "$cargo_home/registry" "$outside_root/crate-data"
    ln -s "$outside_root" "$cargo_home/registry/cache"

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
    [[ "$output" == *"Rust cargo cache · stopped (cache path leaves CARGO_HOME)"* ]] || return 1
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
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
    [[ "$output" != *"/registry/src"* ]] || return 1
    [[ "$output" != *"/.cargo/git"* ]] || return 1
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
    cache_root="$HOME/.cargo/registry/cache"
    outside_root="$HOME/outside-rust-cache"
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
    if [[ "$_MOLE_RUST_CACHE_ROOT" == "$HOME/.cargo/registry/cache" ]]; then
        mv "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/cache-original"
        ln -s "$HOME/outside-rust-cache" "$HOME/.cargo/registry/cache"
    fi
    "$guard" || return 75
    safe_clean "$@"
}
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust cargo cache · stopped (process or cache path state unknown)"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
    [[ -d "$outside_root/private-data" ]]
}

@test "clean_dev_rust binds each Cargo cache leaf to its checked root" {
    cargo_home="$HOME/bound-cargo"
    cache_root="$cargo_home/registry/cache"
    outside_root="$HOME/outside-rust-cache-after-guard"
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
        mv "$HOME/bound-cargo/registry/cache" "$HOME/bound-cargo/registry/cache-original"
        ln -s "$HOME/outside-rust-cache-after-guard" "$HOME/bound-cargo/registry/cache"
    fi
    _real_safe_remove "$@"
}

clean_rust_dependency_cache_root \
    "$HOME/bound-cargo" \
    "$HOME/bound-cargo/registry/cache" \
    "Rust cargo cache"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -f "$cache_root-original/crate/inside-marker" ]] || return 1
    [[ -f "$outside_root/crate/outside-marker" ]] || return 1
    [[ "$output" != *"Rust cargo cache ·"* ]]
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
# Signals real processes when not stubbed; tests/clean_automation_browsers.bats owns it.
clean_dev_automation_browsers() { :; }
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

@test "clean_dev_perl clears the CPAN build tree but keeps the source store" {
    # ~/.cpan/sources holds the distribution tarballs CPAN installs from and
    # reuses across installs, so dropping it costs a re-download. The build
    # tree next to it is throwaway scratch.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_perl
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CPAN build artifacts|"* ]] || return 1
    [[ "$output" != *"/.cpan/sources"* ]]
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

@test "clean_dev_python keeps downloaded model weights and run artifacts" {
    # Hugging Face, PyTorch, TensorFlow and Weights & Biases store multi-GB
    # downloads and experiment output, not rebuildable build products. Only
    # ~/.cache/huggingface was ever covered by DEFAULT_WHITELIST_PATTERNS, and
    # that array stops applying once a user saves their own whitelist file, so
    # the other three were deleted for everyone.
    mkdir -p "$HOME/.cache/huggingface/hub" "$HOME/.cache/torch/hub" \
        "$HOME/.cache/tensorflow/datasets" "$HOME/.cache/wandb/run-1"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_tool_cache() { echo "$1|$2"; }
clean_uv_cache() { :; }
clean_pyinstaller_bincache() { :; }
clean_conda_metadata_caches() { :; }
note_activity() { :; }
clean_dev_python
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"huggingface"* ]] || return 1
    [[ "$output" != *"/.cache/torch"* ]] || return 1
    [[ "$output" != *"/.cache/tensorflow"* ]] || return 1
    [[ "$output" != *"/.cache/wandb"* ]] || return 1
    # The rebuildable linter and type-checker caches next to them still go.
    [[ "$output" == *"Ruff cache"* ]] || return 1
    [[ "$output" == *"MyPy cache"* ]]
}

@test "clean_dev_go refuses a symlinked module root but still clears the build cache" {
    # `go clean -modcache` removes the module root directory itself, so handing
    # it the resolved physical path of a symlinked GOMODCACHE deletes the target
    # and leaves the owner's root dangling for the next build. `go clean -cache`
    # empties GOCACHE in place, so a symlinked build root stays supported.
    local module_physical="$HOME/go-module-physical"
    local module_link="$HOME/go-module-link"
    local build_root="$HOME/go-build-cache"
    local trace="$HOME/go-clean.trace"
    mkdir -p "$module_physical" "$build_root"
    ln -s "$module_physical" "$module_link"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_link" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        case "$3" in
            GOMODCACHE) printf '%s\n' "$GO_MODULE_ROOT" ;;
            GOCACHE) printf '%s\n' "$GO_BUILD_ROOT" ;;
        esac
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go module cache · stopped (symlinked module root)"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Go build cache"* ]] || return 1
    # Nothing may be handed to the owner command for the symlinked root, and
    # the physical directory the link points at must survive.
    ! grep -q -- "-modcache" "$trace" || return 1
    [[ -d "$module_physical" ]] || return 1
    grep -qFx "env GOCACHE=$build_root go clean -cache" "$trace" || return 1
    rm -f "$trace" "$module_link"
    rm -rf "$module_physical" "$build_root"
}

@test "clean_dev_go refuses a module root that becomes a symlink after entry" {
    # The entry check only proves the root was a real directory when the caller
    # looked. Swap it for a link afterwards and the parent/target identity
    # comparison still passes, so the owner command would run against whatever
    # the link resolves to.
    local module_root="$HOME/go-module-swap"
    local outside_root="$HOME/go-outside-target"
    local build_root="$HOME/go-build-swap"
    local trace="$HOME/go-clean-swap.trace"
    mkdir -p "$module_root" "$outside_root" "$build_root"
    printf 'keep\n' > "$outside_root/victim.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        case "$3" in
            GOMODCACHE) printf '%s\n' "$GO_MODULE_ROOT" ;;
            GOCACHE) printf '%s\n' "$GO_BUILD_ROOT" ;;
        esac
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
note_activity() { :; }
# Fires inside the bound command, after the entry check has passed.
swapped=0
go_cache_process_state() {
    if [[ "${1:-}" == "GOMODCACHE" && $swapped -eq 0 ]]; then
        swapped=1
        rmdir "$GO_MODULE_ROOT" 2> /dev/null || true
        ln -s "$HOME/go-outside-target" "$GO_MODULE_ROOT"
    fi
    return 1
}
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go module cache · stopped (symlinked module root)"* ]] || {
        echo "$output"
        return 1
    }
    ! grep -q -- "-modcache" "$trace" || {
        cat "$trace"
        return 1
    }
    [[ -f "$outside_root/victim.txt" ]] || return 1
    # The concurrency-safe build cache is unaffected by the module-root swap.
    grep -qFx "env GOCACHE=$build_root go clean -cache" "$trace" || return 1
    rm -f "$trace" "$module_root"
    rm -rf "$outside_root" "$build_root"
}

@test "clean_dev_go uses owner dry-run for the same cache roots" {
    local module_root="$HOME/go-module-dry"
    local build_root="$HOME/go-build-dry"
    local trace="$HOME/go-clean-dry.trace"
    mkdir -p "$module_root" "$build_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=true
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        if [[ "$3" == "GOMODCACHE" ]]; then
            printf '%s\n' "$GO_MODULE_ROOT"
        else
            printf '%s\n' "$GO_BUILD_ROOT"
        fi
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go module cache · would clean"* ]] || return 1
    [[ "$output" == *"Go build cache · would clean"* ]] || return 1
    grep -qFx "env GOMODCACHE=$module_root go clean -n -modcache" "$trace" || return 1
    grep -qFx "env GOCACHE=$build_root go clean -n -cache" "$trace" || return 1
    rm -f "$trace"
    rm -rf "$module_root" "$build_root"
}

@test "clean_dev_go keeps module and build cache whitelist decisions independent" {
    local module_root="$HOME/go-module-whitelist"
    local build_root="$HOME/go-build-whitelist"
    local trace="$HOME/go-clean-whitelist.trace"
    mkdir -p "$module_root" "$build_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        if [[ "$3" == "GOMODCACHE" ]]; then
            printf '%s\n' "$GO_MODULE_ROOT"
        else
            printf '%s\n' "$GO_BUILD_ROOT"
        fi
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { [[ "$1" == "$GO_MODULE_ROOT" ]]; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
clean_tool_cache() { printf 'SKIP=%s|%s\n' "$1" "$2"; }
note_activity() { :; }
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIP=Go module cache|$module_root"* ]] || return 1
    grep -qFx "env GOCACHE=$build_root go clean -cache" "$trace" || return 1
    [[ "$(cat "$trace")" != *"-modcache"* ]] || return 1
    rm -f "$trace"
    rm -rf "$module_root" "$build_root"
}

@test "Go process gating does not block the concurrency-safe build cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_pgrep_any() {
    printf 'PROBE=%s\n' "$*"
    return 0
}
build_rc=0
module_rc=0
go_cache_process_state GOCACHE || build_rc=$?
go_cache_process_state GOMODCACHE || module_rc=$?
printf 'build=%s module=%s\n' "$build_rc" "$module_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"PROBE=-x go -x gopls"* ]] || return 1
    [[ "$output" == *"build=1 module=0"* ]]
}

@test "clean_dev_go propagates owner cleanup cancellation" {
    local module_root="$HOME/go-module-cancel"
    mkdir -p "$module_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        [[ "$3" == "GOMODCACHE" ]] && printf '%s\n' "$GO_MODULE_ROOT" || return 1
        return 0
    fi
    return 124
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
clean_rc=0
clean_dev_go || clean_rc=$?
printf 'rc=%s\n' "$clean_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"rc=124"* ]] || return 1
    rm -rf "$module_root"
}

@test "clean_go_cache_root refuses a path replaced before the owner command" {
    local cache_root="$HOME/go-cache-swap"
    local outside_root="$HOME/go-cache-outside"
    local trace="$HOME/go-clean-swap.trace"
    mkdir -p "$cache_root" "$outside_root/private"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_CACHE_ROOT="$cache_root" GO_OUTSIDE_ROOT="$outside_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
eval "$(declare -f _run_go_cache_clean_bound | sed '1s/_run_go_cache_clean_bound/_original_run_go_cache_clean_bound/')"
_run_go_cache_clean_bound() {
    mv "$GO_CACHE_ROOT" "$GO_CACHE_ROOT-old"
    ln -s "$GO_OUTSIDE_ROOT" "$GO_CACHE_ROOT"
    _original_run_go_cache_clean_bound "$@"
}
clean_go_cache_root "$GO_CACHE_ROOT" GOCACHE -cache "Go build cache"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go build cache · stopped (cache path state unknown)"* ]] || return 1
    [ ! -e "$trace" ] || return 1
    [ -d "$outside_root/private" ] || return 1
    rm -f "$cache_root"
    rm -rf "$cache_root-old" "$outside_root"
}

@test "clean_dev_jvm keeps the Ivy store and the sbt toolchain" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 1; }
safe_clean() { echo "$2|$1"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"/.ivy2/"* ]] || return 1
    [[ "$output" != *"/.sbt/"* ]]
}

@test "clean_dev_python clears Poetry package caches but keeps its virtualenvs" {
    # virtualenvs is hard-safety whitelisted, and protecting a nested path
    # protects its parent, so the whole pypoetry root drops out of the generic
    # ~/Library/Caches sweep. Without naming the rebuildable siblings the
    # protection silently costs all of Poetry's reclaimable space.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_tool_cache() { echo "$1|$2"; }
clean_uv_cache() { :; }
clean_pyinstaller_bincache() { :; }
clean_conda_metadata_caches() { :; }
note_activity() { :; }
clean_dev_python
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Poetry artifacts cache|$HOME/Library/Caches/pypoetry/artifacts/"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Poetry package cache|$HOME/Library/Caches/pypoetry/cache/"* ]] || return 1
    [[ "$output" != *"pypoetry/virtualenvs"* ]] || {
        echo "$output"
        return 1
    }
}

@test "clean_dev_other_langs keeps the Deno module store" {
    # DENO_DIR mixes remote imports with origin storage and runtime payloads;
    # the owner clean command resets the whole root rather than a narrow leaf.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_clang_module_cache() { :; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Deno"* ]] || return 1
    [[ "$output" != *"Caches/deno"* ]] || return 1
    [[ "$output" == *"Zig cache"* ]]
}

@test "clean_dev_other_langs keeps the NuGet global packages folder" {
    # ~/.nuget/packages is the restore target itself, the .NET counterpart of
    # ~/.m2/repository, which clean_large_files only reports for review.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_clang_module_cache() { :; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *".nuget"* ]] || return 1
    [[ "$output" != *"NuGet"* ]] || return 1
    [[ "$output" == *"Zig cache"* ]]
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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
    # Spotlight lists no other Codex copy, as on a machine without Codex.
    mole_test_fake_command mdfind
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

# Each case below gets its own HOME: they assert exact row counts, and the
# shared file HOME already holds other worktree fixtures.
_worktree_hint_run() {
    run env HOME="$1" PROJECT_ROOT="$PROJECT_ROOT" MOLE_CURRENT_COMMAND=clean \
        SIZE_STUB_RC="${2:-0}" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() {
    [[ "$SIZE_STUB_RC" == "0" ]] || return "$SIZE_STUB_RC"
    echo "2097152"
}
rc=0
report_agent_worktree_candidates || rc=$?
printf 'RC=%s CANCEL=%s\n' "$rc" "${MOLE_CLEAN_CANCEL_STATUS:-none}"
EOF
}

@test "report_agent_worktree_candidates reports a case-variant root once" {
    local test_home="$HOME/wt-case-home"
    mkdir -p "$test_home/code/proj/.claude/worktrees/wt-one"
    # ~/Code only aliases ~/code on a case-insensitive volume.
    [[ -d "$test_home/Code" ]] || skip "case-sensitive filesystem"

    _worktree_hint_run "$test_home"

    [ "$status" -eq 0 ] || return 1
    local rows
    rows=$(grep -c "AI agent worktrees" <<< "$output" || true)
    [ "$rows" -eq 1 ]
}

@test "report_agent_worktree_candidates reports a container once when one root links into another" {
    local test_home="$HOME/wt-link-home"
    mkdir -p "$test_home/code/sub/proj/.claude/worktrees/wt-one"
    ln -s "$test_home/code/sub" "$test_home/dev"

    _worktree_hint_run "$test_home"

    [ "$status" -eq 0 ] || return 1
    local rows
    rows=$(grep -c "AI agent worktrees" <<< "$output" || true)
    [ "$rows" -eq 1 ]
}

@test "report_agent_worktree_candidates reports the Codex worktree container" {
    local test_home="$HOME/wt-codex-home"
    mkdir -p "$test_home/.codex/worktrees/topic/repo"
    echo "data" > "$test_home/.codex/worktrees/topic/repo/file"

    _worktree_hint_run "$test_home"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"AI agent worktrees"*".codex/worktrees"* ]] || return 1
    # Report only: the worktree must still exist afterwards.
    [ -f "$test_home/.codex/worktrees/topic/repo/file" ]
}

@test "report_agent_worktree_candidates skips a row on a size timeout without cancelling clean" {
    local test_home="$HOME/wt-timeout-home"
    mkdir -p "$test_home/code/proj/.claude/worktrees/wt-one"

    _worktree_hint_run "$test_home" 124

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"AI agent worktrees"* ]] || return 1
    [[ "$output" == *"RC=0 CANCEL=none"* ]]
}

@test "report_agent_worktree_candidates keeps a size signal sticky" {
    local test_home="$HOME/wt-signal-home"
    mkdir -p "$test_home/code/proj/.claude/worktrees/wt-one"

    _worktree_hint_run "$test_home" 130

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"AI agent worktrees"* ]] || return 1
    [[ "$output" == *"RC=130 CANCEL=130"* ]]
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
_MOLE_COMPLETE_LSOF_MODE=direct
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
_MOLE_COMPLETE_LSOF_MODE=direct
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
_MOLE_COMPLETE_LSOF_MODE=direct
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
_MOLE_COMPLETE_LSOF_MODE=direct
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
run_with_timeout() {
    shift
    # Only the synthetic HOME install belongs to this fixture.
    if [[ "$1" == "/usr/libexec/PlistBuddy" && "${4:-}" == "/Applications/Codex.app/Contents/Info.plist" ]]; then
        return 1
    fi
    "$@"
}
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

@test "clean_codex_crashpad_pending removes only stale direct pending files (#1490)" {
    local case_home="$HOME/codex-crashpad-basic"
    local crashpad="$case_home/Library/Application Support/Codex/Crashpad"
    mkdir -p "$crashpad/pending/nested" "$crashpad/new" "$crashpad/completed" "$crashpad/attachments"
    touch "$crashpad/pending/stale.dmp" "$crashpad/pending/fresh.dmp" \
        "$crashpad/pending/nested/keep.dmp" "$crashpad/new/queued.dmp" \
        "$crashpad/completed/done.dmp" "$crashpad/settings.dat"
    touch -t 202001010000 "$crashpad/pending/stale.dmp" "$crashpad/pending/nested" \
        "$crashpad/pending/nested/keep.dmp" "$crashpad/new/queued.dmp" \
        "$crashpad/completed/done.dmp" "$crashpad/settings.dat"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { echo 4; }
safe_remove() { echo "SAFE_REMOVE:$1"; }
note_activity() { :; }
clean_codex_crashpad_pending
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE_REMOVE:$crashpad/pending/stale.dmp"* ]] || return 1
    [[ "$output" != *"fresh.dmp"* ]] || return 1
    [[ "$output" != *"nested"* ]] || return 1
    [[ "$output" != *"/new/"* ]] || return 1
    [[ "$output" != *"/completed/"* ]] || return 1
    [[ "$output" != *"settings.dat"* ]] || return 1
    [[ "$output" == *"Cleaned 1 stale Codex crash reports"* ]]
}

@test "clean_codex_crashpad_pending defers while Codex or its crash handler runs" {
    local case_home="$HOME/codex-crashpad-running"
    local pending="$case_home/Library/Application Support/Codex/Crashpad/pending"
    mkdir -p "$pending"
    touch "$pending/stale.dmp"
    touch -t 202001010000 "$pending/stale.dmp"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { [[ "$*" == *"-x Codex"* ]] && return 0; return 1; }
mole_defer_cleanup_family() { echo "DEFERRED:$1"; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; }
note_activity() { :; }
clean_codex_crashpad_pending
echo "---handler---"
pgrep() { [[ "$*" == *"Application Support/Codex/Crashpad"* ]] && return 0; return 1; }
clean_codex_crashpad_pending
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DELETE"* ]] || return 1
    [[ "${output%%---handler---*}" == *"DEFERRED:Codex"* ]] || return 1
    [[ "${output##*---handler---}" == *"DEFERRED:Codex"* ]] || return 1
    [[ -f "$pending/stale.dmp" ]]
}

@test "clean_codex_crashpad_pending fails closed on unknown probe states" {
    local case_home="$HOME/codex-crashpad-unknown"
    local pending="$case_home/Library/Application Support/Codex/Crashpad/pending"
    mkdir -p "$pending"
    touch "$pending/stale.dmp"
    touch -t 202001010000 "$pending/stale.dmp"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
command() { if [[ "$1" == "-v" && "$2" == "pgrep" ]]; then return 1; fi; builtin command "$@"; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; }
note_activity() { :; }
clean_codex_crashpad_pending
echo "---open-files---"
unset -f command
pgrep() { return 1; }
codex_sparkle_staging_has_open_files() { return 0; }
clean_codex_crashpad_pending
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DELETE"* ]] || return 1
    [[ "${output%%---open-files---*}" == *"skipped (process state unknown)"* ]] || return 1
    [[ "${output##*---open-files---}" == *"skipped (reports in use)"* ]] || return 1
    [[ -f "$pending/stale.dmp" ]]
}

@test "clean_codex_crashpad_pending rejects a symlinked pending ancestor" {
    local case_home="$HOME/codex-crashpad-ancestor-link"
    local crashpad="$case_home/Library/Application Support/Codex/Crashpad"
    local outside="$case_home/Documents/CrashpadVictim"
    mkdir -p "$crashpad" "$outside/pending"
    touch "$outside/pending/OUTSIDE_SENTINEL.dmp"
    touch -t 202001010000 "$outside/pending/OUTSIDE_SENTINEL.dmp"
    ln -s "$outside/pending" "$crashpad/pending"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; }
note_activity() { :; }
clean_codex_crashpad_pending
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DELETE"* ]] || return 1
    [[ -f "$outside/pending/OUTSIDE_SENTINEL.dmp" ]]
}

@test "should_protect_path opens exactly the crashpad pending file level (#1490)" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
base="$HOME/Library/Application Support/Codex"
should_protect_path "$base/Crashpad/pending/report.dmp" && exit 1
should_protect_path "$base/Crashpad/pending" || exit 1
should_protect_path "$base/Crashpad/pending/deeper/report.dmp" || exit 1
should_protect_path "$base/Crashpad" || exit 1
should_protect_path "$base/Crashpad/new/queued.dmp" || exit 1
should_protect_path "$base/Crashpad/settings.dat" || exit 1
should_protect_path "$base/sessions/session.json" || exit 1
echo "PROTECTION_SHAPE_OK"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"PROTECTION_SHAPE_OK"* ]]
}

@test "clean_tool_cache keeps ordinary owner failures quiet without claiming success" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
activities=0
note_activity() { activities=$((activities + 1)); }
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
clean_tool_cache "ok cache" "" true
clean_tool_cache "failing cache" "" false
owner_timeout() { return 124; }
clean_tool_cache "slow cache" "" owner_timeout
printf 'ACTIVITIES=%s\n' "$activities"
printf 'CANCEL=%s\n' "${MOLE_CLEAN_CANCEL_STATUS:-0}"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"ok cache"* ]] || return 1
    [[ "$output" != *"failing cache"* ]] || return 1
    [[ "$output" != *"slow cache"* ]] || return 1
    [[ "$output" == *"ACTIVITIES=1"* ]] || return 1
    [[ "$output" == *"CANCEL=0"* ]]
}

@test "an interrupted owner command stops the next pnpm store before its probe or prune" {
    # Ctrl-C while `pnpm store prune` holds the terminal reaches only the
    # child. Whichever store runs first is interrupted; the other one must
    # not even be probed.
    local test_home="$HOME/pnpm-cancel-home"
    mkdir -p "$test_home/bin" "$test_home/.local/share/mise/installs/pnpm/10.34.5"
    local bin
    for bin in "$test_home/bin/pnpm" "$test_home/.local/share/mise/installs/pnpm/10.34.5/pnpm"; do
        cat > "$bin" <<'SCRIPT'
#!/bin/bash
marker="$HOME/first-prune-interrupted"
case "${1:-}" in
    --version)
        [[ -e "$marker" ]] && echo "SECOND-PROBE-RAN" >> "$HOME/trace"
        echo "10.34.5"
        exit 0
        ;;
    store)
        if [[ "${2:-}" == "path" ]]; then
            echo "$HOME/store-$(basename "$(dirname "$0")")"
            exit 0
        fi
        if [[ "${2:-}" == "prune" ]]; then
            if [[ -e "$marker" ]]; then
                echo "SECOND-OWNER-RAN" >> "$HOME/trace"
                exit 0
            fi
            touch "$marker"
            exit 130
        fi
        ;;
esac
exit 2
SCRIPT
        chmod +x "$bin"
    done

    run env HOME="$test_home" PATH="$test_home/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
is_safe_pnpm_store_path() { [[ -n "$1" ]]; }
export -f pgrep
DRY_RUN=false
rc=0
clean_pnpm_stores || rc=$?
printf 'RC=%s CANCEL=%s\n' "$rc" "${MOLE_CLEAN_CANCEL_STATUS:-none}"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [ -e "$test_home/first-prune-interrupted" ] || return 1
    [[ "$output" == *"RC=130 CANCEL=130"* ]] || return 1
    [ ! -e "$test_home/trace" ]
}


@test "pip and mise owner interruptions stop later developer cleanup" {
    local tool code test_home
    for tool in pip3 mise; do
        for code in 130 143; do
            test_home="$HOME/owner-$tool-$code"
            mkdir -p "$test_home/bin"
            cat > "$test_home/bin/$tool" <<'SCRIPT'
#!/bin/bash
case "$*" in
    --version) echo test-version ;;
    'cache dir' | 'cache path') echo "$HOME/cache" ;;
    'cache purge' | 'cache clear') echo owner >> "$HOME/trace"; exit "$OWNER_RC" ;;
    *) exit 2 ;;
esac
SCRIPT
            chmod +x "$test_home/bin/$tool"
            run env HOME="$test_home" PATH="$test_home/bin:/usr/bin:/bin"                 PROJECT_ROOT="$PROJECT_ROOT" TOOL="$tool" OWNER_RC="$code"                 MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
note_activity() { :; }
stop_section_spinner() { :; }
safe_clean() { echo later-sink >> "$HOME/trace"; }
clean_uv_cache() { :; }
clean_pyinstaller_bincache() { :; }
clean_conda_metadata_caches() { :; }
clean_dev_npm() { :; }
if [[ "$TOOL" == pip3 ]]; then
    clean_dev_go() { echo later-section >> "$HOME/trace"; return 143; }
else
    clean_dev_python() { :; }
    clean_dev_go() { :; }
fi
clean_dev_rust() { echo later-section >> "$HOME/trace"; return 143; }
rc=0
clean_developer_tools || rc=$?
printf 'RC=%s CANCEL=%s\n' "$rc" "${MOLE_CLEAN_CANCEL_STATUS:-0}"
EOF
            [ "$status" -eq 0 ] || { echo "$output"; return 1; }
            [[ "$output" == *"RC=$code CANCEL=$code"* ]] || { echo "$tool: $output"; return 1; }
            [[ "$(cat "$test_home/trace")" == owner ]] || { cat "$test_home/trace"; return 1; }
        done
    done
}

@test "clean_tool_cache honors pending cancellation before real and dry-run work" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
owner() { echo UNEXPECTED_OWNER; }
is_path_whitelisted() { echo UNEXPECTED_WHITELIST; return 1; }
for pending in 124 130; do
    for DRY_RUN in false true; do
        MOLE_CLEAN_CANCEL_STATUS="$pending"
        rc=0
        clean_tool_cache "pending cache" "$HOME/cache" owner || rc=$?
        [[ "$rc" == "$pending" ]] || exit 1
    done
done
echo PENDING_KEPT
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == PENDING_KEPT ]] || return 1
}

@test "mise owner failures never fall back to direct removal" {
    local code test_home
    for code in 0 1 124; do
        test_home="$HOME/mise-owner-$code"
        mkdir -p "$test_home/bin" "$test_home/cache"
        printf keep > "$test_home/cache/blob"
        cat > "$test_home/bin/mise" <<'SCRIPT'
#!/bin/bash
case "$*" in
    'cache path') echo "$HOME/cache" ;;
    'cache clear') echo owner > "$HOME/trace"; exit "$OWNER_RC" ;;
    *) exit 2 ;;
esac
SCRIPT
        chmod +x "$test_home/bin/mise"
        run env HOME="$test_home" PATH="$test_home/bin:/usr/bin:/bin"             PROJECT_ROOT="$PROJECT_ROOT" OWNER_RC="$code" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
note_activity() { :; }
safe_clean() { echo direct-removal >> "$HOME/trace"; }
clean_dev_mise
printf 'CANCEL=%s\n' "${MOLE_CLEAN_CANCEL_STATUS:-0}"
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$(cat "$test_home/trace")" == owner ]] || { cat "$test_home/trace"; return 1; }
        [[ "$output" == *"CANCEL=0"* ]] || return 1
    done
}

@test "Codex staging query timeout keeps the target without cancelling later cleanup (#1653)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
_MOLE_CODEX_STAGING_ROOT="$HOME/Library/Caches/com.openai.codex/staging"
mkdir -p "$_MOLE_CODEX_STAGING_ROOT"
target="$_MOLE_CODEX_STAGING_ROOT/payload"
printf 'keep' > "$target"
_codex_staging_entry_is_still_stale() { return 0; }
codex_desktop_process_state() { return 1; }
codex_sparkle_updater_running() { return 1; }
lsof() { return "$scripted_rc"; }
run_with_timeout() { shift; "$@"; }
MOLE_CURRENT_COMMAND=clean
for scripted_rc in 124 130 143; do
    MOLE_CLEAN_CANCEL_STATUS=0
    probe_rc=0
    codex_sparkle_staging_has_open_files "$_MOLE_CODEX_STAGING_ROOT" || probe_rc=$?
    guard_rc=0
    _codex_staging_delete_guard_allows || guard_rc=$?
    [[ $guard_rc -ne 0 ]] || safe_remove "$target" true 1
    next="$HOME/later-$scripted_rc.log"
    printf 'later' > "$next"
    next_rc=0
    safe_remove "$next" true 1 || next_rc=$?
    printf 'STATUS=%s PROBE=%s GUARD=%s CANCEL=%s NEXT=%s\n' "$scripted_rc" "$probe_rc" "$guard_rc" "$MOLE_CLEAN_CANCEL_STATUS" "$next_rc"
    [[ -f "$target" ]] || exit 1
    if [[ "$scripted_rc" == 124 ]]; then
        [[ $probe_rc -eq 2 && $guard_rc -ne 0 && $MOLE_CLEAN_CANCEL_STATUS -eq 0 && $next_rc -eq 0 && ! -e "$next" ]] || exit 1
    else
        [[ $probe_rc -eq $scripted_rc && $guard_rc -ne 0 && $MOLE_CLEAN_CANCEL_STATUS -eq $scripted_rc && $next_rc -eq $scripted_rc && -f "$next" ]] || exit 1
    fi
done
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
