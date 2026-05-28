#!/bin/bash
# Roomy - operation history reports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/core/common.sh
source "$PROJECT_ROOT/lib/core/common.sh"

trap cleanup_temp_files EXIT INT TERM

show_report_help() {
    cat << EOF
Usage: roomy report [OPTIONS]

Summarize Roomy's operation journal.

Options:
  --last Nd|Nh       Include recent records only (default: all)
  --limit N          Number of top paths to show (default: 8)
  --json             Output JSON
  -h, --help         Show this help message
EOF
}

report_cutoff_timestamp() {
    local value="$1"
    [[ -n "$value" ]] || return 1

    case "$value" in
        *d)
            local days="${value%d}"
            [[ "$days" =~ ^[0-9]+$ ]] || return 1
            date -v-"${days}"d '+%Y-%m-%d %H:%M:%S' 2> /dev/null
            ;;
        *h)
            local hours="${value%h}"
            [[ "$hours" =~ ^[0-9]+$ ]] || return 1
            date -v-"${hours}"H '+%Y-%m-%d %H:%M:%S' 2> /dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

report_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

report_create_temp_file() {
    local target_var="$1"
    local temp_path
    temp_path=$(create_temp_file) || return 1
    register_temp_file "$temp_path"
    printf -v "$target_var" '%s' "$temp_path"
}

