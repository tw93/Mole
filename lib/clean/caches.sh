#!/bin/bash
# Cache Cleanup Module
set -euo pipefail

_MOLE_CACHES_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MOLE_CACHES_MODULE_PATH="$_MOLE_CACHES_MODULE_DIR/${BASH_SOURCE[0]##*/}"
# shellcheck disable=SC1091
source "$_MOLE_CACHES_MODULE_DIR/purge_shared.sh"
# Analyzers before 1.48.0 wrote one flat `<hash>.cache` per scanned directory
# straight into ~/.cache/mole with no cap; one user reached 1.88M files and
# 7.82GB, and listing that directory froze Mole Mac's Analyze and even `ls`.
# The analyzer sweeps them on its own start, which users who never run
# `mo analyze` again never reach, so clean starts the same sweep. It matches
# the analyzer's predicate exactly (regular `*.cache` files and the overview
# snapshot at the top level, never the shell's state files or subdirectories),
# runs in the background because a large store takes minutes to unlink, and is
# resumable: whatever one run does not reach the next run picks up.
sweep_legacy_analyzer_cache_now() {
    local root="$1"
    [[ -d "$root" && ! -L "$root" ]] || return 0
    local -a legacy_match=(-mindepth 1 -maxdepth 1 -type f \( -name '*.cache' -o -name 'overview_sizes.json' \))
    command find "$root" "${legacy_match[@]}" -delete 2> /dev/null || true # SAFE: Mole's own regenerable analyzer cache, top-level regular files only
}

