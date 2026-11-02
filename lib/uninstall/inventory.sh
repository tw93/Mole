#!/bin/bash
# Mole CLI (Linux) - installed apps and their exact-ID leftovers.
#
# An app is something with a launcher: a pacman package (repo or AUR) that was
# explicitly installed and ships a .desktop file, a Flatpak app, or an Omarchy
# web app launcher. Rows are tab separated:
#   kind  id  name  size_kb  desktop_ids(comma)  exec  scope
# kind is pacman | aur | flatpak | webapp | tui | appimage | orphan; scope is
# the Flatpak installation (user, system, or a custom installation's name). An orphan is a Flatpak sandbox home whose app is no
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

# Words of an Exec= value, one per line, with the Desktop Entry quoting
# removed: double quotes group a word, and inside them a backslash escapes the
# next character. Nothing is glob-expanded or evaluated.
mole_desktop_exec_words() {
    local s="$1" word="" c i quoted=false have=false
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        if [[ "$quoted" == true ]]; then
            if [[ "$c" == $'\\' ]] && ((i + 1 < ${#s})); then
                i=$((i + 1))
                word+="${s:i:1}"
            elif [[ "$c" == '"' ]]; then
                quoted=false
            else
                word+="$c"
            fi
        elif [[ "$c" == '"' ]]; then
            quoted=true
            have=true
        elif [[ "$c" == ' ' || "$c" == $'\t' ]]; then
            [[ "$have" == true ]] && printf '%s\n' "$word"
            word=""
            have=false
        else
            word+="$c"
            have=true
        fi
    done
    [[ "$have" == true ]] && printf '%s\n' "$word"
    return 0
}

# Exec= program as written: the first word that is not an env assignment, not
# `env` itself and not one of env's options (-u NAME and -C DIR take a value).
mole_desktop_exec_path() {
    local -a words=()
    local w i=0 in_env=false
    mapfile -t words < <(mole_desktop_exec_words "$(mole_desktop_field "$1" Exec)")
    while ((i < ${#words[@]})); do
        w="${words[i]}"
        if [[ "$w" == env && "$in_env" == false ]]; then
            in_env=true
        elif [[ "$in_env" == true && ("$w" == -u || "$w" == --unset || "$w" == -C || "$w" == --chdir) ]]; then
            i=$((i + 1))
        elif [[ "$in_env" == true && "$w" == -* ]]; then
            :
        elif [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            :
        else
            printf '%s' "$w"
            return 0
        fi
        i=$((i + 1))
    done
    return 0
}

# Program name of Exec=, for the running check.
mole_desktop_exec() {
    local prog
    prog=$(mole_desktop_exec_path "$1")
    [[ -n "$prog" ]] && printf '%s' "$(basename -- "$prog")"
    return 0
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
    [[ -n "${_MOLE_LOGIN_SHELL_PKG:-}" && "$1" == "$_MOLE_LOGIN_SHELL_PKG" ]] && return 0
    case "$1" in
        base | base-devel | linux | linux-* | systemd | systemd-* | pacman | pacman-* | sudo | bash | zsh | \
            fish | nushell | dash | tcsh | ksh | mksh | xonsh | elvish | \
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
    # The package that provides the user's login shell, whatever it is.
    local login_shell
    login_shell=$(getent passwd "$(id -un)" 2> /dev/null | cut -d: -f7) || login_shell=""
    [[ "$login_shell" == /* ]] && _MOLE_LOGIN_SHELL_PKG=$(mole_c pacman -Qoq -- "$login_shell" 2> /dev/null | head -1)
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

# A Flatpak installation name as `flatpak list` prints it: user, system, or
# the name of a custom installation (/etc/flatpak/installations.d).
mole_valid_flatpak_installation() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# The flatpak option that addresses one installation. A custom installation is
# neither --user nor --system; picking either would act on the wrong one.
mole_flatpak_installation_flag() {
    case "$1" in
        user) printf '%s' --user ;;
        system) printf '%s' --system ;;
        *)
            mole_valid_flatpak_installation "$1" || return 1
            printf '%s' "--installation=$1"
            ;;
    esac
}

_inventory_flatpak() {
    command -v flatpak > /dev/null 2>&1 || return 0
    local id name scope dir kb flag
    while IFS=$'\t' read -r id name scope; do
        [[ -n "$id" ]] || continue
        mole_valid_flatpak_installation "$scope" || continue
        case "$scope" in
            user) dir="$MOLE_DATA_HOME/flatpak/app/$id" ;;
            system) dir="/var/lib/flatpak/app/$id" ;;
            *)
                flag=$(mole_flatpak_installation_flag "$scope") || continue
                dir=$(mole_c flatpak "$flag" info --show-location -- "$id" 2> /dev/null) || dir=""
                ;;
        esac
        kb=0
        [[ "$dir" == /* ]] && kb=$(mole_path_kb "$dir")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' flatpak "$id" "${name:-$id}" "$kb" "$id" "$id" "$scope"
    done < <(mole_c flatpak list --app --columns=application,name,installation 2> /dev/null)
}

# Omarchy web apps: a launcher whose Exec runs omarchy-launch-webapp or a
# webapp handler. Removing one removes its launcher and icon, as Omarchy's
# own omarchy-webapp-remove does.
mole_desktop_is_webapp() {
    local exec
    exec=$(mole_desktop_field "$1" Exec)
    [[ "$exec" == *omarchy-launch-webapp* || "$exec" == *omarchy-webapp-handler* ]]
}

# Omarchy terminal app launchers (omarchy-tui-install): a terminal started
# with -e, the test omarchy-tui-remove itself uses.
mole_desktop_is_tui() {
    local exec
    exec=$(mole_desktop_field "$1" Exec)
    [[ "$exec" =~ (\$TERMINAL|xdg-terminal-exec).*\ -e\  ]]
}

_inventory_webapps() {
    local dir="$MOLE_DATA_HOME/applications" f id kind
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.desktop; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        if mole_desktop_is_webapp "$f"; then
            kind=webapp
        elif mole_desktop_is_tui "$f"; then
            kind=tui
        else
            continue
        fi
        id="$(basename -- "$f" .desktop)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$id" "$(mole_desktop_field "$f" Name)" 4 "$id" "" user
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
    # Only an icon file in the user's icon folders belongs to the app; a path
    # anywhere else may be a photo or another launcher's icon.
    if [[ "$icon" == "$MOLE_DATA_HOME/icons/"* && "$icon" != *"/../"* ]]; then
        [[ -f "$icon" && ! -L "$icon" ]] && printf '%s\n' "$icon"
    elif [[ "$icon" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        for f in "$MOLE_DATA_HOME/icons/hicolor"/*/apps/"$icon".{png,svg,jpg,jpeg,webp,gif,ico,xpm}; do
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

# How many launchers on the system name this Icon=, so an icon file is taken
# with a launcher only when no other launcher shows it.
declare -A _MOLE_ICON_COUNT=()
_MOLE_ICON_LOADED=false
_mole_load_icons() {
    [[ "$_MOLE_ICON_LOADED" == true ]] && return 0
    _MOLE_ICON_LOADED=true
    local -a files=()
    local f icon
    for f in /usr/share/applications/*.desktop "$MOLE_DATA_HOME/applications"/*.desktop \
        /var/lib/flatpak/exports/share/applications/*.desktop "$MOLE_DATA_HOME/flatpak/exports/share/applications"/*.desktop; do
        [[ -f "$f" ]] && files+=("$f")
    done
    [[ ${#files[@]} -gt 0 ]] || return 0
    while IFS= read -r icon; do
        [[ -n "$icon" ]] || continue
        _MOLE_ICON_COUNT[$icon]=$((${_MOLE_ICON_COUNT[$icon]:-0} + 1))
    done < <(awk '
        FNR == 1 { in_entry = 0 }
        /^\[/ { in_entry = ($0 == "[Desktop Entry]"); next }
        in_entry && index($0, "Icon=") == 1 { print substr($0, 6) }
    ' "${files[@]}" 2> /dev/null)
}

# Image extensions an icon copied by omarchy-webapp-install or
# omarchy-tui-install may keep: they copy a local file with its own extension.
readonly MOLE_ICON_EXTS="png svg jpg jpeg webp gif ico xpm"

# Files that belong to an Omarchy web app or terminal app launcher (always
# removed with it): the launcher and its icon under the names Omarchy writes
# (the lowercased name, the name itself, or what Icon= says when no other
# launcher uses that icon), in any image format, plus the old icon folder.
mole_webapp_files() {
    local id="$1" desktop="$MOLE_DATA_HOME/applications/$1.desktop"
    local icon_dir="$MOLE_DATA_HOME/icons/hicolor/256x256/apps" old_dir="$MOLE_DATA_HOME/applications/icons"
    local safe icon name ext f
    printf '%s\n' "$desktop"
    safe=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]\{1,\}/-/g; s/^-//; s/-$//')
    local -a names=("$safe")
    [[ "$id" != "$safe" ]] && names+=("$id")
    icon=$(mole_desktop_field "$desktop" Icon)
    if [[ -n "$icon" && "$icon" != */* && "$icon" != "$safe" && "$icon" != "$id" ]]; then
        _mole_load_icons
        [[ "${_MOLE_ICON_COUNT[$icon]:-0}" -eq 1 ]] && names+=("$icon")
    fi
    local -A seen=()
    for name in "${names[@]}"; do
        for ext in $MOLE_ICON_EXTS; do
            for f in "$icon_dir/$name.$ext" "$old_dir/$name.$ext"; do
                [[ -f "$f" && ! -L "$f" && -z "${seen[$f]:-}" ]] || continue
                seen[$f]=1
                printf '%s\n' "$f"
            done
        done
    done
    return 0
}

# Folders in $HOME a known app keeps under a name that is not its ID. Only
# what the app itself documents: the Code - OSS build Arch ships as `code`
# keeps ~/.vscode-oss, Microsoft's build ~/.vscode.
mole_app_alias_paths() {
    case "$1" in
        code) printf '%s\n' "$HOME/.vscode-oss" "$MOLE_CONFIG_HOME/Code - OSS" ;;
        visual-studio-code-bin | visual-studio-code-insiders-bin) printf '%s\n' "$HOME/.vscode" ;;
        vscodium | vscodium-bin) printf '%s\n' "$HOME/.vscode-oss" "$MOLE_CONFIG_HOME/VSCodium" ;;
        cursor-bin | cursor) printf '%s\n' "$HOME/.cursor" "$MOLE_CONFIG_HOME/Cursor" ;;
        firefox | firefox-esr | firefox-developer-edition | firefox-bin | firefox-esr-bin | firefox-beta-bin | \
            firefox-nightly | firefox-nightly-bin) printf '%s\n' "$HOME/.mozilla" "$MOLE_CONFIG_HOME/mozilla" ;;
        # GNU IceCat and SeaMonkey keep their profiles inside ~/.mozilla too,
        # so each one claims it while installed.
        icecat | icecat-bin | seamonkey | seamonkey-bin) printf '%s\n' "$HOME/.mozilla" ;;
        thunderbird) printf '%s\n' "$HOME/.thunderbird" ;;
        zen-browser-bin | zen-browser) printf '%s\n' "$HOME/.zen" ;;
    esac
    local class path
    while IFS=$'\t' read -r class path; do
        [[ -n "$path" ]] && printf '%s\n' "$path"
    done < <(mole_app_xdg_ninja_paths "$1")
    return 0
}

