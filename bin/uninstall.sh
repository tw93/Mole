#!/bin/bash
# Mole - Uninstall command.
# Interactive app uninstaller.
# Removes app files and leftovers.

set -euo pipefail

# User state and installed tools must never run with inherited root privileges.
# Individual maintenance operations request administrator access themselves.
if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'Run Mole without sudo; it requests administrator access when needed.' >&2
    exit 1
fi

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
source "$SCRIPT_DIR/../lib/uninstall/steam.sh"
source "$SCRIPT_DIR/../lib/uninstall/batch.sh"

# State
selected_apps=()
declare -a apps_data=()
declare -a selection_state=()
total_items=0
files_cleaned=0
total_size_cleaned=0

readonly MOLE_UNINSTALL_META_CACHE_DIR="$HOME/.cache/mole"
readonly MOLE_UNINSTALL_META_CACHE_FILE="$MOLE_UNINSTALL_META_CACHE_DIR/uninstall_app_metadata_v4"
readonly MOLE_UNINSTALL_META_CACHE_LOCK="${MOLE_UNINSTALL_META_CACHE_FILE}.lock"
readonly MOLE_UNINSTALL_META_REFRESH_TTL=604800 # 7 days
readonly MOLE_UNINSTALL_EPOCH_FLOOR=978307200
# Display-name mdls lookup budget during scan; overridable for slow disks or
# cold Spotlight.
readonly MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC:-0.04}"
readonly MOLE_UNINSTALL_INLINE_MDLS_SIZE_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_MDLS_SIZE_TIMEOUT_SEC:-0.04}"
# Bounded inline du fallback for cold rows whose quick mdls probe missed
# (new apps are often not yet Spotlight-indexed). Only enabled when the
# cold-row count is small so a fully cold first scan keeps the fast path.
readonly MOLE_UNINSTALL_INLINE_DU_SIZE_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_DU_SIZE_TIMEOUT_SEC:-2}"
readonly MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS="${MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS:-20}"

uninstall_normalize_size_display() {
    local size="${1:-}"
    local app_path="${2:-}"

    if [[ -n "$app_path" ]] && uninstall_app_is_steam_launcher "$app_path"; then
        echo "N/A (Steam-managed)"
        return 0
    fi

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

uninstall_quick_app_size_kb() {
    local app_path="$1"
    [[ -n "$app_path" && -d "$app_path" ]] || {
        echo "0"
        return 0
    }

    local physical_size
    physical_size=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_SIZE_TIMEOUT_SEC" mdls -name kMDItemPhysicalSize -raw "$app_path" 2> /dev/null || echo "")
    if [[ "$physical_size" =~ ^[0-9]+$ && "$physical_size" -gt 0 ]]; then
        echo $(((physical_size + 1023) / 1024))
        return 0
    fi

    echo "0"
}

# This bounded physical-size fallback stands in until the deferred refresh
# can query Spotlight metadata.
uninstall_inline_du_size_kb() {
    local app_path="$1"
    [[ -n "$app_path" && -d "$app_path" ]] || {
        echo "0"
        return 0
    }

    local du_size_kb
    du_size_kb=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_DU_SIZE_TIMEOUT_SEC" du -skP "$app_path" 2> /dev/null | awk '{print $1; exit}') || du_size_kb=""
    if [[ "$du_size_kb" =~ ^[0-9]+$ && "$du_size_kb" -gt 0 ]]; then
        echo "$du_size_kb"
        return 0
    fi

    echo "0"
}

# The user's UI language preference, most preferred first. Resolved once per
# run: `defaults` costs a fork, and the answer cannot change mid-scan. An empty
# result (no `defaults`, or a fresh account with no array) simply skips the
# localized lookup and leaves the bundle's unlocalized names in charge.
mole_uninstall_preferred_languages() {
    defaults read -g AppleLanguages 2> /dev/null |
        sed -e 's/[()"]//g' -e 's/,//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
        grep -v '^$'
}

# Directory names to try inside Contents/Resources for one BCP-47 tag, most
# specific first. macOS bundles spell the same locale several ways, so
# "zh-Hans-CN" has to reach a zh-Hans.lproj, a zh_CN.lproj or a bare zh.lproj.
_uninstall_lproj_candidates() {
    local tag="$1"
    [[ -n "$tag" ]] || return 0

    local base script region rest
    base="${tag%%-*}"
    rest="${tag#"$base"}"
    rest="${rest#-}"
    script=""
    region=""
    if [[ -n "$rest" ]]; then
        local second="${rest%%-*}"
        if [[ "$second" =~ ^[A-Z][a-z]{3}$ ]]; then
            script="$second"
            region="${rest#"$second"}"
            region="${region#-}"
        else
            region="$second"
        fi
    fi

    printf '%s\n' "$tag" "${tag//-/_}"
    [[ -n "$script" ]] && printf '%s\n' "${base}-${script}" "${base}_${script}"
    [[ -n "$region" ]] && printf '%s\n' "${base}_${region}" "${base}-${region}"
    printf '%s\n' "$base"
}

readonly MOLE_UNINSTALL_PREFERRED_LANGS="$(mole_uninstall_preferred_languages)"
# Display names depend on the ordered language list. Keep the fingerprint in
# each cache row so a language change invalidates only the derived name while
# size and last-used metadata remain reusable.
readonly MOLE_UNINSTALL_LANGUAGE_SIGNATURE="$(printf '%s' "$MOLE_UNINSTALL_PREFERRED_LANGS" | cksum | awk '{print $1 ":" $2}')"

# The bundle's own name for a locale, read from the same InfoPlist.strings that
# Finder consults. Prints nothing when the bundle does not localize the name,
# which leaves the caller on the unlocalized Info.plist values.
#
# The search stops at the first preferred language the bundle localizes at all,
# and never continues into a language the user did not ask for. MiaoYan.app is
# the case that rule exists for: it ships zh-Hans.lproj but no en.lproj, and an
# English-preferring Mac shows "MiaoYan", not the Chinese name that happens to
# be the only override present.
_uninstall_localized_bundle_name() {
    local app_path="$1"
    local resources="$app_path/Contents/Resources"
    [[ -d "$resources" ]] || return 0

    local dev_region=""
    dev_region=$(plutil -extract CFBundleDevelopmentRegion raw "$app_path/Contents/Info.plist" 2> /dev/null || echo "")
    case "$dev_region" in
        English) dev_region="en" ;;
        Japanese) dev_region="ja" ;;
        French) dev_region="fr" ;;
        German) dev_region="de" ;;
    esac
    local dev_base="${dev_region%%-*}"

    local lang candidate lproj=""
    while IFS= read -r lang; do
        [[ -n "$lang" ]] || continue
        while IFS= read -r candidate; do
            if [[ -d "$resources/$candidate.lproj" ]]; then
                lproj="$resources/$candidate.lproj"
                break
            fi
        done < <(_uninstall_lproj_candidates "$lang")
        [[ -n "$lproj" ]] && break

        # Base.lproj carries the development region, so a bundle with only
        # Base.lproj still counts as localized for that language.
        if [[ -n "$dev_base" && "${lang%%-*}" == "$dev_base" && -d "$resources/Base.lproj" ]]; then
            lproj="$resources/Base.lproj"
            break
        fi
    done <<< "$MOLE_UNINSTALL_PREFERRED_LANGS"

    [[ -n "$lproj" && -f "$lproj/InfoPlist.strings" ]] || return 0

    local localized
    localized=$(plutil -extract CFBundleDisplayName raw -- "$lproj/InfoPlist.strings" 2> /dev/null || echo "")
    if [[ -z "$localized" || "$localized" == "(null)" ]]; then
        localized=$(plutil -extract CFBundleName raw -- "$lproj/InfoPlist.strings" 2> /dev/null || echo "")
    fi
    [[ -n "$localized" && "$localized" != "(null)" ]] || return 0
    printf '%s' "$localized"
}

