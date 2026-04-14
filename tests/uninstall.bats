#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${BATS_TMPDIR:-}" # Use BATS_TMPDIR as original HOME if set by bats
	if [[ -z "$ORIGINAL_HOME" ]]; then
		ORIGINAL_HOME="${HOME:-}"
	fi
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-home.XXXXXX")"
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

create_app_artifacts() {
	mkdir -p "$HOME/Applications/TestApp.app"
	mkdir -p "$HOME/Library/Application Support/TestApp"
	mkdir -p "$HOME/Library/Caches/TestApp"
	mkdir -p "$HOME/Library/Containers/com.example.TestApp"
	mkdir -p "$HOME/Library/Preferences"
	touch "$HOME/Library/Preferences/com.example.TestApp.plist"
	mkdir -p "$HOME/Library/Preferences/ByHost"
	touch "$HOME/Library/Preferences/ByHost/com.example.TestApp.ABC123.plist"
	mkdir -p "$HOME/Library/Saved Application State/com.example.TestApp.savedState"
	mkdir -p "$HOME/Library/LaunchAgents"
	touch "$HOME/Library/LaunchAgents/com.example.TestApp.plist"
}

@test "find_app_files discovers user-level leftovers" {
	create_app_artifacts

	result="$(
		HOME="$HOME" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.TestApp" "TestApp"
EOF
	)"

	[[ "$result" == *"Application Support/TestApp"* ]]
	[[ "$result" == *"Caches/TestApp"* ]]
	[[ "$result" == *"Preferences/com.example.TestApp.plist"* ]]
	[[ "$result" == *"Saved Application State/com.example.TestApp.savedState"* ]]
	[[ "$result" == *"Containers/com.example.TestApp"* ]]
	[[ "$result" == *"LaunchAgents/com.example.TestApp.plist"* ]]
}

@test "get_diagnostic_report_paths_for_app avoids executable prefix collisions" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

diag_dir="$HOME/Library/Logs/DiagnosticReports"
app_dir="$HOME/Applications/Foo.app"
mkdir -p "$diag_dir" "$app_dir/Contents"

cat > "$app_dir/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Foo</string>
</dict>
</plist>
PLIST

touch "$diag_dir/Foo.crash"
touch "$diag_dir/Foo_2026-01-01-120000_host.ips"
touch "$diag_dir/Foobar.crash"
touch "$diag_dir/Foobar_2026-01-01-120001_host.ips"

