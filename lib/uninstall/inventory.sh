#!/bin/bash
# Mole CLI (Linux) - installed apps and their exact-ID leftovers.
#
# An app is something with a launcher: a pacman package (repo or AUR) that was
# explicitly installed and ships a .desktop file, a Flatpak app, or an Omarchy
# web app launcher. Rows are tab separated:
#   kind  id  name  size_kb  desktop_ids(comma)  exec  scope
# kind is pacman | aur | flatpak | webapp | appimage | orphan; scope is
# user|system for Flatpak. An orphan is a Flatpak sandbox home whose app is no
# longer installed in any installation (flatsweep's test, minus its rmtree).

set -euo pipefail

# Field from the [Desktop Entry] group of one .desktop file.
mole_desktop_field() {
    local file="$1" key="$2"
    awk -v key="$key" '
        /^\[/ { in_entry = ($0 == "[Desktop Entry]"); next }
        in_entry && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
    ' "$file" 2> /dev/null
}

# First word of Exec= without env assignments or a path, for the running check.
mole_desktop_exec() {
    local exec word
    exec=$(mole_desktop_field "$1" Exec)
    for word in $exec; do
        [[ "$word" == *=* && "$word" != /* ]] && continue
        [[ "$word" == env ]] && continue
        printf '%s' "$(basename -- "${word//\"/}")"
        return 0
    done
}

# Exec= program as written (quotes removed), for launchers that point at a file.
mole_desktop_exec_path() {
    local exec word
    exec=$(mole_desktop_field "$1" Exec)
    for word in $exec; do
        [[ "$word" == *=* && "$word" != /* ]] && continue
        [[ "$word" == env ]] && continue
        printf '%s' "${word//\"/}"
        return 0
    done
}

# StartupWMClass is the name the app itself declares for its windows, and for
# most Electron and GTK apps it is also its config folder (Code, obsidian).
# It counts as an exact ID only when one launcher on the system declares it and
# it is not a runtime's generic class.
declare -A _MOLE_WMCLASS_COUNT=()
_MOLE_WMCLASS_LOADED=false
_mole_load_wmclasses() {
    [[ "$_MOLE_WMCLASS_LOADED" == true ]] && return 0
    _MOLE_WMCLASS_LOADED=true
    local -a files=()
    local f cls lc
    for f in /usr/share/applications/*.desktop "$MOLE_DATA_HOME/applications"/*.desktop \
        /var/lib/flatpak/exports/share/applications/*.desktop "$MOLE_DATA_HOME/flatpak/exports/share/applications"/*.desktop; do
        [[ -f "$f" ]] && files+=("$f")
    done
    [[ ${#files[@]} -gt 0 ]] || return 0
    while IFS= read -r cls; do
        [[ -n "$cls" ]] || continue
        mole_ascii_lowercase lc "$cls"
        _MOLE_WMCLASS_COUNT[$lc]=$((${_MOLE_WMCLASS_COUNT[$lc]:-0} + 1))
    done < <(awk '
        FNR == 1 { in_entry = 0 }
        /^\[/ { in_entry = ($0 == "[Desktop Entry]"); next }
        in_entry && index($0, "StartupWMClass=") == 1 { print substr($0, 16) }
    ' "${files[@]}" 2> /dev/null)
}

mole_desktop_wmclass_id() {
    local cls lc
    cls=$(mole_desktop_field "$1" StartupWMClass)
    [[ "$cls" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 0
    mole_ascii_lowercase lc "$cls"
    case "$lc" in
        electron* | java* | sun-awt-* | wine* | python* | steam_app_* | chromium | chromium-browser | qemu*) return 0 ;;
    esac
    _mole_load_wmclasses
    [[ "${_MOLE_WMCLASS_COUNT[$lc]:-0}" -eq 1 ]] && printf '%s' "$cls"
    return 0
}

# Pacman package names as pacman accepts them; anything else never reaches argv.
mole_valid_package_name() {
    [[ "$1" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$ ]]
}

mole_desktop_hidden() {
    local file="$1"
    [[ "$(mole_desktop_field "$file" NoDisplay)" == "true" || "$(mole_desktop_field "$file" Hidden)" == "true" ]]
}

# Packages the desktop session or the system itself runs on. They ship
# launchers (uwsm's uuctl, fcitx5's configuration tool) but removing them
# breaks login, input, sound or networking, so uninstall never lists them.
mole_package_protected() {
    case "$1" in
        base | base-devel | linux | linux-* | systemd | systemd-* | pacman | pacman-* | sudo | bash | zsh | \
            omarchy | omarchy-* | uwsm | hyprland | hyprland-* | hypr* | xdg-desktop-portal* | waybar | walker | \
            walker-* | elephant | elephant-* | mako | swayosd | swaybg | swaync | fcitx5 | fcitx5-* | \
            pipewire | pipewire-* | wireplumber | networkmanager | network-manager-* | iwd | impala | \
            bluez | bluez-* | blueberry | bluetui | polkit | polkit-* | gnome-keyring | sddm | gdm | plymouth | \
            mesa | mesa-* | vulkan-* | nvidia | nvidia-* | yay | yay-* | paru | paru-* | flatpak | \
            gnome-shell | gnome-session | plasma-* | kwin | kde-cli-tools | xorg-* | wayland) return 0 ;;
    esac
    return 1
}

_inventory_pacman() {
    command -v pacman > /dev/null 2>&1 || return 0
    local -a desktops=()
    local f
    for f in /usr/share/applications/*.desktop; do
        [[ -f "$f" ]] || continue
        mole_desktop_hidden "$f" && continue
        desktops+=("$f")
    done
    [[ ${#desktops[@]} -gt 0 ]] || return 0

    local explicit foreign
    explicit=$(mole_c pacman -Qqe 2> /dev/null) || explicit=""
    foreign=$(mole_c pacman -Qqm 2> /dev/null) || foreign=""

    # "<path> is owned by <pkg> <version>"
    declare -A pkg_desktops=() pkg_name=() pkg_exec=()
    local line path pkg id cls owned_re='^(/.+) is owned by ([^ ]+) [^ ]+$'
    while IFS= read -r line; do
        [[ "$line" =~ $owned_re ]] || continue
        path="${BASH_REMATCH[1]}"
        pkg="${BASH_REMATCH[2]}"
        mole_valid_package_name "$pkg" || continue
        grep -qxF -- "$pkg" <<< "$explicit" || continue
        mole_package_protected "$pkg" && continue
        id="$(basename -- "$path" .desktop)"
        pkg_desktops[$pkg]="${pkg_desktops[$pkg]:+${pkg_desktops[$pkg]},}$id"
        cls=$(mole_desktop_wmclass_id "$path")
        [[ -n "$cls" ]] && pkg_desktops[$pkg]+=",$cls"
        if [[ -z "${pkg_name[$pkg]:-}" || "$id" == "$pkg" ]]; then
            pkg_name[$pkg]="$(mole_desktop_field "$path" Name)"
            pkg_exec[$pkg]="$(mole_desktop_exec "$path")"
        fi
    done < <(mole_c pacman -Qo "${desktops[@]}" 2> /dev/null)
    [[ ${#pkg_desktops[@]} -gt 0 ]] || return 0

    # Installed Size, in pacman's own units.
    declare -A pkg_kb=()
    local name="" key value
    while IFS= read -r line; do
        key="${line%%:*}"
        key="${key%"${key##*[! ]}"}"
        value="${line#*: }"
        case "$key" in
            Name) name="$value" ;;
            "Installed Size") pkg_kb[$name]=$(awk -v v="$value" 'BEGIN {
                n = v + 0; u = v; sub(/^[0-9.]+ */, "", u); u = substr(u, 1, 1)
                m = 1 / 1024; if (u == "K") m = 1; else if (u == "M") m = 1024; else if (u == "G") m = 1048576
                printf "%d", n * m }') ;;
        esac
    done < <(mole_c pacman -Qi "${!pkg_desktops[@]}" 2> /dev/null)

    local kind
    for pkg in "${!pkg_desktops[@]}"; do
        kind=pacman
        grep -qxF -- "$pkg" <<< "$foreign" && kind=aur
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$pkg" "${pkg_name[$pkg]:-$pkg}" "${pkg_kb[$pkg]:-0}" \
            "${pkg_desktops[$pkg]}" "${pkg_exec[$pkg]:-}" system
    done
}

_inventory_flatpak() {
    command -v flatpak > /dev/null 2>&1 || return 0
    local id name scope dir kb
    while IFS=$'\t' read -r id name scope; do
        [[ -n "$id" ]] || continue
        if [[ "$scope" == user ]]; then
            dir="$MOLE_DATA_HOME/flatpak/app/$id"
        else
            dir="/var/lib/flatpak/app/$id"
        fi
        kb=$(mole_path_kb "$dir")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' flatpak "$id" "${name:-$id}" "$kb" "$id" "$id" "$scope"
    done < <(mole_c flatpak list --app --columns=application,name,installation 2> /dev/null)
}

# Omarchy web apps: a launcher whose Exec runs omarchy-launch-webapp or a
# webapp handler. Removing one removes its launcher and icon, as Omarchy's
# own omarchy-webapp-remove does.
_inventory_webapps() {
    local dir="$MOLE_DATA_HOME/applications" f exec id
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.desktop; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        exec=$(mole_desktop_field "$f" Exec)
        [[ "$exec" == *omarchy-launch-webapp* || "$exec" == *omarchy-webapp-handler* ]] || continue
        id="$(basename -- "$f" .desktop)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' webapp "$id" "$(mole_desktop_field "$f" Name)" 4 "$id" "" user
    done
}

# AppImages started from a launcher in ~/.local/share/applications (by hand or
# by AppImageLauncher / Gear Lever): the launcher's Exec names the file.
_inventory_appimages() {
    local dir="$MOLE_DATA_HOME/applications" f target id ids cls kb
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.desktop; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        target=$(mole_desktop_exec_path "$f")
        [[ "$target" == "$HOME/"* ]] || continue
        mole_ascii_lowercase ids "$target"
        [[ "$ids" == *.appimage ]] || continue
        [[ -f "$target" && ! -L "$target" && -O "$target" ]] || continue
        id="$(basename -- "$f" .desktop)"
        ids="$id"
        cls=$(mole_desktop_wmclass_id "$f")
        [[ -n "$cls" ]] && ids+=",$cls"
        kb=$(($(mole_c stat -c %s -- "$target" 2> /dev/null || echo 0) / 1024))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' appimage "$id" "$(mole_desktop_field "$f" Name)" "$kb" "$ids" "$target" user
    done
}

# Files an AppImage launcher owns: the launcher, the AppImage and its icon.
mole_appimage_files() {
    local id="$1" target="$2" desktop="$MOLE_DATA_HOME/applications/$1.desktop" icon f
    printf '%s\n' "$desktop" "$target"
    icon=$(mole_desktop_field "$desktop" Icon)
    if [[ "$icon" == "$HOME/"* ]]; then
        [[ -f "$icon" ]] && printf '%s\n' "$icon"
    elif [[ "$icon" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        for f in "$MOLE_DATA_HOME/icons/hicolor"/*/apps/"$icon".{png,svg}; do
            [[ -f "$f" ]] && printf '%s\n' "$f"
        done
    fi
    return 0
}

# ~/.var/app/<id> left behind by a Flatpak app that is no longer installed in
# any installation. Only when flatpak itself answered the inventory question.
_inventory_flatpak_orphans() {
    local base="$HOME/.var/app" installed dir id kb
    [[ -d "$base" && ! -L "$base" ]] || return 0
    command -v flatpak > /dev/null 2>&1 || return 0
    installed=$(mole_c flatpak list --app --columns=application 2> /dev/null) || return 0
    for dir in "$base"/*; do
        [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || continue
        id="${dir##*/}"
        [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
        grep -qxF -- "$id" <<< "$installed" && continue
        [[ -d "$dir/cache" || -d "$dir/config" || -d "$dir/data" ]] || continue
        kb=$(mole_path_kb "$dir")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' orphan "$id" "$id" "$kb" "" "" user
    done
}

mole_list_apps() {
    {
        _inventory_pacman
        _inventory_flatpak
        _inventory_webapps
        _inventory_appimages
        _inventory_flatpak_orphans
    } | LC_ALL=C sort -t $'\t' -f -k3,3
}

# Files that belong to a web app itself (always removed with it).
mole_webapp_files() {
    local id="$1" icon_dir="$MOLE_DATA_HOME/icons/hicolor/256x256/apps" icon_name
    printf '%s\n' "$MOLE_DATA_HOME/applications/$id.desktop"
    icon_name=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]\{1,\}/-/g; s/^-//; s/-$//')
    [[ -f "$icon_dir/$icon_name.png" ]] && printf '%s\n' "$icon_dir/$icon_name.png"
    [[ "$icon_name" != "$id" && -f "$icon_dir/$id.png" ]] && printf '%s\n' "$icon_dir/$id.png"
    return 0
}

# Leftovers by exact identifier, one per line: class<TAB>path
#   cache  rebuilt by the app, checked by default
#   data   settings and user data, unchecked by default
mole_app_leftovers() {
    local kind="$1" id="$2" desktop_ids="$3"
    local -a ids=("$id")
    local d
    IFS=',' read -ra extra <<< "$desktop_ids"
    for d in "${extra[@]}"; do
        [[ -n "$d" && "$d" != "$id" ]] && ids+=("$d")
    done

    local -A seen=()
    emit() {
        local class="$1" path="$2"
        [[ -n "${seen[$path]:-}" ]] && return 0
        [[ -e "$path" || -L "$path" ]] || return 0
        mole_is_protected_path "$path" && return 0
        seen[$path]=1
        printf '%s\t%s\n' "$class" "$path"
    }

    [[ "$kind" == orphan ]] && return 0
    if [[ "$kind" == flatpak ]]; then
        emit data "$HOME/.var/app/$id"
        return 0
    fi
    for d in "${ids[@]}"; do
        [[ "$d" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
        emit cache "$MOLE_CACHE_HOME/$d"
        emit cache "$MOLE_CONFIG_HOME/autostart/$d.desktop"
        emit data "$MOLE_CONFIG_HOME/$d"
        emit data "$MOLE_DATA_HOME/$d"
        emit data "$MOLE_STATE_HOME/$d"
        emit data "$MOLE_CONFIG_HOME/systemd/user/$d.service"
        [[ "$kind" == webapp || "$kind" == appimage ]] || emit cache "$MOLE_DATA_HOME/applications/$d.desktop"
    done
}
