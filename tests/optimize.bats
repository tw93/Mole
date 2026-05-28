#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize.XXXXXX")"
	export HOME

	mkdir -p "$HOME"
}

teardown_file() {
	rm -rf "$HOME"
	if [[ -n "${ORIGINAL_HOME:-}" ]]; then
		export HOME="$ORIGINAL_HOME"
	fi
}

@test "needs_permissions_repair returns true when home not writable" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" USER="tester" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
stat() { echo "root"; }
export -f stat
if needs_permissions_repair; then
    echo "needs"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"needs"* ]]
}

@test "has_bluetooth_hid_connected detects HID" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
system_profiler() {
    cat << 'OUT'
Bluetooth:
  Apple Magic Mouse:
    Connected: Yes
    Type: Mouse
OUT
}
export -f system_profiler
if has_bluetooth_hid_connected; then
    echo "hid"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"hid"* ]]
}

@test "is_ac_power detects AC power" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

@test "is_memory_pressure_high detects warning" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
memory_pressure() { echo "warning"; }
export -f memory_pressure
if is_memory_pressure_high; then
    echo "high"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"high"* ]]
}

@test "opt_system_maintenance reports DNS and Spotlight" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
flush_dns_cache() { return 0; }
mdutil() { echo "Indexing enabled."; }
opt_system_maintenance
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"DNS cache flushed"* ]]
	[[ "$output" == *"Spotlight index verified"* ]]
}

@test "opt_network_optimization refreshes DNS" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
flush_dns_cache() { return 0; }
opt_network_optimization
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"DNS cache refreshed"* ]]
	[[ "$output" == *"mDNSResponder restarted"* ]]
}

@test "fix_broken_preferences repairs only non-Apple preference plists" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
	[[ "$output" == *"count=3"* ]]
	[[ "$output" == *"remove:$HOME/Library/Preferences/com.example.broken.plist"* ]]
	[[ "$output" == *"remove:$HOME/Library/Preferences/ByHost/com.example.byhost.plist"* ]]
	[[ "$output" == *"remove:$HOME/Library/Preferences/ByHost/loginwindow.plist"* ]]
	[[ "$output" != *"lint:$HOME/Library/Preferences/com.apple.broken.plist"* ]]
	[[ "$output" != *"lint:$HOME/Library/Preferences/loginwindow.plist"* ]]
}

@test "opt_cache_refresh reuses measured cache sizes for deletion" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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

opt_cache_refresh
echo "cleaned=${OPTIMIZE_CACHE_CLEANED_KB:-missing}"
cat "$CALL_LOG"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"QuickLook thumbnails refreshed"* ]]
	[[ "$output" == *"cleaned=42"* ]]
	[[ "$output" == *"remove:$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache:42"* ]]
	[ "$(grep -c "size:$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache" <<< "$output")" -eq 1 ]
}

@test "opt_quarantine_cleanup reports clean when no database" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_quarantine_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already clean"* ]]
}

@test "opt_quarantine_cleanup reports entries in dry-run" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
opt_quarantine_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Quarantine history cleared"* ]]
	[[ "$output" == *"2 entries"* ]]
}

@test "opt_quarantine_cleanup refuses symlinked database path" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mkdir -p "$HOME/Library/Preferences"
protected_db="$HOME/protected-quarantine.sqlite"
quarantine_db="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
sqlite3 "$protected_db" "CREATE TABLE IF NOT EXISTS LSQuarantineEvent (id TEXT);"
sqlite3 "$protected_db" "DELETE FROM LSQuarantineEvent;"
sqlite3 "$protected_db" "INSERT INTO LSQuarantineEvent VALUES ('keep');"
ln -sf "$protected_db" "$quarantine_db"

opt_quarantine_cleanup
echo "rows=$(sqlite3 "$protected_db" "SELECT COUNT(*) FROM LSQuarantineEvent;")"
[[ -L "$quarantine_db" ]]
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"redirected database path"* ]]
	[[ "$output" == *"rows=1"* ]]
}

@test "opt_quarantine_cleanup skips when sqlite3 unavailable" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
export PATH="/nonexistent"
opt_quarantine_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"sqlite3 unavailable"* ]]
}

@test "execute_optimization dispatches quarantine_cleanup" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_quarantine_cleanup() { echo "quarantine"; }
execute_optimization quarantine_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"quarantine"* ]]
}

