#!/usr/bin/env bats
# shellcheck disable=SC2016  # inner bash scripts expand their own arguments

load helpers/common

setup_file() {
	mole_test_setup_home slim-home
	FIXTURE_BIN_DIR="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-slim-bin.XXXXXX")"
	export FIXTURE_BIN_DIR
	SLIM_HAVE_FAT_TOOLCHAIN=0
	if command -v clang > /dev/null 2>&1 && xcode-select -p > /dev/null 2>&1; then
		printf 'int main(void) { return 0; }\n' > "$FIXTURE_BIN_DIR/main.c"
		printf 'int mole_fixture(void) { return 1; }\n' > "$FIXTURE_BIN_DIR/lib.c"
		if clang -arch arm64 -arch x86_64 -o "$FIXTURE_BIN_DIR/fat-exe" "$FIXTURE_BIN_DIR/main.c" 2> /dev/null &&
			clang -dynamiclib -arch arm64 -arch x86_64 -o "$FIXTURE_BIN_DIR/fat.dylib" "$FIXTURE_BIN_DIR/lib.c" 2> /dev/null; then
			SLIM_HAVE_FAT_TOOLCHAIN=1
		fi
	fi
	export SLIM_HAVE_FAT_TOOLCHAIN
}

teardown_file() {
	if [[ "$FIXTURE_BIN_DIR" == "${BATS_TEST_DIRNAME}/tmp-slim-bin."* ]]; then
		rm -rf "$FIXTURE_BIN_DIR" # SAFE: test-owned mktemp fixture directory
	fi
	mole_test_teardown_home
}

setup() {
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	export TERM="xterm-256color"
	export MO_DEBUG=0
	export MO_NO_OPLOG=1
	APPS_ROOT="$BATS_TEST_TMPDIR/apps"
	TRASH_DIR="$BATS_TEST_TMPDIR/trash"
	mkdir -p "$APPS_ROOT" "$TRASH_DIR"
}

# Build a signed bundle whose main executable and Frameworks dylib are nested
# code, plus a universal tool in SharedSupport that the seal records by hash.
make_fixture_app() {
	local app="$APPS_ROOT/Fixture.app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/SharedSupport"
	cat > "$app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Fixture</string>
	<key>CFBundleIdentifier</key>
	<string>com.example.molefixture</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
</dict>
</plist>
PLIST
	cp "$FIXTURE_BIN_DIR/fat-exe" "$app/Contents/MacOS/Fixture"
	cp "$FIXTURE_BIN_DIR/fat.dylib" "$app/Contents/Frameworks/libfixture.dylib"
	cp "$FIXTURE_BIN_DIR/fat-exe" "$app/Contents/SharedSupport/tool"
	codesign -s - "$app/Contents/Frameworks/libfixture.dylib" > /dev/null 2>&1
	codesign -s - "$app" > /dev/null 2>&1
	printf '%s\n' "$app"
}

slim_env() {
	env HOME="$HOME" PATH="$PATH" MO_NO_OPLOG=1 MOLE_TEST_MODE=1 \
		MOLE_TEST_TRASH_DIR="$TRASH_DIR" MOLE_SLIM_TEST_APP_ROOTS="$APPS_ROOT" \
		MOLE_DELETE_LOG="$BATS_TEST_TMPDIR/deletions.log" "$@"
}

@test "slim.sh rejects unknown options" {
	run "$PROJECT_ROOT/bin/slim.sh" --unknown-option

	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown option"* ]]
}

@test "mo slim is routed and listed in help" {
	run env HOME="$HOME" "$PROJECT_ROOT/mole" slim --help

	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage: mo slim"* ]] || return 1
	run env HOME="$HOME" "$PROJECT_ROOT/mole" --help
	[[ "$output" == *"mo slim"* ]]
}

@test "slim refuses on an Intel host and says why" {
	run slim_env MOLE_SLIM_TEST_HOST_ARM64=0 /bin/bash -c '
		source "$1"
		main --dry-run
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 1 ]
	[[ "$output" == *"needs an Apple Silicon Mac"* ]]
}

