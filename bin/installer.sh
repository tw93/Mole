#!/bin/bash
# Mole - Installer command
# Find and remove installer files - .dmg, .pkg, .mpkg, .iso, .xip, .zip

set -euo pipefail

# shellcheck disable=SC2154
# External variables set by menu_paginated.sh and environment
declare MOLE_SELECTION_RESULT
declare MOLE_INSTALLER_SCAN_MAX_DEPTH

export LC_ALL=C
export LANG=C
export MOLE_CURRENT_COMMAND="${MOLE_CURRENT_COMMAND:-installer}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"

cleanup() {
    if [[ "${IN_ALT_SCREEN:-0}" == "1" ]]; then
        leave_alt_screen
        IN_ALT_SCREEN=0
    fi
    show_cursor
    cleanup_temp_files
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT TERM

# Scan configuration
readonly INSTALLER_SCAN_MAX_DEPTH_DEFAULT=2
readonly INSTALLER_SCAN_PATHS=(
    "$HOME/Downloads"
    "$HOME/Desktop"
    "$HOME/Documents"
    "$HOME/Public"
    "$HOME/Library/Downloads"
    "/Users/Shared"
    "/Users/Shared/Downloads"
    "$HOME/Library/Caches/Homebrew"
    "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
    "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    "$HOME/Library/Application Support/Telegram Desktop"
    "$HOME/Downloads/Telegram Desktop"
)
readonly MAX_ZIP_ENTRIES=50
readonly INSTALLER_EXIT_INCOMPLETE=3
ZIP_LIST_CMD=()
IN_ALT_SCREEN=0

if command -v zipinfo > /dev/null 2>&1; then
    ZIP_LIST_CMD=(zipinfo -1)
elif command -v unzip > /dev/null 2>&1; then
    ZIP_LIST_CMD=(unzip -Z -1)
fi

TERMINAL_WIDTH=0

# Check for installer payloads inside ZIP - check first N entries for installer patterns
is_installer_zip() {
    local zip="$1"
    local cap="$MAX_ZIP_ENTRIES"

    [[ ${#ZIP_LIST_CMD[@]} -gt 0 ]] || return 1

    if ! "${ZIP_LIST_CMD[@]}" "$zip" 2> /dev/null |
        head -n "$cap" |
        awk '
            /\.(app|pkg|dmg|xip)(\/|$)/ { found=1; exit 0 }
            END { exit found ? 0 : 1 }
        '; then
        return 1
    fi

    return 0
}

handle_candidate_file() {
    local file="$1"

    [[ -L "$file" ]] && return 0 # Skip symlinks explicitly
    case "$file" in
        *.dmg | *.pkg | *.mpkg | *.iso | *.xip)
            echo "$file"
            ;;
        *.zip)
            [[ -r "$file" ]] || return 0
            if is_installer_zip "$file" 2> /dev/null; then
                echo "$file"
            fi
            ;;
    esac
}

scan_installers_in_path() {
    local path="$1"
    local max_depth="${MOLE_INSTALLER_SCAN_MAX_DEPTH:-$INSTALLER_SCAN_MAX_DEPTH_DEFAULT}"

    [[ -d "$path" ]] || return 0

    local file

    if command -v fd > /dev/null 2>&1; then
        while IFS= read -r file; do
            handle_candidate_file "$file"
        done < <(
            fd --no-ignore --hidden --type f --max-depth "$max_depth" \
                -e dmg -e pkg -e mpkg -e iso -e xip -e zip \
                . "$path" 2> /dev/null || true
        )
    else
        while IFS= read -r file; do
            handle_candidate_file "$file"
        done < <(
            find "$path" -maxdepth "$max_depth" -type f \
                \( -name '*.dmg' -o -name '*.pkg' -o -name '*.mpkg' \
                -o -name '*.iso' -o -name '*.xip' -o -name '*.zip' \) \
                2> /dev/null || true
        )
    fi
}

scan_all_installers() {
    for path in "${INSTALLER_SCAN_PATHS[@]}"; do
        scan_installers_in_path "$path"
    done
}

# Initialize stats
declare -i total_deleted=0
declare -i total_size_freed_kb=0
declare -i total_delete_failed=0

# Global arrays for installer data
declare -a INSTALLER_PATHS=()
declare -a INSTALLER_SIZES=()
declare -a INSTALLER_SOURCES=()
declare -a DISPLAY_NAMES=()
declare -a INSTALLER_DELETE_PATHS=()
declare -a INSTALLER_DELETE_SIZES=()
declare -a INSTALLER_DELETE_IDENTITIES=()
declare -a INSTALLER_DELETE_FAILURES=()

# Get source directory display name - for example "Downloads" or "Desktop"
get_source_display() {
    local file_path="$1"
    local dir_path="${file_path%/*}"

    # Match against known paths and return friendly names
    case "$dir_path" in
        "$HOME/Downloads"*) echo "Downloads" ;;
        "$HOME/Desktop"*) echo "Desktop" ;;
        "$HOME/Documents"*) echo "Documents" ;;
        "$HOME/Public"*) echo "Public" ;;
        "$HOME/Library/Downloads"*) echo "Library" ;;
        "/Users/Shared"*) echo "Shared" ;;
        "$HOME/Library/Caches/Homebrew"*) echo "Homebrew" ;;
        "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"*) echo "iCloud" ;;
        "$HOME/Library/Containers/com.apple.mail"*) echo "Mail" ;;
        *"Telegram Desktop"*) echo "Telegram" ;;
        *) echo "${dir_path##*/}" ;;
    esac
}

