#!/usr/bin/env bats

# Safety boundary tests for find_app_files() and ByHost cleanup.
# These guard against regressions where uninstalling a developer toolchain
# would silently delete user project source, signing keys, OAuth tokens,
# or other manually-curated data.

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${BATS_TMPDIR:-}"
	if [[ -z "$ORIGINAL_HOME" ]]; then
		ORIGINAL_HOME="${HOME:-}"
	fi
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-safety-home.XXXXXX")"
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

@test "find_app_files preserves Android Studio project source and credentials" {
	mkdir -p "$HOME/AndroidStudioProjects/my-app"
	mkdir -p "$HOME/.android/avd/Pixel_5.avd"
	mkdir -p "$HOME/.android/cache"
	touch "$HOME/.android/debug.keystore"
	touch "$HOME/.android/adbkey"
	mkdir -p "$HOME/Library/Android/sdk/platform-tools"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.google.android.studio" "Android Studio"
EOF
	)"

	[[ "$result" != *"AndroidStudioProjects"* ]] || { echo "leaked project source"; exit 1; }
	[[ "$result" != *"/.android/avd"* ]] || { echo "leaked AVD images"; exit 1; }
	[[ "$result" != *"/.android/debug.keystore"* ]] || { echo "leaked signing key"; exit 1; }
	[[ "$result" != *"/.android/adbkey"* ]] || { echo "leaked adb key"; exit 1; }
	[[ "$result" != *"Library/Android"* ]] || { echo "leaked SDK tree"; exit 1; }
	[[ "$result" == *"/.android/cache"* ]] || { echo "missed safe cache subdir"; exit 1; }
}

@test "find_app_files preserves Docker auth tokens and config" {
	mkdir -p "$HOME/.docker"
	touch "$HOME/.docker/config.json"
	mkdir -p "$HOME/.docker/contexts/meta"
	mkdir -p "$HOME/.docker/buildx"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.docker.docker" "Docker"
EOF
	)"

	[[ "$result" != *"/.docker/config.json"* ]] || { echo "leaked Docker auth tokens"; exit 1; }
	[[ "$result" != *"/.docker/contexts"* ]] || { echo "leaked Docker contexts"; exit 1; }
	# An exact-match line for $HOME/.docker would route the entire tree (auth
	# tokens, contexts, plugins) to deletion. Walk every line so the assertion
	# cannot be silently satisfied.
	while IFS= read -r line; do
		[[ "$line" == "$HOME/.docker" ]] && { echo "leaked entire ~/.docker tree"; exit 1; }
	done <<< "$result"
	# Buildx cache is regenerable, safe to clean.
	[[ "$result" == *"/.docker/buildx"* ]] || { echo "missed safe buildx cache"; exit 1; }
}

@test "find_app_files preserves Xcode user data and only collects regenerable caches" {
	mkdir -p "$HOME/Library/Developer/Xcode/DerivedData/MyApp-abc/Build"
	mkdir -p "$HOME/Library/Developer/Xcode/iOS DeviceSupport/17.0"
	mkdir -p "$HOME/Library/Developer/Xcode/Archives/2026/03/MyApp.xcarchive"
	mkdir -p "$HOME/Library/Developer/Xcode/UserData"
	mkdir -p "$HOME/Library/Developer/Toolchains/swift-6.0.xctoolchain"
	mkdir -p "$HOME/Library/Developer/CoreSimulator/Devices/abc"
	mkdir -p "$HOME/Library/Developer/CoreSimulator/Caches/dyld"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.apple.dt.Xcode" "Xcode"
EOF
	)"

	# Bare ~/Library/Developer must never appear, otherwise the whole tree
	# (Archives, UserData, Toolchains, Devices) gets routed to deletion.
	while IFS= read -r line; do
		[[ "$line" == "$HOME/Library/Developer" ]] && { echo "leaked entire Library/Developer"; exit 1; }
	done <<< "$result"

	[[ "$result" != *"/Library/Developer/Xcode/Archives"* ]] || { echo "leaked Xcode archives"; exit 1; }
	[[ "$result" != *"/Library/Developer/Xcode/UserData"* ]] || { echo "leaked Xcode user data"; exit 1; }
	[[ "$result" != *"/Library/Developer/Toolchains"* ]] || { echo "leaked toolchains"; exit 1; }
	[[ "$result" != *"/Library/Developer/CoreSimulator/Devices"* ]] || { echo "leaked simulator devices"; exit 1; }

	[[ "$result" == *"/Library/Developer/Xcode/DerivedData"* ]] || { echo "missed DerivedData cache"; exit 1; }
	[[ "$result" == *"/Library/Developer/Xcode/iOS DeviceSupport"* ]] || { echo "missed iOS DeviceSupport"; exit 1; }
	[[ "$result" == *"/Library/Developer/CoreSimulator/Caches"* ]] || { echo "missed simulator caches"; exit 1; }
}

