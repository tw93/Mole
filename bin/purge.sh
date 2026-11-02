#!/bin/bash
# Mole CLI (Linux) - purge: remove build output of projects you have not
# touched for a week (node_modules, target, build, .venv and the like). Each
# folder is rebuilt by its own tool; nothing goes to the Trash, since build
# output in the Trash frees nothing.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/lib/purge/scan.sh"

DRY_RUN=false
PATHS_MODE=false
ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        --dry-run | -n) DRY_RUN=true ;;
        --paths) PATHS_MODE=true ;;
        --yes | -y) ASSUME_YES=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            echo "Usage: mo purge [OPTIONS]"
            echo ""
            echo "Remove build output of your projects (node_modules, target, build, .venv"
            echo "and others). Folders changed in the last 7 days start unselected."
            echo ""
            echo "Options:"
            echo "  --dry-run, -n     Preview without making changes"
            echo "  --paths           Show and edit the folders purge scans"
            echo "  --yes, -y         Remove what is older than 7 days without asking (needed outside a terminal)"
            echo "  --debug           Show detailed operation logs"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Use 'mo purge --help' for supported options." >&2
            exit 1
            ;;
    esac
done
export DRY_RUN

# A folder rm was working on when the user pressed Ctrl-C is logged as partly
# removed, so mo history shows it.
purge_interrupted() {
    stop_inline_spinner
    show_cursor
    [[ -n "${MOLE_REMOVING:-}" ]] && log_operation purge FAILED "$MOLE_REMOVING" "interrupted"
    echo ""
    exit 130
}
trap purge_interrupted INT TERM

# One row per candidate.
declare -a P_PATH=() P_ROOT=() P_ID=() P_KB=() P_STATE=() P_MTIME=()
declare -A ROOT_SNAPSHOT=()

age_label() {
    local mtime="${1:-0}" now days
    [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -gt 0 ]] || {
        echo "unknown age"
        return
    }
    now=$(date +%s)
    days=$(((now - mtime) / 86400))
    ((days < 0)) && days=0
    if ((days < 7)); then
        echo "${days}d ago"
    elif ((days < 30)); then
        echo "$((days / 7))w ago"
    elif ((days < 365)); then
        echo "$((days / 30))mo ago"
    else
        echo "$((days / 365))y ago"
    fi
}

state_label() {
    case "$1" in
        old) age_label "$2" ;;
        recent) echo "changed this week" ;;
        busy) echo "in use" ;;
        *) echo "unknown age" ;;
    esac
}

