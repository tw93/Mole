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
