#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home brew-uninstall-home

    # Prevent AppleScript permission dialogs during tests
    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE
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
    mkdir -p "$HOME/Applications"
    mkdir -p "$HOME/Library/Caches"
    # Create fake Caskroom
    mkdir -p "$HOME/Caskroom/test-app/1.2.3/TestApp.app"
}

@test "brew uninstall permits nested tty reads when GNU timeout is installed" {
    if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect || ! -x /usr/bin/perl ]]; then
        skip "macOS expect/perl required"
    fi
    local timeout_bin
    timeout_bin=$(command -v gtimeout || command -v timeout || true)
    [[ -n "$timeout_bin" ]] || skip "GNU timeout required"

    # shellcheck disable=SC2016 # The external brew stub expands its own arguments and input.
    mole_test_fake_command brew '
set -euo pipefail
[[ "$*" == "uninstall --cask tty-probe" ]] || exit 97
printf "READY\n"
IFS= read -r value
printf "READ:%s\n" "$value"
'
    run /usr/bin/expect "$PROJECT_ROOT/tests/timeout_tty_read.exp" \
        "$PROJECT_ROOT" brew "$timeout_bin"

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"READ:typed-value"* ]] || return 1
    [[ "$output" == *"BACKEND-RESTORED"* ]]
}

@test "brew uninstall preserves the non-tty timeout backend" {
    export MOLE_TIMEOUT_CALLS="$BATS_TEST_TMPDIR/timeout-calls"
    # shellcheck disable=SC2016 # The timeout stub records and executes its own arguments.
    mole_test_fake_command gtimeout '
printf "%s\n" "$*" >> "$MOLE_TIMEOUT_CALLS"
shift
exec "$@"
'
    mole_test_fake_command brew

    run /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/timeout.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"
# The full runner may export a backend detected before this test's PATH stub.
MO_TIMEOUT_BIN="$(command -v gtimeout)"
debug_log() { :; }
log_operation() { :; }
is_brew_cask_installed() { return 1; }
brew_uninstall_cask tty-probe "" nozap < /dev/null
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$(cat "$MOLE_TIMEOUT_CALLS")" == *"brew uninstall --cask tty-probe"* ]]
}

@test "get_brew_cask_name detects app in Caskroom (simulated)" {
    # Create fake Caskroom structure with symlink (modern Homebrew style)
    mkdir -p "$HOME/Caskroom/test-app/1.0.0"
    mkdir -p "$HOME/Applications/TestApp.app"
    ln -s "$HOME/Applications/TestApp.app" "$HOME/Caskroom/test-app/1.0.0/TestApp.app"

    run /bin/bash << EOF
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

    result=$(
        /bin/bash << EOF
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

@test "brew detection requires brew info to mention the exact selected app path" {
    mkdir -p "$HOME/Applications/Owned.app" "$HOME/Applications/Other.app" "$HOME/Applications/SameName.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

brew() {
    case "$*" in
        "list --cask")
            printf '%s\n' "mixed" "owned" "samename" "standard"
            ;;
        "info --cask owned")
            printf 'app "%s"\n' "$HOME/Applications/Owned.app"
            ;;
        "info --cask samename")
            printf '%s\n' 'app "/Applications/SameName.app"'
            ;;
        "info --cask standard")
            printf '%s\n' 'Standard.app (App)'
            ;;
        "info --cask mixed")
            printf '%s\n' 'Mixed.APP (App)'
            ;;
        *)
            return 1
            ;;
    esac
}
export -f brew

owned=$(_detect_cask_via_brew_list "$HOME/Applications/Owned.app" "Owned.app")
[[ "$owned" == "owned" ]] || exit 1
! _detect_cask_via_brew_list "$HOME/Applications/Other.app" "Other.app" || exit 1
! _detect_cask_via_brew_list "$HOME/Applications/SameName.app" "SameName.app" || exit 1
! get_brew_cask_name "$HOME/Applications/SameName.app" || exit 1
standard=$(_detect_cask_via_brew_list "/Applications/Standard.app" "Standard.app")
[[ "$standard" == "standard" ]] || exit 1
mixed=$(_detect_cask_via_brew_list "/Applications/Mixed.APP" "Mixed.APP")
[[ "$mixed" == "mixed" ]] || exit 1
EOF

    [ "$status" -eq 0 ]
}

