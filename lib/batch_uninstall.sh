#!/bin/bash

set -euo pipefail

# Ensure common.sh is loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -z "${MOLE_COMMON_LOADED:-}" ]] && source "$SCRIPT_DIR/lib/common.sh"

# Batch uninstall functionality with minimal confirmations
# Replaces the overly verbose individual confirmation approach
# Note: find_app_files() and calculate_total_size() functions now in lib/common.sh

# Batch uninstall with single confirmation
batch_uninstall_applications() {
    local total_size_freed=0

    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    # Pre-process: Check for running apps and calculate total impact
    local -a running_apps=()
    local -a sudo_apps=()
    local total_estimated_size=0
    local -a app_details=()

    echo ""
    # Silent analysis without spinner output (avoid visual flicker)
    for selected_app in "${selected_apps[@]}"; do
        [[ -z "$selected_app" ]] && continue
        IFS='|' read -r epoch app_path app_name bundle_id size last_used <<< "$selected_app"

        # Check if app is running
        if pgrep -f "$app_name" >/dev/null 2>&1; then
            running_apps+=("$app_name")
        fi

        # Check if app requires sudo to delete
        if [[ ! -w "$(dirname "$app_path")" ]] || [[ "$(stat -f%Su "$app_path" 2>/dev/null)" == "root" ]]; then
            sudo_apps+=("$app_name")
        fi

        # Calculate size for summary
        local app_size_kb=$(du -sk "$app_path" 2>/dev/null | awk '{print $1}' || echo "0")
        local related_files=$(find_app_files "$bundle_id" "$app_name")
        local related_size_kb=$(calculate_total_size "$related_files")
        local total_kb=$((app_size_kb + related_size_kb))
        ((total_estimated_size += total_kb))

        # Store details for later use
        # Base64 encode related_files to handle multi-line data safely
        local encoded_files=$(echo "$related_files" | base64)
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files")
    done

    # Format size display (convert KB to bytes for bytes_to_human())
    local size_display=$(bytes_to_human "$((total_estimated_size * 1024))")

    # Show summary and get batch confirmation first (before asking for password)
    local app_total=${#selected_apps[@]}
    local app_text="app"
    [[ $app_total -gt 1 ]] && app_text="apps"
    if [[ ${#running_apps[@]} -gt 0 ]]; then
        echo -n "${BLUE}${ICON_CONFIRM}${NC} Remove ${app_total} ${app_text} | ${size_display} | Force quit: ${running_apps[*]} | Enter=go / ESC=q: "
    else
        echo -n "${BLUE}${ICON_CONFIRM}${NC} Remove ${app_total} ${app_text} | ${size_display} | Enter=go / ESC=q: "
    fi
    IFS= read -r -s -n1 key || key=""
    case "$key" in
        $'\e'|q|Q) echo ""; return 0 ;;
        ""|$'\n'|$'\r'|y|Y) echo "" ;;
        *) echo ""; return 0 ;;
    esac

    # User confirmed, now request sudo access if needed
    if [[ ${#sudo_apps[@]} -gt 0 ]]; then
        # Check if sudo is already cached
        if ! sudo -n true 2>/dev/null; then
            if ! request_sudo_access "Admin required for system apps: ${sudo_apps[*]}"; then
                echo ""
                log_error "Admin access denied"
                return 1
            fi
        fi
        (while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null) &
        local sudo_keepalive_pid=$!
        local _trap_cleanup_cmd="kill $sudo_keepalive_pid 2>/dev/null || true; wait $sudo_keepalive_pid 2>/dev/null || true"
        for signal in EXIT INT TERM; do
            local existing_trap; existing_trap=$(trap -p "$signal" | awk -F"'" '{print $2}')
            if [[ -n "$existing_trap" ]]; then
                trap "$existing_trap; $_trap_cleanup_cmd" "$signal"
            else
                trap "$_trap_cleanup_cmd" "$signal"
            fi
        done
    fi

    echo ""
    if [[ -t 1 ]]; then start_inline_spinner "Uninstalling apps..."; fi

    # Force quit running apps first (batch)
    if [[ ${#running_apps[@]} -gt 0 ]]; then
        pkill -f "${running_apps[0]}" 2>/dev/null || true
        for app_name in "${running_apps[@]:1}"; do pkill -f "$app_name" 2>/dev/null || true; done
        sleep 2
        if pgrep -f "${running_apps[0]}" >/dev/null 2>&1; then sleep 1; fi
    fi

    # Perform uninstallations (silent mode, show results at end)
    if [[ -t 1 ]]; then stop_inline_spinner; fi
    local success_count=0 failed_count=0
    local -a failed_items=()
    local -a success_items=()
    for detail in "${app_details[@]}"; do
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files <<< "$detail"
        local related_files=$(echo "$encoded_files" | base64 -d)
        local reason=""
        local needs_sudo=false
        [[ ! -w "$(dirname "$app_path")" || "$(stat -f%Su "$app_path" 2>/dev/null)" == "root" ]] && needs_sudo=true
        if ! force_kill_app "$app_name"; then
            reason="still running"
        fi
        if [[ -z "$reason" ]]; then
            if [[ "$needs_sudo" == true ]]; then
                sudo rm -rf "$app_path" 2>/dev/null || reason="remove failed"
            else
                rm -rf "$app_path" 2>/dev/null || reason="remove failed"
            fi
        fi
        if [[ -z "$reason" ]]; then
            local files_removed=0
            while IFS= read -r file; do
                [[ -n "$file" && -e "$file" ]] || continue
                rm -rf "$file" 2>/dev/null && ((files_removed++)) || true
            done <<< "$related_files"
            ((total_size_freed += total_kb))
            ((success_count++))
            ((files_cleaned++))
            ((total_items++))
            success_items+=("$app_name")
        else
            ((failed_count++))
            failed_items+=("$app_name:$reason")
        fi
    done

    # Summary
    local freed_display=$(bytes_to_human "$((total_size_freed * 1024))")
    local bar="================================================================================"
    echo ""
    echo "$bar"
    if [[ $success_count -gt 0 ]]; then
        local success_list="${success_items[*]}"
        echo -e "Removed: ${GREEN}${success_list}${NC} | Freed: ${GREEN}${freed_display}${NC}"
    fi
    if [[ $failed_count -gt 0 ]]; then
        local failed_names=()
        local reason_summary=""
        for item in "${failed_items[@]}"; do
            local name=${item%%:*}
            failed_names+=("$name")
        done
        local failed_list="${failed_names[*]}"

        # Determine primary reason
        if [[ $failed_count -eq 1 ]]; then
            local first_reason=${failed_items[0]#*:}
            case "$first_reason" in
                still*running*) reason_summary="still running" ;;
                remove*failed*) reason_summary="could not be removed" ;;
                permission*) reason_summary="permission denied" ;;
                *) reason_summary="$first_reason" ;;
            esac
            echo -e "Failed: ${RED}${failed_list}${NC} ${reason_summary}"
        else
            echo -e "Failed: ${RED}${failed_list}${NC} could not be removed"
        fi
    fi
    echo "$bar"

    # Clean up sudo keepalive if it was started
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2>/dev/null || true
        wait "$sudo_keepalive_pid" 2>/dev/null || true
    fi

    ((total_size_cleaned += total_size_freed))
    unset failed_items
}
