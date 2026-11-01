#!/bin/bash
# Mole CLI (Linux) - terminal UI: cursor, keys, menu rows, spinner.
# Same keys and look as Mole CLI (macOS).

set -euo pipefail

if [[ -n "${MOLE_UI_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UI_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"

readonly MOLE_KEY_SEQ_TIMEOUT="0.3"

clear_screen() { printf '\033[2J\033[H'; }
hide_cursor() { [[ -t 1 ]] && printf '\033[?25l' >&2 || true; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h' >&2 || true; }

# Read single keyboard input
read_key() {
    local key rest read_status
    if [[ "${1:-}" == "1" ]]; then
        # Bash 3.2 returns 1 for both EOF and timeout; elapsed shell time
        # distinguishes an idle tick from immediate EOF. ESC reads stay below.
        local read_started=$SECONDS
        if IFS= read -r -s -n 1 -t 1 key; then read_status=0; else read_status=$?; fi
        if [[ "$read_status" -ne 0 ]] && ((SECONDS > read_started)); then return 1; fi
    else
        if IFS= read -r -s -n 1 key; then read_status=0; else read_status=$?; fi
    fi
    [[ $read_status -ne 0 ]] && {
        echo "QUIT"
        return 0
    }

    # Decode terminal sequences once, in both navigation and text-input modes.
    # Keep the established one-second ESC reads for Bash 3.2.
    if [[ "$key" == $'\x1b' ]]; then
        local sequence="" terminator=""
        if ! IFS= read -r -s -n 1 -t 1 rest 2> /dev/null; then
            echo "QUIT"
        elif [[ "$rest" == "[" || "$rest" == "O" ]]; then
            if ! IFS= read -r -s -n 1 -t 1 sequence 2> /dev/null; then
                [[ "$rest" == "[" ]] && echo "QUIT" || echo "OTHER"
            else
                case "$sequence" in
                    A) echo "UP" ;;
                    B) echo "DOWN" ;;
                    C) echo "RIGHT" ;;
                    D) echo "LEFT" ;;
                    H) echo "TOP" ;;
                    F) echo "BOTTOM" ;;
                    1 | 3 | 4 | 5 | 6 | 7 | 8)
                        if [[ "$rest" == "[" ]] && IFS= read -r -s -n 1 -t 1 terminator 2> /dev/null && [[ "$terminator" == "~" ]]; then
                            case "$sequence" in
                                1 | 7) echo "TOP" ;;
                                4 | 8) echo "BOTTOM" ;;
                                5) echo "LEFT" ;;
                                6) echo "RIGHT" ;;
                                3) echo "DELETE" ;;
                            esac
                        else
                            echo "OTHER"
                        fi
                        ;;
                    *) echo "OTHER" ;;
                esac
            fi
        elif [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
            echo "QUIT"
        else
            echo "OTHER"
        fi
        return 0
    fi

    if [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
        [[ -z "$key" ]] && {
            echo "ENTER"
            return 0
        }
        case "$key" in
            $'\n' | $'\r') echo "ENTER" ;;
            $'\x7f' | $'\x08') echo "DELETE" ;;
            $'\x15') echo "CLEAR_LINE" ;; # Ctrl+U (often mapped from Cmd+Delete in terminals)
            ' ') echo "SPACE" ;;          # Search input or selection, decided by the menu
            $'\x03') echo "QUIT" ;;
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
        'v' | 'V') echo "VERSION" ;;
        'j' | 'J') echo "DOWN" ;;
        'k' | 'K') echo "UP" ;;
        'h' | 'H') echo "LEFT" ;;
        'l' | 'L') echo "RIGHT" ;;
        'G') echo "BOTTOM" ;;
        'g')
            if IFS= read -r -s -n 1 -t "$MOLE_KEY_SEQ_TIMEOUT" rest 2> /dev/null; then
                if [[ "$rest" == "g" ]]; then
                    echo "TOP"
                else
                    echo "OTHER"
                fi
            else
                echo "OTHER"
            fi
            ;;
        $'\x03') echo "QUIT" ;;
        $'\x7f' | $'\x08') echo "DELETE" ;;
        $'\x15') echo "CLEAR_LINE" ;; # Ctrl+U
        [[:print:]]) echo "CHAR:$key" ;;
        *) echo "OTHER" ;;
    esac
}

# Absolute path on purpose: a version-manager shim earlier on PATH can fail or

