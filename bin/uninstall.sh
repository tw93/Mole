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
declare -a NAMES=()
for arg in "$@"; do
    case "$arg" in
        --dry-run | -n) DRY_RUN=true ;;
        --list) LIST_ONLY=true ;;
        --with-data) WITH_DATA=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            echo "Usage: mo uninstall [OPTIONS] [APP_NAME ...]"
            echo ""
            echo "Remove apps and their leftover files. Packages are removed by pacman or"
            echo "flatpak, which ask for their own confirmation; leftovers go to the Trash."
            echo ""
            echo "Examples:"
            echo "  mo uninstall                   Open interactive app selector"
            echo "  mo uninstall spotify           Uninstall Spotify"
            echo "  mo uninstall --dry-run zoom    Preview what would be removed"
            echo "  mo uninstall --list            List apps and the names mo uninstall accepts"
            echo ""
            echo "Options:"
            echo "  --list            List installed apps with the name mo uninstall accepts"
            echo "  --dry-run, -n     Preview without making changes"
            echo "  --with-data       Start with settings and data selected"
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

trap 'stop_inline_spinner; show_cursor; echo ""; exit 130' INT TERM

declare -a APP_KIND=() APP_ID=() APP_NAME=() APP_KB=() APP_DESKTOPS=() APP_EXEC=() APP_SCOPE=()

kind_label() {
    case "$1" in
        pacman) echo "pacman" ;;
        aur) echo "AUR" ;;
        flatpak) echo "Flatpak" ;;
        webapp) echo "Web app" ;;
        appimage) echo "AppImage" ;;
        orphan) echo "Leftover" ;;
    esac
}

load_apps() {
    local kind id name kb desktops exec scope
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
}

print_list() {
    local i
    printf '%-34s %-30s %-8s %s\n' "NAME" "ACCEPTS" "SOURCE" "SIZE"
    for i in "${!APP_ID[@]}"; do
        printf '%-34s %-30s %-8s %s\n' "${APP_NAME[i]:0:34}" "${APP_ID[i]:0:30}" "$(kind_label "${APP_KIND[i]}")" \
            "$(bytes_to_human_kb "${APP_KB[i]}")"
    done
}

# Exact, case-insensitive match on the package/app ID or the display name.
match_names() {
    local want i lw lid lname found
    for want in "${NAMES[@]}"; do
        mole_ascii_lowercase lw "$want"
        found=false
        for i in "${!APP_ID[@]}"; do
            mole_ascii_lowercase lid "${APP_ID[i]}"
            mole_ascii_lowercase lname "${APP_NAME[i]}"
            if [[ "$lw" == "$lid" || "$lw" == "$lname" ]]; then
                SELECTED+=("$i")
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            log_error "No installed app named \"$want\". Run mo uninstall --list to see the accepted names."
            return 1
        fi
    done
}

choose_apps() {
    local -a rows=() sizes=() names=()
    local i width=32
    for i in "${!APP_ID[@]}"; do
        local name
        name=$(truncate_by_display_width "${APP_NAME[i]}" "$width")
        local pad=$((width - $(get_display_width "$name")))
        ((pad < 0)) && pad=0
        rows+=("$(printf '%s%*s %9s  %s' "$name" "$pad" "" "$(bytes_to_human_kb "${APP_KB[i]}")" "$(kind_label "${APP_KIND[i]}")")")
        sizes+=("${APP_KB[i]}")
        names+=("${APP_NAME[i]} ${APP_ID[i]}")
    done
    local MOLE_MENU_META_SIZEKB MOLE_MENU_FILTER_NAMES MOLE_MENU_SORT_MODE=name MOLE_MENU_SORT_REVERSE=false
    MOLE_MENU_META_SIZEKB=$(IFS=,; printf '%s' "${sizes[*]}")
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${names[@]}")
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
# user picks which settings and data go.
declare -a LEFT_APP=() LEFT_CLASS=() LEFT_PATH=() LEFT_ON=()
app_own_files() {
    local i="$1"
    case "${APP_KIND[i]}" in
        webapp) mole_webapp_files "${APP_ID[i]}" ;;
        appimage) mole_appimage_files "${APP_ID[i]}" "${APP_EXEC[i]}" ;;
        orphan) printf '%s\n' "$HOME/.var/app/${APP_ID[i]}" ;;
    esac
}

