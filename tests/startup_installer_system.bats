#!/usr/bin/env bats

load helpers

# A desktop entry with the given keys after [Desktop Entry].
entry() {
    local file="$1"
    shift
    mkdir -p "${file%/*}"
    { echo '[Desktop Entry]'; printf '%s\n' "Type=Application" "$@"; } > "$file"
}

@test "mo startup lists autostart entries; hidden and other-desktop ones stay out" {
    export XDG_CONFIG_DIRS="$TEST_ROOT/xdg" XDG_CURRENT_DESKTOP=GNOME
    entry "$TEST_ROOT/xdg/autostart/tracker.desktop" "Name=Tracker" "Exec=tracker"
    entry "$TEST_ROOT/xdg/autostart/plumbing.desktop" "Name=Plumbing" "NoDisplay=true"
    entry "$TEST_ROOT/xdg/autostart/kde.desktop" "Name=KDE Only" "OnlyShowIn=KDE;"
    entry "$HOME/.config/autostart/sync.desktop" "Name=Sync" "Hidden=true" "Name[de]=Abgleich"
    run bash "$REPO/mole" startup --json
    [ "$status" -eq 0 ]
    python3 - "$output" << 'PY'
import json, sys
items = {i["id"]: i for i in json.loads(sys.argv[1])}
assert set(items) == {"tracker.desktop", "sync.desktop"}, items
assert items["tracker.desktop"]["enabled"] and items["tracker.desktop"]["source"] == "system"
assert not items["sync.desktop"]["enabled"] and items["sync.desktop"]["name"] == "Sync"
PY
}

@test "mo startup disable writes a Hidden override, enable turns it back, the system file stays" {
    export XDG_CONFIG_DIRS="$TEST_ROOT/xdg"
    entry "$TEST_ROOT/xdg/autostart/tracker.desktop" "Name=Tracker" "Exec=tracker --flag"
    local before
    before=$(cat "$TEST_ROOT/xdg/autostart/tracker.desktop")
    run bash "$REPO/mole" startup disable tracker.desktop
    [ "$status" -eq 0 ]
    grep -qx 'Hidden=true' "$HOME/.config/autostart/tracker.desktop"
    grep -qx 'Exec=tracker --flag' "$HOME/.config/autostart/tracker.desktop"
    [ "$(cat "$TEST_ROOT/xdg/autostart/tracker.desktop")" == "$before" ]
    grep -q "\[startup run=[0-9-]*\] REBUILT $HOME/.config/autostart/tracker.desktop (disabled at login)" "$HOME/.local/state/mole/operations.log"
    run bash "$REPO/mole" startup enable tracker.desktop
    [ "$status" -eq 0 ]
    grep -qx 'Hidden=false' "$HOME/.config/autostart/tracker.desktop"
    [ "$(grep -c '^Hidden=' "$HOME/.config/autostart/tracker.desktop")" -eq 1 ]
}

@test "mo startup refuses an unknown id, a linked user entry, and changes nothing in a dry run" {
    export XDG_CONFIG_DIRS="$TEST_ROOT/xdg"
    entry "$TEST_ROOT/xdg/autostart/tracker.desktop" "Name=Tracker"
    entry "$TEST_ROOT/real.desktop" "Name=Linked"
    mkdir -p "$HOME/.config/autostart"
    ln -s "$TEST_ROOT/real.desktop" "$HOME/.config/autostart/linked.desktop"
    run bash "$REPO/mole" startup disable nothing.desktop
    [ "$status" -eq 1 ]
    [[ "$output" == *'No startup item named "nothing.desktop"'* ]]
    run bash "$REPO/mole" startup disable linked.desktop
    [ "$status" -eq 1 ]
    [[ "$output" == *"is a link"* ]]
    run grep -q Hidden "$TEST_ROOT/real.desktop"
    [ "$status" -eq 1 ]
    run bash "$REPO/mole" startup --dry-run disable tracker.desktop
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.config/autostart/tracker.desktop" ]
}

@test "mo installer finds installers, keeps AppImages a launcher starts, and moves only what it found" {
    fake_command xdg-user-dir 'exit 1'
    mkdir -p "$HOME/Downloads/sub" "$HOME/Desktop" "$HOME/.local/share/applications"
    head -c 4096 /dev/zero > "$HOME/Downloads/tool.deb"
    head -c 4096 /dev/zero > "$HOME/Downloads/sub/os.ISO"
    head -c 4096 /dev/zero > "$HOME/Desktop/App.AppImage"
    echo notes > "$HOME/Downloads/notes.txt"
    entry "$HOME/.local/share/applications/app.desktop" "Name=App" "Exec=$HOME/Desktop/App.AppImage %U"
    run bash "$REPO/mole" installer --json
    [ "$status" -eq 0 ]
    python3 - "$output" << 'PY'
import json, sys
items = {i["name"]: i for i in json.loads(sys.argv[1])}
assert set(items) == {"tool.deb", "os.ISO", "App.AppImage"}, items
assert items["App.AppImage"]["state"] == "in-use" and items["App.AppImage"]["note"] == "has a launcher"
assert items["os.ISO"]["kind"] == "Disk image"
PY
    run bash "$REPO/mole" installer --yes "$HOME/Downloads/notes.txt"
    [ "$status" -eq 1 ]
    [ -f "$HOME/Downloads/notes.txt" ]
    run bash "$REPO/mole" installer --yes "$HOME/Desktop/App.AppImage"
    [ "$status" -eq 1 ]
    [ -f "$HOME/Desktop/App.AppImage" ]
    run bash "$REPO/mole" installer --yes "$HOME/Downloads/tool.deb"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/Downloads/tool.deb" ]
    [ -f "$HOME/.local/share/Trash/files/tool.deb" ]
    [ -f "$HOME/Downloads/sub/os.ISO" ]
    grep -q "\[installer run=[0-9-]*\] TRASHED $HOME/Downloads/tool.deb" "$HOME/.local/state/mole/operations.log"
}

