#!/bin/bash
# Mole - File Operations
# Safe file and directory manipulation with validation

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_FILE_OPS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_FILE_OPS_LOADED=1

# Error codes for removal operations
readonly MOLE_ERR_SIP_PROTECTED=10
readonly MOLE_ERR_AUTH_FAILED=11
readonly MOLE_ERR_READONLY_FS=12

# Ensure dependencies are loaded
_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi
if [[ -z "${MOLE_LOG_LOADED:-}" ]]; then
    # shellcheck source=lib/core/log.sh
    source "$_MOLE_CORE_DIR/log.sh"
fi
if [[ -z "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeout.sh
    source "$_MOLE_CORE_DIR/timeout.sh"
fi

# ============================================================================
# Utility Functions
# ============================================================================

# Format duration in seconds to human readable string (e.g., "5 days", "2 months")
format_duration_human() {
    local seconds="${1:-0}"
    [[ ! "$seconds" =~ ^[0-9]+$ ]] && seconds=0

    local days=$((seconds / 86400))

    if [[ $days -eq 0 ]]; then
        echo "today"
    elif [[ $days -eq 1 ]]; then
        echo "1 day"
    elif [[ $days -lt 7 ]]; then
        echo "${days} days"
    elif [[ $days -lt 30 ]]; then
        local weeks=$((days / 7))
        [[ $weeks -eq 1 ]] && echo "1 week" || echo "${weeks} weeks"
    elif [[ $days -lt 365 ]]; then
        local months=$((days / 30))
        [[ $months -eq 1 ]] && echo "1 month" || echo "${months} months"
    else
        local years=$((days / 365))
        [[ $years -eq 1 ]] && echo "1 year" || echo "${years} years"
    fi
}

# ============================================================================
# Path Validation
# ============================================================================

# Validate path for deletion (absolute, no traversal, not system dir)
validate_path_for_deletion() {
    local path="$1"

    # Check path is not empty
    if [[ -z "$path" ]]; then
        log_error "Path validation failed: empty path"
        return 1
    fi

    # Check symlink target if path is a symbolic link
    if [[ -L "$path" ]]; then
        local link_target
        link_target=$(readlink "$path" 2> /dev/null) || {
            log_error "Cannot read symlink: $path"
            return 1
        }

        # Resolve relative symlinks to absolute paths for validation
        local resolved_target="$link_target"
        if [[ "$link_target" != /* ]]; then
            local link_dir
            link_dir=$(dirname "$path")
            resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") || resolved_target=""
        fi

        # Validate resolved target against protected paths
        if [[ -n "$resolved_target" ]]; then
            case "$resolved_target" in
                / | /System | /System/* | /bin | /bin/* | /sbin | /sbin/* | \
                    /usr | /usr/bin | /usr/bin/* | /usr/lib | /usr/lib/* | \
                    /etc | /etc/* | /private/etc | /private/etc/* | \
                    /Library/Extensions | /Library/Extensions/*)
                    log_error "Symlink points to protected system path: $path -> $resolved_target"
                    return 1
                    ;;
            esac
        fi
    fi

    # Check path is absolute
    if [[ "$path" != /* ]]; then
        log_error "Path validation failed: path must be absolute: $path"
        return 1
    fi

    # Check for path traversal attempts
    # Only reject .. when it appears as a complete path component (/../ or /.. or ../)
    # This allows legitimate directory names containing .. (e.g., Firefox's "name..files")
    if [[ "$path" =~ (^|/)\.\.(\/|$) ]]; then
        log_error "Path validation failed: path traversal not allowed: $path"
        return 1
    fi

    # Check path doesn't contain dangerous characters
    if [[ "$path" =~ [[:cntrl:]] ]] || [[ "$path" =~ $'\n' ]]; then
        log_error "Path validation failed: contains control characters: $path"
        return 1
    fi

    # Allow deletion of coresymbolicationd cache (safe system cache that can be rebuilt)
    case "$path" in
        /System/Library/Caches/com.apple.coresymbolicationd/data | /System/Library/Caches/com.apple.coresymbolicationd/data/*)
            return 0
            ;;
    esac

    # Allow known safe paths under /private
    case "$path" in
        /private/tmp | /private/tmp/* | \
            /private/var/tmp | /private/var/tmp/* | \
            /private/var/log | /private/var/log/* | \
            /private/var/folders | /private/var/folders/* | \
            /private/var/db/diagnostics | /private/var/db/diagnostics/* | \
            /private/var/db/DiagnosticPipeline | /private/var/db/DiagnosticPipeline/* | \
            /private/var/db/powerlog | /private/var/db/powerlog/* | \
            /private/var/db/reportmemoryexception | /private/var/db/reportmemoryexception/* | \
            /private/var/db/receipts/*.bom | /private/var/db/receipts/*.plist)
            return 0
            ;;
    esac

    # Check path isn't critical system directory
    case "$path" in
        / | /bin | /bin/* | /sbin | /sbin/* | /usr | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | /usr/lib | /usr/lib/* | /System | /System/* | /Library/Extensions)
            log_error "Path validation failed: critical system directory: $path"
            return 1
            ;;
        /private)
            log_error "Path validation failed: critical system directory: $path"
            return 1
            ;;
        /etc | /etc/* | /private/etc | /private/etc/*)
            log_error "Path validation failed: /etc contains critical system files: $path"
            return 1
            ;;
        /var | /var/db | /var/db/* | /private/var | /private/var/db | /private/var/db/*)
            log_error "Path validation failed: /var/db contains system databases: $path"
            return 1
            ;;
    esac

    # Check if path is protected (keychains, system settings, etc)
    if declare -f should_protect_path > /dev/null 2>&1; then
        if should_protect_path "$path"; then
            if [[ "${MO_DEBUG:-0}" == "1" ]]; then
                log_warning "Path validation: protected path skipped: $path"
            fi
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# Safe Removal Operations
# ============================================================================

# Safe wrapper around rm -rf with validation
safe_remove() {
    local path="$1"
    local silent="${2:-false}"

    # Validate path
    if ! validate_path_for_deletion "$path"; then
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0
    fi

    # Dry-run mode: log but don't delete
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        if [[ "${MO_DEBUG:-}" == "1" ]]; then
            local file_type="file"
            [[ -d "$path" ]] && file_type="directory"
            [[ -L "$path" ]] && file_type="symlink"

            local file_size=""
            local file_age=""

            if [[ -e "$path" ]]; then
                local size_kb
                size_kb=$(get_path_size_kb "$path" 2> /dev/null || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    file_size=$(bytes_to_human "$((size_kb * 1024))")
                fi

                if [[ -f "$path" || -d "$path" ]] && ! [[ -L "$path" ]]; then
                    local mod_time
                    mod_time=$(stat -f%m "$path" 2> /dev/null || echo "0")
                    local now
                    now=$(date +%s 2> /dev/null || echo "0")
                    if [[ "$mod_time" -gt 0 && "$now" -gt 0 ]]; then
                        file_age=$(((now - mod_time) / 86400))
                    fi
                fi
            fi

            debug_file_action "[DRY RUN] Would remove" "$path" "$file_size" "$file_age"
        else
            debug_log "[DRY RUN] Would remove: $path"
        fi
        return 0
    fi

    debug_log "Removing: $path"

    # Calculate size before deletion for logging
    local size_kb=0
    local size_human=""
    if oplog_enabled; then
        if [[ -e "$path" ]]; then
            size_kb=$(get_path_size_kb "$path" 2> /dev/null || echo "0")
            if [[ "$size_kb" =~ ^[0-9]+$ ]] && [[ "$size_kb" -gt 0 ]]; then
                size_human=$(bytes_to_human "$((size_kb * 1024))" 2> /dev/null || echo "${size_kb}KB")
            fi
        fi
    fi

    # Perform the deletion
    # Use || to capture the exit code so set -e won't abort on rm failures
    local error_msg
    local rm_exit=0
    error_msg=$(rm -rf "$path" 2>&1) || rm_exit=$? # safe_remove

    # Preserve interrupt semantics so callers can abort long-running deletions.
    if [[ $rm_exit -ge 128 ]]; then
        return "$rm_exit"
    fi

    if [[ $rm_exit -eq 0 ]]; then
        # Log successful removal
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "$size_human"
        return 0
    else
        # Check if it's a permission error
        if [[ "$error_msg" == *"Permission denied"* ]] || [[ "$error_msg" == *"Operation not permitted"* ]]; then
            MOLE_PERMISSION_DENIED_COUNT=${MOLE_PERMISSION_DENIED_COUNT:-0}
            MOLE_PERMISSION_DENIED_COUNT=$((MOLE_PERMISSION_DENIED_COUNT + 1))
            export MOLE_PERMISSION_DENIED_COUNT
            debug_log "Permission denied: $path, may need Full Disk Access"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "permission denied"
        else
            [[ "$silent" != "true" ]] && log_error "Failed to remove: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "error"
        fi
        return 1
    fi
}

# Safe symlink removal (for pre-validated symlinks only)
safe_remove_symlink() {
    local path="$1"
    local use_sudo="${2:-false}"

    if [[ ! -L "$path" ]]; then
        return 1
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would remove symlink: $path"
        return 0
    fi

    local rm_exit=0
    if [[ "$use_sudo" == "true" ]]; then
        sudo rm "$path" 2> /dev/null || rm_exit=$?
    else
        rm "$path" 2> /dev/null || rm_exit=$?
    fi

    if [[ $rm_exit -eq 0 ]]; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "symlink"
        return 0
    else
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "symlink removal failed"
        return 1
    fi
}

# Safe sudo removal with symlink protection
safe_sudo_remove() {
    local path="$1"

    if ! validate_path_for_deletion "$path"; then
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$path"; then
            debug_log "Skipped sudo remove for protected path: $path"
        else
            log_error "Path validation failed for sudo remove: $path"
        fi
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    if [[ -L "$path" ]]; then
        log_error "Refusing to sudo remove symlink: $path"
        return 1
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        if [[ "${MO_DEBUG:-}" == "1" ]]; then
            local file_type="file"
            [[ -d "$path" ]] && file_type="directory"

            local file_size=""
            local file_age=""

            if sudo test -e "$path" 2> /dev/null; then
                local size_kb
                size_kb=$(sudo du -skP "$path" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    file_size=$(bytes_to_human "$((size_kb * 1024))")
                fi

                if sudo test -f "$path" 2> /dev/null || sudo test -d "$path" 2> /dev/null; then
                    local mod_time
                    mod_time=$(sudo stat -f%m "$path" 2> /dev/null || echo "0")
                    local now
                    now=$(date +%s 2> /dev/null || echo "0")
                    if [[ "$mod_time" -gt 0 && "$now" -gt 0 ]]; then
                        local age_seconds=$((now - mod_time))
                        file_age=$(format_duration_human "$age_seconds")
                    fi
                fi
            fi

            log_info "[DRY-RUN] Would sudo remove: $file_type $path"
            [[ -n "$file_size" ]] && log_info "  Size: $file_size"
            [[ -n "$file_age" ]] && log_info "  Age: $file_age"
        else
            log_info "[DRY-RUN] Would sudo remove: $path"
        fi
        return 0
    fi

    local size_kb=0
    local size_human=""
    if oplog_enabled; then
        if sudo test -e "$path" 2> /dev/null; then
            size_kb=$(sudo du -skP "$path" 2> /dev/null | awk '{print $1}' || echo "0")
            if [[ "$size_kb" =~ ^[0-9]+$ ]] && [[ "$size_kb" -gt 0 ]]; then
                size_human=$(bytes_to_human "$((size_kb * 1024))" 2> /dev/null || echo "${size_kb}KB")
            fi
        fi
    fi

    local output
    local ret=0
    output=$(sudo rm -rf "$path" 2>&1) || ret=$? # safe_remove

    if [[ $ret -eq 0 ]]; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "$size_human"
        return 0
    fi

    case "$output" in
        *"Operation not permitted"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sip/mdm protected"
            return "$MOLE_ERR_SIP_PROTECTED"
            ;;
        *"Read-only file system"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "readonly filesystem"
            return "$MOLE_ERR_READONLY_FS"
            ;;
        *"Sorry, try again"* | *"incorrect passphrase"* | *"incorrect credentials"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "auth failed"
            return "$MOLE_ERR_AUTH_FAILED"
            ;;
        *)
            log_error "Failed to remove, sudo: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sudo error"
            return 1
            ;;
    esac
}

# ============================================================================
# Unified deletion helper (Trash + permanent routing with forensic log)
# ============================================================================

# Route a deletion through either macOS Trash or permanent rm, while logging
# every call for forensic review. Designed for destructive paths where undo
# matters (e.g. uninstall). Not used by cache-clean paths.
#
# Usage: mole_delete <path> [needs_sudo=false]
#
# Environment:
#   MOLE_DELETE_MODE      "permanent" (default) or "trash"
#   MOLE_DRY_RUN=1        Log intent, do not delete
#   MOLE_TEST_TRASH_DIR   Test-only override; Trash moves go here via `mv`
#                         instead of Finder/trash CLI. Required for bats.
#   MOLE_DELETE_LOG       Override the log file path (default:
#                         ~/Library/Logs/mole/deletions.log)
#
# Returns 0 on success, 1 on failure. Always appends a tab-separated line to
# the deletions log: <iso_ts>\t<mode>\t<size_kb>\t<status>\t<path>.
# size_kb is "unknown" when du could not measure the path (permission denied,
# disappeared mid-call); never silently coerced to 0KB so post-hoc forensics
# can tell measured-zero from measurement-failure.
mole_delete() {
    local path="$1"
    local needs_sudo="${2:-false}"
    local mode="${MOLE_DELETE_MODE:-permanent}"

    [[ -z "$path" ]] && return 1

    # Nothing to do if path does not exist (but a broken symlink still counts).
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi

    # Validation is delegated to the underlying safe_* helpers (which call
    # validate_path_for_deletion). Trash routing only applies to paths the
    # user could legitimately restore from, so we short-circuit invalid paths
    # up front to avoid a no-op Trash move followed by a validation failure.
    # The rejection itself is recorded in the forensic log so audit trails
    # can distinguish refused-by-policy from never-attempted.
    if [[ ! -L "$path" ]] && ! validate_path_for_deletion "$path"; then
        _mole_delete_log "$mode" "0" "rejected" "$path"
        return 1
    fi

    # Capture size before the delete so the log line is still useful when the
    # path is gone afterwards. Use "unknown" (not 0) on failure so the log
    # never lies about a multi-GB delete by recording it as 0KB.
    local size_kb="unknown"
    if [[ -e "$path" ]]; then
        local raw_size=""
        local du_rc=0
        if [[ "$needs_sudo" == "true" ]]; then
            raw_size=$(sudo du -skP "$path" 2> /dev/null | awk '{print $1; exit}')
            du_rc=${PIPESTATUS[0]}
        else
            raw_size=$(get_path_size_kb "$path" 2> /dev/null) || du_rc=$?
        fi
        if [[ "$du_rc" -eq 0 && "$raw_size" =~ ^[0-9]+$ ]]; then
            size_kb="$raw_size"
        fi
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would delete ($mode): $path"
        _mole_delete_log "$mode" "$size_kb" "dry-run" "$path"
        return 0
    fi

    # Trash mode: attempt Trash move first, fall through to permanent removal
    # on failure so destructive operations never get silently skipped.
    if [[ "$mode" == "trash" ]]; then
        if _mole_move_to_trash "$path" "$needs_sudo"; then
            _mole_delete_log "trash" "$size_kb" "ok" "$path"
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "TRASHED" "$path" "${size_kb}KB"
            return 0
        fi
        # User explicitly chose Trash for recoverability. Surface the fallback
        # to permanent rm once per session so they know an "undo" isn't there.
        if [[ -z "${_MOLE_TRASH_FALLBACK_WARNED:-}" ]]; then
            _MOLE_TRASH_FALLBACK_WARNED=1
            export _MOLE_TRASH_FALLBACK_WARNED
            printf 'Warning: Trash unavailable, removing permanently. Subsequent files this session also bypass Trash.\n' >&2
        fi
        debug_log "Trash move failed, falling back to permanent delete: $path"
    fi

    # Permanent path. Delegate to the existing safe_* helpers so path
    # validation, sudo handling, and existing log_operation calls remain
    # unchanged for callers that have always gone through rm -rf.
    local rc=0
    if [[ -L "$path" ]]; then
        safe_remove_symlink "$path" "$needs_sudo" || rc=$?
    elif [[ "$needs_sudo" == "true" ]]; then
        safe_sudo_remove "$path" || rc=$?
    else
        safe_remove "$path" "true" || rc=$?
    fi

    local status_label="ok"
    [[ $rc -ne 0 ]] && status_label="error"
    # Mark the trash-mode fallback so forensics can tell why rm was used.
    if [[ "$mode" == "trash" && "$status_label" == "ok" ]]; then
        status_label="trash-fallback-rm"
    fi
    _mole_delete_log "$mode" "$size_kb" "$status_label" "$path"
    return "$rc"
}

# Move a path to the macOS Trash. Test harnesses set MOLE_TEST_TRASH_DIR to
# redirect the move to a tmpdir, avoiding any Finder/osascript interaction.
_mole_move_to_trash() {
    local path="$1"
    local needs_sudo="${2:-false}"

    if [[ -n "${MOLE_TEST_TRASH_DIR:-}" ]]; then
        mkdir -p "$MOLE_TEST_TRASH_DIR" 2> /dev/null || return 1
        local dest="$MOLE_TEST_TRASH_DIR/$(basename "$path").$$.$(date +%s 2> /dev/null || echo 0)"
        mv "$path" "$dest" 2> /dev/null
        return $?
    fi

    # Blocked in test mode so uninstall tests never hit Finder/AppleScript.
    if [[ "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    # Prefer the `trash` CLI (Homebrew formula) when available — it's faster
    # and does not need Finder running. Fall back to AppleScript, which
    # ships with macOS but prompts for auth on root-owned targets.
    if command -v trash > /dev/null 2>&1; then
        if [[ "$needs_sudo" == "true" ]]; then
            sudo trash "$path" > /dev/null 2>&1 && return 0
        else
            trash "$path" > /dev/null 2>&1 && return 0
        fi
    fi

    # AppleScript fallback. Pass the path via argv so special chars (quotes,
    # backslashes) cannot break out of the quoted string.
    osascript - "$path" > /dev/null 2>&1 << 'APPLESCRIPT'
on run argv
    set p to POSIX file (item 1 of argv)
    tell application "Finder"
        delete p
    end tell
end run
APPLESCRIPT
}

_mole_delete_log() {
    local mode="$1"
    local size_kb="$2"
    local status="$3"
    local target="$4"

    local log_file="${MOLE_DELETE_LOG:-$HOME/Library/Logs/mole/deletions.log}"
    local log_dir
    log_dir=$(dirname "$log_file")

    # Surface log-write failures once per session. The deletions log is the
    # only audit trail for Trash-routed removals; silently no-oping when the
    # log dir is unwritable (root-owned from prior sudo, ENOSPC, read-only
    # volume) defeats the design.
    if ! mkdir -p "$log_dir" 2> /dev/null; then
        _mole_warn_log_broken "create directory: $log_dir"
        return 0
    fi

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2> /dev/null || echo "unknown")

    if ! printf '%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$mode" "$size_kb" "$status" "$target" \
        >> "$log_file" 2> /dev/null; then
        _mole_warn_log_broken "write to: $log_file"
    fi
}

_mole_warn_log_broken() {
    [[ -n "${_MOLE_DELETE_LOG_WARNED:-}" ]] && return 0
    _MOLE_DELETE_LOG_WARNED=1
    export _MOLE_DELETE_LOG_WARNED
    printf 'Warning: deletions audit log unavailable (%s). Forensic trail incomplete this session.\n' "$1" >&2
}

# ============================================================================
# Safe Find and Delete Operations
# ============================================================================

# Safe file discovery and deletion with depth and age limits
safe_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory exists and is not a symlink
    if [[ ! -d "$base_dir" ]]; then
        log_error "Directory does not exist: $base_dir"
        return 1
    fi

    if [[ -L "$base_dir" ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi

    debug_log "Finding in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "5" "-name" "$pattern" "-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Iterate results to respect both system protection and user whitelist.
    # Per-caller whitelist gates were missed in past releases (see #710, #724,
    # #738, #744, #757); enforcing here makes the protection structural so
    # new clean_* functions get whitelist enforcement for free.
    while IFS= read -r -d '' match; do
        if should_protect_path "$match"; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null && is_path_whitelisted "$match"; then
            continue
        fi
        safe_remove "$match" true || true
    done < <(command find "$base_dir" "${find_args[@]}" -print0 2> /dev/null || true)

    return 0
}

# Safe sudo discovery and deletion
safe_sudo_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory (use sudo for permission-restricted dirs)
    if ! sudo test -d "$base_dir" 2> /dev/null; then
        debug_log "Directory does not exist, skipping: $base_dir"
        return 0
    fi

    if sudo test -L "$base_dir" 2> /dev/null; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi

    debug_log "Finding, sudo, in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "5")
    # Skip -name if pattern is "*" (matches everything anyway, but adds overhead)
    if [[ "$pattern" != "*" ]]; then
        find_args+=("-name" "$pattern")
    fi
    find_args+=("-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Iterate results to respect both system protection and user whitelist.
    # See safe_find_delete for rationale (#757).
    while IFS= read -r -d '' match; do
        if should_protect_path "$match"; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null && is_path_whitelisted "$match"; then
            continue
        fi
        safe_sudo_remove "$match" || true
    done < <(sudo find "$base_dir" "${find_args[@]}" -print0 2> /dev/null || true)

    return 0
}

# ============================================================================
# Size Calculation
# ============================================================================

# Get path size in KB (returns 0 if not found)
get_path_size_kb() {
    local path="$1"
    [[ -z "$path" || ! -e "$path" ]] && {
        echo "0"
        return
    }

    # For .app bundles, prefer mdls logical size as it matches Finder
    # (APFS clone/sparse files make 'du' severely underreport apps like Xcode)
    if [[ "$path" == *.app || "$path" == *.app/ ]]; then
        local mdls_size
        mdls_size=$(mdls -name kMDItemLogicalSize -raw "$path" 2> /dev/null || true)
        if [[ "$mdls_size" =~ ^[0-9]+$ && "$mdls_size" -gt 0 ]]; then
            # Return in KB
            echo "$((mdls_size / 1024))"
            return
        fi
    fi

    local size
    size=$(command du -skP "$path" 2> /dev/null | awk 'NR==1 {print $1; exit}' || true)

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    else
        [[ "${MO_DEBUG:-}" == "1" ]] && debug_log "get_path_size_kb: Failed to get size for $path (returned: $size)"
        echo "0"
    fi
}

# Calculate total size for multiple paths
calculate_total_size() {
    local files="$1"
    local total_kb=0

    while IFS= read -r file; do
        if [[ -n "$file" && -e "$file" ]]; then
            local size_kb
            size_kb=$(get_path_size_kb "$file")
            total_kb=$((total_kb + size_kb))
        fi
    done <<< "$files"

    echo "$total_kb"
}

diagnose_removal_failure() {
    local exit_code="$1"
    local app_name="${2:-application}"

    local reason=""
    local suggestion=""
    local touchid_file="/etc/pam.d/sudo"

    case "$exit_code" in
        "$MOLE_ERR_SIP_PROTECTED")
            reason="protected by macOS (SIP/MDM)"
            ;;
        "$MOLE_ERR_AUTH_FAILED")
            reason="authentication failed"
            if [[ -f "$touchid_file" ]] && grep -q "pam_tid.so" "$touchid_file" 2> /dev/null; then
                suggestion="Check your credentials or restart Terminal"
            else
                suggestion="Try 'mole touchid' to enable fingerprint auth"
            fi
            ;;
        "$MOLE_ERR_READONLY_FS")
            reason="filesystem is read-only"
            suggestion="Check if disk needs repair"
            ;;
        *)
            reason="permission denied"
            if [[ -f "$touchid_file" ]] && grep -q "pam_tid.so" "$touchid_file" 2> /dev/null; then
                suggestion="Try running again or check file ownership"
            else
                suggestion="Try 'mole touchid' or check with 'ls -l'"
            fi
            ;;
    esac

    echo "$reason|$suggestion"
}
