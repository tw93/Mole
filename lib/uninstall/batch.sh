#!/bin/bash

set -euo pipefail

# Ensure common.sh is loaded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -z "${MOLE_COMMON_LOADED:-}" ]] && source "$SCRIPT_DIR/lib/core/common.sh"

# Load Homebrew cask support (provides get_brew_cask_name, brew_uninstall_cask)
[[ -f "$SCRIPT_DIR/lib/uninstall/brew.sh" ]] && source "$SCRIPT_DIR/lib/uninstall/brew.sh"

# Load Steam launcher detection (identifies shortcut-only app bundles)
[[ -f "$SCRIPT_DIR/lib/uninstall/steam.sh" ]] && source "$SCRIPT_DIR/lib/uninstall/steam.sh"

# Batch uninstall with a single confirmation.

is_uninstall_dry_run() {
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]]
}

# High-performance sensitive data detection (pure Bash, no subprocess)
# Faster than grep for batch operations, especially when processing many apps
has_sensitive_data() {
    local files="$1"
    [[ -z "$files" ]] && return 1

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Use Bash native pattern matching (faster than spawning grep)
        case "$file" in
            */.warp* | */.config/* | */themes/* | */settings/* | */User\ Data/* | \
                */.ssh/* | */.gnupg/* | */Documents/* | */Preferences/*.plist | \
                */Desktop/* | */Downloads/* | */Movies/* | */Music/* | */Pictures/* | \
                */.password* | */.token* | */.auth* | */keychain* | \
                */Passwords/* | */Accounts/* | */Cookies/* | \
                */.aws/* | */.docker/config.json | */.kube/* | \
                */credentials/* | */secrets/*)
                return 0 # Found sensitive data
                ;;
        esac
    done <<< "$files"

    return 1 # Not found
}

# Decode and validate base64 file list (safe for set -e).
decode_file_list() {
    local encoded="$1"
    local app_name="$2"
    local decoded

    # macOS uses -D, GNU uses -d. Always return 0 for set -e safety.
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        if ! decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null); then
            log_error "Failed to decode file list for $app_name" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    fi

    if [[ "$decoded" =~ $'\0' ]]; then
        log_warning "File list for $app_name contains null bytes, rejecting" >&2
        echo ""
        return 0 # Return success with empty string
    fi

    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^/ ]]; then
            log_warning "Invalid path in file list for $app_name: $line" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    done <<< "$decoded"

    echo "$decoded"
    return 0
}

# Decode a base64 blob of login-item helper bundle ids. Unlike
# decode_file_list, the lines are bundle ids, not absolute paths, so the
# leading-slash check there would reject every id, print a misleading
# "Invalid path" warning, and blank the whole list, silently skipping the
# launchctl bootout of the app's login item helpers. Per-line validation
# stays in bootout_login_item_helpers via mole_is_reverse_dns_bundle_id.
decode_bundle_id_list() {
    local encoded="$1"
    local app_name="$2"
    local decoded

    # macOS uses -D, GNU uses -d. Always return 0 for set -e safety.
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        if ! decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null); then
            log_error "Failed to decode helper id list for $app_name" >&2
            echo ""
            return 0
        fi
    fi

    if [[ "$decoded" =~ $'\0' ]]; then
        log_warning "Helper id list for $app_name contains null bytes, rejecting" >&2
        echo ""
        return 0
    fi

    echo "$decoded"
    return 0
}
# Note: find_app_files() is in lib/core/app_protection.sh, calculate_total_size() is in lib/core/file_ops.sh.

# Only a background job that is still loaded in launchd, meaning the bootout
# was missed or failed, deserves a summary warning. BTM registration records
# are kept for uninstalled apps on purpose (they restore the user's
# enable/disable choice on a reinstall) and are pruned at the next login.
# Args: $1 - app bundle id, $2 - newline-separated helper bundle ids.
# Returns 0 when any of the labels is still loaded in the user's launchd
# domain. In test mode report "not loaded" so summaries stay quiet; unit
# tests exercise the real branch with MOLE_TEST_MODE=0 and a launchctl mock.
_uninstall_background_job_loaded() {
    local bundle_id="$1"
    local helper_ids="${2:-}"

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    local uid label
    uid=$(id -u)
    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        mole_is_reverse_dns_bundle_id "$label" || continue
        if launchctl print "gui/$uid/$label" > /dev/null 2>&1; then
            return 0
        fi
    done <<< "$(printf '%s\n%s\n' "$bundle_id" "$helper_ids")"

    return 1
}

# Emit the names of successfully-uninstalled apps that still have a background
# job loaded in launchd, meaning the bootout was missed or failed and the user
# must toggle it off manually. Deliberately does NOT consult sfltool dumpbtm:
# unprivileged dumpbtm pops the macOS "sfltool wants to make changes"
# admin-password dialog on every uninstall batch, and registered-but-unloaded
# BTM records are by-design residue macOS clears at next login.
# Args: <app_detail>... -- <success_path>...
# app_detail follows the pipe-encoded shape used inside batch_uninstall_applications.
_uninstall_match_loaded_background_items() {
    local -a details=()
    local -a success_paths=()
    local sep_seen=false
    local arg
    for arg in "$@"; do
        if [[ "$sep_seen" == false ]]; then
            if [[ "$arg" == "--" ]]; then
                sep_seen=true
            else
                details+=("$arg")
            fi
        else
            success_paths+=("$arg")
        fi
    done

    [[ ${#details[@]} -eq 0 || ${#success_paths[@]} -eq 0 ]] && return 0

    local detail app_name app_path bundle_id enc_helpers sp matched
    local _total_kb _encoded_files _encoded_system_files _has_sensitive_data
    local _needs_sudo _is_brew_cask _cask_name _encoded_diag_system
    local _encoded_review_system _sibling_guard _expected_app_identity
    local _original_bundle_id _encoded_live_sibling_fingerprint _expected_info_identity
    for detail in "${details[@]}"; do
        IFS='|' read -r app_name app_path bundle_id _total_kb _encoded_files _encoded_system_files \
            _has_sensitive_data _needs_sudo _is_brew_cask _cask_name _encoded_diag_system \
            _encoded_review_system enc_helpers _sibling_guard _expected_app_identity \
            _original_bundle_id _encoded_live_sibling_fingerprint \
            _expected_info_identity <<< "$detail"
        matched=false
        for sp in "${success_paths[@]}"; do
            [[ "$sp" == "$app_path" ]] && matched=true && break
        done
        [[ "$matched" != true ]] && continue

        # The sibling guard can demote bundle_id to "unknown" while helper ids
        # stay valid; _uninstall_background_job_loaded validates each label,
        # so no explicit unknown-skip is needed here.
        local helper_ids
        helper_ids=$(decode_bundle_id_list "${enc_helpers:-}" "$app_name")
        if _uninstall_background_job_loaded "$bundle_id" "$helper_ids"; then
            printf '%s\n' "$app_name"
        fi
    done
}

append_line() {
    local current="$1"
    local addition="$2"
    [[ -z "$addition" ]] && {
        printf '%s' "$current"
        return 0
    }
    if [[ -n "$current" ]]; then
        printf '%s\n%s' "$current" "$addition"
    else
        printf '%s' "$addition"
    fi
}

format_uninstall_preview_path() {
    local path="$1"
    # Replacement must come from a variable: bash 5.3+ tilde-expands a literal
    # unquoted ~ in the patsub replacement, turning this into a no-op.
    local tilde='~'
    local display_path="${path/#$HOME/$tilde}"
    local size_kb="0"
    local size_rc=0
    size_kb=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
    [[ $size_rc -eq 124 || $size_rc -ge 128 ]] && return "$size_rc"
    [[ $size_rc -eq 0 ]] || size_kb="0"

    if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
        printf '%s %s, %s%s' "$display_path" "$GRAY" "$(bytes_to_human "$((size_kb * 1024))")" "$NC"
    else
        printf '%s' "$display_path"
    fi
}

discover_login_item_helper_bundle_ids() {
    local app_path="$1"
    local login_items_root="$app_path/Contents/Library/LoginItems"
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE="${_MOLE_UNINSTALL_DISCOVERY_DEADLINE:-$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))}"
    [[ -d "$login_items_root" ]] || return 0

    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    _mole_uninstall_materialize_find0 "$scan_file" \
        "$login_items_root" -maxdepth 1 -iname "*.app" \
        -print0 || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    local helper info bundle_id
    local result_rc=0
    while IFS= read -r -d '' helper; do
        info="$helper/Contents/Info.plist"
        [[ -f "$info" ]] || continue
        local plist_rc=0
        local plist_timeout=""
        plist_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$_MOLE_UNINSTALL_DISCOVERY_DEADLINE") || plist_rc=$?
        if [[ $plist_rc -eq 0 ]]; then
            bundle_id=$(run_with_timeout "$plist_timeout" plutil \
                -extract CFBundleIdentifier raw "$info" \
                2> /dev/null) || plist_rc=$?
        fi
        if [[ $plist_rc -eq 124 || $plist_rc -ge 128 ]]; then
            result_rc=$plist_rc
            break
        fi
        if mole_is_reverse_dns_bundle_id "$bundle_id"; then
            printf '%s\n' "$bundle_id"
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ $result_rc -ne 0 ]]; then
        return "$result_rc"
    fi
    return 0
}

bootout_login_item_helpers() {
    local helper_ids="$1"
    [[ -n "$helper_ids" ]] || return 0
    if is_uninstall_dry_run || [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would bootout login item helpers"
        return 0
    fi

    local uid helper_id
    uid=$(id -u)
    while IFS= read -r helper_id; do
        [[ -n "$helper_id" ]] || continue
        mole_is_reverse_dns_bundle_id "$helper_id" || continue
        # A third-party helper's Info.plist could claim an Apple label; never
        # boot out the protected namespace regardless of what the bundle says.
        case "$helper_id" in
            com.apple.*) continue ;;
        esac
        local bootout_rc=0
        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" launchctl \
            bootout "gui/$uid/$helper_id" > /dev/null 2>&1 || bootout_rc=$?
        [[ $bootout_rc -eq 124 || $bootout_rc -ge 128 ]] && return "$bootout_rc"
    done <<< "$helper_ids"
    return 0
}

can_unload_launch_plist() {
    local plist="$1"
    [[ "$plist" == *.plist ]] || return 1
    case "$plist" in
        "$HOME"/Library/LaunchAgents/*.plist | /Library/LaunchAgents/*.plist | /Library/LaunchDaemons/*.plist) ;;
        *) return 1 ;;
    esac
    validate_path_for_deletion "$plist" > /dev/null 2>&1
}

unload_launch_plist() {
    local plist="$1"
    local needs_sudo="${2:-false}"
    local deadline="${3:-}"
    can_unload_launch_plist "$plist" || return 0
    local unload_timeout="$MOLE_TIMEOUT_MEDIUM_PROBE_SEC"
    if [[ -n "$deadline" ]]; then
        unload_timeout=$(_mole_timeout_with_deadline "$unload_timeout" \
            "$deadline") || return $?
    fi
    if [[ "$needs_sudo" == "true" ]]; then
        local unload_rc=0
        run_with_timeout "$unload_timeout" sudo launchctl \
            unload "$plist" > /dev/null 2>&1 || unload_rc=$?
    else
        local unload_rc=0
        run_with_timeout "$unload_timeout" launchctl \
            unload "$plist" > /dev/null 2>&1 || unload_rc=$?
    fi
    [[ $unload_rc -eq 124 || $unload_rc -ge 128 ]] && return "$unload_rc"
    return 0
}

_uninstall_unload_launch_plists() {
    local root="$1"
    local needs_sudo="$2"
    local bundle_id="${3:-}"
    local app_path="${4:-}"
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE="${_MOLE_UNINSTALL_DISCOVERY_DEADLINE:-$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))}"
    [[ -d "$root" ]] || return 0

    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    if [[ -n "$bundle_id" ]]; then
        _mole_uninstall_materialize_find0 "$scan_file" "$root" \
            -maxdepth 1 \( -name "${bundle_id}.plist" -o \
            -name "${bundle_id}.*.plist" \) -print0 || scan_rc=$?
    else
        _mole_uninstall_materialize_find0 "$scan_file" "$root" \
            -maxdepth 1 -name '*.plist' -print0 || scan_rc=$?
    fi
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    local plist
    local result_rc=0
    while IFS= read -r -d '' plist; do
        if [[ -n "$app_path" ]]; then
            local grep_rc=0
            local grep_timeout=""
            grep_timeout=$(_mole_timeout_with_deadline \
                "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                "$_MOLE_UNINSTALL_DISCOVERY_DEADLINE") || grep_rc=$?
            if [[ $grep_rc -eq 0 ]]; then
                run_with_timeout "$grep_timeout" grep -qF -- \
                    "$app_path" "$plist" 2> /dev/null || grep_rc=$?
            fi
            [[ $grep_rc -eq 124 || $grep_rc -ge 128 ]] && {
                result_rc=$grep_rc
                break
            }
            [[ $grep_rc -eq 0 ]] || continue
        fi
        local unload_rc=0
        unload_launch_plist "$plist" "$needs_sudo" \
            "$_MOLE_UNINSTALL_DISCOVERY_DEADLINE" || unload_rc=$?
        if [[ $unload_rc -eq 124 || $unload_rc -ge 128 ]]; then
            result_rc=$unload_rc
            break
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ $result_rc -ne 0 ]]; then
        return "$result_rc"
    fi
    return 0
}

# Unload Launch Agents/Daemons for an app.
# Plist deletion is owned by remove_file_list so every removal goes through the
# same validated path list and Trash/permanent deletion mode.
# Security: bundle_id is validated to be reverse-DNS format before use in find patterns
stop_launch_services() {
    local bundle_id="$1"
    local has_system_files="${2:-false}"
    local app_path="${3:-}"

    if is_uninstall_dry_run; then
        debug_log "[DRY RUN] Would unload launch services for bundle: $bundle_id"
        return 0
    fi

    # The bundle-id-keyed unloads below need a valid reverse-DNS id, but the
    # app-path scan further down does not, and it must still run when the
    # sibling guard demoted the bundle id to "unknown": name-globbed agent
    # plists are deleted by remove_file_list, and skipping the unload here
    # would leave their jobs loaded in launchd until logout.
    local bundle_id_usable=true
    if [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]]; then
        bundle_id_usable=false
    elif ! mole_is_reverse_dns_bundle_id "$bundle_id"; then
        # Validate bundle_id format: must be reverse-DNS style (e.g.,
        # com.example.app). This prevents glob injection attacks if bundle_id
        # contains special characters.
        debug_log "Invalid bundle_id format for LaunchAgent search: $bundle_id"
        bundle_id_usable=false
    fi

    if [[ "$bundle_id_usable" == "true" ]] && [[ -d ~/Library/LaunchAgents ]]; then
        _uninstall_unload_launch_plists \
            "$HOME/Library/LaunchAgents" false "$bundle_id" || return $?
    fi

    if [[ "$bundle_id_usable" == "true" && "$has_system_files" == "true" && "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
        if [[ -d /Library/LaunchAgents ]]; then
            _uninstall_unload_launch_plists \
                /Library/LaunchAgents true "$bundle_id" || return $?
        fi
        if [[ -d /Library/LaunchDaemons ]]; then
            _uninstall_unload_launch_plists \
                /Library/LaunchDaemons true "$bundle_id" || return $?
        fi
    fi

    # Scan for LaunchAgents whose ProgramArguments reference the app path.
    # Catches agents with bundle IDs that don't match the app's bundle ID.
    # Enumerate with find -print0 and probe each plist with grep -qF:
    # "grep -rlZ" is not portable on macOS (BSD grep treats -Z as
    # --decompress and prints newline-separated names), which left this scan
    # silently dead inside a NUL-delimited read loop.
    if [[ -n "$app_path" ]]; then
        if [[ -d ~/Library/LaunchAgents ]]; then
            _uninstall_unload_launch_plists \
                "$HOME/Library/LaunchAgents" false "" "$app_path" || return $?
        fi
        if [[ "$has_system_files" == "true" && "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
            if [[ -d /Library/LaunchAgents ]]; then
                _uninstall_unload_launch_plists \
                    /Library/LaunchAgents true "" "$app_path" || return $?
            fi
            if [[ -d /Library/LaunchDaemons ]]; then
                _uninstall_unload_launch_plists \
                    /Library/LaunchDaemons true "" "$app_path" || return $?
            fi
        fi
    fi
}

# Unregister app bundle from LaunchServices before deleting files.
# This helps remove stale app entries from Spotlight's app results list.
unregister_app_bundle() {
    local app_path="$1"

    [[ -n "$app_path" && -e "$app_path" ]] || return 0
    [[ "$app_path" == *.[aA][pP][pP] ]] || return 0

    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0

    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0

    local unregister_rc=0
    run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$lsregister" \
        -u "$app_path" > /dev/null 2>&1 || unregister_rc=$?
    [[ $unregister_rc -eq 124 || $unregister_rc -ge 128 ]] && return "$unregister_rc"
    return 0
}

# Compact LaunchServices after uninstall without forcing every app and extension
# to re-register. A domain-wide rebuild can terminate active app extensions,
# including Network Extension packet tunnels such as Shadowrocket's.
refresh_launch_services_after_uninstall() {
    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0

    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0

    # Best-effort and bounded: stale records are collected, while the targeted
    # -u call above handles the app bundle that was actually removed.
    run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" "$lsregister" -gc > /dev/null 2>&1 || true
    return 0
}

# Remove macOS Login Items for an app
remove_login_item() {
    local app_name="$1"
    local bundle_id="$2"

    if is_uninstall_dry_run; then
        debug_log "[DRY RUN] Would remove login item: ${app_name:-$bundle_id}"
        return 0
    fi

    # Skip if no identifiers provided
    [[ -z "$app_name" && -z "$bundle_id" ]] && return 0

    # Strip .app suffix if present (login items don't include it)
    local clean_name="${app_name%.[aA][pP][pP]}"

    # Remove from Login Items using index-based deletion (handles broken items)
    if [[ -n "$clean_name" ]]; then
        # Skip AppleScript during tests to avoid permission dialogs
        if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
            # Escape double quotes and backslashes for AppleScript
            local escaped_name="${clean_name//\\/\\\\}"
            escaped_name="${escaped_name//\"/\\\"}"

            local login_item_rc=0
            run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" osascript \
                > /dev/null 2>&1 <<- EOF || login_item_rc=$?
				tell application "System Events"
				    try
				        set itemCount to count of login items
				        -- Delete in reverse order to avoid index shifting
				        repeat with i from itemCount to 1 by -1
				            try
				                set itemName to name of login item i
				                if itemName is "$escaped_name" then
				                    delete login item i
				                end if
				            end try
				        end repeat
				    end try
				end tell
			EOF
            [[ $login_item_rc -eq 124 || $login_item_rc -ge 128 ]] && return "$login_item_rc"
        fi
    fi
}

# Remove files (handles symlinks, optional sudo).
# Security: All paths pass validate_path_for_deletion() before any deletion.
# Performance: when MOLE_DELETE_MODE=trash and the batch is sudo-free and
# symlink-free, eligible paths share one guarded helper invocation. The helper
# binds physical parent/target identities and uses direct Trash renames, avoiding
# Finder/AppleScript startup per item without trusting a stale lexical batch.
remove_file_list() {
    local file_list="$1"
    local use_sudo="${2:-false}"
    local count=0
    local mode="${MOLE_DELETE_MODE:-permanent}"

    local -a trash_batch=()
    local -a fallback_paths=()
    _MOLE_TRASH_BATCH_SNAPSHOT_PATHS=()
    _MOLE_TRASH_BATCH_SNAPSHOT_PARENTS=()
    _MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS=()
    _MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS=()

    while IFS= read -r file; do
        [[ -n "$file" && -e "$file" ]] || continue

        if ! validate_path_for_deletion "$file"; then
            continue
        fi

        if [[ "$use_sudo" == "true" ]] && is_uninstall_dry_run; then
            debug_log "[DRY RUN] Would sudo remove: $file"
            ((++count))
            continue
        fi

        # Symlinks, sudo-required paths, app bundles, and TCC-managed app data
        # stay on the per-file mole_delete path. The latter targets bypass
        # third-party Trash tools and Finder inside _mole_move_to_trash.
        if [[ "$mode" == "trash" && "$use_sudo" != "true" && ! -L "$file" ]] &&
            ! _mole_path_requires_direct_trash "$file" &&
            ! is_uninstall_dry_run; then
            if _mole_snapshot_path_identity "$file"; then
                trash_batch+=("$file")
                _MOLE_TRASH_BATCH_SNAPSHOT_PATHS+=("$file")
                _MOLE_TRASH_BATCH_SNAPSHOT_PARENTS+=("$_MOLE_PATH_SNAPSHOT_PARENT")
                _MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
                _MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
            else
                debug_log "Skipped Trash batch path with unstable identity: $file"
                log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$file" "path identity unavailable"
            fi
        else
            fallback_paths+=("$file")
        fi
    done <<< "$file_list"

    if [[ ${#trash_batch[@]} -gt 0 ]]; then
        local batch_rc=0
        _mole_move_to_trash_batch "${trash_batch[@]}" || batch_rc=$?
        if [[ $batch_rc -eq 0 && ${#_MOLE_TRASH_BATCH_MOVED_PATHS[@]} -eq 0 ]]; then
            # Test doubles and compatible older helpers report all-or-nothing
            # success without populating the optional moved-path ledger.
            _MOLE_TRASH_BATCH_MOVED_PATHS=("${trash_batch[@]}")
        fi
        local _bp _bsize
        if [[ ${#_MOLE_TRASH_BATCH_MOVED_PATHS[@]} -gt 0 ]]; then
            for _bp in "${_MOLE_TRASH_BATCH_MOVED_PATHS[@]}"; do
                _bsize="unknown"
                _mole_delete_log "trash" "$_bsize" "ok" "$_bp"
                log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "TRASHED" "$_bp" "batch"
                count=$((count + 1))
            done
        fi
        if [[ $batch_rc -ne 0 ]]; then
            # Do not hand paths whose identity changed to a second lexical sink.
            # A failed direct move leaves that item in place for manual review.
            debug_log "Trash batch stopped; unmoved paths were preserved"
        fi
        [[ $batch_rc -eq 124 || $batch_rc -ge 128 ]] && return "$batch_rc"
    fi

    if [[ ${#fallback_paths[@]} -gt 0 ]]; then
        local fb
        for fb in "${fallback_paths[@]}"; do
            # mole_delete routes through Trash when MOLE_DELETE_MODE=trash
            # (uninstall default) and only uses safe_* permanent removal when
            # the caller explicitly selected permanent mode. See #723.
            local delete_rc=0
            mole_delete "$fb" "$use_sudo" || delete_rc=$?
            [[ $delete_rc -eq 124 || $delete_rc -ge 128 ]] && return "$delete_rc"
            [[ $delete_rc -eq 0 ]] && count=$((count + 1))
        done
    fi

    echo "$count"
}

# Distinct installs can share one bundle id (Xcode.app and Xcode-beta.app are
# both com.apple.dt.Xcode). When a sibling install with the same bundle id
# stays on disk and is not part of the current selection, bundle-id-derived
# leftovers (caches, preferences, containers, launch services) still belong to
# the surviving install and must not be touched by this uninstall.
#
# Siblings under /Volumes/* count on purpose. Exact mirror clones never reach
# this check (the scan dedupe collapses same-basename rows and keeps the live
# path), so a /Volumes row here means a same-bundle app the scan considers a
# distinct install. Apps genuinely run from an external volume use the same
# $HOME bundle-id data, and skipping that data is the safe failure mode: worst
# case a few leftover files stay behind, versus deleting state a real install
# still uses.
# Reads apps_data and selected_apps from the caller's scope via dynamic
# scoping; both may be unset when batch.sh is exercised standalone in tests.
# Lowercase a bundle id for sibling comparison.
#
# Bundle ids are case-PRESERVING but not case-SENSITIVE for the paths a cask
# zap stanza and the name-derived cleanup actually touch: on a default APFS
# volume `~/Library/Preferences/com.Foo.Bar.plist` and `com.foo.bar.plist` are
# the same file. Comparing the ids literally therefore let a survivor whose id
# differs only in case slip the guard, and the uninstall then wiped the data
# both apps share.
#
# `LC_ALL=C tr` rather than `${var,,}`: this repo still supports bash 3.2.
uninstall_normalize_bundle_id() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# A preview-time inventory cannot authorize bundle-id teardown: an app may be
# mounted, installed, or copied into place while the confirmation screen is
# open. This bounded scan is deliberately stricter than UI discovery. Every
# root must complete, and every candidate bundle id must be readable, before
# absence is trusted.
_MOLE_UNINSTALL_LIVE_APP_ROOTS=(
    "/Applications"
    "$HOME/Applications"
    "/System/Applications"
    "/Library/Input Methods"
    "$HOME/Library/Input Methods"
    "$HOME/Library/Application Support/Setapp/Applications"
    "/opt/homebrew/Caskroom"
    "/usr/local/Caskroom"
)
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="/Volumes"

# A same-bundle scan that ran but could not read every path. Distinct from both
# success and failure on purpose: the listing it produced is real, so it can
# still prove a sibling exists, but it can never prove one does not. Callers
# must treat it as "a sibling may be there" and narrow the plan accordingly.
# 3 is safe to add to the 0/1/124/128+ set these scans already speak.
readonly MOLE_UNINSTALL_SCAN_PARTIAL=3

_uninstall_materialize_complete_find0() {
    local output_file="$1"
    local deadline_seconds="$2"
    shift 2

    : > "$output_file" || return 1
    local scan_timeout=""
    local scan_rc=0
    scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
        "$deadline_seconds") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        # Keep find's stderr. It is the only way to tell "could not read one
        # path" apart from "did not run": find exits 1 for an unreadable
        # subdirectory even though it traversed and printed everything else,
        # and macOS 26 hands out that error routinely under TCC. Discarding it
        # made every such run look like a dead scan, which aborted the whole
        # uninstall over a directory that had nothing to do with the app
        # (#1339, #1340).
        local scan_errors=""
        scan_errors=$(create_temp_file) || return 2
        run_with_timeout "$scan_timeout" find "$@" -print0 \
            < /dev/null > "$output_file" 2> "$scan_errors" || scan_rc=$?
        if [[ $scan_rc -eq 1 && -s "$scan_errors" ]]; then
            # Partial view: the listing is real but not exhaustive, so it can
            # support "something is there" and never "nothing is there".
            scan_rc="$MOLE_UNINSTALL_SCAN_PARTIAL"
        fi
        rm -f -- "$scan_errors" 2> /dev/null || true # SAFE: exact tracked temp file created above
    fi
    if [[ $scan_rc -ne 0 && $scan_rc -ne $MOLE_UNINSTALL_SCAN_PARTIAL ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
    return "$scan_rc"
}

_uninstall_live_candidate_is_selected() {
    local candidate="$1"
    local selected_path="$2"
    [[ "$candidate" == "$selected_path" ]] && return 0
    if [[ (-e "$candidate" || -L "$candidate") &&
        (-e "$selected_path" || -L "$selected_path") &&
        "$candidate" -ef "$selected_path" ]]; then
        return 0
    fi
    return 1
}

_uninstall_live_candidate_is_nested_app() {
    local root="$1"
    local candidate="$2"
    [[ "$candidate" == "$root" ]] && return 1
    local relative="${candidate#"$root"/}"
    [[ "$relative" != "$candidate" ]] || return 0
    local parent="${relative%/*}"
    [[ "$parent" != "$relative" ]] || return 1

    local component
    while [[ -n "$parent" && "$parent" != "." ]]; do
        component="${parent%%/*}"
        [[ "$component" == *.[aA][pP][pP] ]] && return 0
        [[ "$parent" == */* ]] || break
        parent="${parent#*/}"
    done
    return 1
}

