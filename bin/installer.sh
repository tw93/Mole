#!/bin/bash
# Mole CLI (Linux) - installer: find installer files left in Downloads and on
# the Desktop (.deb, .rpm, .AppImage, .iso, .run, Flatpak and Snap bundles,
# Arch packages) and move the ones the user picks to the Trash, as Mole CLI
# (macOS) `mo installer` does for .dmg and .pkg files. An AppImage that a
# launcher starts or that is running is an app, not an installer, and stays.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/ui/menu_paginated.sh"
mole_refuse_root

INSTALLER_JSON=false
ASSUME_YES=false
WANTED=()
installer_help() {
    echo "Usage: mo installer [OPTIONS] [FILE...]"
    echo ""
    echo "Find installer files in Downloads and on the Desktop and move them to the Trash."
    echo ""
    echo "Options:"
    echo "  --dry-run, -n     Preview without making changes"
    echo "  --json            List what was found as JSON"
    echo "  --yes, -y         Move every file found, or only the FILEs named, without asking"
    echo "  -h, --help        Show this help message"
}
for arg in "$@"; do
    case "$arg" in
        --dry-run | -n) DRY_RUN=true ;;
        --json) INSTALLER_JSON=true ;;
        --yes | -y) ASSUME_YES=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            installer_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg" >&2
            echo "Use 'mo installer --help' for supported options." >&2
            exit 1
            ;;
        *) WANTED+=("$arg") ;;
    esac
done
export DRY_RUN

# The folders searched, two levels deep: where browsers save and where people
# drop files. xdg-user-dirs names them in the user's language.
installer_roots() {
    local dir name
    for name in DOWNLOAD DESKTOP; do
        dir=""
        command -v xdg-user-dir > /dev/null 2>&1 && dir=$(xdg-user-dir "$name" 2> /dev/null) || true
        if [[ -z "$dir" || "$dir" == "$HOME" ]]; then
            [[ "$name" == DOWNLOAD ]] && dir="$HOME/Downloads" || dir="$HOME/Desktop"
        fi
        [[ -d "$dir" && ! -L "$dir" ]] && printf '%s\n' "$dir"
    done | awk '!seen[$0]++'
}

# The kind of installer a file name is, or nothing.
installer_kind() {
    local lower
    mole_ascii_lowercase lower "$1"
    case "$lower" in
        *.deb) echo "Debian package" ;;
        *.rpm) echo "RPM package" ;;
        *.appimage) echo "AppImage" ;;
        *.iso | *.img) echo "Disk image" ;;
        *.run) echo "Installer script" ;;
        *.flatpak | *.flatpakref) echo "Flatpak bundle" ;;
        *.snap) echo "Snap package" ;;
        *.pkg.tar.zst | *.pkg.tar.xz) echo "Arch package" ;;
        *) return 1 ;;
    esac
}