# Drop queued keystrokes (mouse wheel bursts, key repeat) after an action.
drain_pending_input() {
    local idle_timeout="${1:-0.01}" drained=0
    while IFS= read -r -s -n 1 -t "$idle_timeout" _ 2> /dev/null; do
        drained=$((drained + 1))
        [[ $drained -gt 100 ]] && break
        idle_timeout="0.01"
    done
    return 0
}

show_menu_option() {
    local number="$1" text="$2" selected="$3"
    if [[ "$selected" == "true" ]]; then
        echo -e "${CYAN}${ICON_ARROW} $number. $text${NC}"
    else
        echo "  $number. $text"
    fi
}

# Inline spinner on stderr. A background loop redraws until its stop file
# appears; the message file lets callers swap the text without a restart.
INLINE_SPINNER_PID=""
INLINE_SPINNER_DIR=""

mo_spinner_frames() { MO_SPINNER_FRAMES=("⠖" "⠲" "⠴" "⠦"); }

format_spinner_message() {
    local message="${1//$'\n'/ }" cols
    cols=$(tput cols 2> /dev/null || echo 80)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    local available=$((cols - 8))
    ((available < 20)) && available=20
    if ((${#message} > available)); then
        message="${message:0:$((available - 3))}..."
    fi
    printf '%s' "$message"
}

start_inline_spinner() {
    stop_inline_spinner 2> /dev/null || true
    local display_message
    display_message=$(format_spinner_message "$1")
    if [[ ! -t 2 ]]; then
        return 0
    fi
    INLINE_SPINNER_DIR=$(umask 077 && mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/mole-spinner.XXXXXX" 2> /dev/null) || {
        INLINE_SPINNER_DIR=""
        printf '  %s|%s %s' "$BLUE" "$NC" "$display_message" >&2
        return 0
    }
    printf '%s\n' "$display_message" > "$INLINE_SPINNER_DIR/message"
    (
        local dir="$INLINE_SPINNER_DIR" i=0 current="$display_message" next="" lead
        mo_spinner_frames
        printf '\r\033[2K' >&2 || true
        while [[ ! -f "$dir/stop" ]]; do
            lead="\r"
            IFS= read -r next < "$dir/message" 2> /dev/null || next=""
            if [[ -n "$next" && "$next" != "$current" ]]; then
                current="$next"
                lead="\r\033[2K"
            fi
            printf "${lead}${MOLE_SPINNER_PREFIX:-}${BLUE}%s${NC} %s" "${MO_SPINNER_FRAMES[$((i % 4))]}" "$current" >&2 || break
            i=$((i + 1))
            sleep 0.08
        done
        exit 0
    ) &
    INLINE_SPINNER_PID=$!
    disown "$INLINE_SPINNER_PID" 2> /dev/null || true
}

update_inline_spinner_message() {
    [[ -n "$INLINE_SPINNER_PID" && -n "$INLINE_SPINNER_DIR" ]] || return 1
    kill -0 "$INLINE_SPINNER_PID" 2> /dev/null || return 1
    local tmp
    tmp=$(mktemp "$INLINE_SPINNER_DIR/msg.XXXXXX") || return 1
    format_spinner_message "$1" > "$tmp" && echo >> "$tmp"
    mv -f "$tmp" "$INLINE_SPINNER_DIR/message"
}

stop_inline_spinner() {
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        [[ -n "$INLINE_SPINNER_DIR" ]] && : > "$INLINE_SPINNER_DIR/stop" 2> /dev/null
        local n=0
        while kill -0 "$INLINE_SPINNER_PID" 2> /dev/null && ((n < 5)); do
            sleep 0.05
            n=$((n + 1))
        done
        kill -0 "$INLINE_SPINNER_PID" 2> /dev/null && kill -KILL "$INLINE_SPINNER_PID" 2> /dev/null
        wait "$INLINE_SPINNER_PID" 2> /dev/null || true
        INLINE_SPINNER_PID=""
        [[ -t 2 ]] && printf '\r\033[2K' >&2
    fi
    if [[ -n "$INLINE_SPINNER_DIR" ]]; then
        rm -f "$INLINE_SPINNER_DIR"/stop "$INLINE_SPINNER_DIR"/message "$INLINE_SPINNER_DIR"/msg.* 2> /dev/null
        rmdir "$INLINE_SPINNER_DIR" 2> /dev/null || true
        INLINE_SPINNER_DIR=""
    fi
    return 0
}

start_section_spinner() {
    local message="${1:-Scanning...}"
    update_inline_spinner_message "$message" 2> /dev/null && return 0
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "$message"
}

stop_section_spinner() { stop_inline_spinner; }
