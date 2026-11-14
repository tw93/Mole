#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home browser-cleanup

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    mole_test_teardown_home
}

@test "clean_chrome_old_versions skips when Chrome is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

versions_dir="$HOME/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
    mkdir -p "$versions_dir/128.0.0.0" "$versions_dir/129.0.0.0"
    ln -s "129.0.0.0" "$versions_dir/Current"
touch "$versions_dir/128.0.0.0/sentinel"
# Adding the sentinel updates the old directory mtime. Pin both directories so
# a wall-clock second boundary cannot make the old version look like a newer
# staged update under parallel test load.
touch -t 202401010000 "$versions_dir/128.0.0.0"
touch -t 202402010000 "$versions_dir/129.0.0.0"
export MOLE_CHROME_APP_PATHS="$HOME/Applications/Google Chrome.app"

# Mock pgrep to simulate Chrome running
pgrep() { return 0; }
export -f pgrep
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
defer_cleanup_family() { echo "DEFER:$1"; }

clean_chrome_old_versions
[[ -f "$versions_dir/128.0.0.0/sentinel" ]] || exit 1
rm -rf "$HOME/Applications/Google Chrome.app"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEFER:Chrome"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"Chrome old versions · skipped"* ]]
}

@test "clean_chrome_old_versions does not defer protected-only versions" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
versions_dir="$HOME/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
old="$versions_dir/128.0.0.0"
mkdir -p "$old" "$versions_dir/129.0.0.0"
ln -s "129.0.0.0" "$versions_dir/Current"
export MOLE_CHROME_APP_PATHS="$HOME/Applications/Google Chrome.app"
should_protect_path() { [[ "$1" == "$old" ]]; }
is_path_whitelisted() { return 1; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_chrome_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_chrome_old_versions skips when only Chrome helpers are running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

versions_dir="$HOME/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
    mkdir -p "$versions_dir/128.0.0.0" "$versions_dir/129.0.0.0"
    ln -s "129.0.0.0" "$versions_dir/Current"
touch "$versions_dir/128.0.0.0/sentinel"
touch -t 202401010000 "$versions_dir/128.0.0.0"
touch -t 202402010000 "$versions_dir/129.0.0.0"
export MOLE_CHROME_APP_PATHS="$HOME/Applications/Google Chrome.app"

pgrep() {
    case "$*" in
        *"Google Chrome Helper"*) return 0 ;;
        *) return 1 ;;
    esac
}
export -f pgrep
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
defer_cleanup_family() { echo "DEFER:$1"; }

clean_chrome_old_versions
[[ -f "$versions_dir/128.0.0.0/sentinel" ]] || exit 1
rm -rf "$HOME/Applications/Google Chrome.app"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEFER:Chrome"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"Chrome old versions · skipped"* ]]
}

@test "clean_chrome_old_versions fails closed when the process probe errors" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

versions_dir="$HOME/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$versions_dir/128.0.0.0" "$versions_dir/129.0.0.0"
ln -s "129.0.0.0" "$versions_dir/Current"
touch "$versions_dir/128.0.0.0/sentinel"
touch -t 202401010000 "$versions_dir/128.0.0.0"
touch -t 202402010000 "$versions_dir/129.0.0.0"
export MOLE_CHROME_APP_PATHS="$HOME/Applications/Google Chrome.app"
pgrep() { return 2; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }

clean_chrome_old_versions
[[ -f "$versions_dir/128.0.0.0/sentinel" ]] || exit 1
rm -rf "$HOME/Applications/Google Chrome.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Chrome old versions · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_chrome_old_versions counts only successful removals" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

versions_dir="$HOME/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
rm -rf "$HOME/Applications/Google Chrome.app"
mkdir -p "$versions_dir/127.0.0.0" "$versions_dir/128.0.0.0" "$versions_dir/130.0.0.0"
touch -t 202601010000 "$versions_dir/127.0.0.0"
touch -t 202602010000 "$versions_dir/128.0.0.0"
touch -t 202603010000 "$versions_dir/130.0.0.0"
ln -s "130.0.0.0" "$versions_dir/Current"
export MOLE_CHROME_APP_PATHS="$HOME/Applications/Google Chrome.app"

pgrep() { return 1; }
has_sudo_session() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 10; }
bytes_to_human() { echo "$1 bytes"; }
note_activity() { :; }
debug_log() { :; }

files_cleaned=0
total_size_cleaned=0
total_items=0
safe_remove() { return 1; }
clean_chrome_old_versions
echo "ALL_FAILED:$files_cleaned:$total_size_cleaned"

