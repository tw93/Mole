#!/bin/bash
# Mole - Analyze command.
# Runs the Go disk analyzer UI.
# Uses bundled analyze-go binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MOLE_CORE_DIR="$(cd "$SCRIPT_DIR/../lib/core" && pwd)"
# shellcheck disable=SC1091
source "$_MOLE_CORE_DIR/tr.sh" 2> /dev/null || true
GO_BIN="$SCRIPT_DIR/analyze-go"
if [[ -x "$GO_BIN" ]]; then
    exec "$GO_BIN" "$@"
fi

echo "${TR_ANALYZE_BIN_NOT_FOUND:-Bundled analyzer binary not found. Please reinstall Mole or run mo update to restore it.}" >&2
exit 1
