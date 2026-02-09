#!/bin/bash
# Mole - Uninstall command.
# Interactive app uninstaller.
# Removes app files and leftovers.

set -euo pipefail

# Preserve user's locale for app display name lookup.
readonly MOLE_UNINSTALL_USER_LC_ALL="${LC_ALL:-}"
readonly MOLE_UNINSTALL_USER_LANG="${LANG:-}"

# Fix locale issues on non-English systems.
export LC_ALL=C
export LANG=C

# Load shared helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

# Clean temp files on exit.
trap cleanup_temp_files EXIT INT TERM
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/../lib/ui/app_selector.sh"
source "$SCRIPT_DIR/../lib/uninstall/batch.sh"

# State
selected_apps=()
declare -a apps_data=()
declare -a selection_state=()
total_items=0
files_cleaned=0
total_size_cleaned=0

readonly MOLE_UNINSTALL_META_CACHE_DIR="$HOME/.cache/mole"
readonly MOLE_UNINSTALL_META_CACHE_FILE="$MOLE_UNINSTALL_META_CACHE_DIR/uninstall_app_metadata_v1"
readonly MOLE_UNINSTALL_META_CACHE_LOCK="${MOLE_UNINSTALL_META_CACHE_FILE}.lock"
readonly MOLE_UNINSTALL_META_REFRESH_TTL=604800 # 7 days
readonly MOLE_UNINSTALL_SCAN_SPINNER_DELAY_SEC="0.15"
readonly MOLE_UNINSTALL_INLINE_METADATA_LIMIT=4
readonly MOLE_UNINSTALL_INLINE_MDLS_TIMEOUT_SEC="0.08"

uninstall_relative_time_from_epoch() {
    local value_epoch="${1:-0}"
    local now_epoch="${2:-0}"

    if [[ ! "$value_epoch" =~ ^[0-9]+$ || $value_epoch -le 0 ]]; then
        echo "..."
        return 0
    fi

    local days_ago=$(((now_epoch - value_epoch) / 86400))
    if [[ $days_ago -lt 0 ]]; then
        days_ago=0
    fi

    if [[ $days_ago -eq 0 ]]; then
        echo "Today"
    elif [[ $days_ago -eq 1 ]]; then
        echo "Yesterday"
    elif [[ $days_ago -lt 7 ]]; then
        echo "${days_ago} days ago"
    elif [[ $days_ago -lt 30 ]]; then
        local weeks_ago=$((days_ago / 7))
        [[ $weeks_ago -eq 1 ]] && echo "1 week ago" || echo "${weeks_ago} weeks ago"
    elif [[ $days_ago -lt 365 ]]; then
        local months_ago=$((days_ago / 30))
        [[ $months_ago -eq 1 ]] && echo "1 month ago" || echo "${months_ago} months ago"
    else
        local years_ago=$((days_ago / 365))
        [[ $years_ago -eq 1 ]] && echo "1 year ago" || echo "${years_ago} years ago"
    fi
}

