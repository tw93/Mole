#!/bin/bash
# Mole - Logging System
# Centralized logging with rotation support

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_LOG_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_LOG_LOADED=1

# Ensure base.sh is loaded for colors and icons
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    _MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi

# ============================================================================
# Logging Configuration
# ============================================================================

readonly LOG_FILE="${HOME}/Library/Logs/mole/mole.log"
readonly DEBUG_LOG_FILE="${HOME}/Library/Logs/mole/mole_debug_session.log"
readonly OPERATIONS_LOG_FILE="${HOME}/Library/Logs/mole/operations.log"
readonly LOG_MAX_SIZE_DEFAULT=1048576   # 1MB
readonly OPLOG_MAX_SIZE_DEFAULT=5242880 # 5MB

# Ensure log directory and file exist with correct ownership
ensure_user_file "$LOG_FILE"
if [[ "${MO_NO_OPLOG:-}" != "1" ]]; then
    ensure_user_file "$OPERATIONS_LOG_FILE"
fi

# ============================================================================
# Log Rotation
# ============================================================================

# Existing writable logs need no mkdir/touch before each synchronous append.
# Missing files and privileged ownership repair retain the original setup path.
# EUID avoids forking id(1) once per log line.
_mole_prepare_log_append() {
    if [[ -f "$1" && -w "$1" && ${EUID:-0} -ne 0 ]]; then
        return 0
    fi
    ensure_user_file "$1"
}

# Surface audit-log write failures once per session. operations.log and
# deletions.log are what support reads after a reported deletion; a write
# that fails quietly (root-owned file from an earlier sudo run, ENOSPC, a
# read-only volume) leaves no trail and no hint that it is missing.
_mole_warn_log_broken() {
    [[ -n "${_MOLE_DELETE_LOG_WARNED:-}" ]] && return 0
    _MOLE_DELETE_LOG_WARNED=1
    export _MOLE_DELETE_LOG_WARNED
    printf 'Warning: audit log unavailable (%s). Forensic trail incomplete this session.\n' "$1" >&2
}

append_log_line() {
    local file_path="$1"
    local line="${2:-}"

    if [[ "$file_path" == "$OPERATIONS_LOG_FILE" ]]; then
        _mole_escape_log_value line "$line"
        _mole_prepare_log_append "$file_path" 2> /dev/null || true
        printf '%s\n' "$line" >> "$file_path" 2> /dev/null ||
            _mole_warn_log_broken "write to: $file_path"
        return 0
    fi
    _mole_prepare_log_append "$file_path"
    printf '%s\n' "$line" >> "$file_path" 2> /dev/null || true
}

append_log_lines() {
    local file_path="$1"
    shift

    if [[ "$file_path" == "$OPERATIONS_LOG_FILE" ]]; then
        _mole_prepare_log_append "$file_path" 2> /dev/null || true
        local record
        local -a operation_records=()
        for record in "$@"; do
            _mole_escape_log_value record "$record"
            operation_records+=("$record")
        done
        printf '%s\n' "${operation_records[@]+"${operation_records[@]}"}" >> "$file_path" 2> /dev/null ||
            _mole_warn_log_broken "write to: $file_path"
        return 0
    fi
    _mole_prepare_log_append "$file_path"
    printf '%s\n' "$@" >> "$file_path" 2> /dev/null || true
}

