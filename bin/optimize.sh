#!/bin/bash

set -euo pipefail

# Fix locale issues (Issue #83)
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/core/sudo.sh"
source "$SCRIPT_DIR/lib/manage/update.sh"
source "$SCRIPT_DIR/lib/manage/autofix.sh"
source "$SCRIPT_DIR/lib/optimize/maintenance.sh"
source "$SCRIPT_DIR/lib/optimize/tasks.sh"
source "$SCRIPT_DIR/lib/check/health_json.sh"
source "$SCRIPT_DIR/lib/check/all.sh"
source "$SCRIPT_DIR/lib/manage/whitelist.sh"

print_header() {
    printf '\n'
    echo -e "${PURPLE_BOLD}Optimize and Check${NC}"
}

run_system_checks() {
    unset AUTO_FIX_SUMMARY AUTO_FIX_DETAILS
    echo ""
    echo -e "${PURPLE_BOLD}System Check${NC}"
    echo ""

    echo -e "${BLUE}${ICON_ARROW}${NC} System updates"
    check_all_updates
    echo ""

    echo -e "${BLUE}${ICON_ARROW}${NC} System health"
    check_system_health
    echo ""

    echo -e "${BLUE}${ICON_ARROW}${NC} Security posture"
    check_all_security
    if ask_for_security_fixes; then
        perform_security_fixes
    fi
    echo ""

    echo -e "${BLUE}${ICON_ARROW}${NC} Configuration"
    check_all_config
    echo ""

    show_suggestions
    echo ""

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
    local summary_title="Optimization and Check Complete"
    local -a summary_details=()

    local total_applied=$((safe_count + confirm_count))
    summary_details+=("Applied ${GREEN}${total_applied:-0}${NC} optimizations; all system services tuned")
    summary_details+=("Updates, security and system health fully reviewed")

    local summary_line4=""
    if [[ -n "${AUTO_FIX_SUMMARY:-}" ]]; then
        summary_line4="${AUTO_FIX_SUMMARY}"
        if [[ -n "${AUTO_FIX_DETAILS:-}" ]]; then
            local detail_join
            detail_join=$(echo "${AUTO_FIX_DETAILS}" | paste -sd ", " -)
            [[ -n "$detail_join" ]] && summary_line4+=" — ${detail_join}"
        fi
    else
        summary_line4="Your Mac is now faster and more responsive"
    fi
    summary_details+=("$summary_line4")

    print_summary_block "$summary_title" "${summary_details[@]}"
}

show_system_health() {
    local health_json="$1"

    local mem_used=$(echo "$health_json" | jq -r '.memory_used_gb // 0' 2> /dev/null || echo "0")
    local mem_total=$(echo "$health_json" | jq -r '.memory_total_gb // 0' 2> /dev/null || echo "0")
    local disk_used=$(echo "$health_json" | jq -r '.disk_used_gb // 0' 2> /dev/null || echo "0")
    local disk_total=$(echo "$health_json" | jq -r '.disk_total_gb // 0' 2> /dev/null || echo "0")
    local disk_percent=$(echo "$health_json" | jq -r '.disk_used_percent // 0' 2> /dev/null || echo "0")
    local uptime=$(echo "$health_json" | jq -r '.uptime_days // 0' 2> /dev/null || echo "0")

    mem_used=${mem_used:-0}
    mem_total=${mem_total:-0}
    disk_used=${disk_used:-0}
    disk_total=${disk_total:-0}
    disk_percent=${disk_percent:-0}
    uptime=${uptime:-0}

    printf "${ICON_ADMIN} System  %.0f/%.0f GB RAM | %.0f/%.0f GB Disk | Uptime %.0fd\n" \
        "$mem_used" "$mem_total" "$disk_used" "$disk_total" "$uptime"
}

parse_optimizations() {
    local health_json="$1"
    echo "$health_json" | jq -c '.optimizations[]' 2> /dev/null
}

announce_action() {
    local name="$1"
    local desc="$2"
    local kind="$3"

    local badge=""
    if [[ "$kind" == "confirm" ]]; then
        badge="${YELLOW}[Confirm]${NC} "
    fi

    local line="${BLUE}${ICON_ARROW}${NC} ${badge}${name}"
    if [[ -n "$desc" ]]; then
        line+=" ${GRAY}- ${desc}${NC}"
    fi

    if ${first_heading:-true}; then
        first_heading=false
    else
        echo ""
    fi

    echo -e "$line"
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

    # Fallback: Apple Silicon Macs usually have Touch ID
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
        echo -e "${YELLOW}${ICON_WARNING}${NC} Protected $label"
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
            echo -e "${GREEN}${ICON_SUCCESS}${NC} $label ${GREEN}(${size_display})${NC}"
        else
            echo -e "${GREEN}${ICON_SUCCESS}${NC} $label"
        fi
    else
        echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $label ${GRAY}(grant Full Disk Access to your terminal and retry)${NC}"
    fi
}

ensure_directory() {
    local raw_path="$1"
    local expanded_path="${raw_path/#\~/$HOME}"
    ensure_user_dir "$expanded_path"
}

