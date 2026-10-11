#!/usr/bin/env bats

load helpers/common

setup_file() {
	mole_test_setup_home optimize
}

teardown_file() {
	mole_test_teardown_home
}

@test "needs_permissions_repair returns true when home owner differs" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" USER="tester" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
if needs_permissions_repair; then
    echo "needs"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"needs"* ]]
}

@test "needs_permissions_repair ignores PATH-provided GNU stat (#1196)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" USER="$USER" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

stat() {
    printf '  File: "%s"\n    ID: 10000110000001a Namelen: ? Type: apfs\n' "$HOME"
    return 1
}
export -f stat

if needs_permissions_repair; then
    echo "needs"
else
    echo "optimal"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"optimal"* ]] || return 1
	[[ "$output" != *"needs"* ]]
}

@test "is_ac_power detects AC power" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
pmset() { echo "AC Power"; }
export -f pmset
if is_ac_power; then
    echo "ac"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ac"* ]]
}

@test "dry-run keeps healthy conditional system tasks unchanged" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 MOLE_ASSUME_VPN_ACTIVE=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mkdir -p "$HOME/bin"
printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/route"
printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/dscacheutil"
chmod +x "$HOME/bin/route" "$HOME/bin/dscacheutil"
PATH="$HOME/bin:$PATH"
needs_permissions_repair() { return 1; }

execute_optimization network_stack_optimize
execute_optimization disk_permissions_repair
[[ "$(optimize_outcome_count unchanged)" == "2" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Network stack already optimal"* ]] || return 1
	[[ "$output" == *"User directory permissions already optimal"* ]] || return 1
}

@test "opt_system_maintenance reports DNS and Spotlight" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
flush_dns_cache() { return 0; }
mkdir -p "$HOME/bin"
printf '#!/bin/bash\necho "Indexing enabled."\n' > "$HOME/bin/mdutil"
chmod +x "$HOME/bin/mdutil"
PATH="$HOME/bin:$PATH"
execute_optimization system_maintenance
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"DNS cache flushed"* ]] || return 1
	[[ "$output" == *"Spotlight index verified"* ]]
}

@test "opt_network_optimization refreshes DNS" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
flush_dns_cache() { return 0; }
execute_optimization network_optimization
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"DNS cache refreshed"* ]] || return 1
	[[ "$output" != *"mDNSResponder"* ]]
}

@test "DNS flush is skipped in both optimize tasks while a VPN is active" {
	# run_with_timeout execs a binary, so a shell-function mdutil is never
	# reached and the real Spotlight probe would decide failed vs skipped.
	mole_test_fake_command mdutil 'echo "Indexing enabled."'
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=1 MOLE_OPTIMIZE_SUDO_AVAILABLE=true MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE
sudo() { echo "UNEXPECTED_SUDO:$*"; return 0; }

execute_optimization system_maintenance
execute_optimization network_optimization
[[ "$(optimize_outcome_count skipped)" == "2" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
[[ "$(optimize_outcome_count failed)" == "0" ]] || exit 1
[[ "${MOLE_DNS_FLUSHED:-0}" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"DNS cache flush skipped, active VPN detected"* ]] || return 1
	[[ "$output" == *"DNS cache refresh skipped, active VPN detected"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUDO"* ]] || return 1
	[[ "$output" != *"already refreshed"* ]]
}

@test "dry-run previews the VPN skip instead of a DNS flush" {
	mole_test_fake_command mdutil 'echo "Indexing enabled."'
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=1 MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

execute_optimization system_maintenance
execute_optimization network_optimization
[[ "$(optimize_outcome_count skipped)" == "2" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"DNS cache flush skipped, active VPN detected"* ]] || return 1
	[[ "$output" != *"DNS cache flushed"* ]] || return 1
	[[ "$output" != *"DNS cache refreshed"* ]]
}

@test "DNS flush runs once without a VPN and the second task reports it unchanged" {
	mole_test_fake_command mdutil 'echo "Indexing enabled."'
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 MOLE_OPTIMIZE_SUDO_AVAILABLE=true MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE
sudo() { echo "SUDO:$*"; return 0; }

execute_optimization system_maintenance
execute_optimization network_optimization
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count unchanged)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"SUDO:dscacheutil -flushcache"* ]] || return 1
	[[ "$output" == *"SUDO:killall -HUP mDNSResponder"* ]] || return 1
	[[ "$(grep -c 'SUDO:dscacheutil -flushcache' <<< "$output")" == "1" ]] || return 1
	[[ "$output" == *"DNS cache flushed"* ]] || return 1
	[[ "$output" == *"DNS cache already refreshed"* ]] || return 1
	[[ "$output" != *"Failed to refresh DNS cache"* ]] || return 1
	[[ "$output" != *"restarted"* ]]
}

@test "DNS flush fails closed when the VPN state cannot be determined" {
	mole_test_fake_command mdutil 'echo "Indexing enabled."'
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_OPTIMIZE_SUDO_AVAILABLE=true MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE MOLE_ASSUME_VPN_ACTIVE
has_active_vpn_interface() { return 2; }
sudo() { echo "UNEXPECTED_SUDO:$*"; return 0; }

execute_optimization system_maintenance
execute_optimization network_optimization
[[ "$(optimize_outcome_count failed)" == "2" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$(grep -c 'Failed to inspect active VPN state' <<< "$output")" == "2" ]] || return 1
	[[ "$output" != *"UNEXPECTED_SUDO"* ]]
}

@test "a failed DNS flush is named by both optimize tasks that attempt it" {
	mole_test_fake_command mdutil 'echo "Indexing enabled."'
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 MOLE_OPTIMIZE_SUDO_AVAILABLE=true MOLE_DRY_RUN=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE
sudo() { echo "SUDO_FAILED:$*"; return 1; }

execute_optimization system_maintenance
execute_optimization network_optimization
[[ "$(optimize_outcome_count failed)" == "2" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	# system_maintenance used to count the failure without saying why.
	[[ "$(grep -c 'Failed to refresh DNS cache' <<< "$output")" == "2" ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Spotlight index verified"* ]] || return 1
	[[ "$output" != *"DNS cache flushed"* ]]
}

@test "fix_broken_preferences repairs only non-Apple preference plists" {
	local test_home="$HOME/fixprefs-basic"
	run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"

CALL_LOG="$HOME/fix-broken-preferences.log"
prefs="$HOME/Library/Preferences"
mkdir -p "$prefs/ByHost"
touch \
    "$prefs/com.example.broken.plist" \
    "$prefs/com.apple.broken.plist" \
    "$prefs/loginwindow.plist" \
    "$prefs/ByHost/com.example.byhost.plist" \
    "$prefs/ByHost/loginwindow.plist"

plutil() {
    echo "lint:$2" >> "$CALL_LOG"
    return 1
}
safe_remove() {
    echo "remove:$1" >> "$CALL_LOG"
}

count=$(fix_broken_preferences)
echo "count=$count"
cat "$CALL_LOG"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=3"* ]] || return 1
	[[ "$output" == *"remove:$test_home/Library/Preferences/com.example.broken.plist"* ]] || return 1
	[[ "$output" == *"remove:$test_home/Library/Preferences/ByHost/com.example.byhost.plist"* ]] || return 1
	[[ "$output" == *"remove:$test_home/Library/Preferences/ByHost/loginwindow.plist"* ]] || return 1
	[[ "$output" != *"lint:$test_home/Library/Preferences/com.apple.broken.plist"* ]] || return 1
	[[ "$output" != *"lint:$test_home/Library/Preferences/loginwindow.plist"* ]]
}

@test "fix_broken_preferences does not count safe_remove failures" {
	local test_home="$HOME/fixprefs-remove-failure"
	run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"

prefs="$HOME/Library/Preferences"
mkdir -p "$prefs"
touch "$prefs/com.example.broken.plist"

plutil() { return 1; }
safe_remove() { return 1; }

count=$(fix_broken_preferences)
echo "count=$count"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=0"* ]]
}

@test "opt_fix_broken_configs debug lists only successfully repaired paths" {
	local test_home="$HOME/fixprefs-debug-paths"
	local repaired="$test_home/Library/Preferences/com.example.repaired.plist"
	local failed="$test_home/Library/Preferences/com.example.failed.plist"
	run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

prefs="$HOME/Library/Preferences"
mkdir -p "$prefs"
touch \
    "$prefs/com.example.repaired.plist" \
    "$prefs/com.example.failed.plist"

plutil() { return 1; }
safe_remove() {
    [[ "$1" != *"failed.plist" ]]
}

execute_optimization fix_broken_configs
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Repaired 1 corrupted preference files"* ]] || return 1
	[[ "$output" == *"Removed corrupted preference:"* ]] || return 1
	[[ "$output" == *"$repaired"* ]] || return 1
	[[ "$output" != *"$failed"* ]] || return 1
}

@test "fix_broken_preferences does not count protected Adobe plists" {
	local test_home="$HOME/fixprefs-protected"
	run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"

prefs="$HOME/Library/Preferences"
plist="$prefs/com.adobe.Photoshop.uxp_com.adobe.ccx.start.plist"
mkdir -p "$prefs"
touch "$plist"

plutil() { return 1; }

count=$(fix_broken_preferences)
echo "count=$count"
[[ -f "$plist" ]] && echo "still-present"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=0"* ]] || return 1
	[[ "$output" == *"still-present"* ]]
}

@test "fix_broken_preferences lints plists in one batch instead of per file" {
	local test_home="$HOME/fixprefs-batch"
	run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"

CALL_LOG="$HOME/plutil-calls.log"
prefs="$HOME/Library/Preferences"
mkdir -p "$prefs"
touch \
    "$prefs/com.example.one.plist" \
    "$prefs/com.example.two.plist" \
    "$prefs/com.example.three.plist"

plutil() {
    echo "call" >> "$CALL_LOG"
    return 0
}

count=$(fix_broken_preferences)
echo "count=$count"
echo "calls=$(wc -l < "$CALL_LOG" | tr -d ' ')"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"count=0"* ]] || return 1
	[[ "$output" == *"calls=1"* ]] || return 1
}

@test "opt_fix_broken_configs reports partial results when scan hits its time budget" {
	local test_home="$HOME/fixprefs-budget"
	run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TIMEOUT_HINT_SCAN_SEC=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/maintenance.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

prefs="$HOME/Library/Preferences"
mkdir -p "$prefs"
touch "$prefs/com.example.slow.plist"

plutil() { return 0; }

execute_optimization fix_broken_configs
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Preference scan hit its time budget"* ]] || return 1
	[[ "$output" != *"All preference files valid"* ]] || return 1
}

@test "opt_cache_refresh reuses measured cache sizes for deletion" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

CALL_LOG="$HOME/cache-refresh.log"
cache_dir="$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
mkdir -p "$cache_dir"
touch "$cache_dir/test.db"

get_path_size_kb() {
    echo "size:$1" >> "$CALL_LOG"
    echo "42"
}
should_protect_path() {
    return 1
}
safe_remove() {
    echo "remove:$1:${3:-missing}" >> "$CALL_LOG"
}

execute_optimization cache_refresh
echo "cleaned=${OPTIMIZE_CACHE_CLEANED_KB:-missing}"
cat "$CALL_LOG"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"QuickLook thumbnails refreshed"* ]] || return 1
	[[ "$output" == *"cleaned=42"* ]] || return 1
	[[ "$output" == *"remove:$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache:42"* ]] || return 1
	[ "$(grep -c "size:$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache" <<< "$output")" -eq 1 ]
}

@test "optimize scans never delete candidates from partial find output" {
	local test_home="$HOME/partial-find-output"
	rm -rf "$test_home"
	mkdir -p "$test_home"
	run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

saved="$HOME/Library/Saved Application State/Partial.savedState"
shared="$HOME/Library/Application Support/com.apple.sharedfilelist/Partial.sfl3"
mkdir -p "$saved" "${shared%/*}"
touch "$shared"
# Both tasks send safe_remove output to /dev/null, so a printed marker would
# never reach $output. Record the call in a file the check below reads.
safe_remove() {
    printf '%s\n' "$1" >> "$HOME/unexpected-removals"
    return 0
}
run_with_timeout() {
    shift
    case "$*" in
        *"Saved Application State"*) printf '%s\0' "$saved" ;;
        *) printf '%s\0' "$shared" ;;
    esac
    return 73
}

optimize_task_start
opt_saved_state_cleanup
optimize_task_finish saved_state_cleanup
optimize_task_start
opt_shared_file_list_repair
optimize_task_finish shared_file_list_repair
[[ ! -e "$HOME/unexpected-removals" ]] || { cat "$HOME/unexpected-removals"; exit 1; }
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	# Both scans really ran and failed, so the empty removal log is not vacuous.
	[[ "$output" == *"Failed to scan old saved states"* ]] || return 1
	[[ "$output" == *"Failed to scan shared file lists"* ]]
}