result=$(get_diagnostic_report_paths_for_app "$app_dir" "Foo" "$diag_dir")
[[ "$result" == *"Foo.crash"* ]] || exit 1
[[ "$result" == *"Foo_2026-01-01-120000_host.ips"* ]] || exit 1
[[ "$result" != *"Foobar.crash"* ]] || exit 1
[[ "$result" != *"Foobar_2026-01-01-120001_host.ips"* ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "calculate_total_size returns aggregate kilobytes" {
	mkdir -p "$HOME/sized"
	dd if=/dev/zero of="$HOME/sized/file1" bs=1024 count=1 >/dev/null 2>&1
	dd if=/dev/zero of="$HOME/sized/file2" bs=1024 count=2 >/dev/null 2>&1

	result="$(
		HOME="$HOME" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
files="$(printf '%s
%s
' "$HOME/sized/file1" "$HOME/sized/file2")"
calculate_total_size "$files"
EOF
	)"

	[ "$result" -ge 3 ]
}

@test "batch_uninstall_applications removes selected app data" {
	create_app_artifacts

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

request_sudo_access() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
enter_alt_screen() { :; }
leave_alt_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }
remove_apps_from_dock() { :; }
pgrep() { return 1; }
pkill() { return 0; }
sudo() { return 0; } # Mock sudo command

app_bundle="$HOME/Applications/TestApp.app"
mkdir -p "$app_bundle" # Ensure this is created in the temp HOME

related="$(find_app_files "com.example.TestApp" "TestApp")"
encoded_related=$(printf '%s' "$related" | base64 | tr -d '\n')

selected_apps=()
selected_apps+=("0|$app_bundle|TestApp|com.example.TestApp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

batch_uninstall_applications

[[ ! -d "$app_bundle" ]] || exit 1
[[ ! -d "$HOME/Library/Application Support/TestApp" ]] || exit 1
[[ ! -d "$HOME/Library/Caches/TestApp" ]] || exit 1
[[ ! -f "$HOME/Library/Preferences/com.example.TestApp.plist" ]] || exit 1
[[ ! -f "$HOME/Library/LaunchAgents/com.example.TestApp.plist" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "batch_uninstall_applications warns when removed app declares Local Network usage" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

request_sudo_access() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
enter_alt_screen() { :; }
leave_alt_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }
remove_apps_from_dock() { :; }
pgrep() { return 1; }
pkill() { return 0; }
sudo() { return 0; }

app_bundle="$HOME/Applications/NetworkApp.app"
mkdir -p "$app_bundle/Contents"
cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.NetworkApp</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Discover devices on the local network</string>
</dict>
</plist>
PLIST

selected_apps=()
selected_apps+=("0|$app_bundle|NetworkApp|com.example.NetworkApp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Local Network permissions"* ]]
	[[ "$output" == *"NetworkApp"* ]]
	[[ "$output" == *"Recovery mode"* ]]
}

@test "batch_uninstall_applications skips Local Network warning for regular apps" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

request_sudo_access() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
enter_alt_screen() { :; }
leave_alt_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }
remove_apps_from_dock() { :; }
pgrep() { return 1; }
pkill() { return 0; }
sudo() { return 0; }

app_bundle="$HOME/Applications/PlainApp.app"
mkdir -p "$app_bundle/Contents"
cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.PlainApp</string>
</dict>
</plist>
PLIST

selected_apps=()
selected_apps+=("0|$app_bundle|PlainApp|com.example.PlainApp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"Local Network permissions"* ]]
}

@test "batch_uninstall_applications preview shows full related file list" {
	mkdir -p "$HOME/Applications/TestApp.app"
	mkdir -p "$HOME/Library/Application Support/TestApp"
	mkdir -p "$HOME/Library/Caches/TestApp"
	mkdir -p "$HOME/Library/Logs/TestApp"
	touch "$HOME/Library/Logs/TestApp/log1.log"
	touch "$HOME/Library/Logs/TestApp/log2.log"
	touch "$HOME/Library/Logs/TestApp/log3.log"
	touch "$HOME/Library/Logs/TestApp/log4.log"
	touch "$HOME/Library/Logs/TestApp/log5.log"
	touch "$HOME/Library/Logs/TestApp/log6.log"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

request_sudo_access() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
enter_alt_screen() { :; }
leave_alt_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }
remove_apps_from_dock() { :; }
pgrep() { return 1; }
pkill() { return 0; }
sudo() { return 0; }
has_sensitive_data() { return 1; }
find_app_system_files() { return 0; }
find_app_files() {
    cat << LIST
$HOME/Library/Application Support/TestApp
$HOME/Library/Caches/TestApp
$HOME/Library/Logs/TestApp/log1.log
$HOME/Library/Logs/TestApp/log2.log
$HOME/Library/Logs/TestApp/log3.log
$HOME/Library/Logs/TestApp/log4.log
$HOME/Library/Logs/TestApp/log5.log
$HOME/Library/Logs/TestApp/log6.log
LIST
}

selected_apps=()
selected_apps+=("0|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf 'q' | batch_uninstall_applications
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"~/Library/Logs/TestApp/log6.log"* ]]
	[[ "$output" != *"more files"* ]]
}

@test "uninstall_persist_cache_file heals non-writable destination" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail

# Source only the helper by evaluating its function definition.
eval "$(sed -n '/^uninstall_persist_cache_file()/,/^}$/p' "$PROJECT_ROOT/bin/uninstall.sh")"