@test "Homebrew detection preserves timeout and signal probe statuses" {
    mkdir -p "$HOME/Applications/Probe.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

brew() { printf '%s\n' probe; }
run_with_timeout() { return "${PROBE_RC:?}"; }

PROBE_RC=124
rc=0
is_brew_cask_installed probe || rc=$?
[[ $rc -eq 124 ]] || exit 1
rc=0
_detect_cask_via_brew_list "$HOME/Applications/Probe.app" "Probe.app" || rc=$?
[[ $rc -eq 124 ]] || exit 1
rc=0
get_brew_cask_name "$HOME/Applications/Probe.app" || rc=$?
[[ $rc -eq 124 ]] || exit 1

PROBE_RC=143
rc=0
is_brew_cask_installed probe || rc=$?
[[ $rc -eq 143 ]] || exit 1
rc=0
_detect_cask_via_brew_list "$HOME/Applications/Probe.app" "Probe.app" || rc=$?
[[ $rc -eq 143 ]] || exit 1
rc=0
get_brew_cask_name "$HOME/Applications/Probe.app" || rc=$?
[[ $rc -eq 143 ]]
EOF

    [ "$status" -eq 0 ]
}

@test "brew uninstall preserves an interrupted app size probe" {
    mkdir -p "$HOME/Applications/Probe.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

brew() { printf 'UNEXPECTED_BREW\n'; }
get_path_size_kb() { return 124; }
rc=0
brew_uninstall_cask probe "$HOME/Applications/Probe.app" || rc=$?
printf 'RC=%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_BREW"* ]]
}

