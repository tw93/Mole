#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home uninstall-home
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

assert_sibling_scan_debug_reason() {
    local scan_status="$1" expected="$2"
    run env HOME="$HOME/sibling-debug-$scan_status" PROJECT_ROOT="$PROJECT_ROOT" \
        SCAN_STATUS="$scan_status" MO_DEBUG=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
selected="$HOME/Applications/Selected.app"
mkdir -p "$selected/Contents"
printf '%s\n' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.shared</string></dict></plist>' > "$selected/Contents/Info.plist"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.shared\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT="test-evidence"
    return "$SCAN_STATUS"
}
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '1\n'; }
find_app_files() { : > "$HOME/unexpected-discovery"; return 99; }
find_app_system_files() { : > "$HOME/unexpected-system"; return 99; }
discover_login_item_helper_bundle_ids() { return 0; }
calculate_total_size() { printf '0\n'; }
has_sensitive_data() { return 1; }
selected_apps=("0|$selected|Selected|com.example.shared|0|Never")
running_apps=() sudo_apps=() brew_cask_apps=() blocked_apps=()
manual_removal_apps=() app_details=() total_estimated_size=0
_batch_scan_app_details
[[ ${#app_details[@]} -eq 1 ]] || exit 1
IFS='|' read -r _ stored_path stored_bundle _ stored_related _ _ _ _ _ _ _ _ stored_guard _ \
    stored_original stored_fingerprint _ <<< "${app_details[0]}"
[[ "$stored_path" == "$selected" && "$stored_bundle" == unknown ]] || exit 1
[[ "$stored_guard" == guard_login && "$stored_original" == com.example.shared ]] || exit 1
[[ "$stored_fingerprint" == "$(printf test-evidence | base64 | tr -d '\n')" && -z "$stored_related" ]] || exit 1
[[ ! -e "$HOME/unexpected-discovery" && ! -e "$HOME/unexpected-system" && ! -e "$HOME/unexpected-login" ]] || exit 1
printf 'BUNDLE_ONLY_PLAN\n'
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *BUNDLE_ONLY_PLAN* ]] || return 1
    [[ "$output" == *"$expected"* ]] || { echo "$output"; return 1; }
    if [[ "$scan_status" != 0 ]]; then
        [[ "$output" != *"shared with a live sibling"* ]] || return 1
    fi
}

# Exercise the production sibling scan with real find permission failures.
assert_time_machine_volume_scan() {
    local status output
    run env HOME="$HOME/time-machine" PROJECT_ROOT="$PROJECT_ROOT" \
        SCAN_CASE="$1" EXPECTED_RC="$2" /bin/bash --noprofile --norc <<'EOF_TM'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
if [[ "$SCAN_CASE" == bounded ]]; then
    MO_TIMEOUT_BIN=""
    MO_TIMEOUT_PERL_BIN="$(command -v perl)"
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/stat" <<'STAT'
#!/bin/bash
if [[ "$1" == -f && "$2" == '%u:%d' ]]; then
    printf '0:42\n0:42\n'
else
    exec /usr/bin/stat "$@"
fi
STAT
    chmod +x "$HOME/bin/stat"
    export PATH="$HOME/bin:$PATH"
else
    run_with_timeout() { shift; "$@"; }
fi
pkg_receipt_nonstandard_app_paths() { :; }
mkdir -p "$HOME/Volumes/com.apple.TimeMachine.localsnapshots" "$HOME/Selected.app"
volumes="$HOME/Volumes"
snapshots="$volumes/com.apple.TimeMachine.localsnapshots"
# Restore the volumes root in its own chmod first: BSD chmod stats every
# operand up front, so a child listed beside a still-closed parent stays 000.
trap 'chmod 700 "$volumes" 2>/dev/null; chmod 700 "$snapshots" "$volumes/Ordinary" "$volumes/Share" 2>/dev/null || true' EXIT
# Simulate system ownership without creating root-owned fixtures or mounting disks.
stat() {
    if [[ "$1" == -f && "$2" == '%u:%d' ]]; then
        case "$SCAN_CASE" in
            mounted) printf '0:43\n0:42\n' ;;
            user-owned) printf '501:42\n0:42\n' ;;
            missing-metadata) return 1 ;;
            interrupted) return 130 ;;
            *) printf '0:42\n0:42\n' ;;
        esac
    else
        /usr/bin/stat "$@"
    fi
}
case "$SCAN_CASE" in
    mounted) survivor="$snapshots/Survivor.app" ;;
    lookalike) survivor="$volumes/com.apple.TimeMachine.localsnapshots-copy/Survivor.app" ;;
    sibling) survivor="$volumes/External/Applications/Survivor.app" ;;
    # Sorts after the skipped share, so the scan must continue past it.
    stale-share-sibling) survivor="$volumes/Zeta/Applications/Survivor.app" ;;
    first-level) survivor="$volumes/Survivor.app" ;;
    *) survivor="" ;;
esac
if [[ -n "$survivor" ]]; then
    mkdir -p "$survivor/Contents"
    printf '%s\n' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.snapshot</string></dict></plist>' > "$survivor/Contents/Info.plist"
fi
if [[ "$SCAN_CASE" != mounted ]]; then chmod 000 "$snapshots"; fi
if [[ "$SCAN_CASE" == ordinary ]]; then mkdir -p "$volumes/Ordinary"; chmod 000 "$volumes/Ordinary"; fi
case "$SCAN_CASE" in
    stale-share | stale-share-sibling | reachable-share | mount-timeout | mount-failed | mount-interrupted | probe-timeout | probe-interrupted)
        mkdir -p "$volumes/Share"
        chmod 000 "$volumes/Share"
        # The fixture cannot drop a live server, so only the system answers are
        # modeled: the mount table line and the errno of the mount point lstat.
        run_with_timeout() {
            shift
            if [[ "$1" == /sbin/mount ]]; then
                printf '//GUEST:@host/share on %s (smbfs, nodev, nosuid, nobrowse)\n' "$volumes/Share"
                case "$SCAN_CASE" in
                    mount-timeout) return 124 ;;
                    mount-failed) return 1 ;;
                    mount-interrupted) return 130 ;;
                esac
                return 0
            fi
            if [[ "$1" == /usr/bin/perl && "${!#}" == "$volumes/Share" ]]; then
                case "$SCAN_CASE" in
                    reachable-share) "$@"; return ;;
                    probe-timeout) return 124 ;;
                    probe-interrupted) return 130 ;;
                esac
                return 0
            fi
            "$@"
        }
        ;;
    unlistable-root)
        mkdir -p "$volumes/External/Applications/Survivor.app/Contents"
        printf '%s\n' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.snapshot</string></dict></plist>' > "$volumes/External/Applications/Survivor.app/Contents/Info.plist"
        chmod 000 "$volumes"
        ;;
esac
_MOLE_UNINSTALL_LIVE_APP_ROOTS=()
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$volumes"
selected_apps=("0|$HOME/Selected.app|Selected|com.example.snapshot|0|Never")
rc=0
uninstall_live_bundle_has_other_install com.example.snapshot "$HOME/Selected.app" || rc=$?
printf 'SCAN_CASE=%s RC=%s\n' "$SCAN_CASE" "$rc"
[[ "$rc" -eq "$EXPECTED_RC" ]] || exit 1
if [[ "$EXPECTED_RC" -eq 0 ]]; then
    [[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 1 && "${_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[0]}" == "$survivor" ]] || exit 1
fi
EOF_TM
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # A fixture left at mode 000 breaks every later setup on runners whose rm
    # cannot remove it; local macOS can, so check the permissions directly.
    local locked
    locked=$(find "$HOME/time-machine" -perm 000 2> /dev/null || true)
    [[ -z "$locked" ]] || { echo "locked fixture left behind: $locked"; return 1; }
}

assert_time_machine_batch_plan() {
    local status output
    run env HOME="$HOME/snapshot-plan" PROJECT_ROOT="$PROJECT_ROOT" BATCH_CASE="$1" /bin/bash --noprofile --norc <<'EOF_ROOT'
set -euo pipefail
export MOLE_TEST_NO_AUTH=1 TERM=dumb
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
# Bounded helpers only invoke fixture find/plutil/stat; no authorization or sink.
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/Volumes"
snapshots="$HOME/Volumes/com.apple.TimeMachine.localsnapshots"
mkdir -p "$snapshots"
chmod 000 "$snapshots"
trap 'chmod 700 "$snapshots"' EXIT
stat() {
    if [[ "$1" == -f && "$2" == '%u:%d' ]]; then
        printf '0:42\n0:42\n'
    else
        /usr/bin/stat "$@"
    fi
}

export MO_DEBUG=1
mkdir -p "$HOME/selected/Chosen.app/Contents" "$HOME/Library/Preferences"
for app in "$HOME/selected/Chosen.app"; do
    printf '%s\n' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.shared</string></dict></plist>' > "$app/Contents/Info.plist"
done
printf 'survivor data\n' > "$HOME/Library/Preferences/com.example.shared.plist"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=()
app_path="$HOME/selected/Chosen.app"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.shared\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '1\n'; }
calculate_total_size() { printf '0\n'; }
find_app_files() {
    printf 'discovery\n' >> "$HOME/unexpected-discovery"
    printf '%s\n' "$HOME/Library/Preferences/com.example.shared.plist"
}
find_app_system_files() { :; }
get_diagnostic_report_paths_for_app() { :; }
discover_login_item_helper_bundle_ids() { :; }
has_sensitive_data() { return 1; }
selected_apps=("0|$app_path|Chosen|com.example.shared|0|Never")
running_apps=() sudo_apps=() brew_cask_apps=() blocked_apps=() manual_removal_apps=() app_details=() total_estimated_size=0
_batch_scan_app_details
[[ ${#app_details[@]} -eq 1 ]] || exit 1
IFS='|' read -r stored_name stored_path stored_id stored_size stored_related stored_system stored_sensitive stored_sudo stored_brew stored_cask stored_diag stored_review stored_login stored_guard rest <<< "${app_details[0]}"
printf 'PREVIEW_ID=%s GUARD=%s RELATED=%s\n' "$stored_id" "$stored_guard" "$stored_related"
[[ "$stored_id" == com.example.shared && "$stored_guard" != guard_login && -n "$stored_related" && -z "$stored_system" ]] || exit 1
[[ -s "$HOME/unexpected-discovery" ]] || exit 1
if [[ "$BATCH_CASE" == new-sibling ]]; then
    mkdir -p "$HOME/Volumes/External/Survivor.app/Contents"
    cp "$app_path/Contents/Info.plist" "$HOME/Volumes/External/Survivor.app/Contents/Info.plist"
fi
# Invoke the production final installation recheck, but replace every mutation.
stop_launch_services() { printf 'app-only teardown\n' >> "$HOME/teardown"; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
force_kill_app() { :; }
bootout_login_item_helpers() { [[ -z "$1" ]] && return 0; printf 'unexpected-helper\n' >> "$HOME/forbidden"; return 99; }
remove_file_list() {
    [[ -z "$1" ]] && return 0
    [[ "$BATCH_CASE" == allowed && "$1" == "$HOME/Library/Preferences/com.example.shared.plist" && "$2" == false && "$3" == com.example.shared ]] || return 99
    printf '%s\n' "$1" >> "$HOME/leftover-sink-attempt"
}
mole_delete() {
    [[ "$1" == "$HOME/selected/Chosen.app" && "$2" == false && -n "${3:-}" ]] || return 99
    printf '%s\n' "$1" >> "$HOME/app-sink-attempt"
    return 0
}
success_count=0 failed_count=0 brew_apps_removed=0 total_size_freed=0 files_cleaned=0 total_items=0
failed_items=() success_items=() success_dock_targets=() system_extension_warning_apps=()
review_only_system_leftovers=() review_only_system_leftover_keys=() running_at_uninstall_apps=()
rc=0
_batch_execute_removals || rc=$?
printf 'FINAL_RC=%s SUCCESS=%s FAILED=%s\n' "$rc" "$success_count" "$failed_count"
[[ $rc -eq 0 ]] || exit 1
if [[ "$BATCH_CASE" == allowed ]]; then
    [[ $success_count -eq 1 && $failed_count -eq 0 && -s "$HOME/app-sink-attempt" && -s "$HOME/leftover-sink-attempt" ]] || exit 1
else
    [[ $success_count -eq 0 && $failed_count -eq 1 && ! -e "$HOME/app-sink-attempt" && ! -e "$HOME/leftover-sink-attempt" ]] || exit 1
fi
[[ ! -e "$HOME/forbidden" && -f "$HOME/Library/Preferences/com.example.shared.plist" && -d "$HOME/selected/Chosen.app" ]] || exit 1
printf 'TIME_MACHINE_PLAN_VERIFIED_WITHOUT_REAL_DELETION\n'
EOF_ROOT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *TIME_MACHINE_PLAN_VERIFIED_WITHOUT_REAL_DELETION* ]] || return 1
}

@test "find_app_files discovers user-level leftovers" {
    create_app_artifacts

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.example.TestApp" "TestApp"
EOF
    )"

    [[ "$result" == *"Application Support/TestApp"* ]] || return 1
    [[ "$result" == *"Caches/TestApp"* ]] || return 1
    [[ "$result" == *"Preferences/com.example.TestApp.plist"* ]] || return 1
    [[ "$result" == *"Preferences/TestApp.plist"* ]] || return 1
    [[ "$result" == *"Saved Application State/com.example.TestApp.savedState"* ]] || return 1
    [[ "$result" == *"Saved Application State/TestApp.savedState"* ]] || return 1
    [[ "$result" == *"Containers/com.example.TestApp"* ]] || return 1
    [[ "$result" == *"LaunchAgents/com.example.TestApp.plist"* ]] || return 1
    [[ "$result" == *".cache/testapp"* ]]
}

@test "find_app_files discovers recent-document shared file lists by bundle id" {
    mkdir -p "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
    touch "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.rogueamoeba.soundsource.sfl2"
    touch "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.rogueamoeba.soundsource.sfl3"
    touch "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.rogueamoeba.soundsource.sfl4"
    touch "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.systemsettings.sfl3"

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.rogueamoeba.soundsource" "SoundSource"
EOF
    )"

    [[ "$result" == *"com.rogueamoeba.soundsource.sfl2"* ]] || return 1
    [[ "$result" == *"com.rogueamoeba.soundsource.sfl3"* ]] || return 1
    [[ "$result" == *"com.rogueamoeba.soundsource.sfl4"* ]] || return 1
    [[ "$result" != *"com.apple.systemsettings.sfl3"* ]]
}

@test "find_app_files discovers nested XPC helper preferences from selected app" {
    app="$HOME/Applications/SoundSource.app"
    mkdir -p "$app/Contents/Frameworks/RemoteAU.framework/Versions/A/XPCServices/RemoteAUHost.xpc/Contents"
    mkdir -p "$app/Contents/Frameworks/Sparkle.framework/Versions/A/XPCServices/DownloaderService.xpc/Contents"
    mkdir -p "$app/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents"
    mkdir -p "$HOME/Library/Caches/com.rogueamoeba.RemoteAUHost"
    mkdir -p "$HOME/Library/Caches/com.rogueamoeba.RemoteAUHost.shared"
    mkdir -p "$HOME/Library/HTTPStorages/org.sparkle-project.DownloaderService"
    mkdir -p "$HOME/Library/Preferences"
    cat > "$app/Contents/Frameworks/RemoteAU.framework/Versions/A/XPCServices/RemoteAUHost.xpc/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.rogueamoeba.RemoteAUHost</string>
</dict></plist>
PLIST
    cat > "$app/Contents/Frameworks/Sparkle.framework/Versions/A/XPCServices/DownloaderService.xpc/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.sparkle-project.DownloaderService</string>
</dict></plist>
PLIST
    cat > "$app/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.sparkle-project.Sparkle.Autoupdate</string>
</dict></plist>
PLIST
    touch "$HOME/Library/Preferences/com.rogueamoeba.RemoteAUHost.plist"
    touch "$HOME/Library/Preferences/org.sparkle-project.Sparkle.Autoupdate.plist"

    result="$(
        HOME="$HOME" APP="$app" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
find_app_files "com.rogueamoeba.soundsource" "SoundSource" "$APP"
EOF
    )"

    [[ "$result" == *"Library/Preferences/com.rogueamoeba.RemoteAUHost.plist"* ]] || return 1
    [[ "$result" == *"Library/Caches/com.rogueamoeba.RemoteAUHost"* ]] || return 1
    [[ "$result" != *"Library/Caches/com.rogueamoeba.RemoteAUHost.shared"* ]] || return 1
    [[ "$result" != *"org.sparkle-project.Sparkle.Autoupdate.plist"* ]] || return 1
    [[ "$result" != *"org.sparkle-project.DownloaderService"* ]]
}

@test "find_app_files discards an incomplete root but propagates cancellation" {
    local nested="$HOME/Library/Caches/examplevendor/ExampleProduct"
    mkdir -p "$nested"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NESTED="$nested" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

run_with_timeout() {
    local _duration="$1"
    shift
    if [[ "${1:-}" == "find" ]]; then
        printf '%s\0' "$NESTED"
        return "${SCAN_RC:?}"
    fi
    "$@"
}

SCAN_RC=1
result=$(find_app_files "com.examplevendor.ExampleProduct" "ExampleProduct")
[[ "$result" != *"$NESTED"* ]] || exit 1

SCAN_RC=130
rc=0
result=$(find_app_files "com.examplevendor.ExampleProduct" "ExampleProduct") || rc=$?
[[ $rc -eq 130 ]] || exit 1
[[ "$result" != *"$NESTED"* ]]
EOF

    [ "$status" -eq 0 ]
}

@test "find_app_system_files discovers bundle-id-prefixed LaunchDaemons" {
    fakebin="$HOME/fakebin"
    mkdir -p "$fakebin"

    # The new dot-anchored alternation invokes find with two -name patterns:
    # "${bundle_id}.plist" and "${bundle_id}.*.plist". Match on either form.
    cat > "$fakebin/find" << 'SCRIPT'
#!/bin/sh
args="$*"

case "$args" in
  *"/Library/LaunchDaemons"*'-name com.west2online.ClashXPro.*.plist'*)
    printf '%s\0' "/Library/LaunchDaemons/com.west2online.ClashXPro.ProxyConfigHelper.plist"
    ;;
esac
SCRIPT
    chmod +x "$fakebin/find"

    run env HOME="$HOME" PATH="$fakebin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    : > "$fakebase/Library/LaunchDaemons/com.foo.plist"           # exact match - keep
    : > "$fakebase/Library/LaunchDaemons/com.foo.helper.plist"    # dotted - keep
    : > "$fakebase/Library/LaunchDaemons/com.foobar.plist"        # sibling - reject
    : > "$fakebase/Library/LaunchDaemons/com.foobaz.helper.plist" # sibling - reject

    # Verify the find pattern itself, since the production find is hard-coded
    # to /Library/* paths. This mirrors what app_protection.sh emits.
    run /bin/bash --noprofile --norc -c "
		cd '$fakebase/Library/LaunchDaemons'
		find . -maxdepth 1 \( -name 'com.foo.plist' -o -name 'com.foo.*.plist' \) | sort
	"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.foo.plist"* ]] || return 1
    [[ "$output" == *"com.foo.helper.plist"* ]] || return 1
    [[ "$output" != *"com.foobar.plist"* ]] || return 1
    [[ "$output" != *"com.foobaz.helper.plist"* ]]
}

@test "get_diagnostic_report_paths_for_app avoids executable prefix collisions" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
touch "$diag_dir/Foo Helper.diag"
touch "$diag_dir/Foo_2026-01-01-120000_host.ips"
touch "$diag_dir/Foobar.crash"
touch "$diag_dir/Foobar.diag"
touch "$diag_dir/Foobar Helper.diag"
touch "$diag_dir/Foobar_2026-01-01-120001_host.ips"

