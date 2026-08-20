#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-apps-module.XXXXXX")"
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

@test "clean_ds_store_tree reports dry-run summary" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true NO_COLOR= /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
start_inline_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_file_size() { echo $((2 * 1024 * 1024 * 1024)); }
bytes_to_human() { echo "2.15GB"; }
files_cleaned=0
total_size_cleaned=0
total_items=0
mkdir -p "$HOME/test_ds"
touch "$HOME/test_ds/.DS_Store"
clean_ds_store_tree "$HOME/test_ds" "DS test"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DS test"* ]] || return 1
    [[ "$output" == *$'\033[0;33m→\033[0m'* ]]
}

@test "clean_ds_store_tree uses green for successful cleanups" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false NO_COLOR= /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
start_inline_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
get_file_size() { echo 512; }
bytes_to_human() { echo "512B"; }
files_cleaned=0
total_size_cleaned=0
total_items=0
mkdir -p "$HOME/test_ds"
touch "$HOME/test_ds/.DS_Store"
clean_ds_store_tree "$HOME/test_ds" "DS test"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DS test"* ]] || return 1
    [[ "$output" == *$'\033[0;32m✓\033[0m'* ]]
}

@test "scan_installed_apps uses cache when fresh" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
mkdir -p "$HOME/.cache/mole"
printf '%s\n%s\n' "com.example.App" "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" > "$HOME/.cache/mole/installed_apps_cache"
get_file_mtime() { date +%s; }
debug_log() { :; }
create_temp_dir() { echo "UNEXPECTED_SCAN"; return 1; }
scan_installed_apps "$HOME/installed.txt"
cat "$HOME/installed.txt"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == "com.example.App" ]] || return 1
    [[ "$output" != *"UNEXPECTED_SCAN"* ]] || return 1
    [[ "$output" != *"mole-installed-apps-cache"* ]]
}

@test "scan_installed_apps fails closed when a complete cache cannot reach scan output" {
    run env HOME="$HOME/cache-output-failure" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/.cache/mole" "$HOME/installed-output"
printf '%s\n%s\n' "com.example.App" "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" > "$HOME/.cache/mole/installed_apps_cache"
get_file_mtime() { date +%s; }
debug_log() { :; }
scan_status=0
scan_installed_apps "$HOME/installed-output" || scan_status=$?
[[ $scan_status -ne 0 ]]
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "scan_installed_apps rejects the previous complete-cache schema and finds the installed app" {
    run env HOME="$HOME/unmarked-cache" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/.cache/mole" "$HOME/Applications/Present.app/Contents"
printf '%s\n%s\n' "com.example.Missing" "# mole-installed-apps-cache:v2:complete" > "$HOME/.cache/mole/installed_apps_cache"
cat > "$HOME/Applications/Present.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.Present</string>
</dict></plist>
PLIST
get_file_mtime() { date +%s; }
debug_log() { :; }
scan_installed_apps "$HOME/installed.txt"
grep -Fx "com.example.Present" "$HOME/installed.txt"
if grep -Fx "com.example.Missing" "$HOME/installed.txt"; then
    exit 1
fi
printf 'CACHE_SCHEMA_REBUILT:com.example.Present\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"com.example.Present"* ]] || return 1
    [[ "$output" != *"com.example.Missing"* ]]
}

@test "scan_installed_apps rejects a cache timestamp from the future" {
    run env HOME="$HOME/future-cache" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/.cache/mole" "$HOME/Applications/FuturePresent.app/Contents"
printf '%s\n%s\n' "com.example.FutureStale" "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" > "$HOME/.cache/mole/installed_apps_cache"
cat > "$HOME/Applications/FuturePresent.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.FuturePresent</string>
</dict></plist>
PLIST
get_file_mtime() { echo $(( $(date +%s) + 60 )); }
debug_log() { :; }
scan_installed_apps "$HOME/installed.txt"
grep -Fx "com.example.FuturePresent" "$HOME/installed.txt"
if grep -Fx "com.example.FutureStale" "$HOME/installed.txt"; then
    exit 1
fi
printf 'FUTURE_CACHE_REBUILT:com.example.FuturePresent\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"com.example.FuturePresent"* ]] || return 1
    [[ "$output" != *"com.example.FutureStale"* ]]
}

@test "scan_installed_apps ignores same-directory staging files" {
    run env HOME="$HOME/staged-cache" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/.cache/mole" "$HOME/Applications/StagePresent.app/Contents"
printf '%s\n%s\n' "com.example.PartialStage" "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" > "$HOME/.cache/mole/installed_apps_cache.tmp.interrupted"
cat > "$HOME/Applications/StagePresent.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.StagePresent</string>
</dict></plist>
PLIST
debug_log() { :; }
scan_installed_apps "$HOME/installed.txt"
grep -Fx "com.example.StagePresent" "$HOME/installed.txt"
if grep -Fx "com.example.PartialStage" "$HOME/installed.txt"; then
    exit 1
fi
printf 'STAGED_CACHE_IGNORED:com.example.StagePresent\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"com.example.StagePresent"* ]] || return 1
    [[ "$output" != *"com.example.PartialStage"* ]]
}

@test "scan_installed_apps keeps the previous complete cache when publish fails" {
    run env HOME="$HOME/publish-failure" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

cache_file="$HOME/.cache/mole/installed_apps_cache"
mkdir -p "$(dirname "$cache_file")" "$HOME/Applications/CurrentScan.app/Contents"
printf '%s\n%s\n' "com.example.Previous" "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" > "$cache_file"
cat > "$HOME/Applications/CurrentScan.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.CurrentScan</string>
</dict></plist>
PLIST
get_file_mtime() { echo 0; }
debug_log() { :; }
mv() { return 73; }

scan_installed_apps "$HOME/installed.txt"
grep -Fx "com.example.CurrentScan" "$HOME/installed.txt"
grep -Fx "com.example.Previous" "$cache_file"
[[ "$(tail -n 1 "$cache_file")" == "$INSTALLED_APPS_CACHE_COMPLETE_MARKER" ]]
if find "$(dirname "$cache_file")" -maxdepth 1 -name 'installed_apps_cache.tmp.*' -print -quit | grep -q .; then
    exit 1
fi
printf 'PUBLISH_FAILURE_CURRENT:com.example.CurrentScan\n'
printf 'PUBLISH_FAILURE_PREVIOUS:com.example.Previous\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"com.example.CurrentScan"* ]] || return 1
    [[ "$output" == *"com.example.Previous"* ]]
}

@test "scan_installed_apps fails closed when a discovered app has no readable bundle id" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# HOME is shared across tests in this file; drop any cache a prior test wrote
# so this one exercises a real scan rather than reading a stale cache.
rm -f "$HOME/.cache/mole/installed_apps_cache"

# A plist that cannot be parsed at all. This is the case that has to fail
# closed: the app may well have a CFBundleIdentifier that simply could not be
# read, and leaving that id out of the installed list is what turns a live
# app's data into an apparent orphan. A plist that parses and merely lacks the
# key is a different thing and is covered by its own test, since a bundle with
# no id owns no bundle-id-named leftovers and cannot be mistaken for one.
mkdir -p "$HOME/Applications/FakeApp.app/Contents"
printf 'not a property list at all' > "$HOME/Applications/FakeApp.app/Contents/Info.plist"

# Create a valid .app alongside it
mkdir -p "$HOME/Applications/GoodApp.app/Contents"
cat > "$HOME/Applications/GoodApp.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.GoodApp</string>
</dict>
</plist>
PLIST

debug_log() { :; }
scan_status=0
scan_installed_apps "$HOME/installed.txt" || scan_status=$?
[[ $scan_status -ne 0 ]] || exit 1
[[ ! -e "$HOME/.cache/mole/installed_apps_cache" ]] || exit 1
printf 'APP_METADATA_FAILURE_CLOSED\n'
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"APP_METADATA_FAILURE_CLOSED"* ]] || return 1
}

@test "scan_installed_apps fails closed when every running-app probe fails" {
    local scan_home="$HOME/running-probe-failure"
    rm -rf "$scan_home"
    mkdir -p "$scan_home"

    run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

app_path="$HOME/Applications/ProbeApp.app"
mkdir -p "$app_path/Contents" "$HOME/stub-bin"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.ProbeApp</string>
</dict></plist>
PLIST

cat > "$HOME/stub-bin/find" <<'SH'
#!/bin/sh
if [ "${1:-}" = "$HOME/Applications" ]; then
    printf '%s\n' "$HOME/Applications/ProbeApp.app"
fi
exit 0
SH
for command_name in osascript lsappinfo; do
    cat > "$HOME/stub-bin/$command_name" <<'SH'
#!/bin/sh
exit 64
SH
done
chmod +x "$HOME/stub-bin/find" "$HOME/stub-bin/osascript" "$HOME/stub-bin/lsappinfo"
export PATH="$HOME/stub-bin:/usr/bin:/bin"

debug_log() { :; }
scan_status=0
scan_installed_apps "$HOME/installed.txt" || scan_status=$?
[[ $scan_status -ne 0 ]] || exit 1
[[ ! -e "$HOME/.cache/mole/installed_apps_cache" ]] || exit 1
printf 'AUXILIARY_PROBE_FAILURE_CLOSED\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"AUXILIARY_PROBE_FAILURE_CLOSED"* ]] || return 1
}

