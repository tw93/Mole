#!/usr/bin/env bats
# Test naming variant detection for find_app_files (Issue #377)

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-naming.XXXXXX")"
    export HOME

    source "$PROJECT_ROOT/lib/core/base.sh"
    source "$PROJECT_ROOT/lib/core/log.sh"
    source "$PROJECT_ROOT/lib/core/app_protection.sh"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    export HOME="$ORIGINAL_HOME"
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    find "$HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2> /dev/null || true
    source "$PROJECT_ROOT/lib/core/base.sh"
    source "$PROJECT_ROOT/lib/core/log.sh"
    source "$PROJECT_ROOT/lib/core/app_protection.sh"
}

@test "find_app_files detects lowercase-hyphen variant (maestro-studio)" {
    mkdir -p "$HOME/.config/maestro-studio"
    echo "test" > "$HOME/.config/maestro-studio/config.json"

    result=$(find_app_files "com.maestro.studio" "Maestro Studio")

    [[ "$result" =~ .config/maestro-studio ]]
}

@test "find_app_files detects no-space variant (MaestroStudio)" {
    mkdir -p "$HOME/Library/Application Support/MaestroStudio"
    echo "test" > "$HOME/Library/Application Support/MaestroStudio/data.db"

    result=$(find_app_files "com.maestro.studio" "Maestro Studio")

    [[ "$result" =~ "Library/Application Support/MaestroStudio" ]]
}

@test "find_app_files detects Maestro Studio auth directory (.mobiledev)" {
    mkdir -p "$HOME/.mobiledev"
    echo "token" > "$HOME/.mobiledev/authtoken"

    result=$(find_app_files "com.maestro.studio" "Maestro Studio")

    [[ "$result" =~ .mobiledev ]]
}

@test "find_app_files extracts base name from version suffix (Zed Nightly -> zed)" {
    mkdir -p "$HOME/.config/zed"
    mkdir -p "$HOME/Library/Application Support/Zed"
    echo "test" > "$HOME/.config/zed/settings.json"
    echo "test" > "$HOME/Library/Application Support/Zed/cache.db"

    result=$(find_app_files "dev.zed.Zed-Nightly" "Zed Nightly")

    [[ "$result" =~ .config/zed ]] || return 1
    [[ "$result" =~ "Library/Application Support/Zed" ]]
}

@test "find_app_files detects Zed channel variants in HTTPStorages only" {
    mkdir -p "$HOME/Library/HTTPStorages/dev.zed.Zed-Preview"
    mkdir -p "$HOME/Library/Application Support/Firefox/Profiles/default/storage/default/https+++zed.dev"
    echo "test" > "$HOME/Library/HTTPStorages/dev.zed.Zed-Preview/data"
    echo "test" > "$HOME/Library/Application Support/Firefox/Profiles/default/storage/default/https+++zed.dev/data"

    result=$(find_app_files "dev.zed.Zed-Nightly" "Zed Nightly")

    [[ "$result" =~ Library/HTTPStorages/dev\.zed\.Zed-Preview ]] || return 1
    [[ ! "$result" =~ storage/default/https\+\+\+zed\.dev ]]
}

@test "find_app_files detects multiple naming variants simultaneously" {
    mkdir -p "$HOME/.config/maestro-studio"
    mkdir -p "$HOME/.cache/maestro-studio"
    mkdir -p "$HOME/Library/Application Support/MaestroStudio"
    mkdir -p "$HOME/Library/Application Support/Maestro-Studio"
    mkdir -p "$HOME/Library/Preferences"
    mkdir -p "$HOME/Library/Saved Application State/MaestroStudio.savedState"
    mkdir -p "$HOME/.local/share/maestrostudio"

    echo "test" > "$HOME/.config/maestro-studio/config.json"
    echo "test" > "$HOME/.cache/maestro-studio/cache.db"
    echo "test" > "$HOME/Library/Application Support/MaestroStudio/data.db"
    echo "test" > "$HOME/Library/Application Support/Maestro-Studio/prefs.json"
    echo "test" > "$HOME/Library/Preferences/Maestro-Studio.plist"
    echo "test" > "$HOME/.local/share/maestrostudio/cache.db"

    result=$(find_app_files "com.maestro.studio" "Maestro Studio")

    [[ "$result" =~ .config/maestro-studio ]] || return 1
    [[ "$result" =~ .cache/maestro-studio ]] || return 1
    [[ "$result" =~ "Library/Application Support/MaestroStudio" ]] || return 1
    [[ "$result" =~ "Library/Application Support/Maestro-Studio" ]] || return 1
    [[ "$result" =~ Library/Preferences/Maestro-Studio\.plist ]] || return 1
    [[ "$result" =~ Library/Saved\ Application\ State/MaestroStudio\.savedState ]] || return 1
    [[ "$result" =~ .local/share/maestrostudio ]]
}

