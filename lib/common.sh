#!/bin/bash
# Mole - Common Functions Library
# Shared utilities and functions for all modules

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_COMMON_LOADED=1

# Color definitions (readonly for safety)
readonly ESC=$'\033'
readonly GREEN="${ESC}[0;32m"
readonly BLUE="${ESC}[0;34m"
readonly YELLOW="${ESC}[1;33m"
readonly PURPLE="${ESC}[0;35m"
readonly RED="${ESC}[0;31m"
readonly GRAY="${ESC}[0;90m"
readonly NC="${ESC}[0m"

# Icon definitions
readonly ICON_CONFIRM="◎"      # Confirm operation
readonly ICON_ADMIN="●"        # Admin permission
readonly ICON_SUCCESS="✓"      # Success
readonly ICON_ERROR="✗"        # Error
readonly ICON_EMPTY="○"        # Empty state
readonly ICON_LIST="-"         # List item
readonly ICON_MENU="▸"         # Menu item

# Spinner character helpers (ASCII by default, overridable via env)
mo_spinner_chars() {
    local chars="${MO_SPINNER_CHARS:-|/-\\}"
    [[ -z "$chars" ]] && chars='|/-\\'
    printf "%s" "$chars"
}

# Logging configuration
readonly LOG_FILE="${HOME}/.config/mole/mole.log"
readonly LOG_MAX_SIZE_DEFAULT=1048576  # 1MB

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Log file maintenance (must be defined before logging functions)
rotate_log() {
    local max_size="${MOLE_MAX_LOG_SIZE:-$LOG_MAX_SIZE_DEFAULT}"
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0) -gt "$max_size" ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
        touch "$LOG_FILE" 2>/dev/null || true
    fi
}

# Enhanced logging functions with file logging support
log_info() {
    rotate_log
    echo -e "${BLUE}$1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_success() {
    rotate_log
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_warning() {
    rotate_log
    echo -e "${YELLOW}$1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    rotate_log
    echo -e "${RED}${ICON_ERROR}${NC} $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_header() {
    rotate_log
    echo -e "\n${PURPLE}${ICON_MENU} $1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SECTION: $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Icon output helpers
icon_confirm() {
    echo -e "${BLUE}${ICON_CONFIRM}${NC} $1"
}

icon_admin() {
    echo -e "${BLUE}${ICON_ADMIN}${NC} $1"
}

icon_success() {
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
}

icon_error() {
    echo -e "  ${RED}${ICON_ERROR}${NC} $1"
}

icon_empty() {
    echo -e "  ${BLUE}${ICON_EMPTY}${NC} $1"
}

icon_list() {
    echo -e "  ${ICON_LIST} $1"
}

icon_menu() {
    local num="$1"
    local text="$2"
    echo -e "${BLUE}${ICON_MENU} ${num}. ${text}${NC}"
}

# System detection
detect_architecture() {
    if [[ "$(uname -m)" == "arm64" ]]; then
        echo "Apple Silicon"
    else
        echo "Intel"
    fi
}

get_free_space() {
    df -h / | awk 'NR==2 {print $4}'
}

# Common UI functions
clear_screen() {
    printf '\033[2J\033[H'
}

hide_cursor() {
    printf '\033[?25l'
}

show_cursor() {
    printf '\033[?25h'
}

# Keyboard input handling (simple and robust)
read_key() {
    local key rest
    # Use macOS bash 3.2 compatible read syntax
    IFS= read -r -s -n 1 key || return 1

    # Some terminals can yield empty on Enter with -n1; treat as ENTER
    if [[ -z "$key" ]]; then
        echo "ENTER"
        return 0
    fi

    case "$key" in
        $'\n'|$'\r') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        'q'|'Q') echo "QUIT" ;;
        'a'|'A') echo "ALL" ;;
        'n'|'N') echo "NONE" ;;
        'd'|'D') echo "DELETE" ;;
        'r'|'R') echo "RETRY" ;;
        '?') echo "HELP" ;;
        'o'|'O') echo "OPEN" ;;
        $'\x03') echo "QUIT" ;;  # Ctrl+C
        $'\x7f'|$'\x08') echo "DELETE" ;;  # Delete key (labeled "delete" on Mac, actually backspace)
        $'\x1b')
            # ESC sequence - could be arrow key, delete key, or ESC alone
            # Read the next two bytes within 1s
            if IFS= read -r -s -n 1 -t 1 rest 2>/dev/null; then
                if [[ "$rest" == "[" ]]; then
                    # Got ESC [, read next character
                    if IFS= read -r -s -n 1 -t 1 rest2 2>/dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;;
                            "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;;
                            "D") echo "LEFT" ;;
                            "3")
                                # Delete key (Fn+Delete): ESC [ 3 ~
                                IFS= read -r -s -n 1 -t 1 rest3 2>/dev/null
                                if [[ "$rest3" == "~" ]]; then
                                    echo "DELETE"
                                else
                                    echo "OTHER"
                                fi
                                ;;
                            "5")
                                # Page Up key: ESC [ 5 ~
                                IFS= read -r -s -n 1 -t 1 rest3 2>/dev/null
                                [[ "$rest3" == "~" ]] && echo "OTHER" || echo "OTHER"
                                ;;
                            "6")
                                # Page Down key: ESC [ 6 ~
                                IFS= read -r -s -n 1 -t 1 rest3 2>/dev/null
                                [[ "$rest3" == "~" ]] && echo "OTHER" || echo "OTHER"
                                ;;
                            *) echo "OTHER" ;;
                        esac
                    else
                        echo "QUIT"  # ESC [ timeout
                    fi
                else
                    echo "QUIT"  # ESC + something else
                fi
            else
                # ESC pressed alone - treat as quit
                echo "QUIT"
            fi
            ;;
        *) echo "OTHER" ;;
    esac
}

# Drain pending input (useful for scrolling prevention)
drain_pending_input() {
    local dummy
    local drained=0
    # Single pass with reasonable timeout
    # Touchpad scrolling can generate bursts of arrow keys
    while IFS= read -r -s -n 1 -t 0.001 dummy 2>/dev/null; do
        ((drained++))
        # Safety limit to prevent infinite loop
        [[ $drained -gt 500 ]] && break
    done
}

# Menu display helper
show_menu_option() {
    local number="$1"
    local text="$2"
    local selected="$3"

    if [[ "$selected" == "true" ]]; then
        echo -e "${BLUE}▶ $number. $text${NC}"
    else
        echo "  $number. $text"
    fi
}

