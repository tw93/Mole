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

# Targets to look for (heavy build artifacts).
readonly PURGE_TARGETS=(
    "node_modules"
    "target"        # Rust, Maven
    "build"         # Gradle, various
    "dist"          # JS builds
    "venv"          # Python
    ".venv"         # Python
    ".pytest_cache" # Python (pytest)
    ".mypy_cache"   # Python (mypy)
    ".tox"          # Python (tox virtualenvs)
    ".nox"          # Python (nox virtualenvs)
    ".ruff_cache"   # Python (ruff)
    ".gradle"       # Gradle local
    "__pycache__"   # Python
    ".next"         # Next.js
    ".nuxt"         # Nuxt.js
    ".output"       # Nuxt.js
    "vendor"        # PHP Composer
    "bin"           # .NET build output (guarded; see is_protected_purge_artifact)
    "obj"           # C# / Unity
    ".turbo"        # Turborepo cache
    ".parcel-cache" # Parcel bundler
    ".dart_tool"    # Flutter/Dart build cache
    ".zig-cache"    # Zig
    "zig-out"       # Zig
    ".angular"      # Angular
    ".svelte-kit"   # SvelteKit
    ".astro"        # Astro
    "coverage"      # Code coverage reports
)
# Minimum age in days before considering for cleanup.
readonly MIN_AGE_DAYS=7
# Scan depth defaults (relative to search root).
readonly PURGE_MIN_DEPTH_DEFAULT=1
readonly PURGE_MAX_DEPTH_DEFAULT=6
# Search paths (default, can be overridden via config file).
readonly DEFAULT_PURGE_SEARCH_PATHS=(
    "$HOME/www"
    "$HOME/dev"
    "$HOME/Projects"
    "$HOME/GitHub"
    "$HOME/Code"
    "$HOME/Workspace"
    "$HOME/Repos"
    "$HOME/Development"
)

# Config file for custom purge paths.
readonly PURGE_CONFIG_FILE="$HOME/.config/mole/purge_paths"

# Resolved search paths.
PURGE_SEARCH_PATHS=()

# Project indicators for container detection.
# Monorepo indicators (higher priority)
readonly MONOREPO_INDICATORS=(
    "lerna.json"
    "pnpm-workspace.yaml"
    "nx.json"
    "rush.json"
)

readonly PROJECT_INDICATORS=(
    "package.json"
    "Cargo.toml"
    "go.mod"
    "pyproject.toml"
    "requirements.txt"
    "pom.xml"
    "build.gradle"
    "Gemfile"
    "composer.json"
    "pubspec.yaml"
    "Makefile"
    "build.zig"
    "build.zig.zon"
    ".git"
)

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

# Save discovered paths to config.
save_discovered_paths() {
    local -a paths=("$@")

    ensure_user_dir "$(dirname "$PURGE_CONFIG_FILE")"

    cat > "$PURGE_CONFIG_FILE" << 'EOF'
# Mole Purge Paths - Auto-discovered project directories
# Edit this file to customize, or run: mo purge --paths
# Add one path per line (supports ~ for home directory)
EOF

    printf '\n' >> "$PURGE_CONFIG_FILE"
    for path in "${paths[@]}"; do
        # Convert $HOME to ~ for portability
        path="${path/#$HOME/~}"
        echo "$path" >> "$PURGE_CONFIG_FILE"
    done
}

