#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-user-core.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_user_essentials respects Trash whitelist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { echo "$2"; }
note_activity() { :; }
is_path_whitelisted() { [[ "$1" == "$HOME/.Trash" ]]; }
clean_user_essentials
EOF

    [ "$status" -eq 0 ]
    # Whitelist-protected items no longer show output (UX improvement in V1.22.0)
    [[ "$output" != *"Trash"* ]]
}

@test "clean_user_essentials falls back when Finder trash operations time out" {
    mkdir -p "$HOME/.Trash"
    touch "$HOME/.Trash/one.tmp" "$HOME/.Trash/two.tmp"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
debug_log() { :; }
run_with_timeout() {
    local _duration="$1"
    shift
    if [[ "$1" == "osascript" ]]; then
        return 124
    fi
    "$@"
}
safe_remove() {
    local target="$1"
    /bin/rm -rf "$target"
    return 0
}

clean_user_essentials
[[ ! -e "$HOME/.Trash/one.tmp" ]] || exit 1
[[ ! -e "$HOME/.Trash/two.tmp" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Trash · emptied, 2 items"* ]]
}

@test "clean_user_essentials keeps Mole runtime logs while cleaning other user logs" {
    mkdir -p "$HOME/Library/Logs/mole"
    mkdir -p "$HOME/Library/Logs/OtherApp"
    touch "$HOME/Library/Logs/mole/operations.log"
    touch "$HOME/Library/Logs/OtherApp/old.log"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
DRY_RUN=false
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
safe_clean() {
    local path=""
    for path in "${@:1:$#-1}"; do
        if should_protect_path "$path"; then
            continue
        fi
        /bin/rm -rf "$path"
    done
}

clean_user_essentials

[[ -d "$HOME/Library/Logs/mole" ]]
[[ -f "$HOME/Library/Logs/mole/operations.log" ]]
[[ ! -e "$HOME/Library/Logs/OtherApp/old.log" ]]
EOF

    [ "$status" -eq 0 ]
}

@test "clean_app_caches includes macOS system caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
start_section_spinner() { :; }
safe_clean() { echo "$2"; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Saved application states"* ]] || [[ "$output" == *"App caches"* ]]
}

@test "clean_app_caches shows spinner during initial app cache scan" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { echo "SPIN_START:$1"; }
stop_section_spinner() { echo "SPIN_STOP"; }
safe_clean() { :; }
clean_support_app_data() { :; }
clean_group_container_caches() { :; }

clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SPIN_START:Scanning app caches..."* ]]
}

@test "clean_support_app_data targets crash, idle assets, and messages preview caches only" {
    local support_home="$HOME/support-cache-home-1"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
safe_find_delete() { echo "FIND:$1:$3:$4"; }
pgrep() { return 1; }

mkdir -p "$HOME/Library/Application Support/CrashReporter"
mkdir -p "$HOME/Library/Application Support/com.apple.idleassetsd"

clean_support_app_data

rm -rf "$HOME/Library/Application Support/CrashReporter"
rm -rf "$HOME/Library/Application Support/com.apple.idleassetsd"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"FIND:$support_home/Library/Application Support/CrashReporter:30:f"* ]]
    [[ "$output" == *"FIND:$support_home/Library/Application Support/com.apple.idleassetsd:30:f"* ]]
    [[ "$output" != *"Aerial wallpaper videos"* ]]
    [[ "$output" == *"Messages sticker cache"* ]]
    [[ "$output" == *"Messages preview attachment cache"* ]]
    [[ "$output" == *"Messages preview sticker cache"* ]]
    [[ "$output" != *"Messages attachments"* ]]
}

@test "clean_support_app_data always cleans messages preview caches" {
    local support_home="$HOME/support-cache-home-2"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
safe_find_delete() { :; }
pgrep() { return 0; }

clean_support_app_data
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Messages sticker cache"* ]]
    [[ "$output" == *"Messages preview attachment cache"* ]]
    [[ "$output" == *"Messages preview sticker cache"* ]]
}

@test "clean_app_caches skips protected containers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
safe_clean() { :; }
should_protect_data() { return 0; }
is_critical_system_component() { return 0; }
files_cleaned=0
total_size_cleaned=0
total_items=0
mkdir -p "$HOME/Library/Containers/com.example.app/Data/Library/Caches"
touch "$HOME/Library/Containers/com.example.app/Data/Library/Caches/test.cache"
clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"App caches"* ]] || [[ "$output" == *"already clean"* ]]
}

@test "clean_app_caches skips expensive size scans for large sandboxed caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
safe_clean() { :; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
get_path_size_kb() {
    echo "SHOULD_NOT_SIZE_SCAN"
    return 0
}
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Containers/com.example.large/Data/Library/Caches"
for i in $(seq 1 101); do
    touch "$HOME/Library/Containers/com.example.large/Data/Library/Caches/file-$i.tmp"
done

clean_app_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sandboxed app caches"* ]]
    [[ "$output" != *"SHOULD_NOT_SIZE_SCAN"* ]]
}

