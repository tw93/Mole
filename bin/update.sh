#!/bin/bash
# Mole CLI (Linux) - update: install the newest release over this one.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
mole_refuse_root

case "${1:-}" in
    -h | --help)
        echo "Usage: mo update"
        echo ""
        echo "Install the newest Mole CLI (Linux) release, verified by its checksum."
        exit 0
        ;;
    "") ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
esac

current="$(cat "$SCRIPT_DIR/VERSION" 2> /dev/null || echo unknown)"
if [[ -d "$SCRIPT_DIR/.git" ]]; then
    log_error "This Mole runs from a source checkout; update it with git pull."
    exit 1
fi

start_inline_spinner "Checking for updates..."
rc=0
latest=$(bash "$SCRIPT_DIR/install.sh" --latest 2> /dev/null) || rc=$?
stop_inline_spinner
if [[ $rc -eq 3 ]]; then
    echo -e "${GRAY}No Mole CLI (Linux) release found on GitHub; Mole $current stays.${NC}"
    exit 0
fi
if [[ $rc -ne 0 || ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Could not reach GitHub to check for updates. Try again later."
    exit 1
fi

newest=$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)
if [[ "$current" == "$latest" || "$newest" == "$current" ]]; then
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Mole $current is the latest version"
    exit 0
fi

echo -e "Updating Mole ${current} to ${GREEN}${latest}${NC}"
# The installer replaces this very tree; run a copy of it from outside.
copy="$(mktemp "${TMPDIR:-/tmp}/mole-install.XXXXXX")"
cp -- "$SCRIPT_DIR/install.sh" "$copy"
rc=0
bash "$copy" --version "$latest" || rc=$?
rm -f -- "$copy"
exit "$rc"
