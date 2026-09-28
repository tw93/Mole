#!/bin/bash
# Mole - History parsing and rendering.

set -euo pipefail

if [[ -n "${MOLE_HISTORY_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_HISTORY_LOADED=1

if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    _MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi

readonly MOLE_HISTORY_DEFAULT_LIMIT=20
readonly MOLE_HISTORY_MAX_LIMIT=200

declare -a HISTORY_SESSION_COMMANDS=()
declare -a HISTORY_SESSION_STARTED_AT=()
declare -a HISTORY_SESSION_ENDED_AT=()
declare -a HISTORY_SESSION_ITEMS=()
declare -a HISTORY_SESSION_SIZE=()
declare -a HISTORY_SESSION_REMOVED=()
declare -a HISTORY_SESSION_TRASHED=()
declare -a HISTORY_SESSION_SKIPPED=()
declare -a HISTORY_SESSION_FAILED=()
declare -a HISTORY_SESSION_REBUILT=()
declare -a HISTORY_SESSION_OTHER=()
declare -a HISTORY_SESSION_OPERATIONS=()
declare -a HISTORY_SESSION_FAILED_TASKS=()
declare -a HISTORY_SESSION_START_SEQ=()

declare -a HISTORY_DELETE_TIMESTAMPS=()
declare -a HISTORY_DELETE_MODES=()
declare -a HISTORY_DELETE_SIZE_KB=()
declare -a HISTORY_DELETE_STATUSES=()
declare -a HISTORY_DELETE_PATHS=()

HISTORY_ACTIVE_COMMAND=""
HISTORY_ACTIVE_STARTED_AT=""
HISTORY_ACTIVE_ENDED_AT=""
HISTORY_ACTIVE_ITEMS=0
HISTORY_ACTIVE_SIZE="0B"
HISTORY_ACTIVE_REMOVED=0
HISTORY_ACTIVE_TRASHED=0
HISTORY_ACTIVE_SKIPPED=0
HISTORY_ACTIVE_FAILED=0
HISTORY_ACTIVE_REBUILT=0
HISTORY_ACTIVE_OTHER=0
HISTORY_ACTIVE_OPERATIONS=0
HISTORY_ACTIVE_FAILED_TASKS=0
HISTORY_ACTIVE_MARKED=0
HISTORY_ACTIVE_START_SEQ=0
HISTORY_START_SEQ_COUNTER=0

history_operations_log_file() {
    printf '%s\n' "${MOLE_OPERATIONS_LOG:-${OPERATIONS_LOG_FILE:-$HOME/Library/Logs/mole/operations.log}}"
}

history_deletions_log_file() {
    printf '%s\n' "${MOLE_DELETE_LOG:-$HOME/Library/Logs/mole/deletions.log}"
}

history_normalize_limit() {
    local value="${1:-$MOLE_HISTORY_DEFAULT_LIMIT}"
    local normalized max_digits

    if ! normalized=$(history_normalize_decimal "$value"); then
        printf '%s\n' "$MOLE_HISTORY_DEFAULT_LIMIT"
        return 0
    fi
    if [[ "$normalized" == "0" ]]; then
        printf '%s\n' "$MOLE_HISTORY_DEFAULT_LIMIT"
        return 0
    fi
    max_digits=${#MOLE_HISTORY_MAX_LIMIT}
    if [[ "${#normalized}" -gt "$max_digits" ]]; then
        printf '%s\n' "$MOLE_HISTORY_MAX_LIMIT"
        return 0
    fi
    if [[ "$normalized" -gt "$MOLE_HISTORY_MAX_LIMIT" ]]; then
        printf '%s\n' "$MOLE_HISTORY_MAX_LIMIT"
        return 0
    fi
    printf '%s\n' "$normalized"
}

history_normalize_decimal() {
    local value="${1:-}"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    while [[ "$value" != "0" && "${value#0}" != "$value" ]]; do
        value="${value#0}"
    done
    printf '%s\n' "$value"
}

history_parse_limit() {
    local value="$1"
    local normalized max_digits

    normalized=$(history_normalize_decimal "$value") || return 1
    [[ "$normalized" != "0" ]] || return 1
    max_digits=${#MOLE_HISTORY_MAX_LIMIT}
    [[ "${#normalized}" -le "$max_digits" ]] || return 1
    [[ "$normalized" -le "$MOLE_HISTORY_MAX_LIMIT" ]] || return 1
    printf '%s\n' "$normalized"
}

history_reset_active_session() {
    HISTORY_ACTIVE_COMMAND=""
    HISTORY_ACTIVE_STARTED_AT=""
    HISTORY_ACTIVE_ENDED_AT=""
    HISTORY_ACTIVE_ITEMS=0
    HISTORY_ACTIVE_SIZE="0B"
    HISTORY_ACTIVE_REMOVED=0
    HISTORY_ACTIVE_TRASHED=0
    HISTORY_ACTIVE_SKIPPED=0
    HISTORY_ACTIVE_FAILED=0
    HISTORY_ACTIVE_REBUILT=0
    HISTORY_ACTIVE_OTHER=0
    HISTORY_ACTIVE_OPERATIONS=0
    HISTORY_ACTIVE_FAILED_TASKS=0
    HISTORY_ACTIVE_MARKED=0
    HISTORY_ACTIVE_START_SEQ=0
}

# Sessions of different commands can overlap in one log: a `mo purge` started
# while `mo clean` still runs writes its markers between clean's operation
# lines. Every operation line names its command, so keep at most one open
# session per command and route each line to that command's session instead
# of whichever marker came last. Open sessions of other commands wait here,
# one record per session, fields separated by \x1f. Only sessions opened by a
# start marker are kept open this way: commands that log without markers
# (installer) still end at the next marker, as before.
declare -a HISTORY_PARKED_SESSIONS=()

history_park_active_session() {
    [[ -n "$HISTORY_ACTIVE_COMMAND" ]] || return 0
    local sep=$'\x1f'
    HISTORY_PARKED_SESSIONS+=("${HISTORY_ACTIVE_COMMAND}${sep}${HISTORY_ACTIVE_STARTED_AT}${sep}${HISTORY_ACTIVE_ENDED_AT}${sep}${HISTORY_ACTIVE_ITEMS}${sep}${HISTORY_ACTIVE_SIZE}${sep}${HISTORY_ACTIVE_REMOVED}${sep}${HISTORY_ACTIVE_TRASHED}${sep}${HISTORY_ACTIVE_SKIPPED}${sep}${HISTORY_ACTIVE_FAILED}${sep}${HISTORY_ACTIVE_REBUILT}${sep}${HISTORY_ACTIVE_OTHER}${sep}${HISTORY_ACTIVE_OPERATIONS}${sep}${HISTORY_ACTIVE_FAILED_TASKS}${sep}${HISTORY_ACTIVE_START_SEQ}${sep}${HISTORY_ACTIVE_MARKED}")
    history_reset_active_session
}

# Make the open session of <command> the active one. Returns 1 when that
# command has no open session; the previously active session stays parked.
history_activate_command_session() {
    local command="$1"
    [[ "$HISTORY_ACTIVE_COMMAND" == "$command" ]] && return 0

    history_park_active_session

    local -a remaining=()
    local record found=""
    for record in "${HISTORY_PARKED_SESSIONS[@]+"${HISTORY_PARKED_SESSIONS[@]}"}"; do
        if [[ -z "$found" && "${record%%$'\x1f'*}" == "$command" ]]; then
            found="$record"
        else
            remaining+=("$record")
        fi
    done
    HISTORY_PARKED_SESSIONS=("${remaining[@]+"${remaining[@]}"}")
    [[ -n "$found" ]] || return 1

    IFS=$'\x1f' read -r HISTORY_ACTIVE_COMMAND HISTORY_ACTIVE_STARTED_AT \
        HISTORY_ACTIVE_ENDED_AT HISTORY_ACTIVE_ITEMS HISTORY_ACTIVE_SIZE \
        HISTORY_ACTIVE_REMOVED HISTORY_ACTIVE_TRASHED HISTORY_ACTIVE_SKIPPED \
        HISTORY_ACTIVE_FAILED HISTORY_ACTIVE_REBUILT HISTORY_ACTIVE_OTHER \
        HISTORY_ACTIVE_OPERATIONS HISTORY_ACTIVE_FAILED_TASKS \
        HISTORY_ACTIVE_START_SEQ HISTORY_ACTIVE_MARKED <<< "$found"
    return 0
}

# Close sessions that no start marker opened, except the one of <command>.
history_finish_unmarked_sessions() {
    local keep_command="${1:-}"
    if [[ -n "$HISTORY_ACTIVE_COMMAND" && "$HISTORY_ACTIVE_MARKED" != "1" &&
        "$HISTORY_ACTIVE_COMMAND" != "$keep_command" ]]; then
        history_finish_session
    fi
    local -a unmarked=()
    local record command
    for record in "${HISTORY_PARKED_SESSIONS[@]+"${HISTORY_PARKED_SESSIONS[@]}"}"; do
        [[ "${record##*$'\x1f'}" == "1" ]] && continue
        [[ "${record%%$'\x1f'*}" == "$keep_command" ]] && continue
        unmarked+=("${record%%$'\x1f'*}")
    done
    for command in "${unmarked[@]+"${unmarked[@]}"}"; do
        history_activate_command_session "$command" && history_finish_session
    done
    return 0
}

# Close every session still open at the end of the log, then order all
# sessions by start time. An open session of one command no longer closes
# when another command starts, so without the sort a session that never
# wrote an end marker would be listed as the newest one.
history_finish_all_sessions() {
    history_finish_session
    while [[ ${#HISTORY_PARKED_SESSIONS[@]} -gt 0 ]]; do
        history_activate_command_session "${HISTORY_PARKED_SESSIONS[0]%%$'\x1f'*}" || break
        history_finish_session
    done

    local count=${#HISTORY_SESSION_COMMANDS[@]}
    [[ $count -gt 1 ]] || return 0
    local -a order=()
    local idx _started
    # Index first: tab is IFS whitespace, so an empty leading start time
    # would shift the index into the wrong variable. A malformed start marker
    # sorts by its end time instead. Timestamps have one-second resolution, so
    # sessions started in the same second keep the order of their markers.
    local _start_seq
    while IFS=$'\t' read -r idx _started _start_seq; do
        order+=("$idx")
    done < <(
        for ((idx = 0; idx < count; idx++)); do
            printf '%s\t%s\t%s\n' "$idx" \
                "${HISTORY_SESSION_STARTED_AT[$idx]:-${HISTORY_SESSION_ENDED_AT[$idx]}}" \
                "${HISTORY_SESSION_START_SEQ[$idx]:-0}"
        done | LC_ALL=C sort -t $'\t' -k2,2 -k3,3n
    )
    [[ ${#order[@]} -eq $count ]] || return 0

    local -a sorted_commands=() sorted_started=() sorted_ended=() sorted_items=() sorted_size=() sorted_removed=() sorted_trashed=()
    local -a sorted_skipped=() sorted_failed=() sorted_rebuilt=() sorted_other=() sorted_operations=() sorted_failed_tasks=()
    local -a sorted_start_seq=()
    for idx in "${order[@]}"; do
        sorted_commands+=("${HISTORY_SESSION_COMMANDS[$idx]}")
        sorted_started+=("${HISTORY_SESSION_STARTED_AT[$idx]}")
        sorted_ended+=("${HISTORY_SESSION_ENDED_AT[$idx]}")
        sorted_items+=("${HISTORY_SESSION_ITEMS[$idx]}")
        sorted_size+=("${HISTORY_SESSION_SIZE[$idx]}")
        sorted_removed+=("${HISTORY_SESSION_REMOVED[$idx]}")
        sorted_trashed+=("${HISTORY_SESSION_TRASHED[$idx]}")
        sorted_skipped+=("${HISTORY_SESSION_SKIPPED[$idx]}")
        sorted_failed+=("${HISTORY_SESSION_FAILED[$idx]}")
        sorted_rebuilt+=("${HISTORY_SESSION_REBUILT[$idx]}")
        sorted_other+=("${HISTORY_SESSION_OTHER[$idx]}")
        sorted_operations+=("${HISTORY_SESSION_OPERATIONS[$idx]}")
        sorted_failed_tasks+=("${HISTORY_SESSION_FAILED_TASKS[$idx]}")
        sorted_start_seq+=("${HISTORY_SESSION_START_SEQ[$idx]}")
    done
    HISTORY_SESSION_COMMANDS=("${sorted_commands[@]}")
    HISTORY_SESSION_STARTED_AT=("${sorted_started[@]}")
    HISTORY_SESSION_ENDED_AT=("${sorted_ended[@]}")
    HISTORY_SESSION_ITEMS=("${sorted_items[@]}")
    HISTORY_SESSION_SIZE=("${sorted_size[@]}")
    HISTORY_SESSION_REMOVED=("${sorted_removed[@]}")
    HISTORY_SESSION_TRASHED=("${sorted_trashed[@]}")
    HISTORY_SESSION_SKIPPED=("${sorted_skipped[@]}")
    HISTORY_SESSION_FAILED=("${sorted_failed[@]}")
    HISTORY_SESSION_REBUILT=("${sorted_rebuilt[@]}")
    HISTORY_SESSION_OTHER=("${sorted_other[@]}")
    HISTORY_SESSION_OPERATIONS=("${sorted_operations[@]}")
    HISTORY_SESSION_FAILED_TASKS=("${sorted_failed_tasks[@]}")
    HISTORY_SESSION_START_SEQ=("${sorted_start_seq[@]}")
}

history_start_session() {
    local command="$1"
    local started_at="$2"
    local marked="${3:-0}"

    # A new start of the same command closes that command's previous
    # session (it never wrote an end marker). Other commands stay open.
    if history_activate_command_session "$command"; then
        history_finish_session
    fi

    history_reset_active_session
    HISTORY_ACTIVE_COMMAND="$command"
    HISTORY_ACTIVE_STARTED_AT="$started_at"
    HISTORY_ACTIVE_MARKED="$marked"
    HISTORY_START_SEQ_COUNTER=$((HISTORY_START_SEQ_COUNTER + 1))
    HISTORY_ACTIVE_START_SEQ=$HISTORY_START_SEQ_COUNTER
}

history_finish_session() {
    [[ -z "$HISTORY_ACTIVE_COMMAND" ]] && return 0

    HISTORY_SESSION_COMMANDS+=("$HISTORY_ACTIVE_COMMAND")
    HISTORY_SESSION_STARTED_AT+=("$HISTORY_ACTIVE_STARTED_AT")
    HISTORY_SESSION_ENDED_AT+=("$HISTORY_ACTIVE_ENDED_AT")
    HISTORY_SESSION_ITEMS+=("$HISTORY_ACTIVE_ITEMS")
    HISTORY_SESSION_SIZE+=("$HISTORY_ACTIVE_SIZE")
    HISTORY_SESSION_REMOVED+=("$HISTORY_ACTIVE_REMOVED")
    HISTORY_SESSION_TRASHED+=("$HISTORY_ACTIVE_TRASHED")
    HISTORY_SESSION_SKIPPED+=("$HISTORY_ACTIVE_SKIPPED")
    HISTORY_SESSION_FAILED+=("$HISTORY_ACTIVE_FAILED")
    HISTORY_SESSION_REBUILT+=("$HISTORY_ACTIVE_REBUILT")
    HISTORY_SESSION_OTHER+=("$HISTORY_ACTIVE_OTHER")
    HISTORY_SESSION_OPERATIONS+=("$HISTORY_ACTIVE_OPERATIONS")
    HISTORY_SESSION_FAILED_TASKS+=("$HISTORY_ACTIVE_FAILED_TASKS")
    HISTORY_SESSION_START_SEQ+=("$HISTORY_ACTIVE_START_SEQ")

    history_reset_active_session
}

history_record_operation() {
    local command="$1"
    local action="$2"
    local timestamp="$3"

    if ! history_activate_command_session "$command"; then
        history_start_session "$command" "$timestamp"
    fi

    HISTORY_ACTIVE_OPERATIONS=$((HISTORY_ACTIVE_OPERATIONS + 1))
    case "$action" in
        REMOVED) HISTORY_ACTIVE_REMOVED=$((HISTORY_ACTIVE_REMOVED + 1)) ;;
        TRASHED) HISTORY_ACTIVE_TRASHED=$((HISTORY_ACTIVE_TRASHED + 1)) ;;
        SKIPPED) HISTORY_ACTIVE_SKIPPED=$((HISTORY_ACTIVE_SKIPPED + 1)) ;;
        FAILED) HISTORY_ACTIVE_FAILED=$((HISTORY_ACTIVE_FAILED + 1)) ;;
        TASK_FAILED) HISTORY_ACTIVE_FAILED_TASKS=$((HISTORY_ACTIVE_FAILED_TASKS + 1)) ;;
        REBUILT) HISTORY_ACTIVE_REBUILT=$((HISTORY_ACTIVE_REBUILT + 1)) ;;
        *) HISTORY_ACTIVE_OTHER=$((HISTORY_ACTIVE_OTHER + 1)) ;;
    esac
}

history_parse_session_start() {
    local line="$1"
    local inner command started_at

    case "$line" in
        "# ========== "*" session started at "*" ==========") ;;
        *) return 1 ;;
    esac
    inner="${line#"# ========== "}"
    command="${inner%% session started at *}"
    started_at="${inner#* session started at }"
    started_at="${started_at%" =========="}"
    history_finish_unmarked_sessions
    history_start_session "$command" "$started_at" 1
    return 0
}

history_parse_session_end() {
    local line="$1"
    local inner command rest ended_at tail items size

    case "$line" in
        "# ========== "*" session ended at "*" ==========") ;;
        *) return 1 ;;
    esac
    inner="${line#"# ========== "}"
    command="${inner%% session ended at *}"
    rest="${inner#* session ended at }"
    rest="${rest%" =========="}"
    ended_at="$rest"
    items=""
    size=""
    if [[ "$rest" == *", "* ]]; then
        ended_at="${rest%%, *}"
        tail="${rest#"$ended_at, "}"
        if [[ "$tail" == *" items, "* ]]; then
            items="${tail%% items,*}"
            size="${tail#*, }"
        fi
    fi

    history_finish_unmarked_sessions "$command"
    if ! history_activate_command_session "$command"; then
        history_start_session "$command" "$ended_at"
    fi

    HISTORY_ACTIVE_ENDED_AT="$ended_at"
    [[ "$items" =~ ^[0-9]+$ ]] && HISTORY_ACTIVE_ITEMS="$items"
    [[ -n "$size" ]] && HISTORY_ACTIVE_SIZE="$size"
    history_finish_session
    return 0
}

