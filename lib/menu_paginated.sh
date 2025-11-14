#!/bin/bash
# Paginated menu with arrow key navigation

set -euo pipefail

# Terminal control functions
enter_alt_screen() {
    if command -v tput > /dev/null 2>&1 && [[ -t 1 ]]; then
        tput smcup 2> /dev/null || true
    fi
}
leave_alt_screen() {
    if command -v tput > /dev/null 2>&1 && [[ -t 1 ]]; then
        tput rmcup 2> /dev/null || true
    fi
}

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

# Non-blocking input drain (bash 3.2) - improved for mouse wheel
drain_pending_input() {
    local _k drained=0
    # Multiple passes to handle mouse wheel burst sequences
    while IFS= read -r -s -n 1 -t 0.01 _k 2> /dev/null; do
        ((drained++))
        [[ $drained -gt 1000 ]] && break
    done
    # Second pass with shorter timeout
    while IFS= read -r -s -n 1 -t 0.001 _k 2> /dev/null; do
        ((drained++))
        [[ $drained -gt 1500 ]] && break
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
    local filter_mode="false"                         # filter mode toggle
    local sort_mode="${MOLE_MENU_SORT_DEFAULT:-date}" # date|name|size
    local sort_reverse="false"
    # Live query vs applied query
    local applied_query=""
    local searching="false"

    # Metadata (optional)
    # epochs[i]   -> last_used_epoch (numeric) for item i
    # sizekb[i]   -> size in KB (numeric) for item i
    local -a epochs=()
    local -a sizekb=()
    local has_metadata="false"
    if [[ -n "${MOLE_MENU_META_EPOCHS:-}" ]]; then
        while IFS= read -r v; do epochs+=("${v:-0}"); done < <(_pm_parse_csv_to_array "$MOLE_MENU_META_EPOCHS")
        has_metadata="true"
    fi
    if [[ -n "${MOLE_MENU_META_SIZEKB:-}" ]]; then
        while IFS= read -r v; do sizekb+=("${v:-0}"); done < <(_pm_parse_csv_to_array "$MOLE_MENU_META_SIZEKB")
        has_metadata="true"
    fi

    # If no metadata, force name sorting and disable sorting controls
    if [[ "$has_metadata" == "false" && "$sort_mode" != "name" ]]; then
        sort_mode="name"
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
        for ((i = 0; i < len; i++)); do
            c="${s:i:1}"
            case "$c" in
                '\' | '*' | '?' | '[' | ']') out+="\\$c" ;;
                *) out+="$c" ;;
            esac
        done
        printf '%s' "$out"
    }

    # Case-insensitive fuzzy match (substring search)
    _pm_match() {
        local hay="$1" q="$2"
        q="$(_pm_escape_glob "$q")"
        local pat="*${q}*"

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
        local sep="$1"
        shift
        local -a segs=("$@")

        local cols="${COLUMNS:-}"
        [[ -z "$cols" ]] && cols=$(tput cols 2> /dev/null || echo 80)

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
            if (($(_strip_ansi_len "$candidate") > cols)); then
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
            # Live editing: empty query -> show all items
            effective_query="$filter_query"
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

        # Sort (skip if no metadata)
        if [[ "$has_metadata" == "false" ]]; then
            # No metadata: just use filtered list (already sorted by name naturally)
            view_indices=("${filtered[@]}")
        elif [[ ${#filtered[@]} -eq 0 ]]; then
            view_indices=()
        else
            # Build sort key
            local sort_key
            if [[ "$sort_mode" == "date" ]]; then
                # Date: ascending by default (oldest first)
                sort_key="-k1,1n"
                [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1nr"
            elif [[ "$sort_mode" == "size" ]]; then
                # Size: descending by default (largest first)
                sort_key="-k1,1nr"
                [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1n"
            else
                # Name: ascending by default (A to Z)
                sort_key="-k1,1f"
                [[ "$sort_reverse" == "true" ]] && sort_key="-k1,1fr"
            fi

            # Create temporary file for sorting
            local tmpfile
            tmpfile=$(mktemp 2> /dev/null) || tmpfile=""
            if [[ -n "$tmpfile" ]]; then
                local k id
                for id in "${filtered[@]}"; do
                    case "$sort_mode" in
                        date) k="${epochs[id]:-0}" ;;
                        size) k="${sizekb[id]:-0}" ;;
                        name | *) k="${items[id]}|${id}" ;;
                    esac
                    printf "%s\t%s\n" "$k" "$id" >> "$tmpfile"
                done

                view_indices=()
                while IFS=$'\t' read -r _key _id; do
                    [[ -z "$_id" ]] && continue
                    view_indices+=("$_id")
                done < <(LC_ALL=C sort -t $'\t' $sort_key -- "$tmpfile" 2> /dev/null)

                rm -f "$tmpfile"
            else
                # Fallback: no sorting
                view_indices=("${filtered[@]}")
            fi
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

        # Header only
        printf "${clear_line}${PURPLE}%s${NC}  ${GRAY}%d/%d selected${NC}\n" "${title}" "$selected_count" "$total_items" >&2

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
                    printf "${clear_line}${GRAY}${ICON_NAV_UP}/${ICON_NAV_DOWN}${NC} Nav  ${GRAY}|${NC}  ${GRAY}Space${NC} Select  ${GRAY}|${NC}  ${GRAY}Enter${NC} Confirm  ${GRAY}|${NC}  ${GRAY}/${NC} Filter  ${GRAY}|${NC}  ${GRAY}S${NC} Sort  ${GRAY}|${NC}  ${GRAY}Q${NC} Quit\n" >&2
                    printf "${clear_line}" >&2
                    return
                else
                    # Post-search: truly empty list
                    printf "${clear_line}${GRAY}No items available${NC}\n" >&2
                    for ((i = 0; i < items_per_page + 2; i++)); do
                        printf "${clear_line}\n" >&2
                    done
                    printf "${clear_line}${GRAY}${ICON_NAV_UP}/${ICON_NAV_DOWN}${NC} Nav  ${GRAY}|${NC}  ${GRAY}Space${NC} Select  ${GRAY}|${NC}  ${GRAY}Enter${NC} Confirm  ${GRAY}|${NC}  ${GRAY}/${NC} Filter  ${GRAY}|${NC}  ${GRAY}S${NC} Sort  ${GRAY}|${NC}  ${GRAY}Q${NC} Quit\n" >&2
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

        # Build sort and filter status
        local sort_label=""
        case "$sort_mode" in
            date) sort_label="Date" ;;
            name) sort_label="Name" ;;
            size) sort_label="Size" ;;
        esac
        local arrow="↑"
        [[ "$sort_reverse" == "true" ]] && arrow="↓"
        local sort_status="${sort_label} ${arrow}"

        local filter_status=""
        if [[ "$filter_mode" == "true" ]]; then
            filter_status="${YELLOW}${filter_query:-}${NC}"
        elif [[ -n "$applied_query" ]]; then
            filter_status="${GREEN}${applied_query}${NC}"
        else
            filter_status="${GRAY}—${NC}"
        fi

        # Footer with two lines: basic controls and advanced options
        local sep="  ${GRAY}|${NC}  "
        if [[ "$filter_mode" == "true" ]]; then
            # Filter mode: single line with all filter controls
            local -a _segs_filter=(
                "${GRAY}Filter Input:${NC} ${filter_status}"
                "${GRAY}Delete${NC} Back"
                "${GRAY}Enter${NC} Apply"
                "${GRAY}/${NC} Clear"
                "${GRAY}ESC${NC} Cancel"
            )
            _print_wrapped_controls "$sep" "${_segs_filter[@]}"
        else
            # Normal mode
            if [[ "$has_metadata" == "true" ]]; then
                # With metadata: two lines (basic + advanced)
                local -a _segs_basic=(
                    "${GRAY}${ICON_NAV_UP}/${ICON_NAV_DOWN}${NC} Navigate"
                    "${GRAY}Space${NC} Select"
                    "${GRAY}Enter${NC} Confirm"
                    "${GRAY}Q/ESC${NC} Quit"
                )
                _print_wrapped_controls "$sep" "${_segs_basic[@]}"
                local -a _segs_advanced=(
                    "${GRAY}S${NC} ${sort_status}"
                    "${GRAY}R${NC} Reverse"
                    "${GRAY}/${NC} Filter"
                )
                _print_wrapped_controls "$sep" "${_segs_advanced[@]}"
            else
                # Without metadata: single line (basic only)
                local -a _segs_simple=(
                    "${GRAY}${ICON_NAV_UP}/${ICON_NAV_DOWN}${NC} Navigate"
                    "${GRAY}Space${NC} Select"
                    "${GRAY}Enter${NC} Confirm"
                    "${GRAY}/${NC} Filter"
                    "${GRAY}Q/ESC${NC} Quit"
                )
                _print_wrapped_controls "$sep" "${_segs_simple[@]}"
            fi
        fi
        printf "${clear_line}" >&2
    }

    # Main interaction loop
    while true; do
        draw_menu
        # Drain any pending input to prevent mouse wheel scroll issues
        drain_pending_input
        local key
        key=$(read_key)

        case "$key" in
            "QUIT")
                if [[ "$filter_mode" == "true" ]]; then
                    filter_mode="false"
                    unset MOLE_READ_KEY_FORCE_CHAR
                    filter_query=""
                    applied_query=""
                    top_index=0
                    cursor_pos=0
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
            "RETRY")
                # 'R' toggles reverse order (only if metadata available)
                if [[ "$has_metadata" == "true" ]]; then
                    if [[ "$sort_reverse" == "true" ]]; then
                        sort_reverse="false"
                    else
                        sort_reverse="true"
                    fi
                    rebuild_view
                fi
                ;;
            "CHAR:s" | "CHAR:S")
                if [[ "$filter_mode" == "true" ]]; then
                    local ch="${key#CHAR:}"
                    filter_query+="$ch"
                elif [[ "$has_metadata" == "true" ]]; then
                    # Cycle sort mode (only if metadata available)
                    case "$sort_mode" in
                        date) sort_mode="name" ;;
                        name) sort_mode="size" ;;
                        size) sort_mode="date" ;;
                    esac
                    rebuild_view
                fi
                ;;
            "FILTER")
                # Trigger filter mode with /
                filter_mode="true"
                export MOLE_READ_KEY_FORCE_CHAR=1
                filter_query=""
                top_index=0
                cursor_pos=0
                rebuild_view
                ;;
            "CHAR:f" | "CHAR:F")
                if [[ "$filter_mode" == "true" ]]; then
                    filter_query+="${key#CHAR:}"
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
                    # Special handling for /: clear filter
                    if [[ "$ch" == "/" ]]; then
                        filter_query=""
                        rebuild_view
                    # avoid accidental leading spaces
                    elif [[ -n "$filter_query" || "$ch" != " " ]]; then
                        filter_query+="$ch"
                    fi
                fi
                ;;
            "ENTER")
                if [[ "$filter_mode" == "true" ]]; then
                    applied_query="$filter_query"
                    filter_mode="false"
                    unset MOLE_READ_KEY_FORCE_CHAR
                    top_index=0
                    cursor_pos=0

                    searching="true"
                    draw_menu           # paint "searching..."
                    drain_pending_input # drop any extra keypresses (e.g., double-Enter)
                    rebuild_view
                    searching="false"
                    draw_menu
                    continue
                fi
                # In normal mode: smart Enter behavior
                # 1. Check if any items are already selected
                local has_selection=false
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        has_selection=true
                        break
                    fi
                done

                # 2. If nothing selected, auto-select current item
                if [[ $has_selection == false ]]; then
                    local idx=$((top_index + cursor_pos))
                    if [[ $idx -lt ${#view_indices[@]} ]]; then
                        local real="${view_indices[idx]}"
                        selected[real]=true
                    fi
                fi

                # 3. Confirm and exit with current selections
                local -a selected_indices=()
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        selected_indices+=("$i")
                    fi
                done

                local final_result=""
                if [[ ${#selected_indices[@]} -gt 0 ]]; then
                    local IFS=','
                    final_result="${selected_indices[*]}"
                fi

                trap - EXIT INT TERM
                MOLE_SELECTION_RESULT="$final_result"
                restore_terminal
                return 0
                ;;
            "HELP")
                # Removed help screen, users can explore the interface
                ;;
        esac
    done
}

# Export function for external use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library file. Source it from other scripts." >&2
    exit 1
fi
