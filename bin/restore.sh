#!/bin/bash
# Roomy - best-effort restore center for Trash-routed operations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/core/common.sh
source "$PROJECT_ROOT/lib/core/common.sh"

show_restore_help() {
    cat << EOF
Usage: roomy restore <command> [OPTIONS] [PATH ...]

Restore items that Roomy moved to Trash.

Commands:
  list              List recent trashed items
  restore           Restore selected paths, or use --all

Options:
  --all             Restore all resolvable trashed items
  --limit N         Limit listed/restored items (default list: 20)
  --dry-run, -n     Preview restore operations
  -h, --help        Show this help message
EOF
}

restore_journal_path() {
    printf '%s\n' "${ROOMY_OPERATION_JOURNAL_FILE:-${ROOMY_LOG_DIR:-$HOME/Library/Logs/roomy}/operation_journal.jsonl}"
}

restore_trash_dir() {
    printf '%s\n' "${ROOMY_TEST_TRASH_DIR:-$HOME/.Trash}"
}

RESTORE_LAST_CANDIDATE_STATUS=""

restore_trashed_records() {
    local journal
    journal=$(restore_journal_path)
    [[ -f "$journal" ]] || return 0
    awk '
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
                if (c == "n") out = out "\n"
                else if (c == "t") out = out "\t"
                else if (c == "r") out = out "\r"
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
    {
        if (field($0, "record_type") == "operation" && field($0, "action") == "TRASHED") {
            path = field($0, "path")
            if (path != "" && !seen[path]++) {
                printf "%s%c%s%c", field($0, "timestamp"), 0, path, 0
            }
        }
    }' "$journal"
}

