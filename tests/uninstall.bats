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

@test "an exact ID wins over a display name, and a tie is refused" {
    mole_run uninstall '
        APP_KIND=(flatpak pacman); APP_ID=(org.mozilla.firefox firefox); APP_NAME=(Firefox Firefox)
        NAMES=(firefox); SELECTED=(); match_names; echo "picked=${SELECTED[*]}"
        APP_KIND=(flatpak aur); APP_ID=(org.a.Tool tool-bin); APP_NAME=(Tool Tool)
        NAMES=(tool); SELECTED=(); rc=0; match_names || rc=$?; echo "rc=$rc picked=${SELECTED[*]:-}"'
    [[ "$output" == *"picked=1"* ]]
    [[ "$output" == *"matches more than one app"* ]]
    [[ "$output" == *"rc=1 picked="* ]]
}

@test "a running Flatpak app, or one flatpak cannot answer for, blocks uninstall" {
    fake_command flatpak '[[ "$1" == ps ]] && echo org.test.App'
    mole_run uninstall 'APP_KIND=(flatpak); APP_ID=(org.test.App); APP_NAME=(Test); APP_EXEC=(org.test.App); SELECTED=(0); running_apps && echo "running=${RUNNING[*]}"'
    [ "$output" = "running=Test" ]
    fake_command flatpak 'exit 1'
    mole_run uninstall 'APP_KIND=(flatpak); APP_ID=(org.test.App); APP_NAME=(Test); APP_EXEC=(org.test.App); SELECTED=(0); running_apps && echo "running=${RUNNING[*]}"'
    [ "$output" = "running=Test" ]
    fake_command flatpak '[[ "$1" == ps ]] && echo org.other.App'
    mole_run uninstall 'APP_KIND=(flatpak); APP_ID=(org.test.App); APP_NAME=(Test); APP_EXEC=(org.test.App); SELECTED=(0); running_apps || echo none'
    [ "$output" = "none" ]
}

@test "outside a terminal, uninstall acts only with --yes" {
    local apps="$HOME/.local/share/applications"
    desktop "$apps/MoleWeb.desktop" "Name=MoleWeb" "Exec=omarchy-launch-webapp https://example.com"
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO" bash "$MOLE_TEST_REPO/bin/uninstall.sh" MoleWeb < /dev/null'
    [ "$status" -eq 1 ]
    [[ "$output" == *"pass --yes"* ]]
    [ -f "$apps/MoleWeb.desktop" ]
}

@test "Exec wildcards are not expanded into some other AppImage" {
    local apps="$HOME/.local/share/applications"
    mkdir -p "$HOME/Apps"
    touch "$HOME/Apps/Other.AppImage"
    desktop "$apps/glob.desktop" "Name=Glob" "Exec=$HOME/Apps/*.AppImage"
    mole_run uninstall '_inventory_appimages'
    [ -z "$output" ]
}

@test "an AppImage icon outside the icon folders stays" {
    local apps="$HOME/.local/share/applications"
    mkdir -p "$HOME/Apps" "$HOME/Pictures"
    touch "$HOME/Apps/Tool.AppImage" "$HOME/Pictures/me.png"
    desktop "$apps/tool.desktop" "Name=Tool" "Exec=$HOME/Apps/Tool.AppImage" "Icon=$HOME/Pictures/me.png"
    mole_run uninstall 'mole_appimage_files tool "$HOME/Apps/Tool.AppImage"'
    [[ "$output" != *me.png* ]]
}

@test "an old Omarchy web app icon beside the launchers goes with it" {
    mkdir -p "$HOME/.local/share/applications/icons"
    touch "$HOME/.local/share/applications/HEY.desktop" "$HOME/.local/share/applications/icons/HEY.png"
    mole_run uninstall 'mole_webapp_files HEY'
    [[ "$output" == *"applications/icons/HEY.png"* ]]
}

@test "a running program whose name is longer than comm holds is seen as running" {
    local long="mole-long-process-name-probe"
    cp "$(command -v sleep)" "$TEST_ROOT/bin/$long"
    "$TEST_ROOT/bin/$long" 30 &
    OWNER_PID=$!
    mole_run core 'rc=0; mole_process_running '"$long"' || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=0" ]
    kill "$OWNER_PID"
    wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""
    mole_run core 'rc=0; mole_process_running '"$long"' || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=1" ]
}

@test "a long name shares its first 15 bytes with another program: not taken for it" {
    cp "$(command -v sleep)" "$TEST_ROOT/bin/mole-long-processXYZ"
    "$TEST_ROOT/bin/mole-long-processXYZ" 30 &
    OWNER_PID=$!
    mole_run core 'rc=0; mole_process_running mole-long-process-name-probe || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=1" ]
}

@test "an interpreter running a package's file counts as that package running" {
    mkdir -p "$TEST_ROOT/usr/lib/tool"
    printf 'sleep 30\n' > "$TEST_ROOT/usr/lib/tool/main.sh"
    mole_run core 'bash "'"$TEST_ROOT"'/usr/lib/tool/main.sh" & p=$!; sleep 0.2
        rc=0; mole_files_running "'"$TEST_ROOT"'/usr/lib/tool/main.sh" || rc=$?; kill $p; echo "rc=$rc"'
    [ "$output" = "rc=0" ]
}
