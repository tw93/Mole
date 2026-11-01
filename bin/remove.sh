#!/bin/bash
# Mole CLI (Linux) - remove Mole itself: the installed tree, the mo and mole
# links, and Mole's own config, cache and operations log.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
mole_refuse_root

ASSUME_YES=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --yes | -y) ASSUME_YES=true ;;
        --dry-run | -n) DRY_RUN=true ;;
        -h | --help)
            echo "Usage: mo remove [--dry-run] [--yes]"
            echo ""
            echo "Remove Mole from this computer: the program, the mo and mole links,"
            echo "and Mole's own settings, cache and operations log."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

install_root="$MOLE_DATA_HOME/mole"
if [[ "$(readlink -f -- "$SCRIPT_DIR")" != "$(readlink -f -- "$install_root" 2> /dev/null || echo /nonexistent)" ]]; then
    log_error "This Mole runs from $SCRIPT_DIR, not an installed copy; delete that folder yourself if you no longer need it."
    exit 1
fi
[[ -f "$install_root/mole" && -f "$install_root/VERSION" && -f "$install_root/lib/core/common.sh" && ! -e "$install_root/.git" && ! -L "$install_root" ]] || {
    log_error "$install_root does not look like a Mole install; nothing was removed."
    exit 1
}

declare -a targets=()
for name in mo mole; do
    link="$HOME/.local/bin/$name"
    [[ -L "$link" && "$(readlink -- "$link")" == "$install_root/mole" ]] && targets+=("$link")
done
for dir in "$MOLE_CONFIG_HOME/mole" "$MOLE_CACHE_HOME/mole" "$MOLE_STATE_DIR"; do
    [[ -d "$dir" && ! -L "$dir" ]] && targets+=("$dir")
done
targets+=("$install_root")

echo -e "${PURPLE_BOLD}Remove Mole${NC}"
for path in "${targets[@]}"; do
    echo -e "  ${GRAY}${ICON_LIST}${NC} $(mole_display_path "$path")"
done
if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}Dry run${NC}, nothing removed."
    exit 0
fi
if [[ "$ASSUME_YES" != true ]]; then
    if [[ ! -t 0 ]]; then
        echo "Run mo remove in a terminal, or pass --yes." >&2
        exit 1
    fi
    mole_confirm "Remove Mole?" || {
        echo "Cancelled."
        exit 0
    }
fi

# Everything above is Mole's own: exact paths, checked to be links to this
# install or plain folders, inside the user's home.
for path in "${targets[@]}"; do
    rm -rf --one-file-system -- "$path"
done
echo -e "${GREEN}${ICON_SUCCESS}${NC} Mole removed. Thanks for trying it."