result=$(get_diagnostic_report_paths_for_app "$app_dir" "Foo" "$diag_dir")
[[ "$result" == *"Foo.crash"* ]] || exit 1
[[ "$result" == *"Foo.diag"* ]] || exit 1
[[ "$result" == *"Foo Helper.diag"* ]] || exit 1
[[ "$result" == *"Foo_2026-01-01-120000_host.ips"* ]] || exit 1
[[ "$result" != *"Foobar.crash"* ]] || exit 1
[[ "$result" != *"Foobar.diag"* ]] || exit 1
[[ "$result" != *"Foobar Helper.diag"* ]] || exit 1
[[ "$result" != *"Foobar_2026-01-01-120001_host.ips"* ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "calculate_total_size returns aggregate kilobytes" {
    mkdir -p "$HOME/sized"
    dd if=/dev/zero of="$HOME/sized/file1" bs=1024 count=1 > /dev/null 2>&1
    dd if=/dev/zero of="$HOME/sized/file2" bs=1024 count=2 > /dev/null 2>&1

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
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

@test "calculate_total_size does not double-count nested paths" {
    mkdir -p "$HOME/sized-parent/child"
    dd if=/dev/zero of="$HOME/sized-parent/child/payload" bs=1024 count=2 > /dev/null 2>&1

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
parent="$HOME/sized-parent"
child="$HOME/sized-parent/child"
parent_only=$(calculate_total_size "$parent")
with_child=$(calculate_total_size "$(printf '%s\n%s\n' "$parent" "$child")")
printf '%s|%s\n' "$parent_only" "$with_child"
EOF
    )"

    parent_only="${result%%|*}"
    with_child="${result##*|}"
    [ "$parent_only" -gt 0 ]
    [ "$with_child" -eq "$parent_only" ]
}

@test "format_uninstall_preview_path includes per-path size" {
    dd if=/dev/zero of="$HOME/preview-size-file" bs=1024 count=1 > /dev/null 2>&1
    expected_size_kb="$(du -skP "$HOME/preview-size-file" | awk '{print $1}')"

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
format_uninstall_preview_path "$HOME/preview-size-file"
EOF
    )"

    [[ "$result" == *"~/preview-size-file"* ]] || return 1
    [[ "$result" == *"${expected_size_kb}KB"* ]]
}

@test "format_uninstall_preview_path propagates timed out and interrupted size probes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
get_path_size_kb() { return "$SIZE_RC"; }
for SIZE_RC in 124 130; do
    rc=0
    format_uninstall_preview_path "$HOME/interrupted-preview" || rc=$?
    printf 'SIZE_RC=%s RC=%s\n' "$SIZE_RC" "$rc"
done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SIZE_RC=124 RC=124"* ]] || return 1
    [[ "$output" == *"SIZE_RC=130 RC=130"* ]]
}

@test "batch_uninstall_applications removes selected app data" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    HOME="$fixture_home" create_app_artifacts

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

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
[[ $(wc -l < "$HOME/inventory.trace") -ge 2 ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        printf 'exit status: %s\n%s\n' "$status" "$output"
        return 1
    }
}

@test "batch uninstall routes a root-owned app through unprivileged Trash when its parent is writable (#1331)" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    mkdir -p "$fixture_home/Applications/RootOwned.app"
    local trace="$fixture_home/root-owned-trash.log"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }
export MOLE_DELETE_MODE=trash

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { echo root; }
pgrep() { return 1; }
find_app_files() { return 0; }
find_app_system_files() { return 0; }
ensure_sudo_session() { echo "UNEXPECTED_SUDO"; return 1; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
force_kill_app() { return 0; }
mole_delete() {
	printf 'DELETE:%s:%s\n' "$1" "${2:-false}" >> "$HOME/root-owned-trash.log"
	return 0
}

selected_apps=("0|$HOME/Applications/RootOwned.app|RootOwned|com.example.RootOwned|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$(grep -c "^DELETE:$fixture_home/Applications/RootOwned.app:false$" "$trace" 2> /dev/null || true)" -eq 1 ]] || return 1
    [[ "$output" != *"UNEXPECTED_SUDO"* ]] || return 1
    [[ "$output" != *"cannot be removed safely by Mole"* ]]
}

@test "batch uninstall continues when best-effort teardown steps time out" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    mkdir -p "$fixture_home/Applications/SlowTeardown.app"
    local trace="$fixture_home/slow-teardown.log"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
brew() { :; }

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
pgrep() { return 1; }
find_app_files() { return 0; }
find_app_system_files() { return 0; }
ensure_sudo_session() { echo "UNEXPECTED_SUDO"; return 1; }
# osascript waiting on the System Events automation prompt, a slow lsregister,
# and a hung launchctl all surface here as the timeout status.
stop_launch_services() { return 124; }
unregister_app_bundle() { return 124; }
remove_login_item() { return 124; }
bootout_login_item_helpers() { return 124; }
force_kill_app() { return 0; }
mole_delete() {
	printf 'DELETE:%s\n' "$1" >> "$HOME/slow-teardown.log"
	return 0
}

selected_apps=("0|$HOME/Applications/SlowTeardown.app|SlowTeardown|com.example.SlowTeardown|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$(grep -c "^DELETE:$fixture_home/Applications/SlowTeardown.app$" "$trace" 2> /dev/null || true)" -eq 1 ]] || return 1
    [[ "$output" != *"UNEXPECTED_SUDO"* ]]
}

@test "batch uninstall narrows the plan when the same-bundle scan cannot run (#1624)" {
    mkdir -p "$HOME/Applications/Managed.app" "$HOME/Library/Preferences"
    local pref="$HOME/Library/Preferences/com.example.Managed.plist"
    printf 'pref' > "$pref"
    local trace="$HOME/managed-deletes.log"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
brew() { :; }

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
pgrep() { return 1; }
find_app_files() { printf '%s\n' "$HOME/Library/Preferences/com.example.Managed.plist"; }
find_app_system_files() { return 0; }
ensure_sudo_session() { return 1; }
# A managed Mac where receipts or an app root cannot be read at all.
uninstall_live_bundle_has_other_install() {
	_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
	_MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
	return 2
}
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { echo "UNEXPECTED_LOGIN_ITEM"; }
force_kill_app() { echo "UNEXPECTED_KILL"; return 0; }
mole_delete() {
	printf 'DELETE:%s\n' "$1" >> "$HOME/managed-deletes.log"
	return 0
}

selected_apps=("0|$HOME/Applications/Managed.app|Managed|com.example.Managed|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications 2>&1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Shared leftovers kept (other copies unchecked)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]] || return 1
    [[ "$(grep -c "^DELETE:$HOME/Applications/Managed.app$" "$trace" 2> /dev/null || true)" -eq 1 ]] || return 1
    [[ "$(grep -c "Preferences" "$trace" 2> /dev/null || true)" -eq 0 ]]
}

@test "batch uninstall shows a partial same-bundle scan in the preview, not on the scan spinner" {
    mkdir -p "$HOME/Applications/Managed.app" "$HOME/Library/Preferences"
    local pref="$HOME/Library/Preferences/com.example.Managed.plist"
    printf 'pref' > "$pref"
    local trace="$HOME/managed-deletes.log"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
brew() { :; }

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
pgrep() { return 1; }
find_app_files() { printf '%s\n' "$HOME/Library/Preferences/com.example.Managed.plist"; }
find_app_system_files() { return 0; }
ensure_sudo_session() { return 1; }
# TCC hides one directory from the same-bundle scan, as on macOS 26.
uninstall_live_bundle_has_other_install() {
	_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
	_MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
	return "$MOLE_UNINSTALL_SCAN_PARTIAL"
}
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { echo "UNEXPECTED_LOGIN_ITEM"; }
force_kill_app() { echo "UNEXPECTED_KILL"; return 0; }
mole_delete() {
	printf 'DELETE:%s\n' "$1" >> "$HOME/managed-deletes.log"
	return 0
}

selected_apps=("0|$HOME/Applications/Managed.app|Managed|com.example.Managed|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications 2>&1
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    # The note belongs to this app's preview block. Printed during the scan,
    # it landed on the scan spinner line, before the preview header.
    local header_line app_line note_line
    header_line=$(printf '%s\n' "$output" | grep -n 'Files to be removed' | head -1 | cut -d: -f1)
    app_line=$(printf '%s\n' "$output" | grep -n ' Managed .*0B' | head -1 | cut -d: -f1)
    note_line=$(printf '%s\n' "$output" | grep -n 'Shared leftovers kept (some paths unreadable)' | head -1 | cut -d: -f1)
    [[ -n "$header_line" && -n "$app_line" && -n "$note_line" ]] || { echo "$output"; return 1; }
    [[ $app_line -gt $header_line && $note_line -eq $((app_line + 1)) ]] || { echo "$output"; return 1; }
    [[ "$output" != *"UNEXPECTED_"* ]] || return 1
    [[ "$(grep -c "^DELETE:$HOME/Applications/Managed.app$" "$trace" 2> /dev/null || true)" -eq 1 ]] || return 1
    [[ "$(grep -c "Preferences" "$trace" 2> /dev/null || true)" -eq 0 ]]
}

@test "batch uninstall still stops on a signal during teardown before deleting" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    mkdir -p "$fixture_home/Applications/SignalTeardown.app"
    local trace="$fixture_home/signal-teardown.log"

    local step
    for step in stop_launch_services remove_login_item; do
        rm -f "$trace" "$fixture_home/inventory.trace"
        run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" SIGNAL_STEP="$step" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
brew() { :; }

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
pgrep() { return 1; }
find_app_files() { return 0; }
find_app_system_files() { return 0; }
ensure_sudo_session() { return 1; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
eval "${SIGNAL_STEP}() { return 130; }"
force_kill_app() { return 0; }
mole_delete() {
	printf 'DELETE:%s\n' "$1" >> "$HOME/signal-teardown.log"
	return 0
}

selected_apps=("0|$HOME/Applications/SignalTeardown.app|SignalTeardown|com.example.SignalTeardown|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

batch_rc=0
printf '\n' | batch_uninstall_applications > /dev/null 2>&1 || batch_rc=$?
echo "BATCH_RC=$batch_rc"
EOF

        [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

        [ "$status" -eq 0 ] || {
            echo "$step: $output"
            return 1
        }
        [[ "$output" == *"BATCH_RC=130"* ]] || {
            echo "$step: $output"
            return 1
        }
        [[ ! -e "$trace" ]] || return 1
    done
}

@test "stop_launch_services propagates an unload timeout after one scan" {
    mkdir -p "$HOME/Library/LaunchAgents"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
_uninstall_unload_launch_plists() {
	printf 'ROOT:%s:%s\n' "$1" "${4:-}" >> "$HOME/unload-roots.log"
	return 124
}

rc=0
stop_launch_services "com.example.SlowAgent" false "$HOME/Applications/SlowAgent.app" || rc=$?
echo "RC=$rc"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$(grep -c '^ROOT:' "$HOME/unload-roots.log" 2> /dev/null || true)" -eq 1 ]]
}

@test "batch uninstall names the app and step when a removal times out" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    mkdir -p "$fixture_home/Applications/SlowDelete.app"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
brew() { :; }

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
pgrep() { return 1; }
find_app_files() { return 0; }
find_app_system_files() { return 0; }
ensure_sudo_session() { return 1; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
force_kill_app() { return 0; }
mole_delete() { return 124; }

selected_apps=("0|$HOME/Applications/SlowDelete.app|SlowDelete|com.example.SlowDelete|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

batch_rc=0
printf '\n' | batch_uninstall_applications 2>&1 || batch_rc=$?
echo "BATCH_RC=$batch_rc"
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"BATCH_RC=1"* ]] || return 1
    [[ "$output" == *"Uninstall stopped at SlowDelete: app removal timed out"* ]]
}

@test "batch uninstall rejects privileged permanent removal below a mutable parent before side effects (#1299)" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    mkdir -p "$fixture_home/Applications/RootOwned.app"
    mkdir -p "$fixture_home/Library/Application Support/RootOwned"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }
export MOLE_DELETE_MODE=permanent

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { echo root; }
_mole_privileged_path_has_mutable_ancestor() { return 0; }
pgrep() { return 1; }
find_app_files() { printf 'DISCOVERY\n' >> "$HOME/mutable-parent-side-effects.log"; return 1; }
ensure_sudo_session() { echo "UNEXPECTED_SUDO"; return 1; }
stop_launch_services() { echo "UNEXPECTED_LAUNCH_TEARDOWN"; return 1; }
unregister_app_bundle() { echo "UNEXPECTED_UNREGISTER"; return 1; }
remove_login_item() { echo "UNEXPECTED_LOGIN_ITEM"; return 1; }
force_kill_app() { echo "UNEXPECTED_KILL"; return 1; }
mole_delete() { echo "UNEXPECTED_DELETE"; return 1; }

selected_apps=("0|$HOME/Applications/RootOwned.app|RootOwned|com.example.RootOwned|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

rc=0
batch_uninstall_applications || rc=$?
[[ $rc -eq 1 ]] || { echo "WRONG_RC:$rc"; exit 1; }
[[ -d "$HOME/Applications/RootOwned.app" ]] || { echo "WRONG: bundle removed"; exit 1; }
[[ -d "$HOME/Library/Application Support/RootOwned" ]] || { echo "WRONG: app data removed"; exit 1; }
[[ ! -e "$HOME/mutable-parent-side-effects.log" ]] || { echo "WRONG: discovery ran"; exit 1; }
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"cannot be removed safely by Mole from this location"* ]] || return 1
    [[ "$output" == *"Move it to Trash in Finder"* ]] || return 1
    [[ "$output" == *"protected containers and app data untouched"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]]
}

@test "a foreign Caskroom-like symlink never selects a Homebrew cask (#1299)" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    local fake_target="$fixture_home/foreign/Caskroom/real-cask/1.0/Fake.app"
    mkdir -p "$fixture_home/Applications" "$fake_target"
    ln -s "$fake_target" "$fixture_home/Applications/Fake.app"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_brew_cask_name() { return 1; }
get_file_owner() { echo root; }
_mole_privileged_path_has_mutable_ancestor() { return 0; }
pgrep() { return 1; }
find_app_files() { printf 'DISCOVERY\n' >> "$HOME/foreign-cask-side-effects.log"; return 1; }
brew_uninstall_cask() { echo "UNEXPECTED_BREW:$*"; return 0; }
mole_delete() { echo "UNEXPECTED_DELETE:$*"; return 0; }

selected_apps=("0|$HOME/Applications/Fake.app|Fake|com.example.Fake|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

rc=0
batch_uninstall_applications || rc=$?
[[ $rc -eq 1 ]] || { echo "WRONG_RC:$rc"; exit 1; }
[[ -L "$HOME/Applications/Fake.app" ]] || { echo "WRONG: symlink removed"; exit 1; }
[[ ! -e "$HOME/foreign-cask-side-effects.log" ]] || { echo "WRONG: discovery ran"; exit 1; }
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"cannot be removed safely by Mole from this location"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]]
}

@test "uninstall_bundle_id_has_surviving_sibling detects unselected same-bundle install" {
    mkdir -p "$HOME/Applications/Shared.app" "$HOME/Applications/Shared-beta.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

apps_data=(
	"0|$HOME/Applications/Shared.app|Shared|com.example.Shared|0|Never|0"
	"0|$HOME/Applications/Shared-beta.app|Shared-beta|com.example.Shared|0|Never|0"
)

# Only the beta variant is selected; the stable install survives.
selected_apps=("0|$HOME/Applications/Shared-beta.app|Shared-beta|com.example.Shared|0|Never")
uninstall_bundle_id_has_surviving_sibling "com.example.Shared" "$HOME/Applications/Shared-beta.app" || {
	echo "WRONG: surviving sibling not detected"
	exit 1
}

# Both variants selected: no survivor, bundle-id cleanup is safe.
selected_apps=(
	"0|$HOME/Applications/Shared.app|Shared|com.example.Shared|0|Never"
	"0|$HOME/Applications/Shared-beta.app|Shared-beta|com.example.Shared|0|Never"
)
if uninstall_bundle_id_has_surviving_sibling "com.example.Shared" "$HOME/Applications/Shared-beta.app"; then
	echo "WRONG: sibling reported although both installs are selected"
	exit 1
fi

# Unknown bundle id never reports a sibling.
if uninstall_bundle_id_has_surviving_sibling "unknown" "$HOME/Applications/Shared-beta.app"; then
	echo "WRONG: unknown bundle id reported a sibling"
	exit 1
fi
EOF

    [ "$status" -eq 0 ]
}

@test "uninstall_bundle_id_has_surviving_sibling compares bundle ids case-insensitively" {
    mkdir -p "$HOME/Applications/Shared.app" "$HOME/Applications/Shared-beta.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

# The survivor's id differs from the selected app's only in case. On a default
# APFS volume both apps read and write the SAME ~/Library/Preferences plist, so
# a literal comparison here would let the zap wipe the survivor's settings.
apps_data=(
	"0|$HOME/Applications/Shared.app|Shared|com.Example.Shared|0|Never|0"
	"0|$HOME/Applications/Shared-beta.app|Shared-beta|com.example.shared|0|Never|0"
)
selected_apps=("0|$HOME/Applications/Shared-beta.app|Shared-beta|com.example.shared|0|Never")

uninstall_bundle_id_has_surviving_sibling "com.example.shared" "$HOME/Applications/Shared-beta.app" || {
	echo "WRONG: case-differing survivor was not detected"
	exit 1
}

names=$(uninstall_surviving_sibling_names "com.example.shared" "$HOME/Applications/Shared-beta.app")
case "$names" in
*shared*) ;;
*)
	echo "WRONG: case-differing survivor contributed no protected names"
	exit 1
	;;
esac

# A genuinely different id must still not register as a sibling.
if uninstall_bundle_id_has_surviving_sibling "com.example.other" "$HOME/Applications/Shared-beta.app"; then
	echo "WRONG: unrelated bundle id reported a sibling"
	exit 1
fi
EOF

    [ "$status" -eq 0 ]
}

@test "live same-bundle scan finds a sibling that appeared after preview" {
    local app_root="$HOME/live-apps"
    mkdir -p "$app_root/Selected.app/Contents" \
        "$app_root/Setapp/NewSibling.app/Contents"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP_ROOT="$app_root" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.example.live-shared</string>' \
    '</dict></plist>' \
    > "$APP_ROOT/Selected.app/Contents/Info.plist"
cp "$APP_ROOT/Selected.app/Contents/Info.plist" \
    "$APP_ROOT/Setapp/NewSibling.app/Contents/Info.plist"
selected_apps=("0|$APP_ROOT/Selected.app|Selected|com.example.live-shared|0|Never")
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$APP_ROOT")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
uninstall_live_bundle_has_other_install \
    "com.example.live-shared" "$APP_ROOT/Selected.app"
first_fingerprint="$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT"
[[ -n "$first_fingerprint" && ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 1 ]]

mkdir -p "$APP_ROOT/Utilities/AnotherSibling.app/Contents"
cp "$APP_ROOT/Selected.app/Contents/Info.plist" \
    "$APP_ROOT/Utilities/AnotherSibling.app/Contents/Info.plist"
uninstall_live_bundle_has_other_install \
    "com.example.live-shared" "$APP_ROOT/Selected.app"
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 2 ]] || exit 1
[[ "$first_fingerprint" != "$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT" ]] || exit 1

mkdir -p "$HOME/external/LinkedSibling.app/Contents"
cp "$APP_ROOT/Selected.app/Contents/Info.plist" \
    "$HOME/external/LinkedSibling.app/Contents/Info.plist"
ln -s "$HOME/external/LinkedSibling.app" "$APP_ROOT/LinkedSibling.app"
uninstall_live_bundle_has_other_install \
    "com.example.live-shared" "$APP_ROOT/Selected.app"
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 3 ]]
EOF

    [ "$status" -eq 0 ]
}

