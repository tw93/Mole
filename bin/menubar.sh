#!/bin/bash
# Mole - Menubar command.
# Runs the Swift menu bar system monitor.
# Shows live CPU/RAM in macOS menu bar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_BIN="$SCRIPT_DIR/menubar-swift"
GO_BIN="$SCRIPT_DIR/menubar-go"

BIN=""
if [[ -x "$SWIFT_BIN" ]]; then
    BIN="$SWIFT_BIN"
elif [[ -x "$GO_BIN" ]]; then
    BIN="$GO_BIN"
else
    echo "Bundled menubar binary not found. Please reinstall Mole or run mo update to restore it." >&2
    exit 1
fi

# Check if menubar is already running.
if pgrep -f "$BIN" > /dev/null 2>&1; then
    echo "Menubar is already running."
    exit 0
fi

# Launch in background, detached from terminal.
nohup "$BIN" "$@" > /dev/null 2>&1 &
disown
echo "Menubar started in background (PID $!)."
