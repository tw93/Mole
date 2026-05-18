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
    recent_file=$(command find "$cache_dir" -type f -mtime "-$age_days" -print -quit 2> /dev/null) || return 1
    [[ -z "$recent_file" ]]
}

dirs_cleaner_warn_threshold_kb() {
    local warn_mb="${MOLE_DIRS_CLEANER_WARN_MB:-1024}"
    [[ "$warn_mb" =~ ^[0-9]+$ ]] || warn_mb=1024
    echo $((warn_mb * 1024))
}

dirs_cleaner_age_threshold_days() {
    local age_days="${MOLE_DIRS_CLEANER_AGE_DAYS:-3}"
    [[ "$age_days" =~ ^[0-9]+$ ]] || age_days=3
    echo "$age_days"
}

sudo_path_size_kb_xdev() {
    local path="$1"
    local size_kb=""

    size_kb=$(run_with_timeout 5 sudo du -skxP "$path" 2> /dev/null | awk 'NR==1 {print $1; exit}' || true)
    if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
        echo "$size_kb"
    else
        echo "0"
    fi
}

sudo_path_metadata() {
    local path="$1"
    local stat_out=""
    local owner=""
    local mode=""
    local flags=""
    local mtime=""

    stat_out=$(sudo stat -f '%Su|%Sp|%Sf|%m' "$path" 2> /dev/null || true)
    IFS='|' read -r owner mode flags mtime <<< "$stat_out"

    [[ -n "$owner" ]] || owner="unknown"
    [[ -n "$mode" ]] || mode="unknown"
    [[ -n "$flags" ]] || flags="unknown"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="0"

    printf '%s|%s|%s|%s\n' "$owner" "$mode" "$flags" "$mtime"
}

sudo_path_device_id() {
    local path="$1"
    local device_id=""

    device_id=$(sudo stat -f '%d' "$path" 2> /dev/null || true)
    if [[ "$device_id" =~ ^[0-9]+$ ]]; then
        echo "$device_id"
    else
        echo ""
    fi
}

sudo_shallow_oldest_mtime() {
    local path="$1"
    local fallback_mtime="${2:-0}"
    local oldest_mtime=""

    oldest_mtime=$(run_with_timeout 5 sudo find "$path" -xdev -mindepth 0 -maxdepth 2 ! -type l -exec stat -f '%m' {} + 2> /dev/null |
        awk 'BEGIN {min=""} /^[0-9]+$/ {if (min == "" || $1 < min) min = $1} END {print min}' || true)

    if [[ "$oldest_mtime" =~ ^[0-9]+$ ]]; then
        echo "$oldest_mtime"
    elif [[ "$fallback_mtime" =~ ^[0-9]+$ ]]; then
        echo "$fallback_mtime"
    else
        echo "0"
    fi
}

sudo_shallow_newest_mtime() {
    local path="$1"
    local fallback_mtime="${2:-0}"
    local newest_mtime=""

    newest_mtime=$(run_with_timeout 5 sudo find "$path" -xdev -mindepth 0 -maxdepth 2 ! -type l -exec stat -f '%m' {} + 2> /dev/null |
        awk 'BEGIN {max=""} /^[0-9]+$/ {if (max == "" || $1 > max) max = $1} END {print max}' || true)

    if [[ "$newest_mtime" =~ ^[0-9]+$ ]]; then
        echo "$newest_mtime"
    elif [[ "$fallback_mtime" =~ ^[0-9]+$ ]]; then
        echo "$fallback_mtime"
    else
        echo "0"
    fi
}

sudo_path_newest_mtime_xdev() {
    local path="$1"
    local fallback_mtime="${2:-0}"
    local newest_mtime=""

    newest_mtime=$(run_with_timeout 20 sudo find "$path" -xdev ! -type l -exec stat -f '%m' {} + 2> /dev/null |
        awk 'BEGIN {max=""} /^[0-9]+$/ {if (max == "" || $1 > max) max = $1} END {print max}') || return 1

    if [[ "$newest_mtime" =~ ^[0-9]+$ ]]; then
        echo "$newest_mtime"
    elif [[ "$fallback_mtime" =~ ^[0-9]+$ ]]; then
        echo "$fallback_mtime"
    else
        return 1
    fi
}

format_dirs_cleaner_age() {
    local mtime="${1:-0}"
    local now

    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    if [[ "$mtime" -le 0 ]]; then
        echo "unknown"
        return 0
    fi

    now=$(get_epoch_seconds)
    if [[ "$now" -le "$mtime" ]]; then
        echo "today"
        return 0
    fi

    format_duration_human "$((now - mtime))"
}