files_cleaned=0
total_size_cleaned=0
total_items=0
safe_remove() { [[ "$1" == *"127.0.0.0" ]]; }
clean_chrome_old_versions
echo "PARTIAL:$files_cleaned:$total_size_cleaned"
rm -rf "$HOME/Applications/Google Chrome.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"ALL_FAILED:0:0"* ]] || return 1
    [[ "$output" == *"PARTIAL:1:10"* ]] || return 1
    [[ "$output" == *"Chrome old versions"*"1 dir,"* ]]
}

@test "clean_chrome_old_versions removes old versions but keeps current" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Mock pgrep to simulate Chrome not running
pgrep() { return 1; }
export -f pgrep

# Create mock Chrome directory structure
CHROME_APP="$HOME/Applications/Google Chrome.app"
VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0,130.0.0.0}
export MOLE_CHROME_APP_PATHS="$CHROME_APP"

# Create Current symlink pointing to 130.0.0.0
ln -s "130.0.0.0" "$VERSIONS_DIR/Current"

# Mock functions
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

# Initialize counters
files_cleaned=0
total_size_cleaned=0
total_items=0

clean_chrome_old_versions

# Verify output mentions old versions cleanup
echo "Cleaned: $files_cleaned items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Chrome old versions"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"Cleaned: 2 items"* ]]
}

@test "clean_chrome_old_versions respects whitelist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Mock pgrep to simulate Chrome not running
pgrep() { return 1; }
export -f pgrep

# Create mock Chrome directory structure
CHROME_APP="$HOME/Applications/Google Chrome.app"
VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0,130.0.0.0}
export MOLE_CHROME_APP_PATHS="$CHROME_APP"

# Create Current symlink pointing to 130.0.0.0
ln -s "130.0.0.0" "$VERSIONS_DIR/Current"

# Mock is_path_whitelisted to protect version 128.0.0.0
is_path_whitelisted() {
    [[ "$1" == *"128.0.0.0"* ]] && return 0
    return 1
}
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

# Initialize counters
files_cleaned=0
total_size_cleaned=0
total_items=0

clean_chrome_old_versions

# Should only clean 129.0.0.0 (not 128.0.0.0 which is whitelisted)
echo "Cleaned: $files_cleaned items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 1 items"* ]]
}

@test "clean_chrome_old_versions keeps newest version even when Current points older" {
    rm -rf "$HOME/Applications/Google Chrome.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
export -f pgrep

CHROME_APP="$HOME/Applications/Google Chrome.app"
VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0,130.0.0.0}
export MOLE_CHROME_APP_PATHS="$CHROME_APP"
touch -t 202601010000 "$VERSIONS_DIR/128.0.0.0"
touch -t 202602010000 "$VERSIONS_DIR/129.0.0.0"
touch -t 202603010000 "$VERSIONS_DIR/130.0.0.0"
ln -s "129.0.0.0" "$VERSIONS_DIR/Current"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_chrome_old_versions
echo "Cleaned: $files_cleaned items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned: 1 items"* ]]
}

@test "clean_edge_old_versions keeps newest version even when Current points older" {
    rm -rf "$HOME/Applications/Microsoft Edge.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
export -f pgrep

EDGE_APP="$HOME/Applications/Microsoft Edge.app"
VERSIONS_DIR="$EDGE_APP/Contents/Frameworks/Microsoft Edge Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0,130.0.0.0}
export MOLE_EDGE_APP_PATHS="$EDGE_APP"
touch -t 202601010000 "$VERSIONS_DIR/128.0.0.0"
touch -t 202602010000 "$VERSIONS_DIR/129.0.0.0"
touch -t 202603010000 "$VERSIONS_DIR/130.0.0.0"
ln -s "129.0.0.0" "$VERSIONS_DIR/Current"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_old_versions
echo "Cleaned: $files_cleaned items"
EOF

    # HOME is shared across tests in this file; leave a clean slate for the
    # later "removes old versions" test that reuses this app path.
    rm -rf "$HOME/Applications/Microsoft Edge.app"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    # 130 is a freshly staged update newer than Current (129); only 128 goes.
    [[ "$output" == *"Cleaned: 1 items"* ]] || {
        echo "$output"
        return 1
    }
}

