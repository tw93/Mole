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

@test "a package whose wrapper starts a differently named program blocks uninstall while it runs" {
    mkdir -p "$TEST_ROOT/opt/tool"
    cp "$(command -v sleep)" "$TEST_ROOT/opt/tool/RealTool"
    fake_command pacman '[[ "$1" == -Qlq && "$3" == tool ]] && { echo "$TEST_ROOT/opt/"; echo "$TEST_ROOT/opt/tool/"; echo "$TEST_ROOT/opt/tool/RealTool"; exit 0; }; exit 1'
    fake_command pgrep 'exit 1'
    export TEST_ROOT
    "$TEST_ROOT/opt/tool/RealTool" 30 &
    OWNER_PID=$!
    local setup='APP_KIND=(pacman); APP_ID=(tool); APP_NAME=(Tool); APP_EXEC=(tool-launcher); SELECTED=(0)'
    mole_run uninstall "$setup"'; running_apps && echo "running=${RUNNING[*]}"'
    [ "$output" = "running=Tool" ]
    kill "$OWNER_PID"
    wait "$OWNER_PID" 2> /dev/null || true
    OWNER_PID=""
    mole_run uninstall "$setup"'; running_apps || echo none'
    [ "$output" = "none" ]
    fake_command pacman 'exit 1'
    mole_run uninstall "$setup"'; running_apps && echo "running=${RUNNING[*]}"'
    [ "$output" = "running=Tool" ]
}

@test "an interpreter running a package's file counts as that package running" {
    mkdir -p "$TEST_ROOT/usr/lib/tool"
    printf 'sleep 30\n' > "$TEST_ROOT/usr/lib/tool/main.sh"
    mole_run core 'bash "'"$TEST_ROOT"'/usr/lib/tool/main.sh" & p=$!; sleep 0.2
        rc=0; mole_files_running "'"$TEST_ROOT"'/usr/lib/tool/main.sh" || rc=$?; kill $p; echo "rc=$rc"'
    [ "$output" = "rc=0" ]
}

@test "keys typed while Mole worked never confirm a removal" {
    mole_run uninstall 'if uninstall_confirm "Remove 1 app?" <<< $'"'"'\n\n\n'"'"'; then echo CONFIRMED; else echo CANCELLED; fi'
    [[ "$output" == *CANCELLED* ]]
    [[ "$output" != *CONFIRMED* ]]
}

@test "the app selector drains queued keys before it reads any" {
    run grep -B3 'paginated_multi_select "Select Apps to Remove"' "$REPO/bin/uninstall.sh"
    [[ "$output" == *drain_pending_input* ]]
    run grep -B3 'paginated_multi_select "Settings and data to remove"' "$REPO/bin/uninstall.sh"
    [[ "$output" == *drain_pending_input* ]]
}

@test "a user service is stopped and disabled before its unit files go, timers and sockets included" {
    local u="$HOME/.config/systemd/user"
    mkdir -p "$u/default.target.wants"
    touch "$u/tool.service" "$u/tool.timer" "$u/tool.socket"
    fake_command systemctl 'echo "$*" >> "'"$TEST_ROOT"'/systemctl.log"; exit 0'
    mole_run uninstall '
        APP_KIND=(pacman); APP_ID=(tool); APP_NAME=(Tool); APP_DESKTOPS=(tool); APP_EXEC=(""); SELECTED=(0); WITH_DATA=true
        collect_leftovers; REMOVED=(0); plan_leftover_trash
        printf "trash=%s\n" "${LEFTOVER_PATHS[@]}"; printf "note=%s\n" "${UNIT_NOTES[@]}"'
    [[ "$output" == *"trash=$u/tool.service"* ]]
    [[ "$output" == *"trash=$u/tool.timer"* ]]
    [[ "$output" == *"trash=$u/tool.socket"* ]]
    grep -q -- "--user disable --now -- tool.service tool.timer tool.socket" "$TEST_ROOT/systemctl.log"
}