# Home paths from xdg-ninja's catalog (MIT, see THIRD-PARTY-NOTICES.md),
# proposed by scripts/xdg-ninja-aliases.py and kept only after review: the
# package ships a launcher (uninstall lists nothing else), the path is that
# program's alone, and it is no credential store. One row per line:
# class<TAB>path, class as in mole_app_leftovers (cache: logs, pid and lock
# files the app rewrites; everything else data).
mole_app_xdg_ninja_paths() {
    local h="$HOME"
    case "$1" in
        # xdg-ninja, official repositories.
        alacritty) printf 'data\t%s\n' "$h/.alacritty.yml" ;;
        amule) printf 'data\t%s\n' "$h/.aMule" ;;
        antimicrox) printf 'data\t%s\n' "$h/.antimicro" ;;
        arandr) printf 'data\t%s\n' "$h/.screenlayout" ;;
        audacity) printf 'data\t%s\n' "$h/.audacity-data" ;;
        boinc) printf 'data\t%s\n' "$h/.BOINC" "$h/.BOINC Manager" ;;
        bpython) printf 'data\t%s\n' "$h/.pythonhist" ;;
        conky) printf 'data\t%s\n' "$h/.conkyrc" ;;
        dropbox) printf 'cache\t%s\n' "$h/.dropbox-dist" ;;
        emacs | emacs-wayland | emacs-nox | emacs-git) printf 'data\t%s\n' "$h/.emacs.d" ;;
        feh) printf 'data\t%s\n' "$h/.fehbg" ;;
        fontforge) printf 'data\t%s\n' "$h/.FontForge" "$h/.PfaEdit" ;;
        gvim | vim) printf 'data\t%s\n' "$h/.vimrc" ;;
        htop) printf 'data\t%s\n' "$h/.htoprc" ;;
        jgmenu) printf 'cache\t%s\n' "$h/.jgmenu-lockfile" ;;
        lmms) printf 'data\t%s\n' "$h/.lmmsrc.xml" ;;
        milkytracker) printf 'data\t%s\n' "$h/.milkytracker_config" ;;
        neovim) printf 'data\t%s\n' "$h/.nvim" "$h/.nviminfo" && printf 'cache\t%s\n' "$h/.nvimlog" ;;
        nvidia-settings) printf 'data\t%s\n' "$h/.nvidia-settings-rc" ;;
        octave) printf 'data\t%s\n' "$h/.octaverc" "$h/.octave_hist" "$h/.octave_packages" ;;
        r) printf 'data\t%s\n' "$h/.Rprofile" "$h/.Rhistory" ;;
        racket) printf 'data\t%s\n' "$h/.racketrc" ;;
        rofi) printf 'cache\t%s\n' "$h/.rofi.pid" ;;
        scite) printf 'data\t%s\n' "$h/.SciTE.session" "$h/.SciTEUser.properties" ;;
        scummvm) printf 'data\t%s\n' "$h/.scummvmrc" ;;
        teamspeak3) printf 'data\t%s\n' "$h/.ts3client" ;;
        virtualbox) printf 'data\t%s\n' "$h/.VirtualBox" ;;
        visidata) printf 'data\t%s\n' "$h/.visidatarc" ;;
        xpdf) printf 'data\t%s\n' "$h/.xpdfrc" ;;
        # xdg-ninja, AUR.
        anydesk-bin) printf 'data\t%s\n' "$h/.anydesk" ;;
        asunder) printf 'cache\t%s\n' "$h/.asunder_album_artist" "$h/.asunder_album_genre" "$h/.asunder_album_title" ;;
        burpsuite) printf 'data\t%s\n' "$h/.BurpSuite" ;;
        bytecode-viewer) printf 'data\t%s\n' "$h/.Bytecode-Viewer" ;;
        citra) printf 'data\t%s\n' "$h/.citra-emu" ;;
        cryptomator) printf 'data\t%s\n' "$h/.Cryptomator" ;;
        dia-git) printf 'data\t%s\n' "$h/.dia" ;;
        emulationstation-de) printf 'data\t%s\n' "$h/.emulationstation" "$h/ES-DE" ;;
        gitkraken) printf 'data\t%s\n' "$h/.gk" ;;
        gliv) printf 'data\t%s\n' "$h/.glivrc" ;;
        google-earth-pro) printf 'data\t%s\n' "$h/.googleearth" ;;
        icaclient) printf 'data\t%s\n' "$h/.ICAClient" ;;
        itch-bin) printf 'data\t%s\n' "$h/.itch" ;;
        jameica) printf 'data\t%s\n' "$h/.jameica.properties" ;;
        lens-bin) printf 'data\t%s\n' "$h/.k8slens" ;;
        logseq-desktop-bin) printf 'data\t%s\n' "$h/.logseq" ;;
        lunar-client) printf 'data\t%s\n' "$h/.lunarclient" ;;
        makemkv) printf 'data\t%s\n' "$h/.MakeMKV" && printf 'cache\t%s\n' "$h/MakeMKV_log.txt" ;;
        maptool) printf 'data\t%s\n' "$h/.maptool-rptools" ;;
        mathematica) printf 'data\t%s\n' "$h/.Mathematica" ;;
        minetest-git) printf 'data\t%s\n' "$h/.minetest" ;;
        neverball) printf 'data\t%s\n' "$h/.neverball-dev" ;;
        openshot) printf 'data\t%s\n' "$h/.openshot_qt" ;;
        osmos) printf 'data\t%s\n' "$h/.Osmos" ;;
        parsec-bin) printf 'data\t%s\n' "$h/.parsec" ;;
        portfolio-performance) printf 'data\t%s\n' "$h/.PortfolioPerformance" ;;
        proxyman-bin) printf 'data\t%s\n' "$h/.proxyman" "$h/.proxyman-data" ;;
        scilab) printf 'data\t%s\n' "$h/.Scilab" ;;
        simplescreenrecorder) printf 'data\t%s\n' "$h/.ssr" ;;
        stremio) printf 'data\t%s\n' "$h/.stremio-server" ;;
        texmacs) printf 'data\t%s\n' "$h/.TeXmacs" ;;
        viber) printf 'data\t%s\n' "$h/.ViberPC" ;;
        visual-studio-code-insiders-bin) printf 'data\t%s\n' "$h/.vscode-insiders" ;;
        vmware-workstation) printf 'data\t%s\n' "$h/.vmware" ;;
        weasis-bin) printf 'data\t%s\n' "$h/.weasis" ;;
        x3270) printf 'data\t%s\n' "$h/.x3270pro" "$h/.x3270connect" ;;
    esac
    return 0
}

