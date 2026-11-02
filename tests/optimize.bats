#!/usr/bin/env bats

load helpers

desktop() {
    local file="$1"
    shift
    mkdir -p "$(dirname "$file")"
    { echo "[Desktop Entry]"; echo "Type=Application"; printf '%s\n' "$@"; } > "$file"
}

# A SQLite file with about 2MB of free pages, so VACUUM has something to give back.
loose_db() {
    mkdir -p "$(dirname "$1")"
    sqlite3 "$1" "CREATE TABLE t(b BLOB); WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600) INSERT INTO t SELECT randomblob(4096) FROM n;"
    sqlite3 "$1" "DELETE FROM t WHERE rowid > 50;"
}

@test "a launcher whose program is gone is reported, a working or hidden one is not" {
    local apps="$HOME/.local/share/applications"
    mkdir -p "$HOME/.local/share/omarchy/bin"
    printf '#!/bin/sh\n' > "$HOME/.local/share/omarchy/bin/mole-test-omarchy-helper"
    chmod +x "$HOME/.local/share/omarchy/bin/mole-test-omarchy-helper"
    desktop "$apps/web.desktop" "Name=Web" "Exec=mole-test-omarchy-helper https://example.com"
    desktop "$apps/gone.desktop" "Name=Gone" "Exec=\"$HOME/Apps/Gone.AppImage\" %U"
    desktop "$apps/gonebin.desktop" "Name=GoneBin" "Exec=mole-no-such-program --flag"
    desktop "$apps/off.desktop" "Name=Off" "Hidden=true" "Exec=mole-no-such-program"
    desktop "$apps/try.desktop" "Name=Try" "TryExec=mole-no-such-program" "Exec=sh"
    mole_run optimize 'opt_broken_launchers "$HOME/.local/share/applications" | sort'
    [ "$status" -eq 0 ]
    [ "$output" = "$apps/gone.desktop"$'\n'"$apps/gonebin.desktop"$'\n'"$apps/try.desktop" ]
}

@test "a broken autostart entry needs attention, a hidden override does not" {
    desktop "$HOME/.config/autostart/old.desktop" "Name=Old" "Exec=/opt/removed/old"
    desktop "$HOME/.config/autostart/off.desktop" "Name=Off" "Hidden=true"
    mole_run optimize 'task_autostart; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"1 autostart entry starts a program that is gone"* ]]
    [[ "$output" == *"old.desktop"* ]]
    [[ "$output" != *"off.desktop"* ]]
    [[ "$output" == *"outcome=attention"* ]]
}

@test "a closed browser's loose database is compacted, an open one is left alone" {
    command -v sqlite3 > /dev/null || skip "sqlite3 not installed"
    local db="$HOME/.config/chromium/Default/History"
    loose_db "$db"
    local before after
    before=$(stat -c %s "$db")

    fake_command pgrep '[[ "$*" == *chromium* ]] && exit 0; exit 1'
    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Chromium is open"* ]]
    [[ "$output" == *"outcome=skipped"* ]]
    [ "$(stat -c %s "$db")" -eq "$before" ]

    fake_command pgrep 'exit 2'
    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"outcome=skipped"* ]]
    [ "$(stat -c %s "$db")" -eq "$before" ]

    fake_command pgrep 'exit 1'
    mole_run optimize 'DRY_RUN=true; task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Compacted 1 database"* ]]
    [ "$(stat -c %s "$db")" -eq "$before" ]

    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Compacted 1 database"* ]]
    [[ "$output" == *"outcome=applied"* ]]
    after=$(stat -c %s "$db")
    [ "$after" -lt "$before" ]
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM t;')" -eq 50 ]

    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Already compact for 1 database"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
}

@test "a damaged browser database is never vacuumed" {
    command -v sqlite3 > /dev/null || skip "sqlite3 not installed"
    local db="$HOME/.config/chromium/Default/History"
    loose_db "$db"
    fake_command pgrep 'exit 1'
    real_sqlite="$(command -v sqlite3)"
    fake_command sqlite3 'if [[ "$*" == *quick_check* ]]; then '"$real_sqlite"' "$@" | sed "\$s/^ok\$/*** in database main ***/"; exit 0; fi
if [[ "$*" == *VACUUM* ]]; then echo vacuumed >> "'"$TEST_ROOT"'/vacuum.log"; fi
exec '"$real_sqlite"' "$@"'
    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"could not be compacted"* ]]
    [[ "$output" == *"outcome=failed"* ]]
    [ ! -e "$TEST_ROOT/vacuum.log" ]
}