@test "find_app_files handles multi-word version suffix (Firefox Developer Edition)" {
    mkdir -p "$HOME/.local/share/firefox"
    echo "test" > "$HOME/.local/share/firefox/profiles.ini"

    result=$(find_app_files "org.mozilla.firefoxdeveloperedition" "Firefox Developer Edition")

    [[ "$result" =~ .local/share/firefox ]]
}

@test "find_app_files detects bundle-id-derived extension leftovers" {
    mkdir -p "$HOME/Library/Application Support/FileProvider/com.tencent.xinWeChat.WeChatFileProviderExtension"
    mkdir -p "$HOME/Library/Application Scripts/com.tencent.xinWeChat.WeChatMacShare"
    mkdir -p "$HOME/Library/Application Scripts/5A4RE8SF68.com.tencent.xinWeChat"
    mkdir -p "$HOME/Library/Containers/com.tencent.xinWeChat.WeChatFileProviderExtension"
    mkdir -p "$HOME/Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat"
    mkdir -p "$HOME/Library/Containers/com.tencent.otherapp.Helper"

    result=$(find_app_files "com.tencent.xinWeChat" "WeChat")

    [[ "$result" =~ Library/Application\ Support/FileProvider/com.tencent.xinWeChat.WeChatFileProviderExtension ]] || return 1
    [[ "$result" =~ Library/Application\ Scripts/com.tencent.xinWeChat.WeChatMacShare ]] || return 1
    [[ "$result" =~ Library/Application\ Scripts/5A4RE8SF68.com.tencent.xinWeChat ]] || return 1
    [[ "$result" =~ Library/Containers/com.tencent.xinWeChat.WeChatFileProviderExtension ]] || return 1
    [[ "$result" =~ Library/Group\ Containers/5A4RE8SF68.com.tencent.xinWeChat ]] || return 1
    [[ ! "$result" =~ Library/Containers/com.tencent.otherapp.Helper ]]
}

@test "find_app_files handles the first derived bundle match under bash 3.2 set -u" {
    mkdir -p "$HOME/Library/Containers/com.example.Widget.Helper"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/log.sh"
source "$PROJECT_ROOT/lib/core/app_protection.sh"
find_app_files "com.example.Widget" "Widget"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Library/Containers/com.example.Widget.Helper"* ]] || return 1
    [[ "$output" != *"unbound variable"* ]]
}

@test "find_app_files detects vendor-nested Application Support directories" {
    mkdir -p "$HOME/Library/Application Support/Avid/Sibelius"
    mkdir -p "$HOME/Library/Application Support/OtherVendor/Sibelius"
    echo "test" > "$HOME/Library/Application Support/Avid/Sibelius/settings.db"
    echo "test" > "$HOME/Library/Application Support/OtherVendor/Sibelius/settings.db"

    result=$(find_app_files "com.avid.sibelius" "Sibelius")

    [[ "$result" =~ Library/Application\ Support/Avid/Sibelius ]] || return 1
    [[ ! "$result" =~ Library/Application\ Support/OtherVendor/Sibelius ]]
}

@test "find_app_files does not match empty app name" {
    mkdir -p "$HOME/Library/Application Support/test"
    mkdir -p "$HOME/Library/Preferences"
    mkdir -p "$HOME/.config" "$HOME/.cache" "$HOME/.local/share"

    result=$(find_app_files "com.test" "" 2> /dev/null || true)

    [[ ! "$result" =~ "Library/Application Support"$ ]] || return 1
    [[ ! "$result" =~ "Library/Preferences"$ ]] || return 1
    [[ ! "$result" =~ "$HOME/."$ ]] || return 1
    [[ ! "$result" =~ ".config"$ ]] || return 1
    [[ ! "$result" =~ ".cache"$ ]] || return 1
    [[ ! "$result" =~ ".local/share"$ ]]
}

# Regression: with an invalid bundle id AND an empty app name, no pattern
# block fires, leaving user_patterns empty. macOS /bin/bash 3.2 under set -u
# treats expanding an empty array as an unbound variable, so the scan must
# use the +-guard idiom instead of crashing.
@test "find_app_files survives empty pattern list under bash 3.2 set -u" {
    run /bin/bash -c "set -u
source '$PROJECT_ROOT/lib/core/base.sh'
source '$PROJECT_ROOT/lib/core/log.sh'
source '$PROJECT_ROOT/lib/core/app_protection.sh'
find_app_files 'invalid_bundle' ''"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"unbound variable"* ]] || return 1
}

@test "find_app_files detects VS Code stable Application Support folder (#850)" {
    mkdir -p "$HOME/Library/Application Support/Code"
    mkdir -p "$HOME/Library/Application Support/Code - Insiders"
    mkdir -p "$HOME/.vscode"

    result=$(find_app_files "com.microsoft.VSCode" "Visual Studio Code")

    [[ "$result" =~ Library/Application\ Support/Code$'\n' ]] || [[ "$result" == *"Library/Application Support/Code"* ]]
    [[ "$result" == *"/.vscode"* ]] || return 1
    [[ "$result" != *"Code - Insiders"* ]]
}

