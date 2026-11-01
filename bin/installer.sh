#!/bin/bash
# Mole - Installer command
# Find and remove installer files - .dmg, .pkg, .mpkg, .iso, .xip, .zip

set -euo pipefail

# User state and installed tools must never run with inherited root privileges.
# Individual maintenance operations request administrator access themselves.
if [[ "$EUID" -eq 0 ]]; then
    printf '%s\n' 'Run Mole without sudo; it requests administrator access when needed.' >&2
    exit 1
fi

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
readonly INSTALLER_EXIT_SCAN_FAILED=4
INSTALLER_SCAN_FAILURE_PATH=""
ZIP_LIST_CMD=()
IN_ALT_SCREEN=0

if command -v zipinfo > /dev/null 2>&1; then
    ZIP_LIST_CMD=(zipinfo -1)
elif command -v unzip > /dev/null 2>&1; then
    ZIP_LIST_CMD=(unzip -Z -1)
fi

TERMINAL_WIDTH=0

# Inspect the first N entries only after a complete ZIP listing.
# Return 0 for an installer, 1 for an ordinary/unreadable/corrupt ZIP;
# resource failures and timeout/signal statuses abort discovery.
is_installer_zip() {
    local zip="$1"
    local deadline="${2:-$((SECONDS + 10#${MOLE_TIMEOUT_DISK_VERIFY_SEC%%.*}))}"
    local listing duration rc=0

    [[ ${#ZIP_LIST_CMD[@]} -gt 0 ]] || return 1
    duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_SHORT_QUERY_SEC" "$deadline") || return $?
    listing=$(create_temp_file) || return "$INSTALLER_EXIT_SCAN_FAILED"
    run_with_timeout "$duration" "${ZIP_LIST_CMD[@]}" "$zip" > "$listing" 2> /dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_SHORT_QUERY_SEC" "$deadline") || rc=$?
        if [[ $rc -eq 0 ]]; then
            run_with_timeout "$duration" awk -v cap="$MAX_ZIP_ENTRIES" '
                NR <= cap && /\.(app|pkg|dmg|xip)(\/|$)/ { found=1 }
                END { exit found ? 0 : 1 }
            ' "$listing" || rc=$?
        fi
    elif ! mole_rc_timeout_or_signal "$rc"; then
        rc=1 # Corrupt or unreadable archives remain ordinary non-candidates.
    fi
    rm -f "$listing" # SAFE: tracked mktemp file created by this archive inspection
    return "$rc"
}

handle_candidate_file() {
    local file="$1"

    [[ -L "$file" ]] && return 0 # Skip symlinks explicitly
    case "$file" in
        *.dmg | *.pkg | *.mpkg | *.iso | *.xip)
            printf '%s\0' "$file"
            ;;
        *.zip)
            [[ -r "$file" ]] || return 0
            local zip_rc=0
            is_installer_zip "$file" "${2:-}" 2> /dev/null || zip_rc=$?
            case "$zip_rc" in
                0) printf '%s\0' "$file" ;;
                1) return 0 ;;
                *)
                    # One slow archive (an iCloud file that has to download
                    # first, or a huge listing) is skipped like an unreadable
                    # one. Only the shared deadline or a signal stops the scan.
                    if mole_rc_timeout "$zip_rc" &&
                        _mole_timeout_with_deadline 1 "${2:-}" > /dev/null; then
                        return 0
                    fi
                    return "$zip_rc"
                    ;;
            esac
            ;;
    esac
}

# True when every diagnostic line is a permission refusal: find's
# "Permission denied" / "Operation not permitted" and fd's same text with an
# "(os error N)" suffix. Anything else fails the scan.
installer_scan_errors_are_permission_only() {
    ! grep -E -v -e '(Permission denied|Operation not permitted)( \(os error [0-9]+\))?\.?$' -e '^$' "$1" > /dev/null
}