@test "opt_sqlite_vacuum reports sqlite3 unavailable" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
export PATH="/nonexistent"
opt_sqlite_vacuum
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"sqlite3 unavailable"* ]]
}

@test "opt_sqlite_vacuum skips symlinked databases" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

CALL_LOG="$HOME/sqlite-vacuum.log"
> "$CALL_LOG"
mkdir -p "$HOME/Library/Messages"
touch "$HOME/protected-chat.db"
ln -sf "$HOME/protected-chat.db" "$HOME/Library/Messages/chat.db"

sqlite3() {
    echo "sqlite:$*" >> "$CALL_LOG"
    return 0
}
pgrep() {
    return 1
}

opt_sqlite_vacuum
cat "$CALL_LOG"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Already optimal for 1 databases"* ]]
	[[ "$output" != *"sqlite:"* ]]
}

@test "opt_font_cache_rebuild succeeds in dry-run" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_font_cache_rebuild
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Font cache cleared"* ]]
}

@test "optimize does not auto-fix Gatekeeper anymore" {
	run grep -n "spctl --master-enable\\|SECURITY_FIXES+=([\"']gatekeeper|" "$PROJECT_ROOT/bin/optimize.sh"

	[ "$status" -eq 1 ]
}

@test "opt_font_cache_rebuild skips when Firefox helpers are running" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
pgrep() {
    case "$*" in
        *"Firefox|org\\.mozilla\\.firefox|firefox .*contentproc|firefox .*plugin-container|firefox .*crashreporter"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
export -f pgrep
opt_font_cache_rebuild
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Font cache rebuild skipped · Firefox still running"* ]]
}

@test "browser_family_is_running does not treat generic renderer helpers as Zen Browser" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
pgrep() {
    case "$*" in
        *"renderer|gpu"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
export -f pgrep
if browser_family_is_running "Zen Browser"; then
    echo "MATCHED"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"MATCHED"* ]]
}

@test "opt_dock_refresh clears cache files" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mkdir -p "$HOME/Library/Application Support/Dock"
touch "$HOME/Library/Application Support/Dock/test.db"
safe_remove() { return 0; }
opt_dock_refresh
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Dock cache cleared"* ]]
	[[ "$output" == *"Dock refreshed"* ]]
}

@test "opt_dock_refresh does not touch symlinked Dock plist" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

rm -rf "$HOME/Library/Preferences"
trap 'rm -rf "$HOME/Library/Preferences"; mkdir -p "$HOME/Library/Preferences"' EXIT
mkdir -p "$HOME/Library/Preferences"
protected_plist="$HOME/protected-dock.plist"
dock_plist="$HOME/Library/Preferences/com.apple.dock.plist"
printf 'keep\n' > "$protected_plist"
touch -t 202001010000 "$protected_plist"
ln -sf "$protected_plist" "$dock_plist"
before=$(stat -f %m "$protected_plist")

killall() { return 0; }
opt_dock_refresh

after=$(stat -f %m "$protected_plist")
echo "mtime=$before:$after"
[[ "$before" == "$after" ]]
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Dock refreshed"* ]]
}

@test "opt_prevent_network_dsstore dry-run reports enabled" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
defaults() {
    case "$1" in
        read) return 1 ;;
        write) return 0 ;;
    esac
}
opt_prevent_network_dsstore
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *".DS_Store prevention enabled"* ]]
}

@test "opt_prevent_network_dsstore skips redirected preferences directory" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

CALL_LOG="$HOME/dsstore-defaults.log"
> "$CALL_LOG"
rm -rf "$HOME/Library/Preferences"
trap 'rm -rf "$HOME/Library/Preferences"; mkdir -p "$HOME/Library/Preferences"' EXIT
mkdir -p "$HOME/Library" "$HOME/redirected-prefs"
ln -sf "$HOME/redirected-prefs" "$HOME/Library/Preferences"

defaults() {
    echo "defaults:$*" >> "$CALL_LOG"
    return 0
}

opt_prevent_network_dsstore
cat "$CALL_LOG"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"redirected preferences path"* ]]
	[[ "$output" != *"defaults:"* ]]
}

@test "opt_prevent_network_dsstore idempotent when already set" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
opt_prevent_network_dsstore
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already enabled"* ]]
}

@test "prevent_network_dsstore is optional in optimize health json" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/check/health_json.sh"
json="$(generate_health_json | tr '\n' ' ')"

if printf '%s\n' "$json" | grep -q '"action": "prevent_network_dsstore".*"safe": false'; then
    echo "optional"