@test "Caskroom symlink detection rejects a mismatched app bundle name" {
    mkdir -p "$HOME/Applications"
    ln -s "/opt/homebrew/Caskroom/real-cask/1.0/Real.app" "$HOME/Applications/Fake.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"
resolve_path() { printf '%s\n' "/opt/homebrew/Caskroom/real-cask/1.0/Real.app"; }
! _detect_cask_via_resolved_path "$HOME/Applications/Fake.app" || exit 1
! _detect_cask_via_symlink_check "$HOME/Applications/Fake.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch_uninstall_applications uses brew uninstall for casks (mocked)" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    # Setup fake app
    local app_bundle="$fixture_home/Applications/BrewApp.app"
    mkdir -p "$app_bundle"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

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
printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications

grep -q "ENSURE_SUDO:Admin required for Homebrew casks: BrewApp" "$HOME/brew_calls.log"
grep -q "uninstall --cask brew-app-cask" "$HOME/brew_calls.log" || exit 1
! grep -q -- "--zap" "$HOME/brew_calls.log" || exit 1
[[ $(wc -l < "$HOME/inventory.trace") -ge 2 ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        printf 'exit status: %s\n%s\n' "$status" "$output"
        return 1
    }
}

@test "batch_uninstall_applications drops --zap when a sibling install shares the cask bundle id" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    # iterm2 and iterm2-beta both zap com.googlecode.iterm2. When the stable
    # install survives, uninstalling the beta cask must not run the zap
    # stanza, or brew deletes the survivor's prefs/caches behind the guard.
    mkdir -p "$fixture_home/Applications/BrewShared.app" "$fixture_home/Applications/BrewShared-beta.app"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

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
ensure_sudo_session() { return 0; }

brew() {
    echo "brew call: $*" >> "$HOME/brew_shared_calls.log"
    # Make the uninstall "work" so verification passes and no manual
    # fallback path runs.
    if [[ "$1" == "uninstall" ]]; then
        rm -rf "$HOME/Applications/BrewShared-beta.app"
    fi
    return 0
}
export -f brew

get_brew_cask_name() { echo "brewshared-beta"; return 0; }
export -f get_brew_cask_name

apps_data=(
    "0|$HOME/Applications/BrewShared.app|BrewShared|com.example.brewshared|0|Never|0"
    "0|$HOME/Applications/BrewShared-beta.app|BrewShared-beta|com.example.brewshared|0|Never|0"
)
selected_apps=("0|$HOME/Applications/BrewShared-beta.app|BrewShared-beta|com.example.brewshared|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications > "$HOME/brew_shared_output.log" 2>&1

grep -q "uninstall --cask brewshared-beta" "$HOME/brew_shared_calls.log" || {
    echo "WRONG: plain cask uninstall not invoked"
    cat "$HOME/brew_shared_calls.log"
    exit 1
}
if grep -q -- "--zap" "$HOME/brew_shared_calls.log"; then
    echo "WRONG: --zap used despite surviving same-bundle sibling"
    cat "$HOME/brew_shared_calls.log"
    exit 1
fi
if grep -q -- "Homebrew apps will be fully cleaned" "$HOME/brew_shared_output.log"; then
    echo "WRONG: preview claims --zap despite surviving same-bundle sibling"
    cat "$HOME/brew_shared_output.log"
    exit 1
fi
[[ -d "$HOME/Applications/BrewShared.app" ]] || {
    echo "WRONG: surviving install removed"
    exit 1
}
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications pre-auths sudo for brew-only casks" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    local app_bundle="$fixture_home/Applications/BrewPreAuth.app"
    mkdir -p "$app_bundle"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

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

printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications

grep -q "BREW_CALL:uninstall --cask brew-preauth-cask" "$HOME/order.log"
[[ "$(sed -n '1p' "$HOME/order.log")" == "ENSURE_SUDO:Admin required for Homebrew casks: BrewPreAuth true" ]] || exit 1
[[ $(wc -l < "$HOME/inventory.trace") -ge 2 ]] || exit 1
EOF

    [ "$status" -eq 0 ] || {
        printf 'exit status: %s\n%s\n' "$status" "$output"
        return 1
    }
}

@test "batch_uninstall_applications runs silent brew autoremove without UX noise" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    local app_bundle="$fixture_home/Applications/BrewTimeout.app"
    mkdir -p "$app_bundle"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

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
brew() {
    echo "BREW_CALL:$*" >> "$HOME/timeout_calls.log"
    return 0
}

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

printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications

sleep 0.2

if [[ -f "$HOME/timeout_calls.log" ]]; then
    cat "$HOME/timeout_calls.log"
else
    echo "NO_TIMEOUT_CALL"
fi
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
    [[ "$output" == *"TIMEOUT_CALL:30:brew autoremove"* ]] || return 1
    [[ "$output" != *"Checking brew dependencies"* ]]
}

@test "batch_uninstall_applications keeps brew-managed app intact when brew uninstall fails" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    local app_bundle="$fixture_home/Applications/BrewBroken.app"
    mkdir -p "$app_bundle"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

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

printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications > /dev/null 2>&1 || true

[[ -d "$HOME/Applications/BrewBroken.app" ]] || exit 1
[[ ! -f "$HOME/remove.log" ]]
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications finishes cleanup after brew removes cask record" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    local app_bundle="$fixture_home/Applications/BrewCleanup.app"
    mkdir -p "$app_bundle"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

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

printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications > /dev/null 2>&1

[[ ! -d "$HOME/Applications/BrewCleanup.app" ]] || exit 1
grep -q "SAFE_REMOVE:$HOME/Applications/BrewCleanup.app" "$HOME/remove.log"
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
}

@test "brew fallback preserves mutable-parent diagnosis after its cask record disappears" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    local app_bundle="$fixture_home/Applications/BrewManual.app"
    local leftover="$fixture_home/Library/Application Support/BrewManual"
    mkdir -p "$app_bundle" "$leftover"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

start_inline_spinner() { :; }
stop_inline_spinner() { :; }
get_file_owner() { echo root; }
get_path_size_kb() { echo "100"; }
bytes_to_human() { echo "$1"; }
drain_pending_input() { :; }
print_summary_block() { printf '%s\n' "$@"; }
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
remove_file_list() { printf 'LEFTOVER_DELETE\n' >> "$HOME/brew-manual-side-effects.log"; return 1; }
run_with_timeout() { shift; "$@"; }
ensure_sudo_session() { return 0; }