# Names shared by many apps or by the desktop itself: a folder with one of
# these names is never an app's leftover, whatever app it was found for
# (mole-linux's SHARED_NAMES, plus the dot folders every tool shares).
mole_shared_leftover_name() {
    local lc
    mole_ascii_lowercase lc "$1"
    case "$lc" in
        applications | autostart | dbus-1 | dconf | environment.d | flatpak | fontconfig | fonts | gtk-2.0 | gtk-3.0 | \
            gtk-4.0 | gvfs-metadata | icons | keyrings | libsecret | mime | pipewire | pulse | recently-used.xbel | \
            seahorse | ssh | gnupg | steam | systemd | themes | thumbnails | trash | wireplumber | local | config | \
            cache | var | pki | cargo | rustup | npm | java | m2 | gradle | docker | kube | aws | git | bin | \
            omarchy | hypr | xdg-desktop-portal | menus | desktop-directories | sounds) return 0 ;;
    esac
    return 1
}

# The pkgbase of an installed package from pacman's local database, which
# names the AUR helper's build folder (a split package shares its base).
mole_pkgbase() {
    local pkg="$1" ver dbpath desc base
    ver=$(mole_c pacman -Q -- "$pkg" 2> /dev/null | awk 'NR == 1 { print $2 }') || ver=""
    if [[ -n "$ver" ]]; then
        dbpath="${MOLE_PACMAN_DBPATH:-/var/lib/pacman}"
        desc="$dbpath/local/$pkg-$ver/desc"
        [[ -r "$desc" ]] && base=$(awk '/^%BASE%$/ { getline; print; exit }' "$desc" 2> /dev/null)
    fi
    base="${base:-$pkg}"
    mole_valid_package_name "$base" && printf '%s' "$base"
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

    # A web app or terminal app launcher is only its launcher and icon
    # (mole_webapp_files): the program a TUI launcher starts is still
    # installed, so its config, dot folder, state and cache are not leftovers.
    [[ "$kind" == orphan || "$kind" == webapp || "$kind" == tui ]] && return 0
    if [[ "$kind" == flatpak ]]; then
        emit data "$HOME/.var/app/$id"
        # Permissions the user gave the app with flatpak override --user.
        emit data "$MOLE_DATA_HOME/flatpak/overrides/$id"
        return 0
    fi
    for d in "${ids[@]}"; do
        [[ "$d" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
        mole_shared_leftover_name "$d" && continue
        emit cache "$MOLE_CACHE_HOME/$d"
        emit cache "$MOLE_CONFIG_HOME/autostart/$d.desktop"
        emit data "$MOLE_CONFIG_HOME/$d"
        emit data "$MOLE_DATA_HOME/$d"
        emit data "$MOLE_STATE_HOME/$d"
        emit data "$HOME/.$d"
        emit data "$MOLE_CONFIG_HOME/systemd/user/$d.service"
        emit data "$MOLE_CONFIG_HOME/systemd/user/$d.timer"
        emit data "$MOLE_CONFIG_HOME/systemd/user/$d.socket"
        [[ "$kind" == appimage ]] || emit cache "$MOLE_DATA_HOME/applications/$d.desktop"
    done
    # xdg-ninja rows first, so their class wins over the alias table's data.
    local class
    while IFS=$'\t' read -r class d; do
        [[ -n "$d" ]] && emit "$class" "$d"
    done < <(mole_app_xdg_ninja_paths "$id")
    while IFS= read -r d; do
        [[ -n "$d" ]] && emit data "$d"
    done < <(mole_app_alias_paths "$id")
    if [[ "$kind" == aur ]]; then
        local base
        base=$(mole_pkgbase "$id")
        if [[ -n "$base" ]]; then
            # Build folders of the AUR helpers, only when they hold a
            # PKGBUILD: a folder of that name without one is not a build.
            [[ -f "$MOLE_CACHE_HOME/yay/$base/PKGBUILD" ]] && emit cache "$MOLE_CACHE_HOME/yay/$base"
            [[ -f "$MOLE_CACHE_HOME/paru/clone/$base/PKGBUILD" ]] && emit cache "$MOLE_CACHE_HOME/paru/clone/$base"
        fi
    fi
    return 0
}

# Data that --with-data still leaves unselected (they are listed, never
# preselected): browser and mail profiles hold passwords, history,
# extensions and mail; Spotify keeps its offline music under ~/.cache.
# Prints the reason when it holds a path back.
mole_leftover_holdback() {
    local c="$MOLE_CONFIG_HOME" v="$HOME/.var/app"
    case "$1" in
        "$c/chromium" | "$c/google-chrome" | "$c/google-chrome-"* | "$c/BraveSoftware" | "$c/vivaldi" | "$c/vivaldi-"* | \
            "$c/microsoft-edge" | "$c/microsoft-edge-"* | "$HOME/.mozilla" | "$c/mozilla" | "$HOME/.zen" | "$c/zen" | \
            "$c/opera" | "$c/opera-"* | "$c/yandex-browser" | "$c/yandex-browser-"* | "$c/cromite" | \
            "$c/helium" | "$c/net.imput.helium" | \
            "$HOME/.librewolf" | "$c/librewolf")
            echo "browser profile"
            return 0
            ;;
        "$HOME/.thunderbird" | "$c/thunderbird" | "$v/org.mozilla.Thunderbird")
            echo "mail profile"
            return 0
            ;;
        "$v/org.mozilla.firefox" | "$v/org.chromium.Chromium" | "$v/com.google.Chrome" | \
            "$v/com.brave.Browser" | "$v/com.vivaldi.Vivaldi" | "$v/com.microsoft.Edge" | "$v/app.zen_browser.zen" | \
            "$v/io.gitlab.librewolf-community")
            echo "browser profile"
            return 0
            ;;
        "$MOLE_CACHE_HOME/spotify" | "$v/com.spotify.Client")
            echo "offline music"
            return 0
            ;;
        "$v/net.waterfox.waterfox" | "$v/one.ablaze.floorp" | "$v/net.mullvad.MullvadBrowser" | \
            "$v/org.torproject.torbrowser-launcher" | "$v/com.github.Eloston.UngoogledChromium" | \
            "$v/io.github.ungoogled_software.ungoogled_chromium" | "$v/com.opera.Opera" | "$v/ru.yandex.Browser" | \
            "$v/net.imput.helium")
            echo "browser profile"
            return 0
            ;;
    esac
    # Other Gecko and Chromium family browsers, in ~/.config, ~/.<name> and
    # ~/.local/share forms.
    local n
    for n in waterfox floorp librewolf mullvad-browser tor-browser torbrowser palemoon \
        "moonchild productions" seamonkey icecat thorium ungoogled-chromium; do
        case "$1" in
            "$c/$n" | "$HOME/.$n" | "$MOLE_DATA_HOME/$n")
                echo "browser profile"
                return 0
                ;;
        esac
    done
    return 1
}