@test "clean_brave_old_versions keeps newest version even when Current points older" {
    rm -rf "$HOME/Applications/Brave Browser.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
export -f pgrep

BRAVE_APP="$HOME/Applications/Brave Browser.app"
VERSIONS_DIR="$BRAVE_APP/Contents/Frameworks/Brave Browser Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0,130.0.0.0}
export MOLE_BRAVE_APP_PATHS="$BRAVE_APP"
touch -t 202601010000 "$VERSIONS_DIR/128.0.0.0"
touch -t 202602010000 "$VERSIONS_DIR/129.0.0.0"
touch -t 202603010000 "$VERSIONS_DIR/130.0.0.0"
ln -s "129.0.0.0" "$VERSIONS_DIR/Current"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_brave_old_versions
echo "Cleaned: $files_cleaned items"
EOF

    rm -rf "$HOME/Applications/Brave Browser.app"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Cleaned: 1 items"* ]] || {
        echo "$output"
        return 1
    }
}

@test "clean_edge_updater_old_versions keeps latest version" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
# No readable installed-Edge version: pins the conservative keep-latest
# fallback even on machines where a real Edge is installed.
plutil() { return 1; }
export -f pgrep plutil

UPDATER_DIR="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
mkdir -p "$UPDATER_DIR"/{117.0.2045.60,118.0.2088.46,119.0.2108.9}

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_updater_old_versions

echo "Cleaned: $files_cleaned items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Edge updater old versions"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"Cleaned: 2 items"* ]]
}

@test "clean_chrome_old_versions dry run rechecks the browser after sizing" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
versions_dir="$HOME/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$versions_dir/128.0.0.0" "$versions_dir/129.0.0.0"
ln -s "129.0.0.0" "$versions_dir/Current"
export MOLE_CHROME_APP_PATHS="$HOME/Applications/Google Chrome.app"
pgrep() { [[ -e "$HOME/chrome-started" ]]; }
get_path_size_kb() { touch "$HOME/chrome-started"; echo 10; }
record_dry_run_cleanup_target() { echo "UNEXPECTED_RECORD:$1"; }
defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_chrome_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Chrome"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_RECORD"* ]]
}

@test "clean_edge_updater_old_versions does not defer protected-only versions" {
    run env HOME="$HOME/edge-protected-only" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
updater_dir="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
old="$updater_dir/117.0"
mkdir -p "$old" "$updater_dir/118.0"
plutil() { return 1; }
should_protect_path() { [[ "$1" == "$old" ]]; }
is_path_whitelisted() { return 1; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_edge_updater_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_edge_updater_old_versions counts only successful removals" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

updater_dir="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
edge_app="$HOME/Applications/Microsoft Edge.app"
rm -rf "$updater_dir" "$edge_app"
mkdir -p "$updater_dir/117.0" "$updater_dir/118.0" "$edge_app/Contents"
touch "$edge_app/Contents/Info.plist"

pgrep() { return 1; }
plutil() { echo "120.0"; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo 10; }
bytes_to_human() { echo "$1 bytes"; }
note_activity() { :; }
debug_log() { :; }

files_cleaned=0
total_size_cleaned=0
total_items=0
safe_remove() { return 1; }
clean_edge_updater_old_versions
echo "ALL_FAILED:$files_cleaned:$total_size_cleaned"

files_cleaned=0
total_size_cleaned=0
total_items=0
safe_remove() { [[ "$1" == *"117.0" ]]; }
clean_edge_updater_old_versions
echo "PARTIAL:$files_cleaned:$total_size_cleaned"
rm -rf "$updater_dir" "$edge_app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"ALL_FAILED:0:0"* ]] || return 1
    [[ "$output" == *"PARTIAL:1:10"* ]] || return 1
    [[ "$output" == *"Edge updater old versions"*"1 dir,"* ]]
}

# Issue #1216: after Edge updates itself, the updater staging dir can hold a
# single payload that is OLDER than the installed Edge. The keep-latest rule
# kept that stale copy forever because it was the only directory.
@test "clean_edge_updater_old_versions removes a lone payload older than installed Edge (#1216)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
plutil() { echo "150.0.4078.65"; }
export -f pgrep plutil
mkdir -p "$HOME/Applications/Microsoft Edge.app/Contents"
touch "$HOME/Applications/Microsoft Edge.app/Contents/Info.plist"

UPDATER_DIR="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
rm -rf "$UPDATER_DIR"
mkdir -p "$UPDATER_DIR/149.0.4022.52"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_updater_old_versions
echo "Cleaned: $files_cleaned items"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Edge updater old versions"* ]] || return 1
    [[ "$output" == *"Cleaned: 1 items"* ]] || return 1
}

@test "clean_edge_updater_old_versions keeps payloads not older than installed Edge" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
plutil() { echo "150.0.4078.65"; }
export -f pgrep plutil
mkdir -p "$HOME/Applications/Microsoft Edge.app/Contents"
touch "$HOME/Applications/Microsoft Edge.app/Contents/Info.plist"

