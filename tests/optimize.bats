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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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

@test "opt_quarantine_cleanup reports clean when no database" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_quarantine_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"already clean"* ]]
}

@test "opt_quarantine_cleanup reports entries in dry-run" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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

@test "opt_font_cache_rebuild succeeds in dry-run" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
opt_launch_agents_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Launch Agents all healthy"* ]]
}

@test "opt_launch_agents_cleanup detects broken agents" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 bash --noprofile --norc <<'EOF'
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