uninstall_resolve_display_name() {
    local app_path="$1"
    local app_name="$2"
    local display_name="$app_name"

    if mole_is_playcover_app "$app_path"; then
        # Flat iOS bundle named after its bundle id; the plist holds the name.
        local playcover_name=""
        playcover_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Info.plist" 2> /dev/null || echo "")
        if [[ -z "$playcover_name" || "$playcover_name" == "(null)" ]]; then
            playcover_name=$(plutil -extract CFBundleName raw "$app_path/Info.plist" 2> /dev/null || echo "")
        fi
        [[ -n "$playcover_name" && "$playcover_name" != "(null)" ]] && display_name="$playcover_name"
    elif [[ -f "$app_path/Contents/Info.plist" ]]; then
        # The bundle's own localized name is what Finder shows, so it wins and
        # spares the mdls fork. mdls only ever reports the on-disk file name for
        # an app bundle, which is exactly the unrecognizable string this avoids.
        local localized_name
        localized_name=$(_uninstall_localized_bundle_name "$app_path")

        local md_display_name=""
        if [[ -n "$localized_name" ]]; then
            :
        elif [[ -n "$MOLE_UNINSTALL_USER_LC_ALL" ]]; then
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

        if [[ -n "$localized_name" ]]; then
            display_name="$localized_name"
        elif [[ -n "$md_display_name" && "$md_display_name" != "(null)" && "$md_display_name" != "$app_name" ]]; then
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

    display_name="${display_name%.[aA][pP][pP]}"
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
        local worker_idx=0 wait_rc=0

        while IFS='|' read -r app_path app_mtime bundle_id display_name language_signature; do
            [[ -n "$app_path" && -d "$app_path" ]] || continue
            ((worker_idx++))
            local worker_output="${updates_file}.${worker_idx}"

            # stdin from /dev/null: these workers never read the terminal, and a
            # background job that keeps the tty on stdin lets its timeout helpers
            # take the terminal away from the foreground prompt (#1222).
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

                printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$app_path" "${app_mtime:-0}" "$size_kb" "${last_used_epoch:-0}" "$now_epoch" "$bundle_id" "$display_name" "$language_signature" > "$worker_output"
            ) < /dev/null &
            worker_pids+=($!)

            if ((${#worker_pids[@]} >= max_parallel)); then
                local completed_pid="" worker_slot
                wait_rc=0
                mole_wait_for_any_worker completed_pid "${worker_pids[@]}" || wait_rc=$?
                if [[ $wait_rc -ge 128 ]]; then
                    for worker_pid in "${worker_pids[@]}"; do
                        kill "$worker_pid" 2> /dev/null || true
                    done
                    for worker_pid in "${worker_pids[@]}"; do
                        wait "$worker_pid" 2> /dev/null || true
                    done
                    break
                fi
                for worker_slot in "${!worker_pids[@]}"; do
                    if [[ "${worker_pids[$worker_slot]}" == "$completed_pid" ]]; then
                        unset 'worker_pids[worker_slot]'
                        break
                    fi
                done
            fi
        done < "$refresh_file"

        if [[ $wait_rc -ge 128 ]]; then
            local output_idx
            for ((output_idx = 1; output_idx <= worker_idx; output_idx++)); do
                rm -f "${updates_file}.${output_idx}" # SAFE: exact scratch output of this refresh worker
            done
            rm -f "$updates_file" "$refresh_file" # SAFE: exact scratch files owned by this detached refresh
            exit "$wait_rc"
        fi

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
        # Redirect stdin from /dev/null so the perl timeout fallback does not see
        # a tty on stdin and hand the controlling terminal to its timed child.
        # This background refresh (and its nested workers, which inherit this
        # stdin) never needs the terminal; leaving stdin as the tty lets a worker
        # steal the foreground process group and stop the foreground prompt with
        # SIGTTIN (issue #1222). The interactive sudo handoff (#1201) is on
        # non-background call sites and is unaffected.
    ) > /dev/null 2>&1 < /dev/null &
    disown "$!" 2> /dev/null || true

}

uninstall_print_app_search_dirs() {
    local -a app_dirs=(
        "/Applications"
        "$HOME/Applications"
        "/Library/Input Methods"
        "$HOME/Library/Input Methods"
    )
    local playcover_apps_dir
    playcover_apps_dir=$(mole_playcover_apps_dir)
    [[ -d "$playcover_apps_dir" ]] && app_dirs+=("$playcover_apps_dir")

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

    # Skip nested apps inside another case-variant .app bundle.
    local parent_dir="${app_path%/*}"
    if [[ "$parent_dir" == *.[aA][pP][pP] || "$parent_dir" == *.[aA][pP][pP]/* ]]; then
        return 0
    fi

    # A PlayCover launcher alias is listed through the bundle it points at.
    if [[ "$parent_dir" == "$HOME/Applications/PlayCover" ]] &&
        mole_playcover_alias_target "$app_path" > /dev/null 2>&1; then
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
    mole_is_playcover_app "$app_path" && plist="$app_path/Info.plist"

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

uninstall_app_is_directly_in_search_root() {
    local app_path="$1"
    local app_parent="${app_path%/*}"
    local app_dir

    while IFS= read -r app_dir; do
        [[ -n "$app_dir" ]] || continue
        if [[ "$app_parent" == "$app_dir" ]]; then
            return 0
        fi
    done < <(uninstall_print_app_search_dirs)

    return 1
}

uninstall_app_is_currently_eligible() {
    local app_path="$1"
    local bundle_id="${2:-}"

    [[ -n "$app_path" && -e "$app_path" ]] || return 1

    if [[ -n "$bundle_id" && "$bundle_id" != "unknown" ]] && should_protect_from_uninstall "$bundle_id"; then
        return 1
    fi

    if uninstall_app_is_background_only "$app_path" && ! uninstall_app_is_directly_in_search_root "$app_path"; then
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
    local include_info_mtime="${2:-false}"

    [[ -d "$app_dir" ]] || return 0

    # shellcheck disable=SC2016 # The child shell expands the batch arguments.
    command find "$app_dir" -maxdepth 3 -iname "*.app" -exec /bin/bash -c '
        stat_cmd="$1"
        include_info="$2"
        shift 2
        stat_paths=("$@")
        if [[ "$include_info" == true ]]; then
            for app_path in "$@"; do
                if [[ -e "$app_path/Contents/Info.plist" || -L "$app_path/Contents/Info.plist" ]]; then
                    stat_paths+=("$app_path/Contents/Info.plist")
                fi
            done
        fi
        if rows=$("$stat_cmd" -f "%m%t%N" "${stat_paths[@]}" 2>/dev/null); then
            if [[ "$include_info" == true ]]; then
                printf "%s\n" "$rows" | awk -F "\t" '\''
                    {
                        path = substr($0, index($0, "\t") + 1)
                        mtimes[path] = $1 ~ /^[0-9]+$/ ? $1 : 0
                        if (tolower(path) ~ /[.]app$/) paths[++count] = path
                    }
                    END {
                        for (i = 1; i <= count; i++) {
                            path = paths[i]
                            info = mtimes[path "/Contents/Info.plist"]
                            printf "%s\t%s\t%s\n", mtimes[path], (info == "" ? 0 : info), path
                        }
                    }
                '\''
            else
                printf "%s\n" "$rows" | awk -F "\t" '\''
                    { printf "%s\t%s\n", ($1 ~ /^[0-9]+$/ ? $1 : 0), substr($0, index($0, "\t") + 1) }
                '\''
            fi
        else
            # Discard a partial batch and preserve the old zero-mtime fallback.
            for app_path in "$@"; do
                app_mtime=$("$stat_cmd" -f%m "$app_path" 2>/dev/null) || app_mtime=0
                [[ "$app_mtime" =~ ^[0-9]+$ ]] || app_mtime=0
                if [[ "$include_info" == true ]]; then
                    info_mtime=$("$stat_cmd" -f%m "$app_path/Contents/Info.plist" 2>/dev/null) || info_mtime=0
                    [[ "$info_mtime" =~ ^[0-9]+$ ]] || info_mtime=0
                    printf "%s\t%s\t%s\n" "$app_mtime" "$info_mtime" "$app_path"
                else
                    printf "%s\t%s\n" "$app_mtime" "$app_path"
                fi
            done
        fi
    ' _ "$STAT_BSD" "$include_info_mtime" {} + 2> /dev/null
}

uninstall_app_inventory_fingerprint() {
    if [[ -n "${1:-}" && -s "$1" ]]; then
        LC_ALL=C sort -u "$1"
        return $?
    fi
    local app_dir app_path app_mtime info_mtime pkg_app_path

    {
        while IFS= read -r pkg_app_path; do
            [[ -n "$pkg_app_path" && -d "$pkg_app_path" ]] || continue
            app_mtime=$(get_file_mtime "$pkg_app_path")
            info_mtime=$(get_file_mtime "$pkg_app_path/Contents/Info.plist")
            printf '%s|%s|%s\n' "$pkg_app_path" "${app_mtime:-0}" "${info_mtime:-0}"
        done < <(pkg_receipt_nonstandard_app_paths)

        while IFS= read -r app_dir; do
            [[ -d "$app_dir" ]] || continue
            while IFS=$'\t' read -r app_mtime info_mtime app_path; do
                if [[ ! "$info_mtime" =~ ^[0-9]+$ ]]; then
                    app_path="${info_mtime}${app_path:+$'\t'$app_path}"
                    info_mtime=""
                fi
                [[ -n "$app_path" ]] || continue
                uninstall_should_skip_app_path "$app_path" && continue
                [[ "$info_mtime" =~ ^[0-9]+$ ]] || info_mtime=$(get_file_mtime "$app_path/Contents/Info.plist")
                printf '%s|%s|%s\n' "$app_path" "${app_mtime:-0}" "${info_mtime:-0}"
            done < <(uninstall_print_app_paths_with_mtime "$app_dir" true)
        done < <(uninstall_print_app_search_dirs)
    } | LC_ALL=C sort -u
}

# The in-session app index remains valid when the live inventory only loses
# rows. load_applications rechecks path existence before displaying each row.
# New rows and changed mtimes must rebuild the index so protection and bundle
# metadata are evaluated again.
uninstall_inventory_can_reuse_cached_apps() {
    local cached_inventory="$1"
    local current_inventory="$2"
    local additions=""
    local removals=""

    [[ -n "$cached_inventory" && -n "$current_inventory" ]] || return 1
    additions=$(LC_ALL=C comm -13 \
        <(printf '%s\n' "$cached_inventory") \
        <(printf '%s\n' "$current_inventory")) || return 1
    [[ -z "$additions" ]] || return 1

    removals=$(LC_ALL=C comm -23 \
        <(printf '%s\n' "$cached_inventory") \
        <(printf '%s\n' "$current_inventory")) || return 1
    local removed_row removed_path
    while IFS= read -r removed_row; do
        [[ -n "$removed_row" ]] || continue
        removed_path="${removed_row%|*}"
        removed_path="${removed_path%|*}"
        [[ ! -e "$removed_path" ]] || return 1
    done <<< "$removals"
    return 0
}

# Internal helpers for scan_applications. They read and write locals
# declared in the orchestrator's scope via bash dynamic scoping; do not
# call them outside scan_applications.

# Both metadata phases publish their live workers to scan_applications so
# interruption can stop and reap them before removing the scan scratch files.
_scan_stop_metadata_workers() {
    if [[ ${#metadata_worker_pids[@]} -gt 0 ]]; then
        local metadata_pid
        for metadata_pid in "${metadata_worker_pids[@]}"; do
            kill "$metadata_pid" 2> /dev/null || true
        done
        for metadata_pid in "${metadata_worker_pids[@]}"; do
            wait "$metadata_pid" 2> /dev/null || true
        done
    fi
    metadata_worker_pids=()
    if [[ ${#metadata_worker_outputs[@]} -gt 0 ]]; then
        local metadata_output
        for metadata_output in "${metadata_worker_outputs[@]}"; do
            rm -f "$metadata_output" # SAFE: exact per-worker scan scratch path
        done
    fi
    metadata_worker_outputs=()
    if [[ -n "${metadata_worker_output_dir:-}" ]]; then
        rmdir "$metadata_worker_output_dir" 2> /dev/null || true
        metadata_worker_output_dir=""
    fi
}

_scan_record_inventory_app() {
    local app_path="$1" app_mtime="$2" info_mtime="${3:-}"
    [[ "$info_mtime" =~ ^[0-9]+$ ]] || info_mtime=$(get_file_mtime "$app_path/Contents/Info.plist")
    printf '%s|%s|%s\n' "$app_path" "${app_mtime:-0}" "${info_mtime:-0}" >> "$scan_inventory_file"
}

# Phase 2 (Pass 1): discover candidate .app paths by combining the
# configured app search directories with pkg-receipt non-standard install
# locations, skipping bundles flagged by uninstall_should_skip_app_path.
# Each row in discovered_file is encoded as <app_path>|<app_name>|<app_mtime>.
# Writes: discovered_file and scan_inventory_file
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

        local app_mtime
        app_mtime=$(get_file_mtime "$pkg_app_path")
        if [[ -d "$pkg_app_path" ]]; then
            _scan_record_inventory_app "$pkg_app_path" "$app_mtime"
        fi

        local already_scanned=false
        for app_dir in "${app_dirs[@]}"; do
            if [[ "$pkg_app_path" == "$app_dir"/*.[aA][pP][pP] ]]; then
                already_scanned=true
                break
            fi
        done
        [[ "$already_scanned" == true ]] && continue

        local app_name="${pkg_app_path##*/}"
        app_name="${app_name%.[aA][pP][pP]}"

        printf "%s|%s|%s\n" "$pkg_app_path" "$app_name" "${app_mtime:-0}" >> "$discovered_file"
    done < <(pkg_receipt_nonstandard_app_paths)

    for app_dir in "${app_dirs[@]}"; do
        if [[ ! -d "$app_dir" ]]; then continue; fi

        local info_mtime
        while IFS=$'\t' read -r app_mtime info_mtime app_path; do
            if [[ ! "$info_mtime" =~ ^[0-9]+$ ]]; then
                app_path="${info_mtime}${app_path:+$'\t'$app_path}"
                info_mtime=""
            fi
            if [[ ! -e "$app_path" ]]; then continue; fi

            local app_name="${app_path##*/}"
            app_name="${app_name%.[aA][pP][pP]}"

            uninstall_should_skip_app_path "$app_path" && continue

            _scan_record_inventory_app "$app_path" "$app_mtime" "$info_mtime"

            printf "%s|%s|%s\n" "$app_path" "$app_name" "${app_mtime:-0}" >> "$discovered_file"
        done < <(uninstall_print_app_paths_with_mtime "$app_dir" true)
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
        local cached_size_kb="$5"
        local cached_output_file="$6"

        [[ -n "$cached_bundle_id" && -n "$cached_display_name" ]] || return 1
        [[ "$cached_size_kb" =~ ^[0-9]+$ && "$cached_size_kb" -gt 0 ]] || return 1

        cached_bundle_id=$(uninstall_resolve_eligible_bundle_id "$cached_app_path" "$cached_bundle_id") || return 1

        printf "%s|%s|%s|%s|%s\n" "$cached_app_path" "$cached_display_name" "$cached_bundle_id" "$cached_app_mtime" "$cached_size_kb" >> "$cached_output_file"
        return 0
    }

    if [[ -s "$discovered_file" ]]; then
        awk -F'|' -v cached_out="$cached_rows_file" -v uncached_out="$uncached_rows_file" -v language_signature="$MOLE_UNINSTALL_LANGUAGE_SIGNATURE" '
            FILENAME == ARGV[1] {
                cache_mtime[$1] = $2
                cache_size[$1] = $3
                cache_bundle[$1] = $6
                cache_display[$1] = $7
                cache_language[$1] = $8
                next
            }
            {
                path = $1
                app_mtime = $3
                if (cache_mtime[path] == app_mtime && cache_display[path] != "" && cache_language[path] == language_signature && cache_size[path] ~ /^[0-9]+$/ && cache_size[path] > 0) {
                    cached_bundle = cache_bundle[path] == "" ? "unknown" : cache_bundle[path]
                    print path "|" app_mtime "|" cached_bundle "|" cache_display[path] "|" cache_size[path] >> cached_out
                } else {
                    cached_display = cache_language[path] == language_signature ? cache_display[path] : ""
                    print path "|" $2 "|" app_mtime "|" cache_bundle[path] "|" cached_display >> uncached_out
                }
            }
        ' "$cache_source" "$discovered_file"

        # Live eligibility checks still run for warm rows, but share a small
        # worker budget instead of serializing every plist and protection probe.
        _ensure_uninstall_regex
        local max_parallel
        max_parallel=$(get_optimal_parallel_jobs io)
        [[ "$max_parallel" =~ ^[0-9]+$ && $max_parallel -gt 0 ]] || max_parallel=1
        [[ $max_parallel -le 4 ]] || max_parallel=4
        metadata_worker_outputs=()
        metadata_worker_pids=()
        if [[ -s "$cached_rows_file" ]]; then
            metadata_worker_output_dir=$(create_temp_dir) || return 1
        fi
        local cached_app_path cached_app_mtime cached_bundle_id cached_display_name cached_size_kb
        local completed_pid="" worker_slot warm_rc=0
        while IFS='|' read -r cached_app_path cached_app_mtime cached_bundle_id cached_display_name cached_size_kb; do
            local warm_output="${metadata_worker_output_dir}/warm.${#metadata_worker_outputs[@]}"
            metadata_worker_outputs+=("$warm_output")
            (
                umask 077
                use_cached_scan_metadata "$cached_app_path" "$cached_app_mtime" "$cached_bundle_id" "$cached_display_name" "$cached_size_kb" "$warm_output" || true
            ) < /dev/null &
            metadata_worker_pids+=("$!")
            if [[ ${#metadata_worker_pids[@]} -ge $max_parallel ]]; then
                warm_rc=0
                mole_wait_for_any_worker completed_pid "${metadata_worker_pids[@]}" || warm_rc=$?
                if [[ $warm_rc -ge 128 ]]; then
                    break
                fi
                for worker_slot in "${!metadata_worker_pids[@]}"; do
                    if [[ "${metadata_worker_pids[$worker_slot]}" == "$completed_pid" ]]; then
                        unset 'metadata_worker_pids[worker_slot]'
                        break
                    fi
                done
            fi
        done < "$cached_rows_file"
        if [[ $warm_rc -ge 128 ]]; then
            _scan_stop_metadata_workers
        fi
        if [[ ${#metadata_worker_pids[@]} -gt 0 ]]; then
            for pid in "${metadata_worker_pids[@]}"; do
                [[ $warm_rc -lt 128 ]] || kill "$pid" 2> /dev/null || true
                local worker_rc=0
                wait "$pid" 2> /dev/null || worker_rc=$?
                [[ $worker_rc -lt 128 ]] || warm_rc=$worker_rc
            done
        fi
        metadata_worker_pids=()
        if [[ ${#metadata_worker_outputs[@]} -gt 0 ]]; then
            for warm_output in "${metadata_worker_outputs[@]}"; do
                if [[ $warm_rc -lt 128 && -f "$warm_output" ]]; then
                    local cached_scan_row
                    while IFS= read -r cached_scan_row; do
                        printf '%s\n' "$cached_scan_row"
                    done < "$warm_output" >> "$scan_raw_file"
                fi
                rm -f "$warm_output" # SAFE: exact per-worker scan scratch path above
            done
        fi
        metadata_worker_outputs=()
        if [[ -n "${metadata_worker_output_dir:-}" ]]; then
            rmdir "$metadata_worker_output_dir" 2> /dev/null || true
            metadata_worker_output_dir=""
        fi
        [[ $warm_rc -lt 128 ]] || return "$warm_rc"

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
    # Cold rows are usually the handful of newly installed or updated apps;
    # give those a bounded du when the quick mdls probe misses so the size
    # shows on first paint. A fully cold cache (first run) exceeds the cap
    # and keeps the fast path; the deferred refresh still fills the cache.
    local inline_du_fallback=0
    if [[ "$MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS" =~ ^[0-9]+$ ]] &&
        ((total_apps > 0 && total_apps <= MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS)); then
        inline_du_fallback=1
    fi
    local max_parallel
    max_parallel=$(get_optimal_parallel_jobs "io")
    if [[ $max_parallel -lt 8 ]]; then
        max_parallel=8 # At least 8 for good performance
    elif [[ $max_parallel -gt 32 ]]; then
        max_parallel=32 # Cap at 32 to avoid too many processes
    fi
    metadata_worker_pids=()

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

        display_name="${display_name%.[aA][pP][pP]}"
        display_name="${display_name//|/-}"
        display_name="${display_name//[$'\t\r\n']/}"

        local quick_size_kb
        quick_size_kb=$(uninstall_quick_app_size_kb "$app_path")
        [[ "$quick_size_kb" =~ ^[0-9]+$ ]] || quick_size_kb=0

        if [[ "$quick_size_kb" -eq 0 && "${inline_du_fallback:-0}" == "1" ]]; then
            quick_size_kb=$(uninstall_inline_du_size_kb "$app_path")
            [[ "$quick_size_kb" =~ ^[0-9]+$ ]] || quick_size_kb=0
        fi

        echo "${app_path}|${display_name}|${bundle_id}|${app_mtime}|${quick_size_kb}" >> "$output_file"
    }

    update_scan_status "Scanning applications..." "0" "$total_apps"

    # Skip Pass 2 when the warm cache already wrote every row to $scan_raw_file.
    # Also avoids expanding an empty array; macOS bash 3.2 (the /bin/bash that
    # this script targets) treats `"${empty[@]}"` as unbound under `set -u`.
    if ((total_apps > 0)); then
        for app_data_tuple in "${app_data_tuples[@]}"; do
            ((app_count++))
            # Redirect stdin from /dev/null so the perl timeout fallback used by
            # process_app_metadata does not hand the controlling terminal to its
            # timed mdls/du child from this background worker (issue #1222).
            process_app_metadata "$app_data_tuple" "$scan_raw_file" < /dev/null &
            metadata_worker_pids+=($!)
            update_scan_status "Scanning applications..." "$app_count" "$total_apps"

            if ((${#metadata_worker_pids[@]} >= max_parallel)); then
                local completed_pid="" worker_slot wait_rc=0
                mole_wait_for_any_worker completed_pid "${metadata_worker_pids[@]}" || wait_rc=$?
                if [[ $wait_rc -ge 128 ]]; then
                    return "$wait_rc"
                fi
                for worker_slot in "${!metadata_worker_pids[@]}"; do
                    if [[ "${metadata_worker_pids[$worker_slot]}" == "$completed_pid" ]]; then
                        unset 'metadata_worker_pids[worker_slot]'
                        break
                    fi
                done
            fi
        done

        for pid in "${metadata_worker_pids[@]+"${metadata_worker_pids[@]}"}"; do
            local wait_rc=0
            wait "$pid" 2> /dev/null || wait_rc=$?
            if [[ $wait_rc -ge 128 ]]; then
                return "$wait_rc"
            fi
        done
        metadata_worker_pids=()
    fi
}

# Phase 6: collapse duplicate bundle IDs discovered from backup volumes or
# mirrored Applications folders. Keep the live app locations first.
# The dedupe key includes the .app basename so distinct installs that share a
# bundle ID (e.g. Xcode.app and Xcode-beta.app, both com.apple.dt.Xcode) are
# kept, while true clones of the same bundle name in mirrored roots collapse.
_scan_dedupe_bundle_ids() {
    [[ -s "$scan_raw_file" ]] || return 0

    local deduped_file="${scan_raw_file}.deduped"
    if ! awk -F'|' -v home_apps="$HOME/Applications/" '
        function starts_with(value, prefix) {
            return prefix != "" && substr(value, 1, length(prefix)) == prefix
        }
        function direct_app_under(path, prefix, rest) {
            if (!starts_with(path, prefix)) {
                return 0
            }
            rest = substr(path, length(prefix) + 1)
            return index(rest, "/") == 0 && tolower(rest) ~ /[.]app$/
        }
        function path_rank(path) {
            if (direct_app_under(path, "/Applications/")) {
                return 1
            }
            if (direct_app_under(path, home_apps)) {
                return 2
            }
            if (starts_with(path, "/Volumes/")) {
                return 4
            }
            return 3
        }
        function app_basename(path, n, parts) {
            n = split(path, parts, "/")
            return parts[n]
        }
        {
            bundle_id = $3
            if (bundle_id == "" || bundle_id == "unknown") {
                key = "__path__" NR
                rows[key] = $0
                order[++count] = key
                next
            }

            key = bundle_id "|" app_basename($1)
            rank = path_rank($1)
            if (!(key in rows)) {
                rows[key] = $0
                ranks[key] = rank
                order[++count] = key
                next
            }
            if (rank < ranks[key]) {
                rows[key] = $0
                ranks[key] = rank
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                key = order[i]
                if (key in rows) {
                    print rows[key]
                }
            }
        }
    ' "$scan_raw_file" > "$deduped_file"; then
        rm -f "$deduped_file" 2> /dev/null || true
        return 0
    fi

    if ! mv "$deduped_file" "$scan_raw_file" 2> /dev/null; then
        rm -f "$deduped_file" 2> /dev/null || true
    fi
}

# Phase 7+8: merge scan_raw_file with the persistent metadata cache,
# compute display size / last-used / refresh-needed flags via the embedded awk
# pipeline, persist the cache snapshot under a lock, sort the result by epoch,
# kick off the deferred background refresh, and echo the sorted index path for
# the caller to capture.
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
            cache_language[$1] = $8
            next
        }
        {
            print $0 "|" cache_mtime[$1] "|" cache_size[$1] "|" cache_epoch[$1] "|" cache_updated[$1] "|" cache_bundle[$1] "|" cache_display[$1] "|" cache_language[$1]
        }
    ' "$cache_source" "$scan_raw_file" > "$merged_file"
    if [[ ! -s "$merged_file" && -s "$scan_raw_file" ]]; then
        awk '{print $0 "|||||||"}' "$scan_raw_file" > "$merged_file"
    fi

    local current_epoch
    current_epoch=$(get_epoch_seconds)
    local metadata_total=0
    metadata_total=$(wc -l < "$merged_file" 2> /dev/null || echo "0")
    [[ "$metadata_total" =~ ^[0-9]+$ ]] || metadata_total=0
    update_scan_status "Collecting metadata..." "0" "$metadata_total"

    awk -F'|' \
        -v now="$current_epoch" \
        -v floor="$MOLE_UNINSTALL_EPOCH_FLOOR" \
        -v ttl="$MOLE_UNINSTALL_META_REFRESH_TTL" \
        -v language_signature="$MOLE_UNINSTALL_LANGUAGE_SIGNATURE" \
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
                # A merged row is the 5-field scan row plus the 7 cache fields
                # appended above, so 12 is the only width the current writers
                # produce. The threshold has to track that sum: while the cache
                # block was 6 fields wide, 11 named the same shape, and leaving
                # it at 11 after the language signature landed would have let a
                # hypothetical 11-field row take this branch and read every
                # cached_* value shifted by one, so the signature itself would
                # render as the display name.
                if (NF >= 12) {
                    inline_size_kb = $5
                    cached_mtime = $6
                    cached_size_kb = $7
                    cached_epoch = $8
                    cached_updated_epoch = $9
                    cached_bundle_id = $10
                    cached_display_name = $11
                    cached_language_signature = $12
                } else {
                    inline_size_kb = 0
                    cached_mtime = $5
                    cached_size_kb = $6
                    cached_epoch = $7
                    cached_updated_epoch = $8
                    cached_bundle_id = $9
                    cached_display_name = $10
                    cached_language_signature = ""
                }

                cache_match = (cached_mtime != "" && app_mtime != "" && cached_mtime == app_mtime)

                final_epoch = (isnum(cached_epoch) && cached_epoch > 0) ? cached_epoch : 0
                if (isnum(final_epoch) && final_epoch < floor) {
                    final_epoch = 0
                }
                if ((!isnum(final_epoch) || final_epoch <= 0) && isnum(app_mtime) && app_mtime > floor) {
                    final_epoch = app_mtime
                }

                final_size_kb = (isnum(cached_size_kb) && cached_size_kb > 0) ? cached_size_kb : 0
                if ((!isnum(final_size_kb) || final_size_kb <= 0) && isnum(inline_size_kb) && inline_size_kb > 0) {
                    final_size_kb = inline_size_kb
                }
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
                } else if (cached_language_signature != language_signature) {
                    needs_refresh = 1
                } else if ((now - cached_updated_epoch) > ttl) {
                    needs_refresh = 1
                }

                if (needs_refresh) {
                    print app_path "|" app_mtime "|" bundle_id "|" display_name "|" language_signature >> refresh_out
                }

                persist_updated_epoch = (isnum(cached_updated_epoch) && cached_updated_epoch > 0) ? cached_updated_epoch : 0
                print app_path "|" app_mtime "|" final_size_kb "|" final_epoch "|" persist_updated_epoch "|" bundle_id "|" display_name "|" language_signature >> snapshot_out
                print final_epoch "|" app_path "|" display_name "|" bundle_id "|" final_size "|" final_last_used "|" final_size_kb >> apps_out
            }
        ' "$merged_file"

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
        rm -f "$scan_inventory_file" "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file"
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    }
    rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file"
    [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true

    update_scan_status "Finalizing list..." "0" "0"
    debug_log "Uninstall finalization: metadata refresh begin (elapsed ${SECONDS}s, parent $$)"
    start_uninstall_metadata_refresh "$refresh_file"
    debug_log "Uninstall finalization: metadata refresh launched (elapsed ${SECONDS}s, parent $$)"
    stop_scan_spinner "Preparing app list..."
    debug_log "Uninstall finalization: spinner stopped (elapsed ${SECONDS}s, parent $$)"

    if [[ -f "${temp_file}.sorted" ]]; then
        # shellcheck disable=SC2217 # BSD mv may read stdin when overriding permissions.
        mv -f "$scan_inventory_file" "${temp_file}.sorted.inventory" < /dev/null || {
            rm -f "$scan_inventory_file" "${temp_file}.sorted" # SAFE: exact scan output and inventory scratch files
            restore_scan_int_trap
            return 1
        }
        register_temp_file "${temp_file}.sorted.inventory"
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
    temp_file=$(create_temp_file) || return 1
    scan_raw_file="${temp_file}.scan"
    merged_file="${temp_file}.merged"
    refresh_file="${temp_file}.refresh"
    cache_snapshot_file="${temp_file}.cache"
    discovered_file="${temp_file}.discovered"
    cached_rows_file="${temp_file}.cached_rows"
    uncached_rows_file="${temp_file}.uncached_rows"
    local scan_inventory_file
    scan_inventory_file=$(create_temp_file) || {
        rm -f "$temp_file" # SAFE: exact scan scratch anchor, before any worker starts
        return 1
    }
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

    local -a metadata_worker_pids=() metadata_worker_outputs=()
    local metadata_worker_output_dir=""

    # Local spinner_pid for cleanup
    local spinner_pid=""
    local spinner_shown_file="${temp_file}.spinner_shown"
    local previous_int_trap=""
    local previous_term_trap=""
    previous_int_trap=$(trap -p INT || true)
    previous_term_trap=$(trap -p TERM || true)

    restore_scan_int_trap() {
        if [[ -n "$previous_int_trap" ]]; then
            # eval: restore previous trap captured by $(trap -p INT)
            eval "$previous_int_trap"
        else
            trap - INT
        fi
        if [[ -n "$previous_term_trap" ]]; then
            # eval: restore previous trap captured by $(trap -p TERM)
            eval "$previous_term_trap"
        else
            trap - TERM
        fi
    }

    # Trap to handle Ctrl+C during scan
    # shellcheck disable=SC2329  # Function invoked indirectly via trap
    trap_scan_cleanup() {
        _scan_stop_metadata_workers
        if [[ -n "$spinner_pid" ]]; then
            kill -TERM "$spinner_pid" 2> /dev/null || true
            wait "$spinner_pid" 2> /dev/null || true
        fi
        if [[ -f "$spinner_shown_file" ]]; then
            printf "\r\033[K" >&2
        fi
        rm -f "$scan_inventory_file" "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "$scan_status_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        exit "${1:-130}"
    }
    trap trap_scan_cleanup INT
    trap 'trap_scan_cleanup 143' TERM

    update_scan_status() {
        local message="$1"
        local completed="${2:-0}"
        local total="${3:-0}"
        printf "%s|%s|%s\n" "$message" "$completed" "$total" > "$scan_status_file"
    }

    start_scan_spinner() {
        [[ -n "$spinner_pid" ]] && return 0
        [[ -t 2 || "${MOLE_TEST_FORCE_SCAN_SPINNER:-0}" == "1" ]] || return 0
        (
            # shellcheck disable=SC2329  # Function invoked indirectly via trap
            cleanup_spinner() { exit 0; }
            trap cleanup_spinner TERM INT EXIT
            [[ -f "$scan_status_file" ]] || exit 0
            mo_load_spinner_frames
            local i=0
            : > "$spinner_shown_file"
            while true; do
                local status_line status_message status_completed status_total
                status_line=$(cat "$scan_status_file" 2> /dev/null || echo "")
                IFS='|' read -r status_message status_completed status_total <<< "$status_line"
                [[ -z "$status_message" ]] && status_message="Scanning applications..."
                local c="${MO_SPINNER_FRAMES[$((i % ${#MO_SPINNER_FRAMES[@]}))]}"
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
    }

    # With a final message, a shown spinner leaves that line in place on the
    # alternate screen instead of erasing it, so the screen is not blank while
    # the selector builds its rows. The caller animates it from there.
    stop_scan_spinner() {
        local final_message="${1:-}"
        if [[ -n "$spinner_pid" ]]; then
            debug_log "Uninstall spinner stop begin (pid $spinner_pid, elapsed ${SECONDS}s)"
            kill -TERM "$spinner_pid" 2> /dev/null || true
            wait "$spinner_pid" 2> /dev/null || true
            debug_log "Uninstall spinner stop complete (pid $spinner_pid, elapsed ${SECONDS}s)"
            spinner_pid=""
        fi
        if [[ -f "$spinner_shown_file" ]]; then
            if [[ -n "$final_message" && "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                mo_load_spinner_frames
                printf "\r\033[K%s %s" "${MO_SPINNER_FRAMES[0]}" "$final_message" >&2
            else
                printf "\r\033[K" >&2
            fi
        fi
        rm -f "$spinner_shown_file" "$scan_status_file" 2> /dev/null || true
    }

    update_scan_status "Scanning applications..." "0" "0"
    start_scan_spinner

    # Phase 2: discover candidate apps.
    _scan_discover_apps

    # Phase 3: partition into warm-cache and cold rows.
    local -a app_data_tuples=()
    local metadata_rc=0
    _scan_partition_cache || metadata_rc=$?
    if [[ $metadata_rc -ne 0 ]]; then
        _scan_stop_metadata_workers
        stop_scan_spinner
        rm -f "$scan_inventory_file" "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" # SAFE: exact scan scratch paths above
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return "$metadata_rc"
    fi

    # Phase 4: bail out if discovery yielded nothing.
    if [[ ${#app_data_tuples[@]} -eq 0 && ! -s "$scan_raw_file" ]]; then
        stop_scan_spinner
        rm -f "$scan_inventory_file" "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "$scan_status_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        printf "\r\033[K" >&2
        echo "No applications found to uninstall." >&2
        return 1
    fi
    # Phase 5: parallel metadata resolution for cold rows.
    _scan_resolve_uncached || metadata_rc=$?
    if [[ $metadata_rc -ne 0 ]]; then
        _scan_stop_metadata_workers
        stop_scan_spinner
        rm -f "$scan_inventory_file" "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" # SAFE: exact scan scratch paths above
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return "$metadata_rc"
    fi

    # Phase 6: bail out if Pass 2 produced nothing.
    update_scan_status "Building uninstall index..." "0" "0"

    if [[ ! -s "$scan_raw_file" ]]; then
        stop_scan_spinner
        echo "No applications found to uninstall" >&2
        rm -f "$scan_inventory_file" "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    fi

    _scan_dedupe_bundle_ids

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

# Keep the scan and selector on one alternate screen so restoring the terminal
# also restores the primary-screen cursor to the command's original row.
start_uninstall_interactive_screen() {
    if [[ -t 1 && -t 2 && "${MOLE_ALT_SCREEN_ACTIVE:-}" != "1" ]]; then
        enter_alt_screen
        export MOLE_ALT_SCREEN_ACTIVE=1
        export MOLE_MANAGED_ALT_SCREEN=1
        printf '\033[2J\033[H' >&2
    fi
}

stop_uninstall_interactive_screen() {
    # Every exit from the scan and selector passes here, so a "Preparing app
    # list..." spinner never outlives the alternate screen.
    stop_inline_spinner 2> /dev/null || true
    if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
        leave_alt_screen
    fi
    unset MOLE_ALT_SCREEN_ACTIVE MOLE_MANAGED_ALT_SCREEN
}

# Surface an abort during scan/load/selection instead of returning to the
# prompt as if the run had succeeded. Interactive mode renders on an alternate
# screen, so the reason has to be printed after the screen is restored (#1339).
uninstall_abort() {
    local reason="$1"
    stop_uninstall_interactive_screen
    show_cursor
    log_error "Uninstall aborted: $reason"
}

# Cleanup: restore cursor and kill keepalive.
cleanup() {
    local exit_code="${1:-$?}"
    trap - EXIT INT TERM
    stop_uninstall_interactive_screen
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2> /dev/null || true
        wait "$sudo_keepalive_pid" 2> /dev/null || true
        sudo_keepalive_pid=""
    fi
    # Log session end
    log_operation_session_end "uninstall" "${files_cleaned:-0}" "${total_size_cleaned:-0}"
    cleanup_temp_files
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

    # `mo uninstall Tor Browser` arrives as two words. Matching each word
    # alone sent "Tor" into a substring hit on WebSTORm while the app the
    # user actually named sat in the list (#1365). When the words joined
    # with spaces exactly match an installed app's display or directory
    # name, that is the query, UNLESS every word already exactly names its
    # own installed app: with Foo.app, Bar.app, and "Foo Bar.app" all
    # present, `mo uninstall Foo Bar` keeps its original two-app meaning
    # rather than silently collapsing into the third.
    if [[ ${#search_terms[@]} -gt 1 ]]; then
        local every_word_exact=true
        local word word_lower word_app word_hit
        for word in "${search_terms[@]}"; do
            word_lower=$(echo "$word" | tr '[:upper:]' '[:lower:]')
            word_hit=false
            for word_app in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$word_app"
                local word_name_lower word_dir_lower
                word_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                word_dir_lower=$(basename "$app_path")
                word_dir_lower="${word_dir_lower%.[aA][pP][pP]}"
                word_dir_lower=$(printf '%s' "$word_dir_lower" | tr '[:upper:]' '[:lower:]')
                if [[ "$word_name_lower" == "$word_lower" || "$word_dir_lower" == "$word_lower" ]]; then
                    word_hit=true
                    break
                fi
            done
            if [[ "$word_hit" == "false" ]]; then
                every_word_exact=false
                break
            fi
        done
        if [[ "$every_word_exact" == "false" ]]; then
            local joined_lower
            joined_lower=$(echo "$*" | tr '[:upper:]' '[:lower:]')
            local joined_app
            for joined_app in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$joined_app"
                local joined_name_lower joined_dir_lower
                joined_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                joined_dir_lower=$(basename "$app_path")
                joined_dir_lower="${joined_dir_lower%.[aA][pP][pP]}"
                joined_dir_lower=$(printf '%s' "$joined_dir_lower" | tr '[:upper:]' '[:lower:]')
                if [[ "$joined_name_lower" == "$joined_lower" || "$joined_dir_lower" == "$joined_lower" ]]; then
                    selected_apps=("$joined_app")
                    return 0
                fi
            done
        fi
    fi

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
            dir_name=$(basename "$app_path")
            dir_name="${dir_name%.[aA][pP][pP]}"
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
                dir_name=$(basename "$app_path")
                dir_name="${dir_name%.[aA][pP][pP]}"
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
        uninstall_abort "could not complete the application scan"
        return 1
    fi
    if [[ ! -f "$apps_file" ]]; then
        uninstall_abort "application scan produced no list"
        return 1
    fi
    if ! load_applications "$apps_file"; then
        rm -f "$apps_file" "${apps_file}.inventory" # SAFE: exact scan output and inventory sidecar
        uninstall_abort "no applications available for uninstallation"
        return 1
    fi
    rm -f "$apps_file" "${apps_file}.inventory" # SAFE: exact scan output and inventory sidecar

    # One read-only Caskroom and `brew list --cask` snapshot serves every row
    # instead of one probe per app. It is scoped to this listing pass only.
    local _MOLE_BREW_BATCH_LIST_READY=0 _MOLE_BREW_BATCH_LIST="" _MOLE_BREW_BATCH_LIST_RC=0
    local _MOLE_BREW_BATCH_ROOM_READY=0 _MOLE_BREW_BATCH_ROOM_FILE="" _MOLE_BREW_BATCH_ROOM_RC=0
    local brew_inventory_dir="" brew_prep_rc=0
    if is_homebrew_available && brew_inventory_dir=$(create_temp_dir); then
        _MOLE_BREW_BATCH_ROOM_FILE="$brew_inventory_dir/caskroom"
        _mole_brew_prepare_batch_inventory || brew_prep_rc=$?
        if [[ $brew_prep_rc -ge 128 ]]; then
            rm -rf -- "$brew_inventory_dir" # SAFE: private read-only Homebrew inventory directory created above
            return "$brew_prep_rc"
        fi
    fi

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
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
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
        [[ -z "$brew_inventory_dir" ]] || rm -rf -- "$brew_inventory_dir" # SAFE: private read-only Homebrew inventory directory created above
        return 0
    fi

    local total=${#apps_data[@]}
    if [[ $total -eq 0 ]]; then
        echo "No applications found."
        [[ -z "$brew_inventory_dir" ]] || rm -rf -- "$brew_inventory_dir" # SAFE: private read-only Homebrew inventory directory created above
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
        size_display=$(uninstall_normalize_size_display "$size" "$app_path")

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
    [[ -z "$brew_inventory_dir" ]] || rm -rf -- "$brew_inventory_dir" # SAFE: private read-only Homebrew inventory directory created above
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
                echo "Unknown uninstall option: $arg" >&2
                echo "Whitelist management is currently supported by: mo clean --whitelist / mo optimize --whitelist" >&2
                echo "Use 'mo uninstall --help' for supported options." >&2
                exit 1
                ;;
            -*)
                echo "Unknown uninstall option: $arg" >&2
                echo "Use 'mo uninstall --help' for supported options." >&2
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
            uninstall_abort "could not complete the application scan"
            return 1
        fi
        if [[ ! -f "$apps_file" ]]; then
            uninstall_abort "application scan produced no list"
            return 1
        fi
        if ! load_applications "$apps_file"; then
            rm -f "$apps_file" "${apps_file}.inventory" # SAFE: exact scan output and inventory sidecar
            uninstall_abort "no applications available for uninstallation"
            return 1
        fi

        match_apps_by_name "${app_name_args[@]}"
        rm -f "$apps_file" "${apps_file}.inventory" # SAFE: exact scan output and inventory sidecar

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
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
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
    unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN MOLE_ALT_SCREEN_ACTIVE
    while true; do
        unset MOLE_INLINE_LOADING

        # Keep scanning and selection on one alternate screen. Entering the
        # selector only after the scan leaves the primary-screen cursor below
        # the scan progress; restoring it on cancel then creates a large blank
        # gap before the next shell prompt (#1194).
        start_uninstall_interactive_screen

        if [[ $first_scan == false ]]; then
            echo -e "${GRAY}Checking application list...${NC}" >&2
        fi
        first_scan=false

        local apps_file=""
        local reused_app_cache=false
        if [[ -n "$cached_apps_file" && -f "$cached_apps_file" && -n "$cached_inventory_fingerprint" ]]; then
            local current_inventory_fingerprint
            current_inventory_fingerprint=$(uninstall_app_inventory_fingerprint 2> /dev/null || echo "")
            if uninstall_inventory_can_reuse_cached_apps "$cached_inventory_fingerprint" "$current_inventory_fingerprint"; then
                apps_file="$cached_apps_file"
                reused_app_cache=true
                cached_inventory_fingerprint="$current_inventory_fingerprint"
            fi
        fi

        if [[ "$reused_app_cache" != "true" ]]; then
            if [[ -n "$cached_apps_file" && -f "$cached_apps_file" ]]; then
                rm -f "$cached_apps_file" 2> /dev/null || true
            fi

            local scan_abort_reason=""
            debug_log "Uninstall interactive scan begin (elapsed ${SECONDS}s, parent $$)"
            if ! apps_file=$(scan_applications); then
                scan_abort_reason="could not complete the application scan"
            elif [[ ! -f "$apps_file" ]]; then
                scan_abort_reason="application scan produced no list"
            fi
            if [[ -n "$scan_abort_reason" ]]; then
                uninstall_abort "$scan_abort_reason"
                rm -f "$apps_file"
                [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
                return 1
            fi

            debug_log "Uninstall interactive scan returned (elapsed ${SECONDS}s, parent $$)"
            # The scan runs in a command substitution, so it can only leave a
            # static "Preparing app list..." line. Animate that line here until
            # the selector stops the spinner right before its first draw.
            if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
                MOLE_SPINNER_PREFIX="" start_inline_spinner "Preparing app list..."
            fi
            cached_apps_file="$apps_file"
            debug_log "Uninstall inventory fingerprint begin (elapsed ${SECONDS}s, parent $$)"
            cached_inventory_fingerprint=$(uninstall_app_inventory_fingerprint "${apps_file}.inventory" 2> /dev/null || echo "")
            rm -f "${apps_file}.inventory" # SAFE: exact sidecar produced by scan_applications
            debug_log "Uninstall inventory fingerprint complete (elapsed ${SECONDS}s, parent $$)"
        fi

        debug_log "Uninstall list load begin (elapsed ${SECONDS}s, parent $$)"
        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
            uninstall_abort "no applications available for uninstallation"
            return 1
        fi

        debug_log "Uninstall list load complete (elapsed ${SECONDS}s, parent $$)"
        # Keystrokes typed during the scan/load phase must not leak into the
        # selector. A queued Enter would confirm whichever app is highlighted
        # first and drop the user straight into the destructive path. See #726.
        # The drain flushes everything already queued, so a longer idle wait
        # only adds blank screen before the list.
        debug_log "Uninstall input drain begin (elapsed ${SECONDS}s, parent $$)"
        drain_pending_input
        debug_log "Uninstall selector begin (elapsed ${SECONDS}s, parent $$)"

        set +e
        select_apps_for_uninstall
        local exit_code=$?
        debug_log "Uninstall selector returned (exit $exit_code, elapsed ${SECONDS}s, parent $$)"
        set -e

        if [[ $exit_code -ne 0 ]]; then
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
            if [[ "${_MOLE_MENU_USER_QUIT:-0}" == "1" ]]; then
                # A deliberate q is a cancel, not a failure: leave quietly
                # with success, matching mole's other cancel flows. Only a
                # selector that broke gets the visible abort below.
                stop_uninstall_interactive_screen
                show_cursor
                return 0
            fi
            uninstall_abort "application selection did not complete"
            return 1
        fi

        stop_uninstall_interactive_screen
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
            IFS='|' read -r _ app_path app_name _ size last_used _ <<< "$selected_app"
            local name_width=$(get_display_width "$app_name")
            [[ $name_width -gt $max_name_display_width ]] && max_name_display_width=$name_width
            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
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
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")

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

        # A nested command may have returned the controlling terminal to the
        # parent shell. Reading while Mole is no longer the foreground process
        # group would suspend the completed uninstall with SIGTTIN. The removal
        # is already finished, so exit cleanly instead of touching terminal input.
        if ! mole_tty_is_foreground; then
            show_cursor
            return 0
        fi

        local _countdown=5
        local _key=""
        local _pressed=false
        while [[ $_countdown -gt 0 ]]; do
            printf "\r${GRAY}Press Enter to return to the app list, press q to exit (%d)${NC} " "$_countdown"
            if IFS= read -r -s -n1 -t 1 _key 2> /dev/null; then
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

# Run only when executed; sourcing loads definitions for tests. Kept on one
# line because test harnesses slice this file with sed/awk anchored on the
# `main "$@"` sentinel, and a multi-line guard leaves them an unclosed `if`.
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
