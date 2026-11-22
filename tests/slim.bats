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

# Drive the real menu without scanning or modifying installed applications.
run_slim_selector() {
	printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/slim-keys"
	run slim_env COLUMNS=40 KEYS_FILE="$BATS_TEST_TMPDIR/slim-keys" \
		KEY_STATE="$BATS_TEST_TMPDIR/slim-key-state" /bin/bash -c '
		source "$1"
		SLIM_APP_NAMES=("Same very long application name with hidden suffix Zulu" "Same very long application name with hidden suffix Alpha" Affinity)
		SLIM_APP_PATHS=(/fixture/Zulu.app /fixture/Alpha.app /fixture/Affinity.app)
		SLIM_APP_BYTES=(4096 8192 2048)
		enter_alt_screen() { :; }
		leave_alt_screen() { :; }
		stty() { :; }
		tput() { if [[ "$1" == cols ]]; then echo 40; else echo 16; fi; }
		drain_pending_input() { :; }
		read_key() {
			local index key
			index=$(cat "$KEY_STATE" 2>/dev/null || echo 0)
			index=$((index + 1))
			printf "%s\n" "$index" > "$KEY_STATE"
			key=$(sed -n "${index}p" "$KEYS_FILE")
			printf "%s\n" "${key:-QUIT}"
		}
		rc=0
		select_slim_apps || rc=$?
		printf "RESULT=%s RC=%s\n" "$MOLE_SELECTION_RESULT" "$rc"
		[[ -z "${MOLE_MENU_FILTER_NAMES:-}" ]] || exit 1
	' bash "$PROJECT_ROOT/bin/slim.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

assert_slim_whitelist_change() {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app phase="$1"
	app=$(make_fixture_app)
	mole_test_fake_command spctl 'exit 0'
	run slim_env HOME="$BATS_TEST_TMPDIR/home-$phase" MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		mkdir -p "$HOME/.config/mole"
		if [[ "$3" == before ]]; then
			printf "%s\n" "$2" > "$HOME/.config/mole/whitelist"
			ditto() { echo COPIED; return 1; }
		else
			protected_app="$2"
			phase="$3"
			slim_verify_copy() {
				echo VERIFIED >&2
				if [[ "$phase" == unavailable ]]; then
					mkdir "$HOME/.config/mole/whitelist"
				else
					printf "%s\n" "$protected_app" > "$HOME/.config/mole/whitelist"
				fi
			}
		fi
		mole_delete() { echo DELETED; return 1; }
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed reason=${SLIM_FAILED_REASONS[*]}"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$app" "$phase"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *DELETED* && "$output" != *COPIED* ]] || { echo "$output"; return 1; }
	if [[ "$phase" == unavailable ]]; then
		[[ "$output" == *"slimmed=0 reason=whitelist unavailable"* ]] || { echo "$output"; return 1; }
	else
		[[ "$output" == *"slimmed=0 reason=whitelisted"* ]] || { echo "$output"; return 1; }
	fi
	[[ "$phase" == before || "$output" == *VERIFIED* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == *x86_64* ]] || return 1
	[ -z "$(ls -A "$TRASH_DIR")" ]
}

@test "slim rows fit narrow terminals and keep short lists compact" {
	run slim_env /bin/bash -c '
		source "$1"
		SLIM_APP_NAMES=(Affinity "Hopper Disassembler" "中文应用")
		SLIM_APP_PATHS=(/fixture/Affinity.app /fixture/Hopper.app /fixture/Chinese.app)
		SLIM_APP_BYTES=(1836098519 25585254 1024)
		for COLUMNS in 39 40 41 54 79 80 81 119 120 121; do
			export COLUMNS
			list=$(print_slim_list)
			while IFS= read -r row; do
				width=$(get_display_width "$row")
				[[ $width -le $COLUMNS ]] || { printf "overflow=%s width=%s\n" "$COLUMNS" "$width"; exit 1; }
			done <<< "$list"
			first=${list%%$'"'"'\n'"'"'*}
			[[ $(get_display_width "$first") -le 32 ]] || { echo "short rows spread too far"; exit 1; }
		done
		SLIM_APP_NAMES=("A very long application name with a hidden suffix" "很长的中文应用名称用于检查显示宽度")
		SLIM_APP_PATHS=(/fixture/Long.app /fixture/Chinese.app)
		COLUMNS=40
		while IFS= read -r row; do
			[[ $(get_display_width "$row") -le 40 ]] || exit 1
		done < <(print_slim_list)
	' bash "$PROJECT_ROOT/bin/slim.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "slim searches the full name beyond the displayed suffix" {
	run_slim_selector CHAR:/ CHAR:a CHAR:l CHAR:p CHAR:h CHAR:a ENTER SPACE ENTER
	[[ "$output" == *"RESULT=1 RC=0"* ]] || return 1
}