restore_sanitized_basename() {
    local path="$1"
    local base
    base=$(basename "$path")
    base="${base//:/__}"
    base="${base//\//__}"
    [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || base="roomy-trash-item"
    printf '%s\n' "$base"
}

restore_destination_is_safe() {
    local original="$1"
    validate_path_for_deletion "$original" > /dev/null 2>&1 || return 1
    ! restore_destination_has_symlinked_parent "$original" || return 1

    local physical
    physical=$(restore_destination_physical_path "$original") || return 1
    validate_path_for_deletion "$physical" > /dev/null 2>&1
}

restore_destination_has_symlinked_parent() {
    local original="$1"
    local parent
    parent=$(dirname "$original")

    while [[ "$parent" != "/" && "$parent" != "." && -n "$parent" ]]; do
        [[ -L "$parent" ]] && return 0
        parent=$(dirname "$parent")
    done
    return 1
}

restore_destination_physical_path() {
    roomy_physical_path_for_validation "$1"
}

restore_trash_physical_dir() {
    local trash_dir="$1"

    if [[ -z "$trash_dir" || "$trash_dir" != /* || -L "$trash_dir" ]]; then
        RESTORE_LAST_CANDIDATE_STATUS="unsafe Trash directory"
        return 1
    fi
    [[ -d "$trash_dir" ]] || return 1

    local physical
    if ! physical=$(cd -P "$trash_dir" 2> /dev/null && pwd); then
        RESTORE_LAST_CANDIDATE_STATUS="unsafe Trash directory"
        return 1
    fi
    printf '%s\n' "$physical"
}

restore_candidate_is_safe() {
    local candidate="$1"
    local trash_physical="$2"
    local candidate_physical parent base

    [[ -n "$candidate" && "$candidate" == /* ]] || return 1
    [[ ! -L "$candidate" ]] || return 1
    [[ -f "$candidate" || -d "$candidate" ]] || return 1

    if [[ -d "$candidate" ]]; then
        candidate_physical=$(cd -P "$candidate" 2> /dev/null && pwd) || return 1
    else
        parent=$(dirname "$candidate")
        base=$(basename "$candidate")
        candidate_physical="$(cd -P "$parent" 2> /dev/null && pwd)/$base" || return 1
    fi

    [[ "$candidate_physical" == "$trash_physical"/* ]]
}

restore_find_candidate() {
    local original="$1"
    RESTORE_LAST_CANDIDATE_STATUS="not found or ambiguous"

    local trash_dir trash_physical
    trash_dir=$(restore_trash_dir)
    if ! trash_physical=$(restore_trash_physical_dir "$trash_dir"); then
        return 1
    fi

    local base
    base=$(restore_sanitized_basename "$original")
    local -a raw_matches=()
    local -a safe_matches=()
    local candidate

    candidate="$trash_dir/$base"
    if [[ -e "$candidate" || -L "$candidate" ]]; then
        raw_matches+=("$candidate")
        if restore_candidate_is_safe "$candidate" "$trash_physical"; then
            safe_matches+=("$candidate")
        fi
    fi

    for candidate in "$trash_dir/$base".*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        raw_matches+=("$candidate")
        if restore_candidate_is_safe "$candidate" "$trash_physical"; then
            safe_matches+=("$candidate")
        fi
    done

    [[ ${#raw_matches[@]} -eq 1 ]] || return 1
    if [[ ${#safe_matches[@]} -ne 1 ]]; then
        RESTORE_LAST_CANDIDATE_STATUS="unsafe Trash item"
        return 1
    fi

    printf '%s\n' "${safe_matches[0]}"
}

restore_list() {
    local limit=20
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                shift
                [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || {
                    echo "Invalid --limit value" >&2
                    return 1
                }
                limit="$1"
                ;;
            -h | --help)
                show_restore_help
                return 0
                ;;
            *)
                echo "Unknown restore list option: $1" >&2
                return 1
                ;;
        esac
        shift
    done

    local shown=0 timestamp original candidate status
    while IFS= read -r -d '' timestamp && IFS= read -r -d '' original; do
        [[ -n "$original" ]] || continue
        [[ "$shown" -lt "$limit" ]] || break
        if ! restore_destination_is_safe "$original"; then
            status="unsafe destination"
        elif [[ -e "$original" || -L "$original" ]]; then
            status="already restored"
        elif candidate=$(restore_find_candidate "$original"); then
            status="restorable: ${candidate/#$HOME/~}"
        else
            status="${RESTORE_LAST_CANDIDATE_STATUS:-not found or ambiguous}"
        fi
        echo "$timestamp  $status"
        echo "  $original"
        shown=$((shown + 1))
    done < <(restore_trashed_records)

    [[ "$shown" -gt 0 ]] || echo "No trashed Roomy operations found"
}

restore_targets() {
    local dry_run="false"
    local all="false"
    local limit=0
    local -a requested=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) all="true" ;;
            --dry-run | -n) dry_run="true" ;;
            --limit)
                shift
                [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || {
                    echo "Invalid --limit value" >&2
                    return 1
                }
                limit="$1"
                ;;
            -h | --help)
                show_restore_help
                return 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    requested+=("$1")
                    shift
                done
                break
                ;;
            -*)
                echo "Unknown restore option: $1" >&2
                return 1
                ;;
            *)
                requested+=("$1")
                ;;
        esac
        shift
    done

    if [[ "$all" != "true" && ${#requested[@]} -eq 0 ]]; then
        echo "Usage: roomy restore restore [--all] [PATH ...]" >&2
        return 1
    fi

    local restored=0 skipped=0 considered=0
    local timestamp original candidate parent match=false
    while IFS= read -r -d '' timestamp && IFS= read -r -d '' original; do
        [[ -n "$original" ]] || continue
        if [[ "$all" == "true" ]]; then
            match=true
        else
            match=false
            local req
            for req in "${requested[@]}"; do
                [[ "$req" == "$original" ]] && match=true && break
            done
        fi
        $match || continue
        considered=$((considered + 1))
        if [[ "$limit" -gt 0 && "$considered" -gt "$limit" ]]; then
            break
        fi

        if ! restore_destination_is_safe "$original"; then
            echo "Skipped, unsafe restore destination: $original"
            skipped=$((skipped + 1))
            continue
        fi
        if [[ -e "$original" || -L "$original" ]]; then
            echo "Skipped, original already exists: $original"
            skipped=$((skipped + 1))
            continue
        fi
        if ! candidate=$(restore_find_candidate "$original"); then
            if [[ "${RESTORE_LAST_CANDIDATE_STATUS:-}" == unsafe\ Trash\ * ]]; then
                echo "Skipped, $RESTORE_LAST_CANDIDATE_STATUS: $original"
            else
                echo "Skipped, Trash item not found or ambiguous: $original"
            fi
            skipped=$((skipped + 1))
            continue
        fi

        parent=$(dirname "$original")
        if [[ "$dry_run" == "true" ]]; then
            echo "Would restore: ${candidate/#$HOME/~} -> $original"
            restored=$((restored + 1))
            continue
        fi

        if ! mkdir -p "$parent"; then
            echo "Failed to prepare restore destination: $parent" >&2
            skipped=$((skipped + 1))
            continue
        fi
        if ! restore_destination_is_safe "$original"; then
            echo "Skipped, unsafe restore destination after preparing parent: $original"
            skipped=$((skipped + 1))
            continue
        fi
        if [[ -e "$original" || -L "$original" ]]; then
            echo "Skipped, original already exists: $original"
            skipped=$((skipped + 1))
            continue
        fi
        if mv -n "$candidate" "$original"; then
            echo "Restored: $original"
            log_operation "restore" "RESTORED" "$original" "from Trash"
            restored=$((restored + 1))
        else
            echo "Failed to restore: $original" >&2
            skipped=$((skipped + 1))
        fi
    done < <(restore_trashed_records)

    echo "Restore complete: $restored restored, $skipped skipped"
}

main() {
    case "${1:-list}" in
        list)
            shift || true
            restore_list "$@"
            ;;
        restore)
            shift
            restore_targets "$@"
            ;;
        -h | --help | help)
            show_restore_help
            ;;
        *)
            echo "Unknown restore command: $1" >&2
            show_restore_help >&2
            exit 1
            ;;
    esac
}

main "$@"
