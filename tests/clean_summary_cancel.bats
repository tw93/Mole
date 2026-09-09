#!/usr/bin/env bats

# Regression for #1342: when a cleanup scan/size check hits its internal
# timeout (exit 124), `mo clean` must still print the final summary with an
# explicit reason instead of exiting silently mid-run.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-summary-cancel.XXXXXX")"
    export HOME

    mkdir -p "$HOME/Library/Caches"
    mkdir -p "$HOME/.config/mole"
    for i in 1 2 3 4 5; do
        mkdir -p "$HOME/Library/Caches/cachedir$i"
    done
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-clean-summary-cancel."* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-clean-summary-cancel."* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
}

run_perform_cleanup_with() {
    export SECTION_RC="$1"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
# Stub every section so perform_cleanup never scans the real machine.
# run_with_shell_timeout is stubbed too: its shell-fallback killer process
# would otherwise outlive the test when pgrep is unavailable.
for fn in clean_user_essentials clean_finder_metadata clean_app_caches \
    clean_browsers run_cloud_and_office_cleanup clean_developer_tools \
    clean_user_gui_applications clean_virtualization_tools \
    clean_application_support_logs clean_orphaned_app_data \
    clean_orphaned_system_services clean_orphaned_container_stubs \
    show_user_launch_agent_hint_notice \
    clean_apple_silicon_caches clean_cached_device_firmware \
    clean_time_machine_failed_backups check_large_file_candidates \
    show_project_artifact_hint_notice; do
    eval "$fn() { return 0; }"
done
run_with_shell_timeout() { return 0; }
clean_user_essentials() { return "$SECTION_RC"; }
perform_cleanup
EOF
}

@test "sizing timeout (124) still prints the summary (#1342)" {
    run_perform_cleanup_with 124

    [ "$status" -eq 124 ]
    [[ "$output" == *"Cleanup cancelled"* ]]
    [[ "$output" == *"timed out (exit 124)"* ]]
    [[ "$output" == *"Remaining cleanup was skipped"* ]]
}

@test "interrupted section (>=128) prints an interrupted summary" {
    run_perform_cleanup_with 130

    [ "$status" -eq 130 ]
    [[ "$output" == *"Cleanup interrupted"* ]]
    [[ "$output" == *"was interrupted (exit 130)"* ]]
}

@test "external volume scan failure makes the command incomplete" {
    mkdir -p "$HOME/External"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
EXTERNAL_VOLUME_TARGET="$HOME/External"
clean_external_volume_target() {
    echo "EXTERNAL_SCAN_FAILED"
    return 7
}
set +e
perform_cleanup
cleanup_rc=$?
set -e
printf 'RC=%s\n' "$cleanup_rc"
exit "$cleanup_rc"
EOF

    [ "$status" -eq 7 ] || { echo "$output"; return 1; }
    [[ "$output" == *"EXTERNAL_SCAN_FAILED"* ]] || return 1
    [[ "$output" == *"Cleanup incomplete"* ]] || return 1
    [[ "$output" == *"failed (exit 7)"* ]] || return 1
    [[ "$output" != *"Cleanup complete"* ]] || return 1
    [[ "$output" != *"system already clean"* ]] || return 1
    [[ "$output" != *"System was already clean"* ]] || return 1
}

# Exercise the real external-volume and Finder-metadata helpers through the
# command orchestrator. Only filesystem discovery and removal are mocked.
run_external_finder_scan_with() {
    local test_home="$HOME/finder-$1-$2-${3:-false}"
    mkdir -p "$test_home/External"
    touch "$test_home/External/.DS_Store" "$test_home/External/._later"
    run env HOME="$test_home" PROJECT_ROOT="$PROJECT_ROOT" \
        FINDER_SCAN_RC="$1" TEST_DRY_RUN="$2" TEST_PROTECT_FINDER="${3:-false}" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
EXTERNAL_VOLUME_TARGET="$HOME/External"
DRY_RUN="$TEST_DRY_RUN"
PROTECT_FINDER_METADATA="$TEST_PROTECT_FINDER"
start_section_spinner() { echo "SPINNER_START"; }
stop_section_spinner() { echo "SPINNER_STOP"; }
should_protect_path() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { printf '1\n'; }
run_with_timeout() {
    case "$*" in
        *-name\ .DS_Store*)
            echo "FINDER_SCAN" >&2
            printf '%s\0' "$EXTERNAL_VOLUME_TARGET/.DS_Store"
            return "$FINDER_SCAN_RC"
            ;;
        *-name\ ._*)
            printf '%s\0' "$EXTERNAL_VOLUME_TARGET/._later"
            return 0
            ;;
        *) echo "UNEXPECTED_PROBE:$*" >&2; return 99 ;;
    esac
}
safe_remove() { echo "REMOVE:$1" >> "$HOME/sinks.trace"; }
record_dry_run_cleanup_target() { echo "PREVIEW:$1" >> "$HOME/sinks.trace"; }
set +e
perform_cleanup
cleanup_rc=$?
set -e
if [[ -f "$HOME/sinks.trace" ]]; then
    cat "$HOME/sinks.trace"
