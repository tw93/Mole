#!/bin/bash
# Mole - Deeper system cleanup
# Complete cleanup with smart password handling

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Configuration
SYSTEM_CLEAN=false
DRY_RUN=false
IS_M_SERIES=$([ "$(uname -m)" = "arm64" ] && echo "true" || echo "false")

# Constants
readonly MAX_PARALLEL_JOBS=15 # Maximum parallel background jobs
readonly TEMP_FILE_AGE_DAYS=7 # Age threshold for temp file cleanup
readonly ORPHAN_AGE_DAYS=60   # Age threshold for orphaned data

# Protected Service Worker domains (web-based editing tools)
readonly PROTECTED_SW_DOMAINS=(
    "capcut.com"
    "photopea.com"
    "pixlr.com"
)
# Default whitelist patterns (preselected, user can disable)
declare -a DEFAULT_WHITELIST_PATTERNS=(
    "$HOME/Library/Caches/ms-playwright*"
    "$HOME/.cache/huggingface*"
    "$HOME/.m2/repository/*"
    "$HOME/.ollama/models/*"
    "$HOME/Library/Caches/com.nssurge.surge-mac/*"
    "$HOME/Library/Application Support/com.nssurge.surge-mac/*"
)
declare -a WHITELIST_PATTERNS=()
WHITELIST_WARNINGS=()