@test "optimize saved-state cleanup propagates deletion interruption" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

saved="$HOME/Library/Saved Application State/Interrupted.savedState"
mkdir -p "$saved"
run_with_timeout() {
    shift
    printf '%s\0' "$saved"
}
should_protect_path() { return 1; }
safe_remove() { return 130; }
optimize_task_start
rc=0
opt_saved_state_cleanup || rc=$?
printf 'RC=%s\n' "$rc"
[[ $rc -eq 130 ]]
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"RC=130"* ]]
}

@test "opt_quarantine_cleanup reports clean when no database" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization quarantine_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already clean"* ]]
}

@test "opt_quarantine_cleanup reports entries in dry-run" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Stub whitelist check to always allow.
should_protect_path() { return 1; }
# Create a mock quarantine database with entries.
mkdir -p "$HOME/Library/Preferences"
local_db="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
sqlite3 "$local_db" "CREATE TABLE IF NOT EXISTS LSQuarantineEvent (id TEXT);"
sqlite3 "$local_db" "INSERT INTO LSQuarantineEvent VALUES ('test1');"
sqlite3 "$local_db" "INSERT INTO LSQuarantineEvent VALUES ('test2');"
execute_optimization quarantine_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Quarantine history cleared"* ]] || return 1
	[[ "$output" == *"2 entries"* ]]
}

@test "opt_quarantine_cleanup skips when sqlite3 unavailable" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
export PATH="/nonexistent"
execute_optimization quarantine_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"sqlite3 unavailable"* ]]
}

@test "execute_optimization dispatches quarantine_cleanup" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_quarantine_cleanup() { echo "quarantine"; optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"; }
optimize_outcomes_reset
execute_optimization quarantine_cleanup
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"quarantine"* ]]
}

@test "opt_sqlite_vacuum reports sqlite3 unavailable" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
pgrep() { return 1; }
export PATH="/nonexistent"
execute_optimization sqlite_vacuum
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"sqlite3 unavailable"* ]]
}

@test "opt_sqlite_vacuum reports failed when only some databases optimize" {
	run env HOME="$HOME/sqlite-partial" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mkdir -p "$HOME/Library/Messages" "$HOME/Library/Safari"
touch "$HOME/Library/Messages/chat.db" "$HOME/Library/Safari/History.db"
pgrep() { return 1; }
file() { echo "SQLite 3.x database"; }
get_file_size() { echo 1; }
run_with_timeout() {
    shift
    "$@"
}
sqlite3() {
    case "$2" in
        "PRAGMA page_count; PRAGMA freelist_count;") printf '100\n10\n' ;;
        "PRAGMA integrity_check;") echo "ok" ;;
        "VACUUM;") [[ "$1" == *"chat.db" ]] ;;
    esac
}
export -f pgrep file get_file_size run_with_timeout sqlite3

execute_optimization sqlite_vacuum
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Optimized 1 databases"* ]] || return 1
	[[ "$output" == *"Failed on 1 databases"* ]] || return 1
}