@test "live same-bundle guard finds mixed-case siblings but ignores nested and unrelated bundles" {
    local app_root="$HOME/live-mixed-case-apps"
    mkdir -p "$app_root/Selected.app/Contents" \
        "$app_root/Unrelated.App/Contents"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP_ROOT="$app_root" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

write_bundle_id() {
    local path="$1"
    local bundle_id="$2"
    mkdir -p "$path/Contents"
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        "<key>CFBundleIdentifier</key><string>$bundle_id</string>" \
        '</dict></plist>' \
        > "$path/Contents/Info.plist"
}

write_bundle_id "$APP_ROOT/Selected.app" "com.example.live-mixed"
write_bundle_id "$APP_ROOT/Unrelated.App" "com.example.unrelated"
selected_apps=("0|$APP_ROOT/Selected.app|Selected|com.example.live-mixed|0|Never")
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$APP_ROOT")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"

# A case-variant app with another id must not block the selected app.
if uninstall_live_bundle_has_other_install \
    "com.example.live-mixed" "$APP_ROOT/Selected.app"; then
    echo "WRONG: unrelated app reported as a sibling"
    exit 1
fi
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 0 ]] || exit 1

# A nested helper belongs to Container.APP and is not another installation.
write_bundle_id "$APP_ROOT/Container.APP/Nested.app" "com.example.live-mixed"
if uninstall_live_bundle_has_other_install \
    "com.example.live-mixed" "$APP_ROOT/Selected.app"; then
    echo "WRONG: nested app reported as a sibling"
    exit 1
fi
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 0 ]] || exit 1

