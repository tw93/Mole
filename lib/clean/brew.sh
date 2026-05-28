#!/bin/bash
# Clean Homebrew caches and remove orphaned dependencies
# Env: DRY_RUN
# Skips if run within 7 days, runs cleanup/autoremove in parallel with 120s timeout
clean_homebrew_path_has_symlinked_component() {
    local path="$1"
    local home_path="${HOME%/}"
    local current="${path%/}"

    [[ -n "$current" ]] || return 1

    while [[ "$current" != "/" && "$current" != "." ]]; do
        if [[ -L "$current" ]]; then
            return 0
        fi
        if [[ -n "$home_path" && "$current" == "$home_path" ]]; then
            break
        fi

        local parent
        parent="$(dirname "$current")"
        [[ "$parent" == "$current" ]] && break
        current="$parent"
    done

    return 1
}

clean_homebrew() {
    command -v brew > /dev/null 2>&1 || return 0
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # Check if Homebrew cache is whitelisted
        if is_path_whitelisted "$HOME/Library/Caches/Homebrew"; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew · skipped whitelist"
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Homebrew · would cleanup and autoremove"
        fi
        return 0
    fi
    # Keep behavior consistent with dry-run preview.
    if is_path_whitelisted "$HOME/Library/Caches/Homebrew"; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew · skipped whitelist"
        return 0
    fi
    # Skip if cleaned recently to avoid repeated heavy operations.
    local brew_cache_file="${HOME}/.cache/roomy/brew_last_cleanup"
    local brew_cache_dir
    brew_cache_dir="$(dirname "$brew_cache_file")"
    local cache_valid_days=7
    local should_skip=false
    local brew_cache_redirected=false
    if clean_homebrew_path_has_symlinked_component "$brew_cache_dir"; then
        brew_cache_redirected=true
    fi
    if [[ "$brew_cache_redirected" == "false" && -f "$brew_cache_file" && ! -L "$brew_cache_file" ]]; then
        local last_cleanup
        last_cleanup=$(cat "$brew_cache_file" 2> /dev/null || echo "0")
        if [[ "$last_cleanup" =~ ^[0-9]+$ ]]; then
            local current_time
            current_time=$(get_epoch_seconds)
            if [[ "$current_time" =~ ^[0-9]+$ && $current_time -ge $last_cleanup ]]; then
                local time_diff=$((current_time - last_cleanup))
                local days_diff=$((time_diff / 86400))
                if [[ $days_diff -lt $cache_valid_days ]]; then
                    should_skip=true
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew · cleaned ${days_diff}d ago, skipped"
                fi
            fi
        fi
    fi
    [[ "$should_skip" == "true" ]] && return 0
    # Skip cleanup if cache is small; still run autoremove.
    local skip_cleanup=false
    local brew_cache_size=0
    if [[ -d ~/Library/Caches/Homebrew ]]; then
        brew_cache_size=$(run_with_timeout 3 du -skP ~/Library/Caches/Homebrew 2> /dev/null | awk '{print $1}')
        local du_exit=$?
        if [[ $du_exit -eq 0 && -n "$brew_cache_size" && "$brew_cache_size" -lt 51200 ]]; then
            skip_cleanup=true
        fi
    fi
    # Spinner reflects whether cleanup is skipped.
    if [[ -t 1 ]]; then
        if [[ "$skip_cleanup" == "true" ]]; then
            ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Homebrew autoremove (cleanup skipped)..."
        else
            ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Homebrew cleanup and autoremove..."
        fi
    fi
    # Run cleanup/autoremove in parallel with timeout guard per command.
    local timeout_seconds=120
    local brew_tmp_file autoremove_tmp_file
    local brew_pid autoremove_pid
    local brew_exit=0
    local autoremove_exit=0
    if [[ "$skip_cleanup" == "false" ]]; then
        brew_tmp_file=$(create_temp_file)
        run_with_timeout "$timeout_seconds" brew cleanup --prune=30 > "$brew_tmp_file" 2>&1 &
        brew_pid=$!
    fi
    autoremove_tmp_file=$(create_temp_file)
    run_with_timeout "$timeout_seconds" brew autoremove > "$autoremove_tmp_file" 2>&1 &
    autoremove_pid=$!

    if [[ -n "$brew_pid" ]]; then
        wait "$brew_pid" 2> /dev/null || brew_exit=$?
    fi
    wait "$autoremove_pid" 2> /dev/null || autoremove_exit=$?

    local brew_success=false
    if [[ "$skip_cleanup" == "false" && $brew_exit -eq 0 ]]; then
        brew_success=true
    fi
    local autoremove_success=false
    if [[ $autoremove_exit -eq 0 ]]; then
        autoremove_success=true
    fi
    if [[ -t 1 ]]; then stop_inline_spinner; fi
    # Process cleanup output and extract metrics
    # Summarize cleanup results.
    if [[ "$skip_cleanup" == "true" ]]; then
        # Cleanup was skipped due to small cache size
        local size_mb=$((brew_cache_size / 1024))
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup · cache ${size_mb}MB, skipped"
    elif [[ "$brew_success" == "true" && -f "$brew_tmp_file" ]]; then
        local brew_output
        brew_output=$(cat "$brew_tmp_file" 2> /dev/null || echo "")
        local removed_count freed_space
        removed_count=$(printf '%s\n' "$brew_output" | grep -c "Removing:" 2> /dev/null || true)
        freed_space=$(printf '%s\n' "$brew_output" | grep -o "[0-9.]*[KMGT]B freed" 2> /dev/null | tail -1 || true)
        if [[ $removed_count -gt 0 ]] || [[ -n "$freed_space" ]]; then
            if [[ -n "$freed_space" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup${NC}, ${GREEN}$freed_space${NC}"
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup, ${removed_count} items"
            fi
        fi
    elif [[ $brew_exit -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew cleanup timed out · run ${GRAY}brew cleanup${NC} manually"
    fi
    # Process autoremove output - only show if packages were removed
    # Only surface autoremove output when packages were removed.
    if [[ "$autoremove_success" == "true" && -f "$autoremove_tmp_file" ]]; then
        local autoremove_output
        autoremove_output=$(cat "$autoremove_tmp_file" 2> /dev/null || echo "")
        local removed_packages
        removed_packages=$(printf '%s\n' "$autoremove_output" | grep -c "^Uninstalling" 2> /dev/null || true)
        if [[ $removed_packages -gt 0 ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Removed orphaned dependencies, ${removed_packages} packages"
        fi
    elif [[ $autoremove_exit -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autoremove timed out · run ${GRAY}brew autoremove${NC} manually"
    fi
    # Update cache timestamp on successful completion or when cleanup was intelligently skipped
    # This prevents repeated cache size checks within the 7-day window
    # Update cache timestamp when any work succeeded or was intentionally skipped.
    if [[ "$skip_cleanup" == "true" ]] || [[ "$brew_success" == "true" ]] || [[ "$autoremove_success" == "true" ]]; then
        local brew_cache_tmp
        if [[ "$brew_cache_redirected" == "true" ]]; then
            debug_log "Skipping Homebrew cleanup timestamp through redirected cache path: $brew_cache_file"
        else
            ensure_user_dir "$brew_cache_dir"
            brew_cache_tmp=""
            if [[ -d "$brew_cache_dir" ]]; then
                brew_cache_tmp=$(mktemp "$brew_cache_dir/.brew_last_cleanup.XXXXXX" 2> /dev/null || true)
            fi
            if [[ -n "$brew_cache_tmp" ]]; then
                if get_epoch_seconds > "$brew_cache_tmp"; then
                    commit_staged_user_file "$brew_cache_tmp" "$brew_cache_file" || true
                else
                    rm -f "$brew_cache_tmp" 2> /dev/null || true
                fi
            fi
        fi
    fi
}