@test "scan_installed_apps keeps find traversal options before predicates" {
    rm -f "$HOME/.cache/mole/installed_apps_cache"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

stub_dir="$HOME/stub-bin"
mkdir -p "$stub_dir" "$HOME/Applications/Ordered.app/Contents"
cat > "$stub_dir/find" <<'SH'
#!/bin/sh
root="$1"
shift
case "$root" in
    "$HOME/Library/LaunchAgents" | "/Library/LaunchAgents") exit 0 ;;
esac
if [ "${1:-}" != "-maxdepth" ] ||
    [ "${2:-}" != "3" ] ||
    [ "${3:-}" != "-type" ] ||
    [ "${4:-}" != "d" ] ||
    [ "${5:-}" != "-name" ] ||
    [ "${6:-}" != "*.app" ]; then
    exit 64
fi

if [ "$root" = "$HOME/Applications" ]; then
    printf '%s\n' "$HOME/Applications/Ordered.app"
fi
SH
chmod +x "$stub_dir/find"

cat > "$HOME/Applications/Ordered.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.Ordered</string>
</dict>
</plist>
PLIST

debug_log() { :; }
export PATH="$stub_dir:$PATH"
scan_installed_apps "$HOME/installed.txt"
cat "$HOME/installed.txt"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"com.example.Ordered"* ]]
}

@test "scan_installed_apps aggregates LaunchAgent bundle names without scratch paths" {
    run env HOME="$HOME/agent-scan" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/Applications/AgentOwner.app/Contents" "$HOME/Library/LaunchAgents"
cat > "$HOME/Applications/AgentOwner.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.AgentOwner</string>
</dict></plist>
PLIST
touch "$HOME/Library/LaunchAgents/com.example.Agent.plist"
debug_log() { :; }

scan_installed_apps "$HOME/installed.txt"
grep -qFx 'com.example.AgentOwner' "$HOME/installed.txt"
grep -qFx 'com.example.Agent' "$HOME/installed.txt"
if grep -qF '/Library/LaunchAgents/com.example.Agent.plist' "$HOME/installed.txt"; then
    exit 1
fi
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "scan_installed_apps fails closed when scan result aggregation fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

rm -f "$HOME/.cache/mole/installed_apps_cache"
stub_dir="$HOME/stub-bin-aggregation"
mkdir -p "$stub_dir" "$HOME/Applications"
cat > "$stub_dir/find" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$stub_dir/lsappinfo" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$stub_dir/find" "$stub_dir/lsappinfo"
export PATH="$stub_dir:$PATH"

aggregate_failure_seen="$HOME/aggregate-failure-seen"
cat() {
    local input
    for input in "$@"; do
        case "$input" in
            */apps_*.txt)
                : > "$aggregate_failure_seen"
                return 73
                ;;
        esac
    done
    command cat "$@"
}
debug_log() { :; }

scan_status=0
scan_installed_apps "$HOME/installed.txt" || scan_status=$?
[[ -e "$aggregate_failure_seen" ]] || exit 1
[[ $scan_status -ne 0 ]] || exit 1
printf 'AGGREGATION_FAILED_CLOSED\n'
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"AGGREGATION_FAILED_CLOSED"* ]] || return 1
}

@test "scan_installed_apps leaves tracked scratch cleanup to the temp registry (#1313)" {
    local scan_home="$HOME/registry-scan"
    rm -rf "$scan_home"
    mkdir -p "$scan_home"

    run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail

mkdir -p "$HOME/mole-tmp"
export TMPDIR="$HOME/mole-tmp"

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

rm -f "$HOME/.cache/mole/installed_apps_cache"

stub_dir="$HOME/stub-bin-registry"
mkdir -p "$stub_dir"
cat > "$stub_dir/find" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$stub_dir/lsappinfo" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$stub_dir/find" "$stub_dir/lsappinfo"
export PATH="$stub_dir:$PATH"

remove_calls="$HOME/safe-remove-calls"
: > "$remove_calls"
safe_remove() {
    printf '%s\n' "$1" >> "$remove_calls"
    return 1
}
debug_log() {
    printf 'DEBUG:%s\n' "$*"
}

scan_installed_apps "$HOME/installed.txt"

[[ -s "$MOLE_TEMP_REGISTRY_FILE" ]] || exit 1
scan_tmp_dir=$(head -n 1 "$MOLE_TEMP_REGISTRY_FILE")
[[ -d "$scan_tmp_dir" ]] || exit 1
[[ ! -s "$remove_calls" ]] || exit 1

outside_file="$HOME/outside-temp-root"
touch "$outside_file"
cleanup_temp_files

[[ ! -e "$scan_tmp_dir" ]] || exit 1
[[ -e "$outside_file" ]] || exit 1
printf 'REGISTRY_CLEANUP_OK\n'
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEBUG:Scanned 0 unique applications"* ]] || return 1
    [[ "$output" == *"REGISTRY_CLEANUP_OK"* ]] || return 1
}

@test "clean_orphaned_app_data fails closed when the installed app scan fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/Library/Caches/com.example.LiveApp"
touch -t "$(date -v-31d +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.example.LiveApp"

scan_installed_apps() {
    : > "$1"
    return 1
}
mdfind() { return 0; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { printf '1\n'; }
safe_clean() {
    : > "$HOME/safe-clean-called"
    return 0
}
start_section_spinner() { :; }
stop_section_spinner() { :; }

set +e
clean_orphaned_app_data
rc=$?
set -e

[[ $rc -eq 0 ]] || exit 1
[[ ! -e "$HOME/safe-clean-called" ]] || exit 1
printf 'SCAN_FAILURE_CLOSED\n'
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped: Unable to scan installed applications"* ]] || return 1
    [[ "$output" == *"SCAN_FAILURE_CLOSED"* ]]
}