@test "slim_fat_slices reads fat and fat64 headers the way lipo does" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	lipo "$FIXTURE_BIN_DIR/fat-exe" -thin arm64 -output "$BATS_TEST_TMPDIR/a" || return 1
	lipo "$FIXTURE_BIN_DIR/fat-exe" -thin x86_64 -output "$BATS_TEST_TMPDIR/x" || return 1
	lipo -create -fat64 "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/x" -output "$BATS_TEST_TMPDIR/fat64-exe" || return 1
	[[ "$(od -An -tx1 -N4 "$BATS_TEST_TMPDIR/fat64-exe" | tr -d ' ')" == "cafebabf" ]] || return 1

	local file expected actual
	for file in "$FIXTURE_BIN_DIR/fat-exe" "$BATS_TEST_TMPDIR/fat64-exe"; do
		expected=$(lipo -detailed_info "$file" | awk '
			$1 == "architecture" { arch = $2 }
			$1 == "offset" { off = $2 }
			$1 == "size" { print arch, off, $2 }
		' | sort)
		actual=$(MOLE_TEST_MODE=1 /bin/bash -c 'source "$1"; slim_fat_slices "$2"' bash "$PROJECT_ROOT/bin/slim.sh" "$file" | sort)
		[[ -n "$actual" && "$actual" == "$expected" ]] || {
			printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual"
			return 1
		}
	done

	cp "$BATS_TEST_TMPDIR/fat64-exe" "$BATS_TEST_TMPDIR/thin-me"
	MOLE_TEST_MODE=1 /bin/bash -c 'source "$1"; slim_thin_file "$2"' bash "$PROJECT_ROOT/bin/slim.sh" "$BATS_TEST_TMPDIR/thin-me" || return 1
	lipo "$BATS_TEST_TMPDIR/fat64-exe" -thin arm64 -output "$BATS_TEST_TMPDIR/lipo-thin"
	cmp "$BATS_TEST_TMPDIR/thin-me" "$BATS_TEST_TMPDIR/lipo-thin"
}

@test "slim runs without developer tools and never calls lipo or xcode-select" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	mole_test_fake_command spctl 'exit 0'
	mole_test_fake_command lipo 'echo DEVTOOL_RAN lipo >&2; exit 97'
	mole_test_fake_command xcode-select 'echo DEVTOOL_RAN xcode-select >&2; exit 97'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed failed=$total_failed"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=1 failed=0"* ]] || return 1
	[[ "$output" != *"DEVTOOL_RAN"* ]] || return 1
	[[ "$(file -b "$app/Contents/MacOS/Fixture")" == "Mach-O 64-bit executable arm64" ]]
}

@test "slim_cdhash_sealed_keys lists only files2 entries sealed by cdhash" {
	local plist="$BATS_TEST_TMPDIR/CodeResources"
	cat > "$plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>files</key>
	<dict>
		<key>Frameworks/Legacy.dylib</key>
		<data>AAAA</data>
	</dict>
	<key>files2</key>
	<dict>
		<key>Frameworks/Nested.framework</key>
		<dict>
			<key>cdhash</key>
			<data>AAAA</data>
			<key>requirement</key>
			<string>identifier "x"</string>
		</dict>
		<key>Helpers/R&amp;D tool</key>
		<dict>
			<key>cdhash</key>
			<data>AAAA</data>
		</dict>
		<key>Libraries/libffmpeg.dylib</key>
		<dict>
			<key>hash2</key>
			<data>AAAA</data>
		</dict>
		<key>Resources/empty</key>
		<dict/>
	</dict>
	<key>rules</key>
	<dict>
		<key>cdhash</key>
		<dict>
			<key>cdhash</key>
			<true/>
		</dict>
	</dict>
</dict>
</plist>
PLIST

	run /bin/bash -c '
		export MOLE_TEST_MODE=1
		source "$1"
		slim_cdhash_sealed_keys "$2"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$plist"

	[ "$status" -eq 0 ]
	[ "$output" = $'Frameworks/Nested.framework\nHelpers/R&D tool' ]
}