fi
if printf '%s\n' "$json" | grep -q 'persistent Finder preference'; then
    echo "described"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"optional"* ]]
	[[ "$output" == *"described"* ]]
}

@test "execute_optimization dispatches actions" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_dock_refresh() { echo "dock"; }
execute_optimization dock_refresh
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"dock"* ]]
}

@test "execute_optimization rejects unknown action" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization unknown_action
EOF

	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown action"* ]]
}

@test "opt_launch_services_rebuild handles missing lsregister without exiting" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
get_lsregister_path() {
    echo ""
    return 0
}
opt_launch_services_rebuild
echo "survived"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"lsregister not found"* ]]
	[[ "$output" == *"survived"* ]]
}

@test "opt_launch_agents_cleanup reports healthy when no directory" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Launch Agents all healthy"* ]]
}

@test "opt_launch_agents_cleanup detects broken agents" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
safe_remove() { return 0; }
opt_launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Cleaned 1 broken Launch Agent"* ]]
}

@test "opt_launch_agents_cleanup skips healthy agents" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
opt_launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Launch Agents all healthy"* ]]
}

@test "opt_launch_agents_cleanup skips redirected launch agents directory" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

rm -rf "$HOME/Library/LaunchAgents"
trap 'rm -rf "$HOME/Library/LaunchAgents"; mkdir -p "$HOME/Library/LaunchAgents"' EXIT
mkdir -p "$HOME/Library" "$HOME/redirected-launch-agents"
ln -sf "$HOME/redirected-launch-agents" "$HOME/Library/LaunchAgents"

opt_launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"redirected directory"* ]]
}

@test "execute_optimization dispatches launch_agents_cleanup" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_launch_agents_cleanup() { echo "launch_agents"; }
execute_optimization launch_agents_cleanup
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"launch_agents"* ]]
}

@test "opt_periodic_maintenance reports current when log is fresh" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
tmplog="$(mktemp /tmp/roomy-test-daily.XXXXXX)"
touch "$tmplog"
ROOMY_PERIODIC_LOG="$tmplog" opt_periodic_maintenance
rm -f "$tmplog"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"already current"* ]]
}

@test "opt_periodic_maintenance triggers in dry-run when log is stale" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
tmplog="$(mktemp /tmp/roomy-test-daily.XXXXXX)"
touch -t "$(date -v-10d +%Y%m%d%H%M.%S)" "$tmplog"
ROOMY_PERIODIC_LOG="$tmplog" opt_periodic_maintenance
rm -f "$tmplog"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Periodic maintenance triggered"* ]]
}

@test "opt_periodic_maintenance triggers in dry-run when log is missing" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
periodic() { true; }
export -f periodic
ROOMY_PERIODIC_LOG="/tmp/roomy-test-nonexistent-daily.out" opt_periodic_maintenance
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Periodic maintenance triggered"* ]]
}

@test "opt_shared_file_list_repair skips redirected shared file list directory" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

sfl_path="$HOME/Library/Application Support/com.apple.sharedfilelist"
rm -rf "$sfl_path"
trap 'rm -rf "$sfl_path"; mkdir -p "$sfl_path"' EXIT
mkdir -p "$HOME/Library/Application Support" "$HOME/redirected-sfl"
ln -sf "$HOME/redirected-sfl" "$sfl_path"

opt_shared_file_list_repair
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"redirected directory"* ]]
}

@test "opt_notification_cleanup refuses symlinked database path" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

CALL_LOG="$HOME/notification-sqlite.log"
> "$CALL_LOG"
darwin_dir="$HOME/darwin-user-dir"
nc_dir="$darwin_dir/com.apple.notificationcenter/db2"
mkdir -p "$nc_dir"
touch "$HOME/protected-notification.db"
ln -sf "$HOME/protected-notification.db" "$nc_dir/db"

getconf() {
    if [[ "$1" == "DARWIN_USER_DIR" ]]; then
        printf '%s\n' "$darwin_dir"
        return 0
    fi
    command getconf "$@"
}
sqlite3() {
    echo "sqlite:$*" >> "$CALL_LOG"
    return 0
}

opt_notification_cleanup
cat "$CALL_LOG"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"redirected database path"* ]]
	[[ "$output" != *"sqlite:"* ]]
}

@test "opt_coreduet_cleanup refuses symlinked knowledge database path" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