src="$HOME/cache.src"
dst="$HOME/cache.dst"
printf 'fresh-data\n' > "$src"
printf 'stale-data\n' > "$dst"
chmod 0444 "$dst"
[[ ! -w "$dst" ]] || { echo "precondition: dst should be read-only" >&2; exit 1; }

uninstall_persist_cache_file "$src" "$dst"

[[ ! -e "$src" ]] || { echo "src should be gone" >&2; exit 1; }
[[ -f "$dst" ]] || { echo "dst missing" >&2; exit 1; }
grep -q 'fresh-data' "$dst" || { echo "dst not updated"; exit 1; }
EOF

	[ "$status" -eq 0 ]
}

@test "uninstall_persist_cache_file does not hang when mv would prompt (stdin closed)" {
	# Regression for #722: BSD mv without -f prompts on non-writable dst and
	# blocks reading stdin. The helper must close stdin and use -f.
	#
	# The hang detector uses a marker file rather than a PID-based watchdog:
	# PIDs get recycled quickly on CI and a stale `kill -9 $pid` can succeed
	# against an unrelated process, producing a false HANG. The marker
	# approach only cares about whether the helper itself completed.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^uninstall_persist_cache_file()/,/^}$/p' "$PROJECT_ROOT/bin/uninstall.sh")"

src="$HOME/snap.src"
dst="$HOME/snap.dst"
done_marker="$HOME/snap.done"
printf 'x\n' > "$src"
printf 'y\n' > "$dst"
chmod 0444 "$dst"

(
    printf 'n\nn\nn\n' | uninstall_persist_cache_file "$src" "$dst"
    : > "$done_marker"
) &
bgpid=$!

# Poll for completion marker for up to ~5s.
for _ in $(seq 1 50); do
    [[ -e "$done_marker" ]] && break
    sleep 0.1
done

if [[ ! -e "$done_marker" ]]; then
    kill -9 "$bgpid" 2>/dev/null || true
    echo HANG
fi
wait "$bgpid" 2>/dev/null || true
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"HANG"* ]]
}

@test "uninstall_persist_cache_file is a no-op when source is empty" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^uninstall_persist_cache_file()/,/^}$/p' "$PROJECT_ROOT/bin/uninstall.sh")"

src="$HOME/empty.src"
dst="$HOME/keep.dst"
: > "$src"
printf 'untouched\n' > "$dst"

uninstall_persist_cache_file "$src" "$dst"

[[ ! -e "$src" ]] || exit 1
grep -q 'untouched' "$dst" || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "safe_remove can remove a simple directory" {
	mkdir -p "$HOME/test_dir"
	touch "$HOME/test_dir/file.txt"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

safe_remove "$HOME/test_dir"
[[ ! -d "$HOME/test_dir" ]] || exit 1
EOF
	[ "$status" -eq 0 ]
}

@test "decode_file_list validates base64 encoding" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

