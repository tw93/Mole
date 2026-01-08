#!/bin/bash
# Mole - Base Definitions and Utilities
# Core definitions, constants, and basic utility functions used by all modules

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_BASE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_BASE_LOADED=1

# ============================================================================
# Color Definitions
# ============================================================================
readonly ESC=$'\033'
readonly GREEN="${ESC}[0;32m"
readonly BLUE="${ESC}[0;34m"
readonly CYAN="${ESC}[0;36m"
readonly YELLOW="${ESC}[0;33m"
readonly PURPLE="${ESC}[0;35m"
readonly PURPLE_BOLD="${ESC}[1;35m"
readonly RED="${ESC}[0;31m"
readonly GRAY="${ESC}[0;90m"
readonly NC="${ESC}[0m"

# ============================================================================
# Icon Definitions
# ============================================================================
readonly ICON_CONFIRM="◎"
readonly ICON_ADMIN="⚙"
readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_WARNING="●"
readonly ICON_EMPTY="○"
readonly ICON_SOLID="●"
readonly ICON_LIST="•"
readonly ICON_ARROW="➤"
readonly ICON_DRY_RUN="→"
readonly ICON_NAV_UP="↑"
readonly ICON_NAV_DOWN="↓"

# ============================================================================
# Global Configuration Constants
# ============================================================================
readonly MOLE_TEMP_FILE_AGE_DAYS=7       # Temp file retention (days)
readonly MOLE_ORPHAN_AGE_DAYS=60         # Orphaned data retention (days)
readonly MOLE_MAX_PARALLEL_JOBS=15       # Parallel job limit
readonly MOLE_MAIL_DOWNLOADS_MIN_KB=5120 # Mail attachment size threshold
readonly MOLE_MAIL_AGE_DAYS=30           # Mail attachment retention (days)
readonly MOLE_LOG_AGE_DAYS=7             # Log retention (days)
readonly MOLE_CRASH_REPORT_AGE_DAYS=7    # Crash report retention (days)
readonly MOLE_SAVED_STATE_AGE_DAYS=30    # Saved state retention (days) - increased for safety
readonly MOLE_TM_BACKUP_SAFE_HOURS=48    # TM backup safety window (hours)
readonly MOLE_MAX_DS_STORE_FILES=500     # Max .DS_Store files to clean per scan
readonly MOLE_MAX_ORPHAN_ITERATIONS=100  # Max iterations for orphaned app data scan

# ============================================================================
# Whitelist Configuration
# ============================================================================
readonly FINDER_METADATA_SENTINEL="FINDER_METADATA"
declare -a DEFAULT_WHITELIST_PATTERNS=(
    "$HOME/Library/Caches/ms-playwright*"
    "$HOME/.cache/huggingface*"
    "$HOME/.m2/repository/*"
    "$HOME/.ollama/models/*"
    "$HOME/Library/Caches/com.nssurge.surge-mac/*"
    "$HOME/Library/Application Support/com.nssurge.surge-mac/*"
    "$HOME/Library/Caches/org.R-project.R/R/renv/*"
    "$HOME/Library/Caches/pypoetry/virtualenvs*"
    "$HOME/Library/Caches/JetBrains*"
    "$HOME/Library/Caches/com.jetbrains.toolbox*"
    "$HOME/Library/Application Support/JetBrains*"
    "$HOME/Library/Caches/com.apple.finder"
    "$HOME/Library/Mobile Documents*"
    # System-critical caches that affect macOS functionality and stability
    # CRITICAL: Removing these will cause system search and UI issues
    "$HOME/Library/Caches/com.apple.FontRegistry*"
    "$HOME/Library/Caches/com.apple.spotlight*"
    "$HOME/Library/Caches/com.apple.Spotlight*"
    "$HOME/Library/Caches/CloudKit*"
    "$FINDER_METADATA_SENTINEL"
)

declare -a DEFAULT_OPTIMIZE_WHITELIST_PATTERNS=(
    "check_brew_health"
    "check_touchid"
    "check_git_config"
)

# ============================================================================
# BSD Stat Compatibility
# ============================================================================
readonly STAT_BSD="/usr/bin/stat"

# Get file size in bytes
get_file_size() {
    local file="$1"
    local result
    result=$($STAT_BSD -f%z "$file" 2> /dev/null)
    echo "${result:-0}"
}

