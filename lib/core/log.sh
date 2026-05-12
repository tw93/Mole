#!/bin/bash
# Roomy - Logging System
# Centralized logging with rotation support

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${ROOMY_LOG_LOADED:-}" ]]; then
    return 0
fi
readonly ROOMY_LOG_LOADED=1

# Ensure base.sh is loaded for colors and icons
if [[ -z "${ROOMY_BASE_LOADED:-}" ]]; then
    _ROOMY_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/core/base.sh
    source "$_ROOMY_CORE_DIR/base.sh"
fi

# ============================================================================
# Logging Configuration
# ============================================================================

ROOMY_LOG_DIR="${ROOMY_LOG_DIR:-${HOME}/Library/Logs/roomy}"
readonly LOG_FILE="${ROOMY_LOG_DIR}/roomy.log"
readonly DEBUG_LOG_FILE="${ROOMY_LOG_DIR}/roomy_debug_session.log"
readonly OPERATIONS_LOG_FILE="${ROOMY_LOG_DIR}/operations.log"
readonly OPERATION_JOURNAL_FILE="${ROOMY_OPERATION_JOURNAL_FILE:-${ROOMY_LOG_DIR}/operation_journal.jsonl}"
readonly LOG_MAX_SIZE_DEFAULT=1048576   # 1MB
readonly OPLOG_MAX_SIZE_DEFAULT=5242880 # 5MB

# Ensure log directory and file exist with correct ownership
ensure_user_file "$LOG_FILE"
if [[ "${ROOMY_NO_OPLOG:-}" != "1" ]]; then
    ensure_user_file "$OPERATIONS_LOG_FILE"
    ensure_user_file "$OPERATION_JOURNAL_FILE"
fi

# ============================================================================
# Log Rotation
# ============================================================================

append_log_line() {
    local file_path="$1"
    local line="${2:-}"

    ensure_user_file "$file_path"
    printf '%s\n' "$line" >> "$file_path" 2> /dev/null || true
}

append_log_lines() {
    local file_path="$1"
    shift

    ensure_user_file "$file_path"
    printf '%s\n' "$@" >> "$file_path" 2> /dev/null || true
}

# Rotate log file if it exceeds maximum size
rotate_log_once() {
    # Skip if already checked this session
    [[ -n "${ROOMY_LOG_ROTATED:-}" ]] && return 0
    export ROOMY_LOG_ROTATED=1

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
    if [[ "${ROOMY_NO_OPLOG:-}" != "1" ]]; then
        local oplog_max_size="$OPLOG_MAX_SIZE_DEFAULT"
        if [[ -f "$OPERATIONS_LOG_FILE" ]]; then
            local size
            size=$(get_file_size "$OPERATIONS_LOG_FILE")
            if [[ "$size" -gt "$oplog_max_size" ]]; then
                mv "$OPERATIONS_LOG_FILE" "${OPERATIONS_LOG_FILE}.old" 2> /dev/null || true
                ensure_user_file "$OPERATIONS_LOG_FILE"
            fi
        fi
        if [[ -f "$OPERATION_JOURNAL_FILE" ]]; then
            local journal_size
            journal_size=$(get_file_size "$OPERATION_JOURNAL_FILE")
            if [[ "$journal_size" -gt "$oplog_max_size" ]]; then
                mv "$OPERATION_JOURNAL_FILE" "${OPERATION_JOURNAL_FILE}.old" 2> /dev/null || true
                ensure_user_file "$OPERATION_JOURNAL_FILE"
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

# Log informational message
log_info() {
    echo -e "${BLUE}$1${NC}"
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] INFO: $1"
    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] INFO: $1"
    fi
}

# Log success message
log_success() {
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] SUCCESS: $1"
    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] SUCCESS: $1"
    fi
}

# shellcheck disable=SC2329
log_warning() {
    echo -e "${YELLOW}$1${NC}"
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] WARNING: $1"
    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] WARNING: $1"
    fi
}

# shellcheck disable=SC2329
log_error() {
    echo -e "${YELLOW}${ICON_ERROR}${NC} $1" >&2
    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$LOG_FILE" "[$timestamp] ERROR: $1"
    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] ERROR: $1"
    fi
}

# shellcheck disable=SC2329
debug_log() {
    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
        echo -e "${GRAY}[DEBUG]${NC} $*" >&2
        local timestamp
        timestamp=$(get_timestamp)
        append_log_line "$DEBUG_LOG_FILE" "[$timestamp] DEBUG: $*"
    fi
}

# Phase-level performance timing, gated behind ROOMY_DEBUG=1.
# Uses perl for millisecond precision; falls back to date +%s.
debug_timer_start() {
    [[ "${ROOMY_DEBUG:-}" != "1" ]] && return 0
    local varname="$1"
    local ts
    ts=$(perl -MTime::HiRes -e 'printf "%.3f\n", Time::HiRes::time()' 2> /dev/null || date +%s)
    eval "$varname=$ts"
}