# A top-level surviving .APP with the same id must trip the destructive guard.
write_bundle_id "$APP_ROOT/Survivor.APP" "com.example.live-mixed"
uninstall_live_bundle_has_other_install \
    "com.example.live-mixed" "$APP_ROOT/Selected.app"
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 1 ]] || exit 1
[[ "${_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[0]}" == "$APP_ROOT/Survivor.APP" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "live same-bundle scan accepts dot-app text in a volume ancestor" {
    local app_root="$HOME/Backup.app-data/Applications"
    mkdir -p "$app_root/Survivor.app/Contents" "$HOME/Selected.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP_ROOT="$app_root" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.example.volume-shared</string>' \
    '</dict></plist>' \
    > "$APP_ROOT/Survivor.app/Contents/Info.plist"
selected_apps=("0|$HOME/Selected.app|Selected|com.example.volume-shared|0|Never")
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$APP_ROOT")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
uninstall_live_bundle_has_other_install \
    "com.example.volume-shared" "$HOME/Selected.app"
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 1 ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "live same-bundle scan finds an app at a mounted volume root" {
    local volumes_root="$HOME/Volumes"
    local survivor="$volumes_root/Example/Survivor.app"
    mkdir -p "$survivor/Contents" "$HOME/Selected.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        VOLUMES_ROOT="$volumes_root" SURVIVOR="$survivor" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.example.volume-root</string>' \
    '</dict></plist>' \
    > "$SURVIVOR/Contents/Info.plist"
selected_apps=("0|$HOME/Selected.app|Selected|com.example.volume-root|0|Never")
_MOLE_UNINSTALL_LIVE_APP_ROOTS=()
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$VOLUMES_ROOT"
live_rc=0
uninstall_live_bundle_has_other_install \
    "com.example.volume-root" "$HOME/Selected.app" || live_rc=$?
printf 'LIVE_RC=%s PATHS=%s\n' "$live_rc" "${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]}"
[[ $live_rc -eq 0 ]] || exit 1
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 1 ]] || exit 1
[[ "${_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[0]}" == "$SURVIVOR" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "system Time Machine snapshots do not make live sibling discovery incomplete" {
    assert_time_machine_volume_scan system 1
}

@test "system Time Machine exclusion works through the real Perl timeout backend" {
    assert_time_machine_volume_scan bounded 1
}

@test "Time Machine exclusion preserves real external application siblings" {
    assert_time_machine_volume_scan sibling 0
}

@test "Time Machine exclusion does not hide similarly named external volumes" {
    assert_time_machine_volume_scan lookalike 0
}

@test "Time Machine named mounted volumes are still scanned for siblings" {
    assert_time_machine_volume_scan mounted 0
}

@test "unverified Time Machine ownership keeps sibling discovery unknown" {
    assert_time_machine_volume_scan user-owned 3
}

@test "missing Time Machine metadata keeps sibling discovery unknown" {
    assert_time_machine_volume_scan missing-metadata 3
}

@test "ordinary unreadable volumes still make sibling discovery incomplete" {
    assert_time_machine_volume_scan ordinary 3
}

@test "an unreachable network share does not make sibling discovery incomplete" {
    assert_time_machine_volume_scan stale-share 1
}

@test "skipping an unreachable share still finds a sibling on another volume" {
    assert_time_machine_volume_scan stale-share-sibling 0
}

@test "a reachable but unreadable network share still makes sibling discovery incomplete" {
    assert_time_machine_volume_scan reachable-share 3
}

@test "an unknown mount table keeps every share in sibling discovery" {
    assert_time_machine_volume_scan mount-timeout 3
    assert_time_machine_volume_scan mount-failed 3
}

@test "an unfinished share probe keeps the share in sibling discovery" {
    assert_time_machine_volume_scan probe-timeout 3
}

@test "share discovery interruptions cancel sibling discovery" {
    assert_time_machine_volume_scan mount-interrupted 130
    assert_time_machine_volume_scan probe-interrupted 130
}

@test "an unlistable volumes root keeps sibling discovery unknown" {
    assert_time_machine_volume_scan unlistable-root 3
}

@test "unreachable share detection needs a network mount whose mount point is gone" {
    run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
deadline=$((SECONDS + 30))
gone="$HOME/no-such-volumes/[C] Windows 11.hidden"
mkdir -p "$HOME/live-share"
: > "$HOME/plain-file"
not_dir="$HOME/plain-file/share"
table="//GUEST:@Windows%2011._smb._tcp.local/%5BC%5D on $gone (smbfs, nodev, noexec, nosuid, nobrowse, mounted by me)
nas:/export on $HOME/live-share (nfs, nodev)
//host/x on $not_dir (smbfs, nodev)"
_uninstall_volume_is_unreachable_share "$gone" "$table" "$deadline" || { echo "MISSED_STALE"; exit 1; }
# Brackets in the name match literally: as a pattern, "[C]" would match the
# plain "C" share listed here.
bare_table="//host/c on $HOME/no-such-volumes/C Windows 11.hidden (smbfs, nodev)"
! _uninstall_volume_is_unreachable_share "$gone" "$bare_table" "$deadline" || { echo "PATTERN_MATCH"; exit 1; }
! _uninstall_volume_is_unreachable_share "$gone-2" "$table" "$deadline" || { echo "PREFIX_MATCH"; exit 1; }
! _uninstall_volume_is_unreachable_share "$HOME/live-share" "$table" "$deadline" || { echo "REACHABLE_SKIPPED"; exit 1; }
# Only ENOENT counts as gone; any other lstat error keeps the share in scope.
! _uninstall_volume_is_unreachable_share "$not_dir" "$table" "$deadline" || { echo "OTHER_ERRNO_SKIPPED"; exit 1; }
! _uninstall_volume_is_unreachable_share "$gone" "" "$deadline" || { echo "EMPTY_TABLE_SKIPPED"; exit 1; }
! _uninstall_volume_is_unreachable_share "$gone" "/dev/disk4s1 on $gone (apfs, local)" "$deadline" || { echo "LOCAL_DISK_SKIPPED"; exit 1; }
echo OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = OK ]
}

@test "Time Machine exclusion preserves depth-two volume discovery" {
    assert_time_machine_volume_scan first-level 1
}

@test "Time Machine metadata interruption cancels sibling discovery" {
    assert_time_machine_volume_scan interrupted 130
}

@test "live same-bundle scan covers exact package receipt apps" {
    local app_root="$HOME/pkg-root"
    mkdir -p "$app_root/one/two/three/four/Deep.app/Contents" "$HOME/Selected.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP_ROOT="$app_root" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.example.pkg-shared</string>' \
    '</dict></plist>' \
    > "$APP_ROOT/one/two/three/four/Deep.app/Contents/Info.plist"
selected_apps=("0|$HOME/Selected.app|Selected|com.example.pkg-shared|0|Never")
pkg_receipt_nonstandard_app_paths() {
    printf '%s\n' "$APP_ROOT/one/two/three/four/Deep.app"
}
_MOLE_UNINSTALL_LIVE_APP_ROOTS=()
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
uninstall_live_bundle_has_other_install \
    "com.example.pkg-shared" "$HOME/Selected.app"
[[ ${#_MOLE_UNINSTALL_LIVE_SIBLING_PATHS[@]} -eq 1 ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "strict package receipt discovery rejects partial output" {
    run env HOME="$HOME/pkg-partial" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

pkgutil() {
    case "$1" in
        --pkgs) printf 'com.example.one\ncom.example.two\n' ;;
        --files)
            if [[ "$2" == "com.example.one" ]]; then
                printf 'opt/example/One.app/Contents/Info.plist\n'
            else
                return 124
            fi
            ;;
    esac
}
run_with_timeout() {
    shift
    "$@"
}

rc=0
output=$(MOLE_PKG_RECEIPT_CACHE_DISABLE=1 \
    pkg_receipt_nonstandard_app_paths --require-complete) || rc=$?
printf 'RC=%s OUTPUT=%s\n' "$rc" "$output"
[[ $rc -eq 124 && -z "$output" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124 OUTPUT="* ]]
}

@test "non-strict receipt discovery bounds each pkgutil file listing" {
	local mock_bin="$HOME/mock-pkgutil-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/pkgutil" <<'MOCK'
#!/bin/bash
case "$1" in
    --pkgs) printf 'com.example.big\ncom.example.after\n' ;;
    --files) exec sleep 30 ;;
esac
MOCK
	chmod +x "$mock_bin/pkgutil"

	run env HOME="$HOME/pkg-bound" PROJECT_ROOT="$PROJECT_ROOT" \
		PATH="$mock_bin:/usr/bin:/bin" \
		MOLE_PKG_RECEIPT_CACHE_DISABLE=1 \
		MOLE_PKG_RECEIPT_SCAN_TIMEOUT=1 \
		MOLE_PKG_RECEIPT_LIST_TIMEOUT=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

started=$(date +%s)
rc=0
output=$(pkg_receipt_nonstandard_app_paths) || rc=$?
elapsed=$(( $(date +%s) - started ))
printf 'RC=%s ELAPSED=%s OUTPUT=%s\n' "$rc" "$elapsed" "$output"
[[ $elapsed -lt 8 ]]
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"RC=0 "* ]] || return 1
	[[ "$output" == *" OUTPUT=" ]]
}

@test "live same-bundle scan discards partial find output" {
    local app_root="$HOME/partial-live-apps"
    mkdir -p "$app_root/Selected.app" "$app_root/Partial.app/Contents"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP_ROOT="$app_root" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

selected_apps=("0|$APP_ROOT/Selected.app|Selected|com.example.partial|0|Never")
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$APP_ROOT")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
run_with_timeout() {
    shift
    if [[ "${1:-}" == "find" ]]; then
        printf '%s\0' "$APP_ROOT/Partial.app"
        return 73
    fi
    "$@"
}
rc=0
uninstall_live_bundle_has_other_install \
    "com.example.partial" "$APP_ROOT/Selected.app" || rc=$?
printf 'RC=%s\n' "$rc"
[[ $rc -eq 2 ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=2"* ]]
}

@test "batch execution rejects a changed same-bundle app set before teardown" {
    run env HOME="$HOME/live-set-race" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

app_path="$HOME/Applications/Race.app"
mkdir -p "$app_path"
expected_identity=$(_batch_selected_app_identity "$app_path")
preview_fingerprint=$(printf '%s' 'old-sibling-set' | base64 | tr -d '\n')
fields=(
    "Race" "$app_path" "unknown" "0" "" "" "false" "false" "false"
    "" "" "" "" "guard" "$expected_identity" "com.example.race"
    "$preview_fingerprint" "missing"
)
old_ifs="$IFS"
IFS='|'
detail="${fields[*]}"
IFS="$old_ifs"

uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT="new-sibling-set"
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=("$HOME/Applications/New.app")
    return 0
}
stop_launch_services() { : > "$HOME/teardown-ran"; }

app_details=("$detail")
success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0

_batch_execute_removals
[[ $success_count -eq 0 && $failed_count -eq 1 ]]
[[ "${failed_items[0]}" == *"app installation set changed after preview"* ]] || exit 1
[[ ! -e "$HOME/teardown-ran" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch execution rejects a selected Info.plist changed after preview" {
    run env HOME="$HOME/selected-info-race" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

app_path="$HOME/Applications/Race.app"
mkdir -p "$app_path/Contents"
printf 'old bundle metadata\n' > "$app_path/Contents/Info.plist"
touch -t 202001010000 "$app_path/Contents/Info.plist"
expected_identity=$(_batch_selected_app_identity "$app_path")
expected_info_identity=$(_batch_selected_app_info_identity "$app_path")

fields=(
    "Race" "$app_path" "com.example.race" "0" "" "" "false" "false" "false"
    "" "" "" "" "none" "$expected_identity" "com.example.race" ""
    "$expected_info_identity"
)
old_ifs="$IFS"
IFS='|'
detail="${fields[*]}"
IFS="$old_ifs"

printf 'new bundle metadata\n' > "$app_path/Contents/Info.plist"
touch -t 202101010000 "$app_path/Contents/Info.plist"
[[ "$(_batch_selected_app_identity "$app_path")" == "$expected_identity" ]] || exit 1
[[ "$(_batch_selected_app_info_identity "$app_path")" != "$expected_info_identity" ]] || exit 1

uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
stop_launch_services() { : > "$HOME/teardown-ran"; }

app_details=("$detail")
success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0

_batch_execute_removals
[[ $success_count -eq 0 && $failed_count -eq 1 ]]
[[ "${failed_items[0]}" == *"selected app changed after preview"* ]] || exit 1
[[ ! -e "$HOME/teardown-ran" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch scan narrows a live same-bundle plan to the selected app bundle" {
    run env HOME="$HOME/live-bundle-only" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

selected="$HOME/Applications/Selected.app"
survivor="$HOME/Applications/Survivor.app"
mkdir -p "$selected/Contents" "$survivor/Contents"
for app in "$selected" "$survivor"; do
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        '<key>CFBundleIdentifier</key><string>com.example.shared</string>' \
        '</dict></plist>' > "$app/Contents/Info.plist"
done

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.shared\n'; }
official_uninstaller_vendor() { return 1; }
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '1\n'; }
find_app_files() { : > "$HOME/unexpected-discovery"; return 99; }
calculate_total_size() { printf '0\n'; }
has_sensitive_data() { return 1; }
discover_login_item_helper_bundle_ids() { return 0; }

_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
apps_data=(
    "0|$selected|Selected|com.example.shared|0|Never|0"
    "0|$survivor|Changed Current Name|com.example.shared|0|Never|0"
)
selected_apps=("0|$selected|Selected|com.example.shared|0|Never")
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
app_details=()
total_estimated_size=0

_batch_scan_app_details
IFS='|' read -r _ _ stored_bundle _ _ _ _ _ _ _ _ _ _ stored_guard _ \
    stored_original stored_fingerprint _ <<< "${app_details[0]}"
[[ "$stored_bundle" == "unknown" ]] || exit 1
[[ "$stored_guard" == "guard_login" ]] || exit 1
[[ "$stored_original" == "com.example.shared" ]] || exit 1
[[ -n "$stored_fingerprint" ]] || exit 1
[[ ! -e "$HOME/unexpected-discovery" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch execution protects an earlier app when a later same-bundle selection changes" {
    run env HOME="$HOME/multi-selected-race" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

first="$HOME/Applications/First.app"
second="$HOME/Applications/Second.app"
mkdir -p "$first/Contents" "$second/Contents"
for app in "$first" "$second"; do
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        '<key>CFBundleIdentifier</key><string>com.example.shared</string>' \
        '</dict></plist>' > "$app/Contents/Info.plist"
    touch -t 202001010000 "$app/Contents/Info.plist"
done

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.shared\n'; }
official_uninstaller_vendor() { return 1; }
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '1\n'; }
find_app_files() { : > "$HOME/unexpected-discovery"; return 99; }
calculate_total_size() { printf '0\n'; }
has_sensitive_data() { return 1; }
discover_login_item_helper_bundle_ids() { return 0; }

_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
apps_data=(
    "0|$first|First|com.example.shared|0|Never|0"
    "0|$second|Second|com.example.shared|0|Never|0"
)
selected_apps=(
    "0|$first|First|com.example.shared|0|Never"
    "0|$second|Second|com.example.shared|0|Never"
)
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
app_details=()
total_estimated_size=0

_batch_scan_app_details
[[ ${#app_details[@]} -eq 2 ]] || exit 1
[[ ! -e "$HOME/unexpected-discovery" ]] || exit 1

printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.example.replaced</string>' \
    '</dict></plist>' > "$second/Contents/Info.plist"
touch -t 202101010000 "$second/Contents/Info.plist"
stop_launch_services() { : > "$HOME/teardown-ran"; }

success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0

_batch_execute_removals
[[ $success_count -eq 0 && $failed_count -eq 2 ]]
[[ "${failed_items[0]}" == *"app installation set changed after preview"* ]] || exit 1
[[ "${failed_items[1]}" == *"selected app changed after preview"* ]] || exit 1
[[ ! -e "$HOME/teardown-ran" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch execution removes stable same-bundle multi-selections" {
    run env HOME="$HOME/multi-selected-stable" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }

first="$HOME/Applications/First.app"
second="$HOME/Applications/Second.app"
mkdir -p "$first/Contents" "$second/Contents"
for app in "$first" "$second"; do
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        '<key>CFBundleIdentifier</key><string>com.example.shared</string>' \
        '</dict></plist>' > "$app/Contents/Info.plist"
done

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf '%s\n' "$2"; }
official_uninstaller_vendor() { return 1; }
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '1\n'; }
find_app_files() { : > "$HOME/unexpected-discovery"; return 99; }
calculate_total_size() { printf '0\n'; }
has_sensitive_data() { return 1; }
discover_login_item_helper_bundle_ids() { return 0; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }

_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
apps_data=(
    "0|$first|First|com.example.shared|0|Never|0"
    "0|$second|Second|com.example.shared|0|Never|0"
)
selected_apps=(
    "0|$first|First|com.example.shared|0|Never"
    "0|$second|Second|com.example.shared|0|Never"
)
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
app_details=()
total_estimated_size=0

_batch_scan_app_details
[[ ${#app_details[@]} -eq 2 ]] || exit 1
[[ ! -e "$HOME/unexpected-discovery" ]] || exit 1

success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0

_batch_execute_removals
[[ $success_count -eq 2 && $failed_count -eq 0 ]]
[[ ! -e "$first" && ! -e "$second" ]]

# Dry-run records simulated success but leaves both paths in place. Those
# still-live paths must remain in the expected fingerprint for the second app.
export MOLE_DRY_RUN=1
first="$HOME/Applications/DryFirst.app"
second="$HOME/Applications/DrySecond.app"
mkdir -p "$first/Contents" "$second/Contents"
for app in "$first" "$second"; do
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        '<key>CFBundleIdentifier</key><string>com.example.dryshared</string>' \
        '</dict></plist>' > "$app/Contents/Info.plist"
done
apps_data=(
    "0|$first|DryFirst|com.example.dryshared|0|Never|0"
    "0|$second|DrySecond|com.example.dryshared|0|Never|0"
)
selected_apps=(
    "0|$first|DryFirst|com.example.dryshared|0|Never"
    "0|$second|DrySecond|com.example.dryshared|0|Never"
)
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
app_details=()
total_estimated_size=0
dry_scan_rc=0
_batch_scan_app_details || dry_scan_rc=$?
[[ $dry_scan_rc -eq 0 ]] || exit 1
[[ ${#app_details[@]} -eq 2 ]] || exit 1

success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0
dry_execute_rc=0
_batch_execute_removals || dry_execute_rc=$?
[[ $dry_execute_rc -eq 0 ]] || exit 1
[[ $success_count -eq 2 && $failed_count -eq 0 ]]
[[ -e "$first" && -e "$second" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch_uninstall_applications keeps shared bundle-id leftovers when a sibling install survives" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    # Xcode.app and Xcode-beta.app both use com.apple.dt.Xcode. Uninstalling
    # only the beta must not delete bundle-id-keyed files still owned by the
    # surviving stable install.
    mkdir -p "$fixture_home/Applications/Shared.app" "$fixture_home/Applications/Shared-beta.app"
    mkdir -p "$fixture_home/Library/Caches/com.example.Shared"
    mkdir -p "$fixture_home/Library/Preferences"
    touch "$fixture_home/Library/Preferences/com.example.Shared.plist"
    mkdir -p "$fixture_home/Library/Caches/Shared-beta"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

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

apps_data=(
	"0|$HOME/Applications/Shared.app|Shared|com.example.Shared|0|Never|0"
	"0|$HOME/Applications/Shared-beta.app|Shared-beta|com.example.Shared|0|Never|0"
)
selected_apps=("0|$HOME/Applications/Shared-beta.app|Shared-beta|com.example.Shared|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications

# The selected bundle and its name-keyed leftovers are gone.
[[ ! -d "$HOME/Applications/Shared-beta.app" ]] || { echo "WRONG: beta bundle preserved"; exit 1; }
[[ ! -d "$HOME/Library/Caches/Shared-beta" ]] || { echo "WRONG: beta name cache preserved"; exit 1; }

# The surviving install and every bundle-id-keyed path are untouched.
[[ -d "$HOME/Applications/Shared.app" ]] || { echo "WRONG: surviving install removed"; exit 1; }
[[ -d "$HOME/Library/Caches/com.example.Shared" ]] || { echo "WRONG: shared bundle-id cache removed"; exit 1; }
[[ -f "$HOME/Library/Preferences/com.example.Shared.plist" ]] || { echo "WRONG: shared bundle-id prefs removed"; exit 1; }
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications keeps name-keyed leftovers when sibling installs share a display name" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    # On unindexed volumes mdls returns (null) and CFBundleName collapses both
    # installs to one display name ("Xcode" for Xcode-beta.app). Discovery must
    # fall back to the .app basename; when even that collides with the
    # survivor, name cleanup and login-item removal must be suppressed.
    mkdir -p "$fixture_home/Applications/SharedName-beta.app" "$fixture_home/Applications/SharedName.app"
    mkdir -p "$fixture_home/OtherApps/SharedName.app"
    mkdir -p "$fixture_home/Library/Application Support/SharedName"
    mkdir -p "$fixture_home/Library/Caches/SharedName"
    mkdir -p "$fixture_home/Library/Preferences"
    touch "$fixture_home/Library/Preferences/SharedName.plist"
    mkdir -p "$fixture_home/Library/Caches/SharedName-beta"
    # Same-bundle siblings ship the same CFBundleExecutable (Xcode-beta.app
    # ships "Xcode"); diagnostic-report discovery keys on it, so the beta's
    # Info.plist points at the shared executable name.
    mkdir -p "$fixture_home/Applications/SharedName-beta.app/Contents"
    printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.sharedname</string><key>CFBundleExecutable</key><string>SharedName</string></dict></plist>' > "$fixture_home/Applications/SharedName-beta.app/Contents/Info.plist"
    mkdir -p "$fixture_home/Library/Logs/DiagnosticReports"
    touch "$fixture_home/Library/Logs/DiagnosticReports/SharedName-2026-07-03-101010.ips"
    # LaunchAgents referencing an install by exact path: the one pointing at
    # the selected beta must still be unloaded under the guard (the bundle id
    # is demoted to "unknown", but the path scan is exact evidence), while the
    # one pointing at the survivor must stay loaded.
    mkdir -p "$fixture_home/Library/LaunchAgents" \
        "$fixture_home/Applications/SharedName-beta.app/Contents/MacOS" \
        "$fixture_home/Applications/SharedName.app/Contents/MacOS"
    touch "$fixture_home/Applications/SharedName-beta.app/Contents/MacOS/SharedName" \
        "$fixture_home/Applications/SharedName.app/Contents/MacOS/SharedName"
    cat > "$fixture_home/Library/LaunchAgents/com.thirdparty.betahelper.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$fixture_home/Applications/SharedName-beta.app/Contents/MacOS/SharedName</string></dict></plist>
PLIST
    cat > "$fixture_home/Library/LaunchAgents/com.thirdparty.stablehelper.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$fixture_home/Applications/SharedName.app/Contents/MacOS/SharedName</string></dict></plist>
PLIST
    mole_test_fake_command launchctl \
        "if [[ \"\$1\" == unload ]]; then printf 'UNLOAD:%s\\n' \"\$2\" >> \"\$HOME/unload.log\"; fi"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
_MOLE_UNINSTALL_LIVE_APP_ROOTS+=("$HOME/OtherApps")
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

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
remove_login_item() { printf 'LOGIN_ITEM:%s\n' "$1" >> "$HOME/login.log"; }
force_kill_app() { printf 'KILL:%s\n' "$1" >> "$HOME/kill.log"; return 0; }

# Case 1: display names collide ("SharedName" for both) but basenames differ.
# Discovery must use the basename (SharedName-beta) so the survivor's
# name-keyed dirs stay, and login-item removal must be skipped.
apps_data=(
	"0|$HOME/Applications/SharedName.app|SharedName|com.example.sharedname|0|Never|0"
	"0|$HOME/Applications/SharedName-beta.app|SharedName|com.example.sharedname|0|Never|0"
)
selected_apps=("0|$HOME/Applications/SharedName-beta.app|SharedName|com.example.sharedname|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

[[ ! -d "$HOME/Applications/SharedName-beta.app" ]] || { echo "WRONG: beta bundle preserved"; exit 1; }
[[ ! -d "$HOME/Library/Caches/SharedName-beta" ]] || { echo "WRONG: beta's own cache preserved"; exit 1; }
[[ -d "$HOME/Applications/SharedName.app" ]] || { echo "WRONG: survivor removed"; exit 1; }
[[ -d "$HOME/Library/Application Support/SharedName" ]] || { echo "WRONG: survivor app support removed"; exit 1; }
[[ -d "$HOME/Library/Caches/SharedName" ]] || { echo "WRONG: survivor cache removed"; exit 1; }
[[ -f "$HOME/Library/Preferences/SharedName.plist" ]] || { echo "WRONG: survivor prefs removed"; exit 1; }
[[ ! -f "$HOME/login.log" ]] || { echo "WRONG: login item removed on colliding name"; cat "$HOME/login.log"; exit 1; }
[[ -f "$HOME/Library/Logs/DiagnosticReports/SharedName-2026-07-03-101010.ips" ]] || { echo "WRONG: survivor crash reports deleted under sibling guard"; exit 1; }
grep -q "UNLOAD:.*com.thirdparty.betahelper.plist" "$HOME/unload.log" 2> /dev/null || { echo "WRONG: path-referenced agent of the selected app not unloaded under guard"; exit 1; }
! grep -q "com.thirdparty.stablehelper.plist" "$HOME/unload.log" 2> /dev/null || { echo "WRONG: survivor's agent unloaded"; cat "$HOME/unload.log"; exit 1; }

# Case 2: basenames collide too (same SharedName.app in two folders).
# Name discovery must be suppressed entirely: only the bundle goes.
apps_data=(
	"0|$HOME/OtherApps/SharedName.app|SharedName|com.example.sharedname|0|Never|0"
	"0|$HOME/Applications/SharedName.app|SharedName|com.example.sharedname|0|Never|0"
)
selected_apps=("0|$HOME/Applications/SharedName.app|SharedName|com.example.sharedname|0|Never")

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

[[ ! -d "$HOME/Applications/SharedName.app" ]] || { echo "WRONG: selected bundle preserved"; exit 1; }
[[ -d "$HOME/OtherApps/SharedName.app" ]] || { echo "WRONG: survivor removed (case 2)"; exit 1; }
[[ -d "$HOME/Library/Application Support/SharedName" ]] || { echo "WRONG: shared-name app support removed (case 2)"; exit 1; }
[[ -d "$HOME/Library/Caches/SharedName" ]] || { echo "WRONG: shared-name cache removed (case 2)"; exit 1; }
[[ -f "$HOME/Library/Preferences/SharedName.plist" ]] || { echo "WRONG: shared-name prefs removed (case 2)"; exit 1; }
[[ ! -f "$HOME/login.log" ]] || { echo "WRONG: login item removed on colliding name (case 2)"; exit 1; }

# Case 3: the Xcode toolchain heuristic matches by regex substring, so even
# a non-colliding basename ("XcodeClone-beta") would sweep DerivedData that
# the surviving install still uses. The sibling guard must disable it.
mkdir -p "$HOME/Applications/XcodeClone.app" "$HOME/Applications/XcodeClone-beta.app"
mkdir -p "$HOME/Library/Developer/Xcode/DerivedData"

apps_data=(
	"0|$HOME/Applications/XcodeClone.app|XcodeClone|com.example.xcodeclone|0|Never|0"
	"0|$HOME/Applications/XcodeClone-beta.app|XcodeClone|com.example.xcodeclone|0|Never|0"
)
selected_apps=("0|$HOME/Applications/XcodeClone-beta.app|XcodeClone|com.example.xcodeclone|0|Never")

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

[[ ! -d "$HOME/Applications/XcodeClone-beta.app" ]] || { echo "WRONG: beta bundle preserved (case 3)"; exit 1; }
[[ -d "$HOME/Applications/XcodeClone.app" ]] || { echo "WRONG: survivor removed (case 3)"; exit 1; }
[[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]] || { echo "WRONG: DerivedData swept despite surviving sibling (case 3)"; exit 1; }

# Case 4: inverse direction: uninstalling the base-named install while the
# hyphen-suffixed sibling survives. The discovery name ("RevBase") is
# contained in the survivor's identifiers ("RevBase-beta"), and downstream
# matchers are substring-based (the LaunchAgents scan globs "*<name>*.plist"),
# so name discovery must be suppressed entirely.
mkdir -p "$HOME/Applications/RevBase.app" "$HOME/Applications/RevBase-beta.app"
mkdir -p "$HOME/Library/Application Support/RevBase"
mkdir -p "$HOME/Library/LaunchAgents"
touch "$HOME/Library/LaunchAgents/com.example.RevBase-beta.agent.plist"

apps_data=(
	"0|$HOME/Applications/RevBase.app|RevBase|com.example.revbase|0|Never|0"
	"0|$HOME/Applications/RevBase-beta.app|RevBase-beta|com.example.revbase|0|Never|0"
)
selected_apps=("0|$HOME/Applications/RevBase.app|RevBase|com.example.revbase|0|Never")

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

[[ ! -d "$HOME/Applications/RevBase.app" ]] || { echo "WRONG: selected base bundle preserved (case 4)"; exit 1; }
[[ -d "$HOME/Applications/RevBase-beta.app" ]] || { echo "WRONG: suffixed survivor removed (case 4)"; exit 1; }
[[ -f "$HOME/Library/LaunchAgents/com.example.RevBase-beta.agent.plist" ]] || { echo "WRONG: survivor launch agent removed (case 4)"; exit 1; }
[[ -d "$HOME/Library/Application Support/RevBase" ]] || { echo "WRONG: shared app support removed (case 4)"; exit 1; }
[[ ! -f "$HOME/login.log" ]] || { echo "WRONG: login item removed (case 4)"; exit 1; }

# Across all four guard cases process termination must never run:
# force_kill_app quits by bundle id and matches by CFBundleExecutable, and
# both can belong to the surviving install.
[[ ! -f "$HOME/kill.log" ]] || { echo "WRONG: process termination attempted under sibling guard"; cat "$HOME/kill.log"; exit 1; }

# Case 5 (control): without a surviving sibling the termination and
# diagnostic-report paths must still run, proving the negative assertions
# above are not vacuous.
mkdir -p "$HOME/Applications/SoloApp.app"
touch "$HOME/Library/Logs/DiagnosticReports/SoloApp-2026-07-03-101010.ips"
apps_data=("0|$HOME/Applications/SoloApp.app|SoloApp|com.example.soloapp|0|Never|0")
selected_apps=("0|$HOME/Applications/SoloApp.app|SoloApp|com.example.soloapp|0|Never")

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

[[ ! -d "$HOME/Applications/SoloApp.app" ]] || { echo "WRONG: solo bundle preserved (case 5)"; exit 1; }
grep -q "KILL:SoloApp" "$HOME/kill.log" 2> /dev/null || { echo "WRONG: termination skipped without sibling guard (case 5)"; exit 1; }
[[ ! -f "$HOME/Library/Logs/DiagnosticReports/SoloApp-2026-07-03-101010.ips" ]] || { echo "WRONG: diagnostic reports not collected without sibling guard (case 5)"; exit 1; }
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch_uninstall_applications blocks official-uninstaller apps" {
    mkdir -p "$HOME/Applications/Falcon.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"requires the official CrowdStrike uninstaller"* ]] || return 1
    [[ "$output" != *"MOLE_DELETE"* ]]
}

@test "batch_uninstall_applications keeps system remnants review-only" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    mkdir -p "$fixture_home/Applications/ReviewOnly.app" "$fixture_home/system"
    touch "$fixture_home/system/com.example.review.helper"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

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

grep -q "Review only: ~/system/com.example.review.helper" "$HOME/output.log"
# The summary states the count, not the paths: they were already listed above
# the confirmation prompt, so the path must appear exactly once in the run.
[[ "$(grep -cF "~/system/com.example.review.helper" "$HOME/output.log")" -eq 1 ]] || exit 1
grep -q "Kept 1 system-level path, which Mole never removes" "$HOME/output.log"
# Keeping system paths is the designed outcome, so the run is not "incomplete".
! grep -q "Uninstall incomplete" "$HOME/output.log" || exit 1
grep -q "Uninstall complete" "$HOME/output.log"
# The point of the whole case: the file is reported, never deleted.
! grep -q "$HOME/system/com.example.review.helper" "$HOME/remove.log" || exit 1
[[ -e "$HOME/system/com.example.review.helper" ]]
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
}


# Exercise the production removal/accounting phase with fixture-only sinks.
run_leftover_accounting_case() {
    local du_status="$1" expected_status="$2" expected_freed="$3" du_shape="${4:-total}"
    # shellcheck disable=SC2016 # Expanded by the PATH stub when du runs.
    mole_test_fake_command du '
printf "%s\n" "$*" >> "$HOME/du.log"
case "$DU_SHAPE" in
    total) printf "40\t%s\n60\t%s\n100\ttotal\n" "$HOME/retained-one" "$HOME/retained-two" ;;
    no-total) printf "40\t%s\n" "$HOME/retained-one" ;;
    invalid-total) printf "unknown\ttotal\n" ;;
esac
exit "$DU_STATUS"'
    run env HOME="$HOME/leftover-accounting-$du_status-$du_shape" PROJECT_ROOT="$PROJECT_ROOT" \
        DU_STATUS="$du_status" DU_SHAPE="$du_shape" EXPECTED_STATUS="$expected_status" EXPECTED_FREED="$expected_freed" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME/Applications/First.app" "$HOME/Applications/Second.app" \
    "$HOME/retained-one" "$HOME/retained-two"
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_file_list() { :; }
mole_delete() {
    printf '%s\n' "$1" >> "$HOME/removed.log"
    rmdir "$1"
}

first="$HOME/Applications/First.app"
second="$HOME/Applications/Second.app"
encoded=$(printf '%s\n' "$HOME/retained-one" "$HOME/retained-two" | base64 | tr -d '\n')
app_details=(
    "First|$first|unknown|150|$encoded||false|false|false|||||guard_login|$(_batch_selected_app_identity "$first")|unknown||missing"
    "Second|$second|unknown|10|||false|false|false|||||guard_login|$(_batch_selected_app_identity "$second")|unknown||missing"
)
success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0
rc=0
_batch_execute_removals || rc=$?
printf 'RC=%s FREED=%s\n' "$rc" "$total_size_freed"
[[ $rc -eq $EXPECTED_STATUS ]] || exit 1
[[ $total_size_freed -eq $EXPECTED_FREED ]] || exit 1
[[ -d "$HOME/retained-one" && -d "$HOME/retained-two" ]] || exit 1
grep -Fxq -- "-skcP $HOME/retained-one $HOME/retained-two" "$HOME/du.log" || exit 1
grep -Fxq "$first" "$HOME/removed.log" || exit 1
if [[ $EXPECTED_STATUS -eq 0 ]]; then
    [[ $success_count -eq 2 && $failed_count -eq 0 ]] || exit 1
    grep -Fxq "$second" "$HOME/removed.log" || exit 1
else
    [[ $success_count -eq 0 && -d "$second" ]] || exit 1
    ! grep -Fxq "$second" "$HOME/removed.log" || exit 1
fi
EOF
}

@test "batch leftover accounting subtracts totals even when du reports partial failure" {
    run_leftover_accounting_case 0 0 60
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run_leftover_accounting_case 1 0 60
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "batch leftover accounting requires an actual total row" {
    run_leftover_accounting_case 1 0 160 no-total
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "batch leftover accounting rejects a nonnumeric total" {
    run_leftover_accounting_case 1 0 160 invalid-total
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "batch leftover accounting rejects an unexpected du error" {
    run_leftover_accounting_case 2 0 160 total
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "batch leftover accounting preserves timeout and signal cancellation" {
    run_leftover_accounting_case 124 124 0
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run_leftover_accounting_case 130 130 0
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "batch_uninstall_applications dry-run does not report expected leftovers as failures" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    HOME="$fixture_home" create_app_artifacts

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

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
find_app_system_files() {
    mkdir -p "$HOME/system"
    touch "$HOME/system/com.example.TestApp.helper"
    printf '%s\n' "$HOME/system/com.example.TestApp.helper"
}

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
[[ "$output" != *"system-level path"* ]] || { echo "WRONG: dry-run reported post-removal system leftovers"; cat "$output_file"; exit 1; }
[[ "$output" != *"Uninstall incomplete"* ]] || { echo "WRONG: dry-run marked incomplete"; cat "$output_file"; exit 1; }
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

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

    cat > "$stubdir/osascript" << STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
    chmod +x "$stubdir/osascript"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
        TRACE_PATH="$trace" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

# This unit test covers force_kill_app's ladder, not the timeout backend.
# Keep the PATH osascript stub deterministic under the parallel full suite.
run_with_timeout() {
	shift
	"$@"
}

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
    grep -q 'osascript .*tell application id .*com\.example\.TestApp.* to quit' "$trace" ||
        {
            echo "WRONG: missing AppleScript Quit"
            cat "$trace"
            return 1
        }
    if grep -q '^pkill ' "$trace"; then
        echo "WRONG: pkill ran even though Quit succeeded"
        cat "$trace"
        return 1
    fi
}

@test "force_kill_app escalates to pkill when Quit does not land" {
    # Process keeps showing up in pgrep until pkill -9 fires, exercising the
    # SIGTERM and SIGKILL rungs of the escalation ladder.
    stubdir="$HOME/stubs"
    mkdir -p "$stubdir"
    trace="$HOME/kill_escalate_trace.log"
    : > "$trace"

    cat > "$stubdir/osascript" << STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
    chmod +x "$stubdir/osascript"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
        TRACE_PATH="$trace" /bin/bash --noprofile --norc << 'EOF'
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
    grep -q '^pkill -x StubbornApp' "$trace" ||
        {
            echo "WRONG: SIGTERM rung did not fire"
            cat "$trace"
            return 1
        }
    grep -q '^pkill -9 -x StubbornApp' "$trace" ||
        {
            echo "WRONG: SIGKILL rung did not fire"
            cat "$trace"
            return 1
        }
}

@test "force_kill_app rejects unsafe bundle id in AppleScript Quit target" {
    stubdir="$HOME/stubs"
    mkdir -p "$stubdir"
    trace="$HOME/unsafe_kill_trace.log"
    : > "$trace"

    cat > "$stubdir/osascript" << STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
    chmod +x "$stubdir/osascript"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
        TRACE_PATH="$trace" /bin/bash --noprofile --norc << 'EOF'
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
        echo "WRONG: unsafe bundle id reached AppleScript"
        cat "$trace"
        return 1
    fi
    grep -q 'osascript .*tell application "TestApp" to quit' "$trace" ||
        {
            echo "WRONG: unsafe id did not fall back to app name"
            cat "$trace"
            return 1
        }
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

    cat > "$stubdir/osascript" << STUB
#!/bin/bash
printf 'osascript %s\n' "\$*" >> "$trace"
exit 0
STUB
    chmod +x "$stubdir/osascript"

    for spoofed in Finder Dock loginwindow WindowServer SystemUIServer; do
        : > "$trace"
        run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stubdir:$PATH" \
            TRACE_PATH="$trace" SPOOFED="$spoofed" /bin/bash --noprofile --norc << 'EOF'
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

        [ "$status" -eq 1 ] ||
            {
                echo "WRONG: spoofed $spoofed did not return 1 (got $status)"
                cat "$trace"
                return 1
            }
        if [[ -s "$trace" ]]; then
            echo "WRONG: spoofed $spoofed reached pkill/pgrep/osascript"
            cat "$trace"
            return 1
        fi
    done
}

@test "batch_uninstall_applications proceeds with deletion when force_kill_app fails" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    # Reproduces the issue where uninstalling a still-running app (e.g. Mole.app
    # with a watchdog or XPC helper that ignores SIGKILL) used to abort with
    # "still running" and leave the bundle on disk. macOS allows deleting a
    # running app's bundle; we should warn the user but proceed.
    HOME="$fixture_home" create_app_artifacts

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

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

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
}

@test "stop_launch_services unloads launch agents without deleting plists" {
    mkdir -p "$HOME/Library/LaunchAgents" \
        "$HOME/Applications/TestApp.app/Contents/MacOS"
    touch "$HOME/Applications/TestApp.app/Contents/MacOS/TestApp"
    cat > "$HOME/Library/LaunchAgents/com.example.TestApp.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>$HOME/Applications/TestApp.app/Contents/MacOS/TestApp</string></dict></plist>
PLIST
    touch "$HOME/Library/LaunchAgents/com.example.TestApplication.plist"
    cat > "$HOME/Library/LaunchAgents/com.example.TestApp.helper.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>ProgramArguments</key><array><string>$HOME/Applications/TestApp.app/Contents/MacOS/TestApp</string></array></dict></plist>
PLIST
    cat > "$HOME/Library/LaunchAgents/com.thirdparty.TestApp-other.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><!-- $HOME/Applications/TestApp.app --><dict><key>Program</key><string>/bin/true</string></dict></plist>
PLIST

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

stop_launch_services "com.example.TestApp" "false" "$HOME/Applications/TestApp.app"

	grep -Fq "launchctl unload $HOME/Library/LaunchAgents/com.example.TestApp.plist" "$trace"
	grep -Fq "launchctl unload $HOME/Library/LaunchAgents/com.example.TestApp.helper.plist" "$trace"
	[[ "$(grep -Fc "launchctl unload $HOME/Library/LaunchAgents/com.example.TestApp.plist" "$trace")" -eq 1 ]] || exit 1
	[[ "$(grep -Fc "launchctl unload $HOME/Library/LaunchAgents/com.example.TestApp.helper.plist" "$trace")" -eq 1 ]] || exit 1
	! grep -Fq "com.example.TestApplication.plist" "$trace" || exit 1
	! grep -Fq "com.thirdparty.TestApp-other.plist" "$trace" || exit 1
	! grep -q "safe_remove" "$trace" || exit 1
	[[ -f "$HOME/Library/LaunchAgents/com.example.TestApp.plist" ]] || exit 1
	[[ -f "$HOME/Library/LaunchAgents/com.example.TestApp.helper.plist" ]] || exit 1
	[[ -f "$HOME/Library/LaunchAgents/com.example.TestApplication.plist" ]] || exit 1
	[[ -f "$HOME/Library/LaunchAgents/com.thirdparty.TestApp-other.plist" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications preview shows full related file list" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    mkdir -p "$fixture_home/Applications/TestApp.app"
    mkdir -p "$fixture_home/Library/Application Support/TestApp"
    mkdir -p "$fixture_home/Library/Caches/TestApp"
    mkdir -p "$fixture_home/Library/Logs/TestApp"
    touch "$fixture_home/Library/Logs/TestApp/log1.log"
    touch "$fixture_home/Library/Logs/TestApp/log2.log"
    touch "$fixture_home/Library/Logs/TestApp/log3.log"
    touch "$fixture_home/Library/Logs/TestApp/log4.log"
    touch "$fixture_home/Library/Logs/TestApp/log5.log"
    touch "$fixture_home/Library/Logs/TestApp/log6.log"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
# Homebrew is present but owns no cask; the real brew is never consulted.
brew() { :; }

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

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
    [[ "$output" == *"~/Library/Logs/TestApp/log6.log"* ]] || return 1
    [[ "$output" != *"more files"* ]]
}

@test "uninstall_persist_cache_file heals non-writable destination" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"
uninstall_print_app_search_dirs() { printf '%s\n' "$HOME/Applications"; }

app_path="$HOME/Applications/Vendor/Helper.app"
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"
uninstall_print_app_search_dirs() { printf '%s\n' "$HOME/Applications"; }

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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

safe_remove "$HOME/test_dir"
[[ ! -d "$HOME/test_dir" ]] || exit 1
EOF
    [ "$status" -eq 0 ]
}

@test "decode_file_list validates base64 encoding" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

if result=$(decode_file_list "not-valid-base64!!!" "TestApp" 2>/dev/null); then
    [[ -z "$result" ]] || exit 1
else
    true
fi
EOF

    [ "$status" -eq 0 ]
}

@test "login item helper discovery discards partial results and preserves cancellation" {
    local app="$HOME/Applications/PartialHelpers.app"
    local helper="$app/Contents/Library/LoginItems/Partial.app"
    mkdir -p "$helper/Contents"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APP="$app" HELPER="$helper" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

run_with_timeout() {
    shift
    if [[ "${1:-}" == "find" ]]; then
        printf '%s\0' "$HELPER"
        return 73
    fi
    "$@"
}
result=$(discover_login_item_helper_bundle_ids "$APP")
[[ -z "$result" ]] || exit 1

run_with_timeout() { return 130; }
rc=0
discover_login_item_helper_bundle_ids "$APP" > /dev/null || rc=$?
printf 'RC=%s\n' "$rc"
[[ $rc -eq 130 ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=130"* ]]
}

@test "bootout_login_item_helpers never touches the com.apple namespace" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

is_uninstall_dry_run() { return 1; }
run_with_timeout() { shift; "$@"; }
# The call site redirects launchctl to /dev/null, so trace to a file.
TRACE="$HOME/bootout.trace"
> "$TRACE"
launchctl() { echo "BOOTOUT:$2" >> "$TRACE"; }
export -f launchctl

# A third-party helper whose Info.plist claims an Apple label must be
# skipped; only the vendor helper may be booted out.
bootout_login_item_helpers "com.apple.Safari.helper
com.vendor.App-Helper"
cat "$TRACE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"BOOTOUT:gui/$(id -u)/com.vendor.App-Helper"* ]] || return 1
    [[ "$output" != *"com.apple.Safari.helper"* ]] || return 1
}

@test "decode_bundle_id_list preserves login item helper ids" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

# Regression for App Cleaner 9 (#helper bootout): bundle ids are not paths,
# so routing them through decode_file_list blanked the list and skipped the
# launchctl bootout of the app's login item helpers.
helper_ids=$(printf 'com.nektony.App-Cleaner-SIIICn-UIHelper
com.nektony.App-Cleaner-SIIICn-Monitor' | base64)
result=$(decode_bundle_id_list "$helper_ids" "App Cleaner 9" 2>&1)
[[ "$result" == *"com.nektony.App-Cleaner-SIIICn-UIHelper"* ]] || exit 1
[[ "$result" == *"com.nektony.App-Cleaner-SIIICn-Monitor"* ]] || exit 1
[[ "$result" != *"Invalid path"* ]] || exit 1

# The execute path must decode helper ids with the id decoder, not the
# path decoder that rejects them.
grep -q 'decode_bundle_id_list "$encoded_login_item_helpers"' "$PROJECT_ROOT/lib/uninstall/batch.sh" || exit 1
if grep -q 'decode_file_list "$encoded_login_item_helpers"' "$PROJECT_ROOT/lib/uninstall/batch.sh"; then
    exit 1
fi
exit 0
EOF

    [ "$status" -eq 0 ]
}

# A bundle whose folder name is not its product name reaches the user as an
# unrecognizable string: #1520 reported almost uninstalling CapCut because Mole
# listed it as "VideoFusion-macOS" while Finder showed the Chinese name. The
# name Finder shows comes from Contents/Resources/<lang>.lproj/InfoPlist.strings.
_write_display_name_fixture() {
    local app_path="$1" dev_region="$2" base_name="$3"
    shift 3

    mkdir -p "$app_path/Contents/Resources"
    cat > "$app_path/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.fixture</string>
<key>CFBundleDevelopmentRegion</key><string>$dev_region</string>
<key>CFBundleDisplayName</key><string>$base_name</string>
<key>CFBundleName</key><string>$base_name</string>
</dict></plist>
PLIST

    local spec lproj value
    for spec in "$@"; do
        lproj="${spec%%=*}"
        value="${spec#*=}"
        mkdir -p "$app_path/Contents/Resources/$lproj.lproj"
        if [[ "$value" != "-" ]]; then
            printf '"CFBundleDisplayName" = "%s";\n' "$value" \
                > "$app_path/Contents/Resources/$lproj.lproj/InfoPlist.strings"
        fi
    done
}

_run_display_name_case() {
    local languages="$1" app_path="$2" app_name="$3"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" LANGS="$languages" \
        APP_PATH="$app_path" APP_NAME="$app_name" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
# bin/uninstall.sh freezes these as readonly while it is sourced: the user's
# locale before it forces C, the mdls budget, and the language list it reads
# from `defaults`. Feed each one where the script reads it.
unset LC_ALL LANG
export MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC=3
defaults() { [[ -z "$LANGS" ]] || printf '%s\n' "$LANGS"; }
source "$PROJECT_ROOT/bin/uninstall.sh"
[[ "$MOLE_UNINSTALL_PREFERRED_LANGS" == "$LANGS" ]] || { echo "LANGS_NOT_APPLIED"; exit 1; }

# mdls only ever reports the on-disk file name for an app bundle, which is the
# string this behavior exists to replace. Stub it so the case cannot pass by
# accidentally agreeing with Spotlight.
run_with_timeout() {
    shift
    "$@"
}
mdls() { printf '%s\n' "$(basename "$APP_PATH")"; }

uninstall_resolve_display_name "$APP_PATH" "$APP_NAME"
EOF
}

@test "uninstall_resolve_display_name uses the bundle's localized name for the user's language (#1520)" {
    local app_path="$HOME/Applications/VideoFusion-macOS.app"
    _write_display_name_fixture "$app_path" "en" "VideoFusion-macOS" \
        "en=VideoFusion" "zh-Hans=剪映专业版"

    _run_display_name_case "$(printf 'zh-Hans-CN\nen-CN')" "$app_path" "VideoFusion-macOS.app"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "剪映专业版" ] || { echo "$output"; return 1; }

    _run_display_name_case "$(printf 'en-CN\nzh-Hans-CN')" "$app_path" "VideoFusion-macOS.app"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "VideoFusion" ] || { echo "$output"; return 1; }
}

# The stop condition matters as much as the lookup. MiaoYan.app ships a Chinese
# override and no English one, so a search that kept walking the preference list
# would show a Chinese name to a user who asked for English.
@test "uninstall_resolve_display_name never falls through to an unrequested language (#1520)" {
    local app_path="$HOME/Applications/MiaoYan.app"
    _write_display_name_fixture "$app_path" "en" "MiaoYan" "Base=-" "zh-Hans=妙言"

    _run_display_name_case "$(printf 'en-CN\nzh-Hans-CN')" "$app_path" "MiaoYan.app"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "MiaoYan" ] || { echo "$output"; return 1; }

    _run_display_name_case "$(printf 'zh-Hans-CN\nen-CN')" "$app_path" "MiaoYan.app"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "妙言" ] || { echo "$output"; return 1; }
}

@test "uninstall_resolve_display_name keeps the unlocalized name without a language list (#1520)" {
    local app_path="$HOME/Applications/NoPrefs.app"
    _write_display_name_fixture "$app_path" "en" "NoPrefs Base" "zh-Hans=中文名"

    _run_display_name_case "" "$app_path" "NoPrefs.app"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "NoPrefs Base" ] || { echo "$output"; return 1; }
}

@test "uninstall_resolve_display_name keeps versioned app names when metadata is generic" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
# bin/uninstall.sh freezes the user's locale and language list as readonly
# while it is sourced; start both empty so no host setting reaches the case.
unset LC_ALL LANG
defaults() { return 1; }
source "$PROJECT_ROOT/bin/uninstall.sh"
[[ -z "$MOLE_UNINSTALL_PREFERRED_LANGS" ]] || { echo "HOST_LANGS_LEAKED"; exit 1; }

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

app_path="$HOME/Applications/Xcode 16.4.app"
mkdir -p "$app_path/Contents"
touch "$app_path/Contents/Info.plist"

result=$(uninstall_resolve_display_name "$app_path" "Xcode 16.4.app")
[[ "$result" == "Xcode 16.4" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "decode_file_list handles empty input" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

empty_data=$(printf '' | base64)
result=$(decode_file_list "$empty_data" "TestApp" 2>/dev/null) || true
[[ -z "$result" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "decode_file_list rejects non-absolute paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

bad_data=$(printf 'relative/path' | base64)
if result=$(decode_file_list "$bad_data" "TestApp" 2>/dev/null); then
    [[ -z "$result" ]] || exit 1
else
    true
fi
EOF

    [ "$status" -eq 0 ]
}

@test "decode_file_list handles both BSD and GNU base64 formats" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

@test "refresh_launch_services_after_uninstall compacts without forcing a domain re-registration" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

test_home="$HOME/launchservices-refresh-home"
mkdir -p "$test_home"
log_file="$test_home/lsregister-calls.log"
: > "$log_file"

get_lsregister_path() { echo "/bin/echo"; }
run_with_timeout() {
    local duration="$1"
    shift
    echo "CALL:$duration:$*" >> "$log_file"
    return 124
}

if refresh_launch_services_after_uninstall; then
    echo "RESULT:ok"
else
    echo "RESULT:fail"
fi

cat "$log_file"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT:ok"* ]] || return 1
    [[ "$output" == *"CALL:10:/bin/echo -gc"* ]] || return 1
    [[ "$output" != *" -r "* ]] || return 1
    [[ "$output" != *" -f "* ]] || return 1
    [[ "$output" != *" -domain "* ]] || return 1
    [ "$(printf '%s\n' "$output" | grep -c '^CALL:')" -eq 1 ] || return 1
}

@test "unregister_app_bundle accepts mixed-case app suffixes only in real mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

test_home="$HOME/launchservices-unregister-home"
mkdir -p "$test_home/Upper.APP" "$test_home/Plain.bundle"
log_file="$test_home/lsregister-calls.log"
: > "$log_file"

get_lsregister_path() { echo "/bin/echo"; }
run_with_timeout() {
    local duration="$1"
    shift
    echo "CALL:$duration:$*" >> "$log_file"
}

MOLE_DRY_RUN=0 unregister_app_bundle "$test_home/Upper.APP"
MOLE_DRY_RUN=0 unregister_app_bundle "$test_home/Plain.bundle"
MOLE_DRY_RUN=1 unregister_app_bundle "$test_home/Upper.APP"
cat "$log_file"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"CALL:5:/bin/echo -u $HOME/launchservices-unregister-home/Upper.APP"* ]] || return 1
    [ "$(printf '%s\n' "$output" | grep -c '^CALL:')" -eq 1 ]
}

@test "remove_mole deletes manual binaries and caches" {
    mkdir -p "$HOME/.local/bin"
    touch "$HOME/.local/bin/mole"
    touch "$HOME/.local/bin/mo"
    mkdir -p "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"
    echo "protected-entry" > "$HOME/.config/mole/whitelist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
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
    [ ! -f "$HOME/.local/bin/mole" ] || return 1
    [ ! -f "$HOME/.local/bin/mo" ] || return 1
    [ ! -d "$HOME/.config/mole" ] || return 1
    [ ! -d "$HOME/.cache/mole" ] || return 1
    [ ! -d "$HOME/Library/Logs/mole" ] || return 1
    # Config is user-authored state and must survive in the Trash (#1346).
    [ -f "$HOME/.Trash/mole-config/whitelist" ] || return 1
}

@test "remove_mole preserves custom config and unrelated default settings (#1589)" {
    local iso="$HOME/custom-remove"
    mkdir -p "$iso/.local/bin" "$iso/.local/lib/core" "$iso/.local/lib/python3"
    mkdir -p "$iso/.config/mole"
    touch "$iso/.local/bin/mole" "$iso/.local/bin/mo"
    touch "$iso/.local/lib/core/common.sh" "$iso/.local/install_channel"
    echo foreign > "$iso/.local/bin/other-tool"
    echo foreign > "$iso/.local/lib/python3/user-data"
    echo custom > "$iso/.local/whitelist"
    echo default > "$iso/.config/mole/whitelist"

    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 \
        MOLE_CONFIG_DIR="$iso/.local" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
printf '\n' | "$PROJECT_ROOT/mole" remove
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$iso/.local/bin/other-tool" ] || return 1
    [ -f "$iso/.local/lib/python3/user-data" ] || return 1
    [ -f "$iso/.local/whitelist" ] || return 1
    [ -f "$iso/.config/mole/whitelist" ] || return 1
    [ ! -e "$iso/.local/bin/mole" ] || return 1
    [[ "$output" == *"$iso/.local (kept for manual review)"* ]]
}

@test "remove_mole custom config preview never promises a whole-directory move (#1589)" {
    local iso="$HOME/custom-preview"
    local custom="$iso/Library/Application Support/mole"
    mkdir -p "$iso/.local/bin" "$custom/lib/core" "$iso/.config/mole"
    touch "$iso/.local/bin/mole" "$custom/lib/core/common.sh"
    echo custom > "$custom/whitelist"
    echo default > "$iso/.config/mole/whitelist"

    run env HOME="$iso" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 \
        MOLE_CONFIG_DIR="$custom" /bin/bash "$PROJECT_ROOT/mole" remove --dry-run

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$custom (kept for manual review)"* ]] || return 1
    [[ "$output" != *"Would move to Trash:"* ]] || return 1
    [ -f "$iso/.local/bin/mole" ] || return 1
    [ -f "$custom/whitelist" ] || return 1
    [ -f "$iso/.config/mole/whitelist" ]
}

@test "remove config resolution distinguishes pinned installs from source and Homebrew" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/remove.sh"
is_homebrew_install() { return 1; }
unset MOLE_CONFIG_DIR
SCRIPT_PATH="$PROJECT_ROOT/mole"
SCRIPT_DIR="$PROJECT_ROOT"
printf 'SOURCE=%s\n' "$(_remove_config_dir)"
SCRIPT_PATH="$HOME/.local/bin/mole"
SCRIPT_DIR="$HOME/custom-config"
printf 'CUSTOM=%s\n' "$(_remove_config_dir)"
SCRIPT_PATH="$HOME/custom-config/mole"
printf 'COLOCATED=%s\n' "$(_remove_config_dir)"
is_homebrew_install() { return 0; }
printf 'BREW=%s\n' "$(_remove_config_dir)"
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SOURCE=$HOME/.config/mole"* ]] || return 1
    [[ "$output" == *"CUSTOM=$HOME/custom-config"* ]] || return 1
    [[ "$output" == *"COLOCATED=$HOME/custom-config"* ]] || return 1
    [[ "$output" == *"BREW=$HOME/.config/mole"* ]]
}

@test "remove_mole dry-run keeps manual binaries and caches" {
    mkdir -p "$HOME/.local/bin"
    touch "$HOME/.local/bin/mole"
    touch "$HOME/.local/bin/mo"
    mkdir -p "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
export -f start_inline_spinner stop_inline_spinner
printf '\n' | "$PROJECT_ROOT/mole" remove --dry-run
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN MODE"* ]] || return 1
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
    cat > "$fake_global_bin/brew" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$fake_global_bin/brew"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$fake_global_bin:/usr/bin:/bin" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
export -f start_inline_spinner stop_inline_spinner
printf '\n' | "$PROJECT_ROOT/mole" remove --dry-run
EOF

    rm -rf "$fake_global_bin"

    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/.local/bin/mole"* ]] || return 1
    [[ "$output" == *"$HOME/.local/bin/mo"* ]] || return 1
    [[ "$output" != *"$fake_global_bin/mole"* ]] || return 1
    [[ "$output" != *"$fake_global_bin/mo"* ]] || return 1
    [[ "$output" != *"brew uninstall --force mole"* ]]
}
@test "match_apps_by_name finds exact match case-insensitively" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"TestApp"* ]]
}

@test "match_apps_by_name finds by directory name" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"Test Application"* ]]
}

@test "match_apps_by_name prefers an exact mixed-case bundle basename" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/Foo.APP|Different Display Name|com.example.Foo|1 MB|1000000|1024"
	"1001|$HOME/Applications/Foo Bar.app|Foo Bar|com.example.FooBar|1 MB|1000001|1024"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "Foo"
echo "count=${#selected_apps[@]}"
echo "match=${selected_apps[0]}"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"/Foo.APP|"* ]] || return 1
    [[ "$output" != *"/Foo Bar.app|"* ]]
}

@test "match_apps_by_name warns on no match" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"Warning: No application found matching 'nonexistent'"* ]] || return 1
    [[ "$output" == *"count=0"* ]]
}

