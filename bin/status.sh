#!/bin/bash
# Mole - Status command.
# Runs the Go system status panel.
# Shows live system metrics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/i18n.sh"
GO_BIN="$SCRIPT_DIR/status-go"
if [[ -x "$GO_BIN" ]]; then
    export MOLE_LANG="$(mole_resolve_language)"
    exec "$GO_BIN" "$@"
fi

printf '%s\n' "$(mole_t "Bundled status binary not found. Please reinstall Mole or run mo update to restore it.")" >&2
exit 1
