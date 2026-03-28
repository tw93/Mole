#!/bin/bash
# Mole - Analyze command.
# Runs the Go disk analyzer UI.
# Uses bundled analyze-go binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/i18n.sh"
GO_BIN="$SCRIPT_DIR/analyze-go"
if [[ -x "$GO_BIN" ]]; then
    export MOLE_LANG="$(mole_resolve_language)"
    exec "$GO_BIN" "$@"
fi

printf '%s\n' "$(mole_t "Bundled analyzer binary not found. Please reinstall Mole or run mo update to restore it.")" >&2
exit 1