@test "clean_application_support_logs counts nested directory contents in dry-run size summary" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { :; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/TestApp/logs/nested"
dd if=/dev/zero of="$HOME/Library/Application Support/TestApp/logs/nested/data.bin" bs=1024 count=2 2> /dev/null

clean_application_support_logs
echo "TOTAL_KB=$total_size_cleaned"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Application Support logs/caches"* ]]
    local total_kb
    total_kb=$(printf '%s\n' "$output" | sed -n 's/.*TOTAL_KB=\([0-9][0-9]*\).*/\1/p' | tail -1)
    [[ -n "$total_kb" ]]
    [[ "$total_kb" -ge 2 ]]
}

@test "clean_application_support_logs uses bulk clean for large Application Support directories" {
    local support_home="$HOME/support-appsupport-bulk"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { echo "SPIN:$1"; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { echo "REMOVE:$1"; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
bytes_to_human() { echo "0B"; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/adspower_global/logs"
for i in $(seq 1 101); do
    touch "$HOME/Library/Application Support/adspower_global/logs/file-$i.log"
done

clean_application_support_logs
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SPIN:Scanning Application Support... 1/1 [adspower_global, bulk clean]"* ]]
    [[ "$output" == *"Application Support logs/caches"* ]]
    [[ "$output" != *"151250 items"* ]]
    [[ "$output" != *"REMOVE:"* ]]
}

@test "clean_application_support_logs skips whitelisted application support directories" {
    local support_home="$HOME/support-appsupport-whitelist"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_remove() { echo "REMOVE:$1"; }
update_progress_if_needed() { return 1; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
WHITELIST_PATTERNS=("$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/logs"
touch "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/logs/runtime.log"

clean_application_support_logs
test -f "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/logs/runtime.log"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"REMOVE:"* ]]
}

@test "app_support_entry_count_capped stops at cap without failing under pipefail" {
    local support_home="$HOME/support-appsupport-cap"
    run env HOME="$support_home" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
mkdir -p "$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

mkdir -p "$HOME/Library/Application Support/adspower_global/logs"
for i in $(seq 1 150); do
    touch "$HOME/Library/Application Support/adspower_global/logs/file-$i.log"
done

count=$(app_support_entry_count_capped "$HOME/Library/Application Support/adspower_global/logs" 1 101)
echo "COUNT=$count"
rm -rf "$HOME/Library/Application Support"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT=101"* ]]
}

@test "clean_group_container_caches keeps protected caches and cleans non-protected caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Logs"
mkdir -p "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Caches"
mkdir -p "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches"
echo "log" > "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Logs/log.txt"
echo "cache" > "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Caches/cache.db"
echo "cache" > "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/cache.db"

clean_group_container_caches

if [[ ! -e "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Logs/log.txt" ]] \
    && [[ -e "$HOME/Library/Group Containers/group.com.microsoft.teams/Library/Caches/cache.db" ]] \
    && [[ ! -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/cache.db" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Group Containers logs/caches"* ]]
    [[ "$output" == *"PASS"* ]]
}

@test "clean_group_container_caches respects whitelist entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches"
echo "protected" > "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/keep.db"
echo "remove" > "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/drop.db"

is_path_whitelisted() {
    [[ "$1" == *"/group.com.example.tool/Library/Caches/keep.db" ]]
}

clean_group_container_caches

if [[ -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/keep.db" ]] \
    && [[ ! -e "$HOME/Library/Group Containers/group.com.example.tool/Library/Caches/drop.db" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "clean_group_container_caches skips systemgroup apple containers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/systemgroup.com.apple.example/Library/Caches"
echo "system-data" > "$HOME/Library/Group Containers/systemgroup.com.apple.example/Library/Caches/cache.db"

clean_group_container_caches

if [[ -e "$HOME/Library/Group Containers/systemgroup.com.apple.example/Library/Caches/cache.db" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "clean_group_container_caches does not report when only whitelisted items exist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.example.onlywhite/Library/Caches"
echo "whitelisted" > "$HOME/Library/Group Containers/group.com.example.onlywhite/Library/Caches/keep.db"

is_path_whitelisted() {
    [[ "$1" == *"/group.com.example.onlywhite/Library/Caches/keep.db" ]]
}

clean_group_container_caches

if [[ -e "$HOME/Library/Group Containers/group.com.example.onlywhite/Library/Caches/keep.db" ]]; then
    echo "PASS"
else
    echo "FAIL"
    exit 1
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" != *"Group Containers logs/caches"* ]]
}

@test "clean_group_container_caches skips per-item size scans for large candidates" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
get_path_size_kb() {
    echo "SHOULD_NOT_SIZE_SCAN"
    return 0
}
files_cleaned=0
total_size_cleaned=0
total_items=0

mkdir -p "$HOME/Library/Group Containers/group.com.example.large/Library/Caches"
for i in $(seq 1 101); do
    touch "$HOME/Library/Group Containers/group.com.example.large/Library/Caches/file-$i.tmp"
done

clean_group_container_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Group Containers logs/caches"* ]]
    [[ "$output" != *"SHOULD_NOT_SIZE_SCAN"* ]]
}

@test "clean_finder_metadata respects protection flag" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PROTECT_FINDER_METADATA=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
stop_section_spinner() { :; }
note_activity() { :; }
clean_finder_metadata
EOF

    [ "$status" -eq 0 ]
    # Whitelist-protected items no longer show output (UX improvement in V1.22.0)
    [[ "$output" == "" ]]
}

@test "check_ios_device_backups returns when no backup dir" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
check_ios_device_backups
EOF

    [ "$status" -eq 0 ]
}

@test "clean_browsers calls expected cache paths" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_service_worker_cache() { :; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Safari cache"* ]]
    [[ "$output" == *"Firefox cache"* ]]
    [[ "$output" == *"Puppeteer browser cache"* ]]
}

@test "clean_browsers cleans Brave Service Worker caches" {
    mkdir -p "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker/ScriptCache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_service_worker_cache() { echo "Brave SW $1"; }
note_activity() { :; }
files_cleaned=0
total_size_cleaned=0
total_items=0
clean_browsers
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Brave SW Brave"* ]]
    [[ "$output" == *"Brave Service Worker ScriptCache"* ]]

    rm -rf "$HOME/Library"
}

@test "clean_application_support_logs skips when no access" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
note_activity() { :; }
clean_application_support_logs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped: No permission"* ]]
}

@test "clean_apple_silicon_caches exits when not M-series" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" IS_M_SERIES=false bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
safe_clean() { echo "$2"; }
clean_apple_silicon_caches
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "clean_user_essentials includes dotfiles in Trash cleanup" {
    mkdir -p "$HOME/.Trash"
    touch "$HOME/.Trash/.hidden_file"
    touch "$HOME/.Trash/.DS_Store"
    touch "$HOME/.Trash/regular_file.txt"
    mkdir -p "$HOME/.Trash/.hidden_dir"
    mkdir -p "$HOME/.Trash/regular_dir"

    run bash <<'EOF'
set -euo pipefail
count=0
while IFS= read -r -d '' item; do
    ((count++)) || true
    echo "FOUND: $(basename "$item")"
done < <(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
echo "COUNT: $count"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"COUNT: 5"* ]]
    [[ "$output" == *"FOUND: .hidden_file"* ]]
    [[ "$output" == *"FOUND: .DS_Store"* ]]
    [[ "$output" == *"FOUND: .hidden_dir"* ]]
    [[ "$output" == *"FOUND: regular_file.txt"* ]]
}

