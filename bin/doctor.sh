#!/bin/bash
# Mole - Doctor command.
# Runs the Go health diagnostic UI.
# Uses bundled doctor-go binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="$SCRIPT_DIR/doctor-go"
if [[ -x "$GO_BIN" ]]; then
    exec "$GO_BIN" "$@"
fi

echo "Bundled doctor binary not found. Please reinstall Mole or run mo update to restore it." >&2
exit 1