# Rotate log file if it exceeds maximum size
rotate_log_once() {
    # Skip if already checked this session
    [[ -n "${MOLE_LOG_ROTATED:-}" ]] && return 0
    export MOLE_LOG_ROTATED=1

    local max_size="$LOG_MAX_SIZE_DEFAULT"
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(get_file_size "$LOG_FILE")
        if [[ "$size" -gt "$max_size" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old" 2> /dev/null || true
            ensure_user_file "$LOG_FILE"
        fi
    fi

    # Rotate operations log (5MB limit)
    if [[ "${MO_NO_OPLOG:-}" != "1" ]]; then
        local oplog_max_size="$OPLOG_MAX_SIZE_DEFAULT"
        if [[ -f "$OPERATIONS_LOG_FILE" ]]; then
            local size
            size=$(get_file_size "$OPERATIONS_LOG_FILE")
            if [[ "$size" -gt "$oplog_max_size" ]]; then
                mv "$OPERATIONS_LOG_FILE" "${OPERATIONS_LOG_FILE}.old" 2> /dev/null || true
                ensure_user_file "$OPERATIONS_LOG_FILE"
            fi
        fi
    fi
}

# ============================================================================
# Logging Functions
# ============================================================================

# Get current timestamp (centralized for consistency)
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Any log row printed inside a section counts as section activity; without
# this, a section whose rows come only from log_* helpers is misdetected as
# idle and end_section/start_section reclaim lines that hold real output.
_log_mark_section_activity() {
    # Purge deliberately gives note_activity a different export side effect.
    # Update the stable section state directly so logging never dispatches to
    # a source-order-selected command implementation.
    if [[ "${TRACK_SECTION:-0}" == "1" ]]; then
        SECTION_ACTIVITY=1
    fi
}

# Log informational message
log_info() {
    echo -e "${BLUE}$1${NC}"
    _log_mark_section_activity
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] INFO: $1"
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] INFO: $1"
    fi
}

# Log success message
log_success() {
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
    _log_mark_section_activity
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] SUCCESS: $1"
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] SUCCESS: $1"
    fi
}

# shellcheck disable=SC2329
log_warning() {
    echo -e "${YELLOW}$1${NC}"
    _log_mark_section_activity
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] WARNING: $1"
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] WARNING: $1"
    fi
}

# Record a warning in mole.log without printing it, for diagnostics the
# terminal deliberately stays quiet about, such as a skipped owner timeout.
log_warning_to_file() {
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] WARNING: $1"
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] WARNING: $1"
    fi
}

# shellcheck disable=SC2329
log_error() {
    echo -e "${YELLOW}${ICON_ERROR}${NC} $1" >&2
    _log_mark_section_activity
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] ERROR: $1"
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] ERROR: $1"
    fi
}

# shellcheck disable=SC2329
debug_log() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        printf '%b%s\n' "${GRAY}[DEBUG]${NC} " "$*" >&2
        local timestamp
        timestamp=$(get_timestamp)
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] DEBUG: $*"
    fi
}

# Invisible format marks some app bundles put in their names: WhatsApp's
# display name and every localized one start with U+200E (U+200F in Arabic).
# Terminal.app draws the mark as a blank cell while get_display_width counts
# it as zero, so the name shifts right and its row falls out of line. Zero-width space,
# the bidi marks (Arabic letter mark included), embeddings, overrides and
# isolates, word joiner and BOM go; ZWJ and ZWNJ stay, since emoji sequences and
# Persian names need them. Byte escapes, because /bin/bash 3.2 leaves $'\u...'
# as literal text.
readonly _MOLE_INVISIBLE_MARKS=(
    $'\xe2\x80\x8b' $'\xe2\x80\x8e' $'\xe2\x80\x8f' $'\xd8\x9c'
    $'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' $'\xe2\x80\xad' $'\xe2\x80\xae'
    $'\xe2\x81\xa0' $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9'
    $'\xef\xbb\xbf'
)

# Sets the variable named by $1 to $2 without those marks, for rendering only
# (mole_terminal_safe_text applies it to everything it returns);
# stored names, matching and caches keep the bytes the bundle gave. A name that
# is nothing but marks keeps them, so a row never renders empty. No subshell.
mole_strip_invisible_marks() {
    local _strip_value="$2" _strip_mark
    for _strip_mark in "${_MOLE_INVISIBLE_MARKS[@]}"; do
        _strip_value="${_strip_value//"$_strip_mark"/}"
    done
    [[ -n "$_strip_value" ]] || _strip_value="$2"
    printf -v "$1" '%s' "$_strip_value"
}

