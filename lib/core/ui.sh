#!/bin/bash
# Mole - UI Components
# Terminal UI utilities: cursor control, keyboard input, spinners, menus

set -euo pipefail

if [[ -n "${MOLE_UI_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UI_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"

# Cursor control
clear_screen() { printf '\033[2J\033[H'; }
hide_cursor() { [[ -t 1 ]] && printf '\033[?25l' >&2 || true; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h' >&2 || true; }

# Calculate display width (CJK characters count as 2)
get_display_width() {
    local str="$1"

    # Optimized pure bash implementation without forks
    local width

    # Save current locale
    local old_lc="${LC_ALL:-}"

    # Get Char Count (UTF-8)
    # We must export ensuring it applies to the expansion (though just assignment often works in newer bash, export is safer for all subshells/cmds)
    export LC_ALL=en_US.UTF-8
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
        echo "$str"
        return
    fi

    # Fallback: Use pure bash character iteration
    # Since we need to know the width of *each* character to truncate at the right spot,
    # we cannot just use the total width formula on the whole string.
    # However, iterating char-by-char and calling the optimized get_display_width function
    # is now much faster because it doesn't fork 'wc'.

    # CRITICAL: Switch to UTF-8 for correct character iteration
    local old_lc="${LC_ALL:-}"
    export LC_ALL=en_US.UTF-8

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

    echo "${truncated}..."
}

# Read single keyboard input
read_key() {
    local key rest read_status
    IFS= read -r -s -n 1 key
    read_status=$?
    [[ $read_status -ne 0 ]] && {
        echo "QUIT"
        return 0
    }

    if [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
        [[ -z "$key" ]] && {
            echo "ENTER"
            return 0
        }
        case "$key" in
            $'\n' | $'\r') echo "ENTER" ;;
            $'\x7f' | $'\x08') echo "DELETE" ;;
            $'\x15') echo "CLEAR_LINE" ;; # Ctrl+U (often mapped from Cmd+Delete in terminals)
            $'\x1b')
                if IFS= read -r -s -n 1 -t 1 rest 2> /dev/null; then
                    if [[ "$rest" == "[" ]]; then
                        if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                            case "$rest2" in
                                "A") echo "UP" ;;
                                "B") echo "DOWN" ;;
                                "C") echo "RIGHT" ;;
                                "D") echo "LEFT" ;;
                                "3")
                                    IFS= read -r -s -n 1 -t 1 rest3 2> /dev/null
                                    [[ "$rest3" == "~" ]] && echo "DELETE" || echo "OTHER"
                                    ;;
                                *) echo "OTHER" ;;
                            esac
                        else
                            echo "QUIT"
                        fi
                    elif [[ "$rest" == "O" ]]; then
                        if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                            case "$rest2" in
                                "A") echo "UP" ;;
                                "B") echo "DOWN" ;;
                                "C") echo "RIGHT" ;;
                                "D") echo "LEFT" ;;
                                *) echo "OTHER" ;;
                            esac
                        else echo "OTHER"; fi
                    else
                        echo "QUIT"
                    fi
                else
                    echo "QUIT"
                fi
                ;;
            ' ') echo "SPACE" ;; # Allow space in filter mode for selection
            [[:print:]]) echo "CHAR:$key" ;;
            *) echo "OTHER" ;;
        esac
        return 0
    fi

    [[ -z "$key" ]] && {
        echo "ENTER"
        return 0
    }
    case "$key" in
        $'\n' | $'\r') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        'q' | 'Q') echo "QUIT" ;;
        'R') echo "RETRY" ;;
        'm' | 'M') echo "MORE" ;;
        'u' | 'U') echo "UPDATE" ;;
        't' | 'T') echo "TOUCHID" ;;
        'j' | 'J') echo "DOWN" ;;
        'k' | 'K') echo "UP" ;;
        'h' | 'H') echo "LEFT" ;;
        'l' | 'L') echo "RIGHT" ;;
        $'\x03') echo "QUIT" ;;
        $'\x7f' | $'\x08') echo "DELETE" ;;
        $'\x15') echo "CLEAR_LINE" ;; # Ctrl+U
        $'\x1b')
            if IFS= read -r -s -n 1 -t 1 rest 2> /dev/null; then
                if [[ "$rest" == "[" ]]; then
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;; "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;; "D") echo "LEFT" ;;
                            "3")
                                IFS= read -r -s -n 1 -t 1 rest3 2> /dev/null
                                [[ "$rest3" == "~" ]] && echo "DELETE" || echo "OTHER"
                                ;;
                            *) echo "OTHER" ;;
                        esac
                    else echo "QUIT"; fi
                elif [[ "$rest" == "O" ]]; then
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;; "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;; "D") echo "LEFT" ;;
                            *) echo "OTHER" ;;
                        esac
                    else echo "OTHER"; fi
                else echo "OTHER"; fi
            else echo "QUIT"; fi
            ;;
        [[:print:]]) echo "CHAR:$key" ;;
        *) echo "OTHER" ;;
    esac
}