@test "clean_orphaned_app_data fails closed when an app directory find fails" {
    local scan_home="$HOME/find-failure-scan"
    rm -rf "$scan_home"
    mkdir -p "$scan_home"

    run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/Applications/LiveApp.app" \
    "$HOME/Applications/Partial.app/Contents" \
    "$HOME/Library/Caches/com.example.LiveApp"
touch -t "$(date -v-31d +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.example.LiveApp"
rm -f "$HOME/.cache/mole/installed_apps_cache"

cat > "$HOME/Applications/Partial.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.Partial</string>
</dict>
</plist>
PLIST

stub_dir="$HOME/stub-bin-find-failure"
mkdir -p "$stub_dir"
cat > "$stub_dir/find" <<'SH'
#!/bin/sh
if [ "${1:-}" = "$HOME/Applications" ]; then
    exit 64
fi
if [ "${1:-}" = "/Applications" ]; then
    printf '%s\n' "$HOME/Applications/Partial.app"
fi
exit 0
SH
cat > "$stub_dir/lsappinfo" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$stub_dir/find" "$stub_dir/lsappinfo"
export PATH="$stub_dir:$PATH"

mdfind() { return 0; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { printf '1\n'; }
safe_clean() {
    : > "$HOME/safe-clean-called"
    return 0
}
start_section_spinner() { :; }
stop_section_spinner() { :; }

set +e
clean_orphaned_app_data
rc=$?
set -e

[[ $rc -eq 0 ]] || exit 1
[[ ! -e "$HOME/safe-clean-called" ]] || exit 1
[[ ! -e "$HOME/.cache/mole/installed_apps_cache" ]] || exit 1
printf 'APP_DIRECTORY_SCAN_FAILURE_CLOSED\n'
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped: Unable to scan installed applications"* ]] || return 1
    [[ "$output" == *"APP_DIRECTORY_SCAN_FAILURE_CLOSED"* ]]
}

@test "clean_orphaned_app_data skips gracefully under errexit and names the unreadable bundle" {
    local scan_home="$HOME/errexit-scan"
    rm -rf "$scan_home"
    mkdir -p "$scan_home"

    run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

mkdir -p "$HOME/Applications/Broken.app/Contents" \
    "$HOME/Library/Caches/com.example.LiveApp"
touch -t "$(date -v-31d +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.example.LiveApp"
rm -f "$HOME/.cache/mole/installed_apps_cache"

stub_dir="$HOME/stub-bin-errexit-scan"
mkdir -p "$stub_dir"
cat > "$stub_dir/find" <<'SH'
#!/bin/sh
if [ "${1:-}" = "$HOME/Applications" ]; then
    printf '%s\n' "$HOME/Applications/Broken.app"
fi
exit 0
SH
cat > "$stub_dir/lsappinfo" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$stub_dir/find" "$stub_dir/lsappinfo"
export PATH="$stub_dir:$PATH"

mdfind() { return 0; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { printf '1\n'; }
safe_clean() {
    : > "$HOME/safe-clean-called"
    return 0
}
start_section_spinner() { :; }
stop_section_spinner() { :; }

# No set +e wrapper: the production section window is the only reason a bare
# scan failure did not abort before this change, and a future caller outside
# that window must still reach the graceful skip.
clean_orphaned_app_data

[[ ! -e "$HOME/safe-clean-called" ]] || exit 1
printf 'ERREXIT_SCAN_FAILURE_CLOSED\n'
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped: Unable to scan installed applications (Broken.app)"* ]] || return 1
    [[ "$output" == *"ERREXIT_SCAN_FAILURE_CLOSED"* ]]
}

@test "clean_orphaned_app_data renders hostile unreadable bundle names as inert text" {
    local scan_home="$HOME/control-name-scan"
    rm -rf "$scan_home"
    mkdir -p "$scan_home"

    run env HOME="$scan_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 NO_COLOR=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

bad_name=$'Bad\\033[2J-\033[2J.app'
mkdir -p "$HOME/Applications/$bad_name/Contents" \
    "$HOME/Library/Caches/com.example.LiveApp"
touch -t "$(date -v-31d +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.example.LiveApp"

stub_dir="$HOME/stub-bin-control-name"
mkdir -p "$stub_dir"
cat > "$stub_dir/find" <<'SH'
#!/bin/sh
if [ "${1:-}" = "$HOME/Applications" ]; then
    printf '%s\n' "$HOME/Applications/$BAD_APP_NAME"
fi
exit 0
SH
cat > "$stub_dir/lsappinfo" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$stub_dir/find" "$stub_dir/lsappinfo"
export BAD_APP_NAME="$bad_name"
export PATH="$stub_dir:$PATH"

mdfind() { return 0; }
run_with_timeout() { shift; "$@"; }
get_path_size_kb() { printf '1\n'; }
safe_clean() { echo "UNEXPECTED_CLEAN"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
debug_log() { printf 'DEBUG:%s\n' "$*"; }

clean_orphaned_app_data
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *'Bad\033[2J-'* ]] || return 1
    [[ "$output" != *$'\033[2J'* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]]
}

@test "is_bundle_orphaned returns true for old uninstalled bundle" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ORPHAN_AGE_THRESHOLD=30 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
should_protect_data() { return 1; }
get_file_mtime() { echo 0; }
if is_bundle_orphaned "com.example.Old" "$HOME/old" "$HOME/installed.txt"; then
    echo "orphan"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"orphan"* ]]
}

@test "clean_orphaned_app_data skips when no permission" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
rm -rf "$HOME/Library/Caches"
clean_orphaned_app_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No permission"* ]]
}

@test "clean_orphaned_app_data handles paths with spaces correctly" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Mock scan_installed_apps - return empty (no installed apps)
scan_installed_apps() {
    : > "$1"
}

# Mock mdfind to return empty (no app found)
mdfind() {
    return 0
}

# Ensure local function mock works even if timeout/gtimeout is installed
run_with_timeout() { shift; "$@"; }

# Mock safe_clean (normally from bin/clean.sh)
safe_clean() {
    rm -rf "$1"
    return 0
}
bundle_has_installed_app() { return 1; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" "$1" || return $?
    safe_clean "$@"
}

# Create required Library structure for permission check
mkdir -p "$HOME/Library/Caches"

# Create test structure with spaces in path (old modification time: 31 days ago)
mkdir -p "$HOME/Library/Saved Application State/com.test.orphan.savedState"
# Create a file with some content so directory size > 0
echo "test data" > "$HOME/Library/Saved Application State/com.test.orphan.savedState/data.plist"
# Set modification time to 31 days ago (older than 30-day threshold)
touch -t "$(date -v-31d +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 days ago' +%Y%m%d%H%M.%S)" "$HOME/Library/Saved Application State/com.test.orphan.savedState" 2>/dev/null || true

# Disable spinner for test
start_section_spinner() { :; }
stop_section_spinner() { :; }

# Run cleanup
clean_orphaned_app_data

# Verify path with spaces was handled correctly (not split into multiple paths)
if [[ -d "$HOME/Library/Saved Application State/com.test.orphan.savedState" ]]; then
    echo "ERROR: Orphaned savedState not deleted"
    exit 1
else
    echo "SUCCESS: Orphaned savedState deleted correctly"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SUCCESS"* ]]
}

@test "clean_orphaned_app_data only counts successful deletions" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Mock scan_installed_apps - return empty
scan_installed_apps() {
    : > "$1"
}

# Mock mdfind to return empty (no app found)
mdfind() {
    return 0
}

# Ensure local function mock works even if timeout/gtimeout is installed
run_with_timeout() { shift; "$@"; }

# Create required Library structure for permission check
mkdir -p "$HOME/Library/Caches"

# Create test files (old modification time: 31 days ago)
mkdir -p "$HOME/Library/Caches/com.test.orphan1"
mkdir -p "$HOME/Library/Caches/com.test.orphan2"
# Create files with content so size > 0
echo "data1" > "$HOME/Library/Caches/com.test.orphan1/data"
echo "data2" > "$HOME/Library/Caches/com.test.orphan2/data"
# Set modification time to 31 days ago
touch -t "$(date -v-31d +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 days ago' +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.test.orphan1" 2>/dev/null || true
touch -t "$(date -v-31d +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 days ago' +%Y%m%d%H%M.%S)" "$HOME/Library/Caches/com.test.orphan2" 2>/dev/null || true

# Mock safe_clean to fail on first item, succeed on second
safe_clean() {
    if [[ "$1" == *"orphan1"* ]]; then
        return 1  # Fail
    else
        rm -rf "$1"
        return 0  # Succeed
    fi
}
bundle_has_installed_app() { return 1; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" "$1" || return $?
    safe_clean "$@"
}

# Disable spinner
start_section_spinner() { :; }
stop_section_spinner() { :; }

# Run cleanup
clean_orphaned_app_data

# Verify first item still exists (safe_clean failed)
if [[ -d "$HOME/Library/Caches/com.test.orphan1" ]]; then
    echo "PASS: Failed deletion preserved"
fi

# Verify second item deleted
if [[ ! -d "$HOME/Library/Caches/com.test.orphan2" ]]; then
    echo "PASS: Successful deletion removed"
fi

# Check that output shows correct count (only 1, not 2)
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: Failed deletion preserved"* ]] || return 1
    [[ "$output" == *"PASS: Successful deletion removed"* ]]
}

@test "clean_orphaned_app_data uses dry-run wording for orphaned summary (#1192)" {
    local test_home="$HOME/dry-run-orphan-summary"
    rm -rf "$test_home"
    mkdir -p "$test_home"

    run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() {
    : > "$1"
}

is_bundle_orphaned() {
    return 0
}

is_claude_vm_bundle_orphaned() {
    return 1
}

safe_clean() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    rm -rf "$1"
    return 0
}
bundle_has_installed_app() { return 1; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" "$1" || return $?
    safe_clean "$@"
}

get_path_size_kb() {
    echo 2048
}

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }

mkdir -p "$HOME/Library/Caches/com.test.orphan-dry-run"
echo "data" > "$HOME/Library/Caches/com.test.orphan-dry-run/data"

clean_orphaned_app_data
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Would clean 1 items, about 2.0MB"* ]] || return 1
    [[ "$output" != *"Cleaned 1 items"* ]] || return 1
    [ -d "$test_home/Library/Caches/com.test.orphan-dry-run" ] || return 1
}

@test "clean_orphaned_app_data removes orphaned Claude VM bundle" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() {
    : > "$1"
}

mdfind() {
    return 0
}

pgrep() {
    return 1
}

run_with_timeout() { shift; "$@"; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 4; }

safe_clean() {
    echo "$2"
    rm -rf "$1"
}
bundle_has_installed_app() { return 1; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" "$1" || return $?
    safe_clean "$@"
}

start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

clean_orphaned_app_data

if [[ ! -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Claude VM removed"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned Claude workspace VM"* ]] || return 1
    [[ "$output" == *"PASS: Claude VM removed"* ]]
}