mole_terminal_safe_text() {
    local value="${1:-}"
    value=$(printf '%s' "$value" |
        LC_ALL=C tr '\r\n\t' '   ' |
        LC_ALL=C tr '\001-\010\013\014\016-\037\177' '?') || value=""
    mole_strip_invisible_marks value "$value"
    printf '%s' "$value"
}

# Phase-level performance timing, gated behind MO_DEBUG=1.
# Uses perl for millisecond precision; falls back to date +%s.
debug_timer_start() {
    [[ "${MO_DEBUG:-}" != "1" ]] && return 0
    local varname="$1"
    local ts
    ts=$(perl -MTime::HiRes -e 'printf "%.3f\n", Time::HiRes::time()' 2> /dev/null || date +%s)
    # eval: indirect write by name; bash 3.2 has no nameref
    eval "$varname=$ts"
}

debug_timer_end() {
    [[ "${MO_DEBUG:-}" != "1" ]] && return 0
    local label="$1"
    local start_var="$2"
    local start_ts
    # eval: indirect read by name; bash 3.2 has no nameref
    eval "start_ts=\$$start_var"
    [[ -z "$start_ts" ]] && return 0
    local end_ts
    end_ts=$(perl -MTime::HiRes -e 'printf "%.3f\n", Time::HiRes::time()' 2> /dev/null || date +%s)
    local elapsed
    elapsed=$(perl -e "printf '%.3f', $end_ts - $start_ts" 2> /dev/null || echo "$((end_ts - start_ts))")
    debug_log "PERF [$label] ${elapsed}s"
}

# ============================================================================
# Operation Logging (Enabled by default)
# ============================================================================
# Records all file operations for user troubleshooting
# Disable with MO_NO_OPLOG=1

oplog_enabled() {
    [[ "${MO_NO_OPLOG:-}" != "1" ]]
}

# Session ownership is exported by the invoking shell. Workers that source
# common.sh inherit it; a new session always replaces it, including in a
# child shell. Marker-less commands retain their existing log format.
_MOLE_OPLOG_RUN_ID="${_MOLE_OPLOG_RUN_ID:-}"
_MOLE_OPLOG_RUN_COMMAND="${_MOLE_OPLOG_RUN_COMMAND:-}"
_MOLE_OPLOG_RUN_DRY="${_MOLE_OPLOG_RUN_DRY:-}"

# Write the command field into the caller's variable without a per-record
# subshell. Session markers and batched operations share this same format.
# A dry-run session names its command `<command>-dry-run`, so a preview never
# reads as a real run in mo history, Mole Mac or a support diagnostic. Every
# reader accepts that token as a command name; a word added anywhere else in
# the marker would break their fixed marker grammar.
operation_log_command() {
    local _mole_log_output="$1" _mole_log_command="$2"
    if [[ "$_mole_log_command" == "$_MOLE_OPLOG_RUN_COMMAND" && -n "$_MOLE_OPLOG_RUN_ID" ]]; then
        [[ "$_MOLE_OPLOG_RUN_DRY" == "1" ]] && _mole_log_command+="-dry-run"
        printf -v "$_mole_log_output" '%s run=%s' "$_mole_log_command" "$_MOLE_OPLOG_RUN_ID"
    else
        printf -v "$_mole_log_output" '%s' "$_mole_log_command"
    fi
}

# Log an operation to the operations log file
# Usage: log_operation <command> <action> <path> [detail]
# Example: log_operation "clean" "REMOVED" "/path/to/file" "15.2MB"
# Example: log_operation "clean" "SKIPPED" "/path/to/file" "whitelist"
# Example: log_operation "uninstall" "REMOVED" "/Applications/App.app" "150MB"
log_operation() {
    # Allow disabling via environment variable
    oplog_enabled || return 0

    local command="${1:-unknown}" # clean/uninstall/optimize/purge
    local action="${2:-UNKNOWN}"  # REMOVED/SKIPPED/FAILED/REBUILT
    local path="${3:-}"
    local detail="${4:-}"

    # Skip if no path provided
    [[ -z "$path" ]] && return 0

    local timestamp
    timestamp=$(get_timestamp)

    local log_command
    operation_log_command log_command "$command"
    local log_line="[$timestamp] [$log_command] $action $path"
    [[ -n "$detail" ]] && log_line+=" ($detail)"

    append_log_line "$OPERATIONS_LOG_FILE" "$log_line"
}