# Error handling
handle_error() {
    local message="$1"
    local exit_code="${2:-1}"

    log_error "$message"
    exit "$exit_code"
}

# File size utilities
get_human_size() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        echo "N/A"
        return 1
    fi
    du -sh "$path" 2>/dev/null | cut -f1 || echo "N/A"
}

# Convert bytes to human readable format
bytes_to_human() {
    local bytes="$1"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0B"
        return 1
    fi

    if ((bytes >= 1073741824)); then  # >= 1GB
        echo "$bytes" | awk '{printf "%.2fGB", $1/1073741824}'
    elif ((bytes >= 1048576)); then  # >= 1MB
        echo "$bytes" | awk '{printf "%.1fMB", $1/1048576}'
    elif ((bytes >= 1024)); then     # >= 1KB
        echo "$bytes" | awk '{printf "%.0fKB", $1/1024}'
    else
        echo "${bytes}B"
    fi
}

# Calculate directory size in bytes
get_directory_size_bytes() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo "0"
        return 1
    fi
    du -sk "$path" 2>/dev/null | cut -f1 | awk '{print $1 * 1024}' || echo "0"
}


# Permission checks
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        return 1
    fi
    return 0
}

# Check if Touch ID is configured for sudo
check_touchid_support() {
    if [[ -f /etc/pam.d/sudo ]]; then
        grep -q "pam_tid.so" /etc/pam.d/sudo 2>/dev/null
        return $?
    fi
    return 1
}

# Request sudo access with Touch ID support
# Usage: request_sudo_access "prompt message" [optional: force_password]
request_sudo_access() {
    local prompt_msg="${1:-Admin access required}"
    local force_password="${2:-false}"

    # Check if already has sudo access
    if sudo -n true 2>/dev/null; then
        return 0
    fi

    # If Touch ID is supported and not forced to use password
    if [[ "$force_password" != "true" ]] && check_touchid_support; then
        echo -e "${BLUE}${ICON_ADMIN}${NC} ${prompt_msg} ${GRAY}(Touch ID or password)${NC}"
        if sudo -v 2>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        # Traditional password method
        echo -e "${BLUE}${ICON_ADMIN}${NC} ${prompt_msg}"
        echo -ne "${BLUE}${ICON_MENU}${NC} Password: "
        read -s password
        echo ""
        if [[ -n "$password" ]] && echo "$password" | sudo -S true 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
}

request_sudo() {
    echo "This operation requires administrator privileges."
    echo -n "Please enter your password: "
    read -s password
    echo
    if echo "$password" | sudo -S true 2>/dev/null; then
        return 0
    else
        log_error "Invalid password or cancelled"
        return 1
    fi
}

# Homebrew update utilities
update_via_homebrew() {
    local version="${1:-unknown}"

    if [[ -t 1 ]]; then
        start_inline_spinner "Updating Homebrew..."
    else
        echo "Updating Homebrew..."
    fi
    # Filter out common noise but show important info
    brew update 2>&1 | grep -Ev "^(==>|Already up-to-date)" || true
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "Upgrading Mole..."
    else
        echo "Upgrading Mole..."
    fi
    local upgrade_output
    upgrade_output=$(brew upgrade mole 2>&1) || true
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if echo "$upgrade_output" | grep -q "already installed"; then
        # Get current version
        local current_version
        current_version=$(brew list --versions mole 2>/dev/null | awk '{print $2}')
        echo -e "${GREEN}✓${NC} Already on latest version (${current_version:-$version})"
    elif echo "$upgrade_output" | grep -q "Error:"; then
        log_error "Homebrew upgrade failed"
        echo "$upgrade_output" | grep "Error:" >&2
        return 1
    else
        # Show relevant output, filter noise
        echo "$upgrade_output" | grep -Ev "^(==>|Updating Homebrew|Warning:)" || true
        # Get new version
        local new_version
        new_version=$(brew list --versions mole 2>/dev/null | awk '{print $2}')
        echo -e "${GREEN}✓${NC} Updated to latest version (${new_version:-$version})"
    fi

    # Clear version check cache
    rm -f "$HOME/.cache/mole/version_check" "$HOME/.cache/mole/update_message"
    return 0
}

# Load basic configuration
load_config() {
    MOLE_MAX_LOG_SIZE="${MOLE_MAX_LOG_SIZE:-1048576}"
}





# Initialize configuration on sourcing
load_config

# ============================================================================
# Spinner and Progress Indicators
# ============================================================================

# Global spinner process IDs
SPINNER_PID=""
INLINE_SPINNER_PID=""

# Start a full-line spinner with message
start_spinner() {
    local message="$1"

    if [[ ! -t 1 ]]; then
        echo -n "  ${BLUE}|${NC} $message"
        return
    fi

    echo -n "  ${BLUE}|${NC} $message"
    (
        local delay=0.5
        while true; do
            printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}|${NC} $message.  "
            sleep $delay
            printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}|${NC} $message.. "
            sleep $delay
            printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}|${NC} $message..."
            sleep $delay
            printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}|${NC} $message    "
            sleep $delay
        done
    ) &
    SPINNER_PID=$!
}

# Start an inline spinner (rotating character)
start_inline_spinner() {
    stop_inline_spinner 2>/dev/null || true
    local message="$1"

    if [[ -t 1 ]]; then
        (
            trap 'exit 0' TERM INT EXIT
            local chars
            chars="$(mo_spinner_chars)"
            [[ -z "$chars" ]] && chars='|/-\'
            local i=0
            while true; do
                local c="${chars:$((i % ${#chars})):1}"
                printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}%s${NC} %s" "$c" "$message" 2>/dev/null || exit 0
                ((i++))
                # macOS supports decimal sleep, this is the primary target
                sleep 0.1 2>/dev/null || sleep 1 2>/dev/null || exit 0
            done
        ) &
        INLINE_SPINNER_PID=$!
        disown 2>/dev/null || true
    else
        echo -n "  ${BLUE}|${NC} $message"
    fi
}

# Stop inline spinner
stop_inline_spinner() {
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        kill "$INLINE_SPINNER_PID" 2>/dev/null || true
        wait "$INLINE_SPINNER_PID" 2>/dev/null || true
        INLINE_SPINNER_PID=""
        [[ -t 1 ]] && printf "\r\033[K"
    fi
}