@test "slim name sorting keeps identities when displayed prefixes match" {
	run_slim_selector CHAR:s DOWN ENTER
	[[ "$output" == *"RESULT=1 RC=0"* ]] || return 1
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


@test "slim excludes whitelist paths from dry-run and noninteractive scans" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	cp -R "$app" "$APPS_ROOT/Keep.app"
	mole_test_fake_command spctl 'exit 0'
	run slim_env HOME="$BATS_TEST_TMPDIR/home" MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		mkdir -p "$HOME/.config/mole"
		for mode in --dry-run --debug; do
			for pattern in "$2" "$2/Contents/MacOS/Fixture" "${2%/*}/Fi*.app"; do
				printf "%s" "$pattern" > "$HOME/.config/mole/whitelist"
				main "$mode" || exit 1
				[[ "${SLIM_APP_NAMES[*]}" == Keep ]] || { echo "listed=${SLIM_APP_NAMES[*]}"; exit 2; }
				unset MOLE_DRY_RUN
			done
		done
		printf "%s\n" "${2%/*}" > "$HOME/.config/mole/whitelist"
		main --dry-run || exit 3
		[[ ${#SLIM_APP_PATHS[@]} -eq 0 ]] || exit 4
		echo WHITELIST_OK
	' bash "$PROJECT_ROOT/bin/slim.sh" "$app"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *WHITELIST_OK* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == *x86_64* ]] || return 1
	[ -z "$(ls -A "$TRASH_DIR")" ]
}

@test "slim stops before scanning when its whitelist is unreadable" {
	run slim_env HOME="$BATS_TEST_TMPDIR/home" MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		mkdir -p "$HOME/.config/mole/whitelist"
		collect_slim_candidates() { echo SCANNED; return 1; }
		main --dry-run
	' bash "$PROJECT_ROOT/bin/slim.sh"
	[ "$status" -ne 0 ] || { echo "$output"; return 1; }
	[[ "$output" != *SCANNED* ]] || return 1
	[[ "$output" == *whitelist* ]]
}


@test "slim reloads whitelist changes after scan" {
	assert_slim_whitelist_change before
}

@test "slim reloads whitelist changes before swap" {
	assert_slim_whitelist_change after
}

@test "slim retains the original when whitelist becomes unreadable before swap" {
	assert_slim_whitelist_change unavailable
}

@test "slim scans one level of plain folders but not bundles, links or deeper folders (#1811)" {
	mkdir -p "$APPS_ROOT/Top.app" "$APPS_ROOT/Utilities/Util.app" \
		"$APPS_ROOT/Utilities/Deep/Deeper.app" "$APPS_ROOT/Outer.app/Inner.app" \
		"$BATS_TEST_TMPDIR/elsewhere/Linked.app"
	ln -s "$BATS_TEST_TMPDIR/elsewhere" "$APPS_ROOT/LinkedFolder"

	mole_test_fake_command spctl 'exit 0'
	run slim_env /bin/bash -c '
		source "$1"
		slim_skip_reason() { :; }
		slim_signing_team() { echo ABCDE12345; }
		slim_plan_app() { echo 1; }
		mole_deletion_identity() { echo id; }
		collect_slim_candidates || exit 8
		printf "%s\n" "${SLIM_APP_PATHS[@]}" | sort
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[ "$output" = "$APPS_ROOT/Outer.app"$'\n'"$APPS_ROOT/Top.app"$'\n'"$APPS_ROOT/Utilities/Util.app" ]
}

@test "slim leaves out apps Gatekeeper already rejects but keeps unknown answers" {
	mkdir -p "$APPS_ROOT/Notarized.app" "$APPS_ROOT/Unnotarized.app" "$APPS_ROOT/Offline.app" "$APPS_ROOT/Plain.app"
	mole_test_fake_command spctl 'case "$*" in *Unnotarized.app) exit 3 ;; *Offline.app) exit 1 ;; esac; exit 0'

	run slim_env /bin/bash -c '
		source "$1"
		slim_skip_reason() { :; }
		slim_signing_team() { echo ABCDE12345; }
		slim_plan_app() { [[ "$1" == *Plain.app ]] && echo 0 || echo 1; }
		mole_deletion_identity() { echo id; }
		collect_slim_candidates || exit 8
		printf "%s\n" "${SLIM_APP_PATHS[@]}" | sort
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$output" = "$APPS_ROOT/Notarized.app"$'\n'"$APPS_ROOT/Offline.app" ]
}

@test "slim never thins an executable an enclosing seal lists as a plain file" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app="$APPS_ROOT/Outer.app"
	local plugin="$app/Contents/Library/QuickLook/Plug.qlgenerator/Contents"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/_CodeSignature" "$plugin/MacOS" "$plugin/_CodeSignature"
	cp "$FIXTURE_BIN_DIR/fat-exe" "$app/Contents/MacOS/Outer"
	cp "$FIXTURE_BIN_DIR/fat-exe" "$plugin/MacOS/Plug"
	plutil -create xml1 "$app/Contents/Info.plist"
	plutil -insert CFBundleExecutable -string Outer "$app/Contents/Info.plist"
	plutil -create xml1 "$plugin/Info.plist"
	plutil -insert CFBundleExecutable -string Plug "$plugin/Info.plist"
	printf 'plugin seal' > "$plugin/_CodeSignature/CodeResources"
	printf 'outer seal' > "$app/Contents/_CodeSignature/CodeResources"

	# ScreenFlow's shape: the plugin is signed, yet the app seals its
	# executable by hash2, so thinning it breaks the app's own seal.
	run slim_env /bin/bash -c '
		source "$1"
		app="$3"
		slim_sealed_keys() {
			[[ "$1" == "$app/Contents/_CodeSignature/CodeResources" ]] || return 0
			printf "h\tLibrary/QuickLook/Plug.qlgenerator/Contents/MacOS/Plug\n"
		}
		slim_plan_app "$app" "$2" > /dev/null
		cut -f1 "$2"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$BATS_TEST_TMPDIR/plan" "$app"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ "$output" = "Contents/MacOS/Outer" ]
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

@test "slim reads the host from /usr/sbin/sysctl, not PATH (#1804)" {
	[[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2> /dev/null)" == "1" ]] || skip "needs an Apple Silicon host"
	local bin="$BATS_TEST_TMPDIR/path-bin"
	mkdir -p "$bin"
	printf '#!/bin/sh\necho 0\n' > "$bin/sysctl"
	chmod +x "$bin/sysctl"

	run env HOME="$HOME" PATH="$bin:/usr/bin:/bin" MO_NO_OPLOG=1 MOLE_TEST_MODE=1 /bin/bash -c '
		source "$1"
		slim_host_is_apple_silicon && echo "apple-silicon"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"apple-silicon"* ]]
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

@test "slim_sealed_keys marks which files2 entries are sealed by cdhash" {
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
		slim_sealed_keys "$2"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$plist"

	[ "$status" -eq 0 ]
	[ "$output" = $'c\tFrameworks/Nested.framework\nc\tHelpers/R&D tool\nh\tLibraries/libffmpeg.dylib\nh\tResources/empty' ]
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
	# The original passes the scan; only the slimmed copy is rejected.
	mole_test_fake_command spctl 'case "$*" in *"/apps/Fixture.app") exit 0 ;; esac; exit 3'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0 || exit 7
		echo "slimmed=$total_slimmed failed=${SLIM_FAILED_NAMES[*]} (${SLIM_FAILED_REASONS[*]})"
		ls "$SLIM_WORK_DIR"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=0 failed=Fixture (Gatekeeper check failed)"* ]] || return 1
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
		echo "slimmed=$total_slimmed failed=${SLIM_FAILED_NAMES[*]} (${SLIM_FAILED_REASONS[*]})"
		ls "$SLIM_WORK_DIR"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"slimmed=0 failed=Fixture (code signature already invalid)"* ]] || return 1
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

@test "slim_thin_file keeps a slice cut when tail dies of SIGPIPE" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	cp "$FIXTURE_BIN_DIR/fat-exe" "$BATS_TEST_TMPDIR/thin-me"
	# The slice is not always the last one, and then head closes the pipe
	# while tail is still writing.
	run env MOLE_TEST_MODE=1 /bin/bash -c '
		set -o pipefail
		source "$1"
		tail() { command tail "$@"; return 141; }
		slim_thin_file "$2"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$BATS_TEST_TMPDIR/thin-me"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$(lipo -archs "$BATS_TEST_TMPDIR/thin-me")" == "arm64" ]]
}

