#!/bin/bash
# Roomy - Status command.
# Runs the Go system status panel.
# Shows live system metrics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="$SCRIPT_DIR/status-go"
if [[ -x "$GO_BIN" ]]; then
    exec "$GO_BIN" "$@"
fi

echo "Bundled status binary not found. Please reinstall Roomy or run roomy update to restore it." >&2
exit 1
