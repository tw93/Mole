#!/bin/bash
# Cache Cleanup Module
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/purge_shared.sh"
# Preflight TCC prompts once to avoid mid-run interruptions.
check_tcc_permissions() {
    [[ -t 1 ]] || return 0
    local permission_flag="$HOME/.cache/mole/permissions_granted"
    [[ -f "$permission_flag" ]] && return 0
    local -a tcc_dirs=(
        "$HOME/Library/Caches"
        "$HOME/Library/Logs"
        "$HOME/Library/Application Support"
        "$HOME/Library/Containers"
        "$HOME/.cache"
    )
    # Quick permission probe (avoid deep scans).
    local needs_permission_check=false
    if ! ls "$HOME/Library/Caches" > /dev/null 2>&1; then
        needs_permission_check=true
    fi
    if [[ "$needs_permission_check" == "true" ]]; then
        echo ""
        echo -e "${BLUE}First-time setup${NC}"
        echo -e "${GRAY}macOS will request permissions to access Library folders.${NC}"
        echo -e "${GRAY}You may see ${GREEN}${#tcc_dirs[@]} permission dialogs${NC}${GRAY}, please approve them all.${NC}"
        echo ""
        echo -ne "${PURPLE}${ICON_ARROW}${NC} Press ${GREEN}Enter${NC} to continue: "
        read -r
        MOLE_SPINNER_PREFIX="" start_inline_spinner "Requesting permissions..."
        # Touch each directory to trigger prompts without deep scanning.
        for dir in "${tcc_dirs[@]}"; do
            [[ -d "$dir" ]] && command find "$dir" -maxdepth 1 -type d > /dev/null 2>&1
        done
        stop_inline_spinner
        echo ""
    fi
    # Mark as granted to avoid repeat prompts.
    ensure_user_file "$permission_flag"
    return 0
}
# Args: $1=browser_name, $2=cache_path
# Clean Service Worker cache while protecting critical web editors.
clean_service_worker_cache() {
    local browser_name="$1"
    local cache_path="$2"
    [[ ! -d "$cache_path" ]] && return 0
    local cleaned_size=0
    local protected_count=0
    # shellcheck disable=SC2016
    while IFS= read -r cache_dir; do
        [[ ! -d "$cache_dir" ]] && continue
        # Extract a best-effort domain name from cache folder.
        local domain=$(basename "$cache_dir" | grep -oE '[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}' | head -1 || echo "")
        local size=0
        local _du_out
        if _du_out=$(run_with_timeout 5 du -skP "$cache_dir" 2> /dev/null); then
            local _sz="${_du_out%%[^0-9]*}"
            [[ "$_sz" =~ ^[0-9]+$ ]] && size="$_sz"
        fi
        local is_protected=false
        for protected_domain in "${PROTECTED_SW_DOMAINS[@]}"; do
            if [[ "$domain" == *"$protected_domain"* ]]; then
                is_protected=true
                protected_count=$((protected_count + 1))
                break
            fi
        done
        if [[ "$is_protected" == "false" ]]; then
            if [[ "$DRY_RUN" != "true" ]]; then
                safe_remove "$cache_dir" true || true
            fi
            cleaned_size=$((cleaned_size + size))
        fi
    done < <(run_with_timeout 10 sh -c 'find "$1" -type d -depth 2 2>/dev/null || true' _ "$cache_path")
    if [[ $cleaned_size -gt 0 ]]; then
        local spinner_was_running=false
        if [[ -t 1 && -n "${INLINE_SPINNER_PID:-}" ]]; then
            stop_inline_spinner
            spinner_was_running=true
        fi
        local cleaned_mb=$((cleaned_size / 1024))
        local line_color
        line_color=$(cleanup_result_color_kb "$cleaned_size")
        if [[ "$DRY_RUN" != "true" ]]; then
            if [[ $protected_count -gt 0 ]]; then
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} $browser_name Service Worker${NC}, ${line_color}${cleaned_mb}MB${NC}, ${protected_count} protected"
            else
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} $browser_name Service Worker${NC}, ${line_color}${cleaned_mb}MB${NC}"
            fi
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $browser_name Service Worker, would clean ${cleaned_mb}MB, ${protected_count} protected"
        fi
        note_activity
        if [[ "$spinner_was_running" == "true" ]]; then
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning browser Service Worker caches..."
        fi
    fi
}
# Check whether a directory looks like a project container.
project_cache_has_indicators() {
    local dir="$1"
    local max_depth="${2:-5}"
    local indicator_timeout="${MOLE_PROJECT_CACHE_DISCOVERY_TIMEOUT:-2}"
    [[ -d "$dir" ]] || return 1

    local -a find_args=("$dir" "-maxdepth" "$max_depth" "(")
    local first=true
    local indicator
    for indicator in "${MOLE_PURGE_PROJECT_INDICATORS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            find_args+=("-o")
        fi
        find_args+=("-name" "$indicator")
    done
    find_args+=(")" "-print" "-quit")

    run_with_timeout "$indicator_timeout" find "${find_args[@]}" 2> /dev/null | grep -q .
}