fi
printf 'RC=%s CANCEL=%s FILES=%s\n' \
    "$cleanup_rc" "${MOLE_CLEAN_CANCEL_STATUS:-0}" "$files_cleaned"
exit "$cleanup_rc"
EOF
}

@test "external Finder scan failure stops later cleanup and reports incomplete" {
    run_external_finder_scan_with 7 false
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Cleanup incomplete"* ]] || return 1
    [[ "$output" == *"RC=1 CANCEL=0 FILES=0"* ]] || return 1
    [[ "$output" == *"SPINNER_STOP"* ]] || return 1
    [[ "$output" != *"REMOVE:"* && "$output" != *"PREVIEW:"* ]] || return 1
}

@test "external Finder scan timeout stops later cleanup and reports cancellation" {
    run_external_finder_scan_with 124 false
    [ "$status" -eq 124 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Cleanup cancelled"* ]] || return 1
    [[ "$output" == *"RC=124 CANCEL=124 FILES=0"* ]] || return 1
    [[ "$output" == *"SPINNER_STOP"* ]] || return 1
    [[ "$output" != *"REMOVE:"* && "$output" != *"PREVIEW:"* ]] || return 1
}

@test "external Finder scan interruption stops later cleanup and reports interruption" {
    run_external_finder_scan_with 130 false
    [ "$status" -eq 130 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Cleanup interrupted"* ]] || return 1
    [[ "$output" == *"RC=130 CANCEL=130 FILES=0"* ]] || return 1
    [[ "$output" != *"REMOVE:"* && "$output" != *"PREVIEW:"* ]] || return 1
}

@test "external Finder scan timeout also stops later dry-run previews" {
    run_external_finder_scan_with 124 true
    [ "$status" -eq 124 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=124 CANCEL=124 FILES=0"* ]] || return 1
    [[ "$output" != *"REMOVE:"* && "$output" != *"PREVIEW:"* ]] || return 1
}

@test "complete external Finder scans allow the later eligible candidate" {
    for dry_run in false true; do
        run_external_finder_scan_with 0 "$dry_run"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"RC=0 CANCEL=0"* ]] || { echo "$output"; return 1; }
        [[ "$output" == *"/External/.DS_Store"* ]] || return 1
        [[ "$output" == *"/External/._later"* ]] || return 1
        if [[ "$dry_run" == true ]]; then
            [[ "$output" == *"PREVIEW:"* && "$output" != *"REMOVE:"* ]] || return 1
        else
            [[ "$output" == *"REMOVE:"* && "$output" != *"PREVIEW:"* ]] || return 1
        fi
    done
}

@test "protected Finder metadata skips its scan and preserves later cleanup" {
    run_external_finder_scan_with 124 false true
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=0 CANCEL=0 FILES=1"* ]] || return 1
    [[ "$output" == *"REMOVE:"*"/External/._later"* ]] || return 1
    [[ "$output" != *"/External/.DS_Store"* ]] || return 1
}

@test "cloud safety cancellation crosses the timeout worker and stops later sections" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

for fn in clean_user_essentials clean_finder_metadata clean_app_caches \
    clean_browsers clean_user_gui_applications clean_virtualization_tools \
    clean_application_support_logs clean_orphaned_app_data \
    clean_orphaned_system_services clean_orphaned_container_stubs \
    show_user_launch_agent_hint_notice clean_apple_silicon_caches \
    clean_cached_device_firmware clean_time_machine_failed_backups \
    check_large_file_candidates show_project_artifact_hint_notice; do
    eval "$fn() { return 0; }"
done

clean_cloud_storage() {
    MOLE_CLEAN_CANCEL_STATUS=124
    export MOLE_CLEAN_CANCEL_STATUS
    return 0
}
clean_office_applications() {
    echo "UNEXPECTED_OFFICE"
}
clean_developer_tools() {
    echo "UNEXPECTED_LATER_SECTION"
}
run_with_shell_timeout() {
    shift
    "$@" &
    local worker_pid=$!
    wait "$worker_pid"
}

perform_cleanup
EOF

    [ "$status" -eq 124 ] || return 1
    [[ "$output" == *"Cleanup cancelled"* ]] || return 1
    [[ "$output" == *"Remaining cleanup was skipped"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_"* ]]
}

@test "successful run still prints a complete summary" {
    run_perform_cleanup_with 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleanup complete"* ]]
    [[ "$output" != *"Cleanup cancelled"* ]]
}

@test "run with removal timeouts completes and reports them (#1384)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
# Stub every section so perform_cleanup never scans the real machine.
for fn in clean_user_essentials clean_finder_metadata clean_app_caches \
    clean_browsers run_cloud_and_office_cleanup clean_developer_tools \
    clean_user_gui_applications clean_virtualization_tools \
    clean_application_support_logs clean_orphaned_app_data \
    clean_orphaned_system_services clean_orphaned_container_stubs \
    show_user_launch_agent_hint_notice \
    clean_apple_silicon_caches clean_cached_device_firmware \
    clean_time_machine_failed_backups check_large_file_candidates \
    show_project_artifact_hint_notice; do
    eval "$fn() { return 0; }"
done
run_with_shell_timeout() { return 0; }
clean_user_essentials() { MOLE_CLEAN_REMOVAL_TIMEOUTS=3; return 0; }
perform_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleanup complete"* ]]
    [[ "$output" != *"Cleanup cancelled"* ]]
    [[ "$output" == *"3 item(s) exceeded the 30s removal budget"* ]]
}

@test "run with removal timeouts names the timed-out paths (#1384)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
for fn in clean_user_essentials clean_finder_metadata clean_app_caches \
    clean_browsers run_cloud_and_office_cleanup clean_developer_tools \
    clean_user_gui_applications clean_virtualization_tools \
    clean_application_support_logs clean_orphaned_app_data \
    clean_orphaned_system_services clean_orphaned_container_stubs \
    show_user_launch_agent_hint_notice \
    clean_apple_silicon_caches clean_cached_device_firmware \
    clean_time_machine_failed_backups check_large_file_candidates \
    show_project_artifact_hint_notice; do
    eval "$fn() { return 0; }"
done
run_with_shell_timeout() { return 0; }
clean_user_essentials() {
    MOLE_CLEAN_REMOVAL_TIMEOUTS=2
    _mole_record_removal_timeout_path "$HOME/Library/Developer/XCTestDevices/clone-one"
    _mole_record_removal_timeout_path "$HOME/Library/Developer/XCTestDevices/clone-two"
    return 0
}
perform_cleanup
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"2 item(s) exceeded the 30s removal budget"* ]] || return 1
    [[ "$output" == *"XCTestDevices/clone-one"* ]] || return 1
    [[ "$output" == *"XCTestDevices/clone-two"* ]] || return 1
    # Abbreviated to ~: three absolute paths under the home directory run past
    # the one line this note is capped to.
    [[ "$output" == *"~/Library/Developer/XCTestDevices/clone-one"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"$HOME/Library/Developer/XCTestDevices/clone-one"* ]] || { echo "$output"; return 1; }
}