history_parse_operation_line() {
    local line="$1"
    local timestamp rest command rest_after_command action

    [[ "$line" == "["*"] ["*"] "* ]] || return 1

    timestamp="${line#\[}"
    timestamp="${timestamp%%]*}"
    rest="${line#*\] }"
    command="${rest#\[}"
    command="${command%%]*}"
    rest_after_command="${rest#*\] }"
    action="${rest_after_command%% *}"

    [[ -n "$timestamp" && -n "$command" && -n "$action" ]] || return 1
    history_record_operation "$command" "$action" "$timestamp"
    return 0
}

history_reset_sessions() {
    history_reset_active_session
    HISTORY_PARKED_SESSIONS=()
    HISTORY_SESSION_COMMANDS=()
    HISTORY_SESSION_STARTED_AT=()
    HISTORY_SESSION_ENDED_AT=()
    HISTORY_SESSION_ITEMS=()
    HISTORY_SESSION_SIZE=()
    HISTORY_SESSION_REMOVED=()
    HISTORY_SESSION_TRASHED=()
    HISTORY_SESSION_SKIPPED=()
    HISTORY_SESSION_FAILED=()
    HISTORY_SESSION_REBUILT=()
    HISTORY_SESSION_OTHER=()
    HISTORY_SESSION_OPERATIONS=()
    HISTORY_SESSION_FAILED_TASKS=()
    HISTORY_SESSION_START_SEQ=()
    HISTORY_START_SEQ_COUNTER=0
}

