#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-user-core.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_user_essentials respects Trash whitelist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
note_activity() { :; }
is_path_whitelisted() { [[ "$1" == "$HOME/.Trash" ]]; }
clean_user_essentials
EOF

    [ "$status" -eq 0 ]
    # Whitelist-protected items no longer show output (UX improvement in V1.22.0)
    [[ "$output" != *"Trash"* ]]
}

@test "clean_macos_system_caches calls safe_clean for core paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
clean_macos_system_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Saved application states"* ]]
    [[ "$output" == *"QuickLook"* ]]
}

@test "clean_sandboxed_app_caches skips protected containers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
safe_clean() { :; }
should_protect_data() { return 0; }
is_critical_system_component() { return 0; }
files_cleaned=0
total_size_cleaned=0
total_items=0
mkdir -p "$HOME/Library/Containers/com.example.app/Data/Library/Caches"
process_container_cache "$HOME/Library/Containers/com.example.app"
clean_sandboxed_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Sandboxed app caches"* ]]
}

@test "clean_finder_metadata respects protection flag" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PROTECT_FINDER_METADATA=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
note_activity() { :; }
clean_finder_metadata
EOF

    [ "$status" -eq 0 ]
    # Whitelist-protected items no longer show output (UX improvement in V1.22.0)
    [[ "$output" == "" ]]
}

@test "check_ios_device_backups returns when no backup dir" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
check_ios_device_backups
EOF

    [ "$status" -eq 0 ]
}



@test "clean_browsers calls expected cache paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
mkdir -p "$HOME/.cache/puppeteer"
safe_clean() { echo "$2"; }
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Safari cache"* ]]
    [[ "$output" == *"Firefox cache"* ]]
}

@test "clean_puppeteer_cache cleans when cache exists in non-interactive mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
mkdir -p "$HOME/.cache/puppeteer"
echo "test" > "$HOME/.cache/puppeteer/chrome-1234.zip"
safe_clean() { echo "$2"; }
clean_puppeteer_cache
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Puppeteer browser cache"* ]]
}

@test "clean_puppeteer_cache skips when cache does not exist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
rm -rf "$HOME/.cache/puppeteer"
clean_puppeteer_cache
EOF

    [ "$status" -eq 0 ]
    [[ -z "${output//[[:space:]]/}" ]]
}

@test "clean_puppeteer_cache respects DRY_RUN mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
mkdir -p "$HOME/.cache/puppeteer"
echo "test" > "$HOME/.cache/puppeteer/chrome-1234.zip"
note_activity() { :; }
clean_puppeteer_cache
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Puppeteer browser cache"* ]]
    [[ "$output" == *"dry"* ]]
}

@test "clean_application_support_logs skips when no access" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
clean_application_support_logs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped: No permission"* ]]
}

@test "clean_apple_silicon_caches exits when not M-series" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" IS_M_SERIES=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_apple_silicon_caches
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}