@test "sizing timeouts still clean and the summary reports the under-count (#1374)" {
    mkdir -p "$HOME/Library/Caches/cache1374"
    printf x > "$HOME/Library/Caches/cache1374/file.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
# Stub every section so perform_cleanup never scans the real machine.
# run_with_shell_timeout is stubbed too: its shell-fallback killer process
# would otherwise outlive the test when pgrep is unavailable.
for fn in clean_finder_metadata clean_app_caches \
    clean_browsers run_cloud_and_office_cleanup clean_developer_tools \
    clean_user_gui_applications clean_virtualization_tools \
    clean_application_support_logs clean_orphaned_app_data \
    clean_orphaned_system_services clean_orphaned_container_stubs \
    show_user_launch_agent_hint_notice \
    clean_apple_silicon_caches clean_cached_device_firmware \
    clean_time_machine_failed_backups check_large_file_candidates \
    show_project_artifact_hint_notice; do
    eval "$fn() { return 0; }"
done
run_with_shell_timeout() { return 0; }
# Force every size check to hit the sizing budget.
get_cleanup_path_size_kb() { return 124; }
clean_user_essentials() {
    safe_clean "$HOME/Library/Caches/cache1374" "User app cache"
}
perform_cleanup
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Cleanup complete"* ]] || return 1
    [[ "$output" != *"Cleanup cancelled"* ]] || return 1
    [[ "$output" == *"size-check budget"* ]] || return 1
    [[ "$output" == *"under-reported"* ]] || return 1
    [[ ! -e "$HOME/Library/Caches/cache1374" ]]
}