drain_pending_input() {
    local drained=0
    while IFS= read -r -s -n 1 -t 0.01 _ 2> /dev/null; do
        drained=$((drained + 1))
        [[ $drained -gt 100 ]] && break
    done
}

# Format menu option display
show_menu_option() {
    local number="$1"
    local text="$2"
    local selected="$3"

    if [[ "$selected" == "true" ]]; then
        echo -e "${CYAN}${ICON_ARROW} $number. $text${NC}"
    else
        echo "  $number. $text"
    fi
}

# Background spinner implementation
INLINE_SPINNER_PID=""
INLINE_SPINNER_STOP_FILE=""

# Keep spinner message on one line and avoid wrapping/noisy output on narrow terminals.
format_spinner_message() {
    local message="$1"
    message="${message//$'\r'/ }"
    message="${message//$'\n'/ }"

    local cols=80
    if command -v tput > /dev/null 2>&1; then
        cols=$(tput cols 2> /dev/null || echo "80")
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    # Reserve space for prefix + spinner char + spacing.
    local available=$((cols - 8))
    if [[ $available -lt 20 ]]; then
        available=20
    fi

    if [[ ${#message} -gt $available ]]; then
        if [[ $available -gt 3 ]]; then
            message="${message:0:$((available - 3))}..."
        else
            message="${message:0:$available}"
        fi
    fi

    printf "%s" "$message"
}

start_inline_spinner() {
    stop_inline_spinner 2> /dev/null || true
    local message="$1"
    local display_message
    display_message=$(format_spinner_message "$message")

    if [[ -t 1 ]]; then
        # Create unique stop flag file for this spinner instance
        INLINE_SPINNER_STOP_FILE="${TMPDIR:-/tmp}/mole_spinner_$$_$RANDOM.stop"

        (
            local stop_file="$INLINE_SPINNER_STOP_FILE"
            local chars
            chars="$(mo_spinner_chars)"
            [[ -z "$chars" ]] && chars="|/-\\"
            local i=0

            # Clear line on first output to prevent text remnants from previous messages
            printf "\r\033[2K" >&2 || true

            # Cooperative exit: check for stop file instead of relying on signals
            while [[ ! -f "$stop_file" ]]; do
                local c="${chars:$((i % ${#chars})):1}"
                # Output to stderr to avoid interfering with stdout
                printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}%s${NC} %s" "$c" "$display_message" >&2 || break
                i=$((i + 1))
                /bin/sleep 0.05
            done

            # Clean up stop file before exiting
            rm -f "$stop_file" 2> /dev/null || true
            exit 0
        ) &
        INLINE_SPINNER_PID=$!
        disown "$INLINE_SPINNER_PID" 2> /dev/null || true
    else
        echo -n "  ${BLUE}|${NC} $display_message" >&2 || true
    fi
}

stop_inline_spinner() {
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        # Cooperative stop: create stop file to signal spinner to exit
        if [[ -n "$INLINE_SPINNER_STOP_FILE" ]]; then
            touch "$INLINE_SPINNER_STOP_FILE" 2> /dev/null || true
        fi

        # Wait briefly for cooperative exit
        local wait_count=0
        while kill -0 "$INLINE_SPINNER_PID" 2> /dev/null && [[ $wait_count -lt 5 ]]; do
            /bin/sleep 0.05 2> /dev/null || true
            wait_count=$((wait_count + 1))
        done

        # Only use SIGKILL as last resort if process is stuck
        if kill -0 "$INLINE_SPINNER_PID" 2> /dev/null; then
            kill -KILL "$INLINE_SPINNER_PID" 2> /dev/null || true
        fi

        wait "$INLINE_SPINNER_PID" 2> /dev/null || true

        # Cleanup
        rm -f "$INLINE_SPINNER_STOP_FILE" 2> /dev/null || true
        INLINE_SPINNER_PID=""
        INLINE_SPINNER_STOP_FILE=""

        # Clear the line - use \033[2K to clear entire line, not just to end
        [[ -t 1 ]] && printf "\r\033[2K" >&2 || true
    fi
}

# Get spinner characters
mo_spinner_chars() {
    local chars="|/-\\"
    [[ -z "$chars" ]] && chars="|/-\\"
    printf "%s" "$chars"
}

# Format relative time for compact display (e.g., 3d ago)
format_last_used_summary() {
    local value="$1"

    case "$value" in
        "" | "Unknown")
            echo "Unknown"
            return 0
            ;;
        "Never" | "Recent" | "Today" | "Yesterday" | "This year" | "Old")
            echo "$value"
            return 0
            ;;
    esac

    if [[ $value =~ ^([0-9]+)[[:space:]]+days?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}d ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+weeks?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}w ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+months?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+month\(s\)\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+years?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}y ago"
        return 0
    fi
    echo "$value"
}

