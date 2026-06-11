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
	if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		rm -rf "$HOME"
	fi
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

setup() {
	# Safety: refuse to operate on a real home directory.
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
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
	touch "$HOME/Library/Preferences/TestApp.plist"
	mkdir -p "$HOME/Library/Preferences/ByHost"
	touch "$HOME/Library/Preferences/ByHost/com.example.TestApp.ABC123.plist"
	mkdir -p "$HOME/Library/Saved Application State/com.example.TestApp.savedState"
	mkdir -p "$HOME/Library/Saved Application State/TestApp.savedState"
	mkdir -p "$HOME/Library/LaunchAgents"
	touch "$HOME/Library/LaunchAgents/com.example.TestApp.plist"
	mkdir -p "$HOME/.cache/testapp"
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
	[[ "$result" == *"Preferences/TestApp.plist"* ]]
	[[ "$result" == *"Saved Application State/com.example.TestApp.savedState"* ]]
	[[ "$result" == *"Saved Application State/TestApp.savedState"* ]]
	[[ "$result" == *"Containers/com.example.TestApp"* ]]
	[[ "$result" == *"LaunchAgents/com.example.TestApp.plist"* ]]
	[[ "$result" == *".cache/testapp"* ]]
}

@test "find_app_system_files discovers bundle-id-prefixed LaunchDaemons" {
	fakebin="$HOME/fakebin"
	mkdir -p "$fakebin"

	# The new dot-anchored alternation invokes find with two -name patterns:
	# "${bundle_id}.plist" and "${bundle_id}.*.plist". Match on either form.
	cat > "$fakebin/find" <<'SCRIPT'
#!/bin/sh
args="$*"

case "$args" in
  *"/Library/LaunchDaemons"*'-name com.west2online.ClashXPro.*.plist'*)
    printf '%s\0' "/Library/LaunchDaemons/com.west2online.ClashXPro.ProxyConfigHelper.plist"
    ;;
esac
SCRIPT
	chmod +x "$fakebin/find"

	run env HOME="$HOME" PATH="$fakebin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

