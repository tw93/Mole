#!/bin/bash
# System-Level Cleanup Module (requires sudo).
set -euo pipefail

is_rebuildable_gpu_cache_dir() {
    local cache_dir="$1"

    # Only match current-user-accessible Darwin cache shards under C/.  Do not
    # match T/ temp folders, generic /private/var/folders entries, or arbitrary
    # system paths: these Metal/GPU caches are rebuildable, but deleting active
    # caches can force live apps to recompile shaders and momentarily stutter.
    case "$cache_dir" in
        /private/var/folders/*/*/C/*/com.apple.gpuarchiver | \
            /private/var/folders/*/*/C/*/com.apple.metal | \
            /private/var/folders/*/*/C/*/com.apple.metalfe | \
            /var/folders/*/*/C/*/com.apple.gpuarchiver | \
            /var/folders/*/*/C/*/com.apple.metal | \
            /var/folders/*/*/C/*/com.apple.metalfe)
            return 0
            ;;
    esac

    return 1
}

gpu_cache_dir_is_stale() {
    local cache_dir="$1"
    local age_days="${2:-${MOLE_GPU_CACHE_AGE_DAYS:-1}}"

    [[ "$age_days" =~ ^[0-9]+$ ]] || age_days=1
    [[ -d "$cache_dir" ]] || return 1
    [[ -L "$cache_dir" ]] && return 1

    # Directory mtime only changes when entries are added/removed/renamed.
    # Treat a cache as stale only when no contained file was modified inside
    # the retention window, so live apps that rewrite existing Metal cache
    # files do not lose their active shader/GPU cache on every cleanup run.
    local recent_file=""
    local probe_rc=0
    recent_file=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
        /usr/bin/find "$cache_dir" -type f -mtime "-$age_days" -print -quit 2> /dev/null) || probe_rc=$?
    if [[ $probe_rc -ge 128 ]]; then
        return "$probe_rc"
    fi
    [[ $probe_rc -eq 0 ]] || return 1
    [[ -z "$recent_file" ]]
}

# Fail-closed Software Update probe for macOS installer cleanup. Returns 0
# (treat as pending) when recommended updates are queued, and also when the
# plist is unreadable, plutil fails, or the key is missing: removing staged
# update payloads on a wrong "no updates" answer left a Mac unbootable on a
# macOS 27 beta, so an unknown state must block cleanup.
software_update_pending_or_unknown() {
    local plist="${1:-/Library/Preferences/com.apple.SoftwareUpdate.plist}"
    local deadline_seconds="${2:-}"
    [[ -f "$plist" ]] || return 0
    local recommended=""
    local probe_timeout="$MOLE_TIMEOUT_QUICK_DETECT_SEC"
    if [[ -n "$deadline_seconds" ]]; then
        probe_timeout=$(_mole_timeout_with_deadline "$probe_timeout" \
            "$deadline_seconds") || return 0
    fi
    local probe_rc=0
    recommended=$(run_with_timeout "$probe_timeout" plutil \
        -extract RecommendedUpdates json -o - "$plist" < /dev/null 2> /dev/null) || probe_rc=$?
    if [[ $probe_rc -ge 128 ]]; then
        return "$probe_rc"
    elif [[ $probe_rc -ne 0 ]]; then
        return 0
    fi
    recommended=$(printf '%s' "$recommended" | tr -d '[:space:]')
    # Only a readable, explicitly empty RecommendedUpdates array means "no
    # pending updates"; anything else stays fail-closed.
    if [[ "$recommended" == "[]" ]]; then
        return 1
    fi
    return 0
}

# Report the tens-of-GB runaway shape from #1283 without mutating the active
# database. A 10 GiB threshold reserves the warning for the reported
# tens-of-GB runaway shape; it is never permission to delete or vacuum.
show_large_active_powerlog_notice() {
    local warning_threshold_bytes=$((10 * 1024 * 1024 * 1024))
    local size_bytes=""

    local probe_rc=0
    size_bytes=$(_mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -n "$STAT_BSD" -f%z "$MOLE_ACTIVE_POWERLOG_DB_PATH" < /dev/null 2> /dev/null) || probe_rc=$?
    if [[ $probe_rc -ge 128 ]]; then
        return "$probe_rc"
    fi
    [[ $probe_rc -eq 0 ]] || return 0
    [[ "$size_bytes" =~ ^[0-9]+$ ]] || return 0
    [[ "$size_bytes" -ge "$warning_threshold_bytes" ]] || return 0

    local size_human
    size_human=$(bytes_to_human "$size_bytes")
    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Power telemetry database · ${GREEN}${size_human}${NC} · ${GRAY}active, kept · $(format_path_link "$MOLE_ACTIVE_POWERLOG_DB_PATH")${NC}"
}

report_system_cleanup_incomplete() {
    local label="$1"
    local status="${2:-1}"

    if [[ "$status" -eq 124 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} ${label} · ${GRAY}timed out, cleanup may be partial${NC}"
        if declare -F note_activity > /dev/null 2>&1; then
            note_activity
        fi
    else
        debug_log "$label cleanup incomplete (status $status)"
    fi
}

system_cleanup_budget_reached() {
    local deadline="$1"
    [[ "$SECONDS" -ge "$deadline" ]]
}

system_cleanup_budget_seconds() {
    local requested="${MOLE_TIMEOUT_SYSTEM_CLEANUP_SEC:-120}"

    # Keep this section bounded even when a user needs more time for a slow
    # but healthy filesystem. The lower bound avoids a deadline that expires
    # before a useful scan can start; the upper bound prevents a stalled
    # privileged scan from making clean appear hung indefinitely.
    if [[ "$requested" =~ ^[0-9]+$ ]] && \
        (( 10#$requested >= 30 && 10#$requested <= 600 )); then
        printf '%d\n' "$((10#$requested))"
        return 0
    fi

    if declare -F debug_log > /dev/null 2>&1; then
        debug_log "Ignoring invalid MOLE_TIMEOUT_SYSTEM_CLEANUP_SEC=$requested; using 120s"
    fi
    printf '%s\n' 120
}

report_system_cleanup_budget_reached() {
    echo -e "  ${YELLOW}${ICON_WARNING}${NC} System cleanup · ${GRAY}time limit reached, skipped remaining slow scans${NC}"
    if declare -F note_activity > /dev/null 2>&1; then
        note_activity
    fi
}

# A timed-out producer must not feed its partial prefix into a deletion loop.
# Materialize only completed scans; callers discard the file on every failure.
materialize_completed_system_scan() {
    local output_file="$1"
    local duration="$2"
    shift 2

    : > "$output_file" || return 1
    local scan_rc=0
    run_with_timeout "$duration" "$@" > "$output_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
    return 0
}

macos_installer_candidate_identity() {
    local path="$1"
    local deadline_seconds="$2"
    local identity_timeout=""
    identity_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$deadline_seconds") || return $?
    run_with_timeout "$identity_timeout" "$STAT_BSD" \
        -f%d:%i:%m "$path" < /dev/null 2> /dev/null
}

macos_installer_process_is_idle() {
    local path="$1"
    local deadline_seconds="$2"
    local process_timeout=""
    process_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$deadline_seconds") || return $?
    local process_rc=0
    run_with_timeout "$process_timeout" pgrep -f "$path" \
        < /dev/null > /dev/null 2>&1 || process_rc=$?
    [[ $process_rc -eq 1 ]] && return 0
    [[ $process_rc -ge 128 ]] && return "$process_rc"
    return 1
}

macos_installer_candidate_still_eligible() {
    local path="$1"
    local expected_identity="$2"
    local current_macos_version="$3"
    local deadline_seconds="$4"

    [[ -d "$path" && ! -L "$path" ]] || return 1
    local current_identity=""
    current_identity=$(macos_installer_candidate_identity "$path" \
        "$deadline_seconds") || return $?
    [[ "$current_identity" == "$expected_identity" ]] || return 1

    local current_mtime="${current_identity##*:}"
    [[ "$current_mtime" =~ ^[0-9]+$ && "$current_mtime" -gt 0 ]] || return 1
    local now
    now=$(get_epoch_seconds)
    [[ "$now" =~ ^[0-9]+$ && $now -ge $current_mtime ]] || return 1
    [[ $(((now - current_mtime) / 86400)) -ge 14 ]] || return 1

    local update_state_rc=0
    software_update_pending_or_unknown \
        /Library/Preferences/com.apple.SoftwareUpdate.plist "$deadline_seconds" || update_state_rc=$?
    [[ $update_state_rc -ge 128 ]] && return "$update_state_rc"
    [[ $update_state_rc -eq 0 ]] && return 1
    macos_installer_process_is_idle "$path" "$deadline_seconds" || return $?

    if [[ -n "$current_macos_version" ]]; then
        local installer_plist="$path/Contents/Info.plist"
        [[ -f "$installer_plist" ]] || return 1
        local version_timeout=""
        version_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$deadline_seconds") || return $?
        local installer_version=""
        installer_version=$(run_with_timeout "$version_timeout" /usr/libexec/PlistBuddy \
            -c "Print :DTPlatformVersion" "$installer_plist" < /dev/null 2> /dev/null) || return $?
        installer_version="${installer_version%%.*}"
        [[ -n "$installer_version" && "$installer_version" != "$current_macos_version" ]] || return 1
    fi

    # The size probe between the caller's two eligibility checks can race with
    # Software Update or an installer launch. Repeat active-state checks and
    # finish on the exact app identity handed to safe_sudo_remove.
    update_state_rc=0
    software_update_pending_or_unknown \
        /Library/Preferences/com.apple.SoftwareUpdate.plist "$deadline_seconds" || update_state_rc=$?
    [[ $update_state_rc -ge 128 ]] && return "$update_state_rc"
    [[ $update_state_rc -eq 0 ]] && return 1
    macos_installer_process_is_idle "$path" "$deadline_seconds" || return $?
    current_identity=$(macos_installer_candidate_identity "$path" \
        "$deadline_seconds") || return $?
    [[ "$current_identity" == "$expected_identity" ]]
}

# System caches, logs, and temp files.
clean_deep_system() {
    stop_section_spinner
    # Keep the section bounded as a whole as well as at each inner scan. A
    # single slow filesystem may consume one inner timeout, but later families
    # stop once the bounded section budget is exhausted.
    local system_cleanup_budget_sec=""
    system_cleanup_budget_sec=$(system_cleanup_budget_seconds)
    local system_cleanup_deadline=$((SECONDS + system_cleanup_budget_sec))
    local cache_cleaned=0
    local cache_status=0
    start_section_spinner "Cleaning system caches..."
    local -a cache_extra_patterns=("*.tmp")
    if [[ "$MOLE_LOG_AGE_DAYS" -eq "$MOLE_TEMP_FILE_AGE_DAYS" ]]; then
        cache_extra_patterns+=("*.log")
    fi
    local cache_rc=0
    safe_sudo_find_delete "/Library/Caches" "*.cache" "$MOLE_TEMP_FILE_AGE_DAYS" "f" "5" \
        "$system_cleanup_deadline" "${cache_extra_patterns[@]}" || cache_rc=$?
    if [[ $cache_rc -ge 128 ]]; then
        stop_section_spinner
        return "$cache_rc"
    fi
    if [[ $cache_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
        cache_cleaned=1
    elif [[ $cache_rc -ne 0 ]]; then
        cache_status=$cache_rc
    fi
    # Preserve independent retention semantics if these constants ever diverge;
    # with today's equal values the common directory is traversed only once.
    if [[ "$MOLE_LOG_AGE_DAYS" -ne "$MOLE_TEMP_FILE_AGE_DAYS" && $cache_rc -eq 0 ]] &&
        ! system_cleanup_budget_reached "$system_cleanup_deadline"; then
        cache_rc=0
        safe_sudo_find_delete "/Library/Caches" "*.log" "$MOLE_LOG_AGE_DAYS" "f" "5" \
            "$system_cleanup_deadline" || cache_rc=$?
        if [[ $cache_rc -ge 128 ]]; then
            stop_section_spinner
            return "$cache_rc"
        elif [[ $cache_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
            cache_cleaned=1
        elif [[ $cache_rc -ne 0 && $cache_status -eq 0 ]]; then
            cache_status=$cache_rc
        fi
    fi
    stop_section_spinner
    if [[ $cache_status -ne 0 ]]; then
        report_system_cleanup_incomplete "System caches" "$cache_status"
    fi
    if [[ $cache_cleaned -eq 1 ]]; then
        log_success "System caches"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi
    # Do not sweep generic /private/tmp or /private/var/tmp contents here.
    # Age and a bounded scan do not prove third-party runtime state is
    # disposable, and large shared temp roots made this section look hung.
    start_section_spinner "Cleaning system crash reports..."
    local crash_rc=0
    safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*" \
        "$MOLE_CRASH_REPORT_AGE_DAYS" "f" "1" "$system_cleanup_deadline" || crash_rc=$?
    if [[ $crash_rc -ge 128 ]]; then
        stop_section_spinner
        return "$crash_rc"
    fi
    local crash_cleaned=${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0}
    stop_section_spinner
    if [[ $crash_rc -ne 0 ]]; then
        report_system_cleanup_incomplete "System crash reports" "$crash_rc"
    fi
    if [[ $crash_rc -eq 0 && $crash_cleaned -gt 0 ]]; then
        log_success "System crash reports"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi
    start_section_spinner "Cleaning system logs..."
    local system_logs_cleaned=0
    local system_logs_status=0
    local system_log_rc=0
    safe_sudo_find_delete "/private/var/log" "*.log" "$MOLE_LOG_AGE_DAYS" \
        "f" "3" "$system_cleanup_deadline" "*.gz" "*.asl" || system_log_rc=$?
    if [[ $system_log_rc -ge 128 ]]; then
        stop_section_spinner
        return "$system_log_rc"
    fi
    if [[ $system_log_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
        system_logs_cleaned=1
    elif [[ $system_log_rc -ne 0 ]]; then
        system_logs_status=$system_log_rc
    fi
    stop_section_spinner
    if [[ $system_logs_status -ne 0 ]]; then
        report_system_cleanup_incomplete "System logs" "$system_logs_status"
    fi
    if [[ $system_logs_cleaned -eq 1 ]]; then
        log_success "System logs"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi
    start_section_spinner "Cleaning third-party system logs..."
    local -a third_party_log_dirs=(
        "/Library/Logs/Adobe"
        "/Library/Logs/CreativeCloud"
    )
    local third_party_logs_cleaned=0
    local third_party_logs_status=0
    local third_party_log_dir=""
    for third_party_log_dir in "${third_party_log_dirs[@]}"; do
        if system_cleanup_budget_reached "$system_cleanup_deadline"; then
            third_party_logs_status=124
            break
        fi
        local third_party_rc=0
        safe_sudo_find_delete "$third_party_log_dir" "*" "$MOLE_LOG_AGE_DAYS" "f" "5" \
            "$system_cleanup_deadline" || third_party_rc=$?
        if [[ $third_party_rc -ge 128 ]]; then
            stop_section_spinner
            return "$third_party_rc"
        fi
        if [[ $third_party_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
            third_party_logs_cleaned=1
        elif [[ $third_party_rc -ne 0 && $third_party_logs_status -eq 0 ]]; then
            third_party_logs_status=$third_party_rc
        fi
        [[ $third_party_rc -eq 124 ]] && break
    done
    if [[ $third_party_logs_status -eq 124 ]] || system_cleanup_budget_reached "$system_cleanup_deadline"; then
        if [[ $third_party_logs_status -eq 0 ]]; then
            third_party_logs_status=124
        fi
    else
        local adobegc_rc=0
        safe_sudo_find_delete "/Library/Logs" "adobegc.log" "$MOLE_LOG_AGE_DAYS" "f" "1" \
            "$system_cleanup_deadline" || adobegc_rc=$?
        if [[ $adobegc_rc -ge 128 ]]; then
            stop_section_spinner
            return "$adobegc_rc"
        fi
        if [[ $adobegc_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
            third_party_logs_cleaned=1
        elif [[ $adobegc_rc -ne 0 && $third_party_logs_status -eq 0 ]]; then
            third_party_logs_status=$adobegc_rc
        fi
    fi
    stop_section_spinner
    if [[ $third_party_logs_status -ne 0 ]]; then
        report_system_cleanup_incomplete "Third-party system logs" "$third_party_logs_status"
    fi
    if [[ $third_party_logs_cleaned -eq 1 ]]; then
        log_success "Third-party system logs"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi
    # Software Update owns /Library/Updates and /macOS Install Data. Age,
    # process, and plist probes cannot prove those staging trees are inactive
    # across the full scan-to-delete window, so clean never removes them.
    if [[ -d "/Library/Updates" ]]; then
        debug_log "Keeping /Library/Updates: managed by Software Update"
    fi
    if [[ -d "/macOS Install Data" ]]; then
        debug_log "Keeping macOS Install Data: managed by Software Update"
    fi

    start_section_spinner "Scanning macOS installer files..."
    # Clean macOS installer apps (e.g., "Install macOS Sequoia.app")
    # Only remove installers older than 14 days, not currently running,
    # and not matching the currently installed macOS version (recovery safety).
    local installer_cleaned=0
    local installer_status=0
    local current_macos_version=""
    local current_macos_version_output=""
    local current_macos_version_rc=0
    local current_macos_version_timeout=""
    current_macos_version_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$system_cleanup_deadline") || current_macos_version_rc=$?
    if [[ $current_macos_version_rc -eq 0 ]]; then
        current_macos_version_output=$(run_with_timeout "$current_macos_version_timeout" \
            sw_vers -productVersion < /dev/null 2> /dev/null) || current_macos_version_rc=$?
    fi
    if [[ $current_macos_version_rc -eq 0 ]]; then
        current_macos_version="${current_macos_version_output%%.*}"
    elif [[ $current_macos_version_rc -ge 128 ]]; then
        stop_section_spinner
        return "$current_macos_version_rc"
    else
        installer_status=$current_macos_version_rc
    fi
    for installer_app in /Applications/Install\ macOS*.app; do
        if system_cleanup_budget_reached "$system_cleanup_deadline"; then
            break
        fi
        [[ -d "$installer_app" ]] || continue
        if [[ $installer_status -ne 0 || ! "$current_macos_version" =~ ^[0-9]+$ ]]; then
            debug_log "Keeping macOS installer apps: current system version is unavailable"
            break
        fi
        local app_name
        app_name=$(basename "$installer_app")
        local installer_identity=""
        local installer_identity_rc=0
        installer_identity=$(macos_installer_candidate_identity "$installer_app" \
            "$system_cleanup_deadline") || installer_identity_rc=$?
        if [[ $installer_identity_rc -eq 124 ]]; then
            installer_status=124
            break
        elif [[ $installer_identity_rc -ge 128 ]]; then
            stop_section_spinner
            return "$installer_identity_rc"
        elif [[ $installer_identity_rc -ne 0 ]]; then
            continue
        fi
        local installer_eligibility_rc=0
        macos_installer_candidate_still_eligible "$installer_app" "$installer_identity" \
            "$current_macos_version" "$system_cleanup_deadline" || installer_eligibility_rc=$?
        if [[ $installer_eligibility_rc -eq 124 ]]; then
            installer_status=124
            break
        elif [[ $installer_eligibility_rc -ge 128 ]]; then
            stop_section_spinner
            return "$installer_eligibility_rc"
        elif [[ $installer_eligibility_rc -ne 0 ]]; then
            debug_log "Keeping $app_name: active, current, recent, changed, or update state unknown"
            continue
        fi
        local installer_mtime="${installer_identity##*:}"
        local age_days=$((($(get_epoch_seconds) - installer_mtime) / 86400))
        local size_kb
        local installer_size_timeout=""
        if ! installer_size_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            "$system_cleanup_deadline"); then
            installer_status=124
            break
        fi
        local installer_size_rc=0
        size_kb=$(get_path_size_kb "$installer_app" \
            "$installer_size_timeout") || installer_size_rc=$?
        if [[ $installer_size_rc -eq 124 ]]; then
            installer_status=124
            break
        elif [[ $installer_size_rc -ge 128 ]]; then
            stop_section_spinner
            return "$installer_size_rc"
        elif [[ $installer_size_rc -ne 0 ]]; then
            continue
        fi
        if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
            installer_eligibility_rc=0
            macos_installer_candidate_still_eligible "$installer_app" "$installer_identity" \
                "$current_macos_version" "$system_cleanup_deadline" || installer_eligibility_rc=$?
            if [[ $installer_eligibility_rc -eq 124 ]]; then
                installer_status=124
                break
            elif [[ $installer_eligibility_rc -ge 128 ]]; then
                stop_section_spinner
                return "$installer_eligibility_rc"
            elif [[ $installer_eligibility_rc -ne 0 ]]; then
                debug_log "Keeping $app_name: eligibility changed during size probe"
                continue
            fi
            local size_human
            size_human=$(bytes_to_human "$((size_kb * 1024))")
            debug_log "Cleaning macOS installer: $app_name, $size_human, ${age_days} days old"
            local installer_remove_rc=0
            safe_sudo_remove "$installer_app" "$size_kb" \
                "$system_cleanup_deadline" || installer_remove_rc=$?
            if [[ $installer_remove_rc -eq 124 ]]; then
                installer_status=124
                break
            fi
            if [[ $installer_remove_rc -ge 128 ]]; then
                stop_section_spinner
                return "$installer_remove_rc"
            fi
            if [[ $installer_remove_rc -eq 0 ]]; then
                log_success "$app_name, $size_human"
                installer_cleaned=$((installer_cleaned + 1))
            fi
        fi
    done
    stop_section_spinner
    if [[ $installer_cleaned -gt 0 ]]; then
        debug_log "Cleaned $installer_cleaned macOS installer(s)"
    fi
    if [[ $installer_status -ne 0 ]]; then
        report_system_cleanup_incomplete "macOS installer files" "$installer_status"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi
    start_section_spinner "Scanning browser code signature caches..."
    local code_sign_cleaned=0
    local code_sign_scan_file=""
    local code_sign_scan_rc=0
    if code_sign_scan_file=$(create_temp_file 2> /dev/null); then
        local code_sign_scan_timeout=""
        code_sign_scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            "$system_cleanup_deadline") || code_sign_scan_rc=$?
        if [[ $code_sign_scan_rc -eq 0 ]]; then
            # -path is a test, not a prune: without the container-level prune
            # find still walks every C/ and T/ tree even though only X/ can
            # match. Depth 3 is the /var/folders/<xx>/<hash>/<container> level.
            materialize_completed_system_scan "$code_sign_scan_file" \
                "$code_sign_scan_timeout" /usr/bin/find /private/var/folders \
                -maxdepth 5 -type d \( -depth 3 ! -name X \) -prune \
                -o -type d -name "*.code_sign_clone" -path "*/X/*" -print0 || code_sign_scan_rc=$?
        fi
        if [[ $code_sign_scan_rc -eq 0 ]]; then
            while IFS= read -r -d '' cache_dir; do
                if system_cleanup_budget_reached "$system_cleanup_deadline"; then
                    code_sign_scan_rc=124
                    break
                fi
                # Never delete an EDR agent's code-signature clone -- same
                # sensor-tamper risk as its caches below. Browsers are the target.
                if is_endpoint_security_cache_path "$cache_dir"; then
                    continue
                fi
                local code_sign_remove_rc=0
                safe_sudo_remove "$cache_dir" "" "$system_cleanup_deadline" || code_sign_remove_rc=$?
                if [[ $code_sign_remove_rc -eq 124 || $code_sign_remove_rc -ge 128 ]]; then
                    code_sign_scan_rc=$code_sign_remove_rc
                    break
                fi
                if [[ $code_sign_remove_rc -eq 0 ]]; then
                    code_sign_cleaned=$((code_sign_cleaned + 1))
                fi
            done < "$code_sign_scan_file"
        fi
        rm -f -- "$code_sign_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    else
        code_sign_scan_rc=1
    fi
    stop_section_spinner
    if [[ $code_sign_scan_rc -ne 0 ]]; then
        if [[ $code_sign_scan_rc -ge 128 ]]; then
            return "$code_sign_scan_rc"
        fi
        report_system_cleanup_incomplete "Browser code signature caches" "$code_sign_scan_rc"
    fi
    if [[ $code_sign_cleaned -gt 0 ]]; then
        log_success "Browser code signature caches, $code_sign_cleaned items"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi

    start_section_spinner "Cleaning rebuildable system service caches..."
    local rebuildable_cache_cleaned=0
    local rebuildable_cache_status=0
    local -a rebuildable_cache_dirs=(
        "/Library/Caches/com.apple.iconservices.store"
    )
    local rebuildable_cache_dir=""
    for rebuildable_cache_dir in "${rebuildable_cache_dirs[@]}"; do
        if system_cleanup_budget_reached "$system_cleanup_deadline"; then
            break
        fi
        local rebuildable_exists_rc=0
        local rebuildable_probe_timeout=""
        rebuildable_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$system_cleanup_deadline") || rebuildable_exists_rc=$?
        if [[ $rebuildable_exists_rc -eq 0 ]]; then
            _mole_bounded_sudo "$rebuildable_probe_timeout" \
                -n test -e "$rebuildable_cache_dir" < /dev/null 2> /dev/null || rebuildable_exists_rc=$?
        fi
        if [[ $rebuildable_exists_rc -eq 124 ]]; then
            rebuildable_cache_status=124
            break
        fi
        if [[ $rebuildable_exists_rc -ge 128 ]]; then
            stop_section_spinner
            return "$rebuildable_exists_rc"
        fi
        [[ $rebuildable_exists_rc -eq 0 ]] || continue
        local rebuildable_remove_rc=0
        safe_sudo_remove "$rebuildable_cache_dir" "" "$system_cleanup_deadline" || rebuildable_remove_rc=$?
        if [[ $rebuildable_remove_rc -eq 124 ]]; then
            rebuildable_cache_status=124
            break
        fi
        if [[ $rebuildable_remove_rc -ge 128 ]]; then
            stop_section_spinner
            return "$rebuildable_remove_rc"
        fi
        if [[ $rebuildable_remove_rc -eq 0 ]]; then
            rebuildable_cache_cleaned=$((rebuildable_cache_cleaned + 1))
        fi
    done
    stop_section_spinner
    if [[ $rebuildable_cache_cleaned -gt 0 ]]; then
        local rebuildable_cache_label="items"
        if [[ $rebuildable_cache_cleaned -eq 1 ]]; then
            rebuildable_cache_label="item"
        fi
        log_success "Rebuildable system caches, $rebuildable_cache_cleaned $rebuildable_cache_label"
    fi
    if [[ $rebuildable_cache_status -ne 0 ]]; then
        report_system_cleanup_incomplete "Rebuildable system caches" "$rebuildable_cache_status"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi

    start_section_spinner "Scanning accessible rebuildable GPU caches..."
    local gpu_cache_cleaned=0
    local gpu_cache_dir=""
    local gpu_scan_file=""
    local gpu_scan_rc=0
    if gpu_scan_file=$(create_temp_file 2> /dev/null); then
        local gpu_scan_timeout=""
        gpu_scan_timeout=$(_mole_timeout_with_deadline 8 "$system_cleanup_deadline") || gpu_scan_rc=$?
        if [[ $gpu_scan_rc -eq 0 ]]; then
            # -path "*/C/*" is a test, not a prune: without the container-level
            # prune find walks the entire T/ temp tree to depth 8 even though
            # nothing there can match (measured 217k dirs / 19s on a dev
            # machine, 99.6% of them under T/; pruned: 0.09s, same results).
            materialize_completed_system_scan "$gpu_scan_file" "$gpu_scan_timeout" /usr/bin/find \
                /private/var/folders -maxdepth 8 \
                -type d \( -depth 3 ! -name C \) -prune \
                -o -type d \( \
                -name "com.apple.gpuarchiver" -o \
                -name "com.apple.metal" -o \
                -name "com.apple.metalfe" \
                \) -path "*/C/*" -print0 || gpu_scan_rc=$?
        fi
        if [[ $gpu_scan_rc -eq 0 ]]; then
            while IFS= read -r -d '' gpu_cache_dir; do
                if system_cleanup_budget_reached "$system_cleanup_deadline"; then
                    gpu_scan_rc=124
                    break
                fi
                is_rebuildable_gpu_cache_dir "$gpu_cache_dir" || continue
                # Endpoint-security/EDR agents tamper-protect their cache
                # container. Skip only those; other app GPU caches stay cleanable.
                if is_endpoint_security_cache_path "$gpu_cache_dir"; then
                    continue
                fi
                local gpu_stale_rc=0
                gpu_cache_dir_is_stale "$gpu_cache_dir" "$MOLE_GPU_CACHE_AGE_DAYS" || gpu_stale_rc=$?
                if [[ $gpu_stale_rc -eq 124 ]]; then
                    gpu_scan_rc=124
                    break
                elif [[ $gpu_stale_rc -ge 128 ]]; then
                    gpu_scan_rc=$gpu_stale_rc
                    break
                fi
                [[ $gpu_stale_rc -eq 0 ]] || continue
                local gpu_remove_rc=0
                safe_sudo_remove "$gpu_cache_dir" "" "$system_cleanup_deadline" || gpu_remove_rc=$?
                if [[ $gpu_remove_rc -eq 124 || $gpu_remove_rc -ge 128 ]]; then
                    gpu_scan_rc=$gpu_remove_rc
                    break
                fi
                if [[ $gpu_remove_rc -eq 0 ]]; then
                    gpu_cache_cleaned=$((gpu_cache_cleaned + 1))
                fi
            done < "$gpu_scan_file"
        fi
        rm -f -- "$gpu_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    else
        gpu_scan_rc=1
    fi
    stop_section_spinner
    if [[ $gpu_scan_rc -ne 0 ]]; then
        if [[ $gpu_scan_rc -ge 128 ]]; then
            return "$gpu_scan_rc"
        fi
        report_system_cleanup_incomplete "Accessible rebuildable GPU caches" "$gpu_scan_rc"
    fi
    if [[ $gpu_cache_cleaned -gt 0 ]]; then
        local gpu_cache_label="items"
        if [[ $gpu_cache_cleaned -eq 1 ]]; then
            gpu_cache_label="item"
        fi
        log_success "Accessible rebuildable GPU caches, $gpu_cache_cleaned $gpu_cache_label"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi

    # Aborted Aerial / dynamic-wallpaper downloads. com.apple.idleassetsd runs
    # as root, so its per-user Darwin temp dir sits under root's
    # /private/var/folders tree (mode 700) and is invisible to an unprivileged
    # scan: macOS buries the bytes in the opaque "System Data" bucket, and a
    # stuck (re)download can leave hundreds of GB of ~1GB CFNetworkDownload_*.tmp
    # files behind (#1253). Scope the removal to the idleassetsd temp dir and to
    # that exact aborted-download name, older than the temp-file retention
    # window, so an in-progress download (recent mtime) is never touched. macOS
    # re-fetches assets on demand, so the removal is non-destructive. The locator
    # needs sudo because the whole tree is root-owned; safe_sudo_find_delete then
    # re-applies the shared protection and whitelist gates per file.
    start_section_spinner "Scanning stale wallpaper downloads..."
    local idle_tmp_cleaned=0
    local idle_tmp_status=0
    local idle_tmp_dir=""
    local idle_scan_file=""
    if idle_scan_file=$(create_temp_file 2> /dev/null); then
        local idle_scan_timeout=""
        idle_scan_timeout=$(_mole_timeout_with_deadline 8 "$system_cleanup_deadline") || idle_tmp_status=$?
        if [[ $idle_tmp_status -eq 0 ]]; then
            _mole_materialize_bounded_sudo_find "$idle_scan_file" "$idle_scan_timeout" \
                /private/var/folders -maxdepth 5 -type d -name "com.apple.idleassetsd" \
                -path "*/T/*" -print0 || idle_tmp_status=$?
        fi
        if [[ $idle_tmp_status -eq 0 ]]; then
            while IFS= read -r -d '' idle_tmp_dir; do
                if system_cleanup_budget_reached "$system_cleanup_deadline"; then
                    idle_tmp_status=124
                    break
                fi
                local idle_tmp_rc=0
                safe_sudo_find_delete "$idle_tmp_dir" "CFNetworkDownload_*.tmp" \
                    "$MOLE_TEMP_FILE_AGE_DAYS" "f" "5" "$system_cleanup_deadline" || idle_tmp_rc=$?
                if [[ $idle_tmp_rc -ge 128 ]]; then
                    idle_tmp_status=$idle_tmp_rc
                    break
                fi
                if [[ $idle_tmp_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
                    idle_tmp_cleaned=$((idle_tmp_cleaned + 1))
                elif [[ $idle_tmp_rc -ne 0 && $idle_tmp_status -eq 0 ]]; then
                    idle_tmp_status=$idle_tmp_rc
                fi
            done < "$idle_scan_file"
        fi
        rm -f -- "$idle_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    else
        idle_tmp_status=1
    fi
    stop_section_spinner
    if [[ $idle_tmp_status -ge 128 ]]; then
        return "$idle_tmp_status"
    fi
    if [[ $idle_tmp_status -ne 0 ]]; then
        report_system_cleanup_incomplete "Stale wallpaper downloads" "$idle_tmp_status"
    fi
    if [[ $idle_tmp_cleaned -gt 0 ]]; then
        log_success "Stale wallpaper downloads"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi

    local diag_base="/private/var/db/diagnostics"
    start_section_spinner "Cleaning system diagnostic logs..."
    local diag_cleaned=0
    local diag_status=0
    local diag_rc=0
    safe_sudo_find_delete "$diag_base" "*" "$MOLE_LOG_AGE_DAYS" "f" "5" \
        "$system_cleanup_deadline" || diag_rc=$?
    if [[ $diag_rc -ge 128 ]]; then
        stop_section_spinner
        return "$diag_rc"
    fi
    if [[ $diag_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
        diag_cleaned=1
    elif [[ $diag_rc -ne 0 ]]; then
        diag_status=$diag_rc
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        if [[ $diag_status -eq 0 ]]; then
            diag_status=124
        fi
    else
        diag_rc=0
        safe_sudo_find_delete "/private/var/db/DiagnosticPipeline" "*" \
            "$MOLE_LOG_AGE_DAYS" "f" "5" "$system_cleanup_deadline" || diag_rc=$?
        if [[ $diag_rc -ge 128 ]]; then
            stop_section_spinner
            return "$diag_rc"
        fi
        if [[ $diag_rc -eq 0 && ${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0} -gt 0 ]]; then
            diag_cleaned=1
        elif [[ $diag_rc -ne 0 && $diag_status -eq 0 ]]; then
            diag_status=$diag_rc
        fi
    fi
    stop_section_spinner
    if [[ $diag_status -ne 0 ]]; then
        report_system_cleanup_incomplete "System diagnostic logs" "$diag_status"
    fi
    if [[ $diag_cleaned -eq 1 ]]; then
        log_success "System diagnostic logs"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi

    start_section_spinner "Cleaning power logs..."
    local power_rc=0
    safe_sudo_find_delete "/private/var/db/powerlog" "*" "$MOLE_LOG_AGE_DAYS" "f" "5" \
        "$system_cleanup_deadline" || power_rc=$?
    if [[ $power_rc -ge 128 ]]; then
        stop_section_spinner
        return "$power_rc"
    fi
    local power_cleaned=${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0}
    stop_section_spinner
    if [[ $power_rc -ne 0 ]]; then
        report_system_cleanup_incomplete "Power logs" "$power_rc"
    fi
    if [[ $power_rc -eq 0 && $power_cleaned -gt 0 ]]; then
        log_success "Power logs"
    fi
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        report_system_cleanup_budget_reached
        return 0
    fi
    local power_notice_rc=0
    show_large_active_powerlog_notice || power_notice_rc=$?
    if [[ $power_notice_rc -ge 128 ]]; then
        return "$power_notice_rc"
    fi
    start_section_spinner "Cleaning memory exception reports..."
    local mem_reports_dir="/private/var/db/reportmemoryexception/MemoryLimitViolations"
    local mem_cleaned=0
    # Count and size old files before deletion. The sizing result is advisory;
    # a timeout discards it and the independently bounded deletion scan decides
    # whether any target is eligible.
    local file_count=0
    local total_size_kb=0
    local total_bytes=0
    local stats_out=""
    local stats_rc=0
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        stats_rc=124
    else
        local stats_timeout=""
        stats_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            "$system_cleanup_deadline") || stats_rc=$?
        if [[ $stats_rc -eq 0 ]]; then
            stats_out=$(_mole_bounded_sudo_find "$stats_timeout" \
                "$mem_reports_dir" -maxdepth 5 -type f -mtime +30 -exec stat -f "%z" {} + 2> /dev/null |
                awk '{c++; s+=$1} END {print c+0, s+0}') || stats_rc=$?
        fi
    fi
    if [[ $stats_rc -ge 128 ]]; then
        stop_section_spinner
        return "$stats_rc"
    fi
    if [[ $stats_rc -eq 0 && -n "$stats_out" ]]; then
        read -r file_count total_bytes <<< "$stats_out"
        total_size_kb=$((total_bytes / 1024))
    fi

    local mem_rc=0
    if system_cleanup_budget_reached "$system_cleanup_deadline"; then
        mem_rc=124
    else
        safe_sudo_find_delete "$mem_reports_dir" "*" "30" "f" "5" \
            "$system_cleanup_deadline" || mem_rc=$?
    fi
    if [[ $mem_rc -ge 128 ]]; then
        stop_section_spinner
        return "$mem_rc"
    fi
    local mem_removed_count=${MOLE_SAFE_SUDO_FIND_DELETE_COUNT:-0}
    if [[ $mem_rc -eq 0 && $mem_removed_count -gt 0 ]]; then
        if [[ "${DRY_RUN:-}" != "true" ]]; then
            mem_cleaned=1
            # Only attach the pre-scan size when it covered exactly the same
            # completed candidate set as the deletion helper.
            if [[ $stats_rc -eq 0 && $file_count -eq $mem_removed_count ]] &&
                oplog_enabled && [[ "$total_size_kb" -gt 0 ]]; then
                local size_human
                size_human=$(bytes_to_human "$((total_size_kb * 1024))")
                log_operation "clean" "REMOVED" "$mem_reports_dir" "$mem_removed_count files, $size_human"
            fi
        elif [[ $stats_rc -eq 0 && $file_count -eq $mem_removed_count ]]; then
            log_info "[DRY-RUN] Would remove $mem_removed_count old memory exception reports ($total_size_kb KB)"
        else
            log_info "[DRY-RUN] Would remove $mem_removed_count old memory exception reports"
        fi
    elif [[ $mem_rc -ne 0 ]]; then
        report_system_cleanup_incomplete "Memory exception reports" "$mem_rc"
    elif [[ $stats_rc -eq 124 ]]; then
        report_system_cleanup_incomplete "Memory exception report sizing" "$stats_rc"
    fi
    stop_section_spinner
    if [[ $mem_cleaned -eq 1 ]]; then
        log_success "Memory exception reports"
    fi
    return 0
}

time_machine_candidate_identity() {
    local path="$1"
    local deadline_seconds="$2"
    local identity_timeout=""
    identity_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$deadline_seconds") || return $?
    run_with_timeout "$identity_timeout" "$STAT_BSD" -f%d:%i:%m "$path" < /dev/null 2> /dev/null
}

# Recheck every destructive predicate immediately before tmutil sees the path.
# tmutil remains the owner of backup deletion, but Mole must not hand it a path
# that changed identity/age or became active after the completed scan.
time_machine_candidate_still_eligible() {
    local path="$1"
    local expected_identity="$2"
    local minimum_hours="$3"
    local deadline_seconds="$4"

    [[ -d "$path" && ! -L "$path" ]] || return 1

    local running_rc=0
    tm_is_running "$deadline_seconds" || running_rc=$?
    if [[ $running_rc -ge 128 ]]; then
        return "$running_rc"
    fi
    # Only the explicit idle status authorizes a delete.
    [[ $running_rc -eq 1 ]] || return 1

    local current_identity=""
    local identity_rc=0
    current_identity=$(time_machine_candidate_identity "$path" "$deadline_seconds") || identity_rc=$?
    if [[ $identity_rc -ne 0 ]]; then
        return "$identity_rc"
    fi
    [[ "$current_identity" == "$expected_identity" ]] || return 1

    local current_mtime="${current_identity##*:}"
    [[ "$current_mtime" =~ ^[0-9]+$ && "$current_mtime" -gt 0 ]] || return 1
    local now
    now=$(get_epoch_seconds)
    [[ $(((now - current_mtime) / 3600)) -ge $minimum_hours ]] || return 1

    # A backup may start while the path checks are running. Recheck both the
    # Time Machine state and path identity at the edge of the tmutil call.
    running_rc=0
    tm_is_running "$deadline_seconds" || running_rc=$?
    if [[ $running_rc -ge 128 ]]; then
        return "$running_rc"
    fi
    [[ $running_rc -eq 1 ]] || return 1
    current_identity=$(time_machine_candidate_identity "$path" "$deadline_seconds") || return $?
    [[ "$current_identity" == "$expected_identity" ]]
}

# Incomplete Time Machine backups.
clean_time_machine_failed_backups() {
    local tm_cleaned=0
    if ! command -v tmutil > /dev/null 2>&1; then
        debug_log "Time Machine: no incomplete backups found"
        return 0
    fi
    # Fast pre-check: skip entirely if Time Machine is not configured (no tmutil needed)
    if ! defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        debug_log "Time Machine: no incomplete backups found"
        return 0
    fi
    start_section_spinner "Checking Time Machine configuration..."
    local spinner_active=true
    local tm_info=""
    local tm_info_rc=0
    tm_info=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" tmutil destinationinfo 2>&1) || tm_info_rc=$?
    if [[ $tm_info_rc -ge 128 ]]; then
        stop_section_spinner
        return "$tm_info_rc"
    fi
    if [[ $tm_info_rc -eq 124 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Time Machine cleanup · skipped (configuration check timed out)"
        note_activity
        return 0
    fi
    if [[ "$tm_info" == *"No destinations configured"* || $tm_info_rc -ne 0 ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        debug_log "Time Machine: no incomplete backups found"
        return 0
    fi
    if [[ ! -d "/Volumes" ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        debug_log "Time Machine: no incomplete backups found"
        return 0
    fi
    # tm_is_running is tri-state: 0 running, 1 idle, 2 status-unknown. Treat
    # both running and unknown as "do not touch backups", the same idiom
    # clean_local_snapshots uses. A bare `if tm_is_running` would let a
    # transient tmutil error (rc 2) fall through and delete an in-progress
    # backup.
    local rc_tm_running=0
    tm_is_running || rc_tm_running=$?
    if [[ $rc_tm_running -ge 128 ]]; then
        stop_section_spinner
        return "$rc_tm_running"
    fi
    if [[ $rc_tm_running -eq 0 || $rc_tm_running -eq 2 || $rc_tm_running -eq 124 ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        if [[ $rc_tm_running -eq 2 || $rc_tm_running -eq 124 ]]; then
            echo -e "  ${YELLOW}!${NC} Time Machine cleanup · skipped (status unknown)"
            note_activity
        else
            echo -e "  ${YELLOW}!${NC} Time Machine cleanup · skipped (backup in progress)"
            note_activity
        fi
        return 0
    fi
    if [[ "$spinner_active" == "true" ]]; then
        start_section_spinner "Checking backup volumes..."
    fi
    # Fast pre-scan for backup volumes to avoid slow tmutil checks.
    local -a backup_volumes=()
    for volume in /Volumes/*; do
        [[ -d "$volume" ]] || continue
        [[ "$volume" == "/Volumes/MacintoshHD" || "$volume" == "/" ]] && continue
        [[ -L "$volume" ]] && continue
        if [[ -d "$volume/Backups.backupdb" ]] || [[ -d "$volume/.MobileBackups" ]]; then
            backup_volumes+=("$volume")
        fi
    done
    if [[ ${#backup_volumes[@]} -eq 0 ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        debug_log "Time Machine: no incomplete backups found"
        return 0
    fi
    if [[ "$spinner_active" == "true" ]]; then
        start_section_spinner "Scanning backup volumes..."
    fi
    local tm_scan_file=""
    if ! tm_scan_file=$(create_temp_file 2> /dev/null); then
        stop_section_spinner
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Time Machine backups · ${GRAY}scan unavailable, skipped cleanup${NC}"
        note_activity
        return 0
    fi
    local tm_scan_deadline=$((SECONDS + 60))
    local tm_scan_incomplete=false
    local tm_scan_timed_out=false
    local tm_interrupt_rc=0
    for volume in "${backup_volumes[@]}"; do
        if system_cleanup_budget_reached "$tm_scan_deadline"; then
            tm_scan_timed_out=true
            break
        fi
        local fs_type="unknown"
        local fs_probe=""
        local fs_probe_rc=0
        fs_probe=$(run_with_timeout 1 /bin/df -T "$volume" 2> /dev/null) || fs_probe_rc=$? # 1s: volume FS-type probe, see lib/core/timeouts.sh
        if [[ $fs_probe_rc -ge 128 ]]; then
            tm_interrupt_rc=$fs_probe_rc
            break
        elif [[ $fs_probe_rc -eq 124 ]]; then
            tm_scan_incomplete=true
            tm_scan_timed_out=true
            break
        elif [[ $fs_probe_rc -eq 0 ]]; then
            fs_type=$(printf '%s\n' "$fs_probe" | tail -1 | awk '{print $2}')
        fi
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav | unknown) continue ;;
        esac
        local backupdb_dir="$volume/Backups.backupdb"
        if [[ -d "$backupdb_dir" ]]; then
            local backupdb_scan_rc=0
            local backupdb_scan_timeout=""
            backupdb_scan_timeout=$(_mole_timeout_with_deadline 15 "$tm_scan_deadline") || backupdb_scan_rc=$?
            if [[ $backupdb_scan_rc -eq 0 ]]; then
                materialize_completed_system_scan "$tm_scan_file" "$backupdb_scan_timeout" find "$backupdb_dir" \
                    -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) \
                    -print0 || backupdb_scan_rc=$?
            fi
            if [[ $backupdb_scan_rc -ge 128 ]]; then
                tm_interrupt_rc=$backupdb_scan_rc
                break
            fi
            if [[ $backupdb_scan_rc -ne 0 ]]; then
                debug_log "Skipping incomplete backups in $backupdb_dir: scan status $backupdb_scan_rc"
                tm_scan_incomplete=true
                [[ $backupdb_scan_rc -eq 124 ]] && tm_scan_timed_out=true
                continue
            fi
            while IFS= read -r -d '' inprogress_file; do
                [[ -d "$inprogress_file" ]] || continue
                [[ -L "$inprogress_file" ]] && continue
                # Only delete old incomplete backups (safety window).
                local candidate_identity=""
                local candidate_identity_rc=0
                candidate_identity=$(time_machine_candidate_identity "$inprogress_file" \
                    "$tm_scan_deadline") || candidate_identity_rc=$?
                if [[ $candidate_identity_rc -ge 128 ]]; then
                    tm_interrupt_rc=$candidate_identity_rc
                    break
                elif [[ $candidate_identity_rc -eq 124 ]]; then
                    tm_scan_timed_out=true
                    break
                elif [[ $candidate_identity_rc -ne 0 ]]; then
                    continue
                fi
                local file_mtime="${candidate_identity##*:}"
                # get_file_mtime returns 0 when stat fails. A 0 here would make
                # the backup look ancient and clear the safety window, so treat
                # "cannot read mtime" as "too recent to touch" and keep it.
                [[ "$file_mtime" =~ ^[0-9]+$ && "$file_mtime" -gt 0 ]] || continue
                local current_time
                current_time=$(get_epoch_seconds)
                local hours_old=$(((current_time - file_mtime) / 3600))
                if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                    continue
                fi
                local size_kb
                local size_timeout=""
                size_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    "$tm_scan_deadline") || {
                    tm_scan_timed_out=true
                    break
                }
                local size_rc=0
                size_kb=$(get_path_size_kb "$inprogress_file" "$size_timeout") || size_rc=$?
                if [[ $size_rc -eq 124 ]]; then
                    tm_scan_timed_out=true
                    break
                elif [[ $size_rc -ge 128 ]]; then
                    tm_interrupt_rc=$size_rc
                    break
                elif [[ $size_rc -ne 0 ]]; then
                    continue
                fi
                [[ "$size_kb" -le 0 ]] && continue
                if [[ "$spinner_active" == "true" ]]; then
                    stop_section_spinner
                    spinner_active=false
                fi
                local backup_name
                backup_name=$(basename "$inprogress_file")
                local size_human
                size_human=$(bytes_to_human "$((size_kb * 1024))")
                if [[ "$DRY_RUN" == "true" ]]; then
                    if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                        record_dry_run_cleanup_target "$inprogress_file" "$size_kb" 1 true || continue
                    fi
                    echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete backup: $backup_name${NC} · $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    note_activity
                    continue
                fi
                if ! command -v tmutil > /dev/null 2>&1; then
                    echo -e "  ${YELLOW}!${NC} Incomplete backup: $backup_name · skipped (tmutil unavailable)"
                    note_activity
                    continue
                fi
                local eligibility_rc=0
                time_machine_candidate_still_eligible "$inprogress_file" "$candidate_identity" \
                    "$MOLE_TM_BACKUP_SAFE_HOURS" "$tm_scan_deadline" || eligibility_rc=$?
                if [[ $eligibility_rc -ge 128 ]]; then
                    tm_interrupt_rc=$eligibility_rc
                    break
                elif [[ $eligibility_rc -eq 124 ]]; then
                    tm_scan_timed_out=true
                    break
                elif [[ $eligibility_rc -ne 0 ]]; then
                    debug_log "Keeping changed or active Time Machine candidate: $inprogress_file"
                    continue
                fi
                local tm_delete_timeout=""
                local tm_delete_rc=0
                tm_delete_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    "$tm_scan_deadline") || tm_delete_rc=$?
                if [[ $tm_delete_rc -eq 0 ]]; then
                    run_with_timeout "$tm_delete_timeout" tmutil delete "$inprogress_file" 2> /dev/null || tm_delete_rc=$?
                fi
                if [[ $tm_delete_rc -eq 0 ]]; then
                    local line_color
                    line_color=$(cleanup_result_color_kb "$size_kb")
                    echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete backup: $backup_name${NC} · ${line_color}$size_human${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    files_cleaned=$((files_cleaned + 1))
                    total_size_cleaned=$((total_size_cleaned + size_kb))
                    total_items=$((total_items + 1))
                    note_activity
                else
                    echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name · try manually with sudo"
                    # Mark activity so the idle-section erase in end_section
                    # never wipes this failure warning off the terminal.
                    note_activity
                    if [[ $tm_delete_rc -ge 128 ]]; then
                        tm_interrupt_rc=$tm_delete_rc
                        break
                    elif [[ $tm_delete_rc -eq 124 ]]; then
                        tm_scan_timed_out=true
                        break
                    fi
                fi
            done < "$tm_scan_file"
        fi
        if [[ $tm_interrupt_rc -ne 0 || "$tm_scan_timed_out" == "true" ]]; then
            break
        fi
        # APFS bundles.
        for bundle in "$volume"/*.backupbundle "$volume"/*.sparsebundle; do
            if system_cleanup_budget_reached "$tm_scan_deadline"; then
                tm_scan_timed_out=true
                break
            fi
            [[ -e "$bundle" ]] || continue
            [[ -d "$bundle" ]] || continue
            local bundle_name
            bundle_name=$(basename "$bundle")
            local mounted_path=""
            local hdiutil_info=""
            local hdiutil_rc=0
            hdiutil_info=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" hdiutil info 2> /dev/null) || hdiutil_rc=$?
            if [[ $hdiutil_rc -ge 128 ]]; then
                tm_interrupt_rc=$hdiutil_rc
                break
            elif [[ $hdiutil_rc -eq 124 ]]; then
                tm_scan_incomplete=true
                tm_scan_timed_out=true
                break
            elif [[ $hdiutil_rc -eq 0 ]]; then
                mounted_path=$(printf '%s\n' "$hdiutil_info" | grep -A 5 "image-path.*$bundle_name" | grep "/Volumes/" | awk '{print $1}' | head -1 || true)
            fi
            if [[ -n "$mounted_path" && -d "$mounted_path" ]]; then
                local mounted_scan_rc=0
                local mounted_scan_timeout=""
                mounted_scan_timeout=$(_mole_timeout_with_deadline 15 "$tm_scan_deadline") || mounted_scan_rc=$?
                if [[ $mounted_scan_rc -eq 0 ]]; then
                    materialize_completed_system_scan "$tm_scan_file" "$mounted_scan_timeout" find "$mounted_path" \
                        -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) \
                        -print0 || mounted_scan_rc=$?
                fi
                if [[ $mounted_scan_rc -ge 128 ]]; then
                    tm_interrupt_rc=$mounted_scan_rc
                    break
                fi
                if [[ $mounted_scan_rc -ne 0 ]]; then
                    debug_log "Skipping incomplete backups in $mounted_path: scan status $mounted_scan_rc"
                    tm_scan_incomplete=true
                    [[ $mounted_scan_rc -eq 124 ]] && tm_scan_timed_out=true
                    continue
                fi
                while IFS= read -r -d '' inprogress_file; do
                    [[ -d "$inprogress_file" ]] || continue
                    [[ -L "$inprogress_file" ]] && continue
                    local candidate_identity=""
                    local candidate_identity_rc=0
                    candidate_identity=$(time_machine_candidate_identity "$inprogress_file" \
                        "$tm_scan_deadline") || candidate_identity_rc=$?
                    if [[ $candidate_identity_rc -ge 128 ]]; then
                        tm_interrupt_rc=$candidate_identity_rc
                        break
                    elif [[ $candidate_identity_rc -eq 124 ]]; then
                        tm_scan_timed_out=true
                        break
                    elif [[ $candidate_identity_rc -ne 0 ]]; then
                        continue
                    fi
                    local file_mtime="${candidate_identity##*:}"
                    # Keep the backup if its mtime cannot be read (see above).
                    [[ "$file_mtime" =~ ^[0-9]+$ && "$file_mtime" -gt 0 ]] || continue
                    local current_time
                    current_time=$(get_epoch_seconds)
                    local hours_old=$(((current_time - file_mtime) / 3600))
                    if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                        continue
                    fi
                    local size_kb
                    local size_timeout=""
                    size_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                        "$tm_scan_deadline") || {
                        tm_scan_timed_out=true
                        break
                    }
                    local size_rc=0
                    size_kb=$(get_path_size_kb "$inprogress_file" "$size_timeout") || size_rc=$?
                    if [[ $size_rc -eq 124 ]]; then
                        tm_scan_timed_out=true
                        break
                    elif [[ $size_rc -ge 128 ]]; then
                        tm_interrupt_rc=$size_rc
                        break
                    elif [[ $size_rc -ne 0 ]]; then
                        continue
                    fi
                    [[ "$size_kb" -le 0 ]] && continue
                    if [[ "$spinner_active" == "true" ]]; then
                        stop_section_spinner
                        spinner_active=false
                    fi
                    local backup_name
                    backup_name=$(basename "$inprogress_file")
                    local size_human
                    size_human=$(bytes_to_human "$((size_kb * 1024))")
                    if [[ "$DRY_RUN" == "true" ]]; then
                        if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                            record_dry_run_cleanup_target "$inprogress_file" "$size_kb" 1 true || continue
                        fi
                        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC} · $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        note_activity
                        continue
                    fi
                    if ! command -v tmutil > /dev/null 2>&1; then
                        continue
                    fi
                    local eligibility_rc=0
                    time_machine_candidate_still_eligible "$inprogress_file" "$candidate_identity" \
                        "$MOLE_TM_BACKUP_SAFE_HOURS" "$tm_scan_deadline" || eligibility_rc=$?
                    if [[ $eligibility_rc -ge 128 ]]; then
                        tm_interrupt_rc=$eligibility_rc
                        break
                    elif [[ $eligibility_rc -eq 124 ]]; then
                        tm_scan_timed_out=true
                        break
                    elif [[ $eligibility_rc -ne 0 ]]; then
                        debug_log "Keeping changed or active Time Machine candidate: $inprogress_file"
                        continue
                    fi
                    local tm_delete_timeout=""
                    local tm_delete_rc=0
                    tm_delete_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                        "$tm_scan_deadline") || tm_delete_rc=$?
                    if [[ $tm_delete_rc -eq 0 ]]; then
                        run_with_timeout "$tm_delete_timeout" tmutil delete "$inprogress_file" 2> /dev/null || tm_delete_rc=$?
                    fi
                    if [[ $tm_delete_rc -eq 0 ]]; then
                        local line_color
                        line_color=$(cleanup_result_color_kb "$size_kb")
                        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC} · ${line_color}$size_human${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        files_cleaned=$((files_cleaned + 1))
                        total_size_cleaned=$((total_size_cleaned + size_kb))
                        total_items=$((total_items + 1))
                        note_activity
                    else
                        echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                        # Keep the warning visible past the idle-section erase.
                        note_activity
                        if [[ $tm_delete_rc -ge 128 ]]; then
                            tm_interrupt_rc=$tm_delete_rc
                            break
                        elif [[ $tm_delete_rc -eq 124 ]]; then
                            tm_scan_timed_out=true
                            break
                        fi
                    fi
                done < "$tm_scan_file"
            fi
            if [[ $tm_interrupt_rc -ne 0 || "$tm_scan_timed_out" == "true" ]]; then
                break
            fi
        done
        if [[ $tm_interrupt_rc -ne 0 || "$tm_scan_timed_out" == "true" ]]; then
            break
        fi
    done
    rm -f -- "$tm_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $tm_cleaned -eq 0 ]]; then
        debug_log "Time Machine: no incomplete backups found"
    fi
    if [[ $tm_interrupt_rc -ne 0 ]]; then
        return "$tm_interrupt_rc"
    fi
    if [[ "$tm_scan_timed_out" == "true" || "$tm_scan_incomplete" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Time Machine backups · ${GRAY}scan incomplete, skipped remaining cleanup${NC}"
        note_activity
    fi
}
# Returns 0 if a backup is actively running.
# Returns 1 if not running.
# Returns 2 if status cannot be determined
tm_is_running() {
    local st=""
    local status_rc=0
    local deadline_seconds="${1:-}"
    local status_timeout=""
    status_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$deadline_seconds") || status_rc=$?
    if [[ $status_rc -eq 0 ]]; then
        st="$(run_with_timeout "$status_timeout" tmutil status 2> /dev/null)" || status_rc=$?
    fi
    if [[ $status_rc -ge 128 ]]; then
        return "$status_rc"
    fi
    [[ $status_rc -eq 0 ]] || return 2

    # If we can't find a Running field at all, treat as unknown.
    if ! grep -qE '(^|[[:space:]])("Running"|Running)[[:space:]]*=' <<< "$st"; then
        return 2
    fi

    # Match: Running = 1;   OR   "Running" = 1   (with or without trailing ;)
    grep -qE '(^|[[:space:]])("Running"|Running)[[:space:]]*=[[:space:]]*1([[:space:]]*;|$)' <<< "$st"
}

# Local APFS snapshots (report only).
clean_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        return 0
    fi
    # Fast pre-check: skip entirely if Time Machine is not configured (no tmutil needed)
    if ! defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        return 0
    fi

    start_section_spinner "Checking Time Machine status..."
    local rc_running=0
    tm_is_running || rc_running=$?

    if [[ $rc_running -ge 128 ]]; then
        stop_section_spinner
        return "$rc_running"
    fi

    if [[ $rc_running -eq 2 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Snapshot check · skipped (Time Machine status unknown)"
        note_activity
        return 0
    fi

    if [[ $rc_running -eq 0 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Snapshot check · skipped (backup in progress)"
        note_activity
        return 0
    fi

    start_section_spinner "Checking local snapshots..."
    local snapshot_list=""
    local snapshot_rc=0
    snapshot_list=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" \
        tmutil listlocalsnapshots / 2> /dev/null) || snapshot_rc=$?
    stop_section_spinner
    [[ $snapshot_rc -ge 128 ]] && return "$snapshot_rc"
    [[ $snapshot_rc -eq 0 ]] || return 0
    [[ -z "$snapshot_list" ]] && return 0

    local snapshot_count
    snapshot_count=$(echo "$snapshot_list" | { grep -Eo 'com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true; } | wc -l | awk '{print $1}')
    if [[ "$snapshot_count" =~ ^[0-9]+$ && "$snapshot_count" -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_REVIEW}${NC} Time Machine local snapshots · ${GREEN}${snapshot_count}${NC} ${GRAY}(review: tmutil listlocalsnapshots /)${NC}"
        note_activity
    fi
}