@test "slim leaves a file whose Apple Silicon slice is arm64e" {
	run env MOLE_TEST_MODE=1 /bin/bash -c '
		source "$1"
		slim_fat_slices() { printf "arm64e 16384 100\nx86_64 32768 200\n"; }
		slim_arm_slice /dev/null && echo planned
		slim_fat_slices() { printf "arm64 16384 100\nx86_64 32768 200\n"; }
		slim_arm_slice /dev/null
	' bash "$PROJECT_ROOT/bin/slim.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "16384 100 200" ]]
}

@test "an interrupt during the swap still leaves the slimmed app in place" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local app
	app=$(make_fixture_app)
	mole_test_fake_command spctl 'exit 0'

	run slim_env MOLE_SLIM_TEST_HOST_ARM64=1 /bin/bash -c '
		source "$1"
		slim_signing_team() { echo ABCDE12345; }
		mole_delete() { mv "$1" "$MOLE_TEST_TRASH_DIR/original.app" && kill -INT $$; }
		slim_preflight || exit 9
		collect_slim_candidates || exit 8
		slim_one_app 0
		echo "not interrupted"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 130 ] || { echo "$output"; return 1; }
	[[ "$output" != *"not interrupted"* ]] || return 1
	[[ -d "$app" ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == "arm64" ]] || return 1
	[[ -d "$TRASH_DIR/original.app" ]]
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
		echo "failed=${SLIM_FAILED_NAMES[*]} (${SLIM_FAILED_REASONS[*]})"
	' bash "$PROJECT_ROOT/bin/slim.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"listed=1"* ]] || return 1
	[[ "$output" == *"failed=Fixture (still running)"* ]] || return 1
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
		echo "failed=${SLIM_FAILED_NAMES[*]} (${SLIM_FAILED_REASONS[*]})"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$BATS_TEST_TMPDIR/started"

	[ "$status" -eq 0 ]
	[[ "$output" == *"failed=Fixture (still running)"* ]] || return 1
	[[ "$(lipo -archs "$app/Contents/MacOS/Fixture")" == *x86_64* ]] || return 1
	[ -z "$(ls -A "$TRASH_DIR")" ]
}

