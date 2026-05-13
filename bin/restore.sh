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
            if (esc) { out = out c; esc = 0; continue }
            if (c == "\\") { esc = 1; continue }
            if (c == "\"") break
            out = out c
        }
        return out
    }
    {
        if (field($0, "record_type") == "operation" && field($0, "action") == "TRASHED") {
            printf "%s\t%s\n", field($0, "timestamp"), field($0, "path")
        }
    }' "$journal" | awk -F'\t' '!seen[$2]++'
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

restore_find_candidate() {
    local original="$1"
    local trash_dir
    trash_dir=$(restore_trash_dir)
    [[ -d "$trash_dir" ]] || return 1

    local base
    base=$(restore_sanitized_basename "$original")
    local -a matches=()
    local candidate

    candidate="$trash_dir/$base"
    [[ -e "$candidate" || -L "$candidate" ]] && matches+=("$candidate")

    for candidate in "$trash_dir/$base".*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        matches+=("$candidate")
    done

    [[ ${#matches[@]} -eq 1 ]] || return 1
    printf '%s\n' "${matches[0]}"
}

restore_list() {
    local limit=20
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit)
                shift
                [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || { echo "Invalid --limit value" >&2; return 1; }
                limit="$1"
                ;;
            -h | --help)
                show_restore_help
                return 0
                ;;
            *) echo "Unknown restore list option: $1" >&2; return 1 ;;
        esac
        shift
    done

    local shown=0 timestamp original candidate status
    while IFS=$'\t' read -r timestamp original; do
        [[ -n "$original" ]] || continue
        [[ "$shown" -lt "$limit" ]] || break
        if [[ -e "$original" || -L "$original" ]]; then
            status="already restored"
        elif candidate=$(restore_find_candidate "$original"); then
            status="restorable: ${candidate/#$HOME/~}"
        else
            status="not found or ambiguous"
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
                [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] || { echo "Invalid --limit value" >&2; return 1; }
                limit="$1"
                ;;
            -h | --help)
                show_restore_help
                return 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do requested+=("$1"); shift; done
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
    while IFS=$'\t' read -r timestamp original; do
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

        if [[ -e "$original" || -L "$original" ]]; then
            echo "Skipped, original already exists: $original"
            skipped=$((skipped + 1))
            continue
        fi
        if ! candidate=$(restore_find_candidate "$original"); then
            echo "Skipped, Trash item not found or ambiguous: $original"
            skipped=$((skipped + 1))
            continue
        fi

        parent=$(dirname "$original")
        if [[ "$dry_run" == "true" ]]; then
            echo "Would restore: ${candidate/#$HOME/~} -> $original"
            restored=$((restored + 1))
            continue
        fi

        mkdir -p "$parent"
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