@test "orphan cleanup guard rejects replacement objects and newly installed apps" {
    local candidate="$HOME/Library/Caches/com.test.raced-orphan"
    mkdir -p "$candidate"
    printf 'original\n' > "$candidate/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

candidate="$HOME/Library/Caches/com.test.raced-orphan"
orphan_cleanup_candidate_snapshot "$candidate"
_ORPHAN_CLEANUP_EXPECTED_IDENTITY="$_ORPHAN_CANDIDATE_IDENTITY"
_ORPHAN_CLEANUP_EXPECTED_PARENT="$_ORPHAN_CANDIDATE_PARENT"
_ORPHAN_CLEANUP_EXPECTED_PARENT_ID="$_ORPHAN_CANDIDATE_PARENT_ID"
_ORPHAN_CLEANUP_EXPECTED_TARGET_ID="$_ORPHAN_CANDIDATE_TARGET_ID"
_ORPHAN_CLEANUP_BUNDLE_ID="com.test.raced-orphan"
_ORPHAN_CLEANUP_KIND="bundle"

mv "$candidate" "$candidate.original"
mkdir -p "$candidate"
printf 'replacement\n' > "$candidate/data"
bundle_has_installed_app() { return 1; }
rc=0
orphan_cleanup_candidate_still_eligible "$candidate" || rc=$?
[[ $rc -eq 1 ]] || exit 1
[[ -f "$candidate/data" && -f "$candidate.original/data" ]] || exit 1

orphan_cleanup_candidate_snapshot "$candidate"
_ORPHAN_CLEANUP_EXPECTED_IDENTITY="$_ORPHAN_CANDIDATE_IDENTITY"
_ORPHAN_CLEANUP_EXPECTED_PARENT="$_ORPHAN_CANDIDATE_PARENT"
_ORPHAN_CLEANUP_EXPECTED_PARENT_ID="$_ORPHAN_CANDIDATE_PARENT_ID"
_ORPHAN_CLEANUP_EXPECTED_TARGET_ID="$_ORPHAN_CANDIDATE_TARGET_ID"
bundle_has_installed_app() { return 0; }
rc=0
orphan_cleanup_candidate_still_eligible "$candidate" || rc=$?
[[ $rc -eq 1 ]] || exit 1
[[ -f "$candidate/data" ]]
EOF

    [ "$status" -eq 0 ]
}

@test "orphan cleanup binds its approved object to the final safe_remove sink" {
    local candidate="$HOME/Library/Caches/com.test.bound-orphan"
    mkdir -p "$candidate"
    printf 'cache\n' > "$candidate/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"

candidate="$HOME/Library/Caches/com.test.bound-orphan"
orphan_cleanup_candidate_snapshot "$candidate"
_ORPHAN_CLEANUP_EXPECTED_IDENTITY="$_ORPHAN_CANDIDATE_IDENTITY"
_ORPHAN_CLEANUP_EXPECTED_PARENT="$_ORPHAN_CANDIDATE_PARENT"
_ORPHAN_CLEANUP_EXPECTED_PARENT_ID="$_ORPHAN_CANDIDATE_PARENT_ID"
_ORPHAN_CLEANUP_EXPECTED_TARGET_ID="$_ORPHAN_CANDIDATE_TARGET_ID"
_ORPHAN_CLEANUP_BUNDLE_ID="com.test.bound-orphan"
_ORPHAN_CLEANUP_KIND="bundle"
DRY_RUN=false
MOLE_CURRENT_COMMAND=clean
MOLE_CLEAN_CANCEL_STATUS=0
files_cleaned=0
total_size_cleaned=0
total_items=0
bundle_has_installed_app() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
get_cleanup_path_size_kb() { printf '1\n'; }
safe_remove() {
    [[ "$1" == "$candidate" ]] || exit 1
    [[ "$5" == "$_ORPHAN_CLEANUP_EXPECTED_PARENT" ]] || exit 1
    [[ "$6" == "$_ORPHAN_CLEANUP_EXPECTED_PARENT_ID" ]] || exit 1
    [[ "$7" == "$_ORPHAN_CLEANUP_EXPECTED_TARGET_ID" ]] || exit 1
    printf 'BOUND_SINK\n'
    return 0
}

safe_clean_guarded orphan_cleanup_candidate_still_eligible \
    "$candidate" "Bound orphan"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"BOUND_SINK"* ]]
}

@test "clean_orphaned_app_data keeps recent Claude VM bundle when Claude lookup misses" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() {
    : > "$1"
}

mdfind() {
    return 0
}

pgrep() {
    return 1
}

run_with_timeout() { shift; "$@"; }
get_file_mtime() { date +%s; }

safe_clean() {
    echo "UNEXPECTED:$2"
    return 1
}

start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

clean_orphaned_app_data

if [[ -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Recent Claude VM kept"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED:Orphaned Claude workspace VM"* ]] || return 1
    [[ "$output" == *"PASS: Recent Claude VM kept"* ]]
}

@test "clean_orphaned_app_data keeps Claude VM bundle when Claude is installed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() {
    echo "com.anthropic.claudefordesktop" > "$1"
}

pgrep() {
    return 1
}

safe_clean() {
    echo "UNEXPECTED:$2"
    return 1
}

start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

clean_orphaned_app_data

if [[ -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Claude VM kept"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED:Orphaned Claude workspace VM"* ]] || return 1
    [[ "$output" == *"PASS: Claude VM kept"* ]]
}


@test "clean_orphaned_app_data honors WHITELIST_PATTERNS for Claude VM bundle" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() { : > "$1"; }
mdfind() { return 0; }
pgrep() { return 1; }
run_with_timeout() { shift; "$@"; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 4; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; rm -rf "$1"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches"
mkdir -p "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
echo "vm data" > "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img"

WHITELIST_PATTERNS=("$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle")

clean_orphaned_app_data

if [[ -d "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" ]]; then
    echo "PASS: Claude VM preserved by whitelist"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]] || return 1
    [[ "$output" == *"PASS: Claude VM preserved by whitelist"* ]]
}

@test "clean_orphaned_app_data honors WHITELIST_PATTERNS for orphaned caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

scan_installed_apps() { : > "$1"; }
is_bundle_orphaned() { return 0; }
is_claude_vm_bundle_orphaned() { return 1; }
mdfind() { return 0; }
pgrep() { return 1; }
run_with_timeout() { shift; "$@"; }
get_file_mtime() { echo 0; }
get_path_size_kb() { echo 4; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; rm -rf "$1"; }
start_section_spinner() { :; }
stop_section_spinner() { :; }

mkdir -p "$HOME/Library/Caches/com.devtool.localbuild"
echo "c" > "$HOME/Library/Caches/com.devtool.localbuild/data"

WHITELIST_PATTERNS=("$HOME/Library/Caches/com.devtool.localbuild")

clean_orphaned_app_data

if [[ -d "$HOME/Library/Caches/com.devtool.localbuild" ]]; then
    echo "PASS: whitelisted orphan cache preserved"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]] || return 1
    [[ "$output" == *"PASS: whitelisted orphan cache preserved"* ]]
}

@test "is_critical_system_component matches known system services" {
    run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/app_protection.sh"
is_critical_system_component "backgroundtaskmanagement" && echo "yes"
is_critical_system_component "SystemSettings" && echo "yes"
EOF
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "yes" ]] || return 1
    [[ "${lines[1]}" == "yes" ]]
}

@test "is_critical_system_component ignores non-system names" {
    run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/app_protection.sh"
if is_critical_system_component "myapp"; then
  echo "bad"
else
  echo "ok"
fi
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == "ok" ]]
}

@test "clean_orphaned_system_services respects dry-run" {
    # Without MOLE_TEST_MODE=0 the sweep early-returns under setup_file's
    # MOLE_TEST_MODE=1, leaving $output empty and both negative assertions true.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=true MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.sogou.test.plist"
# An empty file is never classified as an orphan, so the sweep found nothing and
# the dry-run branch under test never ran.
cat > "$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sogou.test</string>
    <key>Program</key>
    <string>$tmp_dir/missing-binary</string>
</dict>
</plist>
PLIST

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    printf '%s\0' "$tmp_plist"
    return 0
  fi
  if [[ "$1" == "du" ]]; then
    echo "4 $tmp_plist"
    return 0
  fi
  if [[ "$1" == "launchctl" ]]; then
    echo "launchctl-called"
    return 0
  fi
  if [[ "$1" == "rm" ]]; then
    echo "rm-called"
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"rm-called"* ]] || return 1
    [[ "$output" != *"launchctl-called"* ]] || return 1
    # Positive control: every other assertion here is true on empty output, so
    # without this the test cannot distinguish "dry-run behaved" from "nothing ran".
    [[ "$output" == *"Orphaned services · "*" found dry"* ]]
}

