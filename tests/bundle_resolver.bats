#!/usr/bin/env bats

# Tests for lib/core/bundle_resolver.sh. Validates the filesystem-fallback path:
# we cannot rely on Spotlight indexing a fake /Applications under a tmpdir,
# so each test forces the Spotlight path to miss (no binary or empty result)
# and asserts the filesystem scan finds the app.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    FAKE_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-bundle-home.XXXXXX")"
    export FAKE_HOME
    mkdir -p "$FAKE_HOME/Applications"

    # Stage a fake /Applications tree inside the tmp area. bundle_has_installed_app
    # hardcodes the real /Applications roots, so we patch _MOLE_BUNDLE_RESOLVER_APP_ROOTS
    # from the test harness itself.
    FAKE_APPS="$FAKE_HOME/FakeApplications"
    export FAKE_APPS
    mkdir -p "$FAKE_APPS"
}

teardown() {
    rm -rf "$FAKE_HOME"
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

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
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

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.adobe.ARMDC.SMJobBlessHelper"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app returns non-zero when no app declares the bundle ID" {
    make_app "$FAKE_APPS/SomeoneElse.app" "com.example.someone"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.ghost.app"
EOF

    [ "$status" -ne 0 ]
}

@test "bundle_has_installed_app finds parent app via .helper suffix (issue #753)" {
    make_app "$FAKE_APPS/AlDente Pro.app" "com.apphousekitchen.aldente-pro"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.apphousekitchen.aldente-pro.helper"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app finds parent app via .daemon suffix" {
    make_app "$FAKE_APPS/Example.app" "com.example.myapp"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.example.myapp.daemon"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app returns non-zero for .helper when parent app absent" {
    make_app "$FAKE_APPS/Other.app" "com.example.other"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.apphousekitchen.aldente-pro.helper"
EOF

    [ "$status" -ne 0 ]
}

@test "bundle_has_installed_app rejects malformed bundle IDs" {
    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "has spaces"
EOF

    [ "$status" -ne 0 ]
}

@test "bundle_has_installed_app finds Microsoft Office helper via explicit mapping (issue #776)" {
    # Microsoft Office helpers don't follow parent.helper naming:
    # com.microsoft.autoupdate.helper should match Office apps only.
    make_app "$FAKE_APPS/Microsoft Word.app" "com.microsoft.Word"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.microsoft.autoupdate.helper"
EOF

    [ "$status" -eq 0 ]
}

@test "bundle_has_installed_app does not use broad Microsoft vendor prefix" {
    make_app "$FAKE_APPS/Microsoft Teams.app" "com.microsoft.teams2"

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
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

    run env FAKE_APPS="$FAKE_APPS" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<EOF
$(prelude)
bundle_has_installed_app "com.example.unmapped.id"
EOF

    # Exit 1 = not found (expected). Exit 2+ or crash = unbound variable bug.
    [ "$status" -eq 1 ]
}
