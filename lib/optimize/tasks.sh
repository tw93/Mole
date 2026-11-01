#!/bin/bash
# Mole CLI (Linux) - optimize tasks.
#
# Each task prints its own lines and records exactly one outcome:
#   applied      a change completed, or would complete in a dry run
#   unchanged    inspected, nothing to do
#   skipped      the run context prevented it (an owner is running)
#   unavailable  the tool or data source is not on this system
#   attention    inspected and found something a person should act on
#   failed       an eligible change did not complete
# Nothing here uses sudo. What would need root (a stale pacman lock, TRIM,
# failed system services, orphan packages) is reported with the command to run.

set -euo pipefail

readonly MOLE_OPT_SQLITE_MAX_BYTES=104857600 # 100MB, as on macOS
readonly MOLE_OPT_SQLITE_MIN_RECLAIM=1048576 # compact only when 1MB comes back
OPT_PACMAN_LOCK="${OPT_PACMAN_LOCK:-/var/lib/pacman/db.lck}" # tests point it elsewhere

declare -a OPT_TASK_NAMES=()
declare -a OPT_TASK_OUTCOMES=()
OPT_RECLAIMED_BYTES=0
_OPT_CURRENT=""

opt_line() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $1"
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $1"
    fi
}
opt_warn() { echo -e "  ${YELLOW}${ICON_WARNING}${NC} $1"; }
opt_gray() { echo -e "  ${GRAY}${ICON_EMPTY} $1${NC}"; }
opt_sub() { echo -e "    ${GRAY}${ICON_SUBLIST}${NC} $1"; }
opt_hint() { echo -e "    ${GRAY}$1${NC}"; }
# singular or plural verb phrase for a count
opt_agree() { if [[ "$1" == "1" ]]; then printf '%s' "$2"; else printf '%s' "$3"; fi; }

opt_outcome() {
    OPT_TASK_NAMES+=("$_OPT_CURRENT")
    OPT_TASK_OUTCOMES+=("$1")
}

opt_count() {
    local want="$1" o n=0
    for o in "${OPT_TASK_OUTCOMES[@]}"; do
        [[ "$o" == "$want" ]] && n=$((n + 1))
    done
    echo "$n"
}