# The most recent complete sibling scan. The fingerprint is a newline-separated,
# sorted set of base64(path):app-identity:Info.plist-identity records. Paths stay
# separately available so the preview can prove that every live sibling was
# represented in the inventory used to build its deletion plan.
_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
_MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()

_uninstall_insert_sorted_live_record() {
    local record="$1"
    local -a inserted=()
    local item
    local did_insert=false

    # shellcheck disable=SC2154 # live_records is provided by the caller via dynamic scope.
    for item in "${live_records[@]+"${live_records[@]}"}"; do
        [[ "$item" == "$record" ]] && return 0
        if [[ "$did_insert" == false && "$record" < "$item" ]]; then
            inserted+=("$record")
            did_insert=true
        fi
        inserted+=("$item")
    done
    [[ "$did_insert" == false ]] && inserted+=("$record")
    live_records=("${inserted[@]}")
}

_uninstall_live_sibling_path_is_duplicate() {
    local candidate="$1"
    local existing
    # shellcheck disable=SC2154 # live_paths is provided by the caller via dynamic scope.
    for existing in "${live_paths[@]+"${live_paths[@]}"}"; do
        [[ "$candidate" == "$existing" ]] && return 0
        if [[ (-e "$candidate" || -L "$candidate") &&
            (-e "$existing" || -L "$existing") &&
            "$candidate" -ef "$existing" ]]; then
            return 0
        fi
    done
    return 1
}

