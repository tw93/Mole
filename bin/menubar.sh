#!/bin/bash
# Mole - Menubar command.
# Runs the Go menu bar system monitor.
# Shows live CPU/RAM in macOS menu bar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="$SCRIPT_DIR/menubar-go"
if [[ -x "$GO_BIN" ]]; then
    exec "$GO_BIN" "$@"
fi

echo "Bundled menubar binary not found. Please reinstall Mole or run mo update to restore it." >&2
exit 1