@test "user services stay where they are when systemctl --user cannot be reached" {
    local u="$HOME/.config/systemd/user"
    mkdir -p "$u"
    touch "$u/tool.service"
    fake_command systemctl 'echo "$*" >> "'"$TEST_ROOT"'/systemctl.log"; exit 1'
    mole_run uninstall '
        APP_KIND=(pacman); APP_ID=(tool); APP_NAME=(Tool); APP_DESKTOPS=(tool); APP_EXEC=(""); SELECTED=(0); WITH_DATA=true
        collect_leftovers; REMOVED=(0); plan_leftover_trash
        printf "trash=%s\n" "${LEFTOVER_PATHS[@]}"; printf "note=%s\n" "${UNIT_NOTES[@]}"'
    [[ "$output" != *"trash=$u/tool.service"* ]]
    [[ "$output" == *"left in place, systemctl --user is not reachable: tool.service"* ]]
    [ -z "$(grep -- disable "$TEST_ROOT/systemctl.log" 2> /dev/null)" ]
}

@test "a package's enabled user unit is disabled before pacman, and enabled again when pacman keeps it" {
    local u="$HOME/.config/systemd/user"
    mkdir -p "$u/default.target.wants"
    ln -s /usr/lib/systemd/user/toold.service "$u/default.target.wants/toold.service"
    fake_command pacman '[[ "$1" == -Qlq ]] && { echo /usr/lib/systemd/user/; echo /usr/lib/systemd/user/toold.service; exit 0; }; [[ "$1" == -Qq ]] && exit 0; exit 1'
    fake_command systemctl 'echo "$*" >> "'"$TEST_ROOT"'/systemctl.log"; [[ "$*" == *is-active* ]] && exit 3; exit 0'
    fake_command sudo 'exit 0'
    mole_run uninstall '
        APP_KIND=(pacman); APP_ID=(tool); APP_NAME=(Tool); APP_DESKTOPS=(tool); APP_EXEC=(""); SELECTED=(0)
        mole_sudo_ready() { return 0; }; mole_sudo_end() { :; }
        collect_leftovers; remove_packages; echo "removed=${REMOVED[*]:-none}"'
    [[ "$output" == *"removed=none"* ]]
    [ "$(grep -n -- 'disable --now -- toold.service' "$TEST_ROOT/systemctl.log" | cut -d: -f1)" -lt "$(grep -n -- 'enable -- toold.service' "$TEST_ROOT/systemctl.log" | cut -d: -f1)" ]
}

@test "after launchers leave, the launcher index is rebuilt and stale associations are reported" {
    local apps="$HOME/.local/share/applications"
    mkdir -p "$apps" "$HOME/.config"
    printf '[Default Applications]\nx-scheme-handler/mailto=HEY.desktop\ntext/plain=other.desktop\n' > "$HOME/.config/mimeapps.list"
    fake_command update-desktop-database 'echo "$*" >> "'"$TEST_ROOT"'/udd.log"'
    cp "$HOME/.config/mimeapps.list" "$TEST_ROOT/before"
    mole_run uninstall '
        APP_KIND=(webapp); APP_ID=(HEY); APP_NAME=(HEY); APP_DESKTOPS=(HEY); REMOVED=(0)
        refresh_after_removal "$HOME/.local/share/applications/HEY.desktop"; stale_mime_associations'
    grep -q -- "-q $apps" "$TEST_ROOT/udd.log"
    [[ "$output" == *"HEY.desktop	x-scheme-handler/mailto"* ]]
    [[ "$output" != *other.desktop* ]]
    [ "$(cat "$HOME/.config/mimeapps.list")" = "$(cat "$TEST_ROOT/before")" ]
}

@test "--with-data leaves Waterfox, Floorp and other Gecko or Chromium family profiles unselected" {
    mkdir -p "$HOME/.waterfox" "$HOME/.floorp" "$HOME/.config/thorium" "$HOME/.local/share/torbrowser" "$HOME/.cache/waterfox"
    mole_run uninstall '
        APP_KIND=(pacman pacman pacman pacman); APP_ID=(waterfox floorp thorium torbrowser); APP_NAME=(W F T B)
        APP_DESKTOPS=(waterfox floorp thorium torbrowser); APP_EXEC=("" "" "" ""); SELECTED=(0 1 2 3); WITH_DATA=true
        package_wants_links() { :; }; collect_leftovers
        for j in "${!LEFT_PATH[@]}"; do echo "${LEFT_PATH[j]}=${LEFT_ON[j]}"; done'
    [[ "$output" == *"$HOME/.waterfox=false"* ]]
    [[ "$output" == *"$HOME/.floorp=false"* ]]
    [[ "$output" == *"$HOME/.config/thorium=false"* ]]
    [[ "$output" == *"$HOME/.local/share/torbrowser=false"* ]]
    [[ "$output" == *"$HOME/.cache/waterfox=true"* ]]
}

