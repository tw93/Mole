#!/bin/bash
# Mole - History command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/core/history.sh"

HISTORY_JSON=false
HISTORY_LIMIT="$MOLE_HISTORY_DEFAULT_LIMIT"

show_history_help() {
    echo "Usage: mo history [OPTIONS]"
    echo ""
    echo "Review recent Mole operation and deletion activity."
    echo ""
    echo "Options:"
    echo "  --json           Output history as JSON"
    echo "  --limit N        Show the most recent N entries, 1-200"
    echo "  -h, --help       Show this help message"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--json")
                HISTORY_JSON=true
                ;;
            "--limit")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Missing value for --limit" >&2
                    exit 1
                fi
                if ! HISTORY_LIMIT=$(history_parse_limit "$1"); then
                    echo "Invalid value for --limit: $1" >&2
                    exit 1
                fi
                ;;
            "--help" | "-h")
                show_history_help
                exit 0
                ;;
            -*)
                echo "Unknown option for mo history: $1" >&2
                echo "Run 'mo history --help' for usage." >&2
                exit 1
                ;;
            *)
                echo "Unexpected argument for mo history: $1" >&2
                echo "Run 'mo history --help' for usage." >&2
                exit 1
                ;;
        esac
        shift
    done

    history_load_operations "$(history_operations_log_file)"
    history_load_deletions "$(history_deletions_log_file)"

    if [[ "$HISTORY_JSON" == "true" ]]; then
        history_render_json "$HISTORY_LIMIT"
    else
        history_render_text "$HISTORY_LIMIT"
    fi
}

main "$@"
