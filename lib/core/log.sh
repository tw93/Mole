#!/bin/bash
# Mole CLI (Linux) - output helpers and the operations log.

set -euo pipefail

if [[ -n "${MOLE_LOG_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_LOG_LOADED=1

readonly OPERATIONS_LOG_FILE="$MOLE_STATE_DIR/operations.log"
readonly OPLOG_MAX_SIZE=5242880

# One id per command run, shared by every row it writes, so mo history can
# group rows into sessions. Exported so helpers the command starts reuse it.
if [[ -z "${_MOLE_OPLOG_RUN_ID:-}" ]]; then
    _MOLE_OPLOG_RUN_ID="$(date '+%Y%m%d%H%M%S')-$$-$RANDOM"
    export _MOLE_OPLOG_RUN_ID
fi

mole_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Control bytes as \n, \r, \t or \xHH, as the Go side writes them, so a file
# name can neither forge a row nor split mo history's fields. Backslashes stay
# literal so the name reads as it is on disk.
mole_escape_log_value() {
    local value="$1"
    if [[ "$value" != *[[:cntrl:]]* ]]; then
        printf '%s' "$value"
        return
    fi
    local out="" c i LC_ALL=C
    for ((i = 0; i < ${#value}; i++)); do
        c="${value:i:1}"
        case "$c" in
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            [[:cntrl:]]) out+=$(printf '\\x%02x' "'$c") ;;
            *) out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# One line per change, the shape Mole CLI (macOS) and (Windows) write:
# [2026-11-01 19:30:00] [clean run=<id>] REMOVED /path (1.2MB)
# Every row ends in one parenthesis-free "(detail)", "-" when there is none,
# so a reader can split it from a path that holds parentheses.
log_operation() {
    [[ "${MO_NO_OPLOG:-}" == "1" || "${DRY_RUN:-false}" == "true" ]] && return 0
    local command="$1" action="$2" path="$3" detail="${4:-}"
    [[ -n "$path" ]] || return 0
    mkdir -p "$MOLE_STATE_DIR" 2> /dev/null || return 0
    if [[ -f "$OPERATIONS_LOG_FILE" ]]; then
        local size
        size=$(stat -c %s -- "$OPERATIONS_LOG_FILE" 2> /dev/null || echo 0)
        if [[ "$size" =~ ^[0-9]+$ ]] && ((size > OPLOG_MAX_SIZE)); then
            mv -f "$OPERATIONS_LOG_FILE" "$OPERATIONS_LOG_FILE.1" 2> /dev/null || true
        fi
    fi
    path=$(mole_escape_log_value "$path")
    detail=$(mole_escape_log_value "$detail")
    detail="${detail//\(/[}"
    detail="${detail//\)/]}"
    local line="[$(mole_timestamp)] [$command run=$_MOLE_OPLOG_RUN_ID] $action $path (${detail:--})"
    printf '%s\n' "$line" >> "$OPERATIONS_LOG_FILE" 2> /dev/null || true
}

log_info() { echo -e "${BLUE}$1${NC}"; }
log_success() {
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
    note_activity
}
log_warning() {
    echo -e "${YELLOW}$1${NC}"
    note_activity
}
log_error() { echo -e "${YELLOW}${ICON_ERROR}${NC} $1" >&2; }
debug_log() {
    [[ "${MO_DEBUG:-}" == "1" ]] || return 0
    echo -e "${GRAY}[DEBUG] $*${NC}" >&2
    if [[ -n "${MOLE_DEBUG_LOG:-}" ]]; then
        # Paths in the file read ~/..., so a shared log names no user.
        local line="$*" home_real
        home_real=$(readlink -e -- "$HOME" 2> /dev/null) || home_real="$HOME"
        line="${line//"$home_real/"/\~/}"
        line="${line//"$HOME/"/\~/}"
        [[ "$line" == *"$home_real" ]] && line="${line%"$home_real"}~"
        [[ "$line" == *"$HOME" ]] && line="${line%"$HOME"}~"
        printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$line" >> "$MOLE_DEBUG_LOG" 2> /dev/null || true
    fi
    return 0
}

start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    echo ""
    echo -e "${PURPLE_BOLD}${ICON_ARROW} $1${NC}"
}

end_section() {
    if [[ "${TRACK_SECTION:-0}" == "1" && "${SECTION_ACTIVITY:-0}" == "0" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to tidy"
    fi
    TRACK_SECTION=0
}

note_activity() {
    [[ "${TRACK_SECTION:-0}" == "1" ]] && SECTION_ACTIVITY=1
    return 0
}

print_summary_block() {
    local heading="$1"
    shift
    local width divider detail
    width=$(tput cols 2> /dev/null || echo 70)
    [[ "$width" =~ ^[0-9]+$ ]] || width=70
    ((width > 70)) && width=70
    divider=$(printf '%*s' "$width" '' | tr ' ' '=')
    echo ""
    echo "$divider"
    [[ -n "$heading" ]] && echo -e "${BLUE}${heading}${NC}"
    for detail in "$@"; do
        [[ -n "$detail" ]] && echo -e "$detail"
    done
    echo "$divider"
}