# Log session start marker
# Usage: log_operation_session_start <command>
log_operation_session_start() {
    export _MOLE_OPLOG_RUN_ID="" _MOLE_OPLOG_RUN_COMMAND="" _MOLE_OPLOG_RUN_DRY=""
    oplog_enabled || return 0

    local command="${1:-mole}"
    local timestamp
    timestamp=$(get_timestamp)
    # Timestamp, shell pid and native random values avoid a new dependency or
    # scratch file. The identity remains opaque to readers.
    export _MOLE_OPLOG_RUN_ID="${timestamp//[!0-9]/}-$$-$RANDOM-$RANDOM"
    export _MOLE_OPLOG_RUN_COMMAND="$command"
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && export _MOLE_OPLOG_RUN_DRY=1
    local log_command
    operation_log_command log_command "$command"

    append_log_lines \
        "$OPERATIONS_LOG_FILE" \
        "" \
        "# ========== $log_command session started at $timestamp =========="
}

# shellcheck disable=SC2329
log_operation_session_end() {
    local command="${1:-mole}" log_command
    operation_log_command log_command "$command"
    # Ownership ends even when the optional end marker is disabled or fails.
    if [[ "$command" == "$_MOLE_OPLOG_RUN_COMMAND" ]]; then
        export _MOLE_OPLOG_RUN_ID="" _MOLE_OPLOG_RUN_COMMAND="" _MOLE_OPLOG_RUN_DRY=""
    fi
    oplog_enabled || return 0

    local items="${2:-0}"
    local size="${3:-0}"
    local timestamp
    timestamp=$(get_timestamp)

    local size_human=""
    if [[ "$size" =~ ^[0-9]+$ ]] && [[ "$size" -gt 0 ]]; then
        size_human=$(bytes_to_human "$((size * 1024))" 2> /dev/null || echo "${size}KB")
    else
        size_human="0B"
    fi

    append_log_line \
        "$OPERATIONS_LOG_FILE" \
        "# ========== $log_command session ended at $timestamp, $items items, $size_human =========="
}

# Enhanced debug logging for operations
debug_operation_start() {
    local operation_name="$1"
    local operation_desc="${2:-}"

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        # Output to stderr for immediate feedback
        echo -e "${GRAY}[DEBUG] === $operation_name ===${NC}" >&2
        [[ -n "$operation_desc" ]] && echo -e "${GRAY}[DEBUG] $operation_desc${NC}" >&2

        # Also log to file
        if [[ -n "$operation_desc" ]]; then
            append_log_lines \
                "$DEBUG_LOG_FILE" \
                "" \
                "=== $operation_name ===" \
                "Description: $operation_desc"
        else
            append_log_lines \
                "$DEBUG_LOG_FILE" \
                "" \
                "=== $operation_name ==="
        fi
    fi
}

# Log detailed operation information
debug_operation_detail() {
    local detail_type="$1" # e.g., "Method", "Target", "Expected Outcome"
    local detail_value="$2"

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        # Output to stderr
        echo -e "${GRAY}[DEBUG] $detail_type: $detail_value${NC}" >&2

        # Also log to file
        append_log_line "$DEBUG_LOG_FILE" "$detail_type: $detail_value"
    fi
}

# Log individual file action with metadata
debug_file_action() {
    local action="$1" # e.g., "Would remove", "Removing"
    local file_path="$2"
    local file_size="${3:-}"
    local file_age="${4:-}"

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        local msg="  * $file_path"
        [[ -n "$file_size" ]] && msg+=", $file_size"
        [[ -n "$file_age" ]] && msg+=", ${file_age} days old"

        # Output to stderr
        echo -e "${GRAY}[DEBUG] $action: $msg${NC}" >&2

        # Also log to file
        append_log_line "$DEBUG_LOG_FILE" "$action: $msg"
    fi
}

