#!/bin/bash
# Mole CLI (Linux) - uninstall: pick apps, let their package manager remove
# them (with its own confirmation), then move exact-ID leftovers to Trash.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/lib/uninstall/inventory.sh"
mole_refuse_root

DRY_RUN=false
LIST_ONLY=false
WITH_DATA=false
ASSUME_YES=false
declare -a NAMES=()
for arg in "$@"; do
    case "$arg" in
        --dry-run | -n) DRY_RUN=true ;;
        --list) LIST_ONLY=true ;;
        --with-data) WITH_DATA=true ;;
        --yes | -y) ASSUME_YES=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            echo "Usage: mo uninstall [OPTIONS] [APP_NAME ...]"
            echo ""
            echo "Remove apps and their leftover files. Packages are removed by pacman, apt,"
            echo "flatpak or snap; the first three ask for their own confirmation. Leftovers"
            echo "go to the Trash."
            echo ""
            echo "Examples:"
            echo "  mo uninstall                   Open interactive app selector"
            echo "  mo uninstall spotify           Uninstall Spotify"
            echo "  mo uninstall --dry-run zoom    Preview what would be removed"
            echo "  mo uninstall --list            List apps and the names mo uninstall accepts"
            echo ""
            echo "Options:"
            echo "  --list            List installed apps with the name mo uninstall accepts (JSON when piped)"
            echo "  --dry-run, -n     Preview without making changes"
            echo "  --with-data       Start with settings and data selected (browser profiles stay unselected)"
            echo "  --yes, -y         Do not ask Mole's confirmation (needed outside a terminal)"
            echo "  --debug           Show detailed operation logs"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg" >&2
            echo "Use 'mo uninstall --help' for supported options." >&2
            exit 1
            ;;
        *) NAMES+=("$arg") ;;
    esac
done
export DRY_RUN

trap 'stop_inline_spinner; show_cursor; mole_sudo_end; echo ""; exit 130' INT TERM

declare -a APP_KIND=() APP_ID=() APP_NAME=() APP_KB=() APP_DESKTOPS=() APP_EXEC=() APP_SCOPE=() APP_LAST=()
declare -a SELECTED=() RUNNING=() REMOVED=()

kind_label() {
    case "$1" in
        pacman) echo "pacman" ;;
        aur) echo "AUR" ;;
        apt) echo "apt" ;;
        snap) echo "Snap" ;;
        flatpak) echo "Flatpak" ;;
        webapp) echo "Web app" ;;
        tui) echo "TUI" ;;
        appimage) echo "AppImage" ;;
        orphan) echo "Leftover" ;;
    esac
}