get_brew_cask_name() { echo "brew-manual-cask"; return 0; }
brew_uninstall_cask() { return 1; }
is_brew_cask_installed() { return 1; }
_mole_privileged_path_has_mutable_ancestor() { return 0; }
mole_delete() { return "$MOLE_ERR_MUTABLE_PARENT"; }

selected_apps=("0|$HOME/Applications/BrewManual.app|BrewManual|com.example.brewmanual|0|Never")
files_cleaned=0
total_items=0
total_size_cleaned=0

printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -d "$app_bundle" ]] || return 1
    [[ -d "$leftover" ]] || return 1
    [[ ! -e "$fixture_home/brew-manual-side-effects.log" ]] || return 1
    [[ "$output" == *"Mole cannot safely use elevated deletion below a user-writable parent"* ]] || return 1
    [[ "$output" == *"Move the app to Trash in Finder"* ]] || return 1
}

@test "batch_uninstall_applications skips brew sudo pre-auth in dry-run mode" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/inventory-fixture.XXXXXX")
    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory

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

printf '\n' | MOLE_TEST_MODE=1 batch_uninstall_applications > /dev/null 2>&1

! grep -q "UNEXPECTED_ENSURE_SUDO:" "$HOME/dry_run.log" 2> /dev/null
EOF

    [[ -s "$fixture_home/inventory.trace" ]] || { echo "$output"; return 1; }

    [ "$status" -eq 0 ]
}

@test "brew_uninstall_cask passes cask token as argv without shell evaluation" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

debug_log() { :; }
get_path_size_kb() { echo "100"; }
run_with_timeout() { shift; "$@"; }
is_brew_cask_installed() { return 1; }

brew() {
    printf '<%s>\n' "$@" >> "$HOME/brew_argv.log"
    return 0
}
export -f brew

cask_name='bad"; touch "$HOME/pwned"; #'
brew_uninstall_cask "$cask_name"

[[ ! -e "$HOME/pwned" ]] || exit 1
grep -Fx '<bad"; touch "$HOME/pwned"; #>' "$HOME/brew_argv.log"
EOF

    [ "$status" -eq 0 ]
}

@test "brew_uninstall_cask logs the bundle Homebrew removed" {
    local fixture_home
    fixture_home=$(mktemp -d "$HOME/brew-oplog.XXXXXX")
    mkdir -p "$fixture_home/Applications/Logged.app"

    run env HOME="$fixture_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"
debug_log() { :; }
get_path_size_kb() { echo "100"; }
run_with_timeout() { shift; "$@"; }
is_brew_cask_installed() { return 1; }
brew() { /bin/rm -rf "$HOME/Applications/Logged.app"; }
export -f brew
export MOLE_CURRENT_COMMAND=uninstall
brew_uninstall_cask "logged-cask" "$HOME/Applications/Logged.app" nozap
EOF2

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -Fq "] [uninstall] REMOVED $fixture_home/Applications/Logged.app (brew uninstall logged-cask)" \
        "$fixture_home/Library/Logs/mole/operations.log" || return 1
}

@test "uninstall logs every keg brew autoremove removed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF2'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
rm -f "$OPERATIONS_LOG_FILE"
export MOLE_CURRENT_COMMAND=uninstall
_batch_log_brew_autoremove "==> Autoremoving 2 unneeded formulae:
libfoo
libbar
Uninstalling /opt/homebrew/Cellar/libfoo/1.2.3... (45 files, 3.2MB)
==> Uninstalling /opt/homebrew/Cellar/libbar/0.9_1... (3 files, 12KB)
Warning: something unrelated"
cat "$OPERATIONS_LOG_FILE"
EOF2

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"[uninstall] REMOVED /opt/homebrew/Cellar/libfoo/1.2.3 (brew autoremove)"* ]] || return 1
    [[ "$output" == *"[uninstall] REMOVED /opt/homebrew/Cellar/libbar/0.9_1 (brew autoremove)"* ]] || return 1
    [ "$(printf '%s\n' "$output" | grep -c 'brew autoremove')" -eq 2 ] || return 1
}