@test "opt_sqlite_vacuum reports a failed integrity probe" {
	run env HOME="$HOME/sqlite-integrity" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
db="$HOME/Library/Messages/chat.db"
mkdir -p "$(dirname "$db")"
touch "$db"
pgrep() { return 1; }
file() { echo "SQLite 3.x database"; }
get_file_size() { echo 1; }
run_with_timeout() {
    shift
    if [[ "$3" == "PRAGMA page_count; PRAGMA freelist_count;" ]]; then
        printf '100\n10\n'
        return 0
    fi
    return 7
}
sqlite3() { return 0; }
export -f pgrep file get_file_size run_with_timeout sqlite3

execute_optimization sqlite_vacuum
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed on 1 databases"* ]] || return 1
}

@test "opt_sqlite_vacuum reports oversized databases as skipped" {
	run env HOME="$HOME/sqlite-oversized" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
db="$HOME/Library/Messages/chat.db"
mkdir -p "$(dirname "$db")"
touch "$db"
pgrep() { return 1; }
file() { echo "SQLite 3.x database"; }
get_file_size() { echo $((MOLE_SQLITE_MAX_SIZE + 1)); }
export -f pgrep file get_file_size

execute_optimization sqlite_vacuum
[[ "$(optimize_outcome_count skipped)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Skipped 1 databases over the 100 MB safety limit"* ]] || return 1
}

@test "optimize does not auto-fix Gatekeeper anymore" {
	run grep -n "spctl --master-enable\\|SECURITY_FIXES+=([\"']gatekeeper|" "$PROJECT_ROOT/bin/optimize.sh"

	[ "$status" -eq 1 ]
}

@test "opt_prevent_network_dsstore dry-run reports enabled" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    case "$1" in
        read) return 1 ;;
        write) return 0 ;;
    esac
}
execute_optimization prevent_network_dsstore
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *".DS_Store prevention enabled"* ]]
}

@test "opt_prevent_network_dsstore idempotent when already set" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    if [[ "$1" == "read" ]]; then
        echo "1"
        return 0
    fi
    return 0
}
execute_optimization prevent_network_dsstore
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already enabled"* ]]
}

@test "opt_prevent_network_dsstore reports a partial write failure" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    if [[ "$1" == "read" ]]; then
        return 1
    fi
    [[ "$3" == "DSDontWriteNetworkStores" ]]
}
export -f defaults

execute_optimization prevent_network_dsstore
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *".DS_Store prevention enabled"* ]] || return 1
	[[ "$output" == *"Failed to enable .DS_Store prevention for 1 volume type(s)"* ]] || return 1
}

@test "opt_legacy_overrides_audit stays silent-positive when defaults are in effect" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    if [[ "$1" == "read" ]]; then return 1; fi
    echo "DELETE_CALLED:$*"
    return 0
}
execute_optimization legacy_overrides_audit
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"No legacy App Nap or disk-image overrides found"* ]] || return 1
	[[ "$output" != *"DELETE_CALLED"* ]] || return 1
}

@test "opt_legacy_overrides_audit removes App Nap and skip-verify overrides (#1242 #1243)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    if [[ "$1" == "read" ]]; then
        # -g NSAppSleepDisabled and diskimages skip-verify are overridden;
        # the other skip-verify variants stay at the OS default.
        if [[ "$2" == "-g" && "$3" == "NSAppSleepDisabled" ]]; then echo "1"; return 0; fi
        if [[ "$2" == "com.apple.frameworks.diskimages" && "$3" == "skip-verify" ]]; then echo "1"; return 0; fi
        return 1
    fi
    echo "DELETE_CALLED:$2 $3"
    return 0
}
execute_optimization legacy_overrides_audit
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"DELETE_CALLED:-g NSAppSleepDisabled"* ]] || return 1
	[[ "$output" == *"DELETE_CALLED:com.apple.frameworks.diskimages skip-verify"* ]] || return 1
	[[ "$output" != *"skip-verify-locked"* ]] || return 1
	[[ "$output" == *"Removed override: App Nap disabled globally"* ]] || return 1
	[[ "$output" == *"Removed override: Disk-image verification skipped (skip-verify)"* ]] || return 1
}

@test "opt_legacy_overrides_audit dry-run previews without deleting" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    if [[ "$1" == "read" ]]; then
        if [[ "$2" == "-g" && "$3" == "NSAppSleepDisabled" ]]; then echo "1"; return 0; fi
        return 1
    fi
    echo "DELETE_CALLED:$*"
    return 0
}
execute_optimization legacy_overrides_audit
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Would remove override: App Nap disabled globally"* ]] || return 1
	[[ "$output" != *"DELETE_CALLED"* ]] || return 1
}

@test "opt_legacy_overrides_audit honors plist whitelist before repair" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    if [[ "$1" == "read" ]]; then
        if [[ "$2" == "-g" && "$3" == "NSAppSleepDisabled" ]]; then echo "1"; return 0; fi
        return 1
    fi
    echo "DELETE_CALLED:$*"
    return 0
}
is_path_whitelisted() { [[ "$1" == *".GlobalPreferences.plist" ]]; }
execute_optimization legacy_overrides_audit
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Skipped (whitelisted): App Nap disabled globally"* ]] || return 1
	[[ "$output" != *"DELETE_CALLED"* ]] || return 1
}

@test "opt_legacy_overrides_audit reports failed after a partial repair" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    if [[ "$1" == "read" ]]; then
        echo "1"
        return 0
    fi
    [[ "$3" == "NSAppSleepDisabled" ]]
}
export -f defaults

execute_optimization legacy_overrides_audit
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Removed override: App Nap disabled globally"* ]] || return 1
	[[ "$output" == *"Could not remove override"* ]] || return 1
}

# cc31ee3a ("Remove optimize confirmation prompt, run all tasks automatically")
# flipped every health item to safe=true before V1.34.0. The old "optional"
# expectation outlived that decision only because the assertion sat mid-test and
# could not fail.
@test "prevent_network_dsstore is auto-run and described in optimize health json" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/check/health_json.sh"
json="$(generate_health_json | tr '\n' ' ')"

if printf '%s\n' "$json" | grep -q '"action": "prevent_network_dsstore".*"safe": true'; then
    echo "auto-run"
fi
if printf '%s\n' "$json" | grep -q 'persistent Finder preference'; then
    echo "described"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"auto-run"* ]] || return 1
	[[ "$output" == *"described"* ]]
}

@test "execute_optimization dispatches actions" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_cache_refresh() { echo "cache"; optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"; }
optimize_outcomes_reset
execute_optimization cache_refresh
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"cache"* ]]
}

@test "execute_optimization rejects unknown action" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization unknown_action
EOF

	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"Unknown action"* ]] || return 1
}

@test "execute_optimization rejects unknown action before whitelist policy" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_whitelisted() { return 0; }
execute_optimization unknown_action
EOF

	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown action"* ]]
}

@test "opt_prune_spotlight_orphan_rules removes orphan but keeps system, apple and installed rules" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
PLIST="$HOME/Library/Preferences/com.apple.spotlight.plist"
mkdir -p "$(dirname "$PLIST")"
rm -f "$PLIST"
/usr/libexec/PlistBuddy \
    -c "Add :EnabledPreferenceRules array" \
    -c "Add :EnabledPreferenceRules:0 string System.iphoneApps" \
    -c "Add :EnabledPreferenceRules:1 string com.apple.Safari" \
    -c "Add :EnabledPreferenceRules:2 string com.installed.App" \
    -c "Add :EnabledPreferenceRules:3 string com.lm.william.TwinklingCard" \
    "$PLIST" >/dev/null 2>&1
defaults() {
    case "$1" in
        read) return 0 ;;
        write | delete) echo "DEFAULTS: $*" ;;
    esac
}
bundle_has_installed_app() { [[ "$1" == "com.installed.App" ]]; }
execute_optimization spotlight_orphan_rules_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Removed 1 orphan"* ]] || return 1
	[[ "$output" == *"DEFAULTS: write"* ]] || return 1
	[[ "$output" == *"System.iphoneApps"* ]] || return 1
	[[ "$output" == *"com.apple.Safari"* ]] || return 1
	[[ "$output" == *"com.installed.App"* ]] || return 1
	[[ "$output" != *"com.lm.william.TwinklingCard"* ]]
}

