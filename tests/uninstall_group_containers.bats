#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${BATS_TMPDIR:-}"
    if [[ -z "$ORIGINAL_HOME" ]]; then
        ORIGINAL_HOME="${HOME:-}"
    fi
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-gc-home.XXXXXX")"
    export HOME
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    export TERM="dumb"
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME"
}

@test "find_app_files with app_path discovers TeamID-prefixed Group Containers via codesign" {
    # Create a mock codesign that returns a known Team ID
    local stubdir="$HOME/stubs"
    mkdir -p "$stubdir"
    cat > "$stubdir/codesign" <<'STUB'
#!/bin/bash
echo "TeamIdentifier=FN2V63AD2J"
STUB
    chmod +x "$stubdir/codesign"

    # Create an app bundle for codesign to inspect
    mkdir -p "$HOME/Applications/TestApp.app/Contents"
    cat > "$HOME/Applications/TestApp.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.TestApp</string>
</dict></plist>
PLIST

    # Create Group Containers: one with TeamID prefix, one without, one unrelated
    mkdir -p "$HOME/Library/Group Containers/FN2V63AD2J.com.example"
    mkdir -p "$HOME/Library/Group Containers/group.com.example.TestApp"
    mkdir -p "$HOME/Library/Group Containers/FN2V63AD2J.com.unrelated"

    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.TestApp" "TestApp" "$HOME/Applications/TestApp.app"
EOF
    )"

    # Should find the TeamID-prefixed container via codesign
    [[ "$result" =~ FN2V63AD2J\.com\.example ]]
    # Should also find the bundle-ID-matching container (Tier 1)
    [[ "$result" =~ group\.com\.example\.TestApp ]]
    # Should not include unrelated containers from the same developer Team ID
    [[ ! "$result" =~ FN2V63AD2J\.com\.unrelated ]]
}

@test "find_app_files without app_path falls back to domain prefix matching" {
    # Create a Group Container whose name contains only the domain prefix (not full bundle ID)
    # e.g. FN2V63AD2J.com.tencent where bundle_id is com.tencent.xinWeChat
    mkdir -p "$HOME/Library/Group Containers/FN2V63AD2J.com.tencent"
    mkdir -p "$HOME/Library/Group Containers/group.com.tencent.xinWeChat"

    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
# No app_path (3rd arg empty) — simulates orphan path
find_app_files "com.tencent.xinWeChat" "WeChat" ""
EOF
    )"

    # Should find via domain prefix (com.tencent) fallback
    [[ "$result" =~ FN2V63AD2J\.com\.tencent ]]
    # Should also find the full bundle ID match
    [[ "$result" =~ group\.com\.tencent\.xinWeChat ]]
}

@test "find_app_files tolerates unsigned apps without aborting Group Container scan" {
    local stubdir="$HOME/stubs"
    mkdir -p "$stubdir"
    cat > "$stubdir/codesign" <<'STUB'
#!/bin/bash
echo "code object is not signed at all" >&2
exit 1
STUB
    chmod +x "$stubdir/codesign"

    mkdir -p "$HOME/Applications/TestApp.app/Contents"
    mkdir -p "$HOME/Library/Group Containers/group.com.example.TestApp"

    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.TestApp" "TestApp" "$HOME/Applications/TestApp.app"
EOF
    )"

    [[ "$result" =~ group\.com\.example\.TestApp ]]
}

@test "Group Container deduplication prevents duplicate entries" {
    local stubdir="$HOME/stubs"
    mkdir -p "$stubdir"
    cat > "$stubdir/codesign" <<'STUB'
#!/bin/bash
echo "TeamIdentifier=FN2V63AD2J"
STUB
    chmod +x "$stubdir/codesign"

    mkdir -p "$HOME/Applications/TestApp.app/Contents"
    cat > "$HOME/Applications/TestApp.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.TestApp</string>
</dict></plist>
PLIST

    # Create a Group Container that matches BOTH bundle ID AND Team ID
    # Name: FN2V63AD2J.com.example.TestApp
    # - Tier 1 matches because *com.example.TestApp* is a substring
    # - Tier 2 matches because *FN2V63AD2J* is a substring
    mkdir -p "$HOME/Library/Group Containers/FN2V63AD2J.com.example.TestApp"

    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.TestApp" "TestApp" "$HOME/Applications/TestApp.app"
EOF
    )"

    # Count occurrences of the container path in result
    local count
    count=$(printf '%s\n' "$result" | grep -c "FN2V63AD2J.com.example.TestApp" || true)
    [[ $count -eq 1 ]] || {
        echo "Expected 1 occurrence, got $count"
        exit 1
    }
}

@test "get_diagnostic_report_paths_for_app with empty app_path matches by name prefix" {
    local diag_dir="$HOME/Library/Logs/DiagnosticReports"
    mkdir -p "$diag_dir"

    # Create diagnostic files with app name prefix
    touch "$diag_dir/MyApp.crash"
    touch "$diag_dir/MyApp.diag"
    touch "$diag_dir/MyApp_2026-01-01-120000_host.ips"
    touch "$diag_dir/MyApp-2026-01-01-120000.spin"
    # Unrelated files
    touch "$diag_dir/OtherApp.crash"
    touch "$diag_dir/OtherApp.diag"

    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
get_diagnostic_report_paths_for_app "" "MyApp" "$HOME/Library/Logs/DiagnosticReports"
EOF
    )"

    [[ "$result" =~ MyApp\.crash ]]
    [[ "$result" =~ MyApp\.diag ]]
    [[ "$result" =~ MyApp_2026-01-01-120000_host\.ips ]]
    [[ "$result" =~ MyApp-2026-01-01-120000\.spin ]]
    [[ ! "$result" =~ OtherApp ]]
}

@test "get_diagnostic_report_paths_for_app case-insensitive matching does not over-match" {
    local diag_dir="$HOME/Library/Logs/DiagnosticReports"
    mkdir -p "$diag_dir"

    touch "$diag_dir/Foo.crash"
    touch "$diag_dir/Foo.diag"
    touch "$diag_dir/Foobar.crash"
    touch "$diag_dir/Foobar.diag"

    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
get_diagnostic_report_paths_for_app "" "Foo" "$HOME/Library/Logs/DiagnosticReports"
EOF
    )"

    [[ "$result" =~ Foo\.crash ]]
    [[ "$result" =~ Foo\.diag ]]
    # Must NOT match Foobar (prefix boundary)
    [[ ! "$result" =~ Foobar ]]
}

@test "find_app_files app_path parameter is backward compatible (empty string)" {
    mkdir -p "$HOME/Library/Application Support/TestApp"

    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.TestApp" "TestApp" ""
EOF
    )"

    [[ "$result" =~ Application\ Support/TestApp ]]
}