# Load user-defined whitelist
if [[ -f "$HOME/.config/mole/whitelist" ]]; then
    while IFS= read -r line; do
        # Trim whitespace
        line="${line#${line%%[![:space:]]*}}"
        line="${line%${line##*[![:space:]]}}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Expand tilde to home directory
        [[ "$line" == ~* ]] && line="${line/#~/$HOME}"

        # Validate path format (allow safe characters only)
        if [[ ! "$line" =~ ^[a-zA-Z0-9/_.\*~\ @-]+$ ]]; then
            WHITELIST_WARNINGS+=("Invalid chars: $line")
            continue
        fi

        # Prevent absolute path to critical system directories
        case "$line" in
            /System/* | /bin/* | /sbin/* | /usr/bin/* | /usr/sbin/*)
                WHITELIST_WARNINGS+=("System path: $line")
                continue
                ;;
        esac

        duplicate="false"
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$line" == "$existing" ]]; then
                    duplicate="true"
                    break
                fi
            done
        fi
        [[ "$duplicate" == "true" ]] && continue
        WHITELIST_PATTERNS+=("$line")
    done < "$HOME/.config/mole/whitelist"
else
    WHITELIST_PATTERNS=("${DEFAULT_WHITELIST_PATTERNS[@]}")
fi
total_items=0

# Tracking variables
TRACK_SECTION=0
SECTION_ACTIVITY=0
files_cleaned=0
total_size_cleaned=0
whitelist_skipped_count=0
SUDO_KEEPALIVE_PID=""

note_activity() {
    if [[ $TRACK_SECTION -eq 1 ]]; then
        SECTION_ACTIVITY=1
    fi
}

# Cleanup background processes
CLEANUP_DONE=false
cleanup() {
    local signal="${1:-EXIT}"
    local exit_code="${2:-$?}"

    # Prevent multiple executions
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    # Stop all spinners and clear the line
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2> /dev/null || true
        wait "$SPINNER_PID" 2> /dev/null || true
        SPINNER_PID=""
    fi

    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        kill "$INLINE_SPINNER_PID" 2> /dev/null || true
        wait "$INLINE_SPINNER_PID" 2> /dev/null || true
        INLINE_SPINNER_PID=""
    fi

    # Clear any spinner output
    if [[ -t 1 ]]; then
        printf "\r\033[K"
    fi

    # Stop sudo keepalive
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2> /dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2> /dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi

    show_cursor

    # If interrupted, show message
    if [[ "$signal" == "INT" ]] || [[ $exit_code -eq 130 ]]; then
        printf "\r\033[K"
        echo -e "${YELLOW}Interrupted by user${NC}"
    fi
}

trap 'cleanup EXIT $?' EXIT
trap 'cleanup INT 130; exit 130' INT
trap 'cleanup TERM 143; exit 143' TERM

# Loading animation functions
SPINNER_PID=""
start_spinner() {
    local message="$1"

    if [[ ! -t 1 ]]; then
        echo -n "  ${BLUE}${ICON_CONFIRM}${NC} $message"
        return
    fi

    echo -n "  ${BLUE}${ICON_CONFIRM}${NC} $message"
    (
        local delay=0.5
        while true; do
            printf "\r  ${BLUE}${ICON_CONFIRM}${NC} $message.  "
            sleep $delay
            printf "\r  ${BLUE}${ICON_CONFIRM}${NC} $message.. "
            sleep $delay
            printf "\r  ${BLUE}${ICON_CONFIRM}${NC} $message..."
            sleep $delay
            printf "\r  ${BLUE}${ICON_CONFIRM}${NC} $message   "
            sleep $delay
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    local result_message="${1:-Done}"

    if [[ ! -t 1 ]]; then
        echo " ✓ $result_message"
        return
    fi

    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2> /dev/null
        wait "$SPINNER_PID" 2> /dev/null
        SPINNER_PID=""
        printf "\r  ${GREEN}${ICON_SUCCESS}${NC} %s\n" "$result_message"
    else
        echo "  ${GREEN}${ICON_SUCCESS}${NC} $result_message"
    fi
}

start_section() {
    TRACK_SECTION=1
    SECTION_ACTIVITY=0
    echo ""
    echo -e "${PURPLE}${ICON_ARROW} $1${NC}"
}

end_section() {
    if [[ $TRACK_SECTION -eq 1 && $SECTION_ACTIVITY -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Nothing to tidy"
    fi
    TRACK_SECTION=0
}

safe_clean() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local description
    local -a targets

    if [[ $# -eq 1 ]]; then
        description="$1"
        targets=("$1")
    else
        # Get last argument as description
        description="${*: -1}"
        # Get all arguments except last as targets array
        targets=("${@:1:$#-1}")
    fi

    local removed_any=0
    local total_size_bytes=0
    local total_count=0
    local skipped_count=0

    # Optimized parallel processing for better performance
    local -a existing_paths=()
    for path in "${targets[@]}"; do
        local skip=false
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for w in "${WHITELIST_PATTERNS[@]}"; do
                # Match both exact path and glob pattern
                # shellcheck disable=SC2053
                if [[ "$path" == "$w" ]] || [[ $path == $w ]]; then
                    skip=true
                    ((skipped_count++))
                    break
                fi
            done
        fi
        [[ "$skip" == "true" ]] && continue
        [[ -e "$path" ]] && existing_paths+=("$path")
    done

    # Update global whitelist skip counter
    if [[ $skipped_count -gt 0 ]]; then
        ((whitelist_skipped_count += skipped_count))
    fi

    if [[ ${#existing_paths[@]} -eq 0 ]]; then
        return 0
    fi

    # Show progress indicator for potentially slow operations
    if [[ ${#existing_paths[@]} -gt 3 ]]; then
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning $total_paths items..."; fi
        local temp_dir
        temp_dir=$(create_temp_dir)

        # Parallel processing (bash 3.2 compatible)
        local -a pids=()
        local idx=0
        local completed=0
        for path in "${existing_paths[@]}"; do
            (
                local size
                size=$(du -sk "$path" 2> /dev/null | awk '{print $1}' || echo "0")
                local count
                count=$(find "$path" -type f 2> /dev/null | wc -l | tr -d ' ')
                # Use index + PID for unique filename
                local tmp_file="$temp_dir/result_${idx}.$$"
                echo "$size $count" > "$tmp_file"
                mv "$tmp_file" "$temp_dir/result_${idx}" 2> /dev/null || true
            ) &
            pids+=($!)
            ((idx++))

            if ((${#pids[@]} >= MAX_PARALLEL_JOBS)); then
                wait "${pids[0]}" 2> /dev/null || true
                pids=("${pids[@]:1}")
                ((completed++))
                # Update progress every 10 items for smoother display
                if [[ -t 1 ]] && ((completed % 10 == 0)); then
                    stop_inline_spinner
                    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning items ($completed/$total_paths)..."
                fi
            fi
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2> /dev/null || true
            ((completed++))
        done

        # Read results using same index
        idx=0
        for path in "${existing_paths[@]}"; do
            local result_file="$temp_dir/result_${idx}"
            if [[ -f "$result_file" ]]; then
                read -r size count < "$result_file" 2> /dev/null || true
                if [[ "$count" -gt 0 && "$size" -gt 0 ]]; then
                    if [[ "$DRY_RUN" != "true" ]]; then
                        rm -rf "$path" 2> /dev/null || true
                    fi
                    ((total_size_bytes += size))
                    ((total_count += count))
                    removed_any=1
                fi
            fi
            ((idx++))
        done

        # Temp dir will be auto-cleaned by cleanup_temp_files
    else
        # Show progress for small batches too (simpler jobs)
        local total_paths=${#existing_paths[@]}
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning $total_paths items..."; fi

        for path in "${existing_paths[@]}"; do
            local size_bytes
            size_bytes=$(du -sk "$path" 2> /dev/null | awk '{print $1}' || echo "0")
            local count
            count=$(find "$path" -type f 2> /dev/null | wc -l | tr -d ' ')

            if [[ "$count" -gt 0 && "$size_bytes" -gt 0 ]]; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    rm -rf "$path" 2> /dev/null || true
                fi
                ((total_size_bytes += size_bytes))
                ((total_count += count))
                removed_any=1
            fi
        done
    fi

    # Clear progress / stop spinner before showing result
    if [[ -t 1 ]]; then
        stop_inline_spinner
        echo -ne "\r\033[K"
    fi

    if [[ $removed_any -eq 1 ]]; then
        # Convert KB to bytes for bytes_to_human()
        local size_human=$(bytes_to_human "$((total_size_bytes * 1024))")

        local label="$description"
        if [[ ${#targets[@]} -gt 1 ]]; then
            label+=" ${#targets[@]} items"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}→${NC} $label ${YELLOW}($size_human dry)${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label ${GREEN}($size_human)${NC}"
        fi
        ((files_cleaned += total_count))
        ((total_size_cleaned += total_size_bytes))
        ((total_items++))
        note_activity
    fi

    return 0
}

start_cleanup() {
    clear
    printf '\n'
    echo -e "${PURPLE}Clean Your Mac${NC}"

    if [[ "$DRY_RUN" != "true" && -t 0 ]]; then
        echo ""
        echo -e "${YELLOW}Tip:${NC} Safety first—run 'mo clean --dry-run'. Important Macs should stop."
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}Dry Run Mode${NC} - Preview only, no deletions"
        echo ""
        SYSTEM_CLEAN=false
        return
    fi

    if [[ -t 0 ]]; then
        echo ""
        echo -ne "${PURPLE}${ICON_ARROW}${NC} System caches need sudo — ${GREEN}Enter${NC} continue, other key skip: "

        # Use IFS= and read without -n to allow Ctrl+C to work properly
        IFS= read -r -s -n 1 choice
        local read_status=$?

        # If read was interrupted (Ctrl+C), exit cleanly
        if [[ $read_status -ne 0 ]]; then
            echo ""
            exit 130
        fi

        if [[ "$choice" == $'\e' ]]; then
            echo -e " ${GRAY}Cancelled${NC}"
            exit 0
        fi

        # Enter = yes, do system cleanup
        if [[ -z "$choice" ]] || [[ "$choice" == $'\n' ]]; then
            printf "\r\033[K" # Clear the prompt line
            if request_sudo_access "System cleanup requires admin access"; then
                SYSTEM_CLEAN=true
                echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access granted"
                echo ""
                # Start sudo keepalive with error handling
                (
                    local retry_count=0
                    while true; do
                        if ! sudo -n true 2> /dev/null; then
                            ((retry_count++))
                            if [[ $retry_count -ge 3 ]]; then
                                exit 1
                            fi
                            sleep 5
                            continue
                        fi
                        retry_count=0
                        sleep 30
                        kill -0 "$$" 2> /dev/null || exit
                    done
                ) 2> /dev/null &
                SUDO_KEEPALIVE_PID=$!
            else
                SYSTEM_CLEAN=false
                echo ""
                echo -e "${YELLOW}Authentication failed${NC}, continuing with user-level cleanup"
            fi
        else
            # ESC or other key = no system cleanup
            SYSTEM_CLEAN=false
            echo ""
            echo -e "${GRAY}Skipped system cleanup, user-level only${NC}"
        fi
    else
        SYSTEM_CLEAN=false
        echo ""
        echo "Running in non-interactive mode"
        echo "  • System-level cleanup skipped (requires interaction)"
        echo "  • User-level cleanup will proceed automatically"
        echo ""
    fi
}

# Clean Service Worker CacheStorage with domain protection
clean_service_worker_cache() {
    local browser_name="$1"
    local cache_path="$2"

    [[ ! -d "$cache_path" ]] && return 0

    local cleaned_size=0
    local protected_count=0

    # Find all cache directories and calculate sizes
    while IFS= read -r cache_dir; do
        [[ ! -d "$cache_dir" ]] && continue

        # Extract domain from path
        local domain=$(basename "$cache_dir" | grep -oE '[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}' | head -1 || echo "")
        local size=$(du -sk "$cache_dir" 2>/dev/null | awk '{print $1}')

        # Check if domain is protected
        local is_protected=false
        for protected_domain in "${PROTECTED_SW_DOMAINS[@]}"; do
            if [[ "$domain" == *"$protected_domain"* ]]; then
                is_protected=true
                protected_count=$((protected_count + 1))
                break
            fi
        done

        # Clean if not protected
        if [[ "$is_protected" == "false" ]]; then
            if [[ "$DRY_RUN" != "true" ]]; then
                rm -rf "$cache_dir" 2>/dev/null || true
            fi
            cleaned_size=$((cleaned_size + size))
        fi
    done < <(find "$cache_path" -type d -depth 2 2>/dev/null)

    if [[ $cleaned_size -gt 0 ]]; then
        local cleaned_mb=$((cleaned_size / 1024))
        if [[ "$DRY_RUN" != "true" ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $browser_name Service Worker cache (${cleaned_mb}MB cleaned, $protected_count protected)"
        else
            echo -e "  ${YELLOW}→${NC} $browser_name Service Worker cache (would clean ${cleaned_mb}MB, $protected_count protected)"
        fi
        note_activity
    fi
}

perform_cleanup() {
    echo -e "${BLUE}${ICON_ADMIN}${NC} $(detect_architecture) | Free space: $(get_free_space)"

    # Show whitelist info if patterns are active
    local active_count=${#WHITELIST_PATTERNS[@]}
    if [[ $active_count -gt 2 ]]; then
        local custom_count=$((active_count - 2))
        echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: $custom_count custom + 2 core patterns active"
    elif [[ $active_count -eq 2 ]]; then
        echo -e "${BLUE}${ICON_SUCCESS}${NC} Whitelist: 2 core patterns active"
    fi

    # Initialize counters
    total_items=0
    files_cleaned=0
    total_size_cleaned=0

    # ===== 1. Deep system cleanup (if admin) - Do this first while sudo is fresh =====
    if [[ "$SYSTEM_CLEAN" == "true" ]]; then
        start_section "Deep system-level cleanup"

        # Clean system caches more safely
        sudo find /Library/Caches -name "*.cache" -delete 2> /dev/null || true
        sudo find /Library/Caches -name "*.tmp" -delete 2> /dev/null || true
        sudo find /Library/Caches -type f -name "*.log" -delete 2> /dev/null || true

        # Clean old temp files only (avoid breaking running processes)
        local tmp_cleaned=0
        local tmp_count=$(sudo find /tmp -type f -mtime +${TEMP_FILE_AGE_DAYS} 2> /dev/null | wc -l | tr -d ' ')
        if [[ "$tmp_count" -gt 0 ]]; then
            sudo find /tmp -type f -mtime +${TEMP_FILE_AGE_DAYS} -delete 2> /dev/null || true
            tmp_cleaned=1
        fi
        local var_tmp_count=$(sudo find /var/tmp -type f -mtime +${TEMP_FILE_AGE_DAYS} 2> /dev/null | wc -l | tr -d ' ')
        if [[ "$var_tmp_count" -gt 0 ]]; then
            sudo find /var/tmp -type f -mtime +${TEMP_FILE_AGE_DAYS} -delete 2> /dev/null || true
            tmp_cleaned=1
        fi
        [[ $tmp_cleaned -eq 1 ]] && log_success "Old system temp files (${TEMP_FILE_AGE_DAYS}+ days)"

        sudo rm -rf /Library/Updates/* 2> /dev/null || true
        log_success "System library caches and updates"

        end_section
    fi

    # Show whitelist warnings if any
    if [[ ${#WHITELIST_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        for warning in "${WHITELIST_WARNINGS[@]}"; do
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Whitelist: $warning"
        done
    fi

    # ===== 2. User essentials =====
    start_section "System essentials"
    safe_clean ~/Library/Caches/* "User app cache"
    safe_clean ~/Library/Logs/* "User app logs"
    safe_clean ~/.Trash/* "Trash"

    # Empty trash on mounted volumes
    if [[ -d "/Volumes" ]]; then
        for volume in /Volumes/*; do
            [[ -d "$volume" && -d "$volume/.Trashes" && -w "$volume" ]] || continue

            # Skip network volumes
            local fs_type=$(df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}')
            case "$fs_type" in
                nfs | smbfs | afpfs | cifs | webdav) continue ;;
            esac

            # Verify volume is mounted
            if mount | grep -q "on $volume "; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    find "$volume/.Trashes" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2> /dev/null || true
                fi
            fi
        done
    fi

    safe_clean ~/Library/Application\ Support/CrashReporter/* "Crash reports"
    safe_clean ~/Library/DiagnosticReports/* "Diagnostic reports"
    safe_clean ~/Library/Caches/com.apple.QuickLook.thumbnailcache "QuickLook thumbnails"
    safe_clean ~/Library/Caches/Quick\ Look/* "QuickLook cache"
    # Skip: affects Bluetooth audio service registration
    # safe_clean ~/Library/Caches/com.apple.LaunchServices* "Launch services cache"
    safe_clean ~/Library/Caches/com.apple.iconservices* "Icon services cache"
    safe_clean ~/Library/Caches/CloudKit/* "CloudKit cache"
    # Skip: may affect renamed Bluetooth device pairing
    # safe_clean ~/Library/Caches/com.apple.bird* "iCloud cache"

    # Clean incomplete downloads
    safe_clean ~/Downloads/*.download "Incomplete downloads (Safari)"
    safe_clean ~/Downloads/*.crdownload "Incomplete downloads (Chrome)"
    safe_clean ~/Downloads/*.part "Incomplete downloads (partial)"
    end_section

    # ===== 3. macOS System Caches =====
    start_section "macOS system caches"
    safe_clean ~/Library/Saved\ Application\ State/* "Saved application states"
    safe_clean ~/Library/Caches/com.apple.spotlight "Spotlight cache"
    # Skip: may store Bluetooth device info
    # safe_clean ~/Library/Caches/com.apple.metadata "Metadata cache"
    safe_clean ~/Library/Caches/com.apple.FontRegistry "Font registry cache"
    safe_clean ~/Library/Caches/com.apple.ATS "Font cache"
    safe_clean ~/Library/Caches/com.apple.photoanalysisd "Photo analysis cache"
    safe_clean ~/Library/Caches/com.apple.akd "Apple ID cache"
    safe_clean ~/Library/Caches/com.apple.Safari/Webpage\ Previews/* "Safari webpage previews"
    # Mail envelope index and backup index are intentionally not cleaned (issue #32)
    safe_clean ~/Library/Application\ Support/CloudDocs/session/db/* "iCloud session cache"
    end_section

    # ===== 4. Sandboxed App Caches =====
    start_section "Sandboxed app caches"
    safe_clean ~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/* "Wallpaper agent cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/* "Media analysis cache"
    safe_clean ~/Library/Containers/com.apple.AppStore/Data/Library/Caches/* "App Store cache"
    safe_clean ~/Library/Containers/*/Data/Library/Caches/* "Sandboxed app caches"
    end_section

    # ===== 5. Browsers =====
    start_section "Browser cleanup"
    safe_clean ~/Library/Caches/com.apple.Safari/* "Safari cache"

    # Chrome/Chromium
    safe_clean ~/Library/Caches/Google/Chrome/* "Chrome cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/Application\ Cache/* "Chrome app cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/GPUCache/* "Chrome GPU cache"
    safe_clean ~/Library/Caches/Chromium/* "Chromium cache"

    safe_clean ~/Library/Caches/com.microsoft.edgemac/* "Edge cache"
    safe_clean ~/Library/Caches/company.thebrowser.Browser/* "Arc cache"
    safe_clean ~/Library/Caches/company.thebrowser.dia/* "Dia cache"
    safe_clean ~/Library/Caches/BraveSoftware/Brave-Browser/* "Brave cache"
    safe_clean ~/Library/Caches/Firefox/* "Firefox cache"
    safe_clean ~/Library/Caches/com.operasoftware.Opera/* "Opera cache"
    safe_clean ~/Library/Caches/com.vivaldi.Vivaldi/* "Vivaldi cache"
    safe_clean ~/Library/Caches/Comet/* "Comet cache"
    safe_clean ~/Library/Caches/com.kagi.kagimacOS/* "Orion cache"
    safe_clean ~/Library/Caches/zen/* "Zen cache"
    safe_clean ~/Library/Application\ Support/Firefox/Profiles/*/cache2/* "Firefox profile cache"

    # Service Worker CacheStorage (all profiles)
    while IFS= read -r sw_path; do
        local profile_name=$(basename "$(dirname "$(dirname "$sw_path")")")
        local browser_name="Chrome"
        [[ "$sw_path" == *"Microsoft Edge"* ]] && browser_name="Edge"
        [[ "$sw_path" == *"Brave"* ]] && browser_name="Brave"
        [[ "$sw_path" == *"Arc"* ]] && browser_name="Arc"
        [[ "$profile_name" != "Default" ]] && browser_name="$browser_name ($profile_name)"
        clean_service_worker_cache "$browser_name" "$sw_path"
    done < <(find "$HOME/Library/Application Support/Google/Chrome" \
                  "$HOME/Library/Application Support/Microsoft Edge" \
                  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" \
                  "$HOME/Library/Application Support/Arc/User Data" \
                  -type d -name "CacheStorage" -path "*/Service Worker/*" 2>/dev/null)
    end_section

    # ===== 6. Cloud Storage =====
    start_section "Cloud storage caches"
    safe_clean ~/Library/Caches/com.dropbox.* "Dropbox cache"
    safe_clean ~/Library/Caches/com.getdropbox.dropbox "Dropbox cache"
    safe_clean ~/Library/Caches/com.google.GoogleDrive "Google Drive cache"
    safe_clean ~/Library/Caches/com.baidu.netdisk "Baidu Netdisk cache"
    safe_clean ~/Library/Caches/com.alibaba.teambitiondisk "Alibaba Cloud cache"
    safe_clean ~/Library/Caches/com.box.desktop "Box cache"
    safe_clean ~/Library/Caches/com.microsoft.OneDrive "OneDrive cache"
    end_section

    # ===== 7. Office Applications =====
    start_section "Office applications"
    safe_clean ~/Library/Caches/com.microsoft.Word "Microsoft Word cache"
    safe_clean ~/Library/Caches/com.microsoft.Excel "Microsoft Excel cache"
    safe_clean ~/Library/Caches/com.microsoft.Powerpoint "Microsoft PowerPoint cache"
    safe_clean ~/Library/Caches/com.microsoft.Outlook/* "Microsoft Outlook cache"
    safe_clean ~/Library/Caches/com.apple.iWork.* "Apple iWork cache"
    safe_clean ~/Library/Caches/com.kingsoft.wpsoffice.mac "WPS Office cache"
    safe_clean ~/Library/Caches/org.mozilla.thunderbird/* "Thunderbird cache"
    safe_clean ~/Library/Caches/com.apple.mail/* "Apple Mail cache"
    end_section

    # ===== 8. Developer tools =====
    start_section "Developer tools"
    if command -v npm > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "npm cache" npm cache clean --force
        else
            echo -e "  ${YELLOW}→${NC} npm cache (would clean)"
        fi
        note_activity
    fi

    safe_clean ~/.npm/_cacache/* "npm cache directory"
    safe_clean ~/.npm/_logs/* "npm logs"
    safe_clean ~/.yarn/cache/* "Yarn cache"
    safe_clean ~/.bun/install/cache/* "Bun cache"

    if command -v pip3 > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "pip cache" bash -c 'pip3 cache purge >/dev/null 2>&1 || true'
        else
            echo -e "  ${YELLOW}→${NC} pip cache (would clean)"
        fi
        note_activity
    fi

    safe_clean ~/.cache/pip/* "pip cache directory"
    safe_clean ~/Library/Caches/pip/* "pip cache (macOS)"
    safe_clean ~/.pyenv/cache/* "pyenv cache"

    if command -v go > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "Go cache" bash -c 'go clean -modcache >/dev/null 2>&1 || true; go clean -cache >/dev/null 2>&1 || true'
        else
            echo -e "  ${YELLOW}→${NC} Go cache (would clean)"
        fi
        note_activity
    fi

    safe_clean ~/Library/Caches/go-build/* "Go build cache"
    safe_clean ~/go/pkg/mod/cache/* "Go module cache"
    safe_clean ~/.cargo/registry/cache/* "Rust cargo cache"

    # Docker build cache
    if command -v docker > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "Docker build cache" docker builder prune -af
        else
            echo -e "  ${YELLOW}→${NC} Docker build cache (would clean)"
        fi
        note_activity
    fi

    safe_clean ~/.kube/cache/* "Kubernetes cache"
    safe_clean ~/.local/share/containers/storage/tmp/* "Container storage temp"
    safe_clean ~/.aws/cli/cache/* "AWS CLI cache"
    safe_clean ~/.config/gcloud/logs/* "Google Cloud logs"
    safe_clean ~/.azure/logs/* "Azure CLI logs"
    safe_clean ~/Library/Caches/Homebrew/* "Homebrew cache"
    safe_clean /opt/homebrew/var/homebrew/locks/* "Homebrew lock files (M series)"
    safe_clean /usr/local/var/homebrew/locks/* "Homebrew lock files (Intel)"
    if command -v brew > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Homebrew cleanup..."; fi
            # Run brew cleanup and capture output
            local brew_output
            brew_output=$(brew cleanup -s --prune=all 2>&1)
            if [[ -t 1 ]]; then stop_inline_spinner; fi

            # Show summary of what was cleaned
            local removed_count=$(echo "$brew_output" | grep -c "Removing:" || echo "0")
            local freed_space=$(echo "$brew_output" | grep -o "[0-9.]*[KMGT]B freed" | tail -1 || echo "")

            if [[ $removed_count -gt 0 ]] || [[ -n "$freed_space" ]]; then
                if [[ -n "$freed_space" ]]; then
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup ${GREEN}($freed_space)${NC}"
                else
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup (${removed_count} items)"
                fi
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup"
            fi
        else
            echo -e "  ${YELLOW}→${NC} Homebrew (would cleanup)"
        fi
        note_activity
    fi

    # Nix package manager
    if command -v nix-collect-garbage > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "Nix garbage collection" nix-collect-garbage --delete-older-than 30d
        else
            echo -e "  ${YELLOW}→${NC} Nix garbage collection (would clean)"
        fi
        note_activity
    fi

    safe_clean ~/.gitconfig.lock "Git config lock"
    end_section

    # ===== 9. Extended developer caches =====
    start_section "Extended developer caches"
    safe_clean ~/.pnpm-store/* "pnpm store cache"
    safe_clean ~/.local/share/pnpm/store/* "pnpm global store"
    safe_clean ~/.cache/typescript/* "TypeScript cache"
    safe_clean ~/.cache/electron/* "Electron cache"
    safe_clean ~/.cache/node-gyp/* "node-gyp cache"
    safe_clean ~/.node-gyp/* "node-gyp build cache"
    # Note: ~/.turbo and ~/.vite may contain important configuration
    # Only clean cache subdirectories if they exist
    safe_clean ~/.turbo/cache/* "Turbo cache"
    # Note: Next.js cache is per-project (.next/cache), not in home directory
    # safe_clean ~/.next/* "Next.js cache"  # REMOVED: Not a standard cache location
    safe_clean ~/.vite/cache/* "Vite cache"
    safe_clean ~/.cache/vite/* "Vite global cache"
    safe_clean ~/.cache/webpack/* "Webpack cache"
    safe_clean ~/.parcel-cache/* "Parcel cache"
    safe_clean ~/Library/Caches/Google/AndroidStudio*/* "Android Studio cache"
    safe_clean ~/Library/Caches/com.unity3d.*/* "Unity cache"
    safe_clean ~/Library/Caches/com.jetbrains.toolbox/* "JetBrains Toolbox cache"
    safe_clean ~/Library/Caches/com.postmanlabs.mac/* "Postman cache"
    safe_clean ~/Library/Caches/com.konghq.insomnia/* "Insomnia cache"
    safe_clean ~/Library/Caches/com.tinyapp.TablePlus/* "TablePlus cache"
    safe_clean ~/Library/Caches/com.mongodb.compass/* "MongoDB Compass cache"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma cache"
    safe_clean ~/Library/Caches/com.github.GitHubDesktop/* "GitHub Desktop cache"
    safe_clean ~/Library/Caches/com.microsoft.VSCode/* "VS Code cache"
    safe_clean ~/Library/Caches/com.sublimetext.*/* "Sublime Text cache"
    safe_clean ~/.cache/poetry/* "Poetry cache"
    safe_clean ~/.cache/uv/* "uv cache"
    safe_clean ~/.cache/ruff/* "Ruff cache"
    safe_clean ~/.cache/mypy/* "MyPy cache"
    safe_clean ~/.pytest_cache/* "Pytest cache"
    safe_clean ~/.jupyter/runtime/* "Jupyter runtime cache"
    safe_clean ~/.cache/huggingface/* "Hugging Face cache"
    safe_clean ~/.cache/torch/* "PyTorch cache"
    safe_clean ~/.cache/tensorflow/* "TensorFlow cache"
    safe_clean ~/.conda/pkgs/* "Conda packages cache"
    safe_clean ~/anaconda3/pkgs/* "Anaconda packages cache"
    safe_clean ~/.cache/wandb/* "Weights & Biases cache"
    safe_clean ~/.cargo/git/* "Cargo git cache"
    safe_clean ~/.rustup/toolchains/*/share/doc/* "Rust documentation cache"
    safe_clean ~/.rustup/downloads/* "Rust downloads cache"
    safe_clean ~/.gradle/caches/* "Gradle caches"
    safe_clean ~/.m2/repository/* "Maven repository cache"
    safe_clean ~/.sbt/* "SBT cache"
    safe_clean ~/.docker/buildx/cache/* "Docker BuildX cache"
    safe_clean ~/.cache/terraform/* "Terraform cache"
    safe_clean ~/Library/Caches/com.getpaw.Paw/* "Paw API cache"
    safe_clean ~/Library/Caches/com.charlesproxy.charles/* "Charles Proxy cache"
    safe_clean ~/Library/Caches/com.proxyman.NSProxy/* "Proxyman cache"
    safe_clean ~/.grafana/cache/* "Grafana cache"
    safe_clean ~/.prometheus/data/wal/* "Prometheus WAL cache"
    safe_clean ~/.jenkins/workspace/*/target/* "Jenkins workspace cache"
    safe_clean ~/.cache/gitlab-runner/* "GitLab Runner cache"
    safe_clean ~/.github/cache/* "GitHub Actions cache"
    safe_clean ~/.circleci/cache/* "CircleCI cache"
    safe_clean ~/.oh-my-zsh/cache/* "Oh My Zsh cache"
    safe_clean ~/.config/fish/fish_history.bak* "Fish shell backup"
    safe_clean ~/.bash_history.bak* "Bash history backup"
    safe_clean ~/.zsh_history.bak* "Zsh history backup"
    safe_clean ~/.sonar/* "SonarQube cache"
    safe_clean ~/.cache/eslint/* "ESLint cache"
    safe_clean ~/.cache/prettier/* "Prettier cache"
    safe_clean ~/Library/Caches/CocoaPods/* "CocoaPods cache"
    safe_clean ~/.bundle/cache/* "Ruby Bundler cache"
    safe_clean ~/.composer/cache/* "PHP Composer cache"
    safe_clean ~/.nuget/packages/* "NuGet packages cache"
    safe_clean ~/.ivy2/cache/* "Ivy cache"
    safe_clean ~/.pub-cache/* "Dart Pub cache"
    safe_clean ~/.cache/curl/* "curl cache"
    safe_clean ~/.cache/wget/* "wget cache"
    safe_clean ~/Library/Caches/curl/* "curl cache (macOS)"
    safe_clean ~/Library/Caches/wget/* "wget cache (macOS)"
    safe_clean ~/.cache/pre-commit/* "pre-commit cache"
    safe_clean ~/.gitconfig.bak* "Git config backup"
    safe_clean ~/.cache/flutter/* "Flutter cache"
    safe_clean ~/.gradle/daemon/* "Gradle daemon logs"
    safe_clean ~/.android/build-cache/* "Android build cache"
    safe_clean ~/.android/cache/* "Android SDK cache"
    safe_clean ~/Library/Developer/Xcode/iOS\ DeviceSupport/*/Symbols/System/Library/Caches/* "iOS device cache"
    safe_clean ~/Library/Developer/Xcode/UserData/IB\ Support/* "Xcode Interface Builder cache"
    safe_clean ~/.cache/swift-package-manager/* "Swift package manager cache"
    safe_clean ~/.cache/bazel/* "Bazel cache"
    safe_clean ~/.cache/zig/* "Zig cache"
    safe_clean ~/Library/Caches/deno/* "Deno cache"
    safe_clean ~/Library/Caches/com.sequel-ace.sequel-ace/* "Sequel Ace cache"
    safe_clean ~/Library/Caches/com.eggerapps.Sequel-Pro/* "Sequel Pro cache"
    safe_clean ~/Library/Caches/redis-desktop-manager/* "Redis Desktop Manager cache"
    safe_clean ~/Library/Caches/com.navicat.* "Navicat cache"
    safe_clean ~/Library/Caches/com.dbeaver.* "DBeaver cache"
    safe_clean ~/Library/Caches/com.redis.RedisInsight "Redis Insight cache"
    safe_clean ~/Library/Caches/SentryCrash/* "Sentry crash reports"
    safe_clean ~/Library/Caches/KSCrash/* "KSCrash reports"
    safe_clean ~/Library/Caches/com.crashlytics.data/* "Crashlytics data"
    # Skip: HTTPStorages contains login sessions
    # safe_clean ~/Library/HTTPStorages/* "HTTP storage cache"

    end_section

    # ===== 10. Applications =====
    start_section "Applications"
    safe_clean ~/Library/Developer/Xcode/DerivedData/* "Xcode derived data"
    # Skip: Archives contain signed App Store builds
    # safe_clean ~/Library/Developer/Xcode/Archives/* "Xcode archives"
    safe_clean ~/Library/Developer/CoreSimulator/Caches/* "Simulator cache"
    safe_clean ~/Library/Developer/CoreSimulator/Devices/*/data/tmp/* "Simulator temp files"
    safe_clean ~/Library/Caches/com.apple.dt.Xcode/* "Xcode cache"
    safe_clean ~/Library/Developer/Xcode/iOS\ Device\ Logs/* "iOS device logs"
    safe_clean ~/Library/Developer/Xcode/watchOS\ Device\ Logs/* "watchOS device logs"
    safe_clean ~/Library/Developer/Xcode/Products/* "Xcode build products"
    safe_clean ~/Library/Application\ Support/Code/logs/* "VS Code logs"
    safe_clean ~/Library/Application\ Support/Code/Cache/* "VS Code cache"
    safe_clean ~/Library/Application\ Support/Code/CachedExtensions/* "VS Code extension cache"
    safe_clean ~/Library/Application\ Support/Code/CachedData/* "VS Code data cache"
    safe_clean ~/Library/Logs/IntelliJIdea*/* "IntelliJ IDEA logs"
    safe_clean ~/Library/Logs/PhpStorm*/* "PhpStorm logs"
    safe_clean ~/Library/Logs/PyCharm*/* "PyCharm logs"
    safe_clean ~/Library/Logs/WebStorm*/* "WebStorm logs"
    safe_clean ~/Library/Logs/GoLand*/* "GoLand logs"
    safe_clean ~/Library/Logs/CLion*/* "CLion logs"
    safe_clean ~/Library/Logs/DataGrip*/* "DataGrip logs"
    safe_clean ~/Library/Caches/JetBrains/* "JetBrains cache"
    safe_clean ~/Library/Application\ Support/discord/Cache/* "Discord cache"
    safe_clean ~/Library/Application\ Support/Slack/Cache/* "Slack cache"
    safe_clean ~/Library/Caches/us.zoom.xos/* "Zoom cache"
    safe_clean ~/Library/Caches/com.tencent.xinWeChat/* "WeChat cache"
    safe_clean ~/Library/Caches/ru.keepcoder.Telegram/* "Telegram cache"
    safe_clean ~/Library/Caches/com.openai.chat/* "ChatGPT cache"
    safe_clean ~/Library/Caches/com.anthropic.claudefordesktop/* "Claude desktop cache"
    safe_clean ~/Library/Logs/Claude/* "Claude logs"
    safe_clean ~/Library/Caches/com.microsoft.teams2/* "Microsoft Teams cache"
    safe_clean ~/Library/Caches/net.whatsapp.WhatsApp/* "WhatsApp cache"
    safe_clean ~/Library/Caches/com.skype.skype/* "Skype cache"
    safe_clean ~/Library/Caches/dd.work.exclusive4aliding/* "DingTalk (iDingTalk) cache"
    safe_clean ~/Library/Caches/com.alibaba.AliLang.osx/* "AliLang security component"
    safe_clean ~/Library/Application\ Support/iDingTalk/log/* "DingTalk logs"
    safe_clean ~/Library/Application\ Support/iDingTalk/holmeslogs/* "DingTalk holmes logs"
    safe_clean ~/Library/Caches/com.tencent.meeting/* "Tencent Meeting cache"
    safe_clean ~/Library/Caches/com.tencent.WeWorkMac/* "WeCom cache"
    safe_clean ~/Library/Caches/com.feishu.*/* "Feishu cache"
    safe_clean ~/Library/Caches/com.bohemiancoding.sketch3/* "Sketch cache"
    safe_clean ~/Library/Application\ Support/com.bohemiancoding.sketch3/cache/* "Sketch app cache"
    safe_clean ~/Library/Caches/net.telestream.screenflow10/* "ScreenFlow cache"
    safe_clean ~/Library/Caches/Adobe/* "Adobe cache"
    safe_clean ~/Library/Caches/com.adobe.*/* "Adobe app caches"
    safe_clean ~/Library/Application\ Support/Adobe/Common/Media\ Cache\ Files/* "Adobe media cache"
    safe_clean ~/Library/Application\ Support/Adobe/Common/Peak\ Files/* "Adobe peak files"
    safe_clean ~/Library/Caches/com.apple.FinalCut/* "Final Cut Pro cache"
    safe_clean ~/Library/Application\ Support/Final\ Cut\ Pro/*/Render\ Files/* "Final Cut render cache"
    safe_clean ~/Library/Application\ Support/Motion/*/Render\ Files/* "Motion render cache"
    safe_clean ~/Library/Caches/com.blackmagic-design.DaVinciResolve/* "DaVinci Resolve cache"
    safe_clean ~/Library/Caches/com.adobe.PremierePro.*/* "Premiere Pro cache"
    safe_clean ~/Library/Caches/org.blenderfoundation.blender/* "Blender cache"
    safe_clean ~/Library/Caches/com.maxon.cinema4d/* "Cinema 4D cache"
    safe_clean ~/Library/Caches/com.autodesk.*/* "Autodesk cache"
    safe_clean ~/Library/Caches/com.sketchup.*/* "SketchUp cache"
    safe_clean ~/Library/Caches/com.raycast.macos/* "Raycast cache"
    safe_clean ~/Library/Caches/com.tw93.MiaoYan/* "MiaoYan cache"
    safe_clean ~/Library/Caches/com.klee.desktop/* "Klee cache"
    safe_clean ~/Library/Caches/klee_desktop/* "Klee desktop cache"
    safe_clean ~/Library/Caches/com.orabrowser.app/* "Ora browser cache"
    safe_clean ~/Library/Caches/com.filo.client/* "Filo cache"
    safe_clean ~/Library/Caches/com.flomoapp.mac/* "Flomo cache"
    safe_clean ~/Library/Caches/com.spotify.client/* "Spotify cache"
    safe_clean ~/Library/Caches/com.apple.Music "Apple Music cache"
    safe_clean ~/Library/Caches/com.apple.podcasts "Apple Podcasts cache"
    safe_clean ~/Library/Caches/com.apple.TV/* "Apple TV cache"
    safe_clean ~/Library/Caches/tv.plex.player.desktop "Plex cache"
    safe_clean ~/Library/Caches/com.netease.163music "NetEase Music cache"
    safe_clean ~/Library/Caches/com.tencent.QQMusic/* "QQ Music cache"
    safe_clean ~/Library/Caches/com.kugou.mac/* "Kugou Music cache"
    safe_clean ~/Library/Caches/com.kuwo.mac/* "Kuwo Music cache"
    safe_clean ~/Library/Caches/com.colliderli.iina "IINA cache"
    safe_clean ~/Library/Caches/org.videolan.vlc "VLC cache"
    safe_clean ~/Library/Caches/io.mpv "MPV cache"
    safe_clean ~/Library/Caches/com.iqiyi.player "iQIYI cache"
    safe_clean ~/Library/Caches/com.tencent.tenvideo "Tencent Video cache"
    safe_clean ~/Library/Caches/tv.danmaku.bili/* "Bilibili cache"
    safe_clean ~/Library/Caches/com.douyu.*/* "Douyu cache"
    safe_clean ~/Library/Caches/com.huya.*/* "Huya cache"
    safe_clean ~/Library/Caches/net.xmac.aria2gui "Aria2 cache"
    safe_clean ~/Library/Caches/org.m0k.transmission "Transmission cache"
    safe_clean ~/Library/Caches/com.qbittorrent.qBittorrent "qBittorrent cache"
    safe_clean ~/Library/Caches/com.downie.Downie-* "Downie cache"
    safe_clean ~/Library/Caches/com.folx.*/* "Folx cache"
    safe_clean ~/Library/Caches/com.charlessoft.pacifist/* "Pacifist cache"
    safe_clean ~/Library/Caches/com.valvesoftware.steam/* "Steam cache"
    safe_clean ~/Library/Application\ Support/Steam/appcache/* "Steam app cache"
    safe_clean ~/Library/Application\ Support/Steam/htmlcache/* "Steam web cache"
    safe_clean ~/Library/Caches/com.epicgames.EpicGamesLauncher/* "Epic Games cache"
    safe_clean ~/Library/Caches/com.blizzard.Battle.net/* "Battle.net cache"
    safe_clean ~/Library/Application\ Support/Battle.net/Cache/* "Battle.net app cache"
    safe_clean ~/Library/Caches/com.ea.*/* "EA Origin cache"
    safe_clean ~/Library/Caches/com.gog.galaxy/* "GOG Galaxy cache"
    safe_clean ~/Library/Caches/com.riotgames.*/* "Riot Games cache"
    safe_clean ~/Library/Caches/com.youdao.YoudaoDict "Youdao Dictionary cache"
    safe_clean ~/Library/Caches/com.eudic.* "Eudict cache"
    safe_clean ~/Library/Caches/com.bob-build.Bob "Bob Translation cache"
    safe_clean ~/Library/Caches/com.cleanshot.* "CleanShot cache"
    safe_clean ~/Library/Caches/com.reincubate.camo "Camo cache"
    safe_clean ~/Library/Caches/com.xnipapp.xnip "Xnip cache"
    safe_clean ~/Library/Caches/com.readdle.smartemail-Mac "Spark cache"
    safe_clean ~/Library/Caches/com.airmail.* "Airmail cache"
    safe_clean ~/Library/Caches/com.todoist.mac.Todoist "Todoist cache"
    safe_clean ~/Library/Caches/com.any.do.* "Any.do cache"
    safe_clean ~/.zcompdump* "Zsh completion cache"
    safe_clean ~/.lesshst "less history"
    safe_clean ~/.viminfo.tmp "Vim temporary files"
    safe_clean ~/.wget-hsts "wget HSTS cache"
    safe_clean ~/Library/Caches/com.runjuu.Input-Source-Pro/* "Input Source Pro cache"
    safe_clean ~/Library/Caches/macos-wakatime.WakaTime/* "WakaTime cache"
    safe_clean ~/Library/Caches/notion.id/* "Notion cache"
    safe_clean ~/Library/Caches/md.obsidian/* "Obsidian cache"
    safe_clean ~/Library/Caches/com.logseq.*/* "Logseq cache"
    safe_clean ~/Library/Caches/com.bear-writer.*/* "Bear cache"
    safe_clean ~/Library/Caches/com.evernote.*/* "Evernote cache"
    safe_clean ~/Library/Caches/com.yinxiang.*/* "Yinxiang Note cache"
    safe_clean ~/Library/Caches/com.runningwithcrayons.Alfred/* "Alfred cache"
    safe_clean ~/Library/Caches/cx.c3.theunarchiver/* "The Unarchiver cache"
    safe_clean ~/Library/Caches/com.teamviewer.*/* "TeamViewer cache"
    safe_clean ~/Library/Caches/com.anydesk.*/* "AnyDesk cache"
    safe_clean ~/Library/Caches/com.todesk.*/* "ToDesk cache"
    safe_clean ~/Library/Caches/com.sunlogin.*/* "Sunlogin cache"

    end_section

    # ===== 11. Virtualization Tools =====
    start_section "Virtualization tools"
    safe_clean ~/Library/Caches/com.vmware.fusion "VMware Fusion cache"
    safe_clean ~/Library/Caches/com.parallels.* "Parallels cache"
    safe_clean ~/VirtualBox\ VMs/.cache "VirtualBox cache"
    safe_clean ~/.vagrant.d/tmp/* "Vagrant temporary files"
    end_section

    # ===== 12. Application Support logs cleanup =====
    start_section "Application Support logs"

    # Clean log directories for apps that store logs in Application Support
    for app_dir in ~/Library/Application\ Support/*; do
        [[ -d "$app_dir" ]] || continue
        app_name=$(basename "$app_dir")

        # Skip system and protected apps
        case "$app_name" in
            com.apple.* | Adobe* | 1Password | Claude)
                continue
                ;;
        esac

        # Clean common log directories
        if [[ -d "$app_dir/log" ]]; then
            safe_clean "$app_dir/log"/* "App logs: $app_name"
        fi
        if [[ -d "$app_dir/logs" ]]; then
            safe_clean "$app_dir/logs"/* "App logs: $app_name"
        fi
        if [[ -d "$app_dir/activitylog" ]]; then
            safe_clean "$app_dir/activitylog"/* "Activity logs: $app_name"
        fi
    done

    end_section

    # ===== 13. Orphaned app data cleanup =====
    # Only touch apps missing from comprehensive scan + 60+ days inactive
    # Skip protected vendors, keep Preferences/Application Support
    start_section "Orphaned app data cleanup"

    local -r ORPHAN_AGE_THRESHOLD=$ORPHAN_AGE_DAYS

    # Build list of installed application bundle identifiers
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning installed applications..."
    local installed_bundles=$(create_temp_file)
    local running_bundles=$(create_temp_file)
    local launch_agents=$(create_temp_file)

    # Scan multiple possible application locations to avoid false positives
    local -a search_paths=(
        "/Applications"
        "$HOME/Applications"
        "/System/Applications"
        "/System/Library/CoreServices/Applications"
        "/Library/Application Support"
        "$HOME/Library/Application Support"
        "/Users/Shared/Applications"
        "/Applications/Utilities"
    )

    # Add Homebrew paths if they exist
    [[ -d "/opt/homebrew/Caskroom" ]] && search_paths+=("/opt/homebrew/Caskroom")
    [[ -d "/usr/local/Caskroom" ]] && search_paths+=("/usr/local/Caskroom")
    [[ -d "/opt/homebrew/Cellar" ]] && search_paths+=("/opt/homebrew/Cellar")
    [[ -d "/usr/local/Cellar" ]] && search_paths+=("/usr/local/Cellar")

    # Add common developer paths
    [[ -d "$HOME/Developer" ]] && search_paths+=("$HOME/Developer")
    [[ -d "$HOME/Projects" ]] && search_paths+=("$HOME/Projects")
    [[ -d "$HOME/Downloads" ]] && search_paths+=("$HOME/Downloads")

    # Add other common third-party install locations
    [[ -d "/opt/apps" ]] && search_paths+=("/opt/apps")
    [[ -d "/opt/local/Applications" ]] && search_paths+=("/opt/local/Applications")
    [[ -d "/usr/local/apps" ]] && search_paths+=("/usr/local/apps")

    # Scan for .app bundles in all search paths
    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            while IFS= read -r app; do
                [[ -f "$app/Contents/Info.plist" ]] || continue
                bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2> /dev/null || echo "")
                [[ -n "$bundle_id" ]] && echo "$bundle_id" >> "$installed_bundles"
            done < <(find "$search_path" -maxdepth 3 -type d -name "*.app" 2> /dev/null || true)
        fi
    done

    # Use Spotlight fallback for apps in unusual locations
    if command -v mdfind > /dev/null 2>&1; then
        while IFS= read -r app; do
            [[ -f "$app/Contents/Info.plist" ]] || continue
            bundle_id=$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2> /dev/null || echo "")
            [[ -n "$bundle_id" ]] && echo "$bundle_id" >> "$installed_bundles"
        done < <(mdfind "kMDItemKind == 'Application'" 2> /dev/null | grep "\.app$" || true)
    fi

    # Get running applications
    local running_apps=$(osascript -e 'tell application "System Events" to get bundle identifier of every application process' 2> /dev/null || echo "")
    echo "$running_apps" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' > "$running_bundles"

    # Check LaunchAgents and LaunchDaemons
    find ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons \
        -name "*.plist" -type f 2> /dev/null | while IFS= read -r plist; do
        bundle_id=$(basename "$plist" .plist)
        echo "$bundle_id" >> "$launch_agents"
    done 2> /dev/null || true

    # Combine and deduplicate all bundle IDs
    sort -u "$installed_bundles" "$running_bundles" "$launch_agents" > "${installed_bundles}.final"
    mv "${installed_bundles}.final" "$installed_bundles"

    local app_count=$(wc -l < "$installed_bundles" | tr -d ' ')
    stop_inline_spinner
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $app_count active/installed apps"

    # Track statistics
    local orphaned_count=0
    local total_orphaned_kb=0

    # Check if bundle is orphaned - conservative approach
    is_orphaned() {
        local bundle_id="$1"
        local directory_path="$2"

        # Skip system-critical and protected apps
        if should_protect_data "$bundle_id"; then
            return 1
        fi

        # Check if app exists in our scan
        if grep -q "^$bundle_id$" "$installed_bundles" 2> /dev/null; then
            return 1
        fi

        # Extra check for system bundles
        case "$bundle_id" in
            com.apple.* | loginwindow | dock | systempreferences | finder | safari)
                return 1
                ;;
        esac

        # Skip major vendors
        case "$bundle_id" in
            com.adobe.* | com.microsoft.* | com.google.* | org.mozilla.* | com.jetbrains.* | com.docker.*)
                return 1
                ;;
        esac

        # Check file age - only clean if 60+ days inactive
        if [[ -e "$directory_path" ]]; then
            local last_access_epoch=$(stat -f%a "$directory_path" 2> /dev/null || echo "0")
            local current_epoch=$(date +%s)
            local days_since_access=$(((current_epoch - last_access_epoch) / 86400))

            if [[ $days_since_access -lt $ORPHAN_AGE_THRESHOLD ]]; then
                return 1
            fi
        fi

        return 0
    }

    # Clean orphaned caches
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned caches..."
    local cache_found=0
    if ls ~/Library/Caches/com.* > /dev/null 2>&1; then
        for cache_dir in ~/Library/Caches/com.* ~/Library/Caches/org.* ~/Library/Caches/net.* ~/Library/Caches/io.*; do
            [[ -d "$cache_dir" ]] || continue
            local bundle_id=$(basename "$cache_dir")
            if is_orphaned "$bundle_id" "$cache_dir"; then
                local size_kb=$(du -sk "$cache_dir" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    safe_clean "$cache_dir" "Orphaned cache: $bundle_id"
                    ((cache_found++))
                    ((total_orphaned_kb += size_kb))
                fi
            fi
        done
    fi
    stop_inline_spinner
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $cache_found orphaned caches"

    # Clean orphaned logs
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned logs..."
    local logs_found=0
    if ls ~/Library/Logs/com.* > /dev/null 2>&1; then
        for log_dir in ~/Library/Logs/com.* ~/Library/Logs/org.* ~/Library/Logs/net.* ~/Library/Logs/io.*; do
            [[ -d "$log_dir" ]] || continue
            local bundle_id=$(basename "$log_dir")
            if is_orphaned "$bundle_id" "$log_dir"; then
                local size_kb=$(du -sk "$log_dir" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    safe_clean "$log_dir" "Orphaned logs: $bundle_id"
                    ((logs_found++))
                    ((total_orphaned_kb += size_kb))
                fi
            fi
        done
    fi
    stop_inline_spinner
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $logs_found orphaned log directories"

    # Clean orphaned saved states
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned saved states..."
    local states_found=0
    if ls ~/Library/Saved\ Application\ State/*.savedState > /dev/null 2>&1; then
        for state_dir in ~/Library/Saved\ Application\ State/*.savedState; do
            [[ -d "$state_dir" ]] || continue
            local bundle_id=$(basename "$state_dir" .savedState)
            if is_orphaned "$bundle_id" "$state_dir"; then
                local size_kb=$(du -sk "$state_dir" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    safe_clean "$state_dir" "Orphaned state: $bundle_id"
                    ((states_found++))
                    ((total_orphaned_kb += size_kb))
                fi
            fi
        done
    fi
    stop_inline_spinner
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $states_found orphaned saved states"

    # Clean orphaned containers
    # Note: Disabled by default - container names may not match Bundle IDs
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned containers..."
    local containers_found=0
    local containers_size_kb=0
    if ls ~/Library/Containers/com.* > /dev/null 2>&1; then
        # Count potential orphaned containers but don't delete them
        for container_dir in ~/Library/Containers/com.* ~/Library/Containers/org.* ~/Library/Containers/net.* ~/Library/Containers/io.*; do
            [[ -d "$container_dir" ]] || continue
            local bundle_id=$(basename "$container_dir")
            if is_orphaned "$bundle_id" "$container_dir"; then
                local size_kb=$(du -sk "$container_dir" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    # DISABLED: Not cleaned due to potential Bundle ID mismatch risk
                    ((containers_found++))
                    ((containers_size_kb += size_kb))
                fi
            fi
        done
    fi
    stop_inline_spinner
    if [[ $containers_found -gt 0 ]]; then
        local containers_mb=$(echo "$containers_size_kb" | awk '{printf "%.1f", $1/1024}')
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Skipped $containers_found potential orphaned containers (~${containers_mb}MB)"
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No potential orphaned containers found"
    fi

    # Clean orphaned WebKit data
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned WebKit data..."
    local webkit_found=0
    if ls ~/Library/WebKit/com.* > /dev/null 2>&1; then
        for webkit_dir in ~/Library/WebKit/com.* ~/Library/WebKit/org.* ~/Library/WebKit/net.* ~/Library/WebKit/io.*; do
            [[ -d "$webkit_dir" ]] || continue
            local bundle_id=$(basename "$webkit_dir")
            if is_orphaned "$bundle_id" "$webkit_dir"; then
                local size_kb=$(du -sk "$webkit_dir" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    safe_clean "$webkit_dir" "Orphaned WebKit: $bundle_id"
                    ((webkit_found++))
                    ((total_orphaned_kb += size_kb))
                fi
            fi
        done
    fi
    stop_inline_spinner
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $webkit_found orphaned WebKit data"

    # Clean orphaned HTTP storages
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned HTTP storages..."
    local http_found=0
    if ls ~/Library/HTTPStorages/com.* > /dev/null 2>&1; then
        for http_dir in ~/Library/HTTPStorages/com.* ~/Library/HTTPStorages/org.* ~/Library/HTTPStorages/net.* ~/Library/HTTPStorages/io.*; do
            [[ -d "$http_dir" ]] || continue
            local bundle_id=$(basename "$http_dir")
            if is_orphaned "$bundle_id" "$http_dir"; then
                local size_kb=$(du -sk "$http_dir" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    safe_clean "$http_dir" "Orphaned HTTP storage: $bundle_id"
                    ((http_found++))
                    ((total_orphaned_kb += size_kb))
                fi
            fi
        done
    fi
    stop_inline_spinner
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $http_found orphaned HTTP storages"

    # Clean orphaned cookies
    MOLE_SPINNER_PREFIX="  " start_inline_spinner "Scanning orphaned cookies..."
    local cookies_found=0
    if ls ~/Library/Cookies/*.binarycookies > /dev/null 2>&1; then
        for cookie_file in ~/Library/Cookies/*.binarycookies; do
            [[ -f "$cookie_file" ]] || continue
            local bundle_id=$(basename "$cookie_file" .binarycookies)
            if is_orphaned "$bundle_id" "$cookie_file"; then
                local size_kb=$(du -sk "$cookie_file" 2> /dev/null | awk '{print $1}' || echo "0")
                if [[ "$size_kb" -gt 0 ]]; then
                    safe_clean "$cookie_file" "Orphaned cookies: $bundle_id"
                    ((cookies_found++))
                    ((total_orphaned_kb += size_kb))
                fi
            fi
        done
    fi
    stop_inline_spinner
    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Found $cookies_found orphaned cookie files"

    # Calculate total (exclude containers since they were not cleaned)
    orphaned_count=$((cache_found + logs_found + states_found + webkit_found + http_found + cookies_found))

    if [[ $orphaned_count -gt 0 ]]; then
        local orphaned_mb=$(echo "$total_orphaned_kb" | awk '{printf "%.1f", $1/1024}')
        echo "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $orphaned_count orphaned items (~${orphaned_mb}MB)"
        note_activity
    else
        echo "  ${GREEN}${ICON_SUCCESS}${NC} No orphaned app data found"
    fi

    rm -f "$installed_bundles" "$running_bundles" "$launch_agents"

    end_section

    # ===== 14. Apple Silicon optimizations =====
    if [[ "$IS_M_SERIES" == "true" ]]; then
        start_section "Apple Silicon optimizations"
        safe_clean /Library/Apple/usr/share/rosetta/rosetta_update_bundle "Rosetta 2 cache"
        safe_clean ~/Library/Caches/com.apple.rosetta.update "Rosetta 2 user cache"
        safe_clean ~/Library/Caches/com.apple.amp.mediasevicesd "Apple Silicon media service cache"
        # Skip: iCloud sync cache, may affect device pairing
        # safe_clean ~/Library/Caches/com.apple.bird.lsuseractivity "User activity cache"
        end_section
    fi

    # ===== 15. iOS device backups =====
    start_section "iOS device backups"
    backup_dir="$HOME/Library/Application Support/MobileSync/Backup"
    if [[ -d "$backup_dir" ]] && find "$backup_dir" -mindepth 1 -maxdepth 1 | read -r _; then
        backup_kb=$(du -sk "$backup_dir" 2> /dev/null | awk '{print $1}')
        if [[ -n "${backup_kb:-}" && "$backup_kb" -gt 102400 ]]; then
            backup_human=$(du -sh "$backup_dir" 2> /dev/null | awk '{print $1}')
            note_activity
            echo -e "  Found ${GREEN}${backup_human}${NC} iOS backups"
            echo -e "  You can delete them manually: ${backup_dir}"
        fi
    fi
    end_section

    # ===== 16. Time Machine failed backups =====
    start_section "Time Machine failed backups"
    local tm_cleaned=0

    # Check all mounted volumes for Time Machine backups
    if [[ -d "/Volumes" ]]; then
        for volume in /Volumes/*; do
            [[ -d "$volume" ]] || continue

            # Skip system volume and network volumes
            [[ "$volume" == "/Volumes/MacintoshHD" || "$volume" == "/" ]] && continue
            local fs_type=$(df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}')
            case "$fs_type" in
                nfs | smbfs | afpfs | cifs | webdav) continue ;;
            esac

            # Look for HFS+ style backups (Backups.backupdb)
            local backupdb_dir="$volume/Backups.backupdb"
            if [[ -d "$backupdb_dir" ]]; then
                # Find all .inProgress and .inprogress files (failed backups)
                # Support both .inProgress (official) and .inprogress (lowercase variant)
                while IFS= read -r inprogress_file; do
                    [[ -d "$inprogress_file" ]] || continue

                    local size_kb=$(du -sk "$inprogress_file" 2> /dev/null | awk '{print $1}' || echo "0")
                    if [[ "$size_kb" -gt 0 ]]; then
                        local backup_name=$(basename "$inprogress_file")

                        if [[ "$DRY_RUN" != "true" ]]; then
                            # Use tmutil to safely delete the failed backup
                            if command -v tmutil > /dev/null 2>&1; then
                                if tmutil delete "$inprogress_file" 2> /dev/null; then
                                    local size_human=$(bytes_to_human "$((size_kb * 1024))")
                                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Failed backup: $backup_name ${GREEN}($size_human)${NC}"
                                    ((tm_cleaned++))
                                    ((files_cleaned++))
                                    ((total_size_cleaned += size_kb))
                                    ((total_items++))
                                    note_activity
                                else
                                    echo -e "  ${YELLOW}!${NC} Could not delete: $backup_name (try manually with sudo)"
                                fi
                            else
                                echo -e "  ${YELLOW}!${NC} tmutil not available, skipping: $backup_name"
                            fi
                        else
                            local size_human=$(bytes_to_human "$((size_kb * 1024))")
                            echo -e "  ${YELLOW}→${NC} Failed backup: $backup_name ${YELLOW}($size_human dry)${NC}"
                            ((tm_cleaned++))
                            note_activity
                        fi
                    fi
                done < <(find "$backupdb_dir" -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
            fi

            # Look for APFS style backups (.backupbundle or .sparsebundle)
            # Note: These bundles are typically auto-mounted by macOS when needed
            # We check if they're already mounted to avoid mounting operations
            for bundle in "$volume"/*.backupbundle "$volume"/*.sparsebundle; do
                [[ -e "$bundle" ]] || continue
                [[ -d "$bundle" ]] || continue

                # Check if bundle is already mounted by looking at hdiutil info
                local bundle_name=$(basename "$bundle")
                local mounted_path=$(hdiutil info 2> /dev/null | grep -A 5 "image-path.*$bundle_name" | grep "/Volumes/" | awk '{print $1}' | head -1 || echo "")

                if [[ -n "$mounted_path" && -d "$mounted_path" ]]; then
                    # Bundle is already mounted, safe to check
                    while IFS= read -r inprogress_file; do
                        [[ -d "$inprogress_file" ]] || continue

                        local size_kb=$(du -sk "$inprogress_file" 2> /dev/null | awk '{print $1}' || echo "0")
                        if [[ "$size_kb" -gt 0 ]]; then
                            local backup_name=$(basename "$inprogress_file")

                            if [[ "$DRY_RUN" != "true" ]]; then
                                if command -v tmutil > /dev/null 2>&1; then
                                    if tmutil delete "$inprogress_file" 2> /dev/null; then
                                        local size_human=$(bytes_to_human "$((size_kb * 1024))")
                                        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Failed APFS backup in $bundle_name: $backup_name ${GREEN}($size_human)${NC}"
                                        ((tm_cleaned++))
                                        ((files_cleaned++))
                                        ((total_size_cleaned += size_kb))
                                        ((total_items++))
                                        note_activity
                                    else
                                        echo -e "  ${YELLOW}!${NC} Could not delete from bundle: $backup_name"
                                    fi
                                fi
                            else
                                local size_human=$(bytes_to_human "$((size_kb * 1024))")
                                echo -e "  ${YELLOW}→${NC} Failed APFS backup in $bundle_name: $backup_name ${YELLOW}($size_human dry)${NC}"
                                ((tm_cleaned++))
                                note_activity
                            fi
                        fi
                    done < <(find "$mounted_path" -type d \( -name "*.inProgress" -o -name "*.inprogress" \) 2> /dev/null || true)
                fi
            done
        done
    fi

    if [[ $tm_cleaned -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No failed Time Machine backups found"
    fi
    end_section

    # ===== Final summary =====
    echo ""

    local summary_heading=""
    local summary_status="success"
    if [[ "$DRY_RUN" == "true" ]]; then
        summary_heading="Dry run complete - no changes made"
    else
        summary_heading="Cleanup complete"
    fi

    local -a summary_details=()

    if [[ $total_size_cleaned -gt 0 ]]; then
        local freed_gb
        freed_gb=$(echo "$total_size_cleaned" | awk '{printf "%.2f", $1/1024/1024}')

        if [[ "$DRY_RUN" == "true" ]]; then
            # Build compact stats line for dry run
            local stats="Potential space: ${GREEN}${freed_gb}GB${NC}"
            [[ $files_cleaned -gt 0 ]] && stats+=" | Files: $files_cleaned"
            [[ $total_items -gt 0 ]] && stats+=" | Categories: $total_items"
            [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
            summary_details+=("$stats")
            summary_details+=("Use ${GRAY}mo clean --whitelist${NC} to protect caches")
        else
            summary_details+=("Space freed: ${GREEN}${freed_gb}GB${NC}")
            summary_details+=("Free space now: $(get_free_space)")

            if [[ $files_cleaned -gt 0 && $total_items -gt 0 ]]; then
                local stats="Files cleaned: $files_cleaned | Categories: $total_items"
                [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
                summary_details+=("$stats")
            elif [[ $files_cleaned -gt 0 ]]; then
                local stats="Files cleaned: $files_cleaned"
                [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
                summary_details+=("$stats")
            elif [[ $total_items -gt 0 ]]; then
                local stats="Categories: $total_items"
                [[ $whitelist_skipped_count -gt 0 ]] && stats+=" | Protected: $whitelist_skipped_count"
                summary_details+=("$stats")
            fi

            if [[ $(echo "$freed_gb" | awk '{print ($1 >= 1) ? 1 : 0}') -eq 1 ]]; then
                local movies
                movies=$(echo "$freed_gb" | awk '{printf "%.0f", $1/4.5}')
                if [[ $movies -gt 0 ]]; then
                    summary_details+=("Equivalent to ~$movies 4K movies of storage.")
                fi
            fi
        fi
    else
        summary_status="info"
        if [[ "$DRY_RUN" == "true" ]]; then
            summary_details+=("No significant reclaimable space detected (system already clean).")
        else
            summary_details+=("System was already clean; no additional space freed.")
        fi
        summary_details+=("Free space now: $(get_free_space)")
    fi

    print_summary_block "$summary_status" "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

main() {
    # Parse args (only dry-run and whitelist)
    for arg in "$@"; do
        case "$arg" in
            "--dry-run" | "-n")
                DRY_RUN=true
                ;;
            "--whitelist")
                source "$SCRIPT_DIR/../lib/whitelist_manager.sh"
                manage_whitelist
                exit 0
                ;;
        esac
    done

    start_cleanup
    hide_cursor
    perform_cleanup
    show_cursor
}

main "$@"