@test "opt_prune_spotlight_orphan_rules dry-run reports but does not write" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
PLIST="$HOME/Library/Preferences/com.apple.spotlight.plist"
mkdir -p "$(dirname "$PLIST")"
rm -f "$PLIST"
/usr/libexec/PlistBuddy \
    -c "Add :EnabledPreferenceRules array" \
    -c "Add :EnabledPreferenceRules:0 string System.iphoneApps" \
    -c "Add :EnabledPreferenceRules:1 string com.lm.william.TwinklingCard" \
    "$PLIST" >/dev/null 2>&1
defaults() {
    case "$1" in
        read) return 0 ;;
        write | delete) echo "DEFAULTS: $*" ;;
    esac
}
bundle_has_installed_app() { return 1; }
execute_optimization spotlight_orphan_rules_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Would remove 1 orphan"* ]] || return 1
	[[ "$output" != *"DEFAULTS: write"* ]] || return 1
	[[ "$output" != *"DEFAULTS: delete"* ]]
}

@test "opt_prune_spotlight_orphan_rules reports clean when every rule still has its app" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
PLIST="$HOME/Library/Preferences/com.apple.spotlight.plist"
mkdir -p "$(dirname "$PLIST")"
rm -f "$PLIST"
/usr/libexec/PlistBuddy \
    -c "Add :EnabledPreferenceRules array" \
    -c "Add :EnabledPreferenceRules:0 string System.iphoneApps" \
    -c "Add :EnabledPreferenceRules:1 string com.apple.Safari" \
    -c "Add :EnabledPreferenceRules:2 string com.installed.App" \
    "$PLIST" >/dev/null 2>&1
defaults() {
    case "$1" in
        read) return 0 ;;
        write | delete) echo "DEFAULTS: $*" ;;
    esac
}
bundle_has_installed_app() { return 0; }
execute_optimization spotlight_orphan_rules_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already clean"* ]] || return 1
	[[ "$output" != *"DEFAULTS: write"* ]]
}

@test "opt_prune_spotlight_orphan_rules propagates an interrupted app resolver" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
PLIST="$HOME/Library/Preferences/com.apple.spotlight.plist"
mkdir -p "$(dirname "$PLIST")"
rm -f "$PLIST"
/usr/libexec/PlistBuddy \
    -c "Add :EnabledPreferenceRules array" \
    -c "Add :EnabledPreferenceRules:0 string com.example.Interrupted" \
    "$PLIST" >/dev/null 2>&1
defaults() {
    case "$1" in
        read) return 0 ;;
        write | delete) echo "UNEXPECTED_WRITE: $*" ;;
    esac
}
bundle_has_installed_app() { return 130; }
rc=0
opt_prune_spotlight_orphan_rules || rc=$?
printf 'RC=%s\n' "$rc"
EOF

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"RC=130"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_WRITE"* ]]
}

@test "Spotlight rules keep the entire array when it changes during app resolution" {
    for change in corrupt append; do
        run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CHANGE="$change" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
PLIST="$HOME/Library/Preferences/com.apple.spotlight.plist"
mkdir -p "${PLIST%/*}"
printf '%s' '<plist version="1.0"><dict><key>EnabledPreferenceRules</key><array><string>com.missing.App</string><string>com.apple.Safari</string></array></dict></plist>' > "$PLIST"
defaults() { case "$1" in read) return 0;; *) echo "UNEXPECTED_WRITE $*";; esac; }
bundle_has_installed_app() {
    if [[ "$CHANGE" == corrupt ]]; then
        printf 'incomplete plist' > "$PLIST"
    else
        /usr/libexec/PlistBuddy -c 'Add :EnabledPreferenceRules: string System.iphoneApps' "$PLIST"
    fi
    return 1
}
execute_optimization spotlight_orphan_rules_cleanup
EOF
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" != *"UNEXPECTED_WRITE"* ]] || return 1
        [[ "$output" != *"Removed 1 orphan"* ]] || return 1
    done
}

@test "Spotlight rules refuse an array containing a non-string before any write" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
PLIST="$HOME/Library/Preferences/com.apple.spotlight.plist"
mkdir -p "${PLIST%/*}"
printf '%s' '<plist version="1.0"><dict><key>EnabledPreferenceRules</key><array><string>com.missing.App</string><dict><key>protected</key><true/></dict></array></dict></plist>' > "$PLIST"
defaults() { case "$1" in read) return 0;; *) echo "UNEXPECTED_WRITE $*";; esac; }
bundle_has_installed_app() { return 1; }
execute_optimization spotlight_orphan_rules_cleanup
EOF
    [ "$status" -eq 0 ]
    [[ "$output" != *"UNEXPECTED_WRITE"* ]] || return 1
}

@test "opt_spotlight_index_optimize reports optimal when probes are fast" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
STUB="$HOME/spotlight-stubs"
mkdir -p "$STUB"
printf '#!/bin/bash\necho "/: Indexing enabled."\n' > "$STUB/mdutil"
printf '#!/bin/bash\necho "mdfind:$*" >> "$HOME/mdfind-calls.log"\nexit 0\n' > "$STUB/mdfind"
chmod +x "$STUB/mdutil" "$STUB/mdfind"
PATH="$STUB:$PATH"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_ac_power() { return 0; }
execute_optimization spotlight_index_optimize
echo "probes=$(wc -l < "$HOME/mdfind-calls.log" | tr -d ' ')"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Spotlight index already optimal"* ]] || return 1
	[[ "$output" == *"probes=2"* ]] || return 1
}

@test "opt_spotlight_index_optimize skips the speed probe on battery" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
STUB="$HOME/spotlight-stubs-battery"
mkdir -p "$STUB"
printf '#!/bin/bash\necho "/: Indexing enabled."\n' > "$STUB/mdutil"
printf '#!/bin/bash\necho "mdfind:$*" >> "$HOME/mdfind-battery.log"\nexit 0\n' > "$STUB/mdfind"
chmod +x "$STUB/mdutil" "$STUB/mdfind"
PATH="$STUB:$PATH"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_ac_power() { return 1; }
execute_optimization spotlight_index_optimize
[[ -f "$HOME/mdfind-battery.log" ]] && echo "probed" || echo "no-probe"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Spotlight index already optimal"* ]] || return 1
	[[ "$output" == *"no-probe"* ]] || return 1
}

@test "opt_spotlight_index_optimize dry-run reports rebuild when probes are slow" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 MOLE_OPTIMIZE_SPOTLIGHT_SLOW_SEC=-1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
STUB="$HOME/spotlight-stubs-slow"
mkdir -p "$STUB"
printf '#!/bin/bash\necho "/: Indexing enabled."\n' > "$STUB/mdutil"
printf '#!/bin/bash\nexit 0\n' > "$STUB/mdfind"
chmod +x "$STUB/mdutil" "$STUB/mdfind"
PATH="$STUB:$PATH"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_ac_power() { return 0; }
execute_optimization spotlight_index_optimize
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Spotlight index rebuild started"* ]] || return 1
}

@test "opt_prune_spotlight_orphan_rules reports clean when rules key is absent" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() { return 1; }
execute_optimization spotlight_orphan_rules_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already clean"* ]]
}

@test "execute_optimization dispatches spotlight_orphan_rules_cleanup" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_prune_spotlight_orphan_rules() { echo "pruned"; optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"; }
optimize_outcomes_reset
execute_optimization spotlight_orphan_rules_cleanup
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"pruned"* ]]
}

@test "opt_launch_agents_cleanup reports healthy when no directory" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Launch Agents all healthy"* ]]
}