@test "_detect_cask_via_caskroom_search handles empty uniq array expansion under set -u" {
    mkdir -p "$BATS_TEST_TMPDIR/TestCaskApp.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TEST_APP_PATH="$BATS_TEST_TMPDIR/TestCaskApp.app" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

find() {
    printf '%s\0' "/opt/homebrew/Caskroom/test-cask-app/1.0.0/TestCaskApp.app"
}
run_with_timeout() {
    shift
    "$@"
}
_mole_brew_probe() {
    echo "test-cask-app"
    return 0
}

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_detect_cask_via_caskroom_search TestCaskApp.app
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == "test-cask-app" ]]
}

# Only discovery and Homebrew are mocked; app identity uses real fixture
# directories and symlinks so a same-name copy cannot satisfy the fallback.
run_caskroom_info_failure_case() {
    local scenario="$1"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" SCENARIO="$scenario" \
        FIXTURE="$BATS_TEST_TMPDIR" /bin/bash --noprofile --norc <<'SCRIPT'
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"
mkdir -p "$FIXTURE/selected/Rebased.app" "$FIXTURE/other/Rebased.app" "$FIXTURE/cask"
app_path="$FIXTURE/selected/Rebased.app"
match="$FIXTURE/cask/Rebased.app"
ln -s "$app_path" "$match"
case "$SCENARIO" in
    unrelated) rm "$match"; ln -s "$FIXTURE/other/Rebased.app" "$match" ;;
    copied) rm "$match"; mkdir "$match" ;;
esac
_mole_brew_caskroom_roots() { printf '%s\n' "$FIXTURE/cask"; }
find() { printf '%s\0' "$FIXTURE/cask/Rebased.app"; }
# Production token parsing has independent coverage; fixture paths must not
# create or change the machine's actual Caskroom.
_extract_cask_token_from_path() { printf '%s\n' rebased; }
run_with_timeout() { shift; "$@"; }
_mole_brew_probe() {
    shift
    case "$*" in
        'list --cask') printf '%s\n' rebased ;;
        'info --cask rebased')
            case "$SCENARIO" in
                timeout) return 124 ;;
                cancelled) return 143 ;;
                retargeted) rm "$FIXTURE/cask/Rebased.app"; ln -s "$FIXTURE/other/Rebased.app" "$FIXTURE/cask/Rebased.app" ;;
            esac
            return 1
            ;;
        *) return 99 ;;
    esac
}
result=""
rc=0
result=$(_detect_cask_via_caskroom_search Rebased.app "$app_path") || rc=$?
printf 'rc=%s token=%s\n' "$rc" "$result"
SCRIPT
}

@test "third-party cask info failure accepts the exact installed app (#1558)" {
    run_caskroom_info_failure_case exact
    [ "$status" -eq 0 ]
    [ "$output" = 'rc=0 token=rebased' ]
}

@test "third-party cask info failure refuses a same-name app at another path (#1558)" {
    run_caskroom_info_failure_case unrelated
    [ "$status" -eq 0 ]
    [ "$output" = 'rc=2 token=' ]
}

@test "third-party cask info failure refuses a same-name copied bundle (#1558)" {
    run_caskroom_info_failure_case copied
    [ "$status" -eq 0 ]
    [ "$output" = 'rc=2 token=' ]
}

@test "third-party cask info failure rechecks a retargeted symlink (#1558)" {
    run_caskroom_info_failure_case retargeted
    [ "$status" -eq 0 ]
    [ "$output" = 'rc=2 token=' ]
}

@test "third-party cask info timeout is not bypassed by exact ownership (#1558)" {
    run_caskroom_info_failure_case timeout
    [ "$status" -eq 0 ]
    [ "$output" = 'rc=124 token=' ]
}

@test "third-party cask info cancellation is not bypassed by exact ownership (#1558)" {
    run_caskroom_info_failure_case cancelled
    [ "$status" -eq 0 ]
    [ "$output" = 'rc=143 token=' ]
}


