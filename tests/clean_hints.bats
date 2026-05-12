#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-hints-home.XXXXXX")"
    export HOME
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/.config/roomy"
}

teardown() {
    rm -rf "$HOME/Library/LaunchAgents"
}

@test "probe_project_artifact_hints reuses purge targets and excludes noisy names" {
    local root="$HOME/hints-root"
    mkdir -p "$root/proj/node_modules" "$root/proj/vendor" "$root/proj/bin"
    touch "$root/proj/package.json"
    printf '%s\n' "$root" > "$HOME/.config/roomy/purge_paths"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOT1'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
run_with_timeout() { shift; "$@"; }
probe_project_artifact_hints
printf 'count=%s\n' "$PROJECT_ARTIFACT_HINT_COUNT"
printf 'examples=%s\n' "${PROJECT_ARTIFACT_HINT_EXAMPLES[*]}"
EOT1

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=1"* ]]
    [[ "$output" == *"node_modules"* ]]
    [[ "$output" != *"vendor"* ]]
    [[ "$output" != *"/bin"* ]]
}

@test "show_project_artifact_hint_notice renders sampled summary" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOT2'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
probe_project_artifact_hints() {
    PROJECT_ARTIFACT_HINT_DETECTED=true
    PROJECT_ARTIFACT_HINT_COUNT=5
    PROJECT_ARTIFACT_HINT_TRUNCATED=true
    PROJECT_ARTIFACT_HINT_EXAMPLES=("~/www/demo/node_modules" "~/www/demo/target")
    PROJECT_ARTIFACT_HINT_ESTIMATED_KB=2048
    PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=2
    PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=false
}
bytes_to_human() { echo "2.00MB"; }
note_activity() { :; }
show_project_artifact_hint_notice
EOT2

    [ "$status" -eq 0 ]
    [[ "$output" == *"5+"* ]]
    [[ "$output" == *"at least 2.00MB sampled from 2 items"* ]]
    [[ "$output" == *"Examples:"* ]]
    [[ "$output" == *"Review: roomy purge"* ]]
}

@test "show_system_data_hint_notice reports large clue paths" {
    mkdir -p "$HOME/Library/Developer/Xcode/DerivedData"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOT3'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
run_with_timeout() {
    shift
    if [[ "${1:-}" == "du" ]]; then
        printf '3145728 %s\n' "${4:-/tmp}"
        return 0
    fi
    "$@"
}
bytes_to_human() { echo "3.00GB"; }
note_activity() { :; }
show_system_data_hint_notice
EOT3

    [ "$status" -eq 0 ]
    [[ "$output" == *"Xcode DerivedData: 3.00GB"* ]]
    [[ "$output" == *"~/Library/Developer/Xcode/DerivedData"* ]]
    [[ "$output" == *"Review: roomy analyze, Device backups, docker system df"* ]]
}

@test "show_user_launch_agent_hint_notice reports missing app-backed target" {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.example.stale.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.stale</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Missing.app/Contents/MacOS/Missing</string>
    </array>
</dict>
</plist>
PLIST

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOT4'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
show_user_launch_agent_hint_notice
EOT4

    [ "$status" -eq 0 ]
    [[ "$output" == *"Potential stale login item: com.example.stale.plist"* ]]
    [[ "$output" == *"Missing app/helper target"* ]]
    [[ "$output" == *"Review: open ~/Library/LaunchAgents"* ]]
}

@test "show_user_launch_agent_hint_notice skips custom shell wrappers" {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.example.custom.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.custom</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>$HOME/bin/custom-task</string>
    </array>
</dict>
</plist>
PLIST

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOT5'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
show_user_launch_agent_hint_notice
EOT5

    [ "$status" -eq 0 ]
    [[ "$output" != *"Potential stale login item:"* ]]
    [[ "$output" != *"Review: open ~/Library/LaunchAgents"* ]]
}

@test "show_user_launch_agent_hint_notice skips MachServices-only plists" {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.google.keystone.agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.google.keystone.agent</string>
    <key>MachServices</key>
    <dict>
        <key>com.google.Keystone.Agent</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOT6'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
show_user_launch_agent_hint_notice
EOT6

    [ "$status" -eq 0 ]
    [[ "$output" != *"Potential stale login item:"* ]]
    [[ "$output" != *"Associated app not found"* ]]
}

# ---- Orphan dotfile hint tests ----

@test "show_orphan_dotdir_hint_notice skips known-safe directories" {
    mkdir -p "$HOME/.ssh" "$HOME/.config" "$HOME/.npm" "$HOME/.cargo" "$HOME/.putty"
    touch -t 202401010000 "$HOME/.ssh" "$HOME/.config" "$HOME/.npm" "$HOME/.cargo" "$HOME/.putty"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" != *"Potential orphan dotfile"* ]]
}

@test "show_orphan_dotdir_hint_notice skips whitelisted directories" {
    mkdir -p "$HOME/.custom-orphan-keep"
    touch -t 202401010000 "$HOME/.custom-orphan-keep"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
WHITELIST_PATTERNS=("$HOME/.custom-orphan-keep")
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" != *".custom-orphan-keep"* ]]
    [[ "$output" != *"Potential orphan dotfile"* ]]
}

@test "show_orphan_dotdir_hint_notice reports dir with no matching binary" {
    mkdir -p "$HOME/.fakecli-test-orphan"
    touch -t 202401010000 "$HOME/.fakecli-test-orphan"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "1024"; }
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" == *"Potential orphan dotfile"* ]]
    [[ "$output" == *".fakecli-test-orphan"* ]]
    [[ "$output" == *"No matching binary in PATH"* ]]
}

@test "show_orphan_dotdir_hint_notice skips dir with existing binary" {
    mkdir -p "$HOME/.bash"
    touch -t 202401010000 "$HOME/.bash"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" != *".bash"* ]]
}

@test "show_orphan_dotdir_hint_notice skips dirs younger than threshold" {
    mkdir -p "$HOME/.youngcli-test"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" != *".youngcli-test"* ]]
}

@test "show_orphan_dotdir_hint_notice limits output to max 5 candidates" {
    for i in $(seq 1 8); do
        mkdir -p "$HOME/.orphantest${i}"
        touch -t 202401010000 "$HOME/.orphantest${i}"
    done

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    local count
    count=$(echo "$output" | grep -c "Potential orphan dotfile" || true)
    [ "$count" -le 5 ]
}