# Get file modification time in epoch seconds
get_file_mtime() {
    local file="$1"
    [[ -z "$file" ]] && {
        echo "0"
        return
    }
    local result
    result=$($STAT_BSD -f%m "$file" 2> /dev/null || echo "")
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "0"
    fi
}

# Determine date command once
if [[ -x /bin/date ]]; then
    _DATE_CMD="/bin/date"
else
    _DATE_CMD="date"
fi

# Get current time in epoch seconds (defensive against locale/aliases)
get_epoch_seconds() {
    local result
    result=$($_DATE_CMD +%s 2> /dev/null || echo "")
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "0"
    fi
}

# Get file owner username
get_file_owner() {
    local file="$1"
    $STAT_BSD -f%Su "$file" 2> /dev/null || echo ""
}

# ============================================================================
# System Utilities
# ============================================================================

# Check if System Integrity Protection is enabled
# Returns: 0 if SIP is enabled, 1 if disabled or cannot determine
is_sip_enabled() {
    if ! command -v csrutil > /dev/null 2>&1; then
        return 0
    fi

    local sip_status
    sip_status=$(csrutil status 2> /dev/null || echo "")

    if echo "$sip_status" | grep -qi "enabled"; then
        return 0
    else
        return 1
    fi
}

# Check if running in an interactive terminal
is_interactive() {
    [[ -t 1 ]]
}

# Detect CPU architecture
# Returns: "Apple Silicon" or "Intel"
detect_architecture() {
    if [[ "$(uname -m)" == "arm64" ]]; then
        echo "Apple Silicon"
    else
        echo "Intel"
    fi
}

# Get free disk space on root volume
# Returns: human-readable string (e.g., "100G")
get_free_space() {
    local target="/"
    if [[ -d "/System/Volumes/Data" ]]; then
        target="/System/Volumes/Data"
    fi

    df -h "$target" | awk 'NR==2 {print $4}'
}

# Get Darwin kernel major version (e.g., 24 for 24.2.0)
# Returns 999 on failure to adopt conservative behavior (assume modern system)
get_darwin_major() {
    local kernel
    kernel=$(uname -r 2> /dev/null || true)
    local major="${kernel%%.*}"
    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        # Return high number to skip potentially dangerous operations on unknown systems
        major=999
    fi
    echo "$major"
}

# Check if Darwin kernel major version meets minimum
is_darwin_ge() {
    local minimum="$1"
    local major
    major=$(get_darwin_major)
    [[ "$major" -ge "$minimum" ]]
}

# Get optimal parallel jobs for operation type (scan|io|compute|default)
get_optimal_parallel_jobs() {
    local operation_type="${1:-default}"
    local cpu_cores
    cpu_cores=$(sysctl -n hw.ncpu 2> /dev/null || echo 4)
    case "$operation_type" in
        scan | io)
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
# User Context Utilities
# ============================================================================

is_root_user() {
    [[ "$(id -u)" == "0" ]]
}

get_user_home() {
    local user="$1"
    local home=""

    if [[ -z "$user" ]]; then
        echo ""
        return 0
    fi

    if command -v dscl > /dev/null 2>&1; then
        home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2> /dev/null | awk '{print $2}' | head -1 || true)
    fi

    if [[ -z "$home" ]]; then
        home=$(eval echo "~$user" 2> /dev/null || true)
    fi

    if [[ "$home" == "~"* ]]; then
        home=""
    fi

    echo "$home"
}

get_invoking_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        echo "$SUDO_USER"
        return 0
    fi
    echo "${USER:-}"
}

get_invoking_uid() {
    if [[ -n "${SUDO_UID:-}" ]]; then
        echo "$SUDO_UID"
        return 0
    fi

    local uid
    uid=$(id -u 2> /dev/null || true)
    echo "$uid"
}

get_invoking_gid() {
    if [[ -n "${SUDO_GID:-}" ]]; then
        echo "$SUDO_GID"
        return 0
    fi

    local gid
    gid=$(id -g 2> /dev/null || true)
    echo "$gid"
}

get_invoking_home() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        get_user_home "$SUDO_USER"
        return 0
    fi

    echo "${HOME:-}"
}