@test "--with-data leaves Opera, Yandex, Cromite and Helium profiles unselected" {
    mkdir -p "$HOME/.config/opera" "$HOME/.config/opera-beta" "$HOME/.config/yandex-browser-beta" "$HOME/.config/cromite" "$HOME/.config/net.imput.helium"
    mole_run uninstall '
        for p in opera opera-beta yandex-browser-beta cromite net.imput.helium; do
            note=$(mole_leftover_holdback "$HOME/.config/$p") && echo "$p=$note" || echo "$p=selected"
        done'
    [ "$status" -eq 0 ]
    [ "$(grep -c "=browser profile" <<< "$output")" -eq 5 ]
}

@test "--with-data still leaves browser profiles and offline music unselected" {
    mkdir -p "$HOME/.config/chromium" "$HOME/.cache/chromium" "$HOME/.config/spotify" "$HOME/.cache/spotify"
    mole_run uninstall '
        APP_KIND=(pacman pacman); APP_ID=(chromium spotify); APP_NAME=(Chromium Spotify); APP_DESKTOPS=(chromium spotify); APP_EXEC=("" ""); SELECTED=(0 1); WITH_DATA=true
        package_wants_links() { :; }; collect_leftovers
        for j in "${!LEFT_PATH[@]}"; do echo "${LEFT_PATH[j]}=${LEFT_ON[j]}"; done'
    [[ "$output" == *"$HOME/.config/chromium=false"* ]]
    [[ "$output" == *"$HOME/.cache/chromium=true"* ]]
    [[ "$output" == *"$HOME/.cache/spotify=false"* ]]
    [[ "$output" == *"$HOME/.config/spotify=true"* ]]
}

@test "a Flatpak is removed from its own installation, system and custom ones through sudo" {
    fake_command flatpak 'echo "$*" >> "'"$TEST_ROOT"'/flatpak.log"; exit 0'
    fake_command sudo 'echo "$*" >> "'"$TEST_ROOT"'/sudo.log"; [[ "$1" == -* ]] && exit 0; exec "$@"'
    mole_run uninstall '
        APP_KIND=(flatpak flatpak flatpak flatpak); APP_ID=(org.a.One org.b.Two org.c.Three org.d.Four); APP_NAME=(One Two Three Four)
        APP_SCOPE=(extra user "bad name" system); SELECTED=(0 1 2 3)
        remove_packages; echo "removed=${REMOVED[*]}"'
    grep -qx -- "uninstall --installation=extra -- org.a.One" "$TEST_ROOT/flatpak.log"
    grep -qx -- "uninstall --user -- org.b.Two" "$TEST_ROOT/flatpak.log"
    grep -qx -- "uninstall --system -- org.d.Four" "$TEST_ROOT/flatpak.log"
    grep -qx -- "flatpak uninstall --installation=extra -- org.a.One" "$TEST_ROOT/sudo.log"
    grep -qx -- "flatpak uninstall --system -- org.d.Four" "$TEST_ROOT/sudo.log"
    [ -z "$(grep -- org.b.Two "$TEST_ROOT/sudo.log")" ]
    [ -z "$(grep -E -- '(^| )-y( |$)|--noninteractive|--assumeyes' "$TEST_ROOT/flatpak.log")" ]
    [ -z "$(grep -- org.c.Three "$TEST_ROOT/flatpak.log")" ]
    [[ "$output" == *"flatpak removes org.d.Four from the system installation"* ]]
    [[ "$output" == *"removed=0 1 3"* ]]
}

@test "a failed sudo is asked once: pacman and system Flatpaks are skipped on one line, the user one still goes" {
    fake_command flatpak 'echo "$*" >> "'"$TEST_ROOT"'/flatpak.log"; exit 0'
    fake_command sudo 'echo "$*" >> "'"$TEST_ROOT"'/sudo.log"; exit 1'
    fake_command pacman '[[ "$1" == -Qq ]] && exit 0; exit 1'
    mole_run uninstall '
        APP_KIND=(pacman flatpak flatpak flatpak); APP_ID=(tool org.d.Four org.e.Five org.b.Two); APP_NAME=(Tool Four Five Two)
        APP_DESKTOPS=(tool "" "" ""); APP_EXEC=("" "" "" ""); APP_SCOPE=("" system extra user); SELECTED=(0 1 2 3)
        restore_package_units() { :; }
        remove_packages < /dev/null; echo "removed=${REMOVED[*]}"'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$TEST_ROOT/sudo.log")" -eq 1 ]
    [ -z "$(grep -E -- 'org.d.Four|org.e.Five' "$TEST_ROOT/flatpak.log")" ]
    grep -qx -- "uninstall --user -- org.b.Two" "$TEST_ROOT/flatpak.log"
    [ "$(grep -c "Needs admin access" <<< "$output")" -eq 1 ]
    [[ "$output" == *"Needs admin access, not removed: tool org.d.Four org.e.Five"* ]]
    [[ "$output" != *"flatpak removes"* ]]
    [[ "$output" == *"removed=3"* ]]
}

