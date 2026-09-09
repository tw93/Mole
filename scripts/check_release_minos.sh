#!/usr/bin/env bash
# Verify release binaries keep an intentional minimum macOS version.

set -euo pipefail

MAX_MINOS="${MAX_RELEASE_MINOS:-12.0}"

if [[ "${1:-}" == "--max" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "--max requires a version value" >&2
        exit 1
    fi
    MAX_MINOS="$2"
    shift 2
fi

if [[ -z "$MAX_MINOS" ]]; then
    echo "MAX_RELEASE_MINOS must not be empty" >&2
    exit 1
fi

if ! command -v otool > /dev/null 2>&1; then
    echo "otool is required to inspect Mach-O release binaries" >&2
    exit 1
fi

version_gt() {
    awk -v left="$1" -v right="$2" '
        BEGIN {
            split(left, l, ".")
            split(right, r, ".")
            for (i = 1; i <= 3; i++) {
                lv = (l[i] == "" ? 0 : l[i] + 0)
                rv = (r[i] == "" ? 0 : r[i] + 0)
                if (lv > rv) exit 0
                if (lv < rv) exit 1
            }
            exit 1
        }
    '
}

extract_minos() {
    otool -l "$1" | awk '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" {
            in_build = 1
            next
        }
        in_build && $1 == "minos" {
            print $2
            exit
        }
        in_build && $1 == "cmd" {
            in_build = 0
        }
    '
}

if [[ $# -eq 0 ]]; then
    set -- bin/analyze-darwin-* bin/status-darwin-*
fi

checked=0
failed=0

for binary in "$@"; do
    if [[ ! -f "$binary" ]]; then
        continue
    fi

    minos=$(extract_minos "$binary")
    if [[ -z "$minos" ]]; then
        echo "ERROR: $binary has no LC_BUILD_VERSION minos" >&2
        failed=1
        continue
    fi

    checked=$((checked + 1))
    if version_gt "$minos" "$MAX_MINOS"; then
        echo "ERROR: $binary minos $minos exceeds allowed $MAX_MINOS" >&2
        failed=1
    else
        echo "OK: $binary minos $minos <= $MAX_MINOS"
    fi
done

if [[ $checked -eq 0 ]]; then
    echo "ERROR: no release binaries found to inspect" >&2
    exit 1
fi

exit "$failed"