@test "mo installer outside a terminal needs --yes or --dry-run" {
    fake_command xdg-user-dir 'exit 1'
    mkdir -p "$HOME/Downloads"
    head -c 4096 /dev/zero > "$HOME/Downloads/tool.deb"
    run bash "$REPO/mole" installer < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a terminal"* ]]
    run bash "$REPO/mole" installer --dry-run < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would move to Trash: 1 file"* ]]
    [ -f "$HOME/Downloads/tool.deb" ]
}

@test "mo system reports a pending restart with its packages, and valid JSON" {
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/bin/system.sh"
        SYSTEM_REBOOT_FILE="'"$TEST_ROOT"'/reboot-required"; SYSTEM_CRASH_DIR="'"$TEST_ROOT"'/crash"
        touch "$SYSTEM_REBOOT_FILE"; printf "libc6\nlinux-base\nlibc6\n" > "$SYSTEM_REBOOT_FILE.pkgs"
        check_restart; SYSTEM_JSON=true; print_json'
    [ "$status" -eq 0 ]
    python3 - "$output" << 'PY'
import json, sys
c = json.loads(sys.argv[1])["checks"][0]
assert c["id"] == "restart" and c["state"] == "attention", c
assert c["items"] == ["libc6", "linux-base"], c
PY
}

@test "mo installer keeps a file an app holds open, and named files need --yes outside a terminal" {
    fake_command xdg-user-dir 'exit 1'
    mkdir -p "$HOME/Downloads"
    head -c 4096 /dev/zero > "$HOME/Downloads/vm.iso"
    head -c 4096 /dev/zero > "$HOME/Downloads/tool.deb"
    sleep 30 < "$HOME/Downloads/vm.iso" &
    OWNER_PID=$!
    sleep 0.2
    run bash "$REPO/mole" installer --json
    [ "$status" -eq 0 ]
    python3 - "$output" << 'PY'
import json, sys
items = {i["name"]: i for i in json.loads(sys.argv[1])}
assert items["vm.iso"]["state"] == "in-use" and items["vm.iso"]["note"] == "open in an app", items
assert items["tool.deb"]["state"] == "ok", items
PY
    run bash "$REPO/mole" installer --yes "$HOME/Downloads/vm.iso"
    [ "$status" -eq 1 ]
    [ -f "$HOME/Downloads/vm.iso" ]
    run bash "$REPO/mole" installer "$HOME/Downloads/tool.deb" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Pass --yes"* ]]
    [ -f "$HOME/Downloads/tool.deb" ]
}

@test "mo startup turns a user service on and off without starting or stopping it now" {
    mkdir -p "$HOME/.config/systemd/user"
    printf '[Service]\nExecStart=/usr/bin/syncthing\n' > "$HOME/.config/systemd/user/sync.service"
    fake_command systemctl 'echo "$*" >> "'"$TEST_ROOT"'/systemctl.log"
        [[ "$*" == *is-enabled* ]] && { echo enabled; exit 0; }
        [[ "$*" == *broken.service* ]] && exit 1
        exit 0'
    run bash "$REPO/mole" startup disable sync.service
    [ "$status" -eq 0 ]
    grep -qx -- '--user disable -- sync.service' "$TEST_ROOT/systemctl.log"
    run grep -q -- '--now' "$TEST_ROOT/systemctl.log"
    [ "$status" -eq 1 ]
    grep -q "REBUILT $HOME/.config/systemd/user/sync.service (disabled at login)" "$HOME/.local/state/mole/operations.log"
}

@test "mo startup leaves out a service whose state systemd cannot tell" {
    mkdir -p "$HOME/.config/systemd/user"
    printf '[Service]\nExecStart=/bin/true\n' > "$HOME/.config/systemd/user/sync.service"
    fake_command systemctl 'exit 1'
    run bash "$REPO/mole" startup --json
    [ "$status" -eq 0 ]
    [[ "$output" != *sync.service* ]]
}

@test "mo completion prints scripts that list every router command" {
    run bash "$REPO/mole" completion bash
    [ "$status" -eq 0 ]
    for c in clean uninstall installer startup system gui history; do [[ "$output" == *"$c "* ]] || return 1; done
    run bash -c "eval \"\$(bash '$REPO/mole' completion bash)\"; COMP_WORDS=(mo sta); COMP_CWORD=1; _mole_complete; echo \"\${COMPREPLY[*]}\""
    [ "$output" == "status startup" ]
    run bash "$REPO/mole" completion fish
    [[ "$output" == *"-a system -d 'Check restart, kernels and updates'"* ]]
    run bash "$REPO/mole" completion tcsh
    [ "$status" -eq 1 ]
}
