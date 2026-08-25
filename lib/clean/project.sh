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
PURGE_CATEGORY_PROJECT_IDS_ARRAY=()
PURGE_CATEGORY_PROJECT_PATHS_ARRAY=()
PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=()

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
    # Package-manager directories: they contain package.json/composer.json
    # but are not project containers; deleting their children leaves
    # packages half-installed and requires a network restore.
    [[ "$basename" == "node_modules" ]] && return 1
    [[ "$basename" == "vendor" ]] && return 1
    [[ "$basename" == "Pods" ]] && return 1

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
            # Resolve to canonical casing to avoid duplicates on
            # case-insensitive filesystems (macOS APFS).
            discovered+=("$(mole_purge_resolve_path_case "$path")")
        fi
    done

    # Scan $HOME for other containers (depth 1).
    local dir
    for dir in "$HOME"/*/; do
        [[ ! -d "$dir" ]] && continue
        dir="${dir%/}" # Remove trailing slash
        # Resolve casing so that ~/code and ~/Code compare equal.
        dir=$(mole_purge_resolve_path_case "$dir")

        local already_found=false
        for existing in "${discovered[@]+"${discovered[@]}"}"; do
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

    printf '%s\n' "${discovered[@]+"${discovered[@]}"}" | sort -u
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

    # Guard empty-array expansion under `set -u` on bash 3.2 (first-run case
    # from `mo purge --paths` passes only the header with no paths).
    if [[ ${#paths[@]} -gt 0 ]]; then
        for path in "${paths[@]}"; do
            # Convert $HOME to ~ for portability
            path="${path/#$HOME/~}"
            if ! printf '%s\n' "$path" >> "$tmp_file"; then
                rm -f "$tmp_file" 2> /dev/null || true
                return 1
            fi
        done
    fi

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

    local line existing_path already_found
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # mole_purge_read_paths_config already folds case variants to the
        # on-disk path, so a config listing ~/code and ~/Code yields the
        # same resolved string twice. Drop the duplicate here so downstream
        # scans and the menu show each path once (#1416).
        already_found=false
        for existing_path in "${PURGE_SEARCH_PATHS[@]+"${PURGE_SEARCH_PATHS[@]}"}"; do
            if [[ "$line" == "$existing_path" ]]; then
                already_found=true
                break
            fi
        done
        [[ "$already_found" == "true" ]] && continue
        PURGE_SEARCH_PATHS+=("$line")
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

    local lexically_contained=false
    [[ "$path" == "$search_path/"* ]] && lexically_contained=true

    # Always compare existing directories physically. A lexical prefix alone
    # is not containment when any ancestor is a symlink; it can otherwise turn
    # a configured project root into authority over an unrelated directory.
    # This also preserves aliases such as /var -> /private/var because both
    # sides are resolved before the comparison.
    if [[ -d "$path" && -d "$search_path" ]]; then
        local physical_path=""
        local physical_search_path=""
        physical_path=$(cd "$path" 2> /dev/null && pwd -P) || return 1
        physical_search_path=$(cd "$search_path" 2> /dev/null && pwd -P) || return 1

        if [[ -z "$physical_path" || -z "$physical_search_path" || "$physical_path" != "$physical_search_path/"* ]]; then
            return 1
        fi

        path="$physical_path"
        search_path="$physical_search_path"
    elif [[ "$lexically_contained" != "true" ]]; then
        return 1
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

# Revalidate a selected artifact against the configured scan roots immediately
# before deletion. Purge supports explicit roots outside HOME (for example
# /var/www), so HOME containment is neither sufficient nor correct here.
is_safe_configured_purge_artifact() {
    local path="$1"

    [[ -n "$path" && "$path" != "/" && "$path" != "$HOME" ]] || return 1
    [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]] || return 1

    local search_path
    for search_path in "${PURGE_SEARCH_PATHS[@]}"; do
        [[ -n "$search_path" ]] || continue
        if is_safe_project_artifact "$path" "$search_path"; then
            return 0
        fi
    done

    return 1
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
    local target_output="${output_file}.targets"
    local tag_output="${output_file}.tags"
    local processed_output="${output_file}.processed"
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

    # A scan result is publishable only after every producer and filter for the
    # root completes. Keep the caller-visible file empty until that point so a
    # timeout or read failure cannot turn a partial prefix into delete candidates.
    : > "$output_file"
    rm -f "$target_output" "$tag_output" "$processed_output" 2> /dev/null || true

    local cachedir_tag_min_depth=$((min_depth + 1))
    local cachedir_tag_max_depth=$((max_depth + 1))

    # Update current scanning path
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    echo "$search_path" > "$stats_dir/purge_scanning" 2> /dev/null || true

    emit_valid_cachedir_tag_dirs() {
        while IFS= read -r tag_file; do
            [[ -n "$tag_file" ]] || continue
            local cache_dir="${tag_file%/*}"
            if [[ -n "$cache_dir" ]] && mole_dir_has_cachedir_tag "$cache_dir"; then
                printf '%s\n' "$cache_dir"
            fi
        done
    }

    # Helper to process raw results
    process_scan_results() {
        local input_file="$1"
        if [[ -f "$input_file" ]]; then
            local process_status=0
            (
                while IFS= read -r item; do
                    # Check if we should abort (scanning file removed by Ctrl+C)
                    if [[ ! -f "$stats_dir/purge_scanning" ]]; then
                        exit 130
                    fi

                    if [[ -n "$item" ]] && is_safe_project_artifact "$item" "$search_path"; then
                        echo "$item"
                        # Update scanning path to show current project directory
                        local project_dir="${item%/*}"
                        echo "$project_dir" > "$stats_dir/purge_scanning" 2> /dev/null || true
                    fi
                done < "$input_file"
            ) | filter_nested_artifacts | filter_protected_artifacts > "$processed_output" || process_status=$?

            if [[ $process_status -ne 0 ]]; then
                rm -f "$processed_output" 2> /dev/null || true
                return "$process_status"
            fi
            if ! mv "$processed_output" "$output_file"; then
                rm -f "$processed_output" 2> /dev/null || true
                return 1
            fi
        else
            return 1
        fi
    }

    cleanup_scan_outputs() {
        rm -f "$target_output" "$tag_output" "$processed_output" 2> /dev/null || true
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
        local fd_tag_args=(
            "--absolute-path"
            "--hidden"
            "--no-ignore"
            "--type" "f"
            "--min-depth" "$cachedir_tag_min_depth"
            "--max-depth" "$cachedir_tag_max_depth"
            "--threads" "8"
            "--exclude" ".git"
            "--exclude" "Library"
            "--exclude" ".Trash"
            "--exclude" "Applications"
        )

        # Trust fd when it exits successfully, including an empty result set.
        # Empty scans are common in healthy project trees; falling back to find
        # doubles the scan cost and can make "nothing to clean" feel slow.
        local _scan_timeout="${MO_PURGE_SCAN_TIMEOUT_SEC:-60}"
        local fd_status=0
        run_with_timeout "$_scan_timeout" fd "${fd_args[@]}" "$pattern" "$search_path" \
            2> /dev/null > "$target_output" || fd_status=$?
        if [[ $fd_status -eq 0 ]]; then
            run_with_timeout "$_scan_timeout" fd "${fd_tag_args[@]}" "^${MOLE_CACHEDIR_TAG_NAME}$" "$search_path" \
                2> /dev/null > "$tag_output" || fd_status=$?
        fi
        if [[ $fd_status -eq 0 ]]; then
            emit_valid_cachedir_tag_dirs < "$tag_output" >> "$target_output" || fd_status=$?
        fi
        if [[ $fd_status -eq 0 ]]; then
            process_scan_results "$target_output" || fd_status=$?
        fi
        if [[ $fd_status -eq 0 ]]; then
            debug_log "Using fd for scanning"
            cleanup_scan_outputs
            use_find=false
        else
            debug_log "fd scan failed (status $fd_status), falling back to find"
            cleanup_scan_outputs
            : > "$output_file"
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
        local _scan_timeout="${MO_PURGE_SCAN_TIMEOUT_SEC:-60}"
        local find_status=0
        run_with_timeout "$_scan_timeout" find "$search_path" -mindepth "$min_depth" -maxdepth "$max_depth" -type d \
            \( "${prune_expr[@]}" \) -prune -o \
            \( "${target_expr[@]}" \) -print -prune \
            2> /dev/null > "$target_output" || find_status=$?

        if [[ $find_status -eq 0 ]]; then
            run_with_timeout "$_scan_timeout" find "$search_path" -mindepth "$cachedir_tag_min_depth" -maxdepth "$cachedir_tag_max_depth" \
                \( "${prune_expr[@]}" \) -prune -o \
                -type f -name "$MOLE_CACHEDIR_TAG_NAME" -print \
                2> /dev/null > "$tag_output" || find_status=$?
        fi
        if [[ $find_status -eq 0 ]]; then
            emit_valid_cachedir_tag_dirs < "$tag_output" >> "$target_output" || find_status=$?
        fi
        if [[ $find_status -eq 0 ]]; then
            process_scan_results "$target_output" || find_status=$?
        fi

        cleanup_scan_outputs
        if [[ $find_status -ne 0 ]]; then
            : > "$output_file"
            debug_log "find scan failed (status $find_status): $search_path"
            return "$find_status"
        fi
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
# Args: $1 - path, $2 - optional current epoch
# Classify artifact activity as recent, old, or uncertain. Only a complete
# bounded scan may return old; timeouts and read failures fail closed.
classify_purge_activity() {
    local path="$1"
    local current_time="${2:-}"
    local age_days=$MIN_AGE_DAYS
    _PURGE_ACTIVITY_STATE="uncertain"

    if [[ ! -e "$path" ]]; then
        _PURGE_ACTIVITY_STATE="old"
        return 0
    fi

    local mod_time
    mod_time=$(get_file_mtime "$path" 2> /dev/null || true)
    if [[ ! "$mod_time" =~ ^[0-9]+$ ]]; then
        debug_log "Unable to read purge activity timestamp: $path"
        return 0
    fi
    if [[ -z "$current_time" || ! "$current_time" =~ ^[0-9]+$ ]]; then
        current_time=$(get_epoch_seconds)
    fi

    local age_seconds=$((current_time - mod_time))
    local age_in_days=$((age_seconds / 86400))
    if [[ $age_in_days -lt $age_days ]]; then
        _PURGE_ACTIVITY_STATE="recent"
        return 0
    fi

    if [[ ! -d "$path" ]]; then
        _PURGE_ACTIVITY_STATE="old"
        return 0
    fi

    local probe_timeout="${MO_PURGE_ACTIVITY_TIMEOUT_SEC:-$MOLE_TIMEOUT_MEDIUM_PROBE_SEC}"
    if [[ ! "$probe_timeout" =~ ^[1-9][0-9]*$ ]]; then
        probe_timeout="$MOLE_TIMEOUT_MEDIUM_PROBE_SEC"
    fi

    # clean_project_artifacts sets one deadline for the whole classification
    # pass. A standalone caller still gets the per-item ceiling above.
    if [[ "${_PURGE_ACTIVITY_DEADLINE_EPOCH:-}" =~ ^[0-9]+$ ]]; then
        local now_epoch remaining
        now_epoch=$(get_epoch_seconds)
        remaining=$((_PURGE_ACTIVITY_DEADLINE_EPOCH - now_epoch))
        if [[ $remaining -le 0 ]]; then
            debug_log "Purge activity scan budget exhausted before: $path"
            return 0
        fi
        if [[ $probe_timeout -gt $remaining ]]; then
            probe_timeout=$remaining
        fi
    fi

    local recent_file=""
    local probe_status=0
    recent_file=$(run_with_timeout "$probe_timeout" \
        find "$path" -type f -mtime "-$age_days" -print -quit 2> /dev/null) || probe_status=$?

    if [[ $probe_status -ne 0 ]]; then
        debug_log "Purge activity scan failed closed (exit $probe_status): $path"
        return 0
    fi
    if [[ -n "$recent_file" ]]; then
        _PURGE_ACTIVITY_STATE="recent"
    else
        _PURGE_ACTIVITY_STATE="old"
    fi
}

# Args: $1 - path, $2 - optional current epoch
# Check whether a path must be protected from default purge selection.
is_recently_modified() {
    classify_purge_activity "$@"
    [[ "$_PURGE_ACTIVITY_STATE" != "old" ]]
}

# An artifact that was old when the menu opened can become active before the
# user confirms deletion. Recheck only those default-safe rows; a user who
# explicitly selected an already-recent row has already overridden that hint.
purge_target_activity_still_safe() {
    local path="$1"
    local was_recent="${2:-true}"
    [[ "$was_recent" == "true" ]] && return 0

    # Do not inherit the menu pass's expired shared deadline.
    local _PURGE_ACTIVITY_DEADLINE_EPOCH=""
    local _PURGE_ACTIVITY_STATE="uncertain"
    if is_recently_modified "$path" "$(get_epoch_seconds)"; then
        return 1
    fi
    # Preserve the established test/caller seam where an override returning 1
    # means old without setting the newer classification detail.
    [[ "$_PURGE_ACTIVITY_STATE" == "old" || "$_PURGE_ACTIVITY_STATE" == "uncertain" ]]
}

# Final safe_remove hook for purge. Candidate identity is checked separately by
# safe_remove; this hook rebinds the policy that depends on current contents so
# a project cannot become active or protected in the last pre-delete window.
_mole_purge_final_remove_guard() {
    local path="$1"
    is_safe_configured_purge_artifact "$path" || return 1
    is_protected_purge_artifact "$path" && return 1
    purge_target_activity_still_safe "$path" "${_MOLE_PURGE_FINAL_WAS_RECENT:-true}"
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
        debug_log "Size calculation failed (exit $du_exit): $path"
        echo "ERROR"
        return
    fi

    local size_kb
    size_kb=$(printf '%s\n' "$du_output" | awk 'NR==1 {print $1; exit}')
    if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
        echo "$size_kb"
    else
        debug_log "Size calculation returned invalid output: $path"
        echo "ERROR"
    fi
}

# Resolve the owning project for a purge artifact. Monorepo indicators take
# precedence so every artifact in one workspace shares the same identity.
find_purge_project_root_for_artifact() {
    local path="$1"
    local current_dir="${path%/*}"
    [[ -z "$current_dir" ]] && current_dir="/"
    local monorepo_root=""
    local project_root=""

    while [[ "$current_dir" != "/" && "$current_dir" != "$HOME" && -n "$current_dir" ]]; do
        if [[ -z "$monorepo_root" ]]; then
            for indicator in "${MONOREPO_INDICATORS[@]}"; do
                if [[ -e "$current_dir/$indicator" ]]; then
                    monorepo_root="$current_dir"
                    break
                fi
            done
        fi

        if [[ -z "$project_root" ]]; then
            for indicator in "${PROJECT_INDICATORS[@]}"; do
                if [[ -e "$current_dir/$indicator" ]]; then
                    project_root="$current_dir"
                    break
                fi
            done
        fi

        if [[ -n "$monorepo_root" ]]; then
            break
        fi

        local relative_to_home="${current_dir#"$HOME"}"
        local without_slashes="${relative_to_home//\//}"
        local depth=$((${#relative_to_home} - ${#without_slashes}))
        if [[ -n "$project_root" && $depth -lt 2 ]]; then
            break
        fi

        local parent="${current_dir%/*}"
        current_dir="${parent:-/}"
    done

    if [[ -n "$monorepo_root" ]]; then
        printf '%s\n' "$monorepo_root"
        return 0
    fi

    if [[ -n "$project_root" ]]; then
        printf '%s\n' "$project_root"
        return 0
    fi

    return 1
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
        # Title, footer context, full path, controls, and spacing. The project
        # context can use two lines on narrow terminals.
        local reserved=10
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

        # Clear traps first to prevent re-entrant firing during eval below.
        trap - EXIT INT TERM

        # Restore terminal state before re-installing caller traps, so the
        # terminal is always usable even if a restored trap handler exits.
        show_cursor
        if [[ -n "${original_stty:-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || true
        fi

        # Snapshot and clear saved traps before eval to prevent infinite
        # recursion if the restored handler triggers another signal.
        local _prev_exit="$previous_exit_trap"
        local _prev_int="$previous_int_trap"
        local _prev_term="$previous_term_trap"
        previous_exit_trap=""
        previous_int_trap=""
        previous_term_trap=""
        # eval: restore caller traps captured by $(trap -p)
        [[ -n "$_prev_exit" ]] && eval "$_prev_exit"
        [[ -n "$_prev_int" ]] && eval "$_prev_int"
        [[ -n "$_prev_term" ]] && eval "$_prev_term"
        return 0
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

        printf "%s${PURPLE_BOLD}Select Artifacts to Purge${NC}%s${GRAY}, ${selected_size_human}, ${selected_count} selected${NC}\n" "$clear_line" "$scroll_indicator"
        printf "%s\n" "$clear_line"

        IFS=',' read -r -a recent_flags <<< "${PURGE_RECENT_CATEGORIES:-}"
        IFS=',' read -r -a age_labels <<< "${PURGE_AGE_LABELS:-}"

        # Calculate visible range
        local end_index=$((top_index + visible_count))

        # Draw only visible items
        for ((i = top_index; i < end_index; i++)); do
            local checkbox="$ICON_EMPTY"
            [[ ${selected[i]} == true ]] && checkbox="$ICON_SOLID"
            local group_marker="─"
            local row_project_id="${PURGE_CATEGORY_PROJECT_IDS_ARRAY[i]:-}"
            if [[ -n "$row_project_id" ]]; then
                local previous_same_project=false
                local next_same_project=false
                if [[ $i -gt 0 && "${PURGE_CATEGORY_PROJECT_IDS_ARRAY[i - 1]:-}" == "$row_project_id" ]]; then
                    previous_same_project=true
                fi
                if [[ $i -lt $((total_items - 1)) && "${PURGE_CATEGORY_PROJECT_IDS_ARRAY[i + 1]:-}" == "$row_project_id" ]]; then
                    next_same_project=true
                fi
                if [[ "$previous_same_project" == "true" && "$next_same_project" == "true" ]]; then
                    group_marker="├"
                elif [[ "$next_same_project" == "true" ]]; then
                    group_marker="┌"
                elif [[ "$previous_same_project" == "true" ]]; then
                    group_marker="└"
                fi
            fi
            local recent_marker=""
            local _age="${age_labels[i]:-}"
            [[ -n "$_age" ]] && recent_marker=" ${GRAY}| ${_age}${NC}"
            local rel_pos=$((i - top_index))
            if [[ $rel_pos -eq $cursor_pos ]]; then
                printf "%s${CYAN}${ICON_ARROW} %s %s %s%s${NC}\n" "$clear_line" "$checkbox" "$group_marker" "${categories[i]}" "$recent_marker"
            else
                printf "%s  %s %s %s%s\n" "$clear_line" "$checkbox" "$group_marker" "${categories[i]}" "$recent_marker"
            fi
        done

        # Keep one blank line between the list and footer tips.
        printf "%s\n" "$clear_line"

        local _term_w
        _term_w=$(tput cols 2> /dev/null || echo 80)
        [[ "$_term_w" =~ ^[0-9]+$ ]] || _term_w=80

        local current_index=$((top_index + cursor_pos))
        local current_project_id="${PURGE_CATEGORY_PROJECT_IDS_ARRAY[current_index]:-}"
        local current_project_path="${PURGE_CATEGORY_PROJECT_PATHS_ARRAY[current_index]:-}"
        if [[ -n "$current_project_path" ]]; then
            local group_size=0
            local group_item_count=0
            local group_selected_count=0
            local group_has_unknown_size=false
            for ((i = 0; i < total_items; i++)); do
                if { [[ -n "$current_project_id" ]] && [[ "${PURGE_CATEGORY_PROJECT_IDS_ARRAY[i]:-}" == "$current_project_id" ]]; } || { [[ -z "$current_project_id" ]] && [[ $i -eq $current_index ]]; }; then
                    group_item_count=$((group_item_count + 1))
                    group_size=$((group_size + ${sizes[i]:-0}))
                    [[ ${selected[i]} == true ]] && group_selected_count=$((group_selected_count + 1))
                    [[ "${PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY[i]:-false}" == "true" ]] && group_has_unknown_size=true
                fi
            done

            local group_size_label
            group_size_label=$(bytes_to_human_kb "$group_size")
            if [[ "$group_has_unknown_size" == "true" ]]; then
                if [[ $group_size -gt 0 ]]; then
                    group_size_label="${group_size_label} + unknown"
                else
                    group_size_label="unknown size"
                fi
            fi

            local project_label="Project: "
            local project_summary=" · ${group_size_label} · ${group_selected_count}/${group_item_count} selected"
            local project_path_width=$((_term_w - ${#project_label} - ${#project_summary}))
            if [[ $project_path_width -ge 12 ]]; then
                printf "%s${GRAY}%s${NC}%s%s\n" "$clear_line" "$project_label" "$(compact_purge_menu_path "$current_project_path" "$project_path_width")" "$project_summary"
            else
                project_path_width=$((_term_w - ${#project_label}))
                [[ $project_path_width -lt 4 ]] && project_path_width=4
                printf "%s${GRAY}%s${NC}%s\n" "$clear_line" "$project_label" "$(compact_purge_menu_path "$current_project_path" "$project_path_width")"
                printf "%s${GRAY}Group:${NC} %s · %s/%s selected\n" "$clear_line" "$group_size_label" "$group_selected_count" "$group_item_count"
            fi
        fi

        local current_full_path=""
        local paths_len="${#PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}"
        if [[ "$paths_len" -gt 0 && "$current_index" -lt "$paths_len" ]]; then
            current_full_path="${PURGE_CATEGORY_FULL_PATHS_ARRAY[current_index]}"
        fi
        if [[ -n "$current_full_path" ]]; then
            printf "%s${GRAY}Full path:${NC} %s\n" "$clear_line" "$current_full_path"
            printf "%s\n" "$clear_line"
        fi

        # Adaptive footer hints, mirrors menu_paginated.sh pattern
        local _sep=" ${GRAY}|${NC} "
        local _nav="${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}${NC}"
        local _space="${GRAY}Space Select${NC}"
        local _enter="${GRAY}Enter Confirm${NC}"
        local _all="${GRAY}A All${NC}"
        local _invert="${GRAY}I Invert${NC}"
        local _skip_project="${GRAY}X Skip Project${NC}"
        local _quit="${GRAY}Q Quit${NC}"

        # Strip ANSI to measure real length
        _ph_len() { printf "%s" "$1" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*[A-Za-z]/,""); printf "%d", length}'; }

        # Level 0 (full): ↑↓ | Space Select | Enter Confirm | A All | I Invert | X Skip Project | Q Quit
        local _full="${_nav}${_sep}${_space}${_sep}${_enter}${_sep}${_all}${_sep}${_invert}${_sep}${_skip_project}${_sep}${_quit}"
        if (($(_ph_len "$_full") <= _term_w)); then
            printf "%s${_full}${NC}\n" "$clear_line"
        else
            # Level 1: ↑↓ | Enter Confirm | A All | X Skip Project | Q Quit
            local _l1="${_nav}${_sep}${_enter}${_sep}${_all}${_sep}${_skip_project}${_sep}${_quit}"
            if (($(_ph_len "$_l1") <= _term_w)); then
                printf "%s${_l1}${NC}\n" "$clear_line"
            else
                # Level 2: keep the project action discoverable on narrow terminals.
                local _l2="${_nav}${_sep}${GRAY}Enter${NC}${_sep}${_skip_project}${_sep}${_quit}"
                if (($(_ph_len "$_l2") <= _term_w)); then
                    printf "%s${_l2}${NC}\n" "$clear_line"
                else
                    # Level 3 (minimal): ↑↓ | Enter | X Skip | Q
                    printf "%s${_nav}${_sep}${GRAY}Enter${NC}${_sep}${GRAY}X Skip${NC}${_sep}${GRAY}Q${NC}\n" "$clear_line"
                fi
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
            "x" | "X") # Deselect the current artifact's exact project
                local current_index=$((top_index + cursor_pos))
                local project_id="${PURGE_CATEGORY_PROJECT_IDS_ARRAY[current_index]:-}"
                if [[ -n "$project_id" ]]; then
                    for ((i = 0; i < total_items; i++)); do
                        if [[ "${PURGE_CATEGORY_PROJECT_IDS_ARRAY[i]:-}" == "$project_id" ]]; then
                            selected[i]=false
                        fi
                    done
                else
                    selected[current_index]=false
                fi
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
    local cloud_count="${4:-0}"
    local -a selected_paths=("${@:5}")

    [[ "$item_count" =~ ^[0-9]+$ ]] || item_count=0
    [[ "$total_size_kb" =~ ^[0-9]+$ ]] || total_size_kb=0
    [[ "$unknown_count" =~ ^[0-9]+$ ]] || unknown_count=0
    [[ "$cloud_count" =~ ^[0-9]+$ ]] || cloud_count=0

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

    if [[ $cloud_count -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}${ICON_WARNING}${NC} Cloud-synced artifacts may also be removed from other devices."
        echo -e "${GRAY}Use 'mo purge --paths' to exclude cloud storage roots.${NC}"
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

# Main cleanup function - scans and prompts user to select artifacts to clean.
# Sets PURGE_RUN_OUTCOME to completed, no_candidates, cancelled, or scan_failed.
clean_project_artifacts() {
    PURGE_RUN_OUTCOME="completed"
    local -a all_found_items=()
    local -a safe_to_clean=()
    local -a safe_recent_flags=()
    local -a safe_activity_states=()
    local -a safe_expected_parents=()
    local -a safe_expected_parent_ids=()
    local -a safe_expected_target_ids=()
    local previous_int_trap=""
    local previous_term_trap=""
    local trap_installed_by_this_call=false
    # Set up cleanup on interrupt
    # Note: Declared without 'local' so cleanup_scan trap can access them
    scan_pids=()
    scan_temps=()
    scan_roots=()
    _cleanup_scan_done=false
    # shellcheck disable=SC2329
    cleanup_scan() {
        [[ "$_cleanup_scan_done" == "true" ]] && return
        _cleanup_scan_done=true
        # Kill all background scans
        for pid in "${scan_pids[@]+"${scan_pids[@]}"}"; do
            kill "$pid" 2> /dev/null || true
        done
        # Clean up temp files
        for temp in "${scan_temps[@]+"${scan_temps[@]}"}"; do
            rm -f "$temp" "${temp}.targets" "${temp}.tags" "${temp}.processed" 2> /dev/null || true
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
    local -a scan_statuses=()
    local -a scan_root_parents=()
    local -a scan_root_parent_ids=()
    local -a scan_root_target_ids=()
    local -a failed_scan_roots=()
    local -a failed_scan_statuses=()
    local failed_scan_count=0
    local max_scan_jobs
    max_scan_jobs=$(get_optimal_parallel_jobs io)
    if ! [[ "$max_scan_jobs" =~ ^[0-9]+$ ]] || [[ "$max_scan_jobs" -lt 1 ]]; then
        max_scan_jobs=1
    elif [[ "$max_scan_jobs" -gt 4 ]]; then
        max_scan_jobs=4
    fi

    _wait_for_purge_scan_batch() {
        local pid
        for pid in "${scan_pids[@]+"${scan_pids[@]}"}"; do
            local scan_status=0
            if wait "$pid" 2> /dev/null; then
                scan_status=0
            else
                scan_status=$?
            fi
            scan_statuses+=("$scan_status")
        done
        scan_pids=()
    }

    # Scanning is started from purge.sh with start_inline_spinner
    # Keep root-level concurrency bounded because each fd scan has its own
    # worker pool. Batches preserve launch-order alignment with scan_statuses.
    for path in "${PURGE_SEARCH_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            if ! _mole_snapshot_path_identity "$path"; then
                failed_scan_count=$((failed_scan_count + 1))
                failed_scan_roots+=("$path")
                failed_scan_statuses+=("1")
                debug_log "Purge scan root identity unavailable: $path"
                continue
            fi
            local scan_output
            scan_output=$(mktemp)
            scan_temps+=("$scan_output")
            scan_roots+=("$path")
            scan_root_parents+=("$_MOLE_PATH_SNAPSHOT_PARENT")
            scan_root_parent_ids+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
            scan_root_target_ids+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
            # Launch scan in background for true parallelism
            scan_purge_targets "$path" "$scan_output" < /dev/null &
            local scan_pid=$!
            scan_pids+=("$scan_pid")
            if [[ ${#scan_pids[@]} -ge $max_scan_jobs ]]; then
                _wait_for_purge_scan_batch
            fi
        fi
    done
    _wait_for_purge_scan_batch

    # Stop the scanning monitor (removes purge_scanning file to signal completion)
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    rm -f "$stats_dir/purge_scanning" 2> /dev/null || true

    # Give monitor process time to exit and clear its output
    if [[ -t 1 ]]; then
        sleep 0.2
    fi

    # Collect all results and deduplicate once. This avoids an O(N²) shell loop
    # when overlapping search roots produce the same artifact many times.
    local dedupe_output
    dedupe_output=$(mktemp_file "mole-purge-dedupe") || return 1
    local completed_scan_count=0
    local scan_index
    for ((scan_index = 0; scan_index < ${#scan_temps[@]}; scan_index++)); do
        scan_output="${scan_temps[$scan_index]}"
        local scan_status="${scan_statuses[$scan_index]:-1}"
        if [[ $scan_status -eq 0 ]] && ! _mole_path_matches_identity \
            "${scan_roots[$scan_index]}" \
            "${scan_root_parents[$scan_index]}" \
            "${scan_root_parent_ids[$scan_index]}" \
            "${scan_root_target_ids[$scan_index]}"; then
            scan_status=1
            scan_statuses[scan_index]=1
            debug_log "Purge scan root changed before results were collected: ${scan_roots[$scan_index]}"
        fi
        if [[ $scan_status -eq 0 && ! -f "$scan_output" ]]; then
            scan_status=1
            scan_statuses[scan_index]=1
        fi
        if [[ $scan_status -eq 0 && -f "$scan_output" ]]; then
            if cat "$scan_output" >> "$dedupe_output"; then
                completed_scan_count=$((completed_scan_count + 1))
            else
                scan_status=1
                scan_statuses[scan_index]=1
                debug_log "Purge scan output unreadable: ${scan_roots[$scan_index]:-unknown root}"
            fi
        fi
        if [[ $scan_status -ne 0 || ! -f "$scan_output" ]]; then
            failed_scan_count=$((failed_scan_count + 1))
            failed_scan_roots+=("${scan_roots[$scan_index]:-unknown root}")
            failed_scan_statuses+=("$scan_status")
            debug_log "Purge scan incomplete (status $scan_status): ${scan_roots[$scan_index]:-unknown root}"
        fi
        rm -f "$scan_output" "${scan_output}.targets" "${scan_output}.tags" "${scan_output}.processed" 2> /dev/null || true
    done
    if [[ -s "$dedupe_output" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] && all_found_items+=("$item")
        done < <(LC_COLLATE=C sort -u "$dedupe_output")
    fi
    rm -f "$dedupe_output"
    # Restore caller traps after this function completes.
    if [[ "$trap_installed_by_this_call" == "true" ]]; then
        trap - INT TERM
        # eval: restore caller traps captured by $(trap -p)
        [[ -n "$previous_int_trap" ]] && eval "$previous_int_trap"
        [[ -n "$previous_term_trap" ]] && eval "$previous_term_trap"
    fi
    if [[ $failed_scan_count -gt 0 ]]; then
        local root_text="root"
        [[ $failed_scan_count -ne 1 ]] && root_text="roots"
        echo ""
        echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped ${failed_scan_count} project scan ${root_text} because scanning did not complete:"
        for ((scan_index = 0; scan_index < ${#failed_scan_roots[@]}; scan_index++)); do
            local display_root="${failed_scan_roots[$scan_index]/#$HOME/~}"
            echo -e "  ${GRAY}${display_root}${NC} (status ${failed_scan_statuses[$scan_index]:-1})"
        done
        echo -e "${GRAY}Re-run with 'mo purge --debug' to inspect the scan failure.${NC}"
        if [[ $completed_scan_count -eq 0 ]]; then
            printf '\n'
            PURGE_RUN_OUTCOME="scan_failed"
            return 0
        fi
    fi
    if [[ ${#all_found_items[@]} -eq 0 ]]; then
        echo ""
        if [[ $failed_scan_count -gt 0 ]]; then
            echo -e "${GRAY}No artifacts found in the completed project scans${NC}"
        else
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No old project artifacts to clean"
        fi
        printf '\n'
        PURGE_RUN_OUTCOME="no_candidates"
        return 0
    fi
    # Mark recently modified items (for default selection state)
    if [[ -t 1 ]]; then
        start_inline_spinner "Checking recent activity..."
    fi
    local _now_epoch
    _now_epoch=$(get_epoch_seconds)
    local _activity_total_timeout="${MO_PURGE_ACTIVITY_TOTAL_TIMEOUT_SEC:-$MOLE_TIMEOUT_HINT_SCAN_SEC}"
    if [[ ! "$_activity_total_timeout" =~ ^[1-9][0-9]*$ ]]; then
        _activity_total_timeout="$MOLE_TIMEOUT_HINT_SCAN_SEC"
    fi
    local _PURGE_ACTIVITY_DEADLINE_EPOCH=$((_now_epoch + _activity_total_timeout))
    for item in "${all_found_items[@]}"; do
        local candidate_bound=false
        local candidate_parent=""
        local candidate_parent_id=""
        local candidate_target_id=""
        local root_index
        for ((root_index = 0; root_index < ${#scan_roots[@]}; root_index++)); do
            [[ ${scan_statuses[$root_index]:-1} -eq 0 ]] || continue
            if ! is_safe_project_artifact "$item" "${scan_roots[$root_index]}"; then
                continue
            fi
            if ! _mole_path_matches_identity \
                "${scan_roots[$root_index]}" \
                "${scan_root_parents[$root_index]}" \
                "${scan_root_parent_ids[$root_index]}" \
                "${scan_root_target_ids[$root_index]}"; then
                continue
            fi
            if [[ ! -d "$item" || -L "$item" ]] || ! _mole_snapshot_path_identity "$item"; then
                continue
            fi
            candidate_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
            candidate_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
            candidate_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
            # Bind the candidate only while both endpoints still match the
            # completed scan. Rechecking the root after the candidate snapshot
            # closes a replacement between those two observations.
            if ! _mole_path_matches_identity \
                "${scan_roots[$root_index]}" \
                "${scan_root_parents[$root_index]}" \
                "${scan_root_parent_ids[$root_index]}" \
                "${scan_root_target_ids[$root_index]}"; then
                continue
            fi
            if ! _mole_path_matches_identity \
                "$item" "$candidate_parent" "$candidate_parent_id" "$candidate_target_id"; then
                continue
            fi
            if ! is_safe_project_artifact "$item" "${scan_roots[$root_index]}"; then
                continue
            fi
            candidate_bound=true
            break
        done
        if [[ "$candidate_bound" != "true" ]]; then
            debug_log "Skipping purge target whose scan identity changed: $item"
            continue
        fi
        if is_protected_purge_artifact "$item"; then
            debug_log "Skipping purge target that became protected after scanning: $item"
            continue
        fi

        local is_recent=false
        _PURGE_ACTIVITY_STATE="uncertain"
        if is_recently_modified "$item" "$_now_epoch"; then
            is_recent=true
        fi
        local activity_state="${_PURGE_ACTIVITY_STATE:-uncertain}"
        if [[ "$activity_state" != "recent" && "$activity_state" != "old" && "$activity_state" != "uncertain" ]]; then
            activity_state="uncertain"
        elif [[ "$activity_state" == "uncertain" && "$is_recent" == "false" ]]; then
            # Preserve the long-standing is_recently_modified test/mocking seam:
            # a legacy override returning 1 means definitely old.
            activity_state="old"
        fi
        # Add all items to safe_to_clean, let user choose
        safe_to_clean+=("$item")
        safe_recent_flags+=("$is_recent")
        safe_activity_states+=("$activity_state")
        safe_expected_parents+=("$candidate_parent")
        safe_expected_parent_ids+=("$candidate_parent_id")
        safe_expected_target_ids+=("$candidate_target_id")
    done
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    # Build menu options - one per artifact
    if [[ -t 1 ]]; then
        start_inline_spinner "Calculating sizes..."
    fi

    # Pre-compute sizes in parallel with sliding-window throttle.
    # Unbounded parallelism (all N at once) causes I/O contention on cold
    # filesystem cache, making du timeout and display "unknown" sizes.
    local -a _size_tmpfiles=()
    local -a _size_pids=()
    local _max_size_jobs
    _max_size_jobs=$(get_optimal_parallel_jobs io)
    if ! [[ "$_max_size_jobs" =~ ^[0-9]+$ ]] || [[ "$_max_size_jobs" -lt 1 ]]; then
        _max_size_jobs=1
    elif [[ "$_max_size_jobs" -gt 8 ]]; then
        _max_size_jobs=8
    fi

    # Reap any finished PID from the sliding window. Uses `wait -n` when
    # available (bash 4.3+) to avoid blocking on the slowest job; falls
    # back to first-PID wait on macOS default bash 3.2.
    local _has_wait_n=false
    if [[ "${BASH_VERSINFO[0]:-0}" -gt 4 ]] ||
        { [[ "${BASH_VERSINFO[0]:-0}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]:-0}" -ge 3 ]]; }; then
        _has_wait_n=true
    fi
    _reap_one_size_pid() {
        if [[ "$_has_wait_n" == "true" ]]; then
            wait -n "${_size_pids[@]}" 2> /dev/null || true
            local -a _remaining=()
            for _p in "${_size_pids[@]}"; do
                if kill -0 "$_p" 2> /dev/null; then
                    _remaining+=("$_p")
                fi
            done
            _size_pids=("${_remaining[@]}")
        else
            wait "${_size_pids[0]}" 2> /dev/null || true
            _size_pids=("${_size_pids[@]:1}")
        fi
    }

    for _sz_item in "${safe_to_clean[@]}"; do
        local _stmp
        _stmp=$(mktemp)
        register_temp_file "$_stmp"
        _size_tmpfiles+=("$_stmp")
        (get_dir_size_kb "$_sz_item" > "$_stmp" 2> /dev/null) < /dev/null &
        _size_pids+=($!)

        if [[ ${#_size_pids[@]} -ge $_max_size_jobs ]]; then
            _reap_one_size_pid
        fi
    done
    for _spid in "${_size_pids[@]+"${_size_pids[@]}"}"; do
        wait "$_spid" 2> /dev/null || true
    done

    local -a menu_options=()
    local -a item_paths=()
    local -a item_sizes=()
    local -a item_size_unknown_flags=()
    local -a item_recent_flags=()
    local -a item_age_labels=()
    local -a item_cloud_flags=()
    local -a item_expected_parents=()
    local -a item_expected_parent_ids=()
    local -a item_expected_target_ids=()
    # Helper to get artifact display name
    # For duplicate artifact names within same project, include parent directory for context
    get_artifact_display_name() {
        local path="$1"
        local item_index="$2"
        local artifact_name="${path##*/}"
        local parent_name="${path%/*}"
        parent_name="${parent_name##*/}"
        local project_name="${_cached_project_names[item_index]}"

        # Check if there are other items with same artifact name AND same project
        local has_duplicate=false
        local other_index
        for other_index in "${!safe_to_clean[@]}"; do
            if [[ "$other_index" != "$item_index" && "${_cached_basenames[other_index]}" == "$artifact_name" && "${_cached_project_names[other_index]}" == "$project_name" ]]; then
                has_duplicate=true
                break
            fi
        done

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
        local path_prefix=""

        if [[ "$project_path" == "[cloud] "* ]]; then
            path_prefix="[cloud] "
            project_path="${project_path#"[cloud] "}"
        fi

        if [[ -n "$max_path_width" ]]; then
            available_width="$max_path_width"
        else
            # Standalone fallback: include the two-column project-group marker.
            local fixed_width=$((artifact_col + 28))
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
        local compact_width=$((available_width - ${#path_prefix}))
        [[ $compact_width -lt 4 ]] && compact_width=4
        truncated_path="${path_prefix}$(compact_purge_menu_path "$project_path" "$compact_width")"
        local current_width
        current_width=$(get_display_width "$truncated_path")

        # Get byte count for printf width calculation
        local old_lc="${LC_ALL:-}"
        export LC_ALL=C
        local byte_count=${#truncated_path}
        if [[ -n "$old_lc" ]]; then
            export LC_ALL="$old_lc"
        else
            unset LC_ALL
        fi

        local padding=$((available_width - current_width))
        local printf_width=$((byte_count + padding))
        # Format: "project_path  size | artifact_type"
        printf "%-*s %9s | %-*s" "$printf_width" "$truncated_path" "$size_str" "$artifact_col" "$artifact_type"
    }
    # Resolve project ownership once per artifact. An indicator-backed root is
    # preferred. Without one, the artifact's direct parent is the narrowest
    # exact ownership boundary we can prove without grouping unrelated paths.
    # The physical identity is authoritative; display text is never a selector.
    local -a _cached_basenames=()
    local -a _cached_project_names=()
    local -a _cached_project_paths=()
    local -a _cached_project_identities=()
    local _pre_idx
    for _pre_idx in "${!safe_to_clean[@]}"; do
        local artifact_path="${safe_to_clean[$_pre_idx]}"
        local project_root=""
        _cached_basenames[_pre_idx]="${artifact_path##*/}"
        if project_root=$(find_purge_project_root_for_artifact "$artifact_path"); then
            _cached_project_names[_pre_idx]="${project_root##*/}"
            _cached_project_paths[_pre_idx]="${project_root/#$HOME/~}"
            _cached_project_identities[_pre_idx]=$(mole_path_identity "$project_root")
        else
            project_root="${artifact_path%/*}"
            _cached_project_names[_pre_idx]="${project_root##*/}"
            _cached_project_paths[_pre_idx]="${project_root/#$HOME/~}"
            _cached_project_identities[_pre_idx]=$(mole_path_identity "$project_root")
        fi
    done

    # Build menu options - one line per artifact
    # Pass 1: collect data into parallel arrays (needed for pre-scan of widths).
    # Sizes are read from pre-computed results (parallel du calls launched above).
    local -a raw_project_paths=()
    local -a raw_artifact_types=()
    local -a item_display_paths=()
    local -a item_project_identities=()
    local -a item_project_paths=()
    local _sz_idx=0
    for item in "${safe_to_clean[@]}"; do
        local item_index=$_sz_idx
        local project_path="${_cached_project_paths[$item_index]}"
        local artifact_type
        artifact_type=$(get_artifact_display_name "$item" "$item_index")
        local size_raw
        size_raw=$(cat "${_size_tmpfiles[$item_index]}" 2> /dev/null || echo "0")
        rm -f "${_size_tmpfiles[$item_index]}" 2> /dev/null || true
        _sz_idx=$((_sz_idx + 1))
        local size_kb=0
        local size_human=""
        local size_unknown=false

        if [[ "$size_raw" == "TIMEOUT" ]]; then
            size_unknown=true
            size_human="unknown"
        elif [[ "$size_raw" == "ERROR" ]]; then
            debug_log "Skipping purge target with unknown size: $item"
            continue
        elif [[ "$size_raw" =~ ^[0-9]+$ ]]; then
            size_kb="$size_raw"
            if [[ $size_kb -eq 0 && "${MOLE_PURGE_INCLUDE_EMPTY:-0}" != "1" ]]; then
                continue
            fi
            size_human=$(bytes_to_human "$((size_kb * 1024))")
        else
            debug_log "Skipping purge target with invalid size result '$size_raw': $item"
            continue
        fi

        local is_recent="${safe_recent_flags[$item_index]:-true}"
        local activity_state="${safe_activity_states[$item_index]:-uncertain}"
        local is_cloud=false
        if mole_purge_is_cloud_synced_path "$item"; then
            is_cloud=true
        fi
        local display_project_path="$project_path"
        local display_item_path
        display_item_path=$(format_purge_target_path "$item")
        if [[ "$is_cloud" == "true" ]]; then
            display_project_path="[cloud] $display_project_path"
            display_item_path="[cloud] $display_item_path"
        fi
        raw_project_paths+=("$display_project_path")
        raw_artifact_types+=("$artifact_type")
        item_paths+=("$item")
        item_display_paths+=("$display_item_path")
        item_project_identities+=("${_cached_project_identities[$item_index]}")
        item_project_paths+=("$display_project_path")
        item_sizes+=("$size_kb")
        item_size_unknown_flags+=("$size_unknown")
        item_recent_flags+=("$is_recent")
        item_cloud_flags+=("$is_cloud")
        item_expected_parents+=("${safe_expected_parents[$item_index]}")
        item_expected_parent_ids+=("${safe_expected_parent_ids[$item_index]}")
        item_expected_target_ids+=("${safe_expected_target_ids[$item_index]}")
        # Build human-readable age label (bash 3.2 compatible, no assoc arrays).
        local _mod_time _age_secs _age_d
        _mod_time=$(get_file_mtime "$item" 2> /dev/null || echo "0")
        _age_secs=$((_now_epoch - _mod_time))
        _age_d=$((_age_secs / 86400))
        if [[ "$activity_state" == "uncertain" ]]; then
            item_age_labels+=("unknown")
        elif [[ "$activity_state" == "recent" && $_age_d -ge $MIN_AGE_DAYS ]]; then
            item_age_labels+=("<${MIN_AGE_DAYS}d")
        elif [[ $_age_d -lt 1 ]]; then
            item_age_labels+=("<1d")
        elif [[ $_age_d -lt 30 ]]; then
            item_age_labels+=("${_age_d}d")
        elif [[ $_age_d -lt 365 ]]; then
            item_age_labels+=("$((_age_d / 30))mo")
        else
            item_age_labels+=("$((_age_d / 365))y")
        fi
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

    # Include the two-column project-group marker in the selector prefix.
    local fixed_overhead=$((max_artifact_width + 28))
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

    # Keep every exact project together. Project groups are ordered by their
    # aggregate known size, then artifacts within each group by item size. Only
    # numeric local indices cross the sort boundary; canonical path identities
    # remain in their aligned shell arrays.
    if [[ ${#item_sizes[@]} -gt 0 ]]; then
        local -a group_project_identities=()
        local -a group_total_sizes=()
        local -a item_group_indices=()
        local group_index

        # Sort an injective, line-safe encoding of each identity once, then
        # assign adjacent rows to the same group. This keeps grouping O(n log n)
        # when a large workspace contains hundreds of distinct projects.
        local grouping_temp
        grouping_temp=$(mktemp)
        for ((i = 0; i < ${#item_sizes[@]}; i++)); do
            local encoded_identity="${item_project_identities[i]}"
            encoded_identity="${encoded_identity//%/%25}"
            encoded_identity="${encoded_identity//|/%7C}"
            encoded_identity="${encoded_identity//$'\n'/%0A}"
            printf '%s|%d|%d\n' "$encoded_identity" "$i" "${item_sizes[i]}"
        done > "$grouping_temp"

        local previous_encoded_identity=""
        local have_previous_identity=false
        while IFS='|' read -r encoded_identity i item_size; do
            if [[ "$have_previous_identity" != "true" || "$encoded_identity" != "$previous_encoded_identity" ]]; then
                group_index=${#group_project_identities[@]}
                group_project_identities+=("${item_project_identities[i]}")
                group_total_sizes+=(0)
                previous_encoded_identity="$encoded_identity"
                have_previous_identity=true
            fi
            item_group_indices[i]=$group_index
            group_total_sizes[group_index]=$((group_total_sizes[group_index] + item_size))
        done < <(LC_ALL=C sort -t'|' -k1,1 -k2,2n "$grouping_temp")
        rm -f "$grouping_temp" # SAFE: this is the exact scratch file created by mktemp above.

        local group_sort_temp
        group_sort_temp=$(mktemp)
        for ((group_index = 0; group_index < ${#group_project_identities[@]}; group_index++)); do
            printf '%d|%d\n' "$group_index" "${group_total_sizes[group_index]}"
        done > "$group_sort_temp"

        local -a group_ranks=()
        local group_rank=0
        while IFS='|' read -r group_index group_total_size; do
            group_ranks[group_index]=$group_rank
            group_rank=$((group_rank + 1))
        done < <(sort -t'|' -k2,2nr -k1,1n "$group_sort_temp")
        rm -f "$group_sort_temp"

        local item_sort_temp
        item_sort_temp=$(mktemp)
        for ((i = 0; i < ${#item_sizes[@]}; i++)); do
            group_index=${item_group_indices[i]}
            printf '%d|%d|%d\n' "${group_ranks[group_index]}" "${item_sizes[i]}" "$i"
        done > "$item_sort_temp"

        local -a sorted_indices=()
        while IFS='|' read -r group_rank size idx; do
            sorted_indices+=("$idx")
        done < <(sort -t'|' -k1,1n -k2,2nr -k3,3n "$item_sort_temp")
        rm -f "$item_sort_temp"

        # Rebuild arrays in sorted order
        local -a sorted_menu_options=()
        local -a sorted_item_paths=()
        local -a sorted_item_sizes=()
        local -a sorted_item_size_unknown_flags=()
        local -a sorted_item_recent_flags=()
        local -a sorted_item_display_paths=()
        local -a sorted_item_project_identities=()
        local -a sorted_item_project_paths=()
        local -a sorted_item_age_labels=()
        local -a sorted_item_cloud_flags=()
        local -a sorted_item_expected_parents=()
        local -a sorted_item_expected_parent_ids=()
        local -a sorted_item_expected_target_ids=()

        for idx in "${sorted_indices[@]}"; do
            sorted_menu_options+=("${menu_options[idx]}")
            sorted_item_paths+=("${item_paths[idx]}")
            sorted_item_sizes+=("${item_sizes[idx]}")
            sorted_item_size_unknown_flags+=("${item_size_unknown_flags[idx]}")
            sorted_item_recent_flags+=("${item_recent_flags[idx]}")
            sorted_item_display_paths+=("${item_display_paths[idx]}")
            sorted_item_project_identities+=("${item_project_identities[idx]}")
            sorted_item_project_paths+=("${item_project_paths[idx]}")
            sorted_item_age_labels+=("${item_age_labels[idx]}")
            sorted_item_cloud_flags+=("${item_cloud_flags[idx]}")
            sorted_item_expected_parents+=("${item_expected_parents[idx]}")
            sorted_item_expected_parent_ids+=("${item_expected_parent_ids[idx]}")
            sorted_item_expected_target_ids+=("${item_expected_target_ids[idx]}")
        done

        # Replace original arrays with sorted versions
        menu_options=("${sorted_menu_options[@]}")
        item_paths=("${sorted_item_paths[@]}")
        item_sizes=("${sorted_item_sizes[@]}")
        item_size_unknown_flags=("${sorted_item_size_unknown_flags[@]}")
        item_recent_flags=("${sorted_item_recent_flags[@]}")
        item_display_paths=("${sorted_item_display_paths[@]}")
        item_project_identities=("${sorted_item_project_identities[@]}")
        item_project_paths=("${sorted_item_project_paths[@]}")
        item_age_labels=("${sorted_item_age_labels[@]}")
        item_cloud_flags=("${sorted_item_cloud_flags[@]}")
        item_expected_parents=("${sorted_item_expected_parents[@]}")
        item_expected_parent_ids=("${sorted_item_expected_parent_ids[@]}")
        item_expected_target_ids=("${sorted_item_expected_target_ids[@]}")
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
        PURGE_RUN_OUTCOME="no_candidates"
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
    export PURGE_AGE_LABELS=$(
        IFS=,
        echo "${item_age_labels[*]-}"
    )
    # Interactive selection (only if terminal is available)
    PURGE_SELECTION_RESULT=""
    PURGE_CATEGORY_FULL_PATHS_ARRAY=("${item_display_paths[@]}")
    PURGE_CATEGORY_PROJECT_IDS_ARRAY=("${item_project_identities[@]}")
    PURGE_CATEGORY_PROJECT_PATHS_ARRAY=("${item_project_paths[@]}")
    PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=("${item_size_unknown_flags[@]}")
    if [[ -t 0 ]]; then
        if ! select_purge_categories "${menu_options[@]}"; then
            PURGE_CATEGORY_FULL_PATHS_ARRAY=()
            PURGE_CATEGORY_PROJECT_IDS_ARRAY=()
            PURGE_CATEGORY_PROJECT_PATHS_ARRAY=()
            PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=()
            unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_AGE_LABELS PURGE_SELECTION_RESULT
            PURGE_RUN_OUTCOME="cancelled"
            return 0
        fi
    else
        # Non-interactive: select all non-recent items
        local skipped_cloud_count=0
        for ((i = 0; i < ${#menu_options[@]}; i++)); do
            if [[ "${item_cloud_flags[i]:-false}" == "true" && "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                skipped_cloud_count=$((skipped_cloud_count + 1))
                continue
            fi
            if [[ ${item_recent_flags[i]} != "true" ]]; then
                [[ -n "$PURGE_SELECTION_RESULT" ]] && PURGE_SELECTION_RESULT+=","
                PURGE_SELECTION_RESULT+="$i"
            fi
        done
        if [[ $skipped_cloud_count -gt 0 ]]; then
            local skipped_cloud_text="artifact"
            [[ $skipped_cloud_count -ne 1 ]] && skipped_cloud_text="artifacts"
            echo ""
            echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped ${skipped_cloud_count} cloud-synced ${skipped_cloud_text} in non-interactive mode (confirmation required)"
        fi
    fi
    if [[ -z "$PURGE_SELECTION_RESULT" ]]; then
        echo ""
        echo -e "${GRAY}No items selected${NC}"
        printf '\n'
        PURGE_CATEGORY_FULL_PATHS_ARRAY=()
        PURGE_CATEGORY_PROJECT_IDS_ARRAY=()
        PURGE_CATEGORY_PROJECT_PATHS_ARRAY=()
        PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=()
        unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_AGE_LABELS PURGE_SELECTION_RESULT
        PURGE_RUN_OUTCOME="cancelled"
        return 0
    fi
    IFS=',' read -r -a selected_indices <<< "$PURGE_SELECTION_RESULT"
    local selected_total_kb=0
    local selected_unknown_count=0
    local selected_cloud_count=0
    local -a selected_display_paths=()
    for idx in "${selected_indices[@]}"; do
        local selected_size_kb="${item_sizes[idx]:-0}"
        [[ "$selected_size_kb" =~ ^[0-9]+$ ]] || selected_size_kb=0
        selected_total_kb=$((selected_total_kb + selected_size_kb))
        if [[ "${item_size_unknown_flags[idx]:-false}" == "true" ]]; then
            selected_unknown_count=$((selected_unknown_count + 1))
        fi
        if [[ "${item_cloud_flags[idx]:-false}" == "true" ]]; then
            selected_cloud_count=$((selected_cloud_count + 1))
        fi
        selected_display_paths+=("${item_display_paths[idx]}")
    done

    if [[ -t 0 ]]; then
        if ! confirm_purge_cleanup "${#selected_indices[@]}" "$selected_total_kb" "$selected_unknown_count" "$selected_cloud_count" "${selected_display_paths[@]}"; then
            echo -e "${GRAY}Purge cancelled${NC}"
            printf '\n'
            PURGE_CATEGORY_FULL_PATHS_ARRAY=()
            PURGE_CATEGORY_PROJECT_IDS_ARRAY=()
            PURGE_CATEGORY_PROJECT_PATHS_ARRAY=()
            PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=()
            unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_AGE_LABELS PURGE_SELECTION_RESULT
            PURGE_RUN_OUTCOME="cancelled"
            return 0
        fi
    fi
    PURGE_CATEGORY_FULL_PATHS_ARRAY=()
    PURGE_CATEGORY_PROJECT_IDS_ARRAY=()
    PURGE_CATEGORY_PROJECT_PATHS_ARRAY=()
    PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=()

    # Clean selected items
    echo ""
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    local cleaned_count=0
    local dry_run_mode="${MOLE_DRY_RUN:-0}"
    for idx in "${selected_indices[@]}"; do
        local item_path="${item_paths[idx]}"
        local display_item_path="${item_display_paths[idx]}"
        local size_kb="${item_sizes[idx]}"
        local size_unknown="${item_size_unknown_flags[idx]:-false}"
        local size_human
        if [[ "$size_unknown" == "true" ]]; then
            size_human="unknown"
        else
            size_human=$(bytes_to_human "$((size_kb * 1024))")
        fi
        # Safety checks
        local expected_parent="${item_expected_parents[idx]}"
        local expected_parent_id="${item_expected_parent_ids[idx]}"
        local expected_target_id="${item_expected_target_ids[idx]}"
        if ! _mole_path_matches_identity \
            "$item_path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $display_item_path (path changed after review)"
            continue
        fi
        if ! is_safe_configured_purge_artifact "$item_path"; then
            debug_log "Skipping purge target outside configured safe roots: ${item_path:-<empty>}"
            continue
        fi
        if is_protected_purge_artifact "$item_path"; then
            debug_log "Skipping purge target that became protected after review: $item_path"
            continue
        fi
        if ! purge_target_activity_still_safe "$item_path" "${item_recent_flags[idx]:-true}"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $display_item_path (activity changed after review)"
            continue
        fi
        if [[ -t 1 ]]; then
            start_inline_spinner "Cleaning $display_item_path..."
        fi
        local removal_recorded=false
        if [[ -e "$item_path" ]]; then
            local _MOLE_PURGE_FINAL_WAS_RECENT="${item_recent_flags[idx]:-true}"
            local _MOLE_SAFE_REMOVE_FINAL_GUARD="_mole_purge_final_remove_guard"
            if safe_remove "$item_path" true "$size_kb" "" \
                "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
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
        fi
        if [[ "$removal_recorded" == "true" ]]; then
            if [[ "$dry_run_mode" == "1" ]]; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} [DRY RUN] $display_item_path${NC}, ${GREEN}$size_human${NC}"
            elif [[ -t 1 ]]; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} $display_item_path${NC}, ${GREEN}$size_human${NC}"
            fi
        fi
    done
    # Update count
    echo "$cleaned_count" > "$stats_dir/purge_count"
    unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_AGE_LABELS PURGE_SELECTION_RESULT
}
