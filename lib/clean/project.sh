#!/bin/bash
# Project Purge Module (mo purge)
# Removes heavy project build artifacts and dependencies

set -euo pipefail

# Targets to look for (heavy build artifacts)
readonly PURGE_TARGETS=(
    "node_modules"
    "target"        # Rust, Maven
    "build"         # Gradle, various
    "dist"          # JS builds
    "venv"          # Python
    ".venv"         # Python
    ".gradle"       # Gradle local
    "__pycache__"   # Python
    ".next"         # Next.js
    ".nuxt"         # Nuxt.js
    ".output"       # Nuxt.js
    "vendor"        # PHP Composer
    "obj"           # C# / Unity
    ".turbo"        # Turborepo cache
    ".parcel-cache" # Parcel bundler
)

# Minimum age in days before considering for cleanup
readonly MIN_AGE_DAYS=7

# Scan depth defaults (relative to search root)
readonly PURGE_MIN_DEPTH_DEFAULT=2
readonly PURGE_MAX_DEPTH_DEFAULT=8

# Search paths (only project directories)
readonly PURGE_SEARCH_PATHS=(
    "$HOME/www"
    "$HOME/dev"
    "$HOME/Projects"
    "$HOME/GitHub"
    "$HOME/Code"
    "$HOME/Workspace"
    "$HOME/Repos"
    "$HOME/Development"
)

