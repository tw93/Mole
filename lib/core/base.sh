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
readonly ICON_EMPTY="○"
readonly ICON_SOLID="●"
readonly ICON_LIST="•"
readonly ICON_ARROW="➤"
readonly ICON_WARNING="☻"
readonly ICON_NAV_UP="↑"
readonly ICON_NAV_DOWN="↓"
readonly ICON_NAV_LEFT="←"
readonly ICON_NAV_RIGHT="→"

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
readonly MOLE_SAVED_STATE_AGE_DAYS=7     # Saved state retention (days)
readonly MOLE_TM_BACKUP_SAFE_HOURS=48    # TM backup safety window (hours)

# ============================================================================
# Seasonal Functions
# ============================================================================
is_christmas_season() {
    local month day
    month=$(date +%-m)
    day=$(date +%-d)

    # December 10 to December 31
    if [[ $month -eq 12 && $day -ge 10 && $day -le 31 ]]; then
        return 0
    fi
    return 1
}

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
    "$HOME/Library/Caches/JetBrains*"
    "$HOME/Library/Caches/com.jetbrains.toolbox*"
    "$HOME/Library/Caches/com.apple.finder"
    "$FINDER_METADATA_SENTINEL"
)

declare -a DEFAULT_OPTIMIZE_WHITELIST_PATTERNS=(
    "check_brew_updates"
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
    result=$($STAT_BSD -f%m "$file" 2> /dev/null)
    echo "${result:-0}"
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
    command df -h / | awk 'NR==2 {print $4}'
}

# Get Darwin kernel major version (e.g., 24 for 24.2.0)
get_darwin_major() {
    local kernel
    kernel=$(uname -r 2> /dev/null || true)
    local major="${kernel%%.*}"
    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        major=0
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
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0B"
        return 1
    fi

    if ((bytes >= 1073741824)); then # >= 1GB
        local divisor=1073741824
        local whole=$((bytes / divisor))
        local remainder=$((bytes % divisor))
        local frac=$(((remainder * 100 + divisor / 2) / divisor))
        if ((frac >= 100)); then
            frac=0
            ((whole++))
        fi
        printf "%d.%02dGB\n" "$whole" "$frac"
        return 0
    fi

    if ((bytes >= 1048576)); then # >= 1MB
        local divisor=1048576
        local whole=$((bytes / divisor))
        local remainder=$((bytes % divisor))
        local frac=$(((remainder * 10 + divisor / 2) / divisor))
        if ((frac >= 10)); then
            frac=0
            ((whole++))
        fi
        printf "%d.%01dMB\n" "$whole" "$frac"
        return 0
    fi

    if ((bytes >= 1024)); then
        local rounded_kb=$(((bytes + 512) / 1024))
        printf "%dKB\n" "$rounded_kb"
        return 0
    fi

    printf "%dB\n" "$bytes"
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

    # Detect if system primary language is Chinese
    local is_chinese=false
    local sys_lang
    sys_lang=$(defaults read -g AppleLanguages 2> /dev/null | grep -o 'zh-Hans\|zh-Hant\|zh' | head -1 || echo "")
    [[ -n "$sys_lang" ]] && is_chinese=true

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
    if [[ $TRACK_SECTION -eq 1 && $SECTION_ACTIVITY -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to tidy"
    fi
    TRACK_SECTION=0
}

# Mark activity in current section
note_activity() {
    if [[ $TRACK_SECTION -eq 1 ]]; then
        SECTION_ACTIVITY=1
    fi
}