# Publish NUL-delimited candidates only on success; preserve producer failures.
scan_installers_in_path() {
    local path="$1"
    local max_depth="${MOLE_INSTALLER_SCAN_MAX_DEPTH:-$INSTALLER_SCAN_MAX_DEPTH_DEFAULT}"
    local deadline="${2:-$((SECONDS + 10#${MOLE_TIMEOUT_DISK_VERIFY_SEC%%.*}))}"

    [[ -d "$path" ]] || return 0

    # A failed producer must never publish its partial candidate prefix.
    local scan_file filtered_file errors_file file scan_timeout scan_rc=0
    scan_file=$(create_temp_file) || return 1
    filtered_file=$(create_temp_file) || return 1
    errors_file=$(create_temp_file) || return 1
    scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        local -a scan_command=()
        if command -v fd > /dev/null 2>&1; then
            scan_command=(fd --show-errors --print0 --no-ignore --hidden --type f --max-depth "$max_depth"
                -e dmg -e pkg -e mpkg -e iso -e xip -e zip . "$path")
        else
            scan_command=(find -H "$path" -maxdepth "$max_depth" -type f
                \( -name '*.dmg' -o -name '*.pkg' -o -name '*.mpkg'
                -o -name '*.iso' -o -name '*.xip' -o -name '*.zip' \) -print0)
        fi
        # Redirect only the producer's diagnostics; the timeout supervisor owns
        # its stderr, including debug traces. exec preserves the producer status.
        # shellcheck disable=SC2016 # This script is evaluated by the child shell.
        run_with_timeout "$scan_timeout" /bin/bash -c '
            errors_file="$1"
            shift
            exec "$@" 2> "$errors_file"
        ' bash "$errors_file" "${scan_command[@]}" > "$scan_file" || scan_rc=$?
    fi
    # A folder the user cannot read (chmod 000, or privacy-protected without
    # Full Disk Access) is out of reach, not a failed scan: its readable
    # siblings still publish, and every removal is bound to its confirmed
    # identity anyway. find exits 1 on it while fd still exits 0, so read the
    # diagnostics; any other diagnostic, or any other status, keeps the whole
    # inventory unpublished.
    if [[ -s "$errors_file" ]] && [[ $scan_rc -eq 0 || $scan_rc -eq 1 ]]; then
        if installer_scan_errors_are_permission_only "$errors_file"; then
            scan_rc=0
        else
            scan_rc=$INSTALLER_EXIT_SCAN_FAILED
        fi
    fi
    if [[ $scan_rc -eq 0 ]]; then
        while IFS= read -r -d '' file; do
            _mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline" > /dev/null || {
                scan_rc=$?
                break
            }
            handle_candidate_file "$file" "$deadline" >> "$filtered_file" || {
                scan_rc=$?
                break
            }
        done < "$scan_file"
    fi
    if [[ $scan_rc -eq 0 ]]; then
        _mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline" > /dev/null || scan_rc=$?
    fi
    if [[ $scan_rc -eq 0 ]]; then
        cat "$filtered_file" || scan_rc=$?
    fi
    rm -f "$scan_file" "$filtered_file" "$errors_file" # SAFE: tracked mktemp files created by this scan
    if [[ $scan_rc -ne 0 ]]; then
        INSTALLER_SCAN_FAILURE_PATH="$path"
    fi
    return "$scan_rc"
}