# A program a launcher points at exists: an absolute path that is executable,
# or a bare name on PATH or in the directories a desktop session adds to it
# (Omarchy keeps its launch helpers in ~/.local/share/omarchy/bin, which is on
# the session's PATH but not on an ssh login's).
opt_program_exists() {
    local prog="$1" dir
    [[ -n "$prog" ]] || return 0
    if [[ "$prog" == /* ]]; then
        [[ -x "$prog" ]]
        return
    fi
    command -v -- "$prog" > /dev/null 2>&1 && return 0
    for dir in "$MOLE_DATA_HOME/omarchy/bin" "$HOME/.local/bin" /usr/local/bin /usr/bin /bin; do
        [[ -x "$dir/$prog" ]] && return 0
    done
    return 1
}

# Launchers whose TryExec or Exec program is gone. Hidden entries are
# overrides that switch a launcher off, never broken.
opt_broken_launchers() {
    local dir="$1" f try prog
    for f in "$dir"/*.desktop; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        [[ "$(mole_desktop_field "$f" Hidden)" == "true" ]] && continue
        try=$(mole_desktop_field "$f" TryExec)
        prog=$(mole_desktop_exec_path "$f")
        if ! opt_program_exists "$try" || ! opt_program_exists "$prog"; then
            printf '%s\n' "$f"
        fi
    done
}

opt_list_paths() {
    local -a items=("$@")
    local i shown=0
    for i in "${items[@]}"; do
        if ((shown == 5)); then
            opt_sub "and $((${#items[@]} - 5)) more"
            break
        fi
        opt_sub "$(mole_display_path "$i")"
        shown=$((shown + 1))
    done
}

task_fonts() {
    if ! command -v fc-cache > /dev/null 2>&1; then
        opt_gray "Font cache skipped, fontconfig is not installed"
        opt_outcome unavailable
        return
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        opt_line "Font cache refreshed"
        opt_outcome applied
    elif mole_c fc-cache > /dev/null 2>&1; then
        opt_line "Font cache refreshed"
        log_operation optimize REBUILT "$MOLE_CACHE_HOME/fontconfig" "fc-cache"
        opt_outcome applied
    else
        opt_warn "Font cache refresh failed"
        opt_outcome failed
    fi
}

task_launchers() {
    local dir="$MOLE_DATA_HOME/applications" rc_db=0 have_db=false
    if [[ ! -d "$dir" || -L "$dir" ]]; then
        opt_line "No personal launchers to refresh"
        opt_outcome unchanged
        return
    fi
    if command -v update-desktop-database > /dev/null 2>&1; then
        have_db=true
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            mole_c update-desktop-database -q "$dir" > /dev/null 2>&1 || rc_db=$?
        fi
        if [[ $rc_db -eq 0 ]]; then
            opt_line "App launcher index refreshed"
            [[ "${DRY_RUN:-false}" == "true" ]] || log_operation optimize REBUILT "$dir/mimeinfo.cache" "update-desktop-database"
        else
            opt_warn "App launcher index refresh failed"
        fi
    fi
    local -a broken=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && broken+=("$f")
    done < <(opt_broken_launchers "$dir")
    if [[ ${#broken[@]} -gt 0 ]]; then
        opt_warn "$(mole_count_label "${#broken[@]}" launcher) $(opt_agree "${#broken[@]}" "points at a program that is" "point at programs that are") gone"
        opt_list_paths "${broken[@]}"
    fi
    # A failure outranks a finding, so the summary and the exit code carry it.
    if [[ $rc_db -ne 0 ]]; then
        opt_outcome failed
    elif [[ ${#broken[@]} -gt 0 ]]; then
        opt_outcome attention
    elif [[ "$have_db" == true ]]; then
        opt_outcome applied
    else
        opt_line "Personal launchers all healthy"
        opt_outcome unchanged
    fi
}

# Program names a Hyprland config starts: `exec-once = cmd` and `exec = cmd`
# in ~/.config/hypr/*.conf, and the string passed to launch_on_start, exec_cmd
# or launch in the Lua config Omarchy now writes. Prints file<TAB>line<TAB>cmd.
opt_hypr_commands() {
    local dir="$MOLE_CONFIG_HOME/hypr" f
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.conf; do
        [[ -f "$f" ]] || continue
        awk '
            /^[ \t]*#/ { next }
            /^[ \t]*exec(-once)?[ \t]*=/ {
                cmd = $0; sub(/^[^=]*=[ \t]*/, "", cmd); sub(/[ \t]+#.*$/, "", cmd)
                if (cmd != "") printf "%s\t%d\t%s\n", FILENAME, FNR, cmd
            }' "$f" 2> /dev/null || true
    done
    for f in "$dir"/*.lua; do
        [[ -f "$f" ]] || continue
        awk '
            /^[ \t]*--/ { next }
            {
                line = $0
                while (match(line, /(launch_on_start|exec_cmd|launch)\([ \t]*"[^"]*"/)) {
                    cmd = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", cmd); sub(/"$/, "", cmd)
                    if (cmd != "") printf "%s\t%d\t%s\n", FILENAME, FNR, cmd
                    line = substr(line, RSTART + RLENGTH)
                }
            }' "$f" 2> /dev/null || true
    done
}

# The program a shell command line starts, when that can be told without
# running a shell: no expansions, pipes, lists or redirections. Leading env
# assignments and the uwsm / app2unit launch wrappers are skipped. Prints
# nothing when it cannot tell.
opt_command_program() {
    local cmd="$1" w i=0
    [[ "$cmd" == *[\$\`\;\|\&\(\)\<\>\'\"\\]* ]] && return 0
    local -a words=()
    read -ra words <<< "$cmd"
    while ((i < ${#words[@]})); do
        w="${words[i]}"
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= || "$w" == exec || "$w" == -- ]]; then
            :
        elif [[ "$w" == uwsm && "${words[i + 1]:-}" == app ]]; then
            i=$((i + 1))
        elif [[ "$w" == uwsm-app || "$w" == app2unit ]]; then
            :
        elif [[ "$w" == -* && $i -gt 0 ]]; then
            :
        else
            printf '%s' "$w"
            return 0
        fi
        i=$((i + 1))
    done
    return 0
}

# The program of each ExecStart= in the user's own unit files, with
# systemd's prefixes (-@:+!) removed; specifiers and variables are skipped.
opt_unit_programs() {
    local f
    for f in "$MOLE_CONFIG_HOME/systemd/user"/*.service; do
        [[ -f "$f" ]] || continue
        awk '
            /^[ \t]*ExecStart(Pre|Post)?[ \t]*=/ {
                v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/^[-@:+!]+/, "", v)
                split(v, w, /[ \t]+/)
                if (w[1] != "" && w[1] !~ /[%$]/) printf "%s\t%s\n", FILENAME, w[1]
            }' "$f" 2> /dev/null || true
    done
}

task_autostart() {
    local dir="$MOLE_CONFIG_HOME/autostart" f checked=0
    local -a broken=() hypr=() units=() links=()
    if [[ -d "$dir" && ! -L "$dir" ]]; then
        for f in "$dir"/*.desktop; do
            [[ -f "$f" && ! -L "$f" ]] || continue
            [[ "$(mole_desktop_field "$f" Hidden)" == "true" ]] && continue
            checked=$((checked + 1))
            if ! opt_program_exists "$(mole_desktop_field "$f" TryExec)" ||
                ! opt_program_exists "$(mole_desktop_exec_path "$f")"; then
                broken+=("$f")
            fi
        done
    fi
    local file line cmd prog
    while IFS=$'\t' read -r file line cmd; do
        [[ -n "$cmd" ]] || continue
        checked=$((checked + 1))
        prog=$(opt_command_program "$cmd")
        [[ -n "$prog" ]] || continue
        opt_program_exists "$prog" || hypr+=("$(mole_display_path "$file"):$line  ${GRAY}$prog${NC}")
    done < <(opt_hypr_commands)
    while IFS=$'\t' read -r file prog; do
        [[ -n "$prog" ]] || continue
        checked=$((checked + 1))
        opt_program_exists "$prog" || units+=("$(mole_display_path "$file")  ${GRAY}$prog${NC}")
    done < <(opt_unit_programs)
    # An enablement link whose unit file is gone: systemd logs an error for
    # it at every login.
    for f in "$MOLE_CONFIG_HOME/systemd/user"/*.wants/*; do
        [[ -L "$f" && ! -e "$f" ]] && links+=("$f")
    done
    if [[ ${#broken[@]} -gt 0 ]]; then
        opt_warn "$(mole_count_label "${#broken[@]}" "autostart entry" "autostart entries") $(opt_agree "${#broken[@]}" "starts a program that is" "start programs that are") gone"
        opt_list_paths "${broken[@]}"
    fi
    if [[ ${#hypr[@]} -gt 0 ]]; then
        opt_warn "$(mole_count_label "${#hypr[@]}" "Hyprland start command") $(opt_agree "${#hypr[@]}" "runs a program that is" "run programs that are") gone"
        local h
        for h in "${hypr[@]:0:5}"; do opt_sub "$h"; done
        [[ ${#hypr[@]} -gt 5 ]] && opt_sub "and $((${#hypr[@]} - 5)) more"
    fi
    if [[ ${#units[@]} -gt 0 ]]; then
        opt_warn "$(mole_count_label "${#units[@]}" "user service") $(opt_agree "${#units[@]}" "starts a program that is" "start programs that are") gone"
        local u
        for u in "${units[@]:0:5}"; do opt_sub "$u"; done
        [[ ${#units[@]} -gt 5 ]] && opt_sub "and $((${#units[@]} - 5)) more"
    fi
    if [[ ${#links[@]} -gt 0 ]]; then
        opt_warn "$(mole_count_label "${#links[@]}" "user service link") $(opt_agree "${#links[@]}" "points at a unit that is" "point at units that are") gone"
        opt_list_paths "${links[@]}"
        opt_hint "Remove a link with rm, or reinstall the program it belonged to"
    fi
    if [[ $((${#broken[@]} + ${#hypr[@]} + ${#units[@]} + ${#links[@]})) -gt 0 ]]; then
        opt_outcome attention
    elif ((checked > 0)); then
        opt_line "Autostart entries all healthy ($checked checked)"
        opt_outcome unchanged
    else
        opt_line "No personal autostart entries"
        opt_outcome unchanged
    fi
}

# Files directly in the home folder or ~/.config that root owns (left by an
# app once run with sudo): the user's own apps cannot update them. Reported
# with the command that gives them back; Mole never changes ownership.
task_home_ownership() {
    local uid="${OPT_FOREIGN_UID:-0}" p
    local -a hits=()
    local -A seen=()
    while IFS= read -r -d '' p; do
        [[ -n "${seen[$p]:-}" ]] && continue
        seen[$p]=1
        hits+=("$p")
    done < <(find "$HOME" "$MOLE_CONFIG_HOME" -mindepth 1 -maxdepth 1 -uid "$uid" ! -type l -print0 2> /dev/null)
    if [[ ${#hits[@]} -eq 0 ]]; then
        opt_line "No root-owned files in your home folder"
        opt_outcome unchanged
        return
    fi
    opt_warn "$(mole_count_label "${#hits[@]}" item) in your home folder $(opt_agree "${#hits[@]}" "is" "are") owned by root, so your apps cannot change $(opt_agree "${#hits[@]}" "it" "them")"
    opt_sub "$(mole_display_path "${hits[0]}")"
    opt_hint "Give it back with sudo chown -R $(id -un): \"${hits[0]}\""
    opt_outcome attention
}

# Icon themes in ~/.local/share/icons that carry an index.theme get their
# icon cache rebuilt, so icons added or removed by hand show up.
task_icon_cache() {
    local base="$MOLE_DATA_HOME/icons" t
    local -a themes=()
    if [[ -d "$base" && ! -L "$base" ]]; then
        for t in "$base"/*/; do
            t="${t%/}"
            [[ -d "$t" && ! -L "$t" && -f "$t/index.theme" ]] && themes+=("$t")
        done
    fi
    if [[ ${#themes[@]} -eq 0 ]]; then
        opt_line "No personal icon themes"
        opt_outcome unchanged
        return
    fi
    if ! command -v gtk-update-icon-cache > /dev/null 2>&1; then
        opt_gray "Icon cache skipped, gtk-update-icon-cache is not installed"
        opt_outcome unavailable
        return
    fi
    local failed=0
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        for t in "${themes[@]}"; do
            if mole_c gtk-update-icon-cache -q -f "$t" > /dev/null 2>&1; then
                log_operation optimize REBUILT "$t/icon-theme.cache" "gtk-update-icon-cache"
            else
                failed=$((failed + 1))
            fi
        done
    fi
    if ((failed > 0)); then
        opt_warn "Icon cache refresh failed for $(mole_count_label "$failed" theme)"
        opt_outcome failed
    else
        opt_line "Icon cache refreshed for $(mole_count_label "${#themes[@]}" theme)"
        opt_outcome applied
    fi
}

# systemd is the running init (sd_booted's test); a container or another init
# answers nothing useful, which is "unavailable", never "healthy".
opt_systemd_running() { command -v systemctl > /dev/null 2>&1 && [[ -d "${OPT_SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]; }

# Unit names from `systemctl [--user] --failed`; returns 2 when systemd cannot
# be asked (not running, or no user bus in an ssh login).
opt_failed_units() {
    local out
    opt_systemd_running || return 2
    out=$(mole_c systemctl "$@" --failed --no-legend --plain --no-pager 2> /dev/null) || return 2
    awk 'NF { print $1 }' <<< "$out"
}

task_services() {
    local -a sys=() usr=()
    local unit rc_sys=0 rc_usr=0 out
    out=$(opt_failed_units) || rc_sys=$?
    [[ $rc_sys -eq 0 && -n "$out" ]] && mapfile -t sys <<< "$out"
    out=$(opt_failed_units --user) || rc_usr=$?
    [[ $rc_usr -eq 0 && -n "$out" ]] && mapfile -t usr <<< "$out"
    if [[ $((${#sys[@]} + ${#usr[@]})) -gt 0 ]]; then
        opt_warn "$(mole_count_label $((${#sys[@]} + ${#usr[@]})) service) failed"
        for unit in "${sys[@]}"; do opt_sub "$unit  ${GRAY}systemctl status $unit${NC}"; done
        for unit in "${usr[@]}"; do opt_sub "$unit  ${GRAY}systemctl --user status $unit${NC}"; done
        [[ $rc_sys -eq 0 ]] || opt_gray "System services could not be checked"
        [[ $rc_usr -eq 0 ]] || opt_gray "User services could not be checked"
        opt_outcome attention
    elif [[ $rc_sys -ne 0 && $rc_usr -ne 0 ]]; then
        opt_gray "Service check skipped, systemd is not reachable"
        opt_outcome unavailable
    elif [[ $rc_sys -ne 0 ]]; then
        # Half an answer is not a healthy system.
        opt_gray "No failed user services, system services could not be checked"
        opt_outcome unavailable
    elif [[ $rc_usr -ne 0 ]]; then
        opt_line "No failed system services, user services not reachable"
        opt_outcome unchanged
    else
        opt_line "No failed services"
        opt_outcome unchanged
    fi
}

task_orphans() {
    local out rc=0
    out=$(mole_c pacman -Qtdq 2> /dev/null) || rc=$?
    # pacman exits 1 both for "no match" and for a database it cannot read;
    # only a database that answers another query makes the empty list true.
    if [[ $rc -eq 1 && -z "$out" ]] && mole_c pacman -Qq pacman > /dev/null 2>&1; then
        opt_line "No orphan packages"
        opt_outcome unchanged
        return
    fi
    if [[ $rc -ne 0 || -z "$out" ]]; then
        opt_gray "Orphan check skipped, pacman could not be asked"
        opt_outcome unavailable
        return
    fi
    local -a pkgs=()
    mapfile -t pkgs <<< "$out"
    local list="${pkgs[*]:0:6}"
    [[ ${#pkgs[@]} -gt 6 ]] && list+=" and $((${#pkgs[@]} - 6)) more"
    opt_warn "$(mole_count_label "${#pkgs[@]}" package) $(opt_agree "${#pkgs[@]}" "was installed as a dependency that nothing needs" "were installed as dependencies that nothing needs") any more"
    opt_sub "$list"
    opt_hint "Review with pacman -Qtd, remove with sudo pacman -Rns <name>"
    opt_outcome attention
}

# 0 when any process with one of these exact names runs, whoever owns it
# (pacman runs as root under sudo), 1 when none does, 2 when it cannot tell.
opt_any_process_running() {
    local name probe rc=1
    command -v pgrep > /dev/null 2>&1 || return 2
    for name in "$@"; do
        probe=0
        pgrep -x -- "$name" > /dev/null 2>&1 || probe=$?
        [[ $probe -eq 0 ]] && return 0
        [[ $probe -eq 1 ]] || rc=2
    done
    return "$rc"
}

task_pacman_lock() {
    local lock="$OPT_PACMAN_LOCK" rc=0
    if [[ ! -e "$lock" ]]; then
        opt_line "Package database not locked"
        opt_outcome unchanged
        return
    fi
    opt_any_process_running pacman yay paru pamac pamac-daemon packagekitd makepkg || rc=$?
    if [[ $rc -eq 0 ]]; then
        opt_line "Package database locked by a running package manager"
        opt_outcome unchanged
        return
    fi
    if [[ $rc -ne 1 ]]; then
        opt_gray "Package database is locked, and Mole cannot tell whether a package manager is running"
        opt_outcome unavailable
        return
    fi
    opt_warn "pacman's lock is left over from an interrupted run, so pacman refuses to start"
    opt_hint "Make sure no update is running, then remove it with sudo rm $lock"
    opt_outcome attention
}

# browser label|process names|profile root|database files in a profile
# Chromium family: the history, icon, autofill, top sites and shortcut
# databases; Cookies and Login Data are never opened. Gecko family (Firefox,
# Zen, Thunderbird): every *.sqlite at the top of a profile except
# cookies.sqlite, as Firefox's own idle maintenance compacts them; per-site
# storage below the profile is not read. Newer Firefox keeps profiles under
# ~/.config/mozilla/firefox, older under ~/.mozilla/firefox; both are read.
opt_browser_specs() {
    local c="$MOLE_CONFIG_HOME" chromium_dbs="History,Favicons,Web Data,Top Sites,Shortcuts" gecko="*.sqlite"
    cat << SPECS
Chromium|chromium|$c/chromium|$chromium_dbs
Google Chrome|chrome|$c/google-chrome|$chromium_dbs
Brave|brave|$c/BraveSoftware/Brave-Browser|$chromium_dbs
Vivaldi|vivaldi-bin|$c/vivaldi|$chromium_dbs
Microsoft Edge|msedge|$c/microsoft-edge|$chromium_dbs
Firefox|firefox,firefox-esr,firefox-bin|$HOME/.mozilla/firefox|$gecko
Firefox|firefox,firefox-esr,firefox-bin|$c/mozilla/firefox|$gecko
Zen|zen,zen-bin|$HOME/.zen|$gecko
Thunderbird|thunderbird,thunderbird-bin|$HOME/.thunderbird|$gecko
SPECS
}

# Database files of one browser: Chromium keeps them in Default and Profile N,
# Firefox, Zen and Thunderbird in one folder per profile.
opt_browser_dbs() {
    local root="$1" names="$2" profile name f
    local -a files=()
    IFS=',' read -ra files <<< "$names"
    for profile in "$root"/*/; do
        profile="${profile%/}"
        [[ -d "$profile" && ! -L "$profile" ]] || continue
        if [[ "$names" == "*.sqlite" ]]; then
            for f in "$profile"/*.sqlite; do
                [[ "${f##*/}" == cookies.sqlite ]] && continue
                [[ -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f"
            done
            continue
        fi
        for name in "${files[@]}"; do
            [[ -f "$profile/$name" && ! -L "$profile/$name" ]] && printf '%s\n' "$profile/$name"
        done
    done
    return 0
}

# A file path as an SQLite URI path (RFC 3986 escaping of the characters a
# URI reserves; Chromium profiles are named "Profile 1").
opt_sqlite_uri() {
    local path="$1"
    path="${path//%/%25}"
    path="${path// /%20}"
    path="${path//\?/%3F}"
    path="${path//#/%23}"
    printf 'file:%s?mode=ro&immutable=1' "$path"
}

# Free bytes VACUUM would give back and the integrity verdict, read without
# touching the file: immutable=1 opens no lock, -wal or -shm (a plain
# read-only open of a WAL database leaves both behind). Prints "<bytes> ok"
# or "<bytes> damaged"; fails when the file is not a readable SQLite database.
opt_sqlite_inspect() {
    local out page free check
    out=$(mole_c sqlite3 -batch "$(opt_sqlite_uri "$1")" 'PRAGMA page_size; PRAGMA freelist_count; PRAGMA quick_check;' 2> /dev/null) || return 1
    page=$(sed -n 1p <<< "$out")
    free=$(sed -n 2p <<< "$out")
    check=$(sed -n '3,$p' <<< "$out")
    [[ "$page" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]] || return 1
    if [[ "$check" == "ok" ]]; then
        echo "$((page * free)) ok"
    else
        echo "$((page * free)) damaged"
    fi
}

task_browser_dbs() {
    if ! command -v sqlite3 > /dev/null 2>&1; then
        opt_gray "Browser databases skipped, sqlite3 is not installed"
        opt_outcome unavailable
        return
    fi
    local label owners root names db size reclaim verdict rc after info
    local found=0 compact=0 done_count=0 failed=0 unreadable=0 skipped_any=false
    local -a open=() unsure=() names_list=()
    while IFS='|' read -r label owners root names; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        local -a dbs=()
        mapfile -t dbs < <(opt_browser_dbs "$root" "$names")
        [[ ${#dbs[@]} -gt 0 && -n "${dbs[0]}" ]] || continue
        IFS=',' read -ra names_list <<< "$owners"
        for db in "${dbs[@]}"; do
            # Asked again before every file: a browser opened mid-run keeps
            # the rest of its files untouched.
            rc=0
            mole_process_running "${names_list[@]}" || rc=$?
            if [[ $rc -ne 1 ]]; then
                if [[ $rc -eq 0 ]]; then
                    [[ " ${open[*]-} " == *" $label "* ]] || open+=("$label")
                else
                    [[ " ${unsure[*]-} " == *" $label "* ]] || unsure+=("$label")
                fi
                skipped_any=true
                break
            fi
            found=$((found + 1))
            size=$(stat -c %s -- "$db" 2> /dev/null) || {
                unreadable=$((unreadable + 1))
                continue
            }
            if ((size > MOLE_OPT_SQLITE_MAX_BYTES)); then
                compact=$((compact + 1))
                continue
            fi
            info=$(opt_sqlite_inspect "$db") || {
                unreadable=$((unreadable + 1))
                continue
            }
            reclaim="${info% *}"
            verdict="${info#* }"
            if ((reclaim < MOLE_OPT_SQLITE_MIN_RECLAIM)); then
                compact=$((compact + 1))
                continue
            fi
            # A damaged database is left for the browser to repair.
            if [[ "$verdict" != "ok" ]]; then
                failed=$((failed + 1))
                continue
            fi
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                done_count=$((done_count + 1))
                OPT_RECLAIMED_BYTES=$((OPT_RECLAIMED_BYTES + reclaim))
                continue
            fi
            if mole_c sqlite3 -batch -cmd '.timeout 2000' "$db" 'VACUUM;' > /dev/null 2>&1; then
                after=$(stat -c %s -- "$db" 2> /dev/null || echo "$size")
                ((size > after)) && OPT_RECLAIMED_BYTES=$((OPT_RECLAIMED_BYTES + size - after))
                done_count=$((done_count + 1))
                log_operation optimize REBUILT "$db" "sqlite VACUUM, $(bytes_to_human "$size") before, $(bytes_to_human "$after") after"
            else
                failed=$((failed + 1))
            fi
        done
    done < <(opt_browser_specs)

    local r
    for r in "${open[@]}"; do
        opt_gray "$r is open, its databases are left alone"
    done
    for r in "${unsure[@]}"; do
        opt_gray "$r may be open, its databases are left alone"
    done
    if ((done_count > 0)); then
        opt_line "Compacted $(mole_count_label "$done_count" database), $(bytes_to_human "$OPT_RECLAIMED_BYTES") reclaimed"
    fi
    ((compact > 0)) && opt_line "Already compact for $(mole_count_label "$compact" database)"
    ((unreadable > 0)) && opt_gray "$(mole_count_label "$unreadable" database) could not be read and $(opt_agree "$unreadable" "was" "were") left alone"
    ((failed > 0)) && opt_warn "$(mole_count_label "$failed" database) could not be compacted and $(opt_agree "$failed" "was" "were") left as $(opt_agree "$failed" "it was" "they were")"
    if ((failed > 0)); then
        opt_outcome failed
    elif ((done_count > 0)); then
        opt_outcome applied
    elif ((compact > 0)); then
        opt_outcome unchanged
    elif [[ "$skipped_any" == true ]] || ((unreadable > 0)); then
        opt_outcome skipped
    elif ((found == 0)); then
        opt_line "No browser databases found"
        opt_outcome unchanged
    else
        opt_outcome unchanged
    fi
}

task_trim() {
    if ! command -v findmnt > /dev/null 2>&1 || ! command -v lsblk > /dev/null 2>&1; then
        opt_gray "TRIM check skipped, findmnt or lsblk is missing"
        opt_outcome unavailable
        return
    fi
    local src opts rota gran type timer
    src=$(findmnt -no SOURCE / 2> /dev/null) || src=""
    src="${src%%\[*}"
    opts=$(findmnt -no OPTIONS / 2> /dev/null) || opts=""
    if [[ "$src" != /dev/* ]]; then
        opt_line "Root is not on a local disk, TRIM does not apply"
        opt_outcome unchanged
        return
    fi
    rota=$(lsblk -ndo ROTA -- "$src" 2> /dev/null | tr -d ' ') || rota=""
    gran=$(lsblk -ndo DISC-GRAN -- "$src" 2> /dev/null | tr -d ' ') || gran=""
    type=$(lsblk -ndo TYPE -- "$src" 2> /dev/null | tr -d ' ') || type=""
    if [[ "$rota" == "1" ]]; then
        opt_line "Root disk is not an SSD, TRIM does not apply"
        opt_outcome unchanged
    elif [[ -z "$gran" || "$gran" == "0B" ]]; then
        # An encrypted root passes TRIM through only when it was opened with
        # discards allowed, a privacy trade-off Mole leaves to the user.
        if [[ "$type" == crypt ]]; then
            opt_line "Encrypted root does not pass TRIM to the SSD"
        else
            opt_line "Root disk does not accept TRIM"
        fi
        opt_outcome unchanged
    elif [[ ",$opts," == *",discard"* ]]; then
        opt_line "Continuous TRIM is on"
        opt_outcome unchanged
    elif ! opt_systemd_running; then
        opt_gray "TRIM schedule unknown, systemd is not running"
        opt_outcome unavailable
    else
        timer=$(mole_c systemctl is-enabled fstrim.timer 2> /dev/null || true)
        if [[ "$timer" == "enabled" ]]; then
            opt_line "Weekly TRIM is on"
            opt_outcome unchanged
        else
            opt_warn "TRIM is off for this SSD, so it slows down as it fills"
            opt_hint "Turn on weekly TRIM with sudo systemctl enable --now fstrim.timer"
            opt_outcome attention
        fi
    fi
}

task_power() {
    if ! opt_systemd_running; then
        opt_gray "Power check skipped, systemd is not running"
        opt_outcome unavailable
        return
    fi
    local unit state
    local -a enabled=()
    # tuned-ppd is tuned's power-profiles-daemon shim and needs tuned, so the
    # pair counts as one manager.
    for unit in tlp power-profiles-daemon auto-cpufreq tuned; do
        state=$(mole_c systemctl is-enabled "$unit.service" 2> /dev/null || true)
        [[ "$state" == "enabled" ]] && enabled+=("$unit")
    done
    if [[ ${#enabled[@]} -ge 2 ]]; then
        local names
        if [[ ${#enabled[@]} -eq 2 ]]; then
            names="${enabled[0]} and ${enabled[1]} are both"
        else
            names="$(printf '%s, ' "${enabled[@]:0:${#enabled[@]}-1}")and ${enabled[-1]} are all"
        fi
        opt_warn "$names enabled and override each other's settings"
        opt_hint "Keep one, for example sudo systemctl disable --now ${enabled[1]}"
        opt_outcome attention
    elif [[ ${#enabled[@]} -eq 1 ]]; then
        opt_line "Power managed by ${enabled[0]}"
        opt_outcome unchanged
    else
        opt_line "No conflicting power managers"
        opt_outcome unchanged
    fi
}