_uninstall_live_sibling_record() {
    local app="$1"
    local info="$2"
    local deadline_seconds="$3"
    local identity_timeout=""
    local identity_rc=0
    identity_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || identity_rc=$?

    local app_identity=""
    local info_identity=""
    if [[ $identity_rc -eq 0 ]]; then
        app_identity=$(run_with_timeout "$identity_timeout" "$STAT_BSD" \
            -f%d:%i:%m "$app" 2> /dev/null) || identity_rc=$?
    fi
    if [[ $identity_rc -eq 0 ]]; then
        identity_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || identity_rc=$?
    fi
    if [[ $identity_rc -eq 0 ]]; then
        info_identity=$(run_with_timeout "$identity_timeout" "$STAT_BSD" \
            -f%d:%i:%m "$info" 2> /dev/null) || identity_rc=$?
    fi
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$app_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 2
    [[ "$info_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 2

    local encoded_path=""
    encoded_path=$(printf '%s' "$app" | base64 | tr -d '\n') || return 2
    printf '%s:%s:%s\n' "$encoded_path" "$app_identity" "$info_identity"
}

_uninstall_materialize_complete_pkg_apps() {
    local output_file="$1"
    local deadline_seconds="$2"
    : > "$output_file" || return 2
    declare -f pkg_receipt_nonstandard_app_paths > /dev/null 2>&1 || return 2

    local remaining=""
    local remaining_rc=0
    remaining=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline_seconds") || remaining_rc=$?
    [[ $remaining_rc -eq 0 ]] || return "$remaining_rc"

    # Allow the on-disk receipt cache (#1383). A cold walk of every non-Apple
    # package on an Xcode machine can burn the whole discovery budget; the
    # cache is keyed by a 1h TTL and only stores nonstandard .app paths, which
    # is enough for the sibling check. A stale miss is still fail-closed:
    # timeout/incomplete paths degrade to MOLE_UNINSTALL_SCAN_PARTIAL and
    # narrow the plan rather than deleting shared leftovers.
    local producer_rc=0
    MOLE_PKG_RECEIPT_LIST_TIMEOUT="$remaining" \
        MOLE_PKG_RECEIPT_SCAN_TIMEOUT="$remaining" \
        pkg_receipt_nonstandard_app_paths \
        --require-complete > "$output_file" || producer_rc=$?
    if [[ $producer_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$producer_rc"
    fi
    return 0
}

_uninstall_collect_live_sibling_candidate() {
    local app="$1"
    local selected_path="$2"
    local bundle_id_lower="$3"
    local deadline_seconds="$4"
    local missing_info_is_unknown="$5"

    _uninstall_live_candidate_is_selected "$app" "$selected_path" && return 1
    local info="$app/Contents/Info.plist"
    if [[ ! -f "$info" ]]; then
        # iOS and iPadOS apps installed on Apple Silicon have no Contents/ at
        # all: the real plist sits at Wrapper/<name>.app/Info.plist. Reading
        # only the Contents/ path classified every one of them as unreadable,
        # and a single such app aborted the uninstall of every other app on
        # the machine (#1339). They are ordinary installs, not a mystery.
        local wrapped=""
        for wrapped in "$app"/Wrapper/*.[aA][pP][pP]/Info.plist; do
            if [[ -f "$wrapped" ]]; then
                info="$wrapped"
                break
            fi
        done
        if [[ ! -f "$info" ]]; then
            [[ "$missing_info_is_unknown" == true ]] && return 2
            return 1
        fi
    fi

    local plist_timeout=""
    local plist_rc=0
    plist_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || plist_rc=$?
    local app_bundle=""
    if [[ $plist_rc -eq 0 ]]; then
        app_bundle=$(run_with_timeout "$plist_timeout" plutil \
            -extract CFBundleIdentifier raw "$info" \
            2> /dev/null) || plist_rc=$?
    fi
    if [[ $plist_rc -ne 0 || -z "$app_bundle" ]]; then
        [[ $plist_rc -eq 124 || $plist_rc -ge 128 ]] && return "$plist_rc"
        # A plist that parses and simply carries no CFBundleIdentifier is a
        # complete answer, not a failed probe: vendor uninstallers and Steam
        # launchers ship bundles like that, and one with no id cannot share an
        # id with the target. Ask plutil whether the file parsed rather than
        # reading its exit code, which is 1 for a missing key, a corrupt file,
        # and an unreadable file alike (measured), or its message, which is
        # prose. Only a file that will not parse stays unknown.
        local lint_rc=0
        local lint_timeout=""
        if lint_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds"); then
            run_with_timeout "$lint_timeout" plutil -lint "$info" \
                > /dev/null 2>&1 || lint_rc=$?
            [[ $lint_rc -eq 124 || $lint_rc -ge 128 ]] && return "$lint_rc"
            [[ $lint_rc -eq 0 ]] && return 1
        fi
        return 2
    fi
    [[ "$(uninstall_normalize_bundle_id "$app_bundle")" == "$bundle_id_lower" ]] || return 1
    _uninstall_live_sibling_path_is_duplicate "$app" && return 1

    local live_record=""
    local record_rc=0
    live_record=$(_uninstall_live_sibling_record \
        "$app" "$info" "$deadline_seconds") || record_rc=$?
    [[ $record_rc -eq 0 ]] || return "$record_rc"
    # shellcheck disable=SC2154 # live_paths/live_records are caller-owned snapshot arrays.
    live_paths+=("$app")
    _uninstall_insert_sorted_live_record "$live_record"
    return 0
}

# Return 0 for one or more other live installs, 1 only for a complete
# proof of absence, 2 for incomplete/unknown state, and preserve signals.
# A deadline timeout degrades to MOLE_UNINSTALL_SCAN_PARTIAL: out of budget
# means the scan is incomplete, not that the user cancelled, and machine-wide
# work such as receipt enumeration can outlive the budget on a healthy Mac
# (#1340). A successful scan always refreshes the fingerprint globals.
uninstall_live_bundle_has_other_install() {
    local bundle_id="$1"
    local selected_path="$2"
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    mole_is_reverse_dns_bundle_id "$bundle_id" || return 1

    local deadline_seconds=$((SECONDS + (2 * MOLE_TIMEOUT_DISK_VERIFY_SEC)))
    local bundle_id_lower
    bundle_id_lower=$(uninstall_normalize_bundle_id "$bundle_id")
    local scan_indeterminate=false
    local scan_file=""
    scan_file=$(create_temp_file) || return 2
    local pkg_paths_file=""
    pkg_paths_file=$(create_temp_file) || {
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return 2
    }

    local pkg_scan_rc=0
    _uninstall_materialize_complete_pkg_apps "$pkg_paths_file" \
        "$deadline_seconds" || pkg_scan_rc=$?
    if [[ $pkg_scan_rc -eq 124 ]]; then
        # Receipt enumeration walks every pkgutil receipt on the machine, and
        # a single vendor receipt can hold tens of thousands of paths, so it
        # can outlive the budget on a healthy Mac (#1340). That is the same
        # doubt as an unreadable path: the receipts we did not reach may name
        # a sibling, so carry the doubt forward instead of ending the run.
        scan_indeterminate=true
    elif [[ $pkg_scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
        [[ $pkg_scan_rc -ge 128 ]] && return "$pkg_scan_rc"
        return 2
    fi

    local -a live_roots=()
    local configured_root
    for configured_root in "${_MOLE_UNINSTALL_LIVE_APP_ROOTS[@]+"${_MOLE_UNINSTALL_LIVE_APP_ROOTS[@]}"}"; do
        live_roots+=("$configured_root")
    done
    if [[ -d "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" ]]; then
        local volume_roots_file=""
        volume_roots_file=$(create_temp_file) || {
            rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
            return 2
        }
        local volume_scan_rc=0
        _uninstall_materialize_complete_find0 "$volume_roots_file" \
            "$deadline_seconds" "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" \
            -mindepth 2 -maxdepth 2 \
            \( \
            \( -type d -name Applications \) -o \
            \( \( -type d -o -type l \) -iname '*.app' \) \
            \) || volume_scan_rc=$?
        if [[ $volume_scan_rc -eq $MOLE_UNINSTALL_SCAN_PARTIAL || $volume_scan_rc -eq 124 ]]; then
            # Some volume was unreadable, or the budget ran out before every
            # volume was listed. Keep the roots we did see and carry the
            # doubt forward: absence can no longer be proven from here.
            scan_indeterminate=true
        elif [[ $volume_scan_rc -ne 0 ]]; then
            rm -f -- "$volume_roots_file" "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
            [[ $volume_scan_rc -ge 128 ]] && return "$volume_scan_rc"
            return 2
        fi
        local volume_root
        while IFS= read -r -d '' volume_root; do
            live_roots+=("$volume_root")
        done < "$volume_roots_file"
        rm -f -- "$volume_roots_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    fi

    local root app
    local -a live_records=()
    local -a live_paths=()
    local result=1
    for root in "${live_roots[@]+"${live_roots[@]}"}"; do
        [[ -e "$root" ]] || continue
        if [[ ! -d "$root" || ! -r "$root" ]]; then
            result=2
            break
        fi
        # Match the inventory's bounded app-root traversal. Receipt-backed
        # non-standard paths are supplied separately as exact candidates.
        local scan_rc=0
        _uninstall_materialize_complete_find0 "$scan_file" \
            "$deadline_seconds" "$root" -maxdepth 3 \
            \( -type d -o -type l \) -iname '*.app' || scan_rc=$?
        if [[ $scan_rc -eq $MOLE_UNINSTALL_SCAN_PARTIAL ]]; then
            # Unreadable subpaths under an app root. The apps this listing did
            # find are still real, so keep going and let the doubt decide the
            # verdict at the end rather than discarding the whole scan.
            scan_indeterminate=true
        elif [[ $scan_rc -ne 0 ]]; then
            [[ $scan_rc -eq 124 || $scan_rc -ge 128 ]] && result=$scan_rc || result=2
            break
        fi

        while IFS= read -r -d '' app; do
            # Nested helpers belong to their containing app, not a distinct
            # installation root.
            _uninstall_live_candidate_is_nested_app "$root" "$app" && continue
            local candidate_rc=0
            _uninstall_collect_live_sibling_candidate \
                "$app" "$selected_path" "$bundle_id_lower" \
                "$deadline_seconds" false || candidate_rc=$?
            if [[ $candidate_rc -eq 0 ]]; then
                result=0
            elif [[ $candidate_rc -ne 1 ]]; then
                [[ $candidate_rc -eq 124 || $candidate_rc -ge 128 ]] && result=$candidate_rc || result=2
                break
            fi
        done < "$scan_file"
        [[ $result -eq 2 || $result -eq 124 || $result -ge 128 ]] && break
    done

    if [[ $result -ne 2 && $result -ne 124 && $result -lt 128 ]]; then
        local pkg_app
        while IFS= read -r pkg_app; do
            [[ -n "$pkg_app" ]] || continue
            local candidate_rc=0
            _uninstall_collect_live_sibling_candidate \
                "$pkg_app" "$selected_path" "$bundle_id_lower" \
                "$deadline_seconds" true || candidate_rc=$?
            if [[ $candidate_rc -eq 0 ]]; then
                result=0
            elif [[ $candidate_rc -ne 1 ]]; then
                [[ $candidate_rc -eq 124 || $candidate_rc -ge 128 ]] && result=$candidate_rc || result=2
                break
            fi
        done < "$pkg_paths_file"
    fi

    rm -f -- "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
    if [[ $result -eq 0 ]]; then
        local IFS=$'\n'
        _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT="${live_records[*]}"
        _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=("${live_paths[@]}")
    fi
    # Absence is a claim only an exhaustive scan can make. A partial one that
    # found nothing means "not seen", which for a delete decision has to read
    # as "may exist" so the caller keeps the narrow plan.
    if [[ "$scan_indeterminate" == true && "$result" -eq 1 ]]; then
        result="$MOLE_UNINSTALL_SCAN_PARTIAL"
    fi
    # A per-root or per-candidate probe that ran out of budget is the same
    # incomplete scan, not a user cancellation: nothing above maps 124 to a
    # key press. Signals returned earlier stay untouched.
    if [[ "$result" -eq 124 ]]; then
        result="$MOLE_UNINSTALL_SCAN_PARTIAL"
    fi
    return "$result"
}

_uninstall_decode_live_sibling_fingerprint() {
    local encoded="$1"
    [[ -z "$encoded" ]] && return 0
    local decoded=""
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null) || return 1
    fi
    printf '%s' "$decoded"
}

_uninstall_live_fingerprint_without_successful_paths() {
    local fingerprint="$1"
    local record encoded_path decoded_path success_path
    local keep
    local output=""
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        encoded_path="${record%%:*}"
        decoded_path=""
        if ! decoded_path=$(printf '%s' "$encoded_path" | base64 -D 2> /dev/null); then
            decoded_path=$(printf '%s' "$encoded_path" | base64 -d 2> /dev/null) || return 1
        fi
        keep=true
        # shellcheck disable=SC2154 # success_items is owned by the batch executor via dynamic scope.
        for success_path in "${success_items[@]+"${success_items[@]}"}"; do
            if [[ "$decoded_path" == "$success_path" &&
                ! -e "$success_path" && ! -L "$success_path" ]]; then
                keep=false
                break
            fi
        done
        if [[ "$keep" == true ]]; then
            [[ -n "$output" ]] && output+=$'\n'
            output+="$record"
        fi
    done <<< "$fingerprint"
    printf '%s' "$output"
}

uninstall_bundle_id_has_surviving_sibling() {
    local bundle_id="$1"
    local app_path="$2"

    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 1

    local bundle_id_lower
    bundle_id_lower=$(uninstall_normalize_bundle_id "$bundle_id")

    local row other_path other_bundle other_bundle_lower
    # shellcheck disable=SC2154 # apps_data is provided by bin/uninstall.sh via dynamic scope.
    for row in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r _ other_path _ other_bundle _ _ _ <<< "$row"
        other_bundle_lower=$(uninstall_normalize_bundle_id "$other_bundle")
        [[ "$other_bundle_lower" == "$bundle_id_lower" ]] || continue
        [[ "$other_path" == "$app_path" ]] && continue
        [[ -d "$other_path" ]] || continue

        local sel selected_path is_selected=false
        for sel in "${selected_apps[@]+"${selected_apps[@]}"}"; do
            IFS='|' read -r _ selected_path _ _ _ _ <<< "$sel"
            if [[ "$selected_path" == "$other_path" ]]; then
                is_selected=true
                break
            fi
        done
        [[ "$is_selected" == true ]] && continue

        return 0
    done

    return 1
}

# Print the lowercased display names and .app basenames of every surviving
# same-bundle sibling (same filter as uninstall_bundle_id_has_surviving_sibling),
# one per line. Used to detect when the selected app's own names collide with
# the survivor's, in which case name-derived cleanup must be suppressed too.
uninstall_surviving_sibling_names() {
    local bundle_id="$1"
    local app_path="$2"

    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 0

    local bundle_id_lower
    bundle_id_lower=$(uninstall_normalize_bundle_id "$bundle_id")

    local row other_path other_name other_bundle other_bundle_lower
    for row in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r _ other_path other_name other_bundle _ _ _ <<< "$row"
        other_bundle_lower=$(uninstall_normalize_bundle_id "$other_bundle")
        [[ "$other_bundle_lower" == "$bundle_id_lower" ]] || continue
        [[ "$other_path" == "$app_path" ]] && continue
        [[ -d "$other_path" ]] || continue

        local sel selected_path is_selected=false
        for sel in "${selected_apps[@]+"${selected_apps[@]}"}"; do
            IFS='|' read -r _ selected_path _ _ _ _ <<< "$sel"
            if [[ "$selected_path" == "$other_path" ]]; then
                is_selected=true
                break
            fi
        done
        [[ "$is_selected" == true ]] && continue

        local other_base="${other_path##*/}"
        other_base="${other_base%.[aA][pP][pP]}"

        # Emit each identifier plus its version-suffix-stripped base: a
        # survivor named "Foo Beta.app" also claims "Foo"-keyed dirs via the
        # stripper in find_app_files, so uninstalling "Foo.app" must treat
        # "foo" as taken.
        local candidate
        for candidate in "$other_name" "$other_base"; do
            [[ -z "$candidate" ]] && continue
            printf '%s\n' "$candidate" | LC_ALL=C tr '[:upper:]' '[:lower:]'
            uninstall_strip_version_suffix "$candidate" | LC_ALL=C tr '[:upper:]' '[:lower:]'
        done
    done

    return 0
}

# Mirror of the version-suffix stripping inside find_app_files. Needed here
# because find_app_files derives extra patterns from the stripped base name
# ("Zed Nightly" also matches "Zed" paths), so a collision check against the
# survivor must consider the stripped form as well.
uninstall_strip_version_suffix() {
    local name="$1"
    local version_suffixes="Nightly|Beta|Alpha|Dev|Canary|Preview|Insider|Edge|Stable|Release|RC|LTS"
    version_suffixes+="|Developer Edition|Technology Preview"
    if [[ "$name" =~ ^(.+)[[:space:]]+(${version_suffixes})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$name"
    fi
}

# Internal helpers for batch_uninstall_applications. They read and write
# locals declared in the orchestrator's scope via bash dynamic scoping; do
# not call them outside batch_uninstall_applications.

# Phase 1: scan every selected app, classify into running/sudo/brew/blocked
# buckets, build pipe-encoded app_details records, accumulate the total
# estimated size, and warn about apps that require an official uninstaller or
# a manual Finder removal.
# Reads:  selected_apps
# Writes: running_apps, sudo_apps, brew_cask_apps, blocked_apps,
#         manual_removal_apps, app_details, total_estimated_size
_batch_refresh_selected_app_bundle_id() {
    local app_path="$1"
    local fallback_bundle_id="$2"

    [[ -d "$app_path" ]] || return 1
    if declare -f uninstall_resolve_eligible_bundle_id > /dev/null 2>&1; then
        uninstall_resolve_eligible_bundle_id "$app_path" "$fallback_bundle_id"
        return $?
    fi

    # Standalone module tests do not source the inventory resolver. Keep their
    # narrow fallback, while production always takes the eligibility path above.
    [[ -n "$fallback_bundle_id" ]] || return 1
    printf '%s\n' "$fallback_bundle_id"
}

_batch_selected_app_identity() {
    local app_path="$1"
    local identity=""
    local identity_rc=0
    identity=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$STAT_BSD" -f%d:%i:%m "$app_path" 2> /dev/null) || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$identity"
}

_batch_selected_app_info_identity() {
    local app_path="$1"
    local info="$app_path/Contents/Info.plist"
    if [[ ! -e "$info" && ! -L "$info" ]]; then
        printf '%s\n' "missing"
        return 0
    fi

    local identity=""
    local identity_rc=0
    identity=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$STAT_BSD" -f%d:%i:%m "$info" 2> /dev/null) || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$identity"
}

_batch_selected_app_plan_matches() {
    local app_path="$1"
    local expected_app_identity="$2"
    local expected_info_identity="$3"
    [[ -n "$expected_app_identity" && -n "$expected_info_identity" ]] || return 1

    local current_app_identity=""
    local current_info_identity=""
    local identity_rc=0
    current_app_identity=$(_batch_selected_app_identity \
        "$app_path") || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    current_info_identity=$(_batch_selected_app_info_identity \
        "$app_path") || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$current_app_identity" == "$expected_app_identity" &&
        "$current_info_identity" == "$expected_info_identity" ]]
}

_batch_scan_app_details() {
    # All selected-app discovery shares one wall-clock budget. Individual
    # producer probes clamp themselves to this deadline.
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE=$((SECONDS + (2 * MOLE_TIMEOUT_DISK_VERIFY_SEC)))
    # Cache current user outside loop
    local current_user=$(whoami)

    if [[ -t 1 ]]; then start_inline_spinner "Scanning files..."; fi
    # shellcheck disable=SC2154 # selected_apps is provided by batch_uninstall_applications via dynamic scope.
    for selected_app in "${selected_apps[@]}"; do
        [[ -z "$selected_app" ]] && continue
        IFS='|' read -r _ app_path app_name bundle_id _ _ <<< "$selected_app"

        local current_bundle_id=""
        local refresh_rc=0
        current_bundle_id=$(_batch_refresh_selected_app_bundle_id \
            "$app_path" "$bundle_id") || refresh_rc=$?
        if [[ $refresh_rc -ge 128 ]]; then
            return "$refresh_rc"
        elif [[ $refresh_rc -ne 0 ]]; then
            manual_removal_apps+=("$app_name")
            continue
        fi
        bundle_id="$current_bundle_id"
        local original_bundle_id="$bundle_id"

        # Bind the confirmation record to the exact bundle object that was
        # inspected. A path can be replaced while the preview is open; the
        # execution phase must reject that new inode instead of treating the
        # same pathname as user approval.
        local app_identity=""
        local app_identity_rc=0
        app_identity=$(_batch_selected_app_identity "$app_path") || app_identity_rc=$?
        if [[ $app_identity_rc -eq 124 || $app_identity_rc -ge 128 ]]; then
            return "$app_identity_rc"
        elif [[ $app_identity_rc -ne 0 ]]; then
            manual_removal_apps+=("$app_name")
            continue
        fi
        local app_info_identity=""
        local app_info_identity_rc=0
        app_info_identity=$(_batch_selected_app_info_identity \
            "$app_path") || app_info_identity_rc=$?
        if [[ $app_info_identity_rc -eq 124 || $app_info_identity_rc -ge 128 ]]; then
            return "$app_info_identity_rc"
        elif [[ $app_info_identity_rc -ne 0 ]]; then
            manual_removal_apps+=("$app_name")
            continue
        fi

        # Leftover matching is destructive and must use the current bundle
        # basename, not a display name cached when the selection list opened.
        local discovery_app_name="${app_path##*/}"
        discovery_app_name="${discovery_app_name%.[aA][pP][pP]}"

        local official_vendor=""
        if official_vendor=$(official_uninstaller_vendor "$bundle_id" "$app_name" "$app_path" 2> /dev/null); then
            blocked_apps+=("$app_name|$official_vendor")
            continue
        fi

        # Capture the complete same-bundle installation set that this preview
        # is based on. If a live sibling exists, current display names cannot
        # be trusted from the older inventory that opened the selection UI.
        # Narrow the plan to the selected app bundle only: no bundle-id/name
        # leftovers, login item, process, helper, or Homebrew zap teardown.
        # Execution compares the exact snapshot before its first side effect.
        local live_sibling_rc=0
        local live_sibling_present=false
        uninstall_live_bundle_has_other_install \
            "$original_bundle_id" "$app_path" || live_sibling_rc=$?
        if [[ $live_sibling_rc -eq 0 ]]; then
            live_sibling_present=true
        elif [[ $live_sibling_rc -eq 1 ]]; then
            : # Complete absence proof; the empty fingerprint is authoritative.
        elif [[ $live_sibling_rc -eq $MOLE_UNINSTALL_SCAN_PARTIAL ]]; then
            # The scan ran but could not read every path, so it cannot rule a
            # sibling out. Treat that exactly like finding one: narrow the plan
            # and keep going. Aborting here is what left `mo uninstall` exiting
            # 1 with a debug-only line for apps whose scan touched anything TCC
            # protects (#1339, #1340).
            live_sibling_present=true
            log_warning "$(printf "%s: some paths could not be read, so shared leftovers are left in place" "$app_name")"
        elif [[ $live_sibling_rc -ge 128 ]]; then
            return "$live_sibling_rc"
        else
            # This refusal ends the whole batch, so it must say so on the
            # normal screen: the debug-only line left users with a silent
            # exit and no way to report the cause (#1340).
            log_error "Could not verify whether other installs share ${app_name}'s bundle id; nothing was removed"
            debug_log "Could not complete the live same-bundle scan for $app_name"
            return 1
        fi
        local preview_live_sibling_fingerprint="$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT"

        # Receipt enumeration is machine-wide and can consume the whole shared
        # discovery budget on an Xcode Mac (#1383). Guarantee a minimum floor
        # for the selected-app remnant walk so a long sibling scan cannot
        # starve leftover matching and hard-abort the batch with 124.
        local remnant_floor=$((SECONDS + MOLE_TIMEOUT_HINT_SCAN_SEC))
        if ((_MOLE_UNINSTALL_DISCOVERY_DEADLINE < remnant_floor)); then
            debug_log "Extending uninstall discovery deadline by ${MOLE_TIMEOUT_HINT_SCAN_SEC}s for remnant scan of $app_name"
            _MOLE_UNINSTALL_DISCOVERY_DEADLINE=$remnant_floor
        fi

        local sibling_guard="none"
        if [[ "$live_sibling_present" == true ]]; then
            sibling_guard="guard_login"
            discovery_app_name=""
            debug_log "Bundle id $bundle_id is shared with a live sibling; removing only the selected app bundle for $app_name"
            bundle_id="unknown"
        elif uninstall_bundle_id_has_surviving_sibling "$bundle_id" "$app_path"; then
            sibling_guard="guard"

            local survivor_names
            survivor_names=$(uninstall_surviving_sibling_names "$bundle_id" "$app_path")
            local discovery_lower discovery_base_lower display_lower
            discovery_lower=$(printf '%s' "$discovery_app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            discovery_base_lower=$(uninstall_strip_version_suffix "$discovery_app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            display_lower=$(printf '%s' "$app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')

            local survivor_name login_name_collides=false
            while IFS= read -r survivor_name; do
                [[ -z "$survivor_name" ]] && continue
                # Equality catches the display-name collapse. The substring
                # direction catches the inverse case: uninstalling "Foo.app"
                # while "Foo-beta.app" survives. Downstream matchers are
                # substring-based (the LaunchAgents scan globs
                # "*<name>*.plist"), so a discovery name contained anywhere
                # in a survivor identifier can still reach survivor data.
                # Reverse containment (survivor inside discovery) stays
                # allowed: patterns keyed on the longer "Foo-beta" cannot
                # match the survivor's shorter "Foo"-keyed paths.
                if [[ "$discovery_lower" == "$survivor_name" || "$discovery_base_lower" == "$survivor_name" ||
                    "$survivor_name" == *"$discovery_lower"* || "$survivor_name" == *"$discovery_base_lower"* ]]; then
                    discovery_app_name=""
                fi
                # Login items are registered under the display name; when that
                # string also belongs to the survivor, deleting it by name
                # would remove the survivor's login item.
                if [[ "$display_lower" == "$survivor_name" ]]; then
                    login_name_collides=true
                fi
            done <<< "$survivor_names"
            if [[ -z "$discovery_app_name" ]]; then
                login_name_collides=true
            fi
            [[ "$login_name_collides" == true ]] && sibling_guard="guard_login"

            if [[ -n "$discovery_app_name" ]]; then
                debug_log "Bundle id $bundle_id shared with a surviving install; restricting $app_name leftovers to name/path matches for '$discovery_app_name'"
            else
                debug_log "Bundle id $bundle_id shared with a surviving install and names collide; removing only the app bundle for $app_name"
            fi
            bundle_id="unknown"
        fi

        # Check running app by bundle executable if available
        local exec_name=""
        local info_plist="$app_path/Contents/Info.plist"
        if [[ -e "$info_plist" ]]; then
            exec_name=$(plutil -extract CFBundleExecutable raw "$info_plist" 2> /dev/null || echo "")
        fi
        if pgrep -qx "${exec_name:-$app_name}" 2> /dev/null; then
            running_apps+=("$app_name")
        fi

        local cask_name="" is_brew_cask="false"
        if command -v get_brew_cask_name > /dev/null 2>&1; then
            local detected_cask=""
            local cask_detect_rc=0
            detected_cask=$(get_brew_cask_name "$app_path" 2> /dev/null) || cask_detect_rc=$?
            if [[ $cask_detect_rc -eq 124 || $cask_detect_rc -ge 128 ]]; then
                return "$cask_detect_rc"
            elif [[ $cask_detect_rc -ne 0 && $cask_detect_rc -ne 1 ]]; then
                return "$cask_detect_rc"
            fi
            if [[ -n "$detected_cask" ]]; then
                cask_name="$detected_cask"
                is_brew_cask="true"
            fi
        fi

        if [[ "$is_brew_cask" == "true" ]]; then
            brew_cask_apps+=("$app_name")
        fi

        # A Trash rename is authorized by the source and destination parents,
        # not by the app bundle's owner. Do not elevate solely because a
        # package-installed app is root-owned when its parent is user-writable;
        # file_ops can retry a TCC-blocked rename through unprivileged Finder.
        # Permanent removal still treats foreign ownership as requiring sudo.
        local needs_sudo=false
        local app_owner=$(get_file_owner "$app_path")
        local delete_mode="${MOLE_DELETE_MODE:-permanent}"
        if [[ ! -w "$(dirname "$app_path")" ]] ||
            { [[ "$delete_mode" != "trash" ]] &&
                { [[ "$app_owner" == "root" ]] ||
                    [[ -n "$app_owner" && "$app_owner" != "$current_user" ]]; }; }; then
            needs_sudo=true
        fi

        # A privileged path-based removal below an invoking-user-mutable
        # ancestor cannot bind the path we previewed to the object root later
        # removes. Reject it before leftover discovery, sudo authorization, or
        # any launch/login/process teardown. Homebrew casks stay on their
        # package-manager path and never use this direct-app preflight.
        if [[ "$needs_sudo" == true && "$is_brew_cask" != "true" ]] &&
            _mole_privileged_path_has_mutable_ancestor "$app_path"; then
            manual_removal_apps+=("$app_name")
            continue
        fi

        local app_size_kb="0"
        local app_size_rc=0
        app_size_kb=$(get_path_size_kb "$app_path") || app_size_rc=$?
        [[ $app_size_rc -eq 124 || $app_size_rc -ge 128 ]] && return "$app_size_rc"
        [[ $app_size_rc -eq 0 && "$app_size_kb" =~ ^[0-9]+$ ]] || app_size_kb=0
        local related_files="" diag_user="" diag_system=""
        # system_files is a newline-separated string, not an array.
        # shellcheck disable=SC2178,SC2128
        local system_files=""
        # discovery_app_name is empty only in the sibling-guard name-collision
        # case: every name-derived pattern would belong to the survivor, and
        # find_app_system_files has no empty-name guard (it would emit root
        # dirs like "/Library/Application Support/"). Skip discovery entirely
        # and remove just the app bundle.
        if [[ -n "$discovery_app_name" ]]; then
            # Under the sibling guard, also disable the regex-keyed toolchain
            # heuristics in find_app_files (DerivedData, DeviceSupport, ...):
            # they match "Xcode-beta" by substring and would still queue
            # caches the surviving install uses.
            local sibling_survives=0
            [[ "$sibling_guard" != "none" ]] && sibling_survives=1
            local discovery_rc=0
            related_files=$(MOLE_UNINSTALL_SIBLING_SURVIVES="$sibling_survives" \
                find_app_files "$bundle_id" "$discovery_app_name" \
                "$app_path") || discovery_rc=$?
            if [[ $discovery_rc -eq 124 ]]; then
                # Out of budget after a heavy machine-wide probe (#1383): keep
                # the selected app removable and leave leftovers alone rather
                # than aborting the whole batch with "nothing was removed".
                related_files=""
                log_warning "$(printf "%s: leftover scan timed out; only the app bundle will be removed" "$app_name")"
            elif [[ $discovery_rc -ne 0 ]]; then
                return "$discovery_rc"
            fi
            # Diagnostic-report discovery prefers CFBundleExecutable from the
            # selected bundle, and same-bundle-id siblings ship the same
            # executable name ("Xcode" for Xcode-beta.app), so under the
            # guard it would collect the survivor's crash reports no matter
            # which name is passed in. Leaving crash logs behind is the
            # fail-safe direction. Skip follow-on probes when leftover
            # discovery already timed out so we do not burn the floor budget.
            if [[ "$sibling_guard" == "none" && $discovery_rc -ne 124 ]]; then
                local diag_rc=0
                diag_user=$(get_diagnostic_report_paths_for_app "$app_path" \
                    "$discovery_app_name" \
                    "$HOME/Library/Logs/DiagnosticReports") || diag_rc=$?
                if [[ $diag_rc -eq 124 ]]; then
                    diag_user=""
                    debug_log "Diagnostic report scan timed out for $app_name"
                elif [[ $diag_rc -ne 0 ]]; then
                    return "$diag_rc"
                fi
                [[ -n "$diag_user" ]] && related_files=$(
                    [[ -n "$related_files" ]] && echo "$related_files"
                    echo "$diag_user"
                )
                diag_rc=0
                diag_system=$(get_diagnostic_report_paths_for_app "$app_path" \
                    "$discovery_app_name" "/Library/Logs/DiagnosticReports") || diag_rc=$?
                if [[ $diag_rc -eq 124 ]]; then
                    diag_system=""
                    debug_log "System diagnostic report scan timed out for $app_name"
                elif [[ $diag_rc -ne 0 ]]; then
                    return "$diag_rc"
                fi
            fi
            if [[ $discovery_rc -ne 124 ]]; then
                local system_rc=0
                system_files=$(find_app_system_files \
                    "$bundle_id" "$discovery_app_name") || system_rc=$?
                if [[ $system_rc -eq 124 ]]; then
                    system_files=""
                    debug_log "System leftover scan timed out for $app_name"
                elif [[ $system_rc -ne 0 ]]; then
                    return "$system_rc"
                fi
            fi
        fi
        local related_size_kb="0"
        local related_size_rc=0
        related_size_kb=$(calculate_total_size "$related_files") || related_size_rc=$?
        if [[ $related_size_rc -eq 124 ]]; then
            # Size is display-only here; keep the leftover plan and under-report.
            related_size_kb=0
            debug_log "Related-file size probe timed out for $app_name"
        elif [[ $related_size_rc -ge 128 ]]; then
            return "$related_size_rc"
        fi
        [[ $related_size_rc -eq 0 && "$related_size_kb" =~ ^[0-9]+$ ]] || related_size_kb=0
        local review_only_system_files="$system_files"
        review_only_system_files=$(append_line "$review_only_system_files" "$diag_system")
        # System-level remnants are review-only in the CLI: shown in the preview
        # via review_only_system_files (encoded into encoded_review_system) but
        # never deleted. Blanking system_files/diag_system here is what enforces
        # that: _batch_execute_removals decodes the now-empty encoded_system_files
        # and encoded_diag_system fields and therefore skips them. Do NOT remove
        # this blanking, or system files would become deletable again.
        system_files=""
        diag_system=""
        local total_kb=$((app_size_kb + related_size_kb))
        total_estimated_size=$((total_estimated_size + total_kb))

        if [[ "$needs_sudo" == "true" ]]; then
            sudo_apps+=("$app_name")
        fi

        # Check for sensitive user data once.
        local has_sensitive_data="false"
        local sensitive_rc=0
        has_sensitive_data "$related_files" 2> /dev/null || sensitive_rc=$?
        if [[ $sensitive_rc -eq 0 ]]; then
            has_sensitive_data="true"
        elif [[ $sensitive_rc -eq 124 || $sensitive_rc -ge 128 ]]; then
            return "$sensitive_rc"
        fi

        # Store details for later use (base64 keeps lists on one line).
        local encoded_files
        encoded_files=$(printf '%s' "$related_files" | base64 | tr -d '\n' || echo "")
        local encoded_system_files
        encoded_system_files=$(printf '%s' "$system_files" | base64 | tr -d '\n' || echo "")
        local encoded_diag_system
        encoded_diag_system=$(printf '%s' "$diag_system" | base64 | tr -d '\n' || echo "")
        local encoded_review_system
        encoded_review_system=$(printf '%s' "$review_only_system_files" | base64 | tr -d '\n' || echo "")
        local login_item_helpers=""
        local login_helpers_rc=0
        login_item_helpers=$(discover_login_item_helper_bundle_ids \
            "$app_path") || login_helpers_rc=$?
        if [[ $login_helpers_rc -eq 124 ]]; then
            login_item_helpers=""
            debug_log "Login-item helper discovery timed out for $app_name"
        elif [[ $login_helpers_rc -ne 0 ]]; then
            return "$login_helpers_rc"
        fi
        local encoded_login_item_helpers
        encoded_login_item_helpers=$(printf '%s' "$login_item_helpers" | base64 | tr -d '\n' || echo "")
        local encoded_live_sibling_fingerprint
        encoded_live_sibling_fingerprint=$(printf '%s' "$preview_live_sibling_fingerprint" | base64 | tr -d '\n') || return 1
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files|$encoded_system_files|$has_sensitive_data|$needs_sudo|$is_brew_cask|$cask_name|$encoded_diag_system|$encoded_review_system|$encoded_login_item_helpers|$sibling_guard|$app_identity|$original_bundle_id|$encoded_live_sibling_fingerprint|$app_info_identity")
    done
    if [[ -t 1 ]]; then stop_inline_spinner; fi

    if [[ ${#blocked_apps[@]} -gt 0 ]]; then
        local blocked_detail blocked_name blocked_vendor
        for blocked_detail in "${blocked_apps[@]}"; do
            IFS='|' read -r blocked_name blocked_vendor <<< "$blocked_detail"
            log_warning "$blocked_name requires the official $blocked_vendor uninstaller"
        done
    fi

    if [[ ${#manual_removal_apps[@]} -gt 0 ]]; then
        local manual_name
        for manual_name in "${manual_removal_apps[@]}"; do
            log_warning "$manual_name cannot be removed safely by Mole from this location"
            log_info "Move it to Trash in Finder; Mole left protected containers and app data untouched"
        done
    fi
}

# Phase 2+3: render the preview block listing every target with its size
# and per-file breakdown, prompt the user for confirmation, and establish
# a sudo session when admin access is needed. Returns:
#   0 - user confirmed and (if needed) sudo session established
#   2 - user cancelled (ESC / 'q' / unknown key)
#   1 - sudo authorization denied
# Reads:  app_details, brew_cask_apps, running_apps, sudo_apps,
#         total_estimated_size
_batch_preview_and_confirm() {
    local size_display=$(bytes_to_human "$((total_estimated_size * 1024))")

    echo -e "\n${PURPLE_BOLD}Files to be removed:${NC}"

    # Warn if brew cask apps are present. The --zap wording only applies to
    # casks that will actually zap; sibling-guarded casks run a plain
    # uninstall so their shared configs and data stay.
    local has_zap_cask=false
    local zap_detail zap_is_brew zap_guard
    for zap_detail in "${app_details[@]}"; do
        IFS='|' read -r _ _ _ _ _ _ _ _ zap_is_brew _ _ _ _ zap_guard _ <<< "$zap_detail"
        if [[ "$zap_is_brew" == "true" && "${zap_guard:-none}" == "none" ]]; then
            has_zap_cask=true
            break
        fi
    done

    if [[ "$has_zap_cask" == "true" ]]; then
        echo -e "${GRAY}${ICON_WARNING} Homebrew apps will be fully cleaned, --zap removes configs and data${NC}"
    fi

    echo ""

    for detail in "${app_details[@]}"; do
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files has_sensitive_data needs_sudo_flag is_brew_cask cask_name encoded_diag_system encoded_review_system encoded_login_item_helpers sibling_guard _expected_app_identity _original_bundle_id _encoded_live_sibling_fingerprint _expected_info_identity <<< "$detail"
        local app_size_display=$(bytes_to_human "$((total_kb * 1024))")

        local brew_tag=""
        [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
        local steam_managed=false
        if uninstall_app_is_steam_launcher "$app_path"; then
            steam_managed=true
            app_size_display="N/A (Steam-managed)"
        fi
        echo -e "${BLUE}${ICON_CONFIRM}${NC} ${app_name}${brew_tag} ${GRAY}, ${app_size_display}${NC}"

        # Show detailed file list for ALL apps (brew casks leave user data behind)
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local diag_system_display
        diag_system_display=$(decode_file_list "$encoded_diag_system" "$app_name")
        local review_system_display
        review_system_display=$(decode_file_list "$encoded_review_system" "$app_name")
        [[ -n "$diag_system_display" ]] && system_files=$(
            [[ -n "$system_files" ]] && echo "$system_files"
            echo "$diag_system_display"
        )

        if [[ "$steam_managed" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Steam launcher only; game files managed by Steam are not included"
        fi

        local preview_path=""
        preview_path=$(format_uninstall_preview_path "$app_path") || return $?
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $preview_path"

        # Show all related files so users can fully review before deletion.
        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                preview_path=$(format_uninstall_preview_path "$file") || return $?
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $preview_path"
            fi
        done <<< "$related_files"

        # Show all system files so users can fully review before deletion.
        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                preview_path=$(format_uninstall_preview_path "$file") || return $?
                echo -e "  ${BLUE}${ICON_WARNING}${NC} System: $preview_path"
            fi
        done <<< "$system_files"

        while IFS= read -r file; do
            if [[ -n "$file" && -e "$file" ]]; then
                preview_path=$(format_uninstall_preview_path "$file") || return $?
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Review only: $preview_path"
            fi
        done <<< "$review_system_display"
    done

    # Confirmation before requesting sudo.
    local app_total=${#app_details[@]}
    local app_text="app"
    [[ $app_total -gt 1 ]] && app_text="apps"

    echo ""
    local removal_note="Remove ${app_total} ${app_text}"
    [[ -n "$size_display" ]] && removal_note+=", ${size_display}"
    if [[ ${#running_apps[@]} -gt 0 ]]; then
        removal_note+=" ${YELLOW}[Running]${NC}"
    fi
    echo -ne "${PURPLE}${ICON_ARROW}${NC} ${removal_note}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    drain_pending_input # Clean up any pending input before confirmation
    IFS= read -r -s -n1 key || key=""
    drain_pending_input # Clean up any escape sequence remnants
    case "$key" in
        $'\e' | q | Q)
            echo ""
            echo ""
            return 2
            ;;
        "" | $'\n' | $'\r' | y | Y)
            echo "" # Move to next line
            ;;
        *)
            echo ""
            echo ""
            return 2
            ;;
    esac

    # Enable uninstall mode - allows deletion of data-protected apps (VPNs, dev tools, etc.)
    # that user explicitly chose to uninstall. System-critical components remain protected.
    export MOLE_UNINSTALL_MODE=1

    # Establish sudo once before uninstalling apps that need admin access.
    # Homebrew cask removal can prompt via sudo during uninstall hooks, which
    # does not work reliably under Mole's timed non-interactive execution path.
    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]] &&
        { [[ ${#sudo_apps[@]} -gt 0 ]] || [[ ${#brew_cask_apps[@]} -gt 0 ]]; }; then
        local admin_prompt="Admin required to uninstall selected apps"
        if [[ ${#sudo_apps[@]} -gt 0 && ${#brew_cask_apps[@]} -eq 0 ]]; then
            admin_prompt="Admin required for system apps: ${sudo_apps[*]}"
        elif [[ ${#brew_cask_apps[@]} -gt 0 && ${#sudo_apps[@]} -eq 0 ]]; then
            admin_prompt="Admin required for Homebrew casks: ${brew_cask_apps[*]}"
        fi

        if ! ensure_sudo_session "$admin_prompt"; then
            echo ""
            log_error "Admin access denied"
            return 1
        fi
    fi
}

# Phase 4: iterate app_details and perform the actual removal for each.
# Tracks per-app failures, warnings (system extensions, still-running
# processes, container leftovers), and the total bytes
# actually freed. Per-app failures do not halt the loop; the surrounding
# trap still terminates the whole pass on SIGINT/SIGTERM.
# Reads:  app_details
# Writes: success_count, failed_count, failed_items, success_items,
#         success_dock_targets, system_extension_warning_apps,
#         review_only_system_leftovers,
#         review_only_system_leftover_keys, running_at_uninstall_apps,
#         total_size_freed, brew_apps_removed,
#         files_cleaned, total_items (the latter two via dynamic scope)
_batch_execute_removals() {
    # See format_uninstall_preview_path: literal ~ in a patsub replacement is
    # tilde-expanded by bash 5.3+, so route it through a variable.
    local tilde_display='~'
    local current_index=0
    for detail in "${app_details[@]}"; do
        current_index=$((current_index + 1))
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system encoded_review_system encoded_login_item_helpers sibling_guard expected_app_identity original_bundle_id encoded_live_sibling_fingerprint expected_info_identity <<< "$detail"
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local diag_system=$(decode_file_list "$encoded_diag_system" "$app_name")
        local review_only_system_files=$(decode_file_list "$encoded_review_system" "$app_name")
        local login_item_helpers=$(decode_bundle_id_list "$encoded_login_item_helpers" "$app_name")
        local reason=""
        local suggestion=""

        # Show progress before the pre-teardown verification, not after: the
        # same-bundle re-scan below can take tens of seconds on a large
        # receipt set, and silence right after the Enter confirm reads as a
        # dead prompt (#1340 family). Every downstream path already runs with
        # this spinner active and stops it before printing.
        local brew_tag=""
        [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
        if [[ -t 1 ]]; then
            if [[ ${#app_details[@]} -gt 1 ]]; then
                start_inline_spinner "[$current_index/${#app_details[@]}] Uninstalling ${app_name}${brew_tag}..."
            else
                start_inline_spinner "Uninstalling ${app_name}${brew_tag}..."
            fi
        fi

        local app_plan_rc=0
        _batch_selected_app_plan_matches "$app_path" \
            "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
        if [[ $app_plan_rc -eq 124 || $app_plan_rc -ge 128 ]]; then
            return "$app_plan_rc"
        elif [[ $app_plan_rc -ne 0 ]]; then
            reason="selected app changed after preview"
            suggestion="Select the app again and review the new removal plan"
        fi

        # Rebuild the exact same-bundle installation snapshot immediately
        # before the first teardown side effect. This uses the original
        # resolved id even when the preview demoted bundle_id to "unknown" to
        # suppress shared leftovers. Any added, removed, replaced, or modified
        # sibling invalidates both the name guard and the reviewed plan.
        original_bundle_id="${original_bundle_id:-$bundle_id}"
        if [[ -z "$reason" ]] && mole_is_reverse_dns_bundle_id "$original_bundle_id"; then
            local preview_live_sibling_fingerprint=""
            if ! preview_live_sibling_fingerprint=$(
                _uninstall_decode_live_sibling_fingerprint \
                    "${encoded_live_sibling_fingerprint:-}"
            ); then
                reason="unable to verify the reviewed app installation set"
                suggestion="Select the app again and review the new removal plan"
            elif ! preview_live_sibling_fingerprint=$(
                _uninstall_live_fingerprint_without_successful_paths \
                    "$preview_live_sibling_fingerprint"
            ); then
                reason="unable to verify the reviewed app installation set"
                suggestion="Select the app again and review the new removal plan"
            fi

            local live_sibling_rc=0
            uninstall_live_bundle_has_other_install \
                "$original_bundle_id" "$app_path" || live_sibling_rc=$?
            if [[ $live_sibling_rc -eq 0 || $live_sibling_rc -eq 1 ]]; then
                if [[ "$preview_live_sibling_fingerprint" != "$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT" ]]; then
                    reason="the app installation set changed after preview"
                    suggestion="Select the app again and review the new removal plan"
                fi
            elif [[ $live_sibling_rc -eq $MOLE_UNINSTALL_SCAN_PARTIAL &&
                "$sibling_guard" == "guard_login" &&
                -z "$encoded_files" ]]; then
                # The preview already narrowed this plan to the selected app
                # bundle alone because the scan could not prove absence. The
                # re-check hitting the same doubt confirms that state rather
                # than contradicting it, and a plan with no shared teardown
                # has nothing a live sibling could lose. Refusing here is what
                # made a deterministically slow or unreadable machine unable
                # to uninstall anything at all (#1340). guard_login alone is
                # not that proof: the surviving-sibling name-collision path
                # sets it while keeping name-keyed leftovers, so the empty
                # deletion list is the evidence that authorizes proceeding.
                :
            elif [[ $live_sibling_rc -ge 128 ]]; then
                return "$live_sibling_rc"
            else
                reason="unable to verify other apps with the same bundle id"
                suggestion="Check mounted volumes and application folders, then try again"
            fi
        fi

        # Stop Launch Agents/Daemons before removal.
        local has_system_files="false"
        [[ -n "$system_files" ]] && has_system_files="true"

        if [[ -z "$reason" ]]; then
            app_plan_rc=0
            _batch_selected_app_plan_matches "$app_path" \
                "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
            if [[ $app_plan_rc -eq 124 || $app_plan_rc -ge 128 ]]; then
                return "$app_plan_rc"
            elif [[ $app_plan_rc -ne 0 ]]; then
                reason="selected app changed after preview"
                suggestion="Select the app again and review the new removal plan"
            fi
        fi

        if [[ -z "$reason" ]]; then
            local teardown_rc=0
            stop_launch_services \
                "$bundle_id" "$has_system_files" "$app_path" || teardown_rc=$?
            [[ $teardown_rc -eq 124 || $teardown_rc -ge 128 ]] && return "$teardown_rc"
            teardown_rc=0
            unregister_app_bundle "$app_path" || teardown_rc=$?
            [[ $teardown_rc -eq 124 || $teardown_rc -ge 128 ]] && return "$teardown_rc"
        fi

        # Remove from Login Items. Skipped when the sibling guard flagged a
        # name collision: login items are matched by display name only, and
        # deleting "Xcode" by name would take out the surviving install's
        # login item along with the beta's.
        if [[ -z "$reason" && "${sibling_guard:-none}" != "guard_login" ]]; then
            local login_remove_rc=0
            remove_login_item "$app_name" "$bundle_id" || login_remove_rc=$?
            [[ $login_remove_rc -eq 124 || $login_remove_rc -ge 128 ]] && return "$login_remove_rc"
        elif [[ -z "$reason" ]]; then
            debug_log "Skipping login item removal for $app_name: name is shared with a surviving install"
        fi

        # Best-effort termination. macOS allows removing a running app bundle
        # (the running process keeps using its mmap'd code), so a stuck app
        # process must NOT block the uninstall. Track it so we can surface a
        # warning at the end without scaring the user with a "failed" status.
        # Skipped under the sibling guard: force_kill_app quits by bundle id
        # and matches processes by CFBundleExecutable, and both identifiers
        # can belong to the surviving install (Xcode-beta.app ships the
        # executable "Xcode"), so the kill ladder could SIGKILL the
        # survivor's running process instead.
        if [[ -z "$reason" && "${sibling_guard:-none}" == "none" ]]; then
            local kill_rc=0
            force_kill_app "$app_name" "$app_path" || kill_rc=$?
            [[ $kill_rc -ge 128 ]] && return "$kill_rc"
            if [[ $kill_rc -ne 0 ]]; then
                running_at_uninstall_apps+=("$app_name")
            fi
        elif [[ -z "$reason" ]]; then
            debug_log "Skipping process termination for $app_name: identifiers are shared with a surviving install"
        fi

        # Keep the spinner alive through the heavy work. For large apps the
        # main bundle delete alone can take many seconds; for apps with
        # 50-200 leftover files the per-file Trash moves add even more. The
        # message is updated so the user sees which phase is running rather
        # than a single static spinner.
        if [[ -t 1 && -z "$reason" ]]; then
            local _phase_size
            _phase_size=$(bytes_to_human "$((total_kb * 1024))")
            local _phase_prefix=""
            if [[ ${#app_details[@]} -gt 1 ]]; then
                _phase_prefix="[$current_index/${#app_details[@]}] "
            fi
            start_inline_spinner "${_phase_prefix}Removing ${app_name} (${_phase_size})..."
        fi

        local used_brew_successfully=false
        if [[ -z "$reason" ]]; then
            app_plan_rc=0
            _batch_selected_app_plan_matches "$app_path" \
                "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
            if [[ $app_plan_rc -eq 124 || $app_plan_rc -ge 128 ]]; then
                return "$app_plan_rc"
            elif [[ $app_plan_rc -ne 0 ]]; then
                reason="selected app changed after preview"
                suggestion="Select the app again and review the new removal plan"
            fi
        fi
        if [[ -z "$reason" ]]; then
            if [[ "$is_brew_cask" == "true" && -n "$cask_name" ]]; then
                # Zap stanzas delete bundle-id-keyed prefs/caches. When the
                # sibling guard is active those paths still belong to the
                # surviving same-bundle install, so run a plain uninstall.
                local cask_zap_mode="zap"
                [[ "${sibling_guard:-none}" != "none" ]] && cask_zap_mode="nozap"
                # Use brew_uninstall_cask helper (handles env vars, timeout, verification)
                local brew_uninstall_rc=0
                brew_uninstall_cask "$cask_name" "$app_path" \
                    "$cask_zap_mode" || brew_uninstall_rc=$?
                if [[ $brew_uninstall_rc -eq 0 ]]; then
                    used_brew_successfully=true
                elif [[ $brew_uninstall_rc -eq 124 || $brew_uninstall_rc -ge 128 ]]; then
                    return "$brew_uninstall_rc"
                else
                    # Only fall back to manual app removal when Homebrew no longer
                    # tracks the cask. Otherwise we would recreate the mismatch
                    # where brew still reports the app as installed after Mole
                    # removes the bundle manually.
                    local cask_state=2
                    if command -v is_brew_cask_installed > /dev/null 2>&1; then
                        if is_brew_cask_installed "$cask_name"; then
                            cask_state=0
                        else
                            cask_state=$?
                        fi
                    fi
                    [[ $cask_state -ge 128 ]] && return "$cask_state"

                    if [[ $cask_state -eq 1 ]]; then
                        app_plan_rc=0
                        _batch_selected_app_plan_matches "$app_path" \
                            "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
                        if [[ $app_plan_rc -eq 124 || $app_plan_rc -ge 128 ]]; then
                            return "$app_plan_rc"
                        elif [[ $app_plan_rc -ne 0 ]]; then
                            reason="selected app changed after preview"
                            suggestion="Select the app again and review the new removal plan"
                        else
                            local removal_rc=0
                            mole_delete "$app_path" "$needs_sudo" \
                                "$expected_app_identity" || removal_rc=$?
                            [[ $removal_rc -eq 124 || $removal_rc -ge 128 ]] && return "$removal_rc"
                            if [[ $removal_rc -ne 0 ]]; then
                                if [[ $removal_rc -eq $MOLE_ERR_MUTABLE_PARENT ]]; then
                                    local diagnosis
                                    diagnosis=$(diagnose_removal_failure "$removal_rc" "$app_name")
                                    IFS='|' read -r reason suggestion <<< "$diagnosis"
                                else
                                    reason="brew cleanup incomplete, manual removal failed"
                                fi
                            fi
                        fi
                    elif [[ $cask_state -eq 0 ]]; then
                        reason="brew uninstall failed, package still installed"
                        if [[ "$cask_zap_mode" == "nozap" ]]; then
                            suggestion="Run brew uninstall --cask $cask_name"
                        else
                            suggestion="Run brew uninstall --cask --zap $cask_name"
                        fi
                    else
                        reason="brew uninstall failed, package state unknown"
                        suggestion="Run brew uninstall --cask --zap $cask_name"
                    fi
                fi
            elif [[ "$needs_sudo" == true ]]; then
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
                                reason="protected system symlink, cannot remove"
                                ;;
                            *)
                                local removal_rc=0
                                mole_delete "$app_path" "true" \
                                    "$expected_app_identity" || removal_rc=$?
                                [[ $removal_rc -eq 124 || $removal_rc -ge 128 ]] && return "$removal_rc"
                                if [[ $removal_rc -ne 0 ]]; then
                                    reason="failed to remove symlink"
                                fi
                                ;;
                        esac
                    else
                        local removal_rc=0
                        mole_delete "$app_path" "true" \
                            "$expected_app_identity" || removal_rc=$?
                        [[ $removal_rc -eq 124 || $removal_rc -ge 128 ]] && return "$removal_rc"
                        if [[ $removal_rc -ne 0 ]]; then
                            reason="failed to remove symlink"
                        fi
                    fi
                else
                    if is_uninstall_dry_run; then
                        local removal_rc=0
                        mole_delete "$app_path" "false" \
                            "$expected_app_identity" || removal_rc=$?
                        [[ $removal_rc -eq 124 || $removal_rc -ge 128 ]] && return "$removal_rc"
                        if [[ $removal_rc -ne 0 ]]; then
                            reason="dry-run path validation failed"
                        fi
                    else
                        local ret=0
                        mole_delete "$app_path" "true" \
                            "$expected_app_identity" || ret=$?
                        [[ $ret -eq 124 || $ret -ge 128 ]] && return "$ret"
                        if [[ $ret -ne 0 ]]; then
                            local diagnosis
                            diagnosis=$(diagnose_removal_failure "$ret" "$app_name")
                            IFS='|' read -r reason suggestion <<< "$diagnosis"
                        fi
                    fi
                fi
            else
                local removal_rc=0
                mole_delete "$app_path" "false" \
                    "$expected_app_identity" || removal_rc=$?
                [[ $removal_rc -eq 124 || $removal_rc -ge 128 ]] && return "$removal_rc"
                if [[ $removal_rc -ne 0 ]]; then
                    if [[ ! -w "$(dirname "$app_path")" ]]; then
                        reason="parent directory not writable"
                    else
                        reason="remove failed, check permissions"
                    fi
                fi
            fi
        fi

        # Remove related files if app removal succeeded.
        if [[ -z "$reason" ]]; then
            if [[ -t 1 ]]; then
                local _phase_prefix=""
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    _phase_prefix="[$current_index/${#app_details[@]}] "
                fi
                start_inline_spinner "${_phase_prefix}Cleaning files for ${app_name}..."
            fi
            local related_remove_rc=0
            remove_file_list "$related_files" "false" > /dev/null || related_remove_rc=$?
            [[ $related_remove_rc -eq 124 || $related_remove_rc -ge 128 ]] && return "$related_remove_rc"

            # Identify leftovers (silent rm failures, e.g. container directories
            # macOS protects via com.apple.provenance xattr). Compute their
            # total size in a single du invocation rather than walking each
            # path; the source paths that DID move to Trash are already gone
            # and would just produce stderr noise we discard.
            local leftover_kb=0
            local -a leftover_paths=()
            if ! is_uninstall_dry_run; then
                while IFS= read -r _lf; do
                    [[ -n "$_lf" && -e "$_lf" ]] || continue
                    # Skip macOS-managed container stubs: containermanagerd protects
                    # these directories via com.apple.provenance xattr; rm -rf always
                    # fails on them by design. User data is already gone at this point.
                    if [[ "$_lf" == */Library/Containers/* && -f "$_lf/.com.apple.containermanagerd.metadata.plist" ]]; then
                        continue
                    fi
                    leftover_paths+=("$_lf")
                done <<< "$related_files"

                if [[ ${#leftover_paths[@]} -gt 0 ]]; then
                    local _du_total=""
                    local _du_rc=0
                    _du_total=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                        du -skcP "${leftover_paths[@]}" 2> /dev/null | awk 'END {print $1}') || _du_rc=$?
                    [[ $_du_rc -eq 124 || $_du_rc -ge 128 ]] && return "$_du_rc"
                    if [[ $_du_rc -eq 0 && "$_du_total" =~ ^[0-9]+$ ]]; then
                        leftover_kb=$_du_total
                    fi
                fi
            fi

            if [[ -t 1 ]]; then
                start_inline_spinner "${_phase_prefix}Cleaning system files for ${app_name}..."
            fi
            if [[ "$used_brew_successfully" == "true" ]]; then
                local system_remove_rc=0
                remove_file_list "$diag_system" "true" > /dev/null || system_remove_rc=$?
                [[ $system_remove_rc -eq 124 || $system_remove_rc -ge 128 ]] && return "$system_remove_rc"
            else
                local system_all="$system_files"
                if [[ -n "$diag_system" ]]; then
                    if [[ -n "$system_all" ]]; then
                        system_all+=$'\n'
                    fi
                    system_all+="$diag_system"
                fi
                local system_remove_rc=0
                remove_file_list "$system_all" "true" > /dev/null || system_remove_rc=$?
                [[ $system_remove_rc -eq 124 || $system_remove_rc -ge 128 ]] && return "$system_remove_rc"
            fi

            # Defaults writes are side effects that should never run in dry-run mode.
            if mole_is_reverse_dns_bundle_id "$bundle_id"; then
                if is_uninstall_dry_run; then
                    debug_log "[DRY RUN] Would clear defaults domain: $bundle_id"
                else
                    if defaults read "$bundle_id" &> /dev/null; then
                        defaults delete "$bundle_id" 2> /dev/null || true
                    fi
                fi

                # ByHost preferences (machine-specific).
                # User-owned plists, so route through user-mode mole_delete to
                # avoid prompting for sudo when uninstalling a normal app.
                if [[ -d "$HOME/Library/Preferences/ByHost" ]]; then
                    local byhost_scan_file=""
                    byhost_scan_file=$(create_temp_file) || return 1
                    local byhost_scan_rc=0
                    run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find \
                        "$HOME/Library/Preferences/ByHost" -maxdepth 1 -type f \
                        -name "${bundle_id}.*.plist" -print0 > "$byhost_scan_file" \
                        2> /dev/null || byhost_scan_rc=$?
                    if [[ $byhost_scan_rc -ne 0 ]]; then
                        rm -f -- "$byhost_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
                        return "$byhost_scan_rc"
                    fi
                    local byhost_delete_rc=0
                    while IFS= read -r -d '' plist_file; do
                        local plist_delete_rc=0
                        mole_delete "$plist_file" "false" || plist_delete_rc=$?
                        if [[ $plist_delete_rc -eq 124 || $plist_delete_rc -ge 128 ]]; then
                            byhost_delete_rc=$plist_delete_rc
                            break
                        fi
                    done < "$byhost_scan_file"
                    rm -f -- "$byhost_scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
                    if [[ $byhost_delete_rc -ne 0 ]]; then
                        return "$byhost_delete_rc"
                    fi
                fi
            fi

            # Login item helper ids are read from the selected bundle and are
            # identical across same-bundle-id siblings, so booting them out
            # under the guard would stop the surviving install's running
            # helper.
            if [[ "${sibling_guard:-none}" == "none" ]]; then
                local bootout_rc=0
                bootout_login_item_helpers "$login_item_helpers" || bootout_rc=$?
                [[ $bootout_rc -eq 124 || $bootout_rc -ge 128 ]] && return "$bootout_rc"
            else
                debug_log "Skipping login item helper bootout for $app_name: helper ids are shared with a surviving install"
            fi

            # All per-app side effects done; tear the spinner down before
            # any echo so the success line does not collide with the spinner.
            [[ -t 1 ]] && stop_inline_spinner

            # Show per-app progress only for multi-app batches. For a single
            # app the summary block right below already names it on the
            # "Removed 1 app" line, so a standalone success line above the
            # box would just duplicate it.
            if [[ -t 1 && ${#app_details[@]} -gt 1 ]]; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} [$current_index/${#app_details[@]}] ${app_name}"
            fi

            # Warn about files that could not be removed and exclude them from freed total.
            if [[ ${#leftover_paths[@]} -gt 0 ]]; then
                for _lpath in "${leftover_paths[@]}"; do
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Could not remove: ${_lpath/#$HOME/$tilde_display}"
                done
                total_kb=$((total_kb - leftover_kb))
                ((total_kb < 0)) && total_kb=0
            fi

            # System-level matches stay review-only. Recheck them after the
            # app and user-owned files are gone so the final summary names
            # only exact paths that still exist.
            if ! is_uninstall_dry_run; then
                local _review_path _review_key
                while IFS= read -r _review_path; do
                    [[ -n "$_review_path" && (-e "$_review_path" || -L "$_review_path") ]] || continue
                    _review_key=$(mole_normalize_path "$_review_path")
                    if [[ ${#review_only_system_leftover_keys[@]} -eq 0 ]] ||
                        ! mole_identity_in_list "$_review_key" "${review_only_system_leftover_keys[@]}"; then
                        review_only_system_leftover_keys+=("$_review_key")
                        review_only_system_leftovers+=("$_review_path")
                    fi
                done <<< "$review_only_system_files"
            fi

            total_size_freed=$((total_size_freed + total_kb))
            success_count=$((success_count + 1))
            [[ "$used_brew_successfully" == "true" ]] && brew_apps_removed=$((brew_apps_removed + 1))
            files_cleaned=$((files_cleaned + 1))
            total_items=$((total_items + 1))
            success_items+=("$app_path")
            success_dock_targets+=("$app_path|$bundle_id")
            # Check for orphaned system extensions (camera, network, endpoint security, etc.)
            if mole_is_reverse_dns_bundle_id "$bundle_id" && [[ -d /Library/SystemExtensions ]]; then
                local system_extension_path=""
                local has_bundle_system_extension=false
                while IFS= read -r -d '' system_extension_path; do
                    if mole_name_starts_with_bundle_id_boundary "$system_extension_path" "$bundle_id"; then
                        has_bundle_system_extension=true
                        break
                    fi
                done < <(command find /Library/SystemExtensions -maxdepth 3 -name "*.systemextension" -print0 2> /dev/null)
                if [[ "$has_bundle_system_extension" == "true" ]]; then
                    system_extension_warning_apps+=("$app_name")
                fi
            fi
        else
            # Stop spinner before printing the failure line so the error
            # message is not painted over by the spinner's next tick.
            [[ -t 1 ]] && stop_inline_spinner
            if [[ -t 1 ]]; then
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    echo -e "${ICON_ERROR} [$current_index/${#app_details[@]}] ${app_name} ${GRAY}, $reason${NC}"
                else
                    echo -e "${ICON_ERROR} ${app_name} failed: $reason"
                fi
                if [[ -n "${suggestion:-}" ]]; then
                    echo -e "${GRAY}   ${ICON_REVIEW} ${suggestion}${NC}"
                fi
            fi

            failed_count=$((failed_count + 1))
            failed_items+=("$app_name:$reason:${suggestion:-}")
        fi
    done
}

# Phase 5+6: assemble the post-removal summary block (success line, failed
# apps, system extension / Background Items / still-running warnings) and emit
# it as a single summary block.
# Reads:  success_count, failed_count, failed_items, success_items,
#         total_size_freed, system_extension_warning_apps,
#         review_only_system_leftovers,
#         background_items_warning_apps, running_at_uninstall_apps
_batch_render_summary() {
    # Summary
    local freed_display
    freed_display=$(bytes_to_human "$((total_size_freed * 1024))")

    local summary_status="success"
    local -a summary_details=()

    if [[ $success_count -gt 0 ]]; then
        local success_text="app"
        [[ $success_count -gt 1 ]] && success_text="apps"
        local success_line="Removed ${success_count} ${success_text}"
        if is_uninstall_dry_run; then
            success_line="Would remove ${success_count} ${success_text}"
        fi
        if [[ -n "$freed_display" ]]; then
            if is_uninstall_dry_run; then
                success_line+=", would free ${GREEN}${freed_display}${NC}"
            else
                success_line+=", freed ${GREEN}${freed_display}${NC}"
            fi
        fi

        # Format app list with max 3 per line.
        if [[ ${#success_items[@]} -gt 0 ]]; then
            local idx=0
            local is_first_line=true
            local current_line=""

            for success_path in "${success_items[@]}"; do
                local display_name
                display_name=$(basename "$success_path")
                display_name="${display_name%.[aA][pP][pP]}"
                local display_item="${GREEN}${display_name}${NC}"

                if ((idx % 3 == 0)); then
                    if [[ -n "$current_line" ]]; then
                        summary_details+=("$current_line")
                    fi
                    if [[ "$is_first_line" == true ]]; then
                        current_line="${success_line}: $display_item"
                        is_first_line=false
                    else
                        current_line="$display_item"
                    fi
                else
                    current_line="$current_line, $display_item"
                fi
                idx=$((idx + 1))
            done
            if [[ -n "$current_line" ]]; then
                summary_details+=("$current_line")
            fi
        else
            summary_details+=("$success_line")
        fi
    fi

    if [[ $failed_count -gt 0 ]]; then
        summary_status="warn"

        local failed_names=()
        for item in "${failed_items[@]}"; do
            local name=${item%%:*}
            failed_names+=("$name")
        done
        local failed_list="${failed_names[*]}"

        local reason_summary="could not be removed"
        local suggestion_text=""
        if [[ $failed_count -eq 1 ]]; then
            # Extract reason and suggestion from format: app:reason:suggestion
            local item="${failed_items[0]}"
            local without_app="${item#*:}"
            local first_reason="${without_app%%:*}"
            local first_suggestion="${without_app#*:}"

            # If suggestion is same as reason, there was no suggestion part
            # Also check if suggestion is empty
            if [[ "$first_suggestion" != "$first_reason" && -n "$first_suggestion" ]]; then
                suggestion_text="${GRAY}${ICON_REVIEW} ${first_suggestion}${NC}"
            fi

            case "$first_reason" in
                still*running*) reason_summary="is still running" ;;
                remove*failed*) reason_summary="could not be removed" ;;
                permission*denied*) reason_summary="permission denied" ;;
                owned*by*) reason_summary="$first_reason, try with sudo" ;;
                *) reason_summary="$first_reason" ;;
            esac
        fi
        summary_details+=("${ICON_LIST} Failed: ${RED}${failed_list}${NC} ${reason_summary}")
        if [[ -n "$suggestion_text" ]]; then
            summary_details+=("$suggestion_text")
        fi
    fi

    if [[ $success_count -eq 0 && $failed_count -eq 0 ]]; then
        summary_status="info"
        summary_details+=("No applications were uninstalled.")
    fi

    if [[ ${#review_only_system_leftovers[@]} -gt 0 ]]; then
        # Deliberately not a warning, and deliberately one line. The CLI never
        # removes system-level paths, so keeping them is the designed outcome
        # of a successful uninstall, not an incomplete one; marking the run
        # "incomplete" told users something went wrong when nothing had. The
        # exact paths were already listed above the confirmation prompt, so
        # repeating them plus a generic "review these" line only added noise to
        # the block the user reads last, with no action attached to it.
        local kept_count=${#review_only_system_leftovers[@]}
        local kept_label="paths"
        [[ $kept_count -eq 1 ]] && kept_label="path"
        summary_details+=("${ICON_REVIEW} Kept ${kept_count} system-level ${kept_label}, which Mole never removes")
    fi

    if [[ ${#system_extension_warning_apps[@]} -gt 0 ]]; then
        local ext_list=""
        local idx
        for ((idx = 0; idx < ${#system_extension_warning_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && ext_list+=", "
            ext_list+="${system_extension_warning_apps[idx]}"
        done

        summary_details+=("${ICON_REVIEW} System extensions may remain after removal: ${YELLOW}${ext_list}${NC}")
        summary_details+=("${GRAY}${ICON_SUBLIST}${NC} Check ${GRAY}System Settings > General > Login Items & Extensions${NC} to remove leftover extensions")
    fi

    if [[ ${#background_items_warning_apps[@]} -gt 0 ]]; then
        local bg_list=""
        local idx
        for ((idx = 0; idx < ${#background_items_warning_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && bg_list+=", "
            bg_list+="${background_items_warning_apps[idx]}"
        done

        summary_details+=("${ICON_REVIEW} Background item still running for ${YELLOW}${bg_list}${NC}, turn it off in ${GRAY}System Settings > Login Items & Extensions${NC}")
    fi

    if [[ ${#running_at_uninstall_apps[@]} -gt 0 ]]; then
        local running_list=""
        local idx
        for ((idx = 0; idx < ${#running_at_uninstall_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && running_list+=", "
            running_list+="${running_at_uninstall_apps[idx]}"
        done

        summary_details+=("${ICON_REVIEW} Still running during uninstall, files removed but process kept alive: ${YELLOW}${running_list}${NC}")
        summary_details+=("${GRAY}${ICON_SUBLIST}${NC} Quit the app to free its in-memory copy; reinstalling before quitting may behave oddly")
    fi

    local title="Uninstall complete"
    if [[ "$summary_status" == "warn" ]]; then
        title="Uninstall incomplete"
    fi
    if is_uninstall_dry_run; then
        title="Uninstall dry run complete"
    fi

    # No blank line here: print_summary_block already opens with one.
    print_summary_block "$title" "${summary_details[@]}"
    printf '\n'
}

# Batch uninstall with single confirmation. Orchestrates the four phases
# (scan, preview/confirm, execute, summary) and manages the cross-phase
# shared state, the SIGINT/SIGTERM trap, sudo keepalive, and the deferred
# Dock / LaunchServices refresh.
batch_uninstall_applications() {
    local total_size_freed=0

    # shellcheck disable=SC2154
    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    local old_trap_int old_trap_term
    old_trap_int=$(trap -p INT)
    old_trap_term=$(trap -p TERM)

    _cleanup_sudo_keepalive() {
        if command -v stop_sudo_session > /dev/null 2>&1; then
            stop_sudo_session
        fi
    }

    _restore_uninstall_traps() {
        _cleanup_sudo_keepalive
        if [[ -n "$old_trap_int" ]]; then
            # eval: restore previous trap captured by $(trap -p INT)
            eval "$old_trap_int"
        else
            trap - INT
        fi
        if [[ -n "$old_trap_term" ]]; then
            # eval: restore previous trap captured by $(trap -p TERM)
            eval "$old_trap_term"
        else
            trap - TERM
        fi
    }

    _abort_uninstall_batch() {
        stop_inline_spinner 2> /dev/null || true
        unset MOLE_UNINSTALL_MODE
        _restore_uninstall_traps
    }

    # SIGINT/SIGTERM during a phase helper would normally `return 130` out of
    # the helper only; without an explicit signal flag the orchestrator would
    # cheerfully run the next phase. The trap sets _batch_interrupted so the
    # orchestrator can check after each helper and bail out the way the
    # pre-refactor inline implementation did.
    local _batch_interrupted=0

    # Trap to clean up spinner, sudo keepalive, and uninstall mode on interrupt
    trap 'stop_inline_spinner 2>/dev/null; _cleanup_sudo_keepalive; unset MOLE_UNINSTALL_MODE; echo ""; _restore_uninstall_traps; _batch_interrupted=1; return 130' INT TERM

    # Pre-scan: running apps, sudo needs, size.
    local -a running_apps=()
    local -a sudo_apps=()
    local -a brew_cask_apps=()
    local -a blocked_apps=()
    local -a manual_removal_apps=()
    local total_estimated_size=0
    local -a app_details=()

    local _scan_rc=0
    _batch_scan_app_details || _scan_rc=$?
    if [[ $_batch_interrupted -eq 1 ]]; then
        _abort_uninstall_batch
        return 130
    fi
    if [[ $_scan_rc -eq 124 || $_scan_rc -ge 128 ]]; then
        _abort_uninstall_batch
        # A signal already echoed through the INT/TERM trap; a timeout has
        # said nothing yet, and a silent exit is unreportable (#1340).
        if [[ $_scan_rc -eq 124 ]]; then
            log_error "The uninstall scan timed out before finishing; nothing was removed"
        fi
        return "$_scan_rc"
    elif [[ $_scan_rc -ne 0 ]]; then
        _abort_uninstall_batch
        # Keep scan failures fail-closed, but do not let `set -e` turn an
        # ordinary probe refusal into a silent return to the shell. This is
        # especially important for the interactive path, where the caller
        # cannot render a follow-up error after this function returns.
        log_error "Could not complete the uninstall scan; nothing was removed"
        debug_log "Uninstall scan stopped before preview with status $_scan_rc"
        return 1
    fi

    if [[ ${#app_details[@]} -eq 0 ]]; then
        _abort_uninstall_batch
        return 1
    fi

    local _confirm_rc=0
    _batch_preview_and_confirm || _confirm_rc=$?
    if [[ $_batch_interrupted -eq 1 ]]; then
        _abort_uninstall_batch
        return 130
    fi
    if [[ $_confirm_rc -eq 124 || $_confirm_rc -ge 128 ]]; then
        _abort_uninstall_batch
        return "$_confirm_rc"
    fi
    case $_confirm_rc in
        0) ;;
        2)
            _abort_uninstall_batch
            return 0
            ;;
        *)
            _abort_uninstall_batch
            return 1
            ;;
    esac

    # Perform uninstallations with per-app progress feedback
    local success_count=0 failed_count=0
    local brew_apps_removed=0 # Track successful brew uninstalls for silent autoremove
    local -a failed_items=()
    local -a success_items=()
    local -a success_dock_targets=()
    local -a system_extension_warning_apps=()
    local -a review_only_system_leftovers=()
    local -a review_only_system_leftover_keys=()
    # Apps whose process was still running after the kill ladder. We do not
    # abort the uninstall for these: macOS allows deleting a running bundle
    # (the process keeps using its mmap'd code), but we warn the user so they
    # know to quit/relaunch the lingering process.
    local -a running_at_uninstall_apps=()

    local _execute_rc=0
    _batch_execute_removals || _execute_rc=$?
    if [[ $_batch_interrupted -eq 1 ]]; then
        _abort_uninstall_batch
        return 130
    fi
    if [[ $_execute_rc -eq 124 || $_execute_rc -ge 128 ]]; then
        _abort_uninstall_batch
        return "$_execute_rc"
    elif [[ $_execute_rc -ne 0 ]]; then
        _abort_uninstall_batch
        return 1
    fi

    # Detect background jobs that survived the uninstall (System Settings >
    # Login Items & Extensions). Modern SMAppService helpers are not removable
    # via osascript and Apple has no public CLI to delete individual BTM
    # records, so we only detect + warn. Detection is launchctl-only: it needs
    # no privileges, while sfltool dumpbtm pops the macOS "sfltool wants to
    # make changes" admin-password dialog on every batch.
    local -a background_items_warning_apps=()
    if [[ ${#success_items[@]} -gt 0 ]] && ! is_uninstall_dry_run; then
        local _bg_line
        while IFS= read -r _bg_line; do
            [[ -n "$_bg_line" ]] && background_items_warning_apps+=("$_bg_line")
        done < <(_uninstall_match_loaded_background_items "${app_details[@]}" -- "${success_items[@]}")
    fi

    _batch_render_summary

    # Run brew autoremove silently in background to avoid interrupting UX.
    if [[ $brew_apps_removed -gt 0 && "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        # This background job never needs terminal input. Keeping its stdin
        # attached lets the Perl timeout fallback hand off the controlling tty
        # and suspend the foreground uninstall prompt with SIGTTIN.
        (
            HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
                run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" brew autoremove > /dev/null 2>&1 || true
        ) > /dev/null 2>&1 < /dev/null &
        disown $! 2> /dev/null || true
    fi

    # Clean up Dock entries for uninstalled apps.
    if [[ $success_count -gt 0 && ${#success_dock_targets[@]} -gt 0 ]]; then
        if is_uninstall_dry_run; then
            log_info "[DRY RUN] Would refresh LaunchServices and update Dock entries"
        else
            # LaunchServices refresh uses run_with_timeout. It is best-effort
            # background work, so it must never own the tty.
            (
                remove_apps_from_dock "${success_dock_targets[@]}" > /dev/null 2>&1 || true
                refresh_launch_services_after_uninstall > /dev/null 2>&1 || true
            ) > /dev/null 2>&1 < /dev/null &
            disown $! 2> /dev/null || true
        fi
    fi

    _cleanup_sudo_keepalive

    # Disable uninstall mode
    unset MOLE_UNINSTALL_MODE

    _restore_uninstall_traps
    unset -f _abort_uninstall_batch
    unset -f _restore_uninstall_traps

    total_size_cleaned=$((total_size_cleaned + total_size_freed))
    unset failed_items
}
