#!/bin/bash
# Cache Cleanup Module
set -euo pipefail

_MOLE_CACHES_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MOLE_CACHES_MODULE_PATH="$_MOLE_CACHES_MODULE_DIR/${BASH_SOURCE[0]##*/}"
# shellcheck disable=SC1091
source "$_MOLE_CACHES_MODULE_DIR/purge_shared.sh"
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
# Args: $1=browser_name, $2=cache_path, $3=optional post-size guard callback,
#       $4=optional absolute SECONDS deadline shared by a larger cleanup family
# Clean Service Worker cache while protecting critical web editors.
clean_service_worker_cache() {
    local browser_name="$1"
    local cache_path="${2%/}"
    local delete_guard="${3:-}"
    local deadline_seconds="${4:-}"
    [[ ! -d "$cache_path" ]] && return 0

    # A lexical CacheStorage path below Application Support is not enough
    # authority for recursive deletion. Refuse a root reached through any
    # symlink so find and the later sink stay inside the profile we inspected.
    local physical_cache_path=""
    physical_cache_path=$(cd -P "$cache_path" 2> /dev/null && pwd -P) || return 1
    if [[ "$physical_cache_path" != "$cache_path" ]]; then
        debug_log "Refusing symlinked Service Worker cache root: $cache_path -> $physical_cache_path"
        return 1
    fi

    # Materialize the complete producer result before the first sink. A timed
    # out find may have printed a valid prefix, but that prefix is not a safe
    # deletion plan and must be discarded as a unit.
    local candidates_file=""
    candidates_file=$(create_temp_file 2> /dev/null) || return 1
    local find_timeout=""
    local find_rc=0
    find_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_PKG_LIST_SEC" "$deadline_seconds") || find_rc=$?
    if [[ $find_rc -eq 0 ]]; then
        # shellcheck disable=SC2016
        run_with_timeout "$find_timeout" sh -c \
            'find "$1" -type d -depth 2 2>/dev/null' _ "$cache_path" \
            > "$candidates_file" || find_rc=$?
    fi
    if [[ $find_rc -ne 0 ]]; then
        debug_log "Service Worker cache discovery failed for $cache_path (status $find_rc)"
        _mole_record_clean_cancellation "$find_rc"
        return "$find_rc"
    fi

    local cleaned_size=0
    local protected_count=0
    local guard_stopped=false
    while IFS= read -r cache_dir; do
        [[ ! -d "$cache_dir" ]] && continue
        [[ "$cache_dir" == "$cache_path/"* ]] || return 1
        if [[ -n "$deadline_seconds" && $SECONDS -ge $deadline_seconds ]]; then
            _mole_record_clean_cancellation 124
            return 124
        fi

        # Extract a best-effort domain name from cache folder.
        local domain=""
        domain=$(basename "$cache_dir" | grep -oE '[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}' | head -1 || echo "")
        local is_protected=false
        for protected_domain in "${PROTECTED_SW_DOMAINS[@]}"; do
            if [[ "$domain" == *"$protected_domain"* ]]; then
                is_protected=true
                protected_count=$((protected_count + 1))
                break
            fi
        done
        # Service Worker cache dirs are keyed by origin hash, so they never
        # match PROTECTED_SW_DOMAINS even when the user added Chrome SW paths
        # to their whitelist. Honor the whitelist explicitly, otherwise MV3
        # extensions lose their registered workers mid-session. See #724.
        if [[ "$is_protected" == "false" ]] && is_path_whitelisted "$cache_dir"; then
            is_protected=true
            protected_count=$((protected_count + 1))
        fi
        if [[ "$is_protected" == "false" ]]; then
            _mole_snapshot_path_identity "$cache_dir" || continue
            local expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
            local expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
            local expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
            case "$expected_parent" in
                "$physical_cache_path" | "$physical_cache_path"/*) ;;
                *)
                    debug_log "Refusing Service Worker candidate outside cache root: $cache_dir -> $expected_parent"
                    return 1
                    ;;
            esac

            local size=0
            local _du_out=""
            local du_timeout=""
            local du_rc=0
            du_timeout=$(_mole_timeout_with_deadline \
                "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || du_rc=$?
            if [[ $du_rc -eq 0 ]]; then
                _du_out=$(run_with_timeout "$du_timeout" du -skP "$cache_dir" 2> /dev/null) || du_rc=$?
            fi
            if mole_rc_timeout_or_signal "$du_rc"; then
                _mole_record_clean_cancellation "$du_rc"
                return "$du_rc"
            fi
            if [[ $du_rc -eq 0 ]]; then
                local _sz="${_du_out%%[^0-9]*}"
                [[ "$_sz" =~ ^[0-9]+$ ]] && size="$_sz"
            fi

            if [[ -n "$delete_guard" ]] && ! "$delete_guard"; then
                guard_stopped=true
                break
            fi
            if ! _mole_path_matches_identity \
                "$cache_dir" "$expected_parent" "$expected_parent_id" \
                "$expected_target_id"; then
                debug_log "Skipping Service Worker cache after identity changed: $cache_dir"
                continue
            fi
            if [[ "$DRY_RUN" == "true" ]]; then
                if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                    record_dry_run_cleanup_target "$cache_dir" "$size" 1 true || continue
                fi
            else
                local remove_rc=0
                safe_remove "$cache_dir" true "$size" "$deadline_seconds" \
                    "$expected_parent" "$expected_parent_id" \
                    "$expected_target_id" || remove_rc=$?
                if mole_rc_timeout_or_signal "$remove_rc"; then
                    return "$remove_rc"
                fi
                [[ $remove_rc -eq 0 ]] || continue
            fi
            cleaned_size=$((cleaned_size + size))
        fi
    done < "$candidates_file"
    if [[ $cleaned_size -gt 0 ]]; then
        local spinner_was_running=false
        if [[ -t 1 && -n "${INLINE_SPINNER_PID:-}" ]]; then
            stop_inline_spinner
            spinner_was_running=true
        fi
        # cleaned_size is in KB. Hand-rolled KB/1024 truncation reported any
        # sub-megabyte cleanup as "0MB"; use the shared formatter like every
        # other cleaner so amounts under 1MB render as KB.
        local cleaned_human
        cleaned_human=$(bytes_to_human "$((cleaned_size * 1024))")
        local line_color
        line_color=$(cleanup_result_color_kb "$cleaned_size")
        if [[ "$DRY_RUN" != "true" ]]; then
            if [[ $protected_count -gt 0 ]]; then
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} $browser_name Service Worker${NC} · $(colorize_human_size "${cleaned_human}"), ${protected_count} protected"
            else
                echo -e "  ${line_color}${ICON_SUCCESS}${NC} $browser_name Service Worker${NC} · $(colorize_human_size "${cleaned_human}")"
            fi
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $browser_name Service Worker, would clean $(colorize_human_size "$cleaned_human"), ${protected_count} protected"
        fi
        note_activity
        if [[ "$spinner_was_running" == "true" ]]; then
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning browser Service Worker caches..."
        fi
    fi
    [[ "$guard_stopped" == "true" ]] && return 75
    return 0
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
    if ! [[ "$_max_jobs" =~ ^[0-9]+$ ]] || [[ "$_max_jobs" -lt 1 ]]; then
        _max_jobs=1
    elif [[ "$_max_jobs" -gt 8 ]]; then
        _max_jobs=8
    fi

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

        (project_cache_has_indicators "$dir" 5 && echo "$dir" >> "$_indicator_tmp") < /dev/null &
        _indicator_pids+=($!)

        if [[ ${#_indicator_pids[@]} -ge $_max_jobs ]]; then
            local completed_pid="" indicator_slot wait_rc=0
            mole_wait_for_any_worker completed_pid "${_indicator_pids[@]}" || wait_rc=$?
            if [[ $wait_rc -ge 128 ]]; then
                for _pid in "${_indicator_pids[@]}"; do
                    kill "$_pid" 2> /dev/null || true
                done
                for _pid in "${_indicator_pids[@]}"; do
                    wait "$_pid" 2> /dev/null || true
                done
                rm -f "$_indicator_tmp"
                return "$wait_rc"
            fi
            for indicator_slot in "${!_indicator_pids[@]}"; do
                if [[ "${_indicator_pids[$indicator_slot]}" == "$completed_pid" ]]; then
                    unset '_indicator_pids[indicator_slot]'
                    break
                fi
            done
        fi
    done
    # bash 3.2 under nounset treats "${arr[@]}" on an empty array as unbound, and
    # the loop above leaves the array empty whenever $HOME has no scannable
    # project dir (every test home, and any real home whose top level is all
    # Library/Applications/dot dirs).
    if [[ ${#_indicator_pids[@]} -gt 0 ]]; then
        for _pid in "${_indicator_pids[@]}"; do
            wait "$_pid" 2> /dev/null || true
        done
    fi

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

pycache_has_bytecode() {
    local pycache_dir="$1"
    [[ -d "$pycache_dir" ]] || return 1

    local nullglob_was_set=0
    if shopt -q nullglob; then
        nullglob_was_set=1
    fi
    shopt -s nullglob
    local -a bytecode_files=("$pycache_dir"/*.pyc "$pycache_dir"/*.pyo)
    if [[ $nullglob_was_set -eq 0 ]]; then
        shopt -u nullglob
    fi

    [[ ${#bytecode_files[@]} -gt 0 ]]
}

_process_project_cache_scan_file() {
    local root="$1"
    local scan_file="$2"
    local processed_file="$3"

    while IFS= read -r match_path; do
        [[ -z "$match_path" ]] && continue
        # Skip __pycache__ dirs with no .pyc/.pyo files (empty or already cleaned)
        if [[ "${match_path##*/}" == "__pycache__" ]]; then
            pycache_has_bytecode "$match_path" || continue
        fi
        local project_root=""
        project_root=$(project_cache_group_root "$root" "$match_path")
        [[ -z "$project_root" ]] && project_root="$root"
        printf '%s\t%s\n' "$project_root" "$match_path" >> "$processed_file"
    done < "$scan_file"
}

