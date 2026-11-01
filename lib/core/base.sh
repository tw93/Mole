#!/bin/bash
# Mole CLI (Linux) - base definitions: colors, icons, sizes, paths.
# The look (colors, icons, size format) matches Mole CLI (macOS) on purpose;
# the code is this branch's own.

set -euo pipefail

if [[ -n "${MOLE_BASE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_BASE_LOADED=1

: "${DRY_RUN:=false}"

# Colors: off for NO_COLOR, TERM=dumb or a non-terminal stdout; forced on in tests.
mole_color=0
if [[ -n "${NO_COLOR:-}" ]]; then
    mole_color=0
elif [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
    mole_color=1
elif [[ "${TERM:-}" != "dumb" ]] && [[ -t 1 ]]; then
    mole_color=1
fi
if [[ "$mole_color" == "0" ]]; then
    readonly ESC="" GREEN="" BLUE="" CYAN="" YELLOW="" PURPLE="" PURPLE_BOLD="" RED="" GRAY="" NC=""
else
    readonly ESC=$'\033'
    readonly GREEN="${ESC}[0;32m"
    readonly BLUE="${ESC}[1;34m"
    readonly CYAN="${ESC}[0;36m"
    readonly YELLOW="${ESC}[0;33m"
    readonly PURPLE="${ESC}[0;35m"
    readonly PURPLE_BOLD="${ESC}[1;35m"
    readonly RED="${ESC}[0;31m"
    readonly GRAY="${ESC}[0;38;5;244m"
    readonly NC="${ESC}[0m"
fi
unset mole_color

readonly ICON_CONFIRM="◎"
readonly ICON_ADMIN="⚙"
readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="☻"
readonly ICON_WARNING="◎"
readonly ICON_EMPTY="○"
readonly ICON_SOLID="●"
readonly ICON_LIST="•"
readonly ICON_SUBLIST="↳"
readonly ICON_ARROW="➤"
readonly ICON_DRY_RUN="○"
readonly ICON_REVIEW="⊙"
readonly ICON_NAV_UP="↑"
readonly ICON_NAV_DOWN="↓"

# UTF-8 locale for width math. C.UTF-8 ships with glibc; en_US.UTF-8 often
# is not generated on Arch, and a missing locale silently counts bytes.
readonly MOLE_UTF8_LOCALE="C.UTF-8"

# XDG locations. A relative XDG value is invalid per the spec and ignored.
mole_xdg_dir() {
    local value="$1" fallback="$2"
    if [[ "$value" == /* ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}
MOLE_CACHE_HOME="$(mole_xdg_dir "${XDG_CACHE_HOME:-}" "$HOME/.cache")"
MOLE_CONFIG_HOME="$(mole_xdg_dir "${XDG_CONFIG_HOME:-}" "$HOME/.config")"
MOLE_DATA_HOME="$(mole_xdg_dir "${XDG_DATA_HOME:-}" "$HOME/.local/share")"
MOLE_STATE_HOME="$(mole_xdg_dir "${XDG_STATE_HOME:-}" "$HOME/.local/state")"
readonly MOLE_CACHE_HOME MOLE_CONFIG_HOME MOLE_DATA_HOME MOLE_STATE_HOME
readonly MOLE_STATE_DIR="$MOLE_STATE_HOME/mole"
readonly MOLE_TRASH_DIR="$MOLE_DATA_HOME/Trash"

# Run an external tool with a fixed C locale before parsing what it prints.
# The Omarchy test VM runs in Chinese; localized text is never matched.
mole_c() { LC_ALL=C LANG=C "$@"; }

bytes_to_human() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || {
        echo "0B"
        return 1
    }
    if ((bytes >= 1000000000)); then
        local scaled=$(((bytes * 100 + 500000000) / 1000000000))
        printf "%d.%02dGB\n" $((scaled / 100)) $((scaled % 100))
    elif ((bytes >= 1000000)); then
        local scaled=$(((bytes * 10 + 500000) / 1000000))
        printf "%d.%01dMB\n" $((scaled / 10)) $((scaled % 10))
    elif ((bytes >= 1000)); then
        printf "%dKB\n" $(((bytes + 500) / 1000))
    else
        printf "%dB\n" "$bytes"
    fi
}

bytes_to_human_kb() {
    bytes_to_human "$((${1:-0} * 1024))"
}

mole_count_label() {
    local count="${1:-0}" noun="$2"
    if [[ "$count" == "1" ]]; then
        printf '%s %s' "$count" "$noun"
    else
        printf '%s %ss' "$count" "$noun"
    fi
}

colorize_human_size() {
    local size_human="$1"
    local size_unit="${size_human%+}"
    local size_color=""
    case "$size_unit" in
        *GB) size_color="$RED" ;;
        *MB) size_color="$YELLOW" ;;
        *KB) size_color="$GREEN" ;;
        *B) size_color="$GRAY" ;;
        *)
            printf '%s' "$size_human"
            return 0
            ;;
    esac
    printf '%s%s%s' "$size_color" "$size_human" "$NC"
}

# Size of one path in KB, staying on its filesystem. Unreadable parts count as
# zero; the exit status of du is not trusted for partial reads.
mole_path_kb() {
    local path="$1" kb
    [[ -e "$path" || -L "$path" ]] || {
        echo 0
        return 0
    }
    kb=$(mole_c du -skx -- "$path" 2> /dev/null | awk 'NR==1 {print $1}') || true
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    echo "$kb"
}

# Free KB on the filesystem holding a path (default $HOME).
get_free_space_kb() {
    local target="${1:-$HOME}" kb
    kb=$(mole_c df -Pk -- "$target" 2> /dev/null | awk 'NR==2 {print $4}') || true
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    echo "$kb"
}

# Display a home path with ~.
mole_display_path() {
    local path="$1"
    if [[ "$path" == "$HOME" ]]; then
        printf '~'
    elif [[ "$path" == "$HOME/"* ]]; then
        # shellcheck disable=SC2088  # Display HOME as a literal tilde.
        printf '~/%s' "${path#"$HOME/"}"
    else
        printf '%s' "$path"
    fi
}

# Process running check by exact process name (comm). Returns 0 when running,
# 1 when not, 2 when the probe itself failed (callers treat 2 as running).
mole_process_running() {
    local name rc=1 probe
    command -v pgrep > /dev/null 2>&1 || return 2
    for name in "$@"; do
        probe=0
        pgrep -x -u "$(id -u)" -- "$name" > /dev/null 2>&1 || probe=$?
        [[ $probe -eq 0 ]] && return 0
        [[ $probe -eq 1 ]] || rc=2
    done
    return "$rc"
}

# 0 when one of the user's processes runs this exact executable file (an
# AppImage's runtime keeps running as its FUSE server), 1 when none does.
mole_exe_running() {
    local want="$1" exe pid
    for pid in /proc/[0-9]*; do
        exe=$(readlink -- "$pid/exe" 2> /dev/null) || continue
        [[ "$exe" == "$want" ]] && return 0
    done
    return 1
}

mole_ascii_lowercase() {
    local _value="${2:-}"
    printf -v "$1" '%s' "$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<< "$_value")"
}

get_display_width() {
    local str="$1"

    # Optimized pure bash implementation without forks
    local width

    # Save current locale
    local old_lc="${LC_ALL:-}"

    # Get Char Count (UTF-8)
    # We must export ensuring it applies to the expansion (though just assignment often works in newer bash, export is safer for all subshells/cmds)
    export LC_ALL=$MOLE_UTF8_LOCALE
    local char_count=${#str}

    # Get Byte Count (C)
    export LC_ALL=C
    local byte_count=${#str}

    # Restore Locale immediately
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi

    if [[ $byte_count -eq $char_count ]]; then
        echo "$char_count"
        return
    fi

    # CJK Heuristic:
    # Most CJK chars are 3 bytes in UTF-8 and width 2.
    # ASCII chars are 1 byte and width 1.
    # Width ~= CharCount + (ByteCount - CharCount) / 2
    # "中" (1 char, 3 bytes) -> 1 + (2)/2 = 2.
    # "A" (1 char, 1 byte) -> 1 + 0 = 1.
    # This is an approximation but very fast and sufficient for App names.
    # Integer arithmetic in bash automatically handles floor.
    local extra_bytes=$((byte_count - char_count))
    local padding=$((extra_bytes / 2))
    width=$((char_count + padding))

    # Adjust for zero-width joiners and emoji variation selectors (common in filenames/emojis)
    # These characters add bytes but no visible width; subtract their count if present.
    local zwj=$'\u200d'  # zero-width joiner
    local vs16=$'\ufe0f' # emoji variation selector
    local zero_width=0

    local without_zwj=${str//$zwj/}
    zero_width=$((zero_width + (char_count - ${#without_zwj})))

    local without_vs=${str//$vs16/}
    zero_width=$((zero_width + (char_count - ${#without_vs})))

    if ((zero_width > 0 && width > zero_width)); then
        width=$((width - zero_width))
    fi

    echo "$width"
}

# Truncate string by display width (handles CJK)

truncate_by_display_width() {
    local str="$1"
    local max_width="$2"
    local current_width
    current_width=$(get_display_width "$str")

    if [[ $current_width -le $max_width ]]; then
        # printf, not echo: a string such as "-n" or "-e" is an echo option.
        printf '%s\n' "$str"
        return
    fi

    # Fallback: Use pure bash character iteration
    # Since we need to know the width of *each* character to truncate at the right spot,
    # we cannot just use the total width formula on the whole string.
    # However, iterating char-by-char and calling the optimized get_display_width function
    # is now much faster because it doesn't fork 'wc'.

    # CRITICAL: Switch to UTF-8 for correct character iteration
    local old_lc="${LC_ALL:-}"
    export LC_ALL=$MOLE_UTF8_LOCALE

    local truncated=""
    local width=0
    local i=0
    local char char_width
    local strlen=${#str} # Re-calculate in UTF-8

    # Optimization: If total width <= max_width, return original string (checked above)

    while [[ $i -lt $strlen ]]; do
        char="${str:$i:1}"

        # Inlined width calculation for minimal overhead to avoid recursion overhead
        # We are already in UTF-8, so ${#char} is char length (1).
        # We need byte length for the heuristic.
        # But switching locale inside loop is disastrous for perf.
        # Logic: If char is ASCII (1 byte), width 1.
        # If char is wide (3 bytes), width 2.
        # How to detect byte size without switching locale?
        # printf %s "$char" | wc -c ? Slow.
        # Check against ASCII range?
        # Fast ASCII check: if [[ "$char" < $'\x7f' ]]; then ...

        if [[ "$char" =~ [[:ascii:]] ]]; then
            char_width=1
        else
            # Assume wide for non-ascii in this context (simplified)
            # Or use LC_ALL=C inside? No.
            # Most non-ASCII in filenames are either CJK (width 2) or heavy symbols.
            # Let's assume 2 for simplicity in this fast loop as we know we are usually dealing with CJK.
            char_width=2
        fi

        if ((width + char_width + 3 > max_width)); then
            break
        fi

        truncated+="$char"
        width=$((width + char_width))
        i=$((i + 1))
    done

    # Restore locale
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi

    printf '%s...\n' "$truncated"
}