# Real paths of every absolute or ~ path a user launcher's Exec names, one
# per line, so a launcher that starts an AppImage through a link still counts.
launcher_targets() {
    local file line word
    local -a words=()
    for file in "$MOLE_DATA_HOME"/applications/*.desktop "$MOLE_CONFIG_HOME"/autostart/*.desktop; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            read -ra words <<< "$line"
            for word in "${words[@]}"; do
                word="${word#\"}"
                word="${word%\"}"
                # shellcheck disable=SC2088 # a literal ~ written in the launcher
                [[ "$word" == "~/"* ]] && word="$HOME/${word#\~/}"
                [[ "$word" == /* ]] && readlink -m -- "$word"
            done
        done < <(awk '/^Exec=/ { sub(/^Exec=/, ""); print }' "$file" 2> /dev/null)
    done
}

# Real paths of the files the user's processes hold open, one per line: an
# .iso a VM has attached, an image an imager writes, a file still being
# downloaded under its final name. Fails when /proc cannot be listed, and the
# caller then treats every candidate as in use.
open_files() {
    [[ -d "$_MOLE_PROC_ROOT/self" ]] || return 1
    local pid fd
    for pid in "$_MOLE_PROC_ROOT"/[0-9]*; do
        mole_pid_mine "$pid" || continue
        for fd in "$pid"/fd/*; do
            readlink -- "$fd" 2> /dev/null || true
        done
    done
}

# Why a candidate must stay right now, or nothing when it may go.
in_use_reason() {
    local real="$1" kind="$2" launchers="$3" open="$4" open_ok="$5"
    if [[ "$kind" == AppImage ]]; then
        [[ $'\n'"$launchers"$'\n' == *$'\n'"$real"$'\n'* ]] && {
            echo "has a launcher"
            return
        }
        # Unknown counts as running: the file is someone's app.
        local probe=0
        mole_exe_running "$real" || probe=$?
        [[ $probe -ne 1 ]] && {
            echo "running"
            return
        }
    fi
    [[ "$open_ok" == true ]] || {
        echo "open files cannot be checked"
        return
    }
    [[ $'\n'"$open"$'\n' == *$'\n'"$real"$'\n'* ]] && echo "open in an app"
    return 0
}

F_PATH=()
F_REAL=()
F_KIND=()
F_KB=()
F_AGE=()
F_NOTE=()
F_STATE=() # ok or in-use
scan() {
    local root path kind launchers now mtime age note state pkg open open_ok=true real
    launchers=$(launcher_targets)
    open=$(open_files) || open_ok=false
    now=$(date +%s)
    while IFS= read -r root; do
        while IFS= read -r -d '' path; do
            kind=$(installer_kind "${path##*/}") || continue
            mtime=$(stat -c %Y -- "$path" 2> /dev/null) || continue
            age=$(((now - mtime) / 86400))
            real=$(readlink -m -- "$path")
            note=$(in_use_reason "$real" "$kind" "$launchers" "$open" "$open_ok")
            state=ok
            [[ -n "$note" ]] && state=in-use
            if [[ "$state" == ok && "$kind" == "Debian package" ]] && command -v dpkg-deb > /dev/null 2>&1; then
                pkg=$(mole_c dpkg-deb -f -- "$path" Package 2> /dev/null) || pkg=""
                # shellcheck disable=SC2016 # dpkg-query's format fields, not shell expansions.
                if [[ -n "$pkg" ]] && mole_c dpkg-query -W -f='${db:Status-Abbrev}' -- "$pkg" 2> /dev/null | grep -q '^ii'; then
                    note="installed"
                fi
            fi
            F_PATH+=("$path")
            F_REAL+=("$real")
            F_KIND+=("$kind")
            F_KB+=("$(mole_path_kb "$path")")
            F_AGE+=("$age")
            F_NOTE+=("$note")
            F_STATE+=("$state")
        done < <(find "$root" -mindepth 1 -maxdepth 2 -xdev -type f -print0 2> /dev/null)
    done < <(installer_roots)
}

age_label() {
    local d="$1"
    if ((d < 1)); then
        echo "today"
    elif ((d < 30)); then
        echo "${d}d old"
    elif ((d < 365)); then
        echo "$((d / 30))mo old"
    else
        echo "$((d / 365))y old"
    fi
}

