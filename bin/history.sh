#!/bin/bash
# Mole CLI (Linux) - history: read operations.log back as recent sessions and
# operations, newest first, as text or JSON. Same report as Mole CLI (macOS)
# and (Windows) `mo history`.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"

HISTORY_JSON=false
HISTORY_LIMIT=20

history_help() {
    echo "Usage: mo history [OPTIONS]"
    echo ""
    echo "Review recent Mole cleanup and removal activity."
    echo ""
    echo "Options:"
    echo "  --json           Output history as JSON"
    echo "  --limit N        Show the most recent N entries, 1-200"
    echo "  -h, --help       Show this help message"
}

# A plain decimal from 1 to 200.
history_limit_ok() { [[ "$1" =~ ^[0-9]{1,3}$ ]] && ((10#$1 >= 1 && 10#$1 <= 200)); }

# Parse the log into tab-separated records, oldest first:
# Empty run ids and details are "-" (read with a tab IFS drops empty fields).
#   S <command> <run id> <started at> <removed> <trashed> <skipped> <failed> <other> <count>
#   O <timestamp> <command> <run id> <action> <path> <detail>
# Rows from before run ids existed are grouped while the command stays the
# same. Session marker lines and anything unparsable are skipped.
history_parse() {
    LC_ALL=C awk '
    function bucket(a) {
        if (a == "REMOVED") return 1
        if (a == "TRASHED") return 2
        if (a == "SKIPPED") return 3
        if (a == "FAILED" || a == "TASK_FAILED") return 4
        return 5
    }
    {
        line = $0
        sub(/\r$/, "", line)
        if (substr(line, 1, 1) != "[" || substr(line, 21, 3) != "] [") next
        ts = substr(line, 2, 19)
        if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) next
        rest = substr(line, 24)
        i = index(rest, "] ")
        if (i == 0) next
        label = substr(rest, 1, i - 1)
        rest = substr(rest, i + 2)
        cmd = label; run = ""
        j = index(label, " run=")
        if (j > 0) { cmd = substr(label, 1, j - 1); run = substr(label, j + 5) }
        if (cmd !~ /^[a-z][a-z0-9._-]*$/) next
        k = index(rest, " ")
        if (k == 0) next
        action = substr(rest, 1, k - 1)
        if (action !~ /^[A-Z][A-Z_]*$/) next
        body = substr(rest, k + 1)
        path = body; detail = ""
        if (match(body, / \([^()]*\)$/)) {
            path = substr(body, 1, RSTART - 1)
            detail = substr(body, RSTART + 2, RLENGTH - 3)
        }
        if (detail == "-") detail = ""
        if (path == "") next
        if (run != "") key = cmd "|" run
        else if (lastkey != "" && lastcmd == cmd && lastrun == "") key = lastkey
        else { legacy++; key = cmd "|legacy" legacy }
        if (!(key in sid)) {
            n++; sid[key] = n; scmd[n] = cmd; srun[n] = run; sts[n] = ts
            for (b = 1; b <= 5; b++) cnt[n, b] = 0
            total[n] = 0
        }
        s = sid[key]
        cnt[s, bucket(action)]++
        total[s]++
        lastkey = key; lastcmd = cmd; lastrun = run
        printf "O\t%s\t%s\t%s\t%s\t%s\t%s\n", ts, cmd, (run == "" ? "-" : run), action, path, (detail == "" ? "-" : detail)
    }
    END {
        for (s = 1; s <= n; s++)
            printf "S\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", scmd[s], (srun[s] == "" ? "-" : srun[s]), sts[s], cnt[s,1], cnt[s,2], cnt[s,3], cnt[s,4], cnt[s,5], total[s]
    }' "$@"
}

json_string() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    if [[ "$s" == *[[:cntrl:]]* ]]; then
        local out="" c i LC_ALL=C
        for ((i = 0; i < ${#s}; i++)); do
            c="${s:i:1}"
            case "$c" in
                [[:cntrl:]]) out+=$(printf '\\u%04x' "'$c") ;;
                *) out+="$c" ;;
            esac
        done
        s="$out"
    fi
    printf '"%s"' "$s"
}

history_main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) HISTORY_JSON=true ;;
            --limit | --limit=*)
                local value
                if [[ "$1" == --limit=* ]]; then
                    value="${1#--limit=}"
                else
                    shift
                    [[ $# -gt 0 ]] || {
                        echo "Missing value for --limit" >&2
                        return 1
                    }
                    value="$1"
                fi
                history_limit_ok "$value" || {
                    echo "Invalid value for --limit: $value" >&2
                    return 1
                }
                HISTORY_LIMIT=$((10#$value))
                ;;
            --debug) export MO_DEBUG=1 ;;
            -h | --help)
                history_help
                return 0
                ;;
            *)
                echo "Unexpected argument for mo history: $1" >&2
                echo "Run 'mo history --help' for usage." >&2
                return 1
                ;;
        esac
        shift
    done

    local log="$OPERATIONS_LOG_FILE"
    local -a sessions=() operations=()
    if [[ -f "$log" ]]; then
        if [[ ! -r "$log" ]]; then
            echo "Cannot read $(mole_display_path "$log")." >&2
            return 1
        fi
        local rec
        while IFS= read -r rec; do
            case "$rec" in
                S$'\t'*) sessions+=("${rec#S$'\t'}") ;;
                O$'\t'*) operations+=("${rec#O$'\t'}") ;;
            esac
        done < <(history_parse "$log")
    fi

    # Newest first, at most the limit.
    local -a new_s=() new_o=()
    local i
    for ((i = ${#sessions[@]} - 1; i >= 0 && ${#new_s[@]} < HISTORY_LIMIT; i--)); do new_s+=("${sessions[i]}"); done
    for ((i = ${#operations[@]} - 1; i >= 0 && ${#new_o[@]} < HISTORY_LIMIT; i--)); do new_o+=("${operations[i]}"); done

    local cmd run started removed trashed skipped failed other count ts action path detail
    if [[ "$HISTORY_JSON" == true ]]; then
        printf '{\n  "logs": {"operations": %s},\n  "limit": %d,\n  "sessions": [' "$(json_string "$log")" "$HISTORY_LIMIT"
        local sep=""
        for rec in "${new_s[@]+"${new_s[@]}"}"; do
            IFS=$'\t' read -r cmd run started removed trashed skipped failed other count <<< "$rec"
            [[ "$run" == - ]] && run=""
            printf '%s\n    {"command": %s, "run_id": %s, "started_at": %s, "operation_count": %d, "actions": {"removed": %d, "trashed": %d, "skipped": %d, "failed": %d, "other": %d}}' \
                "$sep" "$(json_string "$cmd")" "$(json_string "$run")" "$(json_string "$started")" "$count" "$removed" "$trashed" "$skipped" "$failed" "$other"
            sep=","
        done
        [[ -n "$sep" ]] && printf '\n  '
        printf '],\n  "operations": ['
        sep=""
        for rec in "${new_o[@]+"${new_o[@]}"}"; do
            IFS=$'\t' read -r ts cmd run action path detail <<< "$rec"
            [[ "$run" == - ]] && run=""
            [[ "$detail" == - ]] && detail=""
            mole_ascii_lowercase action "$action"
            printf '%s\n    {"timestamp": %s, "command": %s, "run_id": %s, "action": %s, "path": %s, "detail": %s}' \
                "$sep" "$(json_string "$ts")" "$(json_string "$cmd")" "$(json_string "$run")" "$(json_string "$action")" "$(json_string "$path")" "$(json_string "$detail")"
            sep=","
        done
        [[ -n "$sep" ]] && printf '\n  '
        printf ']\n}\n'
        return 0
    fi

    echo -e "${PURPLE_BOLD}Mole History${NC}"
    echo ""
    echo -e "${BLUE}Recent sessions${NC}"
    [[ ${#new_s[@]} -gt 0 ]] || echo -e "  ${GRAY}No operation history yet.${NC}"
    local parts name n
    for rec in "${new_s[@]+"${new_s[@]}"}"; do
        IFS=$'\t' read -r cmd run started removed trashed skipped failed other count <<< "$rec"
        parts=""
        for name in removed trashed skipped failed other; do
            n="${!name}"
            ((n > 0)) && parts+="${parts:+, }$name $n"
        done
        printf '  %-10s %s, %s\n' "$cmd" "$started" "${parts:-no file actions}"
    done
    echo ""
    echo -e "${BLUE}Recent operations${NC}"
    [[ ${#new_o[@]} -gt 0 ]] || echo -e "  ${GRAY}No operations recorded yet.${NC}"
    for rec in "${new_o[@]+"${new_o[@]}"}"; do
        IFS=$'\t' read -r ts cmd run action path detail <<< "$rec"
        [[ "$detail" == - ]] && detail=""
        mole_ascii_lowercase action "$action"
        printf '  %s %-11s %s%s\n' "$ts" "$action" "$path" "${detail:+ ($detail)}"
    done
    echo ""
    echo -e "${BLUE}Log${NC}"
    echo "  operations: $(mole_display_path "$log")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    history_main "$@"
fi