get_terminal_width() {
    if [[ $TERMINAL_WIDTH -le 0 ]]; then
        TERMINAL_WIDTH=$(tput cols 2> /dev/null || echo 80)
    fi
    echo "$TERMINAL_WIDTH"
}

# Format installer display with alignment - similar to purge command
format_installer_display() {
    local filename="$1"
    local size_str="$2"
    local source="$3"

    # Terminal width for alignment
    local terminal_width
    terminal_width=$(get_terminal_width)
    local fixed_width=24 # Reserve for size and source
    local available_width=$((terminal_width - fixed_width))

    # Bounds check: 20-40 chars for filename
    [[ $available_width -lt 20 ]] && available_width=20
    [[ $available_width -gt 40 ]] && available_width=40

    # Truncate filename if needed
    local truncated_name
    truncated_name=$(truncate_by_display_width "$filename" "$available_width")
    local current_width
    current_width=$(get_display_width "$truncated_name")

    # Get byte count for printf width calculation
    local old_lc="${LC_ALL:-}"
    export LC_ALL=C
    local byte_count=${#truncated_name}
    if [[ -n "$old_lc" ]]; then
        export LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi

    local padding=$((available_width - current_width))
    local printf_width=$((byte_count + padding))

    # Format: "filename  size | source"
    printf "%-*s %8s | %-10s" "$printf_width" "$truncated_name" "$size_str" "$source"
}

# Collect all installers with their metadata
collect_installers() {
    # Clear previous results
    INSTALLER_PATHS=()
    INSTALLER_SIZES=()
    INSTALLER_SOURCES=()
    DISPLAY_NAMES=()

    # Start scanning with spinner
    if [[ -t 1 ]]; then
        start_inline_spinner "Scanning for installers..."
    fi

    # Start debug session
    debug_operation_start "Collect Installers" "Scanning for redundant installer files"

    # Scan all paths, deduplicate, and sort results
    local -a all_files=()

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        all_files+=("$file")
        debug_file_action "Found installer" "$file"
    done < <(scan_all_installers | sort -u)

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ ${#all_files[@]} -eq 0 ]]; then
        if [[ "${IN_ALT_SCREEN:-0}" != "1" ]]; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No installer files to clean"
        fi
        return 1
    fi

    # Calculate sizes with spinner
    if [[ -t 1 ]]; then
        start_inline_spinner "Calculating sizes..."
    fi

    # Process each installer
    for file in "${all_files[@]}"; do
        # Calculate file size
        local file_size=0
        if [[ -f "$file" ]]; then
            file_size=$(get_file_size "$file")
        fi

        # Get source directory
        local source
        source=$(get_source_display "$file")

        # Format human readable size
        local size_human
        size_human=$(bytes_to_human "$file_size")

        # Get display filename - strip Homebrew hash prefix if present
        local display_name
        display_name=$(basename "$file")
        if [[ "$source" == "Homebrew" ]]; then
            # Homebrew names often look like: sha256--name--version
            # Strip the leading hash if it matches [0-9a-f]{64}--
            if [[ "$display_name" =~ ^[0-9a-f]{64}--(.*) ]]; then
                display_name="${BASH_REMATCH[1]}"
            fi
        fi

        # Format display with alignment
        local display
        display=$(format_installer_display "$display_name" "$size_human" "$source")

        # Store installer data in parallel arrays
        INSTALLER_PATHS+=("$file")
        INSTALLER_SIZES+=("$file_size")
        INSTALLER_SOURCES+=("$source")
        DISPLAY_NAMES+=("$display")
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    return 0
}

# Installer selector with Select All / Invert support
select_installers() {
    local -a items=("$@")
    local total_items=${#items[@]}
    local clear_line=$'\r\033[2K'

    if [[ $total_items -eq 0 ]]; then
        return 1
    fi

    # Calculate items per page based on terminal height
    _get_items_per_page() {
        local term_height=24
        if [[ -t 0 ]] || [[ -t 2 ]]; then
            term_height=$(stty size < /dev/tty 2> /dev/null | awk '{print $1}')
        fi
        if [[ -z "$term_height" || $term_height -le 0 ]]; then
            if command -v tput > /dev/null 2>&1; then
                term_height=$(tput lines 2> /dev/null || echo "24")
            else
                term_height=24
            fi
        fi
        local reserved=6
        local available=$((term_height - reserved))
        if [[ $available -lt 3 ]]; then
            echo 3
        elif [[ $available -gt 50 ]]; then
            echo 50
        else
            echo "$available"
        fi
    }

    local items_per_page=$(_get_items_per_page)
    local cursor_pos=0
    local top_index=0

    # Initialize selection (all unselected by default)
    local -a selected=()
    for ((i = 0; i < total_items; i++)); do
        selected[i]=false
    done

    local original_stty=""
    if [[ -t 0 ]] && command -v stty > /dev/null 2>&1; then
        original_stty=$(stty -g 2> /dev/null || echo "")
    fi

    restore_terminal() {
        trap - EXIT INT TERM
        if [[ "${IN_ALT_SCREEN:-0}" == "1" ]]; then
            leave_alt_screen
            IN_ALT_SCREEN=0
        fi
        show_cursor
        if [[ -n "${original_stty:-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || true
        fi
    }

    handle_interrupt() {
        restore_terminal
        exit 130
    }

    draw_menu() {
        items_per_page=$(_get_items_per_page)

        local max_top_index=0
        if [[ $total_items -gt $items_per_page ]]; then
            max_top_index=$((total_items - items_per_page))
        fi
        if [[ $top_index -gt $max_top_index ]]; then
            top_index=$max_top_index
        fi
        if [[ $top_index -lt 0 ]]; then
            top_index=0
        fi

        local visible_count=$((total_items - top_index))
        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
        if [[ $cursor_pos -gt $((visible_count - 1)) ]]; then
            cursor_pos=$((visible_count - 1))
        fi
        if [[ $cursor_pos -lt 0 ]]; then
            cursor_pos=0
        fi

        printf "\033[H"

        # Calculate selected size and count
        local selected_size=0
        local selected_count=0
        for ((i = 0; i < total_items; i++)); do
            if [[ ${selected[i]} == true ]]; then
                selected_size=$((selected_size + ${INSTALLER_SIZES[i]:-0}))
                ((selected_count++))
            fi
        done
        local selected_human
        selected_human=$(bytes_to_human "$selected_size")

        # Show position indicator if scrolling is needed
        local scroll_indicator=""
        if [[ $total_items -gt $items_per_page ]]; then
            local current_pos=$((top_index + cursor_pos + 1))
            scroll_indicator=" ${GRAY}[${current_pos}/${total_items}]${NC}"
        fi

        printf "${PURPLE_BOLD}Select Installers to Remove${NC}%s ${GRAY}, ${selected_human}, ${selected_count} selected${NC}\n" "$scroll_indicator"
        printf "%s\n" "$clear_line"

        # Calculate visible range
        local end_index=$((top_index + visible_count))

        # Draw only visible items
        for ((i = top_index; i < end_index; i++)); do
            local checkbox="$ICON_EMPTY"
            [[ ${selected[i]} == true ]] && checkbox="$ICON_SOLID"
            local rel_pos=$((i - top_index))
            if [[ $rel_pos -eq $cursor_pos ]]; then
                printf "%s${CYAN}${ICON_ARROW} %s %s${NC}\n" "$clear_line" "$checkbox" "${items[i]}"
            else
                printf "%s  %s %s\n" "$clear_line" "$checkbox" "${items[i]}"
            fi
        done

        # Fill empty slots
        local items_shown=$visible_count
        for ((i = items_shown; i < items_per_page; i++)); do
            printf "%s\n" "$clear_line"
        done

        printf "%s\n" "$clear_line"
        printf "%s${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit${NC}\n" "$clear_line"
    }

    trap restore_terminal EXIT
    trap handle_interrupt INT TERM
    stty -echo -icanon intr ^C 2> /dev/null || true
    hide_cursor
    if [[ -t 1 ]]; then
        printf "\033[2J\033[H" >&2
    fi

    # Main loop
    while true; do
        draw_menu

        IFS= read -r -s -n1 key || key=""
        case "$key" in
            $'\x1b')
                IFS= read -r -s -n1 -t 1 key2 || key2=""
                if [[ "$key2" == "[" ]]; then
                    IFS= read -r -s -n1 -t 1 key3 || key3=""
                    case "$key3" in
                        A) # Up arrow
                            if [[ $cursor_pos -gt 0 ]]; then
                                ((cursor_pos--))
                            elif [[ $top_index -gt 0 ]]; then
                                ((top_index--))
                            fi
                            ;;
                        B) # Down arrow
                            local absolute_index=$((top_index + cursor_pos))
                            local last_index=$((total_items - 1))
                            if [[ $absolute_index -lt $last_index ]]; then
                                local visible_count=$((total_items - top_index))
                                [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                                if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                                    ((cursor_pos++))
                                elif [[ $((top_index + visible_count)) -lt $total_items ]]; then
                                    ((top_index++))
                                fi
                            fi
                            ;;
                    esac
                else
                    # ESC alone
                    restore_terminal
                    return 1
                fi
                ;;
            " ") # Space - toggle current item
                local idx=$((top_index + cursor_pos))
                if [[ ${selected[idx]} == true ]]; then
                    selected[idx]=false
                else
                    selected[idx]=true
                fi
                ;;
            "a" | "A") # Select all
                for ((i = 0; i < total_items; i++)); do
                    selected[i]=true
                done
                ;;
            "i" | "I") # Invert selection
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        selected[i]=false
                    else
                        selected[i]=true
                    fi
                done
                ;;
            "q" | "Q" | $'\x03') # Quit or Ctrl-C
                restore_terminal
                return 1
                ;;
            "" | $'\n' | $'\r') # Enter - confirm
                MOLE_SELECTION_RESULT=""
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        [[ -n "$MOLE_SELECTION_RESULT" ]] && MOLE_SELECTION_RESULT+=","
                        MOLE_SELECTION_RESULT+="$i"
                    fi
                done
                restore_terminal
                return 0
                ;;
        esac
    done
}

