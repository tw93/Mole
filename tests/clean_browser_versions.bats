#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-browser-cleanup.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
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
    [[ "$output" == *"Chrome old versions"*"1 dirs"* ]]
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
    [[ "$output" == *"Edge updater old versions"*"1 dirs"* ]]
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

# Chrome extension version fixtures. An extension id is 32 letters a-p; each
# version dir gets a file so sizing sees real bytes.
CHROME_EXT_A="fcoeoabgfenejglbffodgkkbkcdhcgfn"
CHROME_EXT_B="aaaabbbbccccddddeeeeffffgggghhhh"
CHROME_EXT_C="hhhhggggffffeeeeddddccccbbbbaaaa"

_chrome_ext_versions() {
    local profile="$1" id="$2"
    shift 2
    local version
    for version in "$@"; do
        mkdir -p "$profile/Extensions/$id/$version"
        echo "{}" > "$profile/Extensions/$id/$version/manifest.json"
    done
}

# Branded Chrome shape: Preferences parses but has no extensions.settings; the
# references live in Secure Preferences. Extension A is loaded at 1.0.91 with
# 1.0.93 waiting for idle (the shape seen on a real Mac). Extension B is loaded
# at 9.0 beside 10.0, so "highest" must compare numerically. Extension C waits
# to install 3.0 while an unreferenced 4.0 is highest, so the idle reference is
# the only thing keeping 3.0. Planned targets: B/8.0_0, A/1.0.92_0, C/1.0_0.
_chrome_ext_profile() {
    local profile="$1"
    _chrome_ext_versions "$profile" "$CHROME_EXT_A" 1.0.91_0 1.0.92_0 1.0.93_0
    _chrome_ext_versions "$profile" "$CHROME_EXT_B" 8.0_0 9.0_0 10.0_0
    _chrome_ext_versions "$profile" "$CHROME_EXT_C" 1.0_0 2.0_0 3.0_0 4.0_0
    printf '{"profile":{"name":"fixture"}}' > "$profile/Preferences"
    printf '{"extensions":{"settings":{"%s":{"path":"%s/1.0.91_0","idle_install_info":{"path":"%s/1.0.93_0"}},"%s":{"path":"%s/9.0_0"},"%s":{"path":"%s/2.0_0","idle_install_info":{"path":"%s/3.0_0"}}}}}' \
        "$CHROME_EXT_A" "$CHROME_EXT_A" "$CHROME_EXT_A" "$CHROME_EXT_B" "$CHROME_EXT_B" \
        "$CHROME_EXT_C" "$CHROME_EXT_C" "$CHROME_EXT_C" > "$profile/Secure Preferences"
}

@test "clean_chrome_extension_old_versions keeps loaded, idle-install, and highest versions" {
    local case_home="$HOME/chrome-ext-keep-set"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"
    _chrome_ext_profile "$profile"
    mkdir -p "$profile/Extensions/Temp/unpacking"
    touch "$profile/Extensions/$CHROME_EXT_A/stray.txt"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_chrome_extension_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Chrome old extension versions"* ]] || return 1
    [[ ! -e "$profile/Extensions/$CHROME_EXT_A/1.0.92_0" ]] || return 1
    [[ ! -e "$profile/Extensions/$CHROME_EXT_B/8.0_0" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_A/1.0.91_0/manifest.json" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_A/1.0.93_0/manifest.json" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_B/9.0_0/manifest.json" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_B/10.0_0/manifest.json" ]] || return 1
    [[ ! -e "$profile/Extensions/$CHROME_EXT_C/1.0_0" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_C/2.0_0/manifest.json" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_C/3.0_0/manifest.json" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_C/4.0_0/manifest.json" ]] || return 1
    [[ -f "$profile/Extensions/$CHROME_EXT_A/stray.txt" ]] || return 1
    [[ -d "$profile/Extensions/Temp/unpacking" ]]
}

@test "clean_chrome_extension_old_versions merges references from both prefs files" {
    local case_home="$HOME/chrome-ext-split-prefs"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"
    _chrome_ext_versions "$profile" "$CHROME_EXT_C" 1.0_0 2.0_0 3.0_0 4.0_0
    printf '{"extensions":{"settings":{"%s":{"path":"%s/2.0_0"}}}}' \
        "$CHROME_EXT_C" "$CHROME_EXT_C" > "$profile/Preferences"
    printf '{"extensions":{"settings":{"%s":{"idle_install_info":{"path":"%s/3.0_0"}}}}}' \
        "$CHROME_EXT_C" "$CHROME_EXT_C" > "$profile/Secure Preferences"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_chrome_extension_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ ! -e "$profile/Extensions/$CHROME_EXT_C/1.0_0" ]] || return 1
    [[ -d "$profile/Extensions/$CHROME_EXT_C/2.0_0" ]] || return 1
    [[ -d "$profile/Extensions/$CHROME_EXT_C/3.0_0" ]] || return 1
    [[ -d "$profile/Extensions/$CHROME_EXT_C/4.0_0" ]]
}