@test "a pacman lock with no package manager running needs attention" {
    touch "$TEST_ROOT/db.lck"
    fake_command pgrep 'exit 1'
    mole_run optimize 'OPT_PACMAN_LOCK="'"$TEST_ROOT"'/db.lck"; task_pacman_lock; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"left over from an interrupted run"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    # pacman under sudo runs as root, so the probe must not filter by user.
    fake_command pgrep '[[ "$*" == *-u* ]] && exit 1; [[ "$*" == *" pacman" ]] && exit 0; exit 1'
    mole_run optimize 'OPT_PACMAN_LOCK="'"$TEST_ROOT"'/db.lck"; task_pacman_lock; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"locked by a running package manager"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
    fake_command pgrep 'exit 2'
    mole_run optimize 'OPT_PACMAN_LOCK="'"$TEST_ROOT"'/db.lck"; task_pacman_lock; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" != *"left over"* ]]
    [[ "$output" == *"outcome=unavailable"* ]]
    [ -e "$TEST_ROOT/db.lck" ]
}

# Tests that fake systemctl also say systemd is the running init.
systemd_up() { mkdir -p "$TEST_ROOT/run-systemd"; export OPT_SYSTEMD_RUN_DIR="$TEST_ROOT/run-systemd"; }

@test "failed units are listed with their status command; no systemd is unavailable, not healthy" {
    systemd_up
    fake_command systemctl 'if [[ "$*" == *--user* ]]; then exit 1; fi; printf "%s\n" "foo.service loaded failed failed Foo"'
    mole_run optimize 'task_services; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"1 service failed"* ]]
    [[ "$output" == *"systemctl status foo.service"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    fake_command systemctl 'exit 1'
    mole_run optimize 'task_services; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"outcome=unavailable"* ]]
    [[ "$output" != *"No failed"* ]]
    fake_command systemctl '[[ "$*" == *--user* ]] && exit 0; exit 1'
    mole_run optimize 'task_services; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"system services could not be checked"* ]]
    [[ "$output" == *"outcome=unavailable"* ]]
}

@test "two power managers enabled at once need attention; no systemd is unavailable" {
    systemd_up
    fake_command systemctl '[[ "$1" == is-enabled && ( "$2" == tlp.service || "$2" == power-profiles-daemon.service ) ]] && { echo enabled; exit 0; }; echo disabled; exit 1'
    mole_run optimize 'task_power; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"tlp and power-profiles-daemon are both enabled"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    fake_command systemctl '[[ "$1" == is-enabled && ( "$2" == tuned.service || "$2" == tuned-ppd.service ) ]] && { echo enabled; exit 0; }; echo disabled; exit 1'
    mole_run optimize 'task_power; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Power managed by tuned"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
    export OPT_SYSTEMD_RUN_DIR="$TEST_ROOT/no-such-dir"
    mole_run optimize 'task_power; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"outcome=unavailable"* ]]
    [[ "$output" != *"No conflicting"* ]]
}

@test "TRIM is reported only for an SSD with neither discard nor the weekly timer" {
    systemd_up
    fake_command findmnt '[[ "$*" == *SOURCE* ]] && echo "/dev/nvme0n1p2[/@]"; [[ "$*" == *OPTIONS* ]] && echo "rw,noatime,ssd,space_cache=v2"; exit 0'
    fake_command lsblk '[[ "$*" == *ROTA* ]] && echo 0; [[ "$*" == *DISC-GRAN* ]] && echo 512B; exit 0'
    fake_command systemctl 'echo disabled; exit 1'
    mole_run optimize 'task_trim; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"TRIM is off"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    fake_command findmnt '[[ "$*" == *SOURCE* ]] && echo "/dev/nvme0n1p2[/@]"; [[ "$*" == *OPTIONS* ]] && echo "rw,noatime,ssd,discard=async"; exit 0'
    mole_run optimize 'task_trim; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Continuous TRIM is on"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
    fake_command findmnt '[[ "$*" == *SOURCE* ]] && echo "/dev/nvme0n1p2"; [[ "$*" == *OPTIONS* ]] && echo "rw,noatime"; exit 0'
    export OPT_SYSTEMD_RUN_DIR="$TEST_ROOT/no-such-dir"
    mole_run optimize 'task_trim; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" != *"TRIM is off"* ]]
    [[ "$output" == *"outcome=unavailable"* ]]
}

@test "orphan packages are listed, never removed" {
    fake_command pacman '[[ "$*" == "-Qtdq" ]] && { printf "%s\n" libfoo libbar; exit 0; }; echo "pacman $*" >> "'"$TEST_ROOT"'/pacman.log"; exit 1'
    mole_run optimize 'task_orphans; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"2 packages were installed as dependencies that nothing needs any more"* ]]
    [[ "$output" == *"libfoo libbar"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    [ ! -e "$TEST_ROOT/pacman.log" ]
    fake_command pacman 'exit 1'
    mole_run optimize 'task_orphans; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" != *"No orphan"* ]]
    [[ "$output" == *"outcome=unavailable"* ]]
}

@test "a dry run end to end uses no sudo and changes nothing" {
    command -v sqlite3 > /dev/null || skip "sqlite3 not installed"
    local db="$HOME/.mozilla/firefox/abc.default/places.sqlite"
    loose_db "$db"
    sqlite3 "$db" "PRAGMA journal_mode=WAL;" > /dev/null
    local before
    before=$(stat -c %s "$db")
    mkdir -p "$HOME/.local/share/applications"
    fake_command pgrep 'exit 1'
    fake_command sudo 'echo "sudo $*" >> "'"$TEST_ROOT"'/changes.log"; exit 1'
    fake_command fc-cache 'echo "fc-cache $*" >> "'"$TEST_ROOT"'/changes.log"'
    fake_command update-desktop-database 'echo "update-desktop-database $*" >> "'"$TEST_ROOT"'/changes.log"'
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO" bash "$MOLE_TEST_REPO/bin/optimize.sh" --dry-run < /dev/null'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry Run Complete"* ]]
    [[ "$output" == *"Compacted 1 database"* ]]
    [ ! -e "$TEST_ROOT/changes.log" ]
    [ "$(stat -c %s "$db")" -eq "$before" ]
    [ ! -e "$db-wal" ]
    [ ! -e "$db-shm" ]
}

@test "a Firefox WAL database and a Chromium profile with a space in its name are compacted" {
    command -v sqlite3 > /dev/null || skip "sqlite3 not installed"
    local fx="$HOME/.mozilla/firefox/abc.default/places.sqlite" ch="$HOME/.config/chromium/Profile 1/History"
    loose_db "$fx"
    sqlite3 "$fx" "PRAGMA journal_mode=WAL;" > /dev/null
    loose_db "$ch"
    local fx_before ch_before
    fx_before=$(stat -c %s "$fx")
    ch_before=$(stat -c %s "$ch")
    fake_command pgrep 'exit 1'
    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Compacted 2 databases"* ]]
    [[ "$output" == *"outcome=applied"* ]]
    [ "$(stat -c %s "$fx")" -lt "$fx_before" ]
    [ "$(stat -c %s "$ch")" -lt "$ch_before" ]
}

@test "a database over 100MB, or in a symlinked profile, is never vacuumed" {
    command -v sqlite3 > /dev/null || skip "sqlite3 not installed"
    local db="$HOME/.config/chromium/Default/History"
    loose_db "$db"
    loose_db "$TEST_ROOT/elsewhere/Profile/History"
    ln -s "$TEST_ROOT/elsewhere/Profile" "$HOME/.config/chromium/Profile 2"
    local other_before
    other_before=$(stat -c %s "$TEST_ROOT/elsewhere/Profile/History")
    fake_command pgrep 'exit 1'
    real_stat="$(command -v stat)"
    fake_command stat 'if [[ "${!#}" == */Default/History ]]; then echo 209715200; else exec '"$real_stat"' "$@"; fi'
    real_sqlite="$(command -v sqlite3)"
    fake_command sqlite3 '[[ "$*" == *VACUUM* ]] && echo "$*" >> "'"$TEST_ROOT"'/vacuum.log"; exec '"$real_sqlite"' "$@"'
    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [ ! -e "$TEST_ROOT/vacuum.log" ]
    [[ "$output" == *"outcome=unchanged"* ]]
    [ "$("$real_stat" -c %s "$TEST_ROOT/elsewhere/Profile/History")" -eq "$other_before" ]
}

@test "a launcher whose quoted program path holds a space is not broken" {
    local apps="$HOME/.local/share/applications"
    mkdir -p "$HOME/My Apps"
    printf '#!/bin/sh\n' > "$HOME/My Apps/Tool App.AppImage"
    chmod +x "$HOME/My Apps/Tool App.AppImage"
    desktop "$apps/tool.desktop" "Name=Tool" "Exec=\"$HOME/My Apps/Tool App.AppImage\" %U"
    desktop "$apps/wine.desktop" "Name=Wine" "Exec=env WINEPREFIX=\"$HOME/My Wine\" sh -c true"
    desktop "$apps/unset.desktop" "Name=Unset" "Exec=env -u FOO sh"
    mole_run optimize 'opt_broken_launchers "$HOME/.local/share/applications"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a browser opened mid-run keeps the rest of its databases untouched" {
    command -v sqlite3 > /dev/null || skip "sqlite3 not installed"
    loose_db "$HOME/.config/chromium/Default/History"
    loose_db "$HOME/.config/chromium/Default/Favicons"
    # The first probe says closed, every later one says open.
    fake_command pgrep 'f="'"$TEST_ROOT"'/probes"; n=$(cat "$f" 2> /dev/null || echo 0); echo $((n + 1)) > "$f"; [[ $n -eq 0 ]] && exit 1; exit 0'
    mole_run optimize 'task_browser_dbs; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Compacted 1 database"* ]]
    [[ "$output" == *"Chromium is open"* ]]
}

@test "Chromium's Web Data, Top Sites and Shortcuts are compacted, Cookies and Login Data never" {
    local p="$HOME/.config/chromium/Default"
    mkdir -p "$p"
    touch "$p/History" "$p/Web Data" "$p/Top Sites" "$p/Shortcuts" "$p/Cookies" "$p/Login Data"
    mole_run optimize 'while IFS="|" read -r l o r n; do opt_browser_dbs "$r" "$n"; done < <(opt_browser_specs)'
    [[ "$output" == *"$p/Web Data"* ]]
    [[ "$output" == *"$p/Top Sites"* ]]
    [[ "$output" == *"$p/Shortcuts"* ]]
    [[ "$output" != *Cookies* ]]
    [[ "$output" != *"Login Data"* ]]
}

@test "Firefox, Zen and Thunderbird profiles give every top-level sqlite but cookies.sqlite, in both Firefox folders" {
    local old="$HOME/.mozilla/firefox/a.default" new="$HOME/.config/mozilla/firefox/b.default" tb="$HOME/.thunderbird/c.default"
    mkdir -p "$old/storage" "$new" "$tb"
    touch "$old/places.sqlite" "$old/formhistory.sqlite" "$old/cookies.sqlite" "$old/storage/x.sqlite" "$old/key4.db"
    touch "$new/places.sqlite" "$tb/global-messages-db.sqlite" "$tb/cookies.sqlite"
    mole_run optimize 'while IFS="|" read -r l o r n; do opt_browser_dbs "$r" "$n" | sed "s/^/$l: /"; done < <(opt_browser_specs)'
    [[ "$output" == *"Firefox: $old/places.sqlite"* ]]
    [[ "$output" == *"Firefox: $old/formhistory.sqlite"* ]]
    [[ "$output" == *"Firefox: $new/places.sqlite"* ]]
    [[ "$output" == *"Thunderbird: $tb/global-messages-db.sqlite"* ]]
    [[ "$output" != *cookies.sqlite* ]]
    [[ "$output" != *storage/x.sqlite* ]]
    [[ "$output" != *key4.db* ]]
}

@test "Hyprland start commands that run a missing program are reported, conf and Lua alike" {
    mkdir -p "$HOME/.config/hypr"
    printf 'exec-once = mole-no-such-daemon --flag\nexec-once = sh -c true\n# exec-once = mole-commented-out\nexec = uwsm app -- mole-no-such-bar\nexec-once = foo $HOME | bar\n' > "$HOME/.config/hypr/autostart.conf"
    printf -- '-- o.launch_on_start("mole-lua-commented")\no.launch_on_start("mole-no-such-lua-app --x")\nhl.exec_cmd(o.launch("sh"))\n' > "$HOME/.config/hypr/autostart.lua"
    mole_run optimize 'task_autostart; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"3 Hyprland start commands run programs that are gone"* ]]
    [[ "$output" == *"autostart.conf:1"*mole-no-such-daemon* ]]
    [[ "$output" == *mole-no-such-bar* ]]
    [[ "$output" == *"autostart.lua:2"*mole-no-such-lua-app* ]]
    [[ "$output" != *commented* ]]
    [[ "$output" != *"foo"* ]]
    [[ "$output" == *"outcome=attention"* ]]
}

@test "a user service whose program is gone, or a link to a gone unit, needs attention" {
    local u="$HOME/.config/systemd/user"
    mkdir -p "$u/default.target.wants"
    printf '[Service]\nExecStart=-/opt/mole-gone/daemon --x\n' > "$u/gone.service"
    printf '[Service]\nExecStart=/bin/sh -c true\n' > "$u/fine.service"
    ln -s "$u/missing.service" "$u/default.target.wants/missing.service"
    mole_run optimize 'task_autostart; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"1 user service starts a program that is gone"* ]]
    [[ "$output" == *"gone.service"*"/opt/mole-gone/daemon"* ]]
    [[ "$output" != *fine.service* ]]
    [[ "$output" == *"1 user service link points at a unit that is gone"* ]]
    [[ "$output" == *"outcome=attention"* ]]
}

@test "root-owned files in the home folder are reported with the fix, never changed" {
    mkdir -p "$HOME/.config/stuck" "$HOME/Documents"
    mole_run optimize 'OPT_FOREIGN_UID=999999; task_home_ownership; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"No root-owned files"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
    mole_run optimize 'OPT_FOREIGN_UID=$(id -u); task_home_ownership; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"owned by root"* ]]
    [[ "$output" == *"sudo chown -R"* ]]
    [[ "$output" == *"outcome=attention"* ]]
}

@test "a personal icon theme with an index gets its icon cache rebuilt, a dry run only says so" {
    mkdir -p "$HOME/.local/share/icons/MyTheme" "$HOME/.local/share/icons/hicolor"
    touch "$HOME/.local/share/icons/MyTheme/index.theme"
    fake_command gtk-update-icon-cache 'echo "$*" >> "'"$TEST_ROOT"'/gtk.log"'
    mole_run optimize 'DRY_RUN=true; task_icon_cache; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"Icon cache refreshed for 1 theme"* ]]
    [ ! -e "$TEST_ROOT/gtk.log" ]
    mole_run optimize 'task_icon_cache; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"outcome=applied"* ]]
    grep -qx -- "-q -f $HOME/.local/share/icons/MyTheme" "$TEST_ROOT/gtk.log"
    [ -z "$(grep hicolor "$TEST_ROOT/gtk.log")" ]
}

# ---- report-only checks: pacnew, broken links, rebuilds, unowned files ----

# Every file under $1 with its content hash, to prove a task changed nothing.
tree_state() { (cd "$1" && find . -print0 | sort -z | xargs -0 stat -c '%n %F %Y %s %N' 2> /dev/null); }

@test "pending .pacnew, .pacsave and .pacorig files are listed and left alone" {
    local etc="$TEST_ROOT/etc"
    mkdir -p "$etc/ssh" "$etc/pacman.d"
    : > "$etc/pacman.conf"; : > "$etc/pacman.conf.pacnew"
    : > "$etc/ssh/sshd_config.pacsave"; : > "$etc/pacman.d/mirrorlist.pacorig"
    : > "$etc/fstab"; : > "$etc/notes.pacnew.txt"
    export OPT_ETC_DIR="$etc"
    local before
    before=$(tree_state "$etc")
    mole_run optimize 'task_pacnew; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 config files in $etc waiting for you to merge (1 .pacnew, 1 .pacsave, 1 .pacorig)"* ]]
    [[ "$output" == *"pacman.conf.pacnew"* && "$output" == *"sshd_config.pacsave"* && "$output" == *"mirrorlist.pacorig"* ]]
    [[ "$output" != *"notes.pacnew.txt"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    [ "$(tree_state "$etc")" = "$before" ]
    # a dry run says the same thing
    local normal="$output"
    mole_run optimize 'DRY_RUN=true; task_pacnew; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [ "${output//$'\n'/|}" != "" ]
    [[ "${output//[^a-z]/}" == "${normal//[^a-z]/}" ]]
}

@test "no pending config files reads as clean, folders only root can read are said so" {
    local etc="$TEST_ROOT/etc"
    mkdir -p "$etc/secret" "$etc/open"
    : > "$etc/open/a.conf"
    export OPT_ETC_DIR="$etc"
    mole_run optimize 'task_pacnew; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"No pending config merges"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
    [ "$(id -u)" -ne 0 ] || skip "root can read every folder"
    : > "$etc/secret/x.pacnew"
    chmod 000 "$etc/secret"
    mole_run optimize 'task_pacnew; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    chmod 755 "$etc/secret"
    [[ "$output" == *"in the folders Mole can read"* ]]
    [[ "$output" == *"1 folder in $etc can only be read by root"* ]]
    [[ "$output" != *"x.pacnew"* ]]
}

@test "broken links in the home folder are listed, never removed, and normal places are skipped" {
    mkdir -p "$HOME/Documents" "$HOME/.cache/app" "$HOME/.local/share/Trash/files" "$HOME/proj/node_modules/x" \
        "$HOME/proj/.git" "$HOME/.var/app/org.x/data" "$HOME/.mozilla/firefox/p" "$HOME/.config/chromium" \
        "$HOME/.local/share/Steam/steamapps" "$HOME/py/.venv/bin" "$HOME/.wine/dosdevices" "$HOME/ok"
    ln -s /nonexistent/target "$HOME/Documents/dead-link"
    ln -s /nonexistent/target "$HOME/dead-top"
    ln -s "$HOME/ok" "$HOME/live-link"
    local p
    for p in .cache/app/l .local/share/Trash/files/l proj/node_modules/x/l proj/.git/l .var/app/org.x/data/l \
        .mozilla/firefox/p/lock .config/chromium/SingletonLock .local/share/Steam/steamapps/l py/.venv/bin/python .wine/dosdevices/d::; do
        ln -s /nonexistent/target "$HOME/$p"
    done
    mole_run optimize 'task_broken_symlinks; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 links point at something that is gone"* ]]
    [[ "$output" == *"~/Documents/dead-link"* && "$output" == *"~/dead-top"* ]]
    [[ "$output" != *"live-link"* && "$output" != *".cache"* && "$output" != *"Trash"* && "$output" != *"node_modules"* ]]
    [[ "$output" != *".git"* && "$output" != *".var"* && "$output" != *".mozilla"* && "$output" != *"Singleton"* ]]
    [[ "$output" != *"Steam"* && "$output" != *".venv"* && "$output" != *"dosdevices"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    [ -L "$HOME/Documents/dead-link" ] && [ -L "$HOME/dead-top" ] && [ -L "$HOME/.cache/app/l" ]
}

@test "a home folder with no broken links reads as clean" {
    mkdir -p "$HOME/ok"
    ln -s "$HOME/ok" "$HOME/live"
    mole_run optimize 'task_broken_symlinks; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"No broken links in your home folder"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
}

@test "a packages needing a rebuild: stale runtime folders of foreign packages only" {
    local lib="$TEST_ROOT/usr/lib"
    mkdir -p "$lib/python3.14" "$lib/python3.13" "$lib/python3.12" "$lib/python3.11" "$lib/python3.9junk"
    export OPT_USR_LIB="$lib"
    fake_command python3 'echo 3.14'
    fake_command python3.11 'exit 0'
    fake_command readelf 'exit 1'
    fake_command ldconfig 'exit 0'
    fake_command ldd 'echo "ldd $*" >> "'"$TEST_ROOT"'/ldd.log"'
    fake_command pacman '
case "$*" in
    "-Qmq") printf "%s\n" auraur aurold python312 aurfine ;;
    "-Qq pacman") echo pacman ;;
    "-Qqo -- "*/python3.13) printf "%s\n" auraur repopkg ;;
    "-Qqo -- "*/python3.12) printf "%s\n" python312 ;;
    "-Qqo -- "*/python3.11) printf "%s\n" aurold ;;
    "-Ql -- "*) ;;
    *) exit 1 ;;
