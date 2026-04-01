#!/bin/bash
# Dev Environment Checks Module
# Surfaces developer-relevant system health information.

# ============================================================================
# Helper Functions
# ============================================================================

_extract_major_minor() {
    printf '%s' "$1" | sed -E 's/^[^0-9]*//' | grep -oE '^[0-9]+\.[0-9]+'
}

# ============================================================================
# Dev Environment Checks
# ============================================================================

check_launch_agents() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_launch_agents"; then return; fi

    local agents_dir="$HOME/Library/LaunchAgents"

    if [[ ! -d "$agents_dir" ]]; then
        echo -e "  ${GREEN}✓${NC} Launch Agents All healthy"
        return
    fi

    local broken_count=0
    local -a broken_labels=()

    for plist in "$agents_dir"/*.plist; do
        [[ -f "$plist" ]] || continue

        local label
        label=$(basename "$plist" .plist)

        local binary=""
        binary=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist" 2> /dev/null || true)
        if [[ -z "$binary" ]]; then
            binary=$(/usr/libexec/PlistBuddy -c "Print :Program" "$plist" 2> /dev/null || true)
        fi

        if [[ -n "$binary" && ! -e "$binary" ]]; then
            broken_count=$((broken_count + 1))
            broken_labels+=("$label")
        fi
    done

    if [[ $broken_count -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Launch Agents All healthy"
    else
        printf "  ${GRAY}%s${NC} %-14s ${YELLOW}%s${NC}\n" "$ICON_WARNING" "Launch Agents" "${broken_count} broken"

        local preview_limit=3
        ((preview_limit > broken_count)) && preview_limit=$broken_count

        local detail=""
        for ((i = 0; i < preview_limit; i++)); do
            if [[ $i -eq 0 ]]; then
                detail="${broken_labels[$i]}"
            else
                detail="${detail}, ${broken_labels[$i]}"
            fi
        done

        if ((broken_count > preview_limit)); then
            local remaining=$((broken_count - preview_limit))
            detail="${detail} +${remaining}"
        fi

        echo -e "    ${GRAY}${detail}${NC}"
    fi
}

check_dev_tools() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_dev_tools"; then return; fi

    local -a tools=(git node python3 brew docker go xcode-select)
    local -a missing=()

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Dev Tools      All present"
    else
        local missing_list
        missing_list=$(printf '%s, ' "${missing[@]}")
        missing_list="${missing_list%, }"
        printf "  ${GRAY}%s${NC} %-14s ${YELLOW}%s${NC}\n" "$ICON_WARNING" "Dev Tools" "${#missing[@]} not found (${missing_list})"
    fi
}

check_version_mismatches() {
    # Check whitelist
    if command -v is_whitelisted > /dev/null && is_whitelisted "check_version_mismatches"; then return; fi

    local -a conflicts=()

    # Check psql client vs postgres server
    if command -v psql > /dev/null 2>&1 && command -v postgres > /dev/null 2>&1; then
        local psql_ver postgres_ver
        psql_ver=$(_extract_major_minor "$(psql --version 2> /dev/null || true)")
        postgres_ver=$(_extract_major_minor "$(postgres --version 2> /dev/null || true)")
        if [[ -n "$psql_ver" && -n "$postgres_ver" && "$psql_ver" != "$postgres_ver" ]]; then
            conflicts+=("psql ${psql_ver} vs server ${postgres_ver}")
        fi
    fi

    # Check node vs nvm default
    local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    if command -v node > /dev/null 2>&1 && [[ -f "$nvm_sh" ]]; then
        local node_ver nvm_default_ver
        node_ver=$(_extract_major_minor "$(node --version 2> /dev/null || true)")
        nvm_default_ver=$(bash -c "source \"$nvm_sh\" 2>/dev/null && nvm version default 2>/dev/null" || true)
        nvm_default_ver=$(_extract_major_minor "$nvm_default_ver")
        if [[ -n "$node_ver" && -n "$nvm_default_ver" && "$node_ver" != "$nvm_default_ver" ]]; then
            conflicts+=("node ${node_ver} vs nvm default ${nvm_default_ver}")
        fi
    fi

    # Check python3 vs pyenv
    if command -v python3 > /dev/null 2>&1 && command -v pyenv > /dev/null 2>&1; then
        local python_ver pyenv_ver
        python_ver=$(_extract_major_minor "$(python3 --version 2> /dev/null || true)")
        pyenv_ver=$(pyenv version 2> /dev/null | awk '{print $1}' || true)
        if [[ -n "$pyenv_ver" && "$pyenv_ver" != "system" ]]; then
            pyenv_ver=$(_extract_major_minor "$pyenv_ver")
            if [[ -n "$python_ver" && -n "$pyenv_ver" && "$python_ver" != "$pyenv_ver" ]]; then
                conflicts+=("python3 ${python_ver} vs pyenv ${pyenv_ver}")
            fi
        fi
    fi

    if [[ ${#conflicts[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Versions       No conflicts"
    else
        local description
        description=$(printf '%s; ' "${conflicts[@]}")
        description="${description%; }"
        printf "  ${GRAY}%s${NC} %-14s ${YELLOW}%s${NC}\n" "$ICON_WARNING" "Versions" "$description"
    fi
}

check_all_dev_environment() {
    echo -e "${BLUE}${ICON_ARROW}${NC} Dev Environment"
    check_launch_agents
    check_dev_tools
    check_version_mismatches
}