collect_leftovers() {
    local i class path
    for i in "${SELECTED[@]}"; do
        # Files that are the app itself; it counts as removed once they are
        # in the Trash.
        while IFS= read -r path; do
            [[ -e "$path" || -L "$path" ]] || continue
            LEFT_APP+=("$i") LEFT_CLASS+=(app) LEFT_PATH+=("$path") LEFT_ON+=(true)
        done < <(app_own_files "$i")
        while IFS=$'\t' read -r class path; do
            [[ -n "$path" ]] || continue
            LEFT_APP+=("$i") LEFT_CLASS+=("$class") LEFT_PATH+=("$path")
            if [[ "$class" == cache || "$WITH_DATA" == true ]]; then
                LEFT_ON+=(true)
            else
                LEFT_ON+=(false)
            fi
        done < <(mole_app_leftovers "${APP_KIND[i]}" "${APP_ID[i]}" "${APP_DESKTOPS[i]}")
    done
}

choose_data() {
    local -a rows=() idx=() pre=()
    local j n=0
    for j in "${!LEFT_PATH[@]}"; do
        [[ "${LEFT_CLASS[j]}" == data ]] || continue
        rows+=("$(mole_display_path "${LEFT_PATH[j]}")  $(bytes_to_human_kb "$(mole_path_kb "${LEFT_PATH[j]}")")")
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
    local i j label
    echo ""
    local -a pkgs=()
    for i in "${SELECTED[@]}"; do
        [[ "${APP_KIND[i]}" == pacman || "${APP_KIND[i]}" == aur ]] && pkgs+=("${APP_ID[i]}")
    done
    for i in "${SELECTED[@]}"; do
        echo -e "${PURPLE_BOLD}${ICON_ARROW}${NC} ${APP_NAME[i]} ${GRAY}$(kind_label "${APP_KIND[i]}") · $(bytes_to_human_kb "${APP_KB[i]}")${NC}"
        for j in "${!LEFT_PATH[@]}"; do
            [[ "${LEFT_APP[j]}" == "$i" ]] || continue
            label="$(mole_display_path "${LEFT_PATH[j]}")"
            if [[ "${LEFT_ON[j]}" == true ]]; then
                echo -e "  ${GREEN}${ICON_SOLID}${NC} $label"
            else
                echo -e "  ${GRAY}${ICON_EMPTY} $label (kept)${NC}"
            fi
        done
    done
    # pacman's own answer to what -Rns takes along, read before any sudo.
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        local extra
        extra=$(mole_c pacman -Rsp --print-format '%n' -- "${pkgs[@]}" 2> /dev/null | grep -vxF -f <(printf '%s\n' "${pkgs[@]}") | paste -sd ' ') || extra=""
        [[ -n "$extra" ]] && echo -e "  ${GRAY}pacman also removes the dependencies only these use: ${extra}${NC}"
    fi
    echo ""
}

running_apps() {
    local i rc
    RUNNING=()
    for i in "${SELECTED[@]}"; do
        [[ -n "${APP_EXEC[i]}" ]] || continue
        rc=0
        case "${APP_KIND[i]}" in
            webapp | orphan) continue ;;
            appimage) mole_exe_running "${APP_EXEC[i]}" || rc=$? ;;
            *) mole_process_running "${APP_EXEC[i]}" || rc=$? ;;
        esac
        [[ $rc -eq 0 ]] && RUNNING+=("${APP_NAME[i]}")
    done
    [[ ${#RUNNING[@]} -gt 0 ]]
}

declare -a REMOVED=()
remove_packages() {
    local i
    local -a pkgs=()
    for i in "${SELECTED[@]}"; do
        [[ "${APP_KIND[i]}" == pacman || "${APP_KIND[i]}" == aur ]] && pkgs+=("${APP_ID[i]}")
    done
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        if [[ -e /var/lib/pacman/db.lck ]]; then
            log_error "pacman is busy (/var/lib/pacman/db.lck); try again when it finishes"
        else
            echo -e "${PURPLE}${ICON_ADMIN}${NC} pacman removes ${pkgs[*]} and the dependencies only they use"
            sudo pacman -Rns -- "${pkgs[@]}" || true
        fi
    fi
    for i in "${SELECTED[@]}"; do
        case "${APP_KIND[i]}" in
            pacman | aur)
                if ! mole_c pacman -Qq -- "${APP_ID[i]}" > /dev/null 2>&1; then
                    REMOVED+=("$i")
                    log_operation uninstall REMOVED "pacman:${APP_ID[i]}"
                fi
                ;;
            flatpak)
                local scope_flag="--system"
                [[ "${APP_SCOPE[i]}" == user ]] && scope_flag="--user"
                if flatpak uninstall "$scope_flag" -- "${APP_ID[i]}"; then
                    REMOVED+=("$i")
                    log_operation uninstall REMOVED "flatpak:${APP_ID[i]}"
                fi
                ;;
            webapp | appimage | orphan)
                # The app is its own files (launcher, icon, AppImage, or the
                # data a removed Flatpak left); removed only once they are in
                # the Trash.
                local -a own=()
                local j
                for j in "${!LEFT_PATH[@]}"; do
                    [[ "${LEFT_APP[j]}" == "$i" && "${LEFT_CLASS[j]}" == app ]] && own+=("${LEFT_PATH[j]}")
                done
                if mole_trash uninstall "${own[@]}"; then
                    REMOVED+=("$i")
                else
                    local err
                    for err in "${MOLE_TRASH_ERRORS[@]}"; do log_error "$err"; done
                fi
                ;;
        esac
    done
}

