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
    rm -rf "${HOME:?}"/.[!.]* "${HOME:?}"/..?* 2> /dev/null || true
    mkdir -p "$HOME/.config/mole"
}

teardown() {
    rm -rf "$HOME/Library/LaunchAgents"
}

@test "probe_project_artifact_hints reuses purge targets and excludes noisy names" {
    local root="$HOME/hints-root"
    mkdir -p "$root/proj/node_modules" "$root/proj/vendor" "$root/proj/bin"
    touch "$root/proj/package.json"
    printf '%s\n' "$root" > "$HOME/.config/mole/purge_paths"

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
    [[ "$output" == *"Review: mo purge"* ]]
}

@test "show_project_artifact_hint_notice points zero-size samples to include-empty (#869)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOT2B'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
probe_project_artifact_hints() {
    PROJECT_ARTIFACT_HINT_DETECTED=true
    PROJECT_ARTIFACT_HINT_COUNT=1
    PROJECT_ARTIFACT_HINT_TRUNCATED=false
    PROJECT_ARTIFACT_HINT_EXAMPLES=("~/www/demo/node_modules")
    PROJECT_ARTIFACT_HINT_ESTIMATED_KB=0
    PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES=1
    PROJECT_ARTIFACT_HINT_ESTIMATE_PARTIAL=false
}
bytes_to_human() { echo "0B"; }
note_activity() { :; }
show_project_artifact_hint_notice
EOT2B

    [ "$status" -eq 0 ]
    [[ "$output" == *"sampled 0B"* ]]
    [[ "$output" == *"Review: mo purge --include-empty"* ]]
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
    [[ "$output" == *"Review: mo analyze, Device backups, docker system df"* ]]
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

@test "show_orphan_dotdir_hint_notice skips dotdir owned by installed GUI app (#872)" {
    mkdir -p "$HOME/.bridge"
    touch -t 202401010000 "$HOME/.bridge"

    local app_path="$HOME/Applications/Proton Mail Bridge.app"
    mkdir -p "$app_path/Contents"
    cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ch.protonmail.bridge</string>
    <key>CFBundleName</key>
    <string>Proton Mail Bridge</string>
</dict>
</plist>
PLIST

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
    [[ "$output" != *".bridge"* ]]
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

@test "show_orphan_dotdir_hint_notice skips dotdir whose name matches an installed .app token (#872)" {
    mkdir -p "$HOME/.bridge"
    touch -t 202401010000 "$HOME/.bridge"

    local fake_apps_root="$HOME/fake-Applications"
    mkdir -p "$fake_apps_root/Proton Mail Bridge.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" FAKE_APPS_ROOT="$fake_apps_root" \
        bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
brew() { return 0; }
export -f brew
_MOLE_DOTDIR_OWNER_APP_ROOTS=("$FAKE_APPS_ROOT")
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" != *".bridge"* ]]
    [[ "$output" != *"Potential orphan dotfile"* ]]
}

@test "show_orphan_dotdir_hint_notice skips dotdir whose name matches a brew cask token (#872)" {
    mkdir -p "$HOME/.bridge"
    touch -t 202401010000 "$HOME/.bridge"

    local empty_apps_root="$HOME/empty-Applications"
    mkdir -p "$empty_apps_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" EMPTY_APPS_ROOT="$empty_apps_root" \
        bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
brew() {
    if [[ "${1:-}" == "list" && "${2:-}" == "--cask" ]]; then
        printf '%s\n' "proton-mail-bridge" "1password"
        return 0
    fi
    return 0
}
export -f brew
_MOLE_DOTDIR_OWNER_APP_ROOTS=("$EMPTY_APPS_ROOT")
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" != *".bridge"* ]]
    [[ "$output" != *"Potential orphan dotfile"* ]]
}

@test "show_orphan_dotdir_hint_notice still flags dotdir whose name has no matching app or cask (#872)" {
    mkdir -p "$HOME/.fakeorphan42xyz"
    touch -t 202401010000 "$HOME/.fakeorphan42xyz"

    local empty_apps_root="$HOME/empty-Applications2"
    mkdir -p "$empty_apps_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" EMPTY_APPS_ROOT="$empty_apps_root" \
        bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
brew() {
    if [[ "${1:-}" == "list" && "${2:-}" == "--cask" ]]; then
        printf '%s\n' "1password" "rectangle"
        return 0
    fi
    return 0
}
export -f brew
_MOLE_DOTDIR_OWNER_APP_ROOTS=("$EMPTY_APPS_ROOT")
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" == *"Potential orphan dotfile"* ]]
    [[ "$output" == *".fakeorphan42xyz"* ]]
}

@test "show_orphan_dotdir_hint_notice ignores short app-name tokens (<4 chars) to avoid false matches (#872)" {
    # `.ai-old` — token `ai` is 2 chars; an `AI.app` should NOT exempt it.
    mkdir -p "$HOME/.ai-old"
    touch -t 202401010000 "$HOME/.ai-old"

    local fake_apps_root="$HOME/fake-Applications-short"
    mkdir -p "$fake_apps_root/AI.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" FAKE_APPS_ROOT="$fake_apps_root" \
        bash --noprofile --norc <<'EOTD'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
hint_get_path_size_kb_with_timeout() { echo "100"; }
brew() { return 0; }
export -f brew
_MOLE_DOTDIR_OWNER_APP_ROOTS=("$FAKE_APPS_ROOT")
show_orphan_dotdir_hint_notice
EOTD

    [ "$status" -eq 0 ]
    [[ "$output" == *"Potential orphan dotfile"* ]]
    [[ "$output" == *".ai-old"* ]]
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
