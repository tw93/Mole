#!/bin/bash
# Project Purge Module (mo purge).
# Removes heavy project build artifacts and dependencies.
set -euo pipefail

PROJECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_LIB_DIR="$(cd "$PROJECT_LIB_DIR/../core" && pwd)"
if ! command -v ensure_user_dir > /dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "$CORE_LIB_DIR/common.sh"
fi
# shellcheck disable=SC1090
source "$PROJECT_LIB_DIR/purge_shared.sh"

readonly PURGE_TARGETS=("${MOLE_PURGE_TARGETS[@]}")
# Minimum age in days before considering for cleanup.
readonly MIN_AGE_DAYS=7
# Scan depth defaults (relative to search root).
readonly PURGE_MIN_DEPTH_DEFAULT=1
readonly PURGE_MAX_DEPTH_DEFAULT=6
# Search paths (default, can be overridden via config file).
readonly DEFAULT_PURGE_SEARCH_PATHS=("${MOLE_PURGE_DEFAULT_SEARCH_PATHS[@]}")

# Config file for custom purge paths.
readonly PURGE_CONFIG_FILE="$HOME/.config/mole/purge_paths"

# Resolved search paths.
PURGE_SEARCH_PATHS=()
PURGE_CATEGORY_FULL_PATHS_ARRAY=()

# Project indicators for container detection.
# Monorepo indicators (higher priority)
readonly MONOREPO_INDICATORS=("${MOLE_PURGE_MONOREPO_INDICATORS[@]}")
readonly PROJECT_INDICATORS=("${MOLE_PURGE_PROJECT_INDICATORS[@]}")

# Check if a directory contains projects (directly or in subdirectories).
is_project_container() {
    local dir="$1"
    local max_depth="${2:-2}"

    # Skip hidden/system directories.
    local basename
    basename=$(basename "$dir")
    [[ "$basename" == .* ]] && return 1
    [[ "$basename" == "Library" ]] && return 1
    [[ "$basename" == "Applications" ]] && return 1
    [[ "$basename" == "Movies" ]] && return 1
    [[ "$basename" == "Music" ]] && return 1
    [[ "$basename" == "Pictures" ]] && return 1
    [[ "$basename" == "Public" ]] && return 1

    # Single find expression for indicators.
    local -a find_args=("$dir" "-maxdepth" "$max_depth" "(")
    local first=true
    for indicator in "${PROJECT_INDICATORS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            find_args+=("-o")
        fi
        find_args+=("-name" "$indicator")
    done
    find_args+=(")" "-print" "-quit")

    if find "${find_args[@]}" 2> /dev/null | grep -q .; then
        return 0
    fi

    return 1
}

# Discover project directories in $HOME.
discover_project_dirs() {
    local -a discovered=()

    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            discovered+=("$path")
        fi
    done

    # Scan $HOME for other containers (depth 1).
    local dir
    for dir in "$HOME"/*/; do
        [[ ! -d "$dir" ]] && continue
        dir="${dir%/}" # Remove trailing slash

        local already_found=false
        for existing in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
            if [[ "$dir" == "$existing" ]]; then
                already_found=true
                break
            fi
        done
        [[ "$already_found" == "true" ]] && continue

        if is_project_container "$dir" 2; then
            discovered+=("$dir")
        fi
    done

    printf '%s\n' "${discovered[@]}" | sort -u
}

# Prepare purge config directory/file ownership when possible.
prepare_purge_config_path() {
    ensure_user_dir "$(dirname "$PURGE_CONFIG_FILE")"
    ensure_user_file "$PURGE_CONFIG_FILE"
}

# Write purge config content atomically when possible.
write_purge_config() {
    local header="$1"
    shift
    local -a paths=("$@")

    prepare_purge_config_path

    local tmp_file
    tmp_file=$(mktemp_file "mole-purge-paths") || return 1

    if ! cat > "$tmp_file" << EOF; then
$header
EOF
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    fi

    for path in "${paths[@]}"; do
        # Convert $HOME to ~ for portability
        path="${path/#$HOME/~}"
        if ! printf '%s\n' "$path" >> "$tmp_file"; then
            rm -f "$tmp_file" 2> /dev/null || true
            return 1
        fi
    done

    if ! mv "$tmp_file" "$PURGE_CONFIG_FILE" 2> /dev/null; then
        rm -f "$tmp_file" 2> /dev/null || true
        return 1
    fi

    return 0
}

warn_purge_config_write_failure() {
    [[ -t 1 ]] || return 0
    [[ -z "${_PURGE_DISCOVERY_SILENT:-}" ]] || return 0
    echo -e "${YELLOW}${ICON_WARNING}${NC} Could not save purge paths to ${PURGE_CONFIG_FILE/#$HOME/~}, using discovered paths for this run" >&2
}

# Save discovered paths to config.
save_discovered_paths() {
    local -a paths=("$@")
    write_purge_config "# Mole Purge Paths - Auto-discovered project directories
# Edit this file to customize, or run: mo purge --paths
# Add one path per line (supports ~ for home directory)
" "${paths[@]}"
}

# Load purge paths from config or auto-discover
load_purge_config() {
    PURGE_SEARCH_PATHS=()

    while IFS= read -r line; do
        [[ -n "$line" ]] && PURGE_SEARCH_PATHS+=("$line")
    done < <(mole_purge_read_paths_config "$PURGE_CONFIG_FILE")

    if [[ ${#PURGE_SEARCH_PATHS[@]} -eq 0 ]]; then
        if [[ -t 1 ]] && [[ -z "${_PURGE_DISCOVERY_SILENT:-}" ]]; then
            echo -e "${GRAY}First run: discovering project directories...${NC}" >&2
        fi

        local -a discovered=()
        while IFS= read -r path; do
            [[ -n "$path" ]] && discovered+=("$path")
        done < <(discover_project_dirs)

        if [[ ${#discovered[@]} -gt 0 ]]; then
            PURGE_SEARCH_PATHS=("${discovered[@]}")
            if save_discovered_paths "${discovered[@]}"; then
                if [[ -t 1 ]] && [[ -z "${_PURGE_DISCOVERY_SILENT:-}" ]]; then
                    echo -e "${GRAY}Found ${#discovered[@]} project directories, saved to config${NC}" >&2
                fi
            else
                warn_purge_config_write_failure
            fi
        else
            PURGE_SEARCH_PATHS=("${DEFAULT_PURGE_SEARCH_PATHS[@]}")
        fi
    fi
}

# Initialize paths on script load.
load_purge_config

format_purge_target_path() {
    local path="$1"
    echo "${path/#$HOME/~}"
}

compact_purge_menu_path() {
    local path="$1"
    local max_width="${2:-0}"

    if ! [[ "$max_width" =~ ^[0-9]+$ ]] || [[ "$max_width" -lt 4 ]]; then
        max_width=4
    fi

    local path_width
    path_width=$(get_display_width "$path")
    if [[ $path_width -le $max_width ]]; then
        echo "$path"
        return
    fi

    local tail=""
    local remainder="$path"
    local prefix_width=3

    while [[ "$remainder" == */* ]]; do
        local segment="/${remainder##*/}"
        remainder="${remainder%/*}"

        local candidate="${segment}${tail}"
        local candidate_width
        candidate_width=$(get_display_width "$candidate")
        if [[ $((candidate_width + prefix_width)) -le $max_width ]]; then
            tail="$candidate"
        else
            break
        fi
    done

    if [[ -n "$tail" ]]; then
        echo "...${tail}"
        return
    fi

    local suffix_len=$((max_width - 3))
    echo "...${path: -$suffix_len}"
}

