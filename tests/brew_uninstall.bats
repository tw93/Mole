#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-brew-uninstall-home.XXXXXX")"
    export HOME

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE
}

teardown_file() {
    rm -rf "$HOME"
    export HOME="$ORIGINAL_HOME"
}

setup() {
    mkdir -p "$HOME/Applications"
    mkdir -p "$HOME/Library/Caches"
    # Create fake Caskroom
    mkdir -p "$HOME/Caskroom/test-app/1.2.3/TestApp.app"
}

@test "mole_brew calls brew directly when not running as root" {
    run bash <<EOF
source "$PROJECT_ROOT/lib/core/common.sh" > /dev/null 2>&1
source "$PROJECT_ROOT/lib/uninstall/brew.sh" > /dev/null 2>&1

id() { echo "501"; }
export -f id
brew() { echo "brew-call:\$*"; }
export -f brew

mole_brew list --cask
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"brew-call:list --cask"* ]]
}

@test "mole_brew refuses to run as root without SUDO_USER" {
    run bash <<EOF
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

id() { echo "0"; }
export -f id
unset SUDO_USER
brew() { echo "should-not-run"; }
export -f brew

mole_brew list --cask
EOF

    [ "$status" -ne 0 ]
    [[ "$output" == *"Homebrew cannot run as root"* ]]
    [[ "$output" != *"should-not-run"* ]]
}

@test "mole_brew drops privileges via sudo -u when run as root" {
    run bash <<EOF
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

id() { echo "0"; }
export -f id
export SUDO_USER="testuser"
sudo() { echo "sudo $*"; }
export -f sudo
brew() { echo "should-not-run-directly"; }
export -f brew

mole_brew uninstall --cask --zap claude
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"-u testuser"* ]]
    [[ "$output" == *"-- brew uninstall --cask --zap claude"* ]]
    [[ "$output" != *"should-not-run-directly"* ]]
}

@test "get_brew_cask_name detects app in Caskroom (simulated)" {
    # Create fake Caskroom structure with symlink (modern Homebrew style)
    mkdir -p "$HOME/Caskroom/test-app/1.0.0"
    mkdir -p "$HOME/Applications/TestApp.app"
    ln -s "$HOME/Applications/TestApp.app" "$HOME/Caskroom/test-app/1.0.0/TestApp.app"

    run bash <<EOF
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

# Override the function to use our test Caskroom
get_brew_cask_name() {
    local app_path="\$1"
    [[ -z "\$app_path" || ! -d "\$app_path" ]] && return 1
    command -v brew > /dev/null 2>&1 || return 1

    local app_bundle_name=\$(basename "\$app_path")
    local cask_match
    # Use test Caskroom
    cask_match=\$(find "$HOME/Caskroom" -maxdepth 3 -name "\$app_bundle_name" 2> /dev/null | head -1 || echo "")
    if [[ -n "\$cask_match" ]]; then
        local relative="\${cask_match#$HOME/Caskroom/}"
        echo "\${relative%%/*}"
        return 0
    fi
    return 1
}

get_brew_cask_name "$HOME/Applications/TestApp.app"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == "test-app" ]]
}

@test "get_brew_cask_name handles non-brew apps" {
    mkdir -p "$HOME/Applications/ManualApp.app"

    result=$(bash <<EOF
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"
# Mock brew to return nothing for this
brew() { return 1; }
export -f brew
get_brew_cask_name "$HOME/Applications/ManualApp.app" || echo "not_found"
EOF
    )

    [[ "$result" == "not_found" ]]
}