# Check if path is safe to clean (must be inside a project directory)
# Args: $1 - path to check
is_safe_project_artifact() {
    local path="$1"
    local search_path="$2"

    # Path must be absolute
    if [[ "$path" != /* ]]; then
        return 1
    fi

    # Must not be a direct child of HOME directory
    # e.g., ~/.gradle is NOT safe, but ~/Projects/foo/.gradle IS safe
    local relative_path="${path#"$search_path"/}"
    local depth=$(echo "$relative_path" | tr -cd '/' | wc -c)

    # Require at least 1 level deep (inside a project folder)
    # e.g., ~/www/weekly/node_modules is OK (depth >= 1)
    # but ~/www/node_modules is NOT OK (depth < 1)
    if [[ $depth -lt 1 ]]; then
        return 1
    fi

    return 0
}

# Fast scan using fd or optimized find
# Args: $1 - search path, $2 - output file
# Scan for purge targets using strict project boundary checks
# Args: $1 - search path, $2 - output file
scan_purge_targets() {
    local search_path="$1"
    local output_file="$2"
    local min_depth="${MOLE_PURGE_MIN_DEPTH:-$PURGE_MIN_DEPTH_DEFAULT}"
    local max_depth="${MOLE_PURGE_MAX_DEPTH:-$PURGE_MAX_DEPTH_DEFAULT}"

    if [[ ! "$min_depth" =~ ^[0-9]+$ ]]; then
        min_depth="$PURGE_MIN_DEPTH_DEFAULT"
    fi
    if [[ ! "$max_depth" =~ ^[0-9]+$ ]]; then
        max_depth="$PURGE_MAX_DEPTH_DEFAULT"
    fi
    if [[ "$max_depth" -lt "$min_depth" ]]; then
        max_depth="$min_depth"
    fi

    if [[ ! -d "$search_path" ]]; then
        return
    fi

    # Use fd for fast parallel search if available
    if command -v fd > /dev/null 2>&1; then
        local fd_args=(
            "--absolute-path"
            "--hidden"
            "--no-ignore"
            "--type" "d"
            "--min-depth" "$min_depth"
            "--max-depth" "$max_depth"
            "--threads" "4"
            "--exclude" ".git"
            "--exclude" "Library"
            "--exclude" ".Trash"
            "--exclude" "Applications"
        )

        for target in "${PURGE_TARGETS[@]}"; do
            fd_args+=("-g" "$target")
        done

        # Run fd command
        fd "${fd_args[@]}" . "$search_path" 2> /dev/null | while IFS= read -r item; do
            if is_safe_project_artifact "$item" "$search_path"; then
                echo "$item"
            fi
        done | filter_nested_artifacts > "$output_file"
    else
        # Fallback to optimized find with pruning
        # This prevents descending into heavily nested dirs like node_modules once found,
        # providing a massive speedup (O(project_dirs) vs O(files)).

        local prune_args=()

        # 1. Directories to prune (ignore completely)
        local prune_dirs=(".git" "Library" ".Trash" "Applications")
        for dir in "${prune_dirs[@]}"; do
            # -name "DIR" -prune -o
            prune_args+=("-name" "$dir" "-prune" "-o")
        done

        # 2. Targets to find (print AND prune)
        # If we find node_modules, we print it and STOP looking inside it
        for target in "${PURGE_TARGETS[@]}"; do
            # -name "TARGET" -print -prune -o
            prune_args+=("-name" "$target" "-print" "-prune" "-o")
        done

        # Run find command
        # Logic: ( prune_pattern -prune -o target_pattern -print -prune )
        # Note: We rely on implicit recursion for directories that don't match any pattern.
        # -print is only called explicitly on targets.

        # Removing the trailing -o from loop construction if necessary?
        # Actually my loop adds -o at the end. I need to handle that.
        # Let's verify the array construction.

        # Re-building args cleanly:
        local find_expr=()

        # Excludes
        for dir in "${prune_dirs[@]}"; do
            find_expr+=("-name" "$dir" "-prune" "-o")
        done

        # Targets
        local i=0
        for target in "${PURGE_TARGETS[@]}"; do
            find_expr+=("-name" "$target" "-print" "-prune")

            # Add -o unless it's the very last item of targets
            if [[ $i -lt $((${#PURGE_TARGETS[@]} - 1)) ]]; then
                find_expr+=("-o")
            fi
            ((i++))
        done

        command find "$search_path" -mindepth "$min_depth" -maxdepth "$max_depth" -type d \
            \( "${find_expr[@]}" \) 2> /dev/null | while IFS= read -r item; do

            if is_safe_project_artifact "$item" "$search_path"; then
                echo "$item"
            fi
        done | filter_nested_artifacts > "$output_file"
    fi
}

# Filter out nested artifacts (e.g. node_modules inside node_modules)
filter_nested_artifacts() {
    while IFS= read -r item; do
        local parent_dir=$(dirname "$item")
        local is_nested=false

        for target in "${PURGE_TARGETS[@]}"; do
            # Check if parent directory IS a target or IS INSIDE a target
            # e.g. .../node_modules/foo/node_modules -> parent has node_modules
            # Use more strict matching to avoid false positives like "my_node_modules_backup"
            if [[ "$parent_dir" == *"/$target/"* || "$parent_dir" == *"/$target" ]]; then
                is_nested=true
                break
            fi
        done

        if [[ "$is_nested" == "false" ]]; then
            echo "$item"
        fi
    done
}

# Check if a path was modified recently (safety check)
# Args: $1 - path
is_recently_modified() {
    local path="$1"
    local age_days=$MIN_AGE_DAYS

    if [[ ! -e "$path" ]]; then
        return 1
    fi

    # Get modification time using base.sh helper (handles GNU vs BSD stat)
    local mod_time
    mod_time=$(get_file_mtime "$path")
    local current_time=$(date +%s)
    local age_seconds=$((current_time - mod_time))
    local age_in_days=$((age_seconds / 86400))

    if [[ $age_in_days -lt $age_days ]]; then
        return 0 # Recently modified
    else
        return 1 # Old enough to clean
    fi
}

# Get human-readable size of directory
# Args: $1 - path
get_dir_size_kb() {
    local path="$1"
    if [[ -d "$path" ]]; then
        du -sk "$path" 2> /dev/null | awk '{print $1}' || echo "0"
    else
        echo "0"
    fi
}

# Simple category selector (for purge only)
# Args: category names and metadata as arrays (passed via global vars)
# Returns: selected indices in PURGE_SELECTION_RESULT (comma-separated)
# Uses PURGE_RECENT_CATEGORIES to mark categories with recent items (default unselected)
select_purge_categories() {
    local -a categories=("$@")
    local total_items=${#categories[@]}
    local clear_line=$'\r\033[2K'

    if [[ $total_items -eq 0 ]]; then
        return 1
    fi

    # Initialize selection (all selected by default, except recent ones)
    local -a selected=()
    IFS=',' read -r -a recent_flags <<< "${PURGE_RECENT_CATEGORIES:-}"
    for ((i = 0; i < total_items; i++)); do
        # Default unselected if category has recent items
        if [[ ${recent_flags[i]:-false} == "true" ]]; then
            selected[i]=false
        else
            selected[i]=true
        fi
    done

    local cursor_pos=0
    local original_stty=""
    if [[ -t 0 ]] && command -v stty > /dev/null 2>&1; then
        original_stty=$(stty -g 2> /dev/null || echo "")
    fi

    # Terminal control functions
    restore_terminal() {
        trap - EXIT INT TERM
        show_cursor
        if [[ -n "${original_stty:-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || true
        fi
    }

    # shellcheck disable=SC2329
    handle_interrupt() {
        restore_terminal
        exit 130
    }

    draw_menu() {
        printf "\033[H"
        # Calculate total size of selected items for header
        local selected_size=0
        local selected_count=0
        IFS=',' read -r -a sizes <<< "${PURGE_CATEGORY_SIZES:-}"
        for ((i = 0; i < total_items; i++)); do
            if [[ ${selected[i]} == true ]]; then
                selected_size=$((selected_size + ${sizes[i]:-0}))
                ((selected_count++))
            fi
        done
        local selected_gb
        selected_gb=$(echo "scale=1; $selected_size/1024/1024" | bc)

        printf "%s\n" "$clear_line"
        printf "%s${PURPLE_BOLD}Select Categories to Clean${NC} ${GRAY}- ${selected_gb}GB ($selected_count selected)${NC}\n" "$clear_line"
        printf "%s\n" "$clear_line"

        IFS=',' read -r -a recent_flags <<< "${PURGE_RECENT_CATEGORIES:-}"
        for ((i = 0; i < total_items; i++)); do
            local checkbox="$ICON_EMPTY"
            [[ ${selected[i]} == true ]] && checkbox="$ICON_SOLID"

            local recent_marker=""
            [[ ${recent_flags[i]:-false} == "true" ]] && recent_marker=" ${GRAY}| Recent${NC}"

            if [[ $i -eq $cursor_pos ]]; then
                printf "%s${CYAN}${ICON_ARROW} %s %s%s${NC}\n" "$clear_line" "$checkbox" "${categories[i]}" "$recent_marker"
            else
                printf "%s  %s %s%s\n" "$clear_line" "$checkbox" "${categories[i]}" "$recent_marker"
            fi
        done

        printf "%s\n" "$clear_line"
        printf "%s${GRAY}↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit${NC}\n" "$clear_line"
    }

    trap restore_terminal EXIT
    trap handle_interrupt INT TERM

    # Preserve interrupt character for Ctrl-C
    stty -echo -icanon intr ^C 2> /dev/null || true
    hide_cursor

    if [[ -t 1 ]]; then
        clear_screen
    fi

    # Main loop
    while true; do
        draw_menu

        # Read key
        IFS= read -r -s -n1 key || key=""

        case "$key" in
            $'\x1b')
                # Arrow keys or ESC
                # Read next 2 chars with timeout (bash 3.2 needs integer)
                IFS= read -r -s -n1 -t 1 key2 || key2=""
                if [[ "$key2" == "[" ]]; then
                    IFS= read -r -s -n1 -t 1 key3 || key3=""
                    case "$key3" in
                        A) # Up arrow
                            ((cursor_pos > 0)) && ((cursor_pos--))
                            ;;
                        B) # Down arrow
                            ((cursor_pos < total_items - 1)) && ((cursor_pos++))
                            ;;
                    esac
                else
                    # ESC alone (no following chars)
                    restore_terminal
                    return 1
                fi
                ;;
            " ") # Space - toggle current item
                if [[ ${selected[cursor_pos]} == true ]]; then
                    selected[cursor_pos]=false
                else
                    selected[cursor_pos]=true
                fi
                ;;
            "a" | "A") # Select all
                for ((i = 0; i < total_items; i++)); do
                    selected[i]=true
                done
                ;;
            "i" | "I") # Invert selection
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        selected[i]=false
                    else
                        selected[i]=true
                    fi
                done
                ;;
            "q" | "Q" | $'\x03') # Quit or Ctrl-C
                restore_terminal
                return 1
                ;;
            "" | $'\n' | $'\r') # Enter - confirm
                # Build result
                PURGE_SELECTION_RESULT=""
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        [[ -n "$PURGE_SELECTION_RESULT" ]] && PURGE_SELECTION_RESULT+=","
                        PURGE_SELECTION_RESULT+="$i"
                    fi
                done

                restore_terminal
                return 0
                ;;
        esac
    done
}

# Main cleanup function - scans and prompts user to select artifacts to clean
clean_project_artifacts() {
    local -a all_found_items=()
    local -a safe_to_clean=()
    local -a recently_modified=()

    # Set up cleanup on interrupt
    # Note: Declared without 'local' so cleanup_scan trap can access them
    scan_pids=()
    scan_temps=()
    # shellcheck disable=SC2329
    cleanup_scan() {
        # Kill all background scans
        for pid in "${scan_pids[@]+"${scan_pids[@]}"}"; do
            kill "$pid" 2> /dev/null || true
        done
        # Clean up temp files
        for temp in "${scan_temps[@]+"${scan_temps[@]}"}"; do
            rm -f "$temp" 2> /dev/null || true
        done
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        printf '\n'
        echo -e "${GRAY}Interrupted${NC}"
        printf '\n'
        exit 130
    }
    trap cleanup_scan INT TERM

    # Start parallel scanning of all paths at once
    if [[ -t 1 ]]; then
        start_inline_spinner "Scanning projects..."
    fi

    # Launch all scans in parallel
    for path in "${PURGE_SEARCH_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            local scan_output
            scan_output=$(mktemp)
            scan_temps+=("$scan_output")

            # Launch scan in background for true parallelism
            scan_purge_targets "$path" "$scan_output" &
            local scan_pid=$!
            scan_pids+=("$scan_pid")
        fi
    done

    # Wait for all scans to complete
    for pid in "${scan_pids[@]+"${scan_pids[@]}"}"; do
        wait "$pid" 2> /dev/null || true
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Collect all results
    for scan_output in "${scan_temps[@]+"${scan_temps[@]}"}"; do
        if [[ -f "$scan_output" ]]; then
            while IFS= read -r item; do
                if [[ -n "$item" ]]; then
                    all_found_items+=("$item")
                fi
            done < "$scan_output"
            rm -f "$scan_output"
        fi
    done

    # Clean up trap
    trap - INT TERM

    if [[ ${#all_found_items[@]} -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}✓${NC} Great! No old project artifacts to clean"
        printf '\n'
        return 2 # Special code: nothing to clean
    fi

    # Mark recently modified items (for default selection state)
    for item in "${all_found_items[@]}"; do
        if is_recently_modified "$item"; then
            recently_modified+=("$item")
        fi
        # Add all items to safe_to_clean, let user choose
        safe_to_clean+=("$item")
    done

    # Build menu options - one per artifact
    if [[ -t 1 ]]; then
        start_inline_spinner "Calculating sizes..."
    fi

    local -a menu_options=()
    local -a item_paths=()
    local -a item_sizes=()
    local -a item_recent_flags=()

    # Helper to get project name from path
    # For ~/www/pake/src-tauri/target -> returns "pake"
    # For ~/www/project/node_modules/xxx/node_modules -> returns "project"
    get_project_name() {
        local path="$1"

        # Find the project root by looking for direct child of search paths
        local search_roots=()
        if [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]]; then
            search_roots=("${PURGE_SEARCH_PATHS[@]}")
        else
            search_roots=("$HOME/www" "$HOME/dev" "$HOME/Projects")
        fi

        for root in "${search_roots[@]}"; do
            # Normalize trailing slash for consistent matching
            root="${root%/}"
            if [[ -n "$root" && "$path" == "$root/"* ]]; then
                # Remove root prefix and get first directory component
                local relative_path="${path#"$root"/}"
                # Extract first directory name
                echo "$relative_path" | cut -d'/' -f1
                return 0
            fi
        done

        # Fallback: use grandparent directory
        dirname "$(dirname "$path")" | xargs basename
    }

    # Format display with alignment (like app_selector)
    format_purge_display() {
        local project_name="$1"
        local artifact_type="$2"
        local size_str="$3"

        # Terminal width for alignment
        local terminal_width=$(tput cols 2> /dev/null || echo 80)
        local fixed_width=28 # Reserve for type and size
        local available_width=$((terminal_width - fixed_width))

        # Bounds: 24-35 chars for project name
        [[ $available_width -lt 24 ]] && available_width=24
        [[ $available_width -gt 35 ]] && available_width=35

        # Truncate project name if needed
        local truncated_name=$(truncate_by_display_width "$project_name" "$available_width")
        local current_width=$(get_display_width "$truncated_name")
        local char_count=${#truncated_name}
        local padding=$((available_width - current_width))
        local printf_width=$((char_count + padding))

        # Format: "project_name  size | artifact_type"
        printf "%-*s %9s | %-13s" "$printf_width" "$truncated_name" "$size_str" "$artifact_type"
    }

    # Build menu options - one line per artifact
    for item in "${safe_to_clean[@]}"; do
        local project_name=$(get_project_name "$item")
        local artifact_type=$(basename "$item")
        local size_kb=$(get_dir_size_kb "$item")
        local size_human=$(bytes_to_human "$((size_kb * 1024))")

        # Check if recent
        local is_recent=false
        for recent_item in "${recently_modified[@]+"${recently_modified[@]}"}"; do
            if [[ "$item" == "$recent_item" ]]; then
                is_recent=true
                break
            fi
        done

        menu_options+=("$(format_purge_display "$project_name" "$artifact_type" "$size_human")")
        item_paths+=("$item")
        item_sizes+=("$size_kb")
        item_recent_flags+=("$is_recent")
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    # Set global vars for selector
    export PURGE_CATEGORY_SIZES=$(
        IFS=,
        echo "${item_sizes[*]}"
    )
    export PURGE_RECENT_CATEGORIES=$(
        IFS=,
        echo "${item_recent_flags[*]}"
    )

    # Interactive selection (only if terminal is available)
    PURGE_SELECTION_RESULT=""
    if [[ -t 0 ]]; then
        if ! select_purge_categories "${menu_options[@]}"; then
            unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_SELECTION_RESULT
            return 1
        fi
    else
        # Non-interactive: select all non-recent items
        for ((i = 0; i < ${#menu_options[@]}; i++)); do
            if [[ ${item_recent_flags[i]} != "true" ]]; then
                [[ -n "$PURGE_SELECTION_RESULT" ]] && PURGE_SELECTION_RESULT+=","
                PURGE_SELECTION_RESULT+="$i"
            fi
        done
    fi

    if [[ -z "$PURGE_SELECTION_RESULT" ]]; then
        echo ""
        echo -e "${GRAY}No items selected${NC}"
        printf '\n'
        unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_SELECTION_RESULT
        return 0
    fi

    # Clean selected items
    echo ""
    IFS=',' read -r -a selected_indices <<< "$PURGE_SELECTION_RESULT"

    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    local cleaned_count=0

    for idx in "${selected_indices[@]}"; do
        local item_path="${item_paths[idx]}"
        local artifact_type=$(basename "$item_path")
        local project_name=$(get_project_name "$item_path")
        local size_kb="${item_sizes[idx]}"
        local size_human=$(bytes_to_human "$((size_kb * 1024))")

        # Safety checks
        if [[ -z "$item_path" || "$item_path" == "/" || "$item_path" == "$HOME" || "$item_path" != "$HOME/"* ]]; then
            continue
        fi

        # Show progress
        if [[ -t 1 ]]; then
            start_inline_spinner "Cleaning $project_name/$artifact_type..."
        fi

        # Clean the item
        if [[ -e "$item_path" ]]; then
            safe_remove "$item_path" true

            # Update stats
            if [[ ! -e "$item_path" ]]; then
                local current_total=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
                echo "$((current_total + size_kb))" > "$stats_dir/purge_stats"
                ((cleaned_count++))
            fi
        fi

        if [[ -t 1 ]]; then
            stop_inline_spinner
            echo -e "${GREEN}✓${NC} $project_name - $artifact_type ${GREEN}($size_human)${NC}"
        fi
    done

    # Update count
    echo "$cleaned_count" > "$stats_dir/purge_count"

    unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_SELECTION_RESULT
}