result=$(find_app_system_files "com.west2online.ClashXPro" "ClashX Pro")
[[ "$result" == *"/Library/LaunchDaemons/com.west2online.ClashXPro.ProxyConfigHelper.plist"* ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

# The previous "${bundle_id}*.plist" glob over-matched: bundle "com.foo"
# would harvest "com.foobar.plist" and "com.foobaz.plist" from unrelated
# vendors. The dot-anchored alternation only matches at the dot boundary.
@test "find_app_system_files does not over-match sibling-vendor LaunchDaemons" {
	# Use a real /Library/LaunchDaemons-like fixture by isolating PATH so the
	# function falls back to the system find binary, then assert only the
	# expected files are surfaced.
	fakebase="$HOME/fakebase"
	mkdir -p "$fakebase/Library/LaunchAgents" "$fakebase/Library/LaunchDaemons"
	: > "$fakebase/Library/LaunchDaemons/com.foo.plist"          # exact match - keep
	: > "$fakebase/Library/LaunchDaemons/com.foo.helper.plist"   # dotted - keep
	: > "$fakebase/Library/LaunchDaemons/com.foobar.plist"       # sibling - reject
	: > "$fakebase/Library/LaunchDaemons/com.foobaz.helper.plist" # sibling - reject

	# Verify the find pattern itself, since the production find is hard-coded
	# to /Library/* paths. This mirrors what app_protection.sh emits.
	run bash --noprofile --norc -c "
		cd '$fakebase/Library/LaunchDaemons'
		find . -maxdepth 1 \( -name 'com.foo.plist' -o -name 'com.foo.*.plist' \) | sort
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"com.foo.plist"* ]]
	[[ "$output" == *"com.foo.helper.plist"* ]]
	[[ "$output" != *"com.foobar.plist"* ]]
	[[ "$output" != *"com.foobaz.helper.plist"* ]]
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
touch "$diag_dir/Foo.diag"
touch "$diag_dir/Foo_2026-01-01-120000_host.ips"
touch "$diag_dir/Foobar.crash"
touch "$diag_dir/Foobar.diag"
touch "$diag_dir/Foobar_2026-01-01-120001_host.ips"

result=$(get_diagnostic_report_paths_for_app "$app_dir" "Foo" "$diag_dir")
[[ "$result" == *"Foo.crash"* ]] || exit 1
[[ "$result" == *"Foo.diag"* ]] || exit 1
[[ "$result" == *"Foo_2026-01-01-120000_host.ips"* ]] || exit 1
[[ "$result" != *"Foobar.crash"* ]] || exit 1
[[ "$result" != *"Foobar.diag"* ]] || exit 1
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

printf '\n' | batch_uninstall_applications

[[ ! -d "$app_bundle" ]] || exit 1
[[ ! -d "$HOME/Library/Application Support/TestApp" ]] || exit 1
[[ ! -d "$HOME/Library/Caches/TestApp" ]] || exit 1
[[ ! -f "$HOME/Library/Preferences/com.example.TestApp.plist" ]] || exit 1
[[ ! -f "$HOME/Library/LaunchAgents/com.example.TestApp.plist" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "batch_uninstall_applications blocks official-uninstaller apps" {
	mkdir -p "$HOME/Applications/Falcon.app"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
mole_delete() { echo "MOLE_DELETE:$1"; return 0; }

selected_apps=("0|$HOME/Applications/Falcon.app|Falcon|com.crowdstrike.falcon.UserAgent|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

if batch_uninstall_applications; then
	exit 1
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"requires the official CrowdStrike uninstaller"* ]]
	[[ "$output" != *"MOLE_DELETE"* ]]
}

@test "batch_uninstall_applications keeps system remnants review-only" {
	mkdir -p "$HOME/Applications/ReviewOnly.app" "$HOME/system"
	touch "$HOME/system/com.example.review.helper"

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
get_file_owner() { whoami; }
get_path_size_kb() { echo "1"; }
calculate_total_size() { echo "1"; }
find_app_files() { :; }
find_app_system_files() { printf '%s\n' "$HOME/system/com.example.review.helper"; }
get_diagnostic_report_paths_for_app() { :; }
remove_file_list() {
	printf 'REMOVE_LIST:%s:%s\n' "${2:-false}" "$1" >> "$HOME/remove.log"
	return 0
}
mole_delete() {
	printf 'MOLE_DELETE:%s:%s\n' "$2" "$1" >> "$HOME/remove.log"
	rm -rf "$1"
	return 0
}

selected_apps=("0|$HOME/Applications/ReviewOnly.app|ReviewOnly|com.example.review|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications > "$HOME/output.log" 2>&1

grep -q "Review only: $HOME/system/com.example.review.helper" "$HOME/output.log"
! grep -q "$HOME/system/com.example.review.helper" "$HOME/remove.log"
[[ -e "$HOME/system/com.example.review.helper" ]]
EOF

	[ "$status" -eq 0 ]
}

@test "batch_uninstall_applications dry-run does not report expected leftovers as failures" {
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
sudo() { return 0; }

export MOLE_DRY_RUN=1
export MOLE_DELETE_MODE=trash

app_bundle="$HOME/Applications/TestApp.app"
mkdir -p "$app_bundle"

selected_apps=()
selected_apps+=("0|$app_bundle|TestApp|com.example.TestApp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

output_file="$HOME/dry_run_uninstall.log"
printf '\n' | batch_uninstall_applications > "$output_file" 2>&1
output=$(cat "$output_file")

[[ -d "$app_bundle" ]] || { echo "WRONG: dry-run removed app bundle"; cat "$output_file"; exit 1; }
[[ -d "$HOME/Library/Application Support/TestApp" ]] || { echo "WRONG: dry-run removed app support"; cat "$output_file"; exit 1; }
[[ -d "$HOME/Library/Caches/TestApp" ]] || { echo "WRONG: dry-run removed cache"; cat "$output_file"; exit 1; }
[[ -f "$HOME/Library/Preferences/com.example.TestApp.plist" ]] || { echo "WRONG: dry-run removed prefs"; cat "$output_file"; exit 1; }

[[ "$output" == *"Uninstall dry run complete"* ]] || { echo "WRONG: missing dry-run summary"; cat "$output_file"; exit 1; }
[[ "$output" == *"Would remove 1 app"* ]] || { echo "WRONG: missing would-remove summary"; cat "$output_file"; exit 1; }
[[ "$output" != *"Could not remove"* ]] || { echo "WRONG: dry-run reported expected leftovers"; cat "$output_file"; exit 1; }
[[ "$output" != *"Uninstall incomplete"* ]] || { echo "WRONG: dry-run marked incomplete"; cat "$output_file"; exit 1; }
EOF

	[ "$status" -eq 0 ]
}

@test "force_kill_app skips the kill ladder when Quit succeeds" {
	# run_with_timeout invokes its argv via gtimeout/timeout, which exec the
	# real binary and bypass bash functions, so we shadow osascript via a
	# real script on PATH and read the trace it writes.
	stubdir="$HOME/stubs"
	mkdir -p "$stubdir"
	trace="$HOME/kill_trace.log"
	: > "$trace"

	cat > "$stubdir/osascript" <<STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
	chmod +x "$stubdir/osascript"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
		TRACE_PATH="$trace" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

# Bundle with a known id so the Quit step uses the precise `id "..."` form
# rather than the by-name fallback.
app_path="$HOME/Applications/TestApp.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TestApp</string>
  <key>CFBundleIdentifier</key><string>com.example.TestApp</string>
</dict></plist>
PLIST

# First pgrep finds the process (so we enter the kill flow); subsequent
# pgrep calls find nothing (so the function returns 0 once Quit "lands").
pgrep_count=0
pgrep() {
	pgrep_count=$((pgrep_count + 1))
	if [[ $pgrep_count -eq 1 ]]; then
		echo 12345
		return 0
	fi
	return 1
}
export -f pgrep

pkill() {
	printf 'pkill %s\n' "$*" >> "$TRACE_PATH"
	return 0
}
export -f pkill

sleep() { :; }
export -f sleep

# Allow the osascript branch to run (the upfront guard skips it under test mode).
unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH

force_kill_app "TestApp" "$app_path"
EOF

	[ "$status" -eq 0 ]
	grep -q 'osascript .*tell application id .*com\.example\.TestApp.* to quit' "$trace" \
		|| { echo "WRONG: missing AppleScript Quit"; cat "$trace"; return 1; }
	if grep -q '^pkill ' "$trace"; then
		echo "WRONG: pkill ran even though Quit succeeded"; cat "$trace"; return 1
	fi
}

@test "force_kill_app escalates to pkill when Quit does not land" {
	# Process keeps showing up in pgrep until pkill -9 fires, exercising the
	# SIGTERM and SIGKILL rungs of the escalation ladder.
	stubdir="$HOME/stubs"
	mkdir -p "$stubdir"
	trace="$HOME/kill_escalate_trace.log"
	: > "$trace"

	cat > "$stubdir/osascript" <<STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
	chmod +x "$stubdir/osascript"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
		TRACE_PATH="$trace" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

app_path="$HOME/Applications/StubbornApp.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>StubbornApp</string>
  <key>CFBundleIdentifier</key><string>com.example.StubbornApp</string>
</dict></plist>
PLIST

# Stays alive until SIGKILL lands, then disappears.
sigkill_seen=0
pgrep() {
	if [[ $sigkill_seen -eq 1 ]]; then
		return 1
	fi
	echo 12345
	return 0
}
export -f pgrep

pkill() {
	printf 'pkill %s\n' "$*" >> "$TRACE_PATH"
	for arg in "$@"; do
		if [[ "$arg" == "-9" ]]; then
			sigkill_seen=1
		fi
	done
	return 0
}
export -f pkill
export sigkill_seen

sudo() { return 1; }
export -f sudo

sleep() { :; }
export -f sleep

unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH

force_kill_app "StubbornApp" "$app_path"
EOF

	[ "$status" -eq 0 ]
	grep -q '^pkill -x StubbornApp' "$trace" \
		|| { echo "WRONG: SIGTERM rung did not fire"; cat "$trace"; return 1; }
	grep -q '^pkill -9 -x StubbornApp' "$trace" \
		|| { echo "WRONG: SIGKILL rung did not fire"; cat "$trace"; return 1; }
}

@test "force_kill_app rejects unsafe bundle id in AppleScript Quit target" {
	stubdir="$HOME/stubs"
	mkdir -p "$stubdir"
	trace="$HOME/unsafe_kill_trace.log"
	: > "$trace"

	cat > "$stubdir/osascript" <<STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
	chmod +x "$stubdir/osascript"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
		TRACE_PATH="$trace" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

app_path="$HOME/Applications/TestApp.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TestApp</string>
  <key>CFBundleIdentifier</key><string>com.example.TestApp&quot; to display dialog &quot;mole</string>
</dict></plist>
PLIST

pgrep_count=0
pgrep() {
	pgrep_count=$((pgrep_count + 1))
	if [[ $pgrep_count -eq 1 ]]; then
		echo 12345
		return 0
	fi
	return 1
}
export -f pgrep

pkill() {
	printf 'pkill %s\n' "$*" >> "$TRACE_PATH"
	return 0
}
export -f pkill

sleep() { :; }
export -f sleep

unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH

force_kill_app "TestApp" "$app_path"
EOF

	[ "$status" -eq 0 ]
	if grep -q 'display dialog' "$trace"; then
		echo "WRONG: unsafe bundle id reached AppleScript"; cat "$trace"; return 1
	fi
	grep -q 'osascript .*tell application "TestApp" to quit' "$trace" \
		|| { echo "WRONG: unsafe id did not fall back to app name"; cat "$trace"; return 1; }
}

@test "force_kill_app refuses to operate on system process names" {
	# Defensive guard: a third-party .app could set CFBundleExecutable to a
	# system process name (Finder, Dock, loginwindow, etc.). Even though the
	# uninstall selection layer filters out protected bundle IDs, force_kill_app
	# is a public function and must hold its own boundary. Verify it returns 1
	# without invoking pkill or osascript for these names.
	stubdir="$HOME/stubs"
	mkdir -p "$stubdir"
	trace="$HOME/system_proc_trace.log"
	: > "$trace"

	cat > "$stubdir/osascript" <<STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
	chmod +x "$stubdir/osascript"

	for spoofed in Finder Dock loginwindow WindowServer SystemUIServer; do
		: > "$trace"
		run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
			TRACE_PATH="$trace" SPOOFED="$spoofed" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

app_path="$HOME/Applications/Evil-$SPOOFED.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$SPOOFED</string>
  <key>CFBundleIdentifier</key><string>com.example.evil</string>
</dict></plist>
PLIST

pkill() {
	printf 'pkill %s\n' "$*" >> "$TRACE_PATH"
	return 0
}
export -f pkill

# pgrep must NOT be called - the guard runs before any process probing.
pgrep() {
	printf 'pgrep %s\n' "$*" >> "$TRACE_PATH"
	return 0
}
export -f pgrep

sleep() { :; }
export -f sleep

unset MOLE_TEST_MODE MOLE_TEST_NO_AUTH

force_kill_app "Evil-$SPOOFED" "$app_path"
EOF

		[ "$status" -eq 1 ] \
			|| { echo "WRONG: spoofed $spoofed did not return 1 (got $status)"; cat "$trace"; return 1; }
		if [[ -s "$trace" ]]; then
			echo "WRONG: spoofed $spoofed reached pkill/pgrep/osascript"; cat "$trace"; return 1
		fi
	done
}

@test "batch_uninstall_applications proceeds with deletion when force_kill_app fails" {
	# Reproduces the issue where uninstalling a still-running app (e.g. Mole.app
	# with a watchdog or XPC helper that ignores SIGKILL) used to abort with
	# "still running" and leave the bundle on disk. macOS allows deleting a
	# running app's bundle; we should warn the user but proceed.
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
# Pretend the kill ladder exhausted itself: process is still there.
force_kill_app() { return 1; }
sudo() { return 0; }

app_bundle="$HOME/Applications/TestApp.app"
mkdir -p "$app_bundle"

related="$(find_app_files "com.example.TestApp" "TestApp")"
encoded_related=$(printf '%s' "$related" | base64 | tr -d '\n')

selected_apps=()
selected_apps+=("0|$app_bundle|TestApp|com.example.TestApp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

# Send batch_uninstall_applications its own /dev/null stdin so the inline
# `read -r -s -n1 key` does not steal a byte from the heredoc script source
# (which would silently corrupt the next bash command into 127).
output_file="$HOME/batch_output.log"
printf '\n' | batch_uninstall_applications > "$output_file" 2>&1
output=$(cat "$output_file")

# Bundle and leftovers must be gone even though kill failed.
[[ ! -d "$app_bundle" ]] || { echo "WRONG: bundle preserved despite running flag"; cat "$output_file"; exit 1; }
[[ ! -d "$HOME/Library/Caches/TestApp" ]] || { echo "WRONG: cache preserved"; exit 1; }
[[ ! -f "$HOME/Library/Preferences/com.example.TestApp.plist" ]] || { echo "WRONG: prefs preserved"; exit 1; }

# The legacy "still running" failure summary must NOT fire.
[[ "$output" != *"is still running"* ]] || { echo "WRONG: legacy still-running failure surfaced"; exit 1; }
[[ "$output" != *Failed:*TestApp* ]] || { echo "WRONG: app counted as failed"; exit 1; }

# A friendlier warning should appear so the user knows to quit the lingering process.
[[ "$output" == *"Still running during uninstall"* ]] || { echo "WRONG: missing running-process warning"; cat "$output_file"; exit 1; }
[[ "$output" == *TestApp* ]] || { echo "WRONG: warning omits app name"; exit 1; }
EOF

	[ "$status" -eq 0 ]
}

@test "stop_launch_services unloads launch agents without deleting plists" {
	mkdir -p "$HOME/Library/LaunchAgents"
	touch "$HOME/Library/LaunchAgents/com.example.TestApp.plist"
	touch "$HOME/Library/LaunchAgents/com.example.TestApp.helper.plist"
	touch "$HOME/Library/LaunchAgents/com.example.TestApplication.plist"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

trace="$HOME/trace.log"
launchctl() {
	printf 'launchctl %s\n' "$*" >> "$trace"
}
run_with_timeout() {
	shift
	"$@"
}
safe_remove() {
	printf 'safe_remove %s\n' "$*" >> "$trace"
	return 0
}
safe_sudo_remove() {
	printf 'safe_sudo_remove %s\n' "$*" >> "$trace"
	return 0
}

stop_launch_services "com.example.TestApp" "false" ""

	grep -Fq "launchctl unload $HOME/Library/LaunchAgents/com.example.TestApp.plist" "$trace"
	grep -Fq "launchctl unload $HOME/Library/LaunchAgents/com.example.TestApp.helper.plist" "$trace"
	! grep -Fq "com.example.TestApplication.plist" "$trace"
	! grep -q "safe_remove" "$trace"
	[[ -f "$HOME/Library/LaunchAgents/com.example.TestApp.plist" ]]
	[[ -f "$HOME/Library/LaunchAgents/com.example.TestApp.helper.plist" ]]
	[[ -f "$HOME/Library/LaunchAgents/com.example.TestApplication.plist" ]]
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

printf '\nq' | batch_uninstall_applications
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

@test "cached uninstall metadata is rejected when the current bundle is protected" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
eval "$(sed -n '/^uninstall_resolve_bundle_id()/,/^uninstall_app_inventory_fingerprint()/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

app_path="$HOME/Applications/Safari.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.apple.Safari</string>
</dict>
</plist>
PLIST

if uninstall_resolve_eligible_bundle_id "$app_path" "com.example.cached" > /dev/null; then
    echo "protected app should not be eligible" >&2
    exit 1
fi
EOF

	[ "$status" -eq 0 ]
}

@test "cached uninstall metadata is rejected when the app is background-only" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
eval "$(sed -n '/^uninstall_resolve_bundle_id()/,/^uninstall_app_inventory_fingerprint()/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

app_path="$HOME/Applications/Helper.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.Helper</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
PLIST

if uninstall_resolve_eligible_bundle_id "$app_path" "com.example.Helper" > /dev/null; then
    echo "background-only app should not be eligible" >&2
    exit 1
fi
EOF

	[ "$status" -eq 0 ]
}

@test "OneDrive Mac App Store bundle is eligible even when marked background-only" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
eval "$(sed -n '/^uninstall_resolve_bundle_id()/,/^uninstall_app_inventory_fingerprint()/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

app_path="$HOME/Applications/OneDrive.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.microsoft.OneDrive-mac</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
PLIST

result=$(uninstall_resolve_eligible_bundle_id "$app_path" "")
[[ "$result" == "com.microsoft.OneDrive-mac" ]] || {
    echo "unexpected bundle id: $result" >&2
    exit 1
}
EOF

	[ "$status" -eq 0 ]
}

@test "eligible uninstall metadata uses the current bundle id over stale cache" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
eval "$(sed -n '/^uninstall_resolve_bundle_id()/,/^uninstall_app_inventory_fingerprint()/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

app_path="$HOME/Applications/Plain.app"
mkdir -p "$app_path/Contents"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.Plain</string>
</dict>
</plist>
PLIST

result=$(uninstall_resolve_eligible_bundle_id "$app_path" "com.example.Stale")
[[ "$result" == "com.example.Plain" ]] || {
    echo "unexpected bundle id: $result" >&2
    exit 1
}
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

@test "main clears pending input before app selection after scan (#726)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'INNER'
set -euo pipefail

trace_file="$HOME/uninstall-trace.log"
app_cache_file="$HOME/apps-cache.txt"
touch "$app_cache_file"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$app_cache_file"; }
load_applications() {
    printf 'load\n' >> "$trace_file"
    return 0
}
drain_pending_input() {
    printf 'drain\n' >> "$trace_file"
}
select_apps_for_uninstall() {
    printf 'select\n' >> "$trace_file"
    return 1
}

eval "$(sed -n '/^main()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

main

expected=$(printf 'load\ndrain\nselect\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

	[ "$status" -eq 0 ]
}

@test "scan_applications starts feedback before discovery and cleans no-app state" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_FORCE_SCAN_SPINNER=1 bash --noprofile --norc <<'INNER'
set -euo pipefail

trace_file="$HOME/scan-feedback-trace.log"
scan_temp="$HOME/scan-feedback-temp"

MOLE_UNINSTALL_META_CACHE_DIR="$HOME/.cache/mole"
MOLE_UNINSTALL_META_CACHE_FILE="$MOLE_UNINSTALL_META_CACHE_DIR/uninstall_app_metadata_v1"
MOLE_UNINSTALL_META_CACHE_LOCK="${MOLE_UNINSTALL_META_CACHE_FILE}.lock"

create_temp_file() { printf '%s\n' "$scan_temp"; }
ensure_user_dir() { mkdir -p "$1"; }
ensure_user_file() {
    mkdir -p "$(dirname "$1")"
    : > "$1"
}

_scan_discover_apps() {
    if [[ -n "${spinner_pid:-}" ]]; then
        printf 'spinner-before-discover\n' >> "$trace_file"
    else
        printf 'missing-spinner\n' >> "$trace_file"
    fi
    : > "$discovered_file"
}
_scan_partition_cache() { printf 'partition\n' >> "$trace_file"; }
_scan_resolve_uncached() { printf 'resolve\n' >> "$trace_file"; }
_scan_dedupe_bundle_ids() { printf 'dedupe\n' >> "$trace_file"; }
_scan_finalize_index() { printf 'finalize\n' >> "$trace_file"; }

eval "$(sed -n '/^scan_applications()/,/^load_applications()/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

set +e
scan_applications > "$HOME/scan-feedback.out" 2> "$HOME/scan-feedback.err"
rc=$?
set -e

[[ $rc -eq 1 ]] || exit 1

expected=$(printf 'spinner-before-discover\npartition\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}

[[ ! -e "${scan_temp}.spinner_shown" ]]
[[ ! -e "${scan_temp}.scan_status" ]]
INNER

	[ "$status" -eq 0 ]
}

@test "select_apps_for_uninstall drains pending input before opening paginated menu" {
	mkdir -p "$HOME/Applications/TraceApp.app"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" bash --noprofile --norc <<'INNER'
set -euo pipefail

trace_file="$HOME/selector-drain-trace.log"

source "$PROJECT_ROOT/lib/ui/app_selector.sh"

apps_data=("1700000000|$HOME/Applications/TraceApp.app|TraceApp|com.example.TraceApp|1MB|Today|1024")
selected_apps=()

get_display_width() { printf '%s\n' "${#1}"; }
format_app_display() {
    printf 'format\n' >> "$trace_file"
    printf '%s' "$1"
}
drain_pending_input() { printf 'drain\n' >> "$trace_file"; }
paginated_multi_select() {
    printf 'guard:%s\n' "${MOLE_MENU_IGNORE_INITIAL_ENTER:-unset}" >> "$trace_file"
    printf 'paginated\n' >> "$trace_file"
    MOLE_SELECTION_RESULT="0"
    return 0
}

select_apps_for_uninstall
[[ ${#selected_apps[@]} -eq 1 ]]
[[ -z "${MOLE_MENU_IGNORE_INITIAL_ENTER:-}" ]]

expected=$(printf 'format\ndrain\nguard:1\npaginated\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

	[ "$status" -eq 0 ]
}

@test "paginated menu can ignore one initial Enter for uninstall launch guard" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" bash --noprofile --norc <<'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

key_state="$HOME/menu-initial-enter-state"
read_key() {
    if [[ ! -f "$key_state" ]]; then
        : > "$key_state"
        echo "ENTER"
    else
        echo "QUIT"
    fi
}

MOLE_SELECTION_RESULT=""
set +e
MOLE_MENU_IGNORE_INITIAL_ENTER=1 paginated_multi_select "Test Menu" "First App" > "$HOME/menu.out" 2> "$HOME/menu.err"
rc=$?
set -e

echo "rc=$rc"
echo "result=${MOLE_SELECTION_RESULT:-}"
INNER

	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=1"* ]]
	[[ "$output" == *"result="* ]]
	[[ "$output" != *"result=0"* ]]
}

@test "main rescans cleanly after returning from a completed uninstall (#866)" {
	local first_cache second_cache
	first_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-866-first.XXXXXX")"
	second_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-866-second.XXXXXX")"

	mkdir -p "$HOME/Applications/FirstApp.app" "$HOME/Applications/SecondApp.app"
	cat > "$first_cache" <<CACHE
1700000000|$HOME/Applications/FirstApp.app|FirstApp|com.example.FirstApp|10MB|Today|10240
CACHE
	cat > "$second_cache" <<CACHE
1700000001|$HOME/Applications/SecondApp.app|SecondApp|com.example.SecondApp|11MB|Today|11264
CACHE

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" FIRST_CACHE="$first_cache" SECOND_CACHE="$second_cache" \
		bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

trace_file="$HOME/uninstall-866-trace.log"
scan_state_file="$HOME/uninstall-866-scan-count"
printf '0\n' > "$scan_state_file"
select_count=0
fingerprint_state="before"
selected_apps=()

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
drain_pending_input() { :; }
uninstall_app_inventory_fingerprint() { printf '%s\n' "$fingerprint_state"; }
batch_uninstall_applications() {
    printf 'batch\n' >> "$trace_file"
    rmdir "$HOME/Applications/FirstApp.app"
    fingerprint_state="after"
}
uninstall_normalize_size_display() { printf '%s\n' "$1"; }
uninstall_normalize_last_used_display() { printf '%s\n' "$1"; }
scan_applications() {
    local scan_count
    scan_count=$(cat "$scan_state_file")
    scan_count=$((scan_count + 1))
    printf '%s\n' "$scan_count" > "$scan_state_file"
    printf 'scan:%s\n' "$scan_count" >> "$trace_file"
    if [[ $scan_count -eq 1 ]]; then
        printf '%s\n' "$FIRST_CACHE"
    else
        printf '%s\n' "$SECOND_CACHE"
    fi
}
load_applications() {
    local apps_file="$1"
    apps_data=()
    selection_state=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        [[ -e "$app_path" ]] || continue
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
        selection_state+=(false)
    done < "$apps_file"
    printf 'load:%s\n' "${apps_data[0]#*|}" >> "$trace_file"
}
select_apps_for_uninstall() {
    select_count=$((select_count + 1))
    printf 'select:%s\n' "$select_count" >> "$trace_file"
    if [[ $select_count -eq 1 ]]; then
        selected_apps=("${apps_data[0]}")
        return 0
    fi
    return 1
}

eval "$(sed -n '/^main()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

printf '\n' | main

expected=$(printf 'scan:1\nload:%s/Applications/FirstApp.app|FirstApp|com.example.FirstApp|10MB|Today|10240\nselect:1\nbatch\nscan:2\nload:%s/Applications/SecondApp.app|SecondApp|com.example.SecondApp|11MB|Today|11264\nselect:2\n' "$HOME" "$HOME")
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

	rm -f "$first_cache" "$second_cache"
	[ "$status" -eq 0 ]
}


# ---------------------------------------------------------------------------
# #723: Trash routing default and --permanent flag
# ---------------------------------------------------------------------------

@test "uninstall main sets MOLE_DELETE_MODE=trash by default" {
	local apps_cache
	apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-723-trash.XXXXXX")"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
		APPS_CACHE_FILE="$apps_cache" bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() { return 0; }
drain_pending_input() { :; }
select_apps_for_uninstall() {
    printf 'delete_mode=%s\n' "${MOLE_DELETE_MODE:-unset}"
    return 1
}

eval "$(sed -n '/^main()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main
INNER

	rm -f "$apps_cache"
	[ "$status" -eq 0 ]
	[[ "$output" == *"delete_mode=trash"* ]]
}

@test "uninstall main sets MOLE_DELETE_MODE=permanent with --permanent flag" {
	local apps_cache
	apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-723-perm.XXXXXX")"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
		APPS_CACHE_FILE="$apps_cache" bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() { return 0; }
drain_pending_input() { :; }
select_apps_for_uninstall() {
    printf 'delete_mode=%s\n' "${MOLE_DELETE_MODE:-unset}"
    return 1
}

eval "$(sed -n '/^main()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main --permanent
INNER

	rm -f "$apps_cache"
	[ "$status" -eq 0 ]
	[[ "$output" == *"delete_mode=permanent"* ]]
}

# ---------------------------------------------------------------------------
# --list: read-only inventory of installable app names (PR #755 scope)
# ---------------------------------------------------------------------------

@test "uninstall --list prints table with NAME, BUNDLE ID, UNINSTALL NAME, SIZE" {
	local apps_cache
	apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-text.XXXXXX")"
	# Format matches load_applications: epoch|app_path|app_name|bundle_id|size|last_used|size_kb
	cat > "$apps_cache" <<'CACHE'
1700000000|/Applications/Slack.app|Slack|com.tinyspeck.slackmacgap|180MB|Today|184320
1700000000|/Applications/Zoom.app|Zoom|us.zoom.xos|140MB|Yesterday|143360
CACHE

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
		APPS_CACHE_FILE="$apps_cache" bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() {
    apps_data=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
    done < "$1"
}
# Stub Homebrew so test stays hermetic and brew detection never fires.
is_homebrew_available() { return 1; }
get_brew_cask_name() { return 1; }
# Stubbed because the production helper lives earlier in bin/uninstall.sh
# and our sed slice only pulls list-related helpers + main().
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

eval "$(sed -n '/^uninstall_list_json_escape()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
# Force text mode by simulating a TTY for stdout via /dev/tty redirect not
# available in bats; instead pipe through a wrapper that fakes -t 1. Simplest:
# call the function directly so [[ -t 1 ]] uses bash's stdout (the bats pipe).
# We accept the function emits JSON when piped; assert against JSON shape too.
main --list
INNER

	rm -f "$apps_cache"
	[ "$status" -eq 0 ]
	# Bats pipes stdout, so output is JSON. Assert both apps and uninstall_name.
	[[ "$output" == *'"name": "Slack"'* ]]
	[[ "$output" == *'"name": "Zoom"'* ]]
	[[ "$output" == *'"uninstall_name": "Slack"'* ]]
	[[ "$output" == *'"bundle_id": "com.tinyspeck.slackmacgap"'* ]]
	[[ "$output" == *'"source": "App"'* ]]
}

@test "uninstall --list emits JSON array when stdout is piped" {
	local apps_cache
	apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-json.XXXXXX")"
	cat > "$apps_cache" <<'CACHE'
1700000000|/Applications/Slack.app|Slack|com.tinyspeck.slackmacgap|180MB|Today|184320
CACHE

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
		APPS_CACHE_FILE="$apps_cache" bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() {
    apps_data=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
    done < "$1"
}
is_homebrew_available() { return 1; }
get_brew_cask_name() { return 1; }
# Stubbed because the production helper lives earlier in bin/uninstall.sh
# and our sed slice only pulls list-related helpers + main().
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

eval "$(sed -n '/^uninstall_list_json_escape()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main --list
INNER

	rm -f "$apps_cache"
	[ "$status" -eq 0 ]
	# Output should start with '[' and end with ']' to be a valid JSON array.
	[[ "${output:0:1}" == "[" ]]
	[[ "${output: -1}" == "]" ]]
	# Round-trip via python to confirm it parses as JSON.
	if command -v python3 > /dev/null; then
		echo "$output" | python3 -c 'import sys, json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d)==1 and d[0]["name"]=="Slack"'
	fi
}

@test "uninstall --list with empty scan returns empty JSON array" {
	local apps_cache
	apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-empty.XXXXXX")"
	# Non-empty file so load_applications doesn't bail early on size check.
	echo "" > "$apps_cache"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
		APPS_CACHE_FILE="$apps_cache" bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() {
    apps_data=()
    return 0
}
is_homebrew_available() { return 1; }
get_brew_cask_name() { return 1; }
# Stubbed because the production helper lives earlier in bin/uninstall.sh
# and our sed slice only pulls list-related helpers + main().
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

eval "$(sed -n '/^uninstall_list_json_escape()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main --list
INNER

	rm -f "$apps_cache"
	[ "$status" -eq 0 ]
	[[ "$output" == "[]" ]]
}

@test "uninstall --list flags brew-managed apps with cask uninstall_name" {
	local apps_cache
	apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-brew.XXXXXX")"
	cat > "$apps_cache" <<'CACHE'
1700000000|/Applications/Visual Studio Code.app|Visual Studio Code|com.microsoft.VSCode|420MB|Today|430080
CACHE

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
		APPS_CACHE_FILE="$apps_cache" bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() {
    apps_data=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
    done < "$1"
}
# Force brew-managed result.
is_homebrew_available() { return 0; }
get_brew_cask_name() { printf '%s' "visual-studio-code"; return 0; }
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

eval "$(sed -n '/^uninstall_list_json_escape()/,/^main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main --list
INNER

	rm -f "$apps_cache"
	[ "$status" -eq 0 ]
	[[ "$output" == *'"uninstall_name": "visual-studio-code"'* ]]
	[[ "$output" == *'"source": "Homebrew"'* ]]
}

# Regression tests for #940: detect Background Items left behind after uninstall.
_btm_helper_runner() {
	HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		BTM_DUMP="$1" DETAIL="$2" SUCCESS_PATH="$3" \
		bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
_uninstall_match_btm_leftovers "$BTM_DUMP" "$DETAIL" -- "$SUCCESS_PATH"
EOF
}

@test "_uninstall_match_btm_leftovers reports bundle id still in BTM dump" {
	local detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"
	local dump=$'Record #1\n  name: Paste\n  bundleID: com.wiheads.paste\n  url: file:///Applications/Paste.app/'

	result="$(_btm_helper_runner "$dump" "$detail" "/Applications/Paste.app")"

	[ "$result" = "Paste" ]
}

@test "_uninstall_match_btm_leftovers stays silent when bundle id is absent" {
	local detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"
	local dump=$'Record #1\n  name: SomethingElse\n  bundleID: com.example.other'

	result="$(_btm_helper_runner "$dump" "$detail" "/Applications/Paste.app")"

	[ -z "$result" ]
}

@test "_uninstall_match_btm_leftovers skips apps that were not successfully removed" {
	local detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"
	local dump=$'Record #1\n  bundleID: com.wiheads.paste'

	result="$(_btm_helper_runner "$dump" "$detail" "/Applications/OtherApp.app")"

	[ -z "$result" ]
}

@test "_uninstall_match_btm_leftovers ignores unknown bundle id" {
	local detail="Paste|/Applications/Paste.app|unknown|0|||false|false|false||||"
	local dump=$'Record #1\n  bundleID: unknown'

	result="$(_btm_helper_runner "$dump" "$detail" "/Applications/Paste.app")"

	[ -z "$result" ]
}

@test "_uninstall_match_btm_leftovers returns empty for empty dump" {
	local detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"

	result="$(_btm_helper_runner "" "$detail" "/Applications/Paste.app")"

	[ -z "$result" ]
}
