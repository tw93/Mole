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
    local deadline="${3:-}"

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

    # A purge target is an artifact, never a container. A stray ~/node_modules
    # is otherwise globbed as one: every npm package ships package.json, the
    # first project indicator, so the maxdepth-2 probe matches immediately and
    # each package becomes a "project root". The scan then starts below the
    # artifact, so filter_nested_artifacts never sees node_modules itself and
    # emits package-internal dist/ and build/ instead. Deleting those leaves
    # the package half-installed: package.json stays, npm reports the tree as
    # up to date, and recovery needs a network restore, which purge must never
    # require (#1459). Same shape for vendor/ and Pods/. A container that
    # happens to share an artifact name stays reachable through
    # ~/.config/mole/purge_paths, which bypasses discovery.
    local purge_target
    for purge_target in "${PURGE_TARGETS[@]}"; do
        if [[ "$basename" == "$purge_target" ]]; then
            return 1
        fi
    done

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

    local probe_timeout probe_output probe_status=0
    probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline") || return $?
    probe_output=$(run_with_timeout "$probe_timeout" find "${find_args[@]}" 2> /dev/null) || probe_status=$?
    if [[ $probe_status -ne 0 ]]; then
        [[ $probe_status -eq 124 || $probe_status -ge 128 ]] && return "$probe_status"
        return 2
    fi
    [[ -n "$probe_output" ]]
}