@test "a web app icon kept in its original format goes with it, a shared icon stays" {
    local apps="$HOME/.local/share/applications" icons="$HOME/.local/share/icons/hicolor/256x256/apps"
    mkdir -p "$icons"
    touch "$icons/my-site.webp" "$icons/brand.svg" "$icons/shared.png"
    desktop "$apps/My Site.desktop" "Name=My Site" "Exec=omarchy-launch-webapp https://example.com" "Icon=my-site"
    desktop "$apps/Brand.desktop" "Name=Brand" "Exec=omarchy-launch-webapp https://b.example" "Icon=brand"
    desktop "$apps/A.desktop" "Name=A" "Exec=omarchy-launch-webapp https://a.example" "Icon=shared"
    desktop "$apps/B.desktop" "Name=B" "Exec=other" "Icon=shared"
    mole_run uninstall 'mole_webapp_files "My Site"; echo ---; mole_webapp_files Brand; echo ---; mole_webapp_files A'
    [[ "$output" == *"$icons/my-site.webp"* ]]
    [[ "$output" == *"$icons/brand.svg"* ]]
    [[ "$output" != *"shared.png"* ]]
}

@test "Omarchy terminal app launchers are listed with their launcher and icon" {
    local apps="$HOME/.local/share/applications" icons="$HOME/.local/share/icons/hicolor/256x256/apps"
    mkdir -p "$icons"
    touch "$icons/lazy-tool.png"
    desktop "$apps/Lazy Tool.desktop" "Name=Lazy Tool" "Exec=xdg-terminal-exec --app-id=TUI.float -e lazytool" "Icon=lazy-tool"
    desktop "$apps/plain.desktop" "Name=Plain" "Exec=foot"
    mole_run uninstall '_inventory_webapps; echo ---; mole_webapp_files "Lazy Tool"'
    [[ "$output" == "tui	Lazy Tool	Lazy Tool	"* ]]
    [[ "$output" != *Plain* ]]
    [[ "$output" == *"$icons/lazy-tool.png"* ]]
}

@test "a terminal app launcher leaves only its launcher and icon, never the program's own files" {
    local apps="$HOME/.local/share/applications" icons="$HOME/.local/share/icons/hicolor/256x256/apps"
    mkdir -p "$icons" "$HOME/.config/btop" "$HOME/.btop" "$HOME/.local/state/btop" "$HOME/.cache/btop" "$HOME/.local/share/btop"
    touch "$icons/btop.png"
    desktop "$apps/btop.desktop" "Name=btop" "Exec=xdg-terminal-exec --app-id=TUI.float -e btop" "Icon=btop"
    mole_run uninstall '
        APP_KIND=(tui); APP_ID=(btop); APP_NAME=(btop); APP_DESKTOPS=(btop); APP_EXEC=(""); SELECTED=(0); WITH_DATA=true
        package_wants_links() { :; }; collect_leftovers
        for j in "${!LEFT_PATH[@]}"; do echo "${LEFT_PATH[j]}"; done'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$apps/btop.desktop"* ]]
    [[ "$output" == *"$icons/btop.png"* ]]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
}