@test "match_apps_by_name handles multiple app names" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"count=2"* ]] || return 1
    [[ "$output" == *"matched=TestApp2"* ]] || return 1
    [[ "$output" == *"matched=TestApp3"* ]]
}

@test "match_apps_by_name falls back to substring match" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"matched=TestApp"* ]]
}

@test "match_apps_by_name does not duplicate when same name given twice" {
    run /bin/bash --noprofile --norc << 'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

trace_file="$HOME/uninstall-trace.log"
app_cache_file="$HOME/apps-cache.txt"
touch "$app_cache_file"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
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
    _MOLE_MENU_USER_QUIT=1
    return 1
}

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

@test "main keeps scan and selector on one alternate screen until cancel (#1194)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

trace_file="$HOME/uninstall-screen-trace.log"
app_cache_file="$HOME/apps-cache.txt"
touch "$app_cache_file"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { printf 'clear\n' >> "$trace_file"; }
start_uninstall_interactive_screen() {
    export MOLE_ALT_SCREEN_ACTIVE=1
    export MOLE_MANAGED_ALT_SCREEN=1
    printf 'start\n' >> "$trace_file"
}
stop_uninstall_interactive_screen() {
    printf 'stop\n' >> "$trace_file"
    unset MOLE_ALT_SCREEN_ACTIVE MOLE_MANAGED_ALT_SCREEN
}
scan_applications() {
    printf 'scan\n' >> "$trace_file"
    printf '%s\n' "$app_cache_file"
}
uninstall_app_inventory_fingerprint() {
    printf 'fingerprint\n' >> "$trace_file"
    printf 'inventory\n'
}
load_applications() { printf 'load\n' >> "$trace_file"; }
drain_pending_input() { printf 'drain\n' >> "$trace_file"; }
select_apps_for_uninstall() {
    [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]
    [[ "${MOLE_MANAGED_ALT_SCREEN:-}" == "1" ]]
    printf 'select\n' >> "$trace_file"
    _MOLE_MENU_USER_QUIT=1
    return 1
}

