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
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
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
! _detect_cask_via_brew_list "$HOME/Applications/Other.app" "Other.app"
! _detect_cask_via_brew_list "$HOME/Applications/SameName.app" "SameName.app"
! get_brew_cask_name "$HOME/Applications/SameName.app"
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
! _detect_cask_via_resolved_path "$HOME/Applications/Fake.app"
! _detect_cask_via_symlink_check "$HOME/Applications/Fake.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "batch_uninstall_applications uses brew uninstall for casks (mocked)" {
    # Setup fake app
    local app_bundle="$HOME/Applications/BrewApp.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

@test "batch_uninstall_applications drops --zap when a sibling install shares the cask bundle id" {
    # iterm2 and iterm2-beta both zap com.googlecode.iterm2. When the stable
    # install survives, uninstalling the beta cask must not run the zap
    # stanza, or brew deletes the survivor's prefs/caches behind the guard.
    mkdir -p "$HOME/Applications/BrewShared.app" "$HOME/Applications/BrewShared-beta.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

printf '\n' | batch_uninstall_applications > "$HOME/brew_shared_output.log" 2>&1

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

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications pre-auths sudo for brew-only casks" {
    local app_bundle="$HOME/Applications/BrewPreAuth.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

printf '\n' | batch_uninstall_applications

sleep 0.2

if [[ -f "$HOME/timeout_calls.log" ]]; then
    cat "$HOME/timeout_calls.log"
else
    echo "NO_TIMEOUT_CALL"
fi
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"TIMEOUT_CALL:30:brew autoremove"* ]] || return 1
    [[ "$output" != *"Checking brew dependencies"* ]]
}

@test "batch_uninstall_applications keeps brew-managed app intact when brew uninstall fails" {
    local app_bundle="$HOME/Applications/BrewBroken.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

[[ -d "$HOME/Applications/BrewBroken.app" ]] || exit 1
[[ ! -f "$HOME/remove.log" ]]
EOF

    [ "$status" -eq 0 ]
}

@test "batch_uninstall_applications finishes cleanup after brew removes cask record" {
    local app_bundle="$HOME/Applications/BrewCleanup.app"
    mkdir -p "$app_bundle"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

[[ ! -d "$HOME/Applications/BrewCleanup.app" ]] || exit 1
grep -q "SAFE_REMOVE:$HOME/Applications/BrewCleanup.app" "$HOME/remove.log"
EOF

    [ "$status" -eq 0 ]
}

@test "brew fallback preserves mutable-parent diagnosis after its cask record disappears" {
    local app_bundle="$HOME/Applications/BrewManual.app"
    local leftover="$HOME/Library/Application Support/BrewManual"
    mkdir -p "$app_bundle" "$leftover"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"

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

printf '\n' | batch_uninstall_applications
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -d "$app_bundle" ]] || return 1
    [[ -d "$leftover" ]] || return 1
    [[ ! -e "$HOME/brew-manual-side-effects.log" ]] || return 1
    [[ "$output" == *"Mole cannot safely use elevated deletion below a user-writable parent"* ]] || return 1
    [[ "$output" == *"Move the app to Trash in Finder"* ]] || return 1
}

@test "batch_uninstall_applications skips brew sudo pre-auth in dry-run mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
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

@test "_detect_cask_via_caskroom_search handles empty uniq array expansion under set -u" {
    mkdir -p "$BATS_TEST_TMPDIR/TestCaskApp.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TEST_APP_PATH="$BATS_TEST_TMPDIR/TestCaskApp.app" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

find() {
    echo "/opt/homebrew/Caskroom/test-cask-app/1.0.0/TestCaskApp.app"
}
run_with_timeout() {
    shift
    "$@"
}
_mole_brew_probe() {
    echo "test-cask-app"
    return 0
}

_detect_cask_via_caskroom_search "$TEST_APP_PATH"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == "test-cask-app" ]]
}

@test "Caskroom detection tolerates unavailable info for third-party taps" {
    mkdir -p "$BATS_TEST_TMPDIR/Rebased.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TEST_APP_PATH="$BATS_TEST_TMPDIR/Rebased.app" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

find() {
    echo "/opt/homebrew/Caskroom/rebased/1.1.15/Rebased.app"
}
run_with_timeout() {
    shift
    "$@"
}
_mole_brew_probe() {
    case "$2:$3:${4:-}" in
        list:--cask:)
            echo "rebased"
            return 0
            ;;
        info:--cask:rebased)
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}

result=$(_detect_cask_via_caskroom_search \
    "Rebased.app" "$TEST_APP_PATH")
[[ "$result" == "rebased" ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == "rebased" ]]
}
