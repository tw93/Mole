#!/bin/bash
# Mole - Optimize command.
# Runs system maintenance checks and fixes.
# Supports dry-run where applicable.

set -euo pipefail

# Fix locale issues.
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"

# Clean temp files on exit.
trap cleanup_temp_files EXIT INT TERM
source "$SCRIPT_DIR/lib/core/sudo.sh"
source "$SCRIPT_DIR/lib/manage/update.sh"
source "$SCRIPT_DIR/lib/manage/autofix.sh"
source "$SCRIPT_DIR/lib/optimize/maintenance.sh"
source "$SCRIPT_DIR/lib/optimize/tasks.sh"
source "$SCRIPT_DIR/lib/check/health_json.sh"
source "$SCRIPT_DIR/lib/check/all.sh"
source "$SCRIPT_DIR/lib/check/dev_environment.sh"
source "$SCRIPT_DIR/lib/manage/whitelist.sh"

print_header() {
    printf '\n'
    echo -e "${PURPLE_BOLD}Optimize and Check${NC}"
}

# Bash-native JSON parsing helpers (no jq dependency).
# Extract a simple numeric value from JSON by key.
json_get_value() {
    local json="$1"
    local key="$2"
    local value
    value=$(echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9.]*" | head -1 | sed 's/.*:[[:space:]]*//')
    echo "${value:-0}"
}

# Validate JSON has expected structure (basic check).
json_validate() {
    local json="$1"
    # Check for required keys
    [[ "$json" == *'"memory_used_gb"'* ]] &&
        [[ "$json" == *'"optimizations"'* ]] &&
        [[ "$json" == *'{'* ]] && [[ "$json" == *'}'* ]]
}