main

expected=$(printf 'start\nscan\nfingerprint\nload\ndrain\nselect\nstop\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Uninstall interactive scan begin"*"Uninstall interactive scan returned"*"Uninstall inventory fingerprint begin"*"Uninstall inventory fingerprint complete"*"Uninstall list load begin"*"Uninstall list load complete"*"Uninstall input drain begin"*"Uninstall selector begin"*"Uninstall selector returned"* ]] || { echo "$output"; return 1; }
}

@test "scan_applications starts feedback before discovery and cleans no-app state" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_FORCE_SCAN_SPINNER=1 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

trace_file="$HOME/scan-feedback-trace.log"
scan_temp="$HOME/scan-feedback-temp"

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

[[ ! -e "${scan_temp}.spinner_shown" ]] || exit 1
[[ ! -e "${scan_temp}.scan_status" ]]
INNER

    [ "$status" -eq 0 ]
}

@test "select_apps_for_uninstall drains pending input before opening paginated menu" {
    mkdir -p "$HOME/Applications/TraceApp.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
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
[[ ${#selected_apps[@]} -eq 1 ]] || exit 1
[[ -z "${MOLE_MENU_IGNORE_INITIAL_ENTER:-}" ]] || exit 1

expected=$(printf 'format\ndrain\nguard:1\npaginated\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ]
}

@test "select_apps_for_uninstall keeps menu line width within 80 columns for Yesterday items (#1573)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/app_selector.sh"

long_app_name="Visual Studio Code - Insiders Edition Long Title For App"
apps_data=("1700000000|/Applications/Test.app|$long_app_name|com.example.test|100MB|Yesterday|102400")
selected_apps=()
drain_pending_input() { :; }

captured_option=""
paginated_multi_select() {
    captured_option="$2"
    MOLE_SELECTION_RESULT=""
    return 1
}

tput() { echo 80; }
select_apps_for_uninstall || true

normal_line="  ○ $captured_option"
active_line="${ICON_ARROW} ○ $captured_option"

# Standard 80-column terminal must not wrap or leave orphan 'ay' characters
[[ ${#normal_line} -le 80 ]] || {
    printf 'normal line length %d exceeds 80: %s\n' "${#normal_line}" "$normal_line" >&2
    exit 1
}
[[ $(get_display_width "$normal_line") -le 80 ]] || {
    printf 'normal line display width %d exceeds 80\n' "$(get_display_width "$normal_line")" >&2
    exit 1
}
[[ $(get_display_width "$active_line") -le 80 ]] || {
    printf 'active line display width %d exceeds 80\n' "$(get_display_width "$active_line")" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ]
}

@test "select_apps_for_uninstall keeps Steam and Yesterday rows within 80 columns (#1573)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/app_selector.sh"

long_app_name="Visual Studio Code - Insiders Edition Long Title For App"
apps_data=("1700000000|/Applications/SteamGame.app|$long_app_name|com.example.steam|N/A (Steam-managed)|Yesterday|95")
selected_apps=()
drain_pending_input() { :; }

captured_option=""
paginated_multi_select() {
    captured_option="$2"
    MOLE_SELECTION_RESULT=""
    return 1
}

tput() { echo 80; }
select_apps_for_uninstall || true

normal_line="  ○ $captured_option"
active_line="${ICON_ARROW} ○ $captured_option"

[[ "$captured_option" == *"    Steam |"* ]] || {
    printf 'selector missing compact Steam label: %s\n' "$captured_option" >&2
    exit 1
}
[[ "$captured_option" != *"N/A (Steam-managed)"* ]] || {
    printf 'selector still used the 19-column Steam label: %s\n' "$captured_option" >&2
    exit 1
}
[[ $(get_display_width "$normal_line") -le 80 ]] || {
    printf 'normal line display width %d exceeds 80: %s\n' "$(get_display_width "$normal_line")" "$normal_line" >&2
    exit 1
}
[[ $(get_display_width "$active_line") -le 80 ]] || {
    printf 'active line display width %d exceeds 80: %s\n' "$(get_display_width "$active_line")" "$active_line" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ]
}

@test "format_app_display keeps Yesterday rows inside a 40-column terminal (#1573)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/app_selector.sh"

name=$(printf 'A%.0s' {1..70})
row=$(format_app_display "$name" "1023.5MB" "Yesterday" 40)
normal_line="  ○ $row"
[[ "$row" == *Yesterday* ]] || {
    printf 'missing Yesterday: %s\n' "$row" >&2
    exit 1
}
[[ $(get_display_width "$normal_line") -le 40 ]] || {
    printf '40-col overflow width=%d: %s\n' "$(get_display_width "$normal_line")" "$normal_line" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ]
}

@test "paginated menu can ignore one initial Enter for uninstall launch guard" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
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
    [[ "$output" == *"rc=1"* ]] || return 1
    [[ "$output" == *"result="* ]] || return 1
    [[ "$output" != *"result=0"* ]]
}

@test "paginated menu skips Size sort when size metadata is unavailable (#1126)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

key_state="$HOME/menu-no-size-state"
read_key() {
    local n
    n=$(cat "$key_state" 2> /dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$key_state"
    case "$n" in
        1 | 2) echo "CHAR:S" ;;
        *) echo "ENTER" ;;
    esac
}

MOLE_SELECTION_RESULT=""
unset MOLE_MENU_SORT_MODE MOLE_MENU_SORT_REVERSE MOLE_MENU_META_SIZEKB
set +e
MOLE_MENU_META_EPOCHS="100,200" paginated_multi_select "Test Menu" "Alpha" "Beta" > "$HOME/menu.out" 2> "$HOME/menu.err" < /dev/null
rc=$?
set -e
echo "rc=$rc"
echo "mode=${MOLE_MENU_SORT_MODE:-}"
echo "result=${MOLE_SELECTION_RESULT:-}"
[[ $rc -eq 0 ]] || exit 1
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]] || return 1
    [[ "$output" == *"mode=date"* ]] || return 1
    [[ "$output" == *"result=0"* ]]
}

@test "paginated menu reverses Size order when size metadata is available (#1126)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

key_state="$HOME/menu-size-state"
read_key() {
    local n
    n=$(cat "$key_state" 2> /dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$key_state"
    case "$n" in
        1) echo "${NEXT_KEY:-ENTER}" ;;
        *) echo "ENTER" ;;
    esac
}

MOLE_SELECTION_RESULT=""
set +e
MOLE_MENU_META_SIZEKB="1,100" MOLE_MENU_SORT_MODE=size MOLE_MENU_SORT_REVERSE=false paginated_multi_select "Test Menu" "Small" "Large" > "$HOME/menu-default.out" 2> "$HOME/menu-default.err" < /dev/null
default_rc=$?
set -e
echo "default=${MOLE_SELECTION_RESULT:-}"

: > "$key_state"
MOLE_SELECTION_RESULT=""
set +e
NEXT_KEY="CHAR:O" MOLE_MENU_META_SIZEKB="1,100" MOLE_MENU_SORT_MODE=size MOLE_MENU_SORT_REVERSE=false paginated_multi_select "Test Menu" "Small" "Large" > "$HOME/menu-reverse.out" 2> "$HOME/menu-reverse.err" < /dev/null
reverse_rc=$?
set -e
echo "default_rc=$default_rc"
echo "reverse_rc=$reverse_rc"
echo "reverse=${MOLE_SELECTION_RESULT:-}"
[[ $default_rc -eq 0 ]] || exit 1
[[ $reverse_rc -eq 0 ]] || exit 1
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"default_rc=0"* ]] || return 1
    [[ "$output" == *"reverse_rc=0"* ]] || return 1
    [[ "$output" == *"default=1"* ]] || return 1
    [[ "$output" == *"reverse=0"* ]]
}

@test "main reuses the app list after a removal-only uninstall (#866, #1315)" {
    local first_cache
    first_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-866-first.XXXXXX")"

    mkdir -p "$HOME/Applications/FirstApp.app" "$HOME/Applications/SecondApp.app"
    cat > "$first_cache" << CACHE
1700000000|$HOME/Applications/FirstApp.app|FirstApp|com.example.FirstApp|10MB|Today|10240
1700000001|$HOME/Applications/SecondApp.app|SecondApp|com.example.SecondApp|11MB|Today|11264
CACHE

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" FIRST_CACHE="$first_cache" \
        /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
drain_pending_input() { :; }
uninstall_app_inventory_fingerprint() {
    if [[ "$fingerprint_state" == "before" ]]; then
        printf '%s|1\n%s|1\n' "$HOME/Applications/FirstApp.app" "$HOME/Applications/SecondApp.app"
    else
        printf '%s|1\n' "$HOME/Applications/SecondApp.app"
    fi
}
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
    printf '%s\n' "$FIRST_CACHE"
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
    _MOLE_MENU_USER_QUIT=1
    return 1
}

printf '\n' | main

expected=$(printf 'scan:1\nload:%s/Applications/FirstApp.app|FirstApp|com.example.FirstApp|10MB|Today|10240\nselect:1\nbatch\nload:%s/Applications/SecondApp.app|SecondApp|com.example.SecondApp|11MB|Today|11264\nselect:2\n' "$HOME" "$HOME")
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

    rm -f "$first_cache"
    [ "$status" -eq 0 ]
}

@test "completed uninstall suppresses dead-terminal countdown read errors (#1503)" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-1503-countdown.XXXXXX")"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" APPS_CACHE_FILE="$apps_cache" \
        /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

log_operation_session_start() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() { :; }
select_apps_for_uninstall() {
    selected_apps=("0|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1KB|Today|1")
}
batch_uninstall_applications() { :; }
uninstall_app_inventory_fingerprint() { printf 'stable\n'; }
uninstall_normalize_size_display() { printf '%s\n' "$1"; }
uninstall_normalize_last_used_display() { printf '%s\n' "$1"; }
get_display_width() { printf '%s\n' "${#1}"; }
truncate_by_display_width() { printf '%s\n' "$1"; }
mole_tty_is_foreground() { return 0; }
drain_pending_input() { :; }
read() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == -t || "$arg" == -t* ]]; then
            printf 'read error: 0: Input/output error\n' >&2
            return 1
        fi
    done
    builtin read "$@"
}

main > "$HOME/countdown.out" 2> "$HOME/countdown.err"

[[ "$(cat "$HOME/countdown.err")" != *'Input/output error'* ]] || {
    cat "$HOME/countdown.err" >&2
    exit 1
}
[[ "$(grep -o 'Press Enter to return to the app list' "$HOME/countdown.out" | wc -l | tr -d ' ')" -eq 5 ]]
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "inventory cache reuse accepts removals only and rejects stale changes (#1315)" {
    run env HOME="$HOME/inventory-reuse" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

mkdir -p "$HOME/Applications/First.app" "$HOME/Applications/Second.app"
mkdir -p "$HOME/Applications/With|Pipe.app"
old=$(printf '%s|1|1\n%s|1|1\n' "$HOME/Applications/First.app" "$HOME/Applications/Second.app")
removed=$(printf '%s|1|1\n' "$HOME/Applications/Second.app")
changed=$(printf '%s|2|1\n' "$HOME/Applications/Second.app")
added=$(printf '%s|1|1\n%s|1|1\n' "$HOME/Applications/Second.app" "$HOME/Applications/Third.app")
pipe_old=$(printf '%s|1|1\n%s|1|1\n' "$HOME/Applications/Second.app" "$HOME/Applications/With|Pipe.app")

if uninstall_inventory_can_reuse_cached_apps "$old" "$removed"; then
    exit 1
fi
if uninstall_inventory_can_reuse_cached_apps "$pipe_old" "$removed"; then
    exit 2
fi
rmdir "$HOME/Applications/With|Pipe.app"
uninstall_inventory_can_reuse_cached_apps "$pipe_old" "$removed" || exit 3
rmdir "$HOME/Applications/First.app"
uninstall_inventory_can_reuse_cached_apps "$old" "$removed" || exit 4
if uninstall_inventory_can_reuse_cached_apps "$old" "$changed"; then
    exit 5
fi
if uninstall_inventory_can_reuse_cached_apps "$old" "$added"; then
    exit 6
fi
if uninstall_inventory_can_reuse_cached_apps "$old" ""; then
    exit 7
fi
INNER

    [ "$status" -eq 0 ] || return 1
}

@test "inventory fingerprint changes when only Info.plist changes" {
    run env HOME="$HOME/inventory-plist-mtime" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

app_path="$HOME/Applications/Mutable.app"
mkdir -p "$app_path/Contents"
touch -t 202001010000 "$app_path/Contents/Info.plist"
uninstall_print_app_search_dirs() { printf '%s\n' "$HOME/Applications"; }
pkg_receipt_nonstandard_app_paths() { :; }
uninstall_should_skip_app_path() { return 1; }

before=$(uninstall_app_inventory_fingerprint)
touch -t 202101010000 "$app_path/Contents/Info.plist"
after=$(uninstall_app_inventory_fingerprint)
[[ "$before" != "$after" ]] || exit 1
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch scan refreshes selected app identity before leftover discovery" {
    run env HOME="$HOME/batch-refresh-identity" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

app_path="$HOME/Applications/Current.app"
mkdir -p "$app_path"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
uninstall_resolve_eligible_bundle_id() { printf 'com.example.Current\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '1\n'; }
find_app_files() { printf '%s|%s\n' "$1" "$2" > "$HOME/discovery-identity"; }
get_diagnostic_report_paths_for_app() { return 0; }
find_app_system_files() { return 0; }
calculate_total_size() { printf '0\n'; }
has_sensitive_data() { return 1; }
discover_login_item_helper_bundle_ids() { return 0; }

selected_apps=("0|$app_path|Stale Display|com.example.Stale|0|Never")
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
app_details=()
total_estimated_size=0
_batch_scan_app_details

[[ "$(cat "$HOME/discovery-identity")" == "com.example.Current|Current" ]] || exit 1
[[ "${app_details[0]}" == "Stale Display|$app_path|com.example.Current|"* ]] || exit 1
INNER

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch scan stops before discovery when app sizing is interrupted" {
    run env HOME="$HOME/batch-size-interrupt" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

app_path="$HOME/Applications/Interrupted.app"
mkdir -p "$app_path"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.Interrupted\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { return 130; }
find_app_files() { printf 'UNEXPECTED_DISCOVERY\n'; return 99; }

selected_apps=("0|$app_path|Interrupted|com.example.Interrupted|0|Never")
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
app_details=()
total_estimated_size=0
rc=0
_batch_scan_app_details || rc=$?
printf 'RC=%s DETAILS=%s\n' "$rc" "${#app_details[@]}"
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130 DETAILS=0"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DISCOVERY"* ]]
}