scan_all_installers() {
    local deadline="${1:-$((SECONDS + 10#${MOLE_TIMEOUT_DISK_VERIFY_SEC%%.*}))}"
    local path
    for path in "${INSTALLER_SCAN_PATHS[@]}"; do
        scan_installers_in_path "$path" "$deadline" || return $?
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

# Escape terminal controls without changing the filesystem path.
installer_display_text() {
    local text="$1"
    if [[ "$text" =~ [[:cntrl:]] ]]; then
        printf -v text '%q' "$text"
    fi
    printf '%s' "$text"
}

# Format installer display with alignment - similar to purge command
format_installer_display() {
    local filename="$1"
    local size_str="$2"
    local source="$3"

    filename=$(installer_display_text "$filename")
    source=$(installer_display_text "$source")

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

# Publish complete installer metadata: 0 success, 1 empty, 4 scan failure,
# or the original timeout/signal status. No failure publishes partial arrays.
collect_installers() {
    # Clear previous results
    INSTALLER_PATHS=()
    INSTALLER_SIZES=()
    INSTALLER_SOURCES=()
    DISPLAY_NAMES=()
    INSTALLER_SCAN_FAILURE_PATH=""

    # Scan all paths, deduplicate, and sort results
    local -a all_files=() sizes=() sources=() displays=()

    local deadline=$((SECONDS + 10#${MOLE_TIMEOUT_DISK_VERIFY_SEC%%.*}))
    local scan_file sorted_file file scan_timeout scan_rc=0
    scan_file=$(create_temp_file) || return "$INSTALLER_EXIT_SCAN_FAILED"
    sorted_file=$(create_temp_file) || return "$INSTALLER_EXIT_SCAN_FAILED"

    # Start scanning with spinner
    if [[ -t 1 ]]; then
        start_inline_spinner "Scanning for installers..."
    fi

    # Start debug session
    debug_operation_start "Collect Installers" "Scanning for redundant installer files"

    scan_all_installers "$deadline" > "$scan_file" || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline") || scan_rc=$?
        if [[ $scan_rc -eq 0 ]]; then
            run_with_timeout "$scan_timeout" sort -zu "$scan_file" > "$sorted_file" || scan_rc=$?
        fi
    fi
    if [[ $scan_rc -ne 0 ]]; then
        rm -f "$scan_file" "$sorted_file" # SAFE: tracked mktemp files created by this collection
        [[ ! -t 1 ]] || stop_inline_spinner
        if mole_rc_timeout_or_signal "$scan_rc"; then
            return "$scan_rc"
        fi
        return "$INSTALLER_EXIT_SCAN_FAILED"
    fi
    while IFS= read -r -d '' file; do
        [[ -z "$file" ]] && continue
        all_files+=("$file")
        debug_file_action "Found installer" "$file"
    done < "$sorted_file"
    rm -f "$scan_file" "$sorted_file" # SAFE: tracked mktemp files created by this collection

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ ${#all_files[@]} -eq 0 ]]; then
        if [[ "${IN_ALT_SCREEN:-0}" != "1" ]]; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} No installer files to clean"
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
        local file_size
        file_size=$(installer_file_size_bytes "$file" "$deadline") || {
            scan_rc=$?
            INSTALLER_SCAN_FAILURE_PATH="$file"
            break
        }

        # Get source directory
        local source
        source=$(get_source_display "$file")

        # Format human readable size
        local size_human
        size_human=$(bytes_to_human "$file_size")

        # Get display filename - strip Homebrew hash prefix if present
        local display_name
        display_name="${file##*/}"
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
        sizes+=("$file_size")
        sources+=("$source")
        displays+=("$display")
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    if [[ $scan_rc -eq 0 ]]; then
        _mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline" > /dev/null || scan_rc=$?
    fi
    if [[ $scan_rc -ne 0 ]]; then
        mole_rc_timeout_or_signal "$scan_rc" && return "$scan_rc"
        return "$INSTALLER_EXIT_SCAN_FAILED"
    fi
    # Publish the parallel arrays together only after every metadata probe finishes.
    INSTALLER_PATHS=("${all_files[@]}")
    INSTALLER_SIZES=("${sizes[@]}")
    INSTALLER_SOURCES=("${sources[@]}")
    DISPLAY_NAMES=("${displays[@]}")
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

        if ! IFS= read -r -s -n1 key; then
            restore_terminal
            return 1
        fi
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
    local file_size duration

    duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "${2:-}") || return $?
    file_size=$(run_with_timeout "$duration" "$STAT_BSD" -f%z "$file_path" < /dev/null 2> /dev/null) || return $?
    [[ "$file_size" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$file_size"
}

build_installer_delete_plan() {
    reset_installer_delete_plan

    local deadline=$((SECONDS + 10#${MOLE_TIMEOUT_DISK_VERIFY_SEC%%.*}))
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

        local identity identity_rc=0
        identity=$(mole_deletion_identity "$file_path" "$deadline") || identity_rc=$?
        if [[ $identity_rc -ne 0 ]]; then
            record_installer_delete_failure "$file_path" "identity unavailable"
            if mole_rc_timeout_or_signal "$identity_rc"; then
                reset_installer_delete_plan
                return "$identity_rc"
            fi
            continue
        fi
        INSTALLER_DELETE_PATHS+=("$file_path")
        INSTALLER_DELETE_SIZES+=("$file_size")
        INSTALLER_DELETE_IDENTITIES+=("$identity")
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

        local current_identity identity_rc=0
        current_identity=$(mole_deletion_identity "$file_path") || identity_rc=$?
        if [[ $identity_rc -ne 0 ]]; then
            record_installer_delete_failure "$file_path" "identity unavailable"
            mole_rc_timeout_or_signal "$identity_rc" && return "$identity_rc"
            continue
        fi
        if [[ "$current_identity" != "$planned_identity" ]]; then
            record_installer_delete_failure "$file_path" "changed since scan"
            continue
        fi

        local current_size size_rc=0
        current_size=$(installer_file_size_bytes "$file_path") || size_rc=$?
        if [[ $size_rc -ne 0 ]]; then
            record_installer_delete_failure "$file_path" "size unavailable"
            if mole_rc_timeout_or_signal "$size_rc" && ! mole_rc_timeout "$size_rc"; then
                return "$size_rc"
            fi
            continue
        fi
        if [[ "$current_size" != "$planned_size" ]]; then
            record_installer_delete_failure "$file_path" "changed since scan"
            continue
        fi

        if mole_delete "$file_path" false "$planned_identity"; then
            if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] || [[ ! -e "$file_path" && ! -L "$file_path" ]]; then
                total_size_freed_kb=$((total_size_freed_kb + ((current_size + 1023) / 1024)))
                total_deleted=$((total_deleted + 1))
            else
                record_installer_delete_failure "$file_path" "still exists"
            fi
        else
            local delete_rc=$?
            record_installer_delete_failure "$file_path" "delete failed"
            if mole_rc_timeout_or_signal "$delete_rc"; then
                return "$delete_rc"
            fi
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

    local plan_status=0
    build_installer_delete_plan "${selected_indices[@]}" || plan_status=$?
    if [[ $plan_status -ne 0 ]]; then
        mole_rc_timeout_or_signal "$plan_status" && return "$plan_status"
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
        printf '  %s%s%s %s %s, %s%s\n' "$GREEN" "$ICON_SUCCESS" "$NC" \
            "$(installer_display_text "${file_path##*/}")" "$GRAY" "$size_human" "$NC"
    done

    # Confirm deletion
    echo ""
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Delete ${#INSTALLER_DELETE_PATHS[@]} installers, ${confirm_human}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    if ! IFS= read -r -s -n1 confirm; then
        printf '\n'
        return 1
    fi
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
    local collect_status=0
    collect_installers || collect_status=$?
    if [[ $collect_status -ne 0 ]]; then
        if [[ -t 1 ]]; then
            leave_alt_screen
            IN_ALT_SCREEN=0
        fi
        printf '\n'
        if [[ $collect_status -ne 1 ]]; then
            local scan_reason="incomplete"
            if mole_rc_timeout "$collect_status"; then
                scan_reason="timed out"
            elif mole_rc_timeout_or_signal "$collect_status"; then
                scan_reason="interrupted"
            fi
            printf '%sInstaller scan %s%s; no files selected' "$YELLOW" "$scan_reason" "$NC" >&2
            if [[ -n "$INSTALLER_SCAN_FAILURE_PATH" ]]; then
                printf ' (%s)' "$(installer_display_text "$INSTALLER_SCAN_FAILURE_PATH")" >&2
            fi
            printf '\nCheck that the scan locations are readable and responsive, then retry mo installer.\n' >&2
            return "$collect_status"
        fi
        echo -e "${GREEN}${ICON_SUCCESS}${NC} No installer files to clean"
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
            local failure_detail
            failure_detail=$(installer_display_text "${INSTALLER_DELETE_FAILURES[$failure_index]}")
            # The shared summary renderer interprets escapes for colors.
            failure_detail=${failure_detail//\\/\\\\}
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
                echo "Unknown option: $arg" >&2
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
        "$INSTALLER_EXIT_SCAN_FAILED")
            return 1
            ;;
        1)
            printf '\n'
            ;;
        2)
            # Already handled by collect_installers
            ;;
        *)
            # A timeout or signal in the delete phase stops before later
            # selections, but it has already recorded which file it hit.
            # Report that and what was removed instead of ending silently.
            if [[ $total_delete_failed -gt 0 ]]; then
                show_summary
                if mole_rc_timeout "$exit_code"; then
                    echo -e "${YELLOW}${ICON_WARNING}${NC} A file check timed out, so later selections were left in place. Retry mo installer."
                fi
            fi
            return "$exit_code"
            ;;
    esac

    return 0
}

# Only run main if not in test mode
if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
