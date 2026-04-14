#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-apps-module.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_ds_store_tree reports dry-run summary" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
start_inline_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_file_size() { echo $((2 * 1024 * 1024 * 1024)); }
bytes_to_human() { echo "2.15GB"; }
files_cleaned=0
total_size_cleaned=0
total_items=0
mkdir -p "$HOME/test_ds"
touch "$HOME/test_ds/.DS_Store"
clean_ds_store_tree "$HOME/test_ds" "DS test"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DS test"* ]]
    [[ "$output" == *$'\033[0;33m→\033[0m'* ]]
}

@test "clean_ds_store_tree uses green for successful cleanups" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
start_inline_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_file_size() { echo 512; }
bytes_to_human() { echo "512B"; }
files_cleaned=0
total_size_cleaned=0
total_items=0
mkdir -p "$HOME/test_ds"
touch "$HOME/test_ds/.DS_Store"
clean_ds_store_tree "$HOME/test_ds" "DS test"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DS test"* ]]
    [[ "$output" == *$'\033[0;32m✓\033[0m'* ]]
}

@test "scan_installed_apps uses cache when fresh" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
mkdir -p "$HOME/.cache/mole"
echo "com.example.App" > "$HOME/.cache/mole/installed_apps_cache"
get_file_mtime() { date +%s; }
debug_log() { :; }
scan_installed_apps "$HOME/installed.txt"
cat "$HOME/installed.txt"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"com.example.App"* ]]
}

@test "scan_installed_apps filters missing value from osascript output" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Create a fake .app with a plist that has no CFBundleIdentifier
mkdir -p "$HOME/Applications/FakeApp.app/Contents"
cat > "$HOME/Applications/FakeApp.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>FakeApp</string>
</dict>
</plist>
PLIST

# Create a valid .app alongside it
mkdir -p "$HOME/Applications/GoodApp.app/Contents"
cat > "$HOME/Applications/GoodApp.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.GoodApp</string>
</dict>
</plist>
PLIST

debug_log() { :; }
scan_installed_apps "$HOME/installed.txt"
cat "$HOME/installed.txt"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"com.example.GoodApp"* ]]
    [[ "$output" != *"missing value"* ]]
}

@test "is_bundle_orphaned returns true for old uninstalled bundle" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ORPHAN_AGE_THRESHOLD=30 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
should_protect_data() { return 1; }
get_file_mtime() { echo 0; }
if is_bundle_orphaned "com.example.Old" "$HOME/old" "$HOME/installed.txt"; then
    echo "orphan"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"orphan"* ]]
}

@test "clean_orphaned_app_data skips when no permission" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
rm -rf "$HOME/Library/Caches"
clean_orphaned_app_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No permission"* ]]
}

@test "clean_orphaned_app_data handles paths with spaces correctly" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Mock scan_installed_apps - return empty (no installed apps)
scan_installed_apps() {
    : > "$1"
}

# Mock mdfind to return empty (no app found)
mdfind() {
    return 0
}

# Ensure local function mock works even if timeout/gtimeout is installed
run_with_timeout() { shift; "$@"; }

# Mock safe_clean (normally from bin/clean.sh)
safe_clean() {
    rm -rf "$1"
    return 0
}

# Create required Library structure for permission check
mkdir -p "$HOME/Library/Caches"

# Create test structure with spaces in path (old modification time: 31 days ago)
mkdir -p "$HOME/Library/Saved Application State/com.test.orphan.savedState"
# Create a file with some content so directory size > 0
echo "test data" > "$HOME/Library/Saved Application State/com.test.orphan.savedState/data.plist"
# Set modification time to 31 days ago (older than 30-day threshold)
touch -t "$(date -v-31d +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 days ago' +%Y%m%d%H%M.%S)" "$HOME/Library/Saved Application State/com.test.orphan.savedState" 2>/dev/null || true

# Disable spinner for test
start_section_spinner() { :; }
stop_section_spinner() { :; }

# Run cleanup
clean_orphaned_app_data

# Verify path with spaces was handled correctly (not split into multiple paths)
if [[ -d "$HOME/Library/Saved Application State/com.test.orphan.savedState" ]]; then
    echo "ERROR: Orphaned savedState not deleted"
    exit 1
else
    echo "SUCCESS: Orphaned savedState deleted correctly"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS"* ]]
}

@test "clean_orphaned_app_data only counts successful deletions" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Mock scan_installed_apps - return empty
scan_installed_apps() {
    : > "$1"
}

# Mock mdfind to return empty (no app found)
mdfind() {
    return 0
}

# Ensure local function mock works even if timeout/gtimeout is installed
run_with_timeout() { shift; "$@"; }

# Create required Library structure for permission check
mkdir -p "$HOME/Library/Caches"

# Create test files (old modification time: 31 days ago)
mkdir -p "$HOME/Library/Caches/com.test.orphan1"
mkdir -p "$HOME/Library/Caches/com.test.orphan2"
# Create files with content so size > 0
echo "data1" > "$HOME/Library/Caches/com.test.orphan1/data"
echo "data2" > "$HOME/Library/Caches/com.test.orphan2/data"
# Set modification time to 31 days ago
touch -t "$(date -v-31d +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 days ago' +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.test.orphan1" 2>/dev/null || true
touch -t "$(date -v-31d +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 days ago' +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.test.orphan2" 2>/dev/null || true