count_local_snapshots() {
    if ! command -v tmutil > /dev/null 2>&1; then
        echo 0
        return
    fi

    local output
    output=$(tmutil listlocalsnapshots / 2> /dev/null || true)
    if [[ -z "$output" ]]; then
        echo 0
        return
    fi

    echo "$output" | grep -c "com.apple.TimeMachine." | tr -d ' '
}

declare -a SECURITY_FIXES=()

collect_security_fix_actions() {
    SECURITY_FIXES=()
    if [[ "${FIREWALL_DISABLED:-}" == "true" ]]; then
        if ! is_whitelisted "firewall"; then
            SECURITY_FIXES+=("firewall|Enable macOS firewall")
        fi
    fi
    if [[ "${GATEKEEPER_DISABLED:-}" == "true" ]]; then
        if ! is_whitelisted "gatekeeper"; then
            SECURITY_FIXES+=("gatekeeper|Enable Gatekeeper (App download protection)")
        fi
    fi
    if touchid_supported && ! touchid_configured; then
        if ! is_whitelisted "touchid"; then
            SECURITY_FIXES+=("touchid|Enable Touch ID for sudo")
        fi
    fi

    ((${#SECURITY_FIXES[@]} > 0))
}

ask_for_security_fixes() {
    if ! collect_security_fix_actions; then
        return 1
    fi

    echo -e "${BLUE}SECURITY FIXES${NC}"
    for entry in "${SECURITY_FIXES[@]}"; do
        IFS='|' read -r _ label <<< "$entry"
        echo -e "  ${ICON_LIST} $label"
    done
    echo ""
    echo -ne "${YELLOW}Apply now?${NC} ${GRAY}Enter confirm / ESC cancel${NC}: "

    local key
    if ! key=$(read_key); then
        echo "skip"
        echo ""
        return 1
    fi

    if [[ "$key" == "ENTER" ]]; then
        echo "apply"
        echo ""
        return 0
    else
        echo "skip"
        echo ""
        return 1
    fi
}

apply_firewall_fix() {
    if sudo defaults write /Library/Preferences/com.apple.alf globalstate -int 1; then
        sudo pkill -HUP socketfilterfw 2> /dev/null || true
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Firewall enabled"
        FIREWALL_DISABLED=false
        return 0
    fi
    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to enable firewall (check permissions)"
    return 1
}

apply_gatekeeper_fix() {
    if sudo spctl --master-enable 2> /dev/null; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Gatekeeper enabled"
        GATEKEEPER_DISABLED=false
        return 0
    fi
    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Failed to enable Gatekeeper"
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
        echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped security fixes (sudo denied)"
        return 1
    fi

    local applied=0
    for entry in "${SECURITY_FIXES[@]}"; do
        IFS='|' read -r action _ <<< "$entry"
        case "$action" in
            firewall)
                apply_firewall_fix && ((applied++))
                ;;
            gatekeeper)
                apply_gatekeeper_fix && ((applied++))
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
    stop_sudo_session
    cleanup_temp_files
}

main() {
    local health_json
    for arg in "$@"; do
        case "$arg" in
            "--debug")
                export MO_DEBUG=1
                ;;
            "--whitelist")
                manage_whitelist "optimize"
                exit 0
                ;;
        esac
    done

    trap cleanup_all EXIT INT TERM

    if [[ -t 1 ]]; then
        clear
    fi
    print_header
    if ! command -v jq > /dev/null 2>&1; then
        echo -e "${RED}${ICON_ERROR}${NC} Missing dependency: jq"
        echo -e "${GRAY}Install with: ${GREEN}brew install jq${NC}"
        exit 1
    fi

    if ! command -v bc > /dev/null 2>&1; then
        echo -e "${RED}${ICON_ERROR}${NC} Missing dependency: bc"
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

    if ! echo "$health_json" | jq empty 2> /dev/null; then
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo ""
        log_error "Invalid system health data format"
        echo -e "${YELLOW}Tip:${NC} Check if jq, awk, sysctl, and df commands are available"
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
        else
            echo -e "${ICON_ADMIN} Active Whitelist: ${GRAY}${count} items${NC}"
        fi
    fi
    echo ""

    echo -ne "${PURPLE}${ICON_ARROW}${NC} Optimization needs sudo — ${GREEN}Enter${NC} continue, ${GRAY}ESC${NC} cancel: "

    local key
    if ! key=$(read_key); then
        exit 0
    fi

    if [[ "$key" == "ENTER" ]]; then
        printf "\r\033[K"
    else
        exit 0
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    local -a safe_items=()
    local -a confirm_items=()
    local opts_file
    opts_file=$(mktemp_file)
    parse_optimizations "$health_json" > "$opts_file"

    while IFS= read -r opt_json; do
        [[ -z "$opt_json" ]] && continue

        local name=$(echo "$opt_json" | jq -r '.name')
        local desc=$(echo "$opt_json" | jq -r '.description')
        local action=$(echo "$opt_json" | jq -r '.action')
        local path=$(echo "$opt_json" | jq -r '.path // ""')
        local safe=$(echo "$opt_json" | jq -r '.safe')

        local item="${name}|${desc}|${action}|${path}"

        if [[ "$safe" == "true" ]]; then
            safe_items+=("$item")
        else
            confirm_items+=("$item")
        fi
    done < "$opts_file"

    local first_heading=true

    ensure_sudo_session "System optimization requires admin access" || true
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