valid_data=$(printf '/path/one
/path/two' | base64)
result=$(decode_file_list "$valid_data" "TestApp")
[[ -n "$result" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "decode_file_list rejects invalid base64" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

if result=$(decode_file_list "not-valid-base64!!!" "TestApp" 2>/dev/null); then
    [[ -z "$result" ]]
else
    true
fi
EOF

	[ "$status" -eq 0 ]
}

@test "uninstall_resolve_display_name keeps versioned app names when metadata is generic" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

function run_with_timeout() {
    shift
    "$@"
}

function mdls() {
    echo "Xcode"
}

function plutil() {
    if [[ "$3" == *"Info.plist" ]]; then
        echo "Xcode"
        return 0
    fi
    return 1
}

MOLE_UNINSTALL_USER_LC_ALL=""
MOLE_UNINSTALL_USER_LANG=""

eval "$(sed -n '/^uninstall_resolve_display_name()/,/^}/p' "$PROJECT_ROOT/bin/uninstall.sh")"

app_path="$HOME/Applications/Xcode 16.4.app"
mkdir -p "$app_path/Contents"
touch "$app_path/Contents/Info.plist"

result=$(uninstall_resolve_display_name "$app_path" "Xcode 16.4.app")
[[ "$result" == "Xcode 16.4" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "decode_file_list handles empty input" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

empty_data=$(printf '' | base64)
result=$(decode_file_list "$empty_data" "TestApp" 2>/dev/null) || true
[[ -z "$result" ]]
EOF

	[ "$status" -eq 0 ]
}

@test "decode_file_list rejects non-absolute paths" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

bad_data=$(printf 'relative/path' | base64)
if result=$(decode_file_list "$bad_data" "TestApp" 2>/dev/null); then
    [[ -z "$result" ]]
else
    true
fi
EOF

	[ "$status" -eq 0 ]
}

@test "decode_file_list handles both BSD and GNU base64 formats" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

test_paths="/path/to/file1
/path/to/file2"

encoded_data=$(printf '%s' "$test_paths" | base64 | tr -d '\n')

result=$(decode_file_list "$encoded_data" "TestApp")

[[ "$result" == *"/path/to/file1"* ]] || exit 1
[[ "$result" == *"/path/to/file2"* ]] || exit 1

[[ -n "$result" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "refresh_launch_services_after_uninstall falls back after timeout" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

log_file="$HOME/lsregister-timeout.log"
: > "$log_file"
call_index=0

get_lsregister_path() { echo "/bin/echo"; }
debug_log() { echo "DEBUG:$*" >> "$log_file"; }
run_with_timeout() {
    local duration="$1"
    shift
    call_index=$((call_index + 1))
    echo "CALL${call_index}:$duration:$*" >> "$log_file"

    if [[ "$call_index" -eq 2 ]]; then
        return 124
    fi
    if [[ "$call_index" -eq 3 ]]; then
        return 124
    fi
    return 0
}

if refresh_launch_services_after_uninstall; then
    echo "RESULT:ok"
else
    echo "RESULT:fail"
fi

cat "$log_file"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"RESULT:ok"* ]]
	[[ "$output" == *"CALL2:15:/bin/echo -r -f -domain local -domain user -domain system"* ]]
	[[ "$output" == *"CALL3:10:/bin/echo -r -f -domain local -domain user"* ]]
	[[ "$output" == *"DEBUG:LaunchServices rebuild timed out, trying lighter version"* ]]
}

@test "remove_mole deletes manual binaries and caches" {
	mkdir -p "$HOME/.local/bin"
	touch "$HOME/.local/bin/mole"
	touch "$HOME/.local/bin/mo"
	mkdir -p "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
rm() {
    local -a flags=()
    local -a paths=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == -* ]]; then
            flags+=("$arg")
        else
            paths+=("$arg")
        fi
    done
    local path
    for path in "${paths[@]}"; do
        if [[ "$path" == "$HOME" || "$path" == "$HOME/"* ]]; then
            /bin/rm "${flags[@]}" "$path"
        fi
    done
    return 0
}
sudo() {
    if [[ "$1" == "rm" ]]; then
        shift
        rm "$@"
        return 0
    fi
    return 0
}
export -f start_inline_spinner stop_inline_spinner rm sudo
printf '\n' | "$PROJECT_ROOT/mole" remove
EOF

	[ "$status" -eq 0 ]
	[ ! -f "$HOME/.local/bin/mole" ]
	[ ! -f "$HOME/.local/bin/mo" ]
	[ ! -d "$HOME/.config/mole" ]
	[ ! -d "$HOME/.cache/mole" ]
	[ ! -d "$HOME/Library/Logs/mole" ]
}