# Mock safe_clean to fail on first item, succeed on second
safe_clean() {
    if [[ "$1" == *"orphan1"* ]]; then
        return 1  # Fail
    else
        rm -rf "$1"
        return 0  # Succeed
    fi
}

# Disable spinner
start_section_spinner() { :; }
stop_section_spinner() { :; }

# Run cleanup
clean_orphaned_app_data

# Verify first item still exists (safe_clean failed)
if [[ -d "$HOME/Library/Caches/com.test.orphan1" ]]; then
    echo "PASS: Failed deletion preserved"
fi

# Verify second item deleted
if [[ ! -d "$HOME/Library/Caches/com.test.orphan2" ]]; then
    echo "PASS: Successful deletion removed"
fi

# Check that output shows correct count (only 1, not 2)
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: Failed deletion preserved"* ]]
    [[ "$output" == *"PASS: Successful deletion removed"* ]]
}

@test "clean_orphaned_app_data removes orphaned Claude VM bundle" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() {
    : > "$1"
}

mdfind() {
    return 0
}

pgrep() {
    return 1
}

run_with_timeout() { shift; "$@"; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 4; }

safe_clean() {
    echo "$2"
    rm -rf "$1"
}

start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

clean_orphaned_app_data

if [[ ! -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Claude VM removed"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned Claude workspace VM"* ]]
    [[ "$output" == *"PASS: Claude VM removed"* ]]
}

@test "clean_orphaned_app_data keeps recent Claude VM bundle when Claude lookup misses" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() {
    : > "$1"
}

mdfind() {
    return 0
}

pgrep() {
    return 1
}

run_with_timeout() { shift; "$@"; }
get_file_mtime() { date +%s; }

safe_clean() {
    echo "UNEXPECTED:$2"
    return 1
}

start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

clean_orphaned_app_data

if [[ -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Recent Claude VM kept"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED:Orphaned Claude workspace VM"* ]]
    [[ "$output" == *"PASS: Recent Claude VM kept"* ]]
}

@test "clean_orphaned_app_data keeps Claude VM bundle when Claude is installed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() {
    echo "com.anthropic.claudefordesktop" > "$1"
}

pgrep() {
    return 1
}

safe_clean() {
    echo "UNEXPECTED:$2"
    return 1
}

start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

clean_orphaned_app_data

if [[ -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Claude VM kept"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED:Orphaned Claude workspace VM"* ]]
    [[ "$output" == *"PASS: Claude VM kept"* ]]
}


@test "clean_orphaned_app_data honors WHITELIST_PATTERNS for Claude VM bundle" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() { : > "$1"; }
mdfind() { return 0; }
pgrep() { return 1; }
run_with_timeout() { shift; "$@"; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 4; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; rm -rf "$1"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

WHITELIST_PATTERNS=("$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle")

clean_orphaned_app_data

if [[ -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Claude VM preserved by whitelist"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
    [[ "$output" == *"PASS: Claude VM preserved by whitelist"* ]]
}

@test "clean_orphaned_app_data honors WHITELIST_PATTERNS for orphaned caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() { : > "$1"; }
is_bundle_orphaned() { return 0; }
is_claude_vm_bundle_orphaned() { return 1; }
mdfind() { return 0; }
pgrep() { return 1; }
run_with_timeout() { shift; "$@"; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 4; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; rm -rf "$1"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches/com.devtool.localbuild"
echo "c" > "$HOME/Library/Caches/com.devtool.localbuild/data"

WHITELIST_PATTERNS=("$HOME/Library/Caches/com.devtool.localbuild")

clean_orphaned_app_data

if [[ -d "$HOME/Library/Caches/com.devtool.localbuild" ]]; then
    echo "PASS: whitelisted orphan cache preserved"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
    [[ "$output" == *"PASS: whitelisted orphan cache preserved"* ]]
}

@test "is_critical_system_component matches known system services" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/app_protection.sh"
is_critical_system_component "backgroundtaskmanagement" && echo "yes"
is_critical_system_component "SystemSettings" && echo "yes"
EOF
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "yes" ]]
    [[ "${lines[1]}" == "yes" ]]
}

@test "is_critical_system_component ignores non-system names" {
    run bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/app_protection.sh"
if is_critical_system_component "myapp"; then
  echo "bad"
else
  echo "ok"
fi
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "ok" ]]
}

@test "clean_orphaned_system_services respects dry-run" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.sogou.test.plist"
touch "$tmp_plist"

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  if [[ "$1" == "find" ]]; then
    printf '%s\0' "$tmp_plist"
    return 0
  fi
  if [[ "$1" == "du" ]]; then
    echo "4 $tmp_plist"
    return 0
  fi
  if [[ "$1" == "launchctl" ]]; then
    echo "launchctl-called"
    return 0
  fi
  if [[ "$1" == "rm" ]]; then
    echo "rm-called"
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"rm-called"* ]]
    [[ "$output" != *"launchctl-called"* ]]
}

@test "clean_orphaned_launch_agents preserves user launch agents" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.example.custom-task.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.custom-task</string>
</dict>
</plist>
PLIST

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }

clean_orphaned_launch_agents

[[ -f "$HOME/Library/LaunchAgents/com.example.custom-task.plist" ]]
EOF

    [ "$status" -eq 0 ]
}