@test "clean_orphaned_system_services reports an authorization timeout" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
_mole_bounded_sudo() { return 124; }
note_activity() { printf 'ACTIVITY\n'; }
clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"authorization check timed out, skipped cleanup"* ]] || return 1
    [[ "$output" == *"ACTIVITY"* ]]
}

@test "clean_orphaned_system_services reports a budget exhausted by an empty inventory" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { printf 'ACTIVITY\n'; }
debug_log() { :; }
_mole_bounded_sudo() { return 0; }
_mole_materialize_bounded_sudo_find() {
    : > "$1"
    SECONDS=$((SECONDS + 61))
    return 0
}
clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"scan incomplete, skipped cleanup"* ]] || return 1
    [[ "$output" == *"ACTIVITY"* ]]
}

@test "clean_orphaned_system_services reads unreadable plists through sudo PlistBuddy" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=true MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { echo "debug: $*"; }
should_protect_path() { return 1; }

tmp_dir="$(mktemp -d)"
tmp_binary="$tmp_dir/live-helper"
tmp_plist="$tmp_dir/com.example.live-helper.plist"
touch "$tmp_binary"
cat > "$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.live-helper</string>
    <key>Program</key>
    <string>$tmp_binary</string>
</dict>
</plist>
PLIST
chmod 000 "$tmp_plist"

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  if [[ "$1" == "/usr/libexec/PlistBuddy" ]]; then
    case "$3" in
      "Print :ProgramArguments:0") return 1 ;;
      "Print :Program") printf '%s\n' "$tmp_binary"; return 0 ;;
    esac
    return 1
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Found 1 orphaned"* ]] || return 1
    [[ "$output" != *"Would remove orphaned service"* ]] || return 1
}

@test "clean_orphaned_system_services keeps earlier candidates when a later privileged inventory times out" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { printf 'ACTIVITY\n'; }
debug_log() { :; }

tmp_dir=$(mktemp -d)
tmp_plist="$tmp_dir/com.example.partial.plist"
candidate_trace="$tmp_dir/candidate.trace"
cat > "$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Program</key><string>$tmp_dir/missing</string></dict></plist>
PLIST

scan_calls=0
_mole_materialize_bounded_sudo_find() {
    scan_calls=$((scan_calls + 1))
    printf 'SCAN:%s\n' "$3"
    if [[ "$3" == "/Library/LaunchDaemons" ]]; then
        printf '%s\0' "$tmp_plist" > "$1"
        return 0
    fi
    if [[ "$3" == "/Library/LaunchAgents" ]]; then
        printf '%s\0' "$tmp_dir/partial.plist" > "$1"
        return 124
    fi
    : > "$1"
}
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test) return 1 ;;
        /usr/libexec/PlistBuddy)
            case "${3:-}" in
                "Print :ProgramArguments:0") return 1 ;;
                "Print :Program")
                    printf 'CANDIDATE_PROBED\n' >> "$candidate_trace"
                    printf '%s\n' "$tmp_dir/missing"
                    ;;
            esac
            ;;
        */stat)
            printf 'IDENTITY_CAPTURED\n' >> "$candidate_trace"
            "$@"
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 99
}

clean_orphaned_system_services
printf 'SCAN_CALLS=%s\n' "$scan_calls"
cat "$candidate_trace"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SCAN:/Library/LaunchDaemons"* ]] || return 1
    [[ "$output" == *"CANDIDATE_PROBED"* ]] || return 1
    [[ "$output" == *"IDENTITY_CAPTURED"* ]] || return 1
    [[ "$output" == *"SCAN:/Library/LaunchAgents"* ]] || return 1
    [[ "$output" == *"scan incomplete, skipped cleanup"* ]] || return 1
    [[ "$output" == *"ACTIVITY"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_orphaned_system_services propagates an interrupted plist probe before deletion" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }

tmp_dir=$(mktemp -d)
tmp_plist="$tmp_dir/com.example.interrupt.plist"
trace="$tmp_dir/probe.trace"
touch "$tmp_plist"
_mole_materialize_bounded_sudo_find() {
    if [[ "$3" == "/Library/LaunchDaemons" ]]; then
        printf '%s\0' "$tmp_plist" > "$1"
    else
        : > "$1"
    fi
}
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        /usr/libexec/PlistBuddy)
            printf 'PLIST_PROBE\n' >> "$trace"
            return 130
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 99
}

rc=0
clean_orphaned_system_services || rc=$?
printf 'RC=%s\n' "$rc"
cat "$trace"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]] || return 1
    [[ "$output" == *"PLIST_PROBE"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_orphaned_system_services propagates an interrupted parent-app resolver" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }
should_protect_path() { return 1; }
_privileged_helper_bundle_id_from_binary() { printf 'com.example.helper\n'; }
bundle_has_installed_app() { return 130; }

tmp_dir=$(mktemp -d)
tmp_plist="$tmp_dir/com.example.helper.plist"
touch "$tmp_plist"
_mole_materialize_bounded_sudo_find() {
    if [[ "$3" == "/Library/LaunchDaemons" ]]; then
        printf '%s\0' "$tmp_plist" > "$1"
    else
        : > "$1"
    fi
}
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test) return 0 ;;
        /usr/libexec/PlistBuddy)
            case "${3:-}" in
                "Print :ProgramArguments:0") return 1 ;;
                "Print :Program") printf '/Library/PrivilegedHelperTools/com.example.helper\n' ;;
            esac
            ;;
        /usr/bin/stat) command "$@" ;;
        *) return 0 ;;
    esac
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 99
}

rc=0
clean_orphaned_system_services || rc=$?
printf 'RC=%s\n' "$rc"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_orphaned_system_services propagates an interrupted protect-pattern mdfind" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }
should_protect_path() { return 1; }
run_with_timeout() { shift; "$@"; }
mdfind() {
    printf 'MDFIND_INTERRUPTED\n' >> "$trace"
    return 130
}

tmp_dir=$(mktemp -d)
trace="$tmp_dir/mdfind.trace"
bundle_id=""
if [[ ! -e "/Library/Input Methods/SogouInput.app" ]]; then
    bundle_id="com.sogou.test"
elif [[ ! -e "/Applications/ClashMac.app" ]]; then
    bundle_id="com.clashmac.test"
elif [[ ! -e "/Applications/i4Tools.app" ]]; then
    bundle_id="cn.i4tools.test"
elif [[ ! -e "/Applications/Wireshark.app" ]]; then
    bundle_id="org.wireshark.ChmodBPF"
elif [[ ! -e "/Applications/zoom.us.app" ]]; then
    bundle_id="us.zoom.test"
elif [[ ! -e "/Applications/Docker.app" ]]; then
    bundle_id="com.docker.test"
else
    printf 'No absent protected app fixture is available\n' >&2
    exit 99
fi

tmp_plist="$tmp_dir/$bundle_id.plist"
touch "$tmp_plist"
_mole_materialize_bounded_sudo_find() {
    if [[ "$3" == "/Library/LaunchDaemons" ]]; then
        printf '%s\0' "$tmp_plist" > "$1"
    else
        : > "$1"
    fi
}
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test) return 1 ;;
        /usr/libexec/PlistBuddy)
            case "${3:-}" in
                "Print :ProgramArguments:0") return 1 ;;
                "Print :Program") printf '%s\n' "$tmp_dir/missing" ;;
            esac
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 99
}

rc=0
clean_orphaned_system_services || rc=$?
printf 'RC=%s\n' "$rc"
cat "$trace"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=130"* ]] || return 1
    [[ "$output" == *"MDFIND_INTERRUPTED"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_orphaned_system_services stops before removal when launchctl unload times out" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { printf 'ACTIVITY\n'; }
debug_log() { :; }
should_protect_path() { return 1; }

tmp_dir=$(mktemp -d)
tmp_plist="$tmp_dir/com.example.unload-timeout.plist"
touch "$tmp_plist"
_mole_materialize_bounded_sudo_find() {
    if [[ "$3" == "/Library/LaunchDaemons" ]]; then
        printf '%s\0' "$tmp_plist" > "$1"
    else
        : > "$1"
    fi
}
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test) return 1 ;;
        /usr/libexec/PlistBuddy)
            case "${3:-}" in
                "Print :ProgramArguments:0") return 1 ;;
                "Print :Program") printf '%s\n' "$tmp_dir/missing" ;;
            esac
            ;;
        /usr/bin/stat) command "$@" ;;
        du) printf '4\n' ;;
        launchctl)
            printf 'LAUNCHCTL_TIMEOUT\n'
            return 124
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 99
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"LAUNCHCTL_TIMEOUT"* ]] || return 1
    [[ "$output" == *"unload timed out, stopped cleanup"* ]] || return 1
    [[ "$output" == *"ACTIVITY"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_orphaned_system_services does not unload a plist replaced after classification" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
should_protect_path() { return 1; }
debug_log() { printf '%s\n' "$*"; }

tmp_dir=$(mktemp -d)
tmp_plist="$tmp_dir/com.example.replaced.plist"
replacement="$tmp_dir/replacement.plist"
marker="$tmp_dir/identity-recorded"
touch "$tmp_plist" "$replacement"
_mole_materialize_bounded_sudo_find() {
    if [[ "$3" == "/Library/LaunchDaemons" ]]; then
        printf '%s\0' "$tmp_plist" > "$1"
    else
        : > "$1"
    fi
}
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test) return 1 ;;
        /usr/libexec/PlistBuddy)
            case "${3:-}" in
                "Print :ProgramArguments:0") return 1 ;;
                "Print :Program") printf '%s\n' "$tmp_dir/missing" ;;
            esac
            ;;
        /usr/bin/stat) command "$@" ;;
        du)
            if [[ ! -e "$marker" ]]; then
                touch "$marker"
                rm -f "$tmp_plist"
                mv "$replacement" "$tmp_plist"
            fi
            printf '4\n'
            ;;
        launchctl)
            printf 'UNEXPECTED_UNLOAD\n'
            return 99
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 99
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Keeping changed or no-longer-orphaned service before unload"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_UNLOAD"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]]
}

