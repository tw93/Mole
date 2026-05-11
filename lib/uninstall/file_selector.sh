#!/bin/bash
# Interactive file selection for uninstall.
# Requires: common.sh (provides read_key, hide_cursor, show_cursor, icons, colors).

set -euo pipefail

# Detect if a path is a "team prefix" match — a Group Container whose directory
# name starts with a 10-char Apple Developer Team ID (e.g. FN2V63AD2J.com.foo).
# These Group Containers are shared across apps from the same developer, so they
# are deselected by default to avoid accidentally removing shared data.
is_team_prefix_path() {
    local path="$1"
    [[ "$path" =~ /Group[[:space:]]Containers/[A-Z0-9]{10}\. ]]
}

# Terminal helpers — lightweight, no dependency on menu scripts.
_sfr_enter_alt_screen() { tput smcup 2> /dev/null || true; }
_sfr_leave_alt_screen() { tput rmcup 2> /dev/null || true; }

_sfr_get_terminal_height() {
    local h
    if [[ -t 0 ]] || [[ -t 2 ]]; then
        h=$(stty size < /dev/tty 2> /dev/null | awk '{print $1}')
    fi
    if [[ -n "$h" && $h -gt 0 ]]; then echo "$h"; else tput lines 2> /dev/null || echo 24; fi
}

