#!/bin/bash
# Whitelist management functionality
# Shows actual files that would be deleted by dry-run

set -euo pipefail

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/paginated_menu.sh"

# Config file path
WHITELIST_CONFIG="$HOME/.config/mole/whitelist"

declare -a DEFAULT_WHITELIST_PATTERNS=(
    "$HOME/Library/Caches/ms-playwright*"
    "$HOME/.cache/huggingface*"
)

patterns_equivalent() {
    local first="${1/#~/$HOME}"
    local second="${2/#~/$HOME}"

    # Only exact string match, no glob expansion
    [[ "$first" == "$second" ]] && return 0
    return 1
}

is_default_pattern() {
    local candidate="$1"
    local default_pat
    for default_pat in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
        if patterns_equivalent "$candidate" "$default_pat"; then
            return 0
        fi
    done
    return 1
}

# Run dry-run cleanup and collect what would be deleted
collect_files_to_be_cleaned() {
    local clean_sh="$SCRIPT_DIR/../bin/clean.sh"
    local -a items=()

    if [[ -t 1 ]]; then
        start_inline_spinner "Scanning cache files..."
    else
        echo "Scanning cache files..."
    fi

    # Run clean.sh in dry-run mode
    local temp_output=$(create_temp_file)
    echo "" | bash "$clean_sh" --dry-run 2>&1 > "$temp_output" || true

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    echo ""

    # Strip ANSI color codes for parsing
    local temp_plain=$(create_temp_file)
    sed $'s/\033\[[0-9;]*m//g' "$temp_output" > "$temp_plain"

    # Parse output: "  → Description (size, dry)"
    local pattern='^[[:space:]]*→[[:space:]]+([^(]+)(\([^)]+\))?[[:space:]]*\(([^,)]+),.*dry\)$'
    while IFS= read -r line; do
        if [[ "$line" =~ $pattern ]]; then
            local description="${BASH_REMATCH[1]}"
            local size="${BASH_REMATCH[3]}"

            description="${description#${description%%[![:space:]]*}}"
            description="${description%${description##*[![:space:]]}}"

            [[ "$description" =~ ^Orphaned ]] && continue

            # Find corresponding path from clean.sh
            local path=""
            while IFS= read -r src_line; do
                # Match: safe_clean <path> "<description>"
                # Path may contain escaped spaces (\ )
                if [[ "$src_line" =~ safe_clean[[:space:]]+(.+)[[:space:]]+\"$description\" ]]; then
                    path="${BASH_REMATCH[1]}"
                    break
                fi
            done < "$clean_sh"

            path="${path/#\~/$HOME}"
            [[ -z "$path" || "$path" =~ \$ ]] && continue

            items+=("$path|$description|$size")
        fi
    done < "$temp_plain"

    # Temp files will be auto-cleaned by cleanup_temp_files

    # Return early if no items found
    if [[ ${#items[@]} -eq 0 ]]; then
        AVAILABLE_CACHE_ITEMS=()
        return
    fi

    # Remove duplicates
    local -a unique_items=()
    local -a seen_descriptions=()

    for item in "${items[@]}"; do
        IFS='|' read -r path desc size <<< "$item"
        local is_duplicate=false
        if [[ ${#seen_descriptions[@]} -gt 0 ]]; then
            for seen in "${seen_descriptions[@]}"; do
                [[ "$desc" == "$seen" ]] && is_duplicate=true && break
            done
        fi

        if [[ "$is_duplicate" == "false" ]]; then
            unique_items+=("$item")
            seen_descriptions+=("$desc")
        fi
    done

    # Sort by size (largest first)
    local -a sorted_items=()
    if [[ ${#unique_items[@]} -gt 0 ]]; then
        while IFS= read -r item; do
            sorted_items+=("$item")
        done < <(
            for item in "${unique_items[@]}"; do
                IFS='|' read -r path desc size <<< "$item"
                local size_kb=0
                if [[ "$size" =~ ([0-9.]+)GB ]]; then
                    size_kb=$(echo "${BASH_REMATCH[1]}" | awk '{printf "%d", $1 * 1024 * 1024}')
                elif [[ "$size" =~ ([0-9.]+)MB ]]; then
                    size_kb=$(echo "${BASH_REMATCH[1]}" | awk '{printf "%d", $1 * 1024}')
                elif [[ "$size" =~ ([0-9.]+)KB ]]; then
                    size_kb=$(echo "${BASH_REMATCH[1]}" | awk '{printf "%d", $1}')
                fi
                printf "%010d|%s\n" "$size_kb" "$item"
            done | sort -rn | cut -d'|' -f2-
        )
    fi

    # Safe assignment for empty array
    if [[ ${#sorted_items[@]} -gt 0 ]]; then
        AVAILABLE_CACHE_ITEMS=("${sorted_items[@]}")
    else
        AVAILABLE_CACHE_ITEMS=()
    fi
}

declare -a AVAILABLE_CACHE_ITEMS=()

load_whitelist() {
    local -a patterns=()

    # Always include default patterns
    patterns=("${DEFAULT_WHITELIST_PATTERNS[@]}")

    # Add user-defined patterns from config file
    if [[ -f "$WHITELIST_CONFIG" ]]; then
        while IFS= read -r line; do
            line="${line#${line%%[![:space:]]*}}"
            line="${line%${line##*[![:space:]]}}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            patterns+=("$line")
        done < "$WHITELIST_CONFIG"
    fi

    if [[ ${#patterns[@]} -gt 0 ]]; then
        local -a unique_patterns=()
        for pattern in "${patterns[@]}"; do
            local duplicate="false"
            if [[ ${#unique_patterns[@]} -gt 0 ]]; then
                for existing in "${unique_patterns[@]}"; do
                    if patterns_equivalent "$pattern" "$existing"; then
                        duplicate="true"
                        break
                    fi
                done
            fi
            [[ "$duplicate" == "true" ]] && continue
            unique_patterns+=("$pattern")
        done
        CURRENT_WHITELIST_PATTERNS=("${unique_patterns[@]}")
    else
        CURRENT_WHITELIST_PATTERNS=()
    fi
}

is_whitelisted() {
    local pattern="$1"
    local check_pattern="${pattern/#\~/$HOME}"

    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -eq 0 ]]; then
        return 1
    fi

    for existing in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
        local existing_expanded="${existing/#\~/$HOME}"
        if [[ "$check_pattern" == "$existing_expanded" ]]; then
            return 0
        fi
        if [[ "$check_pattern" == $existing_expanded ]]; then
            return 0
        fi
    done
    return 1
}

format_whitelist_item() {
    local description="$1" size="$2" is_protected="$3"
    local desc_display="$description"
    [[ ${#description} -gt 40 ]] && desc_display="${description:0:37}..."
    local size_display=$(printf "%-15s" "$size")
    local status=""
    [[ "$is_protected" == "true" ]] && status=" ${GREEN}[Protected]${NC}"
    printf "%-40s %s%s" "$desc_display" "$size_display" "$status"
}

# Get friendly description for a path pattern
get_description_for_pattern() {
    local pattern="$1"
    local desc=""

    # Hardcoded descriptions for common patterns
    case "$pattern" in
        *"ms-playwright"*)
            echo "Playwright Browser"
            return
            ;;
        *"huggingface"*)
            echo "HuggingFace Model"
            return
            ;;
    esac

    # Try to match with safe_clean in clean.sh
    # Use fuzzy matching by removing trailing /* or *
    local pattern_base="${pattern%/\*}"
    pattern_base="${pattern_base%\*}"

    while IFS= read -r line; do
        if [[ "$line" =~ safe_clean[[:space:]]+(.+)[[:space:]]+\"([^\"]+)\" ]]; then
            local clean_path="${BASH_REMATCH[1]}"
            local clean_desc="${BASH_REMATCH[2]}"
            clean_path="${clean_path/#\~/$HOME}"

            # Remove trailing /* or * for comparison
            local clean_base="${clean_path%/\*}"
            clean_base="${clean_base%\*}"

            # Check if base paths match
            if [[ "$pattern_base" == "$clean_base" || "$clean_path" == "$pattern" || "$pattern" == "$clean_path" ]]; then
                echo "$clean_desc"
                return
            fi
        fi
    done < "$SCRIPT_DIR/../bin/clean.sh"

    # If no match found, return short path
    echo "${pattern/#$HOME/~}"
}

manage_whitelist() {
    clear
    echo ""
    echo -e "${PURPLE}Whitelist Manager${NC}"
    echo ""

    # Load user-defined whitelist
    CURRENT_WHITELIST_PATTERNS=()
    load_whitelist

    echo "Select the cache files that need to be protected"
    echo -e "${GRAY}Protected items are pre-selected. You can also edit ${WHITELIST_CONFIG} directly.${NC}"
    echo ""

    collect_files_to_be_cleaned

    # Add items from config that are not in the scan results
    local -a all_items=()
    if [[ ${#AVAILABLE_CACHE_ITEMS[@]} -gt 0 ]]; then
        all_items=("${AVAILABLE_CACHE_ITEMS[@]}")
    fi

    # Add saved patterns that are not in scan results
    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        for pattern in "${CURRENT_WHITELIST_PATTERNS[@]}"; do
            local pattern_expanded="${pattern/#\~/$HOME}"
            local found="false"

            if [[ ${#all_items[@]} -gt 0 ]]; then
                for item in "${all_items[@]}"; do
                    IFS='|' read -r path _ _ <<< "$item"
                    if patterns_equivalent "$path" "$pattern_expanded"; then
                        found="true"
                        break
                    fi
                done
            fi

            if [[ "$found" == "false" ]]; then
                local desc=$(get_description_for_pattern "$pattern_expanded")
                all_items+=("$pattern_expanded|$desc|0B")
            fi
        done
    fi

    if [[ ${#all_items[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} No cache files found - system is clean!"
        echo ""
        echo "Press any key to exit..."
        read -n 1 -s
        return 0
    fi

    # Update global array with all items
    AVAILABLE_CACHE_ITEMS=("${all_items[@]}")

    echo -e "${GREEN}✓${NC} Found ${#AVAILABLE_CACHE_ITEMS[@]} items"
    echo ""

    local -a menu_options=()
    local -a preselected_indices=()
    local index=0

    for item in "${AVAILABLE_CACHE_ITEMS[@]}"; do
        IFS='|' read -r path description size <<< "$item"
        local is_protected="false"
        if is_whitelisted "$path"; then
            is_protected="true"
            preselected_indices+=("$index")
        fi
        menu_options+=("$(format_whitelist_item "$description" "$size" "$is_protected")")
        ((index++))
    done

    echo -e "${GRAY}↑↓ Navigate | Space Toggle | Enter Save | Q Quit${NC}"

    if [[ ${#preselected_indices[@]} -gt 0 ]]; then
        local IFS=','
        MOLE_PRESELECTED_INDICES="${preselected_indices[*]}"
    else
        unset MOLE_PRESELECTED_INDICES
    fi

    MOLE_SELECTION_RESULT=""
    paginated_multi_select "Select items to protect" "${menu_options[@]}"
    unset MOLE_PRESELECTED_INDICES
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo -e "${YELLOW}Cancelled${NC} - No changes made"
        return 1
    fi

    local -a selected_indices=()
    if [[ -n "$MOLE_SELECTION_RESULT" ]]; then
        IFS=',' read -ra selected_indices <<< "$MOLE_SELECTION_RESULT"
    fi

    save_whitelist "${selected_indices[@]}"
}

save_whitelist() {
    local -a selected_indices=("$@")
    mkdir -p "$(dirname "$WHITELIST_CONFIG")"

    local -a selected_patterns=()
    local selected_default_count=0
    local selected_custom_count=0

    for idx in "${selected_indices[@]}"; do
        if [[ $idx -ge 0 && $idx -lt ${#AVAILABLE_CACHE_ITEMS[@]} ]]; then
            local item="${AVAILABLE_CACHE_ITEMS[$idx]}"
            IFS='|' read -r path description size <<< "$item"
            local portable_path="${path/#$HOME/~}"

            local duplicate="false"
            if [[ ${#selected_patterns[@]} -gt 0 ]]; then
                for existing in "${selected_patterns[@]}"; do
                    if patterns_equivalent "$portable_path" "$existing"; then
                        duplicate="true"
                        break
                    fi
                done
            fi
            [[ "$duplicate" == "true" ]] && continue

            if is_default_pattern "$portable_path"; then
                ((selected_default_count++))
            else
                ((selected_custom_count++))
            fi

            selected_patterns+=("$portable_path")
        fi
    done

    cat > "$WHITELIST_CONFIG" << 'EOF'
# Mole Whitelist - Protected paths won't be deleted
# Default: Playwright browsers, HuggingFace models
EOF

    # Only save custom (non-default) patterns
    local -a custom_patterns=()
    for pattern in "${selected_patterns[@]}"; do
        if ! is_default_pattern "$pattern"; then
            custom_patterns+=("$pattern")
        fi
    done

    if [[ ${#custom_patterns[@]} -gt 0 ]]; then
        printf '\n' >> "$WHITELIST_CONFIG"
        for pattern in "${custom_patterns[@]}"; do
            echo "$pattern" >> "$WHITELIST_CONFIG"
        done
    fi

    local total_count=${#selected_patterns[@]}
    local -a summary_parts=()
    if [[ $selected_default_count -gt 0 ]]; then
        local default_label="default"
        [[ $selected_default_count -ne 1 ]] && default_label+="s"
        summary_parts+=("$selected_default_count $default_label")
    fi
    if [[ $selected_custom_count -gt 0 ]]; then
        local custom_label="custom"
        [[ $selected_custom_count -ne 1 ]] && custom_label+="s"
        summary_parts+=("$selected_custom_count $custom_label")
    fi

    local summary=""
    if [[ ${#summary_parts[@]} -gt 0 ]]; then
        summary=" (${summary_parts[0]}"
        for ((i = 1; i < ${#summary_parts[@]}; i++)); do
            summary+=", ${summary_parts[$i]}"
        done
        summary+=")"
    fi

    echo ""
    echo -e "${GREEN}✓${NC} Protected $total_count items${summary}"
    echo -e "${GRAY}Config: ${WHITELIST_CONFIG}${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_whitelist
fi