ensure_user_dir() {
    local raw_path="$1"
    if [[ -z "$raw_path" ]]; then
        return 0
    fi

    local target_path="$raw_path"
    if [[ "$target_path" == "~"* ]]; then
        target_path="${target_path/#\~/$HOME}"
    fi

    mkdir -p "$target_path" 2> /dev/null || true

    if ! is_root_user; then
        return 0
    fi

    local sudo_user="${SUDO_USER:-}"
    if [[ -z "$sudo_user" || "$sudo_user" == "root" ]]; then
        return 0
    fi

    local user_home
    user_home=$(get_user_home "$sudo_user")
    if [[ -z "$user_home" ]]; then
        return 0
    fi
    user_home="${user_home%/}"

    if [[ "$target_path" != "$user_home" && "$target_path" != "$user_home/"* ]]; then
        return 0
    fi

    local owner_uid="${SUDO_UID:-}"
    local owner_gid="${SUDO_GID:-}"
    if [[ -z "$owner_uid" || -z "$owner_gid" ]]; then
        owner_uid=$(id -u "$sudo_user" 2> /dev/null || true)
        owner_gid=$(id -g "$sudo_user" 2> /dev/null || true)
    fi

    if [[ -z "$owner_uid" || -z "$owner_gid" ]]; then
        return 0
    fi

    local dir="$target_path"
    while [[ -n "$dir" && "$dir" != "/" ]]; do
        # Early stop: if ownership is already correct, no need to continue up the tree
        if [[ -d "$dir" ]]; then
            local current_uid
            current_uid=$("$STAT_BSD" -f%u "$dir" 2> /dev/null || echo "")
            if [[ "$current_uid" == "$owner_uid" ]]; then
                break
            fi
        fi

        chown "$owner_uid:$owner_gid" "$dir" 2> /dev/null || true

        if [[ "$dir" == "$user_home" ]]; then
            break
        fi
        dir=$(dirname "$dir")
        if [[ "$dir" == "." ]]; then
            break
        fi
    done
}

ensure_user_file() {
    local raw_path="$1"
    if [[ -z "$raw_path" ]]; then
        return 0
    fi

    local target_path="$raw_path"
    if [[ "$target_path" == "~"* ]]; then
        target_path="${target_path/#\~/$HOME}"
    fi

    ensure_user_dir "$(dirname "$target_path")"
    touch "$target_path" 2> /dev/null || true

    if ! is_root_user; then
        return 0
    fi

    local sudo_user="${SUDO_USER:-}"
    if [[ -z "$sudo_user" || "$sudo_user" == "root" ]]; then
        return 0
    fi

    local user_home
    user_home=$(get_user_home "$sudo_user")
    if [[ -z "$user_home" ]]; then
        return 0
    fi
    user_home="${user_home%/}"

    if [[ "$target_path" != "$user_home" && "$target_path" != "$user_home/"* ]]; then
        return 0
    fi

    local owner_uid="${SUDO_UID:-}"
    local owner_gid="${SUDO_GID:-}"
    if [[ -z "$owner_uid" || -z "$owner_gid" ]]; then
        owner_uid=$(id -u "$sudo_user" 2> /dev/null || true)
        owner_gid=$(id -g "$sudo_user" 2> /dev/null || true)
    fi

    if [[ -n "$owner_uid" && -n "$owner_gid" ]]; then
        chown "$owner_uid:$owner_gid" "$target_path" 2> /dev/null || true
    fi
}

# ============================================================================
# Formatting Utilities
# ============================================================================

# Convert bytes to human-readable format (e.g., 1.5GB)
bytes_to_human() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || {
        echo "0B"
        return 1
    }

    # GB: >= 1073741824 bytes
    if ((bytes >= 1073741824)); then
        printf "%d.%02dGB\n" $((bytes / 1073741824)) $(((bytes % 1073741824) * 100 / 1073741824))
    # MB: >= 1048576 bytes
    elif ((bytes >= 1048576)); then
        printf "%d.%01dMB\n" $((bytes / 1048576)) $(((bytes % 1048576) * 10 / 1048576))
    # KB: >= 1024 bytes (round up)
    elif ((bytes >= 1024)); then
        printf "%dKB\n" $(((bytes + 512) / 1024))
    else
        printf "%dB\n" "$bytes"
    fi
}

# Convert kilobytes to human-readable format
# Args: $1 - size in KB
# Returns: formatted string
bytes_to_human_kb() {
    bytes_to_human "$((${1:-0} * 1024))"
}

