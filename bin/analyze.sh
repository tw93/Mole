#!/bin/bash
# Entry point for the Go-based disk analyzer binary bundled with Mole.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="$SCRIPT_DIR/analyze-go"
if [[ -x "$GO_BIN" ]]; then
    exec "$GO_BIN" "$@"
fi

echo "$(t "analyzer_not_found")" >&2
exit 1