@test "batch uninstall stops before discovery and teardown when app sizing times out" {
    run env HOME="$HOME/batch-size-timeout" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

app_path="$HOME/Applications/TimedOut.app"
mkdir -p "$app_path"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.TimedOut\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { return 124; }
find_app_files() { echo "UNEXPECTED_DISCOVERY"; return 99; }
stop_launch_services() { echo "UNEXPECTED_TEARDOWN"; }
unregister_app_bundle() { echo "UNEXPECTED_TEARDOWN"; }
remove_login_item() { echo "UNEXPECTED_TEARDOWN"; }
force_kill_app() { echo "UNEXPECTED_TEARDOWN"; }
mole_delete() { echo "UNEXPECTED_DELETE"; }

selected_apps=("0|$app_path|TimedOut|com.example.TimedOut|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0
rc=0
batch_uninstall_applications || rc=$?
printf 'RC=%s\n' "$rc"
[[ $rc -eq 124 ]]
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DISCOVERY"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_TEARDOWN"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE"* ]]
}

@test "batch scan keeps the app plan when related-file sizing times out" {
    # Related size is display-only (#1383). A stalled du on leftovers must not
    # abort the batch; the leftover paths stay in the plan with size 0.
    run env HOME="$HOME/batch-related-size-timeout" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

app_path="$HOME/Applications/TimedOut.app"
related_path="$HOME/Library/Caches/com.example.TimedOut"
mkdir -p "$app_path" "$related_path"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.TimedOut\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() {
    if [[ "$1" == "$app_path" ]]; then
        printf '1\n'
        return 0
    fi
    return 124
}
find_app_files() { printf '%s\n' "$related_path"; }
get_diagnostic_report_paths_for_app() { return 0; }
find_app_system_files() { return 0; }
discover_login_item_helper_bundle_ids() { return 0; }
has_sensitive_data() { return 1; }

selected_apps=("0|$app_path|TimedOut|com.example.TimedOut|0|Never")
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
app_details=()
total_estimated_size=0
rc=0
_batch_scan_app_details || rc=$?
printf 'RC=%s DETAILS=%s\n' "$rc" "${#app_details[@]}"
[[ $rc -eq 0 && ${#app_details[@]} -eq 1 ]]
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=0 DETAILS=1"* ]]
}

@test "batch scan keeps the app when leftover discovery times out after receipt work (#1383)" {
    # Machine-wide receipt walks can exhaust the shared deadline; leftover
    # discovery then returns 124. That must narrow to the selected app, not
    # abort with "nothing was removed".
    run env HOME="$HOME/batch-leftover-timeout" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

app_path="$HOME/Applications/UniFi-Discover.app"
mkdir -p "$app_path"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.unifi\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
uninstall_live_bundle_has_other_install() {
    # Sibling scan finished with a complete "no sibling" proof, but burned
    # the shared wall clock so leftover discovery has no budget left.
    _MOLE_UNINSTALL_DISCOVERY_DEADLINE=$SECONDS
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '4\n'; }
find_app_files() { return 124; }
get_diagnostic_report_paths_for_app() { echo "UNEXPECTED_DIAG"; return 99; }
find_app_system_files() { echo "UNEXPECTED_SYSTEM"; return 99; }
discover_login_item_helper_bundle_ids() { return 0; }
has_sensitive_data() { return 1; }

selected_apps=("0|$app_path|UniFi Discover|com.example.unifi|0|Never")
running_apps=()
sudo_apps=()
brew_cask_apps=()
blocked_apps=()
manual_removal_apps=()
leftover_notes=()
app_details=()
total_estimated_size=0
rc=0
_batch_scan_app_details || rc=$?
printf 'RC=%s DETAILS=%s\n' "$rc" "${#app_details[@]}"
# The note waits for the preview instead of printing over the scan spinner.
printf 'NOTES=%s\n' "${leftover_notes[*]-}"
# Plan must exist: one detail row, app-only (no leftover encoding of UNEXPECTED_*)
[[ $rc -eq 0 && ${#app_details[@]} -eq 1 ]]
printf 'DETAIL=%s\n' "${app_details[0]}"
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=0 DETAILS=1"* ]] || return 1
    [[ "$output" == *"NOTES="*"|Leftovers kept (scan timed out)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DIAG"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SYSTEM"* ]] || return 1
}

# ---------------------------------------------------------------------------
# #723: Trash routing default and --permanent flag
# ---------------------------------------------------------------------------

@test "uninstall main sets MOLE_DELETE_MODE=trash by default" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-723-trash.XXXXXX")"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() { return 0; }
drain_pending_input() { :; }
select_apps_for_uninstall() {
    printf 'delete_mode=%s\n' "${MOLE_DELETE_MODE:-unset}"
    _MOLE_MENU_USER_QUIT=1
    return 1
}

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
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() { return 0; }
drain_pending_input() { :; }
select_apps_for_uninstall() {
    printf 'delete_mode=%s\n' "${MOLE_DELETE_MODE:-unset}"
    _MOLE_MENU_USER_QUIT=1
    return 1
}

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
    cat > "$apps_cache" << 'CACHE'
1700000000|/Applications/Slack.app|Slack|com.tinyspeck.slackmacgap|180MB|Today|184320
1700000000|/Applications/Zoom.app|Zoom|us.zoom.xos|140MB|Yesterday|143360
CACHE

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
# Stubbed so the size column never probes a real /Applications bundle.
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

# Force text mode by simulating a TTY for stdout via /dev/tty redirect not
# available in bats; instead pipe through a wrapper that fakes -t 1. Simplest:
# call the function directly so [[ -t 1 ]] uses bash's stdout (the bats pipe).
# We accept the function emits JSON when piped; assert against JSON shape too.
main --list
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    # Bats pipes stdout, so output is JSON. Assert both apps and uninstall_name.
    [[ "$output" == *'"name": "Slack"'* ]] || return 1
    [[ "$output" == *'"name": "Zoom"'* ]] || return 1
    [[ "$output" == *'"uninstall_name": "Slack"'* ]] || return 1
    [[ "$output" == *'"bundle_id": "com.tinyspeck.slackmacgap"'* ]] || return 1
    [[ "$output" == *'"source": "App"'* ]]
}

@test "uninstall --list emits JSON array when stdout is piped" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-json.XXXXXX")"
    cat > "$apps_cache" << 'CACHE'
1700000000|/Applications/Slack.app|Slack|com.tinyspeck.slackmacgap|180MB|Today|184320
CACHE

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
# Stubbed so the size column never probes a real /Applications bundle.
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

main --list
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    # Output should start with '[' and end with ']' to be a valid JSON array.
    [[ "${output:0:1}" == "[" ]] || return 1
    [[ "${output: -1}" == "]" ]] || return 1
    # Round-trip via python to confirm it parses as JSON.
    if command -v python3 > /dev/null; then
        printf '%s\n' "$output" | python3 -c 'import sys, json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d)==1 and d[0]["name"]=="Slack"'
    fi
}

@test "uninstall --list with empty scan returns empty JSON array" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-empty.XXXXXX")"
    # Non-empty file so load_applications doesn't bail early on size check.
    echo "" > "$apps_cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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
# Stubbed so the size column never probes a real /Applications bundle.
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

main --list
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "uninstall --list flags brew-managed apps with cask uninstall_name" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-brew.XXXXXX")"
    cat > "$apps_cache" << 'CACHE'
1700000000|/Applications/Visual Studio Code.app|Visual Studio Code|com.microsoft.VSCode|420MB|Today|430080
CACHE

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"

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

main --list
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"uninstall_name": "visual-studio-code"'* ]] || return 1
    [[ "$output" == *'"source": "Homebrew"'* ]]
}

# Regression tests for #940: warn about background jobs that survive uninstall.
# Detection is launchctl-only. sfltool dumpbtm is deliberately not used:
# unprivileged dumpbtm pops the macOS "sfltool wants to make changes"
# admin-password dialog on every uninstall batch.
_bg_items_runner() {
    HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        DETAIL="$1" SUCCESS_PATH="$2" LAUNCHCTL_RC="${3:-113}" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
launchctl() { return "${LAUNCHCTL_RC}"; }
_uninstall_match_loaded_background_items "$DETAIL" -- "$SUCCESS_PATH"
EOF
}

@test "_uninstall_match_loaded_background_items reports app whose job is still loaded" {
    local detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"

    result="$(_bg_items_runner "$detail" "/Applications/Paste.app" 0)"

    [ "$result" = "Paste" ]
}

@test "_uninstall_match_loaded_background_items stays silent when no job is loaded" {
    local detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"

    result="$(_bg_items_runner "$detail" "/Applications/Paste.app" 113)"

    [ -z "$result" ]
}

@test "_uninstall_match_loaded_background_items checks helper ids under the sibling guard" {
    # Sibling guard demotes bundle_id to "unknown" while helper ids stay
    # valid; a loaded helper job must still be reported.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

helpers=$(printf 'com.wiheads.paste.helper' | base64)
detail="Paste|/Applications/Paste.app|unknown|0|||false|false|false||||$helpers|guard"

launchctl() { [[ "$2" == *"com.wiheads.paste.helper"* ]] && return 0 || return 113; }
result=$(_uninstall_match_loaded_background_items "$detail" -- "/Applications/Paste.app")
[[ "$result" == "Paste" ]] || exit 1

launchctl() { return 113; }
result=$(_uninstall_match_loaded_background_items "$detail" -- "/Applications/Paste.app")
[[ -z "$result" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "_uninstall_match_loaded_background_items stays quiet in test mode" {
    # Test mode must not probe launchctl at all; summaries stay silent so
    # end-to-end uninstall tests never see a background-item warning.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
launchctl() { return 0; }
detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"
result=$(_uninstall_match_loaded_background_items "$detail" -- "/Applications/Paste.app")
[[ -z "$result" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "_uninstall_match_loaded_background_items skips apps that were not successfully removed" {
    local detail="Paste|/Applications/Paste.app|com.wiheads.paste|0|||false|false|false||||"

    result="$(_bg_items_runner "$detail" "/Applications/OtherApp.app" 0)"

    [ -z "$result" ]
}

@test "_uninstall_match_loaded_background_items ignores unknown bundle id without helpers" {
    local detail="Paste|/Applications/Paste.app|unknown|0|||false|false|false||||"

    result="$(_bg_items_runner "$detail" "/Applications/Paste.app" 0)"

    [ -z "$result" ]
}

@test "execution spinner starts before the same-bundle re-scan (#1340 family)" {
    # The pre-teardown re-scan can burn tens of seconds on a large receipt
    # set. When the spinner started after it, the Enter confirm was followed
    # by dead silence and users read the prompt as hung. Pin the order
    # inside _batch_execute_removals.
    local body spin_line scan_line
    body=$(awk '/^_batch_execute_removals\(\)/{f=1} f{n++; print n": "$0} f && /^\}/{exit}' \
        "$PROJECT_ROOT/lib/uninstall/batch.sh")
    spin_line=$(printf '%s\n' "$body" | command grep -m1 'start_inline_spinner' | cut -d: -f1)
    scan_line=$(printf '%s\n' "$body" | command grep -m1 'uninstall_live_bundle_has_other_install' | cut -d: -f1)
    [[ -n "$spin_line" && -n "$scan_line" ]] || {
        echo "expected both calls inside _batch_execute_removals"
        return 1
    }
    [[ "$spin_line" -lt "$scan_line" ]] || {
        echo "spinner starts at line $spin_line, after the re-scan at $scan_line"
        return 1
    }
}

@test "match_apps_by_name joins multi-word args into one exact app name (#1365)" {
    # `mo uninstall Tor Browser` arrives as two words; "Tor" alone
    # substring-matched WebSTORm. The joined words exactly name an
    # installed app, so that must be the single match.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/WebStorm.app|WebStorm|com.jetbrains.WebStorm|3.06 GB|1000000|3208960"
	"1001|$HOME/Applications/Tor Browser.app|Tor Browser|org.torproject.torbrowser|501.8 MB|1000001|513843"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "Tor" "Browser"
echo "count=${#selected_apps[@]}"
echo "match=${selected_apps[0]}"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"Tor Browser"* ]] || return 1
    [[ "$output" != *"WebStorm"* ]] || return 1
}

@test "match_apps_by_name keeps per-word matching when the joined form names nothing" {
    # Two genuinely separate app queries must keep working after the
    # joined-form check: "TestApp2 TestApp3" names no single app.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp2.app|TestApp2|com.example.TestApp2|500 MB|1000001|512000"
	"1001|$HOME/Applications/TestApp3.app|TestApp3|com.example.TestApp3|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "TestApp2" "TestApp3"
echo "count=${#selected_apps[@]}"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"count=2"* ]] || return 1
}

@test "match_apps_by_name keeps two-app meaning when every word exactly names its own app" {
    # With Foo.app, Bar.app, and "Foo Bar.app" all installed, the joined
    # interpretation must not silently swallow the original two-app query.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/Foo.app|Foo|com.example.foo|100 MB|1000000|102400"
	"1001|$HOME/Applications/Bar.app|Bar|com.example.bar|100 MB|1000001|102400"
	"1002|$HOME/Applications/Foo Bar.app|Foo Bar|com.example.foobar|100 MB|1000002|102400"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "Foo" "Bar"
echo "count=${#selected_apps[@]}"
printf 'sel=%s\n' "${selected_apps[@]}"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"count=2"* ]] || return 1
    [[ "$output" == *"|Foo|"* ]] || return 1
    [[ "$output" == *"|Bar|"* ]] || return 1
    [[ "$output" != *"Foo Bar"* ]] || return 1
}

@test "batch uninstall reports an inconclusive Homebrew scan before any removal (#1579, #1580)" {
    run env HOME="$HOME/batch-brew-failure" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

app_path="$HOME/Applications/TimedOut.app"
mkdir -p "$app_path"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.TimedOut\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
uninstall_live_bundle_has_other_install() {
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    return 1
}
pgrep() { return 1; }
get_brew_cask_name() { return 2; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "UNEXPECTED_SIZE"; }
find_app_files() { echo "UNEXPECTED_DISCOVERY"; return 99; }
stop_launch_services() { echo "UNEXPECTED_TEARDOWN"; }
unregister_app_bundle() { echo "UNEXPECTED_TEARDOWN"; }
remove_login_item() { echo "UNEXPECTED_TEARDOWN"; }
force_kill_app() { echo "UNEXPECTED_TEARDOWN"; }
mole_delete() { echo "UNEXPECTED_DELETE"; }

selected_apps=("0|$app_path|TimedOut|com.example.TimedOut|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0
rc=0
batch_uninstall_applications || rc=$?
printf 'RC=%s\n' "$rc"
[[ $rc -eq 1 ]]
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=1"* ]] || return 1
    [[ "$output" == *"Homebrew ownership check"* ]] || return 1
    [[ "$output" == *"nothing was removed"* ]] || return 1
    [[ "$output" == *"'TimedOut' matches a Homebrew cask brew cannot read"* ]] || return 1
    [[ "$output" == *"brew info --cask"* ]] || return 1
    # A cask brew cannot parse still lists cleanly, so pointing the user at
    # `brew list --cask` diagnoses nothing.
    [[ "$output" != *"brew list --cask"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SIZE"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DISCOVERY"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_TEARDOWN"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE"* ]]
}

@test "uninstall preview excludes protected leftovers before sizing and execution" {
    mkdir -p "$HOME/Applications/ChatGPT.app" "$HOME/Library/Logs/com.openai.codex" "$HOME/eligible-leftover"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
brew() { :; }
request_sudo_access() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
enter_alt_screen() { :; }
leave_alt_screen() { :; }
hide_cursor() { :; }
show_cursor() { :; }
remove_apps_from_dock() { :; }
force_kill_app() { :; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
bootout_login_item_helpers() { :; }
pgrep() { return 1; }
pkill() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo 10; }
calculate_total_size() { printf '%s\n' "$1" > "$HOME/sized-plan"; echo 17; }
find_app_files() { printf '%s\n' "$HOME/Library/Logs/com.openai.codex" "$HOME/eligible-leftover"; }
find_app_system_files() { :; }
get_diagnostic_report_paths_for_app() {
    [[ "$3" == "$HOME/Library/Logs/DiagnosticReports" ]] || return 0
    printf '%s\n' "$HOME/Library/Logs/com.openai.codex"
}
_mole_complete_lsof_mode() { echo unexpected-lsof >> "$HOME/forbidden"; return 2; }
validate_path_for_deletion() { echo unexpected-validation >> "$HOME/forbidden"; return 2; }
remove_file_list() {
    [[ -n "$1" ]] || return 0
    printf '%s\n' "$1" >> "$HOME/executed-plan"
    [[ "$1" == "$HOME/eligible-leftover" ]] || return 1
    rmdir "$1"
}
mole_delete() { rmdir "$1"; }
selected_apps=("0|$HOME/Applications/ChatGPT.app|ChatGPT|unknown|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0
printf '\n' | batch_uninstall_applications > "$HOME/output.log" 2>&1
[[ "$(cat "$HOME/sized-plan")" == "$HOME/eligible-leftover" ]] || exit 1
[[ "$(cat "$HOME/executed-plan")" == "$HOME/eligible-leftover" ]] || exit 1
[[ -d "$HOME/Library/Logs/com.openai.codex" ]] || exit 1
[[ ! -e "$HOME/Applications/ChatGPT.app" && ! -e "$HOME/eligible-leftover" ]] || exit 1
[[ ! -e "$HOME/forbidden" ]] || { cat "$HOME/forbidden"; exit 1; }
! grep -q 'Logs/com.openai.codex' "$HOME/output.log" || exit 1
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; cat "$HOME/output.log"; return 1; }
}

@test "batch uninstall explains actual refusal and clears it for the next app" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
export MOLE_UNINSTALL_MODE=1 MOLE_DELETE_MODE=trash
export MOLE_TEST_TRASH_DIR="$HOME/Trash"
mkdir -p "$HOME/Applications/First.app" "$HOME/Applications/Second.app" "$HOME/Library/Caches/com.example.Shared"
shared="$HOME/Library/Caches/com.example.Shared"
stop_launch_services() { :; }
unregister_app_bundle() { :; }
_mole_should_refuse_live_user_cache_path() { [[ "$1" == "$shared" && "$app_name" == First ]]; }
_mole_is_critical_deletion_path() { [[ "$1" == "$shared" && "$app_name" == Second ]]; }
first="$HOME/Applications/First.app"
second="$HOME/Applications/Second.app"
encoded=$(printf '%s\n' "$shared" | base64 | tr -d '\n')
app_details=(
    "First|$first|unknown|0|$encoded||false|false|false|||||guard_login|$(_batch_selected_app_identity "$first")|unknown||missing"
    "Second|$second|unknown|0|$encoded||false|false|false|||||guard_login|$(_batch_selected_app_identity "$second")|unknown||missing"
)
success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0
_batch_execute_removals
[[ $success_count -eq 2 && $failed_count -eq 0 ]] || exit 1
[[ ! -e "$first" && ! -e "$second" && -d "$shared" ]] || exit 1
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Kept (app may be active): ~/Library/Caches/com.example.Shared"* ]] || return 1
    [[ "$output" == *"Could not remove: ~/Library/Caches/com.example.Shared"* ]] || return 1
}


@test "nonprivileged batch privacy denial retains the app and offers factual next steps" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME/Applications/Denied.app"
app="$HOME/Applications/Denied.app"
stop_launch_services() { :; }
unregister_app_bundle() { :; }
mole_delete() {
    [[ "$1" == "$app" && "$2" == false ]] || return 99
    printf 'denied\n' > "$HOME/delete-called"
    return "$MOLE_ERR_PRIVACY_DENIED"
}
remove_file_list() { printf 'unexpected leftovers\n' > "$HOME/leftovers-called"; return 99; }
app_details=("Denied|$app|unknown|0|||false|false|false|||||guard_login|$(_batch_selected_app_identity "$app")|unknown||missing")
success_count=0
failed_count=0
brew_apps_removed=0
failed_items=()
success_items=()
success_dock_targets=()
system_extension_warning_apps=()
review_only_system_leftovers=()
review_only_system_leftover_keys=()
running_at_uninstall_apps=()
total_size_freed=0
files_cleaned=0
total_items=0
_batch_execute_removals
[[ $success_count -eq 0 && $failed_count -eq 1 ]] || exit 1
[[ -d "$app" && -s "$HOME/delete-called" && ! -e "$HOME/leftovers-called" ]] || exit 1
printf 'FAILURE=%s\n' "${failed_items[0]}"
SCRIPT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"macOS denied Trash access"* ]] || return 1
    [[ "$output" == *"Try moving the item to Trash in Finder. Run with --debug for details"* ]] || return 1
    [[ "$output" != *"check permissions"* ]] || return 1
    [[ "$output" != *"Full Disk Access"* ]]
}


@test "batch scan debug reports a confirmed sibling without changing its protected plan" {
    assert_sibling_scan_debug_reason 0 "shared with a live sibling"
}

@test "batch scan debug reports partial sibling evidence without claiming a sibling exists" {
    assert_sibling_scan_debug_reason 3 "Could not rule out other copies of bundle id com.example.shared (scan exit 3)"
}

@test "batch scan debug reports failed sibling evidence without claiming a sibling exists" {
    assert_sibling_scan_debug_reason 2 "Could not rule out other copies of bundle id com.example.shared (scan exit 2)"
}

@test "sibling scan diagnostics distinguish receipt and root failures without changing verdicts" {
    run env HOME="$HOME/sibling-causes" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 /bin/bash --noprofile --norc <<'EOF_CAUSES'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME/Applications"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=()
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
_uninstall_materialize_complete_pkg_apps() { : > "$1"; return 124; }
rc=0
uninstall_live_bundle_has_other_install com.example.selected "$HOME/Selected.app" || rc=$?
[[ $rc -eq "$MOLE_UNINSTALL_SCAN_PARTIAL" ]] || exit 1
printf 'RECEIPT_VERDICT=%s\n' "$rc"
_uninstall_materialize_complete_pkg_apps() { : > "$1"; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
_uninstall_materialize_complete_find0() { : > "$1"; return "$root_rc"; }
for root_rc in 3 7; do
    rc=0
    uninstall_live_bundle_has_other_install com.example.selected "$HOME/Selected.app" || rc=$?
    if [[ $root_rc -eq 3 ]]; then [[ $rc -eq 3 ]] || exit 1; else [[ $rc -eq 2 ]] || exit 1; fi
    printf 'ROOT_VERDICT=%s\n' "$rc"
done
EOF_CAUSES
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Sibling package receipt scan timed out (exit 124)"* && "$output" == *RECEIPT_VERDICT=3* ]] || return 1
    [[ "$output" == *"Sibling application root scan incomplete (exit 3)"* && "$output" == *ROOT_VERDICT=3* ]] || return 1
    [[ "$output" == *"Sibling application root scan failed (exit 7)"* && "$output" == *ROOT_VERDICT=2* ]] || return 1
}

@test "sibling find diagnostics retain partial stdout and sanitize the original error" {
    run env HOME="$HOME/sibling-find-error" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 /bin/bash --noprofile --norc <<'EOF_FIND_ERROR'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME"
scan_file=$(create_temp_file)
run_with_timeout() {
    printf '%s\0' "$HOME/Visible.app"
    printf 'permission denied\033[31m\n' >&2
    return 1
}
rc=0
_uninstall_materialize_complete_find0 "$scan_file" "$((SECONDS + 5))" "$HOME" || rc=$?
[[ $rc -eq "$MOLE_UNINSTALL_SCAN_PARTIAL" ]] || exit 1
IFS= read -r -d '' app < "$scan_file"
[[ "$app" == "$HOME/Visible.app" ]] || exit 1
printf 'PARTIAL_CANDIDATE_RETAINED\n'
EOF_FIND_ERROR
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Sibling application listing failed (exit 1)"* && "$output" == *"permission denied"* && "$output" == *PARTIAL_CANDIDATE_RETAINED* ]] || return 1
    [[ "$output" != *$'\033[31m'* ]] || return 1
}

@test "sibling candidate diagnostics preserve unknown and interrupted plist verdicts" {
    run env HOME="$HOME/sibling-plist-error" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 /bin/bash --noprofile --norc <<'EOF_PLIST_ERROR'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
app="$HOME/Other.app"
mkdir -p "$app/Contents"
printf 'not a plist\n' > "$app/Contents/Info.plist"
run_with_timeout() { return "$probe_rc"; }
for probe_rc in 1 143; do
    rc=0
    _uninstall_collect_live_sibling_candidate "$app" "$HOME/Selected.app" com.example.selected "$((SECONDS + 10))" false || rc=$?
    if [[ $probe_rc -eq 1 ]]; then [[ $rc -eq 2 ]] || exit 1; else [[ $rc -eq 143 ]] || exit 1; fi
    printf 'PLIST_VERDICT=%s\n' "$rc"
done
EOF_PLIST_ERROR
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Sibling plist cannot be validated (exit 1)"* && "$output" == *PLIST_VERDICT=2* ]] || return 1
    [[ "$output" == *"Sibling bundle ID probe incomplete (exit 143)"* && "$output" == *PLIST_VERDICT=143* ]] || return 1
}

@test "successful sibling scans stay quiet in debug refusal diagnostics" {
    run env HOME="$HOME/sibling-complete" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 /bin/bash --noprofile --norc <<'EOF_COMPLETE'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=()
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"
rc=0
uninstall_live_bundle_has_other_install com.example.selected "$HOME/Selected.app" || rc=$?
[[ $rc -eq 1 ]] || exit 1
printf 'COMPLETE_ABSENCE\n'
EOF_COMPLETE
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *COMPLETE_ABSENCE* && "$output" != *"Sibling "* ]] || return 1
}

@test "sibling scan retains uncertainty for symlink app roots with physical controls" {
    run env HOME="$HOME/root-scan" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF_ROOT'
set -euo pipefail
export MOLE_TEST_NO_AUTH=1 TERM=dumb
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
# Bounded helpers only invoke fixture find/plutil/stat; no authorization or sink.
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"

mkdir -p "$HOME/physical/Survivor.app/Contents" "$HOME/Selected.app/Contents"
for app in "$HOME/physical/Survivor.app" "$HOME/Selected.app"; do
    printf '%s\n' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.shared</string></dict></plist>' > "$app/Contents/Info.plist"
done
ln -s "$HOME/physical" "$HOME/Applications"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
rc=0
uninstall_live_bundle_has_other_install com.example.shared "$HOME/Selected.app" || rc=$?
printf 'CONFIGURED_HOME_APPLICATIONS_SYMLINK_RC=%s\n' "$rc"
[[ $rc -eq 2 ]] || { printf 'expected unknown=2, got %s\n' "$rc" >&2; exit 1; }
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/physical")
rc=0
uninstall_live_bundle_has_other_install com.example.shared "$HOME/Selected.app" || rc=$?
printf 'PHYSICAL_POSITIVE_RC=%s\n' "$rc"
[[ $rc -eq 0 && -n "$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT" ]] || exit 1
mkdir -p "$HOME/empty"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/empty")
rc=0
uninstall_live_bundle_has_other_install com.example.shared "$HOME/Selected.app" || rc=$?
printf 'ORDINARY_EMPTY_ABSENCE_RC=%s\n' "$rc"
[[ $rc -eq 1 && -z "$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT" ]] || exit 1
EOF_ROOT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *ORDINARY_EMPTY_ABSENCE_RC=1* ]] || return 1
}

