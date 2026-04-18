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

    ((formulas > 0)) && details+=("${formulas} ${TR_CHK_HB_FORMULA:-formula}")
    ((casks > 0)) && details+=("${casks} ${TR_CHK_HB_CASK:-cask}")

    local detail_str="${total} ${TR_UPD_UPDATES:-updates}"
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
    [[ -n "$detail" ]] && printf "${TR_UPD_BREW_LABEL_FMT:-Homebrew, %s}" "$detail"
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

    if [[ -n "${MOLE_UPDATE_AVAILABLE:-}" && "${MOLE_UPDATE_AVAILABLE}" == "true" ]]; then
        has_updates=true
    fi

    if [[ "$has_updates" == "false" ]]; then
        return 1
    fi

    if [[ "${MOLE_UPDATE_AVAILABLE:-}" == "true" ]]; then
        echo -ne "${YELLOW}${TR_UPD_MOLE_PROMPT:-Update Mole now?}${NC} ${GRAY}${TR_UPD_CONFIRM:-Enter confirm / ESC cancel}${NC}: "

        local key
        if ! key=$(read_key); then
            echo "${TR_UPD_SKIP:-skip}"
            return 1
        fi

        if [[ "$key" == "ENTER" ]]; then
            echo "${TR_UPD_YES:-yes}"
            return 0
        fi
    fi

    if [[ -n "${BREW_OUTDATED_COUNT:-}" && "${BREW_OUTDATED_COUNT:-0}" -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${TR_UPD_BREW_HINT:-Run ${GREEN}brew upgrade${NC} to update}"
    fi
    if [[ -n "${MACOS_UPDATE_AVAILABLE:-}" && "${MACOS_UPDATE_AVAILABLE}" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${TR_UPD_MACOS_HINT:-Open ${GREEN}System Settings${NC} → ${GREEN}General${NC} → ${GREEN}Software Update${NC}}"
    fi
    if [[ -n "${APPSTORE_UPDATE_COUNT:-}" && "${APPSTORE_UPDATE_COUNT:-0}" -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} ${TR_UPD_APPSTORE_HINT:-Open ${GREEN}App Store${NC} → ${GREEN}Updates${NC}}"
    fi

    return 1
}

# Perform all pending updates
# Returns: 0 if all succeeded, 1 if some failed
perform_updates() {
    # Only handle Mole updates here; Homebrew/App Store/macOS are manual (tips shown in ask_for_updates)
    local updated_count=0
    local total_count=0

    if [[ -n "${MOLE_UPDATE_AVAILABLE:-}" && "${MOLE_UPDATE_AVAILABLE}" == "true" ]]; then
        echo -e "${BLUE}${TR_UPD_UPDATING_MOLE:-Updating Mole...}${NC}"
        local mole_bin="${SCRIPT_DIR}/../../mole"
        [[ ! -f "$mole_bin" ]] && mole_bin=$(command -v mole 2> /dev/null || echo "")

        if [[ -x "$mole_bin" ]]; then
            if "$mole_bin" update 2>&1 | grep -qE "(Updated|latest version)"; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} ${TR_UPD_MOLE_UPDATED:-Mole updated}"
                reset_mole_cache
                updated_count=$((updated_count + 1))
            else
                echo -e "${RED}✗${NC} ${TR_UPD_MOLE_FAIL:-Mole update failed}"
            fi
        else
            echo -e "${RED}✗${NC} ${TR_UPD_MOLE_NOT_FOUND:-Mole executable not found}"
        fi
        echo ""
        total_count=1
    fi

    if [[ $total_count -eq 0 ]]; then
        echo -e "${GRAY}${TR_UPD_NONE:-No updates to perform}${NC}"
        return 0
    elif [[ $updated_count -eq $total_count ]]; then
        echo -e "${GREEN}${TR_UPD_ALL_COMPLETE:-All updates completed}, ${updated_count}/${total_count}${NC}"
        return 0
    else
        echo -e "${RED}${TR_UPD_FAIL:-Update failed}, ${updated_count}/${total_count}${NC}"
        return 1
    fi
}