@test "remove_mole dry-run keeps manual binaries and caches" {
	mkdir -p "$HOME/.local/bin"
	touch "$HOME/.local/bin/mole"
	touch "$HOME/.local/bin/mo"
	mkdir -p "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
export -f start_inline_spinner stop_inline_spinner
printf '\n' | "$PROJECT_ROOT/mole" remove --dry-run
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"DRY RUN MODE"* ]]
	[ -f "$HOME/.local/bin/mole" ]
	[ -f "$HOME/.local/bin/mo" ]
	[ -d "$HOME/.config/mole" ]
	[ -d "$HOME/.cache/mole" ]
	[ -d "$HOME/Library/Logs/mole" ]
}

@test "remove_mole test mode ignores PATH installs outside test HOME" {
	mkdir -p "$HOME/.local/bin" "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"
	touch "$HOME/.local/bin/mole"
	touch "$HOME/.local/bin/mo"

	fake_global_bin="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-remove-path.XXXXXX")"
	touch "$fake_global_bin/mole"
	touch "$fake_global_bin/mo"
	cat > "$fake_global_bin/brew" <<'EOF'
#!/bin/bash
exit 0
EOF
	chmod +x "$fake_global_bin/brew"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$fake_global_bin:/usr/bin:/bin" MOLE_TEST_MODE=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
export -f start_inline_spinner stop_inline_spinner
printf '\n' | "$PROJECT_ROOT/mole" remove --dry-run
EOF

	rm -rf "$fake_global_bin"

	[ "$status" -eq 0 ]
	[[ "$output" == *"$HOME/.local/bin/mole"* ]]
	[[ "$output" == *"$HOME/.local/bin/mo"* ]]
	[[ "$output" != *"$fake_global_bin/mole"* ]]
	[[ "$output" != *"$fake_global_bin/mo"* ]]
	[[ "$output" != *"brew uninstall --force mole"* ]]
}
@test "match_apps_by_name finds exact match case-insensitively" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
	"1001|$HOME/Applications/TestApp2.app|TestApp2|com.example.TestApp2|500 MB|1000001|512000"
	"1002|$HOME/Applications/TestApp3.app|TestApp3|com.example.TestApp3|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "testapp"
echo "count=${#selected_apps[@]}"
echo "match=${selected_apps[0]}"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=1"* ]]
	[[ "$output" == *"TestApp"* ]]
}

@test "match_apps_by_name finds by directory name" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1002|$HOME/Applications/TestApp.app|Test Application|com.example.TestApp|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "TestApp"
echo "count=${#selected_apps[@]}"
echo "match=${selected_apps[0]}"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=1"* ]]
	[[ "$output" == *"Test Application"* ]]
}

@test "match_apps_by_name warns on no match" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "nonexistent"
echo "count=${#selected_apps[@]}"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Warning: No application found matching 'nonexistent'"* ]]
	[[ "$output" == *"count=0"* ]]
}

@test "match_apps_by_name handles multiple app names" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
	"1001|$HOME/Applications/TestApp2.app|TestApp2|com.example.TestApp2|500 MB|1000001|512000"
	"1002|$HOME/Applications/TestApp3.app|TestApp3|com.example.TestApp3|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "testapp2" "testapp3"
echo "count=${#selected_apps[@]}"
for app in "${selected_apps[@]}"; do
    IFS='|' read -r _ _ name _ _ _ _ <<< "$app"
    echo "matched=$name"
done
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=2"* ]]
	[[ "$output" == *"matched=TestApp2"* ]]
	[[ "$output" == *"matched=TestApp3"* ]]
}

@test "match_apps_by_name falls back to substring match" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
	"1001|$HOME/Applications/SlackDesktop.app|Slack|com.tinyspeck.slackmacgap|200 MB|1000001|204800"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "test"
echo "count=${#selected_apps[@]}"
for app in "${selected_apps[@]}"; do
    IFS='|' read -r _ _ name _ _ _ _ <<< "$app"
    echo "matched=$name"
done
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=1"* ]]
	[[ "$output" == *"matched=TestApp"* ]]
}

@test "match_apps_by_name does not duplicate when same name given twice" {
	run bash --noprofile --norc <<'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "testapp" "testapp"
echo "count=${#selected_apps[@]}"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=1"* ]]
}
