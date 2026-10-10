#!/usr/bin/env bats

load helpers/common

# Test naming variant detection for find_app_files (Issue #377)

setup_file() {
    mole_test_setup_home naming

    source "$PROJECT_ROOT/lib/core/base.sh"
    source "$PROJECT_ROOT/lib/core/log.sh"
    source "$PROJECT_ROOT/lib/core/app_protection.sh"
}

teardown_file() {
    mole_test_teardown_home
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

@test "find_app_files emits embedded extension leftovers once" {
    local app="$HOME/Applications/Developer.app"
    local widget="$app/Contents/PlugIns/Developer Widget.appex/Contents"
    local app_scripts="$HOME/Library/Application Scripts/developer.apple.wwdc-Release.Developer-Widget"
    local container="$HOME/Library/Containers/developer.apple.wwdc-Release.Developer-Widget"
    mkdir -p "$widget" "$app_scripts" "$container"
    cat > "$widget/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>developer.apple.wwdc-Release.Developer-Widget</string>
</dict></plist>
PLIST

    result=$(
        HOME="$HOME" APP="$app" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "developer.apple.wwdc-Release" "Developer" "$APP"
EOF
    )

    [ "$(printf '%s\n' "$result" | awk -v path="$app_scripts" '$0 == path { count++ } END { print count + 0 }')" -eq 1 ] || return 1
    [ "$(printf '%s\n' "$result" | awk -v path="$container" '$0 == path { count++ } END { print count + 0 }')" -eq 1 ]
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

    [[ "$result" =~ Library/Application\ Support/Code$'\n' ]] || [[ "$result" == *"Library/Application Support/Code"* ]] || return 1
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

@test "find_app_files derives a camel-split data dir from the bundle leaf (AyuGram Desktop)" {
    # tdesktop forks: display name "AyuGram", bundle one.ayugram.AyuGramDesktop,
    # data at "Application Support/AyuGram Desktop". No display-name variant
    # reaches it; the bundle leaf does.
    mkdir -p "$HOME/Library/Application Support/AyuGram Desktop"
    echo "tdata" > "$HOME/Library/Application Support/AyuGram Desktop/settings"

    result=$(find_app_files "one.ayugram.AyuGramDesktop" "AyuGram")

    [[ "$result" =~ "Library/Application Support/AyuGram Desktop" ]] || return 1
}

@test "find_app_files also takes the raw bundle leaf as an exact dir name" {
    mkdir -p "$HOME/Library/Application Support/AyuGramDesktop"
    echo "tdata" > "$HOME/Library/Application Support/AyuGramDesktop/settings"

    result=$(find_app_files "one.ayugram.AyuGramDesktop" "AyuGram")

    [[ "$result" =~ "Library/Application Support/AyuGramDesktop" ]] || return 1
}

@test "bundle-leaf variants need eight characters and a camel transition" {
    # A short or single-word leaf ("app", "desktop", "helper") must derive
    # nothing: exact-path or not, those names collide with unrelated dirs.
    mkdir -p "$HOME/Library/Application Support/app"
    mkdir -p "$HOME/Library/Application Support/desktop"
    mkdir -p "$HOME/Library/Application Support/Whatsapp"

    result=$(find_app_files "com.example.app" "Example")
    [[ "$result" != *"Application Support/app"* ]] || return 1

    result=$(find_app_files "com.example.desktop" "Example")
    [[ "$result" != *"Application Support/desktop"* ]] || return 1

    # 8+ chars but no lower-to-upper transition: no derivation either.
    result=$(find_app_files "com.example.Whatsapp" "Example")
    [[ "$result" != *"Application Support/Whatsapp"* ]] || return 1
}

@test "bundle-leaf variants stay quiet when the leaf equals the display name" {
    # When leaf and display name agree, the ordinary app-name patterns
    # already cover the dir; the derivation must not add anything, and an
    # invalid bundle id must never reach the derivation at all.
    mkdir -p "$HOME/Library/Application Support/CamelCaseApp"

    result=$(find_app_files "com.example.CamelCaseApp" "CamelCaseApp")
    [[ "$result" =~ "Application Support/CamelCaseApp" ]] || return 1

    result=$(find_app_files "unknown" "Other")
    [[ "$result" != *"CamelCaseApp"* ]] || return 1
}

@test "bundle-leaf variants refuse a leaf that does not extend the display name" {
    # Safety review collision classes: a wrapper or fork whose bundle leaf
    # names ANOTHER product must derive nothing, even though the leaf clears
    # every size floor. The dirs exist here, so a miss is a real exclusion.
    mkdir -p "$HOME/Library/Application Support/Google Chrome"
    mkdir -p "$HOME/Library/Application Support/GoogleChrome"
    mkdir -p "$HOME/Library/Application Support/Telegram Desktop"
    mkdir -p "$HOME/Library/Application Support/AddressBook"
    mkdir -p "$HOME/Library/Application Support/AyuGram Desktop"

    result=$(find_app_files "com.wrapper.GoogleChrome" "My Chrome SSB")
    [[ "$result" != *"Google Chrome"* ]] || return 1
    [[ "$result" != *"GoogleChrome"* ]] || return 1

    result=$(find_app_files "org.acmefork.TelegramDesktop" "64Gram")
    [[ "$result" != *"Telegram Desktop"* ]] || return 1

    result=$(find_app_files "com.acme.AddressBook" "Acme Contacts Sync")
    [[ "$result" != *"Application Support/AddressBook"* ]] || return 1

    # Positive control in the same world: the leaf that extends its own
    # display name still derives, so the negatives above are not vacuous.
    result=$(find_app_files "one.ayugram.AyuGramDesktop" "AyuGram")
    [[ "$result" =~ "Application Support/AyuGram Desktop" ]] || return 1
}

@test "find_app_files adds PlayCover's exact per-app files and alias, never PlayChain (#1715)" {
    local root="$HOME/Library/Containers/io.playcover.PlayCover"
    local bundle="$root/Applications/fit.mole.probe.app"
    mkdir -p "$bundle" "$root/App Settings" "$root/Keymapping" "$root/Entitlements" \
        "$root/PlayChain" "$HOME/Applications/PlayCover/Mole Probe.app" \
        "$HOME/Applications/PlayCover/Other.app"
    printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>fit.mole.probe</string></dict></plist>' > "$bundle/Info.plist"
    : > "$bundle/MoleProbe"
    ln -s "$bundle/Info.plist" "$HOME/Applications/PlayCover/Mole Probe.app/Info.plist"
    ln -s "$bundle/MoleProbe" "$HOME/Applications/PlayCover/Mole Probe.app/MoleProbe"
    # Points at the bundle, but holds a real file too: not a PlayCover alias.
    ln -s "$bundle/Info.plist" "$HOME/Applications/PlayCover/Other.app/Info.plist"
    : > "$HOME/Applications/PlayCover/Other.app/Notes.txt"
    local f
    for f in "App Settings/fit.mole.probe.plist" "Keymapping/fit.mole.probe.plist" \
        "Entitlements/fit.mole.probe.plist" "PlayChain/fit.mole.probe" \
        "PlayChain/fit.mole.probe.keyCover" "App Settings/fit.mole.probe.other.plist"; do
        : > "$root/$f"
    done

    result=$(find_app_files "fit.mole.probe" "Mole Probe" "$bundle")

    [[ "$result" == *"$root/App Settings/fit.mole.probe.plist"* ]] || return 1
    [[ "$result" == *"$root/Keymapping/fit.mole.probe.plist"* ]] || return 1
    [[ "$result" == *"$root/Entitlements/fit.mole.probe.plist"* ]] || return 1
    [[ "$result" == *"$HOME/Applications/PlayCover/Mole Probe.app"* ]] || return 1
    [[ "$result" != *"PlayChain"* ]] || return 1
    [[ "$result" != *"fit.mole.probe.other.plist"* ]] || return 1
    [[ "$result" != *"Other.app"* ]] || return 1

    # The same bundle id from any other app path gets none of these.
    result=$(find_app_files "fit.mole.probe" "Mole Probe" "$HOME/Applications/Mole Probe.app")
    [[ "$result" != *"io.playcover.PlayCover"* ]] || return 1
    [[ "$result" != *"Applications/PlayCover"* ]]
}

@test "force_kill_app matches a PlayCover bundle by its executable, not its display name (#1715)" {
    local bundle="$HOME/Library/Containers/io.playcover.PlayCover/Applications/fit.mole.probe.app"
    mkdir -p "$bundle"
    printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>fit.mole.probe</string><key>CFBundleExecutable</key><string>MoleProbe</string></dict></plist>' > "$bundle/Info.plist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/log.sh"
source "$PROJECT_ROOT/lib/core/app_protection.sh"
# force_kill_app silences pgrep, so the stub records its arguments in a file.
pgrep() { echo "PGREP:$*" >> "$HOME/pgrep.log"; return 1; }
force_kill_app "Mole Probe" "$HOME/Library/Containers/io.playcover.PlayCover/Applications/fit.mole.probe.app"
cat "$HOME/pgrep.log"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"PGREP:-x MoleProbe"* ]] || return 1
    [[ "$output" != *"PGREP:-x Mole Probe"* ]]
}