@test "clean_chrome_extension_old_versions dry run previews without removing" {
    local case_home="$HOME/chrome-ext-dry-run"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"
    _chrome_ext_profile "$profile"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 MOLE_DRY_RUN=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_chrome_extension_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Chrome old extension versions"*"3 items"*"dry"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$profile/Extensions/$CHROME_EXT_A/1.0.92_0" ]] || return 1
    [[ -d "$profile/Extensions/$CHROME_EXT_B/8.0_0" ]]
}

@test "clean_chrome_extension_old_versions leaves an extension alone without a usable reference or layout" {
    local case_home="$HOME/chrome-ext-no-reference"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"
    local unlisted="bbbbccccddddeeeeffffgggghhhhaaaa"
    local absolute="ccccddddeeeeffffgggghhhhaaaabbbb"
    local missing="ddddeeeeffffgggghhhhaaaabbbbcccc"
    local linked="eeeeffffgggghhhhaaaabbbbccccdddd"
    _chrome_ext_profile "$profile"
    _chrome_ext_versions "$profile" "$unlisted" 1.0_0 2.0_0 3.0_0
    _chrome_ext_versions "$profile" "$absolute" 1.0_0 2.0_0 3.0_0
    _chrome_ext_versions "$profile" "$missing" 1.0_0 2.0_0 3.0_0
    _chrome_ext_versions "$profile" "$linked" 1.0_0 2.0_0
    ln -s "2.0_0" "$profile/Extensions/$linked/9.0_0"
    # B keeps its reference, so only the stray directory stops 8.0_0 removal.
    mkdir -p "$profile/Extensions/$CHROME_EXT_B/not-a-version"
    printf '{"extensions":{"settings":{"%s":{"path":"%s/1.0.91_0"},"%s":{"path":"%s/9.0_0"},"%s":{"path":"/tmp/%s/1.0_0"},"%s":{"path":"%s/1.5_0"},"%s":{"path":"%s/2.0_0"}}}}' \
        "$CHROME_EXT_A" "$CHROME_EXT_A" "$CHROME_EXT_B" "$CHROME_EXT_B" "$absolute" "$absolute" \
        "$missing" "$missing" "$linked" "$linked" > "$profile/Secure Preferences"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_chrome_extension_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    # Positive control: the referenced extension in the same profile is cleaned.
    [[ ! -e "$profile/Extensions/$CHROME_EXT_A/1.0.92_0" ]] || return 1
    local id
    for id in "$unlisted" "$absolute" "$missing"; do
        [[ -d "$profile/Extensions/$id/1.0_0" ]] || return 1
        [[ -d "$profile/Extensions/$id/2.0_0" ]] || return 1
    done
    [[ -d "$profile/Extensions/$linked/1.0_0" ]] || return 1
    [[ -d "$profile/Extensions/$CHROME_EXT_B/8.0_0" ]]
}

@test "clean_chrome_extension_old_versions leaves a profile alone when a prefs file does not parse" {
    local case_home="$HOME/chrome-ext-corrupt-prefs"
    local chrome="$case_home/Library/Application Support/Google/Chrome"
    _chrome_ext_profile "$chrome/Default"
    _chrome_ext_profile "$chrome/Profile 1"
    printf '{"extensions":{"settings":' > "$chrome/Default/Preferences"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_chrome_extension_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -d "$chrome/Default/Extensions/$CHROME_EXT_A/1.0.92_0" ]] || return 1
    [[ -d "$chrome/Default/Extensions/$CHROME_EXT_B/8.0_0" ]] || return 1
    [[ ! -e "$chrome/Profile 1/Extensions/$CHROME_EXT_A/1.0.92_0" ]]
}

