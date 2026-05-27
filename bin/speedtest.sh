#!/bin/bash
# Mole - Speedtest command.
# Runs the Go network speed test.
# Measures latency, download, and upload via Cloudflare edge.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="$SCRIPT_DIR/speedtest-go"
if [[ -x "$GO_BIN" ]]; then
    exec "$GO_BIN" "$@"
fi

echo "Bundled speedtest binary not found. Please reinstall Mole or run mo update to restore it." >&2
exit 1