@test "batch_uninstall_applications uses brew uninstall for casks (mocked)" {
    # Setup fake app
    local app_bundle="$HOME/Applications/BrewApp.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

# Mock dependencies
request_sudo_access() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { :; }
remove_apps_from_dock() { :; }
force_kill_app() { return 0; }
run_with_timeout() { shift; "$@"; }
export -f run_with_timeout
ensure_sudo_session() {
    echo "ENSURE_SUDO:$*" >> "$HOME/brew_calls.log"
    return 0
}

# Mock brew to track calls
brew() {
    echo "brew call: $*" >> "$HOME/brew_calls.log"
    return 0
}
export -f brew

# Mock get_brew_cask_name to return a name
get_brew_cask_name() { echo "brew-app-cask"; return 0; }
export -f get_brew_cask_name

selected_apps=("0|$HOME/Applications/BrewApp.app|BrewApp|com.example.brewapp|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

# Simulate 'Enter' for confirmation
printf '\n' | batch_uninstall_applications > /dev/null 2>&1

grep -q "ENSURE_SUDO:Admin required for Homebrew casks: BrewApp" "$HOME/brew_calls.log"
grep -q "uninstall --cask --zap brew-app-cask" "$HOME/brew_calls.log"
EOF

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications pre-auths sudo for brew-only casks" {
    local app_bundle="$HOME/Applications/BrewPreAuth.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { :; }
remove_apps_from_dock() { :; }
force_kill_app() { return 0; }
run_with_timeout() { shift; "$@"; }
export -f run_with_timeout

ensure_sudo_session() {
    echo "ENSURE_SUDO:$*" >> "$HOME/order.log"
    return 0
}

brew() {
    echo "BREW_CALL:$*" >> "$HOME/order.log"
    return 0
}
export -f brew

get_brew_cask_name() { echo "brew-preauth-cask"; return 0; }
export -f get_brew_cask_name

selected_apps=("0|$HOME/Applications/BrewPreAuth.app|BrewPreAuth|com.example.brewpreauth|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

grep -q "ENSURE_SUDO:Admin required for Homebrew casks: BrewPreAuth" "$HOME/order.log"
grep -q "BREW_CALL:uninstall --cask --zap brew-preauth-cask" "$HOME/order.log"
[[ "$(sed -n '1p' "$HOME/order.log")" == "ENSURE_SUDO:Admin required for Homebrew casks: BrewPreAuth" ]]
EOF

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications runs silent brew autoremove without UX noise" {
    local app_bundle="$HOME/Applications/BrewTimeout.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

request_sudo_access() { return 0; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { :; }
force_kill_app() { return 0; }
remove_apps_from_dock() { :; }
refresh_launch_services_after_uninstall() { echo "LS_REFRESH"; }
ensure_sudo_session() { return 0; }

get_brew_cask_name() { echo "brew-timeout-cask"; return 0; }
brew_uninstall_cask() { return 0; }

run_with_timeout() {
    local duration="$1"
    shift
    echo "TIMEOUT_CALL:$duration:$*" >> "$HOME/timeout_calls.log"
    "$@"
}

selected_apps=("0|$HOME/Applications/BrewTimeout.app|BrewTimeout|com.example.brewtimeout|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications

sleep 0.2

if [[ -f "$HOME/timeout_calls.log" ]]; then
    cat "$HOME/timeout_calls.log"
else
    echo "NO_TIMEOUT_CALL"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"TIMEOUT_CALL:30:brew autoremove"* ]]
    [[ "$output" != *"Checking brew dependencies"* ]]
}

@test "batch_uninstall_applications keeps brew-managed app intact when brew uninstall fails" {
    local app_bundle="$HOME/Applications/BrewBroken.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { :; }
force_kill_app() { return 0; }
remove_apps_from_dock() { :; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
find_app_files() { return 0; }
find_app_system_files() { return 0; }
get_diagnostic_report_paths_for_app() { return 0; }
calculate_total_size() { echo "0"; }
has_sensitive_data() { return 1; }
decode_file_list() { return 0; }
remove_file_list() { :; }
run_with_timeout() { shift; "$@"; }
ensure_sudo_session() { return 0; }

safe_remove() {
    echo "SAFE_REMOVE:$1" >> "$HOME/remove.log"
    rm -rf "$1"
}

safe_sudo_remove() {
    echo "SAFE_SUDO_REMOVE:$1" >> "$HOME/remove.log"
    rm -rf "$1"
}

get_brew_cask_name() { echo "brew-broken-cask"; return 0; }
brew_uninstall_cask() { return 1; }
is_brew_cask_installed() { return 0; }

selected_apps=("0|$HOME/Applications/BrewBroken.app|BrewBroken|com.example.brewbroken|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications > /dev/null 2>&1 || true

[[ -d "$HOME/Applications/BrewBroken.app" ]]
[[ ! -f "$HOME/remove.log" ]]
EOF

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications finishes cleanup after brew removes cask record" {
    local app_bundle="$HOME/Applications/BrewCleanup.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { :; }
force_kill_app() { return 0; }
remove_apps_from_dock() { :; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
find_app_files() { return 0; }
find_app_system_files() { return 0; }
get_diagnostic_report_paths_for_app() { return 0; }
calculate_total_size() { echo "0"; }
has_sensitive_data() { return 1; }
decode_file_list() { return 0; }
remove_file_list() { :; }
run_with_timeout() { shift; "$@"; }
ensure_sudo_session() { return 0; }

safe_remove() {
    echo "SAFE_REMOVE:$1" >> "$HOME/remove.log"
    rm -rf "$1"
}

safe_sudo_remove() {
    echo "SAFE_SUDO_REMOVE:$1" >> "$HOME/remove.log"
    rm -rf "$1"
}

get_brew_cask_name() { echo "brew-cleanup-cask"; return 0; }
brew_uninstall_cask() { return 1; }
is_brew_cask_installed() { return 1; }

selected_apps=("0|$HOME/Applications/BrewCleanup.app|BrewCleanup|com.example.brewcleanup|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

[[ ! -d "$HOME/Applications/BrewCleanup.app" ]]
grep -q "SAFE_REMOVE:$HOME/Applications/BrewCleanup.app" "$HOME/remove.log"
EOF

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications skips brew sudo pre-auth in dry-run mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

brew() {
    echo "BREW_CALL:$*" >> "$HOME/dry_run.log"
    return 0
}
export -f brew

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { whoami; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { :; }
remove_apps_from_dock() { :; }
force_kill_app() { return 0; }
ensure_sudo_session() {
    echo "UNEXPECTED_ENSURE_SUDO:$*" >> "$HOME/dry_run.log"
    return 1
}
run_with_timeout() { shift; "$@"; }
export -f run_with_timeout

get_brew_cask_name() { echo "brew-dry-run-cask"; return 0; }

export MOLE_DRY_RUN=1
selected_apps=("0|$HOME/Applications/BrewDryRun.app|BrewDryRun|com.example.brewdryrun|0|Never")
mkdir -p "$HOME/Applications/BrewDryRun.app"
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | batch_uninstall_applications > /dev/null 2>&1

! grep -q "UNEXPECTED_ENSURE_SUDO:" "$HOME/dry_run.log" 2> /dev/null
EOF

    [ "$status" -eq 0 ]
}