@test "clean_orphaned_system_services does not count protected skips as cleaned" {
    # setup_file exports MOLE_TEST_MODE=1, under which clean_orphaned_system_services
    # returns immediately and leaves $output empty. Override it as the sibling cases do.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }
should_protect_path() { return 0; }
safe_sudo_remove() {
  echo "unexpected-remove"
  return 0
}

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.sogou.test.plist"
# _plist_is_orphaned needs a Program key pointing at a missing binary; an empty
# file is never classified as an orphan, so the sweep found nothing and this test
# produced no output at all.
cat > "$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sogou.test</string>
    <key>Program</key>
    <string>$tmp_dir/missing-binary</string>
</dict>
</plist>
PLIST

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  if [[ "$1" == "du" ]]; then
    echo "4 $tmp_plist"
    return 0
  fi
  if [[ "$1" == "launchctl" ]]; then
    echo "unexpected-launchctl"
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned services · skipped 1 protected"* ]] || return 1
    [[ "$output" != *"Orphaned services · cleaned"* ]] || return 1
    [[ "$output" != *"unexpected-remove"* ]] || return 1
    [[ "$output" != *"unexpected-launchctl"* ]]
}

# 48ca1090 (#1082) made this sweep call should_protect_path under
# MOLE_UNINSTALL_MODE=1, which deliberately stops consulting DATA_PROTECTED_BUNDLES
# so orphaned vendor helpers can be reclaimed; only SYSTEM_CRITICAL_BUNDLES still
# block. AmneziaWG sits in the data-protected list, so an orphan whose parent app
# is gone is removed by design, exactly like the com.docker case asserted below.
# The older "must stay protected" expectation outlived that change only because
# the assertion sat mid-test and could not fail.
@test "clean_orphaned_system_services reclaims an AmneziaWG helper once its app is gone" {
    # setup_file exports MOLE_TEST_MODE=1, under which clean_orphaned_system_services
    # returns immediately and leaves $output empty. Override it as the sibling cases do.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }
bundle_has_installed_app() { return 1; }
safe_sudo_remove() {
  echo "removed:$1"
  return 0
}

# Routed through /Library/LaunchDaemons, which exists on every macOS box. The
# PrivilegedHelperTools scan is guarded by [[ -d /Library/PrivilegedHelperTools ]]
# in lib/clean/apps.sh, and that directory is absent on GitHub runners, so a
# helper fixture makes this case find nothing and pass vacuously in CI.
tmp_dir="$(mktemp -d)"
tmp_helper="$tmp_dir/org.amnezia.awg.plist"
cat > "$tmp_helper" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.amnezia.awg</string>
    <key>Program</key>
    <string>$tmp_dir/missing-binary</string>
</dict>
</plist>
PLIST

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_helper" ;;
      *) : ;;
    esac
    return 0
  fi
  if [[ "$1" == "du" ]]; then
    echo "4 $tmp_helper"
    return 0
  fi
  if [[ "$1" == "launchctl" ]]; then
    echo "launchctl-unload:$*"
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned services · cleaned 1"* ]] || return 1
    [[ "$output" == *"removed:"*"org.amnezia.awg.plist"* ]] || return 1
    # A LaunchDaemon orphan is unloaded before removal, so this call is the
    # expected order rather than a stray one.
    [[ "$output" == *"launchctl-unload:"*"org.amnezia.awg.plist"* ]]
}

@test "clean_orphaned_system_services keeps a live helper app LaunchDaemon loaded (#1447)" {
    # Chrome Remote Desktop installs its broker inside a standalone .app under
    # PrivilegedHelperTools rather than inside a parent app in /Applications.
    # The existing executable and enclosing helper app are exact ownership
    # evidence: the plist must never reach launchctl unload or removal.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 \
        DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { printf 'DEBUG:%s\n' "$*"; }
should_protect_path() { return 1; }
bundle_has_installed_app() {
    printf 'UNEXPECTED_PARENT_RESOLVER:%s\n' "$1"
    return 1
}

tmp_dir=$(mktemp -d)
tmp_plist="$tmp_dir/org.chromium.chromoting.broker.plist"
helper_binary="/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/remoting_agent_process_broker"
probe_trace="$tmp_dir/probe-trace"
/usr/libexec/PlistBuddy -c "Add :Program string $helper_binary" "$tmp_plist" > /dev/null 2>&1 || true

_mole_materialize_bounded_sudo_find() {
    printf 'SCAN_RAN:%s\n' "$3" >&2
    if [[ "$3" == "/Library/LaunchDaemons" ]]; then
        printf '%s\0' "$tmp_plist" > "$1"
    else
        : > "$1"
    fi
}

sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return 0 ;;
        test)
            [[ "${2:-}" == "-e" && "${3:-}" == "$helper_binary" ]] || return 1
            printf 'HELPER_BINARY_EXISTS\n' >> "$probe_trace"
            return 0
            ;;
        /usr/libexec/PlistBuddy)
            printf 'PLIST_PROGRAM_READ\n' >> "$probe_trace"
            command "$@"
            ;;
        /usr/bin/stat) command "$@" ;;
        du) printf '4\n' ;;
        launchctl)
            printf 'UNEXPECTED_LAUNCHCTL:%s\n' "$*"
            return 0
            ;;
        *) return 0 ;;
    esac
}
safe_sudo_remove() {
    printf 'UNEXPECTED_REMOVE:%s\n' "$1"
    return 0
}

clean_orphaned_system_services
cat "$probe_trace"
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SCAN_RAN:/Library/LaunchDaemons"* ]] || return 1
    [[ "$output" == *"PLIST_PROGRAM_READ"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_PARENT_RESOLVER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_LAUNCHCTL"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_REMOVE"* ]] || return 1
}

@test "_privileged_helper_bundle_id_from_binary prefers Info.plist bundle ID over directory and executable names" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

plutil() {
  [[ "$*" == *"/Library/PrivilegedHelperTools/com.example.directory.bundle/Contents/Info.plist"* ]] || return 1
  printf '%s\n' "io.github.clash-verge-rev.clash-verge-rev.service"
}

result=$(_privileged_helper_bundle_id_from_binary "/Library/PrivilegedHelperTools/com.example.directory.bundle/Contents/MacOS/clash-verge-service")
printf '%s\n' "$result"
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "io.github.clash-verge-rev.clash-verge-rev.service" ]
}

@test "clean_orphaned_system_services removes orphaned helper despite data protection (#1082)" {
    # The Docker leftover in #1082 survived because should_protect_data matches
    # com.docker.* and blocked cleanup. com.getpostman.* hits the exact same
    # should_protect_data branch; orphan cleanup must call should_protect_path in
    # uninstall mode so a verified orphan is not blocked by data protection.
    # Routed through /Library/LaunchDaemons (always present) rather than
    # /Library/PrivilegedHelperTools (absent on CI runners).
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.getpostman.helper.plist"
# Program points at a missing binary, so the plist is a genuine orphan.
/usr/libexec/PlistBuddy -c "Add :Program string $tmp_dir/missing-binary" "$tmp_plist" 2> /dev/null || true

removed_marker="$tmp_dir/removed"
safe_sudo_remove() {
  echo "removed:$1"
  printf '%s\n' "$1" >> "$removed_marker"
  return 0
}

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  if [[ "$1" == "du" ]]; then
    echo "4 $tmp_plist"
    return 0
  fi
  if [[ "$1" == "launchctl" ]]; then
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned services · cleaned 1"* ]] || return 1
    [[ "$output" == *"removed:"* ]] || return 1
    [[ "$output" != *"skipped 1 protected"* ]] || return 1
}

