#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-browser-cleanup.XXXXXX")"
	export HOME

	# Prevent AppleScript permission dialogs during tests
	ROOMY_TEST_MODE=1
	export ROOMY_TEST_MODE

	mkdir -p "$HOME"
}

teardown_file() {
	rm -rf "$HOME"
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

@test "clean_chrome_old_versions skips when Chrome is running" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Mock pgrep to simulate Chrome running
pgrep() { return 0; }
export -f pgrep

clean_chrome_old_versions
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Google Chrome running"* ]]
	[[ "$output" == *"old versions cleanup skipped"* ]]
}

@test "clean_chrome_old_versions skips when only Chrome helpers are running" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() {
    case "$*" in
        *"Google Chrome Helper"*) return 0 ;;
        *) return 1 ;;
    esac
}
export -f pgrep

clean_chrome_old_versions
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Google Chrome running"* ]]
	[[ "$output" == *"old versions cleanup skipped"* ]]
}

@test "clean_chrome_old_versions removes old versions but keeps current" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
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
export ROOMY_CHROME_APP_PATHS="$CHROME_APP"

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
	[[ "$output" == *"Chrome old versions"* ]]
	[[ "$output" == *"dry"* ]]
	[[ "$output" == *"Cleaned: 2 items"* ]]
}

@test "clean_chrome_old_versions does not report success when removal fails" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
is_path_whitelisted() { return 1; }
has_sudo_session() { return 1; }
safe_remove() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f pgrep is_path_whitelisted has_sudo_session safe_remove get_path_size_kb bytes_to_human note_activity

CHROME_APP="$HOME/Applications/Google Chrome.app"
VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0,130.0.0.0}
ln -s "130.0.0.0" "$VERSIONS_DIR/Current"
export ROOMY_CHROME_APP_PATHS="$CHROME_APP"

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_chrome_old_versions
echo "Cleaned: $files_cleaned items"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"Chrome old versions"* ]]
	[[ "$output" == *"Cleaned: 0 items"* ]]
}

@test "clean_chrome_old_versions respects whitelist" {
	rm -rf "$HOME/Applications/Google Chrome.app"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
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
export ROOMY_CHROME_APP_PATHS="$CHROME_APP"

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

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
export -f pgrep

CHROME_APP="$HOME/Applications/Google Chrome.app"
VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
mkdir -p "$VERSIONS_DIR"/{128.0.0.0,129.0.0.0,130.0.0.0}
export ROOMY_CHROME_APP_PATHS="$CHROME_APP"
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

@test "clean_edge_updater_old_versions keeps latest version" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
export -f pgrep

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
	[[ "$output" == *"Edge updater old versions"* ]]
	[[ "$output" == *"dry"* ]]
	[[ "$output" == *"Cleaned: 2 items"* ]]
}

@test "clean_edge_updater_old_versions does not report success when removal fails" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

pgrep() { return 1; }
is_path_whitelisted() { return 1; }
safe_remove() { return 1; }
get_path_size_kb() { echo "10240"; }
bytes_to_human() { echo "10M"; }
note_activity() { :; }
export -f pgrep is_path_whitelisted safe_remove get_path_size_kb bytes_to_human note_activity

UPDATER_DIR="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
mkdir -p "$UPDATER_DIR"/{117.0.2045.60,118.0.2088.46,119.0.2108.9}

files_cleaned=0
total_size_cleaned=0
total_items=0

clean_edge_updater_old_versions
echo "Cleaned: $files_cleaned items"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"Edge updater old versions"* ]]
	[[ "$output" == *"Cleaned: 0 items"* ]]
}

@test "clean_chrome_old_versions DRY_RUN mode does not delete files" {
	# Create test directory
	CHROME_APP="$HOME/Applications/Google Chrome.app"
	VERSIONS_DIR="$CHROME_APP/Contents/Frameworks/Google Chrome Framework.framework/Versions"
	mkdir -p "$VERSIONS_DIR"/{128.0.0.0,130.0.0.0}
	export ROOMY_CHROME_APP_PATHS="$CHROME_APP"

	# Remove Current if it exists as a directory, then create symlink
	rm -rf "$VERSIONS_DIR/Current"
	ln -s "130.0.0.0" "$VERSIONS_DIR/Current"

	# Create a marker file in old version
	touch "$VERSIONS_DIR/128.0.0.0/marker.txt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
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
	[[ "$output" == *"dry"* ]]
	# Verify marker file still exists (not deleted in dry run)
	[ -f "$VERSIONS_DIR/128.0.0.0/marker.txt" ]
}

@test "clean_chrome_old_versions handles missing Current symlink gracefully" {
	# Use a fresh temp directory for this test
	TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-test5.XXXXXX")"

	run env HOME="$TEST_HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
export ROOMY_CHROME_APP_PATHS="$CHROME_APP"
# No Current symlink created

clean_chrome_old_versions
EOF

	rm -rf "$TEST_HOME"
	[ "$status" -eq 0 ]
	# Should exit gracefully with no output
}

@test "clean_edge_old_versions skips when Edge is running" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

# Mock pgrep to simulate Edge running
pgrep() { return 0; }
export -f pgrep

clean_edge_old_versions
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Microsoft Edge running"* ]]
	[[ "$output" == *"old versions cleanup skipped"* ]]
}

@test "clean_edge_old_versions removes old versions but keeps current" {
	# Create mock Edge directory structure
	local EDGE_APP="$HOME/Applications/Microsoft Edge.app"
	local VERSIONS_DIR="$EDGE_APP/Contents/Frameworks/Microsoft Edge Framework.framework/Versions"
	mkdir -p "$VERSIONS_DIR"/{120.0.0.0,121.0.0.0,122.0.0.0}
	ln -s "122.0.0.0" "$VERSIONS_DIR/Current"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true \
		ROOMY_EDGE_APP_PATHS="$EDGE_APP" bash --noprofile --norc <<'EOF'
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
	[[ "$output" == *"Edge old versions"* ]]
	[[ "$output" == *"dry"* ]]
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
		ROOMY_EDGE_APP_PATHS="$EDGE_APP" bash --noprofile --norc <<'EOF'
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