UPDATER_DIR="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
rm -rf "$UPDATER_DIR"
# One stale, one equal to installed, one staged-newer pending update.
mkdir -p "$UPDATER_DIR"/{149.0.4022.52,150.0.4078.65,151.0.5000.1}

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_updater_old_versions
echo "Cleaned: $files_cleaned items"
[[ -d "$UPDATER_DIR/150.0.4078.65" ]] && echo "KEPT-EQUAL"
[[ -d "$UPDATER_DIR/151.0.5000.1" ]] && echo "KEPT-NEWER"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Cleaned: 1 items"* ]] || return 1
    [[ "$output" == *"KEPT-EQUAL"* ]] || return 1
    [[ "$output" == *"KEPT-NEWER"* ]] || return 1
}

@test "clean_edge_updater_old_versions keeps a lone payload when installed version is unknown" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
plutil() { return 1; }
export -f pgrep plutil

UPDATER_DIR="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
rm -rf "$UPDATER_DIR"
mkdir -p "$UPDATER_DIR/149.0.4022.52"

is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_updater_old_versions
echo "Cleaned: $files_cleaned items"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Cleaned: 0 items"* ]] || return 1
}

@test "clean_chrome_old_versions DRY_RUN mode does not delete files" {
    # Create test directory
    CHROME_APP="$HOME/Applications/Google Chrome.app"
    VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
    mkdir -p "$VERSIONS_DIR"/{128.0.0.0,130.0.0.0}
    export MOLE_CHROME_APP_PATHS="$CHROME_APP"

    # Remove Current if it exists as a directory, then create symlink
    rm -rf "$VERSIONS_DIR/Current"
    ln -s "130.0.0.0" "$VERSIONS_DIR/Current"

    # Create a marker file in old version
    touch "$VERSIONS_DIR/128.0.0.0/marker.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f pgrep is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_chrome_old_versions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"dry"* ]] || return 1
    # Verify marker file still exists (not deleted in dry run)
    [ -f "$VERSIONS_DIR/128.0.0.0/marker.txt" ]
}

@test "clean_chrome_old_versions handles missing Current symlink gracefully" {
    # Use a fresh temp directory for this test
    TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-test5.XXXXXX")"

    run env HOME="$TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f pgrep is_path_whitelisted get_path_size_kb bytes_to_human note_activity

# Initialize counters to prevent unbound variable errors
files_cleaned=0
total_size_cleaned=0
total_items=0

# Create Chrome app without Current symlink
CHROME_APP="$HOME/Applications/Google Chrome.app"
VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0}
export MOLE_CHROME_APP_PATHS="$CHROME_APP"
# No Current symlink created

clean_chrome_old_versions
EOF

    rm -rf "$TEST_HOME"
    [ "$status" -eq 0 ]
    # Should exit gracefully with no output
}

@test "clean_edge_old_versions skips when Edge is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

versions_dir="$HOME/Applications/Microsoft Edge.app/Contents/Frameworks/Microsoft Edge Framework.framework/Versions"
    mkdir -p "$versions_dir/120.0.0.0" "$versions_dir/121.0.0.0"
    ln -s "121.0.0.0" "$versions_dir/Current"
touch "$versions_dir/120.0.0.0/sentinel"
touch -t 202401010000 "$versions_dir/120.0.0.0"
touch -t 202402010000 "$versions_dir/121.0.0.0"
export MOLE_EDGE_APP_PATHS="$HOME/Applications/Microsoft Edge.app"

# Mock pgrep to simulate Edge running
pgrep() { return 0; }
export -f pgrep
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
defer_cleanup_family() { echo "DEFER:$1"; }

clean_edge_old_versions
[[ -f "$versions_dir/120.0.0.0/sentinel" ]] || exit 1
rm -rf "$HOME/Applications/Microsoft Edge.app"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEFER:Edge"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ "$output" != *"Edge old versions · skipped"* ]]
}