# Stop spinner with optional result message
stop_spinner() {
    local result_message="${1:-Done}"

    stop_inline_spinner

    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi

    if [[ -n "$result_message" ]]; then
        if [[ -t 1 ]]; then
            printf "\r${MOLE_SPINNER_PREFIX:-}${GREEN}✓${NC} %s\n" "$result_message"
        else
            echo " ✓ $result_message"
        fi
    fi
}

# ============================================================================
# User Interaction - Confirmation Dialogs
# ============================================================================


# ============================================================================
# Temporary File Management
# ============================================================================

# Global temp file tracking
declare -a MOLE_TEMP_FILES=()
declare -a MOLE_TEMP_DIRS=()

# Create tracked temporary file
# Returns: temp file path
create_temp_file() {
    local temp
    temp=$(mktemp) || return 1
    MOLE_TEMP_FILES+=("$temp")
    echo "$temp"
}

# Create tracked temporary directory
# Returns: temp directory path
create_temp_dir() {
    local temp
    temp=$(mktemp -d) || return 1
    MOLE_TEMP_DIRS+=("$temp")
    echo "$temp"
}

# Create temp file with prefix (for analyze.sh compatibility)
# Args: $1 - prefix/suffix string
# Returns: temp file path
create_temp_file_named() {
    local suffix="${1:-}"
    local temp
    temp=$(mktemp "/tmp/mole_${suffix}_XXXXXX") || return 1
    MOLE_TEMP_FILES+=("$temp")
    echo "$temp"
}