@test "clean_orphaned_system_services keeps daemons whose binary is root-only readable (#1188)" {
    # Intego-style self-protecting software (antivirus, endpoint agents) makes
    # its install tree root-only readable, so the unprivileged -e probe misses
    # the daemon binary and every one of its LaunchDaemons used to be flagged
    # as an orphan and removed, breaking the product. The binary must be
    # re-probed with sudo before being treated as missing. A genuinely missing
    # binary must still be detected, which also proves the scan actually ran.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }

tmp_dir="$(mktemp -d)"
protected_plist="$tmp_dir/com.example.selfprotect.daemon.plist"
orphan_plist="$tmp_dir/com.example.gone.daemon.plist"
root_only_binary="$tmp_dir/rootonly/selfprotectd"

# PlistBuddy announces "File Doesn't Exist, Will Create" on stdout, which
# would land in $output and trip the negative plist-name assertions below.
/usr/libexec/PlistBuddy -c "Add :Program string $root_only_binary" "$protected_plist" > /dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :Program string $tmp_dir/missing-binary" "$orphan_plist" > /dev/null 2>&1 || true

safe_sudo_remove() {
  echo "removed:$1"
  return 0
}

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "test" ]]; then
    # Simulate the root-only readable install dir: the binary exists for
    # root but the unprivileged [[ -e ]] probe cannot see it.
    if [[ "${3:-}" == "$root_only_binary" ]]; then
      return 0
    fi
    return 1
  fi
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$protected_plist" "$orphan_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  if [[ "$1" == "du" ]]; then
    echo "4 ${3:-}"
    return 0
  fi
  if [[ "$1" == "launchctl" ]]; then
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned services · cleaned 1"* ]] || return 1
    [[ "$output" == *"removed:"* ]] || return 1
    [[ "$output" == *"com.example.gone.daemon.plist"* ]] || return 1
    [[ "$output" != *"com.example.selfprotect.daemon.plist"* ]] || return 1
}

@test "clean_orphaned_system_services counts safe_sudo protected skips as protected (#1141)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=false MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { echo "debug: $*"; }
should_protect_path() {
  if [[ "${MOLE_UNINSTALL_MODE:-0}" == "1" ]]; then
    return 1
  fi
  return 0
}

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.adobe.example.plist"
cat > "$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.adobe.example</string>
    <key>Program</key>
    <string>$tmp_dir/missing-binary</string>
</dict>
</plist>
PLIST

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  if [[ "$1" == "du" ]]; then
    echo "4 $tmp_plist"
    return 0
  fi
  if [[ "$1" == "launchctl" ]]; then
    echo "launchctl-called"
    return 0
  fi
  if [[ "$1" == "rm" ]]; then
    echo "rm-called"
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Found 1 orphaned"* ]] || return 1
    [[ "$output" == *"Orphaned services · skipped 1 protected"* ]] || return 1
    [[ "$output" != *"rm-called"* ]] || return 1
    [[ "$output" != *"Failed to remove orphaned service"* ]] || return 1
}

@test "clean_orphaned_system_services dry-run skips protected paths (#886)" {
    # MOLE_TEST_NO_AUTH=0 overrides the CI default (=1) so the function actually
    # runs past the auth-skip guard in apps.sh; the sudo() mock satisfies the
    # `sudo -n true` probe.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { echo "debug: $*"; }

should_protect_path() { return 0; }

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.microsoft.office.licensingV2.helper.plist"
/usr/libexec/PlistBuddy -c "Add :Program string $tmp_dir/missing-protected-helper" "$tmp_plist" 2>/dev/null || true

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    # `|| return 1` after each assertion ensures bats fails as soon as one fails
    # (bare `[[ ]]` in the middle of a test body gets swallowed by the next
    # passing command; see #886 review notes).
    [ "$status" -eq 0 ]
    [[ "$output" == *"Found 1 orphaned"* ]] || return 1
    [[ "$output" == *"skipped 1 protected"* ]] || return 1
    [[ "$output" != *"Would remove orphaned service"* ]] || return 1
}

@test "clean_orphaned_system_services dry-run reports unprotected orphans (#886)" {
    # MOLE_TEST_NO_AUTH=0 overrides CI default so the function executes.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { echo "debug: $*"; }

should_protect_path() { return 1; }

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.example.unprotected.orphan.plist"
/usr/libexec/PlistBuddy -c "Add :Program string $tmp_dir/missing-binary" "$tmp_plist" 2>/dev/null || true

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Found 1 orphaned"* ]] || return 1
    [[ "$output" == *"Would remove orphaned service"* ]] || return 1
    [[ "$output" != *"Skipping protected"* ]] || return 1
}

@test "clean_orphaned_system_services dry-run writes orphan paths to the export list (#1210)" {
    # MOLE_TEST_NO_AUTH=0 overrides CI default so the function executes.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }

should_protect_path() { return 1; }

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.example.exported.orphan.plist"
/usr/libexec/PlistBuddy -c "Add :Program string $tmp_dir/missing-binary" "$tmp_plist" > /dev/null 2>&1 || true

EXPORT_LIST_FILE="$tmp_dir/clean-list.txt"
touch "$EXPORT_LIST_FILE"

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
echo "--- export list ---"
cat "$EXPORT_LIST_FILE"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"found dry"* ]] || return 1
    [[ "$output" == *"com.example.exported.orphan.plist  # "* ]] || return 1
}

@test "clean_orphaned_container_stubs removes stub container when app is uninstalled" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Pin the app-existence probe: the hardcoded example bundle id may match an
# app that is actually installed on the developer's machine.
_container_stub_app_exists() { return 1; }

# Stub container: only the metadata plist, no Data/ subdir
stub="$HOME/Library/Containers/com.macpaw.CleanMyMac-mas"
mkdir -p "$stub"
touch "$stub/.com.apple.containermanagerd.metadata.plist"

# Canonical app path does not exist (uninstalled)
# mdfind returns nothing (uninstalled)
mdfind() { echo ""; return 0; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
debug_log() { :; }
is_path_whitelisted() { return 1; }

files_cleaned=0
total_items=0
total_size_cleaned=0

clean_orphaned_container_stubs

if [[ ! -d "$stub" ]]; then
    echo "PASS: stub removed"
else
    echo "FAIL: stub still exists"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: stub removed"* ]] || return 1
    [[ "$output" == *"Orphaned app container stubs"* ]]
}

@test "clean_orphaned_container_stubs preserves content that appears during removal" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Pin the app-existence probe: the hardcoded example bundle id may match an
# app that is actually installed on the developer's machine.
_container_stub_app_exists() { return 1; }

stub="$HOME/Library/Containers/com.macpaw.CleanMyMac-mas"
mkdir -p "$stub"
touch "$stub/.com.apple.containermanagerd.metadata.plist"

fake_bin="$(mktemp -d "$HOME/fake-bin.XXXXXX")"
cat > "$fake_bin/rm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
target=""
for arg in "$@"; do
    target="$arg"
done
if [[ -n "$target" ]]; then
    if [[ -d "$target" ]]; then
        touch "$target/raced-content"
    else
        parent=$(dirname "$target")
        touch "$parent/raced-content"
    fi
fi
exec /bin/rm "$@"
SH
chmod +x "$fake_bin/rm"
PATH="$fake_bin:$PATH"
export PATH
hash -r

mdfind() { echo ""; return 0; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
debug_log() { :; }
is_path_whitelisted() { return 1; }

files_cleaned=0
total_items=0
total_size_cleaned=0

clean_orphaned_container_stubs

if [[ -f "$stub/raced-content" ]]; then
    echo "PASS: race content preserved"
else
    echo "FAIL: race content was deleted"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: race content preserved"* ]] || return 1
    [[ "$output" == *"could not be removed"* ]]
}

@test "container stub removal must bypass safe_remove because Containers are protected" {
    # Guard for the "tidy the outlier back into the house pattern" trap: routing
    # _remove_verified_container_stub through safe_remove looks like a cleanup
    # win, but should_protect_path blankets ~/Library/Containers, so the shared
    # helper refuses the stub and the cleaner silently stops working. This test
    # pins the REASON the carve-out exists, so the next refactor sees it fail.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
# common.sh turns errexit on; the probes below are EXPECTED to return 1.
set +e

# Keep this policy probe independent of the checkout location. A detached
# worktree commonly lives below /private/var/folders, whose children are
# intentionally accepted as disposable temp data before app protection runs.
stub="/Users/mole-clean-apps-fixture-$$/Library/Containers/com.macpaw.CleanMyMac-mas"
plist="$stub/.com.apple.containermanagerd.metadata.plist"

validate_path_for_deletion "$stub" > /dev/null 2>&1
echo "validate_dir_rc=$?"
validate_path_for_deletion "$plist" > /dev/null 2>&1
echo "validate_plist_rc=$?"
EOF

    [ "$status" -eq 0 ]
    # Both must be REFUSED by the shared validator; that is exactly why the
    # stub remover keeps its own narrow guards plus a raw rm/rmdir.
    [[ "$output" == *"validate_dir_rc=1"* ]] || return 1
    [[ "$output" == *"validate_plist_rc=1"* ]] || return 1
}