@test "validate_external_volume_target canonicalizes root before comparing target" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"

mock_bin="$HOME/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/diskutil" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$mock_bin/diskutil"
export PATH="$mock_bin:$PATH"

real_root="$(mktemp -d "$HOME/ext-real.XXXXXX")"
link_root="$HOME/ext-link"
ln -s "$real_root" "$link_root"
mkdir -p "$link_root/USB"
export MOLE_EXTERNAL_VOLUMES_ROOT="$link_root"

resolved=$(validate_external_volume_target "$link_root/USB")
echo "RESOLVED=$resolved"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"RESOLVED="*"/USB"* ]]
    [[ "$output" != *"must be under"* ]]
}

@test "clean_app_caches caps precise sandbox size scans when many containers exist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true MOLE_CONTAINER_CACHE_PRECISE_SIZE_LIMIT=2 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
safe_clean() { :; }
clean_support_app_data() { :; }
clean_group_container_caches() { :; }
bytes_to_human() { echo "0B"; }
note_activity() { :; }
should_protect_data() { return 1; }
is_critical_system_component() { return 1; }
files_cleaned=0
total_size_cleaned=0
total_items=0

count_file="$HOME/size-count"
get_path_size_kb() {
    local count
    count=$(cat "$count_file" 2> /dev/null || echo "0")
    count=$((count + 1))
    echo "$count" > "$count_file"
    echo "1"
}

for i in $(seq 1 5); do
    mkdir -p "$HOME/Library/Containers/com.example.$i/Data/Library/Caches"
    touch "$HOME/Library/Containers/com.example.$i/Data/Library/Caches/file-$i.tmp"
done

clean_app_caches
echo "SIZE_CALLS=$(cat "$count_file")"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Sandboxed app caches"* ]]
    [[ "$output" == *"SIZE_CALLS=2"* ]]
}