# Discover candidate project roots without scanning the whole home directory.
discover_project_cache_roots() {
    local -a roots=()
    local -a unique_roots=()
    local -a seen_identities=()
    local root

    for root in "${MOLE_PURGE_DEFAULT_SEARCH_PATHS[@]}"; do
        [[ -d "$root" ]] && roots+=("$root")
    done

    while IFS= read -r root; do
        [[ -d "$root" ]] && roots+=("$root")
    done < <(mole_purge_read_paths_config "$HOME/.config/mole/purge_paths")

    local _indicator_tmp
    _indicator_tmp=$(create_temp_file)
    local -a _indicator_pids=()
    local _max_jobs
    _max_jobs=$(get_optimal_parallel_jobs scan)

    local dir
    local base
    for dir in "$HOME"/*/; do
        [[ -d "$dir" ]] || continue
        dir="${dir%/}"
        base="${dir##*/}"

        case "$base" in
            .* | Library | Applications | Movies | Music | Pictures | Public)
                continue
                ;;
        esac

        (project_cache_has_indicators "$dir" 5 && echo "$dir" >> "$_indicator_tmp") &
        _indicator_pids+=($!)

        if [[ ${#_indicator_pids[@]} -ge $_max_jobs ]]; then
            wait "${_indicator_pids[0]}" 2> /dev/null || true
            _indicator_pids=("${_indicator_pids[@]:1}")
        fi
    done
    for _pid in "${_indicator_pids[@]}"; do
        wait "$_pid" 2> /dev/null || true
    done

    local _found_dir
    while IFS= read -r _found_dir; do
        [[ -n "$_found_dir" ]] && roots+=("$_found_dir")
    done < "$_indicator_tmp"
    rm -f "$_indicator_tmp"

    [[ ${#roots[@]} -eq 0 ]] && return 0

    for root in "${roots[@]}"; do
        local identity
        identity=$(mole_path_identity "$root")
        if [[ ${#seen_identities[@]} -gt 0 ]] && mole_identity_in_list "$identity" "${seen_identities[@]}"; then
            continue
        fi

        seen_identities+=("$identity")
        unique_roots+=("$root")
    done

    [[ ${#unique_roots[@]} -gt 0 ]] && printf '%s\n' "${unique_roots[@]}"
}

# Scan a project root for supported build caches while pruning heavy subtrees.
scan_project_cache_root() {
    local root="$1"
    local output_file="$2"
    local scan_timeout="${MOLE_PROJECT_CACHE_SCAN_TIMEOUT:-6}"
    [[ -d "$root" ]] || return 0

    local -a find_args=(
        find -P "$root" -maxdepth 9 -mount
        "(" -name "Library" -o -name ".Trash" -o -name "node_modules" -o -name ".git" -o -name ".svn" -o -name ".hg" -o -name ".venv" -o -name "venv" -o -name ".pnpm-store" -o -name ".fvm" -o -name "DerivedData" -o -name "Pods" -o -name "miniconda3" -o -name "anaconda3" -o -name "miniforge3" -o -name "mambaforge" -o -name "site-packages" ")"
        -prune -o
        -type d
        "(" -name ".next" -o -name "__pycache__" -o -name ".dart_tool" ")"
        -print
    )

    local status=0
    local tmp_file
    tmp_file=$(create_temp_file)
    run_with_timeout "$scan_timeout" "${find_args[@]}" > "$tmp_file" 2> /dev/null || status=$?

    if [[ -s "$tmp_file" ]]; then
        while IFS= read -r match_path; do
            [[ -z "$match_path" ]] && continue
            # Skip __pycache__ dirs with no .pyc/.pyo files (empty or already cleaned)
            if [[ "${match_path##*/}" == "__pycache__" ]]; then
                local has_bytecode
                has_bytecode=$(find "$match_path" -maxdepth 1 \( -name '*.pyc' -o -name '*.pyo' \) 2>/dev/null | head -1)
                [[ -z "$has_bytecode" ]] && continue
            fi
            local project_root=""
            project_root=$(project_cache_group_root "$root" "$match_path")
            [[ -z "$project_root" ]] && project_root="$root"
            printf '%s\t%s\n' "$project_root" "$match_path" >> "$output_file"
        done < "$tmp_file"
    fi
    rm -f "$tmp_file"

    if [[ $status -eq 124 ]]; then
        debug_log "Project cache scan timed out: $root"
    elif [[ $status -ne 0 ]]; then
        debug_log "Project cache scan failed (${status}): $root"
    fi

    return 0
}

project_cache_group_root() {
    local scan_root="$1"
    local cache_path="$2"
    local candidate

    candidate=$(dirname "$cache_path")
    while [[ -n "$candidate" && "$candidate" != "/" ]]; do
        if mole_purge_is_project_root "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        [[ "$candidate" == "$scan_root" ]] && break
        candidate=$(dirname "$candidate")
    done

    printf '%s\n' "$scan_root"
}

clean_project_cache_target() {
    if [[ $# -lt 2 ]]; then
        return 0
    fi

    local description="${*: -1}"
    local -a target_paths=("${@:1:$#-1}")

    if declare -f safe_clean > /dev/null 2>&1; then
        safe_clean "${target_paths[@]}" "$description" || true
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi

    local target_path=""
    for target_path in "${target_paths[@]}"; do
        [[ -e "$target_path" ]] || continue
        safe_remove "$target_path" true || true
    done
}

flush_python_group_if_needed() {
    local group_root="$1"
    local array_name="$2"

    local group_count=0
    eval 'group_count=${#'"$array_name"'[@]}'
    [[ -z "$group_root" || "$group_count" -eq 0 ]] && return 0
    eval 'local -a group_dirs=( "${'"$array_name"'[@]}" )'
    # shellcheck disable=SC2154  # group_dirs assigned via eval above
    clean_python_bytecode_cache_group "$group_root" "${group_dirs[@]}"
}

process_project_cache_matches() {
    local matches_file="$1"
    [[ -f "$matches_file" ]] || return 0

    local current_python_root=""
    local -a current_python_dirs=()
    local record_root=""
    local cache_dir=""
    while IFS=$'\t' read -r record_root cache_dir; do
        [[ -n "$record_root" && -n "$cache_dir" ]] || continue
        case "${cache_dir##*/}" in
            ".next")
                flush_python_group_if_needed "$current_python_root" current_python_dirs
                current_python_root=""
                current_python_dirs=()
                [[ -d "$cache_dir/cache" ]] && clean_project_cache_target "$cache_dir/cache"/* "Next.js build cache" || true
                ;;
            "__pycache__")
                if [[ "$record_root" != "$current_python_root" && ${#current_python_dirs[@]} -gt 0 ]]; then
                    flush_python_group_if_needed "$current_python_root" current_python_dirs
                    current_python_dirs=()
                fi
                current_python_root="$record_root"
                [[ -d "$cache_dir" ]] && current_python_dirs+=("$cache_dir")
                ;;
            ".dart_tool")
                flush_python_group_if_needed "$current_python_root" current_python_dirs
                current_python_root=""
                current_python_dirs=()
                if [[ -d "$cache_dir" ]]; then
                    clean_project_cache_target "$cache_dir" "Flutter build cache (.dart_tool)" || true
                    local build_dir="$(dirname "$cache_dir")/build"
                    if [[ -d "$build_dir" ]]; then
                        clean_project_cache_target "$build_dir" "Flutter build cache (build/)" || true
                    fi
                fi
                ;;
        esac
    done < <(LC_ALL=C sort -u "$matches_file" 2> /dev/null)

    flush_python_group_if_needed "$current_python_root" current_python_dirs
}

clean_python_bytecode_cache_group() {
    local project_root="$1"
    shift

    local -a cache_dirs=("$@")
    [[ ${#cache_dirs[@]} -eq 0 ]] && return 0

    local display_root
    display_root=$(basename "$project_root")
    local total_size_kb=0
    local removed_count=0
    local skipped_count=0
    local -a dry_run_paths=()
    local -a dry_run_sizes=()

    local cache_dir
    for cache_dir in "${cache_dirs[@]}"; do
        [[ -d "$cache_dir" ]] || continue

        if should_protect_path "$cache_dir"; then
            skipped_count=$((skipped_count + 1))
            whitelist_skipped_count=$((${whitelist_skipped_count:-0} + 1))
            log_operation "clean" "SKIPPED" "$cache_dir" "protected"
            continue
        fi

        if is_path_whitelisted "$cache_dir"; then
            skipped_count=$((skipped_count + 1))
            whitelist_skipped_count=$((${whitelist_skipped_count:-0} + 1))
            log_operation "clean" "SKIPPED" "$cache_dir" "whitelist"
            continue
        fi

        local size_kb
        size_kb=$(get_path_size_kb "$cache_dir")
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" == "true" ]]; then
            if declare -f register_dry_run_cleanup_target > /dev/null 2>&1; then
                register_dry_run_cleanup_target "$cache_dir" || continue
            fi
            dry_run_paths+=("$cache_dir")
            dry_run_sizes+=("$size_kb")
        else
            if ! safe_remove "$cache_dir" true; then
                continue
            fi
        fi

        total_size_kb=$((total_size_kb + size_kb))
        removed_count=$((removed_count + 1))
    done

    if [[ $removed_count -eq 0 ]]; then
        return 0
    fi

    local size_human
    size_human=$(bytes_to_human "$((total_size_kb * 1024))")

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ -n "${EXPORT_LIST_FILE:-}" ]]; then
            ensure_user_file "$EXPORT_LIST_FILE"
            local i=0
            for ((i = 0; i < ${#dry_run_paths[@]}; i++)); do
                local path="${dry_run_paths[i]}"
                local path_size_kb="${dry_run_sizes[i]:-0}"
                local path_size_human
                path_size_human=$(bytes_to_human "$((path_size_kb * 1024))")
                echo "${path}  # ${path_size_human}" >> "$EXPORT_LIST_FILE"
            done
        fi

        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Python bytecode cache · ${display_root}${NC}, ${YELLOW}${removed_count} dirs, ${size_human} dry, ${skipped_count} skipped${NC}"
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Python bytecode cache · ${display_root}${NC}, ${YELLOW}${removed_count} dirs, ${size_human} dry${NC}"
        fi
    else
        local line_color
        line_color=$(cleanup_result_color_kb "$total_size_kb")
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Python bytecode cache · ${display_root}${NC}, ${line_color}${removed_count} dirs, ${size_human}${NC}, ${skipped_count} skipped"
        else
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Python bytecode cache · ${display_root}${NC}, ${line_color}${removed_count} dirs, ${size_human}${NC}"
        fi
    fi

    files_cleaned=$((${files_cleaned:-0} + removed_count))
    total_size_cleaned=$((${total_size_cleaned:-0} + total_size_kb))
    total_items=$((${total_items:-0} + 1))
    if declare -f note_activity > /dev/null 2>&1; then
        note_activity
    fi
}

# Next.js/Python/Flutter project caches scoped to discovered project roots.
clean_project_caches() {
    stop_inline_spinner 2> /dev/null || true

    local -a scan_roots=()
    local root
    while IFS= read -r root; do
        [[ -n "$root" ]] && scan_roots+=("$root")
    done < <(discover_project_cache_roots)

    [[ ${#scan_roots[@]} -eq 0 ]] && return 0

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  "
        start_inline_spinner "Searching project caches..."
    fi

    for root in "${scan_roots[@]}"; do
        local root_matches_file
        root_matches_file=$(create_temp_file)
        scan_project_cache_root "$root" "$root_matches_file"

        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi

        process_project_cache_matches "$root_matches_file"
        rm -f "$root_matches_file"

        if [[ -t 1 ]]; then
            MOLE_SPINNER_PREFIX="  "
            start_inline_spinner "Searching project caches..."
        fi
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
}
