#!/usr/bin/env bats

load helpers

desktop() {
    local file="$1"
    shift
    mkdir -p "$(dirname "$file")"
    { echo "[Desktop Entry]"; echo "Type=Application"; printf '%s\n' "$@"; } > "$file"
}

@test "leftovers match the exact ID, never a longer name" {
    mkdir -p "$HOME/.config/foo" "$HOME/.config/foobar" "$HOME/.cache/foo" "$HOME/.local/share/foo-extra"
    mole_run uninstall 'mole_app_leftovers pacman foo foo'
    [ "$status" -eq 0 ]
    [[ "$output" == *"data	$HOME/.config/foo"* ]]
    [[ "$output" == *"cache	$HOME/.cache/foo"* ]]
    [[ "$output" != *foobar* ]]
    [[ "$output" != *foo-extra* ]]
}

@test "an ID with a slash or a dot-dot never builds a path" {
    mkdir -p "$HOME/.config"
    mole_run uninstall 'mole_app_leftovers pacman "../x" "../x,a/b"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "StartupWMClass is an ID only when one launcher declares it" {
    local apps="$HOME/.local/share/applications"
    desktop "$apps/a.desktop" "Name=A" "StartupWMClass=MoleUniqueClass"
    desktop "$apps/b.desktop" "Name=B" "StartupWMClass=MoleSharedClass"
    desktop "$apps/c.desktop" "Name=C" "StartupWMClass=MoleSharedClass"
    desktop "$apps/d.desktop" "Name=D" "StartupWMClass=Electron"
    mole_run uninstall 'echo "a=$(mole_desktop_wmclass_id "'"$apps"'/a.desktop") b=$(mole_desktop_wmclass_id "'"$apps"'/b.desktop") d=$(mole_desktop_wmclass_id "'"$apps"'/d.desktop")"'
    [ "$output" = "a=MoleUniqueClass b= d=" ]
}

@test "an AppImage launcher lists the AppImage and owns its launcher and icon" {
    local apps="$HOME/.local/share/applications"
    mkdir -p "$HOME/Apps" "$HOME/.local/share/icons/hicolor/256x256/apps"
    head -c 4096 /dev/zero > "$HOME/Apps/Tool.AppImage"
    touch "$HOME/.local/share/icons/hicolor/256x256/apps/tool-icon.png"
    desktop "$apps/tool.desktop" "Name=Tool" "Exec=\"$HOME/Apps/Tool.AppImage\" %U" "Icon=tool-icon"
    desktop "$apps/elsewhere.desktop" "Name=Elsewhere" "Exec=/opt/Else.AppImage"
    mole_run uninstall '_inventory_appimages; echo ---; mole_appimage_files tool "$HOME/Apps/Tool.AppImage"'
    [ "$status" -eq 0 ]
    [[ "$output" == "appimage	tool	Tool	4	tool	$HOME/Apps/Tool.AppImage	user"* ]]
    [[ "$output" != *Elsewhere* ]]
    [[ "$output" == *"$apps/tool.desktop"* ]]
    [[ "$output" == *"tool-icon.png"* ]]
}

@test "an AppImage launcher is not also listed as its own leftover" {
    mkdir -p "$HOME/.local/share/applications"
    touch "$HOME/.local/share/applications/tool.desktop"
    mole_run uninstall 'mole_app_leftovers appimage tool tool'
    [[ "$output" != *"tool.desktop"* ]]
}

@test "Flatpak data is an orphan only when no installation has the app" {
    mkdir -p "$HOME/.var/app/org.a.Installed/config" "$HOME/.var/app/org.b.Gone/data" "$HOME/.var/app/org.c.Empty"
    fake_command flatpak '[[ "$1" == list ]] && echo org.a.Installed'
    mole_run uninstall '_inventory_flatpak_orphans'
    [ "$status" -eq 0 ]
    [[ "$output" == "orphan	org.b.Gone	org.b.Gone	"* ]]
    [[ "$output" != *org.a.Installed* ]]
    [[ "$output" != *org.c.Empty* ]]
}

@test "no orphan is reported when flatpak cannot list its apps" {
    mkdir -p "$HOME/.var/app/org.b.Gone/data"
    fake_command flatpak 'exit 1'
    mole_run uninstall '_inventory_flatpak_orphans'
    [ -z "$output" ]
}

@test "package names outside pacman's alphabet never reach argv" {
    mole_run uninstall 'for n in -rf "a b" "x;y" ok-name foo++ lib32-gcc; do mole_valid_package_name "$n" && echo "$n"; done'
    [ "$output" = $'ok-name\nfoo++\nlib32-gcc' ]
}

@test "an orphan's removal is moving its sandbox home to the Trash" {
    mkdir -p "$HOME/.var/app/org.b.Gone/data"
    mole_run uninstall 'APP_KIND=(orphan); APP_ID=(org.b.Gone); APP_EXEC=(""); app_own_files 0'
    [ "$output" = "$HOME/.var/app/org.b.Gone" ]
}
