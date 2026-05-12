#!/bin/bash
# Update Manager
# Unified update execution for all update types

set -euo pipefail

# Format Homebrew update details for display
format_brew_update_detail() {
    local total="${BREW_OUTDATED_COUNT:-0}"
    if [[ -z "$total" || "$total" -le 0 ]]; then
        return
    fi

    local -a details=()
    local formulas="${BREW_FORMULA_OUTDATED_COUNT:-0}"
    local casks="${BREW_CASK_OUTDATED_COUNT:-0}"

    ((formulas > 0)) && details+=("${formulas} formula")
    ((casks > 0)) && details+=("${casks} cask")

    local detail_str="${total} updates"
    if ((${#details[@]} > 0)); then
        detail_str="$(
            IFS=', '
            printf '%s' "${details[*]}"
        )"
    fi
    printf "%s" "$detail_str"
}

# Keep for compatibility with existing callers/tests.
format_brew_update_label() {
    local detail
    detail=$(format_brew_update_detail || true)
    [[ -n "$detail" ]] && printf "Homebrew, %s" "$detail"
}

populate_brew_update_counts_if_unset() {
    local need_probe=false
    [[ -z "${BREW_OUTDATED_COUNT:-}" ]] && need_probe=true
    [[ -z "${BREW_FORMULA_OUTDATED_COUNT:-}" ]] && need_probe=true
    [[ -z "${BREW_CASK_OUTDATED_COUNT:-}" ]] && need_probe=true

    if [[ "$need_probe" == "false" ]]; then
        return 0
    fi

    local formula_count="${BREW_FORMULA_OUTDATED_COUNT:-0}"
    local cask_count="${BREW_CASK_OUTDATED_COUNT:-0}"

    if command -v brew > /dev/null 2>&1; then
        local formula_outdated=""
        local cask_outdated=""

        formula_outdated=$(run_with_timeout 8 brew outdated --formula --quiet 2> /dev/null || true)
        cask_outdated=$(run_with_timeout 8 brew outdated --cask --quiet 2> /dev/null || true)

        formula_count=$(printf '%s\n' "$formula_outdated" | awk 'NF {count++} END {print count + 0}')
        cask_count=$(printf '%s\n' "$cask_outdated" | awk 'NF {count++} END {print count + 0}')
    fi

    BREW_FORMULA_OUTDATED_COUNT="$formula_count"
    BREW_CASK_OUTDATED_COUNT="$cask_count"
    BREW_OUTDATED_COUNT="$((formula_count + cask_count))"
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
    populate_brew_update_counts_if_unset

    local has_updates=false
    if [[ -n "${BREW_OUTDATED_COUNT:-}" && "${BREW_OUTDATED_COUNT:-0}" -gt 0 ]]; then
        has_updates=true
    fi

    if [[ -n "${APPSTORE_UPDATE_COUNT:-}" && "${APPSTORE_UPDATE_COUNT:-0}" -gt 0 ]]; then
        has_updates=true
    fi

    if [[ -n "${MACOS_UPDATE_AVAILABLE:-}" && "${MACOS_UPDATE_AVAILABLE}" == "true" ]]; then
        has_updates=true
    fi

    if [[ -n "${ROOMY_UPDATE_AVAILABLE:-}" && "${ROOMY_UPDATE_AVAILABLE}" == "true" ]]; then
        has_updates=true
    fi

    if [[ "$has_updates" == "false" ]]; then
        return 1
    fi

    if [[ "${ROOMY_UPDATE_AVAILABLE:-}" == "true" ]]; then
        echo -ne "${YELLOW}Update Roomy now?${NC} ${GRAY}Enter confirm / ESC cancel${NC}: "

        local key
        if ! key=$(read_key); then
            echo "skip"
            return 1
        fi

        if [[ "$key" == "ENTER" ]]; then
            echo "yes"
            return 0
        fi
    fi

    if [[ -n "${BREW_OUTDATED_COUNT:-}" && "${BREW_OUTDATED_COUNT:-0}" -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Run ${GREEN}brew upgrade${NC} to update"
    fi
    if [[ -n "${MACOS_UPDATE_AVAILABLE:-}" && "${MACOS_UPDATE_AVAILABLE}" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Open ${GREEN}System Settings${NC} → ${GREEN}General${NC} → ${GREEN}Software Update${NC}"
    fi
    if [[ -n "${APPSTORE_UPDATE_COUNT:-}" && "${APPSTORE_UPDATE_COUNT:-0}" -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Open ${GREEN}App Store${NC} → ${GREEN}Updates${NC}"
    fi

    return 1
}

# Perform all pending updates
# Returns: 0 if all succeeded, 1 if some failed
perform_updates() {
    # Only handle Roomy updates here; Homebrew/App Store/macOS are manual (tips shown in ask_for_updates)
    local updated_count=0
    local total_count=0

    if [[ -n "${ROOMY_UPDATE_AVAILABLE:-}" && "${ROOMY_UPDATE_AVAILABLE}" == "true" ]]; then
        echo -e "${BLUE}Updating Roomy...${NC}"
        local roomy_bin="${SCRIPT_DIR}/../../roomy"
        [[ ! -f "$roomy_bin" ]] && roomy_bin=$(command -v roomy 2> /dev/null || echo "")

        if [[ -x "$roomy_bin" ]]; then
            if "$roomy_bin" update 2>&1 | grep -qE "(Updated|latest version)"; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Roomy updated"
                reset_roomy_cache
                updated_count=$((updated_count + 1))
            else
                echo -e "${RED}✗${NC} Roomy update failed"
            fi
        else
            echo -e "${RED}✗${NC} Roomy executable not found"
        fi
        echo ""
        total_count=1
    fi

    if [[ $total_count -eq 0 ]]; then
        echo -e "${GRAY}No updates to perform${NC}"
        return 0
    elif [[ $updated_count -eq $total_count ]]; then
        echo -e "${GREEN}All updates completed, ${updated_count}/${total_count}${NC}"
        return 0
    else
        echo -e "${RED}Update failed, ${updated_count}/${total_count}${NC}"
        return 1
    fi
}