@test "clean_edge_old_versions removes old versions but keeps current" {
    # Create mock Edge directory structure
    local EDGE_APP="$HOME/Applications/Microsoft Edge.app"
    local VERSIONS_DIR="$EDGE_APP/Contents/Frameworks/Microsoft Edge Framework.framework/Versions"
    mkdir -p "$VERSIONS_DIR"/{120.0.0.0,121.0.0.0,122.0.0.0}
    ln -s "122.0.0.0" "$VERSIONS_DIR/Current"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true \
        MOLE_EDGE_APP_PATHS="$EDGE_APP" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f pgrep is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_old_versions

echo "Cleaned: $files_cleaned items"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Edge old versions"* ]] || return 1
    [[ "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"Cleaned: 2 items"* ]]
}

@test "clean_edge_old_versions handles no old versions gracefully" {
    # Use a fresh temp directory for this test
    TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-test8.XXXXXX")"

    # Create Edge with only current version
    local EDGE_APP="$TEST_HOME/Applications/Microsoft Edge.app"
    local VERSIONS_DIR="$EDGE_APP/Contents/Frameworks/Microsoft Edge Framework.framework/Versions"
    mkdir -p "$VERSIONS_DIR/122.0.0.0"
    ln -s "122.0.0.0" "$VERSIONS_DIR/Current"

    run env HOME="$TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_EDGE_APP_PATHS="$EDGE_APP" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f pgrep is_path_whitelisted get_path_size_kb bytes_to_human note_activity

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_old_versions
EOF

    rm -rf "$TEST_HOME"
    [ "$status" -eq 0 ]
    # Should exit gracefully with no cleanup output
    [[ "$output" != *"Edge old versions"* ]]
}

@test "browser cleanup stops after an old-version size timeout" {
    local isolated_home="$HOME/browser-aggregate-timeout"
    mkdir -p "$isolated_home"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_CURRENT_COMMAND=clean /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { :; }
clean_service_worker_cache() { :; }
pgrep() { return 1; }
clean_chrome_old_versions() {
    _mole_record_clean_cancellation 124
    return 124
}
clean_edge_old_versions() { echo "UNEXPECTED_EDGE_CLEAN"; }
set +e
clean_browsers
rc=$?
set -e
printf 'BROWSER_RC:%s CANCEL:%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"BROWSER_RC:124 CANCEL:124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_EDGE_CLEAN"* ]]
}

@test "old browser and updater cleanup continues on non-signal size failure and stops on signal" {
    local target size_rc case_home want_timeouts want_known
    for target in chrome edge_updater; do
        for size_rc in 1 124 130; do
            case_home="$BATS_TEST_TMPDIR/browser-size-$target-$size_rc"
            mkdir -p "$case_home"

            run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" TARGET="$target" SIZE_RC="$size_rc" \
                DRY_RUN=true MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 MOLE_CLEAN_SIZING_TIMEOUTS=0 \
                /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 1; }
plutil() { return 1; }
is_path_whitelisted() { return 1; }
note_activity() { :; }
debug_log() { :; }
get_path_size_kb() {
    if [[ "$1" == *"117.0"* ]]; then
        return "$SIZE_RC"
    fi
    echo 10
}
record_dry_run_cleanup_target() {
    printf '%s|%s\n' "$1" "$4" >> "$HOME/preview"
}
files_cleaned=0
total_size_cleaned=0
total_items=0
rc=0
if [[ "$TARGET" == "chrome" ]]; then
    versions_dir="$HOME/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
    mkdir -p "$versions_dir/117.0" "$versions_dir/118.0" "$versions_dir/119.0"
    ln -s "119.0" "$versions_dir/Current"
    touch -t 202401010000 "$versions_dir/117.0" "$versions_dir/118.0"
    touch -t 202402010000 "$versions_dir/119.0"
    export MOLE_CHROME_APP_PATHS="$HOME/Applications/Google Chrome.app"
    clean_chrome_old_versions || rc=$?
else
    updater_dir="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
    mkdir -p "$updater_dir/117.0" "$updater_dir/118.0" "$updater_dir/119.0"
    clean_edge_updater_old_versions || rc=$?
fi
printf 'RC=%s CANCEL=%s TIMEOUTS=%s CLEANED=%s\n' "$rc" "${MOLE_CLEAN_CANCEL_STATUS:-0}" "${MOLE_CLEAN_SIZING_TIMEOUTS:-0}" "$files_cleaned"
EOF

            [ "$status" -eq 0 ] || { echo "$target/$size_rc: $output"; return 1; }
            if [[ "$size_rc" -eq 130 ]]; then
                [[ "$output" == *"RC=130 CANCEL=130"* ]] || { echo "$output"; return 1; }
                [[ "$output" == *"CLEANED=0"* ]] || { echo "$output"; return 1; }
                [ ! -e "$case_home/preview" ] || return 1
            else
                want_timeouts=0
                want_known=true
                if [[ "$size_rc" -eq 124 ]]; then
                    want_timeouts=1
                    want_known=false
                fi
                [[ "$output" == *"RC=0 CANCEL=0 TIMEOUTS=$want_timeouts"* ]] || { echo "$output"; return 1; }
                [[ "$output" == *"CLEANED=2"* ]] || { echo "$output"; return 1; }
                grep -q "117.0|$want_known$" "$case_home/preview" || return 1
                grep -q "118.0|true$" "$case_home/preview" || return 1
            fi
        done
    done
}
