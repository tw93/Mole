#!/bin/bash
# Mole - Clean command.
# Runs cleanup modules with optional sudo.
# Supports dry-run and whitelist.

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

source "$SCRIPT_DIR/../lib/core/sudo.sh"
source "$SCRIPT_DIR/../lib/clean/brew.sh"
source "$SCRIPT_DIR/../lib/clean/caches.sh"
source "$SCRIPT_DIR/../lib/clean/apps.sh"
source "$SCRIPT_DIR/../lib/clean/dev.sh"
source "$SCRIPT_DIR/../lib/clean/app_caches.sh"
source "$SCRIPT_DIR/../lib/clean/system.sh"
source "$SCRIPT_DIR/../lib/clean/user.sh"

SYSTEM_CLEAN=false
DRY_RUN=false
JSON_OUTPUT=false
PROTECT_FINDER_METADATA=false
IS_M_SERIES=$([[ "$(uname -m)" == "arm64" ]] && echo "true" || echo "false")

EXPORT_LIST_FILE="$HOME/.config/mole/clean-list.txt"
CURRENT_SECTION=""
readonly PROTECTED_SW_DOMAINS=(
    "capcut.com"
    "photopea.com"
    "pixlr.com"
)

# JSON data structures
declare -a JSON_CLEANUP_ITEMS=()
JSON_START_TIME=$(date +%s)