# Newest sign of use, as an epoch (0 when nothing tells): the newest mtime in
# the app's own config, data, state and cache folders, and the atime of its
# program file when that atime is later than the file's ctime (the install).
# On a noatime mount, or a program never run since install, atime does not
# pass its ctime, so it says nothing instead of saying "installed = used".
app_last_used() {
    local i="$1" d base newest=0 t prog stamps
    local -a dirs=() ids=()
    case "${APP_KIND[i]}" in
        flatpak | orphan) dirs+=("$HOME/.var/app/${APP_ID[i]}") ;;
        snap) [[ -d "$HOME/snap/${APP_ID[i]}" && ! -L "$HOME/snap/${APP_ID[i]}" ]] && dirs+=("$HOME/snap/${APP_ID[i]}") ;;
        webapp | tui) ;;
        *)
            ids=("${APP_ID[i]}")
            IFS=',' read -ra base <<< "${APP_DESKTOPS[i]}"
            ids+=("${base[@]}")
            for d in "${ids[@]}"; do
                [[ "$d" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
                mole_shared_leftover_name "$d" && continue
                for base in "$MOLE_CONFIG_HOME" "$MOLE_DATA_HOME" "$MOLE_STATE_HOME" "$MOLE_CACHE_HOME" "$HOME/"; do
                    if [[ "$base" == "$HOME/" ]]; then
                        [[ -d "$HOME/.$d" && ! -L "$HOME/.$d" ]] && dirs+=("$HOME/.$d")
                    else
                        [[ -d "$base/$d" && ! -L "$base/$d" ]] && dirs+=("$base/$d")
                    fi
                done
            done
            while IFS= read -r d; do
                [[ -n "$d" && -d "$d" && ! -L "$d" ]] && dirs+=("$d")
            done < <(mole_app_alias_paths "${APP_ID[i]}")
            ;;
    esac
    if [[ ${#dirs[@]} -gt 0 ]]; then
        t=$(find "${dirs[@]}" -maxdepth 1 -printf '%T@\n' 2> /dev/null | sort -rn | head -1) || t=""
        t="${t%%.*}"
        [[ "$t" =~ ^[0-9]+$ ]] && ((t > newest)) && newest=$t
    fi
    prog=""
    case "${APP_KIND[i]}" in
        appimage) prog="${APP_EXEC[i]}" ;;
        pacman | aur | apt)
            if [[ -n "${APP_EXEC[i]}" ]]; then
                prog=$(command -v -- "${APP_EXEC[i]}" 2> /dev/null) || prog=""
            fi
            ;;
    esac
    if [[ "$prog" == /* && -f "$prog" ]]; then
        stamps=$(stat -L -c '%X %Z' -- "$prog" 2> /dev/null) || stamps=""
        if [[ "$stamps" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
            local at="${BASH_REMATCH[1]}" ct="${BASH_REMATCH[2]}"
            ((at > ct + 60 && at > newest)) && newest=$at
        fi
    fi
    echo "$newest"
}

# Today, Yesterday, 3d ago, 2w ago, 5m ago, 1y ago, as Mole CLI (macOS) shows.
last_used_label() {
    local epoch="${1:-0}" now days
    [[ "$epoch" =~ ^[0-9]+$ && "$epoch" -gt 0 ]] || {
        echo "Unknown"
        return 0
    }
    now=$(date +%s)
    days=$(((now - epoch) / 86400))
    ((days < 0)) && days=0
    if ((days == 0)); then
        echo "Today"
    elif ((days == 1)); then
        echo "Yesterday"
    elif ((days < 7)); then
        echo "${days}d ago"
    elif ((days < 30)); then
        echo "$((days / 7))w ago"
    elif ((days < 365)); then
        echo "$((days / 30))m ago"
    else
        echo "$((days / 365))y ago"
    fi
}

load_apps() {
    local kind id name kb desktops exec scope i
    APP_KIND=() APP_ID=() APP_NAME=() APP_KB=() APP_DESKTOPS=() APP_EXEC=() APP_SCOPE=() APP_LAST=()
    while IFS=$'\t' read -r kind id name kb desktops exec scope; do
        [[ -n "$id" ]] || continue
        APP_KIND+=("$kind")
        APP_ID+=("$id")
        APP_NAME+=("$name")
        APP_KB+=("${kb:-0}")
        APP_DESKTOPS+=("$desktops")
        APP_EXEC+=("$exec")
        APP_SCOPE+=("$scope")
    done < <(mole_list_apps)
    for i in "${!APP_ID[@]}"; do
        APP_LAST+=("$(app_last_used "$i")")
    done
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# A table in a terminal; JSON when stdout is piped, as Mole CLI (macOS) does.
print_list() {
    local i
    if [[ -t 1 ]]; then
        printf '%-34s %-30s %-8s %-9s %s\n' "NAME" "ACCEPTS" "SOURCE" "SIZE" "LAST USED"
        for i in "${!APP_ID[@]}"; do
            printf '%-34s %-30s %-8s %-9s %s\n' "${APP_NAME[i]:0:34}" "${APP_ID[i]:0:30}" "$(kind_label "${APP_KIND[i]}")" \
                "$(bytes_to_human_kb "${APP_KB[i]}")" "$(last_used_label "${APP_LAST[i]}")"
        done
        return 0
    fi
    local first=1
    printf '['
    for i in "${!APP_ID[@]}"; do
        if [[ $first -eq 1 ]]; then
            first=0
            printf '\n'
        else
            printf ',\n'
        fi
        printf '  {"name": "%s", "uninstall_name": "%s", "source": "%s", "kind": "%s", "size": "%s", "size_kb": %s, "last_used": "%s", "last_used_epoch": %s}' \
            "$(json_escape "${APP_NAME[i]}")" "$(json_escape "${APP_ID[i]}")" "$(kind_label "${APP_KIND[i]}")" \
            "${APP_KIND[i]}" "$(bytes_to_human_kb "${APP_KB[i]}")" "${APP_KB[i]}" \
            "$(last_used_label "${APP_LAST[i]}")" "${APP_LAST[i]:-0}"
    done
    [[ $first -eq 0 ]] && printf '\n'
    printf ']\n'
}

# Exact, case-insensitive match: an app ID first, then a display name. More
# than one app at the same level is refused, never guessed.
match_names() {
    local want i lw lid lname
    local -a by_id=() by_name=() hits=()
    for want in "${NAMES[@]}"; do
        mole_ascii_lowercase lw "$want"
        by_id=()
        by_name=()
        for i in "${!APP_ID[@]}"; do
            mole_ascii_lowercase lid "${APP_ID[i]}"
            mole_ascii_lowercase lname "${APP_NAME[i]}"
            [[ "$lw" == "$lid" ]] && by_id+=("$i")
            [[ "$lw" == "$lname" ]] && by_name+=("$i")
        done
        if [[ ${#by_id[@]} -gt 0 ]]; then
            hits=("${by_id[@]}")
        else
            hits=("${by_name[@]+"${by_name[@]}"}")
        fi
        if [[ ${#hits[@]} -eq 0 || -z "${hits[0]:-}" ]]; then
            log_error "No installed app named \"$want\". Run mo uninstall --list to see the accepted names."
            return 1
        fi
        if [[ ${#hits[@]} -gt 1 ]]; then
            log_error "\"$want\" matches more than one app; name the one you mean:"
            for i in "${hits[@]}"; do
                echo "  mo uninstall ${APP_ID[i]}    # ${APP_NAME[i]}, $(kind_label "${APP_KIND[i]}")" >&2
            done
            return 1
        fi
        SELECTED+=("${hits[0]}")
    done
}

choose_apps() {
    local -a rows=() sizes=() names=() epochs=()
    local i width=32
    for i in "${!APP_ID[@]}"; do
        local name
        name=$(truncate_by_display_width "${APP_NAME[i]}" "$width")
        local pad=$((width - $(get_display_width "$name")))
        ((pad < 0)) && pad=0
        rows+=("$(printf '%s%*s %9s | %-10s %s' "$name" "$pad" "" "$(bytes_to_human_kb "${APP_KB[i]}")" \
            "$(last_used_label "${APP_LAST[i]}")" "$(kind_label "${APP_KIND[i]}")")")
        sizes+=("${APP_KB[i]}")
        epochs+=("${APP_LAST[i]:-0}")
        names+=("${APP_NAME[i]} ${APP_ID[i]}")
    done
    local MOLE_MENU_META_SIZEKB MOLE_MENU_META_EPOCHS MOLE_MENU_FILTER_NAMES MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    MOLE_MENU_META_SIZEKB=$(IFS=,; printf '%s' "${sizes[*]}")
    MOLE_MENU_META_EPOCHS=$(IFS=,; printf '%s' "${epochs[*]}")
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${names[@]}")
    # Keys typed during the scan must not reach the selector: a queued Enter
    # would pick the highlighted app and walk into removal (Mole #726).
    drain_pending_input
    local rc=0
    paginated_multi_select "Select Apps to Remove" "${rows[@]}" || rc=$?
    [[ $rc -eq 0 ]] || return 1
    local -a picked=()
    IFS=',' read -ra picked <<< "${MOLE_SELECTION_RESULT:-}"
    for i in "${picked[@]}"; do
        [[ "$i" =~ ^[0-9]+$ && $i -lt ${#APP_ID[@]} ]] && SELECTED+=("$i")
    done
    [[ ${#SELECTED[@]} -gt 0 ]]
}

# Collect leftovers for the chosen apps. Caches always go with the app; the
# user picks which settings and data go. LEFT_NOTE says why a row is kept.
declare -a LEFT_APP=() LEFT_CLASS=() LEFT_PATH=() LEFT_ON=() LEFT_KB=() LEFT_NOTE=()
app_own_files() {
    local i="$1"
    case "${APP_KIND[i]}" in
        webapp | tui) mole_webapp_files "${APP_ID[i]}" ;;
        appimage) mole_appimage_files "${APP_ID[i]}" "${APP_EXEC[i]}" ;;
        orphan) printf '%s\n' "$HOME/.var/app/${APP_ID[i]}" ;;
    esac
}

is_selected() {
    local want="$1" s
    for s in "${SELECTED[@]}"; do [[ "$s" == "$want" ]] && return 0; done
    return 1
}

# Leftover paths of every installed app that is not being removed: a path one
# of them also answers to stays (mole-linux's "also used by installed app").
declare -A CLAIMED_BY=()
load_claims() {
    local i class path
    CLAIMED_BY=()
    for i in "${!APP_ID[@]}"; do
        is_selected "$i" && continue
        while IFS=$'\t' read -r class path; do
            [[ -n "$path" && -z "${CLAIMED_BY[$path]:-}" ]] && CLAIMED_BY[$path]="${APP_NAME[i]}"
        done < <(mole_app_leftovers "${APP_KIND[i]}" "${APP_ID[i]}" "${APP_DESKTOPS[i]}")
    done
}

add_left() {
    LEFT_APP+=("$1") LEFT_CLASS+=("$2") LEFT_PATH+=("$3") LEFT_ON+=("$4") LEFT_KB+=("$(mole_path_kb "$3")") LEFT_NOTE+=("${5:-}")
}

collect_leftovers() {
    local i class path on note
    LEFT_APP=() LEFT_CLASS=() LEFT_PATH=() LEFT_ON=() LEFT_KB=() LEFT_NOTE=()
    load_claims
    for i in "${SELECTED[@]}"; do
        # Files that are the app itself; it counts as removed once they are
        # in the Trash.
        while IFS= read -r path; do
            [[ -e "$path" || -L "$path" ]] || continue
            add_left "$i" app "$path" true
        done < <(app_own_files "$i")
        while IFS=$'\t' read -r class path; do
            [[ -n "$path" ]] || continue
            if [[ -n "${CLAIMED_BY[$path]:-}" ]]; then
                debug_log "Kept $path: also used by ${CLAIMED_BY[$path]}"
                continue
            fi
            on=false
            note=""
            [[ "$class" == cache || "$WITH_DATA" == true ]] && on=true
            if note=$(mole_leftover_holdback "$path"); then
                on=false
            else
                note=""
            fi
            add_left "$i" "$class" "$path" "$on" "$note"
        done < <(mole_app_leftovers "${APP_KIND[i]}" "${APP_ID[i]}" "${APP_DESKTOPS[i]}")
        while IFS= read -r path; do
            [[ -n "$path" ]] && add_left "$i" wants "$path" true
        done < <(package_wants_links "$i")
    done
}

# Ask for the user's choice, after dropping keys typed while Mole worked.
uninstall_confirm() {
    drain_pending_input
    mole_confirm "$1"
}

choose_data() {
    local -a rows=() idx=() pre=()
    local j n=0
    for j in "${!LEFT_PATH[@]}"; do
        [[ "${LEFT_CLASS[j]}" == data || -n "${LEFT_NOTE[j]}" ]] || continue
        rows+=("$(mole_display_path "${LEFT_PATH[j]}")  $(bytes_to_human_kb "${LEFT_KB[j]}")${LEFT_NOTE[j]:+  (${LEFT_NOTE[j]})}")
        idx+=("$j")
        [[ "${LEFT_ON[j]}" == true ]] && pre+=("$n")
        n=$((n + 1))
    done
    [[ ${#rows[@]} -gt 0 ]] || return 0
    [[ -t 0 && -t 1 ]] || return 0
    local MOLE_PRESELECTED_INDICES="" MOLE_MENU_META_SIZEKB="" MOLE_MENU_META_EPOCHS="" MOLE_MENU_FILTER_NAMES=""
    local MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    local _MOLE_MENU_KEEP_EMPTY=true _MOLE_MENU_SELECT_ALL=true
    [[ ${#pre[@]} -gt 0 ]] && MOLE_PRESELECTED_INDICES=$(IFS=,; printf '%s' "${pre[*]}")
    drain_pending_input
    local rc=0
    paginated_multi_select "Settings and data to remove" "${rows[@]}" || rc=$?
    [[ $rc -eq 0 ]] || return 0
    for j in "${idx[@]}"; do LEFT_ON[j]=false; done
    local -a picked=()
    IFS=',' read -ra picked <<< "${MOLE_SELECTION_RESULT:-}"
    for n in "${picked[@]}"; do
        [[ "$n" =~ ^[0-9]+$ && $n -lt ${#idx[@]} ]] && LEFT_ON[idx[n]]=true
    done
}

show_plan() {
    local i j label total_kb=0 total_n=0
    echo ""
    local -a pkgs=() apkgs=() snaps=()
    for i in "${SELECTED[@]}"; do
        case "${APP_KIND[i]}" in
            pacman | aur) pkgs+=("${APP_ID[i]}") ;;
            apt) apkgs+=("${APP_ID[i]}") ;;
            snap) snaps+=("${APP_ID[i]}") ;;
        esac
    done
    for i in "${SELECTED[@]}"; do
        echo -e "${PURPLE_BOLD}${ICON_ARROW}${NC} ${APP_NAME[i]} ${GRAY}$(kind_label "${APP_KIND[i]}") · $(bytes_to_human_kb "${APP_KB[i]}")${NC}"
        for j in "${!LEFT_PATH[@]}"; do
            [[ "${LEFT_APP[j]}" == "$i" ]] || continue
            [[ "${LEFT_CLASS[j]}" == wants ]] && continue
            label="$(mole_display_path "${LEFT_PATH[j]}")"
            if [[ "${LEFT_ON[j]}" == true ]]; then
                echo -e "  ${GREEN}${ICON_SOLID}${NC} $label  $(colorize_human_size "$(bytes_to_human_kb "${LEFT_KB[j]}")")"
                if [[ "${LEFT_CLASS[j]}" != app ]]; then
                    total_kb=$((total_kb + LEFT_KB[j]))
                    total_n=$((total_n + 1))
                fi
            else
                echo -e "  ${GRAY}${ICON_EMPTY} $label  $(bytes_to_human_kb "${LEFT_KB[j]}") (kept${LEFT_NOTE[j]:+, ${LEFT_NOTE[j]}})${NC}"
            fi
        done
    done
    local units
    units=$(selected_user_units | paste -sd ' ')
    [[ -n "$units" ]] && echo -e "  ${GRAY}User services stopped and disabled first: ${units}${NC}"
    ((total_n > 0)) && echo -e "  ${GRAY}Leftovers to Trash: $(mole_count_label "$total_n" item), $(bytes_to_human_kb "$total_kb")${NC}"
    # pacman's own answer to what -Rns takes along, read before any sudo.
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        local extra
        extra=$(mole_c pacman -Rsp --print-format '%n' -- "${pkgs[@]}" 2> /dev/null | grep -vxF -f <(printf '%s\n' "${pkgs[@]}") | paste -sd ' ') || extra=""
        [[ -n "$extra" ]] && echo -e "  ${GRAY}pacman also removes the dependencies only these use: ${extra}${NC}"
    fi
    # apt's own answer: packages that depend on the picked ones go with them
    # (a metapackage such as ubuntu-desktop), so they are named before sudo.
    if [[ ${#apkgs[@]} -gt 0 ]]; then
        local extra
        extra=$(mole_c apt-get -s remove -- "${apkgs[@]}" 2> /dev/null | awk '/^Remv [^ ]+/ {print $2}' | grep -vxF -f <(printf '%s\n' "${apkgs[@]}") | paste -sd ' ') || extra=""
        [[ -n "$extra" ]] && echo -e "  ${YELLOW}${ICON_WARNING}${NC} ${GRAY}apt also removes the packages that depend on these: ${extra}${NC}"
    fi
    local sn
    for sn in "${snaps[@]+"${snaps[@]}"}"; do
        snap_home_has_data "$sn" || continue
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} snap deletes $(mole_display_path "$HOME/snap/$sn") with ${sn} ($(bytes_to_human_kb "$(snap_home_kb "$sn")")), where it keeps its profile and data; $(snap_snapshot_note)"
    done
    echo ""
}

running_apps() {
    local i rc
    RUNNING=()
    for i in "${SELECTED[@]}"; do
        rc=0
        case "${APP_KIND[i]}" in
            webapp | tui | orphan) continue ;;
            flatpak) mole_flatpak_running "${APP_ID[i]}" || rc=$? ;;
            appimage) mole_exe_running "${APP_EXEC[i]}" || rc=$? ;;
            snap) mole_snap_running "${APP_ID[i]}" || rc=$? ;;
            pacman | aur | apt)
                rc=1
                if [[ -n "${APP_EXEC[i]}" ]]; then
                    rc=0
                    mole_process_running "${APP_EXEC[i]}" || rc=$?
                fi
                # A launcher name is not always the process (/usr/bin/discord
                # starts Discord, code starts electron): any process running a
                # file of the package counts too.
                if [[ $rc -eq 1 ]]; then
                    rc=0
                    mole_package_running "${APP_KIND[i]}" "${APP_ID[i]}" || rc=$?
                fi
                ;;
            *) continue ;;
        esac
        # 1 is the only "not running"; a probe that cannot tell blocks too.
        [[ $rc -ne 1 ]] && RUNNING+=("${APP_NAME[i]}")
    done
    [[ ${#RUNNING[@]} -gt 0 ]]
}

# 0 when ~/snap/<name> holds anything: snap remove deletes it.
# A folder Mole cannot read, or a symlink, counts as holding data.
snap_home_has_data() {
    local dir="$HOME/snap/$1" out
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 0
    [[ -L "$dir" ]] && return 0
    [[ -d "$dir" ]] || return 1
    out=$(find "$dir" -mindepth 1 -print -quit 2> /dev/null) || return 0
    [[ -n "$out" ]]
}

snap_home_kb() {
    local kb
    kb=$(du -sk -- "$HOME/snap/$1" 2> /dev/null | cut -f1) || kb=0
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    echo "$kb"
}

# What snap keeps after remove: an automatic snapshot (snap saved, snap
# restore) unless the system turned them off.
snap_snapshot_note() {
    local keep
    keep=$(mole_c timeout 10 snap get system snapshots.automatic.retention 2> /dev/null) || keep=""
    if [[ "$keep" == no ]]; then
        echo "this system keeps no snapshot of it"
    elif [[ "$keep" =~ ^[0-9]+[a-z]+$ ]]; then
        echo "snap keeps a snapshot for $keep (snap saved, snap restore)"
    else
        echo "snap keeps a snapshot, 31 days by default (snap saved, snap restore)"
    fi
}

# 0 when any process of the user runs a file of this package, 1 when none
# does, 2 when the package's file list cannot be read.
mole_package_running() {
    local out
    out=$(mole_pkg_files "$1" "$2") || return 2
    [[ -n "$out" ]] || return 2
    mole_files_running "$out"
}

# systemd --user answers (the user bus is reachable).
user_systemd_reachable() {
    command -v systemctl > /dev/null 2>&1 || return 1
    mole_c systemctl --user show-environment > /dev/null 2>&1
}

# Unit names of the user's own unit files picked for removal.
selected_user_units() {
    local j dir="$MOLE_CONFIG_HOME/systemd/user/"
    for j in "${!LEFT_PATH[@]}"; do
        [[ "${LEFT_ON[j]}" == true ]] || continue
        case "${LEFT_PATH[j]}" in
            "$dir"*.service | "$dir"*.timer | "$dir"*.socket)
                [[ "${LEFT_PATH[j]#"$dir"}" != */* ]] && printf '%s\n' "${LEFT_PATH[j]#"$dir"}"
                ;;
        esac
    done
    return 0
}

# Unit names a native package ships for the user's systemd (Debian may still
# use /lib, merged into /usr on current releases).
package_user_units() {
    local kind="$1" pkg="$2"
    { mole_pkg_files "$kind" "$pkg" || true; } | awk -F/ '
        /^(\/usr)?\/lib\/systemd\/user\/[^\/]+\.(service|timer|socket)$/ { print $NF }' || true
}

# The user's enablement links (~/.config/systemd/user/*.wants/<unit>) for
# the units a package ships; systemctl disable removes them before pacman
# takes the unit files, so none is left dangling.
package_wants_links() {
    local i="$1" unit link
    mole_native_kind "${APP_KIND[i]}" || return 0
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        for link in "$MOLE_CONFIG_HOME/systemd/user"/*.wants/"$unit"; do
            [[ -L "$link" ]] && printf '%s\n' "$link"
        done
    done < <(package_user_units "${APP_KIND[i]}" "${APP_ID[i]}")
    return 0
}

# Disable the package units the user enabled, before pacman removes them.
# Returns the units it disabled in PKG_UNITS_OFF; restored if pacman keeps
# the package.
declare -a PKG_UNITS_OFF=() PKG_UNITS_ACTIVE=()
UNIT_NOTES=()
disable_package_units() {
    local i j unit
    local -a units=()
    PKG_UNITS_OFF=()
    PKG_UNITS_ACTIVE=()
    for i in "${SELECTED[@]}"; do
        for j in "${!LEFT_PATH[@]}"; do
            [[ "${LEFT_APP[j]}" == "$i" && "${LEFT_CLASS[j]}" == wants ]] || continue
            unit="${LEFT_PATH[j]##*/}"
            [[ " ${units[*]-} " == *" $unit "* ]] || units+=("$unit")
        done
    done
    [[ ${#units[@]} -gt 0 ]] || return 0
    if ! user_systemd_reachable; then
        UNIT_NOTES+=("User services ${units[*]} were left enabled: systemctl --user is not reachable")
        return 0
    fi
    for unit in "${units[@]}"; do
        mole_c systemctl --user is-active --quiet -- "$unit" 2> /dev/null && PKG_UNITS_ACTIVE+=("$unit")
    done
    if mole_c systemctl --user disable --now -- "${units[@]}" > /dev/null 2>&1; then
        PKG_UNITS_OFF=("${units[@]}")
        log_operation uninstall DISABLED "systemd --user: ${units[*]}"
    else
        UNIT_NOTES+=("Could not disable user services ${units[*]}; check systemctl --user status")
    fi
}

restore_package_units() {
    [[ ${#PKG_UNITS_OFF[@]} -gt 0 ]] || return 0
    mole_c systemctl --user enable -- "${PKG_UNITS_OFF[@]}" > /dev/null 2>&1 ||
        UNIT_NOTES+=("Could not enable ${PKG_UNITS_OFF[*]} again; run systemctl --user enable ${PKG_UNITS_OFF[*]}")
    if [[ ${#PKG_UNITS_ACTIVE[@]} -gt 0 ]]; then
        mole_c systemctl --user start -- "${PKG_UNITS_ACTIVE[@]}" > /dev/null 2>&1 || true
    fi
    log_operation uninstall ENABLED "systemd --user: ${PKG_UNITS_OFF[*]}" "package was not removed"
    PKG_UNITS_OFF=()
}

remove_packages() {
    local i
    local -a pkgs=() apkgs=() no_admin=()
    for i in "${SELECTED[@]}"; do
        case "${APP_KIND[i]}" in
            pacman | aur) pkgs+=("${APP_ID[i]}") ;;
            apt) apkgs+=("${APP_ID[i]}") ;;
        esac
    done
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        if [[ -e /var/lib/pacman/db.lck ]]; then
            log_error "pacman is busy (/var/lib/pacman/db.lck); try again when it finishes"
        else
            echo -e "${PURPLE}${ICON_ADMIN}${NC} pacman removes ${pkgs[*]} and the dependencies only they use"
            if mole_sudo_ready; then
                disable_package_units
                sudo pacman -Rns -- "${pkgs[@]}" || true
            else
                no_admin+=("${pkgs[@]}")
            fi
        fi
    fi
    if [[ ${#apkgs[@]} -gt 0 ]]; then
        local busy=0
        mole_apt_busy || busy=$?
        if [[ $busy -ne 1 ]]; then
            log_error "apt or dpkg is running; try again when it finishes"
        else
            # apt keeps its own confirmation (no -y); remove, not purge, so the
            # system configuration under /etc stays as apt leaves it.
            echo -e "${PURPLE}${ICON_ADMIN}${NC} apt removes ${apkgs[*]}"
            if mole_sudo_ready; then
                disable_package_units
                sudo apt-get remove -- "${apkgs[@]}" || true
            else
                no_admin+=("${apkgs[@]}")
            fi
        fi
    fi
    local kept_pkg=false
    for i in "${SELECTED[@]}"; do
        case "${APP_KIND[i]}" in
            pacman | aur | apt)
                # Only a manager that says "gone" counts; one that cannot be
                # asked leaves the app installed, its leftovers untouched.
                local st=0
                mole_pkg_installed "${APP_KIND[i]}" "${APP_ID[i]}" || st=$?
                if [[ $st -eq 1 ]]; then
                    REMOVED+=("$i")
                    log_operation uninstall REMOVED "${APP_KIND[i]/aur/pacman}:${APP_ID[i]}"
                else
                    kept_pkg=true
                fi
                ;;
            snap)
                # snap has no confirmation of its own and deletes the snap's
                # data in ~/snap with it, so a snap that holds data there is
                # removed only after Mole's own confirmation, never on --yes.
                if [[ "$ASSUME_YES" == true ]] && snap_home_has_data "${APP_ID[i]}"; then
                    echo -e "${YELLOW}${ICON_WARNING}${NC} ${APP_NAME[i]} keeps data in $(mole_display_path "$HOME/snap/${APP_ID[i]}"), which snap deletes too; run mo uninstall ${APP_ID[i]} in a terminal to confirm"
                    continue
                fi
                if [[ "$MOLE_SUDO_FAILED" != true ]]; then
                    echo -e "${PURPLE}${ICON_ADMIN}${NC} snap removes ${APP_ID[i]}"
                fi
                if ! mole_sudo_ready; then
                    no_admin+=("${APP_ID[i]}")
                    continue
                fi
                sudo snap remove -- "${APP_ID[i]}" || true
                local sst=0
                mole_pkg_installed snap "${APP_ID[i]}" || sst=$?
                if [[ $sst -eq 1 ]]; then
                    REMOVED+=("$i")
                    log_operation uninstall REMOVED "snap:${APP_ID[i]}"
                fi
                ;;
            flatpak)
                local flag
                if ! flag=$(mole_flatpak_installation_flag "${APP_SCOPE[i]}"); then
                    log_error "${APP_NAME[i]}: unknown Flatpak installation \"${APP_SCOPE[i]}\""
                    continue
                fi
                # The user installation is the user's own; a system or custom
                # installation needs root, asked for on Mole's line like
                # pacman. flatpak keeps its own confirmation (no -y).
                local -a fp=(flatpak uninstall "$flag" -- "${APP_ID[i]}")
                if [[ "$flag" != --user ]]; then
                    # After a failed prompt, no new line and no new prompt.
                    if [[ "$MOLE_SUDO_FAILED" != true ]]; then
                        echo -e "${PURPLE}${ICON_ADMIN}${NC} flatpak removes ${APP_ID[i]} from the ${APP_SCOPE[i]} installation"
                    fi
                    if ! mole_sudo_ready; then
                        no_admin+=("${APP_ID[i]}")
                        continue
                    fi
                    fp=(sudo "${fp[@]}")
                fi
                if "${fp[@]}"; then
                    REMOVED+=("$i")
                    log_operation uninstall REMOVED "flatpak:${APP_ID[i]}"
                fi
                ;;
            webapp | tui | appimage | orphan)
                # The app is its own files (launcher, icon, AppImage, or the
                # data a removed Flatpak left); removed only once they are in
                # the Trash.
                local -a own=()
                local j
                for j in "${!LEFT_PATH[@]}"; do
                    [[ "${LEFT_APP[j]}" == "$i" && "${LEFT_CLASS[j]}" == app ]] && own+=("${LEFT_PATH[j]}")
                done
                [[ ${#own[@]} -gt 0 ]] || continue
                if ! mole_trash uninstall "${own[@]}"; then
                    local err
                    for err in "${MOLE_TRASH_ERRORS[@]}"; do log_error "$err"; done
                fi
                # Gone once its first file (the launcher, or the orphan's
                # folder) actually left; a stray icon does not undo that.
                if [[ $MOLE_TRASH_MOVED -gt 0 && ! -e "${own[0]}" && ! -L "${own[0]}" ]]; then
                    REMOVED+=("$i")
                fi
                ;;
        esac
    done
    if [[ ${#no_admin[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${ICON_WARNING}${NC} Needs admin access, not removed: ${no_admin[*]}"
    fi
    # One sudo session covers pacman and system Flatpaks; it ends here.
    mole_sudo_end
    # pacman kept a package (cancelled, failed): its units come back on.
    [[ "$kept_pkg" == true ]] && restore_package_units
    return 0
}

# pacman installs under /usr; on a subvolume snapper snapshots, a removed
# package's files stay in those snapshots until they rotate.
PACKAGE_ROOT=/usr
PACKAGES_SNAPSHOT_NOTE="Package files are freed as snapshots rotate"
# 0 when any of the given app indexes is a pacman or AUR package and its files
# sit on a snapshotted subvolume; a probe that cannot tell says nothing.
packages_held_by_snapshots() {
    local i any=false
    for i in "$@"; do
        mole_native_kind "${APP_KIND[i]}" && any=true
    done
    [[ "$any" == true ]] && mole_snapshot_state "$PACKAGE_ROOT"
}

# Leftover paths of removed apps that are selected, minus the user units when
# systemd cannot stop them first.
LEFTOVER_PATHS=()
plan_leftover_trash() {
    local i j dir="$MOLE_CONFIG_HOME/systemd/user/" removed_set=" ${REMOVED[*]-} "
    local -a units=() unit_paths=()
    LEFTOVER_PATHS=()
    for j in "${!LEFT_PATH[@]}"; do
        i="${LEFT_APP[j]}"
        [[ "$removed_set" == *" $i "* && "${LEFT_ON[j]}" == true ]] || continue
        case "${LEFT_CLASS[j]}" in
            app | wants) continue ;;
        esac
        case "${LEFT_PATH[j]}" in
            "$dir"*.service | "$dir"*.timer | "$dir"*.socket)
                units+=("${LEFT_PATH[j]#"$dir"}")
                unit_paths+=("${LEFT_PATH[j]}")
                continue
                ;;
        esac
        LEFTOVER_PATHS+=("${LEFT_PATH[j]}")
    done
    [[ ${#units[@]} -gt 0 ]] || return 0
    # A unit file moved away while enabled or running leaves a service
    # systemd still runs and links that point nowhere: stop and disable it
    # first, and leave it where it is when that cannot be done.
    if ! user_systemd_reachable; then
        UNIT_NOTES+=("User services left in place, systemctl --user is not reachable: ${units[*]}")
        return 0
    fi
    if mole_c systemctl --user disable --now -- "${units[@]}" > /dev/null 2>&1; then
        log_operation uninstall DISABLED "systemd --user: ${units[*]}"
        LEFTOVER_PATHS+=("${unit_paths[@]}")
        UNITS_TRASHED=true
    else
        UNIT_NOTES+=("User services left in place, systemctl --user could not disable them: ${units[*]}")
    fi
}

# After launchers or icons left, the user's launcher index and icon cache are
# rebuilt so the menu stops showing them; associations in mimeapps.list that
# name a launcher that no longer exists are reported, never rewritten.
refresh_after_removal() {
    local apps="$MOLE_DATA_HOME/applications" icons="$MOLE_DATA_HOME/icons" p theme
    local launchers=false
    local -A themes=()
    for p in "$@"; do
        [[ -e "$p" || -L "$p" ]] && continue
        [[ "$p" == "$apps/"*.desktop ]] && launchers=true
        if [[ "$p" == "$icons/"*/* ]]; then
            theme="${p#"$icons/"}"
            themes[${theme%%/*}]=1
        fi
    done
    if [[ "$launchers" == true && -d "$apps" ]] && command -v update-desktop-database > /dev/null 2>&1; then
        if mole_c update-desktop-database -q "$apps" > /dev/null 2>&1; then
            log_operation uninstall REBUILT "$apps/mimeinfo.cache" "update-desktop-database"
        fi
    fi
    if command -v gtk-update-icon-cache > /dev/null 2>&1; then
        for theme in "${!themes[@]}"; do
            [[ -f "$icons/$theme/icon-theme.cache" && ! -L "$icons/$theme" ]] || continue
            mole_c gtk-update-icon-cache -q -t -f "$icons/$theme" > /dev/null 2>&1 &&
                log_operation uninstall REBUILT "$icons/$theme/icon-theme.cache" "gtk-update-icon-cache"
        done
    fi
    return 0
}

# "mimeapps.list names HEY.desktop for x-scheme-handler/mailto" for every
# association that points at a launcher of a removed app that is gone from
# every applications folder.
stale_mime_associations() {
    local i d f line key dir found
    local -a ids=() lists=("$MOLE_CONFIG_HOME/mimeapps.list" "$MOLE_DATA_HOME/applications/mimeapps.list")
    for i in "${REMOVED[@]}"; do
        IFS=',' read -ra d <<< "${APP_ID[i]},${APP_DESKTOPS[i]}"
        ids+=("${d[@]}")
    done
    [[ ${#ids[@]} -gt 0 ]] || return 0
    local -A seen=()
    for d in "${ids[@]}"; do
        [[ -n "$d" && -z "${seen[$d]:-}" ]] || continue
        seen[$d]=1
        found=false
        for dir in "$MOLE_DATA_HOME/applications" /usr/share/applications /usr/local/share/applications \
            /var/lib/flatpak/exports/share/applications "$MOLE_DATA_HOME/flatpak/exports/share/applications"; do
            [[ -e "$dir/$d.desktop" ]] && found=true
        done
        [[ "$found" == true ]] && continue
        for f in "${lists[@]}"; do
            [[ -f "$f" ]] || continue
            while IFS= read -r line; do
                key="${line%%=*}"
                printf '%s\t%s\t%s\n' "$(mole_display_path "$f")" "$d.desktop" "$key"
            done < <(grep -E "^[^#=]+=(.*;)?$(printf '%s' "$d" | sed 's/[][\.^$*+?(){}|]/\\&/g')\\.desktop(;|$)" "$f" 2> /dev/null || true)
        done
    done
}

declare -a UNIT_NOTES=()
UNITS_TRASHED=false

run_once() {
    local interactive="$1"
    SELECTED=()
    REMOVED=()
    RUNNING=()
    UNIT_NOTES=()
    UNITS_TRASHED=false

    start_inline_spinner "Scanning installed apps..."
    load_apps
    stop_inline_spinner

    if [[ ${#APP_ID[@]} -eq 0 ]]; then
        echo "No removable apps found."
        return 3
    fi
    if [[ "$LIST_ONLY" == true ]]; then
        print_list
        return 3
    fi

    if [[ "$interactive" == true ]]; then
        choose_apps || return 3
    else
        match_names || return 1
    fi

    collect_leftovers
    [[ "$DRY_RUN" == true ]] || choose_data
    show_plan

    if [[ "$DRY_RUN" == true ]]; then
        local -a dry=("Would remove: $(mole_count_label "${#SELECTED[@]}" app)")
        packages_held_by_snapshots "${SELECTED[@]}" && dry+=("$PACKAGES_SNAPSHOT_NOTE")
        print_summary_block "Dry run complete - no changes made" "${dry[@]}"
        return 0
    fi

    if running_apps; then
        log_error "Quit ${RUNNING[*]} first, then run mo uninstall again."
        return 1
    fi

    if [[ "$ASSUME_YES" != true && ! -t 0 ]]; then
        echo "Run mo uninstall in a terminal, or pass --yes." >&2
        return 1
    fi
    if [[ "$ASSUME_YES" != true ]] && ! uninstall_confirm "Remove $(mole_count_label "${#SELECTED[@]}" app)?"; then
        echo "Cancelled."
        return 4
    fi

    local initial_free
    initial_free=$(get_free_space_kb /)
    remove_packages

    local i j trashed=0 failed=0
    plan_leftover_trash
    if [[ ${#LEFTOVER_PATHS[@]} -gt 0 ]]; then
        if ! mole_trash uninstall "${LEFTOVER_PATHS[@]}"; then
            local err
            for err in "${MOLE_TRASH_ERRORS[@]}"; do log_error "$err"; done
        fi
        trashed=$MOLE_TRASH_MOVED
        failed=$((${#LEFTOVER_PATHS[@]} - trashed))
    fi
    [[ "$UNITS_TRASHED" == true ]] && { mole_c systemctl --user daemon-reload > /dev/null 2>&1 || true; }
    local -a touched=("${LEFTOVER_PATHS[@]}")
    for j in "${!LEFT_PATH[@]}"; do
        [[ "${LEFT_CLASS[j]}" == app ]] && touched+=("${LEFT_PATH[j]}")
    done
    [[ ${#touched[@]} -gt 0 ]] && refresh_after_removal "${touched[@]}"

    local -a details=()
    local final_free removed_names="" note
    for i in "${REMOVED[@]}"; do removed_names+="${removed_names:+, }${APP_NAME[i]}"; done
    if [[ ${#REMOVED[@]} -gt 0 ]]; then
        details+=("Removed: ${removed_names}")
    fi
    if [[ ${#REMOVED[@]} -lt ${#SELECTED[@]} ]]; then
        details+=("Not removed: $(mole_count_label $((${#SELECTED[@]} - ${#REMOVED[@]})) app)")
    fi
    if [[ ${#REMOVED[@]} -gt 0 ]] && packages_held_by_snapshots "${REMOVED[@]}"; then
        details+=("$PACKAGES_SNAPSHOT_NOTE")
    fi
    ((trashed > 0)) && details+=("Leftovers moved to Trash: $(mole_count_label "$trashed" item)")
    ((failed > 0)) && details+=("Leftovers not moved: $(mole_count_label "$failed" item)")
    for note in "${UNIT_NOTES[@]}"; do details+=("$note"); done
    local mime_file mime_desktop mime_key mime_n=0
    while IFS=$'\t' read -r mime_file mime_desktop mime_key; do
        [[ -n "$mime_key" ]] || continue
        mime_n=$((mime_n + 1))
        ((mime_n <= 3)) && details+=("$mime_file still opens $mime_key with $mime_desktop, which is gone")
    done < <(stale_mime_associations)
    ((mime_n > 3)) && details+=("and $((mime_n - 3)) more stale entries in mimeapps.list")
    final_free=$(get_free_space_kb /)
    if ((final_free > initial_free)); then
        details+=("Free space: $(bytes_to_human_kb "$final_free") (+$(bytes_to_human_kb $((final_free - initial_free))))")
    fi
    local heading="Uninstall complete"
    [[ ${#REMOVED[@]} -eq 0 ]] && heading="Nothing was removed"
    print_summary_block "$heading" "${details[@]}"
    [[ ${#REMOVED[@]} -gt 0 ]]
}

# Enter goes back to the app list, anything else or five idle seconds leaves.
return_to_list() {
    local countdown=5 key=""
    while ((countdown > 0)); do
        printf "\r${GRAY}Press Enter to return to the app list, press q to exit (%d)${NC} " "$countdown"
        if IFS= read -r -s -n1 -t 1 key 2> /dev/null; then
            printf "\n"
            drain_pending_input
            [[ -z "$key" ]]
            return
        fi
        countdown=$((countdown - 1))
    done
    printf "\n"
    return 1
}

main() {
    local interactive=false rc
    if [[ ${#NAMES[@]} -eq 0 && "$LIST_ONLY" != true ]]; then
        if [[ ! -t 0 || ! -t 1 ]]; then
            echo "Run mo uninstall in a terminal, or name the apps: mo uninstall <name>." >&2
            exit 1
        fi
        interactive=true
    fi
    while true; do
        rc=0
        run_once "$interactive" || rc=$?
        if [[ "$interactive" != true ]]; then
            case "$rc" in
                3 | 4) exit 0 ;;
                *) exit "$rc" ;;
            esac
        fi
        # The selector was left: done. A cancelled confirmation goes straight
        # back to the list; after a run the user chooses.
        [[ $rc -eq 3 ]] && exit 0
        [[ $rc -eq 4 ]] && continue
        return_to_list || exit 0
    done
}

# Sourced by the bats tests for its functions; run directly otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