# Check if terminal has Full Disk Access
# Returns 0 if FDA is granted, 1 if denied, 2 if unknown
has_full_disk_access() {
    # Cache the result to avoid repeated checks
    if [[ -n "${MOLE_HAS_FDA:-}" ]]; then
        if [[ "$MOLE_HAS_FDA" == "1" ]]; then
            return 0
        elif [[ "$MOLE_HAS_FDA" == "unknown" ]]; then
            return 2
        else
            return 1
        fi
    fi

    # Test access to protected directories that require FDA
    # Strategy: Try to access directories that are commonly protected
    # If ANY of them are accessible, we likely have FDA
    # If ALL fail, we definitely don't have FDA
    local -a protected_dirs=(
        "$HOME/Library/Safari/LocalStorage"
        "$HOME/Library/Mail/V10"
        "$HOME/Library/Messages/chat.db"
    )

    local accessible_count=0
    local tested_count=0

    for test_path in "${protected_dirs[@]}"; do
        # Only test when the protected path exists
        if [[ -e "$test_path" ]]; then
            tested_count=$((tested_count + 1))
            # Try to stat the ACTUAL protected path - this requires FDA
            if stat "$test_path" > /dev/null 2>&1; then
                accessible_count=$((accessible_count + 1))
            fi
        fi
    done

    # Three possible outcomes:
    # 1. tested_count = 0: Can't determine (test paths don't exist) → unknown
    # 2. tested_count > 0 && accessible_count > 0: Has FDA → yes
    # 3. tested_count > 0 && accessible_count = 0: No FDA → no
    if [[ $tested_count -eq 0 ]]; then
        # Can't determine - test paths don't exist, treat as unknown
        export MOLE_HAS_FDA="unknown"
        return 2
    elif [[ $accessible_count -gt 0 ]]; then
        # At least one path is accessible → has FDA
        export MOLE_HAS_FDA=1
        return 0
    else
        # Tested paths exist but not accessible → no FDA
        export MOLE_HAS_FDA=0
        return 1
    fi
}