@test "opt_launch_agents_cleanup reports broken agents and leaves them in place" {
	# launchctl is a PATH stub rather than a shell function: run_with_timeout
	# execs an external timeout binary that never sees shell functions, so a
	# function mock could not observe a reintroduced unload. Real mode, not
	# dry-run, because the removed unload path returned early under dry-run.
	local stub_dir="$HOME/launchctl-stub-bin"
	local trace="$HOME/launchctl.trace"
	mkdir -p "$stub_dir"
	rm -f "$trace"
	printf '#!/bin/bash\necho "$*" >> "%s"\n' "$trace" > "$stub_dir/launchctl"
	chmod +x "$stub_dir/launchctl"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stub_dir:$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Create mock LaunchAgents with a broken binary reference.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.test.broken.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.test.broken</string>
    <key>ProgramArguments</key>
    <array>
        <string>/nonexistent/binary</string>
    </array>
</dict>
</plist>
PLIST
# The audit must never unload or remove the agent (#1617).
safe_remove() { echo "SAFE_REMOVE $1"; return 0; }
execute_optimization launch_agents_cleanup
[[ -f "$HOME/Library/LaunchAgents/com.test.broken.plist" ]] || { echo "PLIST_GONE"; exit 1; }
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Launch Agent com.test.broken: program missing at /nonexistent/binary"* ]] || return 1
	[[ "$output" == *"left in ~/Library/LaunchAgents"* ]] || return 1
	[[ "$output" != *"SAFE_REMOVE"* ]] || return 1
	[[ ! -s "$trace" ]] || { cat "$trace"; return 1; }
	[[ "$output" != *"Cleaned"* ]]
}

@test "opt_launch_agents_cleanup prioritizes Program over ProgramArguments" {
	local stub_dir="$HOME/launchctl-stub-bin"
	local trace="$HOME/launchctl.trace"
	mkdir -p "$stub_dir"
	rm -f "$trace"
	printf '#!/bin/bash\necho "$*" >> "%s"\n' "$trace" > "$stub_dir/launchctl"
	chmod +x "$stub_dir/launchctl"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$stub_dir:$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.test.program.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.test.program</string>
    <key>Program</key>
    <string>/nonexistent/program_binary</string>
    <key>ProgramArguments</key>
    <array>
        <string>program_binary</string>
    </array>
</dict>
</plist>
PLIST
execute_optimization launch_agents_cleanup
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"Launch Agent com.test.program: program missing at /nonexistent/program_binary"* ]] || return 1
	[[ "$output" == *"left in ~/Library/LaunchAgents"* ]] || return 1
}

