#!/usr/bin/env bats

load helpers/common

# Safety boundary tests for find_app_files() and ByHost cleanup.
# These guard against regressions where uninstalling a developer toolchain
# would silently delete user project source, signing keys, OAuth tokens,
# or other manually-curated data.

setup_file() {
	mole_test_setup_home uninstall-safety-home
}

teardown_file() {
	mole_test_teardown_home
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

@test "find_app_files never treats shared XDG roots as Local app leftovers (#1446)" {
	mkdir -p "$HOME/.Local/bin"
	mkdir -p "$HOME/Library/Application Support/Local"
	touch "$HOME/.Local/bin/unrelated-cli"
	touch "$HOME/Library/Application Support/Local/app-state"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.getflywheel.lightning.local" "Local"
EOF
	)"

	[[ "$result" != *"$HOME/.Local"* ]] || { echo "leaked shared ~/.local root"; exit 1; }
	[[ "$result" == *"$HOME/Library/Application Support/Local"* ]] || { echo "missed Local app state"; exit 1; }
}

@test "uninstall discovers only LaunchAgents owned by the selected app" {
	local app="$HOME/Applications/Target.app"
	local agents="$HOME/Library/LaunchAgents"
	mkdir -p "$app/Contents/MacOS" "$agents"
	touch "$app/Contents/MacOS/Target"
	ln -s /bin/true "$app/Contents/MacOS/Outside"
	cat > "$agents/com.thirdparty.Target-daily.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>ProgramArguments</key><array><string>/bin/true</string></array></dict></plist>
PLIST
	cat > "$agents/com.example.Target.helper.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>ProgramArguments</key><array><string>$app/Contents/MacOS/Target</string></array></dict></plist>
PLIST
	cat > "$agents/com.thirdparty.Target-owned.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST
	cat > "$agents/com.example.Target.outside.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Outside</string></dict></plist>
PLIST
	: > "$agents/com.example.Target.plist"
	: > "$agents/com.example.Target.other.plist"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.Target" "Target" "$HOME/Applications/Target.app"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"$agents/com.example.Target.plist"* ]] || return 1
	[[ "$output" == *"$agents/com.example.Target.helper.plist"* ]] || return 1
	[[ "$output" == *"$agents/com.thirdparty.Target-owned.plist"* ]] || return 1
	[[ "$output" != *"$agents/com.thirdparty.Target-daily.plist"* ]] || return 1
	[[ "$output" != *"$agents/com.example.Target.other.plist"* ]] || return 1
	[[ "$output" != *"$agents/com.example.Target.outside.plist"* ]] || return 1
}

@test "find_app_files preserves Android Studio project source and credentials" {
	mkdir -p "$HOME/AndroidStudioProjects/my-app"
	mkdir -p "$HOME/.android/avd/Pixel_5.avd"
	mkdir -p "$HOME/.android/cache"
	touch "$HOME/.android/debug.keystore"
	touch "$HOME/.android/adbkey"
	mkdir -p "$HOME/Library/Android/sdk/platform-tools"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
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
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
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

@test "official uninstaller vendor blocks managed security apps" {
	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
official_uninstaller_vendor "com.crowdstrike.falcon.UserAgent" "Falcon" "/Applications/Falcon.app"
official_uninstaller_vendor "com.jamf.management.Jamf" "Jamf Connect" "/Applications/Jamf Connect.app"
official_uninstaller_vendor "" "Unknown" "/Applications/CrowdStrike Falcon.APP"
EOF
	)"

	[[ "$(printf '%s\n' "$result" | grep -cFx 'CrowdStrike')" -eq 2 ]] || { echo "missed CrowdStrike"; exit 1; }
	[[ "$result" == *"Jamf"* ]] || { echo "missed Jamf"; exit 1; }
}

@test "receipt payload allowlist rejects broad system roots" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

receipt_payload_path_is_allowlisted "/Library/LaunchAgents/com.example.foo.helper.plist" "com.example.foo"
receipt_payload_path_is_allowlisted "/Library/PrivilegedHelperTools/com.example.foo.helper" "com.example.foo"
! receipt_payload_path_is_allowlisted "/Library/Application Support/Foo" "com.example.foo" || exit 1
! receipt_payload_path_is_allowlisted "/Applications/Foo.app" "com.example.foo" || exit 1
! receipt_payload_path_is_allowlisted "/usr/local/bin/foo" "com.example.foo"
EOF

	[ "$status" -eq 0 ]
}

@test "launch plist unload validates path and uses timeout" {
	mkdir -p "$HOME/Library/LaunchAgents"
	touch "$HOME/Library/LaunchAgents/com.example.foo.plist"
	touch "$HOME/Library/LaunchAgents/com.example.foo.helper.plist"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

run_with_timeout() {
	if [[ "$2" == shasum ]]; then
		shift 2
		shasum "$@"
		return $?
	fi
	printf '%s\n' "$*" >> "$HOME/launchctl-call.log"
	return 0
}

unload_launch_plist "$HOME/Library/LaunchAgents/com.example.foo.plist" \
    "false" "" "com.example.foo"
unload_launch_plist "$HOME/Library/LaunchAgents/com.example.foo.helper.plist" \
    "false" "" "com.example.foo"
grep -q "5 launchctl unload $HOME/Library/LaunchAgents/com.example.foo.plist" "$HOME/launchctl-call.log"
[[ "$(grep -c 'launchctl unload' "$HOME/launchctl-call.log")" -eq 1 ]] || exit 1
EOF

	[ "$status" -eq 0 ]
}

