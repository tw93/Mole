#!/bin/bash
# Purge paths management functionality
# Opens config file for editing and shows current status

set -euo pipefail

# Get script directory and source dependencies
_MOLE_MANAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MOLE_MANAGE_DIR/../core/common.sh"
# Only source project.sh if not already loaded (has readonly vars)
if [[ -z "${PURGE_TARGETS:-}" ]]; then
    source "$_MOLE_MANAGE_DIR/../clean/project.sh"
fi

# Config file path (prefer the shared project constant when available)
PURGE_PATHS_CONFIG="${PURGE_PATHS_CONFIG:-${PURGE_CONFIG_FILE:-$HOME/.config/mole/purge_paths}}"

# Ensure config file exists with helpful template
ensure_config_template() {
    if [[ ! -f "$PURGE_PATHS_CONFIG" ]]; then
        if ! write_purge_config "# Mole Purge Paths - Directories to scan for project artifacts
# Add one path per line (supports ~ for home directory)
# Delete all paths to use defaults
#
# Example:
# ~/Documents/MyProjects
# ~/Work/ClientA
# ~/Work/ClientB
"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Could not initialize $(mole_tilde_path "$PURGE_PATHS_CONFIG")" >&2
        fi
    fi
}

# Main management function
manage_purge_paths() {
    ensure_config_template

    local display_config
    display_config=$(mole_tilde_path "$PURGE_PATHS_CONFIG")

    # Clear screen
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi

    echo -e "${PURPLE_BOLD}Purge Paths Configuration${NC}"
    echo ""

    # Show current status
    echo -e "${YELLOW}Current Scan Paths:${NC}"

    # Reload config
    load_purge_config

    if [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]]; then
        for path in "${PURGE_SEARCH_PATHS[@]}"; do
            local display_path
            display_path=$(mole_tilde_path "$path")
            if [[ -d "$path" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $display_path"
            else
                echo -e "  ${GRAY}${ICON_EMPTY}${NC} $display_path${GRAY}, not found${NC}"
            fi
        done
    fi

    # Check if using custom config
    local custom_count=0
    if [[ -f "$PURGE_PATHS_CONFIG" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            custom_count=$((custom_count + 1))
        done < "$PURGE_PATHS_CONFIG"
    fi

    echo ""
    if [[ $custom_count -gt 0 ]]; then
        echo -e "${GRAY}Using custom config with $custom_count paths${NC}"
        local -a missing_defaults=()
        local default_path resolved_default configured_path already_configured
        for default_path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
            [[ -d "$default_path" ]] || continue
            resolved_default=$(mole_purge_resolve_path_case "$default_path")
            already_configured=false
            for configured_path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
                if [[ "$resolved_default" == "$configured_path" ]]; then
                    already_configured=true
                    break
                fi
            done
            [[ "$already_configured" == "true" ]] && continue
            missing_defaults+=("$default_path")
        done
        if [[ ${#missing_defaults[@]} -gt 0 ]]; then
            echo ""
            echo -e "${YELLOW}Unconfigured Default Paths Found:${NC}"
            for path in "${missing_defaults[@]}"; do
                echo -e "  ${CYAN}+${NC} $(mole_tilde_path "$path")"
            done
        fi
    else
        echo -e "${GRAY}Using ${#DEFAULT_PURGE_SEARCH_PATHS[@]} default paths${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Default Paths:${NC}"
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        echo -e "  ${GRAY}-${NC} $(mole_tilde_path "$path")"
    done

    echo ""
    echo -e "${YELLOW}Config File:${NC} $display_config"
    echo ""

    # Open in editor
    local editor="${EDITOR:-${VISUAL:-vim}}"
    echo -e "Opening in ${CYAN}$editor${NC}..."
    echo -e "${GRAY}Save and exit to apply changes. Leave empty to use defaults.${NC}"
    echo ""

    # Wait for user to read
    sleep 1

    # Keep literal executable paths (including spaces) working. Otherwise,
    # interpret the user's editor command while passing the config only as data.
    if command -v "$editor" > /dev/null 2>&1; then
        "$editor" "$PURGE_PATHS_CONFIG" || return $?
    else
        /bin/bash -c "$editor \"\$@\"" mole-editor "$PURGE_PATHS_CONFIG" || return $?
    fi

    # Reload and show updated status
    load_purge_config

    echo ""
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Configuration updated"
    echo -e "${GRAY}Run 'mo purge' to clean with new paths${NC}"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_purge_paths
fi
