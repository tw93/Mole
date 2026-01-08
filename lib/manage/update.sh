#!/bin/bash
# Update Manager
# Unified update execution for all update types

set -euo pipefail

# Format Homebrew update label for display
format_brew_update_label() {
    local total="${BREW_OUTDATED_COUNT:-0}"
    if [[ -z "$total" || "$total" -le 0 ]]; then
        return
    fi

    local -a details=()
    local formulas="${BREW_FORMULA_OUTDATED_COUNT:-0}"
    local casks="${BREW_CASK_OUTDATED_COUNT:-0}"

    ((formulas > 0)) && details+=("${formulas} formula")
    ((casks > 0)) && details+=("${casks} cask")

    local detail_str="(${total} updates)"
    if ((${#details[@]} > 0)); then
        detail_str="($(
            IFS=', '
            printf '%s' "${details[*]}"
        ))"
    fi
    printf "  • Homebrew %s" "$detail_str"
}

brew_has_outdated() {
    local kind="${1:-formula}"
    command -v brew > /dev/null 2>&1 || return 1

    if [[ "$kind" == "cask" ]]; then
        brew outdated --cask --quiet 2> /dev/null | grep -q .
    else
        brew outdated --quiet 2> /dev/null | grep -q .
    fi
}

# Ask user if they want to update
# Returns: 0 if yes, 1 if no
ask_for_updates() {
    local has_updates=false
    local -a update_list=()

    local brew_entry
    brew_entry=$(format_brew_update_label || true)
    if [[ -n "$brew_entry" ]]; then
        has_updates=true
        update_list+=("$brew_entry")
    fi

    if [[ -n "${APPSTORE_UPDATE_COUNT:-}" && "${APPSTORE_UPDATE_COUNT:-0}" -gt 0 ]]; then
        has_updates=true
        update_list+=("  • App Store (${APPSTORE_UPDATE_COUNT} apps)")
    fi

    if [[ -n "${MACOS_UPDATE_AVAILABLE:-}" && "${MACOS_UPDATE_AVAILABLE}" == "true" ]]; then
        has_updates=true
        update_list+=("  • macOS system")
    fi

    if [[ -n "${MOLE_UPDATE_AVAILABLE:-}" && "${MOLE_UPDATE_AVAILABLE}" == "true" ]]; then
        has_updates=true
        update_list+=("  • Mole")
    fi

    if [[ "$has_updates" == "false" ]]; then
        return 1
    fi

    echo -e "${BLUE}AVAILABLE UPDATES${NC}"
    for item in "${update_list[@]}"; do
        echo -e "$item"
    done
    echo ""
    # If only Mole is relevant for automation, prompt just for Mole
    if [[ "${MOLE_UPDATE_AVAILABLE:-}" == "true" ]]; then
        echo ""
        echo -ne "${YELLOW}Update Mole now?${NC} ${GRAY}Enter confirm / ESC cancel${NC}: "

        local key
        if ! key=$(read_key); then
            echo "skip"
            echo ""
            return 1
        fi

        if [[ "$key" == "ENTER" ]]; then
            echo "yes"
            echo ""
            return 0
        fi
    fi

    echo ""
    echo -e "${YELLOW}💡 Run ${GREEN}brew upgrade${YELLOW} to update${NC}"

    return 1
}

# Perform all pending updates
# Returns: 0 if all succeeded, 1 if some failed
perform_updates() {
    # Only handle Mole updates here; Homebrew/App Store/macOS are manual (tips shown in ask_for_updates)
    local updated_count=0
    local total_count=0

    if [[ -n "${MOLE_UPDATE_AVAILABLE:-}" && "${MOLE_UPDATE_AVAILABLE}" == "true" ]]; then
        echo -e "${BLUE}Updating Mole...${NC}"
        local mole_bin="${SCRIPT_DIR}/../../mole"
        [[ ! -f "$mole_bin" ]] && mole_bin=$(command -v mole 2> /dev/null || echo "")

        if [[ -x "$mole_bin" ]]; then
            if "$mole_bin" update 2>&1 | grep -qE "(Updated|latest version)"; then
                echo -e "${GREEN}✓${NC} Mole updated"
                reset_mole_cache
                ((updated_count++))
            else
                echo -e "${RED}✗${NC} Mole update failed"
            fi
        else
            echo -e "${RED}✗${NC} Mole executable not found"
        fi
        echo ""
        total_count=1
    fi

    if [[ $total_count -eq 0 ]]; then
        echo -e "${GRAY}No updates to perform${NC}"
        return 0
    elif [[ $updated_count -eq $total_count ]]; then
        echo -e "${GREEN}All updates completed (${updated_count}/${total_count})${NC}"
        return 0
    else
        echo -e "${RED}Update failed (${updated_count}/${total_count})${NC}"
        return 1
    fi
}