print_json() {
    local i sep=""
    printf '['
    for i in "${!F_PATH[@]}"; do
        printf '%s\n  {"path": %s, "name": %s, "kind": %s, "size_kb": %d, "age_days": %d, "note": %s, "state": %s}' "$sep" \
            "$(json_string "${F_PATH[i]}")" "$(json_string "${F_PATH[i]##*/}")" "$(json_string "${F_KIND[i]}")" \
            "${F_KB[i]}" "${F_AGE[i]}" "$(json_string "${F_NOTE[i]}")" "$(json_string "${F_STATE[i]}")"
        sep=","
    done
    printf '\n]\n'
}

row_text() {
    local i="$1" name
    name=$(truncate_by_display_width "${F_PATH[i]##*/}" 40)
    printf '%-40s %9s | %-16s %s' "$name" "$(bytes_to_human_kb "${F_KB[i]}")" "${F_KIND[i]}" \
        "$(age_label "${F_AGE[i]}")${F_NOTE[i]:+, ${F_NOTE[i]}}"
}

PICKED=()
choose() {
    local -a rows=() pre=() sizes=() names=() idx=()
    local i
    for i in "${!F_PATH[@]}"; do
        [[ "${F_STATE[i]}" == ok ]] || continue
        pre+=("${#rows[@]}")
        rows+=("$(row_text "$i")")
        sizes+=("${F_KB[i]}")
        names+=("${F_PATH[i]}")
        idx+=("$i")
    done
    [[ ${#rows[@]} -gt 0 ]] || return 1
    local MOLE_PRESELECTED_INDICES MOLE_MENU_META_SIZEKB MOLE_MENU_FILTER_NAMES MOLE_MENU_META_EPOCHS=""
    local MOLE_MENU_SORT_MODE=size MOLE_MENU_SORT_REVERSE=false
    MOLE_PRESELECTED_INDICES=$(IFS=,; printf '%s' "${pre[*]}")
    MOLE_MENU_META_SIZEKB=$(IFS=,; printf '%s' "${sizes[*]}")
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${names[@]}")
    drain_pending_input
    local rc=0
    paginated_multi_select "Select installers to move to Trash" "${rows[@]}" || rc=$?
    [[ $rc -eq 0 ]] || return 1
    local -a picked=()
    IFS=',' read -ra picked <<< "${MOLE_SELECTION_RESULT:-}"
    for i in "${picked[@]}"; do
        [[ "$i" =~ ^[0-9]+$ && $i -lt ${#idx[@]} ]] && PICKED+=("${idx[i]}")
    done
    [[ ${#PICKED[@]} -gt 0 ]]
}

# FILEs on the command line must be ones the scan found and may move; a path
# Mole did not find is refused rather than trashed. Compared by real path, so
# a linked home (/home -> /var/home) still matches.
pick_named() {
    local want i found real
    for want in "${WANTED[@]}"; do
        found=""
        real=$(readlink -m -- "$want")
        for i in "${!F_PATH[@]}"; do
            [[ "${F_REAL[i]}" == "$real" ]] && found="$i" && break
        done
        if [[ -z "$found" ]]; then
            log_error "Not an installer Mole found: $want"
            return 1
        fi
        if [[ "${F_STATE[found]}" != ok ]]; then
            log_error "${F_PATH[found]##*/} is in use (${F_NOTE[found]}); it stays."
            return 1
        fi
        PICKED+=("$found")
    done
}

main() {
    [[ "$INSTALLER_JSON" == true ]] || start_inline_spinner "Looking for installers..."
    scan
    [[ "$INSTALLER_JSON" == true ]] || stop_inline_spinner
    if [[ "$INSTALLER_JSON" == true ]]; then
        print_json
        return 0
    fi
    echo -e "${PURPLE_BOLD}Installers${NC}"
    if [[ ${#F_PATH[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No installer files in Downloads or on the Desktop"
        return 0
    fi
    local i
    if [[ ${#WANTED[@]} -gt 0 ]]; then
        pick_named || return 1
        if [[ "$DRY_RUN" != true && "$ASSUME_YES" != true ]]; then
            [[ -t 0 && -t 1 ]] || {
                echo "Pass --yes to move named files outside a terminal, or preview with --dry-run." >&2
                return 1
            }
            mole_confirm "Move $(mole_count_label "${#PICKED[@]}" file) to Trash?" || {
                echo "Nothing moved."
                return 0
            }
        fi
    elif [[ "$DRY_RUN" == true || "$ASSUME_YES" == true ]]; then
        for i in "${!F_PATH[@]}"; do
            [[ "${F_STATE[i]}" == ok ]] && PICKED+=("$i")
        done
    elif [[ -t 0 && -t 1 ]]; then
        choose || {
            echo "Nothing moved."
            return 0
        }
    else
        echo "mo installer asks which files go, so it needs a terminal. Preview with --dry-run, or pass --yes." >&2
        return 1
    fi
    local kb=0
    for i in "${!F_PATH[@]}"; do
        if [[ "${F_STATE[i]}" != ok ]]; then
            echo -e "  ${GRAY}${ICON_EMPTY} ${F_PATH[i]##*/} · ${F_NOTE[i]}, stays${NC}"
        fi
    done
    local -a paths=()
    for i in "${PICKED[@]}"; do
        paths+=("${F_PATH[i]}")
        kb=$((kb + F_KB[i]))
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $(row_text "$i") ${YELLOW}dry${NC}"
        fi
    done
    [[ ${#paths[@]} -gt 0 ]] || {
        echo "Nothing to move."
        return 0
    }
    if [[ "$DRY_RUN" == true ]]; then
        print_summary_block "Dry run complete - no changes made" \
            "Would move to Trash: $(mole_count_label "${#paths[@]}" file), $(bytes_to_human_kb "$kb")"
        return 0
    fi
    # Asked again right before the move: the picker may have waited a while.
    local err rc=0 launchers open open_ok=true reason
    launchers=$(launcher_targets)
    open=$(open_files) || open_ok=false
    paths=()
    local -a still=()
    for i in "${PICKED[@]}"; do
        reason=$(in_use_reason "${F_REAL[i]}" "${F_KIND[i]}" "$launchers" "$open" "$open_ok")
        if [[ -n "$reason" ]]; then
            echo -e "  ${GRAY}${ICON_EMPTY} ${F_PATH[i]##*/} · ${reason}, stays${NC}"
            log_operation installer SKIPPED "${F_PATH[i]}" "$reason"
            continue
        fi
        paths+=("${F_PATH[i]}")
        still+=("$i")
    done
    PICKED=("${still[@]+"${still[@]}"}")
    [[ ${#paths[@]} -gt 0 ]] || return 1
    mole_trash installer "${paths[@]}" || rc=1
    for i in "${PICKED[@]}"; do
        [[ " ${MOLE_TRASH_ERRORS[*]} " == *" ${F_PATH[i]}:"* ]] && continue
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(row_text "$i")"
    done
    for err in "${MOLE_TRASH_ERRORS[@]}"; do log_error "$err"; done
    print_summary_block "Installers moved to Trash" \
        "Moved: $(mole_count_label "$MOLE_TRASH_MOVED" file)" \
        "Restore them from the Trash if one is still needed"
    return "$rc"
}

# Sourced by the bats tests for its functions; run directly otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