# Args: $1 - directory path
# Determine whether a directory is a project root.
# This is used to safely allow cleaning direct-child artifacts when
# users configure a single project directory as a purge search path.
is_purge_project_root() {
    mole_purge_is_project_root "$1"
}

# Args: $1 - path to check
# Safe cleanup requires the path be inside a project directory.
is_safe_project_artifact() {
    local path="$1"
    local search_path="$2"

    # Normalize search path to tolerate user config entries with trailing slash.
    if [[ "$search_path" != "/" ]]; then
        search_path="${search_path%/}"
    fi

    if [[ "$path" != /* ]]; then
        return 1
    fi

    if [[ "$path" != "$search_path/"* ]]; then
        # fd may emit physical/canonical paths (for example /private/var)
        # while configured search roots use symlink aliases (for example /var).
        # Compare physical paths as a fallback to avoid false negatives.
        local physical_path=""
        local physical_search_path=""
        if [[ -d "$path" && -d "$search_path" ]]; then
            physical_path=$(cd "$path" 2> /dev/null && pwd -P || echo "")
            physical_search_path=$(cd "$search_path" 2> /dev/null && pwd -P || echo "")
        fi

        if [[ -z "$physical_path" || -z "$physical_search_path" || "$physical_path" != "$physical_search_path/"* ]]; then
            return 1
        fi

        path="$physical_path"
        search_path="$physical_search_path"
    fi

    # Must not be a direct child of the search root.
    local relative_path="${path#"$search_path"/}"
    local _rel_stripped="${relative_path//\//}"
    local depth=$((${#relative_path} - ${#_rel_stripped}))
    if [[ $depth -lt 1 ]]; then
        # Allow direct-child artifacts only when the search path is itself
        # a project root (single-project mode).
        if is_purge_project_root "$search_path"; then
            return 0
        fi
        return 1
    fi
    return 0
}

# Detect if directory is a Rails project root
is_rails_project_root() {
    local dir="$1"
    [[ -f "$dir/config/application.rb" ]] || return 1
    [[ -f "$dir/Gemfile" ]] || return 1
    [[ -f "$dir/bin/rails" || -f "$dir/config/environment.rb" ]]
}

# Detect if directory is a Go project root
is_go_project_root() {
    local dir="$1"
    [[ -f "$dir/go.mod" ]]
}

# Detect if directory is a PHP Composer project root
is_php_project_root() {
    local dir="$1"
    [[ -f "$dir/composer.json" ]]
}

# Decide whether a "bin" directory is a .NET directory
is_dotnet_bin_dir() {
    local path="$1"
    [[ "$(basename "$path")" == "bin" ]] || return 1

    # Check if parent directory has a .csproj/.fsproj/.vbproj file
    local parent_dir
    parent_dir="$(dirname "$path")"
    find "$parent_dir" -maxdepth 1 \( -name "*.csproj" -o -name "*.fsproj" -o -name "*.vbproj" \) 2> /dev/null | grep -q . || return 1

    # Check if bin directory contains Debug/ or Release/ subdirectories
    [[ -d "$path/Debug" || -d "$path/Release" ]] || return 1

    return 0
}

# Check if a vendor directory should be protected from purge
# Expects path to be a vendor directory (basename == vendor)
# Strategy: Only clean PHP Composer vendor, protect all others
is_protected_vendor_dir() {
    local path="$1"
    local base
    base=$(basename "$path")
    [[ "$base" == "vendor" ]] || return 1
    local parent_dir
    parent_dir=$(dirname "$path")

    # PHP Composer vendor can be safely regenerated with 'composer install'
    # Do NOT protect it (return 1 = not protected = can be cleaned)
    if is_php_project_root "$parent_dir"; then
        return 1
    fi

    # Rails vendor (importmap dependencies) - should be protected
    if is_rails_project_root "$parent_dir"; then
        return 0
    fi

    # Go vendor (optional vendoring) - protect to avoid accidental deletion
    if is_go_project_root "$parent_dir"; then
        return 0
    fi

    # Unknown vendor type - protect by default (conservative approach)
    return 0
}

# Check if an artifact should be protected from purge
is_protected_purge_artifact() {
    local path="$1"
    local base
    base=$(basename "$path")

    case "$base" in
        bin)
            # Only allow purging bin/ when we can detect .NET context.
            if is_dotnet_bin_dir "$path"; then
                return 1
            fi
            return 0
            ;;
        vendor)
            is_protected_vendor_dir "$path"
            return $?
            ;;
        DerivedData)
            # Protect Xcode global DerivedData in ~/Library/Developer/Xcode/
            # Only allow purging DerivedData within project directories
            [[ "$path" == *"/Library/Developer/Xcode/DerivedData"* ]] && return 0
            return 1
            ;;
    esac

    return 1
}

# Scan purge targets using fd (fast) or pruned find.
scan_purge_targets() {
    local search_path="$1"
    local output_file="$2"
    local min_depth="$PURGE_MIN_DEPTH_DEFAULT"
    local max_depth="$PURGE_MAX_DEPTH_DEFAULT"
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

    # Update current scanning path
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    echo "$search_path" > "$stats_dir/purge_scanning" 2> /dev/null || true

    # Helper to process raw results
    process_scan_results() {
        local input_file="$1"
        if [[ -f "$input_file" ]]; then
            while IFS= read -r item; do
                # Check if we should abort (scanning file removed by Ctrl+C)
                if [[ ! -f "$stats_dir/purge_scanning" ]]; then
                    return
                fi

                if [[ -n "$item" ]] && is_safe_project_artifact "$item" "$search_path"; then
                    echo "$item"
                    # Update scanning path to show current project directory
                    local project_dir="${item%/*}"
                    echo "$project_dir" > "$stats_dir/purge_scanning" 2> /dev/null || true
                fi
            done < "$input_file" | filter_nested_artifacts | filter_protected_artifacts > "$output_file"
            rm -f "$input_file"
        else
            touch "$output_file"
        fi
    }

    local use_find=true

    # Allow forcing find via MO_USE_FIND environment variable
    if [[ "${MO_USE_FIND:-0}" == "1" ]]; then
        debug_log "MO_USE_FIND=1: Forcing find instead of fd"
        use_find=true
    elif command -v fd > /dev/null 2>&1; then
        # Escape regex special characters in target names for fd patterns (single sed pass)
        local _escaped_lines
        _escaped_lines=$(printf '%s\n' "${PURGE_TARGETS[@]}" | sed -e 's/[][(){}.^$*+?|\\]/\\&/g')
        local pattern
        pattern="($(printf '%s\n' "$_escaped_lines" | sed -e 's/^/^/' -e 's/$/$/' | paste -sd '|' -))"
        local fd_args=(
            "--absolute-path"
            "--hidden"
            "--no-ignore"
            "--type" "d"
            "--min-depth" "$min_depth"
            "--max-depth" "$max_depth"
            "--threads" "8"
            "--exclude" ".git"
            "--exclude" "Library"
            "--exclude" ".Trash"
            "--exclude" "Applications"
        )

        # Try running fd. If it succeeds (exit code 0), use it.
        # If it fails (e.g. bad flag, permissions, binary issue), fallback to find.
        if fd "${fd_args[@]}" "$pattern" "$search_path" 2> /dev/null > "$output_file.raw"; then
            # Check if fd actually found anything - if empty, fallback to find
            if [[ -s "$output_file.raw" ]]; then
                debug_log "Using fd for scanning (found results)"
                use_find=false
                process_scan_results "$output_file.raw"
            else
                debug_log "fd returned empty results, falling back to find"
                rm -f "$output_file.raw"
            fi
        else
            debug_log "fd command failed, falling back to find"
        fi
    fi

    if [[ "$use_find" == "true" ]]; then
        debug_log "Using find for scanning"
        # Pruned find avoids descending into heavy directories.
        local prune_dirs=(".git" "Library" ".Trash" "Applications")
        local purge_targets=("${PURGE_TARGETS[@]}")

        local prune_expr=()
        for i in "${!prune_dirs[@]}"; do
            prune_expr+=(-name "${prune_dirs[$i]}")
            [[ $i -lt $((${#prune_dirs[@]} - 1)) ]] && prune_expr+=(-o)
        done

        local target_expr=()
        for i in "${!purge_targets[@]}"; do
            target_expr+=(-name "${purge_targets[$i]}")
            [[ $i -lt $((${#purge_targets[@]} - 1)) ]] && target_expr+=(-o)
        done

        # Use plain `find` here for compatibility with environments where
        # `command find` behaves inconsistently in this complex expression.
        find "$search_path" -mindepth "$min_depth" -maxdepth "$max_depth" -type d \
            \( "${prune_expr[@]}" \) -prune -o \
            \( "${target_expr[@]}" \) -print -prune \
            2> /dev/null > "$output_file.raw" || true

        process_scan_results "$output_file.raw"
    fi
}
# Filter out nested artifacts (e.g. node_modules inside node_modules, .build inside build).
# Optimized: Sort paths to put parents before children, then filter in single pass.
filter_nested_artifacts() {
    # 1. Append trailing slash to each path (to ensure /foo/bar starts with /foo/)
    # 2. Sort to group parents and children (LC_COLLATE=C ensures standard sorting)
    # 3. Use awk to filter out paths that start with the previous kept path
    # 4. Remove trailing slash
    sed 's|[^/]$|&/|' | LC_COLLATE=C sort | awk '
        BEGIN { last_kept = "" }
        {
            current = $0
            # If current path starts with last_kept, it is nested
            # Only check if last_kept is not empty
            if (last_kept == "" || index(current, last_kept) != 1) {
                print current
                last_kept = current
            }
        }
    ' | sed 's|/$||'
}

filter_protected_artifacts() {
    while IFS= read -r item; do
        if ! is_protected_purge_artifact "$item"; then
            echo "$item"
        fi
    done
}
# Args: $1 - path
# Check if a path was modified recently (safety check).
is_recently_modified() {
    local path="$1"
    local current_time="${2:-}"
    local age_days=$MIN_AGE_DAYS
    if [[ ! -e "$path" ]]; then
        return 1
    fi
    local mod_time
    mod_time=$(get_file_mtime "$path")
    if [[ -z "$current_time" || ! "$current_time" =~ ^[0-9]+$ ]]; then
        current_time=$(get_epoch_seconds)
    fi
    local age_seconds=$((current_time - mod_time))
    local age_in_days=$((age_seconds / 86400))
    if [[ $age_in_days -lt $age_days ]]; then
        return 0 # Recently modified
    else
        return 1 # Old enough to clean
    fi
}
# Args: $1 - path
# Get directory size in KB.
get_dir_size_kb() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo "0"
        return
    fi

    local timeout_seconds="${MO_PURGE_SIZE_TIMEOUT_SEC:-15}"
    if [[ ! "$timeout_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        timeout_seconds=15
    fi

    local du_output=""
    local du_exit=0
    local du_tmp
    du_tmp=$(mktemp)
    if run_with_timeout "$timeout_seconds" du -skP "$path" > "$du_tmp" 2> /dev/null; then
        du_output=$(cat "$du_tmp")
    else
        du_exit=$?
    fi
    rm -f "$du_tmp"

    if [[ $du_exit -eq 124 ]]; then
        debug_log "Size calculation timed out (${timeout_seconds}s): $path"
        echo "TIMEOUT"
        return
    fi

    if [[ $du_exit -ne 0 ]]; then
        echo "0"
        return
    fi

    local size_kb
    size_kb=$(printf '%s\n' "$du_output" | awk 'NR==1 {print $1; exit}')
    if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
        echo "$size_kb"
    else
        echo "0"
    fi
}
# Purge category selector.
select_purge_categories() {
    local -a categories=("$@")
    local total_items=${#categories[@]}
    local clear_line=$'\r\033[2K'
    if [[ $total_items -eq 0 ]]; then
        return 1
    fi

    # Calculate items per page based on terminal height.
    _get_items_per_page() {
        local term_height=24
        if [[ -t 0 ]] || [[ -t 2 ]]; then
            term_height=$(stty size < /dev/tty 2> /dev/null | awk '{print $1}')
        fi
        if [[ -z "$term_height" || $term_height -le 0 ]]; then
            if command -v tput > /dev/null 2>&1; then
                term_height=$(tput lines 2> /dev/null || echo "24")
            else
                term_height=24
            fi
        fi
        local reserved=8
        local available=$((term_height - reserved))
        if [[ $available -lt 3 ]]; then
            echo 3
        elif [[ $available -gt 50 ]]; then
            echo 50
        else
            echo "$available"
        fi
    }

    local items_per_page=$(_get_items_per_page)
    local cursor_pos=0
    local top_index=0

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
    local original_stty=""
    local previous_exit_trap=""
    local previous_int_trap=""
    local previous_term_trap=""
    local terminal_restored=false
    if [[ -t 0 ]] && command -v stty > /dev/null 2>&1; then
        original_stty=$(stty -g 2> /dev/null || echo "")
    fi
    previous_exit_trap=$(trap -p EXIT || true)
    previous_int_trap=$(trap -p INT || true)
    previous_term_trap=$(trap -p TERM || true)
    # Terminal control functions
    restore_terminal() {
        # Avoid trap churn when restore is called repeatedly via RETURN/EXIT paths.
        if [[ "${terminal_restored:-false}" == "true" ]]; then
            return
        fi
        terminal_restored=true

        trap - EXIT INT TERM
        show_cursor
        if [[ -n "${original_stty:-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || true
        fi
        if [[ -n "$previous_exit_trap" ]]; then
            eval "$previous_exit_trap"
        fi
        if [[ -n "$previous_int_trap" ]]; then
            eval "$previous_int_trap"
        fi
        if [[ -n "$previous_term_trap" ]]; then
            eval "$previous_term_trap"
        fi
    }
    # shellcheck disable=SC2329
    handle_interrupt() {
        restore_terminal
        exit 130
    }
    draw_menu() {
        # Recalculate items_per_page dynamically to handle window resize
        items_per_page=$(_get_items_per_page)

        # Clamp pagination state to avoid cursor drifting out of view
        local max_top_index=0
        if [[ $total_items -gt $items_per_page ]]; then
            max_top_index=$((total_items - items_per_page))
        fi
        if [[ $top_index -gt $max_top_index ]]; then
            top_index=$max_top_index
        fi
        if [[ $top_index -lt 0 ]]; then
            top_index=0
        fi

        local visible_count=$((total_items - top_index))
        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
        if [[ $cursor_pos -gt $((visible_count - 1)) ]]; then
            cursor_pos=$((visible_count - 1))
        fi
        if [[ $cursor_pos -lt 0 ]]; then
            cursor_pos=0
        fi

        printf "\033[H"
        # Calculate total size of selected items for header
        local selected_size=0
        local selected_count=0
        IFS=',' read -r -a sizes <<< "${PURGE_CATEGORY_SIZES:-}"
        for ((i = 0; i < total_items; i++)); do
            if [[ ${selected[i]} == true ]]; then
                selected_size=$((selected_size + ${sizes[i]:-0}))
                selected_count=$((selected_count + 1))
            fi
        done

        # Format selected size (stored in KB) using shared display rules.
        local selected_size_human
        selected_size_human=$(bytes_to_human_kb "$selected_size")

        # Show position indicator if scrolling is needed
        local scroll_indicator=""
        if [[ $total_items -gt $items_per_page ]]; then
            local current_pos=$((top_index + cursor_pos + 1))
            scroll_indicator=" ${GRAY}[${current_pos}/${total_items}]${NC}"
        fi

        printf "%s${PURPLE_BOLD}Select Categories to Clean${NC}%s${GRAY}, ${selected_size_human}, ${selected_count} selected${NC}\n" "$clear_line" "$scroll_indicator"
        printf "%s\n" "$clear_line"

        IFS=',' read -r -a recent_flags <<< "${PURGE_RECENT_CATEGORIES:-}"

        # Calculate visible range
        local end_index=$((top_index + visible_count))

        # Draw only visible items
        for ((i = top_index; i < end_index; i++)); do
            local checkbox="$ICON_EMPTY"
            [[ ${selected[i]} == true ]] && checkbox="$ICON_SOLID"
            local recent_marker=""
            [[ ${recent_flags[i]:-false} == "true" ]] && recent_marker=" ${GRAY}| Recent${NC}"
            local rel_pos=$((i - top_index))
            if [[ $rel_pos -eq $cursor_pos ]]; then
                printf "%s${CYAN}${ICON_ARROW} %s %s%s${NC}\n" "$clear_line" "$checkbox" "${categories[i]}" "$recent_marker"
            else
                printf "%s  %s %s%s\n" "$clear_line" "$checkbox" "${categories[i]}" "$recent_marker"
            fi
        done

        # Keep one blank line between the list and footer tips.
        printf "%s\n" "$clear_line"

        local current_index=$((top_index + cursor_pos))
        local current_full_path=""
        local paths_len="${#PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}"
        if [[ "$paths_len" -gt 0 && "$current_index" -lt "$paths_len" ]]; then
            current_full_path="${PURGE_CATEGORY_FULL_PATHS_ARRAY[current_index]}"
        fi
        if [[ -n "$current_full_path" ]]; then
            printf "%s${GRAY}Full path:${NC} %s\n" "$clear_line" "$current_full_path"
            printf "%s\n" "$clear_line"
        fi

        # Adaptive footer hints — mirrors menu_paginated.sh pattern
        local _term_w
        _term_w=$(tput cols 2> /dev/null || echo 80)
        [[ "$_term_w" =~ ^[0-9]+$ ]] || _term_w=80

        local _sep=" ${GRAY}|${NC} "
        local _nav="${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}${NC}"
        local _space="${GRAY}Space Select${NC}"
        local _enter="${GRAY}Enter Confirm${NC}"
        local _all="${GRAY}A All${NC}"
        local _invert="${GRAY}I Invert${NC}"
        local _quit="${GRAY}Q Quit${NC}"

        # Strip ANSI to measure real length
        _ph_len() { printf "%s" "$1" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*[A-Za-z]/,""); printf "%d", length}'; }

        # Level 0 (full): ↑↓ | Space Select | Enter Confirm | A All | I Invert | Q Quit
        local _full="${_nav}${_sep}${_space}${_sep}${_enter}${_sep}${_all}${_sep}${_invert}${_sep}${_quit}"
        if (($(_ph_len "$_full") <= _term_w)); then
            printf "%s${_full}${NC}\n" "$clear_line"
        else
            # Level 1: ↑↓ | Enter Confirm | A All | I Invert | Q Quit
            local _l1="${_nav}${_sep}${_enter}${_sep}${_all}${_sep}${_invert}${_sep}${_quit}"
            if (($(_ph_len "$_l1") <= _term_w)); then
                printf "%s${_l1}${NC}\n" "$clear_line"
            else
                # Level 2 (minimal): ↑↓ | Enter | Q Quit
                printf "%s${_nav}${_sep}${_enter}${_sep}${_quit}${NC}\n" "$clear_line"
            fi
        fi

        # Clear stale content below the footer when list height shrinks.
        printf '\033[J'
    }
    move_cursor_up() {
        if [[ $cursor_pos -gt 0 ]]; then
            ((cursor_pos--))
        elif [[ $top_index -gt 0 ]]; then
            ((top_index--))
        fi
    }
    move_cursor_down() {
        local absolute_index=$((top_index + cursor_pos))
        local last_index=$((total_items - 1))
        if [[ $absolute_index -lt $last_index ]]; then
            local visible_count=$((total_items - top_index))
            [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
            if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                cursor_pos=$((cursor_pos + 1))
            elif [[ $((top_index + visible_count)) -lt $total_items ]]; then
                top_index=$((top_index + 1))
            fi
        fi
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
                            move_cursor_up
                            ;;
                        B) # Down arrow
                            move_cursor_down
                            ;;
                    esac
                else
                    # ESC alone (no following chars)
                    restore_terminal
                    return 1
                fi
                ;;
            "j" | "J") # Vim down
                move_cursor_down
                ;;
            "k" | "K") # Vim up
                move_cursor_up
                ;;
            " ") # Space - toggle current item
                local idx=$((top_index + cursor_pos))
                if [[ ${selected[idx]} == true ]]; then
                    selected[idx]=false
                else
                    selected[idx]=true
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

# Final confirmation before deleting selected purge artifacts.
confirm_purge_cleanup() {
    local item_count="${1:-0}"
    local total_size_kb="${2:-0}"
    local unknown_count="${3:-0}"
    local -a selected_paths=("${@:4}")

    [[ "$item_count" =~ ^[0-9]+$ ]] || item_count=0
    [[ "$total_size_kb" =~ ^[0-9]+$ ]] || total_size_kb=0
    [[ "$unknown_count" =~ ^[0-9]+$ ]] || unknown_count=0

    local item_text="artifact"
    [[ $item_count -ne 1 ]] && item_text="artifacts"

    local size_display
    size_display=$(bytes_to_human "$((total_size_kb * 1024))")

    local unknown_hint=""
    if [[ $unknown_count -gt 0 ]]; then
        local unknown_text="unknown size"
        [[ $unknown_count -gt 1 ]] && unknown_text="unknown sizes"
        unknown_hint=", ${unknown_count} ${unknown_text}"
    fi

    if [[ ${#selected_paths[@]} -gt 0 ]]; then
        echo ""
        echo -e "${GRAY}Selected paths:${NC}"
        local selected_path=""
        for selected_path in "${selected_paths[@]}"; do
            echo "  $selected_path"
        done
    fi

    echo -ne "${PURPLE}${ICON_ARROW}${NC} Remove ${item_count} ${item_text}, ${size_display}${unknown_hint}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "
    drain_pending_input
    local key=""
    IFS= read -r -s -n1 key || key=""
    drain_pending_input

    case "$key" in
        "" | $'\n' | $'\r' | y | Y)
            echo ""
            return 0
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Main cleanup function - scans and prompts user to select artifacts to clean
clean_project_artifacts() {
    local -a all_found_items=()
    local -a safe_to_clean=()
    local -a recently_modified=()
    local previous_int_trap=""
    local previous_term_trap=""
    local trap_installed_by_this_call=false
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
        # Clean up purge scanning file
        local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
        rm -f "$stats_dir/purge_scanning" 2> /dev/null || true
        echo ""
        exit 130
    }
    # Save caller traps and install local cleanup trap for this function call.
    previous_int_trap=$(trap -p INT || true)
    previous_term_trap=$(trap -p TERM || true)
    trap cleanup_scan INT TERM
    trap_installed_by_this_call=true
    # Scanning is started from purge.sh with start_inline_spinner
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

    # Stop the scanning monitor (removes purge_scanning file to signal completion)
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    rm -f "$stats_dir/purge_scanning" 2> /dev/null || true

    # Give monitor process time to exit and clear its output
    if [[ -t 1 ]]; then
        sleep 0.2
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
    # Restore caller traps after this function completes.
    if [[ "$trap_installed_by_this_call" == "true" ]]; then
        trap - INT TERM
        [[ -n "$previous_int_trap" ]] && eval "$previous_int_trap"
        [[ -n "$previous_term_trap" ]] && eval "$previous_term_trap"
    fi
    if [[ ${#all_found_items[@]} -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No old project artifacts to clean"
        printf '\n'
        return 2 # Special code: nothing to clean
    fi
    # Mark recently modified items (for default selection state)
    local _now_epoch
    _now_epoch=$(get_epoch_seconds)
    for item in "${all_found_items[@]}"; do
        if is_recently_modified "$item" "$_now_epoch"; then
            recently_modified+=("$item")
        fi
        # Add all items to safe_to_clean, let user choose
        safe_to_clean+=("$item")
    done
    # Build menu options - one per artifact
    if [[ -t 1 ]]; then
        start_inline_spinner "Calculating sizes..."
    fi

    # Pre-compute all sizes in parallel to avoid sequential timeout hangs (issue #560).
    # With N artifacts each taking up to 15s, sequential calculation can take N×15s.
    # Parallel: all sizes computed concurrently, total ≤ single longest du call.
    local -a _size_tmpfiles=()
    local -a _size_pids=()
    for _sz_item in "${safe_to_clean[@]}"; do
        local _stmp
        _stmp=$(mktemp)
        register_temp_file "$_stmp"
        _size_tmpfiles+=("$_stmp")
        (get_dir_size_kb "$_sz_item" > "$_stmp" 2> /dev/null) &
        _size_pids+=($!)
    done
    for _spid in "${_size_pids[@]+"${_size_pids[@]}"}"; do
        wait "$_spid" 2> /dev/null || true
    done

    local -a menu_options=()
    local -a item_paths=()
    local -a item_sizes=()
    local -a item_size_unknown_flags=()
    local -a item_recent_flags=()
    # Helper to get project name from path
    # For ~/www/pake/src-tauri/target -> returns "pake"
    # For ~/work/code/MyProject/node_modules -> returns "MyProject"
    # Strategy: Find the nearest ancestor directory containing a project indicator file
    get_project_name() {
        local path="$1"

        local current_dir="${path%/*}"
        [[ -z "$current_dir" ]] && current_dir="/"
        local monorepo_root=""
        local project_root=""

        # Single pass: check both monorepo and project indicators
        while [[ "$current_dir" != "/" && "$current_dir" != "$HOME" && -n "$current_dir" ]]; do
            # First check for monorepo indicators (higher priority)
            if [[ -z "$monorepo_root" ]]; then
                for indicator in "${MONOREPO_INDICATORS[@]}"; do
                    if [[ -e "$current_dir/$indicator" ]]; then
                        monorepo_root="$current_dir"
                        break
                    fi
                done
            fi

            # Then check for project indicators (save first match)
            if [[ -z "$project_root" ]]; then
                for indicator in "${PROJECT_INDICATORS[@]}"; do
                    if [[ -e "$current_dir/$indicator" ]]; then
                        project_root="$current_dir"
                        break
                    fi
                done
            fi

            # If we found monorepo, we can stop (monorepo always wins)
            if [[ -n "$monorepo_root" ]]; then
                break
            fi

            # If we found project but still checking for monorepo above
            # (only stop if we're beyond reasonable depth)
            local _rel="${current_dir#"$HOME"}"
            local _stripped="${_rel//\//}"
            local depth=$((${#_rel} - ${#_stripped}))
            if [[ -n "$project_root" && $depth -lt 2 ]]; then
                break
            fi

            local _parent="${current_dir%/*}"
            current_dir="${_parent:-/}"
        done

        # Determine result: monorepo > project > fallback
        local result=""
        if [[ -n "$monorepo_root" ]]; then
            result="${monorepo_root##*/}"
        elif [[ -n "$project_root" ]]; then
            result="${project_root##*/}"
        else
            # Fallback: first directory under search root
            local search_roots=()
            if [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]]; then
                search_roots=("${PURGE_SEARCH_PATHS[@]}")
            else
                search_roots=("$HOME/www" "$HOME/dev" "$HOME/Projects")
            fi
            for root in "${search_roots[@]}"; do
                root="${root%/}"
                if [[ -n "$root" && "$path" == "$root/"* ]]; then
                    local relative_path="${path#"$root"/}"
                    result="${relative_path%%/*}"
                    break
                fi
            done

            # Final fallback: use grandparent directory
            if [[ -z "$result" ]]; then
                local _gp="${path%/*}"
                _gp="${_gp%/*}"
                result="${_gp##*/}"
            fi
        fi

        echo "$result"
    }

    # Helper to get project path (more complete than just project name)
    # For ~/www/pake/src-tauri/target -> returns "~/www/pake"
    # For ~/work/code/MyProject/node_modules -> returns "~/work/code/MyProject"
    # Shows the full path relative to HOME with ~ prefix for better clarity
    get_project_path() {
        local path="$1"

        local current_dir="${path%/*}"
        [[ -z "$current_dir" ]] && current_dir="/"
        local monorepo_root=""
        local project_root=""

        # Single pass: check both monorepo and project indicators
        while [[ "$current_dir" != "/" && "$current_dir" != "$HOME" && -n "$current_dir" ]]; do
            # First check for monorepo indicators (higher priority)
            if [[ -z "$monorepo_root" ]]; then
                for indicator in "${MONOREPO_INDICATORS[@]}"; do
                    if [[ -e "$current_dir/$indicator" ]]; then
                        monorepo_root="$current_dir"
                        break
                    fi
                done
            fi

            # Then check for project indicators (save first match)
            if [[ -z "$project_root" ]]; then
                for indicator in "${PROJECT_INDICATORS[@]}"; do
                    if [[ -e "$current_dir/$indicator" ]]; then
                        project_root="$current_dir"
                        break
                    fi
                done
            fi

            # If we found monorepo, we can stop (monorepo always wins)
            if [[ -n "$monorepo_root" ]]; then
                break
            fi

            # If we found project but still checking for monorepo above
            local _rel="${current_dir#"$HOME"}"
            local _stripped="${_rel//\//}"
            local depth=$((${#_rel} - ${#_stripped}))
            if [[ -n "$project_root" && $depth -lt 2 ]]; then
                break
            fi

            local _parent="${current_dir%/*}"
            current_dir="${_parent:-/}"
        done

        # Determine result: monorepo > project > fallback
        local result=""
        if [[ -n "$monorepo_root" ]]; then
            result="$monorepo_root"
        elif [[ -n "$project_root" ]]; then
            result="$project_root"
        else
            # Fallback: use parent directory of artifact
            result="${path%/*}"
        fi

        # Convert to ~ format for cleaner display
        result="${result/#$HOME/~}"
        echo "$result"
    }

    # Helper to get artifact display name
    # For duplicate artifact names within same project, include parent directory for context
    # Uses pre-computed _cached_basenames and _cached_project_names arrays when available.
    get_artifact_display_name() {
        local path="$1"
        local artifact_name="${path##*/}"
        local parent_name="${path%/*}"
        parent_name="${parent_name##*/}"

        local project_name
        if [[ -n "${_cached_project_names[*]+x}" ]]; then
            # Fast path: use pre-computed cache
            local _idx
            project_name=""
            for _idx in "${!safe_to_clean[@]}"; do
                if [[ "${safe_to_clean[$_idx]}" == "$path" ]]; then
                    project_name="${_cached_project_names[$_idx]}"
                    break
                fi
            done
        else
            project_name=$(get_project_name "$path")
        fi

        # Check if there are other items with same artifact name AND same project
        local has_duplicate=false
        if [[ -n "${_cached_basenames[*]+x}" ]]; then
            local _idx
            for _idx in "${!safe_to_clean[@]}"; do
                if [[ "${safe_to_clean[$_idx]}" != "$path" && "${_cached_basenames[$_idx]}" == "$artifact_name" && "${_cached_project_names[$_idx]}" == "$project_name" ]]; then
                    has_duplicate=true
                    break
                fi
            done
        else
            for other_item in "${safe_to_clean[@]}"; do
                if [[ "$other_item" != "$path" && "${other_item##*/}" == "$artifact_name" ]]; then
                    if [[ "$(get_project_name "$other_item")" == "$project_name" ]]; then
                        has_duplicate=true
                        break
                    fi
                fi
            done
        fi

        # If duplicate exists in same project and parent is not the project itself, show parent/artifact
        if [[ "$has_duplicate" == "true" && "$parent_name" != "$project_name" && "$parent_name" != "." && "$parent_name" != "/" ]]; then
            echo "$parent_name/$artifact_name"
        else
            echo "$artifact_name"
        fi
    }
    # Format display with alignment (mirrors app_selector.sh approach)
    # Args: $1=project_path $2=artifact_type $3=size_str $4=terminal_width $5=max_path_width $6=artifact_col_width
    format_purge_display() {
        local project_path="$1"
        local artifact_type="$2"
        local size_str="$3"
        local terminal_width="${4:-$(tput cols 2> /dev/null || echo 80)}"
        local max_path_width="${5:-}"
        local artifact_col="${6:-12}"
        local available_width

        if [[ -n "$max_path_width" ]]; then
            available_width="$max_path_width"
        else
            # Standalone fallback: overhead = prefix(4)+space(1)+size(9)+sep(3)+artifact_col+recent(9) = artifact_col+26
            local fixed_width=$((artifact_col + 26))
            available_width=$((terminal_width - fixed_width))

            local min_width=10
            if [[ $terminal_width -ge 120 ]]; then
                min_width=48
            elif [[ $terminal_width -ge 100 ]]; then
                min_width=38
            elif [[ $terminal_width -ge 80 ]]; then
                min_width=25
            fi

            [[ $available_width -lt $min_width ]] && available_width=$min_width
        fi

        # Truncate project path if needed
        local truncated_path
        truncated_path=$(compact_purge_menu_path "$project_path" "$available_width")
        local current_width
        current_width=$(get_display_width "$truncated_path")
        local char_count=${#truncated_path}
        local padding=$((available_width - current_width))
        local printf_width=$((char_count + padding))
        # Format: "project_path  size | artifact_type"
        printf "%-*s %9s | %-*s" "$printf_width" "$truncated_path" "$size_str" "$artifact_col" "$artifact_type"
    }
    # Pre-compute basenames and project names once so get_artifact_display_name()
    # can avoid repeated filesystem traversals during the O(N^2) duplicate check.
    local -a _cached_basenames=()
    local -a _cached_project_names=()
    local -a _cached_project_paths=()
    local _pre_idx
    for _pre_idx in "${!safe_to_clean[@]}"; do
        _cached_basenames[_pre_idx]="${safe_to_clean[$_pre_idx]##*/}"
        _cached_project_names[_pre_idx]=$(get_project_name "${safe_to_clean[$_pre_idx]}")
        _cached_project_paths[_pre_idx]=$(get_project_path "${safe_to_clean[$_pre_idx]}")
    done

    # Build menu options - one line per artifact
    # Pass 1: collect data into parallel arrays (needed for pre-scan of widths).
    # Sizes are read from pre-computed results (parallel du calls launched above).
    local -a raw_project_paths=()
    local -a raw_artifact_types=()
    local -a item_display_paths=()
    local _sz_idx=0
    for item in "${safe_to_clean[@]}"; do
        local project_path="${_cached_project_paths[$_sz_idx]}"
        local artifact_type
        artifact_type=$(get_artifact_display_name "$item")
        local size_raw
        size_raw=$(cat "${_size_tmpfiles[_sz_idx]}" 2> /dev/null || echo "0")
        rm -f "${_size_tmpfiles[_sz_idx]}" 2> /dev/null || true
        _sz_idx=$((_sz_idx + 1))
        local size_kb=0
        local size_human=""
        local size_unknown=false

        if [[ "$size_raw" == "TIMEOUT" ]]; then
            size_unknown=true
            size_human="unknown"
        elif [[ "$size_raw" =~ ^[0-9]+$ ]]; then
            size_kb="$size_raw"
            # Skip empty directories (0 bytes)
            if [[ $size_kb -eq 0 ]]; then
                continue
            fi
            size_human=$(bytes_to_human "$((size_kb * 1024))")
        else
            continue
        fi

        # Check if recent
        local is_recent=false
        for recent_item in "${recently_modified[@]+"${recently_modified[@]}"}"; do
            if [[ "$item" == "$recent_item" ]]; then
                is_recent=true
                break
            fi
        done
        raw_project_paths+=("$project_path")
        raw_artifact_types+=("$artifact_type")
        item_paths+=("$item")
        item_display_paths+=("$(format_purge_target_path "$item")")
        item_sizes+=("$size_kb")
        item_size_unknown_flags+=("$size_unknown")
        item_recent_flags+=("$is_recent")
    done

    # Pre-scan: find max path and artifact display widths (mirrors app_selector.sh approach)
    local terminal_width
    terminal_width=$(tput cols 2> /dev/null || echo 80)
    [[ "$terminal_width" =~ ^[0-9]+$ ]] || terminal_width=80

    local max_path_display_width=0
    local max_artifact_width=0
    for pp in "${raw_project_paths[@]+"${raw_project_paths[@]}"}"; do
        local w
        w=$(get_display_width "$pp")
        [[ $w -gt $max_path_display_width ]] && max_path_display_width=$w
    done
    for at in "${raw_artifact_types[@]+"${raw_artifact_types[@]}"}"; do
        [[ ${#at} -gt $max_artifact_width ]] && max_artifact_width=${#at}
    done

    # Artifact column: cap at 17, floor at 6 (shortest typical names like "dist")
    [[ $max_artifact_width -lt 6 ]] && max_artifact_width=6
    [[ $max_artifact_width -gt 17 ]] && max_artifact_width=17

    # Exact overhead: prefix(4) + space(1) + size(9) + " | "(3) + artifact_col + " | Recent"(9) = artifact_col + 26
    local fixed_overhead=$((max_artifact_width + 26))
    local available_for_path=$((terminal_width - fixed_overhead))

    local min_path_width=10
    if [[ $terminal_width -ge 120 ]]; then
        min_path_width=48
    elif [[ $terminal_width -ge 100 ]]; then
        min_path_width=38
    elif [[ $terminal_width -ge 80 ]]; then
        min_path_width=25
    fi

    [[ $max_path_display_width -lt $min_path_width ]] && max_path_display_width=$min_path_width
    [[ $available_for_path -lt $max_path_display_width ]] && max_path_display_width=$available_for_path
    # Ensure path width is at least 5 on very narrow terminals
    [[ $max_path_display_width -lt 5 ]] && max_path_display_width=5

    # Pass 2: build menu_options using pre-computed widths
    for ((idx = 0; idx < ${#raw_project_paths[@]}; idx++)); do
        local size_kb_val="${item_sizes[idx]}"
        local size_unknown_val="${item_size_unknown_flags[idx]}"
        local size_human_val=""
        if [[ "$size_unknown_val" == "true" ]]; then
            size_human_val="unknown"
        else
            size_human_val=$(bytes_to_human "$((size_kb_val * 1024))")
        fi
        menu_options+=("$(format_purge_display "${raw_project_paths[idx]}" "${raw_artifact_types[idx]}" "$size_human_val" "$terminal_width" "$max_path_display_width" "$max_artifact_width")")
    done

    # Sort by size descending (largest first) - requested in issue #311
    # Use external sort for better performance with many items
    if [[ ${#item_sizes[@]} -gt 0 ]]; then
        # Create temporary file with index|size pairs
        local sort_temp
        sort_temp=$(mktemp)
        for ((i = 0; i < ${#item_sizes[@]}; i++)); do
            printf '%d|%d\n' "$i" "${item_sizes[i]}"
        done > "$sort_temp"

        # Sort by size (field 2) descending, extract indices
        local -a sorted_indices=()
        while IFS='|' read -r idx size; do
            sorted_indices+=("$idx")
        done < <(sort -t'|' -k2,2nr "$sort_temp")
        rm -f "$sort_temp"

        # Rebuild arrays in sorted order
        local -a sorted_menu_options=()
        local -a sorted_item_paths=()
        local -a sorted_item_sizes=()
        local -a sorted_item_size_unknown_flags=()
        local -a sorted_item_recent_flags=()
        local -a sorted_item_display_paths=()

        for idx in "${sorted_indices[@]}"; do
            sorted_menu_options+=("${menu_options[idx]}")
            sorted_item_paths+=("${item_paths[idx]}")
            sorted_item_sizes+=("${item_sizes[idx]}")
            sorted_item_size_unknown_flags+=("${item_size_unknown_flags[idx]}")
            sorted_item_recent_flags+=("${item_recent_flags[idx]}")
            sorted_item_display_paths+=("${item_display_paths[idx]}")
        done

        # Replace original arrays with sorted versions
        menu_options=("${sorted_menu_options[@]}")
        item_paths=("${sorted_item_paths[@]}")
        item_sizes=("${sorted_item_sizes[@]}")
        item_size_unknown_flags=("${sorted_item_size_unknown_flags[@]}")
        item_recent_flags=("${sorted_item_recent_flags[@]}")
        item_display_paths=("${sorted_item_display_paths[@]}")
    fi
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    # Exit early if no artifacts were found to avoid unbound variable errors
    # when expanding empty arrays with set -u active.
    if [[ ${#menu_options[@]} -eq 0 ]]; then
        echo ""
        echo -e "${GRAY}No artifacts found to purge${NC}"
        printf '\n'
        return 0
    fi
    # Set global vars for selector
    export PURGE_CATEGORY_SIZES=$(
        IFS=,
        echo "${item_sizes[*]-}"
    )
    export PURGE_RECENT_CATEGORIES=$(
        IFS=,
        echo "${item_recent_flags[*]-}"
    )
    # Interactive selection (only if terminal is available)
    PURGE_SELECTION_RESULT=""
    PURGE_CATEGORY_FULL_PATHS_ARRAY=("${item_display_paths[@]}")
    if [[ -t 0 ]]; then
        if ! select_purge_categories "${menu_options[@]}"; then
            PURGE_CATEGORY_FULL_PATHS_ARRAY=()
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
        PURGE_CATEGORY_FULL_PATHS_ARRAY=()
        unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_SELECTION_RESULT
        return 0
    fi
    IFS=',' read -r -a selected_indices <<< "$PURGE_SELECTION_RESULT"
    local selected_total_kb=0
    local selected_unknown_count=0
    local -a selected_display_paths=()
    for idx in "${selected_indices[@]}"; do
        local selected_size_kb="${item_sizes[idx]:-0}"
        [[ "$selected_size_kb" =~ ^[0-9]+$ ]] || selected_size_kb=0
        selected_total_kb=$((selected_total_kb + selected_size_kb))
        if [[ "${item_size_unknown_flags[idx]:-false}" == "true" ]]; then
            selected_unknown_count=$((selected_unknown_count + 1))
        fi
        selected_display_paths+=("${item_display_paths[idx]}")
    done

    if [[ -t 0 ]]; then
        if ! confirm_purge_cleanup "${#selected_indices[@]}" "$selected_total_kb" "$selected_unknown_count" "${selected_display_paths[@]}"; then
            echo -e "${GRAY}Purge cancelled${NC}"
            printf '\n'
            PURGE_CATEGORY_FULL_PATHS_ARRAY=()
            unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_SELECTION_RESULT
            return 1
        fi
    fi
    PURGE_CATEGORY_FULL_PATHS_ARRAY=()

    # Clean selected items
    echo ""
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    local cleaned_count=0
    local dry_run_mode="${MOLE_DRY_RUN:-0}"
    for idx in "${selected_indices[@]}"; do
        local item_path="${item_paths[idx]}"
        local display_item_path
        display_item_path=$(format_purge_target_path "$item_path")
        local size_kb="${item_sizes[idx]}"
        local size_unknown="${item_size_unknown_flags[idx]:-false}"
        local size_human
        if [[ "$size_unknown" == "true" ]]; then
            size_human="unknown"
        else
            size_human=$(bytes_to_human "$((size_kb * 1024))")
        fi
        # Safety checks
        if [[ -z "$item_path" || "$item_path" == "/" || "$item_path" == "$HOME" || "$item_path" != "$HOME/"* ]]; then
            continue
        fi
        if [[ -t 1 ]]; then
            start_inline_spinner "Cleaning $display_item_path..."
        fi
        local removal_recorded=false
        if [[ -e "$item_path" ]]; then
            if safe_remove "$item_path" true; then
                if [[ "$dry_run_mode" == "1" || ! -e "$item_path" ]]; then
                    local current_total
                    current_total=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
                    echo "$((current_total + size_kb))" > "$stats_dir/purge_stats"
                    cleaned_count=$((cleaned_count + 1))
                    removal_recorded=true
                fi
            fi
        fi
        if [[ -t 1 ]]; then
            stop_inline_spinner
            if [[ "$removal_recorded" == "true" ]]; then
                if [[ "$dry_run_mode" == "1" ]]; then
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} [DRY RUN] $display_item_path${NC}, ${GREEN}$size_human${NC}"
                else
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} $display_item_path${NC}, ${GREEN}$size_human${NC}"
                fi
            fi
        fi
    done
    # Update count
    echo "$cleaned_count" > "$stats_dir/purge_count"
    unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_SELECTION_RESULT
}