# Get brand-friendly localized name for an application
get_brand_name() {
    local name="$1"

    # Detect if system primary language is Chinese (Cached)
    if [[ -z "${MOLE_IS_CHINESE_SYSTEM:-}" ]]; then
        local sys_lang
        sys_lang=$(defaults read -g AppleLanguages 2> /dev/null | grep -o 'zh-Hans\|zh-Hant\|zh' | head -1 || echo "")
        if [[ -n "$sys_lang" ]]; then
            export MOLE_IS_CHINESE_SYSTEM="true"
        else
            export MOLE_IS_CHINESE_SYSTEM="false"
        fi
    fi

    local is_chinese="${MOLE_IS_CHINESE_SYSTEM}"

    # Return localized names based on system language
    if [[ "$is_chinese" == true ]]; then
        # Chinese system - prefer Chinese names
        case "$name" in
            "qiyimac" | "iQiyi") echo "爱奇艺" ;;
            "wechat" | "WeChat") echo "微信" ;;
            "QQ") echo "QQ" ;;
            "VooV Meeting") echo "腾讯会议" ;;
            "dingtalk" | "DingTalk") echo "钉钉" ;;
            "NeteaseMusic" | "NetEase Music") echo "网易云音乐" ;;
            "BaiduNetdisk" | "Baidu NetDisk") echo "百度网盘" ;;
            "alipay" | "Alipay") echo "支付宝" ;;
            "taobao" | "Taobao") echo "淘宝" ;;
            "futunn" | "Futu NiuNiu") echo "富途牛牛" ;;
            "tencent lemon" | "Tencent Lemon Cleaner" | "Tencent Lemon") echo "腾讯柠檬清理" ;;
            *) echo "$name" ;;
        esac
    else
        # Non-Chinese system - use English names
        case "$name" in
            "qiyimac" | "爱奇艺") echo "iQiyi" ;;
            "wechat" | "微信") echo "WeChat" ;;
            "QQ") echo "QQ" ;;
            "腾讯会议") echo "VooV Meeting" ;;
            "dingtalk" | "钉钉") echo "DingTalk" ;;
            "网易云音乐") echo "NetEase Music" ;;
            "百度网盘") echo "Baidu NetDisk" ;;
            "alipay" | "支付宝") echo "Alipay" ;;
            "taobao" | "淘宝") echo "Taobao" ;;
            "富途牛牛") echo "Futu NiuNiu" ;;
            "腾讯柠檬清理" | "Tencent Lemon Cleaner") echo "Tencent Lemon" ;;
            "keynote" | "Keynote") echo "Keynote" ;;
            "pages" | "Pages") echo "Pages" ;;
            "numbers" | "Numbers") echo "Numbers" ;;
            *) echo "$name" ;;
        esac
    fi
}

# ============================================================================
# Temporary File Management
# ============================================================================

# Tracked temporary files and directories
declare -a MOLE_TEMP_FILES=()
declare -a MOLE_TEMP_DIRS=()

# Create tracked temporary file
create_temp_file() {
    local temp
    temp=$(mktemp) || return 1
    MOLE_TEMP_FILES+=("$temp")
    echo "$temp"
}

# Create tracked temporary directory
create_temp_dir() {
    local temp
    temp=$(mktemp -d) || return 1
    MOLE_TEMP_DIRS+=("$temp")
    echo "$temp"
}

# Register existing file for cleanup
register_temp_file() {
    MOLE_TEMP_FILES+=("$1")
}

# Register existing directory for cleanup
register_temp_dir() {
    MOLE_TEMP_DIRS+=("$1")
}

