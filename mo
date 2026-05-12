#!/bin/bash
# Compatibility alias named `mo` for the Roomy CLI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/roomy" "$@"