# Load purge paths from config or auto-discover
load_purge_config() {
    PURGE_SEARCH_PATHS=()

    if [[ -f "$PURGE_CONFIG_FILE" ]]; then
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"

            [[ -z "$line" || "$line" =~ ^# ]] && continue

            line="${line/#\~/$HOME}"

            PURGE_SEARCH_PATHS+=("$line")
        done < "$PURGE_CONFIG_FILE"
    fi

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
            save_discovered_paths "${discovered[@]}"

            if [[ -t 1 ]] && [[ -z "${_PURGE_DISCOVERY_SILENT:-}" ]]; then
                echo -e "${GRAY}Found ${#discovered[@]} project directories, saved to config${NC}" >&2
            fi
        else
            PURGE_SEARCH_PATHS=("${DEFAULT_PURGE_SEARCH_PATHS[@]}")
        fi
    fi
}

# Initialize paths on script load.
load_purge_config

# Args: $1 - path to check
# Safe cleanup requires the path be inside a project directory.
is_safe_project_artifact() {
    local path="$1"
    local search_path="$2"
    if [[ "$path" != /* ]]; then
        return 1
    fi
    # Must not be a direct child of the search root.
    local relative_path="${path#"$search_path"/}"
    local depth=$(echo "$relative_path" | LC_ALL=C tr -cd '/' | wc -c)
    if [[ $depth -lt 1 ]]; then
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
                    local project_dir=$(dirname "$item")
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
        # Escape regex special characters in target names for fd patterns
        local escaped_targets=()
        for target in "${PURGE_TARGETS[@]}"; do
            escaped_targets+=("^$(printf '%s' "$target" | sed -e 's/[][(){}.^$*+?|\\]/\\&/g')\$")
        done
        local pattern="($(
            IFS='|'
            echo "${escaped_targets[*]}"
        ))"
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

        command find "$search_path" -mindepth "$min_depth" -maxdepth "$max_depth" -type d \
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
    local age_days=$MIN_AGE_DAYS
    if [[ ! -e "$path" ]]; then
        return 1
    fi
    local mod_time
    mod_time=$(get_file_mtime "$path")
    local current_time
    current_time=$(get_epoch_seconds)
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
    if [[ -d "$path" ]]; then
        du -skP "$path" 2> /dev/null | awk '{print $1}' || echo "0"
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
        local reserved=6
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
                ((selected_count++))
            fi
        done
        local selected_gb
        selected_gb=$(printf "%.1f" "$(echo "scale=2; $selected_size/1024/1024" | bc)")

        # Show position indicator if scrolling is needed
        local scroll_indicator=""
        if [[ $total_items -gt $items_per_page ]]; then
            local current_pos=$((top_index + cursor_pos + 1))
            scroll_indicator=" ${GRAY}[${current_pos}/${total_items}]${NC}"
        fi

        printf "%s\n" "$clear_line"
        printf "%s${PURPLE_BOLD}Select Categories to Clean${NC}%s ${GRAY}, ${selected_gb}GB, ${selected_count} selected${NC}\n" "$clear_line" "$scroll_indicator"
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

        # Fill empty slots to clear previous content
        local items_shown=$visible_count
        for ((i = items_shown; i < items_per_page; i++)); do
            printf "%s\n" "$clear_line"
        done

        printf "%s\n" "$clear_line"

        printf "%s${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit${NC}\n" "$clear_line"
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
                            if [[ $cursor_pos -gt 0 ]]; then
                                ((cursor_pos--))
                            elif [[ $top_index -gt 0 ]]; then
                                ((top_index--))
                            fi
                            ;;
                        B) # Down arrow
                            local absolute_index=$((top_index + cursor_pos))
                            local last_index=$((total_items - 1))
                            if [[ $absolute_index -lt $last_index ]]; then
                                local visible_count=$((total_items - top_index))
                                [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                                if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                                    ((cursor_pos++))
                                elif [[ $((top_index + visible_count)) -lt $total_items ]]; then
                                    ((top_index++))
                                fi
                            fi
                            ;;
                    esac
                else
                    # ESC alone (no following chars)
                    restore_terminal
                    return 1
                fi
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
        # Clean up purge scanning file
        local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
        rm -f "$stats_dir/purge_scanning" 2> /dev/null || true
        echo ""
        exit 130
    }
    trap cleanup_scan INT TERM
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
        # Clear the scanning line but preserve the title
        printf '\n\033[K'
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
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No old project artifacts to clean"
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
    # For ~/work/code/MyProject/node_modules -> returns "MyProject"
    # Strategy: Find the nearest ancestor directory containing a project indicator file
    get_project_name() {
        local path="$1"

        local current_dir
        current_dir=$(dirname "$path")
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
            local depth=$(echo "${current_dir#"$HOME"}" | LC_ALL=C tr -cd '/' | wc -c | tr -d ' ')
            if [[ -n "$project_root" && $depth -lt 2 ]]; then
                break
            fi

            current_dir=$(dirname "$current_dir")
        done

        # Determine result: monorepo > project > fallback
        local result=""
        if [[ -n "$monorepo_root" ]]; then
            result=$(basename "$monorepo_root")
        elif [[ -n "$project_root" ]]; then
            result=$(basename "$project_root")
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
                    result=$(echo "$relative_path" | cut -d'/' -f1)
                    break
                fi
            done

            # Final fallback: use grandparent directory
            if [[ -z "$result" ]]; then
                result=$(dirname "$(dirname "$path")" | xargs basename)
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

        local current_dir
        current_dir=$(dirname "$path")
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
            local depth=$(echo "${current_dir#"$HOME"}" | LC_ALL=C tr -cd '/' | wc -c | tr -d ' ')
            if [[ -n "$project_root" && $depth -lt 2 ]]; then
                break
            fi

            current_dir=$(dirname "$current_dir")
        done

        # Determine result: monorepo > project > fallback
        local result=""
        if [[ -n "$monorepo_root" ]]; then
            result="$monorepo_root"
        elif [[ -n "$project_root" ]]; then
            result="$project_root"
        else
            # Fallback: use parent directory of artifact
            result=$(dirname "$path")
        fi

        # Convert to ~ format for cleaner display
        result="${result/#$HOME/~}"
        echo "$result"
    }

    # Helper to get artifact display name
    # For duplicate artifact names within same project, include parent directory for context
    get_artifact_display_name() {
        local path="$1"
        local artifact_name=$(basename "$path")
        local project_name=$(get_project_name "$path")
        local parent_name=$(basename "$(dirname "$path")")

        # Check if there are other items with same artifact name AND same project
        local has_duplicate=false
        for other_item in "${safe_to_clean[@]}"; do
            if [[ "$other_item" != "$path" && "$(basename "$other_item")" == "$artifact_name" ]]; then
                # Same artifact name, check if same project
                if [[ "$(get_project_name "$other_item")" == "$project_name" ]]; then
                    has_duplicate=true
                    break
                fi
            fi
        done

        # If duplicate exists in same project and parent is not the project itself, show parent/artifact
        if [[ "$has_duplicate" == "true" && "$parent_name" != "$project_name" && "$parent_name" != "." && "$parent_name" != "/" ]]; then
            echo "$parent_name/$artifact_name"
        else
            echo "$artifact_name"
        fi
    }
    # Format display with alignment (like app_selector)
    format_purge_display() {
        local project_path="$1"
        local artifact_type="$2"
        local size_str="$3"
        # Terminal width for alignment
        local terminal_width=$(tput cols 2> /dev/null || echo 80)
        local fixed_width=32 # Reserve for size and artifact type (9 + 3 + 20)
        local available_width=$((terminal_width - fixed_width))
        # Bounds: 30 chars min, but cap at 70% of terminal width to preserve aesthetics
        local max_aesthetic_width=$((terminal_width * 70 / 100))
        [[ $available_width -gt $max_aesthetic_width ]] && available_width=$max_aesthetic_width
        [[ $available_width -lt 30 ]] && available_width=30
        # Truncate project path if needed
        local truncated_path=$(truncate_by_display_width "$project_path" "$available_width")
        local current_width=$(get_display_width "$truncated_path")
        local char_count=${#truncated_path}
        local padding=$((available_width - current_width))
        local printf_width=$((char_count + padding))
        # Format: "project_path  size | artifact_type"
        printf "%-*s %9s | %-17s" "$printf_width" "$truncated_path" "$size_str" "$artifact_type"
    }
    # Build menu options - one line per artifact
    for item in "${safe_to_clean[@]}"; do
        local project_path=$(get_project_path "$item")
        local artifact_type=$(get_artifact_display_name "$item")
        local size_kb=$(get_dir_size_kb "$item")

        # Skip empty directories (0 bytes)
        if [[ $size_kb -eq 0 ]]; then
            continue
        fi

        local size_human=$(bytes_to_human "$((size_kb * 1024))")
        # Check if recent
        local is_recent=false
        for recent_item in "${recently_modified[@]+"${recently_modified[@]}"}"; do
            if [[ "$item" == "$recent_item" ]]; then
                is_recent=true
                break
            fi
        done
        menu_options+=("$(format_purge_display "$project_path" "$artifact_type" "$size_human")")
        item_paths+=("$item")
        item_sizes+=("$size_kb")
        item_recent_flags+=("$is_recent")
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
        local -a sorted_item_recent_flags=()

        for idx in "${sorted_indices[@]}"; do
            sorted_menu_options+=("${menu_options[idx]}")
            sorted_item_paths+=("${item_paths[idx]}")
            sorted_item_sizes+=("${item_sizes[idx]}")
            sorted_item_recent_flags+=("${item_recent_flags[idx]}")
        done

        # Replace original arrays with sorted versions
        menu_options=("${sorted_menu_options[@]}")
        item_paths=("${sorted_item_paths[@]}")
        item_sizes=("${sorted_item_sizes[@]}")
        item_recent_flags=("${sorted_item_recent_flags[@]}")
    fi
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
        local project_path=$(get_project_path "$item_path")
        local size_kb="${item_sizes[idx]}"
        local size_human=$(bytes_to_human "$((size_kb * 1024))")
        # Safety checks
        if [[ -z "$item_path" || "$item_path" == "/" || "$item_path" == "$HOME" || "$item_path" != "$HOME/"* ]]; then
            continue
        fi
        if [[ -t 1 ]]; then
            start_inline_spinner "Cleaning $project_path/$artifact_type..."
        fi
        if [[ -e "$item_path" ]]; then
            safe_remove "$item_path" true
            if [[ ! -e "$item_path" ]]; then
                local current_total=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
                echo "$((current_total + size_kb))" > "$stats_dir/purge_stats"
                ((cleaned_count++))
            fi
        fi
        if [[ -t 1 ]]; then
            stop_inline_spinner
            echo -e "${GREEN}${ICON_SUCCESS}${NC} $project_path, $artifact_type${NC}, ${GREEN}$size_human${NC}"
        fi
    done
    # Update count
    echo "$cleaned_count" > "$stats_dir/purge_count"
    unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_SELECTION_RESULT
}