@test "clean_chrome_extension_old_versions defers without reading prefs while Chrome is open" {
    local case_home="$HOME/chrome-ext-running"
    local chrome="$case_home/Library/Application Support/Google/Chrome"
    _chrome_ext_profile "$chrome/Default"
    local stub_bin="$case_home/bin"
    mkdir -p "$stub_bin"
    printf '#!/bin/bash\necho "UNEXPECTED_PLUTIL:$*" >> "%s/plutil.log"\nexec /usr/bin/plutil "$@"\n' "$case_home" > "$stub_bin/plutil"
    chmod +x "$stub_bin/plutil"

    # pgrep sees Chrome; a live local lock; a lock held from another host.
    local state
    for state in pgrep "lock:$HOSTNAME-$$" "lock:other-host-99999999"; do
        rm -f "$chrome/SingletonLock"
        [[ "$state" != lock:* ]] || ln -s "${state#lock:}" "$chrome/SingletonLock"
        run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stub_bin:$PATH" STATE="$state" \
            MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ "$STATE" == "pgrep" ]]; }
defer_cleanup_family() { echo "DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_chrome_extension_old_versions
EOF
        [ "$status" -eq 0 ] || {
            echo "$output"
            return 1
        }
        [[ "$output" == *"DEFER:Chrome"* ]] || return 1
        [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    done
    [[ ! -e "$case_home/plutil.log" ]] || return 1
    [[ -d "$chrome/Default/Extensions/$CHROME_EXT_A/1.0.92_0" ]]
}

@test "clean_chrome_extension_old_versions stays quiet when nothing is eligible" {
    local case_home="$HOME/chrome-ext-nothing-stale"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"
    # Only kept shapes: one version, and the same highest version twice.
    _chrome_ext_versions "$profile" "$CHROME_EXT_A" 1.0.93_0
    _chrome_ext_versions "$profile" "$CHROME_EXT_B" 10.0_0 10.0_1
    mkdir -p "$profile/Extensions/Temp/a" "$profile/Extensions/Temp/b"
    local whitelisted="$case_home/Library/Application Support/Google/Chrome/Profile 1"
    _chrome_ext_profile "$whitelisted"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
pgrep() { return 0; }
is_path_whitelisted() { [[ "$1" == *"/Profile 1/Extensions/"* ]]; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
clean_chrome_extension_old_versions
echo "CANDIDATES:${#_MOLE_CHROME_EXT_CANDIDATES[@]}"
EOF

    [ "$status" -eq 0 ] || return 1
    # Positive control: the whitelisted profile's seven below-highest dirs were
    # seen (the filesystem pass does not read prefs, so referenced ones count).
    [[ "$output" == *"CANDIDATES:7"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DEFER"* ]]
}

@test "clean_chrome_extension_old_versions reports an unknown Chrome state or a stale lock" {
    local case_home="$HOME/chrome-ext-unknown-state"
    local chrome="$case_home/Library/Application Support/Google/Chrome"
    _chrome_ext_profile "$chrome/Default"

    local state
    for state in pgrep-error "lock:$HOSTNAME-99999999"; do
        rm -f "$chrome/SingletonLock"
        [[ "$state" != lock:* ]] || ln -s "${state#lock:}" "$chrome/SingletonLock"
        run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" STATE="$state" \
            MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ "$STATE" == "pgrep-error" ]] && return 2; return 1; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_chrome_extension_old_versions
EOF
        [ "$status" -eq 0 ] || {
            echo "$output"
            return 1
        }
        [[ "$output" == *"Chrome old extension versions · skipped (process state unknown)"* ]] || return 1
        [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
        [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    done
    [[ -d "$chrome/Default/Extensions/$CHROME_EXT_A/1.0.92_0" ]]
}

@test "clean_chrome_extension_old_versions rechecks Chrome after sizing" {
    local case_home="$HOME/chrome-ext-started-late"
    local chrome="$case_home/Library/Application Support/Google/Chrome"

    local variant
    for variant in pgrep lock unknown dry-run; do
        rm -rf "$chrome" "$case_home/chrome-started"
        _chrome_ext_profile "$chrome/Default"
        run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" VARIANT="$variant" \
            MOLE_TEST_NO_AUTH=1 MOLE_DRY_RUN="$([[ "$variant" == "dry-run" ]] && echo 1 || echo 0)" \
            /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() {
    [[ -e "$HOME/chrome-started" ]] || return 1
    [[ "$VARIANT" == "unknown" ]] && return 2
    [[ "$VARIANT" != "lock" ]]
}
get_cleanup_path_size_kb() {
    if [[ ! -e "$HOME/chrome-started" ]]; then
        : > "$HOME/chrome-started"
        if [[ "$VARIANT" == "lock" ]]; then
            ln -s "$HOSTNAME-$PPID" "$HOME/Library/Application Support/Google/Chrome/SingletonLock"
        fi
    fi
    echo 4
}
defer_cleanup_family() { echo "DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
record_dry_run_cleanup_target() { echo "UNEXPECTED_RECORD:$1"; }
clean_chrome_extension_old_versions
EOF
        [ "$status" -eq 0 ] || {
            echo "$output"
            return 1
        }
        [[ -e "$case_home/chrome-started" ]] || return 1
        if [[ "$variant" == "unknown" ]]; then
            [[ "$output" == *"Chrome old extension versions · stopped (process state unknown)"* ]] || return 1
        else
            [[ "$output" == *"DEFER:Chrome"* ]] || return 1
        fi
        [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
        [[ "$output" != *"UNEXPECTED_RECORD"* ]] || return 1
        [[ -d "$chrome/Default/Extensions/$CHROME_EXT_B/8.0_0" ]] || return 1
    done
}

@test "clean_chrome_extension_old_versions stops when prefs change after planning" {
    local case_home="$HOME/chrome-ext-prefs-changed"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"
    _chrome_ext_profile "$profile"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    local prefs="$HOME/Library/Application Support/Google/Chrome/Default/Secure Preferences"
    if [[ ! -e "$HOME/prefs-rewritten" ]]; then
        : > "$HOME/prefs-rewritten"
        cp "$prefs" "$prefs.new"
        mv "$prefs.new" "$prefs"
    fi
    echo 4
}
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_chrome_extension_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -e "$case_home/prefs-rewritten" ]] || return 1
    [[ "$output" == *"Chrome old extension versions · stopped (preferences changed)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -d "$profile/Extensions/$CHROME_EXT_A/1.0.92_0" ]]
}

@test "clean_chrome_extension_old_versions refuses a target swapped during sizing and binds identity" {
    local case_home="$HOME/chrome-ext-swapped"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"
    _chrome_ext_profile "$profile"
    mkdir -p "$case_home/Documents/victim"
    touch "$case_home/Documents/victim/SENTINEL"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
_chrome_extension_collect_candidates "$HOME/Library/Application Support/Google/Chrome"
_chrome_extension_plan_targets
target="${_MOLE_CHROME_EXT_TARGETS[0]}"
_chrome_extension_delete_guard_allows "$target"
[[ "$_MOLE_SAFE_CLEAN_BOUND_PATH" == "$target" && -n "$_MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID" ]] || exit 1
echo "BOUND:${target##*/Extensions/}"

get_cleanup_path_size_kb() {
    local first="$HOME/Library/Application Support/Google/Chrome/Default/Extensions/aaaabbbbccccddddeeeeffffgggghhhh/8.0_0"
    if [[ -d "$first" && ! -L "$first" ]]; then
        mv "$first" "$HOME/moved-away"
        ln -s "$HOME/Documents/victim" "$first"
    fi
    echo 4
}
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
clean_chrome_extension_old_versions
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"BOUND:$CHROME_EXT_B/8.0_0"* ]] || return 1
    [[ "$output" == *"Chrome old extension versions · stopped (target changed)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
    [[ -f "$case_home/Documents/victim/SENTINEL" ]]
}

@test "clean_chrome_extension_old_versions cancels when the final prefs check times out or is signalled" {
    local case_home="$HOME/chrome-ext-guard-timeout"
    local profile="$case_home/Library/Application Support/Google/Chrome/Default"

    local stub_rc
    for stub_rc in 124 130; do
        rm -rf "$case_home"
        _chrome_ext_profile "$profile"
        run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" STUB_RC="$stub_rc" \
            MOLE_TEST_NO_AUTH=1 MOLE_CURRENT_COMMAND=clean DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
eval "$(declare -f _chrome_extension_prefs_stamp | sed '1s/_chrome_extension_prefs_stamp/_real_prefs_stamp/')"
# Planning reads the stamp twice and the first guard once; the second guard fails.
_chrome_extension_prefs_stamp() {
    local calls=0
    [[ ! -f "$HOME/stamp-calls" ]] || calls=$(< "$HOME/stamp-calls")
    calls=$((calls + 1))
    echo "$calls" > "$HOME/stamp-calls"
    [[ $calls -le 3 ]] || return "$STUB_RC"
    _real_prefs_stamp "$@"
}
set +e
clean_chrome_extension_old_versions
rc=$?
set -e
echo "RC:$rc CANCEL:${MOLE_CLEAN_CANCEL_STATUS:-0}"
EOF
        [ "$status" -eq 0 ] || {
            echo "$output"
            return 1
        }
        [[ "$output" == *"RC:$stub_rc CANCEL:$stub_rc"* ]] || return 1
        # Positive control: the first planned target passed its guard.
        [[ ! -e "$profile/Extensions/$CHROME_EXT_B/8.0_0" ]] || return 1
        [[ -d "$profile/Extensions/$CHROME_EXT_A/1.0.92_0" ]] || return 1
        [[ -d "$profile/Extensions/$CHROME_EXT_C/1.0_0" ]] || return 1
    done
}

@test "clean_chrome_extension_old_versions discards the plan on a prefs read timeout or signal" {
    local case_home="$HOME/chrome-ext-read-timeout"
    local chrome="$case_home/Library/Application Support/Google/Chrome"
    _chrome_ext_profile "$chrome/Default"
    _chrome_ext_profile "$chrome/Profile 1"
    local stub_bin="$case_home/bin"
    mkdir -p "$stub_bin"
    # Profile 1 is planned second. Either loading its settings fails, or reading
    # A's loaded `path` from them does, which must never read as "absent" and
    # drop 1.0.91_0 from the keep-set. Default must not be cleaned from the
    # partial plan either.
    cat > "$stub_bin/plutil" << 'STUB'
#!/bin/bash
if [[ "$STUB_AT" == "load" && "$1" == "-extract" && "$*" == *"Profile 1"* ]]; then
    exit "$STUB_RC"
fi
if [[ "$STUB_AT" == "ref" && "$2" == "fcoeoabgfenejglbffodgkkbkcdhcgfn.path" && -e "$HOME/default-planned" ]]; then
    exit "$STUB_RC"
fi
[[ "$2" != "fcoeoabgfenejglbffodgkkbkcdhcgfn.path" ]] || : > "$HOME/default-planned"
exec /usr/bin/plutil "$@"
STUB
    chmod +x "$stub_bin/plutil"

    local stub_rc stub_at
    for stub_at in load ref; do
    for stub_rc in 124 130; do
        rm -f "$case_home/default-planned"
        run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stub_bin:$PATH" STUB_RC="$stub_rc" STUB_AT="$stub_at" \
            MOLE_TEST_NO_AUTH=1 MOLE_CURRENT_COMMAND=clean DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
safe_remove() { echo "UNEXPECTED_REMOVE:$1"; }
set +e
clean_chrome_extension_old_versions
rc=$?
set -e
echo "RC:$rc CANCEL:${MOLE_CLEAN_CANCEL_STATUS:-0}"
EOF
        [ "$status" -eq 0 ] || {
            echo "$output"
            return 1
        }
        [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
        if [[ "$stub_rc" == "124" ]]; then
            [[ "$output" == *"Chrome old extension versions · skipped (preferences read timed out)"* ]] || return 1
            [[ "$output" == *"RC:0 CANCEL:0"* ]] || return 1
        else
            [[ "$output" == *"RC:130 CANCEL:130"* ]] || return 1
        fi
        [[ "$stub_at" != "ref" || -e "$case_home/default-planned" ]] || return 1
    done
    done
    [[ -d "$chrome/Default/Extensions/$CHROME_EXT_A/1.0.92_0" ]] || return 1
    [[ -d "$chrome/Profile 1/Extensions/$CHROME_EXT_A/1.0.91_0" ]] || return 1
    [[ -d "$chrome/Profile 1/Extensions/$CHROME_EXT_A/1.0.92_0" ]]
}
