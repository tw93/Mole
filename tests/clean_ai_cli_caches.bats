#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home ai-cli-caches
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]] || {
        echo "FATAL: HOME is not a test temp dir: $HOME"
        exit 1
    }
    rm -rf "$HOME/.codex" "$HOME/.gemini" "$HOME/.claude" \
        "$HOME/Library/Application Support/Claude" "$HOME/Library/Caches/Codex"
}

assert_run_success() {
    [ "$status" -eq 0 ] || {
        echo "expected status 0, got $status"
        echo "$output"
        return 1
    }
}

assert_output_contains() {
    local expected="$1"
    [[ "$output" == *"$expected"* ]] || {
        echo "expected output to contain: $expected"
        echo "$output"
        return 1
    }
}

assert_output_not_contains() {
    local unexpected="$1"
    [[ "$output" != *"$unexpected"* ]] || {
        echo "expected output not to contain: $unexpected"
        echo "$output"
        return 1
    }
}

@test "clean_codex_cli skips codex state by default" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log" "$HOME/.codex/sessions"
    mkdir -p "$HOME/.codex/cache/codex_app_directory"
    touch "$HOME/.codex/cache/c.bin" "$HOME/.codex/cache/session_index.jsonl"
    touch "$HOME/.codex/cache/codex_app_directory/index.json" "$HOME/.codex/.tmp/t.bin" "$HOME/.codex/log/codex-tui.log"
    touch "$HOME/.codex/sessions/s.jsonl" "$HOME/.codex/auth.json" "$HOME/.codex/history.jsonl"
    touch "$HOME/.codex/state_5.sqlite" "$HOME/.codex/logs_2.sqlite" "$HOME/.codex/session_index.jsonl"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 1; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "Codex CLI state"
    assert_output_not_contains "SAFE_CLEAN:"
    [ -f "$HOME/.codex/cache/session_index.jsonl" ]
    [ -f "$HOME/.codex/cache/codex_app_directory/index.json" ]
    [ -f "$HOME/.codex/.tmp/t.bin" ]
    [ -f "$HOME/.codex/log/codex-tui.log" ]
    [ -f "$HOME/.codex/sessions/s.jsonl" ]
    [ -f "$HOME/.codex/state_5.sqlite" ]
    [ -f "$HOME/.codex/logs_2.sqlite" ]
}

@test "clean_codex_cli is a no-op when ~/.codex is absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 1; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_codex_cli reports running Codex without cleaning state" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log"
    touch "$HOME/.codex/cache/c.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 0; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "Codex CLI state"
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_codex_desktop_caches removes only measured fixed cache leaves through the real sink" {
    run env HOME="$HOME/codex-cache-positive" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache_root="$HOME/Library/Caches/Codex"
support_root="$HOME/Library/Application Support/Codex"
mkdir -p \
    "$cache_root/Default/Cache" \
    "$cache_root/Default/Code Cache" \
    "$cache_root/Default/Partitions/codex-browser-app/Cache" \
    "$cache_root/Default/Partitions/codex-browser-app/Code Cache" \
    "$cache_root/codex-browser-app/Cache" \
    "$cache_root/codex-browser-app/Code Cache" \
    "$cache_root/Default/Local Storage" \
    "$support_root/Default/Cache"
touch \
    "$cache_root/Default/Cache/default-cache.bin" \
    "$cache_root/Default/Code Cache/default-code.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Cache/partition-cache.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Code Cache/partition-code.bin" \
    "$cache_root/codex-browser-app/Cache/browser-cache.bin" \
    "$cache_root/codex-browser-app/Code Cache/browser-code.bin" \
    "$cache_root/Default/Local Storage/state.bin" \
    "$support_root/Default/Cache/durable-state.bin"

source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_codex_desktop_caches

for removed in \
    "$cache_root/Default/Cache/default-cache.bin" \
    "$cache_root/Default/Code Cache/default-code.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Cache/partition-cache.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Code Cache/partition-code.bin" \
    "$cache_root/codex-browser-app/Cache/browser-cache.bin" \
    "$cache_root/codex-browser-app/Code Cache/browser-code.bin"; do
    [[ ! -e "$removed" ]] || { echo "STILL_PRESENT:$removed"; exit 1; }