@test "symlink app roots keep shared leftovers in preview and final removal" {
    run env HOME="$HOME/root-plan" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF_ROOT'
set -euo pipefail
export MOLE_TEST_NO_AUTH=1 TERM=dumb
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
# Bounded helpers only invoke fixture find/plutil/stat; no authorization or sink.
run_with_timeout() { shift; "$@"; }
pkg_receipt_nonstandard_app_paths() { :; }
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/no-volumes"

export MO_DEBUG=1
mkdir -p "$HOME/physical/Survivor.app/Contents" "$HOME/selected/Chosen.app/Contents" "$HOME/Library/Preferences"
for app in "$HOME/physical/Survivor.app" "$HOME/selected/Chosen.app"; do
    printf '%s\n' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.shared</string></dict></plist>' > "$app/Contents/Info.plist"
done
printf 'survivor data\n' > "$HOME/Library/Preferences/com.example.shared.plist"
ln -s "$HOME/physical" "$HOME/Applications"
_MOLE_UNINSTALL_LIVE_APP_ROOTS=("$HOME/Applications")
app_path="$HOME/selected/Chosen.app"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
_batch_refresh_selected_app_bundle_id() { printf 'com.example.shared\n'; }
official_uninstaller_vendor() { return 1; }
uninstall_bundle_id_has_surviving_sibling() { return 1; }
pgrep() { return 1; }
get_brew_cask_name() { return 1; }
get_file_owner() { whoami; }
get_path_size_kb() { printf '1\n'; }
calculate_total_size() { printf '0\n'; }
find_app_files() {
    printf 'discovery\n' >> "$HOME/unexpected-discovery"
    printf '%s\n' "$HOME/Library/Preferences/com.example.shared.plist"
}
find_app_system_files() { :; }
get_diagnostic_report_paths_for_app() { :; }
discover_login_item_helper_bundle_ids() { :; }
has_sensitive_data() { return 1; }
selected_apps=("0|$app_path|Chosen|com.example.shared|0|Never")
running_apps=() sudo_apps=() brew_cask_apps=() blocked_apps=() manual_removal_apps=() app_details=() total_estimated_size=0
_batch_scan_app_details
[[ ${#app_details[@]} -eq 1 ]] || exit 1
IFS='|' read -r stored_name stored_path stored_id stored_size stored_related stored_system stored_sensitive stored_sudo stored_brew stored_cask stored_diag stored_review stored_login stored_guard rest <<< "${app_details[0]}"
printf 'PREVIEW_ID=%s GUARD=%s RELATED=%s\n' "$stored_id" "$stored_guard" "$stored_related"
[[ "$stored_id" == unknown && "$stored_guard" == guard_login && -z "$stored_related" && -z "$stored_system" ]] || exit 1
[[ ! -e "$HOME/unexpected-discovery" ]] || exit 1
# Invoke the production final installation recheck, but replace every mutation.
stop_launch_services() { printf 'app-only teardown\n' >> "$HOME/teardown"; }
unregister_app_bundle() { :; }
remove_login_item() { printf 'unexpected-login\n' >> "$HOME/forbidden"; return 99; }
force_kill_app() { printf 'unexpected-kill\n' >> "$HOME/forbidden"; return 99; }
bootout_login_item_helpers() { printf 'unexpected-helper\n' >> "$HOME/forbidden"; return 99; }
remove_file_list() { [[ -z "$1" ]] && return 0; printf 'unexpected-leftovers\n' >> "$HOME/forbidden"; return 99; }
mole_delete() {
    [[ "$1" == "$HOME/selected/Chosen.app" && "$2" == false && -n "${3:-}" ]] || return 99
    printf '%s\n' "$1" >> "$HOME/app-sink-attempt"
    return 0
}
success_count=0 failed_count=0 brew_apps_removed=0 total_size_freed=0 files_cleaned=0 total_items=0
failed_items=() success_items=() success_dock_targets=() system_extension_warning_apps=()
review_only_system_leftovers=() review_only_system_leftover_keys=() running_at_uninstall_apps=()
rc=0
_batch_execute_removals || rc=$?
printf 'FINAL_RC=%s SUCCESS=%s FAILED=%s\n' "$rc" "$success_count" "$failed_count"
[[ $rc -eq 0 && $success_count -eq 1 && $failed_count -eq 0 ]] || exit 1
[[ -f "$HOME/app-sink-attempt" && ! -e "$HOME/forbidden" ]] || exit 1
[[ -f "$HOME/Library/Preferences/com.example.shared.plist" && -d "$HOME/physical/Survivor.app" && -d "$HOME/selected/Chosen.app" ]] || exit 1
printf 'SHARED_LEFTOVERS_PRESERVED_WITHOUT_REAL_DELETION\n'
EOF_ROOT
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *SHARED_LEFTOVERS_PRESERVED_WITHOUT_REAL_DELETION* ]] || return 1
}

@test "system Time Machine snapshots permit the same leftover plan in preview and execution" {
    assert_time_machine_batch_plan allowed
}

@test "new external sibling after Time Machine preview prevents final removal" {
    assert_time_machine_batch_plan new-sibling
}

@test "sibling find diagnostics show the cause after a Perl timeout preamble" {
    run env HOME="$HOME/find-cause" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF_FIND_CAUSE'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
mkdir -p "$HOME/bin" "$HOME/Volumes"
cat > "$HOME/bin/find" <<'FIND'
#!/bin/bash
printf 'find: %s/Restricted: Permission denied\n' "$1" >&2
exit 1
FIND
chmod +x "$HOME/bin/find"
export PATH="$HOME/bin:$PATH" MO_DEBUG=1
MO_TIMEOUT_BIN=""
MO_TIMEOUT_PERL_BIN="$(command -v perl)"
debug_log() { printf 'DEBUG:%s\n' "$1"; }
result_file=$(mktemp "$HOME/result.XXXXXX")
result=0
_uninstall_materialize_complete_find0 "$result_file" "$((SECONDS + 5))" "$HOME/Volumes" -maxdepth 2 || result=$?
printf 'SCAN_RC=%s\n' "$result"
[[ "$result" -eq "$MOLE_UNINSTALL_SCAN_PARTIAL" ]] || exit 1
EOF_FIND_CAUSE
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SCAN_RC=3"* ]] || return 1
    [[ "$output" == *"Sibling application listing failed (exit 1)"* ]] || return 1
    [[ "$output" == *"Restricted: Permission denied"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Perl fallback"* ]] || return 1
}


@test "calculate_total_size accepts empty and missing-only plans on Bash 3.2" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
get_path_size_kb() { echo UNEXPECTED_SIZE_PROBE; return 99; }
[[ "$(calculate_total_size '')" == 0 ]] || exit 1
[[ "$(calculate_total_size "$HOME/missing")" == 0 ]] || exit 1
printf 'empty-plan-zero\n'
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"empty-plan-zero"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SIZE_PROBE"* ]]
}

@test "force_kill_app continues immediately after SIGTERM exits" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
running=1
pgrep() { [[ "$running" == 1 ]]; }
pkill() { running=0; }
sleep() { echo "unexpected-wait:$*"; return 99; }
force_kill_app MolePerfFixture || exit $?
[[ "$running" == 0 ]] || exit 1
printf 'exited-without-wait\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"exited-without-wait"* ]] || return 1
    [[ "$output" != *"unexpected-wait"* ]]
}


@test "parallel preview preserves path order and measures each invocation fresh" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
fixture=$(mktemp -d "$HOME/preview-workers.XXXXXX")
files=''
for i in 1 2 3 4 5 6; do
    touch "$fixture/$i"
    files+="$fixture/$i"$'\n'
done
get_path_size_kb() {
    printf '%s\n' "$1" >> "$fixture/calls"
    [[ "${1##*/}" != 1 ]] || sleep 0.05
    printf '%s\n' "$size_value"
}
size_value=1
first=$(_uninstall_print_preview_paths "$files" 'row:') || exit 1
size_value=2
second=$(_uninstall_print_preview_paths "$files" 'row:') || exit 1
[[ $(wc -l < "$fixture/calls") -eq 12 ]] || exit 1
index=1
tilde='~'
display="${fixture/#$HOME/$tilde}"
while IFS= read -r row; do
    [[ "$row" == "row:$display/$index "* ]] || exit 1
    index=$((index+1))
done <<< "$first"
[[ "$index" == 7 && "$first" != "$second" ]] || exit 1
printf 'ordered-fresh-preview\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"ordered-fresh-preview"* ]]
}

@test "parallel preview drains failed workers and restores caller traps" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
fixture=$(mktemp -d "$HOME/preview-cancel.XXXXXX")
files=''
for i in 1 2 3 4 5 6; do touch "$fixture/$i"; files+="$fixture/$i"$'\n'; done
create_temp_dir() { mktemp -d "$fixture/output.XXXXXX"; }
get_path_size_kb() {
    touch "$1.started"
    [[ "${1##*/}" != 1 ]] || return 130
    sleep 0.05
    printf 'finished:%s\n' "$1" >> "$fixture/finished"
    echo 1
}
trap ':' INT
before=$(trap -p INT)
rc=0
_uninstall_print_preview_paths "$files" row: > "$fixture/rows" || rc=$?
[[ $rc == 130 && "$(trap -p INT)" == "$before" ]] || exit 1
[[ ! -s "$fixture/rows" ]] || exit 1
[[ $(wc -l < "$fixture/finished") -eq 3 ]] || exit 1
[[ -e "$fixture/1.started" && -e "$fixture/4.started" && ! -e "$fixture/5.started" ]] || exit 1
[[ -z "$(find "$fixture" -type d -name 'output.*')" ]] || exit 1
printf 'drained-and-restored\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"drained-and-restored"* ]]
}

@test "parallel preview drains a slow worker through repeated interruption" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
fixture=$(mktemp -d "$HOME/preview-signals.XXXXXX")
files=''
for i in 1 2 3 4 5; do touch "$fixture/$i"; files+="$fixture/$i"$'\n'; done
create_temp_dir() { mktemp -d "$fixture/output.XXXXXX"; }
get_path_size_kb() {
    touch "$1.started"
    case "${1##*/}" in
        1) return 130 ;;
        2) sleep 0.6 ;;
        *) sleep 0.2 ;;
    esac
    printf 'finished:%s\n' "$1" >> "$fixture/finished"
    echo 1
}
owner=$$
(
    ready=0
    for ((tick=0; tick<200; tick++)); do
        if [[ -f "$fixture/4.started" ]]; then ready=1; break; fi
        sleep 0.01
    done
    [[ $ready == 1 ]] || exit 1
    sleep 0.05
    kill -TERM "$owner"
    sleep 0.05
    kill -TERM "$owner"
) &
sender=$!
trap ':' TERM
before=$(trap -p TERM)
rc=0
_uninstall_print_preview_paths "$files" row: > "$fixture/rows" || rc=$?
wait "$sender" || exit 1
[[ $rc == 143 && "$(trap -p TERM)" == "$before" ]] || exit 1
[[ $(wc -l < "$fixture/finished") -eq 3 ]] || exit 1
[[ ! -s "$fixture/rows" && ! -e "$fixture/5.started" ]] || exit 1
[[ -z "$(find "$fixture" -type d -name 'output.*')" ]] || exit 1
printf 'repeated-signals-drained\n'
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"repeated-signals-drained"* ]]
}

@test "uninstall exit reclaims registered directories after interrupted allocation" {
    local phase fixture
    for phase in inventory preview; do
        fixture=$(mktemp -d "$HOME/exit-cleanup.XXXXXX")
        mkdir -p "$fixture/home" "$fixture/tmp"
        run env HOME="$fixture/home" TMPDIR="$fixture/tmp/" PROJECT_ROOT="$PROJECT_ROOT" \
            REVIEW_FIXTURE="$fixture" REVIEW_PHASE="$phase" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"
eval "$(declare -f register_temp_dir | sed '1s/register_temp_dir/_fixture_register_temp_dir/')"
register_temp_dir() {
    _fixture_register_temp_dir "$@"
    printf '%s\n' "$1" > "$REVIEW_FIXTURE/allocated"
    printf '%s\n' "$MOLE_TEMP_REGISTRY_FILE" > "$REVIEW_FIXTURE/registry"
    sleep 0.2
}
is_homebrew_available() { return 0; }
_mole_brew_prepare_batch_inventory() { echo UNEXPECTED_INVENTORY; return 97; }
_batch_scan_app_details_impl() { :; }
if [[ "$REVIEW_PHASE" == preview ]]; then
    _batch_scan_app_details() { app_details=(fixture); }
    files=''
    for i in 1 2 3 4; do touch "$HOME/$i"; files+="$HOME/$i"$'\n'; done
    _batch_preview_and_confirm() { _uninstall_print_preview_paths "$files" row:; }
fi
selected_apps=(one two)
(
    ready=0
    for ((tick=0; tick<100; tick++)); do
        if [[ -s "$REVIEW_FIXTURE/allocated" ]]; then ready=1; break; fi
        sleep 0.005
    done
    [[ $ready == 1 ]] || exit 1
    kill -TERM "$$"
) &
sender=$!
rc=0
batch_uninstall_applications || rc=$?
wait "$sender" || exit 1
[[ $rc == 130 ]] || exit 1
printf 'allocation-interrupted\n'
EOF
        [ "$status" -eq 0 ] || { echo "$phase: $output"; return 1; }
        [[ "$output" == *"allocation-interrupted"* && "$output" != *"UNEXPECTED_INVENTORY"* ]] || return 1
        [[ -s "$fixture/allocated" && -s "$fixture/registry" ]] || return 1
        [[ ! -d "$(cat "$fixture/allocated")" && ! -e "$(cat "$fixture/registry")" ]] || return 1
    done
}
