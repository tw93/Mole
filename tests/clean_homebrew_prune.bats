#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-brew-prune.XXXXXX")"
    export HOME

    mkdir -p "$HOME/.cache/mole"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_homebrew_old_versions runs brew cleanup --prune=30" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
run_with_timeout() { shift; "$@"; }
create_temp_file() { mktemp; }
get_epoch_seconds() { date +%s; }
ensure_user_file() { mkdir -p "$(dirname "$1")" && touch "$1"; }
DRY_RUN=false

brew() {
    if [[ "$1" == "cleanup" && "$2" == "--prune=30" ]]; then
        echo "Removing: /opt/homebrew/Cellar/old-pkg/1.0"
        echo "==> This operation has freed approximately 500MB of disk space."
        return 0
    fi
    return 0
}
export -f brew

clean_homebrew_old_versions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"old formula versions"* ]]
}

@test "clean_homebrew_old_versions skips when brew not installed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

PATH="/usr/bin:/bin"
DRY_RUN=false

clean_homebrew_old_versions
EOF

    [ "$status" -eq 0 ]
}

@test "clean_homebrew_old_versions dry run shows would-prune message" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/brew.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
DRY_RUN=true

brew() { return 0; }
export -f brew

clean_homebrew_old_versions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"would"* ]]
}