done
[[ -f "$cache_root/Default/Local Storage/state.bin" ]] || exit 1
[[ -f "$support_root/Default/Cache/durable-state.bin" ]] || exit 1
echo "EXACT_LEAVES_CLEANED"
EOF

    assert_run_success
    assert_output_contains "EXACT_LEAVES_CLEANED"
    assert_output_not_contains "STILL_PRESENT:"
}

@test "clean_codex_desktop_caches preserves pipe characters in physical target paths" {
    local case_home="$HOME/codex-cache|pipe-home"
    local target="$case_home/Library/Caches/Codex/Default/Cache/owned.bin"
    local truncated_prefix="${case_home%%|*}"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
note_activity() { :; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" || return 75
    local index
    for ((index = 1; index < $#; index++)); do
        printf 'TARGET:%s\n' "${!index}"
    done
}
clean_codex_desktop_caches
EOF

    assert_run_success
    assert_output_contains "TARGET:$target"
    assert_output_not_contains "TARGET:$truncated_prefix/"
}

@test "clean_codex_desktop_caches stops when Codex starts after the initial probe" {
    run env HOME="$HOME/codex-cache-start-race" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"

probe_count=0
pgrep() {
    probe_count=$((probe_count + 1))
    if [[ $probe_count -ge 5 ]]; then
        return 0
    fi
    return 1
}

clean_codex_desktop_caches || true
[[ -f "$target" ]] || exit 1
printf 'CODEX_START_RACE_CLOSED\n'
EOF

    assert_run_success
    assert_output_contains "CODEX_START_RACE_CLOSED"
    assert_output_not_contains "Codex Desktop caches · stopped"
}

@test "clean_codex_desktop_caches skips while ChatGPT owns the Codex app cache" {
    run env HOME="$HOME/codex-cache-running" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ "$1" == "-x" && "$2" == "ChatGPT" ]]; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "Codex Desktop caches · skipped"
}

@test "clean_codex_desktop_caches skips when its process probe fails" {
    run env HOME="$HOME/codex-cache-probe-error" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 2; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
    assert_output_contains "Codex Desktop caches · skipped (process state unknown)"
}

@test "clean_codex_desktop_caches skips when pgrep is unavailable" {
    run env HOME="$HOME/codex-cache-probe-missing" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"
PATH=/nonexistent
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
    assert_output_contains "Codex Desktop caches · skipped (process state unknown)"
}

@test "clean_codex_desktop_caches rejects symlinked Library and Caches ancestors" {
    run env HOME="$HOME/codex-cache-ancestor-links" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
for component in Library Caches; do
    case_home="$HOME/$component-case"
    outside="$case_home/outside"
    if [[ "$component" == "Library" ]]; then
        target="$outside/Caches/Codex/Default/Cache/external.bin"
        mkdir -p "$(dirname "$target")" "$case_home"
        ln -s "$outside" "$case_home/Library"
    else
        target="$outside/Codex/Default/Cache/external.bin"
        mkdir -p "$(dirname "$target")" "$case_home/Library"
        ln -s "$outside" "$case_home/Library/Caches"
    fi
    touch "$target"
    CASE_HOME="$case_home" TARGET="$target" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
HOME="$CASE_HOME"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$TARGET" ]] || exit 1
INNER
done
EOF

    assert_run_success
}

@test "clean_codex_desktop_caches rejects a symlinked Codex root" {
    run env HOME="$HOME/codex-cache-root-link" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
outside="$HOME/outside-codex"
target="$outside/Default/Cache/external.bin"
mkdir -p "$(dirname "$target")" "$HOME/Library/Caches"
touch "$target"
ln -s "$outside" "$HOME/Library/Caches/Codex"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
}

@test "clean_codex_desktop_caches rejects a symlinked fixed profile" {
    run env HOME="$HOME/codex-cache-profile-link" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache_root="$HOME/Library/Caches/Codex"
outside="$HOME/outside-profile"
target="$outside/Cache/external.bin"
mkdir -p "$(dirname "$target")" "$cache_root"
touch "$target"
ln -s "$outside" "$cache_root/codex-browser-app"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
}

@test "clean_codex_desktop_caches rejects a symlinked cache leaf" {
    run env HOME="$HOME/codex-cache-leaf-link" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
profile="$HOME/Library/Caches/Codex/Default"
outside="$HOME/outside-leaf"
target="$outside/external.bin"
mkdir -p "$profile" "$outside"
touch "$target"
ln -s "$outside" "$profile/Cache"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
}

