#!/bin/bash

set -euo pipefail

# Ensure common.sh is loaded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -z "${MOLE_COMMON_LOADED:-}" ]] && source "$SCRIPT_DIR/lib/core/common.sh"

# Load Homebrew cask support (provides get_brew_cask_name, brew_uninstall_cask)
[[ -f "$SCRIPT_DIR/lib/uninstall/brew.sh" ]] && source "$SCRIPT_DIR/lib/uninstall/brew.sh"

# Batch uninstall with a single confirmation.

# High-performance sensitive data detection (pure Bash, no subprocess)
# Faster than grep for batch operations, especially when processing many apps
has_sensitive_data() {
    local files="$1"
    [[ -z "$files" ]] && return 1

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Use Bash native pattern matching (faster than spawning grep)
        case "$file" in
            */.warp* | */.config/* | */themes/* | */settings/* | */User\ Data/* | \
                */.ssh/* | */.gnupg/* | */Documents/* | */Preferences/*.plist | \
                */Desktop/* | */Downloads/* | */Movies/* | */Music/* | */Pictures/* | \
                */.password* | */.token* | */.auth* | */keychain* | \
                */Passwords/* | */Accounts/* | */Cookies/* | \
                */.aws/* | */.docker/config.json | */.kube/* | \
                */credentials/* | */secrets/*)
                return 0 # Found sensitive data
                ;;
        esac
    done <<< "$files"

    return 1 # Not found
}

# Decode and validate base64 file list (safe for set -e).
decode_file_list() {
    local encoded="$1"
    local app_name="$2"
    local decoded

    # macOS uses -D, GNU uses -d. Always return 0 for set -e safety.
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        if ! decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null); then
            log_error "Failed to decode file list for $app_name" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    fi

    if [[ "$decoded" =~ $'\0' ]]; then
        log_warning "File list for $app_name contains null bytes, rejecting" >&2
        echo ""
        return 0 # Return success with empty string
    fi

    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^/ ]]; then
            log_warning "Invalid path in file list for $app_name: $line" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    done <<< "$decoded"

    echo "$decoded"
    return 0
}
# Note: find_app_files() and calculate_total_size() are in lib/core/common.sh.

# Stop Launch Agents/Daemons for an app.
# Security: bundle_id is validated to be reverse-DNS format before use in find patterns
stop_launch_services() {
    local bundle_id="$1"
    local has_system_files="${2:-false}"

    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 0

    # Validate bundle_id format: must be reverse-DNS style (e.g., com.example.app)
    # This prevents glob injection attacks if bundle_id contains special characters
    if [[ ! "$bundle_id" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+$ ]]; then
        debug_log "Invalid bundle_id format for LaunchAgent search: $bundle_id"
        return 0
    fi

    if [[ -d ~/Library/LaunchAgents ]]; then
        while IFS= read -r -d '' plist; do
            launchctl unload "$plist" 2> /dev/null || true
        done < <(find ~/Library/LaunchAgents -maxdepth 1 -name "${bundle_id}*.plist" -print0 2> /dev/null)
    fi

    if [[ "$has_system_files" == "true" ]]; then
        if [[ -d /Library/LaunchAgents ]]; then
            while IFS= read -r -d '' plist; do
                sudo launchctl unload "$plist" 2> /dev/null || true
            done < <(find /Library/LaunchAgents -maxdepth 1 -name "${bundle_id}*.plist" -print0 2> /dev/null)
        fi
        if [[ -d /Library/LaunchDaemons ]]; then
            while IFS= read -r -d '' plist; do
                sudo launchctl unload "$plist" 2> /dev/null || true
            done < <(find /Library/LaunchDaemons -maxdepth 1 -name "${bundle_id}*.plist" -print0 2> /dev/null)
        fi
    fi
}

# Remove macOS Login Items for an app
remove_login_item() {
    local app_name="$1"
    local bundle_id="$2"

    # Skip if no identifiers provided
    [[ -z "$app_name" && -z "$bundle_id" ]] && return 0

    # Strip .app suffix if present (login items don't include it)
    local clean_name="${app_name%.app}"

    # Remove from Login Items using index-based deletion (handles broken items)
    if [[ -n "$clean_name" ]]; then
        # Escape double quotes and backslashes for AppleScript
        local escaped_name="${clean_name//\\/\\\\}"
        escaped_name="${escaped_name//\"/\\\"}"

        osascript <<- EOF > /dev/null 2>&1 || true
			tell application "System Events"
			    try
			        set itemCount to count of login items
			        -- Delete in reverse order to avoid index shifting
			        repeat with i from itemCount to 1 by -1
			            try
			                set itemName to name of login item i
			                if itemName is "$escaped_name" then
			                    delete login item i
			                end if
			            end try
			        end repeat
			    end try
			end tell
		EOF
    fi
}

# Remove files (handles symlinks, optional sudo).
# Security: All paths pass validate_path_for_deletion() before any deletion.
remove_file_list() {
    local file_list="$1"
    local use_sudo="${2:-false}"
    local count=0

    while IFS= read -r file; do
        [[ -n "$file" && -e "$file" ]] || continue

        if ! validate_path_for_deletion "$file"; then
            continue
        fi

        if [[ -L "$file" ]]; then
            safe_remove_symlink "$file" "$use_sudo" && ((++count)) || true
        else
            if [[ "$use_sudo" == "true" ]]; then
                safe_sudo_remove "$file" && ((++count)) || true
            else
                safe_remove "$file" true && ((++count)) || true
            fi
        fi
    done <<< "$file_list"

    echo "$count"
}

# Batch uninstall with single confirmation.
batch_uninstall_applications() {
    local total_size_freed=0

    # shellcheck disable=SC2154
    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    local old_trap_int old_trap_term
    old_trap_int=$(trap -p INT)
    old_trap_term=$(trap -p TERM)

    _cleanup_sudo_keepalive() {
        if [[ -n "${sudo_keepalive_pid:-}" ]]; then
            kill "$sudo_keepalive_pid" 2> /dev/null || true
            wait "$sudo_keepalive_pid" 2> /dev/null || true
            sudo_keepalive_pid=""
        fi
    }

    _restore_uninstall_traps() {
        _cleanup_sudo_keepalive
        if [[ -n "$old_trap_int" ]]; then
            eval "$old_trap_int"
        else
            trap - INT
        fi
        if [[ -n "$old_trap_term" ]]; then
            eval "$old_trap_term"
        else
            trap - TERM
        fi
    }

    # Trap to clean up spinner, sudo keepalive, and uninstall mode on interrupt
    trap 'stop_inline_spinner 2>/dev/null; _cleanup_sudo_keepalive; unset MOLE_UNINSTALL_MODE; echo ""; _restore_uninstall_traps; return 130' INT TERM

    # Pre-scan: running apps, sudo needs, size.
    local -a running_apps=()
    local -a sudo_apps=()
    local total_estimated_size=0
    local -a app_details=()

    # Cache current user outside loop
    local current_user=$(whoami)

    if [[ -t 1 ]]; then start_inline_spinner "Scanning files..."; fi
    for selected_app in "${selected_apps[@]}"; do
        [[ -z "$selected_app" ]] && continue
        IFS='|' read -r _ app_path app_name bundle_id _ _ <<< "$selected_app"

        # Check running app by bundle executable if available
        local exec_name=""
        local info_plist="$app_path/Contents/Info.plist"
        if [[ -e "$info_plist" ]]; then
            exec_name=$(defaults read "$info_plist" CFBundleExecutable 2> /dev/null || echo "")
        fi
        if pgrep -qx "${exec_name:-$app_name}" 2> /dev/null; then
            running_apps+=("$app_name")
        fi

        local cask_name="" is_brew_cask="false"
        local resolved_path=$(readlink "$app_path" 2> /dev/null || echo "")
        if [[ "$resolved_path" == */Caskroom/* ]]; then
            # Extract cask name using bash parameter expansion (faster than sed)
            local tmp="${resolved_path#*/Caskroom/}"
            cask_name="${tmp%%/*}"
            [[ -n "$cask_name" ]] && is_brew_cask="true"
        elif command -v get_brew_cask_name > /dev/null 2>&1; then
            local detected_cask
            detected_cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
            if [[ -n "$detected_cask" ]]; then
                cask_name="$detected_cask"
                is_brew_cask="true"
            fi
        fi

        # Check if sudo is needed
        local needs_sudo=false
        local app_owner=$(get_file_owner "$app_path")
        if [[ ! -w "$(dirname "$app_path")" ]] ||
            [[ "$app_owner" == "root" ]] ||
            [[ -n "$app_owner" && "$app_owner" != "$current_user" ]]; then
            needs_sudo=true
        fi

        local app_size_kb=$(get_path_size_kb "$app_path" || echo "0")
        local related_files=$(find_app_files "$bundle_id" "$app_name" || true)
        local diag_user
        diag_user=$(get_diagnostic_report_paths_for_app "$app_path" "$app_name" "$HOME/Library/Logs/DiagnosticReports" || true)
        [[ -n "$diag_user" ]] && related_files=$(
            [[ -n "$related_files" ]] && echo "$related_files"
            echo "$diag_user"
        )
        local related_size_kb=$(calculate_total_size "$related_files" || echo "0")
        # system_files is a newline-separated string, not an array.
        # shellcheck disable=SC2178,SC2128
        local system_files=$(find_app_system_files "$bundle_id" "$app_name" || true)
        local diag_system
        diag_system=$(get_diagnostic_report_paths_for_app "$app_path" "$app_name" "/Library/Logs/DiagnosticReports" || true)
        # shellcheck disable=SC2128
        local system_size_kb=$(calculate_total_size "$system_files" || echo "0")
        local diag_system_size_kb=$(calculate_total_size "$diag_system" || echo "0")
        local total_kb=$((app_size_kb + related_size_kb + system_size_kb + diag_system_size_kb))
        ((total_estimated_size += total_kb)) || true

        # shellcheck disable=SC2128
        if [[ -n "$system_files" || -n "$diag_system" ]]; then
            needs_sudo=true
        fi

        if [[ "$needs_sudo" == "true" ]]; then
            sudo_apps+=("$app_name")
        fi

        # Check for sensitive user data once.
        local has_sensitive_data="false"
        if has_sensitive_data "$related_files" 2> /dev/null; then
            has_sensitive_data="true"
        fi

        # Store details for later use (base64 keeps lists on one line).
        local encoded_files
        encoded_files=$(printf '%s' "$related_files" | base64 | tr -d '\n' || echo "")
        local encoded_system_files
        encoded_system_files=$(printf '%s' "$system_files" | base64 | tr -d '\n' || echo "")
        local encoded_diag_system
        encoded_diag_system=$(printf '%s' "$diag_system" | base64 | tr -d '\n' || echo "")
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files|$encoded_system_files|$has_sensitive_data|$needs_sudo|$is_brew_cask|$cask_name|$encoded_diag_system")
    done
    if [[ -t 1 ]]; then stop_inline_spinner; fi

    local size_display=$(bytes_to_human "$((total_estimated_size * 1024))")

    echo ""
    echo -e "${PURPLE_BOLD}Files to be removed:${NC}"
    echo ""

    # Warn if brew cask apps are present.
    local has_brew_cask=false
    for detail in "${app_details[@]}"; do
        IFS='|' read -r _ _ _ _ _ _ _ _ is_brew_cask_flag _ <<< "$detail"
        [[ "$is_brew_cask_flag" == "true" ]] && has_brew_cask=true
    done

    if [[ "$has_brew_cask" == "true" ]]; then
        echo -e "${GRAY}${ICON_WARNING}${NC} ${YELLOW}Homebrew apps will be fully cleaned (--zap: removes configs & data)${NC}"
        echo ""
    fi

    for detail in "${app_details[@]}"; do
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files has_sensitive_data needs_sudo_flag is_brew_cask cask_name encoded_diag_system <<< "$detail"
        local app_size_display=$(bytes_to_human "$((total_kb * 1024))")

        local brew_tag=""
        [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
        echo -e "${BLUE}${ICON_CONFIRM}${NC} ${app_name}${brew_tag} ${GRAY}, ${app_size_display}${NC}"

        # Show detailed file list for ALL apps (brew casks leave user data behind)
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local diag_system_display
        diag_system_display=$(decode_file_list "$encoded_diag_system" "$app_name")
        [[ -n "$diag_system_display" ]] && system_files=$(
            [[ -n "$system_files" ]] && echo "$system_files"
            echo "$diag_system_display"
        )

        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${app_path/$HOME/~}"

        # Show all related files so users can fully review before deletion.
        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${file/$HOME/~}"
            fi
        done <<< "$related_files"

        # Show all system files so users can fully review before deletion.
        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                echo -e "  ${BLUE}${ICON_WARNING}${NC} System: $file"
            fi
        done <<< "$system_files"
    done

    # Confirmation before requesting sudo.
    local app_total=${#selected_apps[@]}
    local app_text="app"
    [[ $app_total -gt 1 ]] && app_text="apps"

    echo ""
    local removal_note="Remove ${app_total} ${app_text}"
    [[ -n "$size_display" ]] && removal_note+=", ${size_display}"
    if [[ ${#running_apps[@]} -gt 0 ]]; then
        removal_note+=" ${YELLOW}[Running]${NC}"
    fi
    echo -ne "${PURPLE}${ICON_ARROW}${NC} ${removal_note}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    drain_pending_input # Clean up any pending input before confirmation
    IFS= read -r -s -n1 key || key=""
    drain_pending_input # Clean up any escape sequence remnants
    case "$key" in
        $'\e' | q | Q)
            echo ""
            echo ""
            _restore_uninstall_traps
            return 0
            ;;
        "" | $'\n' | $'\r' | y | Y)
            echo "" # Move to next line
            ;;
        *)
            echo ""
            echo ""
            _restore_uninstall_traps
            return 0
            ;;
    esac

    # Enable uninstall mode - allows deletion of data-protected apps (VPNs, dev tools, etc.)
    # that user explicitly chose to uninstall. System-critical components remain protected.
    export MOLE_UNINSTALL_MODE=1

    # Request sudo if needed.
    if [[ ${#sudo_apps[@]} -gt 0 ]]; then
        if ! sudo -n true 2> /dev/null; then
            if ! request_sudo_access "Admin required for system apps: ${sudo_apps[*]}"; then
                echo ""
                log_error "Admin access denied"
                _restore_uninstall_traps
                return 1
            fi
        fi
        # Keep sudo alive during uninstall.
        parent_pid=$$
        (while true; do
            if ! kill -0 "$parent_pid" 2> /dev/null; then
                exit 0
            fi
            sudo -n true
            sleep 60
        done 2> /dev/null) &
        sudo_keepalive_pid=$!
    fi

    # Perform uninstallations with per-app progress feedback
    local success_count=0 failed_count=0
    local brew_apps_removed=0 # Track successful brew uninstalls for autoremove tip
    local -a failed_items=()
    local -a success_items=()
    local current_index=0
    for detail in "${app_details[@]}"; do
        ((current_index++))
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system <<< "$detail"
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local diag_system=$(decode_file_list "$encoded_diag_system" "$app_name")
        local reason=""
        local suggestion=""

        # Show progress for current app
        local brew_tag=""
        [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
        if [[ -t 1 ]]; then
            if [[ ${#app_details[@]} -gt 1 ]]; then
                start_inline_spinner "[$current_index/${#app_details[@]}] Uninstalling ${app_name}${brew_tag}..."
            else
                start_inline_spinner "Uninstalling ${app_name}${brew_tag}..."
            fi
        fi

        # Stop Launch Agents/Daemons before removal.
        local has_system_files="false"
        [[ -n "$system_files" ]] && has_system_files="true"

        stop_launch_services "$bundle_id" "$has_system_files"

        # Remove from Login Items
        remove_login_item "$app_name" "$bundle_id"

        if ! force_kill_app "$app_name" "$app_path"; then
            reason="still running"
        fi

        # Remove the application only if not running.
        # Stop spinner before any removal attempt (avoids mixed output on errors)
        [[ -t 1 ]] && stop_inline_spinner

        local used_brew_successfully=false
        if [[ -z "$reason" ]]; then
            if [[ "$is_brew_cask" == "true" && -n "$cask_name" ]]; then
                # Use brew_uninstall_cask helper (handles env vars, timeout, verification)
                if brew_uninstall_cask "$cask_name" "$app_path"; then
                    used_brew_successfully=true
                else
                    # Fallback to manual removal if brew fails
                    if [[ "$needs_sudo" == true ]]; then
                        if ! safe_sudo_remove "$app_path"; then
                            reason="brew failed, manual removal failed"
                        fi
                    else
                        if ! safe_remove "$app_path" true; then
                            reason="brew failed, manual removal failed"
                        fi
                    fi
                fi
            elif [[ "$needs_sudo" == true ]]; then
                if [[ -L "$app_path" ]]; then
                    local link_target
                    link_target=$(readlink "$app_path" 2> /dev/null)
                    if [[ -n "$link_target" ]]; then
                        local resolved_target="$link_target"
                        if [[ "$link_target" != /* ]]; then
                            local link_dir
                            link_dir=$(dirname "$app_path")
                            resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") 2> /dev/null || echo ""
                        fi
                        case "$resolved_target" in
                            /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/* | /private/etc/*)
                                reason="protected system symlink, cannot remove"
                                ;;
                            *)
                                if ! safe_remove_symlink "$app_path" "true"; then
                                    reason="failed to remove symlink"
                                fi
                                ;;
                        esac
                    else
                        if ! safe_remove_symlink "$app_path" "true"; then
                            reason="failed to remove symlink"
                        fi
                    fi
                else
                    local ret=0
                    safe_sudo_remove "$app_path" || ret=$?
                    if [[ $ret -ne 0 ]]; then
                        local diagnosis
                        diagnosis=$(diagnose_removal_failure "$ret" "$app_name")
                        IFS='|' read -r reason suggestion <<< "$diagnosis"
                    fi
                fi
            else
                if ! safe_remove "$app_path" true; then
                    if [[ ! -w "$(dirname "$app_path")" ]]; then
                        reason="parent directory not writable"
                    else
                        reason="remove failed, check permissions"
                    fi
                fi
            fi
        fi

        # Remove related files if app removal succeeded.
        if [[ -z "$reason" ]]; then
            remove_file_list "$related_files" "false" > /dev/null

            if [[ "$used_brew_successfully" == "true" ]]; then
                remove_file_list "$diag_system" "true" > /dev/null
            else
                local system_all="$system_files"
                if [[ -n "$diag_system" ]]; then
                    if [[ -n "$system_all" ]]; then
                        system_all+=$'\n'
                    fi
                    system_all+="$diag_system"
                fi
                remove_file_list "$system_all" "true" > /dev/null
            fi

            # Clean up macOS defaults (preference domains).
            if [[ -n "$bundle_id" && "$bundle_id" != "unknown" ]]; then
                if defaults read "$bundle_id" &> /dev/null; then
                    defaults delete "$bundle_id" 2> /dev/null || true
                fi

                # ByHost preferences (machine-specific).
                if [[ -d "$HOME/Library/Preferences/ByHost" ]]; then
                    if [[ "$bundle_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
                        while IFS= read -r -d '' plist_file; do
                            safe_remove "$plist_file" true > /dev/null || true
                        done < <(command find "$HOME/Library/Preferences/ByHost" -maxdepth 1 -type f -name "${bundle_id}.*.plist" -print0 2> /dev/null || true)
                    else
                        debug_log "Skipping ByHost cleanup, invalid bundle id: $bundle_id"
                    fi
                fi
            fi

            # Show success
            if [[ -t 1 ]]; then
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    echo -e "${GREEN}✓${NC} [$current_index/${#app_details[@]}] ${app_name}"
                else
                    echo -e "${GREEN}✓${NC} ${app_name}"
                fi
            fi

            ((total_size_freed += total_kb))
            ((success_count++))
            [[ "$used_brew_successfully" == "true" ]] && ((brew_apps_removed++))
            ((files_cleaned++))
            ((total_items++))
            success_items+=("$app_path")
        else
            if [[ -t 1 ]]; then
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    echo -e "${ICON_ERROR} [$current_index/${#app_details[@]}] ${app_name} ${GRAY}, $reason${NC}"
                else
                    echo -e "${ICON_ERROR} ${app_name} failed: $reason"
                fi
                if [[ -n "${suggestion:-}" ]]; then
                    echo -e "${GRAY}   → ${suggestion}${NC}"
                fi
            fi

            ((failed_count++))
            failed_items+=("$app_name:$reason:${suggestion:-}")
        fi
    done

    # Summary
    local freed_display
    freed_display=$(bytes_to_human "$((total_size_freed * 1024))")

    local summary_status="success"
    local -a summary_details=()

    if [[ $success_count -gt 0 ]]; then
        local success_text="app"
        [[ $success_count -gt 1 ]] && success_text="apps"
        local success_line="Removed ${success_count} ${success_text}"
        if [[ -n "$freed_display" ]]; then
            success_line+=", freed ${GREEN}${freed_display}${NC}"
        fi

        # Format app list with max 3 per line.
        if [[ ${#success_items[@]} -gt 0 ]]; then
            local idx=0
            local is_first_line=true
            local current_line=""

            for success_path in "${success_items[@]}"; do
                local display_name
                display_name=$(basename "$success_path" .app)
                local display_item="${GREEN}${display_name}${NC}"

                if ((idx % 3 == 0)); then
                    if [[ -n "$current_line" ]]; then
                        summary_details+=("$current_line")
                    fi
                    if [[ "$is_first_line" == true ]]; then
                        current_line="${success_line}: $display_item"
                        is_first_line=false
                    else
                        current_line="$display_item"
                    fi
                else
                    current_line="$current_line, $display_item"
                fi
                ((idx++))
            done
            if [[ -n "$current_line" ]]; then
                summary_details+=("$current_line")
            fi
        else
            summary_details+=("$success_line")
        fi
    fi

    if [[ $failed_count -gt 0 ]]; then
        summary_status="warn"

        local failed_names=()
        for item in "${failed_items[@]}"; do
            local name=${item%%:*}
            failed_names+=("$name")
        done
        local failed_list="${failed_names[*]}"

        local reason_summary="could not be removed"
        local suggestion_text=""
        if [[ $failed_count -eq 1 ]]; then
            # Extract reason and suggestion from format: app:reason:suggestion
            local item="${failed_items[0]}"
            local without_app="${item#*:}"
            local first_reason="${without_app%%:*}"
            local first_suggestion="${without_app#*:}"

            # If suggestion is same as reason, there was no suggestion part
            # Also check if suggestion is empty
            if [[ "$first_suggestion" != "$first_reason" && -n "$first_suggestion" ]]; then
                suggestion_text="${GRAY}   → ${first_suggestion}${NC}"
            fi

            case "$first_reason" in
                still*running*) reason_summary="is still running" ;;
                remove*failed*) reason_summary="could not be removed" ;;
                permission*denied*) reason_summary="permission denied" ;;
                owned*by*) reason_summary="$first_reason, try with sudo" ;;
                *) reason_summary="$first_reason" ;;
            esac
        fi
        summary_details+=("Failed: ${RED}${failed_list}${NC} ${reason_summary}")
        if [[ -n "$suggestion_text" ]]; then
            summary_details+=("$suggestion_text")
        fi
    fi

    if [[ $success_count -eq 0 && $failed_count -eq 0 ]]; then
        summary_status="info"
        summary_details+=("No applications were uninstalled.")
    fi

    local title="Uninstall complete"
    if [[ "$summary_status" == "warn" ]]; then
        title="Uninstall incomplete"
    fi

    echo ""
    print_summary_block "$title" "${summary_details[@]}"
    printf '\n'

    # Auto-run brew autoremove if Homebrew casks were uninstalled
    if [[ $brew_apps_removed -gt 0 ]]; then
        # Show spinner while checking for orphaned dependencies
        if [[ -t 1 ]]; then
            start_inline_spinner "Checking brew dependencies..."
        fi

        local autoremove_output removed_count
        autoremove_output=$(HOMEBREW_NO_ENV_HINTS=1 brew autoremove 2> /dev/null) || true
        removed_count=$(printf '%s\n' "$autoremove_output" | grep -c "^Uninstalling" || true)
        removed_count=${removed_count:-0}

        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi

        if [[ $removed_count -gt 0 ]]; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Cleaned $removed_count orphaned brew dependencies"
            echo ""
        fi
    fi

    # Clean up Dock entries for uninstalled apps.
    if [[ $success_count -gt 0 && ${#success_items[@]} -gt 0 ]]; then
        remove_apps_from_dock "${success_items[@]}" 2> /dev/null || true
    fi

    _cleanup_sudo_keepalive

    # Disable uninstall mode
    unset MOLE_UNINSTALL_MODE

    _restore_uninstall_traps
    unset -f _restore_uninstall_traps

    ((total_size_cleaned += total_size_freed))
    unset failed_items
}