@test "opt_launch_agents_cleanup skips healthy agents" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Clean up any leftover plists from previous tests.
rm -f "$HOME/Library/LaunchAgents"/*.plist 2>/dev/null || true
# Create mock LaunchAgent pointing to an existing binary.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.test.healthy.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.test.healthy</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
    </array>
</dict>
</plist>
PLIST
execute_optimization launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Launch Agents all healthy"* ]]
}

@test "opt_launch_agents_cleanup spares agents on unmounted volumes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Clean up any leftover plists from previous tests.
rm -f "$HOME/Library/LaunchAgents"/*.plist 2>/dev/null || true
# A program on an unplugged /Volumes/<disk> is missing but not broken;
# the volume is simply unmounted, so the agent must be left alone.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.test.external.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.test.external</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Volumes/MoleNonexistentDisk/tool</string>
    </array>
</dict>
</plist>
PLIST
execute_optimization launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Launch Agents all healthy"* ]]
}

@test "execute_optimization dispatches launch_agents_cleanup" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_launch_agents_cleanup() { echo "launch_agents"; optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"; }
optimize_outcomes_reset
execute_optimization launch_agents_cleanup
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"launch_agents"* ]]
}

@test "opt_periodic_maintenance reports current when log is fresh" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
tmplog="$(mktemp /tmp/mole-test-daily.XXXXXX)"
touch "$tmplog"
MOLE_PERIODIC_LOG="$tmplog" execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count unchanged)" == "1" ]] || exit 1
rm -f "$tmplog"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already current"* ]]
}

@test "opt_periodic_maintenance ignores non-BSD stat earlier in PATH" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
tmpdir="$(mktemp -d /tmp/mole-test-stat-path.XXXXXX)"
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/stat" <<'STAT'
#!/usr/bin/env bash
echo "  File: /var/log/daily.out"
STAT
chmod +x "$tmpdir/bin/stat"
tmplog="$tmpdir/daily.out"
touch "$tmplog"
PATH="$tmpdir/bin:$PATH" MOLE_PERIODIC_LOG="$tmplog" execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count unchanged)" == "1" ]] || exit 1
rm -rf "$tmpdir"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already current"* ]] || return 1
	[[ "$output" != *"unbound variable"* ]]
}

@test "opt_periodic_maintenance triggers in dry-run when log is stale" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
tmplog="$(mktemp /tmp/mole-test-daily.XXXXXX)"
touch -t "$(date -v-10d +%Y%m%d%H%M.%S)" "$tmplog"
MOLE_PERIODIC_LOG="$tmplog" execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
rm -f "$tmplog"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Periodic maintenance triggered"* ]]
}

@test "opt_periodic_maintenance triggers in dry-run when log is missing" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
MOLE_PERIODIC_LOG="/tmp/mole-test-nonexistent-daily.out" execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Periodic maintenance triggered"* ]]
}

@test "opt_periodic_maintenance reports skipped without admin access" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
MOLE_PERIODIC_LOG="$HOME/missing-daily.out" execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count skipped)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Periodic maintenance skipped (requires sudo)"* ]] || return 1
}

@test "opt_periodic_maintenance reports command failure" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=0 MOLE_TEST_MODE=0 MOLE_OPTIMIZE_SUDO_AVAILABLE=true /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
sudo() { return 7; }
export -f periodic sudo
MOLE_PERIODIC_LOG="$HOME/missing-daily.out" execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed to run periodic maintenance (exit=7)"* ]] || return 1
}

@test "opt_disk_verify reports a timed out probe as failed" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ENABLE_DISK_VERIFY=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
run_with_timeout() { return 124; }

execute_optimization disk_verify
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count unchanged)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Disk verification timed out"* ]] || return 1
}

@test "opt_network_stack_optimize reports a partial flush failure" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/bin"
printf '#!/bin/bash\nexit 1\n' > "$HOME/bin/route"
printf '#!/bin/bash\nexit 1\n' > "$HOME/bin/dscacheutil"
chmod +x "$HOME/bin/route" "$HOME/bin/dscacheutil"
PATH="$HOME/bin:$PATH"
optimize_sudo_available() { return 0; }
sudo() {
    if [[ "$1" == "route" ]]; then
        return 0
    fi
    return 7
}
export -f optimize_sudo_available sudo

execute_optimization network_stack_optimize
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Network routing table refreshed"* ]] || return 1
	[[ "$output" == *"Network stack refresh incomplete (1 operation(s) failed)"* ]] || return 1
}

@test "run_optimize_diagnostics flags sustained CloudShell as primary bottleneck" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'120 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-capture\n35 /usr/libexec/syspolicyd\n20 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'140 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-processor\n30 /usr/libexec/syspolicyd\n18 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Likely bottleneck: CloudShell / AliEntSafe"* ]] || return 1
	[[ "$output" == *"Mole will not terminate enterprise security processes"* ]]
}

@test "run_optimize_diagnostics treats CoreSimulator images as informational for syspolicyd" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'55 /usr/libexec/syspolicyd\n12 /usr/libexec/diskimagesiod' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'60 /usr/libexec/syspolicyd\n10 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		MOLE_OPTIMIZE_SPCTL_STATUS="assessments enabled" \
		MOLE_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/example.asset/AssetData/Restore/000.dmg\n/dev/disk8s1\t/Library/Developer/CoreSimulator/Volumes/iOS_23E244\n' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Likely bottleneck: syspolicyd"* ]] || return 1
	[[ "$output" == *"Gatekeeper status: assessments enabled"* ]] || return 1
	[[ "$output" == *"Only system-managed CoreSimulator images are mounted"* ]] || return 1
	[[ "$output" != *"assessment overhead:"* ]]
}

@test "run_optimize_diagnostics suppresses one-off CPU spikes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'180 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-capture' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'5 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-capture' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"No sustained high-CPU bottleneck detected"* ]]
}

@test "run_optimize_diagnostics offers user-mounted images under syspolicyd pressure in dry-run" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'55 /usr/libexec/syspolicyd' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'60 /usr/libexec/syspolicyd' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		MOLE_OPTIMIZE_SPCTL_STATUS="assessments enabled" \
		MOLE_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /Users/test/Downloads/TestInstaller.dmg\n/dev/disk14s1\t/Volumes/Test Installer\n' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Likely bottleneck: syspolicyd"* ]] || return 1
	[[ "$output" == *"Mounted image adds assessment overhead:"* ]] || return 1
	[[ "$output" == *"TestInstaller.dmg"* ]] || return 1
	[[ "$output" == *"/Volumes/Test Installer"* ]] || return 1
	[[ "$output" == *"Would offer detach for 1 mounted image"* ]]
}

@test "run_optimize_diagnostics keeps healthy runs quiet even with user-mounted images" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'1 /usr/sbin/distnoted' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'1 /usr/sbin/distnoted' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		MOLE_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /Users/test/Downloads/TestInstaller.dmg\n/dev/disk14s1\t/Volumes/Test Installer\n' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"No sustained high-CPU bottleneck detected"* ]] || return 1
	[[ "$output" != *"assessment overhead:"* ]] || return 1
	[[ "$output" != *"Would offer detach"* ]] || return 1
	[[ "$output" != *"/Volumes/Test Installer"* ]]
}

@test "run_optimize_diagnostics skips protected mounted images" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'55 /usr/libexec/syspolicyd' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'60 /usr/libexec/syspolicyd' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		MOLE_OPTIMIZE_SPCTL_STATUS="assessments enabled" \
		MOLE_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /Users/test/Downloads/KeepMe.dmg\n/dev/disk15s1\t/Volumes/KeepMe\n' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() {
    [[ "$1" == "/Volumes/KeepMe" ]]
}
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Likely bottleneck: syspolicyd"* ]] || return 1
	[[ "$output" != *"assessment overhead:"* ]] || return 1
	[[ "$output" != *"Would offer detach"* ]]
}

@test "run_optimize_diagnostics honors optimize whitelist paths for mounted images (#977)" {
	mkdir -p "$HOME/.config/mole"
	cat > "$HOME/.config/mole/whitelist_optimize" <<'EOF'
system_maintenance
/Volumes/EXT3/Mail/TB.dmg
/Volumes/mail
EOF

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'55 /usr/libexec/syspolicyd' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'60 /usr/libexec/syspolicyd' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		MOLE_OPTIMIZE_SPCTL_STATUS="assessments enabled" \
		MOLE_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /Volumes/EXT3/Mail/TB.dmg\n/dev/disk6s2               Apple_HFS                       /Volumes/mail\n' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
load_whitelist optimize
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Likely bottleneck: syspolicyd"* ]] || return 1
	[[ "$output" != *"assessment overhead:"* ]] || return 1
	[[ "$output" != *"Would offer detach"* ]]
}

@test "run_optimize_diagnostics stays quiet when nothing matches" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_OPTIMIZE_PS_SAMPLE_1=$'4 /usr/sbin/distnoted\n3 /usr/libexec/coreaudiod' \
		MOLE_OPTIMIZE_PS_SAMPLE_2=$'5 /usr/sbin/distnoted\n2 /usr/libexec/coreaudiod' \
		MOLE_OPTIMIZE_SWAPUSAGE='total = 8192.00M  used = 100.00M  free = 8092.00M' \
		MOLE_OPTIMIZE_MEM_FREE_SAMPLE=70 \
		MOLE_OPTIMIZE_RSS_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_VM_SAMPLE=$'1000 Finder' \
		MOLE_OPTIMIZE_PROCTIME_SAMPLE=$'1 00:01 05:00 quietd' \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"No sustained high-CPU bottleneck detected"* ]]
}

@test "opt_diag_detach_candidates prints summary line only for multiple images" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
run_with_timeout() { return 0; }
echo "--- single ---"
opt_diag_detach_candidates $'/Users/test/A.dmg\t/Volumes/A'
echo "--- double ---"
opt_diag_detach_candidates $'/Users/test/A.dmg\t/Volumes/A\n/Users/test/B.dmg\t/Volumes/B'
EOF

	[ "$status" -eq 0 ]
	single="${output#*--- single ---}"
	single="${single%%--- double ---*}"
	double="${output#*--- double ---}"
	[[ "$single" == *"Detached /Volumes/A"* ]] || return 1
	[[ "$single" != *"mounted images"* ]] || return 1
	[[ "$double" == *"Detached 2 mounted images"* ]] || return 1
}

@test "opt_diag_offer_detach_candidates renders image paths without terminal escapes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NO_COLOR=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
image_path=$'/Users/test/Bad\\033[2J-\033[2J.dmg'
mount_path=$'/Volumes/Bad\\033[H-\033[H'
MOLE_DRY_RUN=1 opt_diag_offer_detach_candidates "${image_path}"$'\t'"${mount_path}"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *'Bad\033[2J-'* ]] || return 1
	[[ "$output" == *'/Volumes/Bad\033[H-'* ]] || return 1
	[[ "$output" != *$'\033[2J'* ]] || return 1
	[[ "$output" != *$'\033[H'* ]]
}

@test "opt_diag_detach_candidates renders result paths without terminal escapes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NO_COLOR=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
run_with_timeout() {
	shift
	shift
	shift
	[[ "$1" == *Success* ]]
}
success_mount=$'/Volumes/Success\\033[2J-\033[2J'
failed_mount=$'/Volumes/Failed\\033[H-\033[H'
candidates="/tmp/one.dmg"$'\t'"$success_mount"$'\n'"/tmp/two.dmg"$'\t'"$failed_mount"
opt_diag_detach_candidates "$candidates"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *'Detached /Volumes/Success\033[2J-'* ]] || return 1
	[[ "$output" == *'Failed to detach /Volumes/Failed\033[H-'* ]] || return 1
	[[ "$output" != *$'\033[2J'* ]] || return 1
	[[ "$output" != *$'\033[H'* ]]
}

@test "opt_periodic_maintenance skips when periodic command missing" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
command() {
    if [[ "$1" == "-v" && "$2" == "periodic" ]]; then
        return 1
    fi
    builtin command "$@"
}
export -f command
execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count unavailable)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Periodic maintenance skipped (not available on this macOS version)"* ]]
}

@test "execute_optimization dispatches periodic_maintenance" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_periodic_maintenance() { echo "periodic"; optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"; }
optimize_outcomes_reset
execute_optimization periodic_maintenance
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"periodic"* ]]
}

@test "execute_optimization skips whitelisted task ids" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_whitelisted() { [[ "$1" == "cache_refresh" ]]; }
opt_cache_refresh() { echo "UNEXPECTED_CACHE"; }
optimize_outcomes_reset
execute_optimization cache_refresh
[[ "$(optimize_outcome_count skipped)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped (whitelisted): Finder Cache Refresh"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_CACHE"* ]]
}

@test "optimize whitelist is loaded before system health checks" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
load_line=$(awk '/load_whitelist "optimize"/ { print NR; exit }' "$PROJECT_ROOT/bin/optimize.sh")
health_line=$(awk '/^[[:space:]]*show_system_health / { print NR; exit }' "$PROJECT_ROOT/bin/optimize.sh")
if [[ "$load_line" -lt "$health_line" ]]; then
    echo "ordered"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ordered"* ]]
}

@test "optimize interrupt cleanup disables the EXIT trap before cleanup" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
body=$(sed -n '/^handle_interrupt() {/,/^}/p' "$PROJECT_ROOT/bin/optimize.sh")
trap_line=$(printf '%s\n' "$body" | awk '/trap - EXIT/ { print NR; exit }')
cleanup_line=$(printf '%s\n' "$body" | awk '/^[[:space:]]*cleanup_all 130$/ { print NR; exit }')
[[ -n "$trap_line" && -n "$cleanup_line" && "$trap_line" -lt "$cleanup_line" ]]
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "show_system_health formats floats under comma-decimal locales (#1220)" {
	# Find an installed locale whose decimal separator is a comma.
	local comma_locale="" candidate
	for candidate in fr_FR.UTF-8 de_DE.UTF-8 pt_BR.UTF-8 es_ES.UTF-8 it_IT.UTF-8 nl_NL.UTF-8; do
		if [[ "$(LC_ALL="$candidate" /bin/bash -c 'printf "%.1f" 1' 2> /dev/null)" == "1,0" ]]; then
			comma_locale="$candidate"
			break
		fi
	done
	[[ -n "$comma_locale" ]] || skip "no comma-decimal locale installed"

	run env LC_ALL="$comma_locale" LANG="$comma_locale" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^json_get_value()/,/^}$/p' "$PROJECT_ROOT/bin/optimize.sh")"
eval "$(sed -n '/^show_system_health()/,/^}$/p' "$PROJECT_ROOT/bin/optimize.sh")"
ICON_ADMIN="*"
health_json='{"memory_used_gb": 5.70, "memory_total_gb": 8.00, "disk_used_gb": 287.86, "disk_total_gb": 351.19, "uptime_days": 6.1}'
show_system_health "$health_json"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"6/8 GB RAM"* ]] || return 1
	[[ "$output" == *"288/351 GB Disk"* ]] || return 1
	[[ "$output" == *"Uptime 6d"* ]]
}

@test "optimize whitelist items include task ids" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_optimize_whitelist_items
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Permission Repair|disk_permissions_repair|optimize_task"* ]] || return 1
	[[ "$output" == *"Login Items Audit|login_items_audit|optimize_task"* ]] || return 1
	[[ "$output" == *"Legacy Overrides|legacy_overrides_audit|optimize_task"* ]] || return 1
}

# Login-item matching fixtures must not scan apps installed on the test host.
setup_login_item_fixture() {
	HOME="$HOME/login-item-$BATS_TEST_NUMBER"
	export HOME
	mkdir -p "$HOME/bin"
	printf '#!/bin/bash\nexit 1\n' > "$HOME/bin/mdfind"
	cat > "$HOME/bin/find" <<'EOF'
#!/bin/bash
case "$1" in
    "$HOME"/*) exec /usr/bin/find "$@" ;;
    *) exit 0 ;;
esac
EOF
	chmod +x "$HOME/bin/mdfind" "$HOME/bin/find"
	export PATH="$HOME/bin:$PATH"
}

@test "_login_item_app_exists finds nested helper app bundles" {
	setup_login_item_fixture
	local helper="$HOME/Applications/Roon.app/Contents/RoonServer.app"
	mkdir -p "$helper"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
if _login_item_app_exists "RoonServer"; then
    echo "found"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"found"* ]]
}

@test "_login_item_app_exists finds nested mixed-case app bundles" {
	setup_login_item_fixture
	local helper="$HOME/Applications/Roon.APP/Contents/RoonServer.APP"
	mkdir -p "$helper"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
if _login_item_app_exists "RoonServer"; then
    echo "found"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"found"* ]]
}

@test "_login_item_app_exists finds nested helper apps by bundle display name" {
	setup_login_item_fixture
	local helper="$HOME/Applications/Adobe Acrobat DC.app/Contents/Helpers/AdobeResourceSynchronizer.app"
	mkdir -p "$helper/Contents"
	cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Acrobat Collaboration Synchronizer</string>
    <key>CFBundleName</key>
    <string>AdobeResourceSynchronizer</string>
</dict>
</plist>
PLIST

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
if _login_item_app_exists "Acrobat Collaboration Synchronizer"; then
    echo "found"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"found"* ]]
}

@test "_login_item_app_exists trusts an existing System Events login item path" {
	setup_login_item_fixture
	local helper="$HOME/Applications/Adobe Acrobat DC.app/Contents/Helpers/AdobeResourceSynchronizer.app"
	mkdir -p "$helper"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MO_DEBUG=1 HELPER_PATH="$helper" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
if _login_item_app_exists "Acrobat Collaboration Synchronizer" "$HELPER_PATH" 2>&1; then
    echo "found"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"found"* ]] || return 1
	[[ "$output" == *"resolved by login item path"* ]]
}

@test "optimize_sudo_available returns false when sudo session was denied" {
	run env PROJECT_ROOT="$PROJECT_ROOT" MOLE_OPTIMIZE_SUDO_AVAILABLE="false" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
if optimize_sudo_available; then
	echo "WRONG: returned true under denied sudo"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "optimize_sudo_available returns false in test mode regardless of optimize entrypoint" {
	# Ad-hoc task invocation under MOLE_TEST_NO_AUTH must hard-deny sudo
	# even when MOLE_OPTIMIZE_SUDO_AVAILABLE was never set by bin/optimize.sh.
	run env PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_OPTIMIZE_SUDO_AVAILABLE
if optimize_sudo_available; then
	echo "WRONG: leaked sudo to test-mode caller"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "flush_dns_cache does not invoke sudo under MOLE_TEST_NO_AUTH" {
	# Reproduces the reported regression: ad-hoc flush_dns_cache under test
	# mode used to fall through optimize_sudo_available and reach `sudo dscacheutil`.
	# Pin "no VPN": on a host routing through utun the VPN gate would return
	# first and this test would pass without reaching the sudo guard.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_OPTIMIZE_SUDO_AVAILABLE
trace="$HOME/sudo_calls.log"
: > "$trace"
sudo() {
	printf 'SUDO_CALLED:%s\n' "$*" >> "$trace"
	return 0
}
export -f sudo

flush_dns_cache 2>&1 || true

if [[ -s "$trace" ]]; then
	echo "WRONG: sudo invoked under test mode:"
	cat "$trace"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "sudo-required optimize tasks short-circuit without invoking sudo when access denied" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_OPTIMIZE_SUDO_AVAILABLE="false" \
		MOLE_DRY_RUN="0" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

trace="$HOME/sudo_calls.log"
: > "$trace"
sudo() {
	printf 'sudo %s\n' "$*" >> "$trace"
	return 0
}
export -f sudo

# Force the "needs work" branch so each task reaches its sudo block.
needs_permissions_repair() { return 0; }
has_active_vpn_interface() { return 1; }
route() { return 1; }
dscacheutil() { return 1; }
mdutil() { echo "Indexing enabled."; }
mdfind() { sleep 4; }
get_epoch_seconds() { date +%s; }
is_ac_power() { return 0; }
pgrep() { return 1; }
system_profiler() { return 1; }
plutil() { return 1; }
defaults() { return 1; }
get_path_size_kb() { echo "0"; }
debug_log() { :; }
opt_msg() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }

execute_optimization network_stack_optimize 2>&1 || true
execute_optimization disk_permissions_repair 2>&1 || true
execute_optimization periodic_maintenance 2>&1 || true
flush_dns_cache 2>&1 || true

if [[ -s "$trace" ]]; then
	echo "WRONG: sudo invoked while denied:"
	cat "$trace"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "opt_diag_parse_image_mount_pairs ignores image-alias/icon-path lines (#960)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"

# Sample hdiutil info block reproducing the issue from #960. The image-alias
# line carries an absolute path identical to image-path, which the previous
# extract_mount regex incorrectly accepted as a mount point. Only the
# /dev/disk* line is a real mount.
sample=$(cat <<'HDIUTIL'
================================================
image-path                 : /Volumes/EXT3/Mail/TB.dmg
image-alias                : /Volumes/EXT3/Mail/TB.dmg
shadow-path                : <none>
icon-path                  : /System/Library/PrivateFrameworks/DiskImages.framework/Resources/CDiskImage.icns
image-type                 : read-only
/dev/disk6                 Apple_partition_scheme
/dev/disk6s1               Apple_partition_map
/dev/disk6s2               Apple_HFS                       /Volumes/mail
HDIUTIL
)

opt_diag_parse_image_mount_pairs "$sample"
EOF

	[ "$status" -eq 0 ]
	# Expect exactly one pair: image=/Volumes/EXT3/Mail/TB.dmg mount=/Volumes/mail
	line_count=$(printf '%s\n' "$output" | awk 'NF' | wc -l | tr -d ' ')
	[ "$line_count" = "1" ]
	[[ "$output" == *"/Volumes/EXT3/Mail/TB.dmg"$'\t'"/Volumes/mail"* ]] || return 1
	# Critical regression guard: image-alias line must not surface as a mount.
	[[ "$output" != *"/Volumes/EXT3/Mail/TB.dmg"$'\t'"/Volumes/EXT3/Mail/TB.dmg"* ]]
}

@test "has_active_vpn_interface respects MOLE_ASSUME_VPN_ACTIVE override" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Force scutil/route to fail loudly so the env override is the only path.
scutil() { echo "should not be called" >&2; return 1; }
route() { echo "should not be called" >&2; return 1; }
export -f scutil route
if has_active_vpn_interface; then echo "vpn"; else echo "no_vpn"; fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"vpn"* ]] || return 1
	[[ "$output" != *"no_vpn"* ]] || return 1
	[[ "$output" != *"should not be called"* ]]
}

@test "has_active_vpn_interface returns false when MOLE_ASSUME_VPN_ACTIVE=0" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_ASSUME_VPN_ACTIVE=0 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# scutil/route should not run when env says no.
scutil() { echo "should not be called" >&2; return 1; }
route() { echo "should not be called" >&2; return 1; }
export -f scutil route
if has_active_vpn_interface; then echo "vpn"; else echo "no_vpn"; fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"no_vpn"* ]] || return 1
	[[ "$output" != *"should not be called"* ]]
}

@test "has_active_vpn_interface detects scutil Connected entry" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mock_bin="$HOME/vpn-connected-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/scutil" <<'MOCK'
#!/bin/bash
cat <<'OUTPUT'
* (Disconnected)   AA1B2C3D-1111-2222-3333-444455556666   PPP     (L2TP)         "Office VPN"   [L2TP]
* (Connected)      87654321-aaaa-bbbb-cccc-dddddddddddd   IPSec   (IKEv2)        "Remote Office"[IKEv2]
OUTPUT
MOCK
# Default route should NOT be consulted once scutil already proved a VPN active.
printf '#!/bin/bash\ntouch "$HOME/route-called"\nexit 1\n' > "$mock_bin/route"
chmod +x "$mock_bin/scutil" "$mock_bin/route"
PATH="$mock_bin:$PATH"
if has_active_vpn_interface; then echo "vpn"; else echo "no_vpn"; fi
[[ ! -e "$HOME/route-called" ]] || echo "should not be called"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"vpn"* ]] || return 1
	[[ "$output" != *"no_vpn"* ]] || return 1
	[[ "$output" != *"should not be called"* ]]
}

@test "has_active_vpn_interface ignores scutil entries that are all Disconnected" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mock_bin="$HOME/vpn-disconnected-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/scutil" <<'MOCK'
#!/bin/bash
cat <<'OUTPUT'
* (Disconnected)   AA1B2C3D-1111-2222-3333-444455556666   PPP     (L2TP)         "Office VPN"   [L2TP]
* (Disconnected)   87654321-aaaa-bbbb-cccc-dddddddddddd   IPSec   (IKEv2)        "Remote Office"[IKEv2]
OUTPUT
MOCK
# Default route via en0 (no VPN). This is the user's case in #959.
printf '%s\n' '#!/bin/bash' 'echo "  interface: en0"' > "$mock_bin/route"
chmod +x "$mock_bin/scutil" "$mock_bin/route"
PATH="$mock_bin:$PATH"
if has_active_vpn_interface; then echo "vpn"; else echo "no_vpn"; fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"no_vpn"* ]]
}

@test "has_active_vpn_interface detects full-tunnel via utun default route" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# No system-managed VPN configured in scutil.
mock_bin="$HOME/vpn-full-tunnel-bin"
mkdir -p "$mock_bin"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$mock_bin/scutil"
# Default route owned by utun3 -> full-tunnel VPN (WireGuard / OpenVPN style).
printf '%s\n' '#!/bin/bash' 'echo "  interface: utun3"' > "$mock_bin/route"
chmod +x "$mock_bin/scutil" "$mock_bin/route"
PATH="$mock_bin:$PATH"
if has_active_vpn_interface; then echo "vpn"; else echo "no_vpn"; fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"vpn"* ]] || return 1
	[[ "$output" != *"no_vpn"* ]]
}

@test "has_active_vpn_interface returns false for iCloud Private Relay style utun (#959)" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
# Private Relay / Continuity create utun* but the default route stays on en0.
# The old netstat/ifconfig probe would have false-positived this; the new
# probe must not.
mock_bin="$HOME/vpn-private-relay-bin"
mkdir -p "$mock_bin"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$mock_bin/scutil"
printf '%s\n' '#!/bin/bash' 'echo "  interface: en0"' > "$mock_bin/route"
chmod +x "$mock_bin/scutil" "$mock_bin/route"
PATH="$mock_bin:$PATH"
if has_active_vpn_interface; then echo "vpn"; else echo "no_vpn"; fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"no_vpn"* ]]
}

@test "opt_diag_parse_image_mount_pairs handles multiple blocks" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"

sample=$(cat <<'HDIUTIL'
================================================
image-path                 : /Users/test/Sample.dmg
image-alias                : /Users/test/Sample.dmg
/dev/disk5s2               Apple_HFS                       /Volumes/Sample
================================================
image-path                 : /Library/Developer/CoreSimulator/Volumes/iOS_17.dmg
image-alias                : /Library/Developer/CoreSimulator/Volumes/iOS_17.dmg
/dev/disk7s1               Apple_APFS                      /Library/Developer/CoreSimulator/Volumes/iOS_17.0
HDIUTIL
)

opt_diag_parse_image_mount_pairs "$sample" | awk 'NF' | sort
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"/Users/test/Sample.dmg"$'\t'"/Volumes/Sample"* ]] || return 1
	[[ "$output" == *"/Library/Developer/CoreSimulator/Volumes/iOS_17.dmg"$'\t'"/Library/Developer/CoreSimulator/Volumes/iOS_17.0"* ]] || return 1
	line_count=$(printf '%s\n' "$output" | awk 'NF' | wc -l | tr -d ' ')
	[ "$line_count" = "2" ]
}

@test "has_active_vpn_interface treats a missing default route as no VPN" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mock_bin="$HOME/vpn-offline-bin"
mkdir -p "$mock_bin"
printf '#!/bin/bash\necho "* (Disconnected)   AA1B2C3D-1111-2222-3333-444455556666   PPP     (L2TP)         \\"Office VPN\\"   [L2TP]"\n' > "$mock_bin/scutil"
printf '#!/bin/bash\necho "route: writing to routing socket: not in table" >&2\nexit 1\n' > "$mock_bin/route"
chmod +x "$mock_bin/scutil" "$mock_bin/route"
PATH="$mock_bin:$PATH"
status=0
has_active_vpn_interface || status=$?
echo "probe=$status"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"probe=1"* ]]
}

@test "has_active_vpn_interface keeps other route failures unknown" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mock_bin="$HOME/vpn-route-error-bin"
mkdir -p "$mock_bin"
printf '#!/bin/bash\necho "* (Disconnected)   AA1B2C3D-1111-2222-3333-444455556666   PPP     (L2TP)         \\"Office VPN\\"   [L2TP]"\n' > "$mock_bin/scutil"
printf '#!/bin/bash\necho "route: socket: Operation not permitted" >&2\nexit 1\n' > "$mock_bin/route"
chmod +x "$mock_bin/scutil" "$mock_bin/route"
PATH="$mock_bin:$PATH"
status=0
has_active_vpn_interface || status=$?
echo "probe=$status"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"probe=2"* ]]
}