CALL_LOG="$HOME/coreduet-sqlite.log"
> "$CALL_LOG"
knowledge_dir="$HOME/Library/Application Support/Knowledge"
mkdir -p "$knowledge_dir"
touch "$HOME/protected-knowledge.db"
ln -sf "$HOME/protected-knowledge.db" "$knowledge_dir/knowledgeC.db"

sqlite3() {
    echo "sqlite:$*" >> "$CALL_LOG"
    return 0
}

opt_coreduet_cleanup
cat "$CALL_LOG"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"redirected database path"* ]]
	[[ "$output" != *"sqlite:"* ]]
}

@test "run_optimize_diagnostics flags sustained CloudShell as primary bottleneck" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		ROOMY_OPTIMIZE_PS_SAMPLE_1=$'120 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-capture\n35 /usr/libexec/syspolicyd\n20 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer' \
		ROOMY_OPTIMIZE_PS_SAMPLE_2=$'140 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-processor\n30 /usr/libexec/syspolicyd\n18 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer' \
		bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Likely bottleneck: CloudShell / AliEntSafe"* ]]
	[[ "$output" == *"Roomy will not terminate enterprise security processes"* ]]
}

@test "run_optimize_diagnostics treats CoreSimulator images as informational for syspolicyd" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		ROOMY_OPTIMIZE_PS_SAMPLE_1=$'55 /usr/libexec/syspolicyd\n12 /usr/libexec/diskimagesiod' \
		ROOMY_OPTIMIZE_PS_SAMPLE_2=$'60 /usr/libexec/syspolicyd\n10 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged' \
		ROOMY_OPTIMIZE_SPCTL_STATUS="assessments enabled" \
		ROOMY_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/example.asset/AssetData/Restore/000.dmg\n/dev/disk8s1\t/Library/Developer/CoreSimulator/Volumes/iOS_23E244\n' \
		bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Likely bottleneck: syspolicyd"* ]]
	[[ "$output" == *"Gatekeeper status: assessments enabled"* ]]
	[[ "$output" == *"Only system-managed CoreSimulator images are mounted"* ]]
	[[ "$output" != *"Mounted image detach candidates"* ]]
}

@test "run_optimize_diagnostics suppresses one-off CPU spikes" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		ROOMY_OPTIMIZE_PS_SAMPLE_1=$'180 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-capture' \
		ROOMY_OPTIMIZE_PS_SAMPLE_2=$'5 /Applications/AliEntSafe.app/Contents/Services/CloudShell.app/Contents/MacOS/CloudShell --type=event-capture' \
		bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"No obvious sustained high-CPU bottleneck detected"* ]]
}

@test "run_optimize_diagnostics lists user-mounted image detach candidates in dry-run" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 \
		ROOMY_OPTIMIZE_PS_SAMPLE_1=$'1 /usr/sbin/distnoted' \
		ROOMY_OPTIMIZE_PS_SAMPLE_2=$'1 /usr/sbin/distnoted' \
		ROOMY_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /Users/test/Downloads/TestInstaller.dmg\n/dev/disk14s1\t/Volumes/Test Installer\n' \
		bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Mounted image detach candidates:"* ]]
	[[ "$output" == *"/Volumes/Test Installer"* ]]
	[[ "$output" == *"Would offer detach for 1 mounted image"* ]]
}

@test "run_optimize_diagnostics skips protected mounted images" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DRY_RUN=1 \
		ROOMY_OPTIMIZE_HDIUTIL_INFO=$'================================================\nimage-path      : /Users/test/Downloads/KeepMe.dmg\n/dev/disk15s1\t/Volumes/KeepMe\n' \
		bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() {
    [[ "$1" == "/Volumes/KeepMe" ]]
}
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" != *"Mounted image detach candidates:"* ]]
}

@test "run_optimize_diagnostics stays quiet when nothing matches" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		ROOMY_OPTIMIZE_PS_SAMPLE_1=$'4 /usr/sbin/distnoted\n3 /usr/libexec/coreaudiod' \
		ROOMY_OPTIMIZE_PS_SAMPLE_2=$'5 /usr/sbin/distnoted\n2 /usr/libexec/coreaudiod' \
		bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/diagnostics.sh"
is_path_whitelisted() { return 1; }
run_optimize_diagnostics
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"No obvious sustained high-CPU bottleneck detected"* ]]
}

@test "opt_periodic_maintenance skips when periodic command missing" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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
opt_periodic_maintenance
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Periodic maintenance skipped (not available on this macOS version)"* ]]
}