# Create temp file with prefix (for analyze.sh compatibility)
# Compatible with both BSD mktemp (macOS default) and GNU mktemp (coreutils)
mktemp_file() {
    local prefix="${1:-mole}"
    # Use TMPDIR if set, otherwise /tmp
    # Add .XXXXXX suffix to work with both BSD and GNU mktemp
    mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

# Cleanup all tracked temp files and directories
cleanup_temp_files() {
    stop_inline_spinner 2> /dev/null || true
    local file
    if [[ ${#MOLE_TEMP_FILES[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_FILES[@]}"; do
            [[ -f "$file" ]] && rm -f "$file" 2> /dev/null || true
        done
    fi

    if [[ ${#MOLE_TEMP_DIRS[@]} -gt 0 ]]; then
        for file in "${MOLE_TEMP_DIRS[@]}"; do
            [[ -d "$file" ]] && rm -rf "$file" 2> /dev/null || true # SAFE: cleanup_temp_files
        done
    fi

    MOLE_TEMP_FILES=()
    MOLE_TEMP_DIRS=()
}

# ============================================================================
# Section Tracking (for progress indication)
# ============================================================================

# Global section tracking variables
TRACK_SECTION=0
SECTION_ACTIVITY=0

# Start a new section
# Args: $1 - section title
start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
}

# End a section
# Shows "Nothing to tidy" if no activity was recorded
end_section() {
    if [[ "${TRACK_SECTION:-0}" == "1" && "${SECTION_ACTIVITY:-0}" == "0" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to tidy"
    fi
    TRACK_SECTION=0
}

# Mark activity in current section
note_activity() {
    if [[ "${TRACK_SECTION:-0}" == "1" ]]; then
        SECTION_ACTIVITY=1
    fi
}

# Start a section spinner with optional message
# Usage: start_section_spinner "message"
start_section_spinner() {
    local message="${1:-Scanning...}"
    stop_inline_spinner 2> /dev/null || true
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "$message"
    fi
}

# Stop spinner and clear the line
# Usage: stop_section_spinner
stop_section_spinner() {
    stop_inline_spinner 2> /dev/null || true
    if [[ -t 1 ]]; then
        echo -ne "\r\033[K" >&2 || true
    fi
}

# Safe terminal line clearing with terminal type detection
# Usage: safe_clear_lines <num_lines> [tty_device]
# Returns: 0 on success, 1 if terminal doesn't support ANSI
safe_clear_lines() {
    local lines="${1:-1}"
    local tty_device="${2:-/dev/tty}"

    # Use centralized ANSI support check (defined below)
    # Note: This forward reference works because functions are parsed before execution
    is_ansi_supported 2> /dev/null || return 1

    # Clear lines one by one (more reliable than multi-line sequences)
    local i
    for ((i = 0; i < lines; i++)); do
        printf "\033[1A\r\033[K" > "$tty_device" 2> /dev/null || return 1
    done

    return 0
}

# Safe single line clear with fallback
# Usage: safe_clear_line [tty_device]
safe_clear_line() {
    local tty_device="${1:-/dev/tty}"

    # Use centralized ANSI support check
    is_ansi_supported 2> /dev/null || return 1

    printf "\r\033[K" > "$tty_device" 2> /dev/null || return 1
    return 0
}

# Update progress spinner if enough time has elapsed
# Usage: update_progress_if_needed <completed> <total> <last_update_time_var> [interval]
# Example: update_progress_if_needed "$completed" "$total" last_progress_update 2
# Returns: 0 if updated, 1 if skipped
update_progress_if_needed() {
    local completed="$1"
    local total="$2"
    local last_update_var="$3" # Name of variable holding last update time
    local interval="${4:-2}"   # Default: update every 2 seconds

    # Get current time
    local current_time
    current_time=$(get_epoch_seconds)

    # Get last update time from variable
    local last_time
    eval "last_time=\${$last_update_var:-0}"
    [[ "$last_time" =~ ^[0-9]+$ ]] || last_time=0

    # Check if enough time has elapsed
    if [[ $((current_time - last_time)) -ge $interval ]]; then
        # Update the spinner with progress
        stop_section_spinner
        start_section_spinner "Scanning items... ($completed/$total)"

        # Update the last_update_time variable
        eval "$last_update_var=$current_time"
        return 0
    fi

    return 1
}

# ============================================================================
# Spinner Stack Management (prevents nesting issues)
# ============================================================================

# Global spinner stack
declare -a MOLE_SPINNER_STACK=()

# Push current spinner state onto stack
# Usage: push_spinner_state
push_spinner_state() {
    local current_state=""

    # Save current spinner PID if running
    if [[ -n "${MOLE_SPINNER_PID:-}" ]] && kill -0 "$MOLE_SPINNER_PID" 2> /dev/null; then
        current_state="running:$MOLE_SPINNER_PID"
    else
        current_state="stopped"
    fi

    MOLE_SPINNER_STACK+=("$current_state")
    debug_log "Pushed spinner state: $current_state (stack depth: ${#MOLE_SPINNER_STACK[@]})"
}

# Pop and restore spinner state from stack
# Usage: pop_spinner_state
pop_spinner_state() {
    if [[ ${#MOLE_SPINNER_STACK[@]} -eq 0 ]]; then
        debug_log "Warning: Attempted to pop from empty spinner stack"
        return 1
    fi

    # Stack depth safety check
    if [[ ${#MOLE_SPINNER_STACK[@]} -gt 10 ]]; then
        debug_log "Warning: Spinner stack depth excessive (${#MOLE_SPINNER_STACK[@]}), possible leak"
    fi

    local last_idx=$((${#MOLE_SPINNER_STACK[@]} - 1))
    local state="${MOLE_SPINNER_STACK[$last_idx]}"

    # Remove from stack (Bash 3.2 compatible way)
    # Instead of unset, rebuild array without last element
    local -a new_stack=()
    local i
    for ((i = 0; i < last_idx; i++)); do
        new_stack+=("${MOLE_SPINNER_STACK[$i]}")
    done
    MOLE_SPINNER_STACK=("${new_stack[@]}")

    debug_log "Popped spinner state: $state (remaining depth: ${#MOLE_SPINNER_STACK[@]})"

    # Restore state if needed
    if [[ "$state" == running:* ]]; then
        # Previous spinner was running - we don't restart it automatically
        # This is intentional to avoid UI conflicts
        :
    fi

    return 0
}

# Safe spinner start with stack management
# Usage: safe_start_spinner <message>
safe_start_spinner() {
    local message="${1:-Working...}"

    # Push current state
    push_spinner_state

    # Stop any existing spinner
    stop_section_spinner 2> /dev/null || true

    # Start new spinner
    start_section_spinner "$message"
}

# Safe spinner stop with stack management
# Usage: safe_stop_spinner
safe_stop_spinner() {
    # Stop current spinner
    stop_section_spinner 2> /dev/null || true

    # Pop previous state
    pop_spinner_state || true
}

# ============================================================================
# Terminal Compatibility Checks
# ============================================================================

# Check if terminal supports ANSI escape codes
# Usage: is_ansi_supported
# Returns: 0 if supported, 1 if not
is_ansi_supported() {
    # Check if running in interactive terminal
    [[ -t 1 ]] || return 1

    # Check TERM variable
    [[ -n "${TERM:-}" ]] || return 1

    # Check for known ANSI-compatible terminals
    case "$TERM" in
        xterm* | vt100 | vt220 | screen* | tmux* | ansi | linux | rxvt* | konsole*)
            return 0
            ;;
        dumb | unknown)
            return 1
            ;;
        *)
            # Check terminfo database if available
            if command -v tput > /dev/null 2>&1; then
                # Test if terminal supports colors (good proxy for ANSI support)
                local colors=$(tput colors 2> /dev/null || echo "0")
                [[ "$colors" -ge 8 ]] && return 0
            fi
            return 1
            ;;
    esac
}

# Get terminal capability info
# Usage: get_terminal_info
get_terminal_info() {
    local info="Terminal: ${TERM:-unknown}"

    if is_ansi_supported; then
        info+=" (ANSI supported)"

        if command -v tput > /dev/null 2>&1; then
            local cols=$(tput cols 2> /dev/null || echo "?")
            local lines=$(tput lines 2> /dev/null || echo "?")
            local colors=$(tput colors 2> /dev/null || echo "?")
            info+=" ${cols}x${lines}, ${colors} colors"
        fi
    else
        info+=" (ANSI not supported)"
    fi

    echo "$info"
}

# Validate terminal environment before running
# Usage: validate_terminal_environment
# Returns: 0 if OK, 1 with warning if issues detected
validate_terminal_environment() {
    local warnings=0

    # Check if TERM is set
    if [[ -z "${TERM:-}" ]]; then
        log_warning "TERM environment variable not set"
        ((warnings++))
    fi

    # Check if running in a known problematic terminal
    case "${TERM:-}" in
        dumb)
            log_warning "Running in 'dumb' terminal - limited functionality"
            ((warnings++))
            ;;
        unknown)
            log_warning "Terminal type unknown - may have display issues"
            ((warnings++))
            ;;
    esac

    # Check terminal size if available
    if command -v tput > /dev/null 2>&1; then
        local cols=$(tput cols 2> /dev/null || echo "80")
        if [[ "$cols" -lt 60 ]]; then
            log_warning "Terminal width ($cols cols) is narrow - output may wrap"
            ((warnings++))
        fi
    fi

    # Report compatibility
    if [[ $warnings -eq 0 ]]; then
        debug_log "Terminal environment validated: $(get_terminal_info)"
        return 0
    else
        debug_log "Terminal compatibility warnings: $warnings"
        return 1
    fi
}