esac'
    mole_run optimize 'task_rebuild; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 package from outside the repositories was built for something that has changed since"* ]]
    [[ "$output" == *"auraur"* && "$output" == *"python files in python3.13, python is now 3.14"* ]]
    # not foreign (repopkg), the old runtime's own package (python312), an interpreter still installed (aurold)
    [[ "$output" != *"repopkg"* && "$output" != *"python312"* && "$output" != *"aurold"* && "$output" != *"aurfine"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    [ ! -e "$TEST_ROOT/ldd.log" ]
}

@test "a foreign package whose shared library is gone is reported, bundled and cached ones are not" {
    local extra="$TEST_ROOT/extra"
    mkdir -p "$extra" "$TEST_ROOT/usr/lib"
    : > "$extra/libviarunpath.so.1"
    export OPT_USR_LIB="$TEST_ROOT/usr/lib" OPT_ELF_PATHS_RE='^/'
    fake_command python3 'echo 3.14'
    fake_command ldd 'echo "ldd $*" >> "'"$TEST_ROOT"'/ldd.log"'
    fake_command ldconfig 'printf "2 libs found in cache\n\tlibc.so.6 (libc6,x86-64) => /usr/lib/libc.so.6\n"'
    fake_command pacman '
case "$*" in
    "-Qmq") printf "%s\n" brokenpkg okpkg bundledpkg runpathpkg ;;
    "-Qq pacman") echo pacman ;;
    "-Qqo -- "*) ;;
    "-Ql -- "*)
        printf "%s\n" "brokenpkg /opt/broken/bin/app" "okpkg /opt/ok/bin/app" "bundledpkg /opt/bundled/bin/app" \
            "bundledpkg /opt/bundled/lib/libbundled.so.2" "runpathpkg /opt/rp/bin/app" "okpkg /opt/ok/share/readme.txt" "okpkg /opt/ok/share/" ;;
    *) exit 1 ;;