@test "clean_orphaned_container_stubs preserves container when app is installed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

stub="$HOME/Library/Containers/com.macpaw.CleanMyMac-mas"
mkdir -p "$stub"
touch "$stub/.com.apple.containermanagerd.metadata.plist"

# Simulate the app installed in a user-level Applications directory.
mkdir -p "$HOME/Applications/CleanMyMac X.app"

mdfind() { echo ""; return 0; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
debug_log() { :; }
is_path_whitelisted() { return 1; }
files_cleaned=0
total_items=0
total_size_cleaned=0

clean_orphaned_container_stubs

if [[ -d "$stub" ]]; then
    echo "PASS: stub preserved"
else
    echo "FAIL: stub was wrongly removed"
    exit 1
fi

EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: stub preserved"* ]]
}

@test "clean_orphaned_container_stubs preserves container with Data subdirectory" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

# Container has a Data/ subtree: real sandbox data, must NOT be deleted
stub="$HOME/Library/Containers/com.macpaw.CleanMyMac-mas"
mkdir -p "$stub/Data/Library/Preferences"
touch "$stub/.com.apple.containermanagerd.metadata.plist"
touch "$stub/Data/Library/Preferences/settings.plist"

mdfind() { echo ""; return 0; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
debug_log() { :; }
is_path_whitelisted() { return 1; }

files_cleaned=0
total_items=0
total_size_cleaned=0

clean_orphaned_container_stubs

if [[ -d "$stub/Data" ]]; then
    echo "PASS: data container preserved"
else
    echo "FAIL: data container was wrongly removed"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: data container preserved"* ]]
}

@test "clean_orphaned_container_stubs preserves non-metadata-only container" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

stub="$HOME/Library/Containers/com.macpaw.CleanMyMac-mas"
mkdir -p "$stub"
touch "$stub/.com.apple.containermanagerd.metadata.plist"
touch "$stub/session.lock"

mdfind() { echo ""; return 0; }
run_with_timeout() { shift; "$@"; }
note_activity() { :; }
debug_log() { :; }
is_path_whitelisted() { return 1; }

files_cleaned=0
total_items=0
total_size_cleaned=0

clean_orphaned_container_stubs

if [[ -f "$stub/session.lock" ]]; then
    echo "PASS: non-stub container preserved"
else
    echo "FAIL: non-stub container was wrongly removed"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: non-stub container preserved"* ]]
}

@test "clean_orphaned_system_services tolerates all-whitelisted orphans on /bin/bash 3.2 (#1127)" {
    # macOS ships /bin/bash 3.2 (Apple does not upgrade past it, GPLv3) and
    # lib/clean/apps.sh runs under `set -u`, where bash 3.2 treats "${empty[@]}"
    # as an unbound variable rather than an empty expansion. When orphans are
    # found but every one is whitelisted, kept_files ends up empty and the
    # whitelist filter's `orphaned_files=("${kept_files[@]}")` aborted the whole
    # clean run with "kept_files[@]: unbound variable". Force /bin/bash so the
    # 3.2 expansion behaviour is exercised regardless of any newer bash on PATH.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=0 DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"

start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { :; }

should_protect_path() { return 1; }
# Every detected orphan is whitelisted, so kept_files stays empty.
is_path_whitelisted() { return 0; }
WHITELIST_PATTERNS=("com.example.*")

tmp_dir="$(mktemp -d)"
tmp_plist="$tmp_dir/com.example.whitelisted.orphan.plist"
/usr/libexec/PlistBuddy -c "Add :Program string $tmp_dir/missing-binary" "$tmp_plist" 2> /dev/null || true

sudo() {
  if [[ "$1" == "-n" && "$2" == "true" ]]; then
    return 0
  fi
  [[ "${1:-}" == "-n" ]] && shift
  if [[ "$1" == "find" ]]; then
    case "$2" in
      /Library/LaunchDaemons) printf '%s\0' "$tmp_plist" ;;
      *) : ;;
    esac
    return 0
  fi
  command "$@"
}

clean_orphaned_system_services
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]] || return 1
    # Whitelisted orphan must be filtered out, so nothing is reported for removal.
    [[ "$output" != *"Would remove orphaned service"* ]] || return 1
}

@test "installed-app scan reads wrapped bundles and tolerates a missing bundle id" {
	# Same two shapes that broke the uninstall scan: an iOS app on Apple
	# Silicon keeps its plist under Wrapper/<name>.app, and vendor launchers
	# ship one with no CFBundleIdentifier. Both used to fail the scan closed,
	# which skipped App leftovers entirely. A plist that will not parse still
	# must fail closed, because there the id may exist and be unreadable.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
rm -f "$HOME/.cache/mole/installed_apps_cache"

apps="$HOME/Applications"
rm -rf "$apps"; mkdir -p "$apps/Good.app/Contents" "$apps/Wrapped.app/Wrapper/Inner.app" "$apps/NoId.app/Contents"
plist() {
	cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>$2</dict></plist>
PLIST
}
plist "$apps/Good.app/Contents/Info.plist" '<key>CFBundleIdentifier</key><string>com.example.good</string>'
plist "$apps/Wrapped.app/Wrapper/Inner.app/Info.plist" '<key>CFBundleIdentifier</key><string>com.example.wrapped</string>'
plist "$apps/NoId.app/Contents/Info.plist" '<key>CFBundleExecutable</key><string>run.sh</string>'

debug_log() { :; }
scan_installed_apps "$HOME/installed.txt" || { echo "SCAN_FAILED"; exit 1; }
grep -Fxq "com.example.good" "$HOME/installed.txt" || { echo "MISSING_GOOD"; exit 1; }
grep -Fxq "com.example.wrapped" "$HOME/installed.txt" || { echo "MISSING_WRAPPED"; exit 1; }

# A plist that cannot be parsed still fails the scan closed.
printf 'not a plist' > "$apps/NoId.app/Contents/Info.plist"
rm -f "$HOME/.cache/mole/installed_apps_cache"
if scan_installed_apps "$HOME/installed2.txt"; then
	echo "CORRUPT_NOT_FAILED"; exit 1
fi
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "installed-app scan skips an iOS app with a dangling WrappedBundle symlink" {
	# AudioCopy.app has no Contents/, a WrappedBundle symlink into a Wrapper/
	# that does not exist, so no readable plist anywhere. It owns no
	# bundle-id-named data, so skipping it invents no orphan; before this it
	# failed the whole App-leftovers scan closed on that machine.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
rm -f "$HOME/.cache/mole/installed_apps_cache"
apps="$HOME/Applications"
rm -rf "$apps"
mkdir -p "$apps/Good.app/Contents" "$apps/AudioCopy.app"
ln -s "Wrapper/AudioCopy.app" "$apps/AudioCopy.app/WrappedBundle"
printf '%s' '<?xml version="1.0"?><!DOCTYPE plist><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.good</string></dict></plist>' > "$apps/Good.app/Contents/Info.plist"
debug_log() { :; }
scan_installed_apps "$HOME/installed.txt" || { echo "SCAN_FAILED"; exit 1; }
grep -Fxq "com.example.good" "$HOME/installed.txt" || { echo "MISSING_GOOD"; exit 1; }
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "installed-app scan still fails closed on a plist-less app with no dangling wrapper" {
	# The dangling-symlink skip is narrow: an app with no plist and no
	# WrappedBundle symlink at all keeps failing the scan closed, since its
	# identity is genuinely unknown rather than provably absent.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/apps.sh"
rm -f "$HOME/.cache/mole/installed_apps_cache"
apps="$HOME/Applications"
rm -rf "$apps"
mkdir -p "$apps/Good.app/Contents" "$apps/Mystery.app/Contents"
printf '%s' '<?xml version="1.0"?><!DOCTYPE plist><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.good</string></dict></plist>' > "$apps/Good.app/Contents/Info.plist"
debug_log() { :; }
if scan_installed_apps "$HOME/installed.txt"; then
  echo "SCAN_SUCCEEDED_UNEXPECTEDLY"; exit 1
fi
EOF
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}