start_legacy_analyzer_cache_sweep() {
    [[ "${DRY_RUN:-false}" == "true" || "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0
    local root="$HOME/.cache/mole"
    [[ -d "$root" && ! -L "$root" ]] || return 0
    [[ -n "$(command find "$root" -mindepth 1 -maxdepth 1 -type f -name '*.cache' -print -quit 2> /dev/null)" ]] || return 0
    (sweep_legacy_analyzer_cache_now "$root") < /dev/null > /dev/null 2>&1 &
    disown 2> /dev/null || true
}

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
        echo -e "${GRAY}You may see ${GREEN}${#tcc_dirs[@]} permission dialogs${NC}${GRAY}, allow each one so these caches can be cleaned.${NC}"
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
            'find "$1" -mindepth 2 -maxdepth 2 -type d 2>/dev/null' _ "$cache_path" \
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
    done < <(mole_purge_read_paths_config "$HOME/.config/mole/purge_paths" 2> /dev/null)

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

# `~/Library/CloudStorage` is a File Provider root: its domain folders are
# virtual, and a walk that descends into a signed-out or slow provider fails
# with "Operation not permitted" or blocks. A depth-two directory listing
# decides cheaply whether the root is walkable at all, so the per-root scan
# budget is not spent on a root that can only fail. Readable cloud roots keep
# the normal scan; an unreadable one is still counted as a skipped root.
project_cache_root_is_walkable() {
    local root="${1%/}"
    [[ "$root" == "$HOME/Library/CloudStorage" ]] || return 0
    local probe_timeout="$MOLE_TIMEOUT_QUICK_DETECT_SEC"
    run_with_timeout "$probe_timeout" "$FIND_BSD" -P "$root" -mindepth 2 -maxdepth 2 \
        -type d -print -quit < /dev/null > /dev/null 2>&1
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

    # Build outputs and package stores (target, .build, .gradle, Index.noindex,
    # _cacache) never hold a project cache worth cleaning, but on a typical
    # projects folder they can be half of the directories walked, enough to push
    # the scan past its timeout on a busy disk and skip the whole root.
    local -a find_args=(
        "$FIND_BSD" -P "$root" -maxdepth 9 -mount
        "(" -name "Library" -o -name ".Trash" -o -name "node_modules" -o -name ".git" -o -name ".svn" -o -name ".hg" -o -name ".venv" -o -name "venv" -o -name ".pnpm-store" -o -name ".fvm" -o -name "DerivedData" -o -name "Pods" -o -name "miniconda3" -o -name "anaconda3" -o -name "miniforge3" -o -name "mambaforge" -o -name "site-packages" -o -name "target" -o -name ".build" -o -name ".gradle" -o -name "Index.noindex" -o -name "_cacache" ")"
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
# and keep them when Git could not answer.
#
# process_project_cache_matches asks Git once per repository and records each
# candidate as T (tracked), U (unknown) or C (clear), one per line, held here
# with a leading and trailing newline so a lookup needs no extra process. One
# bounded probe per cache cost about 120 ms each, which a repository with
# hundreds of __pycache__ folders turned into minutes.
_project_cache_git_index=""

# Printable ASCII only, judged bytewise whatever the caller's locale.
_project_cache_path_is_ascii() {
    local LC_ALL=C
    [[ "$1" != *[![:print:]]* ]]
}

# Build the index for every candidate a matches file will reach. All Git
# listings share the deadline given; a repository that cannot be listed in
# time, or whose listing fails, marks its candidates unknown. Signals propagate.
project_cache_build_git_index() {
    local matches_file="$1"
    local index_file="$2"
    local deadline="$3"
    local work_dir=""
    : > "$index_file" || return 1
    work_dir=$(create_temp_dir) || return 1

    local -a logical_roots=() physical_roots=()
    local record_root="" cache_dir="" candidate="" physical="" repo="" i
    local candidates_file="$work_dir/candidates"
    : > "$candidates_file"
    while IFS=$'\t' read -r record_root cache_dir; do
        [[ -n "$record_root" && -n "$cache_dir" ]] || continue
        # find -P never follows links below its root, so only the record root
        # can carry an alias; resolve it once and keep each suffix as found.
        local root_physical=""
        for ((i = 0; i < ${#logical_roots[@]}; i++)); do
            if [[ "${logical_roots[$i]}" == "$record_root" ]]; then
                root_physical="${physical_roots[$i]}"
                break
            fi
        done
        if [[ -z "$root_physical" ]]; then
            root_physical=$(cd "$record_root" 2> /dev/null && /bin/pwd -P) || root_physical="?"
            logical_roots+=("$record_root")
            physical_roots+=("$root_physical")
        fi
        local -a candidates=()
        case "${cache_dir##*/}" in
            ".next")
                # A linked cache folder puts its children in another tree that
                # this repository cannot answer for; keep all of them.
                if [[ -L "$cache_dir/cache" ]]; then
                    for candidate in "$cache_dir/cache"/*; do
                        printf 'U%s\n' "$candidate" >> "$index_file"
                    done
                    continue
                fi
                for candidate in "$cache_dir/cache"/*; do
                    [[ -e "$candidate" || -L "$candidate" ]] && candidates+=("$candidate")
                done
                ;;
            "__pycache__") candidates=("$cache_dir") ;;
            ".dart_tool")
                candidates=("$cache_dir")
                if [[ -L "$(dirname "$cache_dir")/build" ]]; then
                    printf 'U%s\n' "$(dirname "$cache_dir")/build" >> "$index_file"
                elif [[ -d "$(dirname "$cache_dir")/build" ]]; then
                    candidates+=("$(dirname "$cache_dir")/build")
                fi
                ;;
        esac
        for candidate in "${candidates[@]+"${candidates[@]}"}"; do
            if [[ "$root_physical" == "?" || "$candidate" != "$record_root"/* ]]; then
                printf 'U%s\n' "$candidate" >> "$index_file"
                continue
            fi
            physical="$root_physical/${candidate#"$record_root"/}"
            if mole_find_git_repo_root "$physical"; then
                repo="$MOLE_GIT_REPO_ROOT"
                if [[ "$repo" == "$physical" ]]; then
                    # A cache folder that is its own repository is not a cache.
                    printf 'U%s\n' "$candidate" >> "$index_file"
                    continue
                fi
                local rel="${physical#"$repo"/}"
                if ! _project_cache_path_is_ascii "$rel"; then
                    # Git lists macOS names precomposed while the disk may keep
                    # them decomposed, so bytes cannot be compared. Let Git
                    # normalize this one directory; a file stays unknown.
                    local probe_rc=2
                    if [[ -d "$candidate" && ! -L "$candidate" ]]; then
                        probe_rc=0
                        mole_path_has_git_tracked_files "$candidate" "$deadline" || probe_rc=$?
                        if [[ $probe_rc -gt 128 ]]; then
                            rm -rf "$work_dir" # SAFE: exact mktemp-created project cache index scratch directory
                            return "$probe_rc"
                        fi
                    fi
                    case "$probe_rc" in
                        0) printf 'T%s\n' "$candidate" >> "$index_file" ;;
                        1) printf 'C%s\n' "$candidate" >> "$index_file" ;;
                        *) printf 'U%s\n' "$candidate" >> "$index_file" ;;
                    esac
                    continue
                fi
                printf '%s\t%s\t%s\n' "$repo" "$rel" "$candidate" >> "$candidates_file"
            else
                printf 'C%s\n' "$candidate" >> "$index_file"
            fi
        done
    done < <(LC_ALL=C sort -u "$matches_file" 2> /dev/null)

    local current_repo="" listing_rc=0
    local group_file="$work_dir/group" listing_file="$work_dir/listing"
    _project_cache_index_flush_group() {
        [[ -n "$current_repo" && -s "$group_file" ]] || return 0
        listing_rc=0
        mole_git_ls_files "$current_repo" "$deadline" "$current_repo" -z -- . \
            > "$listing_file" || listing_rc=$?
        # git exits 128 for its own fatal errors (a dangling worktree link,
        # an unsafe repository); only 129 and above come from a signal.
        if [[ $listing_rc -gt 128 ]]; then
            return "$listing_rc"
        fi
        if [[ $listing_rc -ne 0 ]]; then
            debug_log "Git listing incomplete for $current_repo (status $listing_rc); its project caches are kept"
            awk -F '\t' '{ print "U" $3 }' "$group_file" >> "$index_file"
            return 0
        fi
        # A candidate is tracked when a listed path equals it or lies below it.
        # Case is folded on both sides: the disk may keep a folder's old
        # spelling after a case-only rename while the index keeps the one Git
        # saw, and a case-sensitive volume can only over-keep. Two candidates
        # that differ only in case share a key, and the one that lost it is
        # absent from the index, which keeps it.
        tr '\0' '\n' < "$listing_file" | LC_ALL=C awk -F '\t' '
            FNR == NR { want[tolower($1)] = $2; next }
            {
                n = split(tolower($0), part, "/")
                prefix = ""
                for (i = 1; i <= n; i++) {
                    prefix = (i == 1) ? part[1] : prefix "/" part[i]
                    if (prefix in want) { print "T" want[prefix]; delete want[prefix] }
                }
            }
            END { for (rel in want) print "C" want[rel] }
        ' <(cut -f2,3 "$group_file") - >> "$index_file"
    }
    local group_rc=0
    while IFS=$'\t' read -r repo physical candidate; do
        if [[ "$repo" != "$current_repo" ]]; then
            _project_cache_index_flush_group || group_rc=$?
            [[ $group_rc -eq 0 ]] || break
            current_repo="$repo"
            : > "$group_file"
        fi
        printf '%s\t%s\t%s\n' "$repo" "$physical" "$candidate" >> "$group_file"
    done < <(LC_ALL=C sort "$candidates_file")
    [[ $group_rc -eq 0 ]] && { _project_cache_index_flush_group || group_rc=$?; }
    unset -f _project_cache_index_flush_group
    rm -rf "$work_dir" # SAFE: exact mktemp-created project cache index scratch directory
    return "$group_rc"
}

# 0 when Git tracks files in the path, 1 when it is clear, 2 when unknown.
# Without an index, as for a direct call, ask Git about this one path.
project_cache_git_status() {
    local path="$1"
    if [[ -z "$_project_cache_git_index" ]]; then
        local probe_rc=0
        mole_path_has_git_tracked_files "$path" || probe_rc=$?
        return "$probe_rc"
    fi
    local nl=$'\n'
    [[ "$_project_cache_git_index" == *"${nl}T$path$nl"* ]] && return 0
    [[ "$_project_cache_git_index" == *"${nl}C$path$nl"* ]] && return 1
    # Unknown, or a path the index never saw, such as a file created after it
    # was built: no free pass.
    return 2
}

# build/ counts as Flutter output by convention only, and a repository inside
# it (a plugin checkout, a vendored package) is authored work the outer Git
# listing never sees. 0 keeps the folder, 1 clears it, a signal propagates;
# a scan that cannot finish keeps the folder.
_project_cache_holds_nested_repo() {
    local dir="$1"
    local found="" scan_rc=0
    found=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find -P "$dir" -mindepth 1 -name .git -print -quit 2> /dev/null) || scan_rc=$?
    [[ $scan_rc -gt 128 ]] && return "$scan_rc"
    local reason=""
    if [[ $scan_rc -ne 0 ]]; then
        reason="nested repository check incomplete"
    elif [[ -n "$found" ]]; then
        reason="holds a nested git repository"
    else
        return 1
    fi
    debug_log "Keeping project cache, $reason: $dir"
    log_operation "clean" "SKIPPED" "$dir" "$reason"
    return 0
}

project_cache_has_tracked_files() {
    local cache_path="$1"
    local tracked_rc=0
    project_cache_git_status "$cache_path" || tracked_rc=$?
    [[ $tracked_rc -le 128 ]] || return "$tracked_rc"
    [[ $tracked_rc -eq 1 ]] && return 1
    local reason="tracked by git"
    [[ $tracked_rc -eq 0 ]] || reason="git status unknown"
    debug_log "Keeping project cache, $reason: $cache_path"
    log_operation "clean" "SKIPPED" "$cache_path" "$reason"
    return 0
}

# Discovery's repository index is only a filter, never deletion authority.
# Re-read literal Git ancestry and nested repositories after sizing and at
# safe_remove's final boundary. Files under .next/cache need the same check.
#
# Each probe draws on a bound of its own, never on a budget shared with the
# other candidates: every deletion asks twice, so a shared one ran out on a few
# hundred caches and the rest were silently kept.
#
# A refusal below concerns this path alone, so it names the path for a guarded
# batch to skip and go on. Only the outer guard's refusal and a signal stop it.
_project_cache_final_guard() {
    local path="$1" git_deadline=$((SECONDS + MOLE_TIMEOUT_MEDIUM_PROBE_SEC))
    local rc=0 evidence="" physical="" repo="" outer_rc=0
    _MOLE_SAFE_CLEAN_SKIP_PATH="$path"
    [[ -e "$path" && ! -L "$path" ]] || return 1
    _mole_snapshot_path_identity "$path" || return 1
    local parent="$_MOLE_PATH_SNAPSHOT_PARENT" parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID" target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    physical="$parent/${path##*/}"
    if mole_find_git_repo_root "$physical"; then
        repo="$MOLE_GIT_REPO_ROOT"
        [[ "$repo" != "$physical" ]] || return 1
        mole_git_path_spec "$repo" "$physical"
        evidence=$(mole_git_ls_files "$repo" "$git_deadline" "$repo" -- "$MOLE_GIT_PATH_SPEC") || rc=$?
        [[ $rc -le 128 ]] || return "$rc"
        if [[ $rc -ne 0 || -n "$evidence" ]]; then
            debug_log "Keeping project cache after Git recheck: $path (status $rc)"
            return 1
        fi
    fi
    if [[ -d "$path" ]]; then
        rc=0
        _project_cache_holds_nested_repo "$path" || rc=$?
        [[ $rc -le 128 ]] || return "$rc"
        [[ $rc -eq 1 ]] || return 1
    fi
    if [[ -n "${_project_cache_outer_guard:-}" ]]; then
        "$_project_cache_outer_guard" "$path" || outer_rc=$?
        if [[ $outer_rc -ne 0 ]]; then
            _MOLE_SAFE_CLEAN_SKIP_PATH=""
            return "$outer_rc"
        fi
    fi
    _mole_path_matches_identity "$path" "$parent" "$parent_id" "$target_id" || return 1
    _MOLE_SAFE_CLEAN_SKIP_PATH=""
    _MOLE_SAFE_CLEAN_BOUND_PATH="$path"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$parent"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$parent_id"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$target_id"
}

clean_project_cache_target() {
    if [[ $# -lt 2 ]]; then
        return 0
    fi

    local description="${*: -1}"
    local -a target_paths=()
    local target_path=""
    for target_path in "${@:1:$#-1}"; do
        # Files count too: .next/cache hands over each child, directory or not.
        if [[ -e "$target_path" || -L "$target_path" ]]; then
            local tracked_rc=0
            project_cache_has_tracked_files "$target_path" || tracked_rc=$?
            [[ $tracked_rc -le 128 ]] || return "$tracked_rc"
            [[ $tracked_rc -ne 0 ]] || continue
        fi
        target_paths+=("$target_path")
    done
    [[ ${#target_paths[@]} -gt 0 ]] || return 0

    local _project_cache_outer_guard="${_MOLE_SAFE_REMOVE_FINAL_GUARD:-}"
    local _MOLE_SAFE_REMOVE_FINAL_GUARD=_project_cache_final_guard
    if declare -f safe_clean > /dev/null 2>&1; then
        local clean_rc=0
        safe_clean_guarded _project_cache_final_guard "${target_paths[@]}" "$description" || clean_rc=$?
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
        # Same policy as the guarded route: a removal timeout is not a stop.
        [[ $remove_rc -lt 128 ]] || return "$remove_rc"
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

    # Keep the index local so a later direct call never reads a stale one.
    local _project_cache_git_index=""
    local index_file="" index_rc=0
    index_file=$(create_temp_file) || return 0
    # A fresh budget for each root: time spent cleaning an earlier root must not
    # leave this one's listings with none.
    project_cache_build_git_index "$matches_file" "$index_file" \
        "$((SECONDS + MOLE_TIMEOUT_HINT_SCAN_SEC))" || index_rc=$?
    if [[ $index_rc -ne 0 ]]; then
        rm -f "$index_file" # SAFE: exact scratch file created by create_temp_file above
        [[ $index_rc -gt 128 ]] && return "$index_rc"
        # Without the index nothing proves a cache untracked: keep them all.
        debug_log "Project cache Git index failed (status $index_rc); project caches kept"
        return 0
    fi
    # Unknown entries are left out: absent already means keep, and every
    # lookup scans this string, so it holds only what can change a decision.
    _project_cache_git_index=$'\n'"$(grep -E '^[TC]' "$index_file" || true)"$'\n'
    local process_rc=0
    _process_project_cache_matches_indexed "$matches_file" || process_rc=$?
    rm -f "$index_file" # SAFE: exact scratch file created by create_temp_file above
    return "$process_rc"
}

_process_project_cache_matches_indexed() {
    local matches_file="$1"

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
                    # build/ counts as Flutter output only beside a .dart_tool,
                    # so one that Git tracks or cannot answer for leaves it
                    # alone. A .dart_tool kept for another reason (a whitelist
                    # entry, a nested repository) says nothing about build/,
                    # which passes its own checks below.
                    local tracked_rc=0
                    project_cache_has_tracked_files "$cache_dir" || tracked_rc=$?
                    [[ $tracked_rc -le 128 ]] || return "$tracked_rc"
                    [[ $tracked_rc -ne 0 ]] || continue
                    clean_project_cache_target "$cache_dir" "Flutter build cache (.dart_tool)" || return $?
                    local build_dir="$(dirname "$cache_dir")/build"
                    if [[ -d "$build_dir" ]]; then
                        local nested_rc=0
                        _project_cache_holds_nested_repo "$build_dir" || nested_rc=$?
                        [[ $nested_rc -gt 128 ]] && return "$nested_rc"
                        if [[ $nested_rc -eq 1 ]]; then
                            clean_project_cache_target "$build_dir" "Flutter build cache (build/)" || return $?
                        fi
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
    local _project_cache_outer_guard="${_MOLE_SAFE_REMOVE_FINAL_GUARD:-}"
    local _MOLE_SAFE_REMOVE_FINAL_GUARD=_project_cache_final_guard

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

        local tracked_rc=0
        project_cache_has_tracked_files "$cache_dir" || tracked_rc=$?
        [[ $tracked_rc -le 128 ]] || return "$tracked_rc"
        [[ $tracked_rc -ne 0 ]] || continue

        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$cache_dir") || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        local guard_rc=0
        _project_cache_final_guard "$cache_dir" || guard_rc=$?
        [[ $guard_rc -le 128 ]] || return "$guard_rc"
        [[ $guard_rc -eq 0 ]] || continue
        if [[ "$DRY_RUN" == "true" ]]; then
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$cache_dir" "$size_kb" 1 true || continue
            elif declare -f register_dry_run_cleanup_target > /dev/null 2>&1; then
                register_dry_run_cleanup_target "$cache_dir" || continue
            fi
            dry_run_paths+=("$cache_dir")
            dry_run_sizes+=("$size_kb")
        else
            local remove_rc=0
            safe_remove "$cache_dir" true "$size_kb" || remove_rc=$?
            # A removal timeout (124) is one failed removal, as in
            # _safe_clean_impl: only a signal ends the run.
            [[ $remove_rc -lt 128 ]] || return "$remove_rc"
            [[ $remove_rc -eq 0 ]] || continue
        fi

        total_size_kb=$((total_size_kb + size_kb))
        removed_count=$((removed_count + 1))
    done

    if [[ $removed_count -eq 0 ]]; then
        return 0
    fi
    stop_section_spinner

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
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Python bytecode cache · ${display_root}${NC} · ${YELLOW}$(mole_count_label "${removed_count}" dir), $(colorize_human_size "$size_human") ${YELLOW}dry, ${skipped_count} skipped${NC}"
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Python bytecode cache · ${display_root}${NC} · ${YELLOW}$(mole_count_label "${removed_count}" dir), $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        fi
    else
        local line_color
        line_color=$(cleanup_result_color_kb "$total_size_kb")
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Python bytecode cache · ${display_root}${NC} · ${line_color}$(mole_count_label "${removed_count}" dir), $(colorize_human_size "${size_human}"), ${skipped_count} skipped"
        else
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Python bytecode cache · ${display_root}${NC} · ${line_color}$(mole_count_label "${removed_count}" dir), $(colorize_human_size "${size_human}")"
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

    local scan_manifest="" scan_rc=0
    if [[ -n "$_MOLE_PROJECT_CACHE_PREFETCH_PID" ]]; then
        scan_manifest="$_MOLE_PROJECT_CACHE_PREFETCH_MANIFEST"
        _wait_project_cache_prefetch || scan_rc=$?
        if [[ $_MOLE_PROJECT_CACHE_PREFETCH_SIGNAL -ge 128 ]]; then
            # Interrupted while waiting: stop the scan, as the inline scan's
            # own traps would, and let the step record the cancellation.
            scan_rc=$_MOLE_PROJECT_CACHE_PREFETCH_SIGNAL
            stop_project_cache_prefetch
            if [[ -t 1 ]]; then
                stop_inline_spinner
            fi
            return "$scan_rc"
        fi
        rm -f "$_MOLE_PROJECT_CACHE_PREFETCH_DONE" # SAFE: exact scratch file created by create_temp_file
        _MOLE_PROJECT_CACHE_PREFETCH_PID=""
        _MOLE_PROJECT_CACHE_PREFETCH_MANIFEST=""
        _MOLE_PROJECT_CACHE_PREFETCH_DONE=""
    elif scan_manifest=$(create_temp_file); then
        scan_project_cache_roots "$scan_manifest" || scan_rc=$?
    else
        scan_manifest=""
    fi

    local collect_rc=0
    if [[ $scan_rc -ge 128 ]]; then
        collect_rc=$scan_rc
    elif [[ -s "$scan_manifest" ]]; then
        # Checking the matches took 1.1s before the first row; the spinner
        # stays up until a row prints (rows stop it themselves).
        if [[ -t 1 ]]; then start_section_spinner "Checking project caches..."; fi
        collect_project_cache_scans "$scan_manifest" || collect_rc=$?
    fi
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    if [[ -n "$scan_manifest" ]]; then
        rm -f "$scan_manifest" # SAFE: exact scratch file created by create_temp_file
    fi
    return "$collect_rc"
}

# The scan only reads project roots, which no section before Developer tools
# writes, so perform_cleanup starts it early. Matches are rechecked at the sink.
_MOLE_PROJECT_CACHE_PREFETCH_PID=""
_MOLE_PROJECT_CACHE_PREFETCH_MANIFEST=""
# Written when the scan exits. Bash frees a finished job's PID at once, so
# stop signals the PID only while this is still empty.
_MOLE_PROJECT_CACHE_PREFETCH_DONE=""
_MOLE_PROJECT_CACHE_PREFETCH_SIGNAL=0

start_project_cache_prefetch() {
    [[ -z "$_MOLE_PROJECT_CACHE_PREFETCH_PID" ]] || return 0
    local scan_manifest done_marker
    scan_manifest=$(create_temp_file) || return 0
    if ! done_marker=$(create_temp_file); then
        rm -f "$scan_manifest" # SAFE: exact scratch file created by create_temp_file
        return 0
    fi
    _MOLE_PROJECT_CACHE_PREFETCH_MANIFEST="$scan_manifest"
    _MOLE_PROJECT_CACHE_PREFETCH_DONE="$done_marker"

    # A signal between the launch and the PID assignment would reach the
    # caller's trap with no PID to stop, so hold it until both are set.
    local launch_signal=0 previous_int_trap previous_term_trap
    previous_int_trap=$(trap -p INT || true)
    previous_term_trap=$(trap -p TERM || true)
    trap 'launch_signal=130' INT
    trap 'launch_signal=143' TERM
    {
        # Mark every exit, including a TERM before the scan installs its own
        # traps and an errexit abort.
        trap 'printf "done\n" > "$done_marker"' EXIT
        trap 'exit 143' TERM
        local scan_rc=0
        scan_project_cache_roots "$scan_manifest" || scan_rc=$?
        exit "$scan_rc"
    } < /dev/null > /dev/null 2>&1 &
    _MOLE_PROJECT_CACHE_PREFETCH_PID=$!
    trap - INT TERM
    # eval: restore caller traps captured by $(trap -p)
    [[ -n "$previous_int_trap" ]] && eval "$previous_int_trap"
    [[ -n "$previous_term_trap" ]] && eval "$previous_term_trap"

    if [[ $launch_signal -ge 128 ]]; then
        stop_project_cache_prefetch
        if [[ $launch_signal -eq 130 ]]; then
            kill -INT $$
        else
            kill -TERM $$
        fi
    fi
    return 0
}

# Returns the scan's own status and sets _MOLE_PROJECT_CACHE_PREFETCH_SIGNAL
# when INT or TERM arrives first. wait reads the status bash saved for the
# job, so a reused PID is never polled.
_wait_project_cache_prefetch() {
    _MOLE_PROJECT_CACHE_PREFETCH_SIGNAL=0
    local wait_signal=0 wait_rc=0 previous_int_trap previous_term_trap
    previous_int_trap=$(trap -p INT || true)
    previous_term_trap=$(trap -p TERM || true)
    trap 'wait_signal=130' INT
    trap 'wait_signal=143' TERM
    wait "$_MOLE_PROJECT_CACHE_PREFETCH_PID" 2> /dev/null || wait_rc=$?
    trap - INT TERM
    # eval: restore caller traps captured by $(trap -p)
    [[ -n "$previous_int_trap" ]] && eval "$previous_int_trap"
    [[ -n "$previous_term_trap" ]] && eval "$previous_term_trap"
    _MOLE_PROJECT_CACHE_PREFETCH_SIGNAL=$wait_signal
    return "$wait_rc"
}

stop_project_cache_prefetch() {
    local prefetch_pid="$_MOLE_PROJECT_CACHE_PREFETCH_PID"
    local scan_manifest="$_MOLE_PROJECT_CACHE_PREFETCH_MANIFEST"
    local done_marker="$_MOLE_PROJECT_CACHE_PREFETCH_DONE"
    _MOLE_PROJECT_CACHE_PREFETCH_PID=""
    _MOLE_PROJECT_CACHE_PREFETCH_MANIFEST=""
    _MOLE_PROJECT_CACHE_PREFETCH_DONE=""
    if [[ -n "$prefetch_pid" ]]; then
        if [[ -n "$done_marker" && ! -s "$done_marker" ]]; then
            kill -TERM "$prefetch_pid" 2> /dev/null || true
        fi
        wait "$prefetch_pid" 2> /dev/null || true
    fi
    if [[ -n "$scan_manifest" ]]; then
        rm -f "$scan_manifest" # SAFE: exact scratch file created by create_temp_file
    fi
    if [[ -n "$done_marker" ]]; then
        rm -f "$done_marker" # SAFE: exact scratch file created by create_temp_file
    fi
    return 0
}

# Writes one "<status>\t<matches file>" line per root, then "skipped\t<count>".
scan_project_cache_roots() {
    local scan_manifest="$1"
    local -a scan_roots=()
    local root
    while IFS= read -r root; do
        [[ -n "$root" ]] && scan_roots+=("$root")
    done < <(discover_project_cache_roots)

    if [[ ${#scan_roots[@]} -eq 0 ]]; then
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
        local walkable_rc=0
        project_cache_root_is_walkable "$root" || walkable_rc=$?
        if [[ $walkable_rc -ge 128 ]]; then
            scan_interrupt_status=$walkable_rc
            break
        fi
        if [[ $walkable_rc -ne 0 ]]; then
            debug_log "Project cache root not walkable, skipped: $root"
            failed_scan_count=$((failed_scan_count + 1))
            continue
        fi
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
        # A signal can arrive after launch but before the PID is registered.
        if [[ $scan_interrupt_status -ge 128 ]]; then
            _cleanup_project_cache_scan_workers
            break
        fi
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

    if [[ $scan_interrupt_status -ge 128 ]]; then
        local pending_file
        for pending_file in "${root_matches_files[@]+"${root_matches_files[@]}"}"; do
            rm -f "$pending_file" # SAFE: exact scratch file created by create_temp_file above
        done
        return "$scan_interrupt_status"
    fi

    local scan_index
    {
        for ((scan_index = 0; scan_index < ${#root_matches_files[@]}; scan_index++)); do
            printf '%s\t%s\n' "${scan_statuses[$scan_index]:-1}" "${root_matches_files[$scan_index]}"
        done
        printf 'skipped\t%s\n' "$failed_scan_count"
    } > "$scan_manifest"
}

collect_project_cache_scans() {
    local scan_manifest="$1"
    local -a root_matches_files=() scan_statuses=()
    local failed_scan_count=0 manifest_status manifest_value
    while IFS=$'\t' read -r manifest_status manifest_value; do
        if [[ "$manifest_status" == "skipped" ]]; then
            failed_scan_count="$manifest_value"
            continue
        fi
        scan_statuses+=("$manifest_status")
        root_matches_files+=("$manifest_value")
    done < "$scan_manifest"
    [[ "$failed_scan_count" =~ ^[0-9]+$ ]] || failed_scan_count=0

    local root_matches_file
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
        stop_section_spinner
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