@test "clean_antigravity_caches cleans antigravity browser caches" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    mkdir -p "$ag/Default/Cache" "$ag/Default/Code Cache" "$ag/Default/GPUCache"
    mkdir -p "$ag/Default/DawnGraphiteCache" "$ag/Default/DawnWebGPUCache"
    mkdir -p "$ag/GraphiteDawnCache" "$ag/component_crx_cache" "$ag/extensions_crx_cache"
    mkdir -p "$ag/Default/Extensions" "$ag/Default/Storage"
    touch "$ag/Default/Cache/a.bin" "$ag/Default/Code Cache/b.bin" "$ag/Default/GPUCache/c.bin"
    touch "$ag/Default/DawnGraphiteCache/d.bin" "$ag/Default/DawnWebGPUCache/e.bin"
    touch "$ag/GraphiteDawnCache/f.bin" "$ag/component_crx_cache/g.bin" "$ag/extensions_crx_cache/h.bin"
    touch "$ag/Default/Extensions/x.js" "$ag/Default/Storage/y.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() {
    printf '%s\n' "$*" >> "$HOME/process-trace"
    return 1
}
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
grep -qxF -- '-x Antigravity' "$HOME/process-trace" || exit 1
grep -qxF -- '-x gemini' "$HOME/process-trace" || exit 1
EOF

    assert_run_success || return 1
    assert_output_contains "SAFE_CLEAN:Antigravity browser cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity code cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity GPU cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity Dawn cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity WebGPU cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity Graphite cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity component cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity extension cache|"
    assert_output_contains "SWC:Antigravity"
    assert_output_not_contains "Default/Extensions"
    assert_output_not_contains "Default/Storage"
}

@test "clean_antigravity_caches is a no-op when the profile is absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:Antigravity"
    assert_output_not_contains "SWC:"
}

@test "clean_antigravity_caches ignores an empty active profile" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    rm -rf "$ag"
    mkdir -p "$ag/Default/Cache" "$ag/Default/Service Worker/CacheStorage"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; }
clean_service_worker_cache() { echo "UNEXPECTED_SWC"; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DEFER"
    assert_output_not_contains "UNEXPECTED_CLEAN"
    assert_output_not_contains "UNEXPECTED_SWC"
    assert_output_not_contains "process state unknown"
}

@test "clean_antigravity_caches recognizes root-level cache candidates" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    rm -rf "$ag"
    mkdir -p "$ag/component_crx_cache"
    touch "$ag/component_crx_cache/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Antigravity component cache|$ag/component_crx_cache/candidate"
}

@test "clean_antigravity_caches never touches gemini tmp chat checkpoints" {
    mkdir -p "$HOME/.gemini/tmp"
    touch "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:"
    assert_output_not_contains "SWC:"
    [[ -f "$HOME/.gemini/tmp/work.bin" ]]
}

@test "clean_antigravity_caches skips browser profile and gemini tmp while running" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    mkdir -p "$ag/Default/Cache" "$HOME/.gemini/tmp"
    touch "$ag/Default/Cache/a.bin" "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { echo "NOTE_ACTIVITY"; }
pgrep() {
    [[ "$1" == "-x" && "$2" == "gemini" ]]
}
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "Antigravity/Gemini caches · skipped"
    assert_output_not_contains "NOTE_ACTIVITY"
    assert_output_not_contains "SAFE_CLEAN:"
    assert_output_not_contains "SWC:"
}

@test "clean_dev_misc invokes Codex and Antigravity cleanup helpers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { :; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_codex_runtimes() { :; }
clean_codex_desktop_staging() { echo "CODEX_STAGING_CALLED"; }
clean_codex_desktop_caches() { echo "CODEX_CACHE_CALLED"; }
note_activity() { :; }
clean_codex_cli() { echo "CODEX_CLI_CALLED"; }
clean_antigravity_caches() { echo "ANTIGRAVITY_CALLED"; }
clean_dev_misc
EOF

    assert_run_success
    assert_output_contains "CODEX_CLI_CALLED"
    assert_output_contains "CODEX_CACHE_CALLED"
    assert_output_contains "CODEX_STAGING_CALLED"
    assert_output_contains "ANTIGRAVITY_CALLED"
}

@test "clean_dev_ai_agents reaps stale Claude Desktop bundled versions when active version is known" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code old version|$claude_support/claude-code/2.1.140"
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code VM old version|$claude_support/claude-code-vm/2.1.140"
    assert_output_not_contains "$claude_support/claude-code/2.1.142"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.142"
    assert_output_not_contains "$claude_support/claude-code/2.1.150"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.150"
}

