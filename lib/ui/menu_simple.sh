#!/bin/bash
# Paginated menu with arrow key navigation

set -euo pipefail

# Terminal control functions
enter_alt_screen() { tput smcup 2> /dev/null || true; }
leave_alt_screen() { tput rmcup 2> /dev/null || true; }

# Get terminal height with fallback
_ms_get_terminal_height() {
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
_ms_calculate_items_per_page() {
    local term_height=$(_ms_get_terminal_height)
    # Layout: header(1) + spacing(1) + items + spacing(1) + footer(1) + clear(1) = 5 fixed lines
    local reserved=6 # Increased to prevent header from being overwritten
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
    local items_per_page=$(_ms_calculate_items_per_page)
    local cursor_pos=0
    local top_index=0
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

    render_item() {
        local idx=$1 is_current=$2
        local checkbox="$ICON_EMPTY"
        [[ ${selected[idx]} == true ]] && checkbox="$ICON_SOLID"

        if [[ $is_current == true ]]; then
            printf "\r\033[2K${CYAN}${ICON_ARROW} %s %s${NC}\n" "$checkbox" "${items[idx]}" >&2
        else
            printf "\r\033[2K  %s %s\n" "$checkbox" "${items[idx]}" >&2
        fi
    }

    # Draw the complete menu
    draw_menu() {
        # Recalculate items_per_page dynamically to handle window resize
        items_per_page=$(_ms_calculate_items_per_page)

        # Move to home position without clearing (reduces flicker)
        printf "\033[H" >&2

        # Clear each line as we go instead of clearing entire screen
        local clear_line="\r\033[2K"

        # Count selections for header display
        local selected_count=0
        for ((i = 0; i < total_items; i++)); do
            [[ ${selected[i]} == true ]] && selected_count=$((selected_count + 1))
        done

        # Header
        printf "${clear_line}${PURPLE_BOLD}%s${NC}  ${GRAY}%d/%d selected${NC}\n" "${title}" "$selected_count" "$total_items" >&2

        if [[ $total_items -eq 0 ]]; then
            printf "${clear_line}${GRAY}No items available${NC}\n" >&2
            printf "${clear_line}\n" >&2
            printf "${clear_line}${GRAY}Q${NC} Quit\n" >&2
            printf "${clear_line}" >&2
            return
        fi

        if [[ $top_index -gt $((total_items - 1)) ]]; then
            if [[ $total_items -gt $items_per_page ]]; then
                top_index=$((total_items - items_per_page))
            else
                top_index=0
            fi
        fi

        local visible_count=$((total_items - top_index))
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
        [[ $end_idx -ge $total_items ]] && end_idx=$((total_items - 1))

        for ((i = start_idx; i <= end_idx; i++)); do
            [[ $i -lt 0 ]] && continue
            local is_current=false
            [[ $((i - start_idx)) -eq $cursor_pos ]] && is_current=true
            render_item $i $is_current
        done

        # Fill empty slots to clear previous content
        local items_shown=$((end_idx - start_idx + 1))
        [[ $items_shown -lt 0 ]] && items_shown=0
        for ((i = items_shown; i < items_per_page; i++)); do
            printf "${clear_line}\n" >&2
        done

        # Clear any remaining lines at bottom
        printf "${clear_line}\n" >&2
        printf "${clear_line}${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN} | Space | Enter | Q Cancel${NC}\n" >&2

        # Clear one more line to ensure no artifacts
        printf "${clear_line}" >&2
    }

    # Main interaction loop
    while true; do
        draw_menu
        local key=$(read_key)

        case "$key" in
            "QUIT")
                cleanup
                return 1
                ;;
            "UP")
                if [[ $total_items -eq 0 ]]; then
                    :
                elif [[ $cursor_pos -gt 0 ]]; then
                    ((cursor_pos--))
                elif [[ $top_index -gt 0 ]]; then
                    ((top_index--))
                fi
                ;;
            "DOWN")
                if [[ $total_items -eq 0 ]]; then
                    :
                else
                    local absolute_index=$((top_index + cursor_pos))
                    if [[ $absolute_index -lt $((total_items - 1)) ]]; then
                        local visible_count=$((total_items - top_index))
                        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page

                        if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                            cursor_pos=$((cursor_pos + 1))
                        elif [[ $((top_index + visible_count)) -lt $total_items ]]; then
                            top_index=$((top_index + 1))
                            visible_count=$((total_items - top_index))
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
                if [[ $idx -lt $total_items ]]; then
                    if [[ ${selected[idx]} == true ]]; then
                        selected[idx]=false
                    else
                        selected[idx]=true
                    fi
                fi
                ;;
            "ALL")
                for ((i = 0; i < total_items; i++)); do
                    selected[i]=true
                done
                ;;
            "NONE")
                for ((i = 0; i < total_items; i++)); do
                    selected[i]=false
                done
                ;;
            "ENTER")
                # Store result in global variable instead of returning via stdout
                local -a selected_indices=()
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        selected_indices+=("$i")
                    fi
                done

                # Allow empty selection - don't auto-select cursor position
                # This fixes the bug where unselecting all items would still select the last cursor position
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
