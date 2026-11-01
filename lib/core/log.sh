#!/bin/bash
# Mole CLI (Linux) - output helpers and the operations log.

set -euo pipefail

if [[ -n "${MOLE_LOG_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_LOG_LOADED=1

readonly OPERATIONS_LOG_FILE="$MOLE_STATE_DIR/operations.log"
readonly OPLOG_MAX_SIZE=5242880

mole_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# One line per change, same shape as Mole CLI (macOS):
# [2026-11-01 19:30:00] [clean] REMOVED /path (1.2MB)
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
    path="${path//$'\n'/\\n}"
    local line="[$(mole_timestamp)] [$command] $action $path"
    [[ -n "$detail" ]] && line+=" ($detail)"
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
debug_log() { [[ "${MO_DEBUG:-}" == "1" ]] && echo -e "${GRAY}[DEBUG] $*${NC}" >&2 || true; }

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