@test "process probes read the real uid from status, match --opt=/path, and fall back to comm" {
    local me other pr
    me=$(id -u); other=$((me + 1)); pr="$TEST_ROOT/proc"
    # Another user's process running the file is not the user's.
    fake_proc "$pr/a" 100 "$other" keepassxc /usr/bin/keepassxc keepassxc
    # A non-dumpable process of the user: no exe, argv not a path, comm matches.
    fake_proc "$pr/b" 101 "$me" keepassxc - keepassxc
    # A non-dumpable process of the user with another comm stays "not running".
    fake_proc "$pr/c" 102 "$me" bash - bash
    # An argument in --opt=/path form.
    fake_proc "$pr/d" 103 "$me" electron /usr/bin/electron electron --app=/usr/lib/code/out/main.js
    # A name longer than comm: no exe, argv[0] another name.
    fake_proc "$pr/e" 104 "$me" telegram-deskto - launcher
    fake_proc "$pr/f" 105 "$other" telegram-deskto /usr/bin/telegram-desktop /usr/bin/telegram-desktop
    mole_run core '
        for r in a b c; do _MOLE_PROC_ROOT='"$pr"'/$r; rc=0; mole_files_running /usr/bin/keepassxc || rc=$?; echo "$r=$rc"; done
        _MOLE_PROC_ROOT='"$pr"'/d; rc=0; mole_files_running /usr/lib/code/out/main.js || rc=$?; echo "d=$rc"
        for r in e f; do _MOLE_PROC_ROOT='"$pr"'/$r; rc=0; mole_process_running telegram-desktop || rc=$?; echo "$r=$rc"; done
        _MOLE_PROC_ROOT='"$pr"'/none; rc=0; mole_files_running /usr/bin/keepassxc || rc=$?; echo "none=$rc"'
    [ "$status" -eq 0 ]
    [[ " ${lines[*]} " == *" a=1 "* ]]
    [[ " ${lines[*]} " == *" b=2 "* ]]
    [[ " ${lines[*]} " == *" c=1 "* ]]
    [[ " ${lines[*]} " == *" d=0 "* ]]
    [[ " ${lines[*]} " == *" e=2 "* ]]
    [[ " ${lines[*]} " == *" f=1 "* ]]
    [[ " ${lines[*]} " == *" none=2 "* ]]
}

@test "the comm fallback covers every executable of a package, and AppImages get it too" {
    local me other pr
    me=$(id -u); other=$((me + 1)); pr="$TEST_ROOT/proc"
    mkdir -p "$TEST_ROOT/opt/tool" "$TEST_ROOT/apps"
    printf '#!/bin/sh\n' > "$TEST_ROOT/opt/tool/ToolApp"; chmod +x "$TEST_ROOT/opt/tool/ToolApp"
    echo data > "$TEST_ROOT/opt/tool/readme"
    printf '#!/bin/sh\n' > "$TEST_ROOT/apps/Obsidian-1.5.3.AppImage"; chmod +x "$TEST_ROOT/apps/Obsidian-1.5.3.AppImage"
    # A package executable outside */bin/, hidden by a non-dumpable process.
    fake_proc "$pr/g" 100 "$me" ToolApp - ToolApp
    fake_proc "$pr/h" 100 "$me" readme - readme
    # AppImages: readable exe, hidden exe with the file's comm, another user's, other comm.
    fake_proc "$pr/i" 100 "$me" Obsidian-1.5.3. "$TEST_ROOT/apps/Obsidian-1.5.3.AppImage"
    fake_proc "$pr/j" 100 "$me" Obsidian-1.5.3. -
    fake_proc "$pr/k" 100 "$other" Obsidian-1.5.3. "$TEST_ROOT/apps/Obsidian-1.5.3.AppImage"
    fake_proc "$pr/l" 100 "$me" bash -
    mole_run core '
        list="'"$TEST_ROOT"'/opt/tool/ToolApp
'"$TEST_ROOT"'/opt/tool/readme"
        for r in g h; do _MOLE_PROC_ROOT='"$pr"'/$r; rc=0; mole_files_running "$list" || rc=$?; echo "$r=$rc"; done
        for r in i j k l none; do _MOLE_PROC_ROOT='"$pr"'/$r; rc=0; mole_exe_running "'"$TEST_ROOT"'/apps/Obsidian-1.5.3.AppImage" || rc=$?; echo "$r=$rc"; done'
    [ "$status" -eq 0 ]
    [[ " ${lines[*]} " == *" g=2 "* ]]
    [[ " ${lines[*]} " == *" h=1 "* ]]
    [[ " ${lines[*]} " == *" i=0 "* ]]
    [[ " ${lines[*]} " == *" j=2 "* ]]
    [[ " ${lines[*]} " == *" k=1 "* ]]
    [[ " ${lines[*]} " == *" l=1 "* ]]
    [[ " ${lines[*]} " == *" none=2 "* ]]
}

