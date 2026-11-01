#!/bin/bash
# Mole CLI (Linux) - analyze: runs the Go TUI built from cmd/analyze.
set -euo pipefail
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
bin="$SCRIPT_DIR/bin/analyze-go"
if [[ ! -x "$bin" ]]; then
    echo "analyze is not built. Run make build in $SCRIPT_DIR." >&2
    exit 1
fi
exec "$bin" "$@"