@test "clean_dev_ai_agents keeps active Claude Desktop bundled version even when it is older" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.140" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code old version|$claude_support/claude-code/2.1.142"
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code VM old version|$claude_support/claude-code-vm/2.1.142"
    assert_output_not_contains "$claude_support/claude-code/2.1.140"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.140"
    assert_output_not_contains "$claude_support/claude-code/2.1.150"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.150"
}

@test "clean_dev_ai_agents leaves single Claude Desktop bundled version alone" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_not_contains "Claude Desktop bundled Claude Code"
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop bundled versions when active version is unknown" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_claude_desktop_bundled_versions validates the active version before deferring" {
    local isolated_home="$HOME/claude-missing-sdk-active"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$1"; }
clean_claude_desktop_bundled_versions 1
EOF

    assert_run_success
    assert_output_contains "kept: active version unknown"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "UNEXPECTED_DEFER"
    assert_output_not_contains "UNEXPECTED_CLEAN"
}

@test "clean_claude_desktop_bundled_versions does not defer whitelist-only stale versions" {
    local isolated_home="$HOME/claude-whitelist-only-active"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    local old_cli="$claude_support/claude-code/2.1.140"
    local old_vm="$claude_support/claude-code-vm/2.1.140"
    mkdir -p "$old_cli" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$old_vm" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$old_cli" "$old_vm"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
old_cli="$HOME/Library/Application Support/Claude/claude-code/2.1.140"
old_vm="$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140"
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$old_cli" || "$1" == "$old_vm" ]]; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
printf 'SKIPPED:%s\n' "$whitelist_skipped_count"
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DEFER"
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "SKIPPED:2"
}

@test "versioned agent retention preserves newline-containing pathnames" {
    local isolated_home="$HOME/agent-newline-path"
    local versions_root="$isolated_home/versions"
    local newline_version=$'2.0\njunk'
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$versions_root/$newline_version"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604300000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    touch -t 202604100000 "$versions_root/$newline_version"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
root="$HOME/versions"
newline_version=$'2.0\njunk'
_plan_versioned_agent_cleanup_targets "$root" 1 "$root/3.0"
[[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -eq 2 ]] || exit 1
found_old=false
found_newline=false
for target in "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}"; do
    [[ "$target" != "$root/2.0" ]] || { echo "WRONG_PLANNED_KEEP:$target"; exit 1; }
    [[ "$target" == "$root/1.0" ]] && found_old=true
    [[ "$target" == "$root/$newline_version" ]] && found_newline=true
done
[[ "$found_old" == "true" && "$found_newline" == "true" ]]
EOF

    assert_run_success
    assert_output_not_contains "WRONG_PLANNED_KEEP"
}

@test "versioned agent cleanup discards a partial inventory when find fails" {
    local isolated_home="$HOME/agent-partial-inventory"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$fake_bin"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    cat > "$fake_bin/find" <<'EOF'
#!/bin/bash
root="$1"
printf '%s\0' "$root/1.0" "$root/2.0" "$root/3.0"
exit 73
EOF
    chmod +x "$fake_bin/find"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "UNEXPECTED_DELETE:$1"; }
set +e
clean_versioned_agent_root "$HOME/versions" "Agent old version" 1
rc=$?
set -e
printf 'SCAN_RC:%s\n' "$rc"
[[ $rc -eq 73 ]]
EOF

    assert_run_success
    assert_output_contains "SCAN_RC:73"
    assert_output_not_contains "UNEXPECTED_DELETE"
}

@test "versioned agent delete guard rejects repeated partial active inventories" {
    local isolated_home="$HOME/agent-partial-active-inventory"
    local versions_root="$isolated_home/versions"
    local bin_dir="$isolated_home/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/agent" "$versions_root/2.0/agent" "$versions_root/3.0/agent"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/agent" "$bin_dir/agent"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
root="$HOME/versions"
scan_count=0
_materialize_versioned_agent_entries() {
    local versions_root="$1"
    local output_file="$2"
    scan_count=$((scan_count + 1))
    if [[ $scan_count -eq 1 || $scan_count -eq 3 ]]; then
        printf '%s\0' "$versions_root/1.0" "$versions_root/2.0" > "$output_file"
        return 73
    fi
    command find "$versions_root" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) -print0 > "$output_file"
}
_MOLE_VERSIONED_AGENT_GUARD_ROOT="$root"
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK="$HOME/bin/agent"
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=false
_MOLE_VERSIONED_AGENT_GUARD_KEEP=1
set +e
_versioned_agent_delete_guard_allows "$root/1.0"
rc=$?
set -e
printf 'GUARD_RC:%s\n' "$rc"
[[ $rc -eq 73 ]]
EOF

    assert_run_success
    assert_output_contains "GUARD_RC:73"
}