main() {
    start_inline_spinner "Scanning installed apps..."
    load_apps
    stop_inline_spinner

    if [[ ${#APP_ID[@]} -eq 0 ]]; then
        echo "No removable apps found."
        exit 0
    fi
    if [[ "$LIST_ONLY" == true ]]; then
        print_list
        exit 0
    fi

    SELECTED=()
    if [[ ${#NAMES[@]} -gt 0 ]]; then
        match_names || exit 1
    else
        if [[ ! -t 0 || ! -t 1 ]]; then
            echo "Run mo uninstall in a terminal, or name the apps: mo uninstall <name>." >&2
            exit 1
        fi
        choose_apps || exit 0
    fi

    collect_leftovers
    [[ "$DRY_RUN" == true ]] || choose_data
    show_plan

    if [[ "$DRY_RUN" == true ]]; then
        print_summary_block "Dry run complete - no changes made" \
            "Would remove: $(mole_count_label "${#SELECTED[@]}" app)"
        exit 0
    fi

    if running_apps; then
        log_error "Quit ${RUNNING[*]} first, then run mo uninstall again."
        exit 1
    fi

    if [[ -t 0 ]] && ! mole_confirm "Remove $(mole_count_label "${#SELECTED[@]}" app)?"; then
        echo "Cancelled."
        exit 0
    fi

    local initial_free
    initial_free=$(get_free_space_kb /)
    remove_packages

    local -a paths=()
    local i j trashed=0 failed=0
    for i in "${REMOVED[@]}"; do
        for j in "${!LEFT_PATH[@]}"; do
            [[ "${LEFT_APP[j]}" == "$i" && "${LEFT_ON[j]}" == true && "${LEFT_CLASS[j]}" != app ]] && paths+=("${LEFT_PATH[j]}")
        done
    done
    if [[ ${#paths[@]} -gt 0 ]]; then
        if ! mole_trash uninstall "${paths[@]}"; then
            local err
            for err in "${MOLE_TRASH_ERRORS[@]}"; do log_error "$err"; done
        fi
        trashed=$MOLE_TRASH_MOVED
        failed=$((${#paths[@]} - trashed))
    fi

    local -a details=()
    local final_free removed_names=""
    for i in "${REMOVED[@]}"; do removed_names+="${removed_names:+, }${APP_NAME[i]}"; done
    if [[ ${#REMOVED[@]} -gt 0 ]]; then
        details+=("Removed: ${removed_names}")
    fi
    if [[ ${#REMOVED[@]} -lt ${#SELECTED[@]} ]]; then
        details+=("Not removed: $(mole_count_label $((${#SELECTED[@]} - ${#REMOVED[@]})) app)")
    fi
    ((trashed > 0)) && details+=("Leftovers moved to Trash: $(mole_count_label "$trashed" item)")
    ((failed > 0)) && details+=("Leftovers not moved: $(mole_count_label "$failed" item)")
    final_free=$(get_free_space_kb /)
    if ((final_free > initial_free)); then
        details+=("Free space: $(bytes_to_human_kb "$final_free") (+$(bytes_to_human_kb $((final_free - initial_free))))")
    fi
    local heading="Uninstall complete"
    [[ ${#REMOVED[@]} -eq 0 ]] && heading="Nothing was removed"
    print_summary_block "$heading" "${details[@]}"
    [[ ${#REMOVED[@]} -gt 0 ]]
}

# Sourced by the bats tests for its functions; run directly otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
