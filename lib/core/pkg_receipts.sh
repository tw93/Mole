#!/bin/bash
# Roomy - pkgutil receipt helpers.
# Finds package-installed app bundles outside the standard app locations.

set -euo pipefail

if [[ -n "${ROOMY_PKG_RECEIPTS_LOADED:-}" ]]; then
    return 0
fi
readonly ROOMY_PKG_RECEIPTS_LOADED=1

_roomy_pkg_receipt_app_root() {
    local rel_path="${1#/}"
    [[ -n "$rel_path" ]] || return 1

    local app_path="/$rel_path"
    case "$app_path" in
        /usr/local/*.app | /opt/*.app)
            printf '%s\n' "$app_path"
            return 0
            ;;
        /usr/local/*.app/* | /opt/*.app/*)
            printf '%s.app\n' "${app_path%%.app/*}"
            return 0
            ;;
    esac

    return 1
}

pkg_receipt_nonstandard_app_paths() {
    if ! command -v pkgutil > /dev/null 2>&1; then
        return 0
    fi

    local cache_file="${ROOMY_PKG_RECEIPT_CACHE_FILE:-$HOME/.cache/roomy/pkg_receipt_apps_v1}"
    local cache_ttl="${ROOMY_PKG_RECEIPT_CACHE_TTL:-3600}"
    local now_epoch=0
    if declare -f get_epoch_seconds > /dev/null 2>&1; then
        now_epoch=$(get_epoch_seconds)
    else
        now_epoch=$(date +%s 2> /dev/null || echo 0)
    fi

    if [[ "${ROOMY_PKG_RECEIPT_CACHE_DISABLE:-0}" != "1" && -r "$cache_file" ]]; then
        local cache_mtime=0
        if declare -f get_file_mtime > /dev/null 2>&1; then
            cache_mtime=$(get_file_mtime "$cache_file")
        else
            cache_mtime=$(stat -f "%m" "$cache_file" 2> /dev/null || echo 0)
        fi
        if [[ "$cache_ttl" =~ ^[0-9]+$ && "$cache_mtime" =~ ^[0-9]+$ &&
            "$now_epoch" =~ ^[0-9]+$ && $cache_ttl -gt 0 &&
            $((now_epoch - cache_mtime)) -lt $cache_ttl ]]; then
            while IFS= read -r cached_app_path; do
                [[ -n "$cached_app_path" && -d "$cached_app_path" ]] && printf '%s\n' "$cached_app_path"
            done < "$cache_file"
            return 0
        fi
    fi

    local pkgs_output
    if declare -f run_with_timeout > /dev/null 2>&1; then
        pkgs_output=$(run_with_timeout "${ROOMY_PKG_RECEIPT_LIST_TIMEOUT:-3}" pkgutil --pkgs 2> /dev/null || true)
    else
        pkgs_output=$(pkgutil --pkgs 2> /dev/null || true)
    fi
    [[ -n "$pkgs_output" ]] || return 0

    local -a seen_apps=()
    local scan_start=$SECONDS
    local scan_timeout="${ROOMY_PKG_RECEIPT_SCAN_TIMEOUT:-8}"
    local pkg_id
    while IFS= read -r pkg_id; do
        if [[ "$scan_timeout" =~ ^[0-9]+$ && $scan_timeout -gt 0 && $((SECONDS - scan_start)) -ge $scan_timeout ]]; then
            break
        fi

        [[ -n "$pkg_id" ]] || continue
        [[ "$pkg_id" =~ ^com\.apple\. ]] && continue

        local pkg_files
        pkg_files=$(pkgutil --files "$pkg_id" 2> /dev/null | command grep -E '^(/usr/local/|/opt/).*\.app(/|$)' || true)
        [[ -n "$pkg_files" ]] || continue

        local rel_path app_path duplicate
        while IFS= read -r rel_path; do
            if [[ "$scan_timeout" =~ ^[0-9]+$ && $scan_timeout -gt 0 && $((SECONDS - scan_start)) -ge $scan_timeout ]]; then
                break 2
            fi

            local stripped="${rel_path#/}"
            [[ -n "$stripped" ]] || continue
            local candidate="/$stripped"

            case "$candidate" in
                /usr/local/*.app) app_path="$candidate" ;;
                /opt/*.app) app_path="$candidate" ;;
                /usr/local/*.app/*) app_path="${candidate%%.app/*}.app" ;;
                /opt/*.app/*) app_path="${candidate%%.app/*}.app" ;;
                *) continue ;;
            esac

            [[ -n "$app_path" && -d "$app_path" ]] || continue

            duplicate=false
            local seen
            for seen in "${seen_apps[@]}"; do
                if [[ "$seen" == "$app_path" ]]; then
                    duplicate=true
                    break
                fi
            done
            [[ "$duplicate" == "true" ]] && continue

            seen_apps+=("$app_path")
        done <<< "$pkg_files"
    done <<< "$pkgs_output"

    if [[ ${#seen_apps[@]} -gt 0 ]]; then
        printf '%s\n' "${seen_apps[@]}" | sort -u
    fi

    if [[ "${ROOMY_PKG_RECEIPT_CACHE_DISABLE:-0}" != "1" && -n "$cache_file" ]]; then
        local cache_dir="${cache_file%/*}"
        if [[ -n "$cache_dir" && "$cache_dir" != "$cache_file" ]]; then
            if declare -f ensure_user_dir > /dev/null 2>&1; then
                ensure_user_dir "$cache_dir"
            else
                mkdir -p "$cache_dir" 2> /dev/null || true
            fi
        fi
        local cache_tmp
        cache_tmp=$(mktemp "${TMPDIR:-/tmp}/roomy.pkg_receipts.XXXXXX" 2> /dev/null || true)
        if [[ -n "$cache_tmp" ]]; then
            if [[ ${#seen_apps[@]} -gt 0 ]]; then
                printf '%s\n' "${seen_apps[@]}" | sort -u > "$cache_tmp"
            else
                : > "$cache_tmp"
            fi
            mv -f "$cache_tmp" "$cache_file" 2> /dev/null || rm -f "$cache_tmp" 2> /dev/null || true
        fi
    fi
}