@test "slim_skip_reason keeps App Store, Apple, Rosetta and symlinked apps out" {
	local app
	for app in Store Apple Rosetta Plain; do
		mkdir -p "$APPS_ROOT/$app.app/Contents"
	done
	mkdir -p "$APPS_ROOT/Store.app/Contents/_MASReceipt"
	plutil -create xml1 "$APPS_ROOT/Store.app/Contents/Info.plist"
	plutil -insert CFBundleIdentifier -string com.example.store "$APPS_ROOT/Store.app/Contents/Info.plist"
	plutil -create xml1 "$APPS_ROOT/Apple.app/Contents/Info.plist"
	plutil -insert CFBundleIdentifier -string com.apple.Example "$APPS_ROOT/Apple.app/Contents/Info.plist"
	plutil -create xml1 "$APPS_ROOT/Rosetta.app/Contents/Info.plist"
	plutil -insert CFBundleIdentifier -string com.example.rosetta "$APPS_ROOT/Rosetta.app/Contents/Info.plist"
	plutil -create xml1 "$APPS_ROOT/Plain.app/Contents/Info.plist"
	plutil -insert CFBundleIdentifier -string com.example.plain "$APPS_ROOT/Plain.app/Contents/Info.plist"
	ln -s "$APPS_ROOT/Plain.app" "$APPS_ROOT/Link.app"
	local ls_dir="$HOME/Library/Preferences/com.apple.LaunchServices"
	mkdir -p "$ls_dir"
	cat > "$ls_dir/com.apple.LaunchServices.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>LSArchitecturesForX86_64</key>
	<dict>
		<key>com.example.rosetta</key>
		<array>
			<string>x86_64</string>
		</array>
	</dict>
</dict>
</plist>
PLIST

	run slim_env /bin/bash -c '
		source "$1"
		for app in Store Apple Rosetta Link Plain; do
			printf "%s=%s\n" "$app" "$(slim_skip_reason "$2/$app.app" false)"
		done
	' bash "$PROJECT_ROOT/bin/slim.sh" "$APPS_ROOT"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Store=App Store app"* ]] || return 1
	[[ "$output" == *"Apple=Apple app"* ]] || return 1
	[[ "$output" == *"Rosetta=set to open using Rosetta"* ]] || return 1
	[[ "$output" == *"Link=symlink"* ]] || return 1
	[[ "$output" == *"Plain="$'\n'* || "$output" == *"Plain=" ]]
}

@test "slim plans the main executable and nested dylib but not a hash-sealed tool" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)

	run slim_env /bin/bash -c '
		source "$1"
		plan=$(mktemp)
		slim_plan_app "$2" "$plan" > /dev/null
		cut -f1 "$plan" | sort
	' bash "$PROJECT_ROOT/bin/slim.sh" "$app"

	[ "$status" -eq 0 ]
	[ "$output" = $'Contents/Frameworks/libfixture.dylib\nContents/MacOS/Fixture' ]
}

@test "slim replaces a verified copy and moves the original to Trash" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	mole_test_fake_command spctl 'exit 0'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed failed=$total_failed"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=1 failed=0"* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == "arm64" ]] || return 1
	[[ "$(lipo -archs "$app/Contents/Frameworks/libfixture.dylib")" == "arm64" ]] || return 1
	[[ "$(lipo -archs "$app/Contents/SharedSupport/tool")" == *x86_64* ]] || return 1
	codesign --verify --deep --strict "$app" || return 1
	local trashed=("$TRASH_DIR"/Fixture.app.*)
	[[ -d "${trashed[0]}" ]] || return 1
	[[ "$(lipo -archs "${trashed[0]}/Contents/MacOS/Fixture")" == *x86_64* ]]
}

@test "slim keeps the original untouched when the copy fails Gatekeeper" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app before
	app=$(make_fixture_app)
	before=$(stat -f '%i' "$app/Contents/MacOS/Fixture")
	mole_test_fake_command spctl 'exit 3'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed failed=${SLIM_FAILURES[*]}"
		ls "$SLIM_WORK_DIR"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=0 failed=Fixture.app (Gatekeeper check failed)"* ]] || return 1
	[[ "$output" != *"app."* ]] || return 1
	[[ "$(stat -f '%i' "$app/Contents/MacOS/Fixture")" == "$before" ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == *x86_64* ]] || return 1
	[ -z "$(ls -A "$TRASH_DIR")" ]
}