@test "versioned agent inventory has a wall-clock timeout" {
    local isolated_home="$HOME/agent-inventory-timeout"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$fake_bin"
    cat > "$fake_bin/find" <<'EOF'
#!/bin/bash
sleep 30
EOF
    chmod +x "$fake_bin/find"

    local started=$SECONDS
    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
set +e
_plan_versioned_agent_cleanup_targets "$HOME/versions" 1
rc=$?
set -e
printf 'INVENTORY_RC:%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF
    local elapsed=$((SECONDS - started))

    assert_run_success
    assert_output_contains "INVENTORY_RC:124"
    [ "$elapsed" -lt 10 ]
}

@test "versioned agent stat probes share the inventory deadline" {
    local isolated_home="$HOME/agent-stat-timeout"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$fake_bin"
    cat > "$fake_bin/stat" <<'EOF'
#!/bin/bash
sleep 30
EOF
    chmod +x "$fake_bin/stat"

    local started=$SECONDS
    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
set +e
_plan_versioned_agent_cleanup_targets "$HOME/versions" 1
rc=$?
set -e
printf 'STAT_RC:%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF
    local elapsed=$((SECONDS - started))

    assert_run_success
    assert_output_contains "STAT_RC:124"
    [ "$elapsed" -lt 10 ]
}

