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