# Lightweight multi-select menu — no sort, no filter, no pagination.
# Reads:  MOLE_PRESELECTED_INDICES (comma-separated indices, optional)
# Writes: MOLE_SELECTION_RESULT (comma-separated selected indices)
# Args:   title, then display items
# Returns: 0 on Enter, 1 on Q/ESC.
_sfr_multi_select() {
    local title="$1"
    shift
    local -a items=("$@")

    if [[ ${#items[@]} -eq 0 ]]; then
        echo "No items provided" >&2
        return 1
    fi

    local total=${#items[@]}
    local term_height=$(_sfr_get_terminal_height)
    local reserved=5
    local items_per_page=$((term_height - reserved))
    [[ $items_per_page -lt 1 ]] && items_per_page=1
    [[ $items_per_page -gt 50 ]] && items_per_page=50

    local cursor_pos=0 top_index=0
    local -a selected=()
    local i
    for ((i = 0; i < total; i++)); do selected[i]=false; done

    if [[ -n "${MOLE_PRESELECTED_INDICES:-}" ]]; then
        local cleaned="${MOLE_PRESELECTED_INDICES//[[:space:]]/}"
        local -a ps=()
        local IFS=','
        read -ra ps <<< "$cleaned"
        for i in "${ps[@]}"; do
            [[ "$i" =~ ^[0-9]+$ && $i -ge 0 && $i -lt $total ]] && selected[i]=true
        done
    fi

    # Preserve TTY settings
    local original_stty=""
    if [[ -t 0 ]] && command -v stty > /dev/null 2>&1; then
        original_stty=$(stty -g 2> /dev/null || echo "")
    fi

    _sfr_restore_terminal() {
        show_cursor
        if [[ -n "${original_stty:-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || true
        else
            stty sane 2> /dev/null || stty echo icanon 2> /dev/null || true
        fi
        _sfr_leave_alt_screen
    }

    _sfr_cleanup() {
        trap - EXIT INT TERM
        _sfr_restore_terminal
    }
    trap _sfr_cleanup EXIT
    trap '_sfr_cleanup; exit 130' INT TERM

    stty -echo -icanon intr ^C 2> /dev/null || true
    _sfr_enter_alt_screen
    printf "\033[2J\033[H" >&2
    hide_cursor

    _sfr_draw() {
        printf "\033[H" >&2
        local clear="\r\033[2K"
        local sel_count=0
        local i
        for ((i = 0; i < total; i++)); do
            [[ ${selected[i]} == true ]] && sel_count=$((sel_count + 1))
        done
        printf "${clear}${PURPLE_BOLD}%s${NC}  ${GRAY}%d/%d selected${NC}\n" "$title" "$sel_count" "$total" >&2
        printf "${clear}\n" >&2

        # Clamp viewport
        if [[ $top_index -gt $((total - 1)) ]]; then
            top_index=$((total - items_per_page))
            [[ $top_index -lt 0 ]] && top_index=0
        fi
        local visible=$((total - top_index))
        [[ $visible -gt $items_per_page ]] && visible=$items_per_page
        [[ $visible -le 0 ]] && visible=1
        if [[ $cursor_pos -ge $visible ]]; then
            cursor_pos=$((visible - 1))
            [[ $cursor_pos -lt 0 ]] && cursor_pos=0
        fi

        local end=$((top_index + items_per_page - 1))
        [[ $end -ge $total ]] && end=$((total - 1))

        local idx
        for ((i = top_index; i <= end; i++)); do
            local is_cur=false
            [[ $((i - top_index)) -eq $cursor_pos ]] && is_cur=true
            local cb="$ICON_EMPTY"
            [[ ${selected[i]} == true ]] && cb="$ICON_SOLID"
            if [[ $is_cur == true ]]; then
                printf "${clear}${CYAN}${ICON_ARROW} %s %s${NC}\n" "$cb" "${items[i]}" >&2
            else
                printf "${clear}  %s %s\n" "$cb" "${items[i]}" >&2
            fi
        done

        local shown=$((end - top_index + 1))
        [[ $shown -lt 0 ]] && shown=0
        for ((i = shown; i < items_per_page; i++)); do
            printf "${clear}\n" >&2
        done

        printf "${clear}\n" >&2
        printf "${clear}${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN} | Space Select | Enter Save | Q Cancel${NC}\n" >&2
        printf "${clear}" >&2
    }

    while true; do
        _sfr_draw
        local key
        key=$(read_key)

        case "$key" in
            QUIT)
                _sfr_cleanup
                return 1
                ;;
            UP)
                if [[ $cursor_pos -gt 0 ]]; then
                    cursor_pos=$((cursor_pos - 1))
                elif [[ $top_index -gt 0 ]]; then
                    top_index=$((top_index - 1))
                fi
                ;;
            DOWN)
                local abs_idx=$((top_index + cursor_pos))
                if [[ $abs_idx -lt $((total - 1)) ]]; then
                    local vis=$((total - top_index))
                    [[ $vis -gt $items_per_page ]] && vis=$items_per_page
                    if [[ $cursor_pos -lt $((vis - 1)) ]]; then
                        cursor_pos=$((cursor_pos + 1))
                    elif [[ $((top_index + vis)) -lt $total ]]; then
                        top_index=$((top_index + 1))
                        vis=$((total - top_index))
                        [[ $vis -gt $items_per_page ]] && vis=$items_per_page
                        [[ $cursor_pos -ge $vis ]] && cursor_pos=$((vis - 1))
                    fi
                fi
                ;;
            LEFT | RIGHT)
                # Swallow — no horizontal navigation in this view
                :
                ;;
            SPACE)
                local idx=$((top_index + cursor_pos))
                [[ $idx -lt $total ]] && selected[idx]=$([[ ${selected[idx]} == true ]] && echo false || echo true)
                ;;
            ENTER)
                local -a sel_idx=()
                for ((i = 0; i < total; i++)); do
                    [[ ${selected[i]} == true ]] && sel_idx+=("$i")
                done
                trap - EXIT INT TERM
                _sfr_restore_terminal
                if [[ ${#sel_idx[@]} -gt 0 ]]; then
                    local IFS=','
                    MOLE_SELECTION_RESULT="${sel_idx[*]}"
                else
                    MOLE_SELECTION_RESULT=""
                fi
                return 0
                ;;
        esac
    done
}

# Usage:
#   MOLE_SFR_USER_FILES="..."  MOLE_SFR_SYSTEM_FILES="..."  select_files_for_removal <app_name>
#
# Input:  MOLE_SFR_USER_FILES   — newline-separated user file paths
#         MOLE_SFR_SYSTEM_FILES — newline-separated system file paths
# Output: same variables, filtered to only the files the user kept selected
# Returns: 0 on confirm, 1 on cancel (Q or ESC).
select_files_for_removal() {
    local app_name="$1"

    # ---- build combined file list -------------------------------------------
    local -a _paths=()
    local -a _is_system=()
    local -a _displays=()
    local -a _pre=()
    local _f _disp _kb _hum _dw _maxw=0

    while IFS= read -r _f; do
        [[ -n "$_f" && -e "$_f" ]] || continue
        _paths+=("$_f")
        _is_system+=(false)
        _disp="${_f/$HOME/~}"
        _kb=$(get_path_size_kb "$_f" 2> /dev/null || echo 0)
        _hum=$(bytes_to_human $((_kb * 1024)))
        _dw=$(get_display_width "$_disp")
        ((_dw > _maxw)) && _maxw=$_dw
        if is_team_prefix_path "$_f"; then
            _pre+=(false)
        else
            _pre+=(true)
        fi
        _displays+=("$_disp|$_hum|$_dw")
    done <<< "${MOLE_SFR_USER_FILES:-}"

    while IFS= read -r _f; do
        [[ -n "$_f" && -e "$_f" ]] || continue
        _paths+=("$_f")
        _is_system+=(true)
        _kb=$(get_path_size_kb "$_f" 2> /dev/null || echo 0)
        _hum=$(bytes_to_human $((_kb * 1024)))
        _dw=$(get_display_width "$_f")
        ((_dw > _maxw)) && _maxw=$_dw
        if is_team_prefix_path "$_f"; then
            _pre+=(false)
        else
            _pre+=(true)
        fi
        _displays+=("$_f|$_hum|$_dw")
    done <<< "${MOLE_SFR_SYSTEM_FILES:-}"

    local _total=${#_paths[@]}
    if [[ $_total -eq 0 ]]; then
        return 0
    fi

    # ---- format menu items with aligned size column --------------------------
    local _min_col=30
    ((_maxw < _min_col)) && _maxw=$_min_col
    local _gap=2

    local -a _items=()
    local -a _ps=()
    local _i _path _size _dw2 _pad _fmt
    for ((_i = 0; _i < _total; _i++)); do
        IFS='|' read -r _path _size _dw2 <<< "${_displays[_i]}"
        _pad=$((_maxw - _dw2 + _gap))
        printf -v _fmt "%s%*s%s" "$_path" "$_pad" "" "$_size"
        _items+=("$_fmt")
        [[ ${_pre[_i]} == true ]] && _ps+=("$_i")
    done

    # ---- run the menu -------------------------------------------------------
    local _saved_preselect="${MOLE_PRESELECTED_INDICES:-}"
    local IFS=','
    MOLE_PRESELECTED_INDICES="${_ps[*]}"

    _sfr_multi_select "Select Files to Remove" "${_items[@]}"
    local _rc=$?

    if [[ -n "${_saved_preselect+x}" ]]; then
        MOLE_PRESELECTED_INDICES="$_saved_preselect"
    else
        unset MOLE_PRESELECTED_INDICES
    fi

    if [[ $_rc -ne 0 ]]; then
        return 1
    fi

    # ---- filter file lists from selection -----------------------------------
    if [[ -z "${MOLE_SELECTION_RESULT:-}" ]]; then
        MOLE_SFR_USER_FILES=""
        MOLE_SFR_SYSTEM_FILES=""
        return 0
    fi

    local -a _sel=()
    IFS=',' read -ra _sel <<< "$MOLE_SELECTION_RESULT"

    local _u="" _s="" _idx
    for _idx in "${_sel[@]}"; do
        [[ "$_idx" =~ ^[0-9]+$ && $_idx -ge 0 && $_idx -lt $_total ]] || continue
        if [[ ${_is_system[_idx]} == true ]]; then
            [[ -n "$_s" ]] && _s+=$'\n'
            _s+="${_paths[_idx]}"
        else
            [[ -n "$_u" ]] && _u+=$'\n'
            _u+="${_paths[_idx]}"
        fi
    done

    MOLE_SFR_USER_FILES="$_u"
    MOLE_SFR_SYSTEM_FILES="$_s"
    return 0
}
