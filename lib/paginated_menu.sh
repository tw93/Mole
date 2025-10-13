#!/bin/bash
# Paginated menu with arrow key navigation

set -euo pipefail

# Terminal control functions
enter_alt_screen() { tput smcup 2> /dev/null || true; }
leave_alt_screen() { tput rmcup 2> /dev/null || true; }

# Parse CSV into newline list (Bash 3.2)
_pm_parse_csv_to_array() {
    local csv="${1:-}"
    if [[ -z "$csv" ]]; then
        return 0
    fi
    local IFS=','
    for _tok in $csv; do
        printf "%s\n" "$_tok"
    done
}

# Non-blocking input drain (bash 3.2)
drain_pending_input() {
  local _k
  # -t 0 is non-blocking; -n 1 consumes one byte at a time
  while IFS= read -r -s -n 1 -t 0 _k; do
    IFS= read -r -s -n 1 _k || break
  done
}

# Main paginated multi-select menu function
paginated_multi_select() {
    local title="$1"
    shift
    local -a items=("$@")
    local external_alt_screen=false
    if [[ "${MOLE_MANAGED_ALT_SCREEN:-}" == "1" || "${MOLE_MANAGED_ALT_SCREEN:-}" == "true" ]]; then
        external_alt_screen=true
    fi

    # Validation
    if [[ ${#items[@]} -eq 0 ]]; then
        echo "No items provided" >&2
        return 1
    fi

    local total_items=${#items[@]}
    local items_per_page=15
    local cursor_pos=0
    local top_index=0
    local filter_query=""
    local filter_mode="false"                              # filter mode toggle
    local sort_mode="${MOLE_MENU_SORT_DEFAULT:-date}"     # date|name|size
    local sort_reverse="false"
    # Live query vs applied query
    local applied_query=""
    local searching="false"

    # Metadata (optional)
    # epochs[i]   -> last_used_epoch (numeric) for item i
    # sizekb[i]   -> size in KB (numeric) for item i
    local -a epochs=()
    local -a sizekb=()
    if [[ -n "${MOLE_MENU_META_EPOCHS:-}" ]]; then
        while IFS= read -r v; do epochs+=("${v:-0}"); done < <(_pm_parse_csv_to_array "$MOLE_MENU_META_EPOCHS")
    fi
    if [[ -n "${MOLE_MENU_META_SIZEKB:-}" ]]; then
        while IFS= read -r v; do sizekb+=("${v:-0}"); done < <(_pm_parse_csv_to_array "$MOLE_MENU_META_SIZEKB")
    fi

    # Index mappings
    local -a orig_indices=()
    local -a view_indices=()
    local i
    for ((i = 0; i < total_items; i++)); do
        orig_indices[i]=$i
        view_indices[i]=$i
    done

    # Escape for shell globbing without upsetting highlighters
    _pm_escape_glob() {
        local s="${1-}" out="" c
        local i len=${#s}
        for ((i=0; i<len; i++)); do
            c="${s:i:1}"
            case "$c" in
                '\'|'*'|'?'|'['|']') out+="\\$c" ;;
                *)                   out+="$c"  ;;
            esac
        done
        printf '%s' "$out"
    }

    # Case-insensitive: substring by default, prefix if query starts with '
    _pm_match() {
        local hay="$1" q="$2" anchored=0
        if [[ "$q" == \'* ]]; then
            anchored=1
            q="${q:1}"
        fi
        q="$(_pm_escape_glob "$q")"
        local pat
        if [[ $anchored -eq 1 ]]; then
            pat="${q}*"
        else
            pat="*${q}*"
        fi

        shopt -s nocasematch
        local ok=1
        # shellcheck disable=SC2254  # intentional glob match with a computed pattern
        case "$hay" in
            $pat) ok=0 ;;
        esac
        shopt -u nocasematch
        return $ok
    }

    local -a selected=()

    # Initialize selection array
    for ((i = 0; i < total_items; i++)); do
        selected[i]=false
    done

    if [[ -n "${MOLE_PRESELECTED_INDICES:-}" ]]; then
        local cleaned_preselect="${MOLE_PRESELECTED_INDICES//[[:space:]]/}"
        local -a initial_indices=()
        IFS=',' read -ra initial_indices <<< "$cleaned_preselect"
        for idx in "${initial_indices[@]}"; do
            if [[ "$idx" =~ ^[0-9]+$ && $idx -ge 0 && $idx -lt $total_items ]]; then
                selected[idx]=true
            fi
        done
    fi

    # Preserve original TTY settings so we can restore them reliably
    local original_stty=""
    if [[ -t 0 ]] && command -v stty > /dev/null 2>&1; then
        original_stty=$(stty -g 2> /dev/null || echo "")
    fi

    restore_terminal() {
        show_cursor
        if [[ -n "${original_stty-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || stty echo icanon 2> /dev/null || true
        else
            stty sane 2> /dev/null || stty echo icanon 2> /dev/null || true
        fi
        if [[ "${external_alt_screen:-false}" == false ]]; then
            leave_alt_screen
        fi
    }

    # Cleanup function
    cleanup() {
        trap - EXIT INT TERM
        restore_terminal
        unset MOLE_READ_KEY_FORCE_CHAR
    }

    # Interrupt handler
    handle_interrupt() {
        cleanup
        exit 130 # Standard exit code for Ctrl+C
    }

    trap cleanup EXIT
    trap handle_interrupt INT TERM

    # Setup terminal - preserve interrupt character
    stty -echo -icanon intr ^C 2> /dev/null || true
    if [[ $external_alt_screen == false ]]; then
        enter_alt_screen
        # Clear screen once on entry to alt screen
        printf "\033[2J\033[H" >&2
    else
        printf "\033[H" >&2
    fi
    hide_cursor

    # Helper functions
    print_line() { printf "\r\033[2K%s\n" "$1" >&2; }

    # Print footer lines wrapping only at separators
    _print_wrapped_controls() {
        local sep="$1"; shift
        local -a segs=("$@")

        local cols="${COLUMNS:-}"
        [[ -z "$cols" ]] && cols=$(tput cols 2>/dev/null || echo 80)

        _strip_ansi_len() {
            local text="$1"
            local stripped
            stripped=$(printf "%s" "$text" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*[A-Za-z]/,""); print}')
            printf "%d" "${#stripped}"
        }

        local line="" s candidate
        local clear_line=$'\r\033[2K'
        for s in "${segs[@]}"; do
            if [[ -z "$line" ]]; then
                candidate="$s"
            else
                candidate="$line${sep}${s}"
            fi
            if (( $(_strip_ansi_len "$candidate") > cols )); then
                printf "%s%s\n" "$clear_line" "$line" >&2
                line="$s"
            else
                line="$candidate"
            fi
        done
        printf "%s%s\n" "$clear_line" "$line" >&2
    }

    # Rebuild the view_indices applying filter and sort
    rebuild_view() {
        # Filter
        local -a filtered=()
        local effective_query=""
        if [[ "$filter_mode" == "true" ]]; then
            # Live editing: empty query -> show nothing; non-empty -> match
            effective_query="$filter_query"
            if [[ -z "$effective_query" ]]; then
                filtered=()
            else
                local idx
                for ((idx = 0; idx < total_items; idx++)); do
                    if _pm_match "${items[idx]}" "$effective_query"; then
                        filtered+=("$idx")
                    fi
                done
            fi
        else
            # Normal mode: use applied query; empty -> show all
            effective_query="$applied_query"
            if [[ -z "$effective_query" ]]; then
                filtered=("${orig_indices[@]}")
            else
                local idx
                for ((idx = 0; idx < total_items; idx++)); do
                    if _pm_match "${items[idx]}" "$effective_query"; then
                        filtered+=("$idx")
                    fi
                done
            fi
        fi

        # Sort
        local tmpfile
        tmpfile=$(mktemp) || tmpfile=""
        if [[ -n "$tmpfile" ]]; then
            : > "$tmpfile"
            local k id
            if [[ ${#filtered[@]} -gt 0 ]]; then
                for id in "${filtered[@]}"; do
                    case "$sort_mode" in
                        date) k="${epochs[id]:-${id}}" ;;
                        size) k="${sizekb[id]:-0}" ;;
                        name|*) k="${items[id]}|${id}" ;;
                    esac
                    printf "%s\t%s\n" "$k" "$id" >> "$tmpfile"
                done
            fi

            # Build sort key once and stream results into view_indices
            local sort_key
            if [[ "$sort_mode" == "date" || "$sort_mode" == "size" ]]; then
                sort_key="-k1,1n"
                [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1nr"
            else
                sort_key="-k1,1f"
                [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1fr"
            fi

            view_indices=()
            while IFS=$'\t' read -r _key _id; do
                [[ -z "$_id" ]] && continue
                view_indices+=("$_id")
            done < <(LC_ALL=C sort -t $'\t' $sort_key -- "$tmpfile")

            rm -f "$tmpfile"
        else
            view_indices=("${filtered[@]}")
        fi

        # Clamp cursor into visible range
        local visible_count=${#view_indices[@]}
        local max_top
        if [[ $visible_count -gt $items_per_page ]]; then
            max_top=$((visible_count - items_per_page))
        else
            max_top=0
        fi
        [[ $top_index -gt $max_top ]] && top_index=$max_top
        local current_visible=$((visible_count - top_index))
        [[ $current_visible -gt $items_per_page ]] && current_visible=$items_per_page
        if [[ $cursor_pos -ge $current_visible ]]; then
            cursor_pos=$((current_visible > 0 ? current_visible - 1 : 0))
        fi
        [[ $cursor_pos -lt 0 ]] && cursor_pos=0
    }

    # Initial view (default sort)
    rebuild_view

    render_item() {
        # $1: visible row index (0..items_per_page-1 in current window)
        # $2: is_current flag
        local vrow=$1 is_current=$2
        local idx=$((top_index + vrow))
        local real="${view_indices[idx]:--1}"
        [[ $real -lt 0 ]] && return
        local checkbox="$ICON_EMPTY"
        [[ ${selected[real]} == true ]] && checkbox="$ICON_SOLID"

        if [[ $is_current == true ]]; then
            printf "\r\033[2K${BLUE}${ICON_ARROW} %s %s${NC}\n" "$checkbox" "${items[real]}" >&2
        else
            printf "\r\033[2K  %s %s\n" "$checkbox" "${items[real]}" >&2
        fi
    }

    # Draw the complete menu
    draw_menu() {
        printf "\033[H" >&2
        local clear_line="\r\033[2K"

        # Count selections
        local selected_count=0
        for ((i = 0; i < total_items; i++)); do
            [[ ${selected[i]} == true ]] && ((selected_count++))
        done

        # Header
        printf "${clear_line}${PURPLE}%s${NC}  ${GRAY}%d/%d selected${NC}\n" "${title}" "$selected_count" "$total_items" >&2
        # Sort + Filter status
        local sort_label=""
        case "$sort_mode" in
            date) sort_label="Date" ;;
            name) sort_label="Name" ;;
            size) sort_label="Size" ;;
        esac
        local arrow="↑"
        [[ "$sort_reverse" == "true" ]] && arrow="↓"

        local filter_label=""
        if [[ "$filter_mode" == "true" ]]; then
            filter_label="${YELLOW}${filter_query:-}${NC}${GRAY} [editing]${NC}"
        else
            if [[ -n "$applied_query" ]]; then
                if [[ "$searching" == "true" ]]; then
                    filter_label="${GREEN}${applied_query}${NC}${GRAY} [searching…]${NC}"
                else
                    filter_label="${GREEN}${applied_query}${NC}"
                fi
            else
                filter_label="${GRAY}—${NC}"
            fi
        fi
        printf "${clear_line}${GRAY}Sort:${NC} %s %s  ${GRAY}|${NC}  ${GRAY}Filter:${NC} %s\n" "$sort_label" "$arrow" "$filter_label" >&2

        # Filter-mode hint line
        if [[ "$filter_mode" == "true" ]]; then
            printf "${clear_line}${GRAY}Tip:${NC} prefix with ${YELLOW}'${NC} to match from start\n" >&2
        fi

        # Visible slice
        local visible_total=${#view_indices[@]}
        if [[ $visible_total -eq 0 ]]; then
            if [[ "$filter_mode" == "true" ]]; then
                # While editing: do not show "No items available"
                for ((i = 0; i < items_per_page + 2; i++)); do
                    printf "${clear_line}\n" >&2
                done
                printf "${clear_line}${GRAY}Type to filter${NC}  ${GRAY}|${NC}  ${GRAY}Delete${NC} Backspace  ${GRAY}|${NC}  ${GRAY}Enter${NC} Apply  ${GRAY}|${NC}  ${GRAY}ESC${NC} Cancel\n" >&2
                printf "${clear_line}" >&2
                return
            else
                if [[ "$searching" == "true" ]]; then
                    printf "${clear_line}${GRAY}Searching…${NC}\n" >&2
                    for ((i = 0; i < items_per_page + 2; i++)); do
                        printf "${clear_line}\n" >&2
                    done
                    printf "${clear_line}${GRAY}${ICON_NAV_UP}/${ICON_NAV_DOWN}${NC} Navigate  ${GRAY}|${NC}  ${GRAY}Space${NC} Select  ${GRAY}|${NC}  ${GRAY}Enter${NC} Confirm  ${GRAY}|${NC}  ${GRAY}S/s${NC} Sort  ${GRAY}|${NC}  ${GRAY}R/r${NC} Reverse  ${GRAY}|${NC}  ${GRAY}F/f${NC} Filter  ${GRAY}|${NC}  ${GRAY}Q/ESC${NC} Quit\n" >&2
                    printf "${clear_line}" >&2
                    return
                else
                    # Post-search: truly empty list
                    printf "${clear_line}${GRAY}No items available${NC}\n" >&2
                    for ((i = 0; i < items_per_page + 2; i++)); do
                        printf "${clear_line}\n" >&2
                    done
                    printf "${clear_line}${GRAY}${ICON_NAV_UP}/${ICON_NAV_DOWN}${NC} Navigate  ${GRAY}|${NC}  ${GRAY}Space${NC} Select  ${GRAY}|${NC}  ${GRAY}Enter${NC} Confirm  ${GRAY}|${NC}  ${GRAY}S${NC} Sort  ${GRAY}|${NC}  ${GRAY}R/r${NC} Reverse  ${GRAY}|${NC}  ${GRAY}F${NC} Filter  ${GRAY}|${NC}  ${GRAY}Q/ESC${NC} Quit\n" >&2
                    printf "${clear_line}" >&2
                    return
                fi
            fi
        fi

        local visible_count=$((visible_total - top_index))
        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
        [[ $visible_count -le 0 ]] && visible_count=1
        if [[ $cursor_pos -ge $visible_count ]]; then
            cursor_pos=$((visible_count - 1))
            [[ $cursor_pos -lt 0 ]] && cursor_pos=0
        fi

        printf "${clear_line}\n" >&2

        # Items for current window
        local start_idx=$top_index
        local end_idx=$((top_index + items_per_page - 1))
        [[ $end_idx -ge $visible_total ]] && end_idx=$((visible_total - 1))

        for ((i = start_idx; i <= end_idx; i++)); do
            [[ $i -lt 0 ]] && continue
            local is_current=false
            [[ $((i - start_idx)) -eq $cursor_pos ]] && is_current=true
            render_item $((i - start_idx)) $is_current
        done

        # Fill empty slots to clear previous content
        local items_shown=$((end_idx - start_idx + 1))
        [[ $items_shown -lt 0 ]] && items_shown=0
        for ((i = items_shown; i < items_per_page; i++)); do
            printf "${clear_line}\n" >&2
        done

        printf "${clear_line}\n" >&2
        # Footer with wrapped controls
        local sep="  ${GRAY}|${NC}  "
        if [[ "$filter_mode" == "true" ]]; then
            local -a _segs_filter=(
                "${GRAY}Type to filter${NC}"
                "${GRAY}Delete${NC} Backspace"
                "${GRAY}Enter${NC} Apply"
                "${GRAY}ESC${NC} Cancel"
            )
            _print_wrapped_controls "$sep" "${_segs_filter[@]}"
        else
            local -a _segs_normal=(
                "${GRAY}${ICON_NAV_UP}/${ICON_NAV_DOWN}${NC} Navigate"
                "${GRAY}Space${NC} Select"
                "${GRAY}Enter${NC} Confirm"
                "${GRAY}S/s${NC} Sort"
                "${GRAY}R/r${NC} Reverse"
                "${GRAY}F/f${NC} Filter"
                "${GRAY}A${NC} All"
                "${GRAY}N${NC} None"
                "${GRAY}Q/ESC${NC} Quit"
            )
            _print_wrapped_controls "$sep" "${_segs_normal[@]}"
        fi
        printf "${clear_line}" >&2
    }

    # Show help screen
    show_help() {
        printf "\033[H\033[J" >&2
        cat >&2 << EOF
Help - Navigation Controls
==========================

  ${ICON_NAV_UP} / ${ICON_NAV_DOWN}      Navigate up/down
  Space              Select/deselect item
  Enter              Confirm selection
  S                  Change sort mode (Date / Name / Size)
  R                  Reverse current sort (asc/desc)
  F                  Toggle filter mode, type to filter (case-insensitive; prefix with ' to match from start)
  A                  Select all (visible items)
  N                  Deselect all (visible items)
  Delete             Backspace filter (in filter mode)
  Q / ESC            Exit (ESC exits filter mode first)

Press any key to continue...
EOF
        read -n 1 -s >&2
    }

    # Main interaction loop
    while true; do
        draw_menu
        local key
        key=$(read_key)

        case "$key" in
            "QUIT")
            if [[ "$filter_mode" == "true" ]]; then
                filter_mode="false"
                unset MOLE_READ_KEY_FORCE_CHAR
                filter_query=""
                applied_query=""
                top_index=0; cursor_pos=0
                rebuild_view
                continue
            fi
            cleanup
            return 1
            ;;
            "UP")
                if [[ ${#view_indices[@]} -eq 0 ]]; then
                    :
                elif [[ $cursor_pos -gt 0 ]]; then
                    ((cursor_pos--))
                elif [[ $top_index -gt 0 ]]; then
                    ((top_index--))
                fi
                ;;
            "DOWN")
                if [[ ${#view_indices[@]} -eq 0 ]]; then
                    :
                else
                    local absolute_index=$((top_index + cursor_pos))
                    local last_index=$((${#view_indices[@]} - 1))
                    if [[ $absolute_index -lt $last_index ]]; then
                        local visible_count=$((${#view_indices[@]} - top_index))
                        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page

                        if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                            ((cursor_pos++))
                        elif [[ $((top_index + visible_count)) -lt ${#view_indices[@]} ]]; then
                            ((top_index++))
                            visible_count=$((${#view_indices[@]} - top_index))
                            [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                            if [[ $cursor_pos -ge $visible_count ]]; then
                                cursor_pos=$((visible_count - 1))
                            fi
                        fi
                    fi
                fi
                ;;
            "SPACE")
                local idx=$((top_index + cursor_pos))
                if [[ $idx -lt ${#view_indices[@]} ]]; then
                    local real="${view_indices[idx]}"
                    if [[ ${selected[real]} == true ]]; then
                        selected[real]=false
                    else
                        selected[real]=true
                    fi
                fi
                ;;
            "ALL")
                # Select only currently visible (filtered) rows
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    for real in "${view_indices[@]}"; do
                        selected[real]=true
                    done
                fi
                ;;
            "NONE")
                # Deselect only currently visible (filtered) rows
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    for real in "${view_indices[@]}"; do
                        selected[real]=false
                    done
                fi
                ;;
            "RETRY")
                # 'R' toggles reverse order
                if [[ "$sort_reverse" == "true" ]]; then
                    sort_reverse="false"
                else
                    sort_reverse="true"
                fi
                rebuild_view
                ;;
            "HELP") show_help ;;
            "CHAR:s"|"CHAR:S")
                if [[ "$filter_mode" == "true" ]]; then
                    local ch="${key#CHAR:}"
                    filter_query+="$ch"
                else
                    case "$sort_mode" in
                        date) sort_mode="name" ;;
                        name) sort_mode="size" ;;
                        size) sort_mode="date" ;;
                    esac
                    rebuild_view
                fi
                ;;
            "CHAR:f"|"CHAR:F")
                if [[ "$filter_mode" == "true" ]]; then
                    filter_query+="f"
                else
                    filter_mode="true"
                    export MOLE_READ_KEY_FORCE_CHAR=1
                    filter_query=""       # start empty -> 0 results
                    top_index=0           # reset viewport
                    cursor_pos=0
                    rebuild_view
                fi
                ;;
            "CHAR:r")
                # lower-case r: behave like reverse when NOT in filter mode
                if [[ "$filter_mode" == "true" ]]; then
                    filter_query+="r"
                else
                    if [[ "$sort_reverse" == "true" ]]; then
                        sort_reverse="false"
                    else
                        sort_reverse="true"
                    fi
                    rebuild_view
                fi
                ;;
            "DELETE")
                # Backspace filter
                if [[ "$filter_mode" == "true" && -n "$filter_query" ]]; then
                    filter_query="${filter_query%?}"
                fi
                ;;
            CHAR:*)
                if [[ "$filter_mode" == "true" ]]; then
                    local ch="${key#CHAR:}"
                    # avoid accidental leading spaces
                    if [[ -n "$filter_query" || "$ch" != " " ]]; then
                        filter_query+="$ch"
                    fi
                fi
                ;;
            "ENTER")
                if [[ "$filter_mode" == "true" ]]; then
                    applied_query="$filter_query"
                    filter_mode="false"
                    unset MOLE_READ_KEY_FORCE_CHAR
                    top_index=0; cursor_pos=0

                    searching="true"
                    draw_menu              # paint "searching..."
                    drain_pending_input    # drop any extra keypresses (e.g., double-Enter)
                    rebuild_view
                    searching="false"
                    draw_menu
                    continue
                fi
                local -a selected_indices=()
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        selected_indices+=("$i")
                    fi
                done

                # Allow empty selection - don't auto-select cursor position
                local final_result=""
                if [[ ${#selected_indices[@]} -gt 0 ]]; then
                    local IFS=','
                    final_result="${selected_indices[*]}"
                fi

                # Remove the trap to avoid cleanup on normal exit
                trap - EXIT INT TERM

                # Store result in global variable
                MOLE_SELECTION_RESULT="$final_result"

                # Manually cleanup terminal before returning
                restore_terminal

                return 0
                ;;
        esac
    done
}

# Export function for external use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library file. Source it from other scripts." >&2
    exit 1
fi