dirs_cleaner_child_has_nested_mount() {
    local child="${1%/}"
    local line
    local mount_point

    while IFS= read -r line; do
        mount_point="${line#* on }"
        mount_point="${mount_point% (*}"
        case "$mount_point" in
            "$child"/*)
                return 0
                ;;
        esac
    done < <(mount 2> /dev/null || true)

    return 1
}

dirs_cleaner_candidate_depth() {
    local root="$1"
    local path="$2"
    local rel="${path#"$root"/}"

    if [[ -z "$rel" || "$rel" == "$path" ]]; then
        echo "0"
    elif [[ "$rel" == */*/* ]]; then
        echo "3"
    elif [[ "$rel" == */* ]]; then
        echo "2"
    else
        echo "1"
    fi
}

dirs_cleaner_has_immediate_children() {
    local path="$1"
    local first_child=""

    first_child=$(run_with_timeout 5 sudo find "$path" -xdev -mindepth 1 -maxdepth 1 ! -type l -print -quit 2> /dev/null) || return 2
    [[ -n "$first_child" ]]
}

dirs_cleaner_child_is_safe() {
    local root="$1"
    local root_device="$2"
    local child="$3"
    local context="${4:-dirs_cleaner}"
    local max_depth="${5:-1}"

    case "$child" in
        "$root"/*) ;;
        *)
            debug_log "Skipping dirs_cleaner child outside root: $child"
            return 1
            ;;
    esac

    local child_depth
    child_depth=$(dirs_cleaner_candidate_depth "$root" "$child")
    if [[ "$child_depth" -eq 0 || "$child_depth" -gt "$max_depth" ]]; then
        debug_log "Skipping non-top-level dirs_cleaner target: $child"
        return 1
    fi

    if [[ "$child" =~ [[:cntrl:]] ]]; then
        debug_log "Skipping dirs_cleaner child with control characters"
        return 1
    fi

    if sudo test -L "$child" 2> /dev/null; then
        debug_log "Skipping symlinked dirs_cleaner child: $child"
        return 1
    fi

    local child_device
    child_device=$(sudo_path_device_id "$child")
    if [[ -n "$root_device" && -n "$child_device" && "$child_device" != "$root_device" ]]; then
        debug_log "Skipping dirs_cleaner child on different filesystem: $child"
        log_operation "clean" "SKIPPED" "$child" "$context different filesystem"
        return 1
    fi

    if dirs_cleaner_child_has_nested_mount "$child"; then
        debug_log "Skipping dirs_cleaner child with nested mountpoint: $child"
        log_operation "clean" "SKIPPED" "$child" "$context nested mountpoint"
        return 1
    fi

    if should_protect_path "$child"; then
        debug_log "Skipping protected dirs_cleaner child: $child"
        return 1
    fi
    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$child"; then
        debug_log "Skipping whitelisted dirs_cleaner child: $child"
        return 1
    fi

    return 0
}

report_stuck_dirs_cleaner_staging() {
    local root="/private/var/dirs_cleaner"
    local warn_kb
    local age_threshold_days
    local now
    local entries_file
    local errors_file
    local root_device
    local reported=0

    if ! sudo test -d "$root" 2> /dev/null; then
        return 0
    fi

    if sudo test -L "$root" 2> /dev/null; then
        stop_section_spinner
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} macOS cleanup staging audit skipped: symlinked path"
        echo -e "    ${GRAY}${root}${NC}"
        note_activity
        log_operation "clean" "SKIPPED" "$root" "dirs_cleaner audit symlinked root"
        return 0
    fi

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$root"; then
        debug_log "Skipping dirs_cleaner audit: whitelisted root"
        return 0
    fi

    warn_kb=$(dirs_cleaner_warn_threshold_kb)
    age_threshold_days=$(dirs_cleaner_age_threshold_days)
    now=$(get_epoch_seconds)
    root_device=$(sudo_path_device_id "$root")
    entries_file=$(mktemp_file "dirs_cleaner_entries")
    errors_file=$(mktemp_file "dirs_cleaner_errors")

    if ! run_with_timeout 8 sudo find "$root" -xdev -mindepth 1 -maxdepth 1 ! -type l -print0 > "$entries_file" 2> "$errors_file"; then
        stop_section_spinner
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Could not fully inspect macOS cleanup staging"
        echo -e "    ${GRAY}${root}${NC}"
        echo -e "    ${GRAY}Review: sudo du -xhd 2 ${root}${NC}"
        note_activity
        log_operation "clean" "FAILED" "$root" "dirs_cleaner audit traversal failed"
        return 0
    fi

    if [[ ! -s "$entries_file" ]]; then
        return 0
    fi

    while IFS= read -r -d '' child; do
        [[ -n "$child" ]] || continue
        if ! dirs_cleaner_child_is_safe "$root" "$root_device" "$child" "dirs_cleaner audit"; then
            continue
        fi

        local size_kb
        local metadata
        local owner
        local mode
        local flags
        local mtime
        local oldest_mtime
        local age_days=0
        local age_human
        local size_human
        local metadata_suffix=""

        size_kb=$(sudo_path_size_kb_xdev "$child")
        metadata=$(sudo_path_metadata "$child")
        IFS='|' read -r owner mode flags mtime <<< "$metadata"
        oldest_mtime=$(sudo_shallow_oldest_mtime "$child" "$mtime")
        if [[ "$oldest_mtime" =~ ^[0-9]+$ && "$oldest_mtime" -gt 0 && "$now" -gt "$oldest_mtime" ]]; then
            age_days=$(((now - oldest_mtime) / 86400))
        fi

        if [[ "$size_kb" -lt "$warn_kb" && "$age_days" -lt "$age_threshold_days" ]]; then
            continue
        fi

        if [[ $reported -eq 0 ]]; then
            stop_section_spinner
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Stuck macOS cleanup staging detected"
            echo -e "    ${GRAY}Review: sudo du -xhd 2 ${root}${NC}"
            echo -e "    ${GRAY}Review open handles: sudo lsof +D ${root}${NC}"
            echo -e "    ${GRAY}Clean stale staging: mo clean --dirs-cleaner --dry-run${NC}"
            reported=1
            note_activity
        fi

        size_human=$(bytes_to_human "$((size_kb * 1024))")
        age_human=$(format_dirs_cleaner_age "$oldest_mtime")
        if [[ -n "$flags" && "$flags" != "none" && "$flags" != "-" && "$flags" != "unknown" ]]; then
            metadata_suffix=", flags $flags"
        fi

        echo -e "    ${GRAY}${child}${NC} · $(colorize_human_size "$size_human"), oldest ${age_human}, owner ${owner}, ${mode}${metadata_suffix}"
        log_operation "clean" "WARNING" "$child" "dirs_cleaner staging ${size_human}, oldest ${age_human}, owner ${owner}"
    done < "$entries_file"

    return 0
}

clean_dirs_cleaner_staging() {
    local root="/private/var/dirs_cleaner"
    local age_threshold_days
    local now
    local entries_file
    local errors_file
    local root_device
    local cleaned_count=0
    local eligible_count=0
    local failed_count=0
    local total_size_kb=0

    if ! sudo test -d "$root" 2> /dev/null; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No macOS cleanup staging found"
        return 0
    fi

    if sudo test -L "$root" 2> /dev/null; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} macOS cleanup staging cleanup skipped: symlinked path"
        echo -e "    ${GRAY}${root}${NC}"
        log_operation "clean" "SKIPPED" "$root" "dirs_cleaner cleanup symlinked root"
        return 0
    fi

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$root"; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} macOS cleanup staging is whitelisted"
        debug_log "Skipping dirs_cleaner cleanup: whitelisted root"
        return 0
    fi

    age_threshold_days=$(dirs_cleaner_age_threshold_days)
    now=$(get_epoch_seconds)
    root_device=$(sudo_path_device_id "$root")
    entries_file=$(mktemp_file "dirs_cleaner_cleanup_entries")
    errors_file=$(mktemp_file "dirs_cleaner_cleanup_errors")

    if ! run_with_timeout 8 sudo find "$root" -xdev -mindepth 1 -maxdepth 2 ! -type l -print0 > "$entries_file" 2> "$errors_file"; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Could not fully inspect macOS cleanup staging"
        echo -e "    ${GRAY}${root}${NC}"
        echo -e "    ${GRAY}Review: sudo du -xhd 2 ${root}${NC}"
        log_operation "clean" "FAILED" "$root" "dirs_cleaner cleanup traversal failed"
        return 1
    fi

    if [[ ! -s "$entries_file" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No macOS cleanup staging entries found"
        return 0
    fi

    while IFS= read -r -d '' child; do
        [[ -n "$child" ]] || continue
        if ! dirs_cleaner_child_is_safe "$root" "$root_device" "$child" "dirs_cleaner cleanup" 2; then
            continue
        fi

        local child_depth
        child_depth=$(dirs_cleaner_candidate_depth "$root" "$child")
        if [[ "$child_depth" -eq 1 ]] && sudo test -d "$child" 2> /dev/null; then
            dirs_cleaner_has_immediate_children "$child"
            local has_children_rc=$?
            if [[ $has_children_rc -eq 0 ]]; then
                debug_log "Skipping non-empty top-level dirs_cleaner bucket; checking shallow children: $child"
                continue
            elif [[ $has_children_rc -ne 1 ]]; then
                debug_log "Skipping dirs_cleaner bucket after child scan failure: $child"
                log_operation "clean" "SKIPPED" "$child" "dirs_cleaner cleanup child scan failed"
                continue
            fi
        fi

        local size_kb
        local metadata
        local owner
        local mode
        local flags
        local mtime
        local newest_full_mtime
        local age_days=0
        local age_human
        local size_human
        local metadata_suffix=""

        size_kb=$(sudo_path_size_kb_xdev "$child")
        metadata=$(sudo_path_metadata "$child")
        IFS='|' read -r owner mode flags mtime <<< "$metadata"
        newest_full_mtime=$(sudo_path_newest_mtime_xdev "$child" "$mtime") || {
            debug_log "Skipping dirs_cleaner candidate after full staleness scan failure: $child"
            log_operation "clean" "SKIPPED" "$child" "dirs_cleaner cleanup staleness scan failed"
            continue
        }
        if [[ "$newest_full_mtime" =~ ^[0-9]+$ && "$newest_full_mtime" -gt 0 && "$now" -gt "$newest_full_mtime" ]]; then
            age_days=$(((now - newest_full_mtime) / 86400))
        fi

        if [[ "$age_days" -lt "$age_threshold_days" ]]; then
            continue
        fi

        eligible_count=$((eligible_count + 1))
        total_size_kb=$((total_size_kb + size_kb))
        size_human=$(bytes_to_human "$((size_kb * 1024))")
        age_human=$(format_dirs_cleaner_age "$newest_full_mtime")
        if [[ -n "$flags" && "$flags" != "none" && "$flags" != "-" && "$flags" != "unknown" ]]; then
            metadata_suffix=", flags $flags"
        fi

        if [[ "${DRY_RUN:-false}" == "true" || "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} ${child}${NC}, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
            echo -e "    ${GRAY}newest ${age_human}, owner ${owner}, ${mode}${metadata_suffix}${NC}"
        else
            echo -e "  ${GRAY}${ICON_LIST}${NC} Removing stale cleanup staging: ${child}${NC}"
            echo -e "    ${GRAY}${size_human}, newest ${age_human}, owner ${owner}, ${mode}${metadata_suffix}${NC}"
        fi

        if safe_sudo_remove "$child" "dirs_cleaner"; then
            cleaned_count=$((cleaned_count + 1))
            note_activity
            if [[ "${DRY_RUN:-false}" == "true" || "${MOLE_DRY_RUN:-0}" == "1" ]]; then
                log_operation "clean" "DRY_RUN" "$child" "dirs_cleaner staging ${size_human}, newest ${age_human}, owner ${owner}"
            else
                log_operation "clean" "REMOVED" "$child" "dirs_cleaner staging ${size_human}, newest ${age_human}, owner ${owner}"
            fi
        else
            failed_count=$((failed_count + 1))
            log_operation "clean" "FAILED" "$child" "dirs_cleaner cleanup remove failed"
        fi
    done < "$entries_file"

    if [[ $eligible_count -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No stale macOS cleanup staging found"
        echo -e "    ${GRAY}Threshold: ${age_threshold_days}d; adjust with MOLE_DIRS_CLEANER_AGE_DAYS${NC}"
        return 0
    fi

    local total_size_human
    total_size_human=$(bytes_to_human "$((total_size_kb * 1024))")
    if [[ "${DRY_RUN:-false}" == "true" || "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Stale macOS cleanup staging, ${eligible_count} items, $(colorize_human_size "$total_size_human") ${YELLOW}dry${NC}"
    elif [[ $failed_count -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} macOS cleanup staging partially cleaned: ${cleaned_count}/${eligible_count} items"
        echo -e "    ${GRAY}Review: sudo du -xhd 2 ${root}${NC}"
        return 1
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} macOS cleanup staging, ${cleaned_count} items, $(colorize_human_size "$total_size_human")"
    fi

    return 0
}

# System caches, logs, and temp files.
clean_deep_system() {
    stop_section_spinner
    local cache_cleaned=0
    start_section_spinner "Cleaning system caches..."
    # Optimized: Single pass for /Library/Caches (3 patterns in 1 scan)
    if sudo test -d "/Library/Caches" 2> /dev/null; then
        while IFS= read -r -d '' file; do
            if should_protect_path "$file"; then
                continue
            fi
            if safe_sudo_remove "$file"; then
                cache_cleaned=1
            fi
        done < <(sudo find "/Library/Caches" -maxdepth 5 -type f \( \
            \( -name "*.cache" -mtime "+$MOLE_TEMP_FILE_AGE_DAYS" \) -o \
            \( -name "*.tmp" -mtime "+$MOLE_TEMP_FILE_AGE_DAYS" \) -o \
            \( -name "*.log" -mtime "+$MOLE_LOG_AGE_DAYS" \) \
            \) -print0 2> /dev/null || true)
    fi
    stop_section_spinner
    [[ $cache_cleaned -eq 1 ]] && log_success "System caches"
    start_section_spinner "Cleaning system temporary files..."
    local tmp_cleaned=0
    local -a sys_temp_dirs=("/private/tmp" "/private/var/tmp")
    for tmp_dir in "${sys_temp_dirs[@]}"; do
        if sudo find "$tmp_dir" -maxdepth 1 -type f -mtime "+${MOLE_TEMP_FILE_AGE_DAYS}" -print -quit 2> /dev/null | grep -q .; then
            if safe_sudo_find_delete "$tmp_dir" "*" "${MOLE_TEMP_FILE_AGE_DAYS}" "f"; then
                tmp_cleaned=1
            fi
        fi
    done
    stop_section_spinner
    [[ $tmp_cleaned -eq 1 ]] && log_success "System temp files"
    start_section_spinner "Cleaning system crash reports..."
    if sudo find "/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -mtime "+$MOLE_CRASH_REPORT_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*" "$MOLE_CRASH_REPORT_AGE_DAYS" "f" || true
    fi
    stop_section_spinner
    log_success "System crash reports"
    start_section_spinner "Cleaning system logs..."
    if sudo find "/private/var/log" -maxdepth 3 -type f \( -name "*.log" -o -name "*.gz" -o -name "*.asl" \) -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        safe_sudo_find_delete "/private/var/log" "*.log" "$MOLE_LOG_AGE_DAYS" "f" || true
        safe_sudo_find_delete "/private/var/log" "*.gz" "$MOLE_LOG_AGE_DAYS" "f" || true
        safe_sudo_find_delete "/private/var/log" "*.asl" "$MOLE_LOG_AGE_DAYS" "f" || true
    fi
    stop_section_spinner
    log_success "System logs"
    start_section_spinner "Cleaning third-party system logs..."
    local -a third_party_log_dirs=(
        "/Library/Logs/Adobe"
        "/Library/Logs/CreativeCloud"
    )
    local third_party_logs_cleaned=0
    local third_party_log_dir=""
    for third_party_log_dir in "${third_party_log_dirs[@]}"; do
        if sudo test -d "$third_party_log_dir" 2> /dev/null; then
            if sudo find "$third_party_log_dir" -maxdepth 5 -type f -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
                if safe_sudo_find_delete "$third_party_log_dir" "*" "$MOLE_LOG_AGE_DAYS" "f"; then
                    third_party_logs_cleaned=1
                fi
            fi
        fi
    done
    if sudo find "/Library/Logs" -maxdepth 1 -type f -name "adobegc.log" -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        if safe_sudo_remove "/Library/Logs/adobegc.log"; then
            third_party_logs_cleaned=1
        fi
    fi
    stop_section_spinner
    [[ $third_party_logs_cleaned -eq 1 ]] && log_success "Third-party system logs"
    start_section_spinner "Scanning system library updates..."
    if [[ -d "/Library/Updates" && ! -L "/Library/Updates" ]]; then
        local updates_cleaned=0
        while IFS= read -r -d '' item; do
            if [[ -z "$item" ]] || [[ ! "$item" =~ ^/Library/Updates/[^/]+$ ]]; then
                debug_log "Skipping malformed path: $item"
                continue
            fi
            local item_flags
            item_flags=$($STAT_BSD -f%Sf "$item" 2> /dev/null || echo "")
            if [[ "$item_flags" == *"restricted"* ]]; then
                continue
            fi
            if safe_sudo_remove "$item"; then
                updates_cleaned=$((updates_cleaned + 1))
            fi
        done < <(find /Library/Updates -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        stop_section_spinner
        [[ $updates_cleaned -gt 0 ]] && log_success "System library updates"
    else
        stop_section_spinner
    fi
    start_section_spinner "Scanning macOS installer files..."
    if [[ -d "/macOS Install Data" ]]; then
        local mtime
        mtime=$(get_file_mtime "/macOS Install Data")
        local age_days=$((($(get_epoch_seconds) - mtime) / 86400))
        debug_log "Found macOS Install Data, age ${age_days} days"
        if [[ $age_days -ge 14 ]]; then
            local size_kb
            size_kb=$(get_path_size_kb "/macOS Install Data")
            if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
                local size_human
                size_human=$(bytes_to_human "$((size_kb * 1024))")
                debug_log "Cleaning macOS Install Data: $size_human, ${age_days} days old"
                if safe_sudo_remove "/macOS Install Data"; then
                    log_success "macOS Install Data, $size_human"
                fi
            fi
        else
            debug_log "Keeping macOS Install Data, only ${age_days} days old, needs 14+"
        fi
    fi
    # Clean macOS installer apps (e.g., "Install macOS Sequoia.app")
    # Only remove installers older than 14 days, not currently running,
    # and not matching the currently installed macOS version (recovery safety).
    local installer_cleaned=0
    local current_macos_version=""
    current_macos_version=$(sw_vers -productVersion 2> /dev/null | cut -d. -f1 || true)
    for installer_app in /Applications/Install\ macOS*.app; do
        [[ -d "$installer_app" ]] || continue
        local app_name
        app_name=$(basename "$installer_app")
        # Skip if installer is currently running
        if pgrep -f "$installer_app" > /dev/null 2>&1; then
            debug_log "Skipping $app_name: currently running"
            continue
        fi
        # Skip if this installer matches the current macOS major version.
        # Users may need it for recovery or reinstallation.
        if [[ -n "$current_macos_version" ]]; then
            local installer_plist="$installer_app/Contents/Info.plist"
            if [[ -f "$installer_plist" ]]; then
                local installer_version=""
                installer_version=$(/usr/libexec/PlistBuddy -c "Print :DTPlatformVersion" "$installer_plist" 2> /dev/null | cut -d. -f1 || true)
                if [[ -n "$installer_version" && "$installer_version" == *"$current_macos_version"* ]]; then
                    debug_log "Keeping $app_name: matches current macOS version ($current_macos_version)"
                    continue
                fi
            fi
        fi
        # Check age (same 14-day threshold as /macOS Install Data)
        local mtime
        mtime=$(get_file_mtime "$installer_app")
        local age_days=$((($(get_epoch_seconds) - mtime) / 86400))
        if [[ $age_days -lt 14 ]]; then
            debug_log "Keeping $app_name: only ${age_days} days old, needs 14+"
            continue
        fi
        local size_kb
        size_kb=$(get_path_size_kb "$installer_app")
        if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
            local size_human
            size_human=$(bytes_to_human "$((size_kb * 1024))")
            debug_log "Cleaning macOS installer: $app_name, $size_human, ${age_days} days old"
            if safe_sudo_remove "$installer_app"; then
                log_success "$app_name, $size_human"
                installer_cleaned=$((installer_cleaned + 1))
            fi
        fi
    done
    stop_section_spinner
    [[ $installer_cleaned -gt 0 ]] && debug_log "Cleaned $installer_cleaned macOS installer(s)"
    start_section_spinner "Scanning browser code signature caches..."
    local code_sign_cleaned=0
    while IFS= read -r -d '' cache_dir; do
        if safe_sudo_remove "$cache_dir"; then
            code_sign_cleaned=$((code_sign_cleaned + 1))
        fi
    done < <(run_with_timeout 5 command find /private/var/folders -maxdepth 5 -type d -name "*.code_sign_clone" -path "*/X/*" -print0 2> /dev/null || true)
    stop_section_spinner
    [[ $code_sign_cleaned -gt 0 ]] && log_success "Browser code signature caches, $code_sign_cleaned items"

    start_section_spinner "Cleaning rebuildable system service caches..."
    local rebuildable_cache_cleaned=0
    local -a rebuildable_cache_dirs=(
        "/Library/Caches/com.apple.iconservices.store"
    )
    local rebuildable_cache_dir=""
    for rebuildable_cache_dir in "${rebuildable_cache_dirs[@]}"; do
        if sudo test -e "$rebuildable_cache_dir" 2> /dev/null; then
            if safe_sudo_remove "$rebuildable_cache_dir"; then
                rebuildable_cache_cleaned=$((rebuildable_cache_cleaned + 1))
            fi
        fi
    done
    stop_section_spinner
    if [[ $rebuildable_cache_cleaned -gt 0 ]]; then
        local rebuildable_cache_label="items"
        [[ $rebuildable_cache_cleaned -eq 1 ]] && rebuildable_cache_label="item"
        log_success "Rebuildable system caches, $rebuildable_cache_cleaned $rebuildable_cache_label"
    fi

    start_section_spinner "Scanning accessible rebuildable GPU caches..."
    local gpu_cache_cleaned=0
    local gpu_cache_dir=""
    while IFS= read -r -d '' gpu_cache_dir; do
        is_rebuildable_gpu_cache_dir "$gpu_cache_dir" || continue
        gpu_cache_dir_is_stale "$gpu_cache_dir" "$MOLE_GPU_CACHE_AGE_DAYS" || continue
        if safe_sudo_remove "$gpu_cache_dir"; then
            gpu_cache_cleaned=$((gpu_cache_cleaned + 1))
        fi
    done < <(run_with_timeout 8 command find /private/var/folders -maxdepth 8 -type d \( \
        -name "com.apple.gpuarchiver" -o \
        -name "com.apple.metal" -o \
        -name "com.apple.metalfe" \
        \) -path "*/C/*" -print0 2> /dev/null || true)
    stop_section_spinner
    if [[ $gpu_cache_cleaned -gt 0 ]]; then
        local gpu_cache_label="items"
        [[ $gpu_cache_cleaned -eq 1 ]] && gpu_cache_label="item"
        log_success "Accessible rebuildable GPU caches, $gpu_cache_cleaned $gpu_cache_label"
    fi

    start_section_spinner "Auditing macOS cleanup staging..."
    report_stuck_dirs_cleaner_staging
    stop_section_spinner

    local diag_base="/private/var/db/diagnostics"
    start_section_spinner "Cleaning system diagnostic logs..."
    safe_sudo_find_delete "$diag_base" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    safe_sudo_find_delete "$diag_base" "*.tracev3" "30" "f" || true
    safe_sudo_find_delete "/private/var/db/DiagnosticPipeline" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    stop_section_spinner
    log_success "System diagnostic logs"

    start_section_spinner "Cleaning power logs..."
    safe_sudo_find_delete "/private/var/db/powerlog" "*" "$MOLE_LOG_AGE_DAYS" "f" || true
    stop_section_spinner
    log_success "Power logs"
    start_section_spinner "Cleaning memory exception reports..."
    local mem_reports_dir="/private/var/db/reportmemoryexception/MemoryLimitViolations"
    local mem_cleaned=0
    if sudo test -d "$mem_reports_dir" 2> /dev/null; then
        # Count and size old files before deletion
        local file_count=0
        local total_size_kb=0
        local total_bytes=0
        local stats_out
        stats_out=$(sudo find "$mem_reports_dir" -type f -mtime +30 -exec stat -f "%z" {} + 2> /dev/null | awk '{c++; s+=$1} END {print c+0, s+0}' || true)
        if [[ -n "$stats_out" ]]; then
            read -r file_count total_bytes <<< "$stats_out"
            total_size_kb=$((total_bytes / 1024))
        fi

        if [[ "$file_count" -gt 0 ]]; then
            if [[ "${DRY_RUN:-}" != "true" ]]; then
                if safe_sudo_find_delete "$mem_reports_dir" "*" "30" "f"; then
                    mem_cleaned=1
                fi
                # Log summary to operations.log
                if [[ $mem_cleaned -eq 1 ]] && oplog_enabled && [[ "$total_size_kb" -gt 0 ]]; then
                    local size_human
                    size_human=$(bytes_to_human "$((total_size_kb * 1024))")
                    log_operation "clean" "REMOVED" "$mem_reports_dir" "$file_count files, $size_human"
                fi
            else
                log_info "[DRY-RUN] Would remove $file_count old memory exception reports ($total_size_kb KB)"
            fi
        fi
    fi
    stop_section_spinner
    if [[ $mem_cleaned -eq 1 ]]; then
        log_success "Memory exception reports"
    fi
    return 0
}
# Incomplete Time Machine backups.
clean_time_machine_failed_backups() {
    local tm_cleaned=0
    if ! command -v tmutil > /dev/null 2>&1; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    # Fast pre-check: skip entirely if Time Machine is not configured (no tmutil needed)
    if ! defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2> /dev/null | grep -qE '^[01]$'; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    start_section_spinner "Checking Time Machine configuration..."
    local spinner_active=true
    local tm_info
    tm_info=$(run_with_timeout 2 tmutil destinationinfo 2>&1 || echo "failed")
    if [[ "$tm_info" == *"No destinations configured"* || "$tm_info" == "failed" ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if [[ ! -d "/Volumes" ]]; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if tm_is_running; then
        if [[ "$spinner_active" == "true" ]]; then
            stop_section_spinner
        fi
        echo -e "  ${YELLOW}!${NC} Time Machine backup in progress, skipping cleanup"
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
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
        return 0
    fi
    if [[ "$spinner_active" == "true" ]]; then
        start_section_spinner "Scanning backup volumes..."
    fi
    for volume in "${backup_volumes[@]}"; do
        local fs_type
        fs_type=$(run_with_timeout 1 command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}' || echo "unknown")
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav | unknown) continue ;;
        esac
        local backupdb_dir="$volume/Backups.backupdb"
        if [[ -d "$backupdb_dir" ]]; then
            while IFS= read -r inprogress_file; do
                [[ -d "$inprogress_file" ]] || continue
                # Only delete old incomplete backups (safety window).
                local file_mtime
                file_mtime=$(get_file_mtime "$inprogress_file")
                local current_time
                current_time=$(get_epoch_seconds)
                local hours_old=$(((current_time - file_mtime) / 3600))
                if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                    continue
                fi
                local size_kb
                size_kb=$(get_path_size_kb "$inprogress_file")
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
                    echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete backup: $backup_name${NC}, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    note_activity
                    continue
                fi
                if ! command -v tmutil > /dev/null 2>&1; then
                    echo -e "  ${YELLOW}!${NC} tmutil not available, skipping: $backup_name"
                    continue
                fi
                if tmutil delete "$inprogress_file" 2> /dev/null; then
                    local line_color
                    line_color=$(cleanup_result_color_kb "$size_kb")
                    echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete backup: $backup_name${NC}, ${line_color}$size_human${NC}"
                    tm_cleaned=$((tm_cleaned + 1))
                    files_cleaned=$((files_cleaned + 1))
                    total_size_cleaned=$((total_size_cleaned + size_kb))
                    total_items=$((total_items + 1))
                    note_activity
                else
                    echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name · try manually with sudo"
                fi
            done < <(run_with_timeout 15 find "$backupdb_dir" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
        fi
        # APFS bundles.
        for bundle in "$volume"/*.backupbundle "$volume"/*.sparsebundle; do
            [[ -e "$bundle" ]] || continue
            [[ -d "$bundle" ]] || continue
            local bundle_name
            bundle_name=$(basename "$bundle")
            local mounted_path
            mounted_path=$(hdiutil info 2> /dev/null | grep -A 5 "image-path.*$bundle_name" | grep "/Volumes/" | awk '{print $1}' | head -1 || echo "")
            if [[ -n "$mounted_path" && -d "$mounted_path" ]]; then
                while IFS= read -r inprogress_file; do
                    [[ -d "$inprogress_file" ]] || continue
                    local file_mtime
                    file_mtime=$(get_file_mtime "$inprogress_file")
                    local current_time
                    current_time=$(get_epoch_seconds)
                    local hours_old=$(((current_time - file_mtime) / 3600))
                    if [[ $hours_old -lt $MOLE_TM_BACKUP_SAFE_HOURS ]]; then
                        continue
                    fi
                    local size_kb
                    size_kb=$(get_path_size_kb "$inprogress_file")
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
                        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC}, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        note_activity
                        continue
                    fi
                    if ! command -v tmutil > /dev/null 2>&1; then
                        continue
                    fi
                    if tmutil delete "$inprogress_file" 2> /dev/null; then
                        local line_color
                        line_color=$(cleanup_result_color_kb "$size_kb")
                        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Incomplete APFS backup in $bundle_name: $backup_name${NC}, ${line_color}$size_human${NC}"
                        tm_cleaned=$((tm_cleaned + 1))
                        files_cleaned=$((files_cleaned + 1))
                        total_size_cleaned=$((total_size_cleaned + size_kb))
                        total_items=$((total_items + 1))
                        note_activity
                    else
                        echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                    fi
                done < <(run_with_timeout 15 find "$mounted_path" -maxdepth 3 -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
            fi
        done
    done
    if [[ "$spinner_active" == "true" ]]; then
        stop_section_spinner
    fi
    if [[ $tm_cleaned -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No incomplete backups found"
    fi
}
# Returns 0 if a backup is actively running.
# Returns 1 if not running.
# Returns 2 if status cannot be determined
tm_is_running() {
    local st
    st="$(tmutil status 2> /dev/null)" || return 2

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

    if [[ $rc_running -eq 2 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Could not determine Time Machine status; skipping snapshot check"
        return 0
    fi

    if [[ $rc_running -eq 0 ]]; then
        stop_section_spinner
        echo -e "  ${YELLOW}!${NC} Time Machine is active; skipping snapshot check"
        return 0
    fi

    start_section_spinner "Checking local snapshots..."
    local snapshot_list
    snapshot_list=$(run_with_timeout 3 tmutil listlocalsnapshots / 2> /dev/null || true)
    stop_section_spinner
    [[ -z "$snapshot_list" ]] && return 0

    local snapshot_count
    snapshot_count=$(echo "$snapshot_list" | { grep -Eo 'com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true; } | wc -l | awk '{print $1}')
    if [[ "$snapshot_count" =~ ^[0-9]+$ && "$snapshot_count" -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Time Machine local snapshots: ${GREEN}${snapshot_count}${NC}"
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${GRAY}Review: tmutil listlocalsnapshots /${NC}"
        note_activity
    fi
}
