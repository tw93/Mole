#!/bin/bash
# Mole - Status command.
# Runs the Go system status panel.
# Shows live system metrics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MOLE_CORE_DIR="$(cd "$SCRIPT_DIR/../lib/core" && pwd)"
# shellcheck disable=SC1091
source "$_MOLE_CORE_DIR/tr.sh" 2> /dev/null || true
GO_BIN="$SCRIPT_DIR/status-go"
if [[ -x "$GO_BIN" ]]; then
    exec "$GO_BIN" "$@"
fi

echo "${TR_STATUS_BIN_NOT_FOUND:-Bundled status binary not found. Please reinstall Mole or run mo update to restore it.}" >&2
exit 1