show_paths() {
    local root
    echo -e "${PURPLE_BOLD}Purge Paths${NC}"
    echo ""
    if ! mole_purge_load_roots; then
        echo "Cannot read $(mole_display_path "$MOLE_PURGE_CONFIG_FILE"); fix or remove it." >&2
        return 1
    fi
    local -a roots=("${MOLE_PURGE_ROOTS[@]+"${MOLE_PURGE_ROOTS[@]}"}")
    if [[ "$MOLE_PURGE_ROOTS_FROM_CONFIG" == true ]]; then
        echo -e "${GRAY}From $(mole_display_path "$MOLE_PURGE_CONFIG_FILE"):${NC}"
    else
        echo -e "${GRAY}Found automatically (add your own to $(mole_display_path "$MOLE_PURGE_CONFIG_FILE")):${NC}"
    fi
    if [[ ${#roots[@]} -eq 0 ]]; then
        echo -e "  ${GRAY}${ICON_EMPTY} No project folders found${NC}"
    fi
    for root in "${roots[@]}"; do
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(mole_display_path "$root")"
    done
    echo ""
    local editor="${VISUAL:-${EDITOR:-}}"
    if [[ ! -t 0 || ! -t 1 || -z "$editor" ]]; then
        echo "Edit $(mole_display_path "$MOLE_PURGE_CONFIG_FILE"): one folder per line, ~ allowed; an empty file uses the folders above."
        return 0
    fi
    if [[ ! -e "$MOLE_PURGE_CONFIG_FILE" ]]; then
        mkdir -p "${MOLE_PURGE_CONFIG_FILE%/*}"
        cat > "$MOLE_PURGE_CONFIG_FILE" << 'TEMPLATE'
# Folders mo purge scans for project build output, one per line (~ allowed).
# While no folder is listed, purge uses the folders it finds itself.
#
# ~/www
# ~/work/client-a
TEMPLATE
    fi
    echo -e "Opening in ${CYAN}${editor}${NC}..."
    # VISUAL and EDITOR may carry arguments ("code --wait").
    local -a cmd=()
    read -ra cmd <<< "$editor"
    "${cmd[@]}" "$MOLE_PURGE_CONFIG_FILE"
}

# Find candidates under every root and sort them by size, largest first.
scan() {
    local root path reason state id kb busy_rc=0 incomplete=()
    local -a roots=()
    mole_purge_load_roots || return 1
    roots=("${MOLE_PURGE_ROOTS[@]+"${MOLE_PURGE_ROOTS[@]}"}")
    SCAN_ROOTS=("${roots[@]+"${roots[@]}"}")
    [[ ${#roots[@]} -gt 0 ]] || return 0
    mole_purge_proc_snapshot || busy_rc=$?
    local -a found=() found_root=()
    for root in "${roots[@]}"; do
        start_inline_spinner "Scanning $(mole_display_path "$root")..."
        local rc=0 list
        list=$(mole_purge_walk "$root") || rc=$?
        [[ $rc -eq 124 ]] && incomplete+=("$root")
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            found+=("$path")
            found_root+=("$root")
        done <<< "$list"
        stop_inline_spinner
    done
    SCAN_INCOMPLETE=("${incomplete[@]+"${incomplete[@]}"}")
    local i n=${#found[@]}
    for ((i = 0; i < n; i++)); do
        path="${found[i]}"
        start_inline_spinner "Checking $((i + 1))/$n $(mole_display_path "$path")..."
        reason=$(mole_purge_refusal "$path") || reason=""
        if [[ "$reason" != ok ]]; then
            debug_log "purge keeps $path: $reason"
            continue
        fi
        id=$(mole_purge_identity "$path") || continue
        if [[ $busy_rc -ne 0 ]] || mole_purge_project_busy "${path%/*}" "${found_root[i]}"; then
            state=busy
        else
            state=$(mole_purge_activity "$path")
        fi
        kb=$(mole_purge_size_kb "$path")
        P_PATH+=("$path")
        P_ROOT+=("${found_root[i]}")
        P_ID+=("$id")
        P_KB+=("$kb")
        P_STATE+=("$state")
        P_MTIME+=("$(stat -c %Y -- "$path" 2> /dev/null || echo 0)")
    done
    stop_inline_spinner
    for root in "${roots[@]}"; do
        local snap=0
        mole_snapshot_state "$root" || snap=$?
        [[ $snap -eq 0 ]] && ROOT_SNAPSHOT[$root]=1
    done
    return 0
}

row_text() {
    local i="$1" width=44 shown pad size
    shown=$(mole_display_path "${P_PATH[i]%/*}")
    shown=$(truncate_by_display_width "$shown" "$width")
    pad=$((width - $(get_display_width "$shown")))
    ((pad < 0)) && pad=0
    size=$(bytes_to_human_kb "${P_KB[i]:-0}")
    [[ -n "${P_KB[i]}" ]] || size="?"
    printf '%s%*s %9s | %-14s %s' "$shown" "$pad" "" "$size" "${P_PATH[i]##*/}" "$(state_label "${P_STATE[i]}" "${P_MTIME[i]}")"
}

# Rows selected unless the user picks otherwise: old, measured or not.
default_on() { [[ "${P_STATE[$1]}" == old ]]; }

declare -a PICKED=()
choose() {
    local -a rows=() pre=() sizes=() names=()
    local i
    for i in "${!P_PATH[@]}"; do
        rows+=("$(row_text "$i")")
        default_on "$i" && pre+=("$i")
        sizes+=("${P_KB[i]:-0}")
        names+=("${P_PATH[i]}")
    done
    local MOLE_PRESELECTED_INDICES="" MOLE_MENU_META_SIZEKB MOLE_MENU_META_EPOCHS="" MOLE_MENU_FILTER_NAMES
    # No select-all key: a recent or busy row goes only when picked on its own.
    local MOLE_MENU_SORT_MODE=size MOLE_MENU_SORT_REVERSE=false _MOLE_MENU_SELECT_ALL=false
    [[ ${#pre[@]} -gt 0 ]] && MOLE_PRESELECTED_INDICES=$(IFS=,; printf '%s' "${pre[*]}")
    MOLE_MENU_META_SIZEKB=$(IFS=,; printf '%s' "${sizes[*]}")
    MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${names[@]}")
    drain_pending_input
    local rc=0
    paginated_multi_select "Select build output to remove" "${rows[@]}" || rc=$?
    [[ $rc -eq 0 ]] || return 1
    local -a picked=()
    IFS=',' read -ra picked <<< "${MOLE_SELECTION_RESULT:-}"
    for i in "${picked[@]}"; do
        [[ "$i" =~ ^[0-9]+$ && $i -lt ${#P_PATH[@]} ]] && PICKED+=("$i")
    done
    [[ ${#PICKED[@]} -gt 0 ]]
}

# Everything checked again right before the folder goes: what it is, who
# works in it, and (unless the user picked a recent row on purpose) its age.
recheck() {
    local i="$1" reason state
    reason=$(mole_purge_refusal "${P_PATH[i]}") || reason=""
    [[ "$reason" == ok ]] || {
        echo "${reason:-could not be checked}"
        return 1
    }
    if mole_purge_project_busy "${P_PATH[i]%/*}" "${P_ROOT[i]}"; then
        echo "in use"
        return 1
    fi
    if [[ "${P_STATE[i]}" != recent ]]; then
        state=$(mole_purge_activity "${P_PATH[i]}")
        if [[ "$state" != old ]]; then
            echo "changed since the scan"
            return 1
        fi
    fi
    return 0
}

main() {
    mole_refuse_root
    if [[ "$PATHS_MODE" == true ]]; then
        show_paths
        exit $?
    fi
    if [[ "$DRY_RUN" != true && "$ASSUME_YES" != true && ! (-t 0 && -t 1) ]]; then
        echo "mo purge asks which folders go, so it needs a terminal. Preview with --dry-run, or pass --yes to remove what is older than 7 days." >&2
        exit 1
    fi
    local initial_free
    initial_free=$(get_free_space_kb "$HOME")
    echo -e "${PURPLE_BOLD}Purge Project Build Output${NC}"
    echo ""
    [[ "$DRY_RUN" == true ]] && echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions" && echo ""

    SCAN_ROOTS=()
    SCAN_INCOMPLETE=()
    if ! scan; then
        echo "Cannot read $(mole_display_path "$MOLE_PURGE_CONFIG_FILE"); fix or remove it, then run mo purge again." >&2
        exit 1
    fi
    if [[ ${#SCAN_ROOTS[@]} -eq 0 ]]; then
        echo -e "  ${GRAY}${ICON_EMPTY} No project folders found. Add yours with mo purge --paths${NC}"
        exit 0
    fi
    local root
    for root in "${SCAN_INCOMPLETE[@]+"${SCAN_INCOMPLETE[@]}"}"; do
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} $(mole_display_path "$root") took too long to scan; only part of it was checked"
    done
    if [[ ${#P_PATH[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No build output to remove in $(mole_count_label "${#SCAN_ROOTS[@]}" folder)"
        exit 0
    fi

    # Largest first, for the preview and for --yes.
    local -a order=()
    mapfile -t order < <(for i in "${!P_PATH[@]}"; do printf '%s\t%s\n' "${P_KB[i]:-0}" "$i"; done | sort -t$'\t' -k1,1nr | cut -f2)

    local i
    if [[ "$DRY_RUN" == true || "$ASSUME_YES" == true ]]; then
        for i in "${order[@]}"; do
            default_on "$i" && PICKED+=("$i")
        done
    elif ! choose; then
        echo ""
        echo -e "  ${GRAY}${ICON_EMPTY} Nothing removed${NC}"
        exit 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        local kb=0 n=0 unknown=0
        for i in "${order[@]}"; do
            if default_on "$i"; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $(row_text "$i") ${YELLOW}dry${NC}"
                [[ -n "${P_KB[i]}" ]] && kb=$((kb + P_KB[i])) || unknown=$((unknown + 1))
                n=$((n + 1))
            else
                echo -e "  ${GRAY}${ICON_EMPTY} $(row_text "$i"), kept unless picked${NC}"
            fi
        done
        local line="Would free: $(colorize_human_size "$(bytes_to_human_kb "$kb")") · $(mole_count_label "$n" folder)"
        ((unknown > 0)) && line+=", $unknown not measured"
        print_summary_block "Dry run complete - no changes made" "$line"
        exit 0
    fi

    if [[ "$ASSUME_YES" != true ]]; then
        local sel_kb=0
        for i in "${PICKED[@]}"; do sel_kb=$((sel_kb + ${P_KB[i]:-0})); done
        echo ""
        drain_pending_input
        if ! mole_confirm "Remove $(mole_count_label "${#PICKED[@]}" folder), $(bytes_to_human_kb "$sel_kb")"; then
            echo -e "  ${GRAY}${ICON_EMPTY} Nothing removed${NC}"
            exit 0
        fi
    fi
    if [[ ${#PICKED[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing older than 7 days to remove"
        exit 0
    fi

    # A snapshot that fails leaves MOLE_PURGE_PROC_OK false: every project then
    # counts as in use and nothing goes.
    mole_purge_proc_snapshot || true
    local removed_kb=0 removed=0 rotate_kb=0 failed=0 reason size
    for i in "${PICKED[@]}"; do
        size=$(bytes_to_human_kb "${P_KB[i]:-0}")
        if ! reason=$(recheck "$i"); then
            echo -e "  ${GRAY}${ICON_EMPTY} $(mole_display_path "${P_PATH[i]}") · kept, ${reason}${NC}"
            log_operation purge SKIPPED "${P_PATH[i]}" "$reason"
            continue
        fi
        local rm_rc=0
        mole_remove_artifact "${P_PATH[i]}" "${P_ROOT[i]}" "${P_ID[i]}" "$size" || rm_rc=$?
        if ((rm_rc == 1)); then
            echo -e "  ${GRAY}${ICON_EMPTY} $(mole_display_path "${P_PATH[i]}") · kept, changed before removal${NC}"
            continue
        fi
        if ((rm_rc == 0)); then
            removed=$((removed + 1))
            if [[ -n "${ROOT_SNAPSHOT[${P_ROOT[i]}]:-}" ]]; then
                rotate_kb=$((rotate_kb + ${P_KB[i]:-0}))
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(mole_display_path "${P_PATH[i]}") · $(colorize_human_size "$size") ${GRAY}(freed as snapshots rotate)${NC}"
            else
                removed_kb=$((removed_kb + ${P_KB[i]:-0}))
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(mole_display_path "${P_PATH[i]}") · $(colorize_human_size "$size")"
            fi
        else
            failed=$((failed + 1))
            echo -e "  ${YELLOW}${ICON_ERROR}${NC} $(mole_display_path "${P_PATH[i]}") · could not be removed completely"
        fi
    done

    local -a details=()
    if ((removed > 0)); then
        details+=("Removed: $(colorize_human_size "$(bytes_to_human_kb "$removed_kb")") · $(mole_count_label "$removed" folder)")
    else
        details+=("Nothing was removed.")
    fi
    ((rotate_kb > 0)) && details+=("$(bytes_to_human_kb "$rotate_kb") more returns as btrfs snapshots rotate")
    ((failed > 0)) && details+=("$(mole_count_label "$failed" folder) could not be removed completely; see mo history")
    local final_free note=""
    final_free=$(get_free_space_kb "$HOME")
    ((final_free > initial_free)) && note=" (+$(bytes_to_human_kb $((final_free - initial_free))))"
    details+=("Free space: $(bytes_to_human_kb "$final_free")$note")
    print_summary_block "Purge complete" "${details[@]}"
    ((failed == 0))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