# Discover project directories in $HOME.
discover_project_dirs() {
    local -a discovered=()
    local deadline=$((SECONDS + MOLE_TIMEOUT_HINT_SCAN_SEC))
    local discovery_status=0

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
        if [[ $SECONDS -ge $deadline ]]; then
            discovery_status=124
            break
        fi
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

        local probe_status=0
        if is_project_container "$dir" 2 "$deadline"; then
            discovered+=("$dir")
        else
            probe_status=$?
            if [[ $probe_status -ne 1 ]]; then
                discovery_status=$probe_status
                [[ $probe_status -lt 128 ]] || break
            fi
        fi
    done

    printf '%s\n' "${discovered[@]+"${discovered[@]}"}" | sort -u
    return "$discovery_status"
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
    PURGE_DISCOVERY_STATUS=0

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
        local discovery_output
        discovery_output=$(discover_project_dirs) || PURGE_DISCOVERY_STATUS=$?
        [[ $PURGE_DISCOVERY_STATUS -lt 128 ]] || return "$PURGE_DISCOVERY_STATUS"
        while IFS= read -r path; do
            [[ -n "$path" ]] && discovered+=("$path")
        done <<< "$discovery_output"
        if [[ $PURGE_DISCOVERY_STATUS -ne 0 && -z "${_PURGE_DISCOVERY_SILENT:-}" ]]; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Project discovery was incomplete; using completed roots without saving them. Run mo purge --paths to review search paths." >&2
        fi

        if [[ ${#discovered[@]} -gt 0 ]]; then
            PURGE_SEARCH_PATHS=("${discovered[@]}")
            if [[ $PURGE_DISCOVERY_STATUS -ne 0 ]]; then
                : # A partial inventory must not become the next run's saved scope.
            elif save_discovered_paths "${discovered[@]}"; then
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

    # A single long segment can contain wide characters. Build the suffix by
    # display width so the fallback cannot overflow a narrow terminal.
    local old_lc="${LC_ALL:-}"
    export LC_ALL=en_US.UTF-8
    local suffix=""
    local suffix_width=0
    local char char_width
    local i=$((${#path} - 1))
    while [[ $i -ge 0 ]]; do
        char="${path:$i:1}"
        char_width=$(get_display_width "$char")
        if [[ $((suffix_width + char_width + prefix_width)) -gt $max_width ]]; then
            break
        fi
        suffix="${char}${suffix}"
        suffix_width=$((suffix_width + char_width))
        i=$((i - 1))
    done
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi
    echo "...${suffix}"
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
is_safe_project_artifact_under_root() {
    local path="${1%/}"
    local search_path="${2%/}"

    [[ "$path" == /* && "$search_path" == /* && "$search_path" != "/" ]] || return 1
    [[ "$path" == "$search_path/"* ]] || return 1

    local relative_path="${path#"$search_path"/}"
    local relative_without_slashes="${relative_path//\//}"
    local depth=$((${#relative_path} - ${#relative_without_slashes}))
    if [[ $depth -lt 1 ]]; then
        # Allow direct-child artifacts only when the search path is itself
        # a project root (single-project mode).
        is_purge_project_root "$search_path"
        return $?
    fi
    return 0
}

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

    is_safe_project_artifact_under_root "$path" "$search_path"
}

# Revalidate a selected artifact against the configured scan roots immediately
# before deletion. Purge supports explicit roots outside HOME (for example
# /var/www), so HOME containment is neither sufficient nor correct here.
is_safe_configured_purge_artifact() {
    local path="$1"

    [[ -n "$path" && "$path" != "/" && "$path" != "$HOME" ]] || return 1
    [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]] || return 1

    local search_path
    # Ordinary configured roots retain their lexical prefix in scan results.
    # Check those roots first so one candidate does not resolve every unrelated
    # root physically. The second pass preserves support for symlink aliases.
    for search_path in "${PURGE_SEARCH_PATHS[@]}"; do
        [[ -n "$search_path" ]] || continue
        [[ "$search_path" == "/" || "$path" == "${search_path%/}/"* ]] || continue
        if is_safe_project_artifact "$path" "$search_path"; then
            return 0
        fi
    done
    for search_path in "${PURGE_SEARCH_PATHS[@]}"; do
        [[ -n "$search_path" ]] || continue
        [[ "$search_path" != "/" && "$path" != "${search_path%/}/"* ]] || continue
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
    local path="${1%/}"
    [[ "${path##*/}" == "bin" ]] || return 1

    # Check if parent directory has a .csproj/.fsproj/.vbproj file
    local parent_dir="${path%/*}"
    [[ -n "$parent_dir" ]] || parent_dir="/"
    find "$parent_dir" -maxdepth 1 \( -name "*.csproj" -o -name "*.fsproj" -o -name "*.vbproj" \) 2> /dev/null | grep -q . || return 1

    # Check if bin directory contains Debug/ or Release/ subdirectories
    [[ -d "$path/Debug" || -d "$path/Release" ]] || return 1

    return 0
}

# Check if a vendor directory should be protected from purge
# Expects path to be a vendor directory (basename == vendor)
# Strategy: Only clean PHP Composer vendor, protect all others
is_protected_vendor_dir() {
    local path="${1%/}"
    local base="${path##*/}"
    [[ "$base" == "vendor" ]] || return 1
    local parent_dir="${path%/*}"
    [[ -n "$parent_dir" ]] || parent_dir="/"

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
    local path="${1%/}"
    local base="${path##*/}"

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
    local error_output="${output_file}.errors"
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
    rm -f "$target_output" "$tag_output" "$processed_output" "$error_output" 2> /dev/null || true

    local cachedir_tag_min_depth=$((min_depth + 1))
    local cachedir_tag_max_depth=$((max_depth + 1))
    local scan_timeout="${MO_PURGE_SCAN_TIMEOUT_SEC:-60}"
    [[ "$scan_timeout" =~ ^[1-9][0-9]*$ ]] || scan_timeout=60
    [[ "$scan_timeout" -ge 2 ]] || scan_timeout=2
    local scan_deadline=$((SECONDS + scan_timeout))
    local scan_stage_timeout=""

    # Update current scanning path
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    echo "$search_path" > "$stats_dir/purge_scanning" 2> /dev/null || true

    emit_valid_cachedir_tag_dirs() {
        local deadline="$1"
        while IFS= read -r tag_file; do
            if [[ $SECONDS -ge $deadline ]]; then
                return 124
            fi
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
        local deadline="$2"
        if [[ -f "$input_file" ]]; then
            local process_status=0
            local nested_filter_timeout=""
            nested_filter_timeout=$(_mole_timeout_with_deadline "$scan_timeout" "$deadline") || process_status=$?
            if [[ $process_status -ne 0 ]]; then
                return "$process_status"
            fi
            filter_nested_artifacts "$nested_filter_timeout" < "$input_file" |
                (
                    while IFS= read -r item; do
                        if [[ $SECONDS -ge $deadline ]]; then
                            exit 124
                        fi
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
                    done
                ) | filter_protected_artifacts "$deadline" > "$processed_output" || process_status=$?

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
        rm -f "$target_output" "$tag_output" "$processed_output" "$error_output" 2> /dev/null || true
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
            "--show-errors"
            "--hidden"
            "--no-ignore"
            "--type" "d"
            "--min-depth" "$min_depth"
            "--max-depth" "$max_depth"
            "--threads" "8"
            "--prune"
            "--exclude" ".git"
            "--exclude" "Library"
            "--exclude" ".Trash"
            "--exclude" "Applications"
        )
        local fd_tag_args=(
            "--absolute-path"
            "--show-errors"
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
        local purge_target
        for purge_target in "${PURGE_TARGETS[@]}"; do
            fd_tag_args+=("--exclude" "$purge_target")
        done

        # fd can return zero after unreadable directories. Require both a
        # successful exit and no filesystem diagnostics before trusting output.
        # Empty scans are common in healthy project trees; falling back to find
        # doubles the scan cost and can make "nothing to clean" feel slow.
        local fd_status=0
        scan_stage_timeout=$(_mole_timeout_with_deadline "$scan_timeout" "$scan_deadline") || fd_status=$?
        if [[ $fd_status -eq 0 ]]; then
            # Only fd diagnostics may determine scan completeness; timeout
            # wrapper tracing must not look like a filesystem error in debug mode.
            MO_DEBUG=0 run_with_timeout "$scan_stage_timeout" fd "${fd_args[@]}" "$pattern" "$search_path" \
                2> "$error_output" > "$target_output" || fd_status=$?
        fi
        if [[ $fd_status -eq 0 ]]; then
            scan_stage_timeout=$(_mole_timeout_with_deadline "$scan_timeout" "$scan_deadline") || fd_status=$?
        fi
        if [[ $fd_status -eq 0 ]]; then
            MO_DEBUG=0 run_with_timeout "$scan_stage_timeout" fd "${fd_tag_args[@]}" "^${MOLE_CACHEDIR_TAG_NAME}$" "$search_path" \
                2>> "$error_output" > "$tag_output" || fd_status=$?
        fi
        if [[ $fd_status -eq 0 && -s "$error_output" ]]; then
            fd_status=1
            debug_log "fd reported filesystem errors; requiring a complete find scan"
        fi
        if [[ $fd_status -eq 0 ]]; then
            emit_valid_cachedir_tag_dirs "$scan_deadline" < "$tag_output" >> "$target_output" || fd_status=$?
        fi
        if [[ $fd_status -eq 0 ]]; then
            process_scan_results "$target_output" "$scan_deadline" || fd_status=$?
        fi
        if [[ $fd_status -eq 0 ]]; then
            debug_log "Using fd for scanning"
            cleanup_scan_outputs
            use_find=false
        elif [[ $fd_status -ge 128 ]]; then
            cleanup_scan_outputs
            return "$fd_status"
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
        local find_status=0
        scan_stage_timeout=$(_mole_timeout_with_deadline "$scan_timeout" "$scan_deadline") || find_status=$?
        if [[ $find_status -eq 0 ]]; then
            run_with_timeout "$scan_stage_timeout" find "$search_path" -mindepth "$min_depth" -maxdepth "$max_depth" -type d \
                \( "${prune_expr[@]}" \) -prune -o \
                \( "${target_expr[@]}" \) -print -prune \
                2> /dev/null > "$target_output" || find_status=$?
        fi

        if [[ $find_status -eq 0 ]]; then
            scan_stage_timeout=$(_mole_timeout_with_deadline "$scan_timeout" "$scan_deadline") || find_status=$?
        fi
        if [[ $find_status -eq 0 ]]; then
            run_with_timeout "$scan_stage_timeout" find "$search_path" -mindepth "$cachedir_tag_min_depth" -maxdepth "$cachedir_tag_max_depth" \
                \( -type d \( \( "${prune_expr[@]}" \) -o \( "${target_expr[@]}" \) \) \) -prune -o \
                -type f -name "$MOLE_CACHEDIR_TAG_NAME" -print \
                2> /dev/null > "$tag_output" || find_status=$?
        fi
        if [[ $find_status -eq 0 ]]; then
            emit_valid_cachedir_tag_dirs "$scan_deadline" < "$tag_output" >> "$target_output" || find_status=$?
        fi
        if [[ $find_status -eq 0 ]]; then
            process_scan_results "$target_output" "$scan_deadline" || find_status=$?
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
    local timeout_seconds="${1:-}"
    # shellcheck disable=SC2016 # Awk expands its own variables.
    local nested_filter_program='
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
    '
    # shellcheck disable=SC2016 # The child shell expands its own positional parameters.
    local -a filter_command=(
        /bin/bash -o pipefail -c
        'sed "$1" | LC_COLLATE=C sort | awk "$2" | sed "$3"'
        _
        's|[^/]$|&/|'
        "$nested_filter_program"
        's|/$||'
    )

    # 1. Append trailing slash to each path (to ensure /foo/bar starts with /foo/)
    # 2. Sort to group parents and children (LC_COLLATE=C ensures standard sorting)
    # 3. Use awk to filter out paths that start with the previous kept path
    # 4. Remove trailing slash
    if [[ -n "$timeout_seconds" ]]; then
        run_with_timeout "$timeout_seconds" "${filter_command[@]}"
    else
        "${filter_command[@]}"
    fi
}

filter_protected_artifacts() {
    local deadline="${1:-}"
    while IFS= read -r item; do
        if [[ "$deadline" =~ ^[0-9]+$ && $SECONDS -ge $deadline ]]; then
            return 124
        fi
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
        if [[ $probe_status -eq 124 || $probe_status -ge 128 ]]; then
            return "$probe_status"
        fi
        return 0
    fi
    if [[ -n "$recent_file" ]]; then
        _PURGE_ACTIVITY_STATE="recent"
    else
        _PURGE_ACTIVITY_STATE="old"
    fi
}

# Args: $1 - path, $2 - optional current epoch
# Return 0 for protected, 1 for old, or preserve timeout/signal status.
is_recently_modified() {
    classify_purge_activity "$@" || return $?
    [[ "$_PURGE_ACTIVITY_STATE" != "old" ]]
}

# An artifact that was old when the menu opened can become active before the
# user confirms deletion. Recheck only those default-safe rows; a user who
# explicitly selected an already-recent row has already overridden that hint.
purge_target_activity_still_safe() {
    local path="$1"
    local reviewed_state="${2:-recent}"
    # A known-recent row may be explicitly selected. Unknown probe state is
    # never an override: it must be resolved successfully before deletion.
    [[ "$reviewed_state" == "true" || "$reviewed_state" == "recent" ]] && return 0

    # Do not inherit the menu pass's expired shared deadline.
    local _PURGE_ACTIVITY_DEADLINE_EPOCH=""
    local activity_status=0
    is_recently_modified "$path" "$(get_epoch_seconds)" || activity_status=$?
    [[ $activity_status -eq 1 ]] && return 0
    if [[ $activity_status -eq 124 || $activity_status -ge 128 ]]; then
        return "$activity_status"
    fi
    return 1
}

# Final safe_remove hook for purge. The caller supplies the exact scan-root and
# candidate identities through dynamically scoped locals. Recheck them after
# the stateful activity probe so no filesystem walk separates identity proof
# from safe_remove's deletion sink.
_mole_purge_final_remove_guard() {
    local path="$1"
    is_safe_configured_purge_artifact "$path" || return 1
    is_protected_purge_artifact "$path" && return 1
    purge_target_activity_still_safe "$path" "${_MOLE_PURGE_FINAL_ACTIVITY_STATE:-uncertain}" || return $?

    _mole_path_matches_identity \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT:-}" \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT_PARENT:-}" \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT_PARENT_ID:-}" \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT_TARGET_ID:-}" || return 1
    _mole_path_matches_identity \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL:-}" \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL_PARENT:-}" \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL_PARENT_ID:-}" \
        "${_MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL_TARGET_ID:-}" || return 1
    _mole_path_matches_identity \
        "$path" \
        "${_MOLE_PURGE_FINAL_EXPECTED_PARENT:-}" \
        "${_MOLE_PURGE_FINAL_EXPECTED_PARENT_ID:-}" \
        "${_MOLE_PURGE_FINAL_EXPECTED_TARGET_ID:-}" || return 1

    local current_physical_path="${_MOLE_PATH_SNAPSHOT_PARENT%/}/${path##*/}"
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "/" ]] && current_physical_path="/${path##*/}"
    is_safe_project_artifact_under_root \
        "$current_physical_path" "${_MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL:-}"
}

# Args: $1 - path, $2 - optional shared deadline in SECONDS
# Get directory size in KB.
get_dir_size_kb() {
    local path="$1"
    local deadline="${2:-}"
    if [[ ! -d "$path" ]]; then
        echo "0"
        return
    fi

    local timeout_seconds="${MO_PURGE_SIZE_TIMEOUT_SEC:-15}"
    if [[ ! "$timeout_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        timeout_seconds=15
    fi
    if [[ -n "$deadline" ]]; then
        timeout_seconds=$(_mole_timeout_with_deadline "$timeout_seconds" "$deadline") || {
            debug_log "Size calculation budget exhausted before: $path"
            echo "TIMEOUT"
            return
        }
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

_mole_purge_size_budget_seconds() {
    mole_purge_timeout_budget_seconds "${1:-$MOLE_TIMEOUT_DISK_VERIFY_SEC}" 30
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

# Format one visible row from canonical menu data at the current terminal width.
# Width excludes the selector prefix and activity suffix; inputs contain no ANSI.
format_purge_display() {
    local project_path="$1" artifact="$2" size="$3" width="$4"
    if [[ $width -lt 30 ]]; then
        truncate_by_display_width "$artifact $size" "$width"
        return
    fi
    local artifact_width=$(((width - 13) / 2))
    [[ $artifact_width -gt 24 ]] && artifact_width=24
    local path_width=$((width - artifact_width - 13))
    local path_prefix=""
    if [[ "$project_path" == "[cloud] "* ]]; then
        path_prefix="[cloud] "
        project_path="${project_path#"[cloud] "}"
    fi
    local path
    local body_width=$((path_width - ${#path_prefix}))
    if [[ -n "$path_prefix" && $body_width -lt 4 ]]; then
        path=$(truncate_by_display_width "${path_prefix% }" "$path_width")
    else
        path="${path_prefix}$(compact_purge_menu_path "$project_path" "$body_width")"
    fi
    local padding=$((path_width - $(get_display_width "$path")))
    printf '%s%*s %9s | %s' "$path" "$padding" "" "$size" "$(truncate_by_display_width "$artifact" "$artifact_width")"
}

# Purge category selector.
select_purge_categories() {
    local LC_ALL=en_US.UTF-8
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
            echo 0
        elif [[ $available -gt 50 ]]; then
            echo 50
        else
            echo "$available"
        fi
    }

    local items_per_page=$(_get_items_per_page)
    local cursor_pos=0
    local top_index=0
    local search_query="" search_message=""
    local -a rendered_rows=()
    local rendered_width=0 menu_ready=true

    # Selection and group totals belong to the menu, keyed by canonical row index.
    local -a selected=() sizes=() recent_flags=() age_labels=()
    local -a group_starts=() group_ends=() row_groups=() group_sizes=() group_selected=() group_unknown=()
    local selected_size=0 selected_count=0 selected_unknown=0 group=-1
    local previous_project_id="" project_id=""
    IFS=',' read -r -a sizes <<< "${PURGE_CATEGORY_SIZES:-}"
    IFS=',' read -r -a recent_flags <<< "${PURGE_RECENT_CATEGORIES:-}"
    IFS=',' read -r -a age_labels <<< "${PURGE_AGE_LABELS:-}"
    for ((i = 0; i < total_items; i++)); do
        project_id="${PURGE_CATEGORY_PROJECT_IDS_ARRAY[i]:-}"
        if [[ $i -eq 0 || -z "$project_id" || "$project_id" != "$previous_project_id" ]]; then
            group=$((group + 1))
            group_starts[group]=$i
            group_sizes[group]=0
            group_selected[group]=0
            group_unknown[group]=false
        fi
        previous_project_id="$project_id"
        row_groups[i]=$group
        group_ends[group]=$i
        group_sizes[group]=$((group_sizes[group] + ${sizes[i]:-0}))
        if [[ "${PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY[i]:-false}" == true ]]; then
            group_unknown[group]=true
        fi
        selected[i]=false
        if [[ "${recent_flags[i]:-false}" != true ]]; then
            selected[i]=true
            selected_count=$((selected_count + 1))
            selected_size=$((selected_size + ${sizes[i]:-0}))
            group_selected[group]=$((group_selected[group] + 1))
            if [[ "${PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY[i]:-false}" == true ]]; then
                selected_unknown=$((selected_unknown + 1))
            fi
        fi
    done
    set_selected() {
        local index="$1" value="$2" delta=1
        [[ "${selected[index]}" != "$value" ]] || return 0
        [[ "$value" == true ]] || delta=-1
        selected[index]="$value"
        selected_count=$((selected_count + delta))
        selected_size=$((selected_size + delta * ${sizes[index]:-0}))
        local group_index="${row_groups[index]}"
        group_selected[group_index]=$((group_selected[group_index] + delta))
        if [[ "${PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY[index]:-false}" == true ]]; then
            selected_unknown=$((selected_unknown + delta))
        fi
    }
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
    _get_terminal_width() {
        local term_width=""
        if [[ -t 0 ]] || [[ -t 2 ]]; then
            term_width=$(stty size < /dev/tty 2> /dev/null | awk '{print $2}')
        fi
        if [[ ! "$term_width" =~ ^[1-9][0-9]*$ ]]; then
            term_width=$(tput cols 2> /dev/null || echo 80)
        fi
        [[ "$term_width" =~ ^[1-9][0-9]*$ ]] || term_width=80
        echo "$term_width"
    }
    draw_menu() {
        local focused_index=$((top_index + cursor_pos))
        items_per_page=$(_get_items_per_page)
        local _term_w
        _term_w=$(_get_terminal_width)
        menu_ready=true
        if [[ $_term_w -lt 30 || $items_per_page -eq 0 ]]; then
            menu_ready=false
            printf '\033[H%s%s\n%s%s\n\033[J' "$clear_line" "$(truncate_by_display_width "Resize to 30 columns, 13 rows" "$_term_w")" "$clear_line" "$(truncate_by_display_width "Q Quit" "$_term_w")"
            return 0
        fi
        if [[ $rendered_width -ne $_term_w ]]; then
            # Cache presentation only. Measured metadata is immutable while
            # this menu is open; every resize invalidates its rendered rows.
            rendered_rows=()
            rendered_width=$_term_w
        fi

        # Keep the same absolute artifact focused when the viewport changes.
        local max_top_index=$((total_items - items_per_page))
        [[ $max_top_index -lt 0 ]] && max_top_index=0
        [[ $top_index -gt $max_top_index ]] && top_index=$max_top_index
        [[ $top_index -lt 0 ]] && top_index=0
        if [[ $focused_index -lt $top_index ]]; then
            top_index=$focused_index
        elif [[ $focused_index -ge $((top_index + items_per_page)) ]]; then
            top_index=$((focused_index - items_per_page + 1))
        fi
        cursor_pos=$((focused_index - top_index))
        local visible_count=$((total_items - top_index))
        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page

        printf "\033[H"
        # Format selected size (stored in KB) using shared display rules.
        local selected_size_human
        selected_size_human=$(bytes_to_human_kb "$selected_size")
        [[ $selected_unknown -eq 0 ]] || selected_size_human+=" + $selected_unknown unmeasured"

        # Show position indicator if scrolling is needed
        local scroll_indicator=""
        if [[ $total_items -gt $items_per_page ]]; then
            local current_pos=$((top_index + cursor_pos + 1))
            scroll_indicator=" [${current_pos}/${total_items}]"
        fi

        printf "%s${PURPLE_BOLD}%s${NC}\n" "$clear_line" "$(truncate_by_display_width "Select Artifacts to Purge${scroll_indicator}" "$_term_w")"
        local subtitle="${selected_size_human}, ${selected_count} selected"
        if [[ -n "$search_message" ]]; then
            subtitle="$subtitle · $search_message"
        fi
        printf "%s${GRAY}%s${NC}\n" "$clear_line" "$(truncate_by_display_width "$subtitle" "$_term_w")"

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
            if [[ -z "${rendered_rows[i]+set}" ]]; then
                local row_width=$((_term_w - 6))
                if [[ -n "$_age" ]]; then
                    row_width=$((row_width - ${#_age} - 3))
                fi
                [[ $row_width -lt 1 ]] && row_width=1
                local row_size="unknown"
                if [[ "${PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY[i]:-false}" != "true" ]]; then
                    row_size=$(bytes_to_human_kb "${sizes[i]:-0}")
                fi
                rendered_rows[i]=$(format_purge_display "${PURGE_CATEGORY_PROJECT_PATHS_ARRAY[i]:-}" "${categories[i]}" "$row_size" "$row_width")
            fi
            local row="${rendered_rows[i]}"
            local rel_pos=$((i - top_index))
            if [[ $rel_pos -eq $cursor_pos ]]; then
                printf "%s${CYAN}${ICON_ARROW} %s %s %s%s${NC}\n" "$clear_line" "$checkbox" "$group_marker" "$row" "$recent_marker"
            else
                printf "%s  %s %s %s%s\n" "$clear_line" "$checkbox" "$group_marker" "$row" "$recent_marker"
            fi
        done

        # Keep one blank line between the list and footer tips.
        printf "%s\n" "$clear_line"

        local current_index=$((top_index + cursor_pos))
        local current_project_path="${PURGE_CATEGORY_PROJECT_PATHS_ARRAY[current_index]:-}"
        if [[ -n "$current_project_path" ]]; then
            local current_group="${row_groups[current_index]}"
            local group_size="${group_sizes[current_group]}"
            local group_item_count=$((group_ends[current_group] - group_starts[current_group] + 1))
            local group_selected_count="${group_selected[current_group]}"
            local group_has_unknown_size="${group_unknown[current_group]}"

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
                printf "%s${GRAY}%s${NC}\n" "$clear_line" "$(truncate_by_display_width "Group: $group_size_label · $group_selected_count/$group_item_count selected" "$_term_w")"
            fi
        fi

        local current_full_path=""
        local paths_len="${#PURGE_CATEGORY_FULL_PATHS_ARRAY[@]}"
        if [[ "$paths_len" -gt 0 && "$current_index" -lt "$paths_len" ]]; then
            current_full_path="${PURGE_CATEGORY_FULL_PATHS_ARRAY[current_index]}"
        fi
        if [[ -n "$current_full_path" ]]; then
            printf "%s${GRAY}Path:${NC} %s\n" "$clear_line" "$(compact_purge_menu_path "$current_full_path" "$((_term_w - 6))")"
            printf "%s\n" "$clear_line"
        fi

        # Adaptive footer hints, mirrors menu_paginated.sh pattern
        local _sep=" ${GRAY}|${NC} "
        local _nav="${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN} [] Projects / Find${NC}"
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
                    printf "%s${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}${NC}${_sep}${GRAY}Enter${NC}${_sep}${GRAY}X Skip${NC}${_sep}${GRAY}Q${NC}\n" "$clear_line"
                fi
            fi
        fi

        # Clear stale content below the footer when list height shrinks.
        printf '\033[J'
    }
    focus_item() {
        local target="$1"
        [[ $target -lt 0 ]] && target=0
        [[ $target -ge $total_items ]] && target=$((total_items - 1))
        cursor_pos=$((target - top_index))
    }
    move_project() {
        local current_index=$((top_index + cursor_pos))
        local target_group="${row_groups[current_index]}"
        if [[ "$1" == next ]]; then
            target_group=$((target_group + 1))
        else
            target_group=$((target_group - 1))
        fi
        if [[ $target_group -ge 0 && $target_group -lt ${#group_starts[@]} ]]; then
            focus_item "${group_starts[target_group]}"
        fi
    }
    find_next_match() {
        [[ -n "$search_query" ]] || return 0
        local start="$1" offset index match=-1 case_was_enabled=false
        shopt -q nocasematch && case_was_enabled=true
        shopt -s nocasematch
        for ((offset = 0; offset < total_items; offset++)); do
            index=$(((start + offset) % total_items))
            if [[ "${PURGE_CATEGORY_PROJECT_PATHS_ARRAY[index]:-} ${categories[index]}" == *"$search_query"* ]]; then
                match=$index
                break
            fi
        done
        [[ "$case_was_enabled" == true ]] || shopt -u nocasematch
        if [[ $match -ge 0 ]]; then
            focus_item "$match"
            search_message="n: next match"
        else
            search_message="No match: $search_query"
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
        local key
        key=$(read_key)
        if [[ "$menu_ready" != true && "$key" != QUIT ]]; then
            continue
        fi
        case "$key" in
            CHAR:/)
                # Readline owns text editing and multibyte input. A byte-at-a-time
                # key loop on Bash 3.2 cannot safely edit Unicode project names.
                if ! IFS= read -e -r -p "Find project/artifact: " search_query; then
                    restore_terminal
                    return 1
                fi
                find_next_match 0
                ;;
            CHAR:n | CHAR:N) find_next_match "$((top_index + cursor_pos + 1))" ;;
            UP) focus_item "$((top_index + cursor_pos - 1))" ;;
            DOWN) focus_item "$((top_index + cursor_pos + 1))" ;;
            LEFT) focus_item "$((top_index + cursor_pos - items_per_page))" ;;
            RIGHT) focus_item "$((top_index + cursor_pos + items_per_page))" ;;
            TOP) focus_item 0 ;;
            BOTTOM) focus_item "$((total_items - 1))" ;;
            'CHAR:[') move_project previous ;;
            'CHAR:]') move_project next ;;
            SPACE) # Space - toggle current item
                local idx=$((top_index + cursor_pos))
                if [[ ${selected[idx]} == true ]]; then
                    set_selected "$idx" false
                else
                    set_selected "$idx" true
                fi
                ;;
            CHAR:a | CHAR:A) # Select all
                for ((i = 0; i < total_items; i++)); do
                    set_selected "$i" true
                done
                ;;
            CHAR:i | CHAR:I) # Invert selection
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        set_selected "$i" false
                    else
                        set_selected "$i" true
                    fi
                done
                ;;
            CHAR:x | CHAR:X) # Deselect the current artifact's exact project
                local current_index=$((top_index + cursor_pos))
                local current_group="${row_groups[current_index]}"
                for ((i = group_starts[current_group]; i <= group_ends[current_group]; i++)); do
                    set_selected "$i" false
                done
                move_project next
                ;;
            QUIT) # Quit, Ctrl-C, or closed input
                restore_terminal
                return 1
                ;;
            ENTER) # Enter - confirm
                # A resize can happen while read_key is waiting. Check again
                # before accepting input from a now-unreadable viewport.
                local confirm_width
                confirm_width=$(tput cols 2> /dev/null || echo 80)
                [[ "$confirm_width" =~ ^[1-9][0-9]*$ ]] || confirm_width=80
                if [[ $confirm_width -lt 30 || $(_get_items_per_page) -eq 0 ]]; then
                    continue
                fi
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
    if ! IFS= read -r -s -n1 key; then
        echo ""
        return 1
    fi
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
# Normal outcomes return zero; the command renders the outcome and maps incomplete
# work to failure. Signals and deletion-phase timeouts stop the run immediately.
# PURGE_RUN_OUTCOME: completed, incomplete, no_candidates, cancelled, scan_failed.
clean_project_artifacts() {
    PURGE_RUN_OUTCOME="completed"
    [[ ${PURGE_DISCOVERY_STATUS:-0} -eq 0 ]] || PURGE_RUN_OUTCOME="incomplete"
    PURGE_UNKNOWN_SIZE_COUNT=0
    local -a all_found_items=()
    local -a safe_to_clean=()
    local -a safe_recent_flags=()
    local -a safe_activity_states=()
    local -a safe_expected_parents=()
    local -a safe_expected_parent_ids=()
    local -a safe_expected_target_ids=()
    local -a safe_scan_root_indexes=()
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
        for pid in "${scan_pids[@]+"${scan_pids[@]}"}"; do
            wait "$pid" 2> /dev/null || true
        done
        scan_pids=()
        # Clean up temp files
        for temp in "${scan_temps[@]+"${scan_temps[@]}"}"; do
            rm -f "$temp" "${temp}.targets" "${temp}.tags" "${temp}.processed" "${temp}.errors" 2> /dev/null || true
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
    _restore_purge_scan_traps() {
        [[ "$trap_installed_by_this_call" == "true" ]] || return 0
        trap - INT TERM
        trap_installed_by_this_call=false
        local saved_int_trap="$previous_int_trap"
        local saved_term_trap="$previous_term_trap"
        previous_int_trap=""
        previous_term_trap=""
        # eval: restore caller traps captured by $(trap -p)
        [[ -n "$saved_int_trap" ]] && eval "$saved_int_trap"
        [[ -n "$saved_term_trap" ]] && eval "$saved_term_trap"
        return 0
    }
    local -a scan_statuses=()
    local -a scan_root_parents=()
    local -a scan_root_parent_ids=()
    local -a scan_root_target_ids=()
    local -a scan_root_physical_paths=()
    local -a scan_root_physical_parents=()
    local -a scan_root_physical_parent_ids=()
    local -a scan_root_physical_target_ids=()
    local -a failed_scan_roots=()
    local -a failed_scan_statuses=()
    local failed_scan_count=0
    local scan_interrupt_status=0
    local max_scan_jobs
    max_scan_jobs=$(get_optimal_parallel_jobs io)
    if ! [[ "$max_scan_jobs" =~ ^[0-9]+$ ]] || [[ "$max_scan_jobs" -lt 1 ]]; then
        max_scan_jobs=1
    elif [[ "$max_scan_jobs" -gt 4 ]]; then
        max_scan_jobs=4
    fi

    local -a active_scan_indexes=()
    _reap_purge_scans() {
        local wait_for_completion="${1:-true}"
        local slot pid status finished root_index
        while [[ ${#scan_pids[@]} -gt 0 ]]; do
            local -a running_pids=() running_indexes=()
            finished=false
            for ((slot = 0; slot < ${#scan_pids[@]}; slot++)); do
                pid="${scan_pids[slot]}"
                if kill -0 "$pid" 2> /dev/null; then
                    running_pids+=("$pid")
                    running_indexes+=("${active_scan_indexes[slot]}")
                    continue
                fi
                status=0
                wait "$pid" 2> /dev/null || status=$?
                root_index="${active_scan_indexes[slot]}"
                scan_statuses[root_index]=$status
                finished=true
                if [[ $status -ge 128 ]]; then
                    local peer
                    for peer in "${scan_pids[@]}"; do
                        kill "$peer" 2> /dev/null || true
                    done
                    for peer in "${scan_pids[@]}"; do
                        wait "$peer" 2> /dev/null || true
                    done
                    scan_pids=()
                    active_scan_indexes=()
                    return "$status"
                fi
            done
            scan_pids=("${running_pids[@]+"${running_pids[@]}"}")
            active_scan_indexes=("${running_indexes[@]+"${running_indexes[@]}"}")
            [[ "$finished" == true || "$wait_for_completion" == false ]] && return 0
            sleep 0.05
        done
        return 0
    }

    # Refill free slots as scans finish. Root indexes remain stable regardless
    # of completion order, so incomplete output cannot acquire another root's status.
    for path in "${PURGE_SEARCH_PATHS[@]}"; do
        _reap_purge_scans false || scan_interrupt_status=$?
        [[ $scan_interrupt_status -ge 128 ]] && break
        if [[ -d "$path" ]]; then
            if ! _mole_snapshot_path_identity "$path"; then
                failed_scan_count=$((failed_scan_count + 1))
                failed_scan_roots+=("$path")
                failed_scan_statuses+=("1")
                debug_log "Purge scan root identity unavailable: $path"
                continue
            fi
            local scan_root_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
            local scan_root_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
            local scan_root_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
            local scan_root_physical_path=""
            scan_root_physical_path=$(cd -P "$path" 2> /dev/null && pwd -P) || {
                failed_scan_count=$((failed_scan_count + 1))
                failed_scan_roots+=("$path")
                failed_scan_statuses+=("1")
                debug_log "Purge scan root physical path unavailable: $path"
                continue
            }
            if ! _mole_snapshot_path_identity "$scan_root_physical_path"; then
                failed_scan_count=$((failed_scan_count + 1))
                failed_scan_roots+=("$path")
                failed_scan_statuses+=("1")
                debug_log "Purge scan root physical identity unavailable: $path"
                continue
            fi
            local scan_output
            scan_output=$(mktemp)
            scan_temps+=("$scan_output")
            scan_roots+=("$path")
            scan_root_parents+=("$scan_root_parent")
            scan_root_parent_ids+=("$scan_root_parent_id")
            scan_root_target_ids+=("$scan_root_target_id")
            scan_root_physical_paths+=("$scan_root_physical_path")
            scan_root_physical_parents+=("$_MOLE_PATH_SNAPSHOT_PARENT")
            scan_root_physical_parent_ids+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
            scan_root_physical_target_ids+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
            # Launch scan in background for true parallelism
            scan_purge_targets "$path" "$scan_output" < /dev/null &
            local scan_pid=$!
            scan_pids+=("$scan_pid")
            active_scan_indexes+=("$((${#scan_roots[@]} - 1))")
            if [[ ${#scan_pids[@]} -ge $max_scan_jobs ]]; then
                _reap_purge_scans || scan_interrupt_status=$?
                [[ $scan_interrupt_status -ge 128 ]] && break
            fi
        fi
    done
    while [[ $scan_interrupt_status -lt 128 && ${#scan_pids[@]} -gt 0 ]]; do
        _reap_purge_scans || scan_interrupt_status=$?
    done

    if [[ $scan_interrupt_status -ge 128 ]]; then
        local interrupted_stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
        rm -f "$interrupted_stats_dir/purge_scanning" 2> /dev/null || true
        local interrupted_temp
        for interrupted_temp in "${scan_temps[@]+"${scan_temps[@]}"}"; do
            rm -f "$interrupted_temp" "${interrupted_temp}.targets" \
                "${interrupted_temp}.tags" "${interrupted_temp}.processed" "${interrupted_temp}.errors" 2> /dev/null || true
        done
        _restore_purge_scan_traps
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        return "$scan_interrupt_status"
    fi

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
        if [[ $scan_status -eq 0 ]] && ! _mole_path_matches_identity \
            "${scan_root_physical_paths[$scan_index]}" \
            "${scan_root_physical_parents[$scan_index]}" \
            "${scan_root_physical_parent_ids[$scan_index]}" \
            "${scan_root_physical_target_ids[$scan_index]}"; then
            scan_status=1
            scan_statuses[scan_index]=1
            debug_log "Purge scan root target changed before results were collected: ${scan_roots[$scan_index]}"
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
        rm -f "$scan_output" "${scan_output}.targets" "${scan_output}.tags" "${scan_output}.processed" "${scan_output}.errors" 2> /dev/null || true
    done
    if [[ -s "$dedupe_output" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] && all_found_items+=("$item")
        done < <(LC_COLLATE=C sort -u "$dedupe_output")
    fi
    rm -f "$dedupe_output"
    # Restore caller traps after this function completes.
    _restore_purge_scan_traps
    if [[ $failed_scan_count -gt 0 ]]; then
        PURGE_RUN_OUTCOME="incomplete"
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
        if [[ "$PURGE_RUN_OUTCOME" == "incomplete" ]]; then
            echo -e "${GRAY}No artifacts found in the completed project scans${NC}"
        else
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No old project artifacts to clean"
        fi
        printf '\n'
        [[ "$PURGE_RUN_OUTCOME" != "incomplete" ]] && PURGE_RUN_OUTCOME="no_candidates"
        return 0
    fi
    # Bind candidates before starting the activity evidence budget.
    if [[ -t 1 ]]; then
        start_inline_spinner "Preparing artifacts..."
    fi
    local candidate_index
    for ((candidate_index = 0; candidate_index < ${#all_found_items[@]}; candidate_index++)); do
        item="${all_found_items[$candidate_index]}"
        if is_path_whitelisted "$item"; then
            continue
        fi
        local candidate_bound=false
        local candidate_parent=""
        local candidate_parent_id=""
        local candidate_target_id=""
        local root_index
        local scan_root
        local -a candidate_root_indexes=()
        for ((root_index = 0; root_index < ${#scan_roots[@]}; root_index++)); do
            [[ ${scan_statuses[$root_index]:-1} -eq 0 ]] || continue
            scan_root="${scan_roots[$root_index]}"
            if [[ "$scan_root" == "/" || "$item" == "${scan_root%/}/"* ]]; then
                candidate_root_indexes+=("$root_index")
            fi
        done
        # A scan root may be a symlink while fd/find reports the physical path.
        # Fall back to the full physical containment check only for that rare
        # alias case; normal candidates stay on their lexical roots.
        if [[ ${#candidate_root_indexes[@]} -eq 0 ]]; then
            for ((root_index = 0; root_index < ${#scan_roots[@]}; root_index++)); do
                [[ ${scan_statuses[$root_index]:-1} -eq 0 ]] || continue
                candidate_root_indexes+=("$root_index")
            done
        fi
        if [[ ! -d "$item" || -L "$item" ]] || ! _mole_snapshot_path_identity "$item"; then
            continue
        fi
        candidate_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        candidate_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        candidate_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        local candidate_physical_path="${candidate_parent%/}/${item##*/}"
        [[ "$candidate_parent" == "/" ]] && candidate_physical_path="/${item##*/}"
        local candidate_scan_root_index=-1
        for root_index in "${candidate_root_indexes[@]}"; do
            if ! _mole_path_matches_identity \
                "${scan_roots[$root_index]}" \
                "${scan_root_parents[$root_index]}" \
                "${scan_root_parent_ids[$root_index]}" \
                "${scan_root_target_ids[$root_index]}"; then
                continue
            fi
            if ! _mole_path_matches_identity \
                "${scan_root_physical_paths[$root_index]}" \
                "${scan_root_physical_parents[$root_index]}" \
                "${scan_root_physical_parent_ids[$root_index]}" \
                "${scan_root_physical_target_ids[$root_index]}"; then
                continue
            fi
            if ! _mole_path_matches_identity \
                "$item" "$candidate_parent" "$candidate_parent_id" "$candidate_target_id"; then
                continue
            fi
            if ! is_safe_project_artifact_under_root \
                "$candidate_physical_path" "${scan_root_physical_paths[$root_index]}"; then
                continue
            fi
            candidate_scan_root_index="$root_index"
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

        safe_to_clean+=("$item")
        safe_expected_parents+=("$candidate_parent")
        safe_expected_parent_ids+=("$candidate_parent_id")
        safe_expected_target_ids+=("$candidate_target_id")
        safe_scan_root_indexes+=("$candidate_scan_root_index")
    done
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    if [[ ${#safe_to_clean[@]} -eq 0 ]]; then
        echo -e "${GRAY}No eligible project artifacts to purge${NC}"
        [[ "$PURGE_RUN_OUTCOME" != "incomplete" ]] && PURGE_RUN_OUTCOME="no_candidates"
        return 0
    fi
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
    for item in "${safe_to_clean[@]}"; do
        local is_recent=true
        local activity_status=0
        _PURGE_ACTIVITY_STATE="uncertain"
        is_recently_modified "$item" "$_now_epoch" || activity_status=$?
        if [[ $activity_status -ge 128 ]]; then
            PURGE_RUN_OUTCOME="cancelled"
            [[ ! -t 1 ]] || stop_inline_spinner
            return "$activity_status"
        fi
        # A bounded menu probe may time out: retain that row, unchecked.
        local activity_state="${_PURGE_ACTIVITY_STATE:-uncertain}"
        if [[ $activity_status -eq 1 ]]; then
            is_recent=false
            activity_state="old"
        elif [[ "$activity_state" != "recent" ]]; then
            activity_state="uncertain"
        fi
        safe_recent_flags+=("$is_recent")
        safe_activity_states+=("$activity_state")
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
    local _size_total_timeout
    _size_total_timeout=$(_mole_purge_size_budget_seconds "$MOLE_TIMEOUT_DISK_VERIFY_SEC")
    local _size_deadline=$((SECONDS + _size_total_timeout))
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

    local _size_previous_int_trap=""
    local _size_previous_term_trap=""
    local _size_interrupt_status=0
    local _size_traps_installed=false
    # shellcheck disable=SC2329 # Invoked by the signal trap below.
    _cleanup_purge_size_workers() {
        local size_pid
        for size_pid in "${_size_pids[@]+"${_size_pids[@]}"}"; do
            kill "$size_pid" 2> /dev/null || true
        done
        for size_pid in "${_size_pids[@]+"${_size_pids[@]}"}"; do
            wait "$size_pid" 2> /dev/null || true
        done
        _size_pids=()
    }
    # shellcheck disable=SC2329 # Invoked by the signal trap below.
    _handle_purge_size_interrupt() {
        local interrupt_status="$1"
        if [[ $_size_interrupt_status -lt 128 ]]; then
            _size_interrupt_status="$interrupt_status"
        fi
        _cleanup_purge_size_workers
    }
    _restore_purge_size_traps() {
        [[ "$_size_traps_installed" == "true" ]] || return 0
        trap - INT TERM
        _size_traps_installed=false
        local saved_int_trap="$_size_previous_int_trap"
        local saved_term_trap="$_size_previous_term_trap"
        _size_previous_int_trap=""
        _size_previous_term_trap=""
        # eval: restore caller traps captured by $(trap -p)
        [[ -n "$saved_int_trap" ]] && eval "$saved_int_trap"
        [[ -n "$saved_term_trap" ]] && eval "$saved_term_trap"
        return 0
    }

    _size_previous_int_trap=$(trap -p INT || true)
    _size_previous_term_trap=$(trap -p TERM || true)
    trap '_handle_purge_size_interrupt 130' INT
    trap '_handle_purge_size_interrupt 143' TERM
    _size_traps_installed=true

    for _sz_item in "${safe_to_clean[@]}"; do
        [[ $_size_interrupt_status -ge 128 ]] && break
        local _stmp
        _stmp=$(mktemp)
        register_temp_file "$_stmp"
        _size_tmpfiles+=("$_stmp")
        if [[ $SECONDS -ge $_size_deadline ]]; then
            printf 'TIMEOUT\n' > "$_stmp"
            continue
        fi
        (get_dir_size_kb "$_sz_item" "$_size_deadline" > "$_stmp" 2> /dev/null) < /dev/null &
        _size_pids+=($!)

        if [[ ${#_size_pids[@]} -ge $_max_size_jobs ]]; then
            _reap_one_size_pid
            [[ $_size_interrupt_status -ge 128 ]] && break
        fi
    done
    if [[ $_size_interrupt_status -lt 128 ]]; then
        for _spid in "${_size_pids[@]+"${_size_pids[@]}"}"; do
            wait "$_spid" 2> /dev/null || true
        done
        _size_pids=()
    fi
    _restore_purge_size_traps

    if [[ $_size_interrupt_status -ge 128 ]]; then
        local interrupted_size_temp
        for interrupted_size_temp in "${_size_tmpfiles[@]+"${_size_tmpfiles[@]}"}"; do
            rm -f "$interrupted_size_temp" 2> /dev/null || true # SAFE: exact scratch file created by mktemp above
        done
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        return "$_size_interrupt_status"
    fi

    local -a menu_options=()
    local -a item_paths=()
    local -a item_sizes=()
    local -a item_size_unknown_flags=()
    local -a item_recent_flags=()
    local -a item_activity_states=()
    local -a item_age_labels=()
    local -a item_cloud_flags=()
    local -a item_expected_parents=()
    local -a item_expected_parent_ids=()
    local -a item_expected_target_ids=()
    local -a item_scan_root_indexes=()
    # Resolve project ownership once per artifact. An indicator-backed root is
    # preferred. Without one, the artifact's direct parent is the narrowest
    # exact ownership boundary we can prove without grouping unrelated paths.
    # The physical identity is authoritative; display text is never a selector.
    local -a project_roots=()
    local -a _cached_project_identities=()
    local _pre_idx
    local project_parent=""
    local project_root=""
    local project_identity=""
    for _pre_idx in "${!safe_to_clean[@]}"; do
        local artifact_path="${safe_to_clean[$_pre_idx]}"
        # Adjacent siblings share report-only ownership. Deletion still rebinds
        # every artifact to its original scan evidence at the final boundary.
        if [[ "${artifact_path%/*}" != "$project_parent" ]]; then
            project_parent="${artifact_path%/*}"
            if ! project_root=$(find_purge_project_root_for_artifact "$artifact_path"); then
                project_root="$project_parent"
            fi
            project_identity=$(mole_path_identity "$project_root")
        fi
        project_roots[_pre_idx]="$project_root"
        _cached_project_identities[_pre_idx]="$project_identity"
    done

    # Build menu options - one line per artifact
    # Keep labels unformatted; the selector renders only visible rows.
    # Sizes are read from pre-computed results (parallel du calls launched above).
    local -a item_display_paths=()
    local -a item_project_identities=()
    local -a item_project_paths=()
    local -a size_failed_paths=()
    local _sz_idx=0
    for item in "${safe_to_clean[@]}"; do
        local item_index=$_sz_idx
        local project_root="${project_roots[$item_index]}"
        local project_path="${project_root/#$HOME/~}"
        local artifact_type="${item#"$project_root/"}"
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
        elif [[ "$size_raw" =~ ^[0-9]+$ ]]; then
            size_kb="$size_raw"
            if [[ $size_kb -eq 0 && "${MOLE_PURGE_INCLUDE_EMPTY:-0}" != "1" ]]; then
                continue
            fi
            size_human=$(bytes_to_human "$((size_kb * 1024))")
        else
            PURGE_RUN_OUTCOME="incomplete"
            size_failed_paths+=("$item")
            debug_log "Invalid size result '$size_raw' for $item"
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
        menu_options+=("$artifact_type")
        item_paths+=("$item")
        item_display_paths+=("$display_item_path")
        item_project_identities+=("${_cached_project_identities[$item_index]}")
        item_project_paths+=("$display_project_path")
        item_sizes+=("$size_kb")
        item_size_unknown_flags+=("$size_unknown")
        item_recent_flags+=("$is_recent")
        item_activity_states+=("$activity_state")
        item_cloud_flags+=("$is_cloud")
        item_expected_parents+=("${safe_expected_parents[$item_index]}")
        item_expected_parent_ids+=("${safe_expected_parent_ids[$item_index]}")
        item_expected_target_ids+=("${safe_expected_target_ids[$item_index]}")
        item_scan_root_indexes+=("${safe_scan_root_indexes[$item_index]}")
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
        local -a sorted_item_activity_states=()
        local -a sorted_item_display_paths=()
        local -a sorted_item_project_identities=()
        local -a sorted_item_project_paths=()
        local -a sorted_item_age_labels=()
        local -a sorted_item_cloud_flags=()
        local -a sorted_item_expected_parents=()
        local -a sorted_item_expected_parent_ids=()
        local -a sorted_item_expected_target_ids=()
        local -a sorted_item_scan_root_indexes=()

        for idx in "${sorted_indices[@]}"; do
            sorted_menu_options+=("${menu_options[idx]}")
            sorted_item_paths+=("${item_paths[idx]}")
            sorted_item_sizes+=("${item_sizes[idx]}")
            sorted_item_size_unknown_flags+=("${item_size_unknown_flags[idx]}")
            sorted_item_recent_flags+=("${item_recent_flags[idx]}")
            sorted_item_activity_states+=("${item_activity_states[idx]}")
            sorted_item_display_paths+=("${item_display_paths[idx]}")
            sorted_item_project_identities+=("${item_project_identities[idx]}")
            sorted_item_project_paths+=("${item_project_paths[idx]}")
            sorted_item_age_labels+=("${item_age_labels[idx]}")
            sorted_item_cloud_flags+=("${item_cloud_flags[idx]}")
            sorted_item_expected_parents+=("${item_expected_parents[idx]}")
            sorted_item_expected_parent_ids+=("${item_expected_parent_ids[idx]}")
            sorted_item_expected_target_ids+=("${item_expected_target_ids[idx]}")
            sorted_item_scan_root_indexes+=("${item_scan_root_indexes[idx]}")
        done

        # Replace original arrays with sorted versions
        menu_options=("${sorted_menu_options[@]}")
        item_paths=("${sorted_item_paths[@]}")
        item_sizes=("${sorted_item_sizes[@]}")
        item_size_unknown_flags=("${sorted_item_size_unknown_flags[@]}")
        item_recent_flags=("${sorted_item_recent_flags[@]}")
        item_activity_states=("${sorted_item_activity_states[@]}")
        item_display_paths=("${sorted_item_display_paths[@]}")
        item_project_identities=("${sorted_item_project_identities[@]}")
        item_project_paths=("${sorted_item_project_paths[@]}")
        item_age_labels=("${sorted_item_age_labels[@]}")
        item_cloud_flags=("${sorted_item_cloud_flags[@]}")
        item_expected_parents=("${sorted_item_expected_parents[@]}")
        item_expected_parent_ids=("${sorted_item_expected_parent_ids[@]}")
        item_expected_target_ids=("${sorted_item_expected_target_ids[@]}")
        item_scan_root_indexes=("${sorted_item_scan_root_indexes[@]}")
    fi
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    for item in "${size_failed_paths[@]+"${size_failed_paths[@]}"}"; do
        echo -e "${YELLOW}${ICON_WARNING}${NC} Could not measure ${item/#$HOME/~}; skipped" >&2
    done
    # Exit early if no artifacts were found to avoid unbound variable errors
    # when expanding empty arrays with set -u active.
    if [[ ${#menu_options[@]} -eq 0 ]]; then
        echo ""
        if [[ "$PURGE_RUN_OUTCOME" == "incomplete" ]]; then
            echo -e "${YELLOW}No artifacts could be prepared for review${NC}"
        else
            echo -e "${GRAY}No artifacts found to purge${NC}"
            PURGE_RUN_OUTCOME="no_candidates"
        fi
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
        [[ "$PURGE_RUN_OUTCOME" != "incomplete" ]] && PURGE_RUN_OUTCOME="cancelled"
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
        local expected_scan_root_index="${item_scan_root_indexes[idx]}"
        local expected_scan_root="${scan_roots[$expected_scan_root_index]}"
        local expected_scan_root_physical="${scan_root_physical_paths[$expected_scan_root_index]}"
        if ! _mole_path_matches_identity \
            "$expected_scan_root" \
            "${scan_root_parents[$expected_scan_root_index]}" \
            "${scan_root_parent_ids[$expected_scan_root_index]}" \
            "${scan_root_target_ids[$expected_scan_root_index]}"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $display_item_path (scan root changed after review)"
            continue
        fi
        if ! _mole_path_matches_identity \
            "$expected_scan_root_physical" \
            "${scan_root_physical_parents[$expected_scan_root_index]}" \
            "${scan_root_physical_parent_ids[$expected_scan_root_index]}" \
            "${scan_root_physical_target_ids[$expected_scan_root_index]}"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $display_item_path (scan root target changed after review)"
            continue
        fi
        if ! _mole_path_matches_identity \
            "$item_path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $display_item_path (path changed after review)"
            continue
        fi
        local current_item_physical_path="${_MOLE_PATH_SNAPSHOT_PARENT%/}/${item_path##*/}"
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "/" ]] && current_item_physical_path="/${item_path##*/}"
        if ! is_safe_project_artifact_under_root "$current_item_physical_path" "$expected_scan_root_physical"; then
            debug_log "Skipping purge target outside configured safe roots: ${item_path:-<empty>}"
            continue
        fi
        if is_protected_purge_artifact "$item_path"; then
            debug_log "Skipping purge target that became protected after review: $item_path"
            continue
        fi
        local activity_status=0
        purge_target_activity_still_safe "$item_path" "${item_activity_states[idx]:-uncertain}" || activity_status=$?
        if [[ $activity_status -eq 124 || $activity_status -ge 128 ]]; then
            PURGE_RUN_OUTCOME="cancelled"
            echo "$cleaned_count" > "$stats_dir/purge_count"
            return "$activity_status"
        fi
        if [[ $activity_status -ne 0 ]]; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $display_item_path (activity changed after review)"
            continue
        fi
        if [[ -t 1 ]]; then
            start_inline_spinner "Cleaning $display_item_path..."
        fi
        local removal_recorded=false
        if [[ -e "$item_path" ]]; then
            local _MOLE_PURGE_FINAL_ACTIVITY_STATE="${item_activity_states[idx]:-uncertain}"
            local _MOLE_PURGE_FINAL_SCAN_ROOT="$expected_scan_root"
            local _MOLE_PURGE_FINAL_SCAN_ROOT_PARENT="${scan_root_parents[$expected_scan_root_index]}"
            local _MOLE_PURGE_FINAL_SCAN_ROOT_PARENT_ID="${scan_root_parent_ids[$expected_scan_root_index]}"
            local _MOLE_PURGE_FINAL_SCAN_ROOT_TARGET_ID="${scan_root_target_ids[$expected_scan_root_index]}"
            local _MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL="$expected_scan_root_physical"
            local _MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL_PARENT="${scan_root_physical_parents[$expected_scan_root_index]}"
            local _MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL_PARENT_ID="${scan_root_physical_parent_ids[$expected_scan_root_index]}"
            local _MOLE_PURGE_FINAL_SCAN_ROOT_PHYSICAL_TARGET_ID="${scan_root_physical_target_ids[$expected_scan_root_index]}"
            local _MOLE_PURGE_FINAL_EXPECTED_PARENT="$expected_parent"
            local _MOLE_PURGE_FINAL_EXPECTED_PARENT_ID="$expected_parent_id"
            local _MOLE_PURGE_FINAL_EXPECTED_TARGET_ID="$expected_target_id"
            local _MOLE_SAFE_REMOVE_FINAL_GUARD="_mole_purge_final_remove_guard"
            if safe_remove "$item_path" true "$size_kb" "" \
                "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
                if [[ "$dry_run_mode" == "1" || ! -e "$item_path" ]]; then
                    local current_total
                    current_total=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
                    echo "$((current_total + size_kb))" > "$stats_dir/purge_stats"
                    cleaned_count=$((cleaned_count + 1))
                    if [[ "$size_unknown" == "true" ]]; then
                        PURGE_UNKNOWN_SIZE_COUNT=$((PURGE_UNKNOWN_SIZE_COUNT + 1))
                    fi
                    removal_recorded=true
                fi
            else
                local removal_status=$?
                if [[ $removal_status -eq 124 || $removal_status -ge 128 ]]; then
                    PURGE_RUN_OUTCOME="cancelled"
                    echo "$cleaned_count" > "$stats_dir/purge_count"
                    if [[ -t 1 ]]; then
                        stop_inline_spinner
                    fi
                    return "$removal_status"
                fi
                echo -e "${YELLOW}${ICON_WARNING}${NC} Skipped $display_item_path (final removal check failed; re-run mo purge to review it again)"
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
    if [[ $cleaned_count -lt ${#selected_indices[@]} ]]; then
        PURGE_RUN_OUTCOME="incomplete"
    fi
    unset PURGE_CATEGORY_SIZES PURGE_RECENT_CATEGORIES PURGE_AGE_LABELS PURGE_SELECTION_RESULT
}