uninstall_resolve_display_name() {
    local app_path="$1"
    local app_name="$2"
    local display_name="$app_name"

    if [[ -f "$app_path/Contents/Info.plist" ]]; then
        local md_display_name
        if [[ -n "$MOLE_UNINSTALL_USER_LC_ALL" ]]; then
            md_display_name=$(run_with_timeout 0.04 env LC_ALL="$MOLE_UNINSTALL_USER_LC_ALL" LANG="$MOLE_UNINSTALL_USER_LANG" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        elif [[ -n "$MOLE_UNINSTALL_USER_LANG" ]]; then
            md_display_name=$(run_with_timeout 0.04 env LANG="$MOLE_UNINSTALL_USER_LANG" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        else
            md_display_name=$(run_with_timeout 0.04 mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        fi

        local bundle_display_name
        bundle_display_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist" 2> /dev/null || echo "")
        local bundle_name
        bundle_name=$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist" 2> /dev/null || echo "")

        if [[ "$md_display_name" == /* ]]; then
            md_display_name=""
        fi
        md_display_name="${md_display_name//|/-}"
        md_display_name="${md_display_name//[$'\t\r\n']/}"

        bundle_display_name="${bundle_display_name//|/-}"
        bundle_display_name="${bundle_display_name//[$'\t\r\n']/}"

        bundle_name="${bundle_name//|/-}"
        bundle_name="${bundle_name//[$'\t\r\n']/}"

        if [[ -n "$md_display_name" && "$md_display_name" != "(null)" && "$md_display_name" != "$app_name" ]]; then
            display_name="$md_display_name"
        elif [[ -n "$bundle_display_name" && "$bundle_display_name" != "(null)" ]]; then
            display_name="$bundle_display_name"
        elif [[ -n "$bundle_name" && "$bundle_name" != "(null)" ]]; then
            display_name="$bundle_name"
        fi
    fi

    if [[ "$display_name" == /* ]]; then
        display_name="$app_name"
    fi
    display_name="${display_name%.app}"
    display_name="${display_name//|/-}"
    display_name="${display_name//[$'\t\r\n']/}"
    echo "$display_name"
}

uninstall_acquire_metadata_lock() {
    local lock_dir="$1"
    local attempts=0

    while ! mkdir "$lock_dir" 2> /dev/null; do
        ((attempts++))
        if [[ $attempts -ge 40 ]]; then
            return 1
        fi

        # Clean stale lock if older than 5 minutes.
        if [[ -d "$lock_dir" ]]; then
            local lock_mtime
            lock_mtime=$(get_file_mtime "$lock_dir")
            # Skip stale detection if mtime lookup failed (returns 0).
            if [[ "$lock_mtime" =~ ^[0-9]+$ && $lock_mtime -gt 0 ]]; then
                local lock_age
                lock_age=$(($(get_epoch_seconds) - lock_mtime))
                if [[ "$lock_age" =~ ^-?[0-9]+$ && $lock_age -gt 300 ]]; then
                    rmdir "$lock_dir" 2> /dev/null || true
                fi
            fi
        fi

        sleep 0.1 2> /dev/null || sleep 1
    done

    return 0
}

uninstall_release_metadata_lock() {
    local lock_dir="$1"
    [[ -d "$lock_dir" ]] && rmdir "$lock_dir" 2> /dev/null || true
}

uninstall_collect_inline_metadata() {
    local app_path="$1"
    local app_mtime="${2:-0}"
    local now_epoch="${3:-0}"

    local size_kb
    size_kb=$(get_path_size_kb "$app_path")
    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

    local last_used_epoch=0
    local metadata_date
    metadata_date=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_TIMEOUT_SEC" mdls -name kMDItemLastUsedDate -raw "$app_path" 2> /dev/null || echo "")
    if [[ "$metadata_date" != "(null)" && -n "$metadata_date" ]]; then
        last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$metadata_date" "+%s" 2> /dev/null || echo "0")
    fi

    # Fallback to app mtime so first scan does not show "...".
    if [[ ! "$last_used_epoch" =~ ^[0-9]+$ || $last_used_epoch -le 0 ]]; then
        if [[ "$app_mtime" =~ ^[0-9]+$ && $app_mtime -gt 0 ]]; then
            last_used_epoch="$app_mtime"
        else
            last_used_epoch=0
        fi
    fi

    printf "%s|%s|%s\n" "$size_kb" "$last_used_epoch" "$now_epoch"
}

start_uninstall_metadata_refresh() {
    local refresh_file="$1"
    [[ ! -s "$refresh_file" ]] && {
        rm -f "$refresh_file" 2> /dev/null || true
        return 0
    }

    (
        _refresh_debug() {
            if [[ "${MO_DEBUG:-}" == "1" ]]; then
                local ts
                ts=$(date "+%Y-%m-%d %H:%M:%S" 2> /dev/null || echo "?")
                echo "[$ts] DEBUG: [metadata-refresh] $*" >> "${HOME}/.config/mole/mole_debug_session.log" 2> /dev/null || true
            fi
        }

        ensure_user_dir "$MOLE_UNINSTALL_META_CACHE_DIR"
        ensure_user_file "$MOLE_UNINSTALL_META_CACHE_FILE"
        if [[ ! -r "$MOLE_UNINSTALL_META_CACHE_FILE" ]]; then
            if ! : > "$MOLE_UNINSTALL_META_CACHE_FILE" 2> /dev/null; then
                _refresh_debug "Cannot create cache file, aborting"
                exit 0
            fi
        fi
        if [[ ! -w "$MOLE_UNINSTALL_META_CACHE_FILE" ]]; then
            _refresh_debug "Cache file not writable, aborting"
            exit 0
        fi

        local updates_file
        updates_file=$(mktemp 2> /dev/null) || {
            _refresh_debug "mktemp failed, aborting"
            exit 0
        }
        local now_epoch
        now_epoch=$(get_epoch_seconds)
        local max_parallel
        max_parallel=$(get_optimal_parallel_jobs "io")
        if [[ ! "$max_parallel" =~ ^[0-9]+$ || $max_parallel -lt 1 ]]; then
            max_parallel=1
        elif [[ $max_parallel -gt 4 ]]; then
            max_parallel=4
        fi
        local -a worker_pids=()
        local worker_idx=0

        while IFS='|' read -r app_path app_mtime bundle_id display_name; do
            [[ -n "$app_path" && -d "$app_path" ]] || continue
            ((worker_idx++))
            local worker_output="${updates_file}.${worker_idx}"

            (
                local last_used_epoch=0
                local metadata_date
                metadata_date=$(run_with_timeout 0.2 mdls -name kMDItemLastUsedDate -raw "$app_path" 2> /dev/null || echo "")
                if [[ "$metadata_date" != "(null)" && -n "$metadata_date" ]]; then
                    last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$metadata_date" "+%s" 2> /dev/null || echo "0")
                fi

                if [[ ! "$last_used_epoch" =~ ^[0-9]+$ || $last_used_epoch -le 0 ]]; then
                    last_used_epoch=0
                fi

                local size_kb
                size_kb=$(get_path_size_kb "$app_path")
                [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

                printf "%s|%s|%s|%s|%s|%s|%s\n" "$app_path" "${app_mtime:-0}" "$size_kb" "${last_used_epoch:-0}" "$now_epoch" "$bundle_id" "$display_name" > "$worker_output"
            ) &
            worker_pids+=($!)

            if ((${#worker_pids[@]} >= max_parallel)); then
                wait "${worker_pids[0]}" 2> /dev/null || true
                worker_pids=("${worker_pids[@]:1}")
            fi
        done < "$refresh_file"

        local worker_pid
        for worker_pid in "${worker_pids[@]}"; do
            wait "$worker_pid" 2> /dev/null || true
        done

        local worker_output
        for worker_output in "${updates_file}".*; do
            [[ -f "$worker_output" ]] || continue
            cat "$worker_output" >> "$updates_file"
            rm -f "$worker_output"
        done

        if [[ ! -s "$updates_file" ]]; then
            rm -f "$updates_file"
            exit 0
        fi

        if ! uninstall_acquire_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"; then
            _refresh_debug "Failed to acquire lock, aborting merge"
            rm -f "$updates_file"
            exit 0
        fi

        local merged_file
        merged_file=$(mktemp 2> /dev/null) || {
            _refresh_debug "mktemp for merge failed, aborting"
            uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
            rm -f "$updates_file"
            exit 0
        }

        awk -F'|' '
            NR == FNR { updates[$1] = $0; next }
            !($1 in updates) { print }
            END {
                for (path in updates) {
                    print updates[path]
                }
            }
        ' "$updates_file" "$MOLE_UNINSTALL_META_CACHE_FILE" > "$merged_file"

        mv "$merged_file" "$MOLE_UNINSTALL_META_CACHE_FILE" 2> /dev/null || {
            cp "$merged_file" "$MOLE_UNINSTALL_META_CACHE_FILE" 2> /dev/null || true
            rm -f "$merged_file"
        }

        uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
        rm -f "$updates_file"
        rm -f "$refresh_file" 2> /dev/null || true
    ) > /dev/null 2>&1 &

}

# Scan applications and collect information.
scan_applications() {
    local temp_file scan_raw_file merged_file refresh_file cache_snapshot_file
    temp_file=$(create_temp_file)
    scan_raw_file="${temp_file}.scan"
    merged_file="${temp_file}.merged"
    refresh_file="${temp_file}.refresh"
    cache_snapshot_file="${temp_file}.cache"
    : > "$scan_raw_file"
    : > "$refresh_file"
    : > "$cache_snapshot_file"

    ensure_user_dir "$MOLE_UNINSTALL_META_CACHE_DIR"
    ensure_user_file "$MOLE_UNINSTALL_META_CACHE_FILE"
    local cache_source="$MOLE_UNINSTALL_META_CACHE_FILE"
    local cache_source_is_temp=false
    if [[ ! -r "$cache_source" ]]; then
        cache_source=$(create_temp_file)
        : > "$cache_source"
        cache_source_is_temp=true
    fi

    # Fast lookup cache for unchanged apps: path+mtime -> bundle_id/display_name.
    local -a cache_paths=()
    local -a cache_mtimes=()
    local -a cache_bundle_ids=()
    local -a cache_display_names=()
    local cache_path cache_mtime _cache_size _cache_epoch _cache_updated cache_bundle cache_display
    while IFS='|' read -r cache_path cache_mtime _cache_size _cache_epoch _cache_updated cache_bundle cache_display; do
        [[ -n "$cache_path" ]] || continue
        cache_paths+=("$cache_path")
        cache_mtimes+=("${cache_mtime:-0}")
        cache_bundle_ids+=("${cache_bundle:-}")
        cache_display_names+=("${cache_display:-}")
    done < "$cache_source"

    lookup_cached_identity() {
        local target_path="$1"
        local target_mtime="$2"
        local idx
        for ((idx = 0; idx < ${#cache_paths[@]}; idx++)); do
            if [[ "${cache_paths[idx]}" == "$target_path" ]]; then
                if [[ "${cache_mtimes[idx]:-0}" == "${target_mtime:-0}" ]]; then
                    echo "${cache_bundle_ids[idx]:-}|${cache_display_names[idx]:-}"
                else
                    echo "|"
                fi
                return 0
            fi
        done
        echo "|"
    }

    # Local spinner_pid for cleanup
    local spinner_pid=""
    local spinner_shown_file="${temp_file}.spinner_shown"
    local previous_int_trap=""
    previous_int_trap=$(trap -p INT || true)

    restore_scan_int_trap() {
        if [[ -n "$previous_int_trap" ]]; then
            eval "$previous_int_trap"
        else
            trap - INT
        fi
    }

    # Trap to handle Ctrl+C during scan
    # shellcheck disable=SC2329  # Function invoked indirectly via trap
    trap_scan_cleanup() {
        if [[ -n "$spinner_pid" ]]; then
            kill -TERM "$spinner_pid" 2> /dev/null || true
            wait "$spinner_pid" 2> /dev/null || true
        fi
        if [[ -f "$spinner_shown_file" ]]; then
            printf "\r\033[K" >&2
        fi
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "${temp_file}.sorted" "${temp_file}.progress" "$spinner_shown_file" 2> /dev/null || true
        exit 130
    }
    trap trap_scan_cleanup INT

    # Pass 1: collect app paths and bundle IDs (no mdls).
    local -a app_data_tuples=()
    local -a app_dirs=(
        "/Applications"
        "$HOME/Applications"
        "/Library/Input Methods"
        "$HOME/Library/Input Methods"
    )
    local vol_app_dir
    local nullglob_was_set=0
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for vol_app_dir in /Volumes/*/Applications; do
        [[ -d "$vol_app_dir" && -r "$vol_app_dir" ]] || continue
        if [[ -d "/Applications" && "$vol_app_dir" -ef "/Applications" ]]; then
            continue
        fi
        if [[ -d "$HOME/Applications" && "$vol_app_dir" -ef "$HOME/Applications" ]]; then
            continue
        fi
        app_dirs+=("$vol_app_dir")
    done
    if [[ $nullglob_was_set -eq 0 ]]; then
        shopt -u nullglob
    fi

    for app_dir in "${app_dirs[@]}"; do
        if [[ ! -d "$app_dir" ]]; then continue; fi

        while IFS= read -r -d '' app_path; do
            if [[ ! -e "$app_path" ]]; then continue; fi

            local app_name
            app_name=$(basename "$app_path" .app)

            # Skip nested apps inside another .app bundle.
            local parent_dir
            parent_dir=$(dirname "$app_path")
            if [[ "$parent_dir" == *".app" || "$parent_dir" == *".app/"* ]]; then
                continue
            fi

            if [[ -L "$app_path" ]]; then
                local link_target
                link_target=$(readlink "$app_path" 2> /dev/null)
                if [[ -n "$link_target" ]]; then
                    local resolved_target="$link_target"
                    if [[ "$link_target" != /* ]]; then
                        local link_dir
                        link_dir=$(dirname "$app_path")
                        resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") 2> /dev/null || echo ""
                    fi
                    case "$resolved_target" in
                        /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/* | /private/etc/*)
                            continue
                            ;;
                    esac
                fi
            fi

            local app_mtime
            app_mtime=$(get_file_mtime "$app_path")

            local cached_identity cached_bundle_id cached_display_name
            cached_identity=$(lookup_cached_identity "$app_path" "$app_mtime")
            IFS='|' read -r cached_bundle_id cached_display_name <<< "$cached_identity"

            # Store tuple for pass 2 (bundle + display resolution, then cache merge).
            app_data_tuples+=("${app_path}|${app_name}|${app_mtime}|${cached_bundle_id}|${cached_display_name}")
        done < <(command find "$app_dir" -name "*.app" -maxdepth 3 -print0 2> /dev/null)
    done

    if [[ ${#app_data_tuples[@]} -eq 0 ]]; then
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "${temp_file}.sorted" "${temp_file}.progress" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        printf "\r\033[K" >&2
        echo "No applications found to uninstall." >&2
        return 1
    fi
    # Pass 2: resolve display names in parallel.
    local app_count=0
    local total_apps=${#app_data_tuples[@]}
    local max_parallel
    max_parallel=$(get_optimal_parallel_jobs "io")
    if [[ $max_parallel -lt 8 ]]; then
        max_parallel=8 # At least 8 for good performance
    elif [[ $max_parallel -gt 32 ]]; then
        max_parallel=32 # Cap at 32 to avoid too many processes
    fi
    local pids=()

    process_app_metadata() {
        local app_data_tuple="$1"
        local output_file="$2"

        IFS='|' read -r app_path app_name app_mtime cached_bundle_id cached_display_name <<< "$app_data_tuple"

        local bundle_id="${cached_bundle_id:-}"
        if [[ -z "$bundle_id" ]]; then
            bundle_id="unknown"
            if [[ -f "$app_path/Contents/Info.plist" ]]; then
                bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2> /dev/null || echo "unknown")
            fi
        fi

        if should_protect_from_uninstall "$bundle_id"; then
            return 0
        fi

        local display_name="${cached_display_name:-}"
        if [[ -z "$display_name" ]]; then
            display_name=$(uninstall_resolve_display_name "$app_path" "$app_name")
        fi

        display_name="${display_name%.app}"
        display_name="${display_name//|/-}"
        display_name="${display_name//[$'\t\r\n']/}"

        echo "${app_path}|${display_name}|${bundle_id}|${app_mtime}" >> "$output_file"
    }

    local progress_file="${temp_file}.progress"
    echo "0" > "$progress_file"

    (
        # shellcheck disable=SC2329  # Function invoked indirectly via trap
        cleanup_spinner() { exit 0; }
        trap cleanup_spinner TERM INT EXIT
        sleep "$MOLE_UNINSTALL_SCAN_SPINNER_DELAY_SEC" 2> /dev/null || sleep 1
        [[ -f "$progress_file" ]] || exit 0
        local spinner_chars="|/-\\"
        local i=0
        : > "$spinner_shown_file"
        while true; do
            local completed=$(cat "$progress_file" 2> /dev/null || echo 0)
            local c="${spinner_chars:$((i % 4)):1}"
            printf "\r\033[K%s Scanning applications... %d/%d" "$c" "$completed" "$total_apps" >&2
            ((i++))
            sleep 0.1 2> /dev/null || sleep 1
        done
    ) &
    spinner_pid=$!

    for app_data_tuple in "${app_data_tuples[@]}"; do
        ((app_count++))
        process_app_metadata "$app_data_tuple" "$scan_raw_file" &
        pids+=($!)
        echo "$app_count" > "$progress_file"

        if ((${#pids[@]} >= max_parallel)); then
            wait "${pids[0]}" 2> /dev/null
            pids=("${pids[@]:1}")
        fi
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2> /dev/null
    done

    if [[ -n "$spinner_pid" ]]; then
        kill -TERM "$spinner_pid" 2> /dev/null || true
        wait "$spinner_pid" 2> /dev/null || true
    fi
    if [[ -f "$spinner_shown_file" ]]; then
        echo -ne "\r\033[K" >&2
    fi
    rm -f "$progress_file" "$spinner_shown_file"

    if [[ ! -s "$scan_raw_file" ]]; then
        echo "No applications found to uninstall" >&2
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "${temp_file}.sorted" "${temp_file}.progress" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    fi

    if [[ $total_apps -gt 50 ]]; then
        printf "\rProcessing %d applications...    " "$total_apps" >&2
    fi

    awk -F'|' '
        NR == FNR {
            cache_mtime[$1] = $2
            cache_size[$1] = $3
            cache_epoch[$1] = $4
            cache_updated[$1] = $5
            cache_bundle[$1] = $6
            cache_display[$1] = $7
            next
        }
        {
            print $0 "|" cache_mtime[$1] "|" cache_size[$1] "|" cache_epoch[$1] "|" cache_updated[$1] "|" cache_bundle[$1] "|" cache_display[$1]
        }
    ' "$cache_source" "$scan_raw_file" > "$merged_file"
    if [[ ! -s "$merged_file" && -s "$scan_raw_file" ]]; then
        awk '{print $0 "||||||"}' "$scan_raw_file" > "$merged_file"
    fi

    local current_epoch
    current_epoch=$(get_epoch_seconds)
    local inline_metadata_count=0

    while IFS='|' read -r app_path display_name bundle_id app_mtime cached_mtime cached_size_kb cached_epoch cached_updated_epoch cached_bundle_id cached_display_name; do
        [[ -n "$app_path" && -e "$app_path" ]] || continue

        local cache_match=false
        if [[ -n "$cached_mtime" && -n "$app_mtime" && "$cached_mtime" == "$app_mtime" ]]; then
            cache_match=true
        fi

        local final_epoch=0
        if [[ "$cached_epoch" =~ ^[0-9]+$ && $cached_epoch -gt 0 ]]; then
            final_epoch="$cached_epoch"
        fi

        local final_size_kb=0
        local final_size="..."
        if [[ "$cached_size_kb" =~ ^[0-9]+$ && $cached_size_kb -gt 0 ]]; then
            final_size_kb="$cached_size_kb"
            final_size=$(bytes_to_human "$((cached_size_kb * 1024))")
        fi

        local final_last_used
        final_last_used=$(uninstall_relative_time_from_epoch "$final_epoch" "$current_epoch")

        local needs_refresh=false
        if [[ $cache_match == false ]]; then
            needs_refresh=true
        elif [[ ! "$cached_size_kb" =~ ^[0-9]+$ || $cached_size_kb -le 0 ]]; then
            needs_refresh=true
        elif [[ ! "$cached_epoch" =~ ^[0-9]+$ || $cached_epoch -le 0 ]]; then
            needs_refresh=true
        elif [[ ! "$cached_updated_epoch" =~ ^[0-9]+$ ]]; then
            needs_refresh=true
        elif [[ -z "$cached_bundle_id" || -z "$cached_display_name" ]]; then
            needs_refresh=true
        else
            local cache_age=$((current_epoch - cached_updated_epoch))
            if [[ $cache_age -gt $MOLE_UNINSTALL_META_REFRESH_TTL ]]; then
                needs_refresh=true
            fi
        fi

        if [[ $needs_refresh == true ]]; then
            if [[ $inline_metadata_count -lt $MOLE_UNINSTALL_INLINE_METADATA_LIMIT ]]; then
                local inline_metadata inline_size_kb inline_epoch inline_updated_epoch
                inline_metadata=$(uninstall_collect_inline_metadata "$app_path" "${app_mtime:-0}" "$current_epoch")
                IFS='|' read -r inline_size_kb inline_epoch inline_updated_epoch <<< "$inline_metadata"
                ((inline_metadata_count++))

                if [[ "$inline_size_kb" =~ ^[0-9]+$ && $inline_size_kb -gt 0 ]]; then
                    final_size_kb="$inline_size_kb"
                    final_size=$(bytes_to_human "$((inline_size_kb * 1024))")
                fi
                if [[ "$inline_epoch" =~ ^[0-9]+$ && $inline_epoch -gt 0 ]]; then
                    final_epoch="$inline_epoch"
                    final_last_used=$(uninstall_relative_time_from_epoch "$final_epoch" "$current_epoch")
                fi
                if [[ "$inline_updated_epoch" =~ ^[0-9]+$ && $inline_updated_epoch -gt 0 ]]; then
                    cached_updated_epoch="$inline_updated_epoch"
                fi
            fi
            printf "%s|%s|%s|%s\n" "$app_path" "${app_mtime:-0}" "$bundle_id" "$display_name" >> "$refresh_file"
        fi

        local persist_updated_epoch=0
        if [[ "$cached_updated_epoch" =~ ^[0-9]+$ && $cached_updated_epoch -gt 0 ]]; then
            persist_updated_epoch="$cached_updated_epoch"
        fi
        printf "%s|%s|%s|%s|%s|%s|%s\n" "$app_path" "${app_mtime:-0}" "${final_size_kb:-0}" "${final_epoch:-0}" "${persist_updated_epoch:-0}" "$bundle_id" "$display_name" >> "$cache_snapshot_file"

        echo "${final_epoch}|${app_path}|${display_name}|${bundle_id}|${final_size}|${final_last_used}|${final_size_kb}" >> "$temp_file"
    done < "$merged_file"

    if [[ -s "$cache_snapshot_file" ]]; then
        if uninstall_acquire_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"; then
            mv "$cache_snapshot_file" "$MOLE_UNINSTALL_META_CACHE_FILE" 2> /dev/null || {
                cp "$cache_snapshot_file" "$MOLE_UNINSTALL_META_CACHE_FILE" 2> /dev/null || true
                rm -f "$cache_snapshot_file"
            }
            uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
        fi
    fi

    sort -t'|' -k1,1n "$temp_file" > "${temp_file}.sorted" || {
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file"
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    }
    rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$cache_snapshot_file"
    [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true

    [[ $total_apps -gt 50 ]] && printf "\r\033[K" >&2

    start_uninstall_metadata_refresh "$refresh_file"

    if [[ -f "${temp_file}.sorted" ]]; then
        restore_scan_int_trap
        echo "${temp_file}.sorted"
        return 0
    else
        restore_scan_int_trap
        return 1
    fi
}

load_applications() {
    local apps_file="$1"

    if [[ ! -f "$apps_file" || ! -s "$apps_file" ]]; then
        log_warning "No applications found for uninstallation"
        return 1
    fi

    apps_data=()
    selection_state=()

    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        [[ ! -e "$app_path" ]] && continue

        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
        selection_state+=(false)
    done < "$apps_file"

    if [[ ${#apps_data[@]} -eq 0 ]]; then
        log_warning "No applications available for uninstallation"
        return 1
    fi

    return 0
}

# Cleanup: restore cursor and kill keepalive.
cleanup() {
    if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
        leave_alt_screen
        unset MOLE_ALT_SCREEN_ACTIVE
    fi
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2> /dev/null || true
        wait "$sudo_keepalive_pid" 2> /dev/null || true
        sudo_keepalive_pid=""
    fi
    # Log session end
    log_operation_session_end "uninstall" "${files_cleaned:-0}" "${total_size_cleaned:-0}"
    show_cursor
    exit "${1:-0}"
}

trap cleanup EXIT INT TERM

main() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="uninstall"
    log_operation_session_start "uninstall"

    # Global flags
    for arg in "$@"; do
        case "$arg" in
            "--debug")
                export MO_DEBUG=1
                ;;
            "-h" | "--help")
                echo -e "Usage: mo uninstall [OPTIONS]"
                echo ""
                echo "Interactively select and remove applications and their leftovers."
                echo ""
                echo "Options:"
                echo "  --debug           Show detailed operation logs"
                echo "  -h, --help        Show this help message"
                exit 0
                ;;
        esac
    done

    hide_cursor

    while true; do
        unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN

        local apps_file=""
        if ! apps_file=$(scan_applications); then
            return 1
        fi

        if [[ ! -f "$apps_file" ]]; then
            return 1
        fi

        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            return 1
        fi

        set +e
        select_apps_for_uninstall
        local exit_code=$?
        set -e

        if [[ $exit_code -ne 0 ]]; then
            show_cursor
            clear_screen
            printf '\033[2J\033[H' >&2
            rm -f "$apps_file"

            return 0
        fi

        show_cursor
        clear_screen
        printf '\033[2J\033[H' >&2
        local selection_count=${#selected_apps[@]}
        if [[ $selection_count -eq 0 ]]; then
            echo "No apps selected"
            rm -f "$apps_file"
            continue
        fi
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Selected ${selection_count} apps:"
        local -a summary_rows=()
        local max_name_display_width=0
        local max_size_width=0
        local max_last_width=0
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ _ app_name _ size last_used _ <<< "$selected_app"
            local name_width=$(get_display_width "$app_name")
            [[ $name_width -gt $max_name_display_width ]] && max_name_display_width=$name_width
            local size_display="$size"
            [[ -z "$size_display" || "$size_display" == "0" || "$size_display" == "N/A" || "$size_display" == "Unknown" ]] && size_display="..."
            [[ ${#size_display} -gt $max_size_width ]] && max_size_width=${#size_display}
            local last_display=$(format_last_used_summary "$last_used")
            [[ -z "$last_display" || "$last_display" == "Unknown" || "$last_display" == "Never" ]] && last_display="..."
            [[ ${#last_display} -gt $max_last_width ]] && max_last_width=${#last_display}
        done
        ((max_size_width < 5)) && max_size_width=5
        ((max_last_width < 5)) && max_last_width=5
        ((max_name_display_width < 16)) && max_name_display_width=16

        local term_width=$(tput cols 2> /dev/null || echo 100)
        local available_for_name=$((term_width - 17 - max_size_width - max_last_width))

        local min_name_width=24
        if [[ $term_width -ge 120 ]]; then
            min_name_width=50
        elif [[ $term_width -ge 100 ]]; then
            min_name_width=42
        elif [[ $term_width -ge 80 ]]; then
            min_name_width=30
        fi

        local name_trunc_limit=$max_name_display_width
        [[ $name_trunc_limit -lt $min_name_width ]] && name_trunc_limit=$min_name_width
        [[ $name_trunc_limit -gt $available_for_name ]] && name_trunc_limit=$available_for_name
        [[ $name_trunc_limit -gt 60 ]] && name_trunc_limit=60

        max_name_display_width=0

        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$selected_app"

            local display_name
            display_name=$(truncate_by_display_width "$app_name" "$name_trunc_limit")

            local current_width
            current_width=$(get_display_width "$display_name")
            [[ $current_width -gt $max_name_display_width ]] && max_name_display_width=$current_width

            local size_display="$size"
            if [[ -z "$size_display" || "$size_display" == "0" || "$size_display" == "N/A" || "$size_display" == "Unknown" ]]; then
                size_display="..."
            fi

            local last_display
            last_display=$(format_last_used_summary "$last_used")
            [[ -z "$last_display" || "$last_display" == "Unknown" || "$last_display" == "Never" ]] && last_display="..."

            summary_rows+=("$display_name|$size_display|$last_display")
        done

        ((max_name_display_width < 16)) && max_name_display_width=16

        local index=1
        for row in "${summary_rows[@]}"; do
            IFS='|' read -r name_cell size_cell last_cell <<< "$row"
            local name_display_width
            name_display_width=$(get_display_width "$name_cell")
            local name_char_count=${#name_cell}
            local padding_needed=$((max_name_display_width - name_display_width))
            local printf_name_width=$((name_char_count + padding_needed))

            printf "%d. %-*s  %*s  |  Last: %s\n" "$index" "$printf_name_width" "$name_cell" "$max_size_width" "$size_cell" "$last_cell"
            ((index++))
        done

        batch_uninstall_applications

        rm -f "$apps_file"

        echo -e "${GRAY}Press Enter to return to application list, any other key to exit...${NC}"
        local key
        IFS= read -r -s -n1 key || key=""
        drain_pending_input

        if [[ -z "$key" ]]; then
            :
        else
            show_cursor
            return 0
        fi

    done
}

main "$@"