esac'
    fake_command readelf '
for f in "$@"; do
    case "$f" in
        /opt/broken/bin/app) printf "\nFile: %s\n 0x01 (NEEDED)  Shared library: [libgone.so.1]\n 0x01 (NEEDED)  Shared library: [libc.so.6]\n" "$f" ;;
        /opt/ok/bin/app) printf "\nFile: %s\n 0x01 (NEEDED)  Shared library: [libc.so.6]\n" "$f" ;;
        /opt/bundled/bin/app) printf "\nFile: %s\n 0x01 (NEEDED)  Shared library: [libbundled.so.2]\n" "$f" ;;
        /opt/rp/bin/app) printf "\nFile: %s\n 0x01 (NEEDED)  Shared library: [libviarunpath.so.1]\n 0x01 (RUNPATH)  Library runpath: [%s]\n" "$f" "'"$extra"'" ;;
        /dev/null) printf "\nFile: /dev/null\nreadelf: Error: Not an ELF file\n" ;;
    esac
done'
    mole_run optimize 'task_rebuild; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 package from outside the repositories was built for something that has changed since"* ]]
    [[ "$output" == *"brokenpkg"* && "$output" == *"libgone.so.1 is missing for app"* ]]
    [[ "$output" != *"okpkg"* && "$output" != *"bundledpkg"* && "$output" != *"runpathpkg"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    # readelf only reads; ldd would run the file's own loader
    [ ! -e "$TEST_ROOT/ldd.log" ]
}

@test "a system with no foreign packages, or a pacman that cannot answer, is not reported as needing rebuilds" {
    fake_command pacman '[[ "$*" == "-Qq pacman" ]] && { echo pacman; exit 0; }; exit 1'
    mole_run optimize 'task_rebuild; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"No packages from outside the repositories"* ]]
    [[ "$output" == *"outcome=unchanged"* ]]
    fake_command pacman 'exit 1'
    mole_run optimize 'task_rebuild; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"outcome=unavailable"* ]]
}

@test "unowned files: generated content is skipped and an unowned folder is reported once" {
    export TEST_ROOT
    mkdir -p "$TEST_ROOT/all"
    printf '%s\n' /usr/bin /usr/bin/owned /usr/share/mime /usr/share/mime/foo /usr/lib/python3.14 > "$TEST_ROOT/all/owned"
    printf '%s\n' \
        "d /usr/bin" "f /usr/bin/owned" "f /usr/bin/handmade" \
        "d /usr/share/mime" "f /usr/share/mime/mime.cache" \
        "d /usr/share/tool" "f /usr/share/tool/a" "f /usr/share/tool/b" "d /usr/share/tool/sub" "f /usr/share/tool/sub/c" \
        "d /usr/lib/python3.14" "f /usr/lib/python3.14/__pycache__/x.pyc" \
        "f /usr/share/icons/Adwaita/icon-theme.cache" "f /usr/lib/locale/locale-archive" "f /usr/lib/udev/hwdb.bin" \
        "f /usr/share/glib-2.0/schemas/gschemas.compiled" "f /usr/lib/gtk-3.0/3.0.0/immodules.cache" \
        "f /usr/share/applications/mimeinfo.cache" "f /usr/share/info/dir" "d /empty-unowned" > "$TEST_ROOT/all/all"
    mole_run optimize 'opt_unowned_collapse "$TEST_ROOT/all" 2> "$TEST_ROOT/total"; echo "total=$(cat "$TEST_ROOT/total")"'
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/bin/handmade"$'\n'"/usr/share/tool"$'\n'"total=4" ]
}

@test "unowned files under /usr and /opt are found root-free and report only" {
    local u="$TEST_ROOT/usr" o="$TEST_ROOT/opt"
    mkdir -p "$u/bin" "$u/lib/modules/6.1.0-arch1" "$u/lib/modules/5.0.0-old" "$u/lib/modules/4.9.0-kept" "$u/lib/python3.14/__pycache__" "$u/share/tool" "$o/app"
    : > "$u/bin/owned"; : > "$u/bin/handmade"; : > "$u/share/tool/a"; : > "$u/share/tool/b"
    : > "$u/lib/modules/6.1.0-arch1/modules.dep"; : > "$u/lib/modules/5.0.0-old/modules.dep"
    : > "$u/lib/modules/4.9.0-kept/vmlinuz"; : > "$u/lib/modules/4.9.0-kept/modules.dep"
    : > "$u/lib/python3.14/__pycache__/x.pyc"; : > "$o/app/run"
    printf '%s\n' "$u/" "$u/share/" "$u/bin/" "$u/bin/owned" "$u/lib/" "$u/lib/modules/" "$u/lib/python3.14/" "$o/" > "$TEST_ROOT/owned.list"
    export OPT_UNOWNED_ROOTS="$u $o" OPT_USR_LIB="$u/lib"
    fake_command uname '[[ "$1" == -r ]] && echo 6.1.0-arch1'
    fake_command pacman '[[ "$*" == "-Qlq" ]] && { cat "'"$TEST_ROOT"'/owned.list"; exit 0; }; echo "pacman $*" >> "'"$TEST_ROOT"'/pacman.log"; exit 1'
    local before
    before=$(tree_state "$TEST_ROOT/usr")$(tree_state "$TEST_ROOT/opt")
    mole_run optimize 'task_unowned; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"5 files under /usr and /opt belong to no package"* ]]
    [[ "$output" == *"usr/bin/handmade"* && "$output" == *"usr/share/tool"* && "$output" == *"usr/lib/modules/5.0.0-old"* && "$output" == *"opt/app"* ]]
    [[ "$output" != *"6.1.0-arch1"* && "$output" != *"4.9.0-kept"* && "$output" != *"__pycache__"* && "$output" != *"usr/bin/owned"* ]]
    [[ "$output" == *"outcome=attention"* ]]
    [ "$(tree_state "$TEST_ROOT/usr")$(tree_state "$TEST_ROOT/opt")" = "$before" ]
    [ ! -e "$TEST_ROOT/pacman.log" ]
}

@test "unowned files: a package list that cannot be read is never read as everything unowned" {
    mkdir -p "$TEST_ROOT/usr/bin"
    : > "$TEST_ROOT/usr/bin/x"
    export OPT_UNOWNED_ROOTS="$TEST_ROOT/usr"
    fake_command pacman 'exit 0'
    mole_run optimize 'task_unowned; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"outcome=unavailable"* ]]
    [[ "$output" != *"belong to no package"* ]]
    fake_command pacman 'exit 1'
    mole_run optimize 'task_unowned; echo "outcome=${OPT_TASK_OUTCOMES[*]}"'
    [[ "$output" == *"outcome=unavailable"* ]]
}

@test "the report-only checks print the same in a dry run and change nothing" {
    local etc="$TEST_ROOT/etc"
    mkdir -p "$etc" "$TEST_ROOT/usr/bin"
    : > "$etc/a.pacnew"; : > "$TEST_ROOT/usr/bin/handmade"
    ln -s /nonexistent "$HOME/dead"
    export OPT_ETC_DIR="$etc" OPT_UNOWNED_ROOTS="$TEST_ROOT/usr" OPT_USR_LIB="$TEST_ROOT/usr/lib"
    fake_command pacman 'case "$*" in "-Qlq") echo /usr/;; "-Qmq") exit 1;; "-Qq pacman") echo pacman;; *) exit 1;; esac'
    local code='for t in task_pacnew task_rebuild task_unowned task_broken_symlinks; do $t; done; echo "${OPT_TASK_OUTCOMES[*]}"'
    mole_run optimize "$code"
    local live="$output"
    mole_run optimize "DRY_RUN=true; $code"
    [ "$status" -eq 0 ]
    [ "${output//[^[:alnum:] ]/}" = "${live//[^[:alnum:] ]/}" ]
    [[ "$output" == *"attention unchanged attention attention"* ]]
    [ -L "$HOME/dead" ] && [ -e "$etc/a.pacnew" ] && [ -e "$TEST_ROOT/usr/bin/handmade" ]
}