@test "batch brew inspection shares inventories but final installed probe is fresh" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
fixture=$(mktemp -d "$HOME/inventory.XXXXXX")
mkdir -p "$fixture/Owned.app" "$fixture/Other.app"
selected_apps=(one two)
is_homebrew_available() { return 0; }
_mole_brew_caskroom_roots() { printf '%s\n' "$fixture"; }
run_with_timeout() {
    shift
    if [[ "$1" == find ]]; then
        printf 'scan\n' >> "$fixture/scan-calls"
        printf '%s\0' /opt/homebrew/Caskroom/owned/1/Owned.app /opt/homebrew/Caskroom/other/1/Other.app
    else
        "$@"
    fi
}
_mole_brew_probe() {
    shift
    case "$*" in
        'list --cask') printf 'list\n' >> "$fixture/list-calls"; printf '%s\n' owned other ;;
        'info --cask owned') printf '%s\n' "$fixture/Owned.app" ;;
        'info --cask other') printf '%s\n' "$fixture/Other.app" ;;
        *) return 97 ;;
    esac
}
_batch_scan_app_details_impl() {
    first=$(_detect_cask_via_caskroom_search Owned.app "$fixture/Owned.app") || exit 1
    second=$(_detect_cask_via_caskroom_search Other.app "$fixture/Other.app") || exit 1
    [[ "$first" == owned && "$second" == other ]] || exit 1
}
_batch_scan_app_details || exit 1
[[ $(wc -l < "$fixture/list-calls") -eq 1 ]] || exit 1
[[ $(wc -l < "$fixture/scan-calls") -eq 1 ]] || exit 1
[[ -z "${_MOLE_BREW_BATCH_LIST_READY:-}" ]] || exit 1
[[ -z "${_MOLE_BREW_BATCH_ROOM_FILE:-}" ]] || exit 1
is_brew_cask_installed owned || exit 1
[[ $(wc -l < "$fixture/list-calls") -eq 2 ]] || exit 1
printf 'shared-inspection fresh-execution\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"shared-inspection fresh-execution"* ]]
}

@test "failed batch inventory never feeds partial candidates to brew ownership" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
fixture=$(mktemp -d "$HOME/partial-inventory.XXXXXX")
mkdir -p "$fixture/Owned.app"
selected_apps=(one two)
is_homebrew_available() { return 0; }
_mole_brew_caskroom_roots() { printf '%s\n' "$fixture"; }
run_with_timeout() { printf '%s\0' /opt/homebrew/Caskroom/owned/1/Owned.app; return 124; }
_mole_brew_probe() {
    shift
    [[ "$*" == 'list --cask' ]] || { echo unexpected-info; return 97; }
    printf 'owned\n'
}
_batch_scan_app_details_impl() {
    local rc=0
    _detect_cask_via_caskroom_search Owned.app "$fixture/Owned.app" || rc=$?
    [[ $rc -eq 124 ]] || return 1
    printf 'partial-kept\n'
}
_batch_scan_app_details || exit 1
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"partial-kept"* ]] || return 1
    [[ "$output" != *"unexpected-info"* ]]
}

# Runs `uninstall_list_apps` (JSON, since stdout is captured) over three
# Homebrew-installed apps and one plain app. BREW_INFO_MODE picks how the
# mocked `brew info --cask` answers a multi-token request.
run_list_mode_brew_case() {
    local mode="$1"
    rm -f "$HOME/brew-calls"
    mkdir -p "$HOME/Applications/Alpha.app" "$HOME/Applications/Beta.app" \
        "$HOME/Applications/Gamma.app" "$HOME/Applications/Plain.app"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" BREW_INFO_MODE="$mode" \
        /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"
_mole_brew_caskroom_roots() { return 0; }
brew() {
    printf '%s\n' "$*" >> "$HOME/brew-calls"
    local block_alpha block_beta block_gamma
    # Alpha's block names Beta's path; Beta's own block does not.
    block_alpha=$(printf '==> alpha: 1.0\n%s\n%s\n' "$HOME/Applications/Alpha.app" "$HOME/Applications/Beta.app")
    block_beta=$(printf '==> beta (Beta): 2.0\nBeta.app (App)\n')
    block_gamma=$(printf '==> gamma: 3.0\n%s\n' "$HOME/Applications/Gamma.app")
    case "$*" in
        "list --cask") printf '%s\n' alpha beta gamma unrelated ;;
        "info --cask alpha") printf '%s\n' "$block_alpha" ;;
        "info --cask beta") printf '%s\n' "$block_beta" ;;
        "info --cask gamma") printf '%s\n' "$block_gamma" ;;
        "info --cask "*)
            case "$BREW_INFO_MODE" in
                split) printf '%s\n\n%s\n\n%s\n' "$block_alpha" "$block_beta" "$block_gamma" ;;
                unordered) printf '%s\n\n%s\n\n%s\n' "$block_beta" "$block_alpha" "$block_gamma" ;;
                failed) printf '%s\n' "$block_alpha"; return 1 ;;
                timeout) return 124 ;;
                signal) return 130 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