declare -a WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()
if [[ -f "$HOME/.config/mole/whitelist" ]]; then
    while IFS= read -r line; do
        # shellcheck disable=SC2295
        line="${line#"${line%%[![:space:]]*}"}"
        # shellcheck disable=SC2295
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        [[ "$line" == ~* ]] && line="${line/#~/$HOME}"
        line="${line//\$HOME/$HOME}"
        line="${line//\$\{HOME\}/$HOME}"
        if [[ "$line" =~ \.\. ]]; then
            WHITELIST_WARNINGS+=("Path traversal not allowed: $line")
            continue
        fi

        if [[ "$line" != "$FINDER_METADATA_SENTINEL" ]]; then
            if [[ ! "$line" =~ ^[a-zA-Z0-9/_.@\ *-]+$ ]]; then
                WHITELIST_WARNINGS+=("Invalid path format: $line")
                continue
            fi

            if [[ "$line" != /* ]]; then
                WHITELIST_WARNINGS+=("Must be absolute path: $line")
                continue
            fi
        fi

        if [[ "$line" =~ // ]]; then
            WHITELIST_WARNINGS+=("Consecutive slashes: $line")
            continue
        fi

        case "$line" in
            / | /System | /System/* | /bin | /bin/* | /sbin | /sbin/* | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | /etc | /etc/* | /var/db | /var/db/*)
                WHITELIST_WARNINGS+=("Protected system path: $line")
                continue
                ;;
        esac

        duplicate="false"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$line" == "$existing" ]]; then
                    duplicate="true"
                    break
                fi
            done
        fi
        [[ "$duplicate" == "true" ]] && continue
        WHITELIST_PATTERNS+=("$line")
    done < "$HOME/.config/mole/whitelist"
else
    WHITELIST_PATTERNS=("${DEFAULT_WHITELIST_PATTERNS[@]}")
fi

# Expand whitelist patterns once to avoid repeated tilde expansion in hot loops.
expand_whitelist_patterns() {
    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local -a EXPANDED_PATTERNS
        EXPANDED_PATTERNS=()
        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local expanded="${pattern/#\~/$HOME}"
            EXPANDED_PATTERNS+=("$expanded")
        done
        WHITELIST_PATTERNS=("${EXPANDED_PATTERNS[@]}")
    fi
}
expand_whitelist_patterns

if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
    for entry in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$entry" == "$FINDER_METADATA_SENTINEL" ]]; then
            PROTECT_FINDER_METADATA=true
            break
        fi
    done
fi

# Section tracking and summary counters.
total_items=0
TRACK_SECTION=0
SECTION_ACTIVITY=0
files_cleaned=0
total_size_cleaned=0
whitelist_skipped_count=0

# shellcheck disable=SC2329
note_activity() {
    if [[ "${TRACK_SECTION:-0}" == "1" ]]; then
        SECTION_ACTIVITY=1
    fi
}

CLEANUP_DONE=false
# shellcheck disable=SC2329
cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    stop_inline_spinner 2> /dev/null || true

    if [[ -t 1 ]]; then
        printf "\r\033[K" >&2 || true
    fi

    cleanup_temp_files

    stop_sudo_session

    show_cursor
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    CURRENT_SECTION="$1"
    
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
        echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
    fi

    if [[ -t 1 && "$JSON_OUTPUT" != "true" ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Preparing..."
    fi

    if [[ "$DRY_RUN" == "true" && "$JSON_OUTPUT" != "true" ]]; then
        ensure_user_file "$EXPORT_LIST_FILE"
        echo "" >> "$EXPORT_LIST_FILE"
        echo "=== $1 ===" >> "$EXPORT_LIST_FILE"
    fi
}

end_section() {
    stop_section_spinner

    if [[ "$JSON_OUTPUT" != "true" && "${TRACK_SECTION:-0}" == "1" && "${SECTION_ACTIVITY:-0}" == "0" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to clean"
    fi
    TRACK_SECTION=0
}

# JSON helper functions
json_escape() {
    local string="$1"
    # Escape backslashes, quotes, and control characters
    string="${string//\\/\\\\}"
    string="${string//\"/\\\"}"
    string="${string//$'\t'/\\t}"
    string="${string//$'\n'/\\n}"
    string="${string//$'\r'/\\r}"
    echo -n "$string"
}

json_array() {
    local -a items=("$@")
    local result="["
    local first=true
    
    for item in "${items[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result+=","
        fi
        result+="\"$(json_escape "$item")\""
    done
    result+="]"
    echo -n "$result"
}

add_json_item() {
    local description="$1"
    local size_kb="$2"
    local count="$3"
    local category="$4"
    local paths="$5"
    local status="$6"
    
    local escaped_desc=$(json_escape "$description")
    local escaped_category=$(json_escape "$category")
    local size_human=$(bytes_to_human "$((size_kb * 1024))")
    local escaped_size_human=$(json_escape "$size_human")
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    
    JSON_CLEANUP_ITEMS+=("$(cat <<EOF
    {
      "description": "$escaped_desc",
      "size_kb": $size_kb,
      "size_human": "$escaped_size_human",
      "count": $count,
      "category": "$escaped_category",
      "paths": $paths,
      "status": "$status",
      "timestamp": "$timestamp"
    }
EOF
    )")
}

generate_json_output() {
    local end_time=$(date +%s)
    local duration=$((end_time - JSON_START_TIME))
    
    local freed_gb=$(echo "$total_size_cleaned" | awk '{printf "%.2f", $1/1024/1024}')
    local size_human=$(bytes_to_human "$((total_size_cleaned * 1024))")
    local escaped_size_human=$(json_escape "$size_human")
    local free_space_before=$(get_free_space)
    local escaped_free_space_before=$(json_escape "$free_space_before")
    local free_space_after=$(get_free_space)
    local escaped_free_space_after=$(json_escape "$free_space_after")
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    
    local mode="execution"
    [[ "$DRY_RUN" == "true" ]] && mode="dry_run"
    
    local system_cleanup="false"
    [[ "$SYSTEM_CLEAN" == "true" ]] && system_cleanup="true"
    
    # Generate whitelist patterns array
    local whitelist_array="["
    local first=true
    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            whitelist_array+=","
        fi
        whitelist_array+="\"$(json_escape "$pattern")\""
    done
    whitelist_array+="]"
    
    # Generate cleanup items array
    local items_array="["
    first=true
    for item in "${JSON_CLEANUP_ITEMS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            items_array+=","
        fi
        items_array+="$item"
    done
    items_array+="]"
    
    cat <<EOF
{
  "command": "clean",
  "mode": "$mode",
  "timestamp": "$timestamp",
  "duration_seconds": $duration,
  "summary": {
    "total_size_kb": $total_size_cleaned,
    "total_size_gb": $freed_gb,
    "total_size_human": "$escaped_size_human",
    "items_cleaned": $files_cleaned,
    "categories_cleaned": $total_items,
    "system_cleanup_performed": $system_cleanup,
    "free_space_before": "$escaped_free_space_before",
    "free_space_after": "$escaped_free_space_after"
  },
  "whitelist": {
    "enabled": true,
    "patterns_count": ${#WHITELIST_PATTERNS[@]},
    "patterns": $whitelist_array
  },
  "cleanup_items": $items_array
}
EOF
}

# shellcheck disable=SC2329
normalize_paths_for_cleanup() {
    local -a input_paths=("$@")
    local -a unique_paths=()

    for path in "${input_paths[@]}"; do
        local normalized="${path%/}"
        [[ -z "$normalized" ]] && normalized="$path"
        local found=false
        if [[ ${#unique_paths[@]} -gt 0 ]]; then
            for existing in "${unique_paths[@]}"; do
                if [[ "$existing" == "$normalized" ]]; then
                    found=true
                    break
                fi
            done
        fi
        [[ "$found" == "true" ]] || unique_paths+=("$normalized")
    done

    local sorted_paths
    if [[ ${#unique_paths[@]} -gt 0 ]]; then
        sorted_paths=$(printf '%s\n' "${unique_paths[@]}" | awk '{print length "|" $0}' | LC_ALL=C sort -n | cut -d'|' -f2-)
    else
        sorted_paths=""
    fi

    local -a result_paths=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local is_child=false
        if [[ ${#result_paths[@]} -gt 0 ]]; then
            for kept in "${result_paths[@]}"; do
                if [[ "$path" == "$kept" || "$path" == "$kept"/* ]]; then
                    is_child=true
                    break
                fi
            done
        fi
        [[ "$is_child" == "true" ]] || result_paths+=("$path")
    done <<< "$sorted_paths"

    if [[ ${#result_paths[@]} -gt 0 ]]; then
        printf '%s\n' "${result_paths[@]}"
    fi
}

# shellcheck disable=SC2329
get_cleanup_path_size_kb() {
    local path="$1"

    if [[ -f "$path" && ! -L "$path" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local bytes
            bytes=$(stat -f%z "$path" 2> /dev/null || echo "0")
            if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
                echo $(((bytes + 1023) / 1024))
                return 0
            fi
        fi
    fi

    if [[ -L "$path" ]]; then
        if command -v stat > /dev/null 2>&1; then
            local bytes
            bytes=$(stat -f%z "$path" 2> /dev/null || echo "0")
            if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
                echo $(((bytes + 1023) / 1024))
            else
                echo 0
            fi
            return 0
        fi
    fi

    get_path_size_kb "$path"
}

# Classification helper for cleanup risk levels
# shellcheck disable=SC2329
classify_cleanup_risk() {
    local description="$1"
    local path="${2:-}"

    # HIGH RISK: System files, preference files, require sudo
    if [[ "$description" =~ [Ss]ystem || "$description" =~ [Ss]udo || "$path" =~ ^/System || "$path" =~ ^/Library ]]; then
        echo "HIGH|System files or requires admin access"
        return
    fi

    # HIGH RISK: Preference files that might affect app functionality
    if [[ "$description" =~ [Pp]reference || "$path" =~ /Preferences/ ]]; then
        echo "HIGH|Preference files may affect app settings"
        return
    fi

    # MEDIUM RISK: Installers, large files, app bundles
    if [[ "$description" =~ [Ii]nstaller || "$description" =~ [Aa]pp.*[Bb]undle || "$description" =~ [Ll]arge ]]; then
        echo "MEDIUM|Installer packages or app data"
        return
    fi

    # MEDIUM RISK: Old backups, downloads
    if [[ "$description" =~ [Bb]ackup || "$description" =~ [Dd]ownload || "$description" =~ [Oo]rphan ]]; then
        echo "MEDIUM|Backup or downloaded files"
        return
    fi

    # LOW RISK: Caches, logs, temporary files (automatically regenerated)
    if [[ "$description" =~ [Cc]ache || "$description" =~ [Ll]og || "$description" =~ [Tt]emp || "$description" =~ [Tt]humbnail ]]; then
        echo "LOW|Cache/log files, automatically regenerated"
        return
    fi

    # DEFAULT: MEDIUM
    echo "MEDIUM|User data files"
}

# shellcheck disable=SC2329
safe_clean() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    # Always stop spinner before outputting results
    stop_section_spinner

    local description
    local -a targets

    if [[ $# -eq 1 ]]; then
        description="$1"
        targets=("$1")
    else
        description="${*: -1}"
        targets=("${@:1:$#-1}")
    fi

    local -a valid_targets=()
    for target in "${targets[@]}"; do
        # Optimization: If target is a glob literal and parent dir missing, skip it.
        if [[ "$target" == *"*"* && ! -e "$target" ]]; then
            local base_path="${target%%\**}"
            local parent_dir
            if [[ "$base_path" == */ ]]; then
                parent_dir="${base_path%/}"
            else
                parent_dir=$(dirname "$base_path")
            fi

            if [[ ! -d "$parent_dir" ]]; then
                # debug_log "Skipping nonexistent parent: $parent_dir for $target"
                continue
            fi
        fi
        valid_targets+=("$target")
    done

    if [[ ${#valid_targets[@]} -gt 0 ]]; then
        targets=("${valid_targets[@]}")
    else
        targets=()
    fi
    if [[ ${#targets[@]} -eq 0 ]]; then
        return 0
    fi

    local removed_any=0
    local total_size_kb=0
    local total_count=0
    local skipped_count=0
    local removal_failed_count=0
    local permission_start=${MOLE_PERMISSION_DENIED_COUNT:-0}

    local show_scan_feedback=false
    if [[ ${#targets[@]} -gt 20 && -t 1 && "$JSON_OUTPUT" != "true" ]]; then
        show_scan_feedback=true
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning ${#targets[@]} items..."
    fi

    local -a existing_paths=()
    local -a json_paths=()
    for path in "${targets[@]}"; do
        local skip=false

        if should_protect_path "$path"; then
            skip=true
            ((skipped_count++))
        fi

        [[ "$skip" == "true" ]] && continue

        if is_path_whitelisted "$path"; then
            skip=true
            ((skipped_count++))
        fi
        [[ "$skip" == "true" ]] && continue
        if [[ -e "$path" ]]; then
            existing_paths+=("$path")
            json_paths+=("$path")
        fi
    done

    if [[ "$show_scan_feedback" == "true" ]]; then
        stop_section_spinner
    fi

    debug_log "Cleaning: $description (${#existing_paths[@]} items)"

    # Enhanced debug output with risk level and details
    if [[ "${MO_DEBUG:-}" == "1" && ${#existing_paths[@]} -gt 0 ]]; then
        # Determine risk level for this cleanup operation
        local risk_info
        risk_info=$(classify_cleanup_risk "$description" "${existing_paths[0]}")
        local risk_level="${risk_info%%|*}"
        local risk_reason="${risk_info#*|}"

        debug_operation_start "$description"
        debug_risk_level "$risk_level" "$risk_reason"
        debug_operation_detail "Item count" "${#existing_paths[@]}"

        # Log sample of files (first 10) with details
        if [[ ${#existing_paths[@]} -le 10 ]]; then
            debug_operation_detail "Files to be removed" "All files listed below"
        else
            debug_operation_detail "Files to be removed" "Showing first 10 of ${#existing_paths[@]} files"
        fi
    fi

    if [[ $skipped_count -gt 0 ]]; then
        ((whitelist_skipped_count += skipped_count))
    fi

    if [[ ${#existing_paths[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ ${#existing_paths[@]} -gt 1 ]]; then
        local -a normalized_paths=()
        while IFS= read -r path; do
            [[ -n "$path" ]] && normalized_paths+=("$path")
        done < <(normalize_paths_for_cleanup "${existing_paths[@]}")

        if [[ ${#normalized_paths[@]} -gt 0 ]]; then
            existing_paths=("${normalized_paths[@]}")
        else
            existing_paths=()
        fi
    fi

    local show_spinner=false
    if [[ ${#existing_paths[@]} -gt 10 && "$JSON_OUTPUT" != "true" ]]; then
        show_spinner=true
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning items..."; fi
    fi

    # For larger batches, precompute sizes in parallel for better UX/stat accuracy.
    if [[ ${#existing_paths[@]} -gt 3 ]]; then
        local temp_dir
        temp_dir=$(create_temp_dir)

        local dir_count=0
        local sample_size=$((${#existing_paths[@]} > 20 ? 20 : ${#existing_paths[@]}))
        local max_sample=$((${#existing_paths[@]} * 20 / 100))
        [[ $max_sample -gt $sample_size ]] && sample_size=$max_sample

        for ((i = 0; i < sample_size && i < ${#existing_paths[@]}; i++)); do
            [[ -d "${existing_paths[i]}" ]] && ((dir_count++))
        done

        # Heuristic: mostly files -> sequential stat is faster than subshells.
        if [[ $dir_count -lt 5 && ${#existing_paths[@]} -gt 20 ]]; then
            if [[ -t 1 && "$show_spinner" == "false" && "$JSON_OUTPUT" != "true" ]]; then
                MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning items..."
                show_spinner=true
            fi

            local idx=0
            local last_progress_update
            last_progress_update=$(get_epoch_seconds)
            for path in "${existing_paths[@]}"; do
                local size
                size=$(get_cleanup_path_size_kb "$path")
                [[ ! "$size" =~ ^[0-9]+$ ]] && size=0

                if [[ "$size" -gt 0 ]]; then
                    echo "$size 1" > "$temp_dir/result_${idx}"
                else
                    echo "0 0" > "$temp_dir/result_${idx}"
                fi

                ((idx++))
                if [[ $((idx % 20)) -eq 0 && "$show_spinner" == "true" && -t 1 ]]; then
                    update_progress_if_needed "$idx" "${#existing_paths[@]}" last_progress_update 1 || true
                    last_progress_update=$(get_epoch_seconds)
                fi
            done
        else
            local -a pids=()
            local idx=0
            local completed=0
            local last_progress_update
            last_progress_update=$(get_epoch_seconds)
            local total_paths=${#existing_paths[@]}

            if [[ ${#existing_paths[@]} -gt 0 ]]; then
                for path in "${existing_paths[@]}"; do
                    (
                        local size
                        size=$(get_cleanup_path_size_kb "$path")
                        [[ ! "$size" =~ ^[0-9]+$ ]] && size=0
                        local tmp_file="$temp_dir/result_${idx}.$$"
                        if [[ "$size" -gt 0 ]]; then
                            echo "$size 1" > "$tmp_file"
                        else
                            echo "0 0" > "$tmp_file"
                        fi
                        mv "$tmp_file" "$temp_dir/result_${idx}" 2> /dev/null || true
                    ) &
                    pids+=($!)
                    ((idx++))

                    if ((${#pids[@]} >= MOLE_MAX_PARALLEL_JOBS)); then
                        wait "${pids[0]}" 2> /dev/null || true
                        pids=("${pids[@]:1}")
                        ((completed++))

                        if [[ "$show_spinner" == "true" && -t 1 && "$JSON_OUTPUT" != "true" ]]; then
                            update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                        fi
                    fi
                done
            fi

            if [[ ${#pids[@]} -gt 0 ]]; then
                for pid in "${pids[@]}"; do
                    wait "$pid" 2> /dev/null || true
                    ((completed++))

                    if [[ "$show_spinner" == "true" && -t 1 && "$JSON_OUTPUT" != "true" ]]; then
                        update_progress_if_needed "$completed" "$total_paths" last_progress_update 2 || true
                    fi
                done
            fi
        fi

        # Read results back in original order.
        idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local result_file="$temp_dir/result_${idx}"
                if [[ -f "$result_file" ]]; then
                    read -r size count < "$result_file" 2> /dev/null || true
                    local removed=0
                    if [[ "$DRY_RUN" != "true" ]]; then
                        if [[ -L "$path" ]]; then
                            rm "$path" 2> /dev/null && removed=1
                        else
                            if safe_remove "$path" true; then
                                removed=1
                            fi
                        fi
                    else
                        removed=1
                    fi

                    if [[ $removed -eq 1 ]]; then
                        if [[ "$size" -gt 0 ]]; then
                            ((total_size_kb += size))
                        fi
                        ((total_count += 1))
                        removed_any=1
                    else
                        if [[ -e "$path" && "$DRY_RUN" != "true" ]]; then
                            ((removal_failed_count++))
                        fi
                    fi
                fi
                ((idx++))
            done
        fi

    else
        local idx=0
        if [[ ${#existing_paths[@]} -gt 0 ]]; then
            for path in "${existing_paths[@]}"; do
                local size_kb
                size_kb=$(get_cleanup_path_size_kb "$path")
                [[ ! "$size_kb" =~ ^[0-9]+$ ]] && size_kb=0

                local removed=0
                if [[ "$DRY_RUN" != "true" ]]; then
                    if [[ -L "$path" ]]; then
                        rm "$path" 2> /dev/null && removed=1
                    else
                        if safe_remove "$path" true; then
                            removed=1
                        fi
                    fi
                else
                    removed=1
                fi

                if [[ $removed -eq 1 ]]; then
                    if [[ "$size_kb" -gt 0 ]]; then
                        ((total_size_kb += size_kb))
                    fi
                    ((total_count += 1))
                    removed_any=1
                else
                    if [[ -e "$path" && "$DRY_RUN" != "true" ]]; then
                        ((removal_failed_count++))
                    fi
                fi
                ((idx++))
            done
        fi
    fi

    if [[ "$show_spinner" == "true" ]]; then
        stop_section_spinner
    fi

    local permission_end=${MOLE_PERMISSION_DENIED_COUNT:-0}
    # Track permission failures in debug output (avoid noisy user warnings).
    if [[ $permission_end -gt $permission_start && $removed_any -eq 0 ]]; then
        debug_log "Permission denied while cleaning: $description"
    fi
    if [[ $removal_failed_count -gt 0 && "$DRY_RUN" != "true" ]]; then
        debug_log "Skipped $removal_failed_count items (permission denied or in use) for: $description"
    fi

    if [[ $removed_any -eq 1 ]]; then
        local size_human=$(bytes_to_human "$((total_size_kb * 1024))")

        local label="$description"
        if [[ ${#targets[@]} -gt 1 ]]; then
            label+=" ${#targets[@]} items"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$JSON_OUTPUT" != "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label ${YELLOW}($size_human dry)${NC}"
            fi

            if [[ "$JSON_OUTPUT" != "true" ]]; then
                local paths_temp=$(create_temp_file)

                idx=0
                if [[ ${#existing_paths[@]} -gt 0 ]]; then
                    for path in "${existing_paths[@]}"; do
                        local size=0

                        if [[ -n "${temp_dir:-}" && -f "$temp_dir/result_${idx}" ]]; then
                            read -r size count < "$temp_dir/result_${idx}" 2> /dev/null || true
                        else
                            size=$(get_cleanup_path_size_kb "$path" 2> /dev/null || echo "0")
                        fi

                        [[ "$size" == "0" || -z "$size" ]] && {
                            ((idx++))
                            continue
                        }

                        echo "$(dirname "$path")|$size|$path" >> "$paths_temp"
                        ((idx++))
                    done
                fi

                # Group dry-run paths by parent for a compact export list.
                if [[ -f "$paths_temp" && -s "$paths_temp" ]]; then
                    sort -t'|' -k1,1 "$paths_temp" | awk -F'|' '
                    {
                        parent = $1
                        size = $2
                        path = $3

                        parent_size[parent] += size
                        if (parent_count[parent] == 0) {
                            parent_first[parent] = path
                        }
                        parent_count[parent]++
                    }
                    END {
                        for (parent in parent_size) {
                            if (parent_count[parent] > 1) {
                                printf "%s|%d|%d\n", parent, parent_size[parent], parent_count[parent]
                            } else {
                                printf "%s|%d|1\n", parent_first[parent], parent_size[parent]
                            }
                        }
                    }
                    ' | while IFS='|' read -r display_path total_size child_count; do
                        local size_human=$(bytes_to_human "$((total_size * 1024))")
                        if [[ $child_count -gt 1 ]]; then
                            echo "$display_path  # $size_human ($child_count items)" >> "$EXPORT_LIST_FILE"
                        else
                            echo "$display_path  # $size_human" >> "$EXPORT_LIST_FILE"
                        fi
                    done

                    rm -f "$paths_temp"
                fi
            fi
        else
            if [[ "$JSON_OUTPUT" != "true" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label ${GREEN}($size_human)${NC}"
            fi
        fi
        ((files_cleaned += total_count))
        ((total_size_cleaned += total_size_kb))
        ((total_items++))
        note_activity
        
        # Add to JSON output if enabled
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            local json_paths_array=$(json_array "${json_paths[@]}")
            local status="cleaned"
            [[ "$DRY_RUN" == "true" ]] && status="would_clean"
            add_json_item "$description" "$total_size_kb" "$total_count" "$CURRENT_SECTION" "$json_paths_array" "$status"
        fi
    fi

    return 0
}

start_cleanup() {
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        if [[ -t 1 ]]; then
            printf '\033[2J\033[H'
        fi
        printf '\n'
        echo -e "${PURPLE_BOLD}Clean Your Mac${NC}"
        echo ""

        if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
            echo -e "${GRAY}${ICON_SOLID} Use --dry-run to preview, --whitelist to manage protected paths${NC}"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC} - Preview only, no deletions"
            echo ""
            SYSTEM_CLEAN=false

            ensure_user_file "$EXPORT_LIST_FILE"
            cat > "$EXPORT_LIST_FILE" << EOF
# Mole Cleanup Preview - $(date '+%Y-%m-%d %H:%M:%S')
#
# How to protect files:
# 1. Copy any path below to ~/.config/mole/whitelist
# 2. Run: mo clean --whitelist
#
# Example:
#   /Users/*/Library/Caches/com.example.app
#

EOF
            return
        fi

        if [[ -t 0 ]]; then
            echo -ne "${PURPLE}${ICON_ARROW}${NC} System caches need sudo — ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "

            local choice
            choice=$(read_key)

            # ESC/Q aborts, Space skips, Enter enables system cleanup.
            if [[ "$choice" == "QUIT" ]]; then
                echo -e " ${GRAY}Canceled${NC}"
                exit 0
            fi

            if [[ "$choice" == "SPACE" ]]; then
                echo -e " ${GRAY}Skipped${NC}"
                echo ""
                SYSTEM_CLEAN=false
            elif [[ "$choice" == "ENTER" ]]; then
                printf "\r\033[K" # Clear the prompt line
                if ensure_sudo_session "System cleanup requires admin access"; then
                    SYSTEM_CLEAN=true
                    echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                    echo ""
                else
                    SYSTEM_CLEAN=false
                    echo ""
                    echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
                fi
            else
                SYSTEM_CLEAN=false
                echo -e " ${GRAY}Skipped${NC}"
                echo ""
            fi
        else
            SYSTEM_CLEAN=false
            echo ""
            echo "Running in non-interactive mode"
            echo "  ${ICON_LIST} System-level cleanup skipped (requires interaction)"
            echo "  ${ICON_LIST} User-level cleanup will proceed automatically"
            echo ""
        fi
    else
        # JSON mode: non-interactive, skip system cleanup
        SYSTEM_CLEAN=false
    fi
}

perform_cleanup() {
    # Test mode skips expensive scans and returns minimal output.
    local test_mode_enabled=false
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        test_mode_enabled=true
        if [[ "$DRY_RUN" == "true" && "$JSON_OUTPUT" != "true" ]]; then
            echo -e "${YELLOW}Dry Run Mode${NC} - Preview only, no deletions"
            echo ""
        fi
        if [[ "$JSON_OUTPUT" != "true" ]]; then
            echo -e "${GREEN}${ICON_LIST}${NC} User app cache"
            if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
                local -a expanded_defaults
                expanded_defaults=()
                for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                    expanded_defaults+=("${default/#\~/$HOME}")
                done
                local has_custom=false
                for pattern in "${WHITELIST_PATTERNS[@]}"; do
                    local is_default=false
                    local normalized_pattern="${pattern%/}"
                    for default in "${expanded_defaults[@]}"; do
                        local normalized_default="${default%/}"
                        [[ "$normalized_pattern" == "$normalized_default" ]] && is_default=true && break
                    done
                    [[ "$is_default" == "false" ]] && has_custom=true && break
                done
                [[ "$has_custom" == "true" ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} Protected items found"
            fi
            if [[ "$DRY_RUN" == "true" ]]; then
                echo ""
                echo "Potential space: 0.00GB"
            fi
        fi
        total_items=1
        files_cleaned=0
        total_size_cleaned=0
    fi

    if [[ "$test_mode_enabled" == "false" && "$JSON_OUTPUT" != "true" ]]; then
        echo -e "${BLUE}${ICON_ADMIN}${NC} $(detect_architecture) | Free space: $(get_free_space)"
    fi

    if [[ "$test_mode_enabled" == "true" && "$JSON_OUTPUT" != "true" ]]; then
        local summary_heading="Test mode complete"
        local -a summary_details
        summary_details=()
        summary_details+=("Test mode - no actual cleanup performed")
        print_summary_block "$summary_heading" "${summary_details[@]}"
        printf '\n'
        return 0
    fi

    # Pre-check TCC permissions to avoid mid-run prompts.
    check_tcc_permissions

    if [[ "$JSON_OUTPUT" != "true" && ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local predefined_count=0
        local custom_count=0

        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            local is_predefined=false
            for default in "${DEFAULT_WHITELIST_PATTERNS[@]}"; do
                local expanded_default="${default/#\~/$HOME}"
                if [[ "$pattern" == "$expanded_default" ]]; then
                    is_predefined=true
                    break
                fi
            done

            if [[ "$is_predefined" == "true" ]]; then
                ((predefined_count++))
            else
                ((custom_count++))
            fi
        done

        if [[ $custom_count -gt 0 || $predefined_count -gt 0 ]]; then
            local summary=""
            [[ $predefined_count -gt 0 ]] && summary+="$predefined_count core"
            [[ $custom_count -gt 0 && $predefined_count -gt 0 ]] && summary+=" + "
            [[ $custom_count -gt 0 ]] && summary+="$custom_count custom"
            summary+=" patterns active"

            echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $summary"

            if [[ "$DRY_RUN" == "true" ]]; then
                for pattern in "${WHITELIST_PATTERNS[@]}"; do
                    [[ "$pattern" == "$FINDER_METADATA_SENTINEL" ]] && continue
                    echo -e "  ${GRAY}→ $pattern${NC}"
                done
            fi
        fi
    fi

    if [[ -t 1 && "$DRY_RUN" != "true" && "$JSON_OUTPUT" != "true" ]]; then
        local fda_status=0
        has_full_disk_access
        fda_status=$?
        if [[ $fda_status -eq 1 ]]; then
            echo ""
            echo -e "${YELLOW}${ICON_WARNING}${NC} ${GRAY}Tip: Grant Full Disk Access to your terminal in System Settings for best results${NC}"
        fi
    fi

    total_items=0
    files_cleaned=0
    total_size_cleaned=0

    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1

    # Allow per-section failures without aborting the full run.
    set +e

    # ===== 1. Deep system cleanup (if admin) =====
    if [[ "$SYSTEM_CLEAN" == "true" ]]; then
        start_section "Deep system"
        clean_deep_system
        clean_local_snapshots
        end_section
    fi

    if [[ "$JSON_OUTPUT" != "true" && ${#WHITELIST_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        for warning in "${WHITELIST_WARNINGS[@]}"; do
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Whitelist: $warning"
        done
    fi

    start_section "User essentials"
    clean_user_essentials
    scan_external_volumes
    end_section

    start_section "Finder metadata"
    clean_finder_metadata
    end_section

    # ===== 3. macOS system caches =====
    start_section "macOS system caches"
    clean_macos_system_caches
    clean_recent_items
    clean_mail_downloads
    end_section

    # ===== 4. Sandboxed app caches =====
    start_section "Sandboxed app caches"
    clean_sandboxed_app_caches
    end_section

    # ===== 5. Browsers =====
    start_section "Browsers"
    clean_browsers
    end_section

    # ===== 6. Cloud storage =====
    start_section "Cloud storage"
    clean_cloud_storage
    end_section

    # ===== 7. Office applications =====
    start_section "Office applications"
    clean_office_applications
    end_section

    # ===== 8. Developer tools =====
    start_section "Developer tools"
    clean_developer_tools
    end_section

    # ===== 9. Development applications =====
    start_section "Development applications"
    clean_user_gui_applications
    end_section

    # ===== 10. Virtualization tools =====
    start_section "Virtual machine tools"
    clean_virtualization_tools
    end_section

    # ===== 11. Application Support logs and caches cleanup =====
    start_section "Application Support"
    clean_application_support_logs
    end_section

    # ===== 12. Orphaned app data cleanup (60+ days inactive, skip protected vendors) =====
    start_section "Uninstalled app data"
    clean_orphaned_app_data
    end_section

    # ===== 13. Apple Silicon optimizations =====
    clean_apple_silicon_caches

    # ===== 14. iOS device backups =====
    start_section "iOS device backups"
    check_ios_device_backups
    end_section

    # ===== 15. Time Machine incomplete backups =====
    start_section "Time Machine incomplete backups"
    clean_time_machine_failed_backups
    end_section

    # ===== Final summary =====
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        echo ""
    fi

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        # Generate JSON output
        local json_output
        json_output=$(generate_json_output)
        
        # Save to file
        local json_file="$HOME/.config/mole/clean-output-$(date +%Y%m%d-%H%M%S).json"
        ensure_user_file "$json_file"
        echo "$json_output" > "$json_file"
        
        # Also output to stdout
        echo "$json_output"
    else
        local summary_heading=""
        local summary_status="success"
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_heading="Dry run complete - no changes made"
        else
            summary_heading="Cleanup complete"
        fi

        local -a summary_details=()

        if [[ $total_size_cleaned -gt 0 ]]; then
            local freed_gb
            freed_gb=$(echo "$total_size_cleaned" | awk '{printf "%.2f", $1/1024/1024}')

            if [[ "$DRY_RUN" == "true" ]]; then
                local stats="Potential space: ${GREEN}${freed_gb}GB${NC}"
                [[ $files_cleaned -gt 0 ]] && stats+=" | Items: $files_cleaned"
                [[ $total_items -gt 0 ]] && stats+=" | Categories: $total_items"
                summary_details+=("$stats")

                {
                    echo ""
                    echo "# ============================================"
                    echo "# Summary"
                    echo "# ============================================"
                    echo "# Potential cleanup: ${freed_gb}GB"
                    echo "# Items: $files_cleaned"
                    echo "# Categories: $total_items"
                } >> "$EXPORT_LIST_FILE"

                summary_details+=("Detailed file list: ${GRAY}$EXPORT_LIST_FILE${NC}")
                summary_details+=("Use ${GRAY}mo clean --whitelist${NC} to add protection rules")
            else
                local summary_line="Space freed: ${GREEN}${freed_gb}GB${NC}"

                if [[ $files_cleaned -gt 0 && $total_items -gt 0 ]]; then
                    summary_line+=" | Items cleaned: $files_cleaned | Categories: $total_items"
                elif [[ $files_cleaned -gt 0 ]]; then
                    summary_line+=" | Items cleaned: $files_cleaned"
                elif [[ $total_items -gt 0 ]]; then
                    summary_line+=" | Categories: $total_items"
                fi

                summary_details+=("$summary_line")

                if [[ $(echo "$freed_gb" | awk '{print ($1 >= 1) ? 1 : 0}') -eq 1 ]]; then
                    local movies
                    movies=$(echo "$freed_gb" | awk '{printf "%.0f", $1/4.5}')
                    if [[ $movies -gt 0 ]]; then
                        summary_details+=("Equivalent to ~$movies 4K movies of storage.")
                    fi
                fi

                local final_free_space=$(get_free_space)
                summary_details+=("Free space now: $final_free_space")
            fi
        else
            summary_status="info"
            if [[ "$DRY_RUN" == "true" ]]; then
                summary_details+=("No significant reclaimable space detected (system already clean).")
            else
                summary_details+=("System was already clean; no additional space freed.")
            fi
            summary_details+=("Free space now: $(get_free_space)")
        fi

        if [[ $had_errexit -eq 1 ]]; then
            set -e
        fi

        print_summary_block "$summary_heading" "${summary_details[@]}"
        printf '\n'
    fi
}

main() {
    for arg in "$@"; do
        case "$arg" in
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                DRY_RUN=true
                ;;
            "--json")
                JSON_OUTPUT=true
                ;;
            "--whitelist")
                source "$SCRIPT_DIR/../lib/manage/whitelist.sh"
                manage_whitelist "clean"
                exit 0
                ;;
        esac
    done

    start_cleanup
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        hide_cursor
    fi
    perform_cleanup
    if [[ "$JSON_OUTPUT" != "true" ]]; then
        show_cursor
    fi
    exit 0
}

main "$@"
