#!/bin/bash
# Mole CLI (Linux) - update: install the newest release over this one.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
mole_refuse_root

force=false
nightly=false
for arg in "$@"; do
    case "$arg" in
        --force | -f) force=true ;;
        --nightly) nightly=true ;;
        -h | --help)
            echo "Usage: mo update [--force] [--nightly]"
            echo ""
            echo "Install the newest Mole CLI (Linux) release, verified by its checksum."
            echo ""
            echo "Options:"
            echo "  -f, --force       Reinstall the latest version even when up to date"
            echo "  --nightly         Install the latest unreleased linux branch build"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown update option: $arg" >&2
            echo "Use 'mo update --help' for supported options." >&2
            exit 1
            ;;
    esac
done

current="$(tr -d '[:space:]' 2> /dev/null < "$SCRIPT_DIR/VERSION" || true)"
current="${current:-unknown}"
if [[ -d "$SCRIPT_DIR/.git" ]]; then
    log_error "This Mole runs from a source checkout; update it with git pull."
    exit 1
fi

if ! mole_runs_installed_tree; then
    log_error "This Mole runs from $SCRIPT_DIR, not an installed copy, so mo update would install a second one. Update it yourself, or install with install.sh."
    exit 1
fi

# The installer replaces this very tree; it always runs from a copy outside.
run_installer() {
    local copy rc=0
    copy="$(mktemp "${TMPDIR:-/tmp}/mole-install.XXXXXX")"
    cp -- "$SCRIPT_DIR/install.sh" "$copy"
    bash "$copy" "$@" || rc=$?
    rm -f -- "$copy"
    return "$rc"
}

if [[ "$nightly" == true ]]; then
    start_inline_spinner "Checking for nightly updates..."
    commit=$(bash "$SCRIPT_DIR/install.sh" --latest-commit 2> /dev/null) || commit=""
    stop_inline_spinner
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
        log_error "Could not read the newest nightly commit from GitHub. Try again later."
        exit 1
    fi
    installed_commit="$(tr -d '[:space:]' 2> /dev/null < "$SCRIPT_DIR/NIGHTLY" || true)"
    if [[ "$force" != true && "$installed_commit" == "$commit" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Already on the latest nightly, ${commit:0:7}"
        exit 0
    fi
    echo -e "Updating Mole ${current} to nightly ${GREEN}${commit:0:7}${NC}"
    rc=0
    run_installer --nightly --commit "$commit" || rc=$?
    exit "$rc"
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

# The numeric X.Y.Z core decides: a prerelease of the same core or a broken
# VERSION is replaced, an installed core above the latest is never
# downgraded, --force included.
verdict=$(mole_update_verdict "$latest" "$current")
# A nightly may carry the core of a release still in draft; going back to the
# published release is what plain mo update on a nightly means.
[[ "$verdict" == newer && -f "$SCRIPT_DIR/NIGHTLY" ]] && verdict=install
if [[ "$verdict" == newer ]]; then
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Mole $current is newer than the latest release $latest, nothing to install"
    exit 0
fi
if [[ "$force" != true && "$verdict" == current ]]; then
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Mole $current is the latest version"
    exit 0
fi

if [[ "$current" == "$latest" ]]; then
    echo -e "Reinstalling Mole ${GREEN}${latest}${NC}"
elif [[ -f "$SCRIPT_DIR/NIGHTLY" ]]; then
    echo -e "Switching Mole ${current} to the stable release ${GREEN}${latest}${NC}"
else
    echo -e "Updating Mole ${current} to ${GREEN}${latest}${NC}"
fi
rc=0
run_installer --version "$latest" || rc=$?
exit "$rc"
