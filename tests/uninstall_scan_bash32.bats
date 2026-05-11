#!/usr/bin/env bats

# Regression for #863 — "Can't Open App List, Scanning forever."
#
# macOS ships /bin/bash 3.2 (Apple does not upgrade past it, GPLv3). The
# bin/uninstall.sh shebang is `#!/bin/bash`, so the installed script runs
# under 3.2 regardless of any Homebrew bash also on the system. Under
# `set -u`, bash 3.2 treats `"${empty_array[@]}"` as an unbound expansion
# rather than expanding to zero elements.
#
# scan_applications declares `local -a app_data_tuples=()` and only appends
# rows for apps that miss the warm metadata cache (uncached_rows_file). When
# every discovered app is satisfied by the cache, app_data_tuples stays
# empty while scan_raw_file is non-empty (use_cached_scan_metadata already
# wrote rows to it). The early-return at the `[[ ... && ! -s ... ]]` guard
# therefore does not fire, and the subsequent `for ... in
# "${app_data_tuples[@]}"` iteration aborts with
# "app_data_tuples[@]: unbound variable".

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT
}

setup() {
	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-scan-bash32.XXXXXX")"
	export HOME
	export TERM="dumb"
}

teardown() {
	rm -rf "$HOME"
}

# Build a sourceable copy of bin/uninstall.sh: rewrites SCRIPT_DIR so library
# sources resolve, and strips the `main "$@"` invocation so we can drive
# scan_applications directly. Mirrors tests/performance_uninstall_scan.sh.
sourceable_uninstall_sh() {
	local out="$1"
	awk -v script_dir="$PROJECT_ROOT/bin" '
		/^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" script_dir "\""; next }
		/^main "\$@"/ { print "# main skipped by test"; next }
		{ print }
	' "$PROJECT_ROOT/bin/uninstall.sh" > "$out"
}

@test "scan_applications: Pass 2 tolerates empty app_data_tuples on /bin/bash 3.2 (#863)" {
	src="$HOME/uninstall_source.sh"
	sourceable_uninstall_sh "$src"

	apps_root="$HOME/Applications"
	mkdir -p "$apps_root/TestApp.app/Contents"
	: > "$apps_root/TestApp.app/Contents/Info.plist"

	# Seed the warm metadata cache so that the one discovered app
	# (TestApp.app) is a cache hit: matching mtime, non-empty bundle id
	# and display name are the conditions the awk classifier and
	# use_cached_scan_metadata require for the cached branch to "stick".
	app_mtime="$(stat -f %m "$apps_root/TestApp.app")"
	cache_dir="$HOME/.cache/mole"
	mkdir -p "$cache_dir"
	printf '%s|%s|0|0|0|com.test.TestApp|TestApp\n' \
		"$apps_root/TestApp.app" "$app_mtime" \
		> "$cache_dir/uninstall_app_metadata_v1"

	done_marker="$HOME/scan.done"

	# The bug not only emits "unbound variable" — the spinner subshell
	# `( ... ) &` launched just before the failing iteration keeps running
	# after the parent script errors out (its `while true` loop has no
	# inherited signal). The user-visible symptom is exactly "scanning
	# forever". Mirror the marker-file watchdog from the #722 hang test
	# (uninstall.bats: "uninstall_persist_cache_file does not hang…") so a
	# regression surfaces as HANG rather than blocking the whole bats run.
	(
		env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
			MOLE_TEST_NO_AUTH=1 \
			APPS_ROOT="$apps_root" SRC_PATH="$src" \
			/bin/bash --noprofile --norc <<'EOF' > "$HOME/scan.out" 2> "$HOME/scan.err"
set -euo pipefail

# shellcheck source=/dev/null
source "$SRC_PATH"

# Restrict the discovered search dirs to our sandboxed Applications folder
# so scan_applications does not pick up real /Applications and dilute the
# all-cached condition we are exercising.
uninstall_print_app_search_dirs() { printf '%s\n' "$APPS_ROOT"; }

# Bundle-id resolution would otherwise call /usr/bin/mdls and reject our
# placeholder Info.plist. The cached branch only needs an echo-through here.
uninstall_resolve_eligible_bundle_id() { printf '%s\n' "${2:-${1##*/}}"; }

scan_applications > /dev/null
EOF
		: > "$done_marker"
	) &
	bgpid=$!

	# Poll for completion marker for up to ~5s.
	for _ in $(seq 1 50); do
		[[ -e "$done_marker" ]] && break
		sleep 0.1
	done

	status_msg=""
	if [[ ! -e "$done_marker" ]]; then
		kill -TERM "$bgpid" 2> /dev/null || true
		# Reap the orphaned spinner subshell so it does not leak into the
		# next test or the rest of the run.
		pkill -P "$bgpid" 2> /dev/null || true
		status_msg="HANG"
	fi
	wait "$bgpid" 2> /dev/null || true

	[[ -z "$status_msg" ]] || {
		echo "scan_applications hung — Pass 2 guard regressed" >&2
		echo "stderr captured:" >&2
		cat "$HOME/scan.err" >&2 2> /dev/null || true
		false
	}
	# Use `run` + status check rather than bare `! grep`: bats SC2314 rejects
	# a trailing `!` because earlier bats versions ignored it. `run` records
	# the inverted status explicitly so the assertion is portable.
	run grep -q 'unbound variable' "$HOME/scan.err"
	[ "$status" -ne 0 ]
}

@test "scan_applications includes Artpaper's two-segment bundle id (#861)" {
	src="$HOME/uninstall_source.sh"
	sourceable_uninstall_sh "$src"

	apps_root="$HOME/Applications"
	app_path="$apps_root/Artpaper.app"
	mkdir -p "$app_path/Contents"
	cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>andriiliakh.Artpaper</string>
    <key>CFBundleName</key>
    <string>Artpaper</string>
</dict>
</plist>
PLIST

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TEST_NO_AUTH=1 APPS_ROOT="$apps_root" SRC_PATH="$src" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail

# shellcheck source=/dev/null
source "$SRC_PATH"

uninstall_print_app_search_dirs() { printf '%s\n' "$APPS_ROOT"; }

apps_file=$(scan_applications)
cat "$apps_file"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"|$app_path|Artpaper|andriiliakh.Artpaper|"* ]]
}
