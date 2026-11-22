#!/usr/bin/env bats

load helpers/common

# Tests for lib/core/bundle_resolver.sh. Validates the filesystem-fallback path:
# we cannot rely on Spotlight indexing a fake /Applications under a tmpdir,
# so each test forces the Spotlight path to miss (no binary or empty result)
# and asserts the filesystem scan finds the app.

setup_file() {
    mole_test_setup_project_root
}

setup() {
    FAKE_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-bundle-home.XXXXXX")"
    export FAKE_HOME
    # Safety: refuse to operate if mktemp failed.
    if [[ "$FAKE_HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: FAKE_HOME is not a test temp dir: %s\n' "$FAKE_HOME" >&2
        return 1
    fi
    mkdir -p "$FAKE_HOME/Applications"
    # The prelude's mdfind function never reaches run_with_timeout, which hands
    # the command to gtimeout; a PATH double makes the Spotlight miss real.
    mole_test_fake_command mdfind

    # Stage a fake /Applications tree inside the tmp area. bundle_has_installed_app
    # hardcodes the real /Applications roots, so we patch _MOLE_BUNDLE_RESOLVER_APP_ROOTS
    # from the test harness itself.
    FAKE_APPS="$FAKE_HOME/FakeApplications"
    export FAKE_APPS
    mkdir -p "$FAKE_APPS"
}

teardown() {
    if [[ "$FAKE_HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$FAKE_HOME"
    fi
}

# Shared prelude: source base + resolver, disable mdfind, point resolver at FAKE_APPS.
prelude() {
    cat <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/timeout.sh"
source "$PROJECT_ROOT/lib/core/bundle_resolver.sh"

# Force Spotlight miss so we test only the filesystem fallback.
mdfind() { return 0; }
export -f mdfind

# Override the hardcoded app roots for the test.
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
EOF
}

make_app() {
    local app_dir="$1"
    local bundle_id="$2"
    mkdir -p "$app_dir/Contents"
    cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
</dict>
</plist>
EOF
}

@test "bundle_has_installed_app finds an app by CFBundleIdentifier (Spotlight miss)" {
    make_app "$FAKE_APPS/KeePassXC.app" "org.keepassxc.KeePassXC"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "org.keepassxc.KeePassXC"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app reads a flat bundle with its plist at the bundle root (#2044)" {
    local app="$FAKE_APPS/NetBird UI.app"
    make_app "$app" io.netbird.client
    mv "$app/Contents/Info.plist" "$app/Info.plist"
    rmdir "$app/Contents"
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string netbird-ui" "$app/Info.plist"
    printf '#!/bin/sh\n' > "$app/netbird-ui"
    chmod +x "$app/netbird-ui"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "io.netbird.client"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app finds a mixed-case app bundle suffix" {
    make_app "$FAKE_APPS/KeePassXC.APP" "org.keepassxc.KeePassXC"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "org.keepassxc.KeePassXC"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app falls back after run_with_timeout returns 124 (set -e + pipefail regression)" {
    # Regression for the flake that blocked PR #770: under `set -euo pipefail`,
    # `hit=$(run_with_timeout ... | head -1)` inside a command substitution
    # killed the shell when run_with_timeout exited 124 on timeout. Forcing the
    # timeout path here proves the filesystem fallback still executes.
    make_app "$FAKE_APPS/KeePassXC.app" "org.keepassxc.KeePassXC"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/timeout.sh"
source "$PROJECT_ROOT/lib/core/bundle_resolver.sh"

# Make Spotlight appear available but force the timeout path to return 124.
mdfind() { return 0; }
export -f mdfind
run_with_timeout() { return 124; }
export -f run_with_timeout

_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")

bundle_has_installed_app "org.keepassxc.KeePassXC"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app finds an SMJobBless privileged helper inside a parent app" {
    # Simulate Adobe Acrobat DC shipping its ARMDC helper at
    # Contents/Library/LaunchServices/com.adobe.ARMDC.SMJobBlessHelper.
    local app="$FAKE_APPS/Adobe Acrobat DC.app"
    make_app "$app" "com.adobe.Acrobat.Pro"
    mkdir -p "$app/Contents/Library/LaunchServices"
    : > "$app/Contents/Library/LaunchServices/com.adobe.ARMDC.SMJobBlessHelper"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.adobe.ARMDC.SMJobBlessHelper"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app returns non-zero when no app declares the bundle ID" {
    make_app "$FAKE_APPS/SomeoneElse.app" "com.example.someone"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.ghost.app"
EOF

    [ "$status" -ne 0 ]
}

@test "bundle_has_installed_app finds parent app via .helper suffix (issue #753)" {
    make_app "$FAKE_APPS/AlDente Pro.app" "com.apphousekitchen.aldente-pro"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.apphousekitchen.aldente-pro.helper"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app finds parent app via capitalized .Helper suffix (issue #1210)" {
    make_app "$FAKE_APPS/App Tamer.app" "com.stclairsoft.AppTamer"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.stclairsoft.AppTamer.Helper"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app matches CFBundleIdentifier case-insensitively" {
    make_app "$FAKE_APPS/Example.app" "com.Example.MyApp"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.example.myapp"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app finds parent app via .daemon suffix" {
    make_app "$FAKE_APPS/Example.app" "com.example.myapp"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.example.myapp.daemon"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app finds parent app via .service suffix" {
    make_app "$FAKE_APPS/Clash Verge.app" "io.github.clash-verge-rev.clash-verge-rev"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "io.github.clash-verge-rev.clash-verge-rev.service"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app returns non-zero for .helper when parent app absent" {
    make_app "$FAKE_APPS/Other.app" "com.example.other"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.apphousekitchen.aldente-pro.helper"
EOF

    [ "$status" -ne 0 ]
}

@test "bundle_has_installed_app rejects malformed bundle IDs" {
    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "has spaces"
EOF

    [ "$status" -ne 0 ]
}

@test "bundle_has_installed_app finds Microsoft Office helper via explicit mapping (issue #776)" {
    # Microsoft Office helpers don't follow parent.helper naming:
    # com.microsoft.autoupdate.helper should match Office apps only.
    make_app "$FAKE_APPS/Microsoft Word.app" "com.microsoft.Word"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.microsoft.autoupdate.helper"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app does not use broad Microsoft vendor prefix" {
    make_app "$FAKE_APPS/Microsoft Teams.app" "com.microsoft.teams2"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.microsoft.some.other.helper"
EOF

    [ "$status" -ne 0 ]
}

@test "bundle_has_installed_app handles empty mapped_app_bundles under set -u" {
    # Regression: bash 3.2 with set -u raises "unbound variable" when iterating
    # over an empty array. Non-Microsoft bundle IDs leave mapped_app_bundles=().
    make_app "$FAKE_APPS/SomeApp.app" "com.example.someapp"
    make_app "$FAKE_APPS/AnotherApp.app" "com.example.otherapp"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.example.unmapped.id"
EOF

    # Exit 1 = not found (expected). Exit 2+ or crash = unbound variable bug.
    [ "$status" -eq 1 ]
}

@test "bundle_has_installed_app bounds its direct fallback with the caller deadline" {
    make_app "$FAKE_APPS/Deadline.app" "com.example.deadline"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
bundle_has_installed_app "com.example.deadline" "$((SECONDS + 5))"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app fails closed when its bounded app scan times out" {
    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
run_with_timeout() {
    local _duration="$1"
    shift
    if [[ "${1:-}" == "/usr/bin/find" ]]; then
        return 124
    fi
    "$@"
}
bundle_has_installed_app "com.example.unknown" "$((SECONDS + 5))"
EOF

    # Returning success means "installed or unknown" to orphan detection.
    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app fails closed when a bounded plist probe times out" {
    make_app "$FAKE_APPS/Unknown.app" "com.example.some-app"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
run_with_timeout() {
    local _duration="$1"
    shift
    if [[ "${1:-}" == "plutil" ]]; then
        return 124
    fi
    "$@"
}
bundle_has_installed_app "com.example.unknown" "$((SECONDS + 5))"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app propagates an interrupted Spotlight probe" {
    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
run_with_timeout() { return 130; }
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
rc=0
bundle_has_installed_app "com.example.interrupted" "$((SECONDS + 5))" || rc=$?
printf 'RC=%s\n' "$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]]
}

@test "bundle_has_installed_app propagates an interrupted direct app scan" {
    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
run_with_timeout() {
    local _duration="$1"
    shift
    case "${1:-}" in
        mdfind) return 124 ;;
        /usr/bin/find) return 130 ;;
        *) "$@" ;;
    esac
}
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
rc=0
bundle_has_installed_app "com.example.interrupted" "$((SECONDS + 5))" || rc=$?
printf 'RC=%s\n' "$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]]
}

@test "bundle_has_installed_app propagates an interrupted direct plist probe" {
    make_app "$FAKE_APPS/Interrupted.app" "com.example.some-app"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
run_with_timeout() {
    local _duration="$1"
    shift
    case "${1:-}" in
        mdfind) return 124 ;;
        plutil) return 130 ;;
        *) "$@" ;;
    esac
}
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
rc=0
bundle_has_installed_app "com.example.interrupted" "$((SECONDS + 5))" || rc=$?
printf 'RC=%s\n' "$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]]
}

@test "bundle_has_installed_app keeps a helper whose app root sits behind a folder it cannot search" {
    [[ ${EUID:-$(id -u)} -ne 0 ]] || skip "root searches every folder"
    make_app "$FAKE_APPS/SomeoneElse.app" "com.example.someone"
    mkdir -p "$FAKE_HOME/locked/Apps"
    : > "$FAKE_HOME/plainfile"

    run env FAKE_APPS="$FAKE_APPS" FAKE_HOME="$FAKE_HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
# Proven gone (ENOENT, ENOTDIR): the scan is complete and finds no app.
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS" "$FAKE_HOME/no-such-root" "$FAKE_HOME/plainfile/Apps")
rc=0
bundle_has_installed_app "com.example.orphanprobe.helper" "$((SECONDS + 5))" || rc=$?
echo "COMPLETE=$rc"
chmod 000 "$FAKE_HOME/locked"
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS" "$FAKE_HOME/locked/Apps")
rc=0
bundle_has_installed_app "com.example.orphanprobe.helper" "$((SECONDS + 5))" || rc=$?
chmod 755 "$FAKE_HOME/locked"
echo "UNSEARCHABLE=$rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"COMPLETE=1"* ]] || return 1
    # The parent app may be in the root nobody could look into.
    [[ "$output" == *"UNSEARCHABLE=0"* ]] || return 1
}

@test "bundle_has_installed_app covers nested Homebrew Caskroom apps" {
    local cask_root="$HOME/Caskroom"
    make_app "$cask_root/example/1.2.3/Example.app" "com.example.caskroom"

    run env CASK_ROOT="$cask_root" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mdfind() { return 0; }
export -f mdfind
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$CASK_ROOT")
bundle_has_installed_app "com.example.caskroom" "$((SECONDS + 5))"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app asks Spotlight for a helper's parent id too" {
    # A helper's app installed outside every scanned root answers Spotlight
    # only to its own id, so com.example.thing.helper must also ask for
    # com.example.thing.
    # shellcheck disable=SC2016  # The mdfind stub expands its own arguments.
    mole_test_fake_command mdfind 'case "$1" in
    *"== '"'"'com.example.thing'"'"'c"*) echo "/Users/someone/Downloads/Thing.app" ;;
esac'
    run env HOME="$FAKE_HOME" FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/timeout.sh"
source "$PROJECT_ROOT/lib/core/bundle_resolver.sh"
_MOLE_BUNDLE_RESOLVER_APP_ROOTS=("$FAKE_APPS")
rc=0
bundle_has_installed_app "com.example.thing.helper" || rc=$?
echo "RC:$rc"
rc=0
bundle_has_installed_app "com.example.other.helper" || rc=$?
echo "OTHER:$rc"
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC:0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"OTHER:1"* ]] || { echo "$output"; return 1; }
}

@test "mole_spotlight_answers_bundle_queries needs Finder in Spotlight's answer" {
    local answer
    for answer in finder empty fail; do
        case "$answer" in
            finder)
                # shellcheck disable=SC2016  # The mdfind stub expands its own arguments.
                mole_test_fake_command mdfind '[ "$1" = -onlyin ] && [ "$2" = /System/Library/CoreServices ] && echo /System/Library/CoreServices/Finder.app'
                ;;
            empty) mole_test_fake_command mdfind 'exit 0' ;;
            fail) mole_test_fake_command mdfind 'echo /System/Library/CoreServices/Finder.app; exit 1' ;;
        esac
        run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/timeout.sh"
source "$PROJECT_ROOT/lib/core/bundle_resolver.sh"
rc=0
mole_spotlight_answers_bundle_queries || rc=$?
echo "RC:$rc"
EOF
        [ "$status" -eq 0 ] || { echo "$answer: $output"; return 1; }
        if [[ "$answer" == finder ]]; then
            [[ "$output" == *"RC:0"* ]] || { echo "$answer: $output"; return 1; }
        else
            [[ "$output" == *"RC:1"* ]] || { echo "$answer: $output"; return 1; }
        fi
    done
}