# Cleanup all tracked temp files
cleanup_temp_files() {
    local file
    if [[ ${#MOLE_TEMP_FILES[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_FILES[@]}"; do
            [[ -f "$file" ]] && rm -f "$file" 2>/dev/null || true
        done
    fi

    if [[ ${#MOLE_TEMP_DIRS[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_DIRS[@]}"; do
            [[ -d "$file" ]] && rm -rf "$file" 2>/dev/null || true
        done
    fi

    MOLE_TEMP_FILES=()
    MOLE_TEMP_DIRS=()
}

# Auto-cleanup on script exit (call this in main scripts)
register_temp_cleanup() {
    trap cleanup_temp_files EXIT INT TERM
}

# ============================================================================
# Parallel Processing Framework
# ============================================================================

# Execute commands in parallel with job control
# Args: $1 - max parallel jobs
#       $2 - worker function name
#       $3+ - items to process
parallel_execute() {
    local max_jobs="${1:-12}"
    local worker_func="$2"
    shift 2
    local -a items=("$@")

    if [[ ${#items[@]} -eq 0 ]]; then
        return 0
    fi

    local -a pids=()
    for item in "${items[@]}"; do
        # Execute worker function in background
        "$worker_func" "$item" &
        pids+=($!)

        # Wait for a slot if we've hit max parallel jobs
        if (( ${#pids[@]} >= max_jobs )); then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
        fi
    done

# Wait for remaining background jobs
    if (( ${#pids[@]} > 0 )); then
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    fi
}

# ============================================================================
# Lightweight spinner helper wrappers
# ============================================================================
# Usage: with_spinner "Message" cmd arg...
# Set MOLE_SPINNER_PREFIX="  " for indented spinner (e.g., in clean context)
with_spinner() {
    local msg="$1"; shift || true
    local timeout="${MOLE_CMD_TIMEOUT:-180}"  # Default 3min timeout

    if [[ -t 1 ]]; then
        start_inline_spinner "$msg"
    fi

    # Run command with timeout protection
    if command -v timeout >/dev/null 2>&1; then
        # GNU timeout available
        timeout "$timeout" "$@" >/dev/null 2>&1 || {
            local exit_code=$?
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            # Exit code 124 means timeout
            [[ $exit_code -eq 124 ]] && echo -e "  ${YELLOW}⚠${NC} $msg timed out (skipped)" >&2
            return $exit_code
        }
    else
        # Fallback: run in background with manual timeout
        "$@" >/dev/null 2>&1 &
        local cmd_pid=$!
        local elapsed=0
        while kill -0 $cmd_pid 2>/dev/null; do
            if [[ $elapsed -ge $timeout ]]; then
                kill -TERM $cmd_pid 2>/dev/null || true
                wait $cmd_pid 2>/dev/null || true
                if [[ -t 1 ]]; then stop_inline_spinner; fi
                echo -e "  ${YELLOW}⚠${NC} $msg timed out (skipped)" >&2
                return 124
            fi
            sleep 1
            ((elapsed++))
        done
        wait $cmd_pid 2>/dev/null || {
            local exit_code=$?
            if [[ -t 1 ]]; then stop_inline_spinner; fi
            return $exit_code
        }
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
}

# ============================================================================
# Cache/tool cleanup abstraction
# ============================================================================
# clean_tool_cache "Label" command...
clean_tool_cache() {
    local label="$1"; shift || true
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}→${NC} $label (would clean)"
        return 0
    fi
    if MOLE_SPINNER_PREFIX="  " with_spinner "$label" "$@"; then
        echo -e "  ${GREEN}✓${NC} $label"
    else
        local exit_code=$?
        # Timeout returns 124, don't show error message (already shown by with_spinner)
        if [[ $exit_code -ne 124 ]]; then
            echo -e "  ${YELLOW}⚠${NC} $label failed (skipped)" >&2
        fi
    fi
    return 0  # Always return success to continue cleanup
}

# ============================================================================
# Confirmation prompt abstraction (Enter=confirm ESC/q=cancel)
# confirm_prompt "Message" -> 0 yes, 1 no
confirm_prompt() {
    local message="$1"
    echo -n "$message (Enter=OK / ESC q=Cancel): "
    IFS= read -r -s -n1 _key || _key=""
    case "$_key" in
        $'\e'|q|Q) echo ""; return 1 ;;
        ""|$'\n'|$'\r'|y|Y) echo ""; return 0 ;;
        *) echo ""; return 1 ;;
    esac
}


# Get optimal parallel job count based on CPU cores

# =========================================================================
# Size helpers
# =========================================================================
bytes_to_human_kb() { bytes_to_human "$(( ${1:-0} * 1024 ))"; }
print_space_stat() {
    local freed_kb="$1"; shift || true
    local current_free
    current_free=$(get_free_space)
    local human
    human=$(bytes_to_human_kb "$freed_kb")
    echo "Space freed: ${GREEN}${human}${NC} | Free space now: $current_free"
}

# =========================================================================
# mktemp unification wrappers (register access)
# =========================================================================
register_temp_file() { MOLE_TEMP_FILES+=("$1"); }
register_temp_dir()  { MOLE_TEMP_DIRS+=("$1"); }

mktemp_file() { local f; f=$(mktemp) || return 1; register_temp_file "$f"; echo "$f"; }
mktemp_dir()  { local d; d=$(mktemp -d) || return 1; register_temp_dir "$d"; echo "$d"; }

# =========================================================================
# Uninstall helper abstractions
# =========================================================================
force_kill_app() {
    # Args: app_name; tries graceful then force kill; returns 0 if stopped, 1 otherwise
    local app="$1"
    if pgrep -f "$app" >/dev/null 2>&1; then
        pkill -f "$app" 2>/dev/null || true
        sleep 1
    fi
    if pgrep -f "$app" >/dev/null 2>&1; then
        pkill -9 -f "$app" 2>/dev/null || true
        sleep 1
    fi
    pgrep -f "$app" >/dev/null 2>&1 && return 1 || return 0
}

map_uninstall_reason() {
    # Args: reason_token
    case "$1" in
        still*running*) echo "was not removed; it remains running and resisted termination." ;;
        remove*failed*) echo "was not removed due to a removal failure (permissions or protection)." ;;
        permission*) echo "was not removed due to insufficient permissions." ;;
        *) echo "was not removed; $1." ;;
    esac
}

batch_safe_clean() {
    # Usage: batch_safe_clean "Label" path1 path2 ...
    local label="$1"; shift || true
    local -a paths=("$@")
    if [[ ${#paths[@]} -eq 0 ]]; then return 0; fi
    safe_clean "${paths[@]}" "$label"
}

# Get optimal parallel job count based on CPU cores
get_optimal_parallel_jobs() {
    local operation_type="${1:-default}"
    local cpu_cores
    cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    case "$operation_type" in
        scan|io)
            echo $((cpu_cores * 2))
            ;;
        compute)
            echo "$cpu_cores"
            ;;
        *)
            echo $((cpu_cores + 2))
            ;;
    esac
}

# ============================================================================
# Sudo Keepalive Management
# ============================================================================

# Start sudo keepalive process
# Returns: PID of the keepalive process
start_sudo_keepalive() {
    (
        local retry_count=0
        while true; do
            if ! sudo -n true 2>/dev/null; then
                ((retry_count++))
                if [[ $retry_count -ge 3 ]]; then
                    exit 1
                fi
                sleep 5
                continue
            fi
            retry_count=0
            sleep 30
            kill -0 "$$" 2>/dev/null || exit
        done
    ) 2>/dev/null &
    echo $!
}

# Stop sudo keepalive process
# Args: $1 - PID of the keepalive process
stop_sudo_keepalive() {
    local pid="${1:-}"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# ============================================================================
# Section Management
# ============================================================================

# Section tracking variables
TRACK_SECTION=0
SECTION_ACTIVITY=0

# Start a new section
start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    echo ""
    echo -e "${PURPLE}▶ $1${NC}"
}

# End a section (show "Nothing to tidy" if no activity)
end_section() {
    if [[ $TRACK_SECTION -eq 1 && $SECTION_ACTIVITY -eq 0 ]]; then
        echo -e "  ${BLUE}○${NC} Nothing to tidy"
    fi
    TRACK_SECTION=0
}

# Mark activity in current section
note_activity() {
    if [[ $TRACK_SECTION -eq 1 ]]; then
        SECTION_ACTIVITY=1
    fi
}

# ============================================================================
# App Management Functions
# ============================================================================

# System critical components that should NEVER be uninstalled
readonly SYSTEM_CRITICAL_BUNDLES=(
    "com.apple.*"  # System essentials
    "loginwindow"
    "dock"
    "systempreferences"
    "finder"
    "safari"
    "keychain*"
    "security*"
    "bluetooth*"
    "wifi*"
    "network*"
    "tcc"
    "notification*"
    "accessibility*"
    "universalaccess*"
    "HIToolbox*"
    "textinput*"
    "TextInput*"
    "keyboard*"
    "Keyboard*"
    "inputsource*"
    "InputSource*"
    "keylayout*"
    "KeyLayout*"
    "GlobalPreferences"
    ".GlobalPreferences"
    # Input methods (critical for international users)
    "com.tencent.inputmethod.QQInput"
    "com.sogou.inputmethod.*"
    "com.baidu.inputmethod.*"
    "com.apple.inputmethod.*"
    "com.googlecode.rimeime.*"
    "im.rime.*"
    "org.pqrs.Karabiner*"
    "*.inputmethod"
    "*.InputMethod"
    "*IME"
    "com.apple.inputsource*"
    "com.apple.TextInputMenuAgent"
    "com.apple.TextInputSwitcher"
)

# Apps with important data/licenses - protect during cleanup but allow uninstall
readonly DATA_PROTECTED_BUNDLES=(
    # ============================================================================
    # System Utilities & Cleanup Tools
    # ============================================================================
    "com.nektony.*"                    # App Cleaner & Uninstaller
    "com.macpaw.*"                     # CleanMyMac, CleanMaster
    "com.freemacsoft.AppCleaner"       # AppCleaner
    "com.omnigroup.omnidisksweeper"    # OmniDiskSweeper
    "com.daisydiskapp.*"               # DaisyDisk
    "com.tunabellysoftware.*"          # Disk Utility apps
    "com.grandperspectiv.*"            # GrandPerspective
    "com.binaryfruit.*"                # FusionCast

    # ============================================================================
    # Password Managers & Security
    # ============================================================================
    "com.1password.*"                  # 1Password
    "com.agilebits.*"                  # 1Password legacy
    "com.lastpass.*"                   # LastPass
    "com.dashlane.*"                   # Dashlane
    "com.bitwarden.*"                  # Bitwarden
    "com.keepassx.*"                   # KeePassXC
    "org.keepassx.*"                   # KeePassX
    "com.authy.*"                      # Authy
    "com.yubico.*"                     # YubiKey Manager

    # ============================================================================
    # Development Tools - IDEs & Editors
    # ============================================================================
    "com.jetbrains.*"                  # JetBrains IDEs (IntelliJ, DataGrip, etc.)
    "JetBrains*"                       # JetBrains Application Support folders
    "com.microsoft.VSCode"             # Visual Studio Code
    "com.visualstudio.code.*"          # VS Code variants
    "com.sublimetext.*"                # Sublime Text
    "com.sublimehq.*"                  # Sublime Merge
    "com.microsoft.VSCodeInsiders"     # VS Code Insiders
    "com.apple.dt.Xcode"               # Xcode (keep settings)
    "com.coteditor.CotEditor"          # CotEditor
    "com.macromates.TextMate"          # TextMate
    "com.panic.Nova"                   # Nova
    "abnerworks.Typora"                # Typora (Markdown editor)
    "com.uranusjr.macdown"             # MacDown

    # ============================================================================
    # Development Tools - Database Clients
    # ============================================================================
    "com.sequelpro.*"                  # Sequel Pro
    "com.sequel-ace.*"                 # Sequel Ace
    "com.tinyapp.*"                    # TablePlus
    "com.dbeaver.*"                    # DBeaver
    "com.navicat.*"                    # Navicat
    "com.mongodb.compass"              # MongoDB Compass
    "com.redis.RedisInsight"           # Redis Insight
    "com.pgadmin.pgadmin4"             # pgAdmin
    "com.eggerapps.Sequel-Pro"         # Sequel Pro legacy
    "com.valentina-db.Valentina-Studio" # Valentina Studio
    "com.dbvis.DbVisualizer"           # DbVisualizer

    # ============================================================================
    # Development Tools - API & Network
    # ============================================================================
    "com.postmanlabs.mac"              # Postman
    "com.konghq.insomnia"              # Insomnia
    "com.CharlesProxy.*"               # Charles Proxy
    "com.proxyman.*"                   # Proxyman
    "com.getpaw.*"                     # Paw
    "com.luckymarmot.Paw"              # Paw legacy
    "com.charlesproxy.charles"         # Charles
    "com.telerik.Fiddler"              # Fiddler
    "com.usebruno.app"                 # Bruno (API client)

    # ============================================================================
    # Development Tools - Git & Version Control
    # ============================================================================
    "com.github.GitHubDesktop"         # GitHub Desktop
    "com.sublimemerge"                 # Sublime Merge
    "com.torusknot.SourceTreeNotMAS"   # SourceTree
    "com.git-tower.Tower*"             # Tower
    "com.gitfox.GitFox"                # GitFox
    "com.github.Gitify"                # Gitify
    "com.fork.Fork"                    # Fork
    "com.axosoft.gitkraken"            # GitKraken

    # ============================================================================
    # Development Tools - Terminal & Shell
    # ============================================================================
    "com.googlecode.iterm2"            # iTerm2
    "net.kovidgoyal.kitty"             # Kitty
    "io.alacritty"                     # Alacritty
    "com.github.wez.wezterm"           # WezTerm
    "com.hyper.Hyper"                  # Hyper
    "com.mizage.divvy"                 # Divvy
    "com.fig.Fig"                      # Fig (terminal assistant)
    "dev.warp.Warp-Stable"             # Warp
    "com.termius-dmg"                  # Termius (SSH client)

    # ============================================================================
    # Development Tools - Docker & Virtualization
    # ============================================================================
    "com.docker.docker"                # Docker Desktop
    "com.getutm.UTM"                   # UTM
    "com.vmware.fusion"                # VMware Fusion
    "com.parallels.desktop.*"          # Parallels Desktop
    "org.virtualbox.app.VirtualBox"    # VirtualBox
    "com.vagrant.*"                    # Vagrant
    "com.orbstack.OrbStack"            # OrbStack

    # ============================================================================
    # System Monitoring & Performance
    # ============================================================================
    "com.bjango.istatmenus*"           # iStat Menus
    "eu.exelban.Stats"                 # Stats
    "com.monitorcontrol.*"             # MonitorControl
    "com.bresink.system-toolkit.*"     # TinkerTool System
    "com.mediaatelier.MenuMeters"      # MenuMeters
    "com.activity-indicator.app"       # Activity Indicator
    "net.cindori.sensei"               # Sensei

    # ============================================================================
    # Window Management & Productivity
    # ============================================================================
    "com.macitbetter.*"                # BetterTouchTool, BetterSnapTool
    "com.hegenberg.*"                  # BetterTouchTool legacy
    "com.manytricks.*"                 # Moom, Witch, Name Mangler, Resolutionator
    "com.divisiblebyzero.*"            # Spectacle
    "com.koingdev.*"                   # Koingg apps
    "com.if.Amphetamine"               # Amphetamine
    "com.lwouis.alt-tab-macos"         # AltTab
    "net.matthewpalmer.Vanilla"        # Vanilla
    "com.lightheadsw.Caffeine"         # Caffeine
    "com.contextual.Contexts"          # Contexts
    "com.amethyst.Amethyst"            # Amethyst
    "com.knollsoft.Rectangle"          # Rectangle
    "com.knollsoft.Hookshot"           # Hookshot
    "com.surteesstudios.Bartender"     # Bartender
    "com.gaosun.eul"                   # eul (system monitor)
    "com.pointum.hazeover"             # HazeOver

    # ============================================================================
    # Launcher & Automation
    # ============================================================================
    "com.runningwithcrayons.Alfred"    # Alfred
    "com.raycast.macos"                # Raycast
    "com.blacktree.Quicksilver"        # Quicksilver
    "com.stairways.keyboardmaestro.*"  # Keyboard Maestro
    "com.manytricks.Butler"            # Butler
    "com.happenapps.Quitter"           # Quitter
    "com.pilotmoon.scroll-reverser"    # Scroll Reverser
    "org.pqrs.Karabiner-Elements"      # Karabiner-Elements
    "com.apple.Automator"              # Automator (system, but keep user workflows)

    # ============================================================================
    # Note-Taking & Documentation
    # ============================================================================
    "com.bear-writer.*"                # Bear
    "com.typora.*"                     # Typora
    "com.ulyssesapp.*"                 # Ulysses
    "com.literatureandlatte.*"         # Scrivener
    "com.dayoneapp.*"                  # Day One
    "notion.id"                        # Notion
    "md.obsidian"                      # Obsidian
    "com.logseq.logseq"                # Logseq
    "com.evernote.Evernote"            # Evernote
    "com.onenote.mac"                  # OneNote
    "com.omnigroup.OmniOutliner*"      # OmniOutliner
    "net.shinyfrog.bear"               # Bear legacy
    "com.goodnotes.GoodNotes"          # GoodNotes
    "com.marginnote.MarginNote*"       # MarginNote
    "com.roamresearch.*"               # Roam Research
    "com.reflect.ReflectApp"           # Reflect
    "com.inkdrop.*"                    # Inkdrop

    # ============================================================================
    # Design & Creative Tools
    # ============================================================================
    "com.adobe.*"                      # Adobe Creative Suite
    "com.bohemiancoding.*"             # Sketch
    "com.figma.*"                      # Figma
    "com.framerx.*"                    # Framer
    "com.zeplin.*"                     # Zeplin
    "com.invisionapp.*"                # InVision
    "com.principle.*"                  # Principle
    "com.pixelmatorteam.*"             # Pixelmator
    "com.affinitydesigner.*"           # Affinity Designer
    "com.affinityphoto.*"              # Affinity Photo
    "com.affinitypublisher.*"          # Affinity Publisher
    "com.linearity.curve"              # Linearity Curve
    "com.canva.CanvaDesktop"           # Canva
    "com.maxon.cinema4d"               # Cinema 4D
    "com.autodesk.*"                   # Autodesk products
    "com.sketchup.*"                   # SketchUp

    # ============================================================================
    # Communication & Collaboration
    # ============================================================================
    "com.tencent.xinWeChat"            # WeChat (Chinese users)
    "com.tencent.qq"                   # QQ
    "com.alibaba.DingTalkMac"          # DingTalk
    "com.alibaba.AliLang.osx"          # AliLang (retain login/config data)
    "com.alibaba.alilang3.osx.ShipIt"  # AliLang updater component
    "com.alibaba.AlilangMgr.QueryNetworkInfo" # AliLang network helper
    "us.zoom.xos"                      # Zoom
    "com.microsoft.teams*"             # Microsoft Teams
    "com.slack.Slack"                  # Slack
    "com.hnc.Discord"                  # Discord
    "org.telegram.desktop"             # Telegram
    "ru.keepcoder.Telegram"            # Telegram legacy
    "net.whatsapp.WhatsApp"            # WhatsApp
    "com.skype.skype"                  # Skype
    "com.cisco.webexmeetings"          # Webex
    "com.ringcentral.RingCentral"      # RingCentral
    "com.readdle.smartemail-Mac"       # Spark Email
    "com.airmail.*"                    # Airmail
    "com.postbox-inc.postbox"          # Postbox
    "com.tinyspeck.slackmacgap"        # Slack legacy

    # ============================================================================
    # Task Management & Productivity
    # ============================================================================
    "com.omnigroup.OmniFocus*"         # OmniFocus
    "com.culturedcode.*"               # Things
    "com.todoist.*"                    # Todoist
    "com.any.do.*"                     # Any.do
    "com.ticktick.*"                   # TickTick
    "com.microsoft.to-do"              # Microsoft To Do
    "com.trello.trello"                # Trello
    "com.asana.nativeapp"              # Asana
    "com.clickup.*"                    # ClickUp
    "com.monday.desktop"               # Monday.com
    "com.airtable.airtable"            # Airtable
    "com.notion.id"                    # Notion (also note-taking)
    "com.linear.linear"                # Linear

    # ============================================================================
    # File Transfer & Sync
    # ============================================================================
    "com.panic.transmit*"              # Transmit (FTP/SFTP)
    "com.binarynights.ForkLift*"       # ForkLift
    "com.noodlesoft.Hazel"             # Hazel
    "com.cyberduck.Cyberduck"          # Cyberduck
    "io.filezilla.FileZilla"           # FileZilla
    "com.apple.Xcode.CloudDocuments"   # Xcode Cloud Documents
    "com.synology.*"                   # Synology apps

    # ============================================================================
    # Screenshot & Recording
    # ============================================================================
    "com.cleanshot.*"                  # CleanShot X
    "com.xnipapp.xnip"                 # Xnip
    "com.reincubate.camo"              # Camo
    "com.tunabellysoftware.ScreenFloat" # ScreenFloat
    "net.telestream.screenflow*"       # ScreenFlow
    "com.techsmith.snagit*"            # Snagit
    "com.techsmith.camtasia*"          # Camtasia
    "com.obsidianapp.screenrecorder"   # Screen Recorder
    "com.kap.Kap"                      # Kap
    "com.getkap.*"                     # Kap legacy
    "com.linebreak.CloudApp"           # CloudApp
    "com.droplr.droplr-mac"            # Droplr

    # ============================================================================
    # Media & Entertainment
    # ============================================================================
    "com.spotify.client"               # Spotify
    "com.apple.Music"                  # Apple Music
    "com.apple.podcasts"               # Apple Podcasts
    "com.apple.FinalCutPro"            # Final Cut Pro
    "com.apple.Motion"                 # Motion
    "com.apple.Compressor"             # Compressor
    "com.blackmagic-design.*"          # DaVinci Resolve
    "com.colliderli.iina"              # IINA
    "org.videolan.vlc"                 # VLC
    "io.mpv"                           # MPV
    "com.noodlesoft.Hazel"             # Hazel (automation)
    "tv.plex.player.desktop"           # Plex
    "com.netease.163music"             # NetEase Music

    # ============================================================================
    # License Management & App Stores
    # ============================================================================
    "com.paddle.Paddle*"               # Paddle (license management)
    "com.setapp.DesktopClient"         # Setapp
    "com.devmate.*"                    # DevMate (license framework)
    "org.sparkle-project.Sparkle"      # Sparkle (update framework)
)


# Legacy function - preserved for backward compatibility
# Use should_protect_from_uninstall() or should_protect_data() instead
readonly PRESERVED_BUNDLE_PATTERNS=("${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}")
should_preserve_bundle() {
    local bundle_id="$1"
    for pattern in "${PRESERVED_BUNDLE_PATTERNS[@]}"; do
        # Use case for safer glob matching
        case "$bundle_id" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# Check if app is a system component that should never be uninstalled
should_protect_from_uninstall() {
    local bundle_id="$1"
    for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}"; do
        # Use case for safer glob matching
        case "$bundle_id" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# Check if app data should be protected during cleanup (but app can be uninstalled)
should_protect_data() {
    local bundle_id="$1"
    # Protect both system critical and data protected bundles during cleanup
    for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}"; do
        # Use case for safer glob matching
        case "$bundle_id" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# Find and list app-related files (consolidated from duplicates)
find_app_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a files_to_clean=()

    # ============================================================================
    # User-level files (no sudo required)
    # ============================================================================

    # Application Support
    [[ -d ~/Library/Application\ Support/"$app_name" ]] && files_to_clean+=("$HOME/Library/Application Support/$app_name")
    [[ -d ~/Library/Application\ Support/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Application Support/$bundle_id")

    # Caches
    [[ -d ~/Library/Caches/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Caches/$bundle_id")
    [[ -d ~/Library/Caches/"$app_name" ]] && files_to_clean+=("$HOME/Library/Caches/$app_name")

    # Preferences
    [[ -f ~/Library/Preferences/"$bundle_id".plist ]] && files_to_clean+=("$HOME/Library/Preferences/$bundle_id.plist")
    while IFS= read -r -d '' pref; do
        files_to_clean+=("$pref")
    done < <(find ~/Library/Preferences/ByHost \( -name "$bundle_id*.plist" \) -print0 2>/dev/null)

    # Logs
    [[ -d ~/Library/Logs/"$app_name" ]] && files_to_clean+=("$HOME/Library/Logs/$app_name")
    [[ -d ~/Library/Logs/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Logs/$bundle_id")

    # Saved Application State
    [[ -d ~/Library/Saved\ Application\ State/"$bundle_id".savedState ]] && files_to_clean+=("$HOME/Library/Saved Application State/$bundle_id.savedState")

    # Containers (sandboxed apps)
    [[ -d ~/Library/Containers/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Containers/$bundle_id")

    # Group Containers
    while IFS= read -r -d '' container; do
        files_to_clean+=("$container")
    done < <(find ~/Library/Group\ Containers -type d \( -name "*$bundle_id*" \) -print0 2>/dev/null)

    # WebKit data
    [[ -d ~/Library/WebKit/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/WebKit/$bundle_id")
    [[ -d ~/Library/WebKit/com.apple.WebKit.WebContent/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/WebKit/com.apple.WebKit.WebContent/$bundle_id")

    # HTTP Storage
    [[ -d ~/Library/HTTPStorages/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/HTTPStorages/$bundle_id")

    # Cookies
    [[ -f ~/Library/Cookies/"$bundle_id".binarycookies ]] && files_to_clean+=("$HOME/Library/Cookies/$bundle_id.binarycookies")

    # Launch Agents (user-level)
    [[ -f ~/Library/LaunchAgents/"$bundle_id".plist ]] && files_to_clean+=("$HOME/Library/LaunchAgents/$bundle_id.plist")

    # Application Scripts
    [[ -d ~/Library/Application\ Scripts/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Application Scripts/$bundle_id")

    # Services
    [[ -d ~/Library/Services/"$app_name".workflow ]] && files_to_clean+=("$HOME/Library/Services/$app_name.workflow")

    # Internet Plug-Ins
    while IFS= read -r -d '' plugin; do
        files_to_clean+=("$plugin")
    done < <(find ~/Library/Internet\ Plug-Ins \( -name "$bundle_id*" -o -name "$app_name*" \) -print0 2>/dev/null)

    # QuickLook Plugins
    [[ -d ~/Library/QuickLook/"$app_name".qlgenerator ]] && files_to_clean+=("$HOME/Library/QuickLook/$app_name.qlgenerator")

    # Preference Panes
    [[ -d ~/Library/PreferencePanes/"$app_name".prefPane ]] && files_to_clean+=("$HOME/Library/PreferencePanes/$app_name.prefPane")

    # Screen Savers
    [[ -d ~/Library/Screen\ Savers/"$app_name".saver ]] && files_to_clean+=("$HOME/Library/Screen Savers/$app_name.saver")

    # Frameworks
    [[ -d ~/Library/Frameworks/"$app_name".framework ]] && files_to_clean+=("$HOME/Library/Frameworks/$app_name.framework")

    # CoreData
    while IFS= read -r -d '' coredata; do
        files_to_clean+=("$coredata")
    done < <(find ~/Library/CoreData \( -name "*$bundle_id*" -o -name "*$app_name*" \) -print0 2>/dev/null)

    # Autosave Information
    [[ -d ~/Library/Autosave\ Information/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Autosave Information/$bundle_id")

    # Contextual Menu Items
    [[ -d ~/Library/Contextual\ Menu\ Items/"$app_name".plugin ]] && files_to_clean+=("$HOME/Library/Contextual Menu Items/$app_name.plugin")

    # Receipts (user-level)
    while IFS= read -r -d '' receipt; do
        files_to_clean+=("$receipt")
    done < <(find ~/Library/Receipts \( -name "*$bundle_id*" -o -name "*$app_name*" \) -print0 2>/dev/null)

    # Spotlight Plugins
    [[ -d ~/Library/Spotlight/"$app_name".mdimporter ]] && files_to_clean+=("$HOME/Library/Spotlight/$app_name.mdimporter")

    # Scripting Additions
    while IFS= read -r -d '' scripting; do
        files_to_clean+=("$scripting")
    done < <(find ~/Library/ScriptingAdditions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Color Pickers
    [[ -d ~/Library/ColorPickers/"$app_name".colorPicker ]] && files_to_clean+=("$HOME/Library/ColorPickers/$app_name.colorPicker")

    # Quartz Compositions
    while IFS= read -r -d '' composition; do
        files_to_clean+=("$composition")
    done < <(find ~/Library/Compositions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Address Book Plug-Ins
    while IFS= read -r -d '' plugin; do
        files_to_clean+=("$plugin")
    done < <(find ~/Library/Address\ Book\ Plug-Ins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Mail Bundles
    while IFS= read -r -d '' bundle; do
        files_to_clean+=("$bundle")
    done < <(find ~/Library/Mail/Bundles \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Input Managers (app-specific only)
    while IFS= read -r -d '' manager; do
        files_to_clean+=("$manager")
    done < <(find ~/Library/InputManagers \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Custom Sounds
    while IFS= read -r -d '' sound; do
        files_to_clean+=("$sound")
    done < <(find ~/Library/Sounds \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Plugins
    while IFS= read -r -d '' plugin; do
        files_to_clean+=("$plugin")
    done < <(find ~/Library/Plugins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Private Frameworks
    while IFS= read -r -d '' framework; do
        files_to_clean+=("$framework")
    done < <(find ~/Library/PrivateFrameworks \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # Only print if array has elements to avoid unbound variable error
    if [[ ${#files_to_clean[@]} -gt 0 ]]; then
        printf '%s\n' "${files_to_clean[@]}"
    fi
}

# Find system-level app files (requires sudo)
find_app_system_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a system_files=()

    # System Application Support
    [[ -d /Library/Application\ Support/"$app_name" ]] && system_files+=("/Library/Application Support/$app_name")
    [[ -d /Library/Application\ Support/"$bundle_id" ]] && system_files+=("/Library/Application Support/$bundle_id")

    # System Launch Agents
    [[ -f /Library/LaunchAgents/"$bundle_id".plist ]] && system_files+=("/Library/LaunchAgents/$bundle_id.plist")

    # System Launch Daemons
    [[ -f /Library/LaunchDaemons/"$bundle_id".plist ]] && system_files+=("/Library/LaunchDaemons/$bundle_id.plist")

    # Privileged Helper Tools
    while IFS= read -r -d '' helper; do
        system_files+=("$helper")
    done < <(find /Library/PrivilegedHelperTools \( -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Preferences
    [[ -f /Library/Preferences/"$bundle_id".plist ]] && system_files+=("/Library/Preferences/$bundle_id.plist")

    # Installation Receipts
    while IFS= read -r -d '' receipt; do
        system_files+=("$receipt")
    done < <(find /private/var/db/receipts \( -name "*$bundle_id*" \) -print0 2>/dev/null)

    # System Logs
    [[ -d /Library/Logs/"$app_name" ]] && system_files+=("/Library/Logs/$app_name")
    [[ -d /Library/Logs/"$bundle_id" ]] && system_files+=("/Library/Logs/$bundle_id")

    # System Frameworks
    [[ -d /Library/Frameworks/"$app_name".framework ]] && system_files+=("/Library/Frameworks/$app_name.framework")

    # System Internet Plug-Ins
    while IFS= read -r -d '' plugin; do
        system_files+=("$plugin")
    done < <(find /Library/Internet\ Plug-Ins \( -name "$bundle_id*" -o -name "$app_name*" \) -print0 2>/dev/null)

    # System QuickLook Plugins
    [[ -d /Library/QuickLook/"$app_name".qlgenerator ]] && system_files+=("/Library/QuickLook/$app_name.qlgenerator")

    # System Receipts
    while IFS= read -r -d '' receipt; do
        system_files+=("$receipt")
    done < <(find /Library/Receipts \( -name "*$bundle_id*" -o -name "*$app_name*" \) -print0 2>/dev/null)

    # System Spotlight Plugins
    [[ -d /Library/Spotlight/"$app_name".mdimporter ]] && system_files+=("/Library/Spotlight/$app_name.mdimporter")

    # System Scripting Additions
    while IFS= read -r -d '' scripting; do
        system_files+=("$scripting")
    done < <(find /Library/ScriptingAdditions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Color Pickers
    [[ -d /Library/ColorPickers/"$app_name".colorPicker ]] && system_files+=("/Library/ColorPickers/$app_name.colorPicker")

    # System Quartz Compositions
    while IFS= read -r -d '' composition; do
        system_files+=("$composition")
    done < <(find /Library/Compositions \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Address Book Plug-Ins
    while IFS= read -r -d '' plugin; do
        system_files+=("$plugin")
    done < <(find /Library/Address\ Book\ Plug-Ins \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Mail Bundles
    while IFS= read -r -d '' bundle; do
        system_files+=("$bundle")
    done < <(find /Library/Mail/Bundles \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Input Managers
    while IFS= read -r -d '' manager; do
        system_files+=("$manager")
    done < <(find /Library/InputManagers \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Sounds
    while IFS= read -r -d '' sound; do
        system_files+=("$sound")
    done < <(find /Library/Sounds \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Contextual Menu Items
    while IFS= read -r -d '' item; do
        system_files+=("$item")
    done < <(find /Library/Contextual\ Menu\ Items \( -name "$app_name*" -o -name "$bundle_id*" \) -print0 2>/dev/null)

    # System Preference Panes
    [[ -d /Library/PreferencePanes/"$app_name".prefPane ]] && system_files+=("/Library/PreferencePanes/$app_name.prefPane")

    # System Screen Savers
    [[ -d /Library/Screen\ Savers/"$app_name".saver ]] && system_files+=("/Library/Screen Savers/$app_name.saver")

    # System Caches
    [[ -d /Library/Caches/"$bundle_id" ]] && system_files+=("/Library/Caches/$bundle_id")
    [[ -d /Library/Caches/"$app_name" ]] && system_files+=("/Library/Caches/$app_name")

    # Only print if array has elements
    if [[ ${#system_files[@]} -gt 0 ]]; then
        printf '%s\n' "${system_files[@]}"
    fi
}

# Calculate total size of files (consolidated from duplicates)
calculate_total_size() {
    local files="$1"
    local total_kb=0

    while IFS= read -r file; do
        if [[ -n "$file" && -e "$file" ]]; then
            local size_kb=$(du -sk "$file" 2>/dev/null | awk '{print $1}' || echo "0")
            ((total_kb += size_kb))
        fi
    done <<< "$files"

    echo "$total_kb"
}

# Get normalized brand name (bash 3.2 compatible using case statement)
get_brand_name() {
    local name="$1"

    # Brand name mapping for better user recognition
    case "$name" in
        "qiyimac"|"爱奇艺") echo "iQiyi" ;;
        "wechat"|"微信") echo "WeChat" ;;
        "QQ") echo "QQ" ;;
        "VooV Meeting"|"腾讯会议") echo "VooV Meeting" ;;
        "dingtalk"|"钉钉") echo "DingTalk" ;;
        "NeteaseMusic"|"网易云音乐") echo "NetEase Music" ;;
        "BaiduNetdisk"|"百度网盘") echo "Baidu NetDisk" ;;
        "alipay"|"支付宝") echo "Alipay" ;;
        "taobao"|"淘宝") echo "Taobao" ;;
        "futunn"|"富途牛牛") echo "Futu NiuNiu" ;;
        "tencent lemon"|"Tencent Lemon Cleaner") echo "Tencent Lemon" ;;
        "keynote"|"Keynote") echo "Keynote" ;;
        "pages"|"Pages") echo "Pages" ;;
        "numbers"|"Numbers") echo "Numbers" ;;
        *) echo "$name" ;;  # Return original if no mapping found
    esac
}
