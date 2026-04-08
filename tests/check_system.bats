#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-checksys.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "check_disk_smart reports Verified status" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
diskutil() {
    echo "   Part of Whole:            disk0"
    echo "   SMART Status:             Verified"
}
export -f diskutil
check_disk_smart
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMART Verified"* ]]
}

@test "check_disk_smart reports Failing status" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
diskutil() {
    echo "   Part of Whole:            disk0"
    echo "   SMART Status:             Failing"
}
export -f diskutil
check_disk_smart
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMART Failing"* ]]
    [[ "$output" == *"back up immediately"* ]]
}

@test "check_disk_smart handles missing diskutil gracefully" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
export PATH="/nonexistent"
check_disk_smart
echo "survived"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}

@test "check_disk_smart handles unknown SMART status" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
diskutil() {
    echo "   Part of Whole:            disk0"
    echo "   SMART Status:             Not Supported"
}
export -f diskutil
check_disk_smart
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMART: Not Supported"* ]]
}

@test "check_orphan_launch_agents detects orphans, skips valid + apple plists" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
LA="$HOME/Library/LaunchAgents"
rm -rf "$LA" && mkdir -p "$LA"
export MOLE_LAUNCH_AGENT_DIRS="$LA"
mk() { printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>%s</string></dict></plist>' "$2" > "$1"; }
mk "$LA/com.ghost.helper.plist" "/Applications/Ghost.app/Contents/MacOS/helper"
mk "$LA/com.real.tool.plist" "/bin/sh"
mk "$LA/com.apple.fake.plist" "/nonexistent/x"
check_orphan_launch_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"1 orphan"* ]]
    [[ "$output" == *"com.ghost.helper"* ]]
    [[ "$output" != *"com.real.tool"* ]]
    [[ "$output" != *"com.apple.fake"* ]]
}

@test "check_orphan_launch_agents reports None when clean" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
LA="$HOME/Library/LaunchAgents"
rm -rf "$LA" && mkdir -p "$LA"
export MOLE_LAUNCH_AGENT_DIRS="$LA"
check_orphan_launch_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"None orphaned"* ]]
}

@test "check_orphan_launch_agents respects whitelist" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/all.sh"
is_whitelisted() { [[ "$1" == "check_orphan_launch_agents" ]]; }
export -f is_whitelisted
LA="$HOME/Library/LaunchAgents"
rm -rf "$LA" && mkdir -p "$LA"
export MOLE_LAUNCH_AGENT_DIRS="$LA"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>/nonexistent/x</string></dict></plist>' > "$LA/com.ghost.plist"
check_orphan_launch_agents
EOF

    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}
