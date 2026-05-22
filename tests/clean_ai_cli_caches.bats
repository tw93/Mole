#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-ai-cli-caches.XXXXXX")"
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

setup() {
    [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]] || {
        echo "FATAL: HOME is not a test temp dir: $HOME"
        exit 1
    }
    rm -rf "$HOME/.codex" "$HOME/.gemini"
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

@test "clean_codex_cli cleans codex cache, tmp, and log directories" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log" "$HOME/.codex/sessions"
    touch "$HOME/.codex/cache/c.bin" "$HOME/.codex/.tmp/t.bin" "$HOME/.codex/log/codex-tui.log"
    touch "$HOME/.codex/sessions/s.jsonl" "$HOME/.codex/auth.json" "$HOME/.codex/history.jsonl"
    touch "$HOME/.codex/state_5.sqlite" "$HOME/.codex/logs_2.sqlite"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 1; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Codex CLI cache|$HOME/.codex/cache/"
    assert_output_contains "SAFE_CLEAN:Codex CLI temp files|$HOME/.codex/.tmp/"
    assert_output_contains "SAFE_CLEAN:Codex CLI logs|$HOME/.codex/log/"
    assert_output_not_contains "sessions"
    assert_output_not_contains "auth.json"
    assert_output_not_contains "history.jsonl"
    assert_output_not_contains "state_5.sqlite"
    assert_output_not_contains "logs_2.sqlite"
}

@test "clean_codex_cli is a no-op when ~/.codex is absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

@test "clean_codex_cli skips all targets while Codex is running" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log"
    touch "$HOME/.codex/cache/c.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 0; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_contains "Codex CLI caches · skipped (Codex running)"
    assert_output_not_contains "SAFE_CLEAN:"
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

@test "clean_antigravity_caches cleans gemini CLI temp files without browser profile" {
    mkdir -p "$HOME/.gemini/tmp"
    touch "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
    assert_output_contains "SAFE_CLEAN:Gemini CLI temp files|$HOME/.gemini/tmp/"
}

@test "clean_antigravity_caches skips browser profile and gemini tmp while running" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    mkdir -p "$ag/Default/Cache" "$HOME/.gemini/tmp"
    touch "$ag/Default/Cache/a.bin" "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
    assert_output_contains "Antigravity/Gemini caches · skipped"
    assert_output_contains "NOTE_ACTIVITY"
    assert_output_not_contains "SAFE_CLEAN:"
    assert_output_not_contains "SWC:"
}

@test "clean_dev_misc invokes clean_codex_cli and clean_antigravity_caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { :; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_codex_runtimes() { :; }
note_activity() { :; }
clean_codex_cli() { echo "CODEX_CLI_CALLED"; }
clean_antigravity_caches() { echo "ANTIGRAVITY_CALLED"; }
clean_dev_misc
EOF

    assert_run_success
    assert_output_contains "CODEX_CLI_CALLED"
    assert_output_contains "ANTIGRAVITY_CALLED"
}