@test "execute_optimization dispatches periodic_maintenance" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_periodic_maintenance() { echo "periodic"; }
execute_optimization periodic_maintenance
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"periodic"* ]]
}

@test "execute_optimization skips whitelisted task ids" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_whitelisted() { [[ "$1" == "dock_refresh" ]]; }
opt_dock_refresh() { echo "UNEXPECTED_DOCK"; }
execute_optimization dock_refresh
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped (whitelisted): dock_refresh"* ]]
	[[ "$output" != *"UNEXPECTED_DOCK"* ]]
}

@test "optimize whitelist is loaded before system health checks" {
	run env PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
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

@test "optimize whitelist items include task ids" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_optimize_whitelist_items
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Permission Repair|disk_permissions_repair|optimize_task"* ]]
	[[ "$output" == *"Bluetooth Refresh|bluetooth_reset|optimize_task"* ]]
	[[ "$output" == *"Login Items Audit|login_items_audit|optimize_task"* ]]
}

@test "_login_item_app_exists finds nested helper app bundles" {
	local helper="$HOME/Applications/Roon.app/Contents/RoonServer.app"
	mkdir -p "$helper"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mdfind() { return 1; }
sfltool() { return 1; }
export -f mdfind sfltool
if _login_item_app_exists "RoonServer"; then
    echo "found"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"found"* ]]
}

@test "_login_item_app_exists finds nested helper apps by bundle display name" {
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

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mdfind() { return 1; }
sfltool() { return 1; }
export -f mdfind sfltool
if _login_item_app_exists "Acrobat Collaboration Synchronizer"; then
    echo "found"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"found"* ]]
}

@test "_login_item_app_exists trusts an existing System Events login item path" {
	local helper="$HOME/Applications/Adobe Acrobat DC.app/Contents/Helpers/AdobeResourceSynchronizer.app"
	mkdir -p "$helper"

	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_DEBUG=1 HELPER_PATH="$helper" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
mdfind() { return 1; }
sfltool() { return 1; }
export -f mdfind sfltool
if _login_item_app_exists "Acrobat Collaboration Synchronizer" "$HELPER_PATH" 2>&1; then
    echo "found"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"found"* ]]
	[[ "$output" == *"resolved by login item path"* ]]
}

@test "optimize_sudo_available returns false when sudo session was denied" {
	run env PROJECT_ROOT="$PROJECT_ROOT" ROOMY_OPTIMIZE_SUDO_AVAILABLE="false" bash --noprofile --norc <<'EOF'
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
	# Ad-hoc task invocation under ROOMY_TEST_NO_AUTH must hard-deny sudo
	# even when ROOMY_OPTIMIZE_SUDO_AVAILABLE was never set by bin/optimize.sh.
	run env PROJECT_ROOT="$PROJECT_ROOT" ROOMY_TEST_NO_AUTH=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset ROOMY_OPTIMIZE_SUDO_AVAILABLE
if optimize_sudo_available; then
	echo "WRONG: leaked sudo to test-mode caller"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "flush_dns_cache does not invoke sudo under ROOMY_TEST_NO_AUTH" {
	# Reproduces the reported regression: ad-hoc flush_dns_cache under test
	# mode used to fall through optimize_sudo_available and reach `sudo dscacheutil`.
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_TEST_NO_AUTH=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset ROOMY_OPTIMIZE_SUDO_AVAILABLE
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
		ROOMY_OPTIMIZE_SUDO_AVAILABLE="false" \
		ROOMY_DRY_RUN="0" \
		bash --noprofile --norc <<'EOF'
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
is_memory_pressure_high() { return 0; }
needs_permissions_repair() { return 0; }
has_active_vpn_interface() { return 1; }
route() { return 1; }
dscacheutil() { return 1; }
mdutil() { echo "Indexing enabled."; }
mdfind() { sleep 4; }
get_epoch_seconds() { date +%s; }
is_ac_power() { return 0; }
browser_family_is_running() { return 1; }
pgrep() { return 1; }
system_profiler() { return 1; }
plutil() { return 1; }
defaults() { return 1; }
get_path_size_kb() { echo "0"; }
debug_log() { :; }
opt_msg() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }

opt_memory_pressure_relief 2>&1 || true
opt_network_stack_optimize 2>&1 || true
opt_disk_permissions_repair 2>&1 || true
opt_font_cache_rebuild 2>&1 || true
opt_periodic_maintenance 2>&1 || true
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