# Log risk level for operations
debug_risk_level() {
    local risk_level="$1" # LOW, MEDIUM, HIGH
    local reason="$2"

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        local color="$GRAY"
        case "$risk_level" in
            LOW) color="$GREEN" ;;
            MEDIUM) color="$YELLOW" ;;
            HIGH) color="$RED" ;;
        esac

        # Output to stderr with color
        echo -e "${GRAY}[DEBUG] Risk Level: ${color}${risk_level}${GRAY}, $reason${NC}" >&2

        # Also log to file
        echo "Risk Level: $risk_level, $reason" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
}

# Log system information for debugging
log_system_info() {
    # Only allow once per session
    [[ -n "${MOLE_SYS_INFO_LOGGED:-}" ]] && return 0
    export MOLE_SYS_INFO_LOGGED=1

    # Reset debug log file for this new session
    ensure_user_file "$DEBUG_LOG_FILE"
    if ! : > "$DEBUG_LOG_FILE" 2> /dev/null; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Debug log not writable: $DEBUG_LOG_FILE" >&2
    fi

    # Start block in debug log file
    {
        echo "----------------------------------------------------------------------"
        echo "Mole Debug Session, $(date '+%Y-%m-%d %H:%M:%S')"
        echo "----------------------------------------------------------------------"
        echo "User: $USER"
        echo "Hostname: $(hostname)"
        echo "Architecture: $(uname -m)"
        echo "Kernel: $(uname -r)"
        if command -v sw_vers > /dev/null; then
            echo "macOS: $(sw_vers -productVersion), $(sw_vers -buildVersion)"
        fi
        echo "Shell: ${SHELL:-unknown}, ${TERM:-unknown}"

        # Check sudo status non-interactively (skip in test mode)
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
            echo "Sudo Access: Skipped (test mode)"
        elif sudo -n true 2> /dev/null; then
            echo "Sudo Access: Active"
        else
            echo "Sudo Access: Required"
        fi
        echo "----------------------------------------------------------------------"
    } >> "$DEBUG_LOG_FILE" 2> /dev/null || true

    # Notification to stderr
    echo -e "${GRAY}[DEBUG] Debug logging enabled. Session log: $DEBUG_LOG_FILE${NC}" >&2
}

# ============================================================================
# Formatted Output
# ============================================================================

# Print formatted summary block
print_summary_block() {
    local heading=""
    local -a details=()
    local saw_heading=false

    # Parse arguments
    for arg in "$@"; do
        if [[ "$saw_heading" == "false" ]]; then
            saw_heading=true
            heading="$arg"
        else
            details+=("$arg")
        fi
    done

    local _tw
    _tw=$(tput cols 2> /dev/null || echo 70)
    [[ "$_tw" =~ ^[0-9]+$ ]] || _tw=70
    [[ $_tw -gt 70 ]] && _tw=70
    local divider
    divider=$(printf '%*s' "$_tw" '' | tr ' ' '=')

    # Print with dividers
    echo ""
    echo "$divider"
    if [[ -n "$heading" ]]; then
        echo -e "${BLUE}${heading}${NC}"
    fi

    # Print details
    for detail in "${details[@]}"; do
        [[ -z "$detail" ]] && continue
        echo -e "${detail}"
    done
    echo "$divider"

    # If debug mode is on, remind user about the log file location
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        echo -e "${GRAY}Debug session log saved to:${NC} ${DEBUG_LOG_FILE}"
    fi
}

# ============================================================================
# Initialize Logging
# ============================================================================

# Perform log rotation check on module load
rotate_log_once

# If debug mode is enabled, log system info immediately
if [[ "${MO_DEBUG:-}" == "1" ]]; then
    log_system_info
fi