@test "versioned agent cleanup rechecks the active symlink after sizing" {
    local isolated_home="$HOME/agent-active-symlink-race"
    local versions_root="$isolated_home/.local/share/claude/versions"
    local bin_dir="$isolated_home/.local/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/claude" "$versions_root/2.0/claude" "$versions_root/3.0/claude"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/claude" "$bin_dir/claude"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
get_cleanup_path_size_kb() {
    rm -f "$HOME/.local/bin/claude"
    ln -s "$HOME/.local/share/claude/versions/1.0/claude" "$HOME/.local/bin/claude"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_dev_ai_agents
[[ -d "$HOME/.local/share/claude/versions/1.0" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "Claude Code old version · stopped (retention changed)"
}

@test "versioned agent cleanup rechecks the active symlink after retention planning" {
    local isolated_home="$HOME/agent-active-plan-race"
    local versions_root="$isolated_home/.local/share/claude/versions"
    local bin_dir="$isolated_home/.local/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/claude" "$versions_root/2.0/claude" "$versions_root/3.0/claude"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/claude" "$bin_dir/claude"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
get_cleanup_path_size_kb() {
    : > "$HOME/arm-active-plan-race"
    echo 1
}
_versioned_agent_entry_mtime() {
    if [[ -e "$HOME/arm-active-plan-race" && ! -e "$HOME/flipped-active-plan-race" ]]; then
        : > "$HOME/flipped-active-plan-race"
        rm -f "$HOME/.local/bin/claude"
        ln -s "$HOME/.local/share/claude/versions/1.0/claude" "$HOME/.local/bin/claude"
    fi
    command stat -f%m "$1"
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_dev_ai_agents
[[ -d "$HOME/.local/share/claude/versions/1.0" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "Claude Code old version · stopped (active version changed)"
}

@test "Claude Desktop bundled cleanup rechecks activity after sizing" {
    local isolated_home="$HOME/claude-size-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() {
    [[ -e "$HOME/claude-started" ]] && return 0
    return 1
}
get_cleanup_path_size_kb() {
    : > "$HOME/claude-started"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
rm -f "$HOME/claude-started"
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140" ]] || exit 1
printf 'DEFER:%s\n' "$(format_deferred_cleanup_families)"
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "DEFER:Claude Desktop"
}

@test "Claude Desktop bundled cleanup rechecks active-version evidence after sizing" {
    local isolated_home="$HOME/claude-active-evidence-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    local active="$HOME/Library/Application Support/Claude/claude-code/2.1.150"
    if [[ -d "$active" ]]; then
        mv "$active" "$HOME/relocated-active-version"
    fi
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "stopped (active version changed)"
}

@test "Claude Desktop bundled cleanup rechecks the SDK after retention planning" {
    local isolated_home="$HOME/claude-sdk-plan-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    : > "$HOME/arm-sdk-plan-race"
    echo 1
}
_versioned_agent_entry_mtime() {
    if [[ -e "$HOME/arm-sdk-plan-race" && ! -e "$HOME/flipped-sdk-plan-race" ]]; then
        : > "$HOME/flipped-sdk-plan-race"
        echo "2.1.140" > "$HOME/Library/Application Support/Claude/claude-code-vm/.sdk-version"
    fi
    command stat -f%m "$1"
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "stopped (active version changed)"
}

@test "Claude Desktop bundled cleanup rechecks compiled-model policy after sizing" {
    local isolated_home="$HOME/claude-policy-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    mkdir -p "$1/com.apple.e5rt.e5bundlecache"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "stopped (retention changed)"
}

@test "clean_dev_ai_agents skips Claude Desktop bundled versions when sdk version is path-like" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"
    echo "../2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop cleanup when active version is missing from one bundled root" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop cleanup when only one bundled root can identify active version" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop bundled versions while Claude Desktop is running" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() {
    [[ "$1" == "-x" && "$2" == "Claude" ]]
}
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_not_contains "Claude Desktop bundled Claude Code · skipped"
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_codex_marketplace_staging removes only aged staging prefixes (#1389)" {
    local tmp="$HOME/.codex/.tmp"
    local bundled="$tmp/bundled-marketplaces"
    local staging="$tmp/marketplaces/.staging"
    mkdir -p "$bundled/openai-bundled" \
        "$bundled/openai-bundled.staging-old" \
        "$bundled/openai-bundled.staging-fresh" \
        "$tmp/marketplaces/my-marketplace" \
        "$staging/marketplace-upgrade-old" \
        "$staging/marketplace-add-old" \
        "$staging/marketplace-backup-old"
    touch "$bundled/openai-bundled/KEEP" \
        "$bundled/openai-bundled.staging-old/GONE" \
        "$bundled/openai-bundled.staging-fresh/KEEP" \
        "$tmp/marketplaces/my-marketplace/KEEP" \
        "$staging/marketplace-upgrade-old/GONE" \
        "$staging/marketplace-add-old/GONE" \
        "$staging/marketplace-backup-old/KEEP"
    touch -t 202001010000 \
        "$bundled/openai-bundled" \
        "$bundled/openai-bundled.staging-old" \
        "$tmp/marketplaces/my-marketplace" \
        "$staging/marketplace-upgrade-old" \
        "$staging/marketplace-add-old" \
        "$staging/marketplace-backup-old"
    # Fresh staging must stay (age gate).
    touch "$bundled/openai-bundled.staging-fresh"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
# The staging cleanup has no engine-absent fallback (see the audited-count
# gate in clean_core.bats), so a standalone case supplies the guard itself.
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" || return 75
    safe_clean "$@"
}
note_activity() { :; }
clean_codex_marketplace_staging
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$bundled/openai-bundled.staging-old"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$staging/marketplace-upgrade-old"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$staging/marketplace-add-old"* ]] || return 1
    [[ "$output" != *"openai-bundled|"* ]] || return 1
    [[ "$output" != *"openai-bundled.staging-fresh"* ]] || return 1
    [[ "$output" != *"my-marketplace"* ]] || return 1
    [[ "$output" != *"marketplace-backup-old"* ]] || return 1
}

@test "clean_codex_marketplace_staging defers while Codex runtime is active" {
    local staging="$HOME/.codex/.tmp/marketplaces/.staging"
    mkdir -p "$staging/marketplace-upgrade-old"
    touch "$staging/marketplace-upgrade-old/payload"
    touch -t 202001010000 "$staging/marketplace-upgrade-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() {
    if [[ "$*" == *codex* ]] || [[ "$*" == *Codex* ]] || [[ "$*" == *ChatGPT* ]]; then
        return 0
    fi
    return 1
}
lsof() { return 1; }
safe_clean() { echo "UNEXPECTED:$1"; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_codex_marketplace_staging
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEFER:Codex"* ]] || return 1
    [[ "$output" != *"UNEXPECTED:"* ]] || return 1
    [[ -f "$staging/marketplace-upgrade-old/payload" ]]
}