@test "launch plist unload keeps an agent replaced during its owner probe" {
	local app="$HOME/Applications/Target.app"
	local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
	local fake_bin="$HOME/bin"
	mkdir -p "$app/Contents/MacOS" "${agent%/*}" "$fake_bin"
	touch "$app/Contents/MacOS/Target"
	cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST
	cat > "$fake_bin/plutil" <<'SH'
#!/bin/bash
output=$(/usr/bin/plutil "$@") || exit $?
plist=""
for arg in "$@"; do plist="$arg"; done
printf 'probed\n' > "$HOME/plutil-call.log"
mv "$plist" "$HOME/original-agent.plist"
cat > "$plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
printf '%s\n' "$output"
SH
	cat > "$fake_bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/unload-call.log"
SH
	chmod +x "$fake_bin/plutil" "$fake_bin/launchctl"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		PATH="$fake_bin:$PATH" MOLE_TEST_NO_AUTH=1 \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
unload_launch_plist "$agent" false "" com.example.Target "$app"
[[ -f "$HOME/plutil-call.log" && -f "$HOME/original-agent.plist" ]] || exit 1
[[ -f "$agent" && ! -e "$HOME/unload-call.log" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "launch plist unload rebinds identity after its final content check" {
	local app="$HOME/Applications/Target.app"
	local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
	local fake_bin="$HOME/bin"
	mkdir -p "$app/Contents/MacOS" "${agent%/*}" "$fake_bin"
	touch "$app/Contents/MacOS/Target"
	cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST
	cat > "$fake_bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/unload-call.log"
SH
	chmod +x "$fake_bin/launchctl"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		PATH="$fake_bin:$PATH" MOLE_TEST_NO_AUTH=1 \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
mole_file_sha256() {
    local digest calls=0
    digest=$(shasum -a 256 -- "$1") || return $?
    [[ -f "$HOME/hash-calls" ]] && read -r calls < "$HOME/hash-calls"
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$HOME/hash-calls"
    if [[ $calls -eq 2 ]]; then
        mv "$1" "$HOME/original-agent.plist"
        cat > "$1" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
    fi
    printf '%s\n' "${digest:0:64}"
}
unload_launch_plist "$agent" false "" com.example.Target "$app"
[[ "$(cat "$HOME/hash-calls")" -eq 2 ]] || exit 1
[[ -f "$agent" && -f "$HOME/original-agent.plist" ]] || exit 1
[[ ! -e "$HOME/unload-call.log" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "launch plist unload binds ownership after calculating its timeout" {
	local app="$HOME/Applications/Target.app"
	local agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
	local fake_bin="$HOME/bin"
	mkdir -p "$app/Contents/MacOS" "${agent%/*}" "$fake_bin"
	touch "$app/Contents/MacOS/Target"
	cat > "$agent" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$app/Contents/MacOS/Target</string></dict></plist>
PLIST
	cat > "$fake_bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/unload-call.log"
SH
	chmod +x "$fake_bin/launchctl"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		PATH="$fake_bin:$PATH" MOLE_TEST_NO_AUTH=1 \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
app="$HOME/Applications/Target.app"
agent="$HOME/Library/LaunchAgents/com.example.Target.helper.plist"
_mole_timeout_with_deadline() {
    if [[ "$1" == "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" ]]; then
        mv "$agent" "$HOME/original-agent.plist"
        cat > "$agent" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST
        printf '5\n'
    else
        printf '2\n'
    fi
}
unload_launch_plist "$agent" false "$((SECONDS + 30))" com.example.Target "$app"
[[ -f "$agent" && -f "$HOME/original-agent.plist" ]] || exit 1
[[ ! -e "$HOME/unload-call.log" ]] || exit 1
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "login item helper discovery reads embedded helper bundle ids" {
	app="$HOME/Applications/Carrier.app"
	helper="$app/Contents/Library/LoginItems/Carrier Helper.app/Contents"
	mkdir -p "$helper"
	cat > "$helper/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.carrier.helper</string>
</dict>
</plist>
PLIST

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
discover_login_item_helper_bundle_ids "$HOME/Applications/Carrier.app"
EOF
	)"

	[[ "$result" == "com.example.carrier.helper" ]]
}

@test "login item helper discovery discards partial results and propagates cancellation" {
	app="$HOME/Applications/RacedCarrier.app"
	helper="$app/Contents/Library/LoginItems/Raced Helper.app/Contents"
	mkdir -p "$helper"
	printf '<plist/>\n' > "$helper/Info.plist"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP="$app" \
		HELPER_APP="${helper%/Contents}" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

run_with_timeout() {
	local _duration="$1"
	shift
	if [[ "${1:-}" == "find" ]]; then
		printf '%s\0' "$HELPER_APP"
		return "${SCAN_RC:?}"
	fi
	"$@"
}

SCAN_RC=1
result=$(discover_login_item_helper_bundle_ids "$APP")
[[ -z "$result" ]] || exit 1

SCAN_RC=130
rc=0
result=$(discover_login_item_helper_bundle_ids "$APP") || rc=$?
[[ $rc -eq 130 ]] || exit 1
[[ -z "$result" ]]
EOF

	[ "$status" -eq 0 ]
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
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
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
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
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
			HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" BAD_ID="$bad_id" /bin/bash --noprofile --norc <<'EOF'
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
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
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

@test "find_app_files keeps bundle-id-derived paths on dot boundaries" {
	mkdir -p "$HOME/Library/Preferences/ByHost"
	mkdir -p "$HOME/Library/Group Containers/group.com.example.TestApp"
	mkdir -p "$HOME/Library/Group Containers/group.com.example.TestApplication"
	mkdir -p "$HOME/Library/Containers/com.example.TestApp.helper"
	mkdir -p "$HOME/Library/Containers/com.example.TestApplication"
	mkdir -p "$HOME/Library/Application Scripts/TEAM.com.example.TestApp.Extension"
	mkdir -p "$HOME/Library/Application Scripts/TEAM.com.example.TestApplication.Extension"
	touch "$HOME/Library/Preferences/ByHost/com.example.TestApp.ABC123.plist"
	touch "$HOME/Library/Preferences/ByHost/com.example.TestApplication.ABC123.plist"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.TestApp" "TestApp"
EOF
	)"

	[[ "$result" == *"ByHost/com.example.TestApp.ABC123.plist"* ]] || { echo "missed ByHost plist"; exit 1; }
	[[ "$result" == *"Group Containers/group.com.example.TestApp"* ]] || { echo "missed group container"; exit 1; }
	[[ "$result" == *"Containers/com.example.TestApp.helper"* ]] || { echo "missed helper container"; exit 1; }
	[[ "$result" == *"Application Scripts/TEAM.com.example.TestApp.Extension"* ]] || { echo "missed prefixed app script"; exit 1; }
	[[ "$result" != *"TestApplication"* ]] || { echo "matched sibling bundle prefix"; printf '%s\n' "$result"; exit 1; }
}

@test "ByHost cleanup routes through user-mode mole_delete (no sudo prompt)" {
	local fixture_home
	fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
	mkdir -p "$fixture_home/Library/Preferences/ByHost"
	touch "$fixture_home/Library/Preferences/ByHost/com.example.TestApp.ABC123.plist"
	mkdir -p "$fixture_home/Applications/TestApp.app"

	run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

trace="$HOME/mole_delete.log"
mole_delete() {
	printf '%s|%s\n' "$1" "${2:-false}" >> "$trace"
	if [[ "$1" == "$app_bundle" ]]; then
		mv "$app_bundle" "$HOME/removed-app-fixture"
	fi
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
[[ $(wc -l < "$HOME/inventory.trace") -ge 2 ]] || exit 1
EOF

	[ "$status" -eq 0 ] || {
		printf 'exit status: %s\n%s\n' "$status" "$output"
		return 1
	}
}

@test "malformed bundle ids do not trigger defaults or ByHost side effects" {
	mkdir -p "$HOME/Library/Preferences/ByHost"
	touch "$HOME/Library/Preferences/ByHost/com.example.TestApp.ABC123.plist"
	mkdir -p "$HOME/Applications/TestApp.app"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

trace="$HOME/side_effects.log"

defaults() {
	printf 'defaults:%s\n' "$*" >> "$trace"
	return 0
}
mole_delete() {
	printf 'mole_delete:%s|%s\n' "$1" "${2:-false}" >> "$trace"
	return 0
}
find_app_files() { return 0; }
find_app_system_files() { return 0; }
get_diagnostic_report_paths_for_app() { return 0; }
remove_login_item() { :; }
unregister_app_bundle() { :; }
force_kill_app() { return 0; }
request_sudo_access() { return 0; }
ensure_sudo_session() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
enter_alt_screen() { :; }
leave_alt_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }
pgrep() { return 1; }
pkill() { return 0; }
sudo() { return 0; }

for bad_id in "-g" "NSGlobalDomain" "com-example"; do
	: > "$trace"
	selected_apps=()
	selected_apps+=("0|$HOME/Applications/TestApp.app|TestApp|$bad_id|0|Never")
	files_cleaned=0
	total_items=0
	total_size_cleaned=0

	batch_uninstall_applications </dev/null

	if grep -q '^defaults:' "$trace" || grep -q 'ByHost' "$trace"; then
		echo "unexpected domain cleanup side effect for $bad_id"
		cat "$trace"
		exit 1
	fi
done
EOF

	[ "$status" -eq 0 ]
}

@test "find_app_files discovers CrashReporter plists by app name" {
	mkdir -p "$HOME/Library/Application Support/CrashReporter"
	touch "$HOME/Library/Application Support/CrashReporter/TestApp_AAAA-BBBB.plist"
	touch "$HOME/Library/Application Support/CrashReporter/TestApp_CCCC-DDDD.plist"
	touch "$HOME/Library/Application Support/CrashReporter/OtherApp_EEEE-FFFF.plist"

	result="$(
		HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.testapp" "TestApp"
EOF
	)"

	[[ "$result" == *"CrashReporter/TestApp_AAAA-BBBB.plist"* ]] || { echo "missed CrashReporter plist 1"; exit 1; }
	[[ "$result" == *"CrashReporter/TestApp_CCCC-DDDD.plist"* ]] || { echo "missed CrashReporter plist 2"; exit 1; }
	[[ "$result" != *"OtherApp_EEEE-FFFF.plist"* ]] || { echo "leaked unrelated CrashReporter plist"; exit 1; }
}

@test "an unreadable path makes the same-bundle scan indeterminate, never absent" {
	# find exits 1 for a subdirectory it cannot read even though it printed
	# everything else, and macOS hands that out routinely under TCC. Treating
	# it as a dead scan aborted the whole uninstall (#1339, #1340). Treating it
	# as proven absence would be worse: the caller would then tear down
	# leftovers a sibling install still needs. It has to be its own verdict.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

root="$HOME/scan-roots"
mkdir -p "$root/readable/Some.app" "$root/blocked/inner"
chmod 000 "$root/blocked"
trap 'chmod 755 "$root/blocked" 2>/dev/null || true' EXIT

out="$(create_temp_file)"
rc=0
_uninstall_materialize_complete_find0 "$out" "$((SECONDS + 30))" \
    "$root" -maxdepth 3 \( -type d -o -type l \) -name '*.app' || rc=$?

[[ "$rc" -eq "$MOLE_UNINSTALL_SCAN_PARTIAL" ]] || { echo "RC:$rc want $MOLE_UNINSTALL_SCAN_PARTIAL"; exit 1; }
# The listing it did produce must survive: discarding it is what turned a
# readable-but-incomplete scan into a total failure.
grep -qa "Some.app" "$out" || { echo "RESULTS_DISCARDED"; exit 1; }
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"RESULTS_DISCARDED"* ]] || return 1
}

@test "wrapped iOS bundles and id-less bundles do not make the sibling scan unknown (#1339)" {
	# Two bundle shapes that are ordinary installs, not mysteries: an iOS app
	# on Apple Silicon keeps its plist under Wrapper/<name>.app, and vendor
	# uninstallers ship a plist with no CFBundleIdentifier at all. Both read as
	# "unknown" before, and one of either anywhere on the machine aborted the
	# uninstall of every other app.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

apps="$HOME/sibling-shapes"
mkdir -p "$apps/Wrapped.app/Wrapper/Inner.app" "$apps/NoId.app/Contents" "$apps/Broken.app/Contents"
cat > "$apps/Wrapped.app/Wrapper/Inner.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.wrapped</string></dict></plist>
PLIST
cat > "$apps/NoId.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>run.sh</string></dict></plist>
PLIST
printf 'not a plist' > "$apps/Broken.app/Contents/Info.plist"

live_paths=(); live_records=()
deadline=$((SECONDS + 30))

# The wrapped bundle's real id must be found, so it matches when it should.
rc=0
_uninstall_collect_live_sibling_candidate "$apps/Wrapped.app" "/nowhere.app" \
    "com.example.wrapped" "$deadline" true || rc=$?
[[ "$rc" -eq 0 ]] || { echo "WRAPPED_RC:$rc want 0"; exit 1; }

# No CFBundleIdentifier is an answer: it cannot be a sibling.
rc=0
_uninstall_collect_live_sibling_candidate "$apps/NoId.app" "/nowhere.app" \
    "com.example.wrapped" "$deadline" true || rc=$?
[[ "$rc" -eq 1 ]] || { echo "NOID_RC:$rc want 1"; exit 1; }

# A plist that will not parse is still unknown, and must stay that way.
rc=0
_uninstall_collect_live_sibling_candidate "$apps/Broken.app" "/nowhere.app" \
    "com.example.wrapped" "$deadline" true || rc=$?
[[ "$rc" -eq 2 ]] || { echo "BROKEN_RC:$rc want 2"; exit 1; }
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "interactive scan failure is a visible abort, not a silent success (#1339)" {
	# The interactive loop used to return to the prompt with nothing on screen
	# when the scan could not complete; the session then read as a successful
	# run with zero operations. The abort must be printed after the alternate
	# screen is restored, and the command must fail.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

# No real machine scanning or terminal in this test.
scan_applications() { return 1; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }

main
EOF

	[ "$status" -eq 1 ]
	[[ "$output" == *"Uninstall aborted: could not complete the application scan"* ]]
}

@test "failed app selection aborts visibly instead of returning success (#1339)" {
	# EOF or a broken selector used to exit 0 with nothing printed, so the
	# session read as successful with zero operations. A selector that did
	# not complete for any reason other than a deliberate quit must say so
	# and fail. The deliberate-quit case is pinned separately below.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

fake_apps_list="$HOME/fake-apps"
printf '0|/tmp/Fake.app|Fake|com.example.fake|1KB|Today|1\n' > "$fake_apps_list"
scan_applications() { printf '%s\n' "$fake_apps_list"; }
load_applications() {
	apps_data=("0|/tmp/Fake.app|Fake|com.example.fake|1KB|Today|1")
	selection_state=(false)
	return 0
}
select_apps_for_uninstall() { return 1; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }

main
EOF

	[ "$status" -eq 1 ]
	[[ "$output" == *"Uninstall aborted: application selection did not complete"* ]]
}

@test "a deliberate quit in the selector stays a quiet cancel, not an abort" {
	# Pressing q is the documented way to leave the selector, matching
	# mole's other cancel flows (mo remove ESC exits 0 silently). Only a
	# selector that broke may print the abort and fail; the menu marks the
	# difference through _MOLE_MENU_USER_QUIT.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

fake_apps_list="$HOME/fake-apps"
printf '0|/tmp/Fake.app|Fake|com.example.fake|1KB|Today|1\n' > "$fake_apps_list"
scan_applications() { printf '%s\n' "$fake_apps_list"; }
load_applications() {
	apps_data=("0|/tmp/Fake.app|Fake|com.example.fake|1KB|Today|1")
	selection_state=(false)
	return 0
}
select_apps_for_uninstall() {
	_MOLE_MENU_USER_QUIT=1
	return 1
}
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }

main
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" != *"Uninstall aborted"* ]] || return 1
	[ "$status" -eq 0 ]
}

@test "uninstall --list surfaces a failed scan instead of a bare exit (#1339)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

scan_applications() { return 1; }

uninstall_list_apps
EOF

	[ "$status" -eq 1 ]
	[[ "$output" == *"Uninstall aborted: could not complete the application scan"* ]]
}

@test "a receipt scan that outlives its budget degrades to indeterminate, not a dead run" {
	# Receipt enumeration is machine-wide: 274 receipts with one holding
	# 22k paths blew the shared deadline and the resulting 124 ended the
	# whole uninstall with nothing on screen (#1340). Out of budget is an
	# incomplete scan, so it must land on the same partial verdict an
	# unreadable path produces, never abort the run.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

root="$HOME/live-roots"
mkdir -p "$root"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$root")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-such-volumes"
pkg_receipt_nonstandard_app_paths() { return 124; }

rc=0
uninstall_live_bundle_has_other_install \
    "com.example.selected" "$root/Selected.app" || rc=$?
[[ "$rc" -eq "$MOLE_UNINSTALL_SCAN_PARTIAL" ]] || { echo "RC:$rc want $MOLE_UNINSTALL_SCAN_PARTIAL"; exit 1; }
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "a signal during the receipt scan still cancels the uninstall" {
	# Only deadline timeouts degrade to the partial verdict. A signal is
	# the user cancelling, and must keep propagating unchanged.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

root="$HOME/live-roots"
mkdir -p "$root"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$root")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-such-volumes"
pkg_receipt_nonstandard_app_paths() { return 130; }

rc=0
uninstall_live_bundle_has_other_install \
    "com.example.selected" "$root/Selected.app" || rc=$?
[[ "$rc" -eq 130 ]] || { echo "RC:$rc want 130"; exit 1; }
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "execution-time partial acceptance is gated on an empty deletion plan" {
	# guard_login alone does not prove a bundle-only plan: the
	# surviving-sibling name-collision path sets it while keeping
	# name-keyed leftovers in encoded_files. If the partial re-check
	# acceptance ever drops the empty-deletion-list gate, a sibling
	# hidden behind the unreadable part of a partial or failed re-scan
	# (#1624) could lose
	# name-keyed data without the fingerprint defense.
	local window
	# shellcheck disable=SC2016 # the \$ patterns are literal source text
	window=$(command grep -A2 'live_sibling_rc -lt 128 &&' \
		"$PROJECT_ROOT/lib/uninstall/batch.sh")
	# Positive control: the acceptance branch must exist at all.
	printf '%s\n' "$window" | command grep -q 'guard_login' || {
		echo "acceptance branch not found"
		return 1
	}
	# shellcheck disable=SC2016 # the \$ pattern is literal source text
	printf '%s\n' "$window" | command grep -q -- '-z "\$encoded_files"' || {
		echo "gate missing the empty-plan check"
		return 1
	}
}

@test "protection pattern loops match globs inline, without a per-pattern call" {
	# should_protect_path and should_protect_data run once per candidate across
	# hundreds of patterns, so each loop tests the glob inline instead of
	# calling bundle_matches_pattern. The verdicts pin that the unquoted RHS
	# is still a glob: quoting it would turn a wildcard row such as
	# *wireguard* into an exact-string match and drop the protection.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
calls="$HOME/bundle-match-calls"
: >"$calls"
bundle_matches_pattern() {
    printf '.' >>"$calls"
    [[ -z "$2" ]] && return 1
    # shellcheck disable=SC2053 # unquoted RHS is the glob
    [[ "$1" == $2 ]]
}
verdict() { if "$@"; then echo "$*=protected"; else echo "$*=open"; fi; }
verdict should_protect_data "com.sogou.inputmethod.pinyin"
verdict should_protect_data "com.sogou.cloud"
verdict should_protect_data "im.rime.squirrel"
verdict should_protect_data "org.example.wireguard-ui"
verdict should_protect_data "org.example.plain"
verdict should_protect_path "$HOME/Library/Caches/org.example.wireguard-ui/data"
verdict should_protect_path "$HOME/Library/Caches/org.example.plain/data"
MOLE_UNINSTALL_MODE=1 verdict should_protect_path "com.apple.loginitems.agent"
MOLE_UNINSTALL_MODE=1 verdict should_protect_path "$HOME/Library/Caches/org.example.plain/data"
echo "calls=$(wc -c <"$calls" | tr -d ' ')"
EOF
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"should_protect_data com.sogou.inputmethod.pinyin=protected"* ]] || return 1
	[[ "$output" == *"should_protect_data com.sogou.cloud=open"* ]] || return 1
	[[ "$output" == *"should_protect_data im.rime.squirrel=protected"* ]] || return 1
	[[ "$output" == *"should_protect_data org.example.wireguard-ui=protected"* ]] || return 1
	[[ "$output" == *"should_protect_data org.example.plain=open"* ]] || return 1
	[[ "$output" == *"org.example.wireguard-ui/data=protected"* ]] || return 1
	[[ "$output" == *"should_protect_path com.apple.loginitems.agent=protected"* ]] || return 1
	[[ "$output" == *"org.example.plain/data=open"*"org.example.plain/data=open"* ]] || return 1
	[[ "${lines[${#lines[@]} - 1]}" == "calls=0" ]]
}

@test "uninstall mode matches the Apple uninstallable globs before the critical rows" {
	# With the shipped lists no bundle ID is in both APPLE_UNINSTALLABLE_APPS
	# and SYSTEM_CRITICAL_BUNDLES, so the first loop's verdict equals the
	# fall-through and quoting its right-hand side would change nothing
	# observable. A fixture critical row that overlaps com.apple.dt.* makes the
	# order visible: the unquoted glob wins and Xcode stays uninstallable,
	# while a quoted one is an exact string, misses, and lets the critical
	# row protect it.
	local fixture="$HOME/protection-order-fixture"
	mkdir -p "$fixture"
	cp -R "$PROJECT_ROOT/lib" "$PROJECT_ROOT/bin" "$fixture/"
	awk '{ print } /^readonly SYSTEM_CRITICAL_BUNDLES=\($/ { print "    \"com.apple.dt.*\""; print "    \"org.example.critical.*\"" }' \
		"$PROJECT_ROOT/lib/core/app_protection_data.sh" >"$fixture/lib/core/app_protection_data.sh"

	run env HOME="$HOME" FIXTURE="$fixture" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
source "$FIXTURE/lib/core/common.sh"
verdict() { if "$@"; then echo "$*=protected"; else echo "$*=open"; fi; }
MOLE_UNINSTALL_MODE=1 verdict should_protect_path "org.example.critical.Tool"
MOLE_UNINSTALL_MODE=1 verdict should_protect_path "com.apple.dt.Xcode"
MOLE_UNINSTALL_MODE=1 verdict should_protect_path "com.apple.finder"
EOF
	[ "$status" -eq 0 ] || return 1
	# Positive controls: the fixture row is live in uninstall mode, and a
	# critical ID outside the uninstallable list is still protected.
	[[ "$output" == *"should_protect_path org.example.critical.Tool=protected"* ]] || return 1
	[[ "$output" == *"should_protect_path com.apple.finder=protected"* ]] || return 1
	[[ "$output" == *"should_protect_path com.apple.dt.Xcode=open"* ]]
}

@test "live uninstall inventory treats independent longer bundle IDs as shared owners" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$HOME/Applications/IntelliJ IDEA.app"
other="$HOME/Applications/Community.app"
mkdir -p "$selected/Contents" "$other/Contents"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellij.ce</string></dict></plist>' > "$other/Contents/Info.plist"
rc=0
uninstall_live_bundle_has_other_install com.jetbrains.intellij "$selected" || rc=$?
printf 'LONGER_OWNER_RC=%s\n' "$rc"
[[ $rc -eq 0 && -n "$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT" ]] || exit 1
# A textual neighbour is not an owner. Nested helpers still belong to the
# selected app and must not make every extension-bearing app unremovable.
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellix.ce</string></dict></plist>' > "$other/Contents/Info.plist"
mkdir -p "$selected/Contents/Helper.app/Contents"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellij.helper</string></dict></plist>' > "$selected/Contents/Helper.app/Contents/Info.plist"
rc=0
uninstall_live_bundle_has_other_install com.jetbrains.intellij "$selected" || rc=$?
printf 'UNRELATED_AND_EMBEDDED_RC=%s\n' "$rc"
[[ $rc -eq 1 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "live uninstall inventory protects stable data while removing a differently identified channel" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$HOME/Applications/Zed Nightly.app"
other="$HOME/Applications/Zed.app"
mkdir -p "$selected/Contents" "$other/Contents" "$HOME/.config/zed"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>dev.zed.Zed</string></dict></plist>' > "$other/Contents/Info.plist"
rc=0
uninstall_live_bundle_has_other_install dev.zed.Zed-Nightly "$selected" || rc=$?
printf 'CHANNEL_OWNER_RC=%s\n' "$rc"
[[ $rc -eq 0 && -n "$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "leftover sink rechecks new sibling owners and unknown inventory after app removal" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 MOLE_UNINSTALL_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$HOME/Applications/IntelliJ IDEA.app"
other="$HOME/Applications/Community.app"
data="$HOME/Library/Containers/com.jetbrains.intellij.ce"
mkdir -p "$HOME/Applications" "$data/Data/Documents"
printf 'only copy\n' > "$data/Data/Documents/project"
# Exercise the real caller and policy but replace the irreversible sink.
mole_delete() { printf '%s\n' "$1" >> "$HOME/sink-attempts"; }
# Preview proved absence; a sibling then appears while the selected app moves.
rc=0
uninstall_live_bundle_has_other_install com.jetbrains.intellij "$selected" || rc=$?
[[ $rc -eq 1 ]] || exit 1
mkdir -p "$other/Contents"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellij.ce</string></dict></plist>' > "$other/Contents/Info.plist"
for mode in trash permanent; do
    export MOLE_DELETE_MODE="$mode"
    rc=0
    remove_file_list "$data" false com.jetbrains.intellij "$selected" || rc=$?
    [[ $rc -eq 16 && ! -e "$HOME/sink-attempts" ]] || exit 1
done
# An unreadable inventory also keeps the reviewed data.
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/unknown-root")
ln -s "$HOME/Applications" "$HOME/unknown-root"
rc=0
remove_file_list "$data" false com.jetbrains.intellij "$selected" || rc=$?
[[ $rc -eq 16 && ! -e "$HOME/sink-attempts" ]] || exit 1
# Complete absence keeps normal deletion reachable, including extension data.
mkdir -p "$HOME/empty-apps"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/empty-apps")
remove_file_list "$data" false com.jetbrains.intellij "$selected"
[[ $(cat "$HOME/sink-attempts") == "$data" ]] || exit 1
[[ -f "$data/Data/Documents/project" ]] || exit 1
printf 'FRESH_OWNER_GATE_AND_ABSENCE_CONTROL_OK\n'
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a new owner after the app move preserves defaults helpers and full container bytes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 MOLE_UNINSTALL_MODE=1 MOLE_DELETE_MODE=trash /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$HOME/Applications/IntelliJ IDEA.app"
other="$HOME/Applications/Community.app"
data="$HOME/Library/Containers/com.jetbrains.intellij.ce"
mkdir -p "$selected/Contents" "$data/Data/Documents" "$HOME/Library/Preferences/ByHost"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellij</string></dict></plist>' > "$selected/Contents/Info.plist"
printf 'container metadata\n' > "$data/.com.apple.containermanagerd.metadata.plist"
printf 'only copy of document\n' > "$data/Data/Documents/project"
printf 'preferences\n' > "$HOME/Library/Preferences/ByHost/com.jetbrains.intellij.ce.fixture.plist"
retained_kb=$(du -skP "$data" | awk '{print $1}')
encoded=$(printf '%s' "$data" | base64 | tr -d '\n')
fields=(IDEA "$selected" com.jetbrains.intellij "$((1000 + retained_kb))" "$encoded" '' false false false '' '' '' '' none x com.jetbrains.intellij '' x)
IFS='|' detail="${fields[*]}"; unset IFS
app_details=("$detail")
_batch_selected_app_plan_matches() { return 0; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
force_kill_app() { :; }
stop_inline_spinner() { :; }
defaults() { printf 'defaults:%s\n' "$*" >> "$HOME/forbidden"; }
bootout_login_item_helpers() { printf 'helpers\n' >> "$HOME/forbidden"; }
mole_delete() {
    if [[ "$1" == "$selected" ]]; then
        mv "$selected" "$HOME/removed-fixture.app"
        mkdir -p "$other/Contents"
        printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellij.ce</string></dict></plist>' > "$other/Contents/Info.plist"
        return 0
    fi
    printf 'sink:%s\n' "$1" >> "$HOME/forbidden"
}
success_count=0 failed_count=0 brew_apps_removed=0 total_size_freed=0 files_cleaned=0 total_items=0
failed_items=() success_items=() success_dock_targets=() system_extension_warning_apps=()
review_only_system_leftovers=() review_only_system_leftover_keys=() running_at_uninstall_apps=()
_batch_execute_removals
printf 'SUCCESS=%s FREED_KB=%s\n' "$success_count" "$total_size_freed"
[[ $success_count -eq 1 && $failed_count -eq 0 ]] || exit 1
[[ ! -e "$HOME/forbidden" ]] || { cat "$HOME/forbidden"; exit 1; }
[[ $total_size_freed -eq 1000 ]] || exit 1
[[ -f "$data/Data/Documents/project" && -d "$other" ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "leftover sink keeps data when the selected app path is reinstalled" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 MOLE_UNINSTALL_MODE=1 MOLE_DELETE_MODE=permanent /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
app="$HOME/Applications/Target.app"
data="$HOME/Library/Containers/com.example.Target"
mkdir -p "$app/Contents" "$data"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.example.Target</string></dict></plist>' > "$app/Contents/Info.plist"
mole_delete() { printf 'unexpected sink\n' > "$HOME/forbidden"; }
rc=0
remove_file_list "$data" false com.example.Target "$app" || rc=$?
[[ ! -e "$HOME/forbidden" && $rc -eq 16 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "sibling matching folds case in-process instead of forking per candidate" {
    # The predicate runs once per installed app in every sibling scan, three
    # scans per selected app. Two tr forks per id and per name made a
    # 200-app Mac 2.6x slower than V1.58.0; the verdicts must stay identical.
    local shim="$BATS_TEST_TMPDIR/shim"
    mkdir -p "$shim"
    # shellcheck disable=SC2016  # The shim expands $TR_COUNT_FILE and "$@" when it runs.
    printf '#!/bin/bash\nprintf . >> "$TR_COUNT_FILE"\nexec /usr/bin/tr "$@"\n' > "$shim/tr"
    chmod +x "$shim/tr"
    run env HOME="$BATS_TEST_TMPDIR/home" PATH="$shim:$PATH" \
        TR_COUNT_FILE="$BATS_TEST_TMPDIR/tr-count" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$HOME/Applications/Selected.app"
mkdir -p "$selected/Contents"
apps_data=()
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    app="$HOME/Applications/Vendor$i Tool.app"
    mkdir -p "$app/Contents"
    printf '<plist><dict><key>CFBundleIdentifier</key><string>com.Vendor%s.Tool</string></dict></plist>\n' "$i" > "$app/Contents/Info.plist"
    apps_data+=("$i|$app|Vendor$i Tool|com.Vendor$i.Tool|0|Never|0")
done
verdict() { if uninstall_bundles_share_remnants "$2" "$3" "$4" "$5"; then echo "$1=shared"; else echo "$1=open"; fi; }
: > "$TR_COUNT_FILE"
verdict dot_continuation_any_case com.Foo.Bar com.foo.bar.PRO /A/Foo.app /A/Other.app
verdict same_id_any_case com.Foo.Bar COM.FOO.BAR /A/Foo.app /A/Other.app
verdict channel_name_any_case com.a.x com.b.y "/A/Zed Nightly.app" /A/ZED.app
verdict suffix_strip_is_case_sensitive com.a.x com.b.y "/A/Zed nightly.app" /A/Zed.app
verdict unrelated com.a.x com.b.y /A/Alpha.app /A/Beta.app
verdict one_letter_names com.a.x com.b.y /A/X.app /A/x.app
rc=0
uninstall_live_bundle_has_other_install com.example.selected "$selected" || rc=$?
echo "scan_rc=$rc"
rc=0
uninstall_bundle_id_has_surviving_sibling com.Example.Selected "$selected" || rc=$?
echo "rows_rc=$rc"
echo "names=[$(uninstall_surviving_sibling_names com.example.selected "$selected")]"
forks=$(wc -c < "$TR_COUNT_FILE")
echo "tr_execs=${forks//[[:space:]]/}"
# Positive control: the same harness still finds a real sibling.
mkdir -p "$HOME/Applications/Selected Pro.app/Contents"
printf '<plist><dict><key>CFBundleIdentifier</key><string>com.example.selected.pro</string></dict></plist>\n' > "$HOME/Applications/Selected Pro.app/Contents/Info.plist"
rc=0
uninstall_live_bundle_has_other_install com.example.selected "$selected" || rc=$?
echo "scan_with_sibling_rc=$rc"
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"dot_continuation_any_case=shared"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"same_id_any_case=shared"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"channel_name_any_case=shared"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"suffix_strip_is_case_sensitive=open"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"unrelated=open"* && "$output" == *"one_letter_names=open"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"scan_rc=1"* && "$output" == *"rows_rc=1"* && "$output" == *"names=[]"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"scan_with_sibling_rc=0"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"tr_execs=0"* ]] || { echo "$output"; return 1; }
}

@test "a retained leftover family names its cause once instead of per path" {
    # After the app is already in the Trash the user cannot select it again,
    # so the summary has to say why the data stayed. Three causes can retain a
    # family: a live sibling, an inventory that could not prove absence, and a
    # replacement at the selected path. Each gets its own label, once.
    local scenario label
    for scenario in shared unknown reappeared single; do
        run env HOME="$BATS_TEST_TMPDIR/home-$scenario" PROJECT_ROOT="$PROJECT_ROOT" \
            SCENARIO="$scenario" MOLE_TEST_NO_AUTH=1 MOLE_UNINSTALL_MODE=1 \
            MOLE_DELETE_MODE=trash /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$HOME/Applications/IntelliJ IDEA.app"
other="$HOME/Applications/Community.app"
support="$HOME/Library/Application Support/IntelliJ"
cache="$HOME/Library/Caches/com.jetbrains.intellij"
prefs="$HOME/Library/Preferences/com.jetbrains.intellij.plist"
mkdir -p "$selected/Contents" "$support" "$cache" "${prefs%/*}"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellij</string></dict></plist>' > "$selected/Contents/Info.plist"
printf 'state\n' > "$support/state"
printf 'cache\n' > "$cache/blob"
printf 'prefs\n' > "$prefs"
if [[ "$SCENARIO" == single ]]; then
    planned=("$support")
else
    planned=("$support" "$cache" "$prefs")
fi
# Retained bytes are subtracted from the plan, so size the plan up front.
retained_kb=$(du -skcP "${planned[@]}" | awk 'END {print $1}')
encoded=$(printf '%s\n' "${planned[@]}" | base64 | tr -d '\n')
fields=(IDEA "$selected" com.jetbrains.intellij "$((1000 + retained_kb))" "$encoded" '' false false false '' '' '' '' none x com.jetbrains.intellij '' x)
IFS='|' detail="${fields[*]}"; unset IFS
app_details=("$detail")
_batch_selected_app_plan_matches() { return 0; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
force_kill_app() { :; }
stop_inline_spinner() { :; }
defaults() { printf 'defaults:%s\n' "$*" >> "$HOME/forbidden"; }
bootout_login_item_helpers() { printf 'helpers\n' >> "$HOME/forbidden"; }
mole_delete() {
    if [[ "$1" == "$selected" ]]; then
        mv "$selected" "$HOME/removed-fixture.app"
        case "$SCENARIO" in
            shared | single)
                mkdir -p "$other/Contents"
                printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>com.jetbrains.intellij.ce</string></dict></plist>' > "$other/Contents/Info.plist"
                ;;
            unknown)
                ln -s "$HOME/Applications" "$HOME/unknown-root"
                _MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/unknown-root")
                ;;
            reappeared) mkdir -p "$selected/Contents" ;;
        esac
        return 0
    fi
    printf 'sink:%s\n' "$1" >> "$HOME/forbidden"
}
success_count=0 failed_count=0 brew_apps_removed=0 total_size_freed=0 files_cleaned=0 total_items=0
failed_items=() success_items=() success_dock_targets=() system_extension_warning_apps=()
review_only_system_leftovers=() review_only_system_leftover_keys=() running_at_uninstall_apps=()
_batch_execute_removals
[[ $success_count -eq 1 && $failed_count -eq 0 ]] || exit 1
[[ ! -e "$HOME/forbidden" ]] || { cat "$HOME/forbidden"; exit 1; }
[[ -f "$support/state" ]] || exit 1
printf 'FREED_KB=%s\n' "$total_size_freed"
EOF
        [ "$status" -eq 0 ] || { echo "$scenario: $output"; return 1; }
        case "$scenario" in
            shared) label='Kept (shared with another installed app): 3 paths' ;;
            unknown) label='Kept (other copies of the app could not be checked): 3 paths' ;;
            reappeared) label='Kept (selected app path exists again; select the app again): 3 paths' ;;
            single) label='Kept (shared with another installed app): ~/Library/Application Support/IntelliJ' ;;
        esac
        [[ "$output" == *"$label"* ]] || { echo "$scenario: $output"; return 1; }
        [[ "$(printf '%s\n' "$output" | grep -cF 'Kept (')" -eq 1 ]] || { echo "$scenario: $output"; return 1; }
        [[ "$output" != *"protected by Mole"* && "$output" != *"Could not remove"* ]] || { echo "$scenario: $output"; return 1; }
        [[ "$output" == *"FREED_KB=1000"* ]] || { echo "$scenario: $output"; return 1; }
    done
}

@test "live uninstall inventory counts a PlayCover bundle as a sibling install (#1715)" {
    # shellcheck disable=SC2016  # matches the literal source line, unexpanded
    grep -qF '"$HOME/Library/Containers/io.playcover.PlayCover/Applications"' \
        "$PROJECT_ROOT/lib/uninstall/batch.sh" || return 1
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
playcover="$HOME/Library/Containers/io.playcover.PlayCover/Applications"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications" "$playcover")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$HOME/Applications/Mole Probe.app"
mkdir -p "$selected/Contents" "$playcover/fit.mole.probe.app"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>fit.mole.probe</string></dict></plist>' > "$selected/Contents/Info.plist"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>fit.mole.probe</string></dict></plist>' > "$playcover/fit.mole.probe.app/Info.plist"
rc=0
uninstall_live_bundle_has_other_install fit.mole.probe "$selected" || rc=$?
printf 'PLAYCOVER_SIBLING_RC=%s\n' "$rc"
[[ $rc -eq 0 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "live uninstall inventory keeps shared data when a PlayCover bundle is selected beside a native copy (#1715)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
playcover="$HOME/Library/Containers/io.playcover.PlayCover/Applications"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications" "$playcover")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
selected="$playcover/fit.mole.probe.app"
mkdir -p "$selected" "$HOME/Applications/PlayCover/Mole Probe.app"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>fit.mole.probe</string></dict></plist>' > "$selected/Info.plist"
ln -s "$selected/Info.plist" "$HOME/Applications/PlayCover/Mole Probe.app/Info.plist"
# The launcher alias alone is not another install.
rc=0
uninstall_live_bundle_has_other_install fit.mole.probe "$selected" || rc=$?
printf 'ALIAS_ONLY_RC=%s\n' "$rc"
[[ $rc -eq 1 ]] || exit 1
native="$HOME/Applications/Mole Probe.app"
mkdir -p "$native/Contents"
printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>fit.mole.probe</string></dict></plist>' > "$native/Contents/Info.plist"
rc=0
uninstall_live_bundle_has_other_install fit.mole.probe "$selected" || rc=$?
printf 'NATIVE_SIBLING_RC=%s\n' "$rc"
[[ $rc -eq 0 ]] || exit 1
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