# Scan a project root for supported build caches while pruning heavy subtrees.
scan_project_cache_root() {
    local root="$1"
    local output_file="$2"
    local scan_timeout="${MOLE_PROJECT_CACHE_SCAN_TIMEOUT:-6}"
    if [[ ! "$scan_timeout" =~ ^[0-9]+(\.[0-9]+)?$ || "$scan_timeout" =~ ^0+(\.0+)?$ ]]; then
        scan_timeout=6
    fi
    [[ -d "$root" ]] || return 0
    : > "$output_file"

    local -a find_args=(
        find -P "$root" -maxdepth 9 -mount
        "(" -name "Library" -o -name ".Trash" -o -name "node_modules" -o -name ".git" -o -name ".svn" -o -name ".hg" -o -name ".venv" -o -name "venv" -o -name ".pnpm-store" -o -name ".fvm" -o -name "DerivedData" -o -name "Pods" -o -name "miniconda3" -o -name "anaconda3" -o -name "miniforge3" -o -name "mambaforge" -o -name "site-packages" ")"
        -prune -o
        -type d
        "(" -name ".next" -o -name "__pycache__" -o -name ".dart_tool" ")"
        -print
    )

    local scan_budget
    scan_budget=$(mole_purge_timeout_budget_seconds "$scan_timeout" 6)
    local scan_deadline=$((SECONDS + scan_budget))
    local stage_timeout=""
    local status=0
    local scan_file
    scan_file=$(create_temp_file) || return 1
    local processed_file
    processed_file=$(create_temp_file) || {
        rm -f "$scan_file" # SAFE: exact scratch file created by create_temp_file above
        return 1
    }
    stage_timeout=$(_mole_timeout_with_deadline "$scan_timeout" "$scan_deadline") || status=$?
    if [[ $status -eq 0 ]]; then
        run_with_timeout "$stage_timeout" "${find_args[@]}" > "$scan_file" 2> /dev/null || status=$?
    fi

    if [[ $status -ne 0 ]]; then
        rm -f "$scan_file" "$processed_file" # SAFE: exact scratch files created by create_temp_file above
        if mole_rc_timeout "$status"; then
            debug_log "Project cache scan timed out: $root"
        else
            debug_log "Project cache scan failed (${status}): $root"
        fi
        return "$status"
    fi

    if [[ -s "$scan_file" ]]; then
        stage_timeout=$(_mole_timeout_with_deadline "$scan_timeout" "$scan_deadline") || status=$?
        if [[ $status -eq 0 ]]; then
            # shellcheck disable=SC2016 # The child shell expands its own positional parameters.
            run_with_timeout "$stage_timeout" /bin/bash --noprofile --norc -c '
                set -euo pipefail
                source "$1"
                _process_project_cache_scan_file "$2" "$3" "$4"
            ' _ "$_MOLE_CACHES_MODULE_PATH" "$root" "$scan_file" "$processed_file" || status=$?
        fi
    fi
    rm -f "$scan_file" # SAFE: exact scratch file created by create_temp_file above
    if [[ $status -ne 0 ]]; then
        rm -f "$processed_file" # SAFE: exact scratch file created by create_temp_file above
        if mole_rc_timeout "$status"; then
            debug_log "Project cache post-processing timed out: $root"
        else
            debug_log "Project cache post-processing failed (${status}): $root"
        fi
        return "$status"
    fi
    if ! mv "$processed_file" "$output_file"; then
        rm -f "$processed_file" # SAFE: exact scratch file created by create_temp_file above
        return 1
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

# Project caches are found by name only. Keep any that Git tracks, such as a
# committed test fixture under .dart_tool or bytecode checked in by mistake,
# and keep them when the probe cannot finish.
project_cache_has_tracked_files() {
    local cache_path="$1"
    local tracked_rc=0
    mole_path_has_git_tracked_files "$cache_path" || tracked_rc=$?
    [[ $tracked_rc -eq 1 ]] && return 1
    debug_log "Keeping project cache tracked by Git: $cache_path"
    log_operation "clean" "SKIPPED" "$cache_path" "tracked by git"
    return 0
}

clean_project_cache_target() {
    if [[ $# -lt 2 ]]; then
        return 0
    fi

    local description="${*: -1}"
    local -a target_paths=()
    local target_path=""
    for target_path in "${@:1:$#-1}"; do
        if [[ -d "$target_path" ]] && project_cache_has_tracked_files "$target_path"; then
            continue
        fi
        target_paths+=("$target_path")
    done
    [[ ${#target_paths[@]} -gt 0 ]] || return 0

    if declare -f safe_clean > /dev/null 2>&1; then
        local clean_rc=0
        safe_clean "${target_paths[@]}" "$description" || clean_rc=$?
        if mole_rc_timeout_or_signal "$clean_rc"; then
            return "$clean_rc"
        fi
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi

    for target_path in "${target_paths[@]}"; do
        [[ -e "$target_path" ]] || continue
        local remove_rc=0
        safe_remove "$target_path" true || remove_rc=$?
        if mole_rc_timeout_or_signal "$remove_rc"; then
            return "$remove_rc"
        fi
    done
}

flush_python_group_if_needed() {
    local group_root="$1"
    local array_name="$2"

    local group_count=0
    # eval: indirect array length by name; bash 3.2 has no nameref
    eval 'group_count=${#'"$array_name"'[@]}'
    [[ -z "$group_root" || "$group_count" -eq 0 ]] && return 0
    # eval: indirect array copy by name; bash 3.2 has no nameref
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
                flush_python_group_if_needed "$current_python_root" current_python_dirs || return $?
                current_python_root=""
                current_python_dirs=()
                if [[ -d "$cache_dir/cache" ]]; then
                    clean_project_cache_target "$cache_dir/cache"/* "Next.js build cache" || return $?
                fi
                ;;
            "__pycache__")
                if [[ "$record_root" != "$current_python_root" && ${#current_python_dirs[@]} -gt 0 ]]; then
                    flush_python_group_if_needed "$current_python_root" current_python_dirs || return $?
                    current_python_dirs=()
                fi
                current_python_root="$record_root"
                [[ -d "$cache_dir" ]] && current_python_dirs+=("$cache_dir")
                ;;
            ".dart_tool")
                flush_python_group_if_needed "$current_python_root" current_python_dirs || return $?
                current_python_root=""
                current_python_dirs=()
                if [[ -d "$cache_dir" ]]; then
                    clean_project_cache_target "$cache_dir" "Flutter build cache (.dart_tool)" || return $?
                    local build_dir="$(dirname "$cache_dir")/build"
                    if [[ -d "$build_dir" ]]; then
                        clean_project_cache_target "$build_dir" "Flutter build cache (build/)" || return $?
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

        project_cache_has_tracked_files "$cache_dir" && continue

        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$cache_dir") || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" == "true" ]]; then
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$cache_dir" "$size_kb" 1 true || continue
            elif declare -f register_dry_run_cleanup_target > /dev/null 2>&1; then
                register_dry_run_cleanup_target "$cache_dir" || continue
            fi
            dry_run_paths+=("$cache_dir")
            dry_run_sizes+=("$size_kb")
        else
            if ! safe_remove "$cache_dir" true "$size_kb"; then
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
        if ! declare -f record_dry_run_cleanup_target > /dev/null 2>&1 && [[ -n "${EXPORT_LIST_FILE:-}" ]]; then
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
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Python bytecode cache · ${display_root}${NC} · ${YELLOW}${removed_count} dirs, $(colorize_human_size "$size_human") ${YELLOW}dry, ${skipped_count} skipped${NC}"
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Python bytecode cache · ${display_root}${NC} · ${YELLOW}${removed_count} dirs, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        fi
    else
        local line_color
        line_color=$(cleanup_result_color_kb "$total_size_kb")
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Python bytecode cache · ${display_root}${NC} · ${line_color}${removed_count} dirs, $(colorize_human_size "${size_human}"), ${skipped_count} skipped"
        else
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Python bytecode cache · ${display_root}${NC} · ${line_color}${removed_count} dirs, $(colorize_human_size "${size_human}")"
        fi
    fi

    mole_add_cleaned_row "$removed_count" "$total_size_kb"
    if declare -f note_activity > /dev/null 2>&1; then
        note_activity
    fi
}

# Next.js/Python/Flutter project caches scoped to discovered project roots.
clean_project_caches() {
    stop_inline_spinner 2> /dev/null || true

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  "
        start_inline_spinner "Searching project caches..."
    fi

    local -a scan_roots=()
    local root
    while IFS= read -r root; do
        [[ -n "$root" ]] && scan_roots+=("$root")
    done < <(discover_project_cache_roots)

    if [[ ${#scan_roots[@]} -eq 0 ]]; then
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        return 0
    fi

    local -a root_matches_files=()
    local -a scan_pids=()
    local -a scan_statuses=()
    local failed_scan_count=0
    local scan_interrupt_status=0
    local previous_scan_int_trap=""
    local previous_scan_term_trap=""
    local scan_traps_installed=false
    local max_scan_jobs
    max_scan_jobs=$(get_optimal_parallel_jobs io)
    if ! [[ "$max_scan_jobs" =~ ^[0-9]+$ ]] || [[ "$max_scan_jobs" -lt 1 ]]; then
        max_scan_jobs=1
    elif [[ "$max_scan_jobs" -gt 4 ]]; then
        max_scan_jobs=4
    fi

    _wait_for_project_cache_scan_batch() {
        local drain="${1:-true}" scan_index completed_pid
        while [[ ${#scan_pids[@]} -gt 0 ]]; do
            local scan_rc=0
            completed_pid=""
            mole_wait_for_any_worker completed_pid "${scan_pids[@]}" || scan_rc=$?
            if [[ $scan_rc -ge 128 ]]; then
                _cleanup_project_cache_scan_workers
                return "$scan_rc"
            fi
            for scan_index in "${!scan_pids[@]}"; do
                if [[ "${scan_pids[$scan_index]}" == "$completed_pid" ]]; then
                    scan_statuses[scan_index]="$scan_rc"
                    unset 'scan_pids[scan_index]'
                    break
                fi
            done
            [[ "$drain" == "true" ]] || break
        done
        return 0
    }

    # shellcheck disable=SC2329 # Invoked by the signal trap below.
    _cleanup_project_cache_scan_workers() {
        local scan_pid
        for scan_pid in "${scan_pids[@]+"${scan_pids[@]}"}"; do
            kill "$scan_pid" 2> /dev/null || true
        done
        for scan_pid in "${scan_pids[@]+"${scan_pids[@]}"}"; do
            wait "$scan_pid" 2> /dev/null || true
        done
        scan_pids=()
    }

    # shellcheck disable=SC2329 # Invoked by the signal trap below.
    _handle_project_cache_scan_interrupt() {
        local interrupt_status="$1"
        if [[ $scan_interrupt_status -lt 128 ]]; then
            scan_interrupt_status="$interrupt_status"
        fi
        _cleanup_project_cache_scan_workers
    }

    _restore_project_cache_scan_traps() {
        [[ "$scan_traps_installed" == "true" ]] || return 0
        trap - INT TERM
        scan_traps_installed=false
        # eval: restore caller traps captured by $(trap -p)
        [[ -n "$previous_scan_int_trap" ]] && eval "$previous_scan_int_trap"
        [[ -n "$previous_scan_term_trap" ]] && eval "$previous_scan_term_trap"
        return 0
    }

    previous_scan_int_trap=$(trap -p INT || true)
    previous_scan_term_trap=$(trap -p TERM || true)
    trap '_handle_project_cache_scan_interrupt 130' INT
    trap '_handle_project_cache_scan_interrupt 143' TERM
    scan_traps_installed=true

    for root in "${scan_roots[@]}"; do
        [[ $scan_interrupt_status -ge 128 ]] && break
        local root_matches_file
        if ! root_matches_file=$(create_temp_file); then
            failed_scan_count=$((failed_scan_count + 1))
            continue
        fi
        root_matches_files+=("$root_matches_file")
        [[ $scan_interrupt_status -ge 128 ]] && break
        scan_project_cache_root "$root" "$root_matches_file" < /dev/null &
        local scan_root_index=$((${#root_matches_files[@]} - 1))
        scan_pids[scan_root_index]="$!"
        if [[ ${#scan_pids[@]} -ge $max_scan_jobs ]]; then
            _wait_for_project_cache_scan_batch false || scan_interrupt_status=$?
            if [[ $scan_interrupt_status -ge 128 ]]; then
                break
            fi
        fi
    done
    if [[ $scan_interrupt_status -lt 128 ]]; then
        _wait_for_project_cache_scan_batch || scan_interrupt_status=$?
    fi
    _restore_project_cache_scan_traps

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ $scan_interrupt_status -ge 128 ]]; then
        local pending_file
        for pending_file in "${root_matches_files[@]}"; do
            rm -f "$pending_file" # SAFE: exact scratch file created by create_temp_file above
        done
        return "$scan_interrupt_status"
    fi

    local scan_index
    for ((scan_index = 0; scan_index < ${#root_matches_files[@]}; scan_index++)); do
        local preflight_rc="${scan_statuses[$scan_index]:-1}"
        if [[ $preflight_rc -ge 128 ]]; then
            local pending_file
            for pending_file in "${root_matches_files[@]}"; do
                rm -f "$pending_file"
            done
            return "$preflight_rc"
        fi
    done

    for ((scan_index = 0; scan_index < ${#root_matches_files[@]}; scan_index++)); do
        root_matches_file="${root_matches_files[$scan_index]}"
        local scan_rc="${scan_statuses[$scan_index]:-1}"
        if [[ $scan_rc -ne 0 ]]; then
            failed_scan_count=$((failed_scan_count + 1))
            rm -f "$root_matches_file"
            continue
        fi

        local process_rc=0
        process_project_cache_matches "$root_matches_file" || process_rc=$?
        rm -f "$root_matches_file"
        if [[ $process_rc -ne 0 ]]; then
            local pending_file
            for pending_file in "${root_matches_files[@]}"; do
                rm -f "$pending_file"
            done
            return "$process_rc"
        fi
    done

    if [[ $failed_scan_count -gt 0 ]]; then
        local scan_noun="root scans"
        if [[ $failed_scan_count -eq 1 ]]; then
            scan_noun="root scan"
        fi
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Project caches · skipped ${failed_scan_count} slow/incomplete ${scan_noun}"
        if declare -f note_activity > /dev/null 2>&1; then
            note_activity
        fi
    fi
}