export -f brew
scan_applications() { printf '%s\n' "$HOME/fake-apps"; }
load_applications() {
    apps_data=(
        "0|$HOME/Applications/Alpha.app|Alpha|com.example.alpha|1KB|Today|1"
        "0|$HOME/Applications/Beta.app|Beta|com.example.beta|1KB|Today|1"
        "0|$HOME/Applications/Gamma.app|Gamma|com.example.gamma|1KB|Today|1"
        "0|$HOME/Applications/Plain.app|Plain|com.example.plain|1KB|Today|1"
    )
    return 0
}
touch "$HOME/fake-apps"
rc=0
uninstall_list_apps || rc=$?
printf 'rc=%s\n' "$rc"
INNER
}

list_mode_info_calls() {
    grep -c '^info --cask' "$HOME/brew-calls" || true
}

@test "uninstall --list asks brew info once for every Homebrew candidate" {
    run_list_mode_brew_case split
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"rc=0"* ]] || return 1
    [[ "$(list_mode_info_calls)" -eq 1 ]] || { cat "$HOME/brew-calls"; return 1; }
    grep -qx 'info --cask alpha beta gamma' "$HOME/brew-calls" || return 1
    [[ "$output" == *'"name": "Alpha", "bundle_id": "com.example.alpha", "source": "Homebrew", "uninstall_name": "alpha"'* ]] || return 1
    [[ "$output" == *'"name": "Gamma", "bundle_id": "com.example.gamma", "source": "Homebrew", "uninstall_name": "gamma"'* ]] || return 1
    # Beta's path appears only in Alpha's block, which is not Beta's evidence.
    [[ "$output" == *'"name": "Beta", "bundle_id": "com.example.beta", "source": "App"'* ]] || return 1
    [[ "$output" == *'"name": "Plain", "bundle_id": "com.example.plain", "source": "App"'* ]]
}

@test "uninstall --list falls back to per-token brew info when the batch cannot be split" {
    local mode
    for mode in unordered failed; do
        run_list_mode_brew_case "$mode"
        [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
        [[ "$(list_mode_info_calls)" -eq 4 ]] || { echo "$mode"; cat "$HOME/brew-calls"; return 1; }
        [[ "$output" == *'"name": "Alpha", "bundle_id": "com.example.alpha", "source": "Homebrew"'* ]] || return 1
        [[ "$output" == *'"name": "Gamma", "bundle_id": "com.example.gamma", "source": "Homebrew"'* ]] || return 1
        [[ "$output" == *'"name": "Beta", "bundle_id": "com.example.beta", "source": "App"'* ]] || return 1
    done
}

@test "uninstall --list treats a timed-out batch as unknown and cancels on a signal" {
    run_list_mode_brew_case timeout
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"rc=0"* ]] || return 1
    [[ "$(list_mode_info_calls)" -eq 1 ]] || { cat "$HOME/brew-calls"; return 1; }
    [[ "$output" != *'"source": "Homebrew"'* ]] || return 1

    run_list_mode_brew_case signal
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"rc=130"* ]] || return 1
    [[ "$output" != *'"name": "Alpha"'* ]] || return 1
    [[ "$(list_mode_info_calls)" -eq 1 ]]
}
