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

# Get terminal height with fallback
_pm_get_terminal_height() {
    local height=0

    # Try stty size first (most reliable, real-time)
    # Use </dev/tty to ensure we read from terminal even if stdin is redirected
    if [[ -t 0 ]] || [[ -t 2 ]]; then
        height=$(stty size < /dev/tty 2> /dev/null | awk '{print $1}')
    fi

    # Fallback to tput
    if [[ -z "$height" || $height -le 0 ]]; then
        if command -v tput > /dev/null 2>&1; then
            height=$(tput lines 2> /dev/null || echo "24")
        else
            height=24
        fi
    fi

    echo "$height"
}

# Calculate dynamic items per page based on terminal height
_pm_calculate_items_per_page() {
    local term_height=$(_pm_get_terminal_height)
    # Reserved: header(1) + blank(1) + blank(1) + footer(1-2) = 4-5 rows
    # Use 5 to be safe (leaves 1 row buffer when footer wraps to 2 lines)
    local reserved=5
    local available=$((term_height - reserved))

    # Ensure minimum and maximum bounds
    if [[ $available -lt 1 ]]; then
        echo 1
    elif [[ $available -gt 50 ]]; then
        echo 50
    else
        echo "$available"
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
    local items_per_page=$(_pm_calculate_items_per_page)
    local cursor_pos=0
    local top_index=0
    local sort_mode="${MOLE_MENU_SORT_MODE:-${MOLE_MENU_SORT_DEFAULT:-date}}" # date|name|size
    local sort_reverse="${MOLE_MENU_SORT_REVERSE:-false}"
    local filter_query="" # For / search filter mode

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

    local -a selected=()
    local selected_count=0 # Cache selection count to avoid O(n) loops on every draw

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
                # Only count if not already selected (handles duplicates)
                if [[ ${selected[idx]} != true ]]; then
                    selected[idx]=true
                    ((selected_count++))
                fi
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
        export MOLE_MENU_SORT_MODE="$sort_mode"
        export MOLE_MENU_SORT_REVERSE="$sort_reverse"
        restore_terminal
    }

    # Interrupt handler
    # shellcheck disable=SC2329
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
    # shellcheck disable=SC2329
    print_line() { printf "\r\033[2K%s\n" "$1" >&2; }

    # Print footer lines wrapping only at separators
    _print_wrapped_controls() {
        local sep="$1"
        shift
        local -a segs=("$@")

        local cols="${COLUMNS:-}"
        [[ -z "$cols" ]] && cols=$(tput cols 2> /dev/null || echo 80)
        [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

        _strip_ansi_len() {
            local text="$1"
            local stripped
            stripped=$(printf "%s" "$text" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*[A-Za-z]/,""); print}' || true)
            [[ -z "$stripped" ]] && stripped="$text"
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
            local candidate_len
            candidate_len=$(_strip_ansi_len "$candidate")
            [[ -z "$candidate_len" ]] && candidate_len=0
            if ((candidate_len > cols)); then
                printf "%s%s\n" "$clear_line" "$line" >&2
                line="$s"
            else
                line="$candidate"
            fi
        done
        printf "%s%s\n" "$clear_line" "$line" >&2
    }

    # Rebuild the view_indices applying sort
    rebuild_view() {
        # Sort (skip if no metadata)
        if [[ "$has_metadata" == "false" ]]; then
            # No metadata: just use original indices
            view_indices=("${orig_indices[@]}")
        elif [[ ${#orig_indices[@]} -eq 0 ]]; then
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
                for id in "${orig_indices[@]}"; do
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
                view_indices=("${orig_indices[@]}")
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
            printf "\r\033[2K${CYAN}${ICON_ARROW} %s %s${NC}\n" "$checkbox" "${items[real]}" >&2
        else
            printf "\r\033[2K  %s %s\n" "$checkbox" "${items[real]}" >&2
        fi
    }

    # Draw the complete menu
    draw_menu() {
        # Recalculate items_per_page dynamically to handle window resize
        items_per_page=$(_pm_calculate_items_per_page)

        printf "\033[H" >&2
        local clear_line="\r\033[2K"

        # Use cached selection count (maintained incrementally on toggle)
        # No need to loop through all items anymore!

        # Header only
        printf "${clear_line}${PURPLE_BOLD}%s${NC}  ${GRAY}%d/%d selected${NC}\n" "${title}" "$selected_count" "$total_items" >&2

        # Visible slice
        local visible_total=${#view_indices[@]}
        if [[ $visible_total -eq 0 ]]; then
            printf "${clear_line}No items available\n" >&2
            for ((i = 0; i < items_per_page; i++)); do
                printf "${clear_line}\n" >&2
            done
            printf "${clear_line}${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}  |  Space  |  Enter  |  Q Exit${NC}\n" >&2
            printf "${clear_line}" >&2
            return
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

        # Build sort status
        local sort_label=""
        case "$sort_mode" in
            date) sort_label="Date" ;;
            name) sort_label="Name" ;;
            size) sort_label="Size" ;;
        esac
        local sort_status="${sort_label}"

        # Footer: single line with controls
        local sep=" ${GRAY}|${NC} "

        # Helper to calculate display length without ANSI codes
        _calc_len() {
            local text="$1"
            local stripped
            stripped=$(printf "%s" "$text" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*[A-Za-z]/,""); print}')
            printf "%d" "${#stripped}"
        }

        # Common menu items
        local nav="${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}${NC}"
        local space_select="${GRAY}Space Select${NC}"
        local enter="${GRAY}Enter${NC}"
        local exit="${GRAY}Q Exit${NC}"
        local filter_hint="${GRAY}/ Filter${NC}"

        local reverse_arrow="↑"
        [[ "$sort_reverse" == "true" ]] && reverse_arrow="↓"

        local refresh="${GRAY}R Refresh${NC}"
        local sort_ctrl="${GRAY}S ${sort_status}${NC}"
        local order_ctrl="${GRAY}O ${reverse_arrow}${NC}"

        if [[ "$has_metadata" == "true" ]]; then
            # With metadata: show sort controls
            local term_width="${COLUMNS:-}"
            [[ -z "$term_width" ]] && term_width=$(tput cols 2> /dev/null || echo 80)
            [[ "$term_width" =~ ^[0-9]+$ ]] || term_width=80

            # Full controls
            local -a _segs=("$nav" "$space_select" "$enter" "$filter_hint" "$refresh" "$sort_ctrl" "$order_ctrl" "$exit")

            # Calculate width
            local total_len=0 seg_count=${#_segs[@]}
            for i in "${!_segs[@]}"; do
                total_len=$((total_len + $(_calc_len "${_segs[i]}")))
                [[ $i -lt $((seg_count - 1)) ]] && total_len=$((total_len + 3))
            done

            # Level 1: Remove "Space Select" if too wide
            if [[ $total_len -gt $term_width ]]; then
                _segs=("$nav" "$enter" "$refresh" "$sort_ctrl" "$order_ctrl" "$exit")

                total_len=0
                seg_count=${#_segs[@]}
                for i in "${!_segs[@]}"; do
                    total_len=$((total_len + $(_calc_len "${_segs[i]}")))
                    [[ $i -lt $((seg_count - 1)) ]] && total_len=$((total_len + 3))
                done

                # Level 2: Remove sort label if still too wide
                if [[ $total_len -gt $term_width ]]; then
                    _segs=("$nav" "$enter" "$refresh" "$order_ctrl" "$exit")
                fi
            fi

            _print_wrapped_controls "$sep" "${_segs[@]}"
        else
            # Without metadata: basic controls
            local -a _segs_simple=("$nav" "$space_select" "$enter" "$filter_hint" "$refresh" "$exit")
            _print_wrapped_controls "$sep" "${_segs_simple[@]}"
        fi
        printf "${clear_line}" >&2
    }

    # Track previous cursor position for incremental rendering
    local prev_cursor_pos=$cursor_pos
    local prev_top_index=$top_index
    local need_full_redraw=true

    # Main interaction loop
    while true; do
        if [[ "$need_full_redraw" == "true" ]]; then
            draw_menu
            need_full_redraw=false
            # Update tracking variables after full redraw
            prev_cursor_pos=$cursor_pos
            prev_top_index=$top_index
        fi

        local key
        key=$(read_key)

        case "$key" in
            "QUIT")
                cleanup
                return 1
                ;;
            "UP")
                if [[ ${#view_indices[@]} -eq 0 ]]; then
                    :
                elif [[ $cursor_pos -gt 0 ]]; then
                    # Simple cursor move - only redraw affected rows
                    local old_cursor=$cursor_pos
                    ((cursor_pos--))
                    local new_cursor=$cursor_pos

                    # Calculate terminal row positions (+3: row 1=header, row 2=blank, row 3=first item)
                    local old_row=$((old_cursor + 3))
                    local new_row=$((new_cursor + 3))

                    # Quick redraw: update only the two affected rows
                    printf "\033[%d;1H" "$old_row" >&2
                    render_item "$old_cursor" false
                    printf "\033[%d;1H" "$new_row" >&2
                    render_item "$new_cursor" true

                    # CRITICAL: Move cursor to footer to avoid visual artifacts
                    printf "\033[%d;1H" "$((items_per_page + 4))" >&2

                    prev_cursor_pos=$cursor_pos
                    continue # Skip full redraw
                elif [[ $top_index -gt 0 ]]; then
                    # Scroll up - redraw visible items only
                    ((top_index--))

                    # Redraw all visible items (faster than full screen redraw)
                    local start_idx=$top_index
                    local end_idx=$((top_index + items_per_page - 1))
                    local visible_total=${#view_indices[@]}
                    [[ $end_idx -ge $visible_total ]] && end_idx=$((visible_total - 1))

                    for ((i = start_idx; i <= end_idx; i++)); do
                        local row=$((i - start_idx + 3)) # +3 for header
                        printf "\033[%d;1H" "$row" >&2
                        local is_current=false
                        [[ $((i - start_idx)) -eq $cursor_pos ]] && is_current=true
                        render_item $((i - start_idx)) $is_current
                    done

                    # Move cursor to footer
                    printf "\033[%d;1H" "$((items_per_page + 4))" >&2

                    prev_cursor_pos=$cursor_pos
                    prev_top_index=$top_index
                    continue
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
                            # Simple cursor move - only redraw affected rows
                            local old_cursor=$cursor_pos
                            ((cursor_pos++))
                            local new_cursor=$cursor_pos

                            # Calculate terminal row positions (+3: row 1=header, row 2=blank, row 3=first item)
                            local old_row=$((old_cursor + 3))
                            local new_row=$((new_cursor + 3))

                            # Quick redraw: update only the two affected rows
                            printf "\033[%d;1H" "$old_row" >&2
                            render_item "$old_cursor" false
                            printf "\033[%d;1H" "$new_row" >&2
                            render_item "$new_cursor" true

                            # CRITICAL: Move cursor to footer to avoid visual artifacts
                            printf "\033[%d;1H" "$((items_per_page + 4))" >&2

                            prev_cursor_pos=$cursor_pos
                            continue # Skip full redraw
                        elif [[ $((top_index + visible_count)) -lt ${#view_indices[@]} ]]; then
                            # Scroll down - redraw visible items only
                            ((top_index++))
                            visible_count=$((${#view_indices[@]} - top_index))
                            [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                            if [[ $cursor_pos -ge $visible_count ]]; then
                                cursor_pos=$((visible_count - 1))
                            fi

                            # Redraw all visible items (faster than full screen redraw)
                            local start_idx=$top_index
                            local end_idx=$((top_index + items_per_page - 1))
                            local visible_total=${#view_indices[@]}
                            [[ $end_idx -ge $visible_total ]] && end_idx=$((visible_total - 1))

                            for ((i = start_idx; i <= end_idx; i++)); do
                                local row=$((i - start_idx + 3)) # +3 for header
                                printf "\033[%d;1H" "$row" >&2
                                local is_current=false
                                [[ $((i - start_idx)) -eq $cursor_pos ]] && is_current=true
                                render_item $((i - start_idx)) $is_current
                            done

                            # Move cursor to footer
                            printf "\033[%d;1H" "$((items_per_page + 4))" >&2

                            prev_cursor_pos=$cursor_pos
                            prev_top_index=$top_index
                            continue
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
                        ((selected_count--))
                    else
                        selected[real]=true
                        ((selected_count++))
                    fi

                    # Incremental update: only redraw header (for count) and current row
                    # Header is at row 1
                    printf "\033[1;1H\033[2K${PURPLE_BOLD}%s${NC}  ${GRAY}%d/%d selected${NC}\n" "${title}" "$selected_count" "$total_items" >&2

                    # Redraw current item row (+3: row 1=header, row 2=blank, row 3=first item)
                    local item_row=$((cursor_pos + 3))
                    printf "\033[%d;1H" "$item_row" >&2
                    render_item "$cursor_pos" true

                    # Move cursor to footer to avoid visual artifacts (items + header + 2 blanks)
                    printf "\033[%d;1H" "$((items_per_page + 4))" >&2

                    continue # Skip full redraw
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
                    need_full_redraw=true
                fi
                ;;
            "CHAR:s" | "CHAR:S")
                if [[ "$has_metadata" == "true" ]]; then
                    # Cycle sort mode (only if metadata available)
                    case "$sort_mode" in
                        date) sort_mode="name" ;;
                        name) sort_mode="size" ;;
                        size) sort_mode="date" ;;
                    esac
                    rebuild_view
                    need_full_redraw=true
                fi
                ;;
            "CHAR:j")
                # Down navigation (vim style)
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    local absolute_index=$((top_index + cursor_pos))
                    local last_index=$((${#view_indices[@]} - 1))
                    if [[ $absolute_index -lt $last_index ]]; then
                        local visible_count=$((${#view_indices[@]} - top_index))
                        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                        if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                            ((cursor_pos++))
                        elif [[ $((top_index + visible_count)) -lt ${#view_indices[@]} ]]; then
                            ((top_index++))
                        fi
                        need_full_redraw=true
                    fi
                fi
                ;;
            "CHAR:k")
                # Up navigation (vim style)
                if [[ ${#view_indices[@]} -gt 0 ]]; then
                    if [[ $cursor_pos -gt 0 ]]; then
                        ((cursor_pos--))
                        need_full_redraw=true
                    elif [[ $top_index -gt 0 ]]; then
                        ((top_index--))
                        need_full_redraw=true
                    fi
                fi
                ;;
            "CHAR:r" | "CHAR:R")
                # Trigger Refresh signal
                cleanup
                return 10
                ;;
            "CHAR:o" | "CHAR:O")
                if [[ "$has_metadata" == "true" ]]; then
                    # O toggles reverse order
                    if [[ "$sort_reverse" == "true" ]]; then
                        sort_reverse="false"
                    else
                        sort_reverse="true"
                    fi
                    rebuild_view
                    need_full_redraw=true
                fi
                ;;
            "CHAR:/")
                # Enter filter mode - type to search items
                filter_query=""

                # Save original view_indices to restore on cancel
                local -a orig_view_indices=("${view_indices[@]}")

                while true; do
                    # Show filter prompt and current query
                    local filter_display="$filter_query"
                    [[ -z "$filter_display" ]] && filter_display="(type to filter...)"

                    # Redraw menu with filter prompt
                    items_per_page=$(_pm_calculate_items_per_page)
                    printf "\033[H" >&2
                    local clear_line="\r\033[2K"

                    # Header with filter prompt
                    printf "${clear_line}${PURPLE_BOLD}%s${NC}  ${GRAY}%d/%d selected${NC}\n" "${title}" "$selected_count" "$total_items" >&2
                    printf "${clear_line}${CYAN}Filter: ${NC}${YELLOW}%s${NC}\n" "$filter_display" >&2
                    printf "${clear_line}\n" >&2

                    # Build filtered view_indices
                    view_indices=()
                    if [[ -z "$filter_query" ]]; then
                        # No filter - show all
                        view_indices=("${orig_view_indices[@]}")
                    else
                        # Filter items by name (case-insensitive substring match)
                        # Use tr for bash 3.2 compatibility (macOS)
                        local filter_lc=$(echo "$filter_query" | tr '[:upper:]' '[:lower:]')
                        for idx in "${orig_view_indices[@]}"; do
                            local item_name="${items[idx]}"
                            local name_lc=$(echo "$item_name" | tr '[:upper:]' '[:lower:]')
                            if [[ "$name_lc" == *"$filter_lc"* ]]; then
                                view_indices+=("$idx")
                            fi
                        done
                    fi

                    # Display filtered items
                    local visible_total=${#view_indices[@]}
                    if [[ $visible_total -eq 0 ]]; then
                        printf "${clear_line}No matching items\n" >&2
                        for ((i = 0; i < items_per_page; i++)); do
                            printf "${clear_line}\n" >&2
                        done
                        printf "${clear_line}${GRAY}Press Esc to clear filter, Enter to apply${NC}\n" >&2
                        printf "${clear_line}" >&2
                    else
                        # Show filtered results (same display logic as draw_menu)
                        local visible_count=$((visible_total - top_index))
                        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                        [[ $visible_count -le 0 ]] && visible_count=1

                        local start_idx=$top_index
                        local end_idx=$((top_index + items_per_page - 1))
                        [[ $end_idx -ge $visible_total ]] && end_idx=$((visible_total - 1))

                        for ((i = start_idx; i <= end_idx; i++)); do
                            [[ $i -lt 0 ]] && continue
                            local is_current=false
                            [[ $((i - start_idx)) -eq $cursor_pos ]] && is_current=true
                            render_item $((i - start_idx)) $is_current
                        done

                        local items_shown=$((end_idx - start_idx + 1))
                        [[ $items_shown -lt 0 ]] && items_shown=0
                        for ((i = items_shown; i < items_per_page; i++)); do
                            printf "${clear_line}\n" >&2
                        done

                        printf "${clear_line}\n" >&2
                        printf "${clear_line}${GRAY}Press Esc to cancel, Enter to apply${NC}\n" >&2
                    fi
                    printf "${clear_line}" >&2

                    # Read one character (with timeout for escape sequences)
                    local fkey rest
                    IFS= read -r -s -n 1 fkey 2>/dev/null || { fkey=""; break; }
                    read_status=$?

                    if [[ $read_status -ne 0 ]]; then
                        break
                    fi

                    case "$fkey" in
                        $'\x1b') # Escape key
                            # Cancel filter - restore original view
                            view_indices=("${orig_view_indices[@]}")
                            filter_query=""
                            need_full_redraw=true
                            break
                            ;;
                        $'\n' | $'\r') # Enter key
                            # Apply filter and exit filter mode
                            need_full_redraw=true
                            break
                            ;;
                        $'\x7f' | $'\x08') # Backspace/Delete
                            # Remove last character from filter
                            if [[ -n "$filter_query" ]]; then
                                filter_query="${filter_query%?}"
                            fi
                            ;;
                        [[:print:]])
                            # Add character to filter (limit to 50 chars)
                            if [[ ${#filter_query} -lt 50 ]]; then
                                filter_query+="$fkey"
                            fi
                            ;;
                    esac

                    # Small delay to prevent excessive CPU usage
                    sleep 0.01
                done
                ;;
            "ENTER")
                # Smart Enter behavior
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
                        ((selected_count++))
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
                export MOLE_MENU_SORT_MODE="$sort_mode"
                export MOLE_MENU_SORT_REVERSE="$sort_reverse"
                restore_terminal
                return 0
                ;;
        esac

        # Drain any accumulated input after processing (e.g., mouse wheel events)
        # This prevents buffered events from causing jumps, without blocking keyboard input
        drain_pending_input
    done
}

# Export function for external use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library file. Source it from other scripts." >&2
    exit 1
fi
