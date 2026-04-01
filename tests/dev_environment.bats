#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-devenv.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

# ============================================================================
# Launch Agents tests
# ============================================================================

@test "check_launch_agents reports healthy when no broken agents" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.test.valid.plist" << 'INNER_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.test.valid</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
    </array>
</dict>
</plist>
INNER_PLIST
check_launch_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"All healthy"* ]]
}

@test "check_launch_agents detects broken agent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.test.broken.plist" << 'INNER_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.test.broken</string>
    <key>ProgramArguments</key>
    <array>
        <string>/nonexistent/path/to/binary</string>
    </array>
</dict>
</plist>
INNER_PLIST
check_launch_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"1 broken"* ]]
    [[ "$output" == *"com.test.broken"* ]]
}

@test "check_launch_agents healthy when directory missing" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
rm -rf "$HOME/Library/LaunchAgents"
check_launch_agents
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"All healthy"* ]]
}

# ============================================================================
# Dev Tools tests
# ============================================================================

@test "check_dev_tools detects missing tools" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
command() {
    if [[ "$1" == "-v" ]]; then
        case "$2" in
            docker|go) return 1 ;;
            *) builtin command "$@" ;;
        esac
    else
        builtin command "$@"
    fi
}
export -f command
check_dev_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}

# ============================================================================
# Version Mismatches tests
# ============================================================================

@test "check_version_mismatches detects psql mismatch" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NVM_DIR="/nonexistent" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
psql() { echo "psql (PostgreSQL) 16.2"; }
postgres() { echo "postgres (PostgreSQL) 14.1"; }
export -f psql postgres
command() {
    if [[ "$1" == "-v" ]]; then
        case "$2" in
            psql|postgres) return 0 ;;
            pyenv) return 1 ;;
            *) builtin command "$@" ;;
        esac
    else
        builtin command "$@"
    fi
}
export -f command
check_version_mismatches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"psql 16.2 vs server 14.1"* ]]
}

@test "check_version_mismatches reports no conflicts when versions match" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NVM_DIR="/nonexistent" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
psql() { echo "psql (PostgreSQL) 16.2"; }
postgres() { echo "postgres (PostgreSQL) 16.2"; }
export -f psql postgres
command() {
    if [[ "$1" == "-v" ]]; then
        case "$2" in
            psql|postgres) return 0 ;;
            pyenv) return 1 ;;
            *) builtin command "$@" ;;
        esac
    else
        builtin command "$@"
    fi
}
export -f command
check_version_mismatches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"No conflicts"* ]]
}

@test "_extract_major_minor handles version strings" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
result1=$(_extract_major_minor "v18.17.1")
result2=$(_extract_major_minor "PostgreSQL 16.2")
result3=$(_extract_major_minor "Python 3.12.1")
echo "r1:$result1"
echo "r2:$result2"
echo "r3:$result3"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"r1:18.17"* ]]
    [[ "$output" == *"r2:16.2"* ]]
    [[ "$output" == *"r3:3.12"* ]]
}

# ============================================================================
# Aggregator test
# ============================================================================

@test "check_all_dev_environment runs all three checks" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NVM_DIR="/nonexistent" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/check/dev_environment.sh"
mkdir -p "$HOME/Library/LaunchAgents"
command() {
    if [[ "$1" == "-v" ]]; then
        case "$2" in
            psql|postgres|pyenv) return 1 ;;
            *) builtin command "$@" ;;
        esac
    else
        builtin command "$@"
    fi
}
export -f command
check_all_dev_environment
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Launch Agents"* || "$output" == *"All healthy"* ]]
    [[ "$output" == *"Dev Tools"* || "$output" == *"All present"* ]]
    [[ "$output" == *"Versions"* || "$output" == *"No conflicts"* ]]
}