# Parse optimization items from JSON array.
# Outputs pipe-delimited records: action|name|description|safe
parse_optimization_items() {
    local json="$1"
    # Extract the optimizations array content
    local in_array=false
    local brace_count=0
    local current_item=""

    while IFS= read -r line; do
        # Detect start of optimizations array
        if [[ "$line" == *'"optimizations"'*'['* ]]; then
            in_array=true
            continue
        fi

        [[ "$in_array" != "true" ]] && continue

        # Strip quoted strings before counting braces to handle braces inside string values
        # e.g., "description": "Use {braces} here" should not affect brace counting
        local line_for_counting
        # shellcheck disable=SC2001
        line_for_counting=$(echo "$line" | sed 's/"[^"]*"//g')

        # Count braces to track object boundaries (using stripped line)
        if [[ "$line_for_counting" == *'{'* ]]; then
            ((brace_count++))
        fi

        if ((brace_count > 0)); then
            current_item+="$line"
        fi

        if [[ "$line_for_counting" == *'}'* ]]; then
            ((brace_count--))
            if ((brace_count == 0)) && [[ -n "$current_item" ]]; then
                # Extract fields from the collected item
                local action name desc safe
                action=$(echo "$current_item" | grep -o '"action"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"action"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
                name=$(echo "$current_item" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
                desc=$(echo "$current_item" | grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
                safe=$(echo "$current_item" | grep -o '"safe"[[:space:]]*:[[:space:]]*[a-z]*' | sed 's/.*:[[:space:]]*//')

                [[ -n "$action" ]] && echo "${action}|${name}|${desc}|${safe}"
                current_item=""
            fi
        fi

        # End of array (using stripped line)
        [[ "$line_for_counting" == *']'* ]] && ((brace_count == 0)) && break
    done <<< "$json"
}

run_system_checks() {
    # Skip checks in dry-run mode.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    unset AUTO_FIX_SUMMARY AUTO_FIX_DETAILS
    unset MOLE_SECURITY_FIXES_SHOWN
    unset MOLE_SECURITY_FIXES_SKIPPED
    echo ""

    check_all_updates
    echo ""

    check_system_health
    echo ""

    check_all_security
    if ask_for_security_fixes; then
        perform_security_fixes
    fi
    if [[ "${MOLE_SECURITY_FIXES_SKIPPED:-}" != "true" ]]; then
        echo ""
    fi

    check_all_config
    echo ""

    check_all_dev_environment

    show_suggestions

    if ask_for_updates; then
        perform_updates
    fi
    if ask_for_auto_fix; then
        perform_auto_fix
    fi
}

show_optimization_summary() {
    local safe_count="${OPTIMIZE_SAFE_COUNT:-0}"
    local confirm_count="${OPTIMIZE_CONFIRM_COUNT:-0}"
    if ((safe_count == 0 && confirm_count == 0)) && [[ -z "${AUTO_FIX_SUMMARY:-}" ]]; then
        return
    fi

    local summary_title
    local -a summary_details=()
    local total_applied=$((safe_count + confirm_count))

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        summary_title="Dry Run Complete, No Changes Made"
        summary_details+=("Would apply ${YELLOW}${total_applied:-0}${NC} optimizations")
        summary_details+=("Run without ${YELLOW}--dry-run${NC} to apply these changes")
    else
        summary_title="Optimization and Check Complete"

        # Build statistics summary
        local -a stats=()
        local cache_kb="${OPTIMIZE_CACHE_CLEANED_KB:-0}"
        local db_count="${OPTIMIZE_DATABASES_COUNT:-0}"
        local config_count="${OPTIMIZE_CONFIGS_REPAIRED:-0}"

        if [[ "$cache_kb" =~ ^[0-9]+$ ]] && [[ "$cache_kb" -gt 0 ]]; then
            local cache_human=$(bytes_to_human "$((cache_kb * 1024))")
            stats+=("${cache_human} cache cleaned")
        fi

        if [[ "$db_count" =~ ^[0-9]+$ ]] && [[ "$db_count" -gt 0 ]]; then
            stats+=("${db_count} databases optimized")
        fi

        if [[ "$config_count" =~ ^[0-9]+$ ]] && [[ "$config_count" -gt 0 ]]; then
            stats+=("${config_count} configs repaired")
        fi

        # Build first summary line with most important stat only
        local key_stat=""
        if [[ "$cache_kb" =~ ^[0-9]+$ ]] && [[ "$cache_kb" -gt 0 ]]; then
            local cache_human=$(bytes_to_human "$((cache_kb * 1024))")
            key_stat="${cache_human} cache cleaned"
        elif [[ "$db_count" =~ ^[0-9]+$ ]] && [[ "$db_count" -gt 0 ]]; then
            key_stat="${db_count} databases optimized"
        elif [[ "$config_count" =~ ^[0-9]+$ ]] && [[ "$config_count" -gt 0 ]]; then
            key_stat="${config_count} configs repaired"
        fi

        if [[ -n "$key_stat" ]]; then
            summary_details+=("Applied ${GREEN}${total_applied:-0}${NC} optimizations, ${key_stat}")
        else
            summary_details+=("Applied ${GREEN}${total_applied:-0}${NC} optimizations, all services tuned")
        fi

        local summary_line3=""
        if [[ -n "${AUTO_FIX_SUMMARY:-}" ]]; then
            summary_line3="${AUTO_FIX_SUMMARY}"
            if [[ -n "${AUTO_FIX_DETAILS:-}" ]]; then
                local detail_join
                detail_join=$(echo "${AUTO_FIX_DETAILS}" | paste -sd ", " -)
                [[ -n "$detail_join" ]] && summary_line3+=": ${detail_join}"
            fi
            summary_details+=("$summary_line3")
        fi
        summary_details+=("System fully optimized")
    fi

    print_summary_block "$summary_title" "${summary_details[@]}"
}

show_system_health() {
    local health_json="$1"

    local mem_used=$(json_get_value "$health_json" "memory_used_gb")
    local mem_total=$(json_get_value "$health_json" "memory_total_gb")
    local disk_used=$(json_get_value "$health_json" "disk_used_gb")
    local disk_total=$(json_get_value "$health_json" "disk_total_gb")
    local disk_percent=$(json_get_value "$health_json" "disk_used_percent")
    local uptime=$(json_get_value "$health_json" "uptime_days")

    mem_used=${mem_used:-0}
    mem_total=${mem_total:-0}
    disk_used=${disk_used:-0}
    disk_total=${disk_total:-0}
    disk_percent=${disk_percent:-0}
    uptime=${uptime:-0}

    printf "${ICON_ADMIN} System  %.0f/%.0f GB RAM | %.0f/%.0f GB Disk | Uptime %.0fd\n" \
        "$mem_used" "$mem_total" "$disk_used" "$disk_total" "$uptime"
}

announce_action() {
    local name="$1"
    local desc="$2"
    local kind="$3"

    if [[ "${FIRST_ACTION:-true}" == "true" ]]; then
        export FIRST_ACTION=false
    else
        echo ""
    fi
    echo -e "${BLUE}${ICON_ARROW} ${name}${NC}"
}

touchid_configured() {
    local pam_file="/etc/pam.d/sudo"
    [[ -f "$pam_file" ]] && grep -q "pam_tid.so" "$pam_file" 2> /dev/null
}

touchid_supported() {
    if command -v bioutil > /dev/null 2>&1; then
        if bioutil -r 2> /dev/null | grep -qi "Touch ID"; then
            return 0
        fi
    fi

    # Fallback: Apple Silicon Macs usually have Touch ID.
    if [[ "$(uname -m)" == "arm64" ]]; then
        return 0
    fi
    return 1
}

cleanup_path() {
    local raw_path="$1"
    local label="$2"

    local expanded_path="${raw_path/#\~/$HOME}"
    if [[ ! -e "$expanded_path" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} $label"
        return
    fi
    if should_protect_path "$expanded_path"; then
        echo -e "${GRAY}${ICON_WARNING}${NC} Protected $label"
        return
    fi

    local size_kb
    size_kb=$(get_path_size_kb "$expanded_path")
    local size_display=""
    if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
        size_display=$(bytes_to_human "$((size_kb * 1024))")
    fi

    local removed=false
    if safe_remove "$expanded_path" true; then
        removed=true
    elif request_sudo_access "Removing $label requires admin access"; then
        if safe_sudo_remove "$expanded_path"; then
            removed=true
        fi
    fi

    if [[ "$removed" == "true" ]]; then
        if [[ -n "$size_display" ]]; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} $label${NC}, ${GREEN}${size_display}${NC}"
        else
            echo -e "${GREEN}${ICON_SUCCESS}${NC} $label"
        fi
    else
        echo -e "${GRAY}${ICON_WARNING}${NC} Skipped $label${NC}"
        echo -e "${GRAY}${ICON_REVIEW}${NC} ${GRAY}Grant Full Disk Access to your terminal, then retry${NC}"
    fi
}

ensure_directory() {
    local raw_path="$1"
    local expanded_path="${raw_path/#\~/$HOME}"
    ensure_user_dir "$expanded_path"
}

declare -a SECURITY_FIXES=()

collect_security_fix_actions() {
    SECURITY_FIXES=()
    if [[ "${FIREWALL_DISABLED:-}" == "true" ]]; then
        if ! is_whitelisted "firewall"; then
            SECURITY_FIXES+=("firewall|Enable macOS firewall")
        fi
    fi
    # Gatekeeper state is intentionally user-managed. Optimize may report it,
    # but it must not change the user's "Anywhere" preference.
    if touchid_supported && ! touchid_configured; then
        if ! is_whitelisted "check_touchid"; then
            SECURITY_FIXES+=("touchid|Enable Touch ID for sudo")
        fi
    fi

    ((${#SECURITY_FIXES[@]} > 0))
}

ask_for_security_fixes() {
    if ! collect_security_fix_actions; then
        return 1
    fi

    echo ""
    echo -e "${BLUE}SECURITY FIXES${NC}"
    for entry in "${SECURITY_FIXES[@]}"; do
        IFS='|' read -r _ label <<< "$entry"
        echo -e "  ${ICON_LIST} $label"
    done
    echo ""
    export MOLE_SECURITY_FIXES_SHOWN=true
    echo -ne "${GRAY}${ICON_REVIEW}${NC} ${YELLOW}Apply now?${NC} ${GRAY}Enter confirm / Space cancel${NC}: "

    local key
    if ! key=$(read_key); then
        export MOLE_SECURITY_FIXES_SKIPPED=true
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Security fixes skipped"
        echo ""
        return 1
    fi

    if [[ "$key" == "ENTER" ]]; then
        echo ""
        return 0
    else
        export MOLE_SECURITY_FIXES_SKIPPED=true
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Security fixes skipped"
        echo ""
        return 1
    fi
}

apply_firewall_fix() {
    if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on > /dev/null 2>&1; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Firewall enabled"
        FIREWALL_DISABLED=false
        return 0
    fi
    echo -e "  ${GRAY}${ICON_WARNING}${NC} Failed to enable firewall, check permissions"
    return 1
}

apply_touchid_fix() {
    if "$SCRIPT_DIR/bin/touchid.sh" enable; then
        return 0
    fi
    return 1
}

perform_security_fixes() {
    if ! ensure_sudo_session "Security changes require admin access"; then
        echo -e "${GRAY}${ICON_WARNING}${NC} Skipped security fixes, sudo denied"
        return 1
    fi

    local applied=0
    for entry in "${SECURITY_FIXES[@]}"; do
        IFS='|' read -r action _ <<< "$entry"
        case "$action" in
            firewall)
                apply_firewall_fix && ((applied++))
                ;;
            touchid)
                apply_touchid_fix && ((applied++))
                ;;
        esac
    done

    if ((applied > 0)); then
        log_success "Security settings updated"
    fi
    SECURITY_FIXES=()
}

cleanup_all() {
    stop_inline_spinner 2> /dev/null || true
    stop_sudo_session
    cleanup_temp_files
    # Log session end
    log_operation_session_end "optimize" "${OPTIMIZE_SAFE_COUNT:-0}" "0"
}

handle_interrupt() {
    cleanup_all
    exit 130
}

main() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="optimize"

    local health_json
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                show_optimize_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run")
                export MOLE_DRY_RUN=1
                ;;
            "--whitelist")
                manage_whitelist "optimize"
                exit 0
                ;;
        esac
    done

    log_operation_session_start "optimize"

    trap cleanup_all EXIT
    trap handle_interrupt INT TERM

    if [[ -t 1 ]]; then
        clear_screen
    fi
    print_header

    # Dry-run indicator.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No files will be modified\n"
    fi

    if ! command -v bc > /dev/null 2>&1; then
        echo -e "${YELLOW}${ICON_ERROR}${NC} Missing dependency: bc"
        echo -e "${GRAY}Install with: ${GREEN}brew install bc${NC}"
        exit 1
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "Collecting system info..."
    fi

    if ! health_json=$(generate_health_json 2> /dev/null); then
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo ""
        log_error "Failed to collect system health data"
        exit 1
    fi

    if ! json_validate "$health_json"; then
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo ""
        log_error "Invalid system health data format"
        echo -e "${GRAY}${ICON_REVIEW}${NC} Check if awk, sysctl, and df commands are available"
        exit 1
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    show_system_health "$health_json"

    load_whitelist "optimize"
    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local count=${#CURRENT_WHITELIST_PATTERNS[@]}
        if [[ $count -le 3 ]]; then
            local patterns_list=$(
                IFS=', '
                echo "${CURRENT_WHITELIST_PATTERNS[*]}"
            )
            echo -e "${ICON_ADMIN} Active Whitelist: ${patterns_list}"
        fi
    fi

    local -a safe_items=()
    local -a confirm_items=()
    local opts_file
    opts_file=$(mktemp_file)
    parse_optimization_items "$health_json" > "$opts_file"

    while IFS='|' read -r action name desc safe; do
        [[ -z "$action" ]] && continue

        local path=""
        local item="${name}|${desc}|${action}|${path}"

        if [[ "$safe" == "true" ]]; then
            safe_items+=("$item")
        else
            confirm_items+=("$item")
        fi
    done < "$opts_file"

    echo ""
    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        ensure_sudo_session "System optimization requires admin access" || true
    fi

    export FIRST_ACTION=true
    if [[ ${#safe_items[@]} -gt 0 ]]; then
        for item in "${safe_items[@]}"; do
            IFS='|' read -r name desc action path <<< "$item"
            announce_action "$name" "$desc" "safe"
            execute_optimization "$action" "$path"
        done
    fi

    if [[ ${#confirm_items[@]} -gt 0 ]]; then
        for item in "${confirm_items[@]}"; do
            IFS='|' read -r name desc action path <<< "$item"
            announce_action "$name" "$desc" "confirm"
            execute_optimization "$action" "$path"
        done
    fi

    local safe_count=${#safe_items[@]}
    local confirm_count=${#confirm_items[@]}

    run_system_checks

    export OPTIMIZE_SAFE_COUNT=$safe_count
    export OPTIMIZE_CONFIRM_COUNT=$confirm_count

    show_optimization_summary

    printf '\n'
}

main "$@"