@test "find_app_files preserves DevEco project source and Huawei account state" {
	mkdir -p "$HOME/DevEcoStudioProjects/my-harmonyos-app"
	mkdir -p "$HOME/HarmonyOS/projects"
	mkdir -p "$HOME/DevEco-Studio/config"
	mkdir -p "$HOME/Library/Application Support/Huawei/IdeaIC/options"
	mkdir -p "$HOME/Library/Huawei/SDK"
	mkdir -p "$HOME/.huawei/AppGallery"
	mkdir -p "$HOME/.ohos/sdk"
	mkdir -p "$HOME/Library/Caches/Huawei"
	mkdir -p "$HOME/Library/Logs/Huawei"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.huawei.deveco" "DevEco-Studio"
EOF
	)"

	[[ "$result" != *"DevEcoStudioProjects"* ]] || { echo "leaked DevEco project source"; exit 1; }
	[[ "$result" != *"$HOME/HarmonyOS"* ]] || { echo "leaked HarmonyOS project root"; exit 1; }
	[[ "$result" != *"$HOME/DevEco-Studio"* ]] || { echo "leaked DevEco IDE config + license state"; exit 1; }
	[[ "$result" != *"Application Support/Huawei"* ]] || { echo "leaked Huawei IDE settings"; exit 1; }
	[[ "$result" != *"$HOME/Library/Huawei"* ]] || { echo "leaked Huawei SDK tree"; exit 1; }
	[[ "$result" != *"$HOME/.huawei"* ]] || { echo "leaked Huawei account state"; exit 1; }
	[[ "$result" != *"$HOME/.ohos"* ]] || { echo "leaked OHOS SDK config"; exit 1; }
	[[ "$result" == *"Caches/Huawei"* ]] || { echo "missed Huawei cache"; exit 1; }
	[[ "$result" == *"Logs/Huawei"* ]] || { echo "missed Huawei logs"; exit 1; }
}

@test "find_app_files rejects bundle ids with glob metacharacters" {
	# Pre-stage Group Containers and ByHost entries that an over-broad
	# wildcard could accidentally pick up. A malformed bundle id like
	# "com.foo.*" must not expand into matches against unrelated containers.
	mkdir -p "$HOME/Library/Group Containers/group.com.example.real"
	mkdir -p "$HOME/Library/Group Containers/group.com.victim.unrelated"
	mkdir -p "$HOME/Library/Preferences/ByHost"
	touch "$HOME/Library/Preferences/ByHost/com.example.real.ABC.plist"
	touch "$HOME/Library/Preferences/ByHost/com.victim.unrelated.ABC.plist"
	mkdir -p "$HOME/Library/LaunchAgents"
	touch "$HOME/Library/LaunchAgents/com.example.real.plist"
	touch "$HOME/Library/LaunchAgents/com.victim.unrelated.plist"
	mkdir -p "$HOME/.ssh"
	touch "$HOME/.ssh/id_rsa"

	for bad_id in "com.foo.*" "com.foo.?" "com.foo.[abc]" "../../.ssh/id_rsa" "../etc/passwd" "*"; do
		result="$(
			HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" BAD_ID="$bad_id" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "$BAD_ID" "FakeApp"
EOF
		)"

		[[ "$result" != *"Group Containers/group.com.victim.unrelated"* ]] \
			|| { echo "bundle id '$bad_id' over-matched Group Containers"; exit 1; }
		[[ "$result" != *"ByHost/com.victim.unrelated"* ]] \
			|| { echo "bundle id '$bad_id' over-matched ByHost"; exit 1; }
		[[ "$result" != *"LaunchAgents/com.victim.unrelated"* ]] \
			|| { echo "bundle id '$bad_id' over-matched LaunchAgents"; exit 1; }
		[[ "$result" != *"/.ssh/id_rsa"* ]] \
			|| { echo "bundle id '$bad_id' traversed into .ssh"; exit 1; }
	done
}

@test "find_app_files still resolves wildcards for legitimate reverse-DNS bundle ids" {
	# Sanity check: the new validation must not regress the common case.
	mkdir -p "$HOME/Library/Group Containers/group.com.example.real"
	mkdir -p "$HOME/Library/LaunchAgents"
	touch "$HOME/Library/LaunchAgents/com.example.real.plist"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.real" "RealApp"
EOF
	)"

	[[ "$result" == *"Group Containers/group.com.example.real"* ]] \
		|| { echo "missed legitimate Group Container match"; exit 1; }
	[[ "$result" == *"LaunchAgents/com.example.real.plist"* ]] \
		|| { echo "missed legitimate LaunchAgent match"; exit 1; }
}

@test "ByHost cleanup routes through user-mode mole_delete (no sudo prompt)" {
	mkdir -p "$HOME/Library/Preferences/ByHost"
	touch "$HOME/Library/Preferences/ByHost/com.example.TestApp.ABC123.plist"
	mkdir -p "$HOME/Applications/TestApp.app"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

trace="$HOME/mole_delete.log"
mole_delete() {
	printf '%s|%s\n' "$1" "${2:-false}" >> "$trace"
	return 0
}
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

app_bundle="$HOME/Applications/TestApp.app"

related="$(find_app_files "com.example.TestApp" "TestApp")"
encoded_related=$(printf '%s' "$related" | base64 | tr -d '\n')

selected_apps=()
selected_apps+=("0|$app_bundle|TestApp|com.example.TestApp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications

if grep -q "ByHost.*com.example.TestApp.*plist|true" "$trace"; then
	echo "ByHost plist routed through sudo mole_delete"
	cat "$trace" >&2
	exit 1
fi

grep -q "ByHost.*com.example.TestApp.*plist|false" "$trace"
EOF

	[ "$status" -eq 0 ]
}