@test "slim confirmation requires a successful Enter read" {
	run slim_env /bin/bash -c '
		source "$1"
		SLIM_APP_PATHS=("$2/Fixture.app")
		SLIM_APP_NAMES=(Fixture)
		SLIM_APP_BYTES=(1024)
		if confirm_slim_selection 0 </dev/null; then echo EOF_CONFIRMED; fi
		if confirm_slim_selection 0 < <(printf "\n"); then echo ENTER_CONFIRMED; fi
	' bash "$PROJECT_ROOT/bin/slim.sh" "$BATS_TEST_TMPDIR"
	[ "$status" -eq 0 ]
	[[ "$output" != *EOF_CONFIRMED* ]] || return 1
	[[ "$output" == *ENTER_CONFIRMED* ]]
}

@test "slim summary lists slimmed apps and groups kept apps by reason" {
	run slim_env /bin/bash -c '
		source "$1"
		SLIM_DONE_NAMES=(Claude Sketch NetNewsWire MiaoYan)
		total_slimmed=4
		total_freed_bytes=1048576
		SLIM_FAILED_NAMES=(Stash ScreenFlow Kaku)
		SLIM_FAILED_REASONS=("still running" "code signature check failed" "still running")
		total_failed=3
		show_slim_summary | sed $'"'"'s/\033\\[[0-9;]*m//g'"'"'
	' bash "$PROJECT_ROOT/bin/slim.sh"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Slim incomplete"* ]] || return 1
	[[ "$output" == *"Slimmed 4 apps, freed 1.0MB: Claude, Sketch, NetNewsWire"* ]] || return 1
	[[ "$output" == *$'\nMiaoYan\n'* ]] || return 1
	[[ "$output" == *"Still running: Stash, Kaku"* ]] || return 1
	[[ "$output" == *"Code signature check failed: ScreenFlow"* ]] || return 1
	[[ "$output" != *".app"* ]] || return 1
	[ "$(grep -c "Still running" <<< "$output")" -eq 1 ]
}

@test "slim slice output never follows a pre-existing suffix symlink" {
	[[ "$SLIM_HAVE_FAT_TOOLCHAIN" == "1" ]] || skip "needs clang and a developer directory"
	local file="$BATS_TEST_TMPDIR/thin-me" outside="$BATS_TEST_TMPDIR/outside"
	cp "$FIXTURE_BIN_DIR/fat-exe" "$file"
	printf 'keep outside' > "$outside"
	ln -s "$outside" "$file.mole-slim"
	run slim_env /bin/bash -c '
		source "$1"
		slim_thin_file "$2"
	' bash "$PROJECT_ROOT/bin/slim.sh" "$file"
	[[ "$(cat "$outside")" == "keep outside" ]] || return 1
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[ -L "$file.mole-slim" ]
	[[ "$(lipo -archs "$file")" == arm64 ]]
}