# Show menu for user selection
show_installer_menu() {
    if [[ ${#DISPLAY_NAMES[@]} -eq 0 ]]; then
        return 1
    fi

    echo ""

    MOLE_SELECTION_RESULT=""
    if ! select_installers "${DISPLAY_NAMES[@]}"; then
        return 1
    fi

    return 0
}

reset_installer_delete_results() {
    total_deleted=0
    total_size_freed_kb=0
    total_delete_failed=0
    INSTALLER_DELETE_FAILURES=()
}

reset_installer_delete_plan() {
    INSTALLER_DELETE_PATHS=()
    INSTALLER_DELETE_SIZES=()
    INSTALLER_DELETE_IDENTITIES=()
}

record_installer_delete_failure() {
    local file_path="$1"
    local reason="$2"

    INSTALLER_DELETE_FAILURES+=("$file_path ($reason)")
    total_delete_failed=$((total_delete_failed + 1))
}

installer_file_size_bytes() {
    local file_path="$1"
    local file_size

    file_size=$(get_file_size "$file_path" 2> /dev/null || echo "")
    [[ "$file_size" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$file_size"
}

build_installer_delete_plan() {
    reset_installer_delete_plan

    local idx
    for idx in "$@"; do
        if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ $idx -ge ${#INSTALLER_PATHS[@]} ]]; then
            record_installer_delete_failure "$idx" "stale selection"
            continue
        fi

        local file_path="${INSTALLER_PATHS[$idx]}"
        local file_size="${INSTALLER_SIZES[$idx]:-0}"
        if [[ ! "$file_size" =~ ^[0-9]+$ ]]; then
            file_size=0
        fi

        INSTALLER_DELETE_PATHS+=("$file_path")
        INSTALLER_DELETE_SIZES+=("$file_size")
        INSTALLER_DELETE_IDENTITIES+=("$(mole_path_identity "$file_path")")
    done

    [[ ${#INSTALLER_DELETE_PATHS[@]} -gt 0 ]]
}

execute_installer_delete_plan() {
    local plan_index
    for ((plan_index = 0; plan_index < ${#INSTALLER_DELETE_PATHS[@]}; plan_index++)); do
        local file_path="${INSTALLER_DELETE_PATHS[$plan_index]}"
        local planned_size="${INSTALLER_DELETE_SIZES[$plan_index]}"
        local planned_identity="${INSTALLER_DELETE_IDENTITIES[$plan_index]}"

        if [[ ! -e "$file_path" && ! -L "$file_path" ]]; then
            record_installer_delete_failure "$file_path" "missing"
            continue
        fi

        local current_identity
        current_identity=$(mole_path_identity "$file_path")
        if [[ "$current_identity" != "$planned_identity" ]]; then
            record_installer_delete_failure "$file_path" "changed since scan"
            continue
        fi

        local current_size
        if ! current_size=$(installer_file_size_bytes "$file_path"); then
            record_installer_delete_failure "$file_path" "size unavailable"
            continue
        fi
        if [[ "$current_size" != "$planned_size" ]]; then
            record_installer_delete_failure "$file_path" "changed since scan"
            continue
        fi

        if mole_delete "$file_path" false; then
            if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] || [[ ! -e "$file_path" && ! -L "$file_path" ]]; then
                total_size_freed_kb=$((total_size_freed_kb + ((current_size + 1023) / 1024)))
                total_deleted=$((total_deleted + 1))
            else
                record_installer_delete_failure "$file_path" "still exists"
            fi
        else
            record_installer_delete_failure "$file_path" "delete failed"
        fi
    done

    if [[ $total_delete_failed -gt 0 ]]; then
        return "$INSTALLER_EXIT_INCOMPLETE"
    fi
    return 0
}

# Delete selected installers
delete_selected_installers() {
    reset_installer_delete_results

    # Parse selection indices
    local -a selected_indices=()
    if [[ -n "$MOLE_SELECTION_RESULT" ]]; then
        IFS=',' read -ra selected_indices <<< "$MOLE_SELECTION_RESULT"
    fi

    if [[ ${#selected_indices[@]} -eq 0 ]]; then
        return 1
    fi

    if ! build_installer_delete_plan "${selected_indices[@]}"; then
        if [[ $total_delete_failed -gt 0 ]]; then
            return "$INSTALLER_EXIT_INCOMPLETE"
        fi
        return 1
    fi

    local confirm_size=0
    local plan_index
    for ((plan_index = 0; plan_index < ${#INSTALLER_DELETE_SIZES[@]}; plan_index++)); do
        confirm_size=$((confirm_size + ${INSTALLER_DELETE_SIZES[$plan_index]}))
    done

    local confirm_human
    confirm_human=$(bytes_to_human "$confirm_size")

    # Show files to be deleted
    echo -e "${PURPLE_BOLD}Files to be removed:${NC}"
    for ((plan_index = 0; plan_index < ${#INSTALLER_DELETE_PATHS[@]}; plan_index++)); do
        local file_path="${INSTALLER_DELETE_PATHS[$plan_index]}"
        local file_size="${INSTALLER_DELETE_SIZES[$plan_index]}"
        local size_human
        size_human=$(bytes_to_human "$file_size")
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(basename "$file_path") ${GRAY}, ${size_human}${NC}"
    done

    # Confirm deletion
    echo ""
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Delete ${#INSTALLER_DELETE_PATHS[@]} installers, ${confirm_human}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    IFS= read -r -s -n1 confirm || confirm=""
    case "$confirm" in
        $'\e' | q | Q)
            return 1
            ;;
        "" | $'\n' | $'\r')
            printf "\r\033[K" # Clear prompt line
            echo ""           # Single line break
            ;;
        *)
            return 1
            ;;
    esac

    # Delete each selected installer with spinner
    if [[ -t 1 ]]; then
        start_inline_spinner "Removing installers..."
    fi

    local delete_status=0
    execute_installer_delete_plan || delete_status=$?

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    return "$delete_status"
}

# Perform the installers cleanup
perform_installers() {
    # Enter alt screen for scanning and selection
    if [[ -t 1 ]]; then
        enter_alt_screen
        IN_ALT_SCREEN=1
        printf "\033[2J\033[H" >&2
    fi

    # Collect installers
    if ! collect_installers; then
        if [[ -t 1 ]]; then
            leave_alt_screen
            IN_ALT_SCREEN=0
        fi
        printf '\n'
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No installer files to clean"
        printf '\n'
        return 2 # Nothing to clean
    fi

    # Show menu
    if ! show_installer_menu; then
        if [[ -t 1 ]]; then
            leave_alt_screen
            IN_ALT_SCREEN=0
        fi
        return 1 # User cancelled
    fi

    # Leave alt screen before deletion (so confirmation and results are on main screen)
    if [[ -t 1 ]]; then
        leave_alt_screen
        IN_ALT_SCREEN=0
    fi

    # Delete selected
    local delete_status=0
    delete_selected_installers || delete_status=$?
    if [[ $delete_status -ne 0 ]]; then
        return "$delete_status"
    fi

    return 0
}

show_summary() {
    local summary_heading="Installers cleaned"
    local -a summary_details=()
    local dry_run_mode="${MOLE_DRY_RUN:-0}"

    if [[ "$dry_run_mode" == "1" ]]; then
        summary_heading="Dry run complete - no changes made"
    elif [[ $total_delete_failed -gt 0 ]]; then
        summary_heading="Installer cleanup incomplete"
    fi

    if [[ $total_deleted -gt 0 ]]; then
        local freed_mb
        freed_mb=$(echo "$total_size_freed_kb" | awk '{printf "%.2f", $1/1024}')

        if [[ "$dry_run_mode" == "1" ]]; then
            summary_details+=("Would remove ${GREEN}$total_deleted${NC} installers, free ${GREEN}${freed_mb}MB${NC}")
        else
            summary_details+=("Removed ${GREEN}$total_deleted${NC} installers, freed ${GREEN}${freed_mb}MB${NC}")
            if [[ $total_delete_failed -eq 0 ]]; then
                summary_details+=("Your Mac is cleaner now!")
            fi
        fi
    else
        summary_details+=("No installers were removed")
    fi

    if [[ $total_delete_failed -gt 0 ]]; then
        local failure_label="installers"
        [[ $total_delete_failed -eq 1 ]] && failure_label="installer"
        summary_details+=("Failed to remove ${YELLOW}$total_delete_failed${NC} $failure_label")

        local failure_count=${#INSTALLER_DELETE_FAILURES[@]}
        local failure_limit=5
        if [[ $failure_count -lt $failure_limit ]]; then
            failure_limit=$failure_count
        fi

        local failure_index
        for ((failure_index = 0; failure_index < failure_limit; failure_index++)); do
            local failure_detail="${INSTALLER_DELETE_FAILURES[$failure_index]}"
            summary_details+=("${ICON_WARNING} $failure_detail")
        done

        if [[ $failure_count -gt $failure_limit ]]; then
            summary_details+=("${ICON_WARNING} $((failure_count - failure_limit)) more failed")
        fi
    fi

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

main() {
    for arg in "$@"; do
        case "$arg" in
            "--help" | "-h")
                show_installer_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                export MOLE_DRY_RUN=1
                ;;
            *)
                echo "Unknown option: $arg"
                exit 1
                ;;
        esac
    done

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No installer files will be removed"
        printf '\n'
    fi

    hide_cursor
    # Capture the status without tripping errexit: a bare call under set -e
    # would exit the script before the case handler below could report
    # incomplete cleanup.
    local exit_code=0
    perform_installers || exit_code=$?
    show_cursor

    case $exit_code in
        0)
            show_summary
            ;;
        "$INSTALLER_EXIT_INCOMPLETE")
            show_summary
            return 1
            ;;
        1)
            printf '\n'
            ;;
        2)
            # Already handled by collect_installers
            ;;
    esac

    return 0
}

# Only run main if not in test mode
if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
