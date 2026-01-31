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
safe_clean() { echo "$2"; }
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Safari cache"* ]]
    [[ "$output" == *"Firefox cache"* ]]
    [[ "$output" == *"Puppeteer browser cache"* ]]
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

@test "clean_user_essentials includes dotfiles in Trash cleanup" {
    mkdir -p "$HOME/.Trash"
    touch "$HOME/.Trash/.hidden_file"
    touch "$HOME/.Trash/.DS_Store"
    touch "$HOME/.Trash/regular_file.txt"
    mkdir -p "$HOME/.Trash/.hidden_dir"
    mkdir -p "$HOME/.Trash/regular_dir"

    run bash <<'EOF'
set -euo pipefail
count=0
while IFS= read -r -d '' item; do
    ((count++)) || true
    echo "FOUND: $(basename "$item")"
done < <(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
echo "COUNT: $count"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT: 5"* ]]
    [[ "$output" == *"FOUND: .hidden_file"* ]]
    [[ "$output" == *"FOUND: .DS_Store"* ]]
    [[ "$output" == *"FOUND: .hidden_dir"* ]]
    [[ "$output" == *"FOUND: regular_file.txt"* ]]
}
