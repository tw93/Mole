#!/bin/bash

# Clean Homebrew caches and remove orphaned dependencies
# Skips if run within 2 days, runs cleanup/autoremove in parallel with 120s timeout
# Env: MO_BREW_TIMEOUT, DRY_RUN
clean_homebrew() {
    command -v brew > /dev/null 2>&1 || return 0

    # Dry run mode - just indicate what would happen
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "  ${YELLOW}→${NC} Homebrew (would cleanup and autoremove)"
        return 0
    fi

    # Smart caching: check if brew cleanup was run recently (within 2 days)
    local brew_cache_file="${HOME}/.cache/mole/brew_last_cleanup"
    local cache_valid_days=2
    local should_skip=false

    if [[ -f "$brew_cache_file" ]]; then
        local last_cleanup
        last_cleanup=$(cat "$brew_cache_file" 2> /dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local time_diff=$((current_time - last_cleanup))
        local days_diff=$((time_diff / 86400))

        if [[ $days_diff -lt $cache_valid_days ]]; then
            should_skip=true
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew (cleaned ${days_diff}d ago, skipped)"
        fi
    fi

    [[ "$should_skip" == "true" ]] && return 0

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Homebrew cleanup and autoremove..."
    fi

    local timeout_seconds=${MO_BREW_TIMEOUT:-120}

    # Run brew cleanup and autoremove in parallel for performance
    local brew_tmp_file autoremove_tmp_file
    brew_tmp_file=$(create_temp_file)
    autoremove_tmp_file=$(create_temp_file)

    (brew cleanup > "$brew_tmp_file" 2>&1) &
    local brew_pid=$!

    (brew autoremove > "$autoremove_tmp_file" 2>&1) &
    local autoremove_pid=$!

    local elapsed=0
    local brew_done=false
    local autoremove_done=false

    # Wait for both to complete or timeout
    while [[ "$brew_done" == "false" ]] || [[ "$autoremove_done" == "false" ]]; do
        if [[ $elapsed -ge $timeout_seconds ]]; then
            kill -TERM $brew_pid $autoremove_pid 2> /dev/null || true
            break
        fi

        kill -0 $brew_pid 2> /dev/null || brew_done=true
        kill -0 $autoremove_pid 2> /dev/null || autoremove_done=true

        sleep 1
        ((elapsed++))
    done

    # Wait for processes to finish
    local brew_success=false
    if wait $brew_pid 2> /dev/null; then
        brew_success=true
    fi

    local autoremove_success=false
    if wait $autoremove_pid 2> /dev/null; then
        autoremove_success=true
    fi

    if [[ -t 1 ]]; then stop_inline_spinner; fi

    # Process cleanup output and extract metrics
    if [[ "$brew_success" == "true" && -f "$brew_tmp_file" ]]; then
        local brew_output
        brew_output=$(cat "$brew_tmp_file" 2> /dev/null || echo "")
        local removed_count freed_space
        removed_count=$(printf '%s\n' "$brew_output" | grep -c "Removing:" 2> /dev/null || true)
        freed_space=$(printf '%s\n' "$brew_output" | grep -o "[0-9.]*[KMGT]B freed" 2> /dev/null | tail -1 || true)

        if [[ $removed_count -gt 0 ]] || [[ -n "$freed_space" ]]; then
            if [[ -n "$freed_space" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup ${GREEN}($freed_space)${NC}"
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup (${removed_count} items)"
            fi
        fi
    elif [[ $elapsed -ge $timeout_seconds ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Homebrew cleanup timed out (run ${GRAY}brew cleanup${NC} manually)"
    fi

    # Process autoremove output - only show if packages were removed
    if [[ "$autoremove_success" == "true" && -f "$autoremove_tmp_file" ]]; then
        local autoremove_output
        autoremove_output=$(cat "$autoremove_tmp_file" 2> /dev/null || echo "")
        local removed_packages
        removed_packages=$(printf '%s\n' "$autoremove_output" | grep -c "^Uninstalling" 2> /dev/null || true)

        if [[ $removed_packages -gt 0 ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Removed orphaned dependencies (${removed_packages} packages)"
        fi
    elif [[ $elapsed -ge $timeout_seconds ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Autoremove timed out (run ${GRAY}brew autoremove${NC} manually)"
    fi

    # Update cache timestamp on successful completion
    if [[ "$brew_success" == "true" || "$autoremove_success" == "true" ]]; then
        ensure_user_file "$brew_cache_file"
        date +%s > "$brew_cache_file"
    fi
}
