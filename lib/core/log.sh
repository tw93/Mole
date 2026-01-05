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

readonly LOG_FILE="${HOME}/.config/mole/mole.log"
readonly DEBUG_LOG_FILE="${HOME}/.config/mole/mole_debug_session.log"
readonly LOG_MAX_SIZE_DEFAULT=1048576 # 1MB

# Ensure log directory and file exist with correct ownership
ensure_user_file "$LOG_FILE"

# ============================================================================
# Log Rotation
# ============================================================================

# Rotate log file if it exceeds maximum size
rotate_log_once() {
    # Skip if already checked this session
    [[ -n "${MOLE_LOG_ROTATED:-}" ]] && return 0
    export MOLE_LOG_ROTATED=1

    local max_size="$LOG_MAX_SIZE_DEFAULT"
    if [[ -f "$LOG_FILE" ]] && [[ $(get_file_size "$LOG_FILE") -gt "$max_size" ]]; then
        mv -- "$LOG_FILE" "${LOG_FILE}.old" 2> /dev/null || true
        ensure_user_file "$LOG_FILE"
    fi
}

# ============================================================================
# Logging Functions
# ============================================================================

# Log informational message
log_info() {
    echo -e "${BLUE}$1${NC}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] INFO: $1" >> "$LOG_FILE" 2> /dev/null || true
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        echo "[$timestamp] INFO: $1" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
}

# Log success message
log_success() {
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] SUCCESS: $1" >> "$LOG_FILE" 2> /dev/null || true
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        echo "[$timestamp] SUCCESS: $1" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
}

# Log warning message
log_warning() {
    echo -e "${YELLOW}$1${NC}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] WARNING: $1" >> "$LOG_FILE" 2> /dev/null || true
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        echo "[$timestamp] WARNING: $1" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
}

# Log error message
log_error() {
    echo -e "${YELLOW}${ICON_ERROR}${NC} $1" >&2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ERROR: $1" >> "$LOG_FILE" 2> /dev/null || true
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        echo "[$timestamp] ERROR: $1" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
}

# Debug logging (active when MO_DEBUG=1)
debug_log() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        echo -e "${GRAY}[DEBUG]${NC} $*" >&2
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
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
        {
            echo ""
            echo "=== $operation_name ==="
            [[ -n "$operation_desc" ]] && echo "Description: $operation_desc"
        } >> "$DEBUG_LOG_FILE" 2> /dev/null || true
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
        echo "$detail_type: $detail_value" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
}

# Log individual file action with metadata
debug_file_action() {
    local action="$1" # e.g., "Would remove", "Removing"
    local file_path="$2"
    local file_size="${3:-}"
    local file_age="${4:-}"

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        local msg="  - $file_path"
        [[ -n "$file_size" ]] && msg+=" ($file_size"
        [[ -n "$file_age" ]] && msg+=", ${file_age} days old"
        [[ -n "$file_size" ]] && msg+=")"

        # Output to stderr
        echo -e "${GRAY}[DEBUG] $action: $msg${NC}" >&2

        # Also log to file
        echo "$action: $msg" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
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
        echo -e "${GRAY}[DEBUG] Risk Level: ${color}${risk_level}${GRAY} ($reason)${NC}" >&2

        # Also log to file
        echo "Risk Level: $risk_level ($reason)" >> "$DEBUG_LOG_FILE" 2> /dev/null || true
    fi
}

# Log system information for debugging
log_system_info() {
    # Only allow once per session
    [[ -n "${MOLE_SYS_INFO_LOGGED:-}" ]] && return 0
    export MOLE_SYS_INFO_LOGGED=1

    # Reset debug log file for this new session
    ensure_user_file "$DEBUG_LOG_FILE"
    : > "$DEBUG_LOG_FILE"

    # Start block in debug log file
    {
        echo "----------------------------------------------------------------------"
        echo "Mole Debug Session - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "----------------------------------------------------------------------"
        echo "User: $USER"
        echo "Hostname: $(hostname)"
        echo "Architecture: $(uname -m)"
        echo "Kernel: $(uname -r)"
        if command -v sw_vers > /dev/null; then
            echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
        fi
        echo "Shell: ${SHELL:-unknown} (${TERM:-unknown})"

        # Check sudo status non-interactively
        if sudo -n true 2> /dev/null; then
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
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
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

    local divider="======================================================================"

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