add_finder_info() {
	local path
	for path in "$@"; do
		xattr -wx com.apple.FinderInfo 0000000000000000000400000000000000000000000000000000000000000000 "$path"
	done
}

@test "slim strips Finder info on the copy when it is the only strict verify failure" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	add_finder_info "$app" "$app/Contents" "$app/Contents/MacOS"
	run codesign --verify --deep --strict "$app"
	[[ "$output" == *"detritus not allowed"* ]] || skip "codesign does not flag Finder info here"
	mole_test_fake_command spctl 'exit 0'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed failed=$total_failed"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=1 failed=0"* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == "arm64" ]] || return 1
	codesign --verify --deep --strict "$app" || return 1
	local trashed=("$TRASH_DIR"/Fixture.app.*)
	[[ -d "${trashed[0]}" ]] || return 1
	xattr -p com.apple.FinderInfo "${trashed[0]}/Contents" > /dev/null
}

@test "slim keeps an app whose seal is broken under the Finder info" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	printf 'x' >> "$app/Contents/SharedSupport/tool"
	# real codesign reports the broken seal first, so make detritus mask it
	mole_test_fake_command codesign "
[[ \" \$* \" == *' --strict '* && \"\${!#}\" == '$app' ]] && { echo \"\${!#}: resource fork, Finder information, or similar detritus not allowed\" >&2; exit 1; }
exec /usr/bin/codesign \"\$@\""
	mole_test_fake_command spctl 'exit 0'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed failed=${SLIM_FAILURES[*]}"
		ls "$SLIM_WORK_DIR"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=0 failed=Fixture.app (code signature already invalid)"* ]] || return 1
	[[ "$output" != *"app."* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == *x86_64* ]] || return 1
	[ -z "$(ls -A "$TRASH_DIR")" ]
}

@test "slim strips Finder info on the copy without following a symlink out of it" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app outside="$BATS_TEST_TMPDIR/outside-target"
	app=$(make_fixture_app)
	printf 'keep\n' > "$outside"
	add_finder_info "$outside"
	ln -s "$outside" "$app/Contents/SharedSupport/outside-link"
	mole_test_fake_command codesign "
[[ \" \$* \" == *' --strict '* && \"\${!#}\" == '$app' ]] && { echo \"\${!#}: resource fork, Finder information, or similar detritus not allowed\" >&2; exit 1; }
exec /usr/bin/codesign \"\$@\""
	mole_test_fake_command spctl 'exit 0'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=0"* ]] || return 1
	/usr/bin/xattr -p com.apple.FinderInfo "$outside" > /dev/null
}

@test "slim lists a running app but refuses it when slimming starts" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	mole_test_fake_command spctl 'exit 0'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_app_is_running() { return 0; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		echo "listed=${#SLIM_APP_PATHS[@]}"
		slim_one_app 0 || exit 7
		echo "failed=${SLIM_FAILURES[*]}"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"listed=1"* ]] || return 1
	[[ "$output" == *"failed=Fixture.app (running, quit it and retry)"* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == *x86_64* ]] || return 1
	[ -z "$(ls -A "$TRASH_DIR")" ]
}

@test "slim refuses an app that starts while its copy is checked" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	mole_test_fake_command spctl 'exit 0'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		# Idle when slimming starts, running once the copy has been verified.
		started_marker="$2"
		slim_app_is_running() { [[ -e "$started_marker" ]]; }
		slim_verify_copy() { touch "$started_marker"; }
		slim_one_app 0 || exit 7
		echo "failed=${SLIM_FAILURES[*]}"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$BATS_TEST_TMPDIR/started"

	[ "$status" -eq 0 ]
	[[ "$output" == *"failed=Fixture.app (running, quit it and retry)"* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == *x86_64* ]] || return 1
	[ -z "$(ls -A "$TRASH_DIR")" ]
}