@test "find_app_files detects VS Code Insiders Application Support folder (#850)" {
    mkdir -p "$HOME/Library/Application Support/Code"
    mkdir -p "$HOME/Library/Application Support/Code - Insiders"
    mkdir -p "$HOME/.vscode-insiders"

    result=$(find_app_files "com.microsoft.VSCodeInsiders" "Visual Studio Code - Insiders")

    [[ "$result" == *"Library/Application Support/Code - Insiders"* ]] || return 1
    [[ "$result" == *"/.vscode-insiders"* ]] || return 1
    [[ ! "$result" =~ Library/Application\ Support/Code$'\n' ]]
}

@test "find_app_files detects Anki support files but preserves user profile data (#1145)" {
    mkdir -p "$HOME/Library/Application Support/Anki2"
    mkdir -p "$HOME/Library/Application Support/AnkiProgramFiles"

    result=$(find_app_files "net.ankiweb.anki" "Anki")

    [[ "$result" != *"Library/Application Support/Anki2"* ]] || return 1
    [[ "$result" == *"Library/Application Support/AnkiProgramFiles"* ]]
}

# Independent CLI dotdir protection, issue #993.
# Uninstalling a GUI app named "Claude" / "OpenCode" / etc. must not delete
# the same-named standalone CLI tool's state directory.

@test "find_app_files preserves ~/.claude when uninstalling Claude.app (#993)" {
    mkdir -p "$HOME/.claude/projects"
    mkdir -p "$HOME/Library/Application Support/Claude"
    echo "memory" > "$HOME/.claude/projects/sample"

    result=$(find_app_files "com.anthropic.claudefordesktop" "Claude")

    [[ "$result" == *"Library/Application Support/Claude"* ]] || return 1
    [[ "$result" != *"$HOME/.claude"* ]] || return 1
    [[ "$result" != *"$HOME/.Claude"* ]]
}

@test "find_app_files preserves ~/.local/share/opencode when uninstalling OpenCode.app (#993)" {
    mkdir -p "$HOME/.local/share/opencode/snapshot"
    mkdir -p "$HOME/.config/opencode"
    mkdir -p "$HOME/.opencode"
    mkdir -p "$HOME/Library/Application Support/opencode"

    result=$(find_app_files "ai.opencode.desktop" "opencode")

    [[ "$result" == *"Library/Application Support/opencode"* ]] || return 1
    [[ "$result" != *".local/share/opencode"* ]] || return 1
    [[ "$result" != *".config/opencode"* ]] || return 1
    [[ "$result" != *"$HOME/.opencode"* ]]
}

@test "find_app_files preserves ~/.codex when uninstalling Codex.app (#993)" {
    mkdir -p "$HOME/.codex"
    mkdir -p "$HOME/.config/codex"
    mkdir -p "$HOME/Library/Application Support/Codex"

    result=$(find_app_files "com.openai.codex" "Codex")

    [[ "$result" == *"Library/Application Support/Codex"* ]] || return 1
    [[ "$result" != *"$HOME/.codex"* ]] || return 1
    [[ "$result" != *".config/codex"* ]]
}

@test "find_app_files still removes Zed XDG state (independent-CLI list must not over-protect)" {
    # Sanity check that the deny-list does not break legitimate GUI-app XDG
    # cleanup added for #377. Zed is a GUI app that owns ~/.config/zed and
    # ~/.local/share/zed and must still be picked up on uninstall.
    mkdir -p "$HOME/.config/zed"
    mkdir -p "$HOME/.local/share/zed"

    result=$(find_app_files "dev.zed.Zed-Nightly" "Zed Nightly")

    [[ "$result" == *".config/zed"* ]] || [[ "$result" == *".local/share/zed"* ]]
}

@test "find_app_files keeps Raycast v2 data when uninstalling Raycast v1 (#1202)" {
    # Raycast v2 is a separate app (com.raycast-x.macos); the v1 "*raycast*"
    # sweeps must not collect any of its directories.
    mkdir -p "$HOME/Library/Application Support/com.raycast.macos"
    mkdir -p "$HOME/Library/Application Support/com.raycast-x.macos"
    mkdir -p "$HOME/Library/Containers/com.raycast.macos"
    mkdir -p "$HOME/Library/Containers/com.raycast-x.macos"
    mkdir -p "$HOME/Library/Caches/com.raycast.macos"
    mkdir -p "$HOME/Library/Caches/Raycast-X"
    mkdir -p "$HOME/Library/Application Support/Code/User/globalStorage/raycast-x.raycast"

    result=$(find_app_files "com.raycast.macos" "Raycast")

    [[ "$result" == *"Application Support/com.raycast.macos"* ]] || return 1
    [[ "$result" == *"Containers/com.raycast.macos"* ]] || return 1
    [[ "$result" == *"Caches/com.raycast.macos"* ]] || return 1
    [[ "$result" != *"com.raycast-x.macos"* ]] || return 1
    [[ "$result" != *"Caches/Raycast-X"* ]] || return 1
    [[ "$result" != *"raycast-x.raycast"* ]] || return 1
}