@test "leftovers reach dot folders, known aliases, Flatpak overrides and AUR build folders" {
    mkdir -p "$HOME/.foo" "$HOME/.vscode-oss" "$HOME/.local/share/flatpak/overrides" "$HOME/.cache/yay/foo-base" "$HOME/.cache/paru/clone/foo-base" "$HOME/.cache/yay/foo"
    touch "$HOME/.local/share/flatpak/overrides/org.a.App" "$HOME/.cache/yay/foo-base/PKGBUILD" "$HOME/.cache/paru/clone/foo-base/PKGBUILD"
    mkdir -p "$TEST_ROOT/db/local/foo-1.0-1"
    printf '%%NAME%%\nfoo\n\n%%BASE%%\nfoo-base\n' > "$TEST_ROOT/db/local/foo-1.0-1/desc"
    fake_command pacman '[[ "$1" == -Q ]] && { echo "foo 1.0-1"; exit 0; }; exit 1'
    mole_run uninstall 'export MOLE_PACMAN_DBPATH="'"$TEST_ROOT"'/db"; mole_app_leftovers aur foo foo; mole_app_leftovers pacman code code; mole_app_leftovers flatpak org.a.App org.a.App'
    [[ "$output" == *"data	$HOME/.foo"* ]]
    [[ "$output" == *"cache	$HOME/.cache/yay/foo-base"* ]]
    [[ "$output" == *"cache	$HOME/.cache/paru/clone/foo-base"* ]]
    [ -z "$(grep -x "cache	$HOME/.cache/yay/foo" <<< "$output")" ]
    [[ "$output" == *"data	$HOME/.vscode-oss"* ]]
    [[ "$output" == *"data	$HOME/.local/share/flatpak/overrides/org.a.App"* ]]
}

@test "a shared name is never a leftover, and a path another installed app uses stays" {
    mkdir -p "$HOME/.config/fontconfig" "$HOME/.config/Code" "$HOME/.config/tool"
    mole_run uninstall 'mole_app_leftovers pacman fontconfig fontconfig'
    [ -z "$output" ]
    mole_run uninstall '
        APP_KIND=(pacman aur); APP_ID=(code visual-studio-code-bin); APP_NAME=("Code OSS" "VS Code"); APP_DESKTOPS=("code,Code" "visual-studio-code,Code"); APP_EXEC=("" ""); SELECTED=(0); WITH_DATA=true
        package_wants_links() { :; }; collect_leftovers; printf "%s\n" "${LEFT_PATH[@]}"'
    [[ "$output" != *"$HOME/.config/Code"* ]]
}

@test "the plan shows each leftover's size and the total" {
    mkdir -p "$HOME/.cache/tool"
    head -c 200000 /dev/zero > "$HOME/.cache/tool/blob"
    mole_run uninstall '
        APP_KIND=(pacman); APP_ID=(tool); APP_NAME=(Tool); APP_DESKTOPS=(tool); APP_EXEC=(""); APP_KB=(10); SELECTED=(0)
        package_wants_links() { :; }; collect_leftovers; show_plan'
    [[ "$output" == *"~/.cache/tool"*"KB"* ]]
    [[ "$output" == *"Leftovers to Trash: 1 item, "* ]]
}

@test "--list prints JSON when its output is piped" {
    local apps="$HOME/.local/share/applications"
    desktop "$apps/Mole \"Web\".desktop" "Name=Mole \"Web\"" "Exec=omarchy-launch-webapp https://example.com"
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO" bash "$MOLE_TEST_REPO/bin/uninstall.sh" --list | cat'
    [ "$status" -eq 0 ]
    [[ "$output" == "["* ]]
    [[ "$output" == *'"name": "Mole \"Web\"", "uninstall_name": "Mole \"Web\"", "source": "Web app"'* ]]
    if command -v python3 > /dev/null; then
        python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$output"
    fi
}

@test "last used comes from the app's own folders, and an untouched program's atime says nothing" {
    mkdir -p "$HOME/.config/tool"
    touch -d '3 days ago' "$HOME/.config/tool/x" "$HOME/.config/tool"
    mkdir -p "$TEST_ROOT/prog"
    printf '#!/bin/sh\n' > "$TEST_ROOT/prog/never-run"
    chmod +x "$TEST_ROOT/prog/never-run"
    touch -a -d '2 days ago' "$TEST_ROOT/prog/never-run"
    mole_run uninstall '
        APP_KIND=(pacman pacman); APP_ID=(tool other); APP_DESKTOPS=(tool other); APP_EXEC=("" "'"$TEST_ROOT"'/prog/never-run")
        a=$(app_last_used 0); b=$(app_last_used 1); echo "$(last_used_label "$a") $(last_used_label "$b")"'
    [ "$output" = "3d ago Unknown" ]
}