debug_timer_end() {
    [[ "${ROOMY_DEBUG:-}" != "1" ]] && return 0
    local label="$1"
    local start_var="$2"
    local start_ts
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
# Disable with ROOMY_NO_OPLOG=1

oplog_enabled() {
    [[ "${ROOMY_NO_OPLOG:-}" != "1" ]]
}

operation_journal_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

log_operation_journal_record() {
    oplog_enabled || return 0

    local record_type="${1:-operation}"
    local command="${2:-roomy}"
    local action="${3:-UNKNOWN}"
    local path="${4:-}"
    local detail="${5:-}"
    local timestamp
    timestamp=$(get_timestamp)

    local record
    record=$(printf '{"schema_version":1,"timestamp":"%s","record_type":"%s","command":"%s","action":"%s","path":"%s","detail":"%s"}' \
        "$(operation_journal_escape "$timestamp")" \
        "$(operation_journal_escape "$record_type")" \
        "$(operation_journal_escape "$command")" \
        "$(operation_journal_escape "$action")" \
        "$(operation_journal_escape "$path")" \
        "$(operation_journal_escape "$detail")")
    append_log_line "$OPERATION_JOURNAL_FILE" "$record"
}

log_operation_event_json() {
    oplog_enabled || return 0

    local source="${1:-api}"
    local payload="${2:-}"
    [[ -n "$payload" ]] || return 0

    local timestamp
    timestamp=$(get_timestamp)
    append_log_line "$OPERATION_JOURNAL_FILE" "$(printf '{"schema_version":1,"timestamp":"%s","record_type":"event","source":"%s","payload":%s}' \
        "$(operation_journal_escape "$timestamp")" \
        "$(operation_journal_escape "$source")" \
        "$payload")"
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

    local log_line="[$timestamp] [$command] $action $path"
    [[ -n "$detail" ]] && log_line+=" ($detail)"

    append_log_line "$OPERATIONS_LOG_FILE" "$log_line"
    log_operation_journal_record "operation" "$command" "$action" "$path" "$detail"
}

# Log session start marker
# Usage: log_operation_session_start <command>
log_operation_session_start() {
    oplog_enabled || return 0

    local command="${1:-roomy}"
    local timestamp
    timestamp=$(get_timestamp)

    append_log_lines \
        "$OPERATIONS_LOG_FILE" \
        "" \
        "# ========== $command session started at $timestamp =========="
    log_operation_journal_record "session" "$command" "STARTED" "" ""
}

# shellcheck disable=SC2329
log_operation_session_end() {
    oplog_enabled || return 0

    local command="${1:-roomy}"
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
        "# ========== $command session ended at $timestamp, $items items, $size_human =========="
    log_operation_journal_record "session" "$command" "ENDED" "" "$items items, $size_human"
}

# Enhanced debug logging for operations
debug_operation_start() {
    local operation_name="$1"
    local operation_desc="${2:-}"

    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
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

    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
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

    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
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

    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
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
    [[ -n "${ROOMY_SYS_INFO_LOGGED:-}" ]] && return 0
    export ROOMY_SYS_INFO_LOGGED=1

    # Reset debug log file for this new session
    ensure_user_file "$DEBUG_LOG_FILE"
    if ! : > "$DEBUG_LOG_FILE" 2> /dev/null; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Debug log not writable: $DEBUG_LOG_FILE" >&2
    fi

    # Start block in debug log file
    {
        echo "----------------------------------------------------------------------"
        echo "Roomy Debug Session, $(date '+%Y-%m-%d %H:%M:%S')"
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
        if [[ "${ROOMY_TEST_MODE:-0}" == "1" || "${ROOMY_TEST_NO_AUTH:-0}" == "1" ]]; then
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
# Command Execution Wrappers
# ============================================================================

# Run command silently (ignore errors)
run_silent() {
    "$@" > /dev/null 2>&1 || true
}

# Run command with error logging
run_logged() {
    local cmd="$1"
    # Log to main file, and also to debug file if enabled
    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
        if ! "$@" 2>&1 | tee -a "$LOG_FILE" | tee -a "$DEBUG_LOG_FILE" > /dev/null; then
            log_warning "Command failed: $cmd"
            return 1
        fi
    else
        if ! "$@" 2>&1 | tee -a "$LOG_FILE" > /dev/null; then
            log_warning "Command failed: $cmd"
            return 1
        fi
    fi
    return 0
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
    if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
        echo -e "${GRAY}Debug session log saved to:${NC} ${DEBUG_LOG_FILE}"
    fi
}

# ============================================================================
# Initialize Logging
# ============================================================================

# Perform log rotation check on module load
rotate_log_once

# If debug mode is enabled, log system info immediately
if [[ "${ROOMY_DEBUG:-}" == "1" ]]; then
    log_system_info
fi
