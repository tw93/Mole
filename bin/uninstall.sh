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
readonly MOLE_UNINSTALL_SCAN_SPINNER_DELAY_SEC="0.25"
readonly MOLE_UNINSTALL_INLINE_METADATA_LIMIT="${MOLE_UNINSTALL_INLINE_METADATA_LIMIT:-0}"
readonly MOLE_UNINSTALL_EPOCH_FLOOR=978307200
readonly MOLE_UNINSTALL_INLINE_MDLS_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_MDLS_TIMEOUT_SEC:-0.08}"
# Display-name lookups are smaller queries than last-used-date, so the budget
# is half. Both timeouts are overridable for slow disks or cold Spotlight.
readonly MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC:-0.04}"

uninstall_relative_time_from_epoch() {
    local value_epoch="${1:-0}"
    local now_epoch="${2:-0}"

    if [[ ! "$value_epoch" =~ ^[0-9]+$ || $value_epoch -le 0 ]]; then
        echo "Unknown"
        return 0
    fi

    if [[ $value_epoch -lt $MOLE_UNINSTALL_EPOCH_FLOOR ]]; then
        echo "Unknown"
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

uninstall_normalize_size_display() {
    local size="${1:-}"
    if [[ -z "$size" || "$size" == "0" || "$size" == "Unknown" ]]; then
        echo "N/A"
        return 0
    fi
    echo "$size"
}

uninstall_normalize_last_used_display() {
    local last_used="${1:-}"
    local display
    display=$(format_last_used_summary "$last_used")
    if [[ -z "$display" || "$display" == "Never" ]]; then
        echo "Unknown"
        return 0
    fi
    echo "$display"
}

uninstall_resolve_display_name() {
    local app_path="$1"
    local app_name="$2"
    local display_name="$app_name"

    if [[ -f "$app_path/Contents/Info.plist" ]]; then
        local md_display_name
        if [[ -n "$MOLE_UNINSTALL_USER_LC_ALL" ]]; then
            md_display_name=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC" env LC_ALL="$MOLE_UNINSTALL_USER_LC_ALL" LANG="$MOLE_UNINSTALL_USER_LANG" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        elif [[ -n "$MOLE_UNINSTALL_USER_LANG" ]]; then
            md_display_name=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC" env LANG="$MOLE_UNINSTALL_USER_LANG" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        else
            md_display_name=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
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

    # Keep versioned bundle names when metadata collapses distinct installs.
    if [[ -n "$display_name" && "$app_name" == "$display_name"* && "$app_name" != "$display_name" ]]; then
        local suffix
        suffix="${app_name#"$display_name"}"
        if [[ "$suffix" == *[0-9]* ]]; then
            display_name="$app_name"
        fi
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

# Atomically replace the metadata cache file, healing stale root-owned copies.
# stdin is closed so BSD mv/cp never blocks prompting on a non-writable target.
uninstall_persist_cache_file() {
    local src="$1"
    local dst="$2"

    [[ -s "$src" ]] || {
        rm -f "$src" 2> /dev/null || true
        return 0
    }

    # Heal stale file the user cannot write to (e.g. root-owned from a prior
    # sudo run). The parent dir is user-owned, so rm succeeds regardless.
    if [[ -e "$dst" && ! -w "$dst" ]]; then
        rm -f "$dst" 2> /dev/null || true
    fi

    # shellcheck disable=SC2217 # BSD mv/cp read stdin when prompting; close it to avoid hang.
    mv -f "$src" "$dst" < /dev/null 2> /dev/null || {
        # shellcheck disable=SC2217
        cp -f "$src" "$dst" < /dev/null 2> /dev/null || true
        rm -f "$src" 2> /dev/null || true
    }
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

    if [[ "$last_used_epoch" =~ ^[0-9]+$ && $last_used_epoch -lt $MOLE_UNINSTALL_EPOCH_FLOOR ]]; then
        last_used_epoch=0
    fi

    # Fallback to app mtime so first scan does not show "...".
    if [[ ! "$last_used_epoch" =~ ^[0-9]+$ || $last_used_epoch -le 0 ]]; then
        if [[ "$app_mtime" =~ ^[0-9]+$ && $app_mtime -gt $MOLE_UNINSTALL_EPOCH_FLOOR ]]; then
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
                metadata_date=$(run_with_timeout 0.2 mdls -name kMDItemLastUsedDate -raw "$app_path" 2> /dev/null || echo "") # 0.2s: per-app probe in tight scan loop, see lib/core/timeouts.sh
                if [[ "$metadata_date" != "(null)" && -n "$metadata_date" ]]; then
                    last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$metadata_date" "+%s" 2> /dev/null || echo "0")
                fi

                if [[ ! "$last_used_epoch" =~ ^[0-9]+$ || $last_used_epoch -le 0 || $last_used_epoch -lt $MOLE_UNINSTALL_EPOCH_FLOOR ]]; then
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

        local refresh_merged_file
        refresh_merged_file=$(mktemp 2> /dev/null) || {
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
        ' "$updates_file" "$MOLE_UNINSTALL_META_CACHE_FILE" > "$refresh_merged_file"

        uninstall_persist_cache_file "$refresh_merged_file" "$MOLE_UNINSTALL_META_CACHE_FILE"

        uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
        rm -f "$updates_file" "$refresh_merged_file"
        rm -f "$refresh_file" 2> /dev/null || true
    ) > /dev/null 2>&1 &
    disown "$!" 2> /dev/null || true

}

uninstall_print_app_search_dirs() {
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

    printf '%s\n' "${app_dirs[@]}"
}

uninstall_should_skip_app_path() {
    local app_path="$1"

    [[ -e "$app_path" ]] || return 0

    # Skip nested apps inside another .app bundle.
    local parent_dir="${app_path%/*}"
    if [[ "$parent_dir" == *".app" || "$parent_dir" == *".app/"* ]]; then
        return 0
    fi

    if [[ -L "$app_path" ]]; then
        local link_target
        link_target=$(readlink "$app_path" 2> /dev/null)
        if [[ -n "$link_target" ]]; then
            local resolved_target="$link_target"
            if [[ "$link_target" != /* ]]; then
                local link_dir="${app_path%/*}"
                local _link_parent="${link_target%/*}"
                [[ "$_link_parent" == "$link_target" ]] && _link_parent="."
                resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$_link_parent" 2> /dev/null && pwd)/"${link_target##*/}" 2> /dev/null || echo ""
            fi
            case "$resolved_target" in
                /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/* | /private/etc/*)
                    return 0
                    ;;
            esac
        fi
    fi

    return 1
}

uninstall_resolve_bundle_id() {
    local app_path="$1"
    local fallback_bundle_id="${2:-}"
    local bundle_id=""
    local plist="$app_path/Contents/Info.plist"

    fallback_bundle_id="${fallback_bundle_id//|/-}"
    fallback_bundle_id="${fallback_bundle_id//[$'\t\r\n']/}"

    if [[ -f "$plist" ]]; then
        bundle_id=$(plutil -extract CFBundleIdentifier raw "$plist" 2> /dev/null || echo "")
        bundle_id="${bundle_id//|/-}"
        bundle_id="${bundle_id//[$'\t\r\n']/}"
    fi

    if [[ -n "$bundle_id" && "$bundle_id" != "(null)" ]]; then
        printf '%s\n' "$bundle_id"
        return 0
    fi

    if [[ -n "$fallback_bundle_id" && "$fallback_bundle_id" != "(null)" ]]; then
        printf '%s\n' "$fallback_bundle_id"
        return 0
    fi

    printf '%s\n' "unknown"
}

uninstall_app_is_background_only() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    [[ -f "$plist" ]] || return 1

    local bg_only
    bg_only=$(plutil -extract LSBackgroundOnly raw "$plist" 2> /dev/null || echo "")
    case "$bg_only" in
        1 | YES | yes | TRUE | true)
            return 0
            ;;
    esac

    return 1
}

uninstall_app_is_top_level_onedrive() {
    local app_path="$1"
    local bundle_id="${2:-}"

    [[ "$bundle_id" == com.microsoft.OneDrive* ]] || return 1

    case "$app_path" in
        /Applications/OneDrive.app | "$HOME"/Applications/OneDrive.app)
            return 0
            ;;
    esac

    return 1
}

uninstall_app_is_currently_eligible() {
    local app_path="$1"
    local bundle_id="${2:-}"

    [[ -n "$app_path" && -e "$app_path" ]] || return 1

    if [[ -n "$bundle_id" && "$bundle_id" != "unknown" ]] && should_protect_from_uninstall "$bundle_id"; then
        return 1
    fi

    if uninstall_app_is_background_only "$app_path" && ! uninstall_app_is_top_level_onedrive "$app_path" "$bundle_id"; then
        return 1
    fi

    return 0
}

uninstall_resolve_eligible_bundle_id() {
    local app_path="$1"
    local fallback_bundle_id="${2:-}"
    local bundle_id

    bundle_id=$(uninstall_resolve_bundle_id "$app_path" "$fallback_bundle_id")
    uninstall_app_is_currently_eligible "$app_path" "$bundle_id" || return 1
    printf '%s\n' "$bundle_id"
}

uninstall_print_app_paths_with_mtime() {
    local app_dir="$1"
    local app_path app_mtime

    [[ -d "$app_dir" ]] || return 0

    while IFS= read -r -d '' app_path; do
        [[ -n "$app_path" ]] || continue
        app_mtime=$(get_file_mtime "$app_path")
        printf '%s\t%s\n' "${app_mtime:-0}" "$app_path"
    done < <(command find "$app_dir" -maxdepth 3 -name "*.app" -print0 2> /dev/null)
}

uninstall_app_inventory_fingerprint() {
    local app_dir app_path app_mtime pkg_app_path

    {
        while IFS= read -r pkg_app_path; do
            [[ -n "$pkg_app_path" && -d "$pkg_app_path" ]] || continue
            app_mtime=$(get_file_mtime "$pkg_app_path")
            printf '%s|%s\n' "$pkg_app_path" "${app_mtime:-0}"
        done < <(pkg_receipt_nonstandard_app_paths)

        while IFS= read -r app_dir; do
            [[ -d "$app_dir" ]] || continue
            while IFS=$'\t' read -r app_mtime app_path; do
                [[ -n "$app_path" ]] || continue
                uninstall_should_skip_app_path "$app_path" && continue
                printf '%s|%s\n' "$app_path" "${app_mtime:-0}"
            done < <(uninstall_print_app_paths_with_mtime "$app_dir")
        done < <(uninstall_print_app_search_dirs)
    } | sort -u
}

# Internal helpers for scan_applications. They read and write locals
# declared in the orchestrator's scope via bash dynamic scoping; do not
# call them outside scan_applications.

# Phase 2 (Pass 1): discover candidate .app paths by combining the
# configured app search directories with pkg-receipt non-standard install
# locations, skipping bundles flagged by uninstall_should_skip_app_path.
# Each row in discovered_file is encoded as <app_path>|<app_name>|<app_mtime>.
# Writes: discovered_file
_scan_discover_apps() {
    local -a app_dirs=()
    local app_dir
    while IFS= read -r app_dir; do
        [[ -n "$app_dir" ]] && app_dirs+=("$app_dir")
    done < <(uninstall_print_app_search_dirs)

    # Scan for pkg-installed apps in non-standard locations.
    local pkg_app_path
    while IFS= read -r pkg_app_path; do
        [[ -n "$pkg_app_path" ]] || continue

        local already_scanned=false
        for app_dir in "${app_dirs[@]}"; do
            if [[ "$pkg_app_path" == "$app_dir"/*.app ]]; then
                already_scanned=true
                break
            fi
        done
        [[ "$already_scanned" == true ]] && continue

        local app_name="${pkg_app_path##*/}"
        app_name="${app_name%.app}"

        local app_mtime
        app_mtime=$(get_file_mtime "$pkg_app_path")

        printf "%s|%s|%s\n" "$pkg_app_path" "$app_name" "${app_mtime:-0}" >> "$discovered_file"
    done < <(pkg_receipt_nonstandard_app_paths)

    for app_dir in "${app_dirs[@]}"; do
        if [[ ! -d "$app_dir" ]]; then continue; fi

        while IFS=$'\t' read -r app_mtime app_path; do
            if [[ ! -e "$app_path" ]]; then continue; fi

            local app_name="${app_path##*/}"
            app_name="${app_name%.app}"

            uninstall_should_skip_app_path "$app_path" && continue

            printf "%s|%s|%s\n" "$app_path" "$app_name" "${app_mtime:-0}" >> "$discovered_file"
        done < <(uninstall_print_app_paths_with_mtime "$app_dir")
    done
}

# Phase 3: partition discovered apps into warm-cache rows (written
# directly to scan_raw_file) and cold rows (queued in app_data_tuples
# for parallel metadata resolution in _scan_resolve_uncached).
# Reads:  cache_source, discovered_file
# Writes: cached_rows_file, uncached_rows_file, scan_raw_file (via the
#         nested use_cached_scan_metadata helper), app_data_tuples
_scan_partition_cache() {
    use_cached_scan_metadata() {
        local cached_app_path="$1"
        local cached_app_mtime="$2"
        local cached_bundle_id="$3"
        local cached_display_name="$4"

        [[ -n "$cached_bundle_id" && -n "$cached_display_name" ]] || return 1

        cached_bundle_id=$(uninstall_resolve_eligible_bundle_id "$cached_app_path" "$cached_bundle_id") || return 1

        printf "%s|%s|%s|%s\n" "$cached_app_path" "$cached_display_name" "$cached_bundle_id" "$cached_app_mtime" >> "$scan_raw_file"
        return 0
    }

    if [[ -s "$discovered_file" ]]; then
        awk -F'|' -v cached_out="$cached_rows_file" -v uncached_out="$uncached_rows_file" '
            FILENAME == ARGV[1] {
                cache_mtime[$1] = $2
                cache_bundle[$1] = $6
                cache_display[$1] = $7
                next
            }
            {
                path = $1
                app_mtime = $3
                if (cache_mtime[path] == app_mtime && cache_display[path] != "") {
                    cached_bundle = cache_bundle[path] == "" ? "unknown" : cache_bundle[path]
                    print path "|" app_mtime "|" cached_bundle "|" cache_display[path] >> cached_out
                } else {
                    print path "|" $2 "|" app_mtime "|" cache_bundle[path] "|" cache_display[path] >> uncached_out
                }
            }
        ' "$cache_source" "$discovered_file"

        local cached_app_path cached_app_mtime cached_bundle_id cached_display_name
        while IFS='|' read -r cached_app_path cached_app_mtime cached_bundle_id cached_display_name; do
            use_cached_scan_metadata "$cached_app_path" "$cached_app_mtime" "$cached_bundle_id" "$cached_display_name" || true
        done < "$cached_rows_file"

        local uncached_app_path uncached_app_name uncached_app_mtime uncached_bundle_id uncached_display_name
        while IFS='|' read -r uncached_app_path uncached_app_name uncached_app_mtime uncached_bundle_id uncached_display_name; do
            app_data_tuples+=("${uncached_app_path}|${uncached_app_name}|${uncached_app_mtime}|${uncached_bundle_id}|${uncached_display_name}")
        done < "$uncached_rows_file"
    fi
}

# Phase 5 (Pass 2): resolve display names and bundle IDs in parallel for
# the cold rows queued by _scan_partition_cache. Spawns the progress
# spinner subprocess (assigns spinner_pid), fans out workers up to
# max_parallel, and waits for completion.
# Reads:  app_data_tuples
# Writes: scan_raw_file (appended by worker subshells)
_scan_resolve_uncached() {
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

        local bundle_id
        bundle_id=$(uninstall_resolve_eligible_bundle_id "$app_path" "${cached_bundle_id:-}") || return 0

        local display_name="${cached_display_name:-}"
        if [[ -z "$display_name" ]]; then
            display_name=$(uninstall_resolve_display_name "$app_path" "$app_name")
        fi

        display_name="${display_name%.app}"
        display_name="${display_name//|/-}"
        display_name="${display_name//[$'\t\r\n']/}"

        echo "${app_path}|${display_name}|${bundle_id}|${app_mtime}" >> "$output_file"
    }

    update_scan_status "Scanning applications..." "0" "$total_apps"

    (
        # shellcheck disable=SC2329  # Function invoked indirectly via trap
        cleanup_spinner() { exit 0; }
        trap cleanup_spinner TERM INT EXIT
        sleep "$MOLE_UNINSTALL_SCAN_SPINNER_DELAY_SEC" 2> /dev/null || sleep 1
        [[ -f "$scan_status_file" ]] || exit 0
        local spinner_chars="|/-\\"
        local i=0
        : > "$spinner_shown_file"
        while true; do
            local status_line status_message status_completed status_total
            status_line=$(cat "$scan_status_file" 2> /dev/null || echo "")
            IFS='|' read -r status_message status_completed status_total <<< "$status_line"
            [[ -z "$status_message" ]] && status_message="Scanning applications..."
            local c="${spinner_chars:$((i % 4)):1}"
            if [[ "$status_completed" =~ ^[0-9]+$ && "$status_total" =~ ^[0-9]+$ && $status_total -gt 0 ]]; then
                printf "\r\033[K%s %s %d/%d" "$c" "$status_message" "$status_completed" "$status_total" >&2
            else
                printf "\r\033[K%s %s" "$c" "$status_message" >&2
            fi
            ((i++))
            sleep 0.1 2> /dev/null || sleep 1
        done
    ) &
    spinner_pid=$!

    # Skip Pass 2 when the warm cache already wrote every row to $scan_raw_file.
    # Also avoids expanding an empty array — macOS bash 3.2 (the /bin/bash that
    # this script targets) treats `"${empty[@]}"` as unbound under `set -u`.
    if ((total_apps > 0)); then
        for app_data_tuple in "${app_data_tuples[@]}"; do
            ((app_count++))
            process_app_metadata "$app_data_tuple" "$scan_raw_file" &
            pids+=($!)
            update_scan_status "Scanning applications..." "$app_count" "$total_apps"

            if ((${#pids[@]} >= max_parallel)); then
                wait "${pids[0]}" 2> /dev/null
                pids=("${pids[@]:1}")
            fi
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2> /dev/null
        done
    fi
}

# Phase 7+8: merge scan_raw_file with the persistent metadata cache,
# compute display size / last-used / refresh-needed flags (either via the
# embedded awk pipeline or the bash fallback that performs inline
# metadata fetches when MOLE_UNINSTALL_INLINE_METADATA_LIMIT > 0), persist
# the cache snapshot under a lock, sort the result by epoch, kick off the
# deferred background refresh, and echo the sorted index path for the
# caller to capture.
# Reads:  scan_raw_file, cache_source
# Writes: merged_file, refresh_file, cache_snapshot_file, temp_file,
#         ${temp_file}.sorted, MOLE_UNINSTALL_META_CACHE_FILE
# Returns: 0 on success (sorted path is echoed on stdout), 1 if sort
#          fails or the sorted file did not materialize.
_scan_finalize_index() {
    update_scan_status "Merging cache data..." "0" "0"
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
    local inline_metadata_effective_limit=$MOLE_UNINSTALL_INLINE_METADATA_LIMIT
    [[ $cache_source_is_temp == true && $inline_metadata_effective_limit -gt 0 ]] && inline_metadata_effective_limit=99999
    local metadata_total=0
    metadata_total=$(wc -l < "$merged_file" 2> /dev/null || echo "0")
    [[ "$metadata_total" =~ ^[0-9]+$ ]] || metadata_total=0
    local metadata_processed=0
    update_scan_status "Collecting metadata..." "0" "$metadata_total"

    if [[ "$inline_metadata_effective_limit" -eq 0 ]]; then
        awk -F'|' \
            -v now="$current_epoch" \
            -v floor="$MOLE_UNINSTALL_EPOCH_FLOOR" \
            -v ttl="$MOLE_UNINSTALL_META_REFRESH_TTL" \
            -v refresh_out="$refresh_file" \
            -v snapshot_out="$cache_snapshot_file" \
            -v apps_out="$temp_file" '
            function isnum(value) {
                return value ~ /^[0-9]+$/
            }
            function human_size(kb, bytes, scaled) {
                if (!isnum(kb) || kb <= 0) {
                    return "--"
                }
                bytes = kb * 1024
                if (bytes >= 1000000000) {
                    scaled = int((bytes * 100 + 500000000) / 1000000000)
                    return sprintf("%d.%02dGB", int(scaled / 100), scaled % 100)
                }
                if (bytes >= 1000000) {
                    scaled = int((bytes * 10 + 500000) / 1000000)
                    return sprintf("%d.%01dMB", int(scaled / 10), scaled % 10)
                }
                if (bytes >= 1000) {
                    return sprintf("%dKB", int((bytes + 500) / 1000))
                }
                return sprintf("%dB", bytes)
            }
            function relative_time(epoch, now_epoch, days_ago, weeks_ago, months_ago, years_ago) {
                if (!isnum(epoch) || epoch <= 0 || epoch < floor) {
                    return "Unknown"
                }
                days_ago = int((now_epoch - epoch) / 86400)
                if (days_ago < 0) {
                    days_ago = 0
                }
                if (days_ago == 0) {
                    return "Today"
                }
                if (days_ago == 1) {
                    return "Yesterday"
                }
                if (days_ago < 7) {
                    return days_ago " days ago"
                }
                if (days_ago < 30) {
                    weeks_ago = int(days_ago / 7)
                    return weeks_ago == 1 ? "1 week ago" : weeks_ago " weeks ago"
                }
                if (days_ago < 365) {
                    months_ago = int(days_ago / 30)
                    return months_ago == 1 ? "1 month ago" : months_ago " months ago"
                }
                years_ago = int(days_ago / 365)
                return years_ago == 1 ? "1 year ago" : years_ago " years ago"
            }
            {
                app_path = $1
                display_name = $2
                bundle_id = $3
                app_mtime = $4
                cached_mtime = $5
                cached_size_kb = $6
                cached_epoch = $7
                cached_updated_epoch = $8
                cached_bundle_id = $9
                cached_display_name = $10

                cache_match = (cached_mtime != "" && app_mtime != "" && cached_mtime == app_mtime)

                final_epoch = (isnum(cached_epoch) && cached_epoch > 0) ? cached_epoch : 0
                if (isnum(final_epoch) && final_epoch < floor) {
                    final_epoch = 0
                }
                if ((!isnum(final_epoch) || final_epoch <= 0) && isnum(app_mtime) && app_mtime > floor) {
                    final_epoch = app_mtime
                }

                final_size_kb = (isnum(cached_size_kb) && cached_size_kb > 0) ? cached_size_kb : 0
                final_size = human_size(final_size_kb)
                final_last_used = relative_time(final_epoch, now)

                needs_refresh = 0
                if (!cache_match) {
                    needs_refresh = 1
                } else if (!isnum(cached_size_kb) || cached_size_kb <= 0) {
                    needs_refresh = 1
                } else if (!isnum(cached_epoch) || cached_epoch <= 0) {
                    needs_refresh = 1
                } else if (!isnum(cached_updated_epoch)) {
                    needs_refresh = 1
                } else if (cached_bundle_id == "" || cached_display_name == "") {
                    needs_refresh = 1
                } else if ((now - cached_updated_epoch) > ttl) {
                    needs_refresh = 1
                }

                if (needs_refresh) {
                    print app_path "|" app_mtime "|" bundle_id "|" display_name >> refresh_out
                }

                persist_updated_epoch = (isnum(cached_updated_epoch) && cached_updated_epoch > 0) ? cached_updated_epoch : 0
                print app_path "|" app_mtime "|" final_size_kb "|" final_epoch "|" persist_updated_epoch "|" bundle_id "|" display_name >> snapshot_out
                print final_epoch "|" app_path "|" display_name "|" bundle_id "|" final_size "|" final_last_used "|" final_size_kb >> apps_out
            }
        ' "$merged_file"
    else
        while IFS='|' read -r app_path display_name bundle_id app_mtime cached_mtime cached_size_kb cached_epoch cached_updated_epoch cached_bundle_id cached_display_name; do
            ((metadata_processed++))
            if ((metadata_processed % 5 == 0 || metadata_processed == metadata_total)); then
                update_scan_status "Collecting metadata..." "$metadata_processed" "$metadata_total"
            fi

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
            local final_size="--"
            if [[ "$cached_size_kb" =~ ^[0-9]+$ && $cached_size_kb -gt 0 ]]; then
                final_size_kb="$cached_size_kb"
                final_size=$(bytes_to_human "$((cached_size_kb * 1024))")
            fi

            if [[ "$final_epoch" =~ ^[0-9]+$ && $final_epoch -lt $MOLE_UNINSTALL_EPOCH_FLOOR ]]; then
                final_epoch=0
            fi
            # Fallback to app mtime to avoid unknown "last used" on first scan.
            if [[ ! "$final_epoch" =~ ^[0-9]+$ || $final_epoch -le 0 ]]; then
                if [[ "$app_mtime" =~ ^[0-9]+$ && $app_mtime -gt $MOLE_UNINSTALL_EPOCH_FLOOR ]]; then
                    final_epoch="$app_mtime"
                fi
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
                if [[ $inline_metadata_count -lt $inline_metadata_effective_limit ]]; then
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
    fi

    update_scan_status "Updating cache..." "0" "0"
    if [[ -s "$cache_snapshot_file" ]]; then
        if uninstall_acquire_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"; then
            uninstall_persist_cache_file "$cache_snapshot_file" "$MOLE_UNINSTALL_META_CACHE_FILE"
            uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
        fi
    fi

    update_scan_status "Sorting application list..." "0" "0"
    sort -t'|' -k1,1n "$temp_file" > "${temp_file}.sorted" || {
        stop_scan_spinner
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file"
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    }
    rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file"
    [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true

    update_scan_status "Finalizing list..." "0" "0"
    start_uninstall_metadata_refresh "$refresh_file"
    stop_scan_spinner

    if [[ -f "${temp_file}.sorted" ]]; then
        register_temp_file "${temp_file}.sorted"
        restore_scan_int_trap
        echo "${temp_file}.sorted"
        return 0
    else
        restore_scan_int_trap
        return 1
    fi
}

# Scan applications and collect information. Orchestrates the four
# phases (discover, partition, resolve, finalize) and owns the shared
# temp files, spinner subprocess, INT trap, and metadata cache lock.
scan_applications() {
    local temp_file scan_raw_file merged_file refresh_file cache_snapshot_file discovered_file cached_rows_file uncached_rows_file
    temp_file=$(create_temp_file)
    scan_raw_file="${temp_file}.scan"
    merged_file="${temp_file}.merged"
    refresh_file="${temp_file}.refresh"
    cache_snapshot_file="${temp_file}.cache"
    discovered_file="${temp_file}.discovered"
    cached_rows_file="${temp_file}.cached_rows"
    uncached_rows_file="${temp_file}.uncached_rows"
    local scan_status_file="${temp_file}.scan_status"
    : > "$scan_raw_file"
    : > "$refresh_file"
    : > "$cache_snapshot_file"
    : > "$discovered_file"
    : > "$cached_rows_file"
    : > "$uncached_rows_file"
    : > "$scan_status_file"

    ensure_user_dir "$MOLE_UNINSTALL_META_CACHE_DIR"
    ensure_user_file "$MOLE_UNINSTALL_META_CACHE_FILE"
    local cache_source="$MOLE_UNINSTALL_META_CACHE_FILE"
    local cache_source_is_temp=false
    if [[ ! -r "$cache_source" ]]; then
        cache_source=$(create_temp_file)
        : > "$cache_source"
        cache_source_is_temp=true
    fi

    # Local spinner_pid for cleanup
    local spinner_pid=""
    local spinner_shown_file="${temp_file}.spinner_shown"
    local previous_int_trap=""
    previous_int_trap=$(trap -p INT || true)

    restore_scan_int_trap() {
        if [[ -n "$previous_int_trap" ]]; then
            # eval: restore previous trap captured by $(trap -p INT)
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
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "$scan_status_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        exit 130
    }
    trap trap_scan_cleanup INT

    update_scan_status() {
        local message="$1"
        local completed="${2:-0}"
        local total="${3:-0}"
        printf "%s|%s|%s\n" "$message" "$completed" "$total" > "$scan_status_file"
    }

    stop_scan_spinner() {
        if [[ -n "$spinner_pid" ]]; then
            kill -TERM "$spinner_pid" 2> /dev/null || true
            wait "$spinner_pid" 2> /dev/null || true
            spinner_pid=""
        fi
        if [[ -f "$spinner_shown_file" ]]; then
            printf "\r\033[K" >&2
        fi
        rm -f "$spinner_shown_file" "$scan_status_file" 2> /dev/null || true
    }

    # Phase 2: discover candidate apps.
    _scan_discover_apps

    # Phase 3: partition into warm-cache and cold rows.
    local -a app_data_tuples=()
    _scan_partition_cache

    # Phase 4: bail out if discovery yielded nothing.
    if [[ ${#app_data_tuples[@]} -eq 0 && ! -s "$scan_raw_file" ]]; then
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "$scan_status_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        printf "\r\033[K" >&2
        echo "No applications found to uninstall." >&2
        return 1
    fi
    # Phase 5: parallel metadata resolution for cold rows.
    _scan_resolve_uncached

    # Phase 6: bail out if Pass 2 produced nothing.
    update_scan_status "Building uninstall index..." "0" "0"

    if [[ ! -s "$scan_raw_file" ]]; then
        stop_scan_spinner
        echo "No applications found to uninstall" >&2
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    fi

    # Phase 7+8: merge cache, persist, sort, return path.
    _scan_finalize_index
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
    local exit_code="${1:-$?}"
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
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# Match app names from scan data against user-provided search terms.
# Performs case-insensitive substring matching on app display names.
# Returns matched entries from apps_data in selected_apps.
match_apps_by_name() {
    local -a search_terms=("$@")
    selected_apps=()
    local -a matched_indices=()

    for search_term in "${search_terms[@]}"; do
        local search_lower
        search_lower=$(echo "$search_term" | tr '[:upper:]' '[:lower:]')
        # Escape glob characters to prevent pattern injection
        search_lower=${search_lower//\\/\\\\}
        search_lower=${search_lower//\*/\\*}
        search_lower=${search_lower//\?/\\?}
        search_lower=${search_lower//\[/\\[}
        local found=false
        local idx=0
        for app_data in "${apps_data[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$app_data"
            local name_lower
            name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
            # Also try matching against the .app directory base name
            local dir_name
            dir_name=$(basename "$app_path" .app)
            local dir_lower
            dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

            if [[ "$name_lower" == "$search_lower" || "$dir_lower" == "$search_lower" ]]; then
                # Exact match - prefer this
                local already=false
                local mi
                for mi in "${matched_indices[@]+"${matched_indices[@]}"}"; do
                    [[ -z "$mi" ]] && continue
                    [[ "$mi" == "$idx" ]] && already=true && break
                done
                if [[ "$already" == "false" ]]; then
                    selected_apps+=("$app_data")
                    matched_indices+=("$idx")
                fi
                found=true
                break
            fi
            idx=$((idx + 1))
        done

        # If no exact match, try substring match
        if [[ "$found" == "false" ]]; then
            idx=0
            for app_data in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$app_data"
                local name_lower
                name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                local dir_name
                dir_name=$(basename "$app_path" .app)
                local dir_lower
                dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

                if [[ "$name_lower" == *"$search_lower"* || "$dir_lower" == *"$search_lower"* ]]; then
                    local already=false
                    local mi
                    for mi in "${matched_indices[@]+"${matched_indices[@]}"}"; do
                        [[ -z "$mi" ]] && continue
                        [[ "$mi" == "$idx" ]] && already=true && break
                    done
                    if [[ "$already" == "false" ]]; then
                        selected_apps+=("$app_data")
                        matched_indices+=("$idx")
                    fi
                    found=true
                fi
                idx=$((idx + 1))
            done
        fi

        if [[ "$found" == "false" ]]; then
            echo -e "${YELLOW}Warning:${NC} No application found matching '$search_term'"
        fi
    done
}

# Escape a value for embedding in a single-line JSON string. Only handles
# the chars that would break a one-line value: backslash, quote, and C0
# whitespace. Bundle IDs / display names never contain control bytes worth
# preserving in this output.
uninstall_list_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# Read-only listing: surface each installed app's display name, bundle id,
# the exact name `mo uninstall` accepts, and human-readable size. Reuses the
# existing scanner so the output stays in lockstep with what the destructive
# path sees.
uninstall_list_apps() {
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
    rm -f "$apps_file"

    # Auto-switch to JSON when stdout is piped, matching `mo status`.
    local format="text"
    if [[ ! -t 1 ]]; then
        format="json"
    fi

    if [[ "$format" == "json" ]]; then
        printf '['
        local first=1
        local app_data
        for app_data in "${apps_data[@]+"${apps_data[@]}"}"; do
            IFS='|' read -r _ app_path app_name bundle_id size _ _ <<< "$app_data"
            local cask=""
            if is_homebrew_available; then
                cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
            fi
            local uninstall_name="${cask:-$app_name}"
            local source_label="App"
            [[ -n "$cask" ]] && source_label="Homebrew"
            local size_display
            size_display=$(uninstall_normalize_size_display "$size")
            if [[ $first -eq 1 ]]; then
                first=0
                printf '\n'
            else
                printf ',\n'
            fi
            printf '  {"name": "%s", "bundle_id": "%s", "source": "%s", "uninstall_name": "%s", "path": "%s", "size": "%s"}' \
                "$(uninstall_list_json_escape "$app_name")" \
                "$(uninstall_list_json_escape "$bundle_id")" \
                "$source_label" \
                "$(uninstall_list_json_escape "$uninstall_name")" \
                "$(uninstall_list_json_escape "$app_path")" \
                "$(uninstall_list_json_escape "$size_display")"
        done
        if [[ $first -eq 0 ]]; then
            printf '\n'
        fi
        printf ']\n'
        return 0
    fi

    local total=${#apps_data[@]}
    if [[ $total -eq 0 ]]; then
        echo "No applications found."
        return 0
    fi

    printf '\n'
    printf '%-36s %-30s %-30s %8s\n' 'NAME' 'BUNDLE ID' 'UNINSTALL NAME' 'SIZE'
    printf -- '-%.0s' $(seq 1 108)
    printf '\n'

    local app_data
    for app_data in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r _ app_path app_name bundle_id size _ _ <<< "$app_data"
        local cask=""
        if is_homebrew_available; then
            cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
        fi
        local uninstall_name="${cask:-$app_name}"
        local size_display
        size_display=$(uninstall_normalize_size_display "$size")

        # Truncate by display columns, then adjust printf width for CJK.
        # printf counts bytes (LC_ALL=C), but CJK chars are 3 bytes yet only
        # 2 display columns wide, so we pad with the extra bytes to land on
        # the correct visual column.
        local name_trunc name_display_w name_byte_count name_printf_w
        name_trunc=$(truncate_by_display_width "$app_name" 34)
        name_display_w=$(get_display_width "$name_trunc")

        # Get byte count in C locale for printf
        local old_lc="${LC_ALL:-}"
        export LC_ALL=C
        name_byte_count=${#name_trunc}
        if [[ -n "$old_lc" ]]; then
            export LC_ALL="$old_lc"
        else
            unset LC_ALL
        fi

        name_printf_w=$((36 + name_byte_count - name_display_w))

        printf "%-*s %-30s %-30s %8s\n" \
            "$name_printf_w" "$name_trunc" \
            "${bundle_id:0:28}" \
            "${uninstall_name:0:28}" \
            "$size_display"
    done

    printf '\n%d application(s)  |  Remove with: mo uninstall <UNINSTALL NAME>\n\n' "$total"
    return 0
}

main() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="uninstall"
    log_operation_session_start "uninstall"

    # Default to Trash routing so an accidental uninstall is recoverable.
    # The caller can opt back into rm -rf with --permanent. See #723.
    export MOLE_DELETE_MODE="${MOLE_DELETE_MODE:-trash}"

    # Parse flags and collect app name arguments
    local -a app_name_args=()
    local list_mode=0
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                show_uninstall_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                export MOLE_DRY_RUN=1
                ;;
            "--permanent")
                export MOLE_DELETE_MODE="permanent"
                ;;
            "--list")
                list_mode=1
                ;;
            "--whitelist")
                echo "Unknown uninstall option: $arg"
                echo "Whitelist management is currently supported by: mo clean --whitelist / mo optimize --whitelist"
                echo "Use 'mo uninstall --help' for supported options."
                exit 1
                ;;
            -*)
                echo "Unknown uninstall option: $arg"
                echo "Use 'mo uninstall --help' for supported options."
                exit 1
                ;;
            *)
                app_name_args+=("$arg")
                ;;
        esac
    done

    # --list short-circuits before any destructive code. Read-only path:
    # scan, resolve uninstall names, print table or JSON, exit 0.
    if [[ $list_mode -eq 1 ]]; then
        uninstall_list_apps
        return $?
    fi

    hide_cursor
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No app files or settings will be modified"
        printf '\n'
    fi

    # Direct uninstall by app name
    if [[ ${#app_name_args[@]} -gt 0 ]]; then
        local apps_file=""
        if ! apps_file=$(scan_applications); then
            show_cursor
            return 1
        fi
        if [[ ! -f "$apps_file" ]]; then
            show_cursor
            return 1
        fi
        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            show_cursor
            return 1
        fi

        match_apps_by_name "${app_name_args[@]}"
        rm -f "$apps_file"

        if [[ ${#selected_apps[@]} -eq 0 ]]; then
            show_cursor
            echo "No matching applications found."
            return 1
        fi

        show_cursor
        clear_screen
        local selection_count=${#selected_apps[@]}
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Matched ${selection_count} app(s):"
        local index=1
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ app_path app_name _ size last_used _ <<< "$selected_app"
            local size_display
            size_display=$(uninstall_normalize_size_display "$size")
            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")
            printf "%d. %s  %s  |  Last: %s\n" "$index" "$app_name" "$size_display" "$last_display"
            ((index++))
        done

        printf '\n'
        printf "Proceed with uninstallation? [y/N] "
        local confirm
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborted."
            return 0
        fi

        batch_uninstall_applications
        return 0
    fi

    local first_scan=true
    local cached_apps_file=""
    local cached_inventory_fingerprint=""
    while true; do
        unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN

        if [[ $first_scan == false ]]; then
            echo -e "${GRAY}Checking application list...${NC}" >&2
        fi
        first_scan=false

        local apps_file=""
        local reused_app_cache=false
        if [[ -n "$cached_apps_file" && -f "$cached_apps_file" && -n "$cached_inventory_fingerprint" ]]; then
            local current_inventory_fingerprint
            current_inventory_fingerprint=$(uninstall_app_inventory_fingerprint 2> /dev/null || echo "")
            if [[ -n "$current_inventory_fingerprint" && "$current_inventory_fingerprint" == "$cached_inventory_fingerprint" ]]; then
                apps_file="$cached_apps_file"
                reused_app_cache=true
            fi
        fi

        if [[ "$reused_app_cache" != "true" ]]; then
            if [[ -n "$cached_apps_file" && -f "$cached_apps_file" ]]; then
                rm -f "$cached_apps_file" 2> /dev/null || true
            fi

            if ! apps_file=$(scan_applications); then
                return 1
            fi

            cached_apps_file="$apps_file"
            cached_inventory_fingerprint=$(uninstall_app_inventory_fingerprint 2> /dev/null || echo "")
        fi

        if [[ ! -f "$apps_file" ]]; then
            return 1
        fi

        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
            return 1
        fi

        # Keystrokes typed during the scan/load phase must not leak into the
        # selector. A queued Enter would confirm whichever app is highlighted
        # first and drop the user straight into the destructive path. See #726.
        drain_pending_input

        set +e
        select_apps_for_uninstall
        local exit_code=$?
        set -e

        if [[ $exit_code -ne 0 ]]; then
            show_cursor
            clear_screen
            printf '\033[2J\033[H' >&2
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""

            return 0
        fi

        show_cursor
        clear_screen
        printf '\033[2J\033[H' >&2
        local selection_count=${#selected_apps[@]}
        if [[ $selection_count -eq 0 ]]; then
            echo "No apps selected"
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
            local size_display
            size_display=$(uninstall_normalize_size_display "$size")
            [[ ${#size_display} -gt $max_size_width ]] && max_size_width=${#size_display}
            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")
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

            local size_display
            size_display=$(uninstall_normalize_size_display "$size")

            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")

            summary_rows+=("$display_name|$size_display|$last_display")
        done

        ((max_name_display_width < 16)) && max_name_display_width=16

        local index=1
        for row in "${summary_rows[@]}"; do
            IFS='|' read -r name_cell size_cell last_cell <<< "$row"
            local name_display_width
            name_display_width=$(get_display_width "$name_cell")

            # Get byte count for printf width calculation
            local old_lc="${LC_ALL:-}"
            export LC_ALL=C
            local name_byte_count=${#name_cell}
            if [[ -n "$old_lc" ]]; then
                export LC_ALL="$old_lc"
            else
                unset LC_ALL
            fi

            local padding_needed=$((max_name_display_width - name_display_width))
            local printf_name_width=$((name_byte_count + padding_needed))

            printf "%d. %-*s  %*s  |  Last: %s\n" "$index" "$printf_name_width" "$name_cell" "$max_size_width" "$size_cell" "$last_cell"
            ((index++))
        done

        batch_uninstall_applications

        local _countdown=5
        local _key=""
        local _pressed=false
        while [[ $_countdown -gt 0 ]]; do
            printf "\r${GRAY}Press Enter to return to the app list, press q to exit (%d)${NC} " "$_countdown"
            if IFS= read -r -s -n1 -t 1 _key; then
                _pressed=true
                break
            fi
            ((_countdown--))
        done
        printf "\n"
        drain_pending_input

        if [[ "$_pressed" == "true" && -z "$_key" ]]; then
            :
        else
            show_cursor
            return 0
        fi

    done
}

main "$@"