main() {
    local last=""
    local cutoff=""
    local json="false"
    local limit=8

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --last)
                shift
                [[ $# -gt 0 ]] || {
                    echo "Missing value for --last" >&2
                    exit 1
                }
                last="$1"
                cutoff=$(report_cutoff_timestamp "$last") || {
                    echo "Invalid --last value: $last" >&2
                    exit 1
                }
                ;;
            --limit)
                shift
                [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || {
                    echo "Invalid --limit value" >&2
                    exit 1
                }
                limit="$1"
                ;;
            --json) json="true" ;;
            -h | --help)
                show_report_help
                exit 0
                ;;
            *)
                echo "Unknown report option: $1" >&2
                exit 1
                ;;
        esac
        shift
    done

    local journal="${ROOMY_OPERATION_JOURNAL_FILE:-${ROOMY_LOG_DIR:-$HOME/Library/Logs/roomy}/operation_journal.jsonl}"
    if [[ ! -f "$journal" ]]; then
        if [[ "$json" == "true" ]]; then
            printf '{"schema_version":1,"sessions":0,"bytes_reclaimed":0,"actions":{},"commands":[],"top_paths":[]}\n'
        else
            echo "No Roomy operation journal found"
        fi
        exit 0
    fi

    local temp
    report_create_temp_file temp
    awk -v cutoff="$cutoff" -v limit="$limit" '
    function field(line, key,    pat, rest, i, c, out, esc) {
        pat = "\"" key "\":\""
        i = index(line, pat)
        if (i == 0) return ""
        rest = substr(line, i + length(pat))
        out = ""
        esc = 0
        for (i = 1; i <= length(rest); i++) {
            c = substr(rest, i, 1)
            if (esc) {
                if (c == "n") out = out "\\n"
                else if (c == "t") out = out "\\t"
                else if (c == "r") out = out "\\r"
                else out = out c
                esc = 0
                continue
            }
            if (c == "\\") { esc = 1; continue }
            if (c == "\"") break
            out = out c
        }
        return out
    }
    function bytes_from_human(value,    v, n, unit) {
        v = toupper(value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (match(v, /[0-9]+(\.[0-9]+)?/)) {
            n = substr(v, RSTART, RLENGTH) + 0
        } else {
            return 0
        }
        unit = v
        sub(/^[^A-Z]*/, "", unit)
        gsub(/[[:space:]]/, "", unit)
        if (unit ~ /^TB/) return int(n * 1099511627776)
        if (unit ~ /^GB|^GIB/) return int(n * 1073741824)
        if (unit ~ /^MB|^MIB/) return int(n * 1048576)
        if (unit ~ /^KB|^KIB/) return int(n * 1024)
        return int(n)
    }
    function detail_bytes(detail,    d) {
        d = detail
        if (index(d, ",") > 0) {
            sub(/^.*,/, "", d)
        }
        return bytes_from_human(d)
    }
    function emit(path, bytes) {
        if (path == "" || bytes <= 0) return
        path_bytes[path] += bytes
    }
    {
        ts = field($0, "timestamp")
        if (cutoff != "" && ts < cutoff) next
        record_type = field($0, "record_type")
        command = field($0, "command")
        action = field($0, "action")
        path = field($0, "path")
        detail = field($0, "detail")

        if (record_type == "session" && action == "ENDED") {
            sessions++
            command_sessions[command]++
            b = detail_bytes(detail)
            reclaimed += b
            command_bytes[command] += b
        } else if (record_type == "operation") {
            actions[action]++
            emit(path, detail_bytes(detail))
        }
    }
    END {
        printf "summary\t%d\t%d\n", sessions, reclaimed
        for (action in actions) {
            printf "action\t%s\t%d\n", action, actions[action]
        }
        for (command in command_sessions) {
            printf "command\t%s\t%d\t%d\n", command, command_sessions[command], command_bytes[command]
        }
        for (path in path_bytes) {
            printf "path\t%s\t%d\n", path, path_bytes[path]
        }
    }' "$journal" > "$temp"

    local sessions=0 reclaimed=0
    local action_lines command_lines path_lines
    report_create_temp_file action_lines
    report_create_temp_file command_lines
    report_create_temp_file path_lines

    while IFS=$'\t' read -r kind a b c; do
        case "$kind" in
            summary)
                sessions="$a"
                reclaimed="$b"
                ;;
            action)
                printf '%s\t%s\n' "$a" "$b" >> "$action_lines"
                ;;
            command)
                printf '%s\t%s\t%s\n' "$a" "$b" "$c" >> "$command_lines"
                ;;
            path)
                printf '%s\t%s\n' "$a" "$b" >> "$path_lines"
                ;;
        esac
    done < "$temp"

    if [[ "$json" == "true" ]]; then
        printf '{"schema_version":1,"range":"%s","sessions":%s,"bytes_reclaimed":%s,' "$(report_json_escape "${last:-all}")" "$sessions" "$reclaimed"
        printf '"actions":{'
        local first=true name count
        while IFS=$'\t' read -r name count; do
            [[ -n "$name" ]] || continue
            $first || printf ','
            first=false
            printf '"%s":%s' "$(report_json_escape "$name")" "$count"
        done < "$action_lines"
        printf '},"commands":['
        first=true
        local command sessions_count bytes
        while IFS=$'\t' read -r command sessions_count bytes; do
            [[ -n "$command" ]] || continue
            $first || printf ','
            first=false
            printf '{"name":"%s","sessions":%s,"bytes_reclaimed":%s}' "$(report_json_escape "$command")" "$sessions_count" "$bytes"
        done < "$command_lines"
        printf '],"top_paths":['
        first=true
        local path path_bytes shown=0
        sort -t$'\t' -k2,2nr "$path_lines" | while IFS=$'\t' read -r path path_bytes; do
            [[ -n "$path" ]] || continue
            [[ "$shown" -lt "$limit" ]] || break
            if [[ "$shown" -gt 0 ]]; then printf ','; fi
            printf '{"path":"%s","bytes":%s}' "$(report_json_escape "$path")" "$path_bytes"
            shown=$((shown + 1))
        done
        printf ']}\n'
        exit 0
    fi

    echo "Roomy report (${last:-all history})"
    echo "  Sessions: $sessions"
    echo "  Estimated reclaimed: $(bytes_to_human "$reclaimed")"
    echo ""
    echo "Actions:"
    if [[ -s "$action_lines" ]]; then
        sort "$action_lines" | while IFS=$'\t' read -r name count; do
            echo "  $name: $count"
        done
    else
        echo "  none"
    fi
    echo ""
    echo "Commands:"
    if [[ -s "$command_lines" ]]; then
        sort "$command_lines" | while IFS=$'\t' read -r command sessions_count bytes; do
            echo "  $command: $sessions_count sessions, $(bytes_to_human "$bytes")"
        done
    else
        echo "  none"
    fi
    echo ""
    echo "Top paths:"
    if [[ -s "$path_lines" ]]; then
        sort -t$'\t' -k2,2nr "$path_lines" | head -n "$limit" | while IFS=$'\t' read -r path path_bytes; do
            echo "  $(bytes_to_human "$path_bytes")  $path"
        done
    else
        echo "  none"
    fi
}

main "$@"