history_reset_deletions() {
    HISTORY_DELETE_TIMESTAMPS=()
    HISTORY_DELETE_MODES=()
    HISTORY_DELETE_SIZE_KB=()
    HISTORY_DELETE_STATUSES=()
    HISTORY_DELETE_PATHS=()
}

history_load_operations() {
    local log_file="$1"
    local line

    history_reset_sessions

    [[ -f "$log_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        history_parse_session_start "$line" && continue
        history_parse_session_end "$line" && continue
        history_parse_operation_line "$line" && continue
    done < "$log_file"

    history_finish_all_sessions
}

history_load_deletions() {
    local log_file="$1"
    local line timestamp mode size_kb status path

    history_reset_deletions

    [[ -f "$log_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        IFS=$'\t' read -r timestamp mode size_kb status path <<< "$line"
        [[ -n "${timestamp:-}" && -n "${mode:-}" && -n "${status:-}" ]] || continue
        HISTORY_DELETE_TIMESTAMPS+=("$timestamp")
        HISTORY_DELETE_MODES+=("$mode")
        HISTORY_DELETE_SIZE_KB+=("${size_kb:-unknown}")
        HISTORY_DELETE_STATUSES+=("$status")
        HISTORY_DELETE_PATHS+=("${path:-}")
    done < "$log_file"
}

history_join_counts() {
    local -a parts=()
    local removed="$1"
    local trashed="$2"
    local skipped="$3"
    local failed="$4"
    local rebuilt="$5"
    local other="$6"

    [[ "$removed" -gt 0 ]] && parts+=("removed $removed")
    [[ "$trashed" -gt 0 ]] && parts+=("trashed $trashed")
    [[ "$skipped" -gt 0 ]] && parts+=("skipped $skipped")
    [[ "$failed" -gt 0 ]] && parts+=("failed $failed")
    [[ "$rebuilt" -gt 0 ]] && parts+=("rebuilt $rebuilt")
    [[ "$other" -gt 0 ]] && parts+=("other $other")

    if [[ ${#parts[@]} -eq 0 ]]; then
        printf 'no file actions'
        return 0
    fi

    local output="${parts[0]}"
    local idx=1
    while [[ $idx -lt ${#parts[@]} ]]; do
        output+=", ${parts[$idx]}"
        idx=$((idx + 1))
    done
    printf '%s' "$output"
}

history_size_label() {
    local size_kb="$1"

    if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
        bytes_to_human_kb "$size_kb"
    else
        printf 'unknown'
    fi
}

history_json_escape() {
    local value="${1:-}"
    local LC_ALL=C
    local char code idx

    idx=0
    while [[ "$idx" -lt "${#value}" ]]; do
        char="${value:$idx:1}"
        case "$char" in
            "\\") printf '%s' "\\\\" ;;
            "\"") printf '%s' "\\\"" ;;
            $'\b') printf '%s' "\\b" ;;
            $'\f') printf '%s' "\\f" ;;
            $'\n') printf '%s' "\\n" ;;
            $'\r') printf '%s' "\\r" ;;
            $'\t') printf '%s' "\\t" ;;
            *)
                printf -v code '%d' "'$char"
                if [[ "$code" -lt 0 ]]; then
                    code=$((code + 256))
                fi
                if [[ "$code" -lt 32 ]]; then
                    printf '\\u%04x' "$code"
                else
                    printf '%s' "$char"
                fi
                ;;
        esac
        idx=$((idx + 1))
    done
}

history_json_string() {
    printf '"'
    history_json_escape "${1:-}"
    printf '"'
}

history_json_string_field() {
    local indent="$1"
    local key="$2"
    local value="${3:-}"
    local suffix="${4-,}"

    printf '%s"%s": ' "$indent" "$key"
    history_json_string "$value"
    printf '%s\n' "$suffix"
}

history_json_number_field() {
    local indent="$1"
    local key="$2"
    local value="$3"
    local suffix="${4-,}"

    printf '%s"%s": %s%s\n' "$indent" "$key" "$value" "$suffix"
}

history_render_text() {
    local limit
    limit=$(history_normalize_limit "${1:-$MOLE_HISTORY_DEFAULT_LIMIT}")

    local operations_log deletions_log session_count deletion_count
    operations_log=$(history_operations_log_file)
    deletions_log=$(history_deletions_log_file)
    session_count=${#HISTORY_SESSION_COMMANDS[@]}
    deletion_count=${#HISTORY_DELETE_TIMESTAMPS[@]}

    printf '\n%sMole History%s\n\n' "$BLUE" "$NC"

    if [[ "$session_count" -eq 0 ]]; then
        printf 'Recent sessions\n'
        printf '  No operation history yet.\n'
    else
        printf 'Recent sessions\n'
        local start=$((session_count - limit))
        [[ "$start" -lt 0 ]] && start=0
        local idx=$((session_count - 1))
        while [[ "$idx" -ge "$start" ]]; do
            local command="${HISTORY_SESSION_COMMANDS[$idx]}"
            local started="${HISTORY_SESSION_STARTED_AT[$idx]}"
            local ended="${HISTORY_SESSION_ENDED_AT[$idx]}"
            local items="${HISTORY_SESSION_ITEMS[$idx]}"
            local size="${HISTORY_SESSION_SIZE[$idx]}"
            local removed="${HISTORY_SESSION_REMOVED[$idx]}"
            local trashed="${HISTORY_SESSION_TRASHED[$idx]}"
            local skipped="${HISTORY_SESSION_SKIPPED[$idx]}"
            local failed="${HISTORY_SESSION_FAILED[$idx]}"
            local rebuilt="${HISTORY_SESSION_REBUILT[$idx]}"
            local other="${HISTORY_SESSION_OTHER[$idx]}"
            local failed_tasks="${HISTORY_SESSION_FAILED_TASKS[$idx]}"
            local count_text
            count_text=$(history_join_counts "$removed" "$trashed" "$skipped" "$failed" "$rebuilt" "$other")
            if [[ "$failed_tasks" -gt 0 ]]; then
                count_text+=", $failed_tasks optimize tasks failed"
            fi
            [[ -z "$ended" ]] && ended="not ended"
            printf '  %-10s %s, %s items, %s\n' "$command" "$started" "$items" "$size"
            printf '             %s, ended %s\n' "$count_text" "$ended"
            idx=$((idx - 1))
        done
    fi

    printf '\nDeletion audit\n'
    if [[ "$deletion_count" -eq 0 ]]; then
        printf '  No deletion audit entries yet.\n'
    else
        local start=$((deletion_count - limit))
        [[ "$start" -lt 0 ]] && start=0
        local idx=$((deletion_count - 1))
        while [[ "$idx" -ge "$start" ]]; do
            local timestamp="${HISTORY_DELETE_TIMESTAMPS[$idx]}"
            local mode="${HISTORY_DELETE_MODES[$idx]}"
            local size_kb="${HISTORY_DELETE_SIZE_KB[$idx]}"
            local status="${HISTORY_DELETE_STATUSES[$idx]}"
            local path="${HISTORY_DELETE_PATHS[$idx]}"
            local size_label
            size_label=$(history_size_label "$size_kb")
            printf '  %-24s %-9s %-16s %8s  %s\n' "$timestamp" "$mode" "$status" "$size_label" "$path"
            idx=$((idx - 1))
        done
    fi

    printf '\nLogs\n'
    printf '  operations: %s\n' "$operations_log"
    printf '  deletions:  %s\n\n' "$deletions_log"
}

history_render_json_sessions() {
    local limit="$1"
    local session_count=${#HISTORY_SESSION_COMMANDS[@]}
    local start=$((session_count - limit))
    [[ "$start" -lt 0 ]] && start=0

    printf '  "sessions": [\n'
    local emitted=0
    if [[ "$session_count" -gt 0 ]]; then
        local idx=$((session_count - 1))
        while [[ "$idx" -ge "$start" ]]; do
            [[ "$emitted" -gt 0 ]] && printf ',\n'
            printf '    {\n'
            history_json_string_field "      " "command" "${HISTORY_SESSION_COMMANDS[$idx]}"
            history_json_string_field "      " "started_at" "${HISTORY_SESSION_STARTED_AT[$idx]}"
            history_json_string_field "      " "ended_at" "${HISTORY_SESSION_ENDED_AT[$idx]}"
            history_json_number_field "      " "items" "${HISTORY_SESSION_ITEMS[$idx]}"
            history_json_string_field "      " "size" "${HISTORY_SESSION_SIZE[$idx]}"
            history_json_number_field "      " "operation_count" "${HISTORY_SESSION_OPERATIONS[$idx]}"
            history_json_number_field "      " "failed_tasks" "${HISTORY_SESSION_FAILED_TASKS[$idx]}"
            printf '      "actions": {"removed": %s, "trashed": %s, "skipped": %s, "failed": %s, "rebuilt": %s, "other": %s}\n' \
                "${HISTORY_SESSION_REMOVED[$idx]}" \
                "${HISTORY_SESSION_TRASHED[$idx]}" \
                "${HISTORY_SESSION_SKIPPED[$idx]}" \
                "${HISTORY_SESSION_FAILED[$idx]}" \
                "${HISTORY_SESSION_REBUILT[$idx]}" \
                "${HISTORY_SESSION_OTHER[$idx]}"
            printf '    }'
            emitted=$((emitted + 1))
            idx=$((idx - 1))
        done
    fi
    printf '\n  ]'
}

history_render_json_deletions() {
    local limit="$1"
    local deletion_count=${#HISTORY_DELETE_TIMESTAMPS[@]}
    local start=$((deletion_count - limit))
    [[ "$start" -lt 0 ]] && start=0

    printf '  "deletions": [\n'
    local emitted=0
    if [[ "$deletion_count" -gt 0 ]]; then
        local idx=$((deletion_count - 1))
        while [[ "$idx" -ge "$start" ]]; do
            [[ "$emitted" -gt 0 ]] && printf ',\n'
            printf '    {\n'
            history_json_string_field "      " "timestamp" "${HISTORY_DELETE_TIMESTAMPS[$idx]}"
            history_json_string_field "      " "mode" "${HISTORY_DELETE_MODES[$idx]}"
            history_json_string_field "      " "status" "${HISTORY_DELETE_STATUSES[$idx]}"
            if [[ "${HISTORY_DELETE_SIZE_KB[$idx]}" =~ ^[0-9]+$ ]]; then
                history_json_number_field "      " "size_kb" "${HISTORY_DELETE_SIZE_KB[$idx]}"
            else
                printf '      "size_kb": null,\n'
            fi
            history_json_string_field "      " "path" "${HISTORY_DELETE_PATHS[$idx]}" ""
            printf '    }'
            emitted=$((emitted + 1))
            idx=$((idx - 1))
        done
    fi
    printf '\n  ]'
}

history_render_json() {
    local limit
    limit=$(history_normalize_limit "${1:-$MOLE_HISTORY_DEFAULT_LIMIT}")

    local operations_log deletions_log
    operations_log=$(history_operations_log_file)
    deletions_log=$(history_deletions_log_file)

    printf '{\n'
    printf '  "logs": {"operations": '
    history_json_string "$operations_log"
    printf ', "deletions": '
    history_json_string "$deletions_log"
    printf '},\n'
    printf '  "limit": %s,\n' "$limit"
    history_render_json_sessions "$limit"
    printf ',\n'
    history_render_json_deletions "$limit"
    printf '\n}\n'
}
