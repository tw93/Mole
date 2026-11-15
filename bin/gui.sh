#!/bin/bash
# Mole CLI (Linux) - gui: open the GTK window. It runs this same CLI for every
# report and change, so it needs nothing beyond GTK 4, libadwaita and PyGObject.
set -euo pipefail
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
mole_refuse_root

case "${1:-}" in
    -h | --help)
        echo "Usage: mo gui"
        echo ""
        echo "Open the Mole window: every tool of the CLI in a GTK interface."
        exit 0
        ;;
esac

# The distribution's Python carries PyGObject; a Homebrew or pyenv python3
# first on PATH usually does not.
python=""
for candidate in /usr/bin/python3 python3; do
    if command -v "$candidate" > /dev/null 2>&1 &&
        "$candidate" -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")' > /dev/null 2>&1; then
        python="$candidate"
        break
    fi
done
if [[ -z "$python" ]]; then
    log_error "The window needs GTK 4, libadwaita and PyGObject."
    echo "Install them with: sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1" >&2
    echo "On Arch: sudo pacman -S python-gobject gtk4 libadwaita; on Fedora: sudo dnf install python3-gobject gtk4 libadwaita" >&2
    exit 1
fi
if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    log_error "No graphical session; use the commands in mo --help instead."
    exit 1
fi
cd "$SCRIPT_DIR/gui"
exec "$python" -m mole_gui
